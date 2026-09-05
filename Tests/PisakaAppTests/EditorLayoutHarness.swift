#if os(macOS)
import AppKit
@testable import Pisaka

/// Headless harness that builds the editor's real TextKit 1 stack exactly as
/// `CodeEditorView.makeNSView` does, but without a window or a run loop.
///
/// Construction mirrors `makeNSView` line for line:
///   `NSTextView(usingTextLayoutManager: false)` →
///   `textContainer?.replaceLayoutManager(BracketOverlayLayoutManager())` →
///   `allowsNonContiguousLayout = true` through `textView.layoutManager` after
///   the swap. The comment in `makeNSView` documents that ordering as
///   load-bearing ("keep that ordering when editing"); this harness is what
///   makes the ordering under test — a reordered harness would hide the crash
///   rather than reproduce it.
///
/// The view lives inside an `NSScrollView` with a frame so layout has a
/// container size to work against, but no window is ever created and no timer
/// or run-loop spin is involved. `layOut()` forces layout synchronously with
/// `ensureLayout(for:)` over the whole container, which is the assertion seam
/// the tests use rather than polling.
@MainActor
final class EditorLayoutHarness {
    let scrollView: NSScrollView
    let textView: NSTextView
    let layoutManager: BracketOverlayLayoutManager
    let textContainer: NSTextContainer
    let textStorage: NSTextStorage

    init() {
        let view = NSTextView(usingTextLayoutManager: false)
        let manager = BracketOverlayLayoutManager()
        view.textContainer?.replaceLayoutManager(manager)
        assert(view.layoutManager === manager, "bracket overlay layout manager did not install")

        // After the swap, through textView.layoutManager — the ordering
        // makeNSView documents.
        view.layoutManager?.allowsNonContiguousLayout = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scroll.documentView = view
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        self.scrollView = scroll
        self.textView = view
        self.layoutManager = manager
        self.textContainer = view.textContainer!
        self.textStorage = view.textStorage!
    }

    /// Force layout over the whole container synchronously.
    @MainActor func layOut() {
        layoutManager.ensureLayout(for: textContainer)
    }
}
#endif
