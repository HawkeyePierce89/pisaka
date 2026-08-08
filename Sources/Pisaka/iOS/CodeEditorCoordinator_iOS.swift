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

    /// The shown file's on-disk location, or `nil` for an untitled buffer. Set by
    /// the representable; read only by the symbol re-index, which keys files by URL.
    var fileURL: URL?

    /// Schedules the symbol index's re-index of the shown file. Held *weakly* —
    /// the app owns it for its whole lifetime and this coordinator only asks it for
    /// work; a deallocated one means no re-index, which is what a preview gets.
    weak var symbolIndex: SymbolIndexController?

    /// Where a resolved definition is sent: the root view owns tab opening and the
    /// compact-width navigation stack, so this coordinator only asks. Weak for the
    /// same reason as `symbolIndex` — the root outlives every editor it shows.
    weak var definitionRoute: DefinitionRoute_iOS?

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

    /// The accessory strip offering completions above the keyboard. Built lazily,
    /// on the first non-empty candidate list, so a plain-text buffer or a session
    /// that never triggers completion pays nothing for it.
    private var completionBar: CompletionBar_iOS?

    /// The in-flight completion debounce/provider task; cancelled when a newer
    /// keystroke or caret move lands.
    private var completionTask: Task<Void, Never>?

    /// Monotonic token discarding a candidate list a newer request superseded while
    /// the provider was being awaited — the `BracketHighlightController` idiom, and
    /// the same guard the macOS `CompletionController` uses.
    private var completionGeneration = 0

    /// Debounce before a provider call. 150 ms, matching macOS: the question is put
    /// to a snapshot already in memory, so the cost is a prefix scan and a sort
    /// rather than the re-parse the 400 ms index debounce covers.
    private let completionDebounce: Duration = .milliseconds(150)

    /// How many characters must be typed before the strip offers anything. One
    /// character matches far too much to be a choice; the strip would flash a
    /// full-width row of noise on the first letter of every identifier.
    private static let minimumCompletionPrefixLength = 2

    /// The `DefinitionRoute_iOS.Reveal` token this editor last acted on, so a
    /// standing request is applied exactly once. `0` is below every issued token
    /// (they start at 1), so the first request always lands.
    private var appliedRevealToken = 0

    init(text: Binding<String>) {
        self.text = text
    }

    // MARK: - Edit bridging

    func textViewDidChange(_ textView: UITextView) {
        text.wrappedValue = textView.text
        // Keep this file's symbols in step with what is being typed, behind the
        // controller's 400 ms debounce (a re-parse per keystroke would be felt).
        reindexSymbols(text: textView.text, language: language, immediate: false)
        // Offer completions for the word being typed, behind this coordinator's own
        // (shorter) debounce. Its gates — a bare caret, at least two typed
        // characters, no marked text — mean an ordinary keystroke outside an
        // identifier costs one prefix scan and no task.
        updateCompletions(in: textView)
    }

    /// A caret move (a tap, an arrow key on a hardware keyboard, a selection drag)
    /// invalidates the strip as surely as a keystroke does: the word it answers is
    /// no longer the word being typed.
    func textViewDidChangeSelection(_ textView: UITextView) {
        updateCompletions(in: textView)
    }

    /// Re-index the shown file from its live buffer text — the peer of the macOS
    /// coordinator's method, with the same two triggers.
    ///
    /// `immediate` is the tab-open / buffer-swap case; typing goes through the
    /// debounce. An untitled buffer is skipped (the index is keyed by file URL), and
    /// the language gate lives in the controller, so a plain-text or unindexable
    /// file costs one call and no task.
    func reindexSymbols(text: String, language: SyntaxLanguage?, immediate: Bool) {
        guard let symbolIndex, let fileURL else { return }
        if immediate {
            symbolIndex.noteBufferOpened(url: fileURL, text: text, language: language)
        } else {
            symbolIndex.noteBufferChanged(url: fileURL, text: text, language: language)
        }
    }

    // MARK: - Go to definition

    /// Append "Go to Definition" to the selection's edit menu when the text under
    /// it is an identifier — the iOS entry point for the feature ⌘-click and ⌃⌘J
    /// drive on macOS.
    ///
    /// **The action is offered on the identifier, not on a resolved declaration**,
    /// and that is a shape constraint rather than a preference: UIKit builds the
    /// menu *synchronously* while it is already presenting it, whereas
    /// `CodeIntelligenceProviding` is async (a phase-2 LSP provider must await a
    /// socket). Awaiting the provider here is not possible, and pre-computing a
    /// lookup for every selection change — the inversion the macOS completion
    /// controller uses — would put a provider call behind every tap in the buffer
    /// to save one menu row. So the lookup happens on *tap*, and the empty answer
    /// is reported the way the plan specifies: a light haptic and nothing else.
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard symbolIndex != nil,
              IdentifierScanner.identifier(in: textView.text as NSString, at: range.location) != nil
        else { return nil }

        let action = UIAction(title: "Go to Definition") { [weak self, weak textView] _ in
            guard let self, let textView else { return }
            self.goToDefinition(in: textView, at: textView.selectedRange.location)
        }
        // Returning `nil` above leaves UIKit's own menu untouched; here the
        // suggested actions are carried through explicitly, so Cut/Copy/Paste and
        // the system's own items keep working beside the new one.
        return UIMenu(children: suggestedActions + [action])
    }

    /// Jump to the declaration of the identifier at `offset` — the single entry
    /// point behind the edit-menu action, mirroring the macOS coordinator's method
    /// so the two platforms cannot disagree about what counts as an identifier.
    ///
    /// Every decision is Core's: `IdentifierScanner` says which word the offset
    /// names, the provider ranks the candidates, and `DefinitionRoute_iOS` turns
    /// the count into a jump, a choice or a haptic.
    func goToDefinition(in textView: UITextView, at offset: Int) {
        guard let provider = symbolIndex?.provider,
              let match = IdentifierScanner.identifier(in: textView.text as NSString, at: offset)
        else {
            PlatformFeedback.light()
            return
        }
        let request = DefinitionRequest(
            identifier: match.text,
            fileURL: fileURL,
            offset: match.range.location
        )
        Task { [weak self] in
            let candidates = await provider.definitions(for: request)
            guard let route = self?.definitionRoute else { return }
            route.present(candidates)
        }
    }

    /// Select and scroll to a pending definition jump, if it targets the file this
    /// editor is showing and has not been applied yet — the iOS peer of the macOS
    /// coordinator's `applyReveal`, with the same one-shot token rule.
    ///
    /// The selection is deferred by one main-loop turn: the caller runs inside
    /// `updateUIView`, where the buffer may have just been replaced wholesale and
    /// TextKit has not laid the new text out — scrolling there would compute
    /// against the outgoing layout. The range is clamped to the live buffer, so a
    /// declaration recorded before an edit shrank the file can never raise.
    func applyReveal(_ request: DefinitionRoute_iOS.Reveal?, fileID: UUID) {
        guard let request,
              request.token != appliedRevealToken,
              request.fileID == fileID,
              textView != nil
        else { return }
        appliedRevealToken = request.token
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView else { return }
            let length = (textView.text as NSString).length
            guard request.range.location != NSNotFound,
                  request.range.location >= 0,
                  request.range.location <= length
            else { return }
            let range = NSIntersectionRange(
                request.range,
                NSRange(location: 0, length: length)
            )
            if let textRange = textView.uiTextRange(for: range) {
                textView.selectedTextRange = textRange
            }
            textView.scrollRangeToVisible(range)
        }
    }

    // MARK: - Completion

    /// Recompute the accessory strip's candidates for whatever is being typed.
    ///
    /// The request is built here, on the main actor, from the live buffer — the
    /// text goes *into* the request rather than being read after the hop, so the
    /// words the provider harvests are the ones on screen when the user paused.
    private func updateCompletions(in textView: UITextView) {
        completionTask?.cancel()
        completionTask = nil
        completionGeneration += 1
        let token = completionGeneration

        guard let provider = symbolIndex?.provider,
              // No offers mid-composition. Marked text is uncommitted input the
              // input method still owns; completing over it would insert into a
              // range the composition is about to replace.
              textView.markedTextRange == nil,
              // A non-empty selection is not a partial word: the user is about to
              // replace it, not extend it.
              let caret = textView.selectedTextRange, caret.isEmpty
        else {
            showCompletions([], in: textView)
            return
        }

        let nsText = textView.text as NSString
        let offset = textView.offset(from: textView.beginningOfDocument, to: caret.start)
        let prefixRange = IdentifierScanner.completionPrefixRange(in: nsText, at: offset)
        guard prefixRange.length >= Self.minimumCompletionPrefixLength else {
            showCompletions([], in: textView)
            return
        }

        let request = CompletionRequest(
            prefix: nsText.substring(with: prefixRange),
            fileURL: fileURL,
            text: textView.text
        )
        let interval = completionDebounce
        completionTask = Task { [weak self, weak textView] in
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            let items = await provider.completions(for: request)
            guard let self, let textView, !Task.isCancelled, token == self.completionGeneration
            else { return }
            self.completionTask = nil
            // Re-read the caret rather than trusting it from before the await: a
            // tap or an undo in the meantime moves the strip's subject to a word
            // these items do not answer.
            guard textView.markedTextRange == nil,
                  let caret = textView.selectedTextRange, caret.isEmpty
            else {
                self.showCompletions([], in: textView)
                return
            }
            let liveText = textView.text as NSString
            let offset = textView.offset(from: textView.beginningOfDocument, to: caret.start)
            let range = IdentifierScanner.completionPrefixRange(in: liveText, at: offset)
            guard range.length > 0, liveText.substring(with: range) == request.prefix else {
                self.showCompletions([], in: textView)
                return
            }
            self.showCompletions(items.map(\.text), in: textView)
        }
    }

    /// Install, update or remove the accessory strip.
    ///
    /// `reloadInputViews()` is called only when the strip's *presence* changes, not
    /// on every candidate list: it re-queries the responder's input views and
    /// visibly re-lays the keyboard, which per keystroke would read as a flicker.
    /// An empty list removes the bar rather than showing an empty one, so it never
    /// occupies space for nothing.
    private func showCompletions(_ items: [String], in textView: UITextView) {
        guard !items.isEmpty else {
            guard textView.inputAccessoryView != nil else { return }
            textView.inputAccessoryView = nil
            textView.reloadInputViews()
            return
        }

        let bar = completionBar ?? {
            let bar = CompletionBar_iOS()
            bar.onSelect = { [weak self] item in self?.insertCompletion(item) }
            completionBar = bar
            return bar
        }()
        bar.setItems(items)
        guard textView.inputAccessoryView !== bar else { return }
        textView.inputAccessoryView = bar
        textView.reloadInputViews()
    }

    /// Replace the partial word at the caret with a tapped candidate.
    ///
    /// Routed through `applyEdit` — the same path auto-pair, dedent and the
    /// indented newline take — so the insertion is one undo step and passes the
    /// programmatic-edit guard, meaning a candidate ending in `(` cannot fall into
    /// `AutoPairEngine` and collect a closing bracket it never asked for.
    ///
    /// The prefix range is recomputed here rather than remembered from the
    /// provider call: the strip is a live view, and a tap can land after another
    /// keystroke has already moved the word it answers.
    private func insertCompletion(_ item: String) {
        guard let textView,
              textView.markedTextRange == nil,
              let caret = textView.selectedTextRange, caret.isEmpty
        else { return }
        let nsText = textView.text as NSString
        let offset = textView.offset(from: textView.beginningOfDocument, to: caret.start)
        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: offset)
        guard range.length > 0, item.hasPrefix(nsText.substring(with: range)) else { return }

        applyEdit(
            in: textView,
            range: range,
            replacement: item,
            selecting: NSRange(
                location: range.location + (item as NSString).length,
                length: 0
            )
        )
        // `applyEdit` fires `textViewDidChange` synchronously, which schedules a
        // fresh debounce for the just-completed word; drop it. Offering longer
        // names the instant a choice was made is how a completion strip turns into
        // a treadmill.
        clearCompletions()
    }

    /// Hide the strip and supersede an in-flight provider call — what an insertion
    /// that just answered the question needs. The bar object itself is kept for
    /// reuse; only `tearDownCompletions(in:)` lets it go.
    func clearCompletions() {
        completionTask?.cancel()
        completionTask = nil
        completionGeneration += 1
        if let textView {
            showCompletions([], in: textView)
        }
    }

    /// Detach the strip on view teardown (a tab closed), alongside the highlighter.
    ///
    /// The accessory view is attached to the *responder*, not to the view
    /// hierarchy, so nothing else would drop it; leaving it installed on a text
    /// view SwiftUI is about to discard keeps a stale candidate row alive over the
    /// next file.
    func tearDownCompletions(in textView: UITextView) {
        completionTask?.cancel()
        completionTask = nil
        completionGeneration += 1
        if textView.inputAccessoryView === completionBar {
            textView.inputAccessoryView = nil
        }
        completionBar?.onSelect = nil
        completionBar = nil
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
