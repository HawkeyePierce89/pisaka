#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's `dependencies` tag, hosted in a real window and measured
/// off a rendered bitmap.
///
/// **The design.** A folder `DependencyFolderRule` answers as a dependency root
/// — a table name with one of its markers beside it — draws, after its name, a
/// tag through `ChromeTag`: the word `dependencies` in the secondary text role
/// at the caption style, inside a `hairline` capsule. A folder of the same name
/// with no marker beside it draws its name alone.
///
/// **Why the ignored case.** In the common real project the dependency root is
/// gitignored, so its *name* is already drawn in the secondary text role —
/// the tag's own text role. The mark has to read as a mark beside that name,
/// not as more of it, which is what the ring and the smaller word are for; so
/// the render marks the root `node_modules` ignored, and the first assertion
/// checks the case is real.
///
/// **How it is measured.** One temporary project `p` holding `package.json`, a
/// `node_modules/` with two packages (so it heads no chain), and `other/`
/// holding a second `node_modules/` with two packages and no marker beside it,
/// plus `readme.txt`. `other/` is expanded by a reveal of `readme.txt`, which
/// scrolls nothing in a tree this short. The rows are `p`, `node_modules`,
/// `other`, `other/node_modules`, `readme.txt`, `package.json`. The tree's git
/// lookup holds `node_modules` as ignored, spelled as git reports a wholly
/// ignored directory once its trailing `/` is stripped. One render per
/// appearance — two windows in all. Geometry comes from the metrics at
/// interface scale 1: the name ends at `nameEnd` (the row's leading layout
/// plus the name's width at the label's font), the tag starts one label gap
/// later, and is the word's width at the caption font plus both insets wide.
/// In each appearance:
///
/// - **the case is real** — the name's most saturated ink pixel is nearer the
///   resolved `textSecondary` than `textPrimary`;
/// - **ring** — on the row's centre line, a narrow window at each end of the
///   tag holds a pixel off the row's background, both clear of the word, which
///   starts one horizontal inset inside the ring;
/// - **size** — the word's vertical ink band is strictly shorter than the
///   name's on the same row. The capsule's end radius (about 7 pt) exceeds the
///   horizontal inset (6 pt), so the word's outer columns sit inside the
///   rounded ends; the band is therefore read only on the central half of the
///   word's columns, strictly between the ring's top and bottom lines found on
///   those same columns. The name's band is read on its first letters, `nod`:
///   like those central columns they carry an ascender and no descender,
///   whereas the underscore drops below the baseline and would let a word
///   drawn at the name's own font still measure shorter than the whole name;
/// - **unmarked row** — `other/node_modules` holds only its background where
///   a tag would sit, one indent step further right, and the sixth row's
///   presence proves the reveal expanded `other/`.
@MainActor
final class TreeDependencyCaptionTests: XCTestCase {

    func testOnlyTheMarkedDependencyRootIsTaggedInBothAppearances() throws {
        let root = try makeProject()
        let metrics = InterfaceMetrics(scale: 1)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        // The tree's rows start under the header and the list's top padding.
        let top = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        // A depth-1 row's name starts after the indent, the row's padding, the
        // chevron column and its gap, the folder glyph and its gap.
        let nameStart = indent + metrics.scaled(ChromeGeometry.rowPaddingX)
            + metrics.scaled(TreeRowLayout.chevronWidth) + metrics.scaled(TreeRowLayout.chevronSpacing)
            + metrics.scaled(TreeRowLayout.iconSize) + metrics.scaled(4)
        let nameFont = NSFont.systemFont(ofSize: CGFloat(metrics.font(.body)))
        let nameEnd = nameStart + ("node_modules" as NSString).size(withAttributes: [.font: nameFont]).width
        // The name's first letters, `nod`: an ascender and no descender, like
        // the word's central columns, and a letter clear of the underscore,
        // which drops below the baseline and starts where `node`'s advance
        // ends.
        let nodEnd = nameStart + ("nod" as NSString).size(withAttributes: [.font: nameFont]).width
        let tagFont = NSFont.systemFont(ofSize: CGFloat(metrics.font(.caption)))
        let wordWidth = ("dependencies" as NSString).size(withAttributes: [.font: tagFont]).width
        let inset = metrics.scaled(ChromeGeometry.tagPaddingX)
        let tagStart = nameEnd + metrics.scaled(4)
        let tagWidth = wordWidth + 2 * inset
        // The central half of the word's columns, clear of the rounded ends.
        let wordStart = tagStart + inset
        let central = (wordStart + wordWidth / 4)...(wordStart + 3 * wordWidth / 4)

        for appearance in [ChromeAppearance.dark, .light] {
            let render = try render(root, appearance: appearance)
            func centre(of index: Int) -> CGFloat { top + (CGFloat(index) + 0.5) * rowHeight }
            func rows(of index: Int) -> [CGFloat] {
                Array(stride(from: top + CGFloat(index) * rowHeight, to: top + CGFloat(index + 1) * rowHeight,
                             by: 1 / render.pixelScale))
            }
            func columns(_ span: ClosedRange<CGFloat>) -> [CGFloat] {
                Array(stride(from: span.lowerBound, through: span.upperBound, by: 1 / render.pixelScale))
            }
            func background(row index: Int) throws -> NSColor {
                try XCTUnwrap(render.color(atX: render.bounds.width - 6, y: centre(of: index)),
                              "no background pixel in row \(index) (\(appearance))")
            }
            func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                try XCTUnwrap(render.color(atX: x, y: y), "no pixel at (\(x), \(y)) (\(appearance))")
            }
            let rowBackground = try background(row: 1)
            // Ink is anything further from the ground than the hairline's own
            // full contrast against it, so a ring line — fully covered or
            // antialiased — never reads as ink; the text roles sit far above it.
            let ground = try XCTUnwrap(HostedRender.swatch(.bgPanel, ground: nil, appearance: appearance))
            let ring = try XCTUnwrap(HostedRender.swatch(.hairline, ground: nil, appearance: appearance))
            let secondary = try XCTUnwrap(HostedRender.swatch(.textSecondary, ground: nil, appearance: appearance))
            let primary = try XCTUnwrap(HostedRender.swatch(.textPrimary, ground: nil, appearance: appearance))
            let inkThreshold = (distance(ring, ground) + distance(secondary, ground)) / 2
            func isInk(_ color: NSColor) -> Bool { distance(color, rowBackground) > inkThreshold }

            // The case is real: the ignored name is drawn in textSecondary.
            var extreme: NSColor?
            for y in rows(of: 1) {
                for x in columns(nameStart...nameEnd) {
                    let color = try pixel(x, y)
                    if distance(color, rowBackground) > extreme.map({ distance($0, rowBackground) }) ?? 0 {
                        extreme = color
                    }
                }
            }
            let nameInk = try XCTUnwrap(extreme, "the name node_modules draws no ink (\(appearance))")
            XCTAssertLessThan(distance(nameInk, secondary), distance(nameInk, primary),
                              "the ignored node_modules name is not drawn in textSecondary (\(appearance))")

            // Ring: a pixel off the background at each end of the tag.
            let line = centre(of: 1)
            let leftEnd = try columns((tagStart - 1.5)...(tagStart + 2)).contains {
                differs(try pixel($0, line), rowBackground)
            }
            let rightEnd = try columns((tagStart + tagWidth - 2)...(tagStart + tagWidth + 1.5)).contains {
                differs(try pixel($0, line), rowBackground)
            }
            XCTAssertTrue(leftEnd, "the tag draws no ring at its left end (\(appearance))")
            XCTAssertTrue(rightEnd, "the tag draws no ring at its right end (\(appearance))")

            // Size: the ring's top and bottom lines on the central columns —
            // the outermost rows of the row where every one differs from the
            // background — then the word's ink band strictly between them.
            let centralColumns = columns(central)
            let ringLines = try rows(of: 1).filter { y in
                try centralColumns.allSatisfy { differs(try pixel($0, y), rowBackground) }
            }
            let ringTop = try XCTUnwrap(ringLines.first, "no ring line above the word (\(appearance))")
            let ringBottom = try XCTUnwrap(ringLines.last, "no ring line below the word (\(appearance))")
            XCTAssertGreaterThan(ringBottom - ringTop, 2, "the ring's top and bottom lines coincide (\(appearance))")
            let wordRows = try rows(of: 1).filter { y in
                guard y > ringTop, y < ringBottom else { return false }
                return try centralColumns.contains { isInk(try pixel($0, y)) }
            }
            let nameRows = try rows(of: 1).filter { y in
                try columns(nameStart...nodEnd).contains { isInk(try pixel($0, y)) }
            }
            let word = try XCTUnwrap(band(wordRows), "the tag draws no word (\(appearance))")
            let name = try XCTUnwrap(band(nameRows), "the name draws no ink (\(appearance))")
            XCTAssertLessThan(word.upperBound - word.lowerBound, name.upperBound - name.lowerBound,
                              "the tag's word is not smaller than the name beside it (\(appearance))")

            // Row 3 is `other/node_modules` only if the reveal expanded `other`;
            // collapsed, the tree has four rows and row 3 is `package.json`,
            // whose short name would leave the band blank whatever the tag
            // does. The sixth row, `package.json`, exists only when expanded.
            let expanded = try columns((nameStart + 2)...(nameStart + 30)).contains { x in
                try (-4...4).contains { dy in differs(try pixel(x, centre(of: 5) + CGFloat(dy)), try background(row: 5)) }
            }
            XCTAssertTrue(expanded, "other/ was not expanded, so row 3 is not other/node_modules (\(appearance))")
            let unmarkedBackground = try background(row: 3)
            let unmarked = try columns((tagStart + indent)...(tagStart + tagWidth + indent)).allSatisfy { x in
                try rows(of: 3).allSatisfy { !differs(try pixel(x, $0), unmarkedBackground) }
            }
            XCTAssertTrue(unmarked,
                          "other/node_modules, beside no marker, draws something after its name (\(appearance))")
        }
    }

    // MARK: - Helpers

    /// The span from the first to the last of `rows`, or nil for none.
    private func band(_ rows: [CGFloat]) -> ClosedRange<CGFloat>? {
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    /// The largest per-channel gap between two pixels.
    private func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        max(abs(lhs.redComponent - rhs.redComponent),
            abs(lhs.greenComponent - rhs.greenComponent),
            abs(lhs.blueComponent - rhs.blueComponent))
    }

    /// Whether two pixels differ by more than the bitmap's own rounding. Low
    /// on purpose: the dark hairline sits barely a twentieth off the panel in
    /// any channel, and an antialiased ring line keeps at least half of that.
    private func differs(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        distance(lhs, rhs) > 0.015
    }

    private func render(_ root: URL, appearance: ChromeAppearance) throws -> HostedRender {
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("other/readme.txt"), root: root)
        )
        let lookup = TreeGitStatus(
            snapshot: GitStatusSnapshot(changedFiles: [], ignoredPaths: ["node_modules"]),
            repositoryRoot: root,
            openedFolder: root
        )
        let render = try HostedRender(
            size: CGSize(width: 340, height: 220),
            root: ProjectTreeView(model: model, reveal: reveal, gitStatus: lookup)
                .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
                .environment(\.chromeTheme, ChromeTheme(appearance))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }

    /// The project `p`, removed in teardown.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("TreeDependencyCaptionTests-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p", isDirectory: true)
        for folder in ["node_modules/a", "node_modules/b", "other/node_modules/a", "other/node_modules/b"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["package.json", "other/readme.txt"] {
            try Data("x\n".utf8).write(to: root.appendingPathComponent(file))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }
}
#endif
