import Foundation

/// Where the main window opens when no frame has ever been saved for it.
///
/// A first launch (or one after the saved frame was deleted) has no descriptor
/// to restore, and the scene's own default is a small window in a corner. This
/// rule answers instead: **75% of the screen's visible frame on each axis**,
/// raised to the window's minimum frame size, then capped to the visible frame,
/// and **centred** in it — the result keeps the visible frame's coordinate
/// space, so a screen whose visible origin is not zero (a Dock on the left, a
/// secondary display) is respected. Extents are whole points, rounded down, so
/// the frame never spills a fraction of a point past the visible frame.
///
/// A saved descriptor always wins — provided it is well formed
/// (`isRestorable(_:)`); a malformed one counts as missing. The app asks this
/// rule only on the missing-key path (`MainWindowFrameAutosave.swift`, pinned by
/// `MainWindowFrameSourceGatingTests`). A visible frame that is empty, negative
/// or non-finite has no answer (`nil`): the window keeps whatever frame the
/// scene gave it rather than collapsing to nothing.
public enum MainWindowInitialFrameRule {
    /// The share of the visible frame the window takes on each axis.
    public static let screenFraction = 0.75

    /// A rectangle in screen points, origin at its lower-left corner.
    public struct Rect: Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The first-launch frame for a window whose frame (not content) must be at
    /// least `minimumWidth` × `minimumHeight`, on a screen whose visible frame
    /// is `visible`.
    public static func frame(visible: Rect, minimumWidth: Double, minimumHeight: Double) -> Rect? {
        let values = [visible.x, visible.y, visible.width, visible.height]
        guard values.allSatisfy(\.isFinite), visible.width > 0, visible.height > 0 else { return nil }
        let width = extent(of: visible.width, minimum: minimumWidth)
        let height = extent(of: visible.height, minimum: minimumHeight)
        return Rect(
            x: visible.x + ((visible.width - width) / 2).rounded(.down),
            y: visible.y + ((visible.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
    }

    /// Whether a saved frame descriptor has a shape `setFrame(from:)` applies:
    /// whitespace-separated finite numbers, **exactly four** (the frame alone)
    /// or **exactly eight** (the frame and the screen's, which is what
    /// `NSWindow.frameDescriptor` writes), the frame's width and height
    /// positive and — with eight — the screen's too. AppKit leaves the window
    /// untouched for any other count (five, six, seven) and for a screen with
    /// no area, and `setFrame(from:)` reports nothing, so such a value would
    /// otherwise silently keep the scene's small default; the app treats one
    /// this refuses exactly as a missing key. Nine or more fields, which
    /// AppKit would read past, are refused too: no writer produces them.
    public static func isRestorable(_ descriptor: String) -> Bool {
        let fields = descriptor.split(whereSeparator: \.isWhitespace)
        let numbers = fields.compactMap { Double($0) }
        guard numbers.count == fields.count, numbers.count == 4 || numbers.count == 8,
              numbers.allSatisfy(\.isFinite) else { return false }
        let sizes = numbers.count == 8 ? [numbers[2], numbers[3], numbers[6], numbers[7]] : [numbers[2], numbers[3]]
        return sizes.allSatisfy { $0 > 0 }
    }

    private static func extent(of available: Double, minimum: Double) -> Double {
        let share = (available * screenFraction).rounded(.down)
        let raised = minimum.isFinite ? max(share, minimum.rounded(.up)) : share
        return min(raised, available.rounded(.down))
    }
}
