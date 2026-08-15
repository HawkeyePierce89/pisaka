#if os(macOS)
import AppKit
import PisakaCore

/// Feeds AppKit's built-in completion popup from the asynchronous code
/// intelligence seam.
///
/// **The whole problem this class exists to solve** is a mismatch of shapes.
/// `NSTextViewDelegate.textView(_:completions:forPartialWordRange:indexOfSelectedItem:)`
/// is *synchronous* — AppKit asks for the list while it is already putting the
/// popup on screen — while `CodeIntelligenceProviding` is *asynchronous*, because
/// a phase-2 LSP provider has to await a socket. So the work is inverted: this
/// controller computes candidates ahead of time behind a debounce, stores them
/// together with the prefix they were computed for, and only then asks the text
/// view to `complete(nil)`. The delegate call that follows is served from that
/// snapshot and touches nothing asynchronous. Nothing about the seam is
/// compromised — the provider is still awaited, just one turn earlier than AppKit
/// would like.
///
/// Everything the popup shows is decided in `PisakaCore`:
/// `IdentifierScanner.completionPrefixRange(in:at:)` says what is being typed and
/// `SymbolIntelligenceProvider` ranks and caps the answers. This class only
/// decides *when* to ask and *whether the answer is still current*, so — like the
/// rest of `Sources/Pisaka` — it is thin, untested view-layer glue.
///
/// **Debounce and generation token** follow the `BracketHighlightController`
/// idiom: a cancellable `Task.sleep` coalesces a burst of keystrokes into one
/// provider call, and a monotonic token discards an answer that a newer request
/// (a further keystroke, a caret move, a tab switch) superseded while it was in
/// flight. 150 ms, matching the minimap's tokenizer rather than the index's
/// 400 ms: this asks a question of a snapshot already in memory, so the cost is
/// a prefix scan and a sort, not a re-parse.
///
/// **The list is strings; the answers are items.** AppKit's popup shows strings
/// and hands one back when a row is committed, but an LSP answer is more than
/// its text — it may carry the `import` line that makes the symbol resolve (D4).
/// The snapshot therefore keeps whole `CompletionItem`s keyed by that string, so
/// `insert(_:forPartialWordRange:isFinal:in:)` can find the item behind it and
/// apply its edits itself. Everything about *which* edits and in what order is
/// `CompletionEditPlan`'s; this class only supplies the live buffer, the undo
/// group and the text view.
///
/// That string is the item's **display** spelling (`CompletionItem.displayText`),
/// not the text it inserts, and it is the key in all three tables — the
/// snapshot, the prefetched `resolved` edits and `resolveTasks` — because AppKit
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
    /// resolve — and then, only if a popup may be up, asks the text view to
    /// re-query. `complete(nil)` reaches the delegate, which now answers `[]`,
    /// and an empty answer is what closes a popup that is already on screen.
    ///
    /// "May be up" is **a live snapshot in the editor the user is actually typing
    /// in**, and the focus half is not decoration: a snapshot is stored by
    /// `apply(…)` *before* its own focus/caret guards and is not dropped when a
    /// popup closes (Esc and an accepted row both leave it standing until the next
    /// keystroke), so a snapshot routinely outlives — or never had — a visible
    /// list. Calling `complete(nil)` on that would break the very rule `apply`
    /// states: only the focused editor may reach AppKit's completion machinery, or
    /// a list floats over whatever the user *is* typing in.
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
        guard !enabled else { return }
        // Read before `reset()` drops it.
        let mayHavePopup = snapshot != nil
        reset()
        guard mayHavePopup else { return }
        DispatchQueue.main.async { [weak self] in
            // `textView` is unwrapped rather than compared through the optional
            // chain: `nil === nil` is *true*, so an `Optional` first-responder
            // test would pass for a controller that has no text view at all.
            guard let self,
                  !self.isEnabled,
                  let textView = self.textView,
                  let window = textView.window,
                  window.isKeyWindow,
                  window.firstResponder === textView,
                  !textView.hasMarkedText()
            else { return }
            textView.complete(nil)
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
        /// The member position these answer, or `nil` when they answer an ordinary
        /// partial word. Carried — **receiver and all** — so the delegate can
        /// apply the same still-in-*this*-member-position test
        /// `apply(prefix:member:items:)` does. The receiver is the load-bearing
        /// half: an empty prefix matches every dot in the buffer, so a test of
        /// "still after *a* dot" would let a caret moved to `other.` be served
        /// `Worker.`'s list. Only the receiver is compared, not the whole context
        /// — its `prefixRange` is position-dependent by construction.
        let member: IdentifierScanner.MemberContext?
        /// The strings the popup shows, in the provider's order.
        let texts: [String]
        /// The same answers, whole and keyed by the string above.
        ///
        /// AppKit's popup is a list of *strings* and its insertion callback hands
        /// one back, so the item behind it has to be findable by that string or
        /// an LSP item's edits (D4's auto-import) could never be applied. The
        /// display spelling rather than the inserted text for exactly that
        /// reason: the popup only ever knows the row it is showing. First wins on
        /// a duplicate: two items that *read* the same are one row, and the
        /// higher-ranked one is the one the user is choosing.
        ///
        /// Note this key is deliberately **not** the provider's: it deduped by
        /// the *inserted* text, so two items that insert differently but read
        /// the same survive there and collapse here. This is the one place the
        /// popup's list is narrower than the provider's answer, and it has to
        /// be — a row the user cannot tell apart is not a choice. Everything
        /// keyed by the same string (the resolves) is therefore fed from *this*
        /// deduped list rather than from the provider's, so no dropped item can
        /// file edits under a surviving row's key.
        let items: [String: CompletionItem]
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

    /// What a *preview* insertion last wrote over the typed word.
    ///
    /// AppKit writes the highlighted row into the buffer as the user arrows
    /// through the popup — `insertCompletion(…, isFinal: false)` — so by the
    /// time the final call arrives the typed word the provider's edits are
    /// expressed against is no longer what stands there. Every one of those
    /// writes passes through this controller, so remembering the last one is
    /// enough to re-express the edits (`CompletionEdit.shifted(…)`) and to state
    /// what the buffer must still read for them to be applied at all.
    private var preview: String?

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

    // MARK: - Serving AppKit

    /// The list AppKit's popup shows for `charRange` — the delegate's whole body.
    ///
    /// Returns the stored snapshot only while the requested partial word is still
    /// *exactly* the prefix it was computed for, and `[]` otherwise. The mismatch
    /// case is not an error: it is the ordinary "the user typed one more
    /// character" state, and `[]` dismisses the popup until the debounce fires
    /// again a moment later with a list that does match.
    ///
    /// The range is validated against the live buffer before it is read: AppKit
    /// hands back the range `rangeForUserCompletion` reported, and a completion
    /// session that outlived an edit shrinking the buffer would otherwise index
    /// out of bounds.
    func completions(forPartialWordRange charRange: NSRange, in textView: NSTextView) -> [String] {
        // The second half of the on/off gate, covering the commands that never
        // pass through `update(…)`: AppKit's stock ⌥⎋ and F5 reach this delegate
        // answer directly. `[]` is also what dismisses a popup that was on screen
        // when the toggle was flipped — `setEnabled` re-queries for exactly that.
        //
        // Stated locally rather than left to the `guard let snapshot` below, which
        // today happens to answer `[]` too (nothing can populate a snapshot while
        // off: `setEnabled` resets and `update` returns at its entry). That is a
        // non-local proof about three other methods; "off answers nothing" is the
        // rule this switch is, so it is written where the answer is given.
        guard isEnabled else { return [] }
        // One read: `NSTextView.string` copies the whole buffer out of the mutable
        // text storage on every access, and this runs while AppKit is already
        // putting the popup on screen.
        let nsText = textView.string as NSString
        guard let snapshot,
              charRange.location != NSNotFound,
              charRange.location >= 0,
              // Checked with the bound below rather than left to it: `NSMaxRange`
              // of a negative length is *smaller* than the location, so a negative
              // length passes the bound and then raises inside `substring(with:)`.
              // The insertion side (`insert(_:for:in:)`) makes the same check on
              // the same AppKit-supplied range.
              charRange.length >= 0,
              NSMaxRange(charRange) <= nsText.length
        else { return [] }
        guard nsText.substring(with: charRange) == snapshot.prefix else {
            return []
        }
        // The partial word matching is not enough on its own: a member list and an
        // ordinary list answer the same typed characters with different candidate
        // *sets* (a member list carries no keywords and no non-member symbols), so
        // the caret must still be in the same member state the items were computed
        // for — receiver and all — at **every** prefix length, not only the empty
        // one. This path is the one that needs it most: AppKit's stock ⌥⎋/F5
        // reaches the delegate directly, without going through `update(…)`, and a
        // caret move does not refresh the snapshot. So without this, ⌥⎋ after
        // `other.` would be served the members of the `Worker.` typed before it,
        // ⌥⎋ in open space the last dot's list, and ⌥⎋ over an unrelated `na`
        // the member-only list computed for `worker.na`.
        //
        // `map(\.receiver)` rather than `?.receiver`: the receiver is itself
        // optional (a bracketed one — `f().` — names no type), and optional
        // chaining would flatten "not a member position" into "a member position
        // with an unnamed receiver" and let the two serve each other's lists.
        guard IdentifierScanner.memberContext(in: nsText, at: charRange.location).map(\.receiver)
                == snapshot.member.map(\.receiver)
        else { return [] }
        return snapshot.texts
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
            return
        }

        guard let textView, let provider else {
            snapshot = nil
            return
        }
        // No popup mid-composition. Marked text is uncommitted input the input
        // method still owns; completing over it would insert into a range the
        // composition is about to replace — the same reasoning as the ⌘D guard.
        guard !textView.hasMarkedText() else {
            snapshot = nil
            return
        }
        let caret = textView.selectedRange()
        // A non-empty selection is not a partial word: the user is about to
        // replace it, not extend it.
        guard caret.length == 0 else {
            snapshot = nil
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
            guard prefixRange.length >= (explicit ? 1 : Self.minimumPrefixLength) else {
                snapshot = nil
                return
            }
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
                token: token
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
        token: Int
    ) {
        var byText: [String: CompletionItem] = [:]
        var texts: [String] = []
        for item in items where byText[item.displayText] == nil {
            byText[item.displayText] = item
            texts.append(item.displayText)
        }
        guard !texts.isEmpty else {
            snapshot = nil
            return
        }
        snapshot = Snapshot(prefix: prefix, member: member, texts: texts, items: byText)
        // D4: an item the server kept its edits back on is resolved *now*,
        // concurrently and in the background, rather than when it is chosen —
        // the pick is hundreds of milliseconds away, which is time enough for a
        // round trip the user never waits on. Nothing depends on the answer
        // arriving: an item committed first takes the follow-up path instead.
        //
        // The **deduped** rows, not the provider's raw list, and that is a
        // correctness requirement rather than a saving: the resolve tables are
        // keyed by the displayed string, so an item this snapshot dropped would
        // file its edits under a key that now belongs to the row the user can
        // actually see — and `insert` prefers `resolved[word]` over the item's
        // own edits, so the visible row would commit the dropped item's
        // replacement and its `import`. Keying off `texts` makes the collision
        // unrepresentable: within the snapshot the display strings are unique by
        // construction, and the provider's order is preserved.
        prefetchResolves(for: texts.compactMap { byText[$0] }, provider: provider, token: token)

        guard let textView,
              !textView.hasMarkedText(),
              // Only the focused editor may open a popup: `complete(nil)` on a
              // text view the user is not typing in would put a floating list over
              // whatever they *are* typing in.
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
        textView.complete(nil)
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
    func insert(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        isFinal: Bool,
        in textView: NSTextView
    ) -> Bool {
        let nsText = textView.string as NSString
        guard let snapshot,
              let item = snapshot.items[word],
              charRange.location != NSNotFound,
              charRange.location >= 0,
              charRange.length >= 0,
              NSMaxRange(charRange) <= nsText.length
        else {
            // Esc restores the typed word through this same method, and so does
            // any insertion this controller never offered: whatever preview was
            // in the buffer is about to be overwritten by something that is not
            // one of our rows, so it stops being a thing to reason about.
            preview = nil
            return false
        }
        guard isFinal else {
            preview = word
            return false
        }

        // Where the typed word stood when the *request* was made — the frame all
        // of an item's edits are expressed in. Its location is `charRange`'s:
        // a completion session does not move the word's start, only its length,
        // and a `charRange` that disagrees fails the staleness check below.
        let typedWord = NSRange(
            location: charRange.location,
            length: (snapshot.prefix as NSString).length
        )
        // An empty resolve is not an answer. `resolveEdits` returns `[]` for a
        // timeout, a dead session and a superseded handle alike, so reading it as
        // "this item turned out to have no edits" would throw away the ones the
        // item was *published* with — including a server-chosen range wider than
        // the typed prefix, which AppKit's stock insertion would then leave
        // standing in the buffer. A resolve that genuinely adds nothing loses
        // nothing here either: it answers the same edits the item already carried.
        let edits = resolved[word].flatMap { $0.isEmpty ? nil : $0 } ?? item.edits
        if let plan = plan(
            for: edits,
            over: preview ?? snapshot.prefix,
            replacing: typedWord,
            in: nsText
        ) {
            // The programmatic-edit flag is already up: `insertCompletion` holds
            // it for the whole call, this one included.
            apply(plan, in: textView)
            preview = nil
            return true
        }

        preview = word
        if item.resolveHandle != nil, resolved[word] == nil {
            scheduleFollowUp(for: item, replacing: typedWord, in: textView)
        }
        return false
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
        followUpTask = Task { [weak self, weak textView] in
            guard let before = textView?.string else { return }
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
        preview = nil
    }
}

#endif
