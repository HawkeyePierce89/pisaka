#if os(macOS)
import AppKit
import PisakaCore

/// Turns "the pointer has been sitting on this identifier" into a hover request,
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
/// decides whether there is an answer, and `HoverContent` decides what the
/// answer looks like and how much of it fits. This class owns exactly two facts
/// of its own — where the pointer is, and whether the answer on screen still
/// describes it.
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
        let rootGeneration: Int?
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
    /// the next popover; a change while one is up is not worth re-laying out,
    /// since the pointer moving an inch takes it down anyway.
    func syncAppearance(codeFontSize: CGFloat, metrics: InterfaceMetrics) {
        self.codeFontSize = codeFontSize
        self.metrics = metrics
    }

    // MARK: - The pointer

    /// The pointer moved to `point`, in the text view's own coordinates.
    ///
    /// Three outcomes and no others: the pointer is over something that is not a
    /// word (dismiss), it is still over the thing the current answer is about
    /// (do nothing at all), or it is over a new identifier (supersede everything
    /// and start a fresh dwell).
    func pointerMoved(to point: NSPoint, in textView: NSTextView) {
        guard let offset = Self.characterIndex(at: point, in: textView) else {
            dismiss()
            return
        }
        // Only an identifier is worth asking about, and its range is what
        // anchors the popover before the server names a range of its own. This
        // is also the gate that keeps whitespace, punctuation and the empty
        // region past a line's end from reaching the provider at all.
        guard let match = IdentifierScanner.identifier(in: textView.string as NSString, at: offset)
        else {
            dismiss()
            return
        }
        if let anchorRange, NSLocationInRange(offset, anchorRange) { return }

        // Everything older is now about a different word. The token is bumped
        // *before* the hop, so an answer already in flight for the previous
        // identifier can no longer be drawn.
        dwellTask?.cancel()
        generation += 1
        let token = generation
        panel.dismiss()
        anchorRange = match.range

        guard let source = source() else { return }
        let provider = source.provider
        let rootGeneration = source.rootGeneration
        // The live buffer travels with the question (D2): document sync is
        // request-driven, so the text the server type-checks is the text on
        // screen when the pointer stopped, not whatever is there when the task
        // happens to resume.
        let request = HoverRequest(
            fileURL: source.fileURL,
            offset: offset,
            text: textView.string
        )
        dwellTask = Task { [weak self, weak textView] in
            try? await Task.sleep(for: .seconds(HoverContent.dwellDelay))
            if Task.isCancelled { return }
            let answer = await provider.hover(for: request)
            guard !Task.isCancelled,
                  let self,
                  let textView,
                  token == self.generation,
                  self.source()?.rootGeneration == rootGeneration
            else { return }
            self.dwellTask = nil
            guard let answer else { return }
            self.present(answer, in: textView)
        }
    }

    /// The pointer left the text view: there is nothing under it to describe.
    func pointerExited() {
        dismiss()
    }

    // MARK: - Showing and hiding

    /// Put the answer on screen, anchored to the span it is about.
    private func present(_ answer: HoverAnswer, in textView: NSTextView) {
        // Only over the window the user is actually in. A popover that arrived a
        // dwell after the editor lost focus would float over whatever took it.
        guard let window = textView.window, window.isKeyWindow else { return }
        let length = textView.textStorage?.length ?? 0
        guard answer.range.location >= 0, answer.range.location <= length else { return }
        // Clamped by truncating the length rather than intersecting, for
        // `pendingRevealRange`'s reason: a range starting exactly at the buffer's
        // end shares no unit with it, and an intersection would answer `{0, 0}` —
        // anchoring the popover at the top of the file.
        let clamped = NSRange(
            location: answer.range.location,
            length: min(max(answer.range.length, 0), length - answer.range.location)
        )
        // What the pointer is now measured against: the server's own range when
        // it sent one, which is usually wider than the identifier (a qualified
        // name, an operator expression) and is the honest span of the answer.
        anchorRange = clamped
        panel.show(
            answer.content.truncated(),
            anchoredTo: textView.firstRect(forCharacterRange: clamped, actualRange: nil),
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
    /// glyph resolve to the glyph, and neither half of the empty space past a line
    /// resolves to anything.
    ///
    /// The insertion index is clamped by AppKit and both probes are bounded by the
    /// buffer's length, so nothing here can name a glyph that does not exist. That
    /// is deliberate: the obvious spelling — `glyphIndex(for:in:)` guarded against
    /// `numberOfGlyphs` — would force glyph generation for the **entire document**
    /// on every mouse-moved event, the exact cost `allowsNonContiguousLayout`
    /// exists to avoid (see `restoreViewport`).
    private static func characterIndex(at point: NSPoint, in textView: NSTextView) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return nil }
        let length = textView.textStorage?.length ?? 0
        guard length > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let insertion = textView.characterIndexForInsertion(at: point)
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
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
