#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's `dependencies` caption, hosted in a real window and
/// measured off a rendered bitmap.
///
/// **The design.** A folder `DependencyFolderRule` answers as a dependency root
/// — a table name with one of its markers beside it — draws `dependencies` in
/// the secondary text role after its name, at the label's own font. A folder
/// of the same name with no marker beside it draws its name alone.
///
/// **How it is measured.** One temporary project `p` holding `package.json`, a
/// `node_modules/` with two packages (so it heads no chain), and `other/`
/// holding a second `node_modules/` with two packages and no marker beside it,
/// plus `readme.txt`. `other/` is expanded by a reveal of `readme.txt`, which
/// scrolls nothing in a tree this short. The rows are `p`, `node_modules`,
/// `other`, `other/node_modules`, `readme.txt`, `package.json`. One render per
/// appearance — two windows in all. The band sampled is the one just right of
/// the name `node_modules`, whose end is the row's leading layout plus the
/// name's width at the label's font; on `other/node_modules` the same band
/// sits one indent step further right.
@MainActor
final class TreeDependencyCaptionTests: XCTestCase {

    func testOnlyTheMarkedDependencyRootIsCaptionedInBothAppearances() throws {
        let root = try makeProject()
        let metrics = InterfaceMetrics(scale: 1)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        // The tree's rows start under the header and the list's top padding.
        let top = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        // A depth-1 row's name ends after the indent, the row's padding, the
        // chevron column and its gap, the folder glyph and its gap.
        let nameStart = indent + metrics.scaled(ChromeGeometry.rowPaddingX)
            + metrics.scaled(TreeRowLayout.chevronWidth) + metrics.scaled(TreeRowLayout.chevronSpacing)
            + metrics.scaled(TreeRowLayout.iconSize) + metrics.scaled(4)
        let font = NSFont.systemFont(ofSize: CGFloat(metrics.font(.body)))
        let nameEnd = nameStart + ("node_modules" as NSString).size(withAttributes: [.font: font]).width
        let captionWidth = ("dependencies" as NSString).size(withAttributes: [.font: font]).width
        // Inside the caption, clear of the name's last glyph and the caption's.
        let band = (nameEnd + metrics.scaled(4) + 2)...(nameEnd + metrics.scaled(4) + captionWidth - 2)

        for appearance in [ChromeAppearance.dark, .light] {
            let render = try render(root, appearance: appearance)
            func inkCount(row index: Int, shift: CGFloat) throws -> Int {
                let centre = top + (CGFloat(index) + 0.5) * rowHeight
                let background = try XCTUnwrap(render.color(atX: render.bounds.width - 6, y: centre),
                                               "no background pixel in row \(index) (\(appearance))")
                var count = 0
                for dy in stride(from: -4.0, through: 4.0, by: 1.0) {
                    for x in stride(from: band.lowerBound + shift, through: band.upperBound + shift, by: 1.0) {
                        let pixel = try XCTUnwrap(render.color(atX: x, y: centre + dy),
                                                  "no pixel at \(x) in row \(index) (\(appearance))")
                        if differs(pixel, background) { count += 1 }
                    }
                }
                return count
            }

            XCTAssertGreaterThan(try inkCount(row: 1, shift: 0), 0,
                                 "node_modules beside package.json draws no caption after its name (\(appearance))")
            XCTAssertEqual(try inkCount(row: 3, shift: indent), 0,
                           "other/node_modules, beside no marker, draws something after its name (\(appearance))")
        }
    }

    // MARK: - Helpers

    /// Whether two pixels differ in any channel by more than the bitmap's own
    /// rounding — antialiased caption text moves a channel by far more.
    private func differs(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) > 0.05
            || abs(lhs.greenComponent - rhs.greenComponent) > 0.05
            || abs(lhs.blueComponent - rhs.blueComponent) > 0.05
    }

    private func render(_ root: URL, appearance: ChromeAppearance) throws -> HostedRender {
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("other/readme.txt"), root: root)
        )
        let render = try HostedRender(
            size: CGSize(width: 340, height: 220),
            root: ProjectTreeView(model: model, reveal: reveal)
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
