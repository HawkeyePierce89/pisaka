#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The branch graph's lane table, pinned value by value.
///
/// `CommitGraphPalette` is the chrome's fourth colour exemption: eight lane
/// identities, each a light/dark pair chosen against the gutter's ground,
/// `bgPanel`. The table is restated here and compared, so a value changed in one
/// place and not the other is the failure this suite produces; and the table is
/// measured through `ContrastArithmetic` — 3:1 against `bgPanel` (read from
/// `ChromePalette`, not restated), 20° of hue between any two lanes per
/// appearance, and no lane equal to a status role or `accent`.
final class CommitGraphPaletteTests: XCTestCase {

    /// The table, restated, in lane order.
    private static let expected: [(lane: CommitGraphPalette.Lane, light: UInt32, dark: UInt32)] = [
        (.blue, 0x2F64C8, 0x6AA2FF),
        (.green, 0x2E7D32, 0x5FC46A),
        (.orange, 0xB8560A, 0xF0954A),
        (.purple, 0x8A3FC0, 0xC08CF5),
        (.red, 0xC0392B, 0xF2706A),
        (.teal, 0x00798A, 0x3FC4D4),
        (.pink, 0xC2185B, 0xF27AAE),
        (.yellow, 0x8A6D00, 0xE3C449),
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

    // MARK: - The measurements

    /// The table's values per appearance, in lane order.
    private static func values(dark: Bool) -> [UInt32] {
        CommitGraphPalette.Lane.allCases.map {
            let entry = CommitGraphPalette.entry(for: $0)
            return dark ? entry.dark : entry.light
        }
    }

    func testEveryLaneClearsThreeToOneAgainstThePanelGround() {
        let ground = ChromePalette.entry(for: .bgPanel)
        for dark in [false, true] {
            let panel = dark ? ground.dark : ground.light
            for (lane, value) in zip(CommitGraphPalette.Lane.allCases, Self.values(dark: dark)) {
                let ratio = ContrastArithmetic.contrast(value, panel)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3, "\(lane), \(dark ? "dark" : "light"): \(ratio)"
                )
            }
        }
    }

    func testHuesStayTwentyDegreesApartPerAppearance() {
        for dark in [false, true] {
            let hues = Self.values(dark: dark).map(ContrastArithmetic.hue)
            var closest = Double.infinity
            for first in hues.indices {
                for second in hues.indices where second > first {
                    closest = min(closest, ContrastArithmetic.hueSeparation(hues[first], hues[second]))
                }
            }
            XCTAssertGreaterThanOrEqual(closest, 20, "\(dark ? "dark" : "light"): \(closest)")
        }
    }

    func testNoLaneEqualsAStatusRoleOrTheAccent() {
        let roles: [ChromeColorRole] = [.statusRed, .statusGreen, .statusYellow, .accent]
        for dark in [false, true] {
            let chrome = Set(roles.map { role -> UInt32 in
                let entry = ChromePalette.entry(for: role)
                return dark ? entry.dark : entry.light
            })
            for (lane, value) in zip(CommitGraphPalette.Lane.allCases, Self.values(dark: dark)) {
                XCTAssertFalse(chrome.contains(value), "\(lane), \(dark ? "dark" : "light")")
            }
        }
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
            try resolvedRGB(CommitGraphPalette.nsColor(forLane: 8), under: .aqua), 0x2F64C8
        )
        XCTAssertEqual(
            try resolvedRGB(CommitGraphPalette.nsColor(forLane: -1), under: .darkAqua), 0xE3C449
        )
    }
}

#endif
