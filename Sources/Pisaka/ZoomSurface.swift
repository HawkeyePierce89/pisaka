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
/// merge panes, the source viewer), by `CodeScrollView`, the scroll view each of
/// them is the document of, by the three views that draw *beside* them and are
/// therefore unreachable through them — `LineNumberRulerView` and
/// `DiffGutterView` (a scroll view's ruler is a sibling of its text view) and
/// `MinimapView` (a sibling of the editor's scroll view) — by SwiftTerm's
/// terminal view, and by `ZoomSurfaceMarkerView`, the AppKit half of the marker
/// the SwiftUI-drawn code surfaces use. Nothing declares `.interface`: chrome is
/// what is left when no surface was hit, which is why `ZoomSurfaceKind` has no
/// case for it.
///
/// Two things are easy to get wrong here, and both have already gone wrong:
///
/// - **The sibling rule.** A view that *looks* like part of the editor but sits
///   next to its text view produces no candidate at all, so the pointer over it
///   resolves to `.interface` and the gesture resizes the whole application
///   chrome. Anything drawn at the code font needs its own conformance.
/// - **The empty-region rule.** A conforming view answers only for the area it
///   actually covers, which for a content-sized text view is the text and not the
///   pane — see `CodeScrollView`.
///
/// And one rule that reads like an exception and is not: **unreachable ≡ chrome.**
/// A view the pointer can never actually be *over* is not a surface however it is
/// drawn. The hover popover (`HoverPanel`) draws a type signature at the code
/// font directly on top of the editor and declares nothing, because it sets
/// `ignoresMouseEvents = true`: a gesture aimed at where it appears to be is a
/// gesture over the text view underneath, which is the zone the user means. The
/// sibling rule above is about views the pointer *can* reach; this is what bounds
/// it. `ZoomSourceGatingTests` pins both halves — that the panel passes events
/// through, and that it declares no surface.
@MainActor
protocol ZoomSurfaceProviding: AnyObject {
    var zoomSurfaceKind: ZoomSurfaceKind { get }
}

/// The scroll view of a code pane, declaring the *whole pane* a code surface.
///
/// The four code text views are content-sized: each is configured with
/// `minSize = .zero`, `autoresizingMask = []`, both resizable flags set and an
/// unbounded text container, so its frame is the laid-out text's own size — not
/// the clip view's. (`CodeEditorView` already depends on this, clamping its
/// scroll offset with `max(0, textView.frame.height - clipView.bounds.height)`.)
/// The pointer below the last line of a short file, or right of the longest line
/// of a narrow one — the ordinary case, not a corner — is therefore over the
/// pane but over *no* conforming view, so `ZoomZone.resolve` answered
/// `.interface` and ⌘=/⌘0/a ⌘-scroll aimed at the code resized the whole chrome.
///
/// Conforming the scroll view fixes that without touching the deepest-candidate
/// rule: it is a strictly shallower candidate than its document view and its
/// ruler, so wherever one of those is hit it still wins, and both name the same
/// zone anyway. Nothing but a code pane uses this subclass — an
/// `extension NSScrollView` would have made the project tree and every settings
/// list a code surface too.
@MainActor
final class CodeScrollView: NSScrollView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code
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
    /// - **`bounds` intersected with `visibleRect`, not either alone.**
    ///   `visibleRect` is the part the superviews have not clipped away, so a
    ///   text view scrolled far past the pointer — or one inside a collapsed
    ///   split pane — contains the point in its own `bounds` yet is not under
    ///   the pointer at all. The intersection is not redundant: AppKit returns
    ///   that region in the receiver's coordinates *without* intersecting the
    ///   receiver's own rectangle, so a view whose superviews clip nothing gets
    ///   back the whole content area (a 50×50 view in a 400×400 window measures
    ///   `visibleRect (-100, -100, 400, 432)`). Unintersected, every unclipped
    ///   surface — the terminal, the minimap, the rulers — would claim every
    ///   pointer location, and `ZoomZone.resolve`'s deepest-candidate rule would
    ///   then pick whichever surface sits deepest in the view tree rather than
    ///   the one under the pointer.
    ///
    /// Siblings are visited in `subviews` order, which is what
    /// `ZoomZone.resolve`'s documented tie-break means by "scan order".
    static func candidates(under point: NSPoint, in view: NSView, depth: Int) -> [ZoomSurfaceCandidate] {
        guard !view.isHidden else { return [] }
        var found: [ZoomSurfaceCandidate] = []
        if let surface = view as? ZoomSurfaceProviding,
           view.bounds.intersection(view.visibleRect).contains(point) {
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
