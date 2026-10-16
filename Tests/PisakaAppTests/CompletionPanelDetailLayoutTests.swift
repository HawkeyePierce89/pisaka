#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The completion panel's detail column (`CompletionRowLayout`): the measured
/// width never exceeds the panel's cap, the label is drawn whole and before the
/// detail, and a detail that does not fit loses its *head*, so its tail — the
/// part that tells two overloads apart — survives.
@MainActor
final class CompletionPanelDetailLayoutTests: XCTestCase {
    private let font = EditorFont.font(size: 13, family: nil)
    private let metrics = InterfaceMetrics.unscaled

    private func row(_ label: String, detail: String?) -> CompletionRow {
        let item = CompletionItem(text: label, kind: .function, isFromCurrentFile: false, detail: detail)
        return CompletionRow(displayText: label, badge: .init(symbolName: "f.square"), item: item)
    }

    private func textWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testALongLabelAndALongDetailStayWithinTheCapAndKeepTheDetailsTail() throws {
        let label = "makeConfigurationWithDefaults"
        let detail = "(environment: ProcessEnvironment, overrides: [String: String], strict: Bool) -> Configuration"
        let row = row(label, detail: detail)
        let cap = CompletionPanel.maximumWidth

        let width = CompletionRowLayout.measureWidth(for: [row], codeFont: font, metrics: metrics, maximumWidth: cap)
        XCTAssertLessThanOrEqual(width, cap)
        XCTAssertEqual(width, cap, "a row this long must be capped, not merely fit")

        let layout = CompletionRowLayout.make(
            label: label, detail: detail, codeFont: font, metrics: metrics, width: width
        )
        XCTAssertEqual(layout.label, label, "the label keeps priority and is never truncated")
        let drawn = try XCTUnwrap(layout.detail, "there is room for part of the detail")
        XCTAssertTrue(drawn.hasPrefix("…"), "the detail is truncated at its leading edge: \(drawn)")
        XCTAssertTrue(detail.hasSuffix(String(drawn.dropFirst())), "the drawn detail is the original's tail")
        XCTAssertTrue(drawn.hasSuffix("-> Configuration"))

        let labelEnd = layout.labelX + textWidth(of: layout.label)
        XCTAssertGreaterThan(layout.detailX, labelEnd, "the detail starts after the label ends")
        XCTAssertLessThanOrEqual(
            layout.detailX + textWidth(of: drawn),
            width - CompletionRowLayout.trailingInset(metrics: metrics) + 0.5,
            "the detail is right-aligned inside the panel"
        )
    }

    func testAShortDetailIsDrawnWholeAndRightAligned() throws {
        let row = row("count", detail: "Int")
        let width = CompletionRowLayout.measureWidth(
            for: [row], codeFont: font, metrics: metrics, maximumWidth: CompletionPanel.maximumWidth
        )
        XCTAssertLessThan(width, CompletionPanel.maximumWidth)
        let layout = CompletionRowLayout.make(label: "count", detail: "Int", codeFont: font, metrics: metrics, width: width)
        XCTAssertEqual(layout.detail, "Int")
        XCTAssertEqual(
            layout.detailX + textWidth(of: "Int"),
            width - CompletionRowLayout.trailingInset(metrics: metrics),
            accuracy: 0.5
        )
    }

    func testNoDetailDrawsNothingAndMeasuresAsBefore() {
        let row = row("count", detail: nil)
        let width = CompletionRowLayout.measureWidth(
            for: [row], codeFont: font, metrics: metrics, maximumWidth: CompletionPanel.maximumWidth
        )
        XCTAssertEqual(width, textWidth(of: "count") + 40, accuracy: 0.5, "badge column + label + padding, as before")
        let layout = CompletionRowLayout.make(label: "count", detail: nil, codeFont: font, metrics: metrics, width: width)
        XCTAssertNil(layout.detail)
    }

    func testALabelFillingTheRowLeavesNoDetail() {
        let label = String(repeating: "x", count: 200)
        let layout = CompletionRowLayout.make(
            label: label, detail: "String", codeFont: font, metrics: metrics, width: CompletionPanel.maximumWidth
        )
        XCTAssertEqual(layout.label, label)
        XCTAssertNil(layout.detail, "no room after the label draws no detail rather than overlapping it")
    }
}
#endif
