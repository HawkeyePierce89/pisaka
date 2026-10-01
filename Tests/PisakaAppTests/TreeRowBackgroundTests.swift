#if os(macOS)
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's state-to-role mapping, and the claim that it composes no
/// alpha.
///
/// `TreeRowBackground` is the one place a `TreeRowState` becomes a colour, read by
/// both tree row kinds and by the commit dialog's file row. This suite pins two
/// things about it: which role each state answers (`nil` for `.plain` alone), and
/// that `color(for:resolving:)` hands back exactly the colour the resolver gave
/// for that role — no `.opacity` chained on top, so a wash's strength is the
/// palette's and the tree cannot drift back to composing one.
///
/// What it leaves to others: the palette's values, `dropTargetTint`'s among them,
/// are `ChromePaletteTests`' business, and the precedence between the four facts
/// a row can show is Core's (`TreeRowState`'s own tests).
final class TreeRowBackgroundTests: XCTestCase {

    func testEveryStateButPlainAnswersARole() {
        let expected: [TreeRowState: ChromeColorRole?] = [
            .plain: nil,
            .hover: .hoverTint,
            .selectedFocused: .accentTintStrong,
            .selectedUnfocused: .selectionInactive,
            .dropTarget: .dropTargetTint,
        ]
        XCTAssertEqual(Set(expected.keys), Set(TreeRowState.allCases))
        for state in TreeRowState.allCases {
            XCTAssertEqual(TreeRowBackground.role(for: state), expected[state] ?? nil, "\(state)")
        }
        let roleless = TreeRowState.allCases.filter { TreeRowBackground.role(for: $0) == nil }
        XCTAssertEqual(roleless, [.plain])
    }

    func testTheColourIsTheResolversAnswerWithNoAlphaComposed() {
        // A distinct, recognizable colour per role, so the colour that comes back
        // can be compared to the one the resolver handed over.
        let colours = Dictionary(uniqueKeysWithValues: ChromeColorRole.allCases.enumerated().map { index, role in
            (role, Color(red: Double(index + 1) / 64, green: 0.25, blue: 0.5))
        })

        for state in TreeRowState.allCases {
            var asked: [ChromeColorRole] = []
            let colour = TreeRowBackground.color(for: state) { role in
                asked.append(role)
                return colours[role] ?? Color.clear
            }

            if let role = TreeRowBackground.role(for: state) {
                XCTAssertEqual(asked, [role], "\(state) must ask its own role exactly once")
                XCTAssertEqual(colour, colours[role], "\(state) must return the resolver's colour unchanged")
            } else {
                XCTAssertEqual(asked, [], "\(state) must not ask the resolver")
                XCTAssertEqual(colour, Color.clear, "\(state) paints nothing")
            }
        }
    }
}
#endif
