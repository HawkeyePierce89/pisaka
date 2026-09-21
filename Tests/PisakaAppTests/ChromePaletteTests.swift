#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The chrome palette's two value sets, pinned component by component.
///
/// `ChromePalette` is the one file in the chrome allowed to spell a hex literal,
/// and the exhaustive `switch` in it makes a *missing* pair a compile error. What
/// no compiler can see is a pair that is simply wrong — a digit transposed, a
/// dark value written on the light side, an alpha left at `1` on a wash — so the
/// table is written out a second time here and the two are compared. The
/// duplication is the test: a value changed in one place and not the other is the
/// failure this suite exists to produce.
///
/// The palette lives in the app target (colour is the view layer's business;
/// `PisakaCore` stays colour-free), so these assertions run in the app-layer
/// bundle rather than in `swift test`.
final class ChromePaletteTests: XCTestCase {

    /// The table, restated. One row per `ChromeColorRole`.
    ///
    /// The alpha is the design's own byte — the last two digits of an eight-digit
    /// value — compared as `CGFloat(alpha) / 255`, so the row here is the number
    /// the design states rather than a fraction rounded away from it.
    private static let expected: [ChromeColorRole: (dark: UInt32, light: UInt32, alpha: UInt8)] = [
        .bgCanvas: (0x1E1F22, 0xF5F5F7, 0xFF),
        .bgPanel: (0x2B2D30, 0xECECEF, 0xFF),
        .bgEditor: (0x2F3136, 0xFFFFFF, 0xFF),
        .bgPopover: (0x36383D, 0xFFFFFF, 0xFF),
        .textPrimary: (0xDFE1E5, 0x1D1D1F, 0xFF),
        .textSecondary: (0xA0A3AA, 0x6E6E73, 0xFF),
        .onAccent: (0xFFFFFF, 0xFFFFFF, 0xFF),
        .hairline: (0x393B40, 0xD1D1D6, 0xFF),
        .accent: (0x4F8DFF, 0x2F6FE0, 0xFF),
        .accentTint: (0x4F8DFF, 0x2F6FE0, 0x22),
        .accentTintStrong: (0x4F8DFF, 0x2F6FE0, 0x33),
        .hoverTint: (0xFFFFFF, 0x000000, 0x0A),
        .selectionInactive: (0x34363B, 0xF0F0F2, 0xFF),
        .currentLine: (0x34363B, 0xF0F0F2, 0xFF),
        .bracketMatch: (0x3D4A5C, 0xDBE6F5, 0xFF),
        .statusGreen: (0x7A9D6E, 0x4F8A3D, 0xFF),
        .statusRed: (0xC4746B, 0xC1483D, 0xFF),
        .statusYellow: (0xC9A35C, 0xA67C2E, 0xFF),
        .diffAddedBackground: (0x7A9D6E, 0x4F8A3D, 0x22),
        .diffRemovedBackground: (0xC4746B, 0xC1483D, 0x22),
        .conflictBackground: (0xC9A35C, 0xA67C2E, 0x26),
    ]

    /// The one role the design gives the *same* value in both appearances: text
    /// drawn on the accent is white over either, the accent being the one colour
    /// that does not change weight between the two themes. Exempted by name from
    /// the disagree-about-every-role rule below, and by name only.
    private static let sameInBothAppearances: Set<ChromeColorRole> = [.onAccent]

    // MARK: - Helpers

    /// The sRGB components of a concrete colour, as the 0...255 integers a hex
    /// literal is written in, plus its alpha.
    private func components(_ color: NSColor) throws -> (r: Int, g: Int, b: Int, alpha: CGFloat) {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB), "the colour is not representable in sRGB")
        return (
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()),
            srgb.alphaComponent
        )
    }

    private func assertComponents(
        _ color: NSColor,
        equal rgb: UInt32,
        alpha: UInt8,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try components(color)
        XCTAssertEqual(actual.r, Int((rgb >> 16) & 0xFF), "\(message()) — red", file: file, line: line)
        XCTAssertEqual(actual.g, Int((rgb >> 8) & 0xFF), "\(message()) — green", file: file, line: line)
        XCTAssertEqual(actual.b, Int(rgb & 0xFF), "\(message()) — blue", file: file, line: line)
        XCTAssertEqual(
            actual.alpha, CGFloat(alpha) / 255, accuracy: 0.002,
            "\(message()) — alpha", file: file, line: line
        )
    }

    /// Resolves a dynamic colour the way AppKit does when it draws inside a
    /// window carrying that appearance.
    private func resolved(_ color: NSColor, under name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            // Asking a dynamic colour for a concrete colour space is what forces
            // it through its appearance closure; inside this block the current
            // drawing appearance is the one named.
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    // MARK: - The two value sets

    func testEveryRoleResolvesToItsTabledValueInBothAppearances() throws {
        // The table is complete: a role added to Core without a row here fails
        // before any value is compared.
        XCTAssertEqual(Set(Self.expected.keys), Set(ChromeColorRole.allCases))

        for role in ChromeColorRole.allCases {
            let row = try XCTUnwrap(Self.expected[role], "\(role.rawValue) has no expected row")
            try assertComponents(
                ChromePalette.nsColor(role, in: .dark),
                equal: row.dark,
                alpha: row.alpha,
                "\(role.rawValue), dark"
            )
            try assertComponents(
                ChromePalette.nsColor(role, in: .light),
                equal: row.light,
                alpha: row.alpha,
                "\(role.rawValue), light"
            )
        }
    }

    // MARK: - The AppKit bridge

    func testTheDynamicColourFollowsTheDrawingAppearance() throws {
        for role in ChromeColorRole.allCases {
            let row = try XCTUnwrap(Self.expected[role])
            let dynamic = ChromePalette.nsColor(role)
            try assertComponents(
                resolved(dynamic, under: .darkAqua),
                equal: row.dark,
                alpha: row.alpha,
                "\(role.rawValue) under darkAqua"
            )
            try assertComponents(
                resolved(dynamic, under: .aqua),
                equal: row.light,
                alpha: row.alpha,
                "\(role.rawValue) under aqua"
            )
        }
    }

    // MARK: - The SwiftUI path

    func testTheTwoThemesDisagreeAboutEveryRoleButTheExemptedOne() {
        let dark = ChromeTheme(.dark)
        let light = ChromeTheme(.light)
        XCTAssertNotEqual(dark, light)
        // The exemption is pinned by set equality rather than merely skipped: a
        // second role quietly given one value in both appearances must fail here.
        XCTAssertEqual(Self.sameInBothAppearances, [.onAccent])
        for role in ChromeColorRole.allCases where !Self.sameInBothAppearances.contains(role) {
            XCTAssertNotEqual(
                dark.color(role), light.color(role),
                "\(role.rawValue) is the same colour in both appearances — one of its two values is wrong"
            )
        }
        for role in Self.sameInBothAppearances {
            XCTAssertEqual(
                dark.color(role), light.color(role),
                "\(role.rawValue) is exempted because the design gives it one value in both appearances"
            )
        }
    }

    func testTheSwiftUIColourAgreesWithTheConcreteAppKitOne() throws {
        for role in ChromeColorRole.allCases {
            for appearance in ChromeAppearance.allCases {
                let fromSwiftUI = NSColor(ChromePalette.color(role, in: appearance))
                let row = try XCTUnwrap(Self.expected[role])
                try assertComponents(
                    fromSwiftUI,
                    equal: appearance == .dark ? row.dark : row.light,
                    alpha: row.alpha,
                    "\(role.rawValue), \(appearance.rawValue), through SwiftUI"
                )
            }
        }
    }

    // MARK: - The resolution the roots perform

    func testThePreferenceResolvesTheAppearanceTheThemeCarries() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChromePaletteTests"))
        defaults.removePersistentDomain(forName: "ChromePaletteTests")
        let settings = SettingsStore(defaults: defaults)
        settings.themePreference = .dark
        XCTAssertEqual(settings.chromeTheme(systemPrefersDark: false).appearance, .dark)
        settings.themePreference = .light
        XCTAssertEqual(settings.chromeTheme(systemPrefersDark: true).appearance, .light)
        settings.themePreference = .system
        XCTAssertEqual(settings.chromeTheme(systemPrefersDark: true).appearance, .dark)
        XCTAssertEqual(settings.chromeTheme(systemPrefersDark: false).appearance, .light)
    }
}

#endif
