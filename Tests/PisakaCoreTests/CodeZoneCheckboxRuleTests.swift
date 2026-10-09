import XCTest
@testable import PisakaCore

final class CodeZoneCheckboxRuleTests: XCTestCase {
    private let fontRange = ZoomScaleRule.editorFont

    private func isOnHalfPointGrid(_ value: Double) -> Bool {
        (value * 2).rounded() == value * 2
    }

    // MARK: - The reference size

    func testDefaultFontGivesTheChromeBox() {
        let rule = CodeZoneCheckboxRule(fontSize: 13)
        XCTAssertEqual(rule.side, ChromeGeometry.checkboxSide)
        XCTAssertEqual(rule.side, 14)
        XCTAssertEqual(rule.glyphSide, 10)
        XCTAssertEqual(rule.cornerRadius, ChromeGeometry.checkboxCornerRadius)
        XCTAssertEqual(rule.strokeWidth, ChromeGeometry.hairlineWidth)
        XCTAssertEqual(rule.placeholderWidth, rule.side)
    }

    // MARK: - The code zone's bounds

    func testMinimumFontSize() {
        // 8 × 14 / 13 = 8.615… → 8.5; 8.5 × 10 / 14 = 6.07… → 6;
        // 3 × 8.5 / 14 = 1.82… → 2; 1 × 8.5 / 14 → floored at 1.
        let rule = CodeZoneCheckboxRule(fontSize: fontRange.minimum)
        XCTAssertEqual(rule.side, 8.5)
        XCTAssertEqual(rule.glyphSide, 6)
        XCTAssertEqual(rule.cornerRadius, 2)
        XCTAssertEqual(rule.strokeWidth, 1)
        XCTAssertEqual(rule.placeholderWidth, 8.5)
    }

    func testMaximumFontSize() {
        // 32 × 14 / 13 = 34.46… → 34.5; 34.5 × 10 / 14 = 24.64… → 24.5;
        // 3 × 34.5 / 14 = 7.39… → 7.5; 1 × 34.5 / 14 = 2.46… → 2.5.
        let rule = CodeZoneCheckboxRule(fontSize: fontRange.maximum)
        XCTAssertEqual(rule.side, 34.5)
        XCTAssertEqual(rule.glyphSide, 24.5)
        XCTAssertEqual(rule.cornerRadius, 7.5)
        XCTAssertEqual(rule.strokeWidth, 2.5)
    }

    func testOutOfRangeAndNonFiniteFontSizesAreClamped() {
        XCTAssertEqual(CodeZoneCheckboxRule(fontSize: 2), CodeZoneCheckboxRule(fontSize: fontRange.minimum))
        XCTAssertEqual(CodeZoneCheckboxRule(fontSize: 400), CodeZoneCheckboxRule(fontSize: fontRange.maximum))
        XCTAssertEqual(CodeZoneCheckboxRule(fontSize: .nan), CodeZoneCheckboxRule(fontSize: fontRange.defaultValue))
        XCTAssertEqual(CodeZoneCheckboxRule(fontSize: .infinity), CodeZoneCheckboxRule(fontSize: fontRange.defaultValue))
    }

    // MARK: - Across the whole range

    private var everyFontSize: [Double] {
        Array(stride(from: fontRange.minimum, through: fontRange.maximum, by: 0.5))
    }

    func testSideGrowsWithTheFontSize() {
        var previous: CodeZoneCheckboxRule?
        for size in everyFontSize {
            let rule = CodeZoneCheckboxRule(fontSize: size)
            if let previous {
                XCTAssertGreaterThanOrEqual(rule.side, previous.side, "side shrank at \(size)pt")
                XCTAssertGreaterThanOrEqual(rule.glyphSide, previous.glyphSide, "glyph shrank at \(size)pt")
                XCTAssertGreaterThanOrEqual(rule.cornerRadius, previous.cornerRadius, "radius shrank at \(size)pt")
                XCTAssertGreaterThanOrEqual(rule.strokeWidth, previous.strokeWidth, "stroke shrank at \(size)pt")
            }
            previous = rule
        }
        XCTAssertGreaterThan(
            CodeZoneCheckboxRule(fontSize: 20).side,
            CodeZoneCheckboxRule(fontSize: 13).side
        )
    }

    func testGlyphProportionHoldsWithinRounding() {
        for size in everyFontSize {
            let rule = CodeZoneCheckboxRule(fontSize: size)
            // Half-point rounding moves the glyph by at most a quarter point.
            XCTAssertEqual(rule.glyphSide, rule.side * 10 / 14, accuracy: 0.25, "at \(size)pt")
            XCTAssertEqual(rule.side, size * 14 / 13, accuracy: 0.25, "at \(size)pt")
            XCTAssertLessThan(rule.glyphSide, rule.side, "at \(size)pt")
        }
    }

    func testEveryValueIsOnTheHalfPointGridAndTheStrokeIsAtLeastOnePoint() {
        for size in everyFontSize {
            let rule = CodeZoneCheckboxRule(fontSize: size)
            for value in [rule.side, rule.glyphSide, rule.cornerRadius, rule.strokeWidth] {
                XCTAssertTrue(isOnHalfPointGrid(value), "\(value) off the grid at \(size)pt")
            }
            XCTAssertGreaterThanOrEqual(rule.strokeWidth, 1, "at \(size)pt")
            XCTAssertEqual(rule.placeholderWidth, rule.side, "at \(size)pt")
        }
    }

    // MARK: - Independent of the chrome's zone

    /// The rule must not consult the chrome's scale: the two zones never
    /// interact. Read raw — comments included — which is stricter than the
    /// stripped reading, because the file must not even mention them.
    func testRuleNamesNeitherTheMetricsTypeNorTheChromeScale() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PisakaCore/CodeZoneCheckboxRule.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("InterfaceMetrics"))
        XCTAssertFalse(source.contains("interfaceScale"))
        XCTAssertFalse(source.contains("interfaceMetrics"))
    }
}
