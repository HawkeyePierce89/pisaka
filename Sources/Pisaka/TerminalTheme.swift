#if os(macOS)
import AppKit
import SwiftTerm

/// The embedded terminal's single built-in light/dark color table.
///
/// SwiftTerm 1.5.0 starts every view from its own hardcoded defaults (black
/// background, `#8A8A8A` text) and never reacts to the appearance, so the
/// terminal stayed dark in a light app. This type holds the two palettes and
/// applies one to a live `TerminalView`, mirroring `SyntaxTheme`: a built-in
/// (not user-configurable) table that lives in the view layer so `PisakaCore`
/// stays color-free.
///
/// Unlike `SyntaxTheme`, which hands dynamic `NSColor`s to AppKit and lets it
/// resolve them at draw time, the palette is resolved *at apply time*: SwiftTerm
/// stores its own `SwiftTerm.Color` structs (and plain `NSColor`s for the caret
/// and the selection) and never re-resolves them, so the caller passes the
/// appearance to resolve under.
///
/// The ANSI-16 palette is part of the theme rather than a follow-up: SwiftTerm's
/// sixteen defaults are tuned for its black background and several of them are
/// unreadable on a white one (bright white `#E5E5E5` is 1.26:1, bright yellow
/// 1.35:1, bright cyan 1.57:1, ANSI 7 `#BFBFBF` 1.84:1 — and since
/// `useBrightColors` defaults to `true`, *bold* text on colors 0–6 is remapped
/// onto those brights, so ordinary prompt/`ls`/`npm` output would vanish). The
/// dark theme keeps SwiftTerm's values verbatim; the light theme installs a
/// darkened set. What stays out of scope is a *user-configurable* palette.
enum TerminalTheme {
    /// The colors one theme needs. The four `NSColor`s may be dynamic system
    /// colors; `apply(to:appearance:)` resolves them under the target appearance.
    /// `ansi` is the 16-entry ANSI palette, already in SwiftTerm's own color type
    /// (these are fixed terminal colors, never appearance-dependent).
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let caret: NSColor
        let selection: NSColor
        let ansi: [SwiftTerm.Color]
    }

    /// White background with near-black text, matching a light `NSTextView`.
    static let light = Palette(
        background: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        foreground: NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1.0),
        caret: .selectedContentBackgroundColor,
        selection: .selectedTextBackgroundColor,
        ansi: lightANSIColors
    )

    /// SwiftTerm's own defaults — black background and its exact
    /// `Color.defaultForeground` (35389/65535 per channel, i.e. `#8A8A8A`
    /// rounded to 8 bits) — so the dark theme looks exactly as the terminal did
    /// before this feature.
    static let dark = Palette(
        background: NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
        foreground: NSColor(srgbRed: 35389 / 65535.0, green: 35389 / 65535.0, blue: 35389 / 65535.0, alpha: 1.0),
        caret: .selectedContentBackgroundColor,
        selection: .selectedTextBackgroundColor,
        ansi: darkANSIColors
    )

    /// An 8-bit-per-channel color as a `SwiftTerm.Color`. SwiftTerm's own
    /// `init(red8:green8:blue8:)` is module-internal, so we reproduce its ×257
    /// mapping onto the public 16-bit initializer (0xFF × 257 == 65535).
    private static func rgb8(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    /// SwiftTerm's `Color.defaultInstalledColors`, spelled out here so the dark
    /// theme reinstalls exactly what the view started with (installing is
    /// unconditional, so switching dark → light → dark must restore them).
    private static let darkANSIColors: [SwiftTerm.Color] = [
        rgb8(0, 0, 0),
        rgb8(153, 0, 1),
        rgb8(0, 166, 3),
        rgb8(153, 153, 0),
        rgb8(3, 0, 178),
        rgb8(178, 0, 178),
        rgb8(0, 165, 178),
        rgb8(191, 191, 191),
        rgb8(138, 137, 138),
        rgb8(229, 0, 1),
        rgb8(0, 216, 0),
        rgb8(229, 229, 0),
        rgb8(7, 0, 254),
        rgb8(229, 0, 229),
        rgb8(0, 229, 229),
        rgb8(229, 229, 229)
    ]

    /// The light theme's ANSI-16, darkened so every entry clears 4.4:1 against
    /// the white background (SwiftTerm's own brights sit at 1.3–1.9:1 there).
    /// "Bright" reads as *more saturated* rather than lighter, which is the only
    /// direction that stays legible on a light background.
    private static let lightANSIColors: [SwiftTerm.Color] = [
        rgb8(0x00, 0x00, 0x00),
        rgb8(0xB0, 0x1B, 0x1B),
        rgb8(0x0B, 0x7A, 0x28),
        rgb8(0x8A, 0x61, 0x00),
        rgb8(0x1E, 0x4F, 0xBF),
        rgb8(0x9A, 0x22, 0xA8),
        rgb8(0x00, 0x70, 0x7F),
        rgb8(0x4D, 0x4D, 0x4D),
        rgb8(0x75, 0x75, 0x75),
        rgb8(0xC7, 0x30, 0x1E),
        rgb8(0x1F, 0x7A, 0x33),
        rgb8(0x9A, 0x70, 0x00),
        rgb8(0x2E, 0x5F, 0xD0),
        rgb8(0xA8, 0x3B, 0xB5),
        rgb8(0x00, 0x80, 0x8F),
        rgb8(0x1E, 0x1E, 0x1E)
    ]

    /// The palette for an appearance, matched against the two base appearances
    /// so a high-contrast or accessibility variant still resolves to light/dark.
    static func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    /// A fingerprint of everything `apply(to:appearance:)` would install for an
    /// appearance: the four resolved colors as 16-bit sRGB components.
    ///
    /// This is the key `TerminalSession` compares to decide whether a re-apply is
    /// needed, and it is deliberately *not* the `NSAppearance.Name`. Two of the four
    /// colors are the semantic `.selectedContentBackgroundColor` /
    /// `.selectedTextBackgroundColor`, which follow the user's **accent color** — a
    /// preference that changes them without changing the appearance name, so a
    /// name-keyed guard would leave every live session on the old accent. The other
    /// two are the fixed light/dark background and foreground, which differ between
    /// the two palettes (white/black), so they also encode the palette choice and
    /// hence the ANSI-16 set that goes with it — the key covers the whole apply.
    ///
    /// Comparing resolved *components* rather than the `NSColor`s themselves keeps
    /// the guard deterministic: a false negative here would silently reinstate the
    /// per-tab-switch color reset the guard exists to prevent.
    struct ThemeKey: Equatable {
        let colors: [UInt16]
    }

    /// The `ThemeKey` for `appearance` — resolved through the same palette choice
    /// and the same dynamic-color resolution `apply(to:appearance:)` uses.
    static func key(for appearance: NSAppearance) -> ThemeKey {
        let colors = resolvedColors(palette(for: appearance), in: appearance)
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
        let palette = palette(for: appearance)
        let colors = resolvedColors(palette, in: appearance)
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
        // colors. Unconditional in both directions: dark reinstalls SwiftTerm's
        // own values, so switching back restores exactly what the view started with.
        view.installColors(palette.ansi)
        view.setBackgroundColor(source: terminal, color: terminalColor(background))
        view.setForegroundColor(source: terminal, color: terminalColor(foreground))

        view.caretColor = colors.caret
        // Text under a block cursor is drawn in this color, so the palette
        // background keeps it readable against the caret. This only works because
        // the caret is `.selectedContentBackgroundColor` (a saturated accent blue,
        // #0064E1/#0059D1) rather than `.selectedControlColor` — the latter is the
        // pale *selection* tint (#B3D7FF in light), against which a white glyph
        // would sit at 1.5:1, and it is byte-identical to the selection color, so
        // the caret and a selected region would also be indistinguishable.
        view.caretTextColor = background
        view.selectedTextBackgroundColor = colors.selection

        // SwiftTerm assigns the layer background only once, in `setupOptions()`,
        // so a later palette change has to update it or the view keeps painting
        // its uncovered areas in the old background.
        view.layer?.backgroundColor = background.cgColor
    }

    /// The palette's four appearance-dependent colors, all resolved under
    /// `appearance`. Shared by `apply(to:appearance:)` and `key(for:)` so the
    /// guard can never judge a different set of colors than the one applied.
    private static func resolvedColors(
        _ palette: Palette,
        in appearance: NSAppearance
    ) -> (background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor) {
        (
            background: resolved(palette.background, in: appearance),
            foreground: resolved(palette.foreground, in: appearance),
            caret: resolved(palette.caret, in: appearance),
            selection: resolved(palette.selection, in: appearance)
        )
    }

    /// Resolves a possibly-dynamic `NSColor` (`.selectedControlColor` and
    /// friends are appearance-dependent catalog colors) to concrete components
    /// *under `appearance`*.
    ///
    /// Without the explicit drawing appearance, `usingColorSpace(_:)` resolves
    /// against the current thread's appearance — which is the app's, not the
    /// hosting view's — so a window forced light by `ThemePreference` while the
    /// system is dark would hand SwiftTerm the dark variant.
    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
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
    /// trap. Rounding rather than truncating is what makes the dark palette
    /// reproduce SwiftTerm's `defaultForeground` exactly (35389, not 35388).
    private static func component(_ value: CGFloat) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(max(value, 0), 1) * 65535).rounded())
    }
}

#endif
