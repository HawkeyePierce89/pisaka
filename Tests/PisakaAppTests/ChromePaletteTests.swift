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
    private static let expected: [ChromeColorRole: (dark: UInt32, light: UInt32, alpha: CGFloat)] = [
        .bgEditor: (0x1F1F24, 0xFFFFFF, 1),
        .bgPanel: (0x26262C, 0xF2F2F4, 1),
        .bgSidebar: (0x232329, 0xECECEF, 1),
        .bgBar: (0x2A2A31, 0xF7F7F9, 1),
        .bgPopover: (0x2E2E36, 0xFDFDFE, 1),
        .textPrimary: (0xE8E8ED, 0x1D1D1F, 1),
        .textSecondary: (0x9B9BA5, 0x6B6B73, 1),
        .textTertiary: (0x6E6E78, 0x9A9AA2, 1),
        .hairline: (0x3A3A42, 0xD8D8DC, 1),
        .accent: (0x4A9EFF, 0x1B6BCC, 1),
        .accentTint: (0x4A9EFF, 0x1B6BCC, 0.12),
        .accentTintStrong: (0x4A9EFF, 0x1B6BCC, 0.25),
        .hoverTint: (0xFFFFFF, 0x000000, 0.07),
        .selectionInactive: (0xFFFFFF, 0x000000, 0.12),
        .dropTint: (0x4A9EFF, 0x1B6BCC, 0.40),
        .statusRed: (0xFF7B85, 0xC01C5A, 1),
        .statusYellow: (0xE2B03C, 0xA05E00, 1),
        .statusGreen: (0x7EE787, 0x1E7A33, 1),
        .statusBlue: (0x79B8DA, 0x45718B, 1),
        .diffAddedBackground: (0x7EE787, 0x1E7A33, 0.16),
        .diffRemovedBackground: (0xFF7B85, 0xC01C5A, 0.16),
        .conflictBackground: (0xE2B03C, 0xA05E00, 0.18),
    ]

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
        alpha: CGFloat,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try components(color)
        XCTAssertEqual(actual.r, Int((rgb >> 16) & 0xFF), "\(message()) — red", file: file, line: line)
        XCTAssertEqual(actual.g, Int((rgb >> 8) & 0xFF), "\(message()) — green", file: file, line: line)
        XCTAssertEqual(actual.b, Int(rgb & 0xFF), "\(message()) — blue", file: file, line: line)
        XCTAssertEqual(actual.alpha, alpha, accuracy: 0.001, "\(message()) — alpha", file: file, line: line)
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

    func testTheTwoThemesDisagreeAboutEveryRole() {
        let dark = ChromeTheme(.dark)
        let light = ChromeTheme(.light)
        XCTAssertNotEqual(dark, light)
        for role in ChromeColorRole.allCases {
            XCTAssertNotEqual(
                dark.color(role), light.color(role),
                "\(role.rawValue) is the same colour in both appearances — one of its two values is wrong"
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
