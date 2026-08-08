#if os(iOS)
import SwiftUI
import UIKit
import PisakaCore

/// A monospaced code editor backed by `UITextView`, with tree-sitter syntax
/// highlighting via Neon's `TextViewHighlighter` — the UIKit peer of the macOS
/// `CodeEditorView`. The two share the same pure Core engines
/// (`IndentEngine`/`AutoPairEngine`), `SyntaxLanguageConfiguration`, and
/// `SyntaxTheme`; only the text-view API differs.
///
/// Per the Phase 1 plan decision, the line-number gutter and minimap are
/// deferred on iOS (low value on phones), so this is just the editing surface —
/// no `LineNumberRulerView`/`MinimapView` port.
///
/// The text is driven by a SwiftUI `Binding`; user edits flow back through it so
/// the workspace model can track dirty state. `fileID` identifies the shown file:
/// a change replaces the contents (a tab switch) rather than treating it as an
/// in-place edit. `fileName`'s *whole name* resolves the `SyntaxLanguage` — by
/// extension, by exact name (`Dockerfile`, `.env`), or by dot-ignore shape
/// (`.gitignore`) — or `nil` for an untitled/unknown file, shown as plain text
/// with no highlighter.
struct CodeEditorView_iOS: UIViewRepresentable {
    /// Identity of the file being edited; a change means a tab switch.
    let fileID: UUID

    /// The selected file's display name. Its extension selects the syntax
    /// language; `"Untitled"` (and unknown extensions) resolve to plain text.
    let fileName: String

    /// The selected file's on-disk location, or `nil` for an untitled buffer. Only
    /// the symbol index reads it — it keys files by URL, so an untitled buffer has
    /// nothing to be filed under and is skipped. Defaults to `nil` so a
    /// default-constructed view compiles.
    var fileURL: URL? = nil

    /// The editor contents. Edits are written back through this binding.
    @Binding var text: String

    /// The shared editor font size (points). Owned by `SettingsStore`; a change
    /// re-applies the font in `updateUIView`.
    let fontSize: Double

    /// Steps the shared font size. Wired to `SettingsStore.stepFontSize(by:)` and
    /// driven on iOS by a pinch-to-zoom gesture (the analog of the macOS
    /// Cmd+scroll), plus the Preferences stepper. Called with `+1`/`-1`; the store
    /// clamps.
    let onStepFontSize: (Double) -> Void

    /// Keeps the shown file's symbols current: an immediate re-index on tab open or
    /// switch, a debounced one while typing — the same controller and the same two
    /// triggers as macOS. Defaults to a controller over a fresh, never-walked index
    /// so a default-constructed view (previews) still compiles.
    var symbolIndex: SymbolIndexController = SymbolIndexController(model: SymbolIndexModel())

    func makeCoordinator() -> CodeEditorCoordinator_iOS {
        CodeEditorCoordinator_iOS(text: $text)
    }

    /// The shared monospaced editor font at the current size.
    private func editorFont() -> UIFont {
        .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    func makeUIView(context: Context) -> UITextView {
        // Build the text view explicitly as TextKit 1 (`usingTextLayoutManager:
        // false`), matching the macOS editor's known-good configuration. With no
        // `NSTextLayoutManager`, Neon styles through its `TextStorageSystemInterface`
        // (direct storage attributes), which the highlighter detach/plain-text
        // path in the coordinator relies on.
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.font = editorFont()
        textView.isEditable = true
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        // Long lines scroll horizontally rather than soft-wrapping, matching the
        // macOS editor (so a logical line is one visual row).
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.text = text

        context.coordinator.textView = textView
        context.coordinator.appliedFontSize = CGFloat(fontSize)
        context.coordinator.onStepFontSize = onStepFontSize

        // Pinch-to-zoom font sizing — the iOS analog of the macOS Cmd+scroll path.
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(CodeEditorCoordinator_iOS.handlePinch(_:))
        )
        textView.addGestureRecognizer(pinch)

        let language = SyntaxLanguage(forFileName: fileName)
        context.coordinator.fileID = fileID
        // Do not pre-assign `coordinator.language`: `updateHighlighter` compares
        // the incoming language against the stored one to decide whether to build
        // the highlighter, and sets `coordinator.language` itself.
        context.coordinator.updateHighlighter(
            for: textView,
            language: language,
            contentReplaced: false
        )
        // Index the shown file from its *buffer* text at once: iOS has no watcher,
        // so a tab open is one of the three moments the index moves forward at all,
        // and the file may sit outside the walked folder (a standalone document
        // pick) where nothing else would ever reach it.
        context.coordinator.symbolIndex = symbolIndex
        context.coordinator.fileURL = fileURL
        context.coordinator.reindexSymbols(text: text, language: language, immediate: true)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Keep the binding the coordinator writes to current across view updates.
        context.coordinator.text = $text

        // Re-apply the shared font when its size changed (the Preferences stepper
        // or a pinch). Setting `font` re-styles the whole buffer; the tree-sitter
        // colors (storage attributes) survive.
        let desiredFontSize = CGFloat(fontSize)
        if context.coordinator.appliedFontSize != desiredFontSize {
            context.coordinator.appliedFontSize = desiredFontSize
            textView.font = editorFont()
        }
        context.coordinator.onStepFontSize = onStepFontSize

        let switchedFile = context.coordinator.fileID != fileID
        context.coordinator.fileID = fileID

        let language = SyntaxLanguage(forFileName: fileName)

        // Replace the contents on a file switch, or when the model's text diverged
        // from the view (e.g. an external save/load). Avoid clobbering an
        // in-progress edit + selection when they already match.
        let contentReplaced = switchedFile || textView.text != text
        if contentReplaced {
            // Detach the active highlighter before swapping the buffer so the
            // outgoing grammar can't asynchronously repaint the incoming file.
            context.coordinator.detachHighlighter(from: textView)
            textView.text = text
            // Clear undo history on a real tab switch so one file's edits can't be
            // undone onto another's contents (iOS has no per-file undo-manager hook
            // like macOS `undoManagerForTextView`).
            if switchedFile {
                textView.undoManager?.removeAllActions()
            }
        }

        // Build/swap/detach the highlighter to match the selected file's language.
        context.coordinator.updateHighlighter(
            for: textView,
            language: language,
            contentReplaced: contentReplaced
        )

        // Re-index the shown file's symbols, immediately, on a tab switch or a
        // wholesale buffer swap only: ordinary keystrokes go through
        // `textViewDidChange`'s debounced call, so doing it here too would re-parse
        // the file twice per settled burst of typing.
        context.coordinator.symbolIndex = symbolIndex
        context.coordinator.fileURL = fileURL
        if switchedFile || contentReplaced {
            context.coordinator.reindexSymbols(
                text: textView.text,
                language: language,
                immediate: true
            )
        }
    }

    /// Detach the highlighter when the view is torn down (e.g. a tab closed) so the
    /// storage delegate doesn't linger.
    static func dismantleUIView(_ textView: UITextView, coordinator: CodeEditorCoordinator_iOS) {
        coordinator.detachHighlighter(from: textView)
    }
}

extension CodeEditorCoordinator_iOS {
    /// Step the shared font size on a pinch (the iOS analog of macOS Cmd+scroll).
    /// A continuous pinch is reduced to discrete `+1`/`-1` steps on threshold
    /// crossings so it drives the same clamped `SettingsStore.stepFontSize` path as
    /// the Preferences stepper.
    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchAccumulatedScale = 1
        case .changed:
            pinchAccumulatedScale *= gesture.scale
            gesture.scale = 1
            // ~15% growth per step up, the reciprocal down.
            while pinchAccumulatedScale >= 1.15 {
                onStepFontSize?(1)
                pinchAccumulatedScale /= 1.15
            }
            while pinchAccumulatedScale <= 1 / 1.15 {
                onStepFontSize?(-1)
                pinchAccumulatedScale *= 1.15
            }
        default:
            break
        }
    }
}
#endif
