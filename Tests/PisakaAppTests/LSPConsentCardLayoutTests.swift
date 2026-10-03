#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The language-server consent card, the shipped `LSPConsentCard`, hosted in a
/// real window and measured off a rendered bitmap.
///
/// **The design.** The card sits in a full-width band on the editor's ground,
/// `bgEditor`, inset 8 points on every side. It is filled `bgPanel` inside a
/// rounded rectangle of radius 6 under a one-hairline `hairline` border, every
/// length scaling with the interface. The text column takes all the width the
/// actions leave, so a primary line that fits beside the actions is drawn on
/// one line rather than wrapping at about half the width it could use.
///
/// **How the band and the border are measured.** One render per scale. A column
/// through the card's leading padding carries `hairline` at its top and bottom
/// edges; the top edge must sit 8 scaled points below the band's top, and the
/// first `hairline` pixel of the card's middle row 8 scaled points in from the
/// band's leading edge. That row's run of `hairline` pixels is the border's
/// width, one scaled hairline and no wider. The band's ground is sampled at
/// half the inset to the left of, above and below the card; the interior just
/// inside the border must read `bgPanel`; and the pixel half a point in from
/// the card's top-leading corner, outside the radius, must read `bgEditor`.
///
/// **How the text column is measured.** The card is rendered at a generous
/// width. Across every interior row — strictly between the top and bottom
/// border rows — the primary button's leading edge is the first `accent` pixel
/// right of the card's middle (the minimum over rows), and the line's trailing
/// edge is the last non-`bgPanel` pixel left of that edge (the maximum over
/// rows; one row cannot stand in, since a row through the last character may
/// carry no ink). A narrow width is derived from those two, never from button
/// widths: it leaves the line exactly its room beside the spacer's 16-point
/// minimum, plus a small slack. Rendered again at that width the card must keep
/// its height, which it does only if the text column reaches the actions. The
/// generous render must itself be as tall as a card whose line is one word, or
/// a column capped short of the actions would wrap both renders alike and the
/// comparison would hold vacuously.
///
/// **What mutation showed.** A column capped at 400 points fails the suite. The
/// column's `.layoutPriority(1)` removed — or turned to -1 — does *not*: the
/// stack lays the spacer out after the text either way, so the line kept its
/// one line at the derived width, with and without a secondary line. The
/// priority stays as the stated intent; what this suite pins is the drawn
/// outcome, not that one modifier.
///
/// Hosting, settling and colour comparison are `HostedRender`'s.
@MainActor
final class LSPConsentCardLayoutTests: XCTestCase {

    private static let message =
        "Download the TypeScript/JavaScript language server (52.2 MB) for completion and Go to Definition?"

    func testTheBandAndTheCardAtScaleOne() throws {
        try assertBandAndCard(scale: 1)
    }

    func testTheBandAndTheCardAtScaleOnePointEight() throws {
        try assertBandAndCard(scale: 1.8)
    }

    func testThePrimaryLineTakesTheWholeTextColumn() throws {
        let metrics = InterfaceMetrics(scale: 1)
        let generousWidth = metrics.scaled(1_100)
        let generous = try render(width: generousWidth, metrics: metrics)
        let generousCard = try cardExtent(generous, metrics: metrics)

        // One line at the generous width: as tall as a card whose line is a
        // single word, or a column capped short of the actions would wrap both
        // renders alike and the comparison below would hold vacuously.
        let oneWord = try render(width: generousWidth, metrics: metrics, message: "Download?")
        let oneLine = try cardExtent(oneWord, metrics: metrics)
        XCTAssertEqual(
            generousCard.maxY - generousCard.minY, oneLine.maxY - oneLine.minY, accuracy: 0.6,
            "at \(generousWidth) points the primary line already wrapped"
        )

        let step = 1 / generous.pixelScale
        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let rows = Array(stride(
            from: generousCard.minY + hairline + step, to: generousCard.maxY - hairline - step, by: step
        ))
        XCTAssertFalse(rows.isEmpty, "the card has no interior rows")

        // The primary button's leading edge: the first `accent` pixel right of
        // the card's middle, the minimum over every interior row.
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
        // button, the maximum over every interior row.
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
        let narrowCard = try cardExtent(narrow, metrics: metrics)

        XCTAssertEqual(
            narrowCard.maxY - narrowCard.minY, generousCard.maxY - generousCard.minY, accuracy: 0.6,
            "at \(narrowWidth) points the primary line wrapped although the text column had room for it"
        )
    }

    private func assertBandAndCard(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let width = metrics.scaled(900)
        let inset = metrics.scaled(8)
        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let render = try render(width: width, metrics: metrics)
        let card = try cardExtent(render, metrics: metrics, file: file, line: line)
        let midY = (card.minY + card.maxY) / 2
        let step = 1 / render.pixelScale

        XCTAssertEqual(
            card.minY, inset, accuracy: 0.6,
            "the card's top edge at scale \(scale) is not 8 scaled below the band's top", file: file, line: line
        )

        // The card's middle row from the band's leading edge: `bgEditor`, then
        // the border's run of `hairline`, then the panel.
        let border = stride(from: step / 2, to: inset * 3, by: step)
            .filter { render.matches(.hairline, atX: $0, y: midY) }
        let first = try XCTUnwrap(border.first, "no leading border at scale \(scale)", file: file, line: line)
        let last = try XCTUnwrap(border.last, file: file, line: line)
        XCTAssertEqual(
            first - step / 2, inset, accuracy: 0.6,
            "the card's leading edge at scale \(scale) is not 8 scaled in", file: file, line: line
        )
        XCTAssertEqual(
            last - first + step, hairline, accuracy: 0.6,
            "the border at scale \(scale) is not one scaled hairline wide", file: file, line: line
        )

        XCTAssertTrue(
            render.matches(.bgEditor, atX: inset / 2, y: midY),
            "the band left of the card is not bgEditor at scale \(scale)", file: file, line: line
        )
        XCTAssertTrue(
            render.matches(.bgEditor, atX: width / 2, y: inset / 2),
            "the band above the card is not bgEditor at scale \(scale)", file: file, line: line
        )
        XCTAssertTrue(
            render.matches(.bgEditor, atX: width / 2, y: card.maxY + inset / 2),
            "the band below the card is not bgEditor at scale \(scale)", file: file, line: line
        )
        XCTAssertTrue(
            render.matches(.bgPanel, atX: inset + hairline + metrics.scaled(2), y: midY),
            "the card's interior is not bgPanel at scale \(scale)", file: file, line: line
        )
        let corner = render.color(atX: inset + 0.5, y: inset + 0.5)
        XCTAssertTrue(
            render.matches(.bgEditor, atX: inset + 0.5, y: inset + 0.5),
            "the card's top-leading corner at scale \(scale) is not rounded: \(String(describing: corner))",
            file: file, line: line
        )
        XCTAssertFalse(
            render.matches(.bgPanel, atX: inset + 0.5, y: inset + 0.5),
            "the card's panel fills its top-leading corner at scale \(scale)", file: file, line: line
        )
    }

    /// The card with the download arrow, the primary line, no secondary line
    /// and no-op actions, pinned to the top of a window taller than its band.
    private func render(
        width: CGFloat, metrics: InterfaceMetrics, message: String = LSPConsentCardLayoutTests.message
    ) throws -> HostedRender {
        let render = try HostedRender(
            size: CGSize(width: width, height: metrics.scaled(200)),
            root: LSPConsentCard(
                symbolName: "arrow.down.circle",
                message: message,
                detail: nil,
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

    /// The card's vertical extent: the `hairline` rows of a column through its
    /// leading padding, between the band's inset and the icon.
    private func cardExtent(
        _ render: HostedRender, metrics: InterfaceMetrics, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (minY: CGFloat, maxY: CGFloat) {
        try XCTUnwrap(
            render.extent(of: .hairline, atX: metrics.scaled(8 + 9)),
            "the card drew no border in its leading padding", file: file, line: line
        )
    }
}

#endif
