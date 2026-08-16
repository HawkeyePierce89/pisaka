#if os(macOS)
import SwiftUI
import AppKit
import Neon
import PisakaCore

/// The SwiftUI content of a **source viewer** window: one file, shown read-only,
/// syntax-highlighted, scrolled to a range (D3).
///
/// This is where a Go to Definition lands when the declaration lives *outside* the
/// opened folder — an SDK `.swiftinterface`, a dependency checkout, a generated
/// header. Such a target must not become a tab: a tab carries a `WorkspaceModel`
/// entry, a dirty flag and an autosave participation, and the whole point of the
/// decision is that a semantic jump into the SDK **structurally cannot write
/// outside the project root**. So the file arrives here as an immutable `String`
/// the window controller already read, and there is no path from this view back to
/// disk — no binding, no save, no `WorkspaceModel`, no `AutosaveController`.
///
/// Modeled on `DiffWindowContent` + `DiffView`'s read-only pane: same
/// `preferredColorScheme` propagation into a separate window, same Neon
/// highlighting through `SyntaxLanguageConfiguration`/`SyntaxTheme`, same
/// Cmd+scroll font step. Unlike the diff it loads nothing asynchronously — the
/// text is read before the window exists, precisely so an unreadable target can
/// beep instead of opening an empty window.
struct SourceViewerContent: View {
    /// Identity of the shown file *for the reveal token* (see `reveal`). One
    /// viewer window shows one file for its whole lifetime, so this is generated
    /// once by the controller and never changes.
    let fileID: UUID

    /// The file's name (last path component). Selects the syntax language, exactly
    /// as it does for a diff pane.
    let fileName: String

    /// The file's contents, read once by `SourceViewerWindowController` before the
    /// window was created. Immutable by construction.
    let text: String

    /// Shared user preferences, observed so the viewer's font tracks the editor's
    /// (Preferences stepper or Cmd+scroll) and a forced Light/Dark reaches this
    /// separate window's hosted AppKit content — the `DiffWindowContent` rule.
    @ObservedObject var settings: SettingsStore

    /// The pending "scroll to this range" request. Reused rather than reinvented:
    /// a second ⌘-click landing in a file already open in a viewer re-reveals
    /// through the same one-shot token mechanism the editor consumes for a Find in
    /// Files activation, instead of opening a second window on the same file.
    @ObservedObject var reveal: EditorRevealState

    var body: some View {
        SourceViewerPane(
            fileID: fileID,
            fileName: fileName,
            text: text,
            fontSize: settings.fontSize,
            reveal: reveal
        )
        .preferredColorScheme(settings.themePreference.colorScheme)
    }
}

/// The viewer's single read-only pane: a non-wrapping `NSTextView` in a scroll
/// view with the editor's own `LineNumberRulerView` gutter and Neon highlighting.
///
/// Deliberately *not* `CodeEditorView` with `isEditable = false`: that view brings
/// the whole editing apparatus — the binding it writes back through, per-file undo
/// managers, auto-pair/indent interception, the symbol-index re-index, blame, the
/// minimap, completion — none of which has a meaning for a file the user cannot
/// edit and which is not a tab. What is left after removing all of it is this,
/// and it is the same shape as `DiffView.makePane`.
struct SourceViewerPane: NSViewRepresentable {
    let fileID: UUID
    let fileName: String
    let text: String
    var fontSize: Double
    @ObservedObject var reveal: EditorRevealState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SourceViewerTextView(usingTextLayoutManager: false)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView

        // Same TextKit 1 / no-soft-wrap setup as the editor and the diff panes: a
        // logical line is one visual row, so the gutter's numbers line up with the
        // lines the server counted.
        let maxSize = CGFloat.greatestFiniteMagnitude
        textView.minSize = .zero
        textView.maxSize = NSSize(width: maxSize, height: maxSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: maxSize, height: maxSize)
        textView.layoutManager?.allowsNonContiguousLayout = true

        // Read-only, but selectable: copying a signature out of an SDK interface is
        // the second thing anyone does after jumping into one.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)

        // The editor's own gutter. `canAnnotate` stays false (its default), so its
        // one context-menu item is greyed out — blaming a file outside the
        // repository would be a `git` error, not an annotation.
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let coordinator = context.coordinator
        coordinator.attach(scrollView: scrollView, textView: textView, ruler: ruler)
        coordinator.appliedFontSize = CGFloat(fontSize)
        coordinator.load(text: text, fileName: fileName)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator

        // Re-apply the shared font when its size changed, exactly as the diff panes
        // do: setting `.font` re-styles the whole buffer and the tree-sitter colors
        // (temporary attributes on the layout manager) survive.
        let desiredFontSize = CGFloat(fontSize)
        if coordinator.appliedFontSize != desiredFontSize {
            coordinator.appliedFontSize = desiredFontSize
            coordinator.textView?.font = .monospacedSystemFont(ofSize: desiredFontSize, weight: .regular)
            coordinator.ruler?.editorFontChanged()
        }

        // The shown file never changes for a given window, so this is the one
        // update that does anything after the first: a fresh jump into a file whose
        // viewer is already open bumps the reveal token.
        coordinator.applyReveal(reveal.request, fileID: fileID)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Owns the pane's Neon highlighter and consumes reveal requests.
    @MainActor
    final class Coordinator: NSObject {
        /// Held weakly — the view hierarchy owns them, this only observes (the
        /// `DiffView.Coordinator` rule).
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var ruler: LineNumberRulerView?

        /// The font size currently applied, so `updateNSView` re-applies only on a
        /// real change.
        var appliedFontSize: CGFloat?

        /// The highlighter installs itself as the text storage's delegate; held
        /// strongly so it lives as long as the window does.
        private var highlighter: TextViewHighlighter?

        /// The last reveal token applied, so a view update triggered by anything
        /// else (a font change, a theme switch) does not yank the selection back.
        private var appliedRevealToken: Int?

        func attach(scrollView: NSScrollView, textView: NSTextView, ruler: LineNumberRulerView) {
            self.scrollView = scrollView
            self.textView = textView
            self.ruler = ruler
        }

        /// Install the file's text and build its highlighter.
        func load(text: String, fileName: String) {
            textView?.string = text
            guard let textView else { return }
            highlighter = Self.makeHighlighter(
                for: textView,
                language: SyntaxLanguage(forFileName: fileName)
            )
        }

        /// Select `request.range` and scroll it into view — the same one-shot,
        /// token-guarded, clamped rule as `CodeEditorView.Coordinator.applyReveal`,
        /// including the deferral to the next turn so the target range has been
        /// laid out (a freshly created window has not laid anything out yet).
        func applyReveal(_ request: EditorRevealState.Request?, fileID: UUID) {
            guard let request,
                  request.token != appliedRevealToken,
                  request.fileID == fileID,
                  textView != nil
            else { return }
            appliedRevealToken = request.token
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                let length = textView.textStorage?.length ?? 0
                guard request.range.location != NSNotFound,
                      request.range.location >= 0,
                      request.range.location <= length
                else { return }
                // Clamped by truncating the length rather than intersecting, for
                // the reason spelled out on the editor's copy: an empty range at
                // the very end of the buffer must not scroll to the top.
                let range = NSRange(
                    location: request.range.location,
                    length: min(request.range.length, length - request.range.location)
                )
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
            }
        }

        func teardown() {
            highlighter = nil
            textView?.textStorage?.delegate = nil
        }

        /// Build a Neon highlighter mapping each tree-sitter capture through
        /// `SyntaxTokenKind` to a `SyntaxTheme` color — the same three lines the
        /// editor and the diff panes use, so a `.swiftinterface` reads exactly like
        /// a project file. `nil` for plain text / a grammar that fails to load,
        /// which degrades to unstyled text rather than to no window.
        private static func makeHighlighter(
            for textView: NSTextView,
            language: SyntaxLanguage?
        ) -> TextViewHighlighter? {
            guard
                let language,
                let languageConfiguration = SyntaxLanguageConfiguration.configuration(for: language)
            else { return nil }

            let theme = SyntaxTheme.shared
            let attributeProvider: TokenAttributeProvider = { token in
                [.foregroundColor: theme.nsColor(for: SyntaxTokenKind(captureName: token.name))]
            }
            let configuration = TextViewHighlighter.Configuration(
                languageConfiguration: languageConfiguration,
                attributeProvider: attributeProvider,
                languageProvider: { name in
                    SyntaxLanguageConfiguration.configuration(forInjectionName: name)
                },
                locationTransformer: { _ in nil }
            )
            return try? TextViewHighlighter(textView: textView, configuration: configuration)
        }
    }
}

/// The viewer's text view. An ordinary read-only `NSTextView` that declares
/// itself a code surface, so zooming works the same here as in the editor, the
/// diff and the merge panes — through the app's one event monitor rather than a
/// `scrollWheel` override of its own.
@MainActor
final class SourceViewerTextView: NSTextView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code
}

#endif
