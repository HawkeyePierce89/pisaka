#if os(macOS)
import Foundation

/// WCAG contrast and hue arithmetic over 8-bit sRGB `0xRRGGBB` values — the
/// shared measuring stick of the app suites that pin a colour table against
/// the ground it is drawn on.
///
/// **Test arithmetic, not Core code.** No production code reads a contrast
/// ratio or a hue angle; they are properties a test asserts about a table the
/// app ships. And the pin must not rely on a converter it is checking: the
/// values go in as the literal hex the table states, never through `NSColor`
/// or the palette, so a conversion fault in the product cannot also bend the
/// measurement. `TerminalThemeTests` keeps its own 16-bit arithmetic, because
/// it measures resolved colours, not stated literals.
enum ContrastArithmetic {

    /// The three 8-bit components of `0xRRGGBB`, each in `0...1`.
    static func components(_ rgb: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((rgb >> 16) & 0xFF) / 255,
            Double((rgb >> 8) & 0xFF) / 255,
            Double(rgb & 0xFF) / 255
        )
    }

    /// WCAG relative luminance, through the standard sRGB linearisation.
    static func luminance(_ rgb: UInt32) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = components(rgb)
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colours; symmetric, `1...21`.
    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The hue angle in degrees, `0..<360`; `0` for a grey, which has none.
    static func hue(_ rgb: UInt32) -> Double {
        let (red, green, blue) = components(rgb)
        let maximum = max(red, green, blue)
        let chroma = maximum - min(red, green, blue)
        guard chroma > 0 else { return 0 }
        let sector: Double
        if maximum == red {
            sector = (green - blue) / chroma
        } else if maximum == green {
            sector = (blue - red) / chroma + 2
        } else {
            sector = (red - green) / chroma + 4
        }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The shorter way round the hue circle between two angles, `0...180`.
    static func hueSeparation(_ first: Double, _ second: Double) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

#endif
