#if os(iOS)
import SwiftUI
import UIKit
import Neon
import PisakaCore

/// Bridges `UITextView` edits back into the SwiftUI binding and owns the
/// tree-sitter highlighter for the currently shown file. The UIKit peer of
/// `CodeEditorView.Coordinator`, sharing the same pure Core engines
/// (`IndentEngine`/`AutoPairEngine`), `SyntaxLanguageConfiguration`, and
/// `SyntaxTheme` — only the text-view API differs.
///
/// All the indent/auto-pair decision logic is pure and lives in `PisakaCore`;
/// this is thin, untested view glue (per project convention), mirroring the
/// macOS coordinator's semantics: a programmatic-edit re-entry guard and
/// single-step-undoable programmatic edits.
@MainActor
final class CodeEditorCoordinator_iOS: NSObject, UITextViewDelegate {
    /// The binding user edits flow back into so the workspace model tracks dirty
    /// state.
    var text: Binding<String>

    /// Identity of the file currently shown; a change means a tab switch.
    var fileID: UUID?

    /// The language whose highlighter is currently attached (`nil` = plain text,
    /// no highlighter). Drives the rebuild decision on a tab/language switch.
    var language: SyntaxLanguage?

    /// The text view this coordinator drives. Held weakly — the representable's
    /// view hierarchy owns it.
    weak var textView: UITextView?

    /// The editor font size currently applied, so the representable re-applies the
    /// shared font only when the size actually changed.
    var appliedFontSize: CGFloat?

    /// Steps the shared font size (the pinch-to-zoom path). Wired to
    /// `SettingsStore.stepFontSize(by:)`; `nil` until the view sets it.
    var onStepFontSize: ((Double) -> Void)?

    /// Accumulated pinch scale since the gesture began, reduced to discrete font
    /// steps on threshold crossings (see `handlePinch`).
    var pinchAccumulatedScale: CGFloat = 1

    /// The active Neon highlighter. It installs itself as the text storage's
    /// delegate; replacing it (or setting it to `nil`) detaches the old one.
    private var highlighter: TextViewHighlighter?

    /// Identifies the current highlighter so a superseded one (built before a
    /// later rebuild) can't restyle the reused text view. Mirrors the macOS
    /// `HighlighterGeneration`.
    private let highlighterGeneration = HighlighterGeneration_iOS()

    /// Guards against re-entering the change interceptor while applying a
    /// programmatic indent or auto-pair edit. `replace(_:withText:)` can re-invoke
    /// `shouldChangeTextIn` synchronously; while this is set the interceptor lets
    /// the programmatic edit through untouched (mirrors the macOS guard).
    private var isApplyingProgrammaticEdit = false

    init(text: Binding<String>) {
        self.text = text
    }

    // MARK: - Edit bridging

    func textViewDidChange(_ textView: UITextView) {
        text.wrappedValue = textView.text
    }

    /// Intercept single-character input, Return, and Backspace for auto-indent and
    /// auto-close, mirroring the macOS coordinator. Returns `false` (suppressing
    /// the default edit) when a handler applied a programmatic edit, else `true`.
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText: String
    ) -> Bool {
        guard !isApplyingProgrammaticEdit else { return true }

        // Return → indented newline (the iOS equivalent of macOS `insertNewline:`).
        if replacementText == "\n" {
            return !insertIndentedNewline(in: textView, range: range)
        }

        // Backspace of a single character → delete an empty auto-inserted pair
        // whole, if the caret sits between one.
        if replacementText.isEmpty, range.length == 1 {
            return !deleteAutoPair(in: textView, range: range)
        }

        // A single typed character → auto-close brackets/quotes, or dedent on a
        // closing bracket.
        if replacementText.count == 1 {
            return !applyAutoPairOrDedent(in: textView, range: range, typed: replacementText)
        }

        return true
    }

    // MARK: - Auto-indent

    /// Replace the selection (or caret) with a computed newline+indent via
    /// `IndentEngine`. Returns `true` when it applied the edit.
    private func insertIndentedNewline(in textView: UITextView, range: NSRange) -> Bool {
        let nsText = textView.text as NSString
        let unit = IndentEngine.inferIndentUnit(text: nsText)
        let edit = IndentEngine.newlineIndentation(
            text: nsText,
            location: range.location,
            unit: unit,
            selectionLength: range.length
        )
        // `consumeAfter` extends the deleted range to also swallow trailing
        // whitespace just past the selection (the opener case) so it doesn't stack
        // on the inserted indent.
        let replacementRange = NSRange(
            location: range.location,
            length: range.length + edit.consumeAfter
        )
        applyEdit(
            in: textView,
            range: replacementRange,
            replacement: edit.text,
            // Place the caret at the engine's offset (e.g. on the indented middle
            // line of a between-brackets split), measured from the edit start.
            selecting: NSRange(location: range.location + edit.cursorOffset, length: 0)
        )
        return true
    }

    // MARK: - Auto-close / dedent

    /// When Backspace at an empty selection sits between an empty auto-inserted
    /// pair `(|)`, `"|"`, …, delete both characters in one undoable edit. The
    /// deletion range is `[caret-1, 1]`, so the caret is `range.location + 1`.
    private func deleteAutoPair(in textView: UITextView, range: NSRange) -> Bool {
        let caret = range.location + 1
        let nsText = textView.text as NSString
        guard AutoPairEngine.shouldDeletePair(text: nsText, location: caret) else {
            return false
        }
        applyEdit(
            in: textView,
            range: NSRange(location: caret - 1, length: 2),
            replacement: "",
            selecting: NSRange(location: caret - 1, length: 0)
        )
        return true
    }

    /// Run a single typed character through `AutoPairEngine`, then the
    /// dedent-on-closing path for a closer that doesn't auto-pair. Returns `true`
    /// when it applied a programmatic edit.
    private func applyAutoPairOrDedent(
        in textView: UITextView,
        range: NSRange,
        typed: String
    ) -> Bool {
        let nsText = textView.text as NSString
        switch AutoPairEngine.action(text: nsText, selectedRange: range, typed: typed) {
        case .wrap(let open, let close):
            // Surround the selection with the pair; leave the selection on the
            // (unchanged) inner text between the inserted delimiters.
            let inner = nsText.substring(with: range)
            applyEdit(
                in: textView,
                range: range,
                replacement: open + inner + close,
                selecting: NSRange(
                    location: range.location + (open as NSString).length,
                    length: (inner as NSString).length
                )
            )
            return true

        case .insertPair(let close):
            // Insert opener+closer, then drop the caret between them.
            applyEdit(
                in: textView,
                range: range,
                replacement: typed + close,
                selecting: NSRange(
                    location: range.location + (typed as NSString).length,
                    length: 0
                )
            )
            return true

        case .typeOver:
            // The identical closer already sits after the caret: step over it
            // instead of inserting a duplicate.
            setCaret(in: textView, to: range.location + 1)
            return true

        case .passthrough:
            return applyDedentIfNeeded(in: textView, range: range, typed: typed)
        }
    }

    /// The dedent-on-closing path, reached only when auto-pair passed the
    /// keystroke through. Rewrites a whitespace-only line prefix to the opener
    /// line's indentation and inserts the bracket in one undoable edit when
    /// `IndentEngine.dedentOnClosing` finds a match; otherwise the keystroke passes
    /// through.
    private func applyDedentIfNeeded(
        in textView: UITextView,
        range: NSRange,
        typed: String
    ) -> Bool {
        guard
            range.length == 0,
            let closing = typed.first,
            closing == "}" || closing == ")" || closing == "]"
        else { return false }

        let nsText = textView.text as NSString
        guard let replacement = IndentEngine.dedentOnClosing(
            text: nsText,
            location: range.location,
            closing: closing
        ) else { return false }

        let newPrefix = replacement.replacement + String(closing)
        applyEdit(
            in: textView,
            range: replacement.range,
            replacement: newPrefix,
            selecting: NSRange(
                location: replacement.range.location + (newPrefix as NSString).length,
                length: 0
            )
        )
        return true
    }

    // MARK: - Programmatic edits

    /// Apply a programmatic replacement as one undoable edit through the text
    /// input system (`replace(_:withText:)` registers a single undo action and
    /// fires `textViewDidChange`), then place the selection. The re-entry guard is
    /// held across the call so the interceptor lets the programmatic edit through.
    private func applyEdit(
        in textView: UITextView,
        range: NSRange,
        replacement: String,
        selecting selection: NSRange
    ) {
        guard let textRange = textView.uiTextRange(for: range) else { return }
        isApplyingProgrammaticEdit = true
        textView.replace(textRange, withText: replacement)
        isApplyingProgrammaticEdit = false
        if let selectionRange = textView.uiTextRange(for: selection) {
            textView.selectedTextRange = selectionRange
        }
        // `replace` fires `textViewDidChange`, but update the binding directly too
        // so it never lags a programmatic edit.
        text.wrappedValue = textView.text
    }

    private func setCaret(in textView: UITextView, to location: Int) {
        if let caretRange = textView.uiTextRange(for: NSRange(location: location, length: 0)) {
            textView.selectedTextRange = caretRange
        }
    }

    // MARK: - Highlighter

    /// Detach the active highlighter (if any) before a wholesale buffer swap so
    /// the outgoing grammar can't asynchronously repaint the incoming file.
    func detachHighlighter(from textView: UITextView) {
        highlighter = nil
        textView.textStorage.delegate = nil
    }

    /// Attach, swap, or detach the highlighter so it matches `language`. Rebuilds
    /// on a language change, or when the language is unchanged but the buffer was
    /// replaced wholesale (`contentReplaced`).
    func updateHighlighter(
        for textView: UITextView,
        language: SyntaxLanguage?,
        contentReplaced: Bool
    ) {
        let languageChanged = language != self.language
        self.language = language
        if languageChanged || contentReplaced {
            rebuildHighlighter(for: textView, language: language)
        }
    }

    /// Tear down the current highlighter and, if `language` resolves to a loadable
    /// grammar, build a fresh one whose attribute provider maps each tree-sitter
    /// capture through `SyntaxTokenKind` to a `SyntaxTheme` color.
    private func rebuildHighlighter(for textView: UITextView, language: SyntaxLanguage?) {
        let generation = highlighterGeneration.advance()

        // Detach the old highlighter (it is the text storage's delegate).
        highlighter = nil
        textView.textStorage.delegate = nil

        guard
            let language,
            let languageConfiguration = SyntaxLanguageConfiguration.configuration(for: language)
        else {
            // Untitled / unknown extension: plain text, no highlighter. Clear any
            // colors a previous highlighter left behind. On iOS with a TextKit 1
            // text view (`usingTextLayoutManager: false`), Neon falls back to the
            // `TextStorageSystemInterface`, which writes attributes directly on the
            // storage — so resetting the storage foreground is enough (no
            // layout-manager temporary attributes to clear, unlike macOS).
            let storage = textView.textStorage
            if storage.length > 0 {
                let fullRange = NSRange(location: 0, length: storage.length)
                storage.removeAttribute(.foregroundColor, range: fullRange)
                storage.addAttribute(
                    .foregroundColor,
                    value: textView.textColor ?? .label,
                    range: fullRange
                )
            }
            return
        }

        let theme = SyntaxTheme.shared
        let highlighterGeneration = self.highlighterGeneration
        let attributeProvider: TokenAttributeProvider = { token in
            guard highlighterGeneration.current == generation else { return [:] }
            let kind = SyntaxTokenKind(captureName: token.name)
            return [.foregroundColor: theme.color(for: kind)]
        }

        let configuration = TextViewHighlighter.Configuration(
            languageConfiguration: languageConfiguration,
            attributeProvider: attributeProvider,
            languageProvider: { name in
                SyntaxLanguageConfiguration.configuration(forInjectionName: name)
            },
            locationTransformer: { _ in nil }
        )

        // A grammar that fails to start the parser degrades to plain text rather
        // than crashing the editor.
        highlighter = try? TextViewHighlighter(textView: textView, configuration: configuration)
    }
}

/// A monotonic counter identifying the live highlighter (the UIKit peer of the
/// macOS `HighlighterGeneration`). Each rebuilt highlighter captures `advance()`'s
/// value; its attribute provider styles only while that snapshot equals `current`,
/// so a superseded highlighter's lingering async work can't paint a previous
/// grammar's colors onto the reused text view.
final class HighlighterGeneration_iOS {
    private(set) var current = 0

    func advance() -> Int {
        current += 1
        return current
    }
}

extension UITextView {
    /// Convert a UTF-16 `NSRange` into the `UITextRange` the text-input edit/select
    /// APIs require, clamped to the document. `nil` when the range can't be mapped.
    func uiTextRange(for range: NSRange) -> UITextRange? {
        guard
            let start = position(from: beginningOfDocument, offset: range.location),
            let end = position(from: start, offset: range.length)
        else { return nil }
        return textRange(from: start, to: end)
    }
}
#endif
