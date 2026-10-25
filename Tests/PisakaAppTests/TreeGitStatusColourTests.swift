#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's git-status name colours, hosted in a real window and
/// measured off a rendered bitmap.
///
/// **The design.** Only a row's *name* takes its git state's role —
/// `ChromeColorRole.treeNameRole(for:)` — a folder answering for the strongest
/// change below it; the glyph keeps `textSecondary`, and a plain row draws
/// exactly as the tree did before git state existed.
///
/// **How it is measured.** One root folder holding a modified, an ignored and a
/// plain file, rendered twice at scale one — once with the lookup, once with
/// `.empty` — and every sample read out of those two bitmaps. The name is the
/// span right of the row's glyph slot; the glyph slot is the one the glyph
/// layout suite pins.
@MainActor
final class TreeGitStatusColourTests: XCTestCase {

    func testRowNamesTakeTheirGitStateAndNothingElseChanges() throws {
        let root = try makeProject()
        let lookup = TreeGitStatus(
            snapshot: GitStatusSnapshot(
                changedFiles: [ChangedFile(path: "a.swift", status: .modified)],
                ignoredPaths: ["b.swift"]
            ),
            repositoryRoot: root,
            openedFolder: root
        )
        let coloured = try render(root, gitStatus: lookup)
        let plain = try render(root, gitStatus: .empty)

        let metrics = InterfaceMetrics(scale: 1)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let padding = metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = metrics.scaled(TreeRowLayout.chevronWidth)
        let gap = metrics.scaled(TreeRowLayout.chevronSpacing)
        let icon = metrics.scaled(TreeRowLayout.iconSize)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        // The tree's rows start under the header and the list's top padding.
        let top = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        func row(_ index: Int) -> Range<CGFloat> {
            (top + CGFloat(index) * rowHeight)..<(top + CGFloat(index + 1) * rowHeight)
        }
        let width = coloured.bounds.width
        let folderName = (padding + chevron + gap + icon)..<width
        let fileGlyph = (indent + padding + chevron + gap)..<(indent + padding + chevron + gap + icon)
        let fileName = fileGlyph.upperBound..<width

        // The root folder answers for the modified file below it.
        XCTAssertTrue(contains(.statusYellow, in: coloured, x: folderName, rows: row(0)),
                      "the folder holding a modified file did not draw its name in statusYellow")
        XCTAssertFalse(contains(.statusYellow, in: plain, x: folderName, rows: row(0)))

        // The modified file: a yellow name over an unchanged glyph.
        XCTAssertTrue(contains(.statusYellow, in: coloured, x: fileName, rows: row(1)),
                      "the modified file did not draw its name in statusYellow")
        XCTAssertTrue(identical(coloured, plain, x: fileGlyph, rows: row(1)),
                      "the modified file's glyph changed — only the name takes the git colour")

        // The ignored file: dimmed to textSecondary, and no change colour.
        XCTAssertTrue(contains(.textSecondary, in: coloured, x: fileName, rows: row(2)),
                      "the ignored file did not draw its name in textSecondary")
        XCTAssertFalse(identical(coloured, plain, x: fileName, rows: row(2)),
                       "the ignored file's name draws as a plain one")
        XCTAssertFalse(contains(.statusYellow, in: coloured, x: fileName, rows: row(2)))

        // The plain file draws exactly as the tree without git state.
        XCTAssertTrue(identical(coloured, plain, x: folderName.lowerBound..<width, rows: row(3)),
                      "a plain row no longer draws pixel-identical to the tree without git state")
    }

    // MARK: - Helpers

    private func render(_ root: URL, gitStatus: TreeGitStatus) throws -> HostedRender {
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let render = try HostedRender(
            size: CGSize(width: 240, height: 160),
            root: ProjectTreeView(model: model, gitStatus: gitStatus)
                .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }

    /// Whether any pixel in `x` × `rows` is `role`. Reads the one bitmap.
    private func contains(
        _ role: ChromeColorRole, in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>
    ) -> Bool {
        let step = 1 / render.pixelScale
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step)
            where render.matches(role, atX: px, y: py) {
                return true
            }
        }
        return false
    }

    /// Whether the two renders draw `x` × `rows` alike, pixel for pixel.
    private func identical(
        _ lhs: HostedRender, _ rhs: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>
    ) -> Bool {
        let step = 1 / lhs.pixelScale
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step) {
                guard let a = lhs.color(atX: px, y: py), let b = rhs.color(atX: px, y: py) else { return false }
                if abs(a.redComponent - b.redComponent) > 0.004
                    || abs(a.greenComponent - b.greenComponent) > 0.004
                    || abs(a.blueComponent - b.blueComponent) > 0.004 {
                    return false
                }
            }
        }
        return true
    }

    /// A root folder holding three files, removed in teardown.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeGitStatusColourTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.swift", "b.swift", "c.swift"] {
            try Data("let x = 1\n".utf8).write(to: root.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
