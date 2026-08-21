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
/// the snapshot, the prefetched `resolved` edits, and `resolveTasks`. The display
/// spelling differs from the insert text (e.g. `greet` vs `.greet` for members).
/// hands a committed row back *by string* and there has to be one key that all
/// of them answer to. The two spellings differ only for a member item whose
/// server rewrote the typed dot: tsserver answers `greeter.` with a `textEdit`
/// covering the `.`, so the row inserts `.greet` and reads `greet`.
///
/// Showing something other than what is inserted is safe here only because of
/// the rule Core enforces when it computes the display string
/// (`CompletionEdit.displayText(forTypedWordStartingAt:in:)`): it may drop
/// **only** a head that re-writes, verbatim, characters already standing in the
/// buffer. This class writes that string into the buffer twice — as AppKit's
/// arrow-key preview, and through `super` whenever `CompletionEditPlan.make`
/// rejects the plan as stale. The rule's guarantee is **one-directional**, and
/// that is what it is for: whenever a head *is* dropped, those two writes
/// compose exactly the buffer the plan would have (`greeter.` + `greet`), for
/// edits that end where the typed word ends — which is every shape this exists
/// for. Under a looser rule they would corrupt it, so the rule is not a
/// formatting nicety to be simplified away: an optional receiver's `?.greet`
/// covers the same range but rewrites a `?` that is *not* there, and displaying
/// the LSP `label` instead — `greet(name: String)` — would have the fallback
/// path insert that.
///
/// What it does **not** promise is that a *kept* string composes the plan's
/// buffer. `?.greet` inserted over the typed word writes `greeter.?.greet`, and
/// a server range reaching past the caret leaves the characters beyond it
/// standing. Both are the fallback path's pre-existing limit rather than
/// anything the display string introduced — that path can only ever replace the
/// typed word, so no display string fixes it — and both are why the rule refuses
/// to shorten in those cases instead of guessing.
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
    /// ⌥⎋/F5), which is why it is enforced in two places rather than one — at the
    /// entry of `update(…)`, the per-keystroke path, and again in
    /// `completions(forPartialWordRange:in:)`, the delegate answer the stock
    /// commands reach without passing through `update`. The narrower JetBrains
    /// behaviour (auto-popup off, explicit invocation alive) was considered and
    /// deliberately rejected as a complication; it is a possible follow-up.
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
    /// resolve — and then, only if a popup is up, asks the text view to
    /// re-query. `complete(nil)` reaches the delegate, which now answers `[]`,
    /// and an empty answer is what closes a popup that is already on screen.
    ///
    /// "Is up" is `isServingPopup` — **what the delegate last actually served**,
    /// in the editor the user is actually typing in. The snapshot is emphatically
    /// *not* that question: it is stored by `apply(…)` before its own focus/caret
    /// guards and is not dropped when a popup closes (Esc and an accepted row both
    /// leave it standing until the next keystroke), so it routinely outlives — or
    /// never had — a visible list. Asking it instead would fire `complete(nil)`
    /// with nothing on screen, and an invocation of AppKit's completion machinery
    /// that finds no completions *beeps*: every "type a word, dismiss the list,
    /// switch completion off" would sound an unexplained alert. The focus half is
    /// not decoration either — calling `complete(nil)` on an unfocused editor
    /// would break the very rule `apply` states: only the focused editor may reach
    /// AppKit's completion machinery, or a list floats over whatever the user
    /// *is* typing in.
    ///
    /// **Focus is two questions, not one.** `NSWindow.firstResponder` is *not*
    /// cleared when its window stops being key, so an editor in a background
    /// window — which is every open editor when the toggle is flipped from the
    /// Preferences window — still answers `firstResponder === textView`. The
    /// responder test alone would therefore pass for precisely the editors it is
    /// meant to exclude, which is why `isKeyWindow` is asked as well. Nothing
    /// dismissable is lost to the narrower test: a completion popup can only be on
    /// screen in the key window.
    ///
    /// **The re-query is deferred by one run-loop turn**, because this runs inside
    /// `updateNSView`. Dismissing a live popup makes AppKit restore the typed word
    /// through `insertCompletion(…isFinal:)` — a real buffer edit, which fires
    /// `textDidChange`, which writes the SwiftUI text binding: mutating observed
    /// state from within a view update. Hopping out of that pass is the same move
    /// `EditorSearchController.setNeedsRefresh` makes and costs nothing the user
    /// can perceive. Every condition is re-asked on the hop, since the toggle may
    /// have been flipped back and the editor may have lost focus, gained marked
    /// text or been torn down in between.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            reset()
        }
    }

    /// The candidates the delegate serves, and the prefix they answer.
    ///
    /// The prefix is stored *with* them because it is the only thing that makes an
    /// asynchronously-computed list safe to hand to a synchronous delegate: by the
    /// time AppKit asks, the user may have typed another character, and offering
    /// completions for the previous word is worse than offering none. Since
    /// phase 1.5 that prefix may be the empty string — the member list a bare `.`
    /// opens answers no typed characters at all.
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
    /// `language` feeds the keyword source and nothing else; `nil` (an
    /// unclassifiable buffer) means no keywords rather than some default
    /// language's — see `CompletionRequest.language`.
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
        // computed and then discarded. Nothing is left standing for the delegate
        // to serve either, which is what makes turning the switch back on start
        // from a clean list rather than a stale one.
        guard isEnabled else {
            snapshot = nil
            dismiss()
            return
        }

        guard let textView, let provider else {
            snapshot = nil
            dismiss()
            return
        }
        // No popup mid-composition. Marked text is uncommitted input the input
        // method still owns; completing over it would insert into a range the
        // composition is about to replace — the same reasoning as the ⌘D guard.
        guard !textView.hasMarkedText() else {
            snapshot = nil
            dismiss()
            return
        }
        let caret = textView.selectedRange()
        // A non-empty selection is not a partial word: the user is about to
        // replace it, not extend it.
        guard caret.length == 0 else {
            snapshot = nil
            dismiss()
            return
        }

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
        if member == nil {
            guard prefixRange.length >= (explicit ? 0 : Self.minimumPrefixLength) else {
                snapshot = nil
                dismiss()
                return
            }
        }

        if let snap = snapshot, prefixRange.location != snap.prefixLocation {
            snapshot = nil
            dismiss()
            return
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
        let interval = debounceInterval
        pendingTask = Task { [weak self] in
            if !explicit {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            let items = await provider.completions(for: request)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.pendingTask = nil
            self.apply(
                prefix: request.prefix,
                member: member,
                items: items,
                provider: provider,
                token: token,
                language: language
            )
        }
    }

    /// Store the answer and, if it is still the answer to what is being typed,
    /// let AppKit open the popup over it.
    ///
    /// The caret is re-read here rather than trusted from before the await: the
    /// request was built a debounce ago, and a click, an arrow key or an undo in
    /// the meantime moves the popup's anchor to a word these items do not answer.
    /// An empty result clears the snapshot and opens nothing — an empty popup is
    /// strictly worse than no popup.
    ///
    /// `member` is the second half of the re-check, and it is demanded at every
    /// prefix length rather than only at zero. The ordinary re-check is "the
    /// partial word under the caret is still the one these items answer", and it
    /// is not sufficient on its own: a member list and an ordinary list answer the
    /// same characters with different candidate *sets*, so the caret must also
    /// still be in the same member state — **receiver and all** — the items were
    /// computed for. An *empty* prefix makes that most obvious (it satisfies the
    /// word test everywhere there is no partial word at all: in open space, after
    /// a `(`, at the start of a line, and after every other dot in the buffer),
    /// but `worker.na`'s member-only list is just as wrong over an unrelated `na`.
    private func apply(
        prefix: String,
        member: IdentifierScanner.MemberContext?,
        items: [CompletionItem],
        provider: CodeIntelligenceProviding,
        token: Int,
        language: SyntaxLanguage?
    ) {
        let rows = CompletionRow.rows(for: items, language: language)
        guard !rows.isEmpty else {
            snapshot = nil
            panel.dismiss()
            return
        }

        let texts = rows.map { $0.displayText }
        prefetchResolves(for: rows.map { $0.item }, provider: provider, token: token)

        guard let textView,
              !textView.hasMarkedText(),
              textView.window?.firstResponder === textView
        else { return }

        let nsText = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return }

        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        guard nsText.substring(with: range) == prefix else { return }

        guard IdentifierScanner.memberContext(in: nsText, at: caret.location).map(\.receiver)
                == member.map(\.receiver)
        else { return }

        let selection = CompletionPopupSelection(count: rows.count)
        snapshot = Snapshot(
            prefix: prefix,
            prefixLocation: range.location,
            member: member,
            rows: rows,
            selection: selection
        )

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
    /// key the snapshot uses, since that is the only one AppKit ever hands back.
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

        guard let textView else { return }
        let nsText = textView.string as NSString
        let caret = textView.selectedRange()
        let range = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        let anchor = textView.firstRect(forCharacterRange: range, actualRange: nil)

        panel.show(
            rows: updated.rows,
            selection: updated.selection,
            anchoredTo: anchor,
            in: textView.window,
            codeFontSize: codeFontSize
        )
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
        panel.dismiss()
        forgetList()
    }

    // MARK: - Inserting a chosen item

    /// Apply the chosen item's own edits, answering whether the insertion was
    /// handled here — `EditorTextView.insertCompletion`'s whole decision.
    ///
    /// `false` means "do what you have always done": `super` replaces
    /// `charRange` with `word`, which is exactly right for a tree-sitter item
    /// (it carries no edits) and for an LSP item whose only effect is to replace
    /// the typed word with its own text. `true` is the D4 case — an `import`
    /// travelling with the symbol, or a server-chosen range other than the one
    /// the client typed — where the edits must be applied *as written*, in one
    /// undo group, with the caret after the symbol rather than at the import.
    ///
    /// A **non-final** call is always `false`: it is AppKit previewing the
    /// highlighted row, not a commitment, and rewriting the file's imports once
    /// per arrow key would be indefensible. The preview is remembered instead,
    /// because it is what the final call's edits have to be re-expressed over.
    ///
    /// Rejection is silent and safe everywhere: an unknown word, a stale buffer
    /// or an unusable edit set all fall through to `super`, which inserts the
    /// plain text and loses only the auto-import.
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
        let item = row.item

        let nsText = textView.string as NSString
        let caret = textView.selectedRange()

        guard caret.length == 0 else {
            dismiss()
            return false
        }

        let prefixRange = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        guard nsText.substring(with: prefixRange) == snapshot.prefix else {
            dismiss()
            return false
        }

        let targetRange: NSRange
        switch mode {
        case .insert:
            targetRange = prefixRange
        case .replace:
            targetRange = IdentifierScanner.completionReplaceRange(in: nsText, at: caret.location)
        }

        let typedWord = NSRange(location: targetRange.location, length: (snapshot.prefix as NSString).length)

        dismiss()

        var edits = resolved[word].flatMap { $0.isEmpty ? nil : $0 } ?? item.edits

        // Append suffix deletion as an edit so it's part of the plan and undo group
        if !edits.isEmpty, mode == .replace && targetRange.length > prefixRange.length {
            let suffixRange = NSRange(
                location: prefixRange.location + prefixRange.length,
                length: targetRange.length - prefixRange.length
            )
            if !edits.contains(where: { $0.role == .primary && NSMaxRange($0.range) >= NSMaxRange(targetRange) }) {
                edits.append(CompletionEdit(range: suffixRange, newText: "", role: .additional))
            }
        }

        if let plan = plan(for: edits, over: snapshot.prefix, replacing: typedWord, in: nsText) {
            noteProgrammaticEdit(true)
            apply(plan, in: textView)
            noteProgrammaticEdit(false)
            return true
        }

        // Simple insertion
        noteProgrammaticEdit(true)
        undoManager.beginUndoGrouping()
        textView.insertText(word, replacementRange: targetRange)
        undoManager.endUndoGrouping()
        noteProgrammaticEdit(false)

        if item.resolveHandle != nil, resolved[word] == nil {
            scheduleFollowUp(for: item, replacing: targetRange, in: textView)
        }
        return true
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
    /// runs a main-actor turn *after* `insertCompletion` returned, so by then
    /// AppKit's own insertion is in the buffer and there is a real "before" to
    /// compare against.
    ///
    /// An item past `prefetchResolveLimit` has no resolve in flight, so this is
    /// also where one is started: it is worth a round trip now that it is the row
    /// the user chose, and the answer takes exactly the path a prefetched one
    /// that lost the race takes.
    private func scheduleFollowUp(
        for item: CompletionItem,
        replacing typedWord: NSRange,
        in textView: NSTextView
    ) {
        // The display spelling, which here is doing two jobs at once: it is the
        // resolve key, and it is *what now stands in the buffer* — the plan was
        // rejected, so AppKit inserted the row's own string over the typed word,
        // and that is exactly the "typed" text `plan(for:over:replacing:in:)`
        // has to re-express the edits against.
        let word = item.displayText
        let token = generation
        let task: Task<[CompletionEdit], Never>
        if let inFlight = resolveTasks[word] {
            task = inFlight
        } else if let provider = resolveSource {
            task = startResolve(for: item, provider: provider, token: token)
        } else {
            return
        }
        let before = textView.string
        followUpTask = Task { [weak self, weak textView] in
            let edits = await task.value
            guard !Task.isCancelled,
                  let self,
                  let textView,
                  token == self.generation,
                  textView.string == before,
                  let plan = self.plan(
                      for: edits,
                      over: word,
                      replacing: typedWord,
                      in: before as NSString
                  )
            else { return }
            // Outside AppKit's `insertCompletion` bracket, so this one raises the
            // flag itself — the inserted line is not typed text and must not be
            // read by the auto-pair or dedent interceptors.
            self.noteProgrammaticEdit(true)
            self.apply(plan, in: textView)
            self.noteProgrammaticEdit(false)
        }
    }

    // MARK: - Teardown

    /// Drop the snapshot and cancel a pending request (tab teardown).
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        snapshot = nil
        panel.dismiss()
        forgetList()
    }

    /// Forget everything that belongs to the currently-offered list: its
    /// previews, its prefetched resolves and any late auto-import still waiting
    /// on one. The snapshot itself is deliberately *not* dropped here — `update`
    /// keeps the old list serving the popup until the new answer arrives.
    ///
    /// The callers are exactly the two that supersede a list: a keystroke
    /// (`update`) and a tab teardown (`reset`). A caret move is deliberately not
    /// one of them, because it does not supersede the snapshot either — both are
    /// re-validated where they are used instead, the list against the word under
    /// the caret and the edits against the text they were computed over.
    private func forgetList() {
        for task in resolveTasks.values { task.cancel() }
        resolveTasks.removeAll()
        resolved.removeAll()
        followUpTask?.cancel()
        followUpTask = nil
    }
}

#endif
