#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The pinned stack (`TreeStickyRule`), hosted in a real window and measured
/// off a rendered bitmap.
///
/// **The design.** While an expanded folder's real row has scrolled above the
/// viewport and its subtree continues below, a copy of that row is pinned in
/// the first row slot directly under the pane header — drawn exactly as the
/// real row draws: the same chevron and glyph at the same depth's slots, the
/// name in its git role, the glyph carrying its diagnostic dot, every
/// enclosing folder's guide running through it, and one `hairline` along the
/// stack's bottom edge.
///
/// **How it is measured.** At interface scale 1.8, in a window
/// `metrics.scaled(240) × metrics.scaled(300)`, dark theme, over a temporary
/// project whose `a/` holds forty files, with `a/f03` modified and an error in
/// `a/f07`. Two renders in all, each one window read out of its one bitmap:
/// - **Render A**, no reveal: `a` collapsed in row 1. Its name colour and dot
///   colour are read, and the root row's chevron — the expanded artwork, at
///   depth 0 — is measured.
/// - **Render B**, a reveal of `a/f30`, centred, so `a`'s real row is above the
///   viewport. The copy's chevron and glyph must be inked in the first row
///   slot under the header at the depth-1 slots (`TreeChainRowLayoutTests`'
///   slot functions); the chevron must be the root's artwork, one indent step
///   right of it and placed in its slot exactly as the root's is in row 0;
///   the name and dot colours must equal render A's and match their roles;
///   the hairline must run at the stack's bottom edge, and the root's guide
///   through the copy at the depth-0 guide centre.
///
/// Its accessibility is pinned off the source instead, for the reason the
/// test states.
///
/// The reveal scrolls with an animation, which moves the clip view's bounds
/// and no view's frame, so the frame-settling harness alone cannot see it
/// finish: render B first waits for the clip view's origin to hold still away
/// from the top, failing loudly if it never does.
@MainActor
final class TreeStickyStackLayoutTests: XCTestCase {

    func testAPinnedFolderDrawsAsItsRealRowUnderTheHeader() throws {
        let metrics = InterfaceMetrics(scale: 1.8)
        let root = try makeProject()
        let gitStatus = TreeGitStatus(
            snapshot: GitStatusSnapshot(
                changedFiles: [ChangedFile(path: "a/f03", status: .modified)], ignoredPaths: []
            ),
            repositoryRoot: root,
            openedFolder: root
        )
        let diagnostics = errorLookup(in: root.appendingPathComponent("a/f07"), root: root)

        let header = metrics.scaled(ChromeGeometry.sidebarHeaderHeight)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let padding = metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = metrics.scaled(TreeRowLayout.chevronWidth)
        let gap = metrics.scaled(TreeRowLayout.chevronSpacing)
        let icon = metrics.scaled(TreeRowLayout.iconSize)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        let thickness = metrics.scaled(ChromeGeometry.hairlineWidth)
        let dot = metrics.scaled(TreeRowLayout.diagnosticDotSize)
        // Unscrolled, the tree's rows start under the header and the list's
        // top padding; the stack's first slot starts at the header itself.
        let top = header + metrics.scaled(4)
        func row(_ index: Int) -> Range<CGFloat> {
            (top + CGFloat(index) * rowHeight)..<(top + CGFloat(index + 1) * rowHeight)
        }
        let pinnedSlot = header..<(header + rowHeight)
        func chevronSlot(depth: Int) -> Range<CGFloat> {
            let start = CGFloat(depth) * indent + padding
            return start..<(start + chevron)
        }
        func glyphSlot(depth: Int) -> Range<CGFloat> {
            let start = chevronSlot(depth: depth).upperBound + gap
            return start..<(start + icon)
        }
        func guideCentre(depth: Int) -> CGFloat { CGFloat(depth) * indent + padding + chevron / 2 }
        let size = CGSize(width: metrics.scaled(240), height: metrics.scaled(300))

        // Render A — `a` collapsed in row 1.
        let renderA = try HostedRender(
            size: size,
            root: tree(root, metrics: metrics, gitStatus: gitStatus, diagnostics: diagnostics, reveal: nil)
        )
        addTeardownBlock { @MainActor in renderA.window.close() }
        let step = 1 / renderA.pixelScale
        /// The bottom-trailing quarter of the depth-1 glyph slot in `rows`.
        func dotCorner(_ rows: Range<CGFloat>) -> (x: Range<CGFloat>, rows: Range<CGFloat>) {
            let slot = glyphSlot(depth: 1)
            let glyphTop = rows.lowerBound + (rowHeight - icon) / 2
            return (
                (slot.upperBound - dot - step)..<slot.upperBound,
                (glyphTop + icon - dot - step)..<(glyphTop + icon)
            )
        }
        let nameX = glyphSlot(depth: 1).upperBound..<renderA.bounds.width
        let nameA = try XCTUnwrap(first(.statusYellow, in: renderA, x: nameX, rows: row(1)),
                                  "a's real row drew no statusYellow name")
        let cornerA = dotCorner(row(1))
        let dotA = try XCTUnwrap(first(.statusRed, in: renderA, x: cornerA.x, rows: cornerA.rows),
                                 "a's real row drew no statusRed dot")
        let rootChevron = try XCTUnwrap(ink(in: renderA, x: chevronSlot(depth: 0), rows: row(0)),
                                        "the root row drew no chevron")

        // Render B — `a/f30` revealed, `a`'s real row above the viewport.
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("a/f30"), root: root)
        )
        let renderB = try HostedRender(
            size: size,
            root: tree(root, metrics: metrics, gitStatus: gitStatus, diagnostics: diagnostics, reveal: reveal)
        )
        addTeardownBlock { @MainActor in renderB.window.close() }
        let scrolled = try waitForScrollToSettle(in: renderB)
        XCTAssertGreaterThan(scrolled, row(1).upperBound, "the reveal did not scroll a's real row out of view")
        renderB.settle()
        try renderB.capture()

        // The chevron and the glyph, at the depth-1 slots of the first slot.
        let pinnedChevron = try XCTUnwrap(ink(in: renderB, x: chevronSlot(depth: 1), rows: pinnedSlot),
                                          "no chevron in the first row slot under the header")
        XCTAssertGreaterThan(pinnedChevron.width, chevron / 3,
                             "the first slot's depth-1 chevron column holds a rule, not a chevron")
        XCTAssertEqual(pinnedChevron.minX - rootChevron.minX, indent, accuracy: step * 2,
                       "the pinned chevron is not one indent step right of the root's")
        XCTAssertEqual(pinnedChevron.width, rootChevron.width, accuracy: step * 2,
                       "the pinned chevron is not the expanded row's artwork")
        XCTAssertEqual(pinnedChevron.height, rootChevron.height, accuracy: step * 2,
                       "the pinned chevron is not the expanded row's artwork")
        XCTAssertEqual(pinnedChevron.minY - pinnedSlot.lowerBound, rootChevron.minY - row(0).lowerBound,
                       accuracy: step * 2, "the pinned row does not start directly under the header")
        let pinnedGlyph = try XCTUnwrap(ink(in: renderB, x: glyphSlot(depth: 1), rows: pinnedSlot),
                                        "no folder glyph in the first row slot under the header")
        XCTAssertGreaterThan(pinnedGlyph.width, icon / 2, "the pinned glyph slot holds no folder glyph")

        // The name and the dot: render A's colours, in their roles.
        let nameB = try XCTUnwrap(first(.statusYellow, in: renderB, x: nameX, rows: pinnedSlot),
                                  "the pinned copy's name is not drawn in its git role, statusYellow")
        let cornerB = dotCorner(pinnedSlot)
        let dotB = try XCTUnwrap(first(.statusRed, in: renderB, x: cornerB.x, rows: cornerB.rows),
                                 "the pinned copy's glyph carries no statusRed dot")
        XCTAssertTrue(close(nameA, nameB), "the pinned name's colour \(nameB) is not the real row's \(nameA)")
        XCTAssertTrue(close(dotA, dotB), "the pinned dot's colour \(dotB) is not the real row's \(dotA)")

        // The hairline along the stack's bottom edge, read down a column
        // right of every name and left of the scroller, where no row draws.
        let edge = renderB.bounds.width * 0.6
        let rule = stride(from: header + step, to: header + 2 * rowHeight, by: step).filter {
            renderB.matches(.hairline, atX: edge, y: $0)
        }
        let ruleTop = try XCTUnwrap(rule.first, "no hairline under the pinned row")
        let ruleBottom = try XCTUnwrap(rule.last) + step
        XCTAssertEqual(ruleBottom, pinnedSlot.upperBound, accuracy: step * 2,
                       "the hairline does not run at the stack's bottom edge")
        XCTAssertEqual(ruleBottom - ruleTop, thickness, accuracy: step * 2,
                       "the stack's bottom rule is not the scaled hairline width")

        // The root's guide runs through the copy, which grounds everything
        // else it covers in `bgPanel`.
        let guideGaps = stride(from: pinnedSlot.lowerBound + step, to: ruleTop - step, by: step).filter {
            !renderB.matches(.hairline, atX: guideCentre(depth: 0), y: $0)
        }
        XCTAssertTrue(guideGaps.isEmpty, "the root's guide does not run through the pinned row at y \(guideGaps)")
        XCTAssertTrue(renderB.matches(.bgPanel, atX: guideCentre(depth: 1), y: pinnedSlot.lowerBound + step),
                      "the pinned row does not draw its bgPanel ground over the rows it covers")
    }

    /// The whole stack is hidden from accessibility: the real rows carry
    /// everything a reader needs, and a copy announced beside them would name
    /// each pinned folder twice.
    ///
    /// **Why the source, and not the accessibility tree.** Headless, SwiftUI
    /// builds no accessibility nodes for the hosted tree: measured, the hosting
    /// view's `accessibilityChildren()` is empty and an accessibility hit test
    /// over the pinned row answers the hosting view itself, with the window
    /// ordered front or not — so a probe of the tree passes whether or not the
    /// overlay is hidden. The modifier is therefore read off
    /// `ProjectTreeView.swift`, comments stripped so a sentence quoting it
    /// cannot stand in for it, inside `TreeStickyStackView`'s declaration.
    func testThePinnedStackIsHiddenFromAccessibility() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Pisaka/ProjectTreeView.swift")
        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "private struct TreeStickyStackView"),
                                  "ProjectTreeView.swift declares no TreeStickyStackView")
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\nprivate struct ")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(rest[..<end].contains(".accessibilityHidden(true)"),
                      "the pinned stack is not hidden from accessibility")
    }

    // MARK: - Helpers

    private func tree(
        _ root: URL, metrics: InterfaceMetrics, gitStatus: TreeGitStatus, diagnostics: TreeDiagnostics,
        reveal: TreeRevealRequest?
    ) -> some View {
        let model = WorkspaceModel()
        model.openFolder(url: root)
        return ProjectTreeView(model: model, reveal: reveal, gitStatus: gitStatus, diagnostics: diagnostics)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
    }

    /// One error diagnostic in `file`.
    private func errorLookup(in file: URL, root: URL) -> TreeDiagnostics {
        var store = DiagnosticStore()
        let serverKey = DiagnosticStore.ServerKey(serverID: "test-server", root: root.path)
        store.replace(url: file, serverKey: serverKey, diagnostics: [
            Diagnostic(
                range: NSRange(location: 0, length: 1), line: 0, severity: .error,
                message: "m", source: "test", fileURL: file
            ),
        ])
        return TreeDiagnostics(store: store, root: TreeDiagnostics.Root(root))
    }

    /// Turns the run loop until the hosted scroll view's clip origin has left
    /// the top and held still for five turns, and answers it; `XCTFail` after
    /// three seconds. A condition, not a window: the animated reveal lands
    /// whenever it lands.
    private func waitForScrollToSettle(in render: HostedRender) throws -> CGFloat {
        let clip = try XCTUnwrap(Self.scrollView(in: render.host), "the tree hosts no NSScrollView").contentView
        let deadline = Date().addingTimeInterval(3)
        var previous = clip.bounds.origin.y
        var stableTurns = 0
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let origin = clip.bounds.origin.y
            stableTurns = origin == previous && origin > 0 ? stableTurns + 1 : 0
            if stableTurns >= 5 { return origin }
            previous = origin
        }
        XCTFail("the reveal's scroll never settled")
        return clip.bounds.origin.y
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    /// The first pixel in `x` × `rows` painted `role`, as rendered. Reads the
    /// one bitmap.
    private func first(
        _ role: ChromeColorRole, in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>
    ) -> NSColor? {
        let step = 1 / render.pixelScale
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step)
            where render.matches(role, atX: px, y: py) {
                return render.color(atX: px, y: py)
            }
        }
        return nil
    }

    /// The bounding box of every pixel in `x` × `rows` that differs from the
    /// row's ground — sampled at the row's leading edge, inside the padding —
    /// or `nil` when the region is clean. Reads the one bitmap.
    private func ink(in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>) -> CGRect? {
        let step = 1 / render.pixelScale
        guard let ground = render.color(atX: step, y: (rows.lowerBound + rows.upperBound) / 2) else { return nil }
        var box: CGRect?
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step) {
                guard let color = render.color(atX: px, y: py), !close(color, ground, tolerance: 0.08) else {
                    continue
                }
                let pixel = CGRect(x: px, y: py, width: step, height: step)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    private func close(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }

    /// A root folder whose `a/` holds forty files, removed in teardown.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeStickyStackLayoutTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data().write(to: folder.appendingPathComponent(String(format: "f%02d", index)))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
