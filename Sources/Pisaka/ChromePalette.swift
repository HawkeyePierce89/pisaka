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
/// twenty-third role added to Core without a pair here is a *compile* error
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
    struct Entry: Equatable {
        /// The value used when the chrome is drawn dark.
        let dark: UInt32
        /// The value used when the chrome is drawn light.
        let light: UInt32
        /// The opacity both variants are drawn at; `1` for everything opaque.
        let alpha: CGFloat
    }

    /// The table. Every role, no `default`.
    static func entry(for role: ChromeColorRole) -> Entry {
        switch role {
        // Backgrounds.
        case .bgEditor: return Entry(dark: 0x1F1F24, light: 0xFFFFFF, alpha: 1)
        case .bgPanel: return Entry(dark: 0x26262C, light: 0xF2F2F4, alpha: 1)
        case .bgSidebar: return Entry(dark: 0x232329, light: 0xECECEF, alpha: 1)
        case .bgBar: return Entry(dark: 0x2A2A31, light: 0xF7F7F9, alpha: 1)
        case .bgPopover: return Entry(dark: 0x2E2E36, light: 0xFDFDFE, alpha: 1)

        // Text.
        case .textPrimary: return Entry(dark: 0xE8E8ED, light: 0x1D1D1F, alpha: 1)
        case .textSecondary: return Entry(dark: 0x9B9BA5, light: 0x6B6B73, alpha: 1)
        case .textTertiary: return Entry(dark: 0x6E6E78, light: 0x9A9AA2, alpha: 1)

        // Lines and accent.
        case .hairline: return Entry(dark: 0x3A3A42, light: 0xD8D8DC, alpha: 1)
        case .accent: return Entry(dark: 0x4A9EFF, light: 0x1B6BCC, alpha: 1)
        case .accentTint: return Entry(dark: 0x4A9EFF, light: 0x1B6BCC, alpha: 0.12)
        case .accentTintStrong: return Entry(dark: 0x4A9EFF, light: 0x1B6BCC, alpha: 0.25)

        // Row states.
        case .hoverTint: return Entry(dark: 0xFFFFFF, light: 0x000000, alpha: 0.07)
        case .selectionInactive: return Entry(dark: 0xFFFFFF, light: 0x000000, alpha: 0.12)
        case .dropTint: return Entry(dark: 0x4A9EFF, light: 0x1B6BCC, alpha: 0.40)

        // Status.
        case .statusRed: return Entry(dark: 0xFF7B85, light: 0xC01C5A, alpha: 1)
        case .statusYellow: return Entry(dark: 0xE2B03C, light: 0xA05E00, alpha: 1)
        case .statusGreen: return Entry(dark: 0x7EE787, light: 0x1E7A33, alpha: 1)
        case .statusBlue: return Entry(dark: 0x79B8DA, light: 0x45718B, alpha: 1)

        // Diff and merge.
        case .diffAddedBackground: return Entry(dark: 0x7EE787, light: 0x1E7A33, alpha: 0.16)
        case .diffRemovedBackground: return Entry(dark: 0xFF7B85, light: 0xC01C5A, alpha: 0.16)
        case .conflictBackground: return Entry(dark: 0xE2B03C, light: 0xA05E00, alpha: 0.18)
        }
    }

    // MARK: - The AppKit path

    /// A role as a **dynamic** `NSColor`, built on the
    /// `PlatformColor.dynamic(light:dark:alpha:)` primitive already in the tree
    /// (the syntax theme's own colours are built the same way) — so AppKit
    /// resolves the value itself, per appearance, at draw time.
    ///
    /// That is why **no AppKit view in the chrome caches a resolved colour and
    /// none observes an appearance change by hand.** The Theme preference is
    /// applied as `.preferredColorScheme` at each SwiftUI window root, which sets
    /// that window's `NSAppearance`; every `NSView` inside the window inherits it,
    /// and a dynamic colour asked to draw under the new appearance answers the new
    /// value. A view that resolved a colour once into a stored property would
    /// freeze whichever appearance happened to be current when it did, and would
    /// then need an observer to un-freeze it — two mechanisms where the platform
    /// already provides one.
    static func nsColor(_ role: ChromeColorRole) -> NSColor {
        let entry = entry(for: role)
        return PlatformColor.dynamic(light: entry.light, dark: entry.dark, alpha: entry.alpha)
    }

    /// A role as the **concrete** `NSColor` of one appearance.
    ///
    /// For the sites that are not drawing — the palette test, which has to read
    /// the components of each side — and for an AppKit view that has already been
    /// handed an appearance to resolve against. Drawing code asks `nsColor(_:)`.
    static func nsColor(_ role: ChromeColorRole, in appearance: ChromeAppearance) -> NSColor {
        let entry = entry(for: role)
        let rgb = appearance == .dark ? entry.dark : entry.light
        return NSColor(rgb: rgb).withAlphaComponent(entry.alpha)
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
            opacity: Double(entry.alpha)
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
