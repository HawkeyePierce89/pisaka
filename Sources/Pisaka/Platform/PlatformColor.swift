#if os(macOS)
import AppKit

/// The platform's concrete color class. On macOS this is `NSColor`; on iOS it is
/// `UIColor`. The view layer's color tables (syntax theme, diff backgrounds, the
/// minimap/graph palettes) build appearance-aware colors through this typealias so
/// the same construction code compiles on both platforms — `PisakaCore` stays
/// color-free (the `FileIconColor` precedent), and only this thin bridge knows the
/// concrete UIKit/AppKit type.
typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit

typealias PlatformColor = UIColor
#endif

#if os(macOS) || os(iOS)
import CoreGraphics

extension PlatformColor {
    /// Creates an opaque color from a `0xRRGGBB` integer literal. The component
    /// arithmetic is identical on both platforms; only the designated initializer
    /// differs (`srgbRed:` on AppKit, `red:` on UIKit — both sRGB).
    convenience init(rgb: UInt32) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        #if os(macOS)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        self.init(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    /// Builds a dynamic color that resolves to `light` or `dark` (each a
    /// `0xRRGGBB` literal) depending on the effective appearance at draw time, so a
    /// single table entry stays legible in both light and dark mode without a
    /// user-configurable theme. Opaque: the alpha-carrying form below is the
    /// primitive, and this is it at `alpha: 1`.
    static func dynamic(light: UInt32, dark: UInt32) -> PlatformColor {
        dynamic(light: light, dark: dark, alpha: 1)
    }

    /// The translucent form: the same appearance-aware resolution, with `alpha`
    /// applied to each *per-appearance variant* rather than to the dynamic color
    /// itself. That is the whole point of the second constructor — a dynamic color
    /// has no single component to read, so asking the finished color for a
    /// translucent copy resolves it against whatever appearance happens to be
    /// current and freezes it there; applying the alpha to the two concrete sRGB
    /// colors *before* the closure keeps the result dynamic. macOS resolves via the
    /// `NSColor(name:)` appearance closure (the original syntax-theme
    /// implementation, preserved byte-for-byte); iOS via `UIColor(dynamicProvider:)`
    /// keyed on `userInterfaceStyle`.
    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat) -> PlatformColor {
        let lightColor = PlatformColor(rgb: light).withAlphaComponent(alpha)
        let darkColor = PlatformColor(rgb: dark).withAlphaComponent(alpha)
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? darkColor : lightColor
        }
        #else
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
        #endif
    }
}
#endif
