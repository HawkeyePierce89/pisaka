// swiftlint:disable file_length
#if os(macOS)
import AppKit
import PisakaCore

/// Feeds the custom `CompletionPanel` from the asynchronous code intelligence seam.
///
/// **The whole problem this class exists to solve** is bridging the gap between
/// fast typing and asynchronous language servers. `CodeIntelligenceProviding` is
/// *asynchronous* because a phase-2 LSP provider has to await a socket, while
/// keystrokes happen synchronously on the main thread. This controller computes
/// candidates ahead of time behind a debounce, stores them together with the
/// prefix they were computed for, and shows a custom `CompletionPanel` when ready.
///
/// Everything the popup shows is decided in `PisakaCore`:
/// `IdentifierScanner` says what is being typed and `SymbolIntelligenceProvider`
/// ranks and caps the answers. `CompletionPopup` manages selection state and rows.
/// This class only decides *when* to ask, *whether the answer is still current*,
/// and drives the panel UI.
///
/// **Debounce and generation token** follow the `BracketHighlightController`
/// idiom: a cancellable `Task.sleep` coalesces a burst of keystrokes into one
/// provider call, and a monotonic token discards an answer that a newer request
/// (a further keystroke, a caret move, a tab switch) superseded while it was in
/// flight. 150 ms, matching the minimap's tokenizer rather than the index's
/// 400 ms: this asks a question of a snapshot already in memory, so the cost is
/// a prefix scan and a sort, not a re-parse.
///
/// **Two commit modes.** A commit can either `.insert` (Enter) which replaces only
/// the typed prefix, or `.replace` (Tab) which consumes the trailing suffix of the
/// identifier as well. `IdentifierScanner` provides both ranges.
///
/// **Staleness guards and dismissal.** The controller maintains a strict dismissal
/// set to tear down the popup if the context changes: losing first responder,
/// clicking outside, scrolling, moving the caret out of the word, or typing a
/// space. Before applying any completion, it re-verifies that the text in the
/// buffer exactly matches the text that was on screen when the popup was shown.
///
/// **Display strings as keys.** The snapshot keeps whole `CompletionItem`s keyed
/// by `CompletionItem.displayText`. This string is the key in all three tables —
/// the snapshot, the prefetched `resolved` edits, and `resolveTasks`.
/// The display spelling differs from the insert text (e.g. `greet` vs `.greet` for members),
/// but the popup operates on the full `CompletionItem` chosen by the user and executes its
/// precise `CompletionEdit` payload rather than relying on string rewriting.
///
/// The rule Core enforces when it computes the display string ensures that
/// what the user reads on screen accurately represents the semantic entity being
/// completed, while the underlying edit ranges perform the exact AST manipulation
/// required by the language server.
///
/// **Two triggers, not one.** The ordinary trigger is a partial word of at least
/// `minimumPrefixLength` characters. The second is a *member position* — a caret
/// sitting after `receiver.`, per `IdentifierScanner.memberContext(in:at:)` —
/// which opens the list on the typed `.` itself, with a prefix that is legally
/// empty. A snapshot's `prefix` may therefore be `""`, and the checks that guard
/// a stale snapshot are written to survive that: matching the partial word is
/// never enough on its own, so both guards additionally require the caret to be
/// in the *same member state* the items were computed for — the same receiver, or
/// no member position on either side. Neither a caret moved to open space (where
/// the partial word is also empty) nor one moved to a different `other.` can
/// inherit a member list, and an ordinary list cannot be served after a dot.
@MainActor
// swiftlint:disable:next type_body_length
final class CompletionController {

    /// How many characters must be typed before the popup opens by itself.
    ///
    /// One character matches far too much to be a choice, and an unbidden popup
    /// after the first letter of every identifier is the single most-complained-of
    /// behavior of as-you-type completion. An *explicit* invocation (⌃Space, ⌥⎋)
    /// bypasses this — the user asked. So does a member position: the `.` is
    /// itself the request, and waiting for two more characters would defeat the
    /// point of member completion.
    private static let minimumPrefixLength = 2

    /// How many of a list's deferred items are resolved up front.
    ///
    /// D4 wants an item's edits in hand *before* it is picked, and the pick is
    /// hundreds of milliseconds away — but "everything the server deferred" is
    /// not a small set. `completionItem/resolve` is only offered where the
    /// server kept something back, and sourcekit-lsp signals that by attaching
    /// `data` to **every** item it sends, so prefetching the whole list is 30
    /// type-checking round trips per debounce, on every keystroke, each one
    /// cancelled by the next — sustained load on the very server the next
    /// completion is waiting on.
    ///
    /// The rows a user commits are the ones at the top of a list they can see
    /// (the popup's own selection starts on the first), so those are prefetched
    /// and the rest are resolved only if one is actually chosen — D4's stated
    /// race, which `scheduleFollowUp` already handles, rather than a lost import.
    private static let prefetchResolveLimit = 5

    /// The text view being completed in. Held weakly: the view hierarchy owns it,
    /// exactly as the `Coordinator` holds it.

    private let panel = CompletionPanel()
    private var codeFontSize: CGFloat = 13

    var isVisible: Bool { panel.isVisible }

    private weak var textView: NSTextView?

    /// Whether completion is offered at all — `SettingsStore.completionEnabled`,
    /// forwarded here by `CodeEditorView.updateNSView`.
    ///
    /// The switch is **binary and total**: off silences the as-you-type popup
    /// *and* every explicit invocation (⌃Space, Find > Complete, AppKit's stock
    /// ⌥⎋/F5), which all funnel through `update(…)` — the one door into this
    /// controller. The narrower JetBrains behaviour (auto-popup off, explicit
    /// invocation alive) was considered and deliberately rejected as a
    /// complication; it is a possible follow-up.
    ///
    /// **Nothing in the intelligence stack is torn down** by turning this off: no
    /// LSP server is stopped, no session shut down, the registry is untouched and
    /// the symbol index keeps walking and refreshing. Only completion *requests*
    /// stop being made and completion *UI* stops being shown, which is what makes
    /// the toggle instant and free in both directions — and why go-to-definition,
    /// which shares the same provider, is entirely unaffected.
    private var isEnabled = true

    /// Turn completion on or off, taking effect on the very next keystroke.
    ///
    /// An unchanged value is ignored, so the per-update forwarding from
    /// `updateNSView` costs nothing on the overwhelmingly common path.
    ///
    /// Turning it *off* is not merely a gate raised for future keystrokes: it
    /// `reset()`s — cancelling the pending debounce/provider task, bumping the
    /// generation, dropping the snapshot and every prefetched or in-flight
    /// resolve, and taking a visible panel down with everything else.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            reset()
        }
    }

    /// The candidates the panel is showing, and the prefix they answer.
    ///
    /// The prefix is stored *with* them because it is the only thing that makes an
    /// asynchronously-computed list safe to show: by the time the answer arrives,
    /// the user may have typed another character, and offering completions for
    /// the previous word is worse than offering none. Since phase 1.5 that prefix
    /// may be the empty string — the member list a bare `.` opens answers no typed
    /// characters at all. `prefixLocation` and `member` are the other two halves
    /// of the same staleness question: the caret must still sit where the list
    /// was computed, in the same member state.
    private struct Snapshot {
        let prefix: String
        let prefixLocation: Int
        let member: IdentifierScanner.MemberContext?
        let rows: [CompletionRow]
        var selection: CompletionPopupSelection?
    }

    private var snapshot: Snapshot?

    /// Edits that arrived from a background `completionItem/resolve`, keyed by
    /// the row's displayed string — the D4 prefetch's landing place. Cleared with
    /// the list they belong to.
    private var resolved: [String: [CompletionEdit]] = [:]

    /// The in-flight resolve per displayed string, so the item's edits can be
    /// awaited if the user commits before one lands, and so all of them can be
    /// cancelled when the list they belong to is superseded.
    private var resolveTasks: [String: Task<[CompletionEdit], Never>] = [:]

    /// The provider the current list came from, so an item past
    /// `prefetchResolveLimit` can still be resolved when it is the one being
    /// inserted.
    ///
    /// Deliberately *not* cleared with the list: `update` forgets the list before
    /// the new answer arrives, and the old snapshot keeps serving the popup in
    /// between — an item committed in that window must still be able to ask. The
    /// provider is a long-lived app object that holds no reference back here, so
    /// there is no cycle to weaken against.
    private var resolveSource: CodeIntelligenceProviding?

    /// The late auto-import D4 allows: applied when its resolve arrives after
    /// the insertion has already happened.
    private var followUpTask: Task<Void, Never>?

    /// Raises and lowers the coordinator's programmatic-edit flag around an
    /// insertion this controller performs *outside* AppKit's own
    /// `insertCompletion` bracket — i.e. the late auto-import only. Set by
    /// `Coordinator.attachCompletion(textView:)`.
    var noteProgrammaticEdit: (Bool) -> Void = { _ in }

    /// The in-flight debounce/provider task; cancelled when a newer request lands.
    private var pendingTask: Task<Void, Never>?

    /// Monotonic token guarding an answer against a newer request that landed
    /// while the provider was being awaited.
    private var generation = 0
    private var bufferVersion = 0

    /// Debounce before a (non-explicit) provider call, coalescing rapid
    /// keystrokes.
    private let debounceInterval: Duration = .milliseconds(150)

    /// Bind the controller to the editor's text view.
    func attach(textView: NSTextView) {
        self.textView = textView
    }

    // MARK: - Asking the provider

    /// Recompute the candidate list for whatever is being typed, and open the
    /// popup when there is something to show.
    ///
    /// `explicit` is the ⌃Space / menu path: it skips both the debounce and the
    /// two-character minimum, because the user asked for the list rather than
    /// having it offered. Everything else (a keystroke) is debounced and gated.
    ///
    /// A **member position** skips the minimum too, explicit or not: the caret is
    /// after `receiver.`, which is a request in itself, and the prefix it carries
    /// is whatever has been typed since the dot — legitimately nothing. Explicit
    /// invocation still works there; it only removes the debounce.
    ///
    /// The request is built here, on the main actor, from the live buffer — the
    /// text goes *into* the request rather than being read later, so the words the
    /// provider harvests are the ones on screen when the user paused, not the ones
    /// present when the task happened to resume.
    func update(
        provider: CodeIntelligenceProviding?,
        fileURL: URL?,
        language: SyntaxLanguage?,
        explicit: Bool
    ) {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        let token = generation
        // A keystroke ends the previous completion session: its previews are
        // history, its prefetched imports answer a word that is no longer being
        // typed, and a late auto-import must not land on a buffer the user has
        // since changed (D4's stated condition).
        forgetList()

        // The on/off gate at the *entry* of the per-keystroke path, so while
        // completion is off a keystroke costs nothing at all: no debounce task,
        // no provider call, no resolve prefetch — not merely a result that is
        // computed and then discarded. Nothing stale is left standing either,
        // which is what makes turning the switch back on start from a clean
        // list rather than a stale one.
        guard isEnabled else { return refuse() }
        guard let textView, let provider else { return refuse() }
        // No popup mid-composition. Marked text is uncommitted input the input
        // method still owns; completing over it would insert into a range the
        // composition is about to replace — the same reasoning as the ⌘D guard.
        guard !textView.hasMarkedText() else { return refuse() }
        let caret = textView.selectedRange()
        // A non-empty selection is not a partial word: the user is about to
        // replace it, not extend it.
        guard caret.length == 0 else { return refuse() }

        // Read the buffer once and reuse it for both the prefix scan and the
        // request: each `textView.string` access copies the entire text storage,
        // and this runs on every keystroke that passes the gates above.
        let contents = textView.string
        let nsText = contents as NSString
        // Ask about the member position *before* the length gate: it is the one
        // state in which a zero- or one-character prefix is still worth a list,
        // and `memberContext`'s own `prefixRange` is exactly what
        // `completionPrefixRange` reports here, so the two agree by construction
        // rather than by a second scan.
        let member = IdentifierScanner.memberContext(in: nsText, at: caret.location)
        let prefixRange = member?.prefixRange
            ?? IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        if member == nil,
           prefixRange.length < (explicit ? 0 : Self.minimumPrefixLength) {
            return refuse()
        }

        // The caret must sit where the shown list was computed; anywhere else —
        // open space, another dot, a different word entirely — invalidates it.
        if let snap = snapshot, prefixRange.location != snap.prefixLocation {
            return refuse()
        }

        let request = CompletionRequest(
            prefix: nsText.substring(with: prefixRange),
            fileURL: fileURL,
            text: contents,
            language: language,
            member: member,
            // Where the question is being asked, which an LSP provider cannot
            // answer without — see `CompletionRequest.offset`. The caret is the
            // end of `prefixRange` by construction, so the two agree.
            offset: caret.location
        )
        dispatch(request, provider: provider, explicit: explicit, token: token)
    }

    /// An early return for "this context cannot offer completions": drop any
    /// snapshot still standing and take a visible panel down with it. Every
    /// `update(…)` early return funnels through here so the dismissal set in
    /// `CodeEditorView` holds no matter which gate refused the keystroke.
    private func refuse() {
        snapshot = nil
        dismiss()
    }

    /// Debounce (unless `explicit`) and await the provider, then hand the answer
    /// to `apply(…)` behind the generation-token check. Split from `update(…)`,
    /// which owns the synchronous validation, so each stays readable.
    private func dispatch(
        _ request: CompletionRequest,
        provider: CodeIntelligenceProviding,
        explicit: Bool,
        token: Int
    ) {
        let interval = debounceInterval
        pendingTask = Task { [weak self] in
            if !explicit {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            let items = await provider.completions(for: request)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.pendingTask = nil
            self.apply(request, items: items, provider: provider, token: token)
        }
    }

    /// Store the answer and, if it is still the answer to what is being typed,
    /// show the panel over it.
    ///
    /// The caret is re-read here rather than trusted from before the await: the
    /// request was built a debounce ago, and a click, an arrow key or an undo in
    /// the meantime moves the popup's anchor to a word these items do not answer.
    /// An empty result clears the snapshot and opens nothing — an empty popup is
    /// strictly worse than no popup.
    ///
    /// The member state is the second half of the re-check, and it is demanded at
    /// every prefix length rather than only at zero. The ordinary re-check is "the
    /// partial word under the caret is still the one these items answer", and it
    /// is not sufficient on its own: a member list and an ordinary list answer the
    /// same characters with different candidate *sets*, so the caret must also
    /// still be in the same member state — **receiver and all** — the items were
    /// computed for. An *empty* prefix makes that most obvious (it satisfies the
    /// word test everywhere there is no partial word at all: in open space, after
    /// a `(`, at the start of a line, and after every other dot in the buffer),
    /// but `worker.na`'s member-only list is just as wrong over an unrelated `na`.
    private func apply(
        _ request: CompletionRequest,
        items: [CompletionItem],
        provider: CodeIntelligenceProviding,
        token: Int
    ) {
        let rows = CompletionRow.rows(for: items, language: request.language)
        guard !rows.isEmpty else {
            snapshot = nil
            panel.dismiss()
            return
        }

        // The re-reads below are staleness guards: when one fails, this answer is
        // history and must not even prefetch against it — the resolves would be
        // cancelled by the next keystroke without ever serving a visible row.
        guard let textView,
              !textView.hasMarkedText(),
              textView.window?.firstResponder === textView
        else { return }

        let nsText = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return }

        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        guard nsText.substring(with: range) == request.prefix else { return }

        guard IdentifierScanner.memberContext(in: nsText, at: caret.location).map(\.receiver)
                == request.member.map(\.receiver)
        else { return }

        prefetchResolves(for: rows.map { $0.item }, provider: provider, token: token)

        let selection = CompletionPopupSelection(count: rows.count)
        snapshot = Snapshot(
            prefix: request.prefix,
            prefixLocation: range.location,
            member: request.member,
            rows: rows,
            selection: selection
        )
        present(rows: rows, selection: selection)
    }

    /// Put `rows` on the panel, anchored to the live caret's word.
    ///
    /// The anchor is recomputed from the text view on every call, which makes
    /// this shared by `apply(…)` (first show) and `moveSelection(_:)` (every
    /// arrow key): both present the current snapshot at wherever the caret now
    /// is. The commit callback routes a click through Enter's insertion mode,
    /// updating the stored selection first so `commit(_:)` picks the clicked row.
    private func present(rows: [CompletionRow], selection: CompletionPopupSelection?) {
        guard let textView else { return }
        let nsText = textView.string as NSString
        let caret = textView.selectedRange()
        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        let anchor = textView.firstRect(forCharacterRange: range, actualRange: nil)

        panel.onCommit = { [weak self] index in
            guard let self else { return }
            self.snapshot?.selection?.select(index)
            self.commit(.insert)
        }

        panel.show(
            rows: rows,
            selection: selection,
            anchoredTo: anchor,
            in: textView.window,
            codeFontSize: codeFontSize
        )
    }

    // MARK: - Resolving deferred items

    /// Ask the provider for the edits of the deferred items most likely to be
    /// picked — `prefetchResolveLimit` of them, in the provider's own order.
    ///
    /// One task per item rather than one for the batch, so a single slow resolve
    /// does not hold back the others and so each can be awaited on its own by
    /// the follow-up path. Every task is cancelled when the list is superseded.
    private func prefetchResolves(
        for items: [CompletionItem],
        provider: CodeIntelligenceProviding,
        token: Int
    ) {
        resolveSource = provider
        var remaining = Self.prefetchResolveLimit
        for item in items where item.resolveHandle != nil {
            guard remaining > 0 else { break }
            remaining -= 1
            startResolve(for: item, provider: provider, token: token)
        }
    }

    /// One background resolve, filed under the string its row shows — the same
    /// key the snapshot and the panel's commit callback use.
    @discardableResult
    private func startResolve(
        for item: CompletionItem,
        provider: CodeIntelligenceProviding,
        token: Int
    ) -> Task<[CompletionEdit], Never> {
        let text = item.displayText
        let task = Task { [weak self] in
            let edits = await provider.resolveEdits(for: item)
            guard let self, !Task.isCancelled, token == self.generation else { return edits }
            self.resolved[text] = edits
            return edits
        }
        resolveTasks[text] = task
        return task
    }

    // MARK: - Panel Drive

    func syncAppearance(codeFontSize: CGFloat) {
        self.codeFontSize = codeFontSize
    }

    /// Move the popup's selection one row up or down (clamped by the Core state
    /// machine) and re-present the same rows at the same anchor.
    func moveSelection(_ direction: MoveDirection) {
        guard let snapshot, isVisible else { return }
        var updated = snapshot
        switch direction {
        case .moveUp:
            updated.selection?.moveUp()
        case .moveDown:
            updated.selection?.moveDown()
        }
        self.snapshot = updated
        present(rows: updated.rows, selection: updated.selection)
    }

    enum MoveDirection {
        case moveUp
        case moveDown
    }

    enum CommitMode {
        case insert
        case replace
    }

    func dismiss() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        snapshot = nil
        panel.dismiss()
        forgetList()
    }

    // MARK: - Inserting a chosen item

    /// Commit the selected row, in Enter's (`.insert`) or Tab's (`.replace`)
    /// mode, answering whether the key that triggered it was consumed.
    ///
    /// `false` — no usable snapshot, an unusable buffer, a non-empty selection
    /// or a word that has moved — dismisses and hands the keystroke back to the
    /// editor, which then does what it always does (a newline for Return, an
    /// indent for Tab). `true` means the row is in the buffer.
    ///
    /// The live buffer and caret are re-read rather than trusted from the
    /// snapshot, and the commit range is derived per mode from `IdentifierScanner`
    /// — `completionPrefixRange` for Enter, `completionReplaceRange` for Tab.
    ///
    /// **The staleness rule is the same word *start*, not the same word *text*.**
    /// `update` keeps the previous list serving the panel while a fresh answer
    /// debounces, so a keystroke that extends or shrinks the word under an open
    /// popup is ordinary — refusing to commit during that window would hand a
    /// Return pressed mid-word straight through as a newline. What genuinely
    /// invalidates the list is a caret that moved away, and every such move
    /// fails `update`'s own location gate and takes the popup down before any
    /// key can be claimed; matching that gate here makes "still visible" ≡
    /// "committable". Every range is derived from the live buffer, so the row
    /// lands over whatever is actually typed now, and an LSP item whose edits
    /// were computed for a different spelling of the word is re-expressed or
    /// refused by `CompletionEditPlan` exactly as decision 8 states.
    ///
    /// For an item with edits (an LSP auto-import) the existing
    /// `plan(for:over:replacing:in:) + apply(_:in:)` path runs unchanged over the
    /// typed word; for everything else one `insertText(_:replacementRange:)`
    /// replaces the commit range with the row's own display string. Both land in
    /// one undo group behind the coordinator's programmatic-edit flag, and Tab's
    /// suffix deletion happens inside the same group *after* the plan,
    /// re-verifying the suffix text still stands at the caret — if it does not,
    /// Tab degrades to Enter rather than deleting something else.
    @discardableResult
    func commit(_ mode: CommitMode) -> Bool {
        guard let snapshot,
              let selection = snapshot.selection,
              selection.selectedIndex < snapshot.rows.count,
              let textView,
              let undoManager = textView.undoManager
        else {
            dismiss()
            return false
        }

        let row = snapshot.rows[selection.selectedIndex]
        let word = row.displayText

        let nsText = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0 else { dismiss(); return false }
        let prefixRange = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        // Same word *start*, not same word text — see the staleness paragraph
        // above: `update`'s keep-open gate is the rule commit answers to, so the
        // word may have grown or shrunk under the popup since the list was
        // computed and the commit still lands over its live extent.
        guard prefixRange.location == snapshot.prefixLocation else { dismiss(); return false }
        let livePrefix = nsText.substring(with: prefixRange)

        // The chosen row's resolve task is removed before dismissal so it alone
        // survives `forgetList()` — D4's late auto-import must stay in flight.
        let isResolved = resolved[word] != nil
        let edits = resolved[word].flatMap { $0.isEmpty ? nil : $0 } ?? row.item.edits
        let inFlightResolve = resolveTasks.removeValue(forKey: word)
        let provider = resolveSource

        let target = commitTarget(
            for: mode,
            nsText: nsText,
            caretLocation: caret.location,
            prefixRange: prefixRange,
            typedPrefixLength: (livePrefix as NSString).length
        )

        // Hide the panel first so the insertion's own textDidChange cannot
        // re-open anything over the committed word.
        dismiss()

        if let plan = plan(for: edits, over: livePrefix, replacing: target.typedWord, in: nsText) {
            noteProgrammaticEdit(true)
            undoManager.beginUndoGrouping()
            apply(plan, in: textView)
            deleteExpectedSuffix(target.expectedSuffix, afterCaretAt: plan.caretOffset, in: textView)
            undoManager.endUndoGrouping()
            noteProgrammaticEdit(false)
            return true
        }

        insertInUndoGroup(word, over: target.range, textView: textView)

        if row.item.resolveHandle != nil, !isResolved {
            scheduleFollowUp(
                for: row.item,
                replacing: target.range,
                in: textView,
                inFlight: inFlightResolve,
                provider: provider
            )
        }
        return true
    }

    /// The commit range and its company, per mode: Enter replaces only the typed
    /// prefix; Tab's range is Enter's plus whatever identifier suffix follows the
    /// caret, whose verbatim text is captured here so the deletion can verify it
    /// still stands there after the insertion.
    private struct CommitTarget {
        let range: NSRange
        let typedWord: NSRange
        var expectedSuffix: String?
    }

    private func commitTarget(
        for mode: CommitMode,
        nsText: NSString,
        caretLocation: Int,
        prefixRange: NSRange,
        typedPrefixLength: Int
    ) -> CommitTarget {
        let targetRange: NSRange
        var expectedSuffix: String?
        switch mode {
        case .insert:
            targetRange = prefixRange
        case .replace:
            targetRange = IdentifierScanner.completionReplaceRange(in: nsText, at: caretLocation)
            if targetRange.length > prefixRange.length {
                expectedSuffix = nsText.substring(
                    with: NSRange(location: NSMaxRange(prefixRange), length: targetRange.length - prefixRange.length)
                )
            }
        }
        let typedWord = NSRange(location: targetRange.location, length: typedPrefixLength)
        return CommitTarget(range: targetRange, typedWord: typedWord, expectedSuffix: expectedSuffix)
    }

    /// One `insertText(_:replacementRange:)` inside the coordinator's
    /// programmatic-edit bracket and one undo group — the simple commit path.
    private func insertInUndoGroup(_ text: String, over range: NSRange, textView: NSTextView) {
        noteProgrammaticEdit(true)
        textView.undoManager?.beginUndoGrouping()
        textView.insertText(text, replacementRange: range)
        textView.undoManager?.endUndoGrouping()
        noteProgrammaticEdit(false)
    }

    /// Tab's second half: delete the identifier suffix that stood to the right of
    /// the caret, but only if it is still exactly there once the plan has landed —
    /// a server-chosen primary range can move or rewrite the text around the
    /// caret, in which case deleting would corrupt the line, so nothing is done.
    private func deleteExpectedSuffix(
        _ expectedSuffix: String?,
        afterCaretAt caretOffset: Int,
        in textView: NSTextView
    ) {
        guard let expectedSuffix else { return }
        let nsText = textView.string as NSString
        let suffixStart = caretOffset
        guard suffixStart + expectedSuffix.utf16.count <= nsText.length else { return }
        let suffixRange = NSRange(location: suffixStart, length: expectedSuffix.utf16.count)
        guard nsText.substring(with: suffixRange) == expectedSuffix else { return }
        textView.insertText("", replacementRange: suffixRange)
    }

    /// The plan for `edits`, re-expressed over whatever now stands in the typed
    /// word's place, or `nil` if there is nothing to apply or the buffer has
    /// moved on.
    private func plan(
        for edits: [CompletionEdit],
        over current: String,
        replacing typedWord: NSRange,
        in text: NSString
    ) -> CompletionEditPlan? {
        guard !edits.isEmpty else { return nil }
        let length = (current as NSString).length
        let shifted = edits.map {
            $0.shifted(afterReplacingTypedWord: typedWord, withLength: length)
        }
        let result = CompletionEditPlan.make(
            edits: shifted,
            in: text,
            replacing: NSRange(location: typedWord.location, length: length),
            typed: current
        )
        return try? result.get()
    }

    /// Apply a plan: one undo group, the edits in the order the plan put them
    /// (last-to-first, so no pending offset is invalidated), caret last.
    ///
    /// `insertText(_:replacementRange:)` per edit rather than one rewritten span
    /// — the plan's ordering is what makes that safe, and an auto-import spans
    /// the file, so rewriting everything between the `import` line and the caret
    /// would re-parse and re-highlight the whole buffer to insert two words. The
    /// explicit undo group is what makes ⌘Z undo the symbol *and* its import in
    /// one step, and keeps the pair from coalescing into the user's preceding
    /// typing.
    private func apply(_ plan: CompletionEditPlan, in textView: NSTextView) {
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        for edit in plan.edits {
            textView.insertText(edit.newText, replacementRange: edit.range)
        }
        undoManager?.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: plan.caretOffset, length: 0))
    }

    /// D4's race: the item was committed before its resolve landed, so the plain
    /// text is already in the buffer and the import — if there turns out to be
    /// one — arrives as a second undo step.
    ///
    /// The whole edit set is applied, not just the additional edits: re-expressed
    /// over the insertion that already happened, the primary edit replaces the
    /// inserted text with itself (or widens to the range the server actually
    /// meant), which is both correct and the only way the caret ends up in the
    /// right place after a line is inserted above it.
    ///
    /// The buffer must be untouched since the insertion — the condition D4
    /// states. It is read at the top of the task rather than passed in: this
    /// runs a main-actor turn *after* `commit(_:)` returned, so by then the
    /// committed word is in the buffer and there is a real "before" to compare
    /// against.
    ///
    /// An item past `prefetchResolveLimit` has no resolve in flight, so this is
    /// also where one is started: it is worth a round trip now that it is the row
    /// the user chose, and the answer takes exactly the path a prefetched one
    /// that lost the race takes.
    private func scheduleFollowUp(
        for item: CompletionItem,
        replacing typedWord: NSRange,
        in textView: NSTextView,
        inFlight: Task<[CompletionEdit], Never>?,
        provider: CodeIntelligenceProviding?
    ) {
        // The display spelling, which here is doing two jobs at once: it is the
        // resolve key, and it is *what now stands in the buffer* — the plan was
        // rejected, so `commit(_:)` inserted the row's own string over the typed
        // word, and that is exactly the "typed" text
        // `plan(for:over:replacing:in:)` has to re-express the edits against.
        let word = item.displayText
        let token = generation
        let task: Task<[CompletionEdit], Never>
        if let inFlight {
            task = inFlight
        } else if let provider {
            task = startResolve(for: item, provider: provider, token: token)
        } else {
            return
        }
        let version = bufferVersion
        followUpTask = Task { [weak self, weak textView] in
            let edits = await task.value
            guard !Task.isCancelled,
                  let self,
                  let textView,
                  token == self.generation,
                  version == self.bufferVersion,
                  let plan = self.plan(
                      for: edits,
                      over: word,
                      replacing: typedWord,
                      in: textView.string as NSString
                  )
            else { return }
            // Outside `commit(_:)`'s programmatic-edit bracket, so this one
            // raises the flag itself — the inserted line is not typed text and
            // must not be read by the auto-pair or dedent interceptors.
            self.noteProgrammaticEdit(true)
            self.apply(plan, in: textView)
            self.noteProgrammaticEdit(false)
        }
    }

    // MARK: - Teardown

    /// The buffer changed — typing or any programmatic edit. Bumps the version
    /// the D4 follow-up compares against, so a late auto-import never lands on a
    /// buffer the user has touched since the commit.
    func noteEdit() {
        bufferVersion += 1
    }

    /// Drop everything (snapshot, pending request, panel) — tab teardown and the
    /// completion-off switch.
    func reset() {
        dismiss()
    }

    /// Forget everything that belongs to the currently-offered list: its
    /// prefetched resolves and any late auto-import still waiting on one. The
    /// snapshot itself is deliberately *not* dropped here — `update` keeps the
    /// old list serving the panel until the new answer arrives.
    ///
    /// The callers are exactly the ones that supersede a list: a keystroke
    /// (`update`), a dismissal (`dismiss`) and a tab teardown (`reset`). A caret
    /// move is deliberately not one of them, because it does not supersede the
    /// snapshot either — both are re-validated where they are used instead, the
    /// list against the word under the caret and the edits against the text they
    /// were computed over.
    private func forgetList() {
        for task in resolveTasks.values { task.cancel() }
        resolveTasks.removeAll()
        resolved.removeAll()
        followUpTask?.cancel()
        followUpTask = nil
    }
}

#endif
