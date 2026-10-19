#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// Word-level emphasis in the two diff surfaces, read off a rendered bitmap.
///
/// A `.modified` row's changed words (Core's `DiffRow.words`, copied onto the
/// unified diff's `-`/`+` lines as `UnifiedDiffLine.emphasis`) are filled once
/// more with the row's own wash role over the row's wash. Both washes are the
/// same translucent colour, so a pixel is classified by where it sits on the
/// line from the ground to the single wash: `0` is the ground, `1` the wash,
/// and about `1.9` the wash composited twice. The band sampled is the top few
/// points of the row, above the x-height, and every line's text is lowercase
/// letters without ascenders, so no glyph reaches it.
///
/// Both side-by-side panes and both appearances are covered: a one-word change
/// shows the stronger wash inside the word's layout rect and the plain wash a
/// few points outside it; a rewritten line — over the 60% threshold, so Core
/// gives it no ranges — shows the plain wash across its whole text. The unified
/// diff's `-` and `+` lines carry exactly one stronger run, about the word's
/// width, and a line without emphasis none.
@MainActor
final class DiffWordEmphasisTests: XCTestCase {

    private static let fontSize = 28.0

    // MARK: - Side-by-side DiffView

    func testAOneWordChangeIsEmphasizedOnlyInsideTheWordOnBothPanes() throws {
        let rows = LineDiff.rows(old: "same\naaa xxx ccc\n", new: "same\naaa zzz ccc\n")
        let words = try XCTUnwrap(rows[1].words, "the modified row carries no word ranges — the case is not exercised")
        XCTAssertEqual(words.old, [NSRange(location: 4, length: 3)])
        XCTAssertEqual(words.new, [NSRange(location: 4, length: 3)])
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let render = try SideBySideRender(rows: rows, appearance: appearance)
            addTeardownBlock { @MainActor in render.window.close() }
            for side in [DiffSide.old, .new] {
                let pane = try render.pane(side)
                let word = try render.rect(ofCharacters: NSRange(location: 4, length: 3), inLine: 1, of: pane)
                let y = word.minY + 3
                let inside = try render.washLevel(atX: word.midX, y: y, of: pane, groundLine: 0)
                XCTAssertEqual(inside, 1.9, accuracy: 0.4, "\(side) pane, \(appearance.rawValue): the word is not emphasized")
                for x in [word.minX - 3, word.maxX + 3] {
                    let outside = try render.washLevel(atX: x, y: y, of: pane, groundLine: 0)
                    XCTAssertEqual(
                        outside, 1, accuracy: 0.25,
                        "\(side) pane, \(appearance.rawValue): the emphasis leaks outside the word at x \(x)"
                    )
                }
            }
        }
    }

    func testARewrittenLineShowsAUniformWash() throws {
        let rows = LineDiff.rows(old: "same\naaa xxx ccc\n", new: "same\nzzz mmm\n")
        XCTAssertEqual(rows[1].kind, .modified, "the rewritten line did not pair — the case is not exercised")
        XCTAssertNil(rows[1].words, "a rewritten line carries word ranges")
        let render = try SideBySideRender(rows: rows, appearance: .darkAqua)
        addTeardownBlock { @MainActor in render.window.close() }
        for side in [DiffSide.old, .new] {
            let pane = try render.pane(side)
            let text = try render.rect(ofCharacters: NSRange(location: 0, length: 7), inLine: 1, of: pane)
            for x in stride(from: text.minX + 1, to: text.maxX, by: 2) {
                let level = try render.washLevel(atX: x, y: text.minY + 3, of: pane, groundLine: 0)
                XCTAssertEqual(level, 1, accuracy: 0.25, "\(side) pane: the rewritten line's wash is not uniform at x \(x)")
            }
        }
    }

    // MARK: - Unified diff

    func testTheUnifiedDiffEmphasizesTheWordOnItsRemovedAndAddedLines() throws {
        let lines = [
            UnifiedDiffLine(
                kind: .removed, text: "aaa xxx ccc", oldNumber: 1, newNumber: nil, unitIndex: 0,
                emphasis: [NSRange(location: 4, length: 3)]
            ),
            UnifiedDiffLine(
                kind: .added, text: "aaa zzz ccc", oldNumber: nil, newNumber: 1, unitIndex: 0,
                emphasis: [NSRange(location: 4, length: 3)]
            ),
        ]
        let render = try UnifiedRender(lines: lines)
        addTeardownBlock { @MainActor in render.render.window.close() }
        let advance = ("x" as NSString).size(withAttributes: [
            .font: EditorFont.font(size: CGFloat(Self.fontSize), family: nil),
        ]).width
        for role: ChromeColorRole in [.diffRemovedBackground, .diffAddedBackground] {
            let runs = try render.strongRuns(inRowWashed: role)
            XCTAssertEqual(runs.count, 1, "\(role.rawValue): expected one emphasized run, got \(runs)")
            let width = try XCTUnwrap(runs.first).width
            XCTAssertEqual(width, advance * 3, accuracy: 3, "\(role.rawValue): the run is not the word's width")
        }
    }

    func testAUnifiedLineWithoutEmphasisShowsNone() throws {
        let lines = [
            UnifiedDiffLine(kind: .removed, text: "aaa xxx ccc", oldNumber: 1, newNumber: nil, unitIndex: 0),
            UnifiedDiffLine(kind: .added, text: "zzz mmm", oldNumber: nil, newNumber: 1, unitIndex: 0),
        ]
        let render = try UnifiedRender(lines: lines)
        addTeardownBlock { @MainActor in render.render.window.close() }
        for role: ChromeColorRole in [.diffRemovedBackground, .diffAddedBackground] {
            XCTAssertEqual(try render.strongRuns(inRowWashed: role), [], "\(role.rawValue): a line without emphasis has one")
        }
    }
}

/// Where a pixel sits on the line from `ground` to `wash`: the projection of
/// `pixel - ground` onto `wash - ground`, so `0` is the ground and `1` the wash.
@MainActor
private func level(of pixel: NSColor, ground: NSColor, wash: NSColor) -> CGFloat {
    let delta = [
        wash.redComponent - ground.redComponent,
        wash.greenComponent - ground.greenComponent,
        wash.blueComponent - ground.blueComponent,
    ]
    let offset = [
        pixel.redComponent - ground.redComponent,
        pixel.greenComponent - ground.greenComponent,
        pixel.blueComponent - ground.blueComponent,
    ]
    let norm = delta.reduce(0) { $0 + $1 * $1 }
    guard norm > 0 else { return 0 }
    return zip(delta, offset).reduce(0) { $0 + $1.0 * $1.1 } / norm
}

/// The side-by-side `DiffView` hosted in a borderless 600 × 300 window.
@MainActor
private final class SideBySideRender {
    let render: HostedRender
    var window: NSWindow { render.window }

    init(rows: [DiffRow], appearance: NSAppearance.Name) throws {
        let root = DiffView(fileID: "f", fileName: "file.txt", rows: rows, fontSize: 28)
            .frame(width: 600, height: 300)
        render = try HostedRender(size: CGSize(width: 600, height: 300), root: root)
        window.appearance = NSAppearance(named: appearance)
        render.settle()
        for side in [DiffSide.old, .new] { try pane(side).needsDisplay = true }
        try render.capture()
    }

    func pane(_ side: DiffSide) throws -> DiffTextView {
        try XCTUnwrap(Self.textViews(in: render.host).first { $0.side == side }, "no \(side) pane")
    }

    private static func textViews(in view: NSView) -> [DiffTextView] {
        (view as? DiffTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    /// `range` (UTF-16, within line `line`'s text) laid out in `pane`, in the
    /// host's top-left point space.
    func rect(ofCharacters range: NSRange, inLine line: Int, of pane: DiffTextView) throws -> CGRect {
        let layoutManager = try XCTUnwrap(pane.layoutManager)
        let container = try XCTUnwrap(pane.textContainer)
        let start = pane.lineStartOffsets[line]
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: start + range.location, length: range.length), actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y = fragment.minY
        rect.size.height = fragment.height
        return toHost(rect.offsetBy(dx: pane.textContainerOrigin.x, dy: pane.textContainerOrigin.y), from: pane)
    }

    private func toHost(_ rect: CGRect, from view: NSView) -> CGRect {
        var converted = view.convert(rect, to: render.host)
        if !render.host.isFlipped { converted.origin.y = render.host.bounds.height - converted.maxY }
        return converted
    }

    /// The level at (`x`, `y`) against the ground read at the same offset into
    /// line `groundLine` (unchanged, so unwashed) and the plain wash read at the
    /// pane's visible trailing edge on the sampled row.
    func washLevel(atX x: CGFloat, y: CGFloat, of pane: DiffTextView, groundLine: Int) throws -> CGFloat {
        let visible = toHost(pane.visibleRect, from: pane)
        let trailing = visible.maxX - 4
        let groundRow = try rect(ofCharacters: NSRange(location: 0, length: 1), inLine: groundLine, of: pane)
        let sampledRow = try rect(ofCharacters: NSRange(location: 0, length: 1), inLine: 1, of: pane)
        let ground = try XCTUnwrap(render.color(atX: trailing, y: groundRow.minY + (y - sampledRow.minY)))
        let wash = try XCTUnwrap(render.color(atX: trailing, y: y))
        let pixel = try XCTUnwrap(render.color(atX: x, y: y))
        return level(of: pixel, ground: ground, wash: wash)
    }
}

/// The commit dialog's unified diff hosted in a borderless 600 × 300 window on
/// a black ground, dark appearance.
@MainActor
private final class UnifiedRender {
    let render: HostedRender
    private let width: CGFloat = 600

    init(lines: [UnifiedDiffLine]) throws {
        let root = CommitUnifiedDiffView(
            rows: lines.map { .line($0) }, selectedUnits: [0], wholeOnlyMessage: nil, fontSize: 28
        )
        .frame(width: 600, height: 300)
        .environment(\.chromeTheme, ChromeTheme(.dark))
        .background(Color.black)
        render = try HostedRender(size: CGSize(width: 600, height: 300), root: root)
    }

    /// The horizontal runs, in points, of the row washed `role` whose pixels
    /// sit at the doubled wash, sampled a few points below the row's top.
    ///
    /// Runs narrower than 1.5 points are dropped: the sampled band can cross the
    /// line's checkbox, whose anti-aliased edges pass through the doubled level
    /// for a pixel or two. That happens since the diff is top-aligned in its
    /// pane (the content's minimum height is the visible height), which moved
    /// the rows to a different pixel offset; an emphasized word is always
    /// several points wide.
    func strongRuns(inRowWashed role: ChromeColorRole) throws -> [ClosedRange<CGFloat>] {
        let row = try XCTUnwrap(render.extent(of: role, atX: width - 4, ground: .black), "no \(role.rawValue) row")
        let y = row.minY + 4
        let ground = try XCTUnwrap(render.color(atX: width - 4, y: 295))
        let wash = try XCTUnwrap(render.color(atX: width - 4, y: y))
        var runs: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        let step = 1 / render.pixelScale
        for x in stride(from: CGFloat(0), to: width, by: step) {
            let pixel = try XCTUnwrap(render.color(atX: x, y: y))
            let strong = abs(level(of: pixel, ground: ground, wash: wash) - 1.9) < 0.4
            if strong, start == nil { start = x }
            if !strong, let begin = start {
                runs.append(begin...x)
                start = nil
            }
        }
        if let begin = start { runs.append(begin...width) }
        return runs.filter { $0.width >= 1.5 }
    }
}

private extension ClosedRange where Bound == CGFloat {
    var width: CGFloat { upperBound - lowerBound }
}
#endif
