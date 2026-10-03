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
/// tautology, including under both high-contrast variants. The light ANSI set's
/// contrast floor, which set each appearance installs and both sets' size are
/// pinned beside it.
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
