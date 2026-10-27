#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// A chain that grows while keeping its head lists its new tail.
///
/// **The property.** When a folder chain extends — `a/b` becomes `a/b/c` — the
/// node keeps its head, `a`, and so its identity and its expansion; only its
/// `shape` changes, and `.onChange(of: shape)` reloads the listing the rows are
/// drawn from. That action must read the shape it was called for: the
/// deprecated one-argument `onChange` reads the previous update's `shape`, so
/// the node listed the *old* tail `b` — the row `a/b/c` drew `c` itself as its
/// one child — until the next tree revision. Same defect, same remedy as the
/// reveal sites `TreeRevealOnScreenTests` pins.
///
/// **How it is measured.** One window at interface scale 1 over a temporary
/// project `p` holding `a/b/x` and a root file `f`, so the root lists the chain
/// `a/b` with one file under it. A reveal of `a/b/x` expands the chain, whose
/// node reports its frame through `TreeStickyFoldersKey`: its row plus `x`'s,
/// two rows. Then `x` is removed and `b/c/` is created holding `y1` and `y2`,
/// and the tree revision is bumped: the root re-lists, the chain grows to
/// `a/b/c`, and the expanded node must draw its row plus `y1` and `y2` — three
/// rows, where the old tail's listing would draw two (its row and `c`). The
/// waits are causal, laying the host out each turn and failing loudly.
@MainActor
final class TreeChainReshapeTests: XCTestCase {

    func testAGrownChainListsItsNewTail() throws {
        let root = try makeProject()
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let metrics = InterfaceMetrics(scale: 1)
        let h = metrics.scaled(ChromeGeometry.rowHeight)
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("a/b/x"), root: root)
        )
        let state = TreeRevealHostState(reveal: reveal)
        let render = try HostedRender(
            size: CGSize(width: 240, height: 300),
            root: TreeRevealHost(model: model, state: state, metrics: metrics)
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let chain = try waitForChain(in: state, render: render, height: 2 * h)
        XCTAssertEqual(chain?.frame.height, 2 * h, "the chain a/b did not expand to its row and x's")

        let fm = FileManager.default
        try fm.removeItem(at: root.appendingPathComponent("a/b/x"))
        let tail = root.appendingPathComponent("a/b/c")
        try fm.createDirectory(at: tail, withIntermediateDirectories: true)
        try Data().write(to: tail.appendingPathComponent("y1"))
        try Data().write(to: tail.appendingPathComponent("y2"))
        model.bumpTreeRevision()

        let grown = try waitForChain(in: state, render: render, height: 3 * h)
        XCTAssertEqual(grown?.frame.height, 3 * h,
                       "the grown chain a/b/c did not list y1 and y2 under its row")
    }

    // MARK: - Helpers

    /// Turns the run loop until the expanded chain headed `a` reports `height`,
    /// and answers its last report; `XCTFail` after three seconds.
    private func waitForChain(
        in state: TreeRevealHostState, render: HostedRender, height: CGFloat
    ) throws -> TreeStickyFolderReport? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            render.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if chain(in: state)?.frame.height == height { break }
        }
        return chain(in: state)
    }

    private func chain(in state: TreeRevealHostState) -> TreeStickyFolderReport? {
        state.reports.first { $0.isExpanded && $0.scrollID.hasSuffix("/p/a") }
    }

    /// A real temporary project `p`: `a/b/` holding one file `x`, and a root
    /// file `f`.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("tree-chain-reshape-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p")
        let folder = root.appendingPathComponent("a/b")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("x"))
        try Data().write(to: root.appendingPathComponent("f"))
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }
}
#endif
