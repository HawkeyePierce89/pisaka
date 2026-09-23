#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// The branch graph's lane table, pinned value by value.
///
/// `CommitGraphPalette` is the chrome's fourth colour exemption: eight lane
/// identities, each a light/dark pair carried over from the system colours the
/// gutter used to draw. The table is restated here and compared, so a value
/// changed in one place and not the other is the failure this suite produces.
final class CommitGraphPaletteTests: XCTestCase {

    /// The table, restated, in lane order.
    private static let expected: [(lane: CommitGraphPalette.Lane, light: UInt32, dark: UInt32)] = [
        (.blue, 0x007AFF, 0x0A84FF),
        (.green, 0x28CD41, 0x32D74B),
        (.orange, 0xFF9500, 0xFF9F0A),
        (.purple, 0xAF52DE, 0xBF5AF2),
        (.red, 0xFF3B30, 0xFF453A),
        (.teal, 0x30B0C7, 0x40C8E0),
        (.pink, 0xFF2D55, 0xFF375F),
        (.yellow, 0xFFCC00, 0xFFD60A),
    ]

    // MARK: - Helpers

    /// Resolves a dynamic colour under a named appearance and returns its sRGB
    /// value as the 24-bit integer a hex literal is written in.
    private func resolvedRGB(_ color: NSColor, under name: NSAppearance.Name) throws -> UInt32 {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(resolved, "the colour is not representable in sRGB")
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    // MARK: - The table

    func testTheTableHoldsEightLanesWithTheStatedValues() {
        XCTAssertEqual(CommitGraphPalette.Lane.allCases.count, 8)
        XCTAssertEqual(Self.expected.map(\.lane), CommitGraphPalette.Lane.allCases)
        for row in Self.expected {
            XCTAssertEqual(
                CommitGraphPalette.entry(for: row.lane),
                CommitGraphPalette.Entry(light: row.light, dark: row.dark),
                "\(row.lane)"
            )
        }
    }

    func testEachSetIsPairwiseDistinct() {
        let entries = CommitGraphPalette.Lane.allCases.map(CommitGraphPalette.entry(for:))
        XCTAssertEqual(Set(entries.map(\.light)).count, 8, "two lanes share a light value")
        XCTAssertEqual(Set(entries.map(\.dark)).count, 8, "two lanes share a dark value")
    }

    // MARK: - The dynamic colour

    func testTheColourResolvesPerAppearance() throws {
        for (index, row) in Self.expected.enumerated() {
            let color = CommitGraphPalette.nsColor(forLane: index)
            XCTAssertEqual(try resolvedRGB(color, under: .aqua), row.light, "\(row.lane), light")
            XCTAssertEqual(try resolvedRGB(color, under: .darkAqua), row.dark, "\(row.lane), dark")
        }
    }

    // MARK: - The wrap

    func testIndicesWrapInBothDirections() throws {
        XCTAssertEqual(CommitGraphPalette.lane(forIndex: 8), .blue)
        XCTAssertEqual(CommitGraphPalette.lane(forIndex: 9), .green)
        XCTAssertEqual(CommitGraphPalette.lane(forIndex: -1), .yellow)
        XCTAssertEqual(CommitGraphPalette.lane(forIndex: -8), .blue)

        // The colour itself wraps too, not only the lane lookup.
        XCTAssertEqual(
            try resolvedRGB(CommitGraphPalette.nsColor(forLane: 8), under: .aqua), 0x007AFF
        )
        XCTAssertEqual(
            try resolvedRGB(CommitGraphPalette.nsColor(forLane: -1), under: .darkAqua), 0xFFD60A
        )
    }
}

#endif
