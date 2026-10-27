#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's test-row wash, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** A row `TreeTestRule` answers as a test row — under a test
/// folder, a test folder itself, or a file named by its ecosystem's convention —
/// is painted in `treeRowWashRole`'s answer beneath its row-state tint, through
/// `TreeRowBackground`'s one layered site; every other row draws as before.
///
/// **How it is measured.** One temporary project `p` holding a `Tests/` folder
/// with one file in it (`Gate.swift`, a name no convention matches, so only the
/// folder washes it), a plain sibling folder, the convention-named `a_test.go`
/// beside a plain `b.go`, and a second convention-named file, `c_test.go`, open
/// as the active tab so its row is selected. `Tests/` is expanded by a reveal of
/// its file, which scrolls nothing in a tree this short. The selected row is a
/// file of its own because the unfocused selection, `selectionInactive`, is
/// opaque: a washed row under it could not show its wash. One render per
/// appearance — two windows in all — and every sample is read out of those two
/// bitmaps, each at the right of its row, where no name reaches.
@MainActor
final class TreeTestRowWashTests: XCTestCase {

    func testTestRowsAreWashedBeneathTheirStateTintInBothAppearances() throws {
        let root = try makeProject()
        for appearance in [ChromeAppearance.dark, .light] {
            let render = try render(root, appearance: appearance)

            let metrics = InterfaceMetrics(scale: 1)
            let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
            // The tree's rows start under the header and the list's top padding.
            let top = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
            let x = render.bounds.width * 0.85
            func pixel(row index: Int) throws -> NSColor {
                try XCTUnwrap(render.color(atX: x, y: top + (CGFloat(index) + 0.5) * rowHeight),
                              "no pixel in row \(index) (\(appearance))")
            }

            // Directories first, then names case-insensitively: the root `p`,
            // `plain`, `Tests` and its `Gate.swift`, then the three root files.
            let plainFolder = try pixel(row: 1)
            let testsFolder = try pixel(row: 2)
            let testsChild = try pixel(row: 3)
            let conventionFile = try pixel(row: 4)
            let plainFile = try pixel(row: 5)
            let selectedTestFile = try pixel(row: 6)
            let canvas = try XCTUnwrap(render.color(atX: x, y: top + 8.5 * rowHeight),
                                       "no pixel below the rows (\(appearance))")

            let washed = ["the Tests folder": testsFolder, "its child file": testsChild, "a_test.go": conventionFile]
            for (name, colour) in washed {
                XCTAssertTrue(differs(colour, plainFile), "\(name) is drawn as the plain b.go (\(appearance))")
                XCTAssertTrue(differs(colour, plainFolder), "\(name) is drawn as the plain folder (\(appearance))")
                XCTAssertTrue(differs(colour, canvas), "\(name) is drawn as the canvas below the rows (\(appearance))")
                XCTAssertFalse(differs(colour, testsFolder),
                               "\(name) is not washed as the Tests folder is — one wash, one colour (\(appearance))")
            }
            XCTAssertFalse(differs(plainFile, canvas), "the plain b.go is not drawn as the canvas (\(appearance))")
            XCTAssertFalse(differs(plainFolder, canvas), "the plain folder is not drawn as the canvas (\(appearance))")
            XCTAssertTrue(differs(selectedTestFile, conventionFile),
                          "the selected test row draws as an unselected washed one — no selection tint (\(appearance))")
        }
    }

    // MARK: - Helpers

    /// Whether two pixels differ in any channel by more than the bitmap's own
    /// rounding — the faint wash moves a channel by several steps of 1/255.
    private func differs(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) > 0.01
            || abs(lhs.greenComponent - rhs.greenComponent) > 0.01
            || abs(lhs.blueComponent - rhs.blueComponent) > 0.01
    }

    private func render(_ root: URL, appearance: ChromeAppearance) throws -> HostedRender {
        let model = WorkspaceModel()
        model.openFolder(url: root)
        try model.open(url: root.appendingPathComponent("c_test.go"))
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("Tests/Gate.swift"), root: root)
        )
        let render = try HostedRender(
            size: CGSize(width: 240, height: 260),
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
        let holder = fm.temporaryDirectory.appendingPathComponent("TreeTestRowWashTests-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p", isDirectory: true)
        for folder in ["Tests", "plain"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Tests/Gate.swift", "plain/main.swift", "a_test.go", "b.go", "c_test.go"] {
            try Data("x\n".utf8).write(to: root.appendingPathComponent(file))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }
}
#endif
