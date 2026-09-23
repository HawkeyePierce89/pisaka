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
/// **The eight hues are today's system values**, written out as light/dark
/// pairs and carried over deliberately, so moving the gutter off the system
/// colours changes nothing visually. They were not chosen against the design's
/// ground; choosing hues that sit on it is an open design question, not a
/// decision this table records.
///
/// Like `ChromePalette`, the table is an exhaustive `switch` with no `default`,
/// and the colour it answers is **dynamic** — resolved per appearance at draw
/// time — so the gutter caches nothing and watches for no appearance change.
/// `CommitGraphPaletteTests` restates the values and pins the wrap.
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
        case .blue: return Entry(light: 0x007AFF, dark: 0x0A84FF)
        case .green: return Entry(light: 0x28CD41, dark: 0x32D74B)
        case .orange: return Entry(light: 0xFF9500, dark: 0xFF9F0A)
        case .purple: return Entry(light: 0xAF52DE, dark: 0xBF5AF2)
        case .red: return Entry(light: 0xFF3B30, dark: 0xFF453A)
        case .teal: return Entry(light: 0x30B0C7, dark: 0x40C8E0)
        case .pink: return Entry(light: 0xFF2D55, dark: 0xFF375F)
        case .yellow: return Entry(light: 0xFFCC00, dark: 0xFFD60A)
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
