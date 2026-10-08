#if os(macOS)
import AppKit
import SwiftTerm
import XCTest
import PisakaCore
@testable import Pisaka

/// The terminal's four chrome colours and its light ANSI-16 set, pinned.
///
/// `TerminalTheme` resolves `bgPanel`, `textPrimary`, `accent` and
/// `accentTintStrong` concretely at apply time, because SwiftTerm stores the
/// colours it is handed and never re-resolves them. The key the session guard
/// compares is the only observable form of what an apply installs, so it is
/// checked against the palette here — with this suite's own component arithmetic
/// rather than the theme's private converter, so the comparison is not a
/// tautology, including under both high-contrast variants. Beside it are pinned:
/// the light ANSI set's 4.5:1 floor on `bgPanel` light; the dark set's 4.5:1
/// floor on `bgPanel` dark — the terminal's actual ground, read from the
/// palette, never a literal — for every entry but ANSI 0, whose exact black is
/// the one stated exception; the dark set's exact sixteen values, so dark →
/// light → dark restores precisely them; which set each appearance installs; and
/// both sets' size.
final class TerminalThemeTests: XCTestCase {

    /// The roles in the order `ThemeKey` fingerprints them: ground, text, caret,
    /// selection.
    private static let roles: [ChromeColorRole] = [.bgPanel, .textPrimary, .accent, .accentTintStrong]

    func testThemeKeyIsTheFourRolesResolvedForEachAppearance() throws {
        let cases: [(NSAppearance.Name, ChromeAppearance)] = [
            (.aqua, .light),
            (.darkAqua, .dark),
            (.accessibilityHighContrastAqua, .light),
            (.accessibilityHighContrastDarkAqua, .dark),
        ]
        for (name, chrome) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let expected = Self.roles.flatMap { Self.sixteenBit(ChromePalette.nsColor($0, in: chrome)) }
            XCTAssertEqual(
                TerminalTheme.key(for: appearance).colors,
                expected,
                "the terminal's colours under \(name.rawValue) are not the four chrome roles of \(chrome)"
            )
        }
    }

    func testEveryLightANSIEntryClearsTheFloorOnTheLightGround() {
        let ground = Self.sixteenBit(ChromePalette.nsColor(.bgPanel, in: .light))
        let groundLuminance = Self.luminance(red: ground[0], green: ground[1], blue: ground[2])
        for (index, entry) in TerminalTheme.lightANSIColors.enumerated() {
            let luminance = Self.luminance(red: entry.red, green: entry.green, blue: entry.blue)
            let ratio = (max(luminance, groundLuminance) + 0.05) / (min(luminance, groundLuminance) + 0.05)
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "light ANSI \(index) sits at \(String(format: "%.2f", ratio)):1 on the light ground"
            )
        }
    }

    func testEveryDarkANSIEntryButBlackClearsTheFloorOnTheDarkGround() {
        let ground = Self.sixteenBit(ChromePalette.nsColor(.bgPanel, in: .dark))
        let groundLuminance = Self.luminance(red: ground[0], green: ground[1], blue: ground[2])
        let black = TerminalTheme.darkANSIColors[0]
        XCTAssertEqual([black.red, black.green, black.blue], [0, 0, 0], "dark ANSI 0 is not exactly 0x000000")
        for (index, entry) in TerminalTheme.darkANSIColors.enumerated().dropFirst() {
            let luminance = Self.luminance(red: entry.red, green: entry.green, blue: entry.blue)
            let ratio = (max(luminance, groundLuminance) + 0.05) / (min(luminance, groundLuminance) + 0.05)
            XCTAssertGreaterThanOrEqual(
                ratio,
                4.5,
                "dark ANSI \(index) sits at \(String(format: "%.2f", ratio)):1 on the dark ground"
            )
        }
    }

    /// Each dark bright entry (8–15) stays brighter than its normal partner
    /// (0–7), so a retune cannot invert a pair while updating the pin. The
    /// light set makes no such promise: its bright white is darkened for the
    /// light ground.
    func testEveryDarkBrightANSIEntryIsBrighterThanItsNormalPartner() {
        let set = TerminalTheme.darkANSIColors
        for index in 0..<8 {
            let normal = set[index], bright = set[index + 8]
            XCTAssertGreaterThan(
                Self.luminance(red: bright.red, green: bright.green, blue: bright.blue),
                Self.luminance(red: normal.red, green: normal.green, blue: normal.blue),
                "dark ANSI \(index + 8) is not brighter than ANSI \(index)"
            )
        }
    }

    /// SwiftTerm's hues, nine of them brightened for `bgPanel` dark; the other
    /// seven are SwiftTerm's own values verbatim.
    func testTheDarkANSISetIsExactlyTheTunedSixteen() {
        let expected: [UInt32] = [
            0x000000, 0xFF6B6B, 0x00B803, 0xA0A000, 0x9393FF, 0xE070E0, 0x00A5B2, 0xBFBFBF,
            0x9E9D9E, 0xFF8C8C, 0x00D800, 0xE5E500, 0xAAAAFF, 0xFF8CFF, 0x00E5E5, 0xE5E5E5,
        ]
        let actual = TerminalTheme.darkANSIColors.map { entry in
            [entry.red, entry.green, entry.blue].reduce(UInt32(0)) { ($0 << 8) | UInt32($1 / 257) }
        }
        XCTAssertEqual(actual.map { String(format: "%06X", $0) }, expected.map { String(format: "%06X", $0) })
    }

    /// What an apply actually leaves on a live view, rather than the key: the
    /// layer's ground and the text under a block caret are both the terminal's
    /// ground, and that ground is `bgPanel` resolved for the appearance — the
    /// role the dock slot and the panel's inset paint, so the three read as one
    /// surface. A plain `TerminalView` starts no process.
    func testAnApplyPaintsTheGroundBgPanelInBothAppearances() throws {
        let cases: [(NSAppearance.Name, ChromeAppearance)] = [(.aqua, .light), (.darkAqua, .dark)]
        for (name, chrome) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            view.wantsLayer = true
            TerminalTheme.apply(to: view, appearance: appearance)
            let expected = Self.sixteenBit(ChromePalette.nsColor(.bgPanel, in: chrome))
            let layerGround = try XCTUnwrap(
                view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) },
                "the apply left no layer ground under \(name.rawValue)"
            )
            XCTAssertEqual(Self.sixteenBit(layerGround), expected, "the layer's ground under \(name.rawValue) is not bgPanel")
            XCTAssertEqual(
                Self.sixteenBit(view.caretTextColor ?? .clear), expected,
                "the text under the caret under \(name.rawValue) is not drawn in the bgPanel ground"
            )
        }
    }

    func testEachAppearanceInstallsItsOwnANSISet() {
        XCTAssertEqual(TerminalTheme.ansiColors(for: .dark), TerminalTheme.darkANSIColors)
        XCTAssertEqual(TerminalTheme.ansiColors(for: .light), TerminalTheme.lightANSIColors)
    }

    func testBothANSISetsHaveSixteenEntries() {
        XCTAssertEqual(TerminalTheme.darkANSIColors.count, 16)
        XCTAssertEqual(TerminalTheme.lightANSIColors.count, 16)
    }

    // MARK: - Arithmetic

    /// A colour's sRGB components ×65535, rounded, alpha included.
    private static func sixteenBit(_ color: NSColor) -> [UInt16] {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let values = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        return values.map { UInt16(($0 * 65535).rounded()) }
    }

    /// Relative luminance of a 16-bit sRGB colour.
    private static func luminance(red: UInt16, green: UInt16, blue: UInt16) -> Double {
        func linear(_ component: UInt16) -> Double {
            let value = Double(component) / 65535
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

#endif
