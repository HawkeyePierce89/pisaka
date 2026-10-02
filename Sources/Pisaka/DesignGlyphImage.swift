#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// The one way a design glyph reaches the screen.
///
/// Every surface drawing one of `DesignGlyph`'s template images goes through
/// this file: SwiftUI through `DesignGlyphImage`, AppKit through
/// `DesignGlyphDrawing.image(_:pointSize:tint:)`. No other macOS source loads a
/// glyph by name — `ChromeThemeSourceGatingTests` holds that — so the template
/// intent, the aspect rule and the accessibility rule are each stated once.
///
/// The glyph is a template, so it carries no colour of its own: the SwiftUI
/// view tints it with a role from the injected theme, and an AppKit caller hands
/// a tint it has resolved inside its own drawing appearance (rule 25's footing).
struct DesignGlyphImage: View {
    let glyph: DesignGlyph
    /// The drawn size in points at interface scale 1.0; the glyph's own
    /// `nativeSize` unless the surface names another.
    let size: Double
    /// The square the glyph is centred in, at interface scale 1.0.
    let slot: Double
    let role: ChromeColorRole

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    init(_ glyph: DesignGlyph, size: Double? = nil, slot: Double, role: ChromeColorRole) {
        self.glyph = glyph
        self.size = size ?? glyph.nativeSize
        self.slot = slot
        self.role = role
    }

    var body: some View {
        // Fitted, never stretched: the frame is square and `scaledToFit` keeps the
        // glyph's own aspect inside it. Hidden from accessibility because a
        // glyph is the control's picture, never its name — the control states
        // its name (and any state the glyph carried) itself.
        Image(glyph.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: metrics.pt(size), height: metrics.pt(size))
            .foregroundStyle(theme.color(role))
            .frame(width: metrics.pt(slot), height: metrics.pt(slot))
            .accessibilityHidden(true)
    }
}

/// The AppKit half: a design glyph as an `NSImage` an AppKit view draws itself.
enum DesignGlyphDrawing {
    /// `glyph` fitted into a `pointSize` square, filled with `tint`.
    ///
    /// The tint is filled at draw time over the template's coverage, so a
    /// caller passes a colour it has resolved inside the drawing appearance —
    /// from `draw(_:)` or a `performAsCurrentDrawingAppearance` body — and the
    /// image takes exactly that value. `nil` when the asset is missing, which
    /// `DesignGlyphAssetTests` makes a Core-gate failure rather than a run-time
    /// surprise.
    static func image(_ glyph: DesignGlyph, pointSize: CGFloat, tint: NSColor) -> NSImage? {
        guard let template = NSImage(named: glyph.assetName) else { return nil }
        let square = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: square, flipped: false) { bounds in
            template.draw(in: fittedRect(for: template.size, in: bounds))
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        image.accessibilityDescription = nil
        return image
    }

    /// The largest rect of `size`'s aspect centred in `bounds` — the AppKit
    /// spelling of `scaledToFit()`.
    static func fittedRect(for size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * factor, height: size.height * factor)
        return NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
#endif
