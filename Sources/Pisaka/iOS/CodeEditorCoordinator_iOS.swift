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

    /// Answers what `.editorconfig` says about the shown file, for the two
    /// synchronous key handlers below. Held *weakly*, like `symbolIndex`: the app
    /// owns it for its whole lifetime and this only ever asks it a question. A
    /// deallocated one means empty properties, which is exactly the "no
    /// configuration applies" answer — so the editor degrades to the content
    /// inference rather than misbehaving.
    weak var editorConfig: EditorConfigModel?

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

    /// The member position the strip's current items answer, or `nil` when they
    /// answer an ordinary partial word.
    ///
    /// Carried — **receiver and all** — for exactly the reason the macOS
    /// `CompletionController.Snapshot` carries it, and compared at **every** prefix
    /// length rather than only at zero. A caret move does **not** clear the strip
    /// synchronously — `textViewDidChangeSelection` schedules the same 150 ms
    /// debounce a keystroke does — so for that window the previous receiver's rows
    /// are still on screen. Without the compare, a tap landing in that window
    /// inserts a member of `Worker` at the `other.` caret (the zero-length case:
    /// "still after *a* dot" is satisfied by every other dot in the buffer), and
    /// equally inserts one of `worker.na`'s members over an unrelated `na`, which
    /// a fuzzy-match test of the typed characters alone waves through.
    private var answeredMember: IdentifierScanner.MemberContext?

    /// Whether the completion strip is offered at all —
    /// `SettingsStore.completionEnabled`, forwarded here by
    /// `CodeEditorView_iOS.updateUIView`. The macOS peer is
    /// `CompletionController.isEnabled`, and the switch means the same thing on
    /// both platforms: **binary and total**, since the strip has no explicit
    /// invocation of its own, off simply means no request is made and no bar is
    /// installed.
    ///
    /// **Nothing in the intelligence stack is torn down** by turning this off: the
    /// symbol index keeps walking and refreshing, the provider is untouched, and
    /// Go to Definition — which asks that same provider from the edit menu — keeps
    /// working. Only completion *requests* stop being made and the *strip* stops
    /// being shown, which is what makes the toggle instant and free in both
    /// directions.
    private var completionEnabled = true

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
    ///
    /// A **member position** — a caret after `receiver.`, per
    /// `IdentifierScanner.memberContext(in:at:)` — bypasses this, exactly as it
    /// does on macOS: the `.` is itself the request, and waiting for two more
    /// characters would defeat the point of member completion. The prefix a
    /// member request carries is therefore legitimately empty.
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
        // Read once: `UITextView.text` builds a fresh `String` out of the text
        // storage on every access, so re-reading it per consumer made a keystroke
        // cost several whole-buffer copies on the main thread.
        let contents = textView.text ?? ""
        text.wrappedValue = contents
        // Keep this file's symbols in step with what is being typed, behind the
        // controller's 400 ms debounce (a re-parse per keystroke would be felt).
        reindexSymbols(text: contents, language: language, immediate: false)
        // Offer completions for the word being typed, behind this coordinator's own
        // (shorter) debounce. Its gates — a bare caret, no marked text, and either
        // two typed characters or a member position — mean an ordinary keystroke
        // outside an identifier costs one prefix scan and no task.
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
            offset: match.range.location,
            // Carried on iOS too, where no language server runs, for the reason
            // stated on the field: the default exists so phase-1 call sites still
            // compile, which makes a *forgotten* one the hazard — an offset with no
            // buffer behind it is exactly the shape `LSPIntelligenceProvider`
            // refuses to send. The tree-sitter provider ignores it, so filling it in
            // changes nothing today and cannot be wrong later.
            text: textView.text ?? ""
        )
        // The folder the question is asked in, pinned synchronously before the hop
        // — the macOS coordinator's guard, for the reason written there: the index
        // refuses to answer for a folder the user has left, but the candidates
        // cross one more main-actor hop to reach the route, and a folder change
        // landing inside it would present a declaration from the previous project.
        let rootGeneration = symbolIndex?.currentRootGeneration
        Task { [weak self] in
            let candidates = await provider.definitions(for: request)
            guard let self, self.symbolIndex?.currentRootGeneration == rootGeneration else { return }
            guard let route = self.definitionRoute else { return }
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
    ///
    /// The request is also retired *at the route* once applied, not merely recorded
    /// here: `appliedRevealToken` dies with this coordinator, and on compact width
    /// the editor is a `navigationDestination` the user can pop and re-enter, which
    /// builds a fresh coordinator that would re-apply a still-standing request. The
    /// route is captured strongly for the hop so the clear happens even if this
    /// coordinator is torn down in the same turn — that is exactly the case the
    /// clear exists for.
    func applyReveal(_ request: DefinitionRoute_iOS.Reveal?, fileID: UUID) {
        guard let request,
              request.token != appliedRevealToken,
              request.fileID == fileID,
              textView != nil
        else { return }
        appliedRevealToken = request.token
        let route = definitionRoute
        DispatchQueue.main.async { [weak self] in
            // Clearing `reveal` republishes the route, so it is deliberately done
            // on this hop rather than inside `updateUIView`, where mutating
            // observed state is a SwiftUI violation.
            route?.consumeReveal(token: request.token)
            guard let textView = self?.textView else { return }
            let length = (textView.text as NSString).length
            guard request.range.location != NSNotFound,
                  request.range.location >= 0,
                  request.range.location <= length
            else { return }
            // Clamped by *truncating the length*, not by intersecting: a range
            // whose location is exactly the buffer end shares no unit with the
            // document, and `NSIntersectionRange` answers `{0, 0}` for that — which
            // would scroll to the top of the file instead of leaving the caret at
            // the end.
            let range = NSRange(
                location: request.range.location,
                length: min(request.range.length, length - request.range.location)
            )
            if let textRange = textView.uiTextRange(for: range) {
                textView.selectedTextRange = textRange
            }
            textView.scrollRangeToVisible(range)
        }
    }

    // MARK: - Completion

    /// Turn completion on or off, taking effect on the very next keystroke.
    ///
    /// An unchanged value is ignored, so the per-update forwarding from
    /// `updateUIView` costs nothing on the overwhelmingly common path.
    ///
    /// Turning it *off* is not merely a gate raised for future keystrokes:
    /// `clearCompletions()` cancels the pending debounce/provider task, bumps the
    /// generation so an answer already in flight cannot land, and removes the
    /// accessory strip — which, going through `showCompletions([])`, also drops
    /// `answeredMember`, so no receiver outlives the bar it belonged to. That is
    /// the iOS peer of the macOS `setEnabled(_:)`'s popup dismissal, and simpler
    /// for the same reason the strip is simpler: it is this coordinator's own view,
    /// not one UIKit puts up on its own behalf.
    func setCompletionEnabled(_ enabled: Bool) {
        guard enabled != completionEnabled else { return }
        completionEnabled = enabled
        guard !enabled else { return }
        clearCompletions()
    }

    /// Recompute the accessory strip's candidates for whatever is being typed.
    ///
    /// The request is built here, on the main actor, from the live buffer — the
    /// text goes *into* the request rather than being read after the hop, so the
    /// words the provider harvests are the ones on screen when the user paused.
    ///
    /// **Two triggers, not one**, the same pair the macOS `CompletionController`
    /// has: an ordinary partial word of at least `minimumCompletionPrefixLength`
    /// characters, or a member position, which opens the strip on the typed `.`
    /// with a prefix that may be empty. `language` feeds the keyword source and
    /// nothing else — `nil` (an unclassifiable buffer) means no keywords rather
    /// than some default language's.
    private func updateCompletions(in textView: UITextView) {
        // The gate sits at the very entry, before the prefix scan and before the
        // request is built, so a keystroke or a caret move costs nothing at all
        // while completion is off — no task, no provider call, not even a scan
        // whose answer is then discarded. Hiding the strip first is what makes the
        // path idempotent (there is nothing in flight to cancel: the setter
        // cancelled it, and nothing spawns one while off); it returns immediately
        // when no bar is installed, which is every call but the first.
        guard completionEnabled else {
            showCompletions([], in: textView)
            return
        }

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

        // One read for both the prefix scan and the request — see the note in
        // `textViewDidChange`; this runs on every keystroke and every caret move.
        let contents = textView.text ?? ""
        let nsText = contents as NSString
        let offset = textView.offset(from: textView.beginningOfDocument, to: caret.start)
        // Ask about the member position *before* the length gate: it is the one
        // state in which a zero- or one-character prefix is still worth a list,
        // and `memberContext`'s own `prefixRange` is exactly what
        // `completionPrefixRange` reports here, so the two agree by construction
        // rather than by a second scan.
        let member = IdentifierScanner.memberContext(in: nsText, at: offset)
        let prefixRange = member?.prefixRange
            ?? IdentifierScanner.completionPrefixRange(in: nsText, at: offset)
        if member == nil {
            guard prefixRange.length >= Self.minimumCompletionPrefixLength else {
                showCompletions([], in: textView)
                return
            }
        }

        let request = CompletionRequest(
            prefix: nsText.substring(with: prefixRange),
            fileURL: fileURL,
            text: contents,
            language: language,
            member: member,
            // Carried on iOS too, where no language server runs: the field costs
            // nothing to fill and a request that means the same thing on both
            // platforms is one fewer difference to remember.
            offset: offset
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
            guard liveText.substring(with: range) == request.prefix else {
                self.showCompletions([], in: textView)
                return
            }
            // Matching the partial word is not enough on its own, at **any**
            // prefix length: a member list and an ordinary list answer the same
            // typed characters with different candidate *sets* (a member list
            // carries no keywords and no non-member symbols), so the caret must
            // still be in the same member state these items were computed for —
            // receiver and all. The empty prefix makes that most obvious (it
            // compares equal everywhere there is no word at all: in open space,
            // after a `(`, at the start of a line, and after every other dot in
            // the buffer), but `worker.na`'s member-only list is just as wrong
            // over an unrelated `na` — which is why this is not nested in the
            // zero-length case, matching the macOS `CompletionController`.
            //
            // `map(\.receiver)` rather than `?.receiver`: the receiver is itself
            // optional (a bracketed one — `f().` — names no type), and optional
            // chaining would flatten "not a member position" into "a member
            // position with an unnamed receiver" and let the two serve each
            // other's lists.
            guard IdentifierScanner.memberContext(in: liveText, at: offset).map(\.receiver)
                    == member.map(\.receiver)
            else {
                self.showCompletions([], in: textView)
                return
            }
            // `displayText`, not `text`, because that is what the seam says a row
            // reads — and this strip both shows the string and inserts it over
            // the typed word, which is precisely the pair the display rule is
            // safe for. Identical here today: iOS installs no LSP provider, so
            // every item's `displayText` defaults to its `text`. Spelling it this
            // way puts the invariant where it is consumed rather than resting on
            // that.
            self.showCompletions(items.map(\.displayText), answering: member, in: textView)
        }
    }

    /// Install, update or remove the accessory strip.
    ///
    /// `reloadInputViews()` is called only when the strip's *presence* changes, not
    /// on every candidate list: it re-queries the responder's input views and
    /// visibly re-lays the keyboard, which per keystroke would read as a flicker.
    /// An empty list removes the bar rather than showing an empty one, so it never
    /// occupies space for nothing.
    ///
    /// `member` is the position these items answer, recorded alongside them so
    /// `insertCompletion(_:)` can make the same still-in-*this*-member-position
    /// test the post-await re-check above makes — see `answeredMember`. An empty
    /// list clears it, so a dismissed strip can never leave a receiver behind.
    private func showCompletions(
        _ items: [String],
        answering member: IdentifierScanner.MemberContext? = nil,
        in textView: UITextView
    ) {
        answeredMember = items.isEmpty ? nil : member
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
    ///
    /// The re-check asks the **same matcher the candidates were chosen by**,
    /// `FuzzyMatch`, rather than a prefix test of its own. That is not a
    /// refinement but a correctness rule: the provider offers case-insensitive
    /// prefix *and* subsequence matches (typing `arrBuf` offers `ArrayBuffer`),
    /// so any narrower guard here would let the user tap a perfectly valid
    /// candidate and have nothing happen at all — a dead row on the strip, with
    /// no feedback explaining it.
    ///
    /// That matcher test is the second guard, not the only one. The first is that
    /// the caret is still in the **same member state** these items answered —
    /// `answeredMember`'s *receiver*, not merely "some dot is here" — and it is
    /// demanded at every prefix length, exactly as macOS demands it: a member-only
    /// list and an ordinary list answer the same typed characters with different
    /// candidate sets, so `worker.na`'s members are as wrong over an unrelated
    /// `na` as they are after a caret moved to `other.`.
    ///
    /// A **zero-length** range is then accepted only in that member position: it is
    /// the bare typed `.`, where there is no typed text to match against and the
    /// empty range at the caret is already the correct insertion point. Everywhere
    /// else a zero-length range means the word this tap answered has moved, and the
    /// tap is dropped.
    private func insertCompletion(_ item: String) {
        guard let textView,
              textView.markedTextRange == nil,
              let caret = textView.selectedTextRange, caret.isEmpty
        else { return }
        let nsText = textView.text as NSString
        let offset = textView.offset(from: textView.beginningOfDocument, to: caret.start)
        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: offset)
        guard IdentifierScanner.memberContext(in: nsText, at: offset).map(\.receiver)
                == answeredMember.map(\.receiver)
        else { return }
        if range.length == 0 {
            // The bare typed `.`, whose member position the compare above has
            // already confirmed is still the one these items answered. Everywhere
            // else a zero-length range means the word this tap answered has moved,
            // and the tap is dropped.
            guard answeredMember != nil else { return }
        } else {
            guard FuzzyMatch.matches(item, query: nsText.substring(with: range)) else { return }
        }

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
        // This path does not go through `showCompletions`, so the receiver the
        // strip last answered has to be dropped here too; leaving it set would
        // outlive the bar it belongs to.
        answeredMember = nil
        if textView.inputAccessoryView === completionBar {
            textView.inputAccessoryView = nil
            // Paired with the detach exactly as in `showCompletions`: the accessory
            // view is cached by the *responder*, so clearing the property alone can
            // leave the strip on screen over the incoming file — the one outcome
            // this method exists to prevent.
            textView.reloadInputViews()
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

        // Tab → the configured spaces, when (and only when) the configuration asks
        // for them outright. `IndentUnitRule.tabInsertion` answers a literal tab in
        // every other case, and this lets that answer through untouched, so a
        // project with no `.editorconfig` keeps inserting exactly the tab it does
        // today.
        if replacementText == "\t" {
            return !insertConfiguredTab(in: textView, range: range)
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

    /// What `.editorconfig` says about the shown file, or nothing at all when no
    /// configuration applies (and when the app's model is gone, which is the same
    /// answer).
    private func editorConfigProperties() -> EditorConfigProperties {
        editorConfig?.properties(for: fileURL) ?? EditorConfigProperties()
    }

    /// One indentation level for the shown buffer: what `.editorconfig` says,
    /// falling back per half to what the content itself looks like.
    ///
    /// The single place Enter asks, so it and Tab can never disagree about the
    /// unit — they differ only in *whether* the unit is used, which is
    /// `IndentUnitRule`'s own distinction. The macOS coordinator holds the
    /// identical pair.
    private func indentUnit(text nsText: NSString) -> String {
        IndentUnitRule.unit(
            config: editorConfigProperties(),
            inferred: IndentEngine.inferIndentUnit(text: nsText)
        )
    }

    /// Insert the configured indentation for a Tab press. Returns `true` when it
    /// applied the edit, and `false` — letting `UITextView` insert its own literal
    /// tab — whenever the rule does not ask for spaces outright.
    ///
    /// The single range goes through `IndentUnitRule.tabInsertionPlan` even though
    /// `UITextView` has exactly one `selectedRange` and needs no fan-out: it is the
    /// same rule the macOS editor applies to its several insertion points, so the
    /// arithmetic that decides what replaces the selection and where the caret
    /// lands is asked once, in Core, rather than restated here.
    private func insertConfiguredTab(in textView: UITextView, range: NSRange) -> Bool {
        // The cheap question first, exactly as the macOS coordinator asks it: the
        // rule answers a literal tab unless `indent_style = space` is stated
        // outright, and only that case needs the inference — so a project without
        // an applicable configuration never pays for a whole-buffer copy plus a
        // full-file scan on a keystroke. `inferred:` is an autoclosure, so a
        // configuration stating both halves (`indent_style = space` +
        // `indent_size`) does not pay for them either — only spaces of an unstated
        // width read the buffer, to carry the file's own width over.
        let config = editorConfigProperties()
        guard config.indentStyle == .space else { return false }
        let insertion = IndentUnitRule.tabInsertion(
            config: config,
            inferred: IndentEngine.inferIndentUnit(text: textView.text as NSString)
        )
        guard insertion != "\t" else { return false }
        let plan = IndentUnitRule.tabInsertionPlan(ranges: [range], insertion: insertion)
        guard let replacement = plan.replacements.first, let caret = plan.carets.first else {
            return false
        }
        applyEdit(
            in: textView,
            range: replacement.range,
            replacement: replacement.replacement,
            selecting: caret
        )
        return true
    }

    /// Replace the selection (or caret) with a computed newline+indent via
    /// `IndentEngine`. Returns `true` when it applied the edit.
    private func insertIndentedNewline(in textView: UITextView, range: NSRange) -> Bool {
        let nsText = textView.text as NSString
        let unit = indentUnit(text: nsText)
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
