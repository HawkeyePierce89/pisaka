#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The language-server consent bar, the shipped `LSPConsentBar`, hosted in a
/// real window and measured off a rendered bitmap.
///
/// **The geometry.** The bar runs the window's full width on the panel ground,
/// `bgPanel`, nothing inset. Its row is padded 14 points vertically and 18
/// horizontally around a 28-point content height — the shared buttons' — and a
/// one-hairline `hairline` rule runs along its bottom, every length scaling
/// with the interface; there is no radius, no border and no band around it.
/// The text column takes all the width the actions leave, so a primary line
/// that fits beside the actions is drawn on one line rather than wrapping at
/// about half the width it could use.
///
/// **How the ground and the rule are measured.** One render per scale, the bar
/// pinned to the top of a taller window. The pixel half a point in from the
/// window's top-leading corner reads `bgPanel`, so nothing is inset, and so does
/// the bar's ground at the window's horizontal middle, inside the top padding. A column through the
/// leading padding carries `hairline` only at the bottom rule: that extent is
/// one scaled hairline tall, and its `maxY` — the bar's height — is the scaled
/// 14 + 28 + 14 plus the scaled hairline, both within 0.6. The rule reads
/// `hairline` half a point in from both window edges and at the middle, so it
/// spans the full width, and the pixel just below it is the window's ground,
/// not `bgPanel`.
///
/// **How the text column is measured.** The bar is rendered at a generous
/// width. Across every row above the rule, the primary button's leading edge
/// is the first `accent` pixel right of the bar's middle (the minimum over
/// rows), and the line's trailing edge is the last non-`bgPanel` pixel left of
/// that edge (the maximum over rows; one row cannot stand in, since a row
/// through the last character may carry no ink). A narrow width is derived from
/// those two, never from button widths: it leaves the line exactly its room
/// beside the spacer's 16-point minimum, plus a small slack. Rendered again at
/// that width the bar must keep its height, which it does only if the text
/// column reaches the actions. The generous render must itself be as tall as a
/// bar whose line is one word, or a column capped short of the actions would
/// wrap both renders alike and the comparison would hold vacuously.
///
/// **How the secondary line is measured.** A one-word primary line over a
/// secondary line long enough to wrap, checked to have wrapped against a bar
/// whose secondary line is one word. The widest ink left of the primary button
/// across the rows above the rule is then the secondary line's, and it must
/// reach past three quarters of the column — from the scaled 18 + 16 + 10 to
/// the spacer's minimum before the actions, less at most one ordinary word —
/// where a line wrapping at half the column would stop short.
///
/// **What mutation showed.** A text column capped at 400 points fails both
/// width tests.
///
/// Hosting, settling and colour comparison are `HostedRender`'s.
@MainActor
final class LSPConsentBarLayoutTests: XCTestCase {

    private static let message =
        "Download the TypeScript/JavaScript language server (52.2 MB) for completion and Go to Definition?"

    func testTheBarAtScaleOne() throws {
        try assertBar(scale: 1)
    }

    func testTheBarAtScaleOnePointEight() throws {
        try assertBar(scale: 1.8)
    }

    func testThePrimaryLineTakesTheWholeTextColumn() throws {
        let metrics = InterfaceMetrics(scale: 1)
        let generousWidth = metrics.scaled(1_100)
        let generous = try render(width: generousWidth, metrics: metrics)
        let generousRule = try rule(generous, metrics: metrics)

        // One line at the generous width: as tall as a bar whose line is a
        // single word, or a column capped short of the actions would wrap both
        // renders alike and the comparison below would hold vacuously.
        let oneWord = try render(width: generousWidth, metrics: metrics, message: "Download?")
        let oneLine = try rule(oneWord, metrics: metrics)
        XCTAssertEqual(
            generousRule.maxY, oneLine.maxY, accuracy: 0.6,
            "at \(generousWidth) points the primary line already wrapped"
        )

        let step = 1 / generous.pixelScale
        let rows = Array(stride(from: step, to: generousRule.minY - step, by: step))
        XCTAssertFalse(rows.isEmpty, "the bar has no rows above its rule")

        // The primary button's leading edge: the first `accent` pixel right of
        // the bar's middle, the minimum over every row above the rule.
        var buttonEdge = generousWidth
        for y in rows {
            var x = generousWidth / 2
            while x < buttonEdge {
                if generous.matches(.accent, atX: x, y: y) {
                    buttonEdge = x
                    break
                }
                x += step
            }
        }
        XCTAssertLessThan(buttonEdge, generousWidth, "no primary button was drawn")

        // The line's trailing edge: the last non-`bgPanel` pixel left of the
        // button, the maximum over every row above the rule.
        var lineEdge: CGFloat = 0
        for y in rows {
            var x = buttonEdge - step
            while x > lineEdge {
                if !generous.matches(.bgPanel, atX: x, y: y) {
                    lineEdge = x + step
                    break
                }
                x -= step
            }
        }
        XCTAssertGreaterThan(lineEdge, 0, "no primary line was drawn")

        // Exactly the line's room beside the spacer's minimum, plus a slack
        // for the last glyph's trailing bearing.
        let narrowWidth = generousWidth - (buttonEdge - lineEdge) + metrics.scaled(16) + metrics.scaled(4)
        XCTAssertLessThan(narrowWidth, generousWidth, "the generous width left no spare room to take away")
        let narrow = try render(width: narrowWidth, metrics: metrics)
        let narrowRule = try rule(narrow, metrics: metrics)

        XCTAssertEqual(
            narrowRule.maxY, generousRule.maxY, accuracy: 0.6,
            "at \(narrowWidth) points the primary line wrapped although the text column had room for it"
        )
    }

    func testTheSecondaryLineWrapsAcrossTheWholeTextColumn() throws {
        let metrics = InterfaceMetrics(scale: 1)
        let width = metrics.scaled(1_100)
        // A one-word primary line, so the widest ink left of the actions is
        // the secondary line's; ordinary words, so its ragged edge is at most
        // one word short of the column's end.
        let longDetail = Array(repeating: "Built with your own toolchain into a folder of its own.", count: 8)
            .joined(separator: " ")
        let wrapped = try render(width: width, metrics: metrics, message: "Download?", detail: longDetail)
        let wrappedRule = try rule(wrapped, metrics: metrics)
        let short = try render(width: width, metrics: metrics, message: "Download?", detail: "Built.")
        let shortRule = try rule(short, metrics: metrics)
        XCTAssertGreaterThan(
            wrappedRule.maxY, shortRule.maxY + metrics.scaled(8),
            "the long secondary line did not wrap, so the measurement below would hold vacuously"
        )

        let step = 1 / wrapped.pixelScale
        let rows = Array(stride(from: step, to: wrappedRule.minY - step, by: step))
        var buttonEdge = width
        for y in rows {
            var x = width / 2
            while x < buttonEdge {
                if wrapped.matches(.accent, atX: x, y: y) {
                    buttonEdge = x
                    break
                }
                x += step
            }
        }
        XCTAssertLessThan(buttonEdge, width, "no primary button was drawn")
        var lineEdge: CGFloat = 0
        for y in rows {
            var x = buttonEdge - step
            while x > lineEdge {
                if !wrapped.matches(.bgPanel, atX: x, y: y) {
                    lineEdge = x + step
                    break
                }
                x -= step
            }
        }

        // The column runs from past the padding, icon and gap — nothing is
        // inset — to the spacer's 16-point minimum before the actions. A line
        // wrapping at half of it ends far short of three quarters.
        let columnStart = metrics.scaled(18 + 16 + 10)
        let columnEnd = buttonEdge - metrics.scaled(16)
        XCTAssertGreaterThan(
            lineEdge, columnStart + (columnEnd - columnStart) * 0.75,
            "the secondary line wraps at \(lineEdge) points, short of a column ending at \(columnEnd)"
        )
    }

    private func assertBar(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let width = metrics.scaled(900)
        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let render = try render(width: width, metrics: metrics)
        let rule = try rule(render, metrics: metrics, file: file, line: line)
        let step = 1 / render.pixelScale

        XCTAssertTrue(
            render.matches(.bgPanel, atX: 0.5, y: 0.5),
            "the window's top-leading corner is not bgPanel at scale \(scale); the bar is inset",
            file: file, line: line
        )
        // Inside the top padding, clear of the line's ink at every scale.
        XCTAssertTrue(
            render.matches(.bgPanel, atX: width / 2, y: metrics.scaled(7)),
            "the bar's ground at the middle is not bgPanel at scale \(scale)", file: file, line: line
        )

        XCTAssertEqual(
            rule.maxY - rule.minY, hairline, accuracy: 0.6,
            "the bottom rule at scale \(scale) is not one scaled hairline tall", file: file, line: line
        )
        XCTAssertEqual(
            rule.maxY, metrics.scaled(14 + 28 + 14) + hairline, accuracy: 0.6,
            "the bar at scale \(scale) is not the scaled 14 + 28 + 14 plus a hairline tall", file: file, line: line
        )

        let ruleY = (rule.minY + rule.maxY) / 2
        for x in [step / 2, width / 2, width - step / 2] {
            XCTAssertTrue(
                render.matches(.hairline, atX: x, y: ruleY),
                "the bottom rule at scale \(scale) is missing at x \(x); it does not span the width",
                file: file, line: line
            )
        }
        XCTAssertFalse(
            render.matches(.bgPanel, atX: width / 2, y: rule.maxY + step / 2),
            "below the rule at scale \(scale) is still bgPanel, not the window's ground", file: file, line: line
        )
    }

    /// The bar with the download arrow, the primary line, the secondary line
    /// when one is given and no-op actions, pinned to the top of a window taller than it.
    private func render(
        width: CGFloat,
        metrics: InterfaceMetrics,
        message: String = LSPConsentBarLayoutTests.message,
        detail: String? = nil
    ) throws -> HostedRender {
        let render = try HostedRender(
            size: CGSize(width: width, height: metrics.scaled(200)),
            root: LSPConsentBar(
                symbolName: "arrow.down.circle",
                message: message,
                detail: detail,
                confirmTitle: "Download",
                onConfirm: {},
                onDecline: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }

    /// The bottom rule's vertical extent: the `hairline` rows of a column
    /// through the bar's leading padding, short of the icon. Its `maxY` is the
    /// bar's height.
    private func rule(
        _ render: HostedRender, metrics: InterfaceMetrics, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (minY: CGFloat, maxY: CGFloat) {
        try XCTUnwrap(
            render.extent(of: .hairline, atX: metrics.scaled(9)),
            "the bar drew no bottom rule in its leading padding", file: file, line: line
        )
    }
}

#endif
