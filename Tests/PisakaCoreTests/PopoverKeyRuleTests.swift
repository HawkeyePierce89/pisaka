import XCTest
@testable import PisakaCore

/// `PopoverKeyRule` over every (key, state) pair — 7 keys × 8 states — against
/// one literal table, plus named assertions for the properties the table is
/// built around.
final class PopoverKeyRuleTests: XCTestCase {
    private struct Case: Hashable {
        let key: PopoverKey
        let state: PopoverKeyState
    }

    private static func state(_ open: Bool, _ selected: Bool, _ submenu: Bool) -> PopoverKeyState {
        PopoverKeyState(submenuOpen: open, hasSelection: selected, selectedHasSubmenu: submenu)
    }

    /// The column order of every row below.
    private static let keyOrder: [PopoverKey] = [.up, .down, .return, .escape, .left, .right, .other]

    /// One row per state — (submenuOpen, hasSelection, selectedHasSubmenu) —
    /// and one action per key in `keyOrder`.
    private static let table: [(PopoverKeyState, [PopoverKeyAction])] = [
        (state(false, false, false), [.passThrough, .passThrough, .passThrough, .dismiss, .passThrough, .passThrough, .passThrough]),
        (state(false, false, true), [.passThrough, .passThrough, .passThrough, .dismiss, .passThrough, .passThrough, .passThrough]),
        (state(false, true, false), [.moveUp, .moveDown, .activate, .dismiss, .passThrough, .passThrough, .passThrough]),
        (state(false, true, true), [.moveUp, .moveDown, .openSubmenu, .dismiss, .passThrough, .openSubmenu, .passThrough]),
        (state(true, false, false), [.passThrough, .passThrough, .passThrough, .closeSubmenu, .closeSubmenu, .passThrough, .passThrough]),
        (state(true, false, true), [.passThrough, .passThrough, .passThrough, .closeSubmenu, .closeSubmenu, .passThrough, .passThrough]),
        (state(true, true, false), [.moveUp, .moveDown, .activate, .closeSubmenu, .closeSubmenu, .passThrough, .passThrough]),
        (state(true, true, true), [.moveUp, .moveDown, .activate, .closeSubmenu, .closeSubmenu, .passThrough, .passThrough]),
    ]

    private static var allStates: [PopoverKeyState] {
        [false, true].flatMap { open in
            [false, true].flatMap { selected in
                [false, true].map { submenu in state(open, selected, submenu) }
            }
        }
    }

    private static var expected: [Case: PopoverKeyAction] {
        var result: [Case: PopoverKeyAction] = [:]
        for (state, actions) in table {
            for (key, action) in zip(keyOrder, actions) {
                result[Case(key: key, state: state)] = action
            }
        }
        return result
    }

    func testTheTableCoversEveryKeyAndStateExactly() {
        XCTAssertEqual(Set(Self.keyOrder.map { "\($0)" }), Set(PopoverKey.allCases.map { "\($0)" }))
        XCTAssertTrue(Self.table.allSatisfy { $0.1.count == Self.keyOrder.count })
        let everyPair = Set(PopoverKey.allCases.flatMap { key in
            Self.allStates.map { Case(key: key, state: $0) }
        })
        XCTAssertEqual(everyPair.count, 56)
        XCTAssertEqual(Set(Self.expected.keys), everyPair)
    }

    func testEveryPairAnswersItsTableEntry() {
        for (pair, action) in Self.expected {
            XCTAssertEqual(
                PopoverKeyRule.action(for: pair.key, state: pair.state),
                action,
                "key=\(pair.key) state=\(pair.state)"
            )
        }
    }

    func testOtherPassesThroughInAllEightStatesSoTheFieldKeepsTyping() {
        for state in Self.allStates {
            XCTAssertEqual(PopoverKeyRule.action(for: .other, state: state), .passThrough, "\(state)")
        }
    }

    func testArrowsSidewaysPassThroughWheneverTheyMeanNothing() {
        for state in Self.allStates where !state.submenuOpen {
            XCTAssertEqual(PopoverKeyRule.action(for: .left, state: state), .passThrough, "\(state)")
        }
        for state in Self.allStates where state.submenuOpen {
            XCTAssertEqual(PopoverKeyRule.action(for: .right, state: state), .passThrough, "\(state)")
        }
        XCTAssertEqual(PopoverKeyRule.action(for: .right, state: Self.state(false, true, false)), .passThrough)
    }

    func testEscapeClosesTheSubmenuAloneWhenOpenAndDismissesOtherwise() {
        for state in Self.allStates {
            XCTAssertEqual(
                PopoverKeyRule.action(for: .escape, state: state),
                state.submenuOpen ? .closeSubmenu : .dismiss,
                "\(state)"
            )
        }
    }

    func testReturnOnARowWithASubmenuOpensItRatherThanActivating() {
        XCTAssertEqual(PopoverKeyRule.action(for: .return, state: Self.state(false, true, true)), .openSubmenu)
        XCTAssertEqual(PopoverKeyRule.action(for: .return, state: Self.state(false, true, false)), .activate)
    }

    func testTheImpossibleCombinationReadsAsNoSelection() {
        for key in PopoverKey.allCases {
            XCTAssertEqual(
                PopoverKeyRule.action(for: key, state: Self.state(false, false, true)),
                PopoverKeyRule.action(for: key, state: Self.state(false, false, false)),
                "\(key)"
            )
        }
    }
}
