#if os(macOS)
import AppKit

/// The branch graph's lane colours — the chrome's **fourth** stated colour
/// exemption, beside `SyntaxTheme`, `TerminalTheme` and `FileIcon`.
///
/// A lane colour is an **identity token, not a chrome meaning**: it says "this
/// line is the same branch as that one", the way an ANSI-16 colour is a
/// protocol's vocabulary rather than a statement about the window around it. So
/// it is not a `ChromeColorRole`, and must not become one — pressing a lane into
/// `statusRed` or `accent` would be exactly the misuse the closed role
/// vocabulary exists to prevent, a branch suddenly reading as an error or a
/// selection. Nor can the design's own two lane colours stand in: two hues
/// cannot tell several concurrent branches apart, which is the gutter's whole
/// job.
///
/// **The eight hues are chosen against the gutter's own ground.** The lanes
/// sit on `bgPanel` — `0xECECEF` light, `0x2B2D30` dark — which the dock sets as
/// its ground; neither the graph view nor an unselected row draws anything
/// beneath them. Every entry clears 3:1 against it (WCAG), in table order:
/// light 4.71, 4.35, 4.07, 5.01, 4.61, 4.34, 4.98, 4.17; dark 5.41, 6.31, 5.99,
/// 5.47, 4.80, 6.61, 5.37, 8.06. Over a selected row (`accentTintStrong` on
/// `bgPanel`) every entry still clears 3:1, the floor pinned on `bgPanel` only.
/// The hues stay at least 20° apart per appearance (closest: orange–red light,
/// orange–yellow dark), and no value equals `statusRed`, `statusGreen`,
/// `statusYellow` or `accent` in either appearance — so the table stays the
/// fourth exemption and no lane becomes a `ChromeColorRole`.
///
/// Like `ChromePalette`, the table is an exhaustive `switch` with no `default`,
/// and the colour it answers is **dynamic** — resolved per appearance at draw
/// time — so the gutter caches nothing and watches for no appearance change.
/// `CommitGraphPaletteTests` restates the values, measures them and pins the wrap.
enum CommitGraphPalette {

    /// The eight lane identities, in the order a colour index cycles through.
    enum Lane: Int, CaseIterable {
        case blue, green, orange, purple, red, teal, pink, yellow
    }

    /// The two sRGB values one lane resolves to.
    struct Entry: Equatable {
        let light: UInt32
        let dark: UInt32
    }

    /// The table. Every lane, no `default`.
    static func entry(for lane: Lane) -> Entry {
        switch lane {
        case .blue: return Entry(light: 0x2F64C8, dark: 0x6AA2FF)
        case .green: return Entry(light: 0x2E7D32, dark: 0x5FC46A)
        case .orange: return Entry(light: 0xB8560A, dark: 0xF0954A)
        case .purple: return Entry(light: 0x8A3FC0, dark: 0xC08CF5)
        case .red: return Entry(light: 0xC0392B, dark: 0xF2706A)
        case .teal: return Entry(light: 0x00798A, dark: 0x3FC4D4)
        case .pink: return Entry(light: 0xC2185B, dark: 0xF27AAE)
        case .yellow: return Entry(light: 0x8A6D00, dark: 0xE3C449)
        }
    }

    /// The lane a stable colour index names, cycling when there are more lanes
    /// than identities. Negative indices wrap too, as they always have.
    static func lane(forIndex index: Int) -> Lane {
        let lanes = Lane.allCases
        return lanes[((index % lanes.count) + lanes.count) % lanes.count]
    }

    /// A lane's colour as a dynamic `NSColor`, resolved at draw time.
    static func nsColor(forLane index: Int) -> NSColor {
        let entry = entry(for: lane(forIndex: index))
        return PlatformColor.dynamic(light: entry.light, dark: entry.dark)
    }
}

#endif
