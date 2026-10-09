#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The chrome's focus border on the three surfaces that carry one — the
/// database grid's focused cell, the selected row of the problem browser's
/// focused list and of the Acknowledgements dependency list — hosted in a real
/// window and measured off a rendered bitmap.
///
/// **The rule.** What holds the keyboard keeps its `accentTintStrong` wash and
/// draws, over it, an `accent` border at the scaled `fieldFocusedBorderWidth`
/// — the shared field's own focused stroke — and nothing of it while it does
/// not. The platform's focus ring is disabled on every one of these chains
/// (`ChromeThemeSourceGatingTests`' rule forty-nine); this suite pins what is
/// drawn in its place.
///
/// **How it is measured.** Each surface is hosted on its `bgPanel` ground, and
/// one pixel column inside the row's horizontal padding — clear of any text —
/// is scanned top to bottom: a border is the run of `accent` pixels at each
/// end of the column, the wash the `accentTintStrong`-over-`bgPanel` pixels
/// between them. Widths are compared within one pixel.
@MainActor
final class FocusBorderLayoutTests: XCTestCase {

    private static let size = CGSize(width: 240, height: 40)

    func testAFocusedGridCellDrawsTheAccentBorderAtTheFocusedWidth() throws {
        for scale in [1.0, 1.5] {
            let render = try Self.host(scale: scale) {
                Text("value")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(DatabaseGridCellFocus(isFocused: true))
            }
            let column = Self.column(render, atX: 3)
            Self.assertBorder(column, render: render, scale: scale, "the focused grid cell at \(scale)")
            XCTAssertTrue(column.contains(.wash), "the focused cell lost its accentTintStrong fill at \(scale)")
        }
    }

    func testAnUnfocusedGridCellDrawsNeitherBorderNorWash() throws {
        let render = try Self.host(scale: 1) {
            Text("value")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(DatabaseGridCellFocus(isFocused: false))
        }
        let column = Self.column(render, atX: 3)
        XCTAssertFalse(column.contains(.border), "an unfocused cell draws the focus border")
        XCTAssertFalse(column.contains(.wash), "an unfocused cell draws the selection wash")
    }

    func testTheSelectedAcknowledgementsRowDrawsAccentTintStrong() throws {
        let render = try Self.host(scale: 1) {
            AcknowledgementsRow(
                document: Self.document, isSelected: true, showsFocusBorder: false, onSelect: {}
            )
        }
        let column = Self.column(render, atX: 3)
        XCTAssertTrue(column.contains(.wash), "the selected dependency row does not draw accentTintStrong")
        XCTAssertFalse(column.contains(.border), "an unfocused list's selected row draws the focus border")
    }

    func testTheFocusedAcknowledgementsRowDrawsTheBorder() throws {
        for scale in [1.0, 1.5] {
            let render = try Self.host(scale: scale) {
                AcknowledgementsRow(
                    document: Self.document, isSelected: true, showsFocusBorder: true, onSelect: {}
                )
            }
            let column = Self.column(render, atX: 3)
            Self.assertBorder(column, render: render, scale: scale, "the focused dependency row at \(scale)")
            XCTAssertTrue(column.contains(.wash), "the focused dependency row lost its wash at \(scale)")
        }
    }

    func testTheFocusedBrowserRowDrawsTheBorder() throws {
        for scale in [1.0, 1.5] {
            let render = try Self.host(scale: scale) {
                LeetCodeBrowserRow(
                    problem: Self.problem, isSelected: true, showsFocusBorder: true, onSelect: {}, onOpen: {}
                )
            }
            let column = Self.column(render, atX: 3)
            Self.assertBorder(column, render: render, scale: scale, "the focused browser row at \(scale)")
            XCTAssertTrue(column.contains(.wash), "the focused browser row lost its wash at \(scale)")
        }
    }

    func testAnUnfocusedBrowserRowDrawsNoBorder() throws {
        let render = try Self.host(scale: 1) {
            LeetCodeBrowserRow(
                problem: Self.problem, isSelected: true, showsFocusBorder: false, onSelect: {}, onOpen: {}
            )
        }
        let column = Self.column(render, atX: 3)
        XCTAssertTrue(column.contains(.wash), "the selected browser row does not draw accentTintStrong")
        XCTAssertFalse(column.contains(.border), "an unfocused list's selected row draws the focus border")
    }

    // MARK: - Harness

    private static let document = LicenseDocument(
        notice: LicenseNotice(
            id: "example", name: "Example", origin: "https://example.com/example",
            version: "1.0.0", revision: String(repeating: "0", count: 40), spdx: "MIT", file: "example.txt"
        ),
        text: "Permission is hereby granted."
    )

    private static let problem = LeetCodeProblem(
        frontendID: 1, slug: "two-sum", title: "Two Sum", difficulty: .easy, isPaidOnly: false
    )

    /// What one pixel of a scanned column is.
    private enum Pixel: Equatable {
        case border, wash, other
    }

    /// `content` at `scale` on the dark `bgPanel` ground, sized to fill the
    /// window's width and the row's own height.
    private static func host<V: View>(scale: Double, @ViewBuilder content: () -> V) throws -> HostedRender {
        let theme = ChromeTheme(.dark)
        let root = content()
            .frame(width: size.width * scale)
            .frame(maxHeight: .infinity)
            .environment(\.interfaceMetrics, InterfaceMetrics(scale: scale))
            .environment(\.chromeTheme, theme)
            .background(theme.color(.bgPanel))
        return try HostedRender(size: CGSize(width: size.width * scale, height: size.height * scale), root: root)
    }

    /// The column at `x` points, top to bottom, one entry per pixel row, each
    /// classified against the `accent` and `accentTintStrong`-over-`bgPanel`
    /// swatches.
    private static func column(_ render: HostedRender, atX x: CGFloat) -> [Pixel] {
        let ground = ChromeTheme(.dark).color(.bgPanel)
        return stride(from: 0, to: render.bounds.height, by: 1 / render.pixelScale).map { y in
            if render.matches(.accent, atX: x, y: y, ground: ground) { return .border }
            if render.matches(.accentTintStrong, atX: x, y: y, ground: ground) { return .wash }
            return .other
        }
    }

    /// The column's leading run of `accent` pixels is one focused-border width
    /// at `scale`, and so is its trailing run, with wash between them.
    private static func assertBorder(
        _ column: [Pixel], render: HostedRender, scale: Double, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = render.pixelScale * CGFloat(ChromeGeometry.fieldFocusedBorderWidth * scale)
        guard let first = column.firstIndex(of: .border), let last = column.lastIndex(of: .border) else {
            XCTFail("\(what) draws no accent border", file: file, line: line)
            return
        }
        let top = column[first...].prefix { $0 == .border }.count
        let bottom = column[...last].reversed().prefix { $0 == .border }.count
        XCTAssertEqual(CGFloat(top), expected, accuracy: 1, "\(what): the top border is not the focused width", file: file, line: line)
        XCTAssertEqual(
            CGFloat(bottom), expected, accuracy: 1, "\(what): the bottom border is not the focused width", file: file, line: line
        )
        XCTAssertTrue(
            column[first..<last].contains(.wash), "\(what): no wash between the borders", file: file, line: line
        )
    }
}
#endif
