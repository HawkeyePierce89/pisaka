#if os(macOS)
import AppKit
import PisakaCore

/// Turns "the pointer has been sitting on this identifier" — or, since D34,
/// "the pointer has come to rest inside a diagnostic" — into a hover request,
/// and its answer into a popover.
///
/// Built in the `CompletionController` mould, because it has the same shape of
/// problem: an asynchronous seam behind an event that fires per pixel of mouse
/// movement. So the same three devices appear, doing the same jobs —
///
/// - **One cancellable dwell task.** `HoverContent.dwellDelay` is Core's, not a
///   literal here, and it is what makes moving the pointer across a file cost
///   nothing: every move supersedes the previous task before it has slept.
/// - **One monotonic generation token**, captured *synchronously* before the
///   hop. An answer whose token is stale is dropped and never shown — which is
///   also what makes a dismissal racing an in-flight answer safe, since
///   `dismiss()` bumps the token as its first act.
/// - **One panel**, reused, dismissed idempotently.
///
/// Everything it decides is Core's: `IdentifierScanner` says what counts as a
/// word (so hover, ⌘-click and completion can never disagree), the provider
/// decides whether there is an answer, `HoverContent` decides what the
/// answer looks like and how much of it fits, and since D34 the diagnostic
/// messages merge into that same answer through `Diagnostic.hoverContent` —
/// still the one popover, with no second surface. This class owns exactly two
/// facts of its own — where the pointer is, and whether the answer on screen
/// still describes it.
///
/// **Silent throughout.** No server, no capability, no answer, a timeout, a
/// stale document: all of them are "no popover", with no beep and no alert.
/// Unlike ⌘-click, nobody asked for this — a warning sound for an answer the
/// user never requested would be noise.
///
/// Thin, untested view-layer glue by convention.
@MainActor
final class HoverController: NSObject {

    /// What a request needs from the editor around it, read *at the moment the
    /// question is asked* rather than stored.
    ///
    /// The provider especially: `SymbolIndexController` hands out the model's
    /// latest snapshot, so a held reference would answer from the state a folder
    /// was opened in — the same reason `updateCompletions` re-reads it per call.
    struct Source {
        let provider: any CodeIntelligenceProviding
        let fileURL: URL?
        /// The index's project token, pinned before the hop so an answer for a
        /// folder the user has since left is discarded rather than drawn over
        /// the new one (`SymbolIndexController.currentRootGeneration`).
        ///
        /// Non-optional on purpose. The staleness guard compares this against
        /// `source()?.rootGeneration`, so an optional here would make the
        /// editor-has-gone path read `nil == nil` and *accept* the stale answer
        /// it exists to drop.
        let rootGeneration: Int
        /// Every diagnostic currently held for `fileURL` at a buffer offset, in
        /// ``Diagnostic/orderingKey`` order — D34's lookup, read *at the moment
        /// the question would be asked* like everything else in here. Empty for
        /// an undiagnosed document (and for a preview), which makes the whole
        /// diagnostics half of the dwell rule inert rather than special-cased:
        /// the pointer rules below collapse onto the identifier-only behaviour
        /// they had before this existed.
        let diagnosticsAtOffset: (URL, Int) -> [Diagnostic]
    }

    /// Supplies the above; `nil` means "nothing to ask", which is the state a
    /// preview and a torn-down editor are both in.
    var source: () -> Source? = { nil }

    /// The text view the pointer is tracked over. Held weakly: the view
    /// hierarchy owns it, exactly as every other controller here holds it.
    private weak var textView: NSTextView?

    private let panel = HoverPanel()

    /// The in-flight dwell + provider call; cancelled by any newer pointer
    /// position and by every dismissal.
    private var dwellTask: Task<Void, Never>?

    /// Monotonic token guarding an answer against anything that superseded it
    /// while the provider was being awaited.
    private var generation = 0

    /// The buffer range the current question is about — the identifier's while a
    /// request is in flight, and the range the *answer* covers once one arrives.
    ///
    /// **This is the re-ask suppressor.** While the pointer stays inside it,
    /// nothing is asked and nothing is dismissed: the popover on screen already
    /// describes what is under the pointer. The moment the pointer leaves it, the
    /// answer stops being about anything and comes down.
    ///
    /// Deliberately also set for a request that turns out to have *no* answer, so
    /// a server that knows nothing about an identifier is asked once per visit
    /// rather than once per mouse-moved event.
    private var anchorRange: NSRange?

    /// The editor's own font size — the code zone's, forwarded from
    /// `CodeEditorView` exactly as it is to the text view itself.
    private var codeFontSize: CGFloat = 12

    /// The interface zone's metrics, for the popover's prose. Arrives as a plain
    /// value beside the font size; the raw scale is never named here.
    private var metrics: InterfaceMetrics = .unscaled

    // MARK: - Wiring

    /// Bind the controller to the editor's text view (`makeNSView`).
    ///
    /// The key-window observation is registered here rather than per request:
    /// a window resigning key means the user is somewhere else entirely — another
    /// window, another application — and an annotation of a buffer they are no
    /// longer looking at is stale by definition. Registered for *any* window's
    /// notification because the answer is the same whichever one it was, and
    /// because a popover can only ever be up over the key window.
    func attach(textView: NSTextView) {
        self.textView = textView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    /// Keep the two font inputs current (`makeNSView`/`updateNSView`). Applied to
    /// the next popover: a live one is never re-laid out, it is dismissed. For the
    /// code size `CodeEditorView` does that itself, in the same branch that
    /// re-applies the font — a zoom reflows the buffer under a popover anchored in
    /// screen coordinates, and neither ⌘+/⌘− nor ⌘-scroll moves the pointer, so
    /// nothing else would take it down.
    func syncAppearance(codeFontSize: CGFloat, metrics: InterfaceMetrics) {
        self.codeFontSize = codeFontSize
        self.metrics = metrics
    }

    // MARK: - The pointer

    /// The pointer moved to `point`, in the text view's own coordinates.
    ///
    /// Three outcomes and no others: the pointer is over something that is
    /// neither a word nor diagnosed text (dismiss), it is still over the thing
    /// the current answer is about (do nothing at all), or it is over a new
    /// identifier — or into a diagnostic range (D34) — (supersede everything
    /// and start a fresh dwell).
    func pointerMoved(to point: NSPoint, in textView: NSTextView) {
        guard let offset = Self.characterIndex(at: point, in: textView) else {
            dismiss()
            return
        }
        // The source is read once, up front, and reused below: D34's diagnostics
        // lookup needs it *before* any ask is decided, and calling twice for one
        // event would be two snapshots of something the gates must reason about
        // as one. `nil` does not dismiss by itself — the gates below keep
        // deciding that exactly as they did — so a popover whose editor has lost
        // its index controller still leaves through the suppression test rather
        // than being torn down ahead of it.
        let resolvedSource = source()
        // D34: what a server has flagged under the pointer, read at the moment
        // the question would be asked like everything else here. Empty for an
        // undiagnosed document (and for a preview), which makes every
        // diagnostic-shaped branch below inert: the rules collapse onto the
        // identifier-only behaviour they had before this lookup existed.
        let hitDiagnostics = resolvedSource.map { source -> [Diagnostic] in
            source.fileURL.map { source.diagnosticsAtOffset($0, offset) } ?? []
        } ?? []
        guard let storage = textView.textStorage else {
            dismiss()
            return
        }
        // An identifier is still the first thing worth asking about, and its
        // range is what anchors the popover when it is all there is. This is
        // also the gate that keeps whitespace, punctuation and the empty region
        // past a line's end from reaching the provider at all — unless a
        // diagnostic sits under the pointer, which asks too (D34): a squiggle
        // can cover punctuation no scanner calls a word.
        //
        // Read through the storage's own `NSMutableString` rather than
        // `textView.string`: this line runs on every mouse-moved event, and the
        // bridge to a Swift `String` copies the whole document each time. Every
        // other `textView.string` in the editor sits behind a debounce or an
        // explicit command; nothing here may. Read-only, and synchronously on the
        // main actor, so no edit can interleave.
        let match = IdentifierScanner.identifier(in: storage.mutableString, at: offset)
        guard match != nil || !hitDiagnostics.isEmpty else {
            dismiss()
            return
        }
        // Still about the answer on screen? Two ways that can be true, and the
        // second is not decoration: `IdentifierScanner` also resolves the
        // identifier *ending* at an offset, so the pointer sitting on the `.` of
        // `worker.name`, on a `(`, or on the space after a name resolves to the
        // word before it while lying outside that word's range. Testing only the
        // offset would take the popover down and re-ask on every pixel of jitter
        // at exactly the positions a pointer comes to rest on.
        //
        // The *empty region past a line's end* is not one of those positions, and
        // it is `characterIndex(at:in:)` that keeps it out of here: a trailing
        // separator is laid out spanning the whole remainder of its line fragment,
        // so a pointer inches to the right of the text resolves to it and the
        // ending-at probe would answer the line's last word — retaining a popover
        // about a symbol the pointer has plainly left. Rejecting the separator
        // there is what makes this test and the ask below agree; a guard on the
        // offset alone cannot, because the `.` after a name and the newline after
        // one sit at the very same offset relative to it.
        //
        // The anchor may now equally be a diagnostic union (D34); the offset test
        // covers it without ceremony, since the pointer staying inside the union
        // is precisely "still about the answer on screen".
        if let anchorRange {
            let matchCovered = match.map { Self.range(anchorRange, contains: $0.range) } ?? false
            // A *zero-length* anchor is the one shape `NSLocationInRange` cannot
            // answer for: a server's "expected `}`" at a position produces a
            // union of width 0, which contains no offset at all, so a pointer
            // resting on that very character would fail this test on every
            // `mouseMoved` — dismissing and re-dwelling the popover per pixel of
            // jitter. Its own offset *is* "still about the answer on screen" for
            // it, the same reading `DiagnosticStore.diagnostics(at:)` and
            // `DiagnosticRun.merged` already give an empty range.
            let insideAnchor = anchorRange.length == 0
                ? offset == anchorRange.location
                : NSLocationInRange(offset, anchorRange)
            if insideAnchor || matchCovered {
                return
            }
        }
        // Nothing on screen to keep, so the *second* probe's answer is no longer
        // wanted: a question is only asked when the pointer is over the word
        // itself — or inside a diagnostic range, which is D34's addition and the
        // one place the ending-at probe's resolution is allowed to stand in.
        // Keeping the rest out also makes the offset the question carries
        // agree with the range the answer is anchored to, which matters because the
        // servers disagree at exactly those positions (sourcekit-lsp resolves at the
        // preceding token, gopls' node lookup is `[Pos, End)`).
        let insideIdentifier = match.map { NSLocationInRange(offset, $0.range) } ?? false
        guard insideIdentifier || !hitDiagnostics.isEmpty else {
            dismiss()
            return
        }

        // Everything older is now about a different word. The token is bumped
        // *before* the hop, so an answer already in flight for the previous
        // identifier can no longer be drawn.
        dwellTask?.cancel()
        generation += 1
        let token = generation
        panel.dismiss()
        anchorRange = nil

        // What the question carries and what it anchors to: the identifier's
        // span when there is one, extended over every diagnostic range it hit —
        // or, for a pointer resting inside a squiggle but not on any word, the
        // union of the hit spans alone. The union is what makes the re-ask
        // suppressor hold across the whole span: moving between overlapping
        // diagnostics' text must not tear the popover down per pixel. Off an
        // identifier the question carries the span's start rather than the
        // pointer's own offset — servers resolve tokens, and a diagnostic begins
        // at the construct it complains about, so the start is the likeliest
        // position to resolve at all.
        let question = Self.question(for: offset, identifier: match, diagnostics: hitDiagnostics)

        // The anchor is claimed only once a question is certain to be asked — it
        // means "this has been asked about", and the source read up front is the
        // one this ask consumes (nothing is read twice for one event).
        guard let resolvedSource else { return }
        anchorRange = question.anchor
        let provider = resolvedSource.provider
        let rootGeneration = resolvedSource.rootGeneration
        let fileURL = resolvedSource.fileURL
        // The messages travel with the question, captured synchronously before
        // the hop like everything else: a push landing during the dwell or the
        // await must not rewrite what this popover is about to say mid-flight.
        let pendingDiagnostics = hitDiagnostics
        dwellTask = Task { [weak self, weak textView] in
            try? await Task.sleep(for: .seconds(HoverContent.dwellDelay))
            if Task.isCancelled { return }
            guard let textView else { return }
            // The live buffer travels with the question (D2): document sync is
            // request-driven, so the text the server type-checks is the text on
            // screen when the pointer came to rest.
            //
            // Read *after* the dwell, and that is the point: the bridge to a
            // Swift `String` copies the whole document, and building the request
            // eagerly would pay that copy for every identifier a pointer sweeps
            // across — on the main thread, for a question most of those sweeps
            // never get to ask. It is the same cost the identifier scan above
            // reads `storage.mutableString` to avoid. Reading it here is no less
            // faithful: every character edit calls `dismiss()` (the storage's
            // `editedCharacters` notification), which cancels this task, so the
            // text cannot have changed under the offset while we slept. The
            // closure is main-actor isolated like the rest of the class, so the
            // read is as safe here as it was there.
            let request = HoverRequest(
                fileURL: fileURL,
                offset: question.offset,
                text: textView.string
            )
            let answer = await provider.hover(for: request)
            guard !Task.isCancelled,
                  let self,
                  token == self.generation,
                  self.source()?.rootGeneration == rootGeneration
            else { return }
            self.dwellTask = nil
            // D34: the messages ride the same popover — above the type answer
            // when there is one, alone when there is not, and nothing shows at
            // all when both come back empty (the no-empty-popover rule decides,
            // silently, as ever).
            guard let content = Diagnostic.hoverContent(
                for: pendingDiagnostics,
                merging: answer?.content
            ) else { return }
            // The server's own range stays the honest span when it answered; a
            // diagnostics-only answer keeps the union set at ask time.
            self.present(content, anchoredTo: answer?.range ?? question.anchor, in: textView)
        }
    }

    /// The pointer left the text view: there is nothing under it to describe.
    func pointerExited() {
        dismiss()
    }

    // MARK: - Showing and hiding

    /// Put the answer on screen, anchored to the span it is about.
    ///
    /// One popover, one content type: the merged answer D34 builds is the same
    /// `HoverContent` a plain type answer always was — no second panel, no
    /// second presentation path.
    private func present(
        _ content: HoverContent,
        anchoredTo rawRange: NSRange,
        in textView: NSTextView
    ) {
        // Only over the window the user is actually in. A popover that arrived a
        // dwell after the editor lost focus would float over whatever took it.
        guard let window = textView.window, window.isKeyWindow else { return }
        let length = textView.textStorage?.length ?? 0
        guard rawRange.location >= 0, rawRange.location <= length else { return }
        // Clamped by truncating the length rather than intersecting, for
        // `pendingRevealRange`'s reason: a range starting exactly at the buffer's
        // end shares no unit with it, and an intersection would answer `{0, 0}` —
        // anchoring the popover at the top of the file.
        let clamped = NSRange(
            location: rawRange.location,
            length: min(max(rawRange.length, 0), length - rawRange.location)
        )
        // Measured *before* the anchor is published, and the order is load-bearing:
        // `firstRect` can force layout on a range not yet laid out, and a reflow
        // posts `frameDidChangeNotification` — which lands in `dismissHover()`
        // synchronously and clears `anchorRange`. Assigning first would leave that
        // dismissal undone by the `show` below: a popover on screen with no anchor,
        // which the next mouse-moved event inside the same word tears down and
        // re-asks, for a visible flicker and a redundant round trip.
        let anchor = textView.firstRect(forCharacterRange: clamped, actualRange: nil)
        // What the pointer is now measured against: the server's own range when
        // it sent one, which is usually wider than what was asked about (a
        // qualified name, an operator expression) and is the honest span of the
        // answer; for diagnostics alone it is the union of the flagged spans,
        // set when the question was claimed.
        anchorRange = clamped
        panel.show(
            content.truncated(),
            anchoredTo: anchor,
            in: window,
            codeFontSize: codeFontSize,
            metrics: metrics
        )
    }

    /// Take the popover down and forget what it was about.
    ///
    /// **Idempotent, and safe against a dismissal racing an in-flight answer**:
    /// the generation bump is what makes the second guarantee — a provider call
    /// that lands after this returns finds a stale token and publishes nothing,
    /// so there is no window in which a dismissed popover comes back.
    ///
    /// Every trigger the feature lists funnels here: the pointer leaving the
    /// anchor range or the text view, a scroll, a text edit, a selection change,
    /// a tab or file switch, the window resigning key, and teardown.
    func dismiss() {
        dwellTask?.cancel()
        dwellTask = nil
        generation += 1
        anchorRange = nil
        panel.dismiss()
    }

    /// Teardown (`Coordinator.teardown`): dismiss and stop observing.
    func reset() {
        dismiss()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    /// Whether `outer` covers the whole of `inner` — the "the pointer is still on
    /// the thing the popover describes" test, asked of the *identifier* rather
    /// than of the offset. A server's range is usually the wider of the two (a
    /// qualified name, an operator expression), which is exactly why moving
    /// within it must not re-ask.
    private static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Where a hover question about `offset` points and what it anchors to.
    ///
    /// The identifier's span when there is one — extended, when the pointer also
    /// sits in diagnosed text, over every diagnostic range it hit — or otherwise
    /// the union of the hit ranges alone. Off an identifier the request carries
    /// the union's *start*: a diagnostic begins at the construct it complains
    /// about, so the start is the likeliest position for a token-resolving
    /// server to answer at all (see `pointerMoved`).
    private static func question(
        for offset: Int,
        identifier: IdentifierScanner.Match?,
        diagnostics: [Diagnostic]
    ) -> (offset: Int, anchor: NSRange) {
        var anchor = identifier.map(\.range)
        var start = offset
        if let first = diagnostics.first {
            let union = diagnostics.dropFirst().reduce(first.range) { Self.union($0, $1.range) }
            anchor = anchor.map { Self.union($0, union) } ?? union
            let inside = identifier.map { NSLocationInRange(offset, $0.range) } ?? false
            if !inside { start = union.location }
        }
        return (start, anchor ?? NSRange(location: offset, length: 0))
    }

    /// The smallest range covering both — how overlapping diagnostics become
    /// one anchor span. Both inputs are store-mapped ranges (`location >= 0`),
    /// so no `NSNotFound` guard is owed here.
    private static func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        let location = min(a.location, b.location)
        let end = max(NSMaxRange(a), NSMaxRange(b))
        return NSRange(location: location, length: end - location)
    }

    // MARK: - Resolving the character under the pointer

    /// The UTF-16 offset of the character the pointer is **over**, or `nil` when
    /// it is over no character at all.
    ///
    /// A *nearest insertion point* is not the answer, which is the whole reason
    /// this is not one line. `characterIndexForInsertion(at:)` — what the ⌘-click
    /// and the viewport memory use — resolves a pointer in the empty space past
    /// the end of a line to that line's last character, and a popover describing
    /// a symbol the pointer is a hand's width away from is worse than no popover.
    /// So its answer is *verified*: the character is accepted only when its own
    /// laid-out rectangle contains the point.
    ///
    /// Two candidates are tried because an insertion point is a boundary, not a
    /// character: a pointer in the right half of a glyph reports the index *after*
    /// it. The character before the boundary is therefore checked as well, and the
    /// containment test is what tells the two apart — so both halves of every
    /// glyph resolve to the glyph.
    ///
    /// A **line separator is no character** for this purpose, and that is the one
    /// thing the rectangle test cannot buy on its own: a line's trailing newline is
    /// laid out spanning the whole remainder of its line fragment, so a point far to
    /// the right of the text is genuinely inside that glyph's rectangle. Answering
    /// the separator would hand `pointerMoved(to:in:)` an offset whose ending-at
    /// probe resolves to the line's last word — which the ask path rejects, but which
    /// the re-ask suppressor would happily accept, leaving a popover up while the
    /// pointer sweeps the blank half of the line. The separator set is
    /// `LineStartIndex`', so "where a line ends" means here what it means to the
    /// gutter, the minimap and TextKit's own layout.
    ///
    /// The insertion index is clamped by AppKit and both probes are bounded by the
    /// buffer's length, so nothing here can name a glyph that does not exist. That
    /// is deliberate: the obvious spelling — `glyphIndex(for:in:)` guarded against
    /// `numberOfGlyphs` — would force glyph generation for the **entire document**
    /// on every mouse-moved event, the exact cost `allowsNonContiguousLayout`
    /// exists to avoid (see `restoreViewport`).
    private static func characterIndex(at point: NSPoint, in textView: NSTextView) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage
        else { return nil }
        let length = storage.length
        guard length > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let insertion = textView.characterIndexForInsertion(at: point)
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            // Read through the storage's own `NSMutableString`, as the identifier
            // scan does and for the same per-mouse-moved-event reason.
            if LineStartIndex.isLineSeparator(storage.mutableString.character(at: candidate)) {
                continue
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: candidate, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }
            if layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                .contains(containerPoint) {
                return candidate
            }
        }
        return nil
    }
}

#endif
