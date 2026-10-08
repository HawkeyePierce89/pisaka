#if os(macOS)
import AppKit
import PisakaCore
import SwiftTerm

/// The embedded terminal's single built-in light/dark color table.
///
/// SwiftTerm 1.5.0 starts every view from its own hardcoded defaults (black
/// background, `#8A8A8A` text) and never reacts to the appearance, so the
/// terminal stayed dark in a light app. This type applies one theme to a live
/// `TerminalView`: a built-in (not user-configurable) table that lives in the
/// view layer so `PisakaCore` stays color-free.
///
/// Only the two ANSI-16 arrays are spelled here — they are the terminal's own
/// vocabulary, a protocol's numbering rather than chrome. The four colors around
/// them are chrome and are read from `ChromePalette` as roles: the ground is
/// `bgPanel` — the role the dock slot paints, so the terminal and the inset
/// `TerminalPanelView` draws around it read as one surface — the default text
/// `textPrimary`, the caret `accent` and the selection `accentTintStrong`. None
/// of them follows the system accent.
///
/// Unlike the rest of the AppKit chrome, which hands dynamic `NSColor`s to AppKit
/// and lets it resolve them at draw time, the colors are resolved *at apply time*
/// through `ChromePalette.nsColor(_:in:)`: SwiftTerm stores its own
/// `SwiftTerm.Color` structs (and plain `NSColor`s for the caret and the
/// selection) and never re-resolves them, so the caller passes the appearance to
/// resolve under and re-applies on every appearance change.
///
/// The ANSI-16 palette is part of the theme rather than a follow-up: SwiftTerm's
/// sixteen defaults are tuned for its black background and several of them are
/// unreadable on a light one (bright white `#E5E5E5` is 1.26:1 on white, bright
/// yellow 1.35:1, bright cyan 1.57:1, ANSI 7 `#BFBFBF` 1.84:1 — and since
/// `useBrightColors` defaults to `true`, *bold* text on colors 0–6 is remapped
/// onto those brights, so ordinary prompt/`ls`/`npm` output would vanish).
/// SwiftTerm's set fails the other way too: on the dark `bgPanel` ground eight of
/// its entries fall below 4.5:1. So each appearance installs a fixed set of its
/// own — the dark theme SwiftTerm's hues with nine entries brightened, the light
/// theme a darkened set. What stays out of scope is a *user-configurable* palette.
enum TerminalTheme {
    /// The chrome appearance a hosting `NSAppearance` resolves the four roles
    /// under, matched against the two base appearances so a high-contrast or
    /// accessibility variant still resolves to light/dark.
    static func chromeAppearance(for appearance: NSAppearance) -> ChromeAppearance {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The ANSI-16 set that goes with a chrome appearance.
    static func ansiColors(for appearance: ChromeAppearance) -> [SwiftTerm.Color] {
        appearance == .dark ? darkANSIColors : lightANSIColors
    }

    /// An 8-bit-per-channel color as a `SwiftTerm.Color`. SwiftTerm's own
    /// `init(red8:green8:blue8:)` is module-internal, so we reproduce its ×257
    /// mapping onto the public 16-bit initializer (0xFF × 257 == 65535).
    private static func rgb8(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    /// The dark theme's ANSI-16: SwiftTerm's `Color.defaultInstalledColors` hues,
    /// with nine entries brightened so every one but black clears at least 4.5:1
    /// against the terminal's actual ground, `bgPanel`'s dark `0x2B2D30`.
    /// SwiftTerm's own set is tuned for black and, on that ground, sinks to 1.08:1
    /// (ANSI 4) — eight of its entries fell below the floor and ANSI 3 sat on it.
    /// Each brightened entry keeps SwiftTerm's hue angle (red 0°, green ≈121°,
    /// yellow 60°, blue 240°, magenta 300°, ANSI 8's faint 300° grey tint) and
    /// only gains lightness, and every bright entry stays brighter than its
    /// normal partner. ANSI 0, 6, 7, 10, 11, 14 and 15 already cleared and are
    /// SwiftTerm's values verbatim; ANSI 0's exact black is the one stated
    /// exception to the floor. Installing is unconditional, so switching dark →
    /// light → dark must restore exactly these — which needs a *fixed* set, not
    /// SwiftTerm's.
    static let darkANSIColors: [SwiftTerm.Color] = [
        rgb8(0x00, 0x00, 0x00),
        rgb8(0xFF, 0x6B, 0x6B),
        rgb8(0x00, 0xB8, 0x03),
        rgb8(0xA0, 0xA0, 0x00),
        rgb8(0x93, 0x93, 0xFF),
        rgb8(0xE0, 0x70, 0xE0),
        rgb8(0x00, 0xA5, 0xB2),
        rgb8(0xBF, 0xBF, 0xBF),
        rgb8(0x9E, 0x9D, 0x9E),
        rgb8(0xFF, 0x8C, 0x8C),
        rgb8(0x00, 0xD8, 0x00),
        rgb8(0xE5, 0xE5, 0x00),
        rgb8(0xAA, 0xAA, 0xFF),
        rgb8(0xFF, 0x8C, 0xFF),
        rgb8(0x00, 0xE5, 0xE5),
        rgb8(0xE5, 0xE5, 0xE5),
    ]

    /// The light theme's ANSI-16, darkened so every entry clears at least 4.5:1
    /// against the light ground, `bgPanel`'s `0xECECEF` (SwiftTerm's own brights
    /// sit at 1.3–1.9:1 on a light ground). "Bright" reads as *more saturated*
    /// rather than lighter, which is the only direction that stays legible on a
    /// light background.
    static let lightANSIColors: [SwiftTerm.Color] = [
        rgb8(0x00, 0x00, 0x00),
        rgb8(0xB0, 0x1B, 0x1B),
        rgb8(0x0B, 0x7A, 0x28),
        rgb8(0x8A, 0x61, 0x00),
        rgb8(0x1E, 0x4F, 0xBF),
        rgb8(0x9A, 0x22, 0xA8),
        rgb8(0x00, 0x70, 0x7F),
        rgb8(0x4D, 0x4D, 0x4D),
        rgb8(0x6A, 0x6A, 0x6A),
        rgb8(0xC7, 0x30, 0x1E),
        rgb8(0x1F, 0x7A, 0x33),
        rgb8(0x8A, 0x64, 0x00),
        rgb8(0x2E, 0x5F, 0xD0),
        rgb8(0xA6, 0x3A, 0xB3),
        rgb8(0x00, 0x75, 0x83),
        rgb8(0x1E, 0x1E, 0x1E),
    ]

    /// A fingerprint of everything `apply(to:appearance:)` would install for an
    /// appearance: the four resolved colors as 16-bit sRGB components, in the order
    /// ground, text, caret, selection.
    ///
    /// This is the key `TerminalSession` compares to decide whether a re-apply is
    /// needed. The ground differs between the two appearances, so it also encodes
    /// the ANSI-16 set that goes with it — the key covers the whole apply.
    ///
    /// Comparing resolved *components* rather than the `NSColor`s themselves keeps
    /// the guard deterministic: a false negative here would silently reinstate the
    /// per-tab-switch color reset the guard exists to prevent.
    struct ThemeKey: Equatable {
        let colors: [UInt16]
    }

    /// The `ThemeKey` for `appearance` — resolved through the same appearance
    /// match and the same roles `apply(to:appearance:)` uses.
    static func key(for appearance: NSAppearance) -> ThemeKey {
        let colors = resolvedColors(in: chromeAppearance(for: appearance))
        return ThemeKey(
            colors: [colors.background, colors.foreground, colors.caret, colors.selection]
                .flatMap(components(of:))
        )
    }

    /// Recolors a live terminal view for `appearance`, leaving its shell,
    /// scrollback and selection state untouched.
    ///
    /// This is a full *reset* of the color state — including the ANSI-16 palette and
    /// the default fore/background — so it also discards whatever the terminal itself
    /// set through OSC 4/10/11/12. That is correct for an actual theme change, which
    /// is why the caller (`TerminalSession.applyTheme(for:)`) is the one that skips a
    /// re-apply for an unchanged `ThemeKey` rather than calling in unconditionally.
    static func apply(to view: TerminalView, appearance: NSAppearance) {
        let chrome = chromeAppearance(for: appearance)
        let colors = resolvedColors(in: chrome)
        let background = colors.background
        let foreground = colors.foreground

        // Go through the public `set*Color(source:color:)` pair rather than
        // writing `nativeBackgroundColor`/`nativeForegroundColor` directly: on
        // macOS those setters only push the value into the terminal engine,
        // while these also call SwiftTerm's internal `colorsChanged()`, which
        // clears the cached text attributes and forces a full repaint. Without
        // that, a live theme change would leave every already-drawn cell in the
        // old colors. (`source:` is unused by the implementation; the view's own
        // terminal is the honest thing to pass.)
        let terminal = view.getTerminal()
        // `installColors` also resets the cached attributes and repaints, so the
        // ANSI palette goes in through the same public surface as the two default
        // colors. Unconditional in both directions: each appearance reinstalls its
        // own fixed set, so switching back restores exactly the same sixteen.
        view.installColors(ansiColors(for: chrome))
        view.setBackgroundColor(source: terminal, color: terminalColor(background))
        view.setForegroundColor(source: terminal, color: terminalColor(foreground))

        view.caretColor = colors.caret
        // Text under a block cursor is drawn in the ground color, which keeps it
        // readable against the caret. This only works because the caret is the
        // saturated `accent` rather than the pale `accentTintStrong` wash the
        // selection uses — against the wash a ground-colored glyph would vanish,
        // and the caret and a selected region would be indistinguishable.
        view.caretTextColor = background
        view.selectedTextBackgroundColor = colors.selection

        // SwiftTerm assigns the layer background only once, in `setupOptions()`,
        // so a later palette change has to update it or the view keeps painting
        // its uncovered areas in the old background.
        view.layer?.backgroundColor = background.cgColor
    }

    /// The four chrome roles, resolved concretely for `appearance`. Shared by
    /// `apply(to:appearance:)` and `key(for:)` so the guard can never judge a
    /// different set of colors than the one applied.
    private static func resolvedColors(
        in appearance: ChromeAppearance
    ) -> (background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor) {
        (
            background: ChromePalette.nsColor(.bgPanel, in: appearance),
            foreground: ChromePalette.nsColor(.textPrimary, in: appearance),
            caret: ChromePalette.nsColor(.accent, in: appearance),
            selection: ChromePalette.nsColor(.accentTintStrong, in: appearance)
        )
    }

    /// `NSColor` → `SwiftTerm.Color` (16-bit components). SwiftTerm's own
    /// `NSColor.getTerminalColor()` is module-internal, so we convert ourselves.
    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let rgba = components(of: color)
        return SwiftTerm.Color(red: rgba[0], green: rgba[1], blue: rgba[2])
    }

    /// A color's sRGB components on SwiftTerm's 16-bit scale, `[r, g, b, a]` —
    /// the conversion behind both `terminalColor(_:)` (which drops the alpha the
    /// terminal has no use for) and `key(for:)` (which keeps it, since the
    /// selection tint is translucent).
    private static func components(of color: NSColor) -> [UInt16] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [component(red), component(green), component(blue), component(alpha)]
    }

    /// A 0…1 component to SwiftTerm's 16-bit scale.
    ///
    /// The range is clamped because an extended-range color space can report
    /// values outside 0…1, which would trap the `UInt16` conversion. The NaN
    /// branch is separate rather than folded into the clamp: `min`/`max`
    /// *propagate* NaN (`max(.nan, 0)` is `.nan`), so a clamp alone would still
    /// trap. Rounding rather than truncating keeps an 8-bit palette value on the
    /// exact ×257 point of the 16-bit scale.
    private static func component(_ value: CGFloat) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(max(value, 0), 1) * 65535).rounded())
    }
}

#endif
