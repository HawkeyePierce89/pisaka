#if os(macOS)
import AppKit
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
/// The tree rows paint through the layered `background(for:isTestRow:resolving:)`
/// rather than `color(for:resolving:)`, which the commit dialog's file row keeps:
/// `layers(for:isTestRow:)` is pinned over all ten state × test-row combinations
/// — the wash role first, the state's role over it, nothing for a plain row that
/// is no test row — and the layered background is pinned to ask the resolver
/// once per layer and hand each colour back unchanged.
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

    func testTheLayersAreTheWashFirstThenTheStatesRole() {
        let expected: [TreeRowState: ChromeColorRole?] = [
            .plain: nil,
            .hover: .hoverTint,
            .selectedFocused: .accentTintStrong,
            .selectedUnfocused: .selectionInactive,
            .dropTarget: .dropTargetTint,
        ]
        XCTAssertEqual(Set(expected.keys), Set(TreeRowState.allCases))
        for state in TreeRowState.allCases {
            let stateRole = expected[state] ?? nil
            XCTAssertEqual(
                TreeRowBackground.layers(for: state, isTestRow: false),
                [stateRole].compactMap { $0 },
                "\(state), not a test row: the state's role alone"
            )
            XCTAssertEqual(
                TreeRowBackground.layers(for: state, isTestRow: true),
                [.diffAddedBackground] + [stateRole].compactMap { $0 },
                "\(state), a test row: the wash first, the state's role over it"
            )
        }
        XCTAssertEqual(TreeRowBackground.layers(for: .plain, isTestRow: false), [], "a plain row that is no test row")
    }

    func testTheLayeredBackgroundIsTheResolversAnswersWithNoAlphaComposed() {
        let colours = Dictionary(uniqueKeysWithValues: ChromeColorRole.allCases.enumerated().map { index, role in
            (role, Color(red: Double(index + 1) / 64, green: 0.25, blue: 0.5))
        })

        for state in TreeRowState.allCases {
            for isTestRow in [false, true] {
                var asked: [ChromeColorRole] = []
                let background = TreeRowBackground.background(for: state, isTestRow: isTestRow) { role in
                    asked.append(role)
                    return colours[role] ?? Color.clear
                }
                let layers = TreeRowBackground.layers(for: state, isTestRow: isTestRow)
                XCTAssertEqual(asked, layers, "\(state), test row \(isTestRow): the resolver is asked once per layer")
                XCTAssertEqual(
                    background.colors, layers.map { colours[$0] ?? Color.clear },
                    "\(state), test row \(isTestRow): each layer is the resolver's colour unchanged, bottom to top"
                )
            }
        }
    }

    /// "Bottom to top" is `Layered`'s drawing, not only its array's order: two
    /// opaque colours, rendered once, show the last. Reversed, the wash would
    /// paint over the state's tint and every bitmap suite comparing washed
    /// rows to each other would still pass.
    @MainActor
    func testTheLayeredBackgroundPaintsItsLastColourOnTop() throws {
        let render = try HostedRender(
            size: CGSize(width: 20, height: 20),
            root: TreeRowBackground.Layered(colors: [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 0, blue: 1)])
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let pixel = try XCTUnwrap(render.color(atX: 10, y: 10), "no pixel in the layered background")
        XCTAssertGreaterThan(pixel.blueComponent, 0.9, "the last colour is not on top: \(pixel)")
        XCTAssertLessThan(pixel.redComponent, 0.1, "the first colour shows over the last: \(pixel)")
    }
}
#endif
