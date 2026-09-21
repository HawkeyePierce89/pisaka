#if os(macOS)
import AppKit
import XCTest
import PisakaCore
@testable import Pisaka

/// The code zone's colour table, pinned component by component.
///
/// `SyntaxTheme.table` is the one place a syntax colour is spelled, and nothing
/// in the product reads a value back out of it, so no compiler and no other
/// suite can see a digit transposed, a light value written on the dark side or a
/// row silently dropped. The table is therefore written out a second time here
/// and the two are compared: the duplication is the test.
///
/// The theme lives in the app target (colour is the view layer's business;
/// `PisakaCore` stays colour-free), so these assertions run in the app-layer
/// bundle rather than in `swift test`, mirroring `ChromePaletteTests`.
final class SyntaxThemeTests: XCTestCase {

    /// The table, restated. One row per `SyntaxTokenKind`. Every entry is opaque
    /// — nothing in this table is a wash — which the suite asserts rather than
    /// assumes.
    private static let expected: [SyntaxTokenKind: (dark: UInt32, light: UInt32)] = [
        .keyword: (0xB48EAD, 0x8250B0),
        .string: (0x9DB97B, 0x4F7942),
        .comment: (0x6B6E76, 0x8A8A90),
        .number: (0xC9976C, 0xA5652D),
        .type: (0x6A9FB5, 0x2B6A83),
        .function: (0x7AA6DA, 0x2F5FA8),
        .variable: (0xDFE1E5, 0x1D1D1F),
        .constant: (0xC9976C, 0xA5652D),
        .operator: (0xA0A3AA, 0x6E6E73),
        .punctuation: (0xA0A3AA, 0x6E6E73),
        .property: (0x7FA8A0, 0x2F6B63),
        .parameter: (0xDFE1E5, 0x1D1D1F),
        .label: (0x4F8DFF, 0x2F6FE0),
        .plain: (0xDFE1E5, 0x1D1D1F),
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
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try components(color)
        XCTAssertEqual(actual.r, Int((rgb >> 16) & 0xFF), "\(message()) — red", file: file, line: line)
        XCTAssertEqual(actual.g, Int((rgb >> 8) & 0xFF), "\(message()) — green", file: file, line: line)
        XCTAssertEqual(actual.b, Int(rgb & 0xFF), "\(message()) — blue", file: file, line: line)
        XCTAssertEqual(actual.alpha, 1, accuracy: 0.002, "\(message()) — alpha", file: file, line: line)
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

    func testEveryTokenKindResolvesToItsTabledValueInBothAppearances() throws {
        // The restated table is complete: a kind added to Core without a row here
        // fails before any value is compared.
        XCTAssertEqual(Set(Self.expected.keys), Set(SyntaxTokenKind.allCases))

        for kind in SyntaxTokenKind.allCases {
            let row = try XCTUnwrap(Self.expected[kind], "\(kind) has no expected row")
            let colour = SyntaxTheme.shared.nsColor(for: kind)
            try assertComponents(resolved(colour, under: .darkAqua), equal: row.dark, "\(kind), dark")
            try assertComponents(resolved(colour, under: .aqua), equal: row.light, "\(kind), light")
        }
    }

    // MARK: - The rule

    /// No token kind resolves to a system semantic colour, in either appearance.
    ///
    /// The defect this exists for: a system colour follows the *system*
    /// appearance, so a kind left on one would ignore the app's own Theme
    /// preference and disagree with every surface drawn around the code. The rule
    /// is about that property, not about today's numbers — a later palette change
    /// keeps it, and a row quietly replaced by `.labelColor` breaks it.
    func testNoTokenKindResolvesToASystemSemanticColour() throws {
        let systemColours: [(name: String, colour: NSColor)] = [
            ("labelColor", .labelColor),
            ("secondaryLabelColor", .secondaryLabelColor),
            ("tertiaryLabelColor", .tertiaryLabelColor),
            ("textColor", .textColor),
        ]
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            for system in systemColours {
                let systemComponents = try components(resolved(system.colour, under: name))
                for kind in SyntaxTokenKind.allCases {
                    let kindComponents = try components(
                        resolved(SyntaxTheme.shared.nsColor(for: kind), under: name)
                    )
                    XCTAssertFalse(
                        kindComponents.r == systemComponents.r
                            && kindComponents.g == systemComponents.g
                            && kindComponents.b == systemComponents.b
                            && abs(kindComponents.alpha - systemComponents.alpha) < 0.002,
                        "\(kind) resolves to \(system.name) under \(name.rawValue) — "
                            + "a system colour follows the system appearance, not the app's Theme preference"
                    )
                }
            }
        }
    }

    // MARK: - The fallback

    /// The fallback constant, asserted directly — no call to `color(for:)` can
    /// reach it — beside the statement of *why* that is so: the table is total
    /// over the closed `SyntaxTokenKind`, so there is no unmapped kind to ask
    /// with. The two sentences are one test because they are read together.
    func testThePlainTextFallbackIsThePlainRowAndIsUnreachableWhileTheTableIsTotal() throws {
        let row = try XCTUnwrap(Self.expected[.plain])
        try assertComponents(resolved(SyntaxTheme.plainText, under: .darkAqua), equal: row.dark, "plainText, dark")
        try assertComponents(resolved(SyntaxTheme.plainText, under: .aqua), equal: row.light, "plainText, light")

        // Why the constant has to be asserted directly: the table names every
        // kind, so `color(for:)` never falls through to it.
        XCTAssertEqual(Set(SyntaxTheme.table.keys), Set(SyntaxTokenKind.allCases))
    }

    // MARK: - Uncovered text

    /// The value the editor gives a character no capture covers.
    ///
    /// Two sites read it — the text view's base foreground and the no-grammar
    /// reset path — and both spell `SyntaxTheme.shared.color(for: .plain)`. This
    /// pins what that expression resolves to, so neither site can drift back onto
    /// a platform label colour (which follows the *system* appearance and so
    /// ignores the app's Theme preference) without the suite noticing.
    func testUncoveredTextReadsThePlainRowInBothAppearances() throws {
        let row = try XCTUnwrap(Self.expected[.plain])
        let colour = SyntaxTheme.shared.nsColor(for: .plain)
        try assertComponents(resolved(colour, under: .darkAqua), equal: row.dark, "uncovered text, dark")
        try assertComponents(resolved(colour, under: .aqua), equal: row.light, "uncovered text, light")
    }
}

#endif
