#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// A view that declares itself a zoom *surface* — something the pointer can be
/// over that is drawn at a zone's own scale rather than at the interface scale.
///
/// Deliberately a marker with one read-only property and no behavior: everything
/// a gesture does with the answer lives in `ZoomController`, and every rule for
/// turning a set of answers into a zone lives in `PisakaCore.ZoomZone`. A view
/// conforms in order to be *found*, not in order to act.
///
/// Conformed to by the four code text views (the editor, the diff panes, the
/// merge panes, the source viewer), by the three views that draw *beside* them
/// and are therefore unreachable through them — `LineNumberRulerView` and
/// `DiffGutterView` (a scroll view's ruler is a sibling of its text view) and
/// `MinimapView` (a sibling of the editor's scroll view) — by SwiftTerm's
/// terminal view, and by `ZoomSurfaceMarkerView`, the AppKit half of the marker
/// the SwiftUI-drawn code surfaces use. Nothing declares `.interface`: chrome is
/// what is left when no surface was hit, which is why `ZoomSurfaceKind` has no
/// case for it.
///
/// The sibling rule is the easy thing to get wrong: a view that *looks* like part
/// of the editor but sits next to its text view produces no candidate at all, so
/// the pointer over it resolves to `.interface` and the gesture resizes the whole
/// application chrome. Anything drawn at the code font needs its own conformance.
@MainActor
protocol ZoomSurfaceProviding: AnyObject {
    var zoomSurfaceKind: ZoomSurfaceKind { get }
}

/// Marks a region of SwiftUI-drawn content as a zoom surface.
///
/// Two surfaces in this app draw at the code font without an `NSTextView` behind
/// them — the Find in Files result rows and the LeetCode statement's `WKWebView`
/// body — so there is no AppKit class of ours to conform. This representable
/// supplies one: an empty, non-drawing, hit-test-transparent `NSView` placed
/// *behind* the content with `.background(...)`, so it inherits exactly that
/// content's frame and nothing else about it.
///
/// Zero-cost is meant literally: the view draws nothing, accepts no clicks
/// (`hitTest` answers `nil`), takes no focus and is hidden from accessibility.
/// The only thing it contributes is a frame the pointer walk can find.
struct ZoomSurfaceMarker: NSViewRepresentable {
    let kind: ZoomSurfaceKind

    func makeNSView(context: Context) -> ZoomSurfaceMarkerView {
        ZoomSurfaceMarkerView(kind: kind)
    }

    func updateNSView(_ nsView: ZoomSurfaceMarkerView, context: Context) {
        nsView.zoomSurfaceKind = kind
    }
}

/// The `NSView` behind `ZoomSurfaceMarker`. Internal rather than private only
/// because the representable names it in its signatures.
@MainActor
final class ZoomSurfaceMarkerView: NSView, ZoomSurfaceProviding {
    var zoomSurfaceKind: ZoomSurfaceKind

    init(kind: ZoomSurfaceKind) {
        self.zoomSurfaceKind = kind
        super.init(frame: .zero)
        // Not part of the accessibility tree: it has no content, and an empty
        // group element in the middle of a results list is noise to a screen
        // reader.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Transparent to every click, drag and mouse-over. The pointer walk finds
    /// this view by geometry (`ZoomHitTest`), never through AppKit hit testing,
    /// so refusing hits costs the zoom nothing and keeps the marker from ever
    /// standing between the user and the row it marks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What is under the pointer, right now, expressed in Core's vocabulary.
///
/// The whole app-side half of the pointer rule: find the frontmost window at the
/// pointer, walk it, and hand `ZoomZone.resolve` a list of candidates. Every
/// *decision* over that list is Core's; this collects the facts.
@MainActor
enum ZoomHitTest {
    /// Where the pointer is, as `ZoomZone.resolve` wants it.
    ///
    /// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` answers with the
    /// frontmost window at that screen point **across every application**, which
    /// is the point: a window belonging to another app (or no window at all)
    /// gives a number this process does not own, `window(withWindowNumber:)`
    /// answers `nil`, and the location is `.outsideApp` — the case the menu
    /// shortcuts can reach and a scroll cannot. Hit-testing our own windows in
    /// z-order by hand would get the cross-application half wrong.
    static func pointerLocation(screenPoint: NSPoint = NSEvent.mouseLocation) -> ZoomPointerLocation {
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number) else { return .outsideApp }
        guard let content = window.contentView else { return .insideApp([]) }
        // Screen → window → the content view's own coordinates, so the recursive
        // walk below can convert once per step instead of per candidate.
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let contentPoint = content.convert(windowPoint, from: nil)
        return .insideApp(candidates(under: contentPoint, in: content, depth: 0))
    }

    /// Every conforming view containing `point`, with its depth below the
    /// window's content view (which is depth 0).
    ///
    /// Two rules, both load-bearing:
    ///
    /// - **A hidden view and its whole subtree are skipped.** The three bottom
    ///   panels and the terminal's inactive tabs stay in the hierarchy while
    ///   hidden, and a hidden terminal under the pointer would otherwise claim
    ///   every gesture aimed at whatever replaced it.
    /// - **`visibleRect`, not `bounds`.** It is the part of the view its
    ///   superviews have not clipped away, so a text view scrolled far past the
    ///   pointer — or one inside a collapsed split pane — contains the point in
    ///   its own coordinates yet is not under the pointer at all.
    ///
    /// Siblings are visited in `subviews` order, which is what
    /// `ZoomZone.resolve`'s documented tie-break means by "scan order".
    static func candidates(under point: NSPoint, in view: NSView, depth: Int) -> [ZoomSurfaceCandidate] {
        guard !view.isHidden else { return [] }
        var found: [ZoomSurfaceCandidate] = []
        if let surface = view as? ZoomSurfaceProviding, view.visibleRect.contains(point) {
            found.append(ZoomSurfaceCandidate(kind: surface.zoomSurfaceKind, depth: depth))
        }
        for subview in view.subviews {
            found += candidates(under: view.convert(point, to: subview), in: subview, depth: depth + 1)
        }
        return found
    }

    /// The surface the key window's focus is in, if any.
    ///
    /// Only consulted when the pointer is outside every window of ours, which
    /// only a menu shortcut can reach. Walked *up* the responder chain from the
    /// first responder, so a focused text view answers for itself and a focused
    /// subview of SwiftTerm's terminal answers for the terminal.
    static func focusedSurfaceKind() -> ZoomSurfaceKind? {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let surface = current as? ZoomSurfaceProviding { return surface.zoomSurfaceKind }
            responder = current.nextResponder
        }
        return nil
    }
}

#endif
