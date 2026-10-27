#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// A folder node's test-row answer as the hosted tree computes it.
///
/// **The property.** `TreeTestRule` judges a row by its contents directory's
/// path below the root, which the tree builds from listing names: the parent's
/// components plus the row's `TreeNodeShape.segmentNames` — every segment, for
/// a chain. So the Maven layout `src/test/java`, which folds into one chain
/// row, is a test row by its inner `test` segment, and `lib/core` is not. The
/// node's answer is also what its `TreeStickyFolderReport` carries, which the
/// pinned copy paints from, so the report is the place both are read: a chain
/// path built from its head alone, or a report handed a literal, fails here
/// where `TreeTestRuleTests`' hand-built paths cannot see it.
///
/// **How it is measured.** One window at interface scale 1 over a temporary
/// project `p` holding `src/test/java/Foo.java` and `lib/core/x` — two chains,
/// as each folder holds only the next. A reveal of `Foo.java` expands the first
/// chain; a second reveal, of `lib/core/x`, the other. Collapsed nodes report
/// nothing, so each wait is a condition on the expanded report arriving,
/// failing loudly.
@MainActor
final class TreeTestRowReportTests: XCTestCase {

    func testAChainIsJudgedByAllItsSegmentsAndItsReportCarriesTheAnswer() throws {
        let root = try makeProject()
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let first = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("src/test/java/Foo.java"), root: root)
        )
        let state = TreeRevealHostState(reveal: first)
        let render = try HostedRender(
            size: CGSize(width: 240, height: 300),
            root: TreeRevealHost(model: model, state: state, metrics: InterfaceMetrics(scale: 1))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let testChain = try XCTUnwrap(waitForExpanded("/p/src", in: state, render: render),
                                      "the chain src/test/java never reported itself expanded")
        XCTAssertTrue(testChain.isTestRow, "src/test/java is not a test row by its inner test segment")
        let rootReport = try XCTUnwrap(state.reports.first { $0.scrollID.hasSuffix("/p") }, "no report for the root")
        XCTAssertFalse(rootReport.isTestRow, "the project root is marked")

        state.reveal = TreeRevealRequest(after: first, revealing: root.appendingPathComponent("lib/core/x"), root: root)
        let plainChain = try XCTUnwrap(waitForExpanded("/p/lib", in: state, render: render),
                                       "the chain lib/core never reported itself expanded")
        XCTAssertFalse(plainChain.isTestRow, "lib/core is marked although no segment names a test folder")
    }

    // MARK: - Helpers

    /// Turns the run loop until an expanded node whose scroll id ends in
    /// `suffix` reports, and answers it; `nil` after three seconds.
    private func waitForExpanded(
        _ suffix: String, in state: TreeRevealHostState, render: HostedRender
    ) -> TreeStickyFolderReport? {
        let deadline = Date().addingTimeInterval(3)
        func report() -> TreeStickyFolderReport? {
            state.reports.first { $0.isExpanded && $0.scrollID.hasSuffix(suffix) }
        }
        while report() == nil, Date() < deadline {
            render.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return report()
    }

    /// A real temporary project `p`: `src/test/java/Foo.java` and `lib/core/x`.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("tree-test-row-report-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p")
        for file in ["src/test/java/Foo.java", "lib/core/x"] {
            let url = root.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }
}
#endif
