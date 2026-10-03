#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The terminal's left and right margin inside its panel, measured off a
/// rendered bitmap.
///
/// **The design.** The terminal sits 14 points in from the panel's leading and
/// trailing edges at interface scale 1.0, the margin scaling with the
/// interface, and the margin is painted `bgPanel` — the terminal's own ground —
/// so the panel reads as one surface.
///
/// **How it is measured.** `TerminalPanelInset` is hosted once per scale around
/// an `accent`-filled stand-in, since a real terminal would spawn a shell. One
/// row through the middle of that single bitmap is scanned for the stand-in's
/// first and last `accent` pixels: their distance from the two edges is the
/// inset. The margin itself, sampled on both sides, must read `bgPanel`.
@MainActor
final class TerminalPanelInsetTests: XCTestCase {

    func testTheInsetAtScaleOne() throws {
        try assertInset(scale: 1)
    }

    func testTheInsetAtScaleOnePointEight() throws {
        try assertInset(scale: 1.8)
    }

    private func assertInset(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let theme = ChromeTheme(.dark)
        let width = metrics.scaled(300)
        let height = metrics.scaled(60)
        let inset = metrics.scaled(14)

        let render = try HostedRender(
            size: CGSize(width: width, height: height),
            root: TerminalPanelInset {
                Rectangle().fill(theme.color(.accent))
            }
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let midY = height / 2
        let step = 1 / render.pixelScale
        let filled = stride(from: step / 2, to: width, by: step)
            .filter { render.matches(.accent, atX: $0, y: midY) }
        let first = try XCTUnwrap(filled.first, "the stand-in drew nothing", file: file, line: line)
        let last = try XCTUnwrap(filled.last, file: file, line: line)

        XCTAssertEqual(
            first - step / 2, inset, accuracy: 0.5,
            "the terminal's leading inset at scale \(scale) is not 14 scaled", file: file, line: line
        )
        XCTAssertEqual(
            width - (last + step / 2), inset, accuracy: 0.5,
            "the terminal's trailing inset at scale \(scale) is not 14 scaled", file: file, line: line
        )
        XCTAssertTrue(
            render.matches(.bgPanel, atX: inset / 2, y: midY),
            "the leading margin is not painted bgPanel", file: file, line: line
        )
        XCTAssertTrue(
            render.matches(.bgPanel, atX: width - inset / 2, y: midY),
            "the trailing margin is not painted bgPanel", file: file, line: line
        )
    }
}

#endif
