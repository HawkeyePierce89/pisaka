import XCTest
@testable import PisakaCore

/// The chrome design system's Core half: the closed role set, the geometry
/// tokens, the appearance resolution, the tree-row state rule and the
/// severity → role mapping.
final class ChromeThemeTests: XCTestCase {

    // MARK: - Roles

    /// The whole vocabulary, spelled out. Asserted by **set equality** in both
    /// directions so a role added without a design decision — or one quietly
    /// removed while a surface still means it — fails here rather than in a
    /// screenshot.
    private static let declaredRoles: Set<String> = [
        "bgCanvas", "bgPanel", "bgEditor", "bgPopover",
        "textPrimary", "textSecondary", "onAccent",
        "hairline", "accent", "accentTint", "accentTintStrong",
        "hoverTint", "selectionInactive", "currentLine", "bracketMatch",
        "statusGreen", "statusRed", "statusYellow",
        "diffAddedBackground", "diffRemovedBackground", "conflictBackground",
    ]

    func testTheRoleSetIsExactlyTheDeclaredOne() {
        XCTAssertEqual(Set(ChromeColorRole.allCases.map(\.rawValue)), Self.declaredRoles)
        XCTAssertEqual(ChromeColorRole.allCases.count, 21)
    }

    func testEveryRoleHasADistinctRawValue() {
        XCTAssertEqual(Set(ChromeColorRole.allCases.map(\.rawValue)).count, ChromeColorRole.allCases.count)
    }

    func testEveryRoleRoundTripsThroughItsRawValue() {
        for role in ChromeColorRole.allCases {
            XCTAssertEqual(ChromeColorRole(rawValue: role.rawValue), role)
        }
    }

    // MARK: - Geometry

    /// The numbers are the chrome design's own table, deliberately *not* the
    /// metrics the app happened to draw with before it.
    func testGeometryTokensCarryTheirTableValues() {
        XCTAssertEqual(ChromeGeometry.rowHeight, 24)
        XCTAssertEqual(ChromeGeometry.rowPaddingX, 8)
        XCTAssertEqual(ChromeGeometry.treeIndentStep, 16)
        XCTAssertEqual(ChromeGeometry.cornerRadiusMax, 6)
        XCTAssertEqual(ChromeGeometry.hairlineWidth, 1)
        XCTAssertEqual(ChromeGeometry.tabStripHeight, 32)
        XCTAssertEqual(ChromeGeometry.verticalTabRowHeight, 28)
        XCTAssertEqual(ChromeGeometry.dockTabRowHeight, 28)
        XCTAssertEqual(ChromeGeometry.sidebarHeaderHeight, 32)
        XCTAssertEqual(ChromeGeometry.bottomBarHeight, 28)
        XCTAssertEqual(ChromeGeometry.barPaddingX, 12)
        XCTAssertEqual(ChromeGeometry.breadcrumbHeight, 24)
        XCTAssertEqual(ChromeGeometry.bottomBarToggleSide, 22)
        XCTAssertEqual(ChromeGeometry.bottomBarToggleRadius, 4)
        XCTAssertEqual(ChromeGeometry.panelHeaderHeight, 28)
        XCTAssertEqual(ChromeGeometry.panelHeaderPaddingX, 14)
        XCTAssertEqual(ChromeGeometry.dockTabRowPaddingX, 10)
        XCTAssertEqual(ChromeGeometry.dockTabLabelPaddingX, 10)
        XCTAssertEqual(ChromeGeometry.accentIndicator, 2)
        XCTAssertEqual(ChromeGeometry.buttonPaddingX, 10)
        XCTAssertEqual(ChromeGeometry.buttonCornerRadius, 5)
    }

    /// `ChromeGeometry` is a namespace of `static let`s, so its membership is
    /// invisible to the type system at run time. Read the declaration out of the
    /// source file instead — the same `#filePath` technique the repository-file
    /// suites use — and pin it by set equality, which is what makes "and no font
    /// size" an assertion rather than a comment: a `fontSizeBody` added here
    /// fails this test, and the three chrome text sizes stay where they already
    /// live (pinned below).
    func testGeometryDeclaresExactlyTheseTokensAndNoFontSize() throws {
        let source = try Self.readCoreSource("ChromeGeometry.swift")
        let declared = Self.staticLetNames(in: source)
        XCTAssertEqual(declared, [
            "rowHeight", "rowPaddingX", "treeIndentStep", "cornerRadiusMax", "hairlineWidth",
            "tabStripHeight", "verticalTabRowHeight", "dockTabRowHeight", "sidebarHeaderHeight",
            "bottomBarHeight", "barPaddingX", "breadcrumbHeight", "bottomBarToggleSide",
            "bottomBarToggleRadius", "panelHeaderHeight", "panelHeaderPaddingX", "dockTabRowPaddingX",
            "dockTabLabelPaddingX", "accentIndicator", "buttonPaddingX", "buttonCornerRadius",
        ])
        for suspect in ["font", "Font", "fontSize", "textSize"] {
            XCTAssertFalse(
                declared.contains(where: { $0.localizedCaseInsensitiveContains(suspect) }),
                "ChromeGeometry must carry no font size: found a token naming \(suspect)"
            )
        }
    }

    /// Where the three chrome text sizes actually live. Pinned here so the
    /// "no second table" decision above has something to point at.
    func testTheChromeTextSizesLiveInTheInterfaceTypeScale() {
        XCTAssertEqual(InterfaceTextStyle.body.basePointSize, 13)
        XCTAssertEqual(InterfaceTextStyle.callout.basePointSize, 12)
        XCTAssertEqual(InterfaceTextStyle.subheadline.basePointSize, 11)
    }

    // MARK: - Appearance

    func testAppearanceResolutionIsTotalOverEveryPreferenceAndSystemAnswer() {
        for systemPrefersDark in [true, false] {
            XCTAssertEqual(ChromeAppearance.resolved(.dark, systemPrefersDark: systemPrefersDark), .dark)
            XCTAssertEqual(ChromeAppearance.resolved(.light, systemPrefersDark: systemPrefersDark), .light)
        }
        XCTAssertEqual(ChromeAppearance.resolved(.system, systemPrefersDark: true), .dark)
        XCTAssertEqual(ChromeAppearance.resolved(.system, systemPrefersDark: false), .light)
        XCTAssertEqual(ThemePreference.allCases.count, 3)
        XCTAssertEqual(ChromeAppearance.allCases, [.dark, .light])
    }

    // MARK: - The tree-row state rule

    /// One row of the truth table below. A named type rather than a tuple: five
    /// positional booleans-and-a-case read as noise, and the style authority
    /// caps a tuple at four members for exactly that reason.
    private struct Case {
        let selected: Bool
        let key: Bool
        let hover: Bool
        let drop: Bool
        let answer: TreeRowState
    }

    /// Exhaustive over all sixteen inputs, written out rather than computed, so
    /// the precedence is readable as a table.
    func testRowStateIsExhaustiveOverEveryInput() {
        let expected: [Case] = [
            Case(selected: false, key: false, hover: false, drop: false, answer: .plain),
            Case(selected: false, key: false, hover: false, drop: true, answer: .dropTarget),
            Case(selected: false, key: false, hover: true, drop: false, answer: .hover),
            Case(selected: false, key: false, hover: true, drop: true, answer: .dropTarget),
            Case(selected: false, key: true, hover: false, drop: false, answer: .plain),
            Case(selected: false, key: true, hover: false, drop: true, answer: .dropTarget),
            Case(selected: false, key: true, hover: true, drop: false, answer: .hover),
            Case(selected: false, key: true, hover: true, drop: true, answer: .dropTarget),
            Case(selected: true, key: false, hover: false, drop: false, answer: .selectedUnfocused),
            Case(selected: true, key: false, hover: false, drop: true, answer: .dropTarget),
            Case(selected: true, key: false, hover: true, drop: false, answer: .selectedUnfocused),
            Case(selected: true, key: false, hover: true, drop: true, answer: .dropTarget),
            Case(selected: true, key: true, hover: false, drop: false, answer: .selectedFocused),
            Case(selected: true, key: true, hover: false, drop: true, answer: .dropTarget),
            Case(selected: true, key: true, hover: true, drop: false, answer: .selectedFocused),
            Case(selected: true, key: true, hover: true, drop: true, answer: .dropTarget),
        ]
        XCTAssertEqual(expected.count, 16)
        for row in expected {
            XCTAssertEqual(
                TreeRowState.state(
                    isSelected: row.selected,
                    isWindowKey: row.key,
                    isHovering: row.hover,
                    isDropTarget: row.drop
                ),
                row.answer,
                "selected=\(row.selected) key=\(row.key) hover=\(row.hover) drop=\(row.drop)"
            )
        }
    }

    /// The precedence cases, named, so a reordering of the rule fails with a
    /// sentence rather than with a row index.
    func testDropTargetOutranksSelectionAndSelectionOutranksHover() {
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: true, isHovering: true, isDropTarget: true),
            .dropTarget
        )
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: true, isHovering: true, isDropTarget: false),
            .selectedFocused
        )
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: false, isHovering: true, isDropTarget: false),
            .selectedUnfocused
        )
        XCTAssertEqual(
            TreeRowState.state(isSelected: false, isWindowKey: true, isHovering: true, isDropTarget: false),
            .hover
        )
    }

    /// The three combinations the project tree's two row kinds actually ask the
    /// rule for, named after the gesture that produces each — so the rows' own
    /// reading of the rule is stated in `swift test` rather than only in the
    /// views that do the asking.
    ///
    /// A file row asks with `isDropTarget: false` always (a file is not a drop
    /// destination) and a folder row with `isSelected: false` always (selection
    /// is derived from the active editor tab, and a folder is never one), which
    /// is why these three and not the whole product are the interesting ones.
    func testTheRowsAskFortheseThreeCombinations() {
        // The pointer passes over the row the editor is currently showing, in
        // the front window: it stays legible as *the* selected row.
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: true, isHovering: true, isDropTarget: false),
            .selectedFocused
        )
        // The same row, once the window resigns key — the selection is still
        // there to be seen, without claiming focus it no longer has.
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: false, isHovering: true, isDropTarget: false),
            .selectedUnfocused
        )
        // A drag hovering a folder row that also happens to be selected: the
        // question on screen is where the drop lands, so the drop answers.
        XCTAssertEqual(
            TreeRowState.state(isSelected: true, isWindowKey: true, isHovering: true, isDropTarget: true),
            .dropTarget
        )
    }

    // MARK: - Severity

    /// Severity → chrome role, the one answer both the gutter's dot and the
    /// Problems panel read: the four answers pinned verbatim, and **pairwise
    /// distinct** as roles, so two severities can never share a mark. The app
    /// bundle's gutter suite pins the other half the Core gate cannot see — that
    /// the four roles also *resolve* to four different colours under both
    /// appearances.
    func testEverySeverityMapsToItsChromeRole() {
        let expected: [(DiagnosticSeverity, ChromeColorRole)] = [
            (.error, .statusRed),
            (.warning, .statusYellow),
            (.information, .accent),
            (.hint, .textSecondary),
        ]
        for (severity, role) in expected {
            XCTAssertEqual(
                ChromeColorRole.diagnosticRole(for: severity), role,
                "\(severity) should be drawn in \(role.rawValue)"
            )
        }
        let answers = expected.map { ChromeColorRole.diagnosticRole(for: $0.0) }
        XCTAssertEqual(Set(answers).count, answers.count, "two severities share one role: \(answers)")
    }

    // MARK: - Reading the source file

    private static func readCoreSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PisakaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/PisakaCore")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The names of every `public static let` declared in `source`, in
    /// declaration order, read off comment-stripped text.
    private static func staticLetNames(in source: String) -> [String] {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(source)
            .split(separator: "\n")
            .compactMap { line in
                let words = line.split(whereSeparator: { $0 == " " || $0 == ":" })
                guard words.count >= 4, words[0] == "public", words[1] == "static", words[2] == "let" else {
                    return nil
                }
                return String(words[3])
            }
    }
}
