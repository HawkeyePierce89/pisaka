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
@MainActor
final class CompletionController {

    /// How many characters must be typed before the popup opens by itself.
    ///
    /// One character matches far too much to be a choice, and an unbidden popup
    /// after the first letter of every identifier is the single most-complained-of
    /// behavior of as-you-type completion. An *explicit* invocation (⌃Space, ⌥⎋)
    /// bypasses this — the user asked.
    private static let minimumPrefixLength = 2

    /// The text view being completed in. Held weakly: the view hierarchy owns it,
    /// exactly as the `Coordinator` holds it.
    private weak var textView: NSTextView?

    /// The candidates the delegate serves, and the prefix they answer.
    ///
    /// The prefix is stored *with* them because it is the only thing that makes an
    /// asynchronously-computed list safe to hand to a synchronous delegate: by the
    /// time AppKit asks, the user may have typed another character, and offering
    /// completions for the previous word is worse than offering none.
    private struct Snapshot {
        let prefix: String
        let items: [String]
    }

    private var snapshot: Snapshot?

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
        guard let snapshot,
              charRange.location != NSNotFound,
              charRange.location >= 0,
              NSMaxRange(charRange) <= (textView.string as NSString).length
        else { return [] }
        guard (textView.string as NSString).substring(with: charRange) == snapshot.prefix else {
            return []
        }
        return snapshot.items
    }

    // MARK: - Asking the provider

    /// Recompute the candidate list for whatever is being typed, and open the
    /// popup when there is something to show.
    ///
    /// `explicit` is the ⌃Space / menu path: it skips both the debounce and the
    /// two-character minimum, because the user asked for the list rather than
    /// having it offered. Everything else (a keystroke) is debounced and gated.
    ///
    /// The request is built here, on the main actor, from the live buffer — the
    /// text goes *into* the request rather than being read later, so the words the
    /// provider harvests are the ones on screen when the user paused, not the ones
    /// present when the task happened to resume.
    func update(provider: CodeIntelligenceProviding?, fileURL: URL?, explicit: Bool) {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        let token = generation

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

        let nsText = textView.string as NSString
        let prefixRange = IdentifierScanner.completionPrefixRange(in: nsText, at: caret.location)
        guard prefixRange.length >= (explicit ? 1 : Self.minimumPrefixLength) else {
            snapshot = nil
            return
        }

        let request = CompletionRequest(
            prefix: nsText.substring(with: prefixRange),
            fileURL: fileURL,
            text: textView.string
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
            self.apply(prefix: request.prefix, items: items)
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
    private func apply(prefix: String, items: [CompletionItem]) {
        let texts = items.map(\.text)
        guard !texts.isEmpty else {
            snapshot = nil
            return
        }
        snapshot = Snapshot(prefix: prefix, items: texts)

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
        guard range.length > 0, nsText.substring(with: range) == prefix else { return }
        textView.complete(nil)
    }

    // MARK: - Teardown

    /// Drop the snapshot and cancel a pending request (tab teardown).
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        snapshot = nil
    }
}

#endif
