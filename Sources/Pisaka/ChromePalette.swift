#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// The one place a chrome colour is spelled.
///
/// `ChromeColorRole` names a meaning and carries no colour; this table turns a
/// meaning into the two concrete values the chrome is drawn from — a dark one
/// and a light one — and nothing else in the gated chrome may spell a hex
/// literal at all (`ChromeThemeSourceGatingTests` pins that, with this file as
/// its single, deliberately narrow exemption).
///
/// **The `switch` below is exhaustive on purpose — there is no `default`.** A
/// twenty-second role added to Core without a pair here is a *compile* error
/// rather than a colour that silently falls back to something plausible; a pair
/// spelled wrongly is caught instead by `ChromePaletteTests`, which asserts every
/// role's two values component by component.
enum ChromePalette {

    /// One row of the table: the two sRGB values a role resolves to, and the
    /// alpha both of them are drawn at.
    ///
    /// A single alpha rather than one per appearance, because the roles that are
    /// translucent are *washes* — a tint is the same wash over either background,
    /// and two alphas would be two opinions about the same design decision.
    ///
    /// The alpha is a `UInt8`, the byte the design's own eight-digit values carry
    /// in their last position, so this table spells the design's numbers verbatim
    /// rather than a rounded fraction of them; every accessor divides by 255 at
    /// the moment it builds a colour.
    struct Entry: Equatable {
        /// The value used when the chrome is drawn dark.
        let dark: UInt32
        /// The value used when the chrome is drawn light.
        let light: UInt32
        /// The opacity both variants are drawn at; `0xFF` for everything opaque.
        let alpha: UInt8

        init(dark: UInt32, light: UInt32, alpha: UInt8 = 0xFF) {
            self.dark = dark
            self.light = light
            self.alpha = alpha
        }

        /// The alpha as the fraction a drawing API wants.
        var opacity: CGFloat { CGFloat(alpha) / 255 }
    }

    /// The table. Every role, no `default`.
    static func entry(for role: ChromeColorRole) -> Entry {
        switch role {
        // Backgrounds.
        case .bgCanvas: return Entry(dark: 0x1E1F22, light: 0xF5F5F7)
        case .bgPanel: return Entry(dark: 0x2B2D30, light: 0xECECEF)
        case .bgEditor: return Entry(dark: 0x2F3136, light: 0xFFFFFF)
        case .bgPopover: return Entry(dark: 0x36383D, light: 0xFFFFFF)

        // Text.
        case .textPrimary: return Entry(dark: 0xDFE1E5, light: 0x1D1D1F)
        case .textSecondary: return Entry(dark: 0xA0A3AA, light: 0x6E6E73)
        case .onAccent: return Entry(dark: 0xFFFFFF, light: 0xFFFFFF)

        // Lines and accent.
        case .hairline: return Entry(dark: 0x393B40, light: 0xD1D1D6)
        case .accent: return Entry(dark: 0x4F8DFF, light: 0x2F6FE0)
        case .accentTint: return Entry(dark: 0x4F8DFF, light: 0x2F6FE0, alpha: 0x22)
        case .accentTintStrong: return Entry(dark: 0x4F8DFF, light: 0x2F6FE0, alpha: 0x33)

        // Row and line states.
        case .hoverTint: return Entry(dark: 0xFFFFFF, light: 0x000000, alpha: 0x0A)
        case .selectionInactive: return Entry(dark: 0x34363B, light: 0xF0F0F2)
        case .currentLine: return Entry(dark: 0x34363B, light: 0xF0F0F2)
        case .bracketMatch: return Entry(dark: 0x3D4A5C, light: 0xDBE6F5)

        // Status.
        case .statusGreen: return Entry(dark: 0x7A9D6E, light: 0x4F8A3D)
        case .statusRed: return Entry(dark: 0xC4746B, light: 0xC1483D)
        case .statusYellow: return Entry(dark: 0xC9A35C, light: 0xA67C2E)

        // Diff and merge.
        case .diffAddedBackground: return Entry(dark: 0x7A9D6E, light: 0x4F8A3D, alpha: 0x22)
        case .diffRemovedBackground: return Entry(dark: 0xC4746B, light: 0xC1483D, alpha: 0x22)
        case .conflictBackground: return Entry(dark: 0xC9A35C, light: 0xA67C2E, alpha: 0x26)
        }
    }

    // MARK: - The AppKit path

    /// A role as a **dynamic** `NSColor`, built on the
    /// `PlatformColor.dynamic(light:dark:alpha:)` primitive already in the tree
    /// (the syntax theme's own colours are built the same way) — so AppKit
    /// resolves the value itself, per appearance, at draw time.
    ///
    /// That is why **no AppKit view in the chrome caches a resolved colour and
    /// none watches for a *colour* change by hand.** The Theme preference is
    /// applied as `.preferredColorScheme` at each SwiftUI window root, which sets
    /// that window's `NSAppearance`; every `NSView` inside the window inherits it,
    /// and a dynamic colour asked to draw under the new appearance answers the new
    /// value. A view that resolved a colour once into a stored property would
    /// freeze whichever appearance happened to be current when it did, and would
    /// then need an observer to un-freeze it — two mechanisms where the platform
    /// already provides one.
    ///
    /// **That is a rule about the value, not about the drawing.** A dynamic colour
    /// resolves whenever the drawing happens, so a chrome view asking for one
    /// every time it paints needs no cached value and no colour-specific
    /// observer. The surfaces differ only in what they hand AppKit: the editor
    /// pane and the read-only viewer pane set a `backgroundColor`; the gutter
    /// (an `NSRulerView`, which has none to set) and the minimap fill their own
    /// background while drawing. The gutter overrides
    /// `viewDidChangeEffectiveAppearance()` nowhere and was measured recolouring
    /// live in both directions when the system appearance changed under the
    /// running window. `MinimapView` does carry such an override; whether it is
    /// required or redundant there was not established, it predates the chrome
    /// sweep, and it stays until something measures it.
    static func nsColor(_ role: ChromeColorRole) -> NSColor {
        let entry = entry(for: role)
        return PlatformColor.dynamic(light: entry.light, dark: entry.dark, alpha: entry.opacity)
    }

    /// A role as the **concrete** `NSColor` of one appearance.
    ///
    /// For the sites that are not drawing — the palette test, which has to read
    /// the components of each side — and for an AppKit view that has already been
    /// handed an appearance to resolve against. Drawing code asks `nsColor(_:)`.
    static func nsColor(_ role: ChromeColorRole, in appearance: ChromeAppearance) -> NSColor {
        let entry = entry(for: role)
        let rgb = appearance == .dark ? entry.dark : entry.light
        return NSColor(rgb: rgb).withAlphaComponent(entry.opacity)
    }

    // MARK: - The SwiftUI path

    /// A role as a SwiftUI `Color` in one appearance, composed from the same row
    /// as the two `NSColor` forms above rather than converted from one of them.
    static func color(_ role: ChromeColorRole, in appearance: ChromeAppearance) -> Color {
        let entry = entry(for: role)
        let rgb = appearance == .dark ? entry.dark : entry.light
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: Double(entry.opacity)
        )
    }
}

/// The chrome's colours for one view tree, as SwiftUI reads them.
///
/// Carries the **resolved** `ChromeAppearance` rather than a dynamic colour, and
/// that is the whole reason a Theme change recolours the chrome live: the value
/// is `Equatable`, so flipping the preference changes the environment value,
/// which invalidates every view that declared `@Environment(\.chromeTheme)`. A
/// theme holding dynamic colours would compare equal across the change and
/// nothing below it would redraw.
struct ChromeTheme: Equatable {
    /// Which of the palette's two value sets this tree draws from.
    let appearance: ChromeAppearance

    init(_ appearance: ChromeAppearance) {
        self.appearance = appearance
    }

    /// The colour this role takes in this theme.
    func color(_ role: ChromeColorRole) -> Color {
        ChromePalette.color(role, in: appearance)
    }
}

#endif
