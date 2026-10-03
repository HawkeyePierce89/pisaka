#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The Local Changes panel, hosted in a real window and measured off a rendered
/// bitmap.
///
/// **The design.** The toolbar leads with Commit… on the `accent` ground, then
/// the revert and refresh glyphs, each in a 15-point slot; the list beside the
/// diff defaults to 320 points wide, its edge a `hairline`; a file row reads
/// checkbox, status letter, name — the letter left of the name.
///
/// **How it is measured.** The panel is rendered once per scale over two
/// changed files in two folders, nothing selected, and every sample is read out
/// of that one bitmap. The list's width is where the divider's `hairline` sits
/// in a row below the list's last file. The toolbar's order is the run of
/// inked columns across the toolbar band, clustered: the first cluster holds the
/// `accent` ground, the next two are glyph-sized. The row order compares the
/// status colour's rightmost pixel with the name's leftmost `textPrimary` one.
@MainActor
final class LocalChangesLayoutTests: XCTestCase {

    func testThePanelAtScaleOne() async throws {
        try await assertPanel(scale: 1)
    }

    func testThePanelAtScaleOnePointEight() async throws {
        try await assertPanel(scale: 1.8)
    }

    private func assertPanel(scale: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        let metrics = InterfaceMetrics(scale: scale)
        let root = URL(fileURLWithPath: "/tmp/LocalChangesLayoutTests-project")
        let git = StubGit(files: [
            ChangedFile(path: "Sources/Main.swift", status: .modified),
            ChangedFile(path: "README.md", status: .added),
        ])
        let model = LocalChangesModel(gitService: git, fileService: StubFiles())
        await model.refresh(root: root)
        XCTAssertEqual(model.changedFiles.count, 2, file: file, line: line)

        let theme = ChromeTheme(.dark)
        let panel = theme.color(.bgPanel)
        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(900), height: metrics.scaled(240)),
            root: LocalChangesView(model: model, projectRoot: root)
                .background(panel)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let toolbarHeight = metrics.scaled(LocalChangesLayout.toolbarHeight)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let listTop = toolbarHeight + metrics.scaled(LocalChangesLayout.listPaddingY)

        // The list's default width: the divider's hairline at 320.
        let belowRows = listTop + rowHeight * 4 + metrics.scaled(20)
        let dividerX = try XCTUnwrap(
            firstX(in: render, y: belowRows, from: metrics.scaled(100), to: metrics.scaled(600)) {
                render.matches(.hairline, atX: $0, y: belowRows, ground: panel)
            },
            "no divider hairline beside the list at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            dividerX, metrics.scaled(320), accuracy: 1,
            "the list is not 320 points wide at scale \(scale)", file: file, line: line
        )

        // The toolbar, leading edge first: Commit…, revert, refresh.
        let clusters = inkClusters(
            in: render, rows: metrics.scaled(2)..<(toolbarHeight - metrics.scaled(2)),
            columns: 0..<metrics.scaled(200), mergeGap: metrics.scaled(3)
        )
        XCTAssertGreaterThanOrEqual(clusters.count, 3, "the toolbar drew fewer than three controls: \(clusters)",
                                    file: file, line: line)
        guard clusters.count >= 3 else { return }
        let commit = clusters[0]
        XCTAssertEqual(commit.lowerBound, metrics.scaled(LocalChangesLayout.toolbarPaddingX), accuracy: 1,
                       "Commit… does not lead the toolbar at scale \(scale)", file: file, line: line)
        XCTAssertTrue(
            render.matches(.accent, atX: commit.lowerBound + metrics.scaled(3), y: toolbarHeight / 2, ground: panel),
            "the toolbar's first control is not the accent Commit… button", file: file, line: line
        )
        let glyphSlot = metrics.scaled(LocalChangesLayout.toolbarGlyphSize)
        for (index, cluster) in clusters[1...2].enumerated() {
            XCTAssertLessThanOrEqual(
                cluster.upperBound - cluster.lowerBound, glyphSlot + 1,
                "toolbar glyph \(index + 1) is wider than its 15-point slot at scale \(scale)", file: file, line: line
            )
        }
        XCTAssertGreaterThan(clusters[1].lowerBound, commit.upperBound, file: file, line: line)
        XCTAssertGreaterThan(clusters[2].lowerBound, clusters[1].upperBound, file: file, line: line)

        // A file row: the status letter left of the name. The rows are the root
        // group (README.md, added) and then `Sources` (Main.swift, modified).
        let fileRow = (listTop + rowHeight)..<(listTop + rowHeight * 2)
        let status = ChromeColorRole.changedFileRole(for: .added)
        let listColumns = 0..<(dividerX - 1)
        let letter = try XCTUnwrap(
            xExtent(in: render, rows: fileRow, columns: listColumns) {
                render.matches(status, atX: $0, y: $1, ground: panel)
            },
            "no status letter in the file row at scale \(scale)", file: file, line: line
        )
        let name = try XCTUnwrap(
            xExtent(in: render, rows: fileRow, columns: listColumns) {
                render.matches(.textPrimary, atX: $0, y: $1, ground: panel)
            },
            "no name in the file row at scale \(scale)", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(letter.lowerBound, metrics.scaled(LocalChangesLayout.fileRowInset),
                                    "the status letter is not past the checkbox", file: file, line: line)
        XCTAssertLessThan(letter.upperBound, name.lowerBound,
                          "the status letter is not left of the name at scale \(scale)", file: file, line: line)
    }

    // MARK: - Sampling (all off the one bitmap)

    /// The first `x` in `range` along row `y` satisfying `test`, at pixel steps.
    private func firstX(
        in render: HostedRender, y: CGFloat, from start: CGFloat, to end: CGFloat, test: (CGFloat) -> Bool
    ) -> CGFloat? {
        stride(from: start, to: end, by: 1 / render.pixelScale).first(where: test)
    }

    /// The horizontal extent of the pixels in the band satisfying `test`.
    private func xExtent(
        in render: HostedRender, rows: Range<CGFloat>, columns: Range<CGFloat>, test: (CGFloat, CGFloat) -> Bool
    ) -> Range<CGFloat>? {
        let step = 1 / render.pixelScale
        var minX: CGFloat?
        var maxX: CGFloat?
        for x in stride(from: columns.lowerBound, to: columns.upperBound, by: step) {
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: step) where test(x, y) {
                minX = min(minX ?? x, x)
                maxX = max(maxX ?? x, x)
                break
            }
        }
        guard let minX, let maxX else { return nil }
        return minX..<(maxX + step)
    }

    /// The columns holding any ink — a pixel off the panel ground — within the
    /// band, merged into clusters across gaps narrower than `mergeGap`.
    private func inkClusters(
        in render: HostedRender, rows: Range<CGFloat>, columns: Range<CGFloat>, mergeGap: CGFloat
    ) -> [Range<CGFloat>] {
        guard let ground = HostedRender.swatch(.bgPanel, ground: nil) else { return [] }
        let step = 1 / render.pixelScale
        var clusters: [Range<CGFloat>] = []
        for x in stride(from: columns.lowerBound, to: columns.upperBound, by: step) {
            let inked = stride(from: rows.lowerBound, to: rows.upperBound, by: step).contains { y in
                guard let c = render.color(atX: x, y: y) else { return false }
                return abs(c.redComponent - ground.redComponent) > 0.06
                    || abs(c.greenComponent - ground.greenComponent) > 0.06
                    || abs(c.blueComponent - ground.blueComponent) > 0.06
            }
            guard inked else { continue }
            if let last = clusters.last, x - last.upperBound < mergeGap {
                clusters[clusters.count - 1] = last.lowerBound..<(x + step)
            } else {
                clusters.append(x..<(x + step))
            }
        }
        return clusters
    }

    // MARK: - Stubs

    private final class StubGit: GitServicing {
        let files: [ChangedFile]
        init(files: [ChangedFile]) { self.files = files }
        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { files }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}
    }

    private final class StubFiles: FileServicing {
        func read(url: URL) throws -> String { "" }
        func write(_ text: String, to url: URL) throws {}
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? { nil }
        func isExecutableFile(at url: URL) -> Bool { false }
    }
}
#endif
