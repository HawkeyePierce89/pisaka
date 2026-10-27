#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// A reveal reaches a tree that is already on screen.
///
/// **The property.** A `DirectoryNodeView` already on screen expands for a
/// request that names it from its `.onChange(of: reveal)`. That action must read
/// the request it was called for: the deprecated one-argument `onChange` reads
/// the previous update's `reveal`, which for a node on screen before the request
/// is `nil`, so the node never expanded and the reveal did nothing. The
/// on-screen *file row*'s report, the same defect at the other site, is pinned
/// by `TreeStickyScrollRoundingTests`, whose second reveal reaches a row already
/// drawn.
///
/// **How it is measured.** One window at interface scale 1 over a temporary
/// project `p` holding `t/x` and a root file `f`. The tree is hosted with no
/// request, settles with `t` collapsed, and then a request for `t/x` is
/// published through `TreeRevealHost`. The wait is causal: it turns the run
/// loop, laying the host out each turn, until `t` reports itself expanded
/// through `TreeStickyFoldersKey`, and fails loudly if it never does.
@MainActor
final class TreeRevealOnScreenTests: XCTestCase {

    func testARevealExpandsAFolderAlreadyOnScreen() throws {
        let root = try makeProject()
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let state = TreeRevealHostState(reveal: nil)

        let render = try HostedRender(
            size: CGSize(width: 240, height: 300),
            root: TreeRevealHost(model: model, state: state, metrics: InterfaceMetrics(scale: 1))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        // Seen, not assumed: the tree has reported (the root, expanded) and
        // `t` is not among the expanded nodes, so the wait below has work to do.
        XCTAssertTrue(state.reports.contains { $0.isExpanded && $0.scrollID.hasSuffix("/p") },
                      "the tree reported no expanded root before the request")
        XCTAssertNil(expandedT(in: state), "t is expanded before any request")

        state.reveal = TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("t/x"), root: root)
        let deadline = Date().addingTimeInterval(3)
        while expandedT(in: state) == nil, Date() < deadline {
            render.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNotNil(expandedT(in: state), "the reveal never expanded t, which was already on screen")
    }

    // MARK: - Helpers

    private func expandedT(in state: TreeRevealHostState) -> TreeStickyFolderReport? {
        state.reports.first { $0.isExpanded && $0.scrollID.hasSuffix("/p/t") }
    }

    /// A real temporary project `p`: `t/` holding one file `x`, and a root
    /// file `f`.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("tree-reveal-on-screen-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p")
        let folder = root.appendingPathComponent("t")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("x"))
        try Data().write(to: root.appendingPathComponent("f"))
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }
}
#endif
