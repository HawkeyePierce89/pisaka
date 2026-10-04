import CoreGraphics

/// Where the bottom-bar popover goes: its leading edge, its bottom edge and the
/// height left for it to grow into.
public struct PopoverAnchoring: Equatable {
    /// The popover's leading x.
    public let x: CGFloat
    /// The popover's bottom y — the edge it grows upward from.
    public let bottom: CGFloat
    /// The tallest the popover may be: its cap, or less when the window is
    /// short. Never negative.
    public let availableHeight: CGFloat

    public init(x: CGFloat, bottom: CGFloat, availableHeight: CGFloat) {
        self.x = x
        self.bottom = bottom
        self.availableHeight = availableHeight
    }
}

/// The arithmetic that places the bottom-bar popover and its submenu inside
/// the window.
///
/// **Coordinates are the window root's top-left, y-down space** — the space a
/// SwiftUI named coordinate space at the window root reports — so "up" is a
/// smaller y, a frame's `minY` is its top and `maxY` its bottom. Every input
/// and every answer is in that one space; no screen coordinate is involved,
/// because the popover is drawn inside the window and moves with it.
///
/// Pure and Foundation-only: the app layer measures the frames and positions
/// the views, and every decision about where they go is made here.
public enum PopoverPlacement {
    /// The popover opens **upward** from the bar, left-aligned to its widget.
    ///
    /// - The leading x is the widget's `minX`; when the widget sits nearer the
    ///   window's right edge than `width`, the popover shifts left so its right
    ///   edge is the window's, and it never goes past the window's left edge
    ///   (a window narrower than the popover pins it there).
    /// - The bottom is `gap` above the bar's top edge.
    /// - The available height is `maxHeight`, or the room between that bottom
    ///   and the window's top when that is less, and never negative. A short
    ///   window therefore caps the container and the List shrinks; the popover
    ///   never draws outside the window.
    public static func popover(
        widget: CGRect,
        barTop: CGFloat,
        window: CGRect,
        width: CGFloat,
        maxHeight: CGFloat,
        gap: CGFloat
    ) -> PopoverAnchoring {
        var x = widget.minX
        if x + width > window.maxX {
            x = window.maxX - width
        }
        x = max(x, window.minX)
        let bottom = barTop - gap
        let available = max(0, min(maxHeight, bottom - window.minY))
        return PopoverAnchoring(x: x, bottom: bottom, availableHeight: available)
    }

    /// The submenu's frame: `gap` to the right of the popover with its top at
    /// the anchor row's top, flipped to `gap` on the popover's left when it
    /// does not fit on the right, then clamped inside the window on both axes —
    /// shifted up when its bottom would pass the window's bottom, and never
    /// above the window's top.
    public static func submenu(
        popover: CGRect,
        anchorRowTop: CGFloat,
        size: CGSize,
        window: CGRect,
        gap: CGFloat
    ) -> CGRect {
        var x = popover.maxX + gap
        if x + size.width > window.maxX {
            x = popover.minX - gap - size.width
        }
        x = max(min(x, window.maxX - size.width), window.minX)
        var y = anchorRowTop
        if y + size.height > window.maxY {
            y = window.maxY - size.height
        }
        y = max(y, window.minY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
