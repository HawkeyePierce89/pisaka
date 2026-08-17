import XCTest
@testable import PisakaCore

/// The arithmetic all three zoom zones share: clamping, stepping on a grid, and
/// the numbers each shipped rule carries.
final class ZoomScaleRuleTests: XCTestCase {
    private let allRules: [(name: String, rule: ZoomScaleRule)] = [
        ("editorFont", .editorFont),
        ("terminalFont", .terminalFont),
        ("interfaceScale", .interfaceScale),
    ]

    // MARK: - The shipped numbers

    func testShippedRules() {
        // The editor's numbers are the ones `SettingsStore` has always used;
        // changing them changes an existing user's editor on the next launch.
        XCTAssertEqual(ZoomScaleRule.editorFont.minimum, 8)
        XCTAssertEqual(ZoomScaleRule.editorFont.maximum, 32)
        XCTAssertEqual(ZoomScaleRule.editorFont.defaultValue, 13)
        XCTAssertEqual(ZoomScaleRule.editorFont.step, 1)

        // 13 = `NSFont.systemFontSize`, SwiftTerm's own default: at rest the
        // terminal must look exactly as it does today.
        XCTAssertEqual(ZoomScaleRule.terminalFont.minimum, 8)
        XCTAssertEqual(ZoomScaleRule.terminalFont.maximum, 32)
        XCTAssertEqual(ZoomScaleRule.terminalFont.defaultValue, 13)
        XCTAssertEqual(ZoomScaleRule.terminalFont.step, 1)

        XCTAssertEqual(ZoomScaleRule.interfaceScale.minimum, 0.8)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.maximum, 2.0)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.defaultValue, 1.0)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.step, 0.1)
    }

    func testEveryRuleHasItsDefaultInRangeAndOnTheGrid() {
        for (name, rule) in allRules {
            XCTAssertEqual(rule.clamp(rule.defaultValue), rule.defaultValue, name)
            XCTAssertGreaterThan(rule.step, 0, name)
            XCTAssertLessThan(rule.minimum, rule.maximum, name)
            // Both bounds must sit on the default-anchored grid, or a zone could
            // never be stepped all the way to its own limit.
            for bound in [rule.minimum, rule.maximum] {
                let steps = (bound - rule.defaultValue) / rule.step
                XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-9, "\(name) bound \(bound)")
            }
        }
    }

    func testZoneToRuleMapping() {
        XCTAssertEqual(ZoomScaleRule.rule(for: .code), .editorFont)
        XCTAssertEqual(ZoomScaleRule.rule(for: .terminal), .terminalFont)
        XCTAssertEqual(ZoomScaleRule.rule(for: .interface), .interfaceScale)
    }

    // MARK: - Clamping

    func testClampBringsValuesIntoRange() {
        for (name, rule) in allRules {
            XCTAssertEqual(rule.clamp(rule.minimum - 100), rule.minimum, name)
            XCTAssertEqual(rule.clamp(rule.maximum + 100), rule.maximum, name)
            XCTAssertEqual(rule.clamp(rule.minimum), rule.minimum, name)
            XCTAssertEqual(rule.clamp(rule.maximum), rule.maximum, name)
        }
    }

    func testClampCollapsesNonFiniteValuesToTheDefault() {
        // The NaN-recursion guard, inherited from the editor font size: `min`/
        // `max` propagate NaN, so a surviving NaN would make a clamp-in-`didSet`
        // property's `clamped != value` always true and recurse without bound.
        for (name, rule) in allRules {
            XCTAssertEqual(rule.clamp(.nan), rule.defaultValue, name)
            XCTAssertEqual(rule.clamp(.infinity), rule.defaultValue, name)
            XCTAssertEqual(rule.clamp(-.infinity), rule.defaultValue, name)
        }
    }

    func testClampDoesNotSnapToTheGrid() {
        // An arbitrary value from a slider or an older build stays put; only
        // stepping snaps.
        XCTAssertEqual(ZoomScaleRule.editorFont.clamp(13.5), 13.5)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.clamp(1.05), 1.05)
    }

    // MARK: - Stepping

    func testSteppingMovesByWholeSteps() {
        XCTAssertEqual(ZoomScaleRule.editorFont.stepped(13, by: 1), 14)
        XCTAssertEqual(ZoomScaleRule.editorFont.stepped(13, by: -2), 11)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.stepped(1.0, by: 1), 1.1)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.stepped(1.0, by: -2), 0.8)
        XCTAssertEqual(ZoomScaleRule.terminalFont.stepped(13, by: 3), 16)
    }

    func testSteppingClampsAtBothBounds() {
        for (name, rule) in allRules {
            XCTAssertEqual(rule.stepped(rule.maximum, by: 5), rule.maximum, name)
            XCTAssertEqual(rule.stepped(rule.minimum, by: -5), rule.minimum, name)
            XCTAssertEqual(rule.stepped(rule.defaultValue, by: 1000), rule.maximum, name)
            XCTAssertEqual(rule.stepped(rule.defaultValue, by: -1000), rule.minimum, name)
        }
    }

    func testSteppingByZeroSnapsButDoesNotMove() {
        XCTAssertEqual(ZoomScaleRule.editorFont.stepped(14, by: 0), 14)
        // Off-grid values are corrected once, on the first step, rather than
        // carrying a private grid of their own forever.
        XCTAssertEqual(ZoomScaleRule.interfaceScale.stepped(1.04, by: 0), 1.0)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.stepped(1.06, by: 0), 1.1)
    }

    func testSteppingRejectsNonFiniteInputs() {
        XCTAssertEqual(ZoomScaleRule.editorFont.stepped(.nan, by: 1), 14)
        XCTAssertEqual(ZoomScaleRule.editorFont.stepped(20, by: .nan), 20)
        XCTAssertEqual(ZoomScaleRule.interfaceScale.stepped(1.0, by: .infinity), 1.0)
    }

    func testNStepsUpAndNDownReturnExactlyTheStartingValue() {
        // The property the whole index-based arithmetic exists for: repeated
        // `+ 0.1` / `- 0.1` drifts in binary floating point and the interface
        // scale would never return to exactly 100%.
        for (name, rule) in allRules {
            for count in 1...6 {
                var value = rule.defaultValue
                for _ in 0..<count { value = rule.stepped(value, by: 1) }
                for _ in 0..<count { value = rule.stepped(value, by: -1) }
                XCTAssertEqual(value, rule.defaultValue, "\(name) after \(count) steps each way")
            }
        }
    }

    func testWalkingTheWholeRangeOneStepAtATimeLandsOnBothBoundsExactly() {
        for (name, rule) in allRules {
            let stepsUp = Int(((rule.maximum - rule.defaultValue) / rule.step).rounded())
            var value = rule.defaultValue
            for _ in 0..<stepsUp { value = rule.stepped(value, by: 1) }
            XCTAssertEqual(value, rule.maximum, "\(name) walking up")

            let stepsDown = Int(((rule.maximum - rule.minimum) / rule.step).rounded())
            for _ in 0..<stepsDown { value = rule.stepped(value, by: -1) }
            XCTAssertEqual(value, rule.minimum, "\(name) walking down")
        }
    }

    func testSteppingSeveralAtOnceEqualsSteppingOneAtATime() {
        for (name, rule) in allRules {
            var oneAtATime = rule.defaultValue
            for _ in 0..<4 { oneAtATime = rule.stepped(oneAtATime, by: 1) }
            XCTAssertEqual(rule.stepped(rule.defaultValue, by: 4), oneAtATime, name)
        }
    }

    func testInterfaceScaleStepsReadBackAsRoundNumbers() {
        // Not cosmetic: the value reaches `UserDefaults` and the Preferences UI,
        // and the round-trip equality above is exact only because the residue of
        // the multiply-and-add is stripped.
        var value = 1.0
        var seen: [Double] = []
        for _ in 0..<10 {
            value = ZoomScaleRule.interfaceScale.stepped(value, by: 1)
            seen.append(value)
        }
        XCTAssertEqual(seen, [1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0])
    }

    func testADegenerateStepClampsInsteadOfDividingByZero() {
        // `init` is public and validates nothing, so a rule with a zero (or
        // negative) step is constructible. Without the guard the step *index* is
        // a division by zero and `stepped` returns NaN, which `clamp` then turns
        // into the resting value — a silent reset rather than an inert step. The
        // accumulator's own degenerate-threshold case is asserted the same way.
        let degenerate = ZoomScaleRule(minimum: 0, maximum: 10, defaultValue: 5, step: 0)
        XCTAssertEqual(degenerate.stepped(7, by: 3), 7)
        XCTAssertEqual(degenerate.stepped(7, by: -3), 7)
        // Still clamped, so a degenerate rule cannot hand a layout a value out of
        // its own range.
        XCTAssertEqual(degenerate.stepped(99, by: 1), 10)
        XCTAssertEqual(degenerate.stepped(.nan, by: 1), 5)

        let negative = ZoomScaleRule(minimum: 0, maximum: 10, defaultValue: 5, step: -1)
        XCTAssertEqual(negative.stepped(7, by: 3), 7)
    }

    func testANonFiniteStepCountLeavesTheValueWhereItIs() {
        // A NaN reaching `steps` would make `index + steps` NaN and the clamp
        // collapse the zone to its resting value — the same silent reset, from
        // the other argument.
        for (name, rule) in allRules {
            let start = rule.stepped(rule.defaultValue, by: 1)
            XCTAssertEqual(rule.stepped(start, by: .nan), start, name)
            XCTAssertEqual(rule.stepped(start, by: .infinity), start, name)
            XCTAssertEqual(rule.stepped(start, by: -.infinity), start, name)
        }
    }
}
