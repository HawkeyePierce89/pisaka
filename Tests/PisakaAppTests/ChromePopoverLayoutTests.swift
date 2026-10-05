#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The bar popover component, hosted in a real window and measured off a
/// rendered bitmap: what the container and its pieces *draw*, against the
/// `ChromeGeometry` tokens they are built from.
///
/// **Five renders, five windows, and no more.** The branch popover is rendered
/// once at interface scale 1.0 and once at 1.8, the project popover the same,
/// and the branch popover once more under a cap shorter than its content; every
/// measurement in a case is read off that case's one bitmap. One more case is
/// no render at all: an unwindowed hosting view's fitting size, for a cap
/// shorter than the fixed slots alone. There is
/// no render per row and no screen-recording API; the colour swatches are
/// `HostedRender`'s, cached per role for the life of the process.
///
/// **What the branch bitmap holds.** A stub git service answers a current local
/// branch, a second local branch and one remote branch; a checkout it refuses
/// then leaves the model's error standing beside that list, so the Foot draws.
/// "New Branch…" — the first row — is selected.
///
/// **What the project bitmap holds.** Two recent projects, the current one
/// first and selected. Besides the selected row's height, a second column down
/// the glyph slot's centre reads the slot itself: the current row's check
/// pulling its pixels toward `accent`, and nothing but fill through the other
/// row's band.
///
/// **Reading a column.** The measurements are taken down one column three
/// quarters of the way across the container, clear of every title, the field's
/// placeholder and the remote row's chevron. Each pixel there is classified as
/// the nearest of the roles the container paints — `hairline` and `bgPopover`
/// are only three steps apart per channel in the dark palette, so a plain
/// tolerance match would read the fill as a rule — and the classified column is
/// read as runs: the container's top stroke, the field box, the selected row,
/// the Head's rule, the Foot's rule and the bottom stroke.
///
/// **The section header's height.** A list row with no ground draws nothing in
/// the column, so the first Local row's top is not visible on its own. The List
/// runs from the Head's rule to the Foot's rule and holds two headers, three
/// 28-point rows and the 6-point bottom padding, so one header's height is that
/// span less the rows and padding, halved — read entirely off the bitmap — and
/// is held to its two padding tokens plus the drawn line height of its font.
///
/// **The tolerance is half a point, or one bitmap pixel where that is larger.**
/// A token at scale 1.8 lands off the pixel grid (8 × 1.8 is 14.4), layout snaps
/// each edge onto it, and a bitmap rendered at one pixel per point then draws
/// 14.4 as 15. Half a point is the bound wherever a pixel is that fine.
@MainActor
final class ChromePopoverLayoutTests: XCTestCase {

    func testTheBranchPopoverDrawsItsMeasurements() async throws {
        try await assertBranchPopover(scale: 1)
    }

    func testTheBranchPopoverDrawsItsMeasurementsAtInterfaceScaleOnePointEight() async throws {
        try await assertBranchPopover(scale: 1.8)
    }

    /// Under a `maxHeight` shorter than its content the container is exactly
    /// that tall, and the List alone gives up height: the Head's rule and the
    /// Foot's rule are both still drawn, the Foot's flush above the bottom
    /// stroke.
    func testTheBranchPopoverCapsItsHeightAndOnlyTheListGivesUpHeight() async throws {
        let metrics = InterfaceMetrics(scale: 1)
        let model = BranchSwitcherModel(gitService: ChromePopoverStubGit())
        await model.refresh(root: URL(fileURLWithPath: "/tmp/repo"))
        let second = try XCTUnwrap(model.filteredLocalBranches.first { !$0.isCurrent })
        await model.switchTo(second)
        XCTAssertNotNil(model.errorMessage, "the Foot has nothing to draw")

        let cap: CGFloat = 180
        let context = ChromePopoverContext(
            maxHeight: cap,
            selectedRowID: BranchSwitcherPopover.newBranchRowID,
            activateRow: { _ in }
        )
        let render = try PopoverRender(metrics: metrics, height: 420) {
            BranchSwitcherPopover(model: model, context: context)
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let x = render.origin + metrics.scaled(ChromeGeometry.popoverWidth) * 0.75
        let runs = render.column(atX: x)
        let rules = runs.filter { $0.label == .hairline }
        XCTAssertGreaterThanOrEqual(rules.count, 4, "too few hairline rules in the column: \(runs)")
        guard rules.count >= 4 else { return }
        let top = rules[0]
        let bottom = rules[rules.count - 1]
        let footRule = rules[rules.count - 2]
        let selected = try XCTUnwrap(runs.first { $0.label == .selection }, "no selected row drawn")
        let headRule = try XCTUnwrap(rules.first { $0.minY >= selected.maxY }, "no Head rule drawn")
        XCTAssertEqual(bottom.maxY - top.minY, cap, accuracy: render.tolerance, "the container is not capped")
        XCTAssertGreaterThan(footRule.minY, headRule.maxY, "the Foot's rule is not below the List")
        XCTAssertEqual(
            headRule.minY - selected.maxY, 4, accuracy: render.tolerance,
            "the Head gave up its bottom padding under the cap"
        )
    }

    /// Under a cap shorter than the Head and Foot alone — a long wrapping error,
    /// a short window — the container still never exceeds the cap: the fixed
    /// slots give up height too rather than push the popover outside the window.
    func testTheContainerNeverExceedsACapShorterThanItsFixedSlots() {
        let cap: CGFloat = 60
        let popover = ChromePopover(
            maxHeight: cap,
            head: { Color.clear.frame(height: 50) },
            list: { Color.clear.frame(height: 100) },
            foot: Color.clear.frame(height: 50)
        )
        .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
        .environment(\.chromeTheme, ChromeTheme(.dark))
        let host = NSHostingView(rootView: popover)
        XCTAssertEqual(host.fittingSize.height, cap, accuracy: 0.5, "the fixed slots pushed the container past its cap")
    }

    func testTheProjectRowDrawsItsHeight() throws {
        try assertProjectPopover(scale: 1)
    }

    func testTheProjectRowDrawsItsHeightAtInterfaceScaleOnePointEight() throws {
        try assertProjectPopover(scale: 1.8)
    }

    // MARK: - Assertions

    private func assertBranchPopover(scale: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        let metrics = InterfaceMetrics(scale: scale)
        let model = BranchSwitcherModel(gitService: ChromePopoverStubGit())
        let root = URL(fileURLWithPath: "/tmp/repo")
        await model.refresh(root: root)
        let second = try XCTUnwrap(model.filteredLocalBranches.first { !$0.isCurrent }, file: file, line: line)
        await model.switchTo(second)
        XCTAssertEqual(model.filteredLocalBranches.count, 2, file: file, line: line)
        XCTAssertEqual(model.filteredRemoteBranches.count, 1, file: file, line: line)
        XCTAssertNotNil(model.errorMessage, "the Foot has nothing to draw", file: file, line: line)

        let context = ChromePopoverContext(
            maxHeight: metrics.scaled(ChromeGeometry.popoverMaxHeight),
            selectedRowID: BranchSwitcherPopover.newBranchRowID,
            activateRow: { _ in }
        )
        let render = try PopoverRender(metrics: metrics, height: 420) {
            BranchSwitcherPopover(model: model, context: context)
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let s = CGFloat(scale)
        let tolerance = render.tolerance
        let x = render.origin + metrics.scaled(ChromeGeometry.popoverWidth) * 0.75
        let runs = render.column(atX: x)
        let rules = runs.filter { $0.label == .hairline }
        XCTAssertGreaterThanOrEqual(rules.count, 4, "too few hairline rules in the column: \(runs)", file: file, line: line)
        guard rules.count >= 4 else { return }
        let top = rules[0]
        let bottom = rules[rules.count - 1]
        let footRule = rules[rules.count - 2]
        let selected = try XCTUnwrap(
            runs.first { $0.label == .selection }, "no selected row drawn at scale \(scale)", file: file, line: line
        )
        let headRule = try XCTUnwrap(
            rules.first { $0.minY >= selected.maxY }, "no Head rule drawn at scale \(scale)", file: file, line: line
        )
        let fieldTop = try XCTUnwrap(
            runs.first { $0.minY >= top.maxY && $0.label != .fill }, "no field box drawn", file: file, line: line
        ).minY
        let fieldBottom = try XCTUnwrap(
            runs.last { $0.maxY <= selected.minY && $0.label != .fill }, "no field box drawn", file: file, line: line
        ).maxY

        let width = try XCTUnwrap(render.strokeSpan(atY: (selected.minY + selected.maxY) / 2), file: file, line: line)
        XCTAssertEqual(width, 300 * s, accuracy: tolerance, "the container is not 300 points wide at scale \(scale)", file: file, line: line)
        XCTAssertEqual(
            fieldTop - top.minY, 8 * s, accuracy: tolerance,
            "the field block's top padding at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            selected.minY - fieldBottom, 8 * s, accuracy: tolerance,
            "the field block's bottom padding at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            selected.maxY - selected.minY, 28 * s, accuracy: tolerance,
            "the selected row's ground is not 28 points at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            headRule.maxY - headRule.minY, 1 * s, accuracy: tolerance,
            "the Head's rule thickness at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            footRule.maxY - footRule.minY, 1 * s, accuracy: tolerance,
            "the Foot's rule thickness at scale \(scale)", file: file, line: line
        )
        XCTAssertGreaterThan(footRule.minY, headRule.maxY, "the Foot's rule is not below the List", file: file, line: line)
        XCTAssertGreaterThan(bottom.minY, footRule.maxY, "the bottom stroke is not below the Foot", file: file, line: line)

        let list = footRule.minY - headRule.maxY
        let header = (list - (3 * 28 + 6) * s) / 2
        let lineHeight = NSHostingView(
            rootView: Text("Local").font(metrics.scaledFont(.subheadline, weight: .semibold))
        ).fittingSize.height
        XCTAssertEqual(
            header, 12 * s + 4 * s + lineHeight, accuracy: 1,
            "a section header's height at scale \(scale)", file: file, line: line
        )
    }

    private func assertProjectPopover(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let rows = [
            RecentProject(id: "a", url: URL(fileURLWithPath: "/tmp/alpha"), name: "alpha", path: "/tmp/alpha", isCurrent: true),
            RecentProject(id: "b", url: URL(fileURLWithPath: "/tmp/beta"), name: "beta", path: "/tmp/beta", isCurrent: false),
        ]
        let context = ChromePopoverContext(
            maxHeight: metrics.scaled(ChromeGeometry.popoverMaxHeight),
            selectedRowID: "project:a",
            activateRow: { _ in }
        )
        let render = try PopoverRender(metrics: metrics, height: 260) {
            ProjectSwitcherPopover(rows: rows, context: context)
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let tolerance = render.tolerance
        let x = render.origin + metrics.scaled(ChromeGeometry.popoverWidth) * 0.75
        let selected = try XCTUnwrap(
            render.column(atX: x).first { $0.label == .selection },
            "no selected project row drawn at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            selected.maxY - selected.minY, 36 * CGFloat(scale), accuracy: tolerance,
            "the selected project row's ground is not 36 points at scale \(scale)", file: file, line: line
        )

        // The glyph slot's centre column: the current row draws its check in
        // `accent`; the other row's slot is empty, so its band is all fill.
        // At one pixel per point the check's thin stroke covers no pixel
        // whole, so the current row's reading asks for a pixel that leans
        // from the selected ground toward `accent` rather than one that
        // matches it.
        let slotX = render.origin
            + metrics.scaled(ChromeGeometry.popoverRowPaddingX)
            + metrics.scaled(ChromeGeometry.popoverRowGlyphSlot) / 2
        func labels(_ column: [PopoverRender.Run], from minY: CGFloat, to maxY: CGFloat) -> [PopoverRender.Run] {
            column.filter { $0.maxY > minY + tolerance && $0.minY < maxY - tolerance }
        }
        XCTAssertTrue(
            render.hasPixel(
                atX: slotX, from: selected.minY + tolerance, to: selected.maxY - tolerance,
                nearer: .focus, than: .selection
            ),
            "no check drawn in the current row's slot at scale \(scale)", file: file, line: line
        )
        let other = labels(render.column(atX: slotX), from: selected.maxY, to: selected.maxY + 36 * CGFloat(scale))
        XCTAssertTrue(
            other.allSatisfy { $0.label == .fill },
            "the non-current row's slot is not empty at scale \(scale): \(other)", file: file, line: line
        )
    }
}

/// A popover hosted in a borderless window on a black ground, inset by
/// `origin` points from its top-leading corner (`HostedRender`), with the
/// column and row readings the suite measures from.
@MainActor
private final class PopoverRender {
    /// What a pixel is classified as: the nearest of the roles the container
    /// paints, or `other` when it is close to none of them.
    enum Label: Equatable {
        case hairline, fill, field, focus, selection, other
    }

    struct Run: CustomStringConvertible {
        let label: Label
        let minY: CGFloat
        let maxY: CGFloat
        var description: String { "\(label) \(minY)–\(maxY)" }
    }

    private let render: HostedRender
    let origin: CGFloat
    var window: NSWindow { render.window }

    /// Half a point, or one bitmap pixel where a pixel is larger — the
    /// suite header says why.
    var tolerance: CGFloat { max(0.5, 1 / render.pixelScale) }

    private let swatches: [(Label, NSColor)]

    init<V: View>(metrics: InterfaceMetrics, height: Double, @ViewBuilder content: () -> V) throws {
        origin = metrics.scaled(20)
        let size = CGSize(
            width: metrics.scaled(ChromeGeometry.popoverWidth + 40),
            height: metrics.scaled(height)
        )
        let theme = ChromeTheme(.dark)
        let root = content()
            .padding(origin)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, theme)
            .background(Color.black)
        render = try HostedRender(size: size, root: root)
        let popover = theme.color(.bgPopover)
        swatches = try [
            (.hairline, XCTUnwrap(HostedRender.swatch(.hairline, ground: nil))),
            (.fill, XCTUnwrap(HostedRender.swatch(.bgPopover, ground: nil))),
            (.field, XCTUnwrap(HostedRender.swatch(.bgEditor, ground: nil))),
            (.focus, XCTUnwrap(HostedRender.swatch(.accent, ground: nil))),
            (.selection, XCTUnwrap(HostedRender.swatch(.accentTintStrong, ground: popover))),
        ]
    }

    /// The nearest swatch to `color`, or `other` beyond 0.02 per channel from all.
    private func classify(_ color: NSColor?) -> Label {
        guard let color else { return .other }
        let nearest = swatches.map { ($0.0, Self.distance(color, $0.1)) }.min { $0.1 < $1.1 }
        guard let nearest, nearest.1 < 0.02 else { return .other }
        return nearest.0
    }

    /// Whether any pixel of column `x` between `minY` and `maxY` is nearer the
    /// swatch of `label` than that of `other` — a stroke too thin to cover a
    /// pixel whole still pulls it off the ground toward its own colour.
    func hasPixel(atX x: CGFloat, from minY: CGFloat, to maxY: CGFloat, nearer label: Label, than other: Label) -> Bool {
        guard let target = swatches.first(where: { $0.0 == label })?.1,
              let ground = swatches.first(where: { $0.0 == other })?.1 else { return false }
        let scale = render.pixelScale
        return (Int((minY * scale).rounded())..<Int((maxY * scale).rounded())).contains { py in
            guard let color = render.color(atX: x, y: (CGFloat(py) + 0.5) / scale) else { return false }
            return Self.distance(color, target) < Self.distance(color, ground)
        }
    }

    private static func distance(_ color: NSColor, _ swatch: NSColor) -> CGFloat {
        max(
            abs(color.redComponent - swatch.redComponent),
            abs(color.greenComponent - swatch.greenComponent),
            abs(color.blueComponent - swatch.blueComponent)
        )
    }

    /// Column `x`, top to bottom, as runs of one label each, in points.
    func column(atX x: CGFloat) -> [Run] {
        let scale = render.pixelScale
        let pixels = Int((render.bounds.height * scale).rounded())
        var runs: [Run] = []
        var current: (label: Label, start: Int)?
        for py in 0...pixels {
            let label = py < pixels ? classify(render.color(atX: x, y: (CGFloat(py) + 0.5) / scale)) : nil
            if let open = current, open.label != label {
                runs.append(Run(label: open.label, minY: CGFloat(open.start) / scale, maxY: CGFloat(py) / scale))
                current = nil
            }
            if current == nil, let label { current = (label, py) }
        }
        return runs
    }

    /// The distance, in points, from the left edge of the first `hairline`
    /// pixel in the row at `y` to the right edge of the last — the container's
    /// two stroke columns, outer edge to outer edge.
    func strokeSpan(atY y: CGFloat) -> CGFloat? {
        let hits = (0..<render.pixelsWide).filter { classify(render.color(atPixelX: $0, y: y)) == .hairline }
        guard let first = hits.first, let last = hits.last else { return nil }
        return CGFloat(last + 1 - first) / render.pixelScale
    }
}

/// A repository with a current local branch, a second local branch and one
/// remote, which refuses every checkout with a short message. Which local
/// branch is current is settable, for the presenter suite's HEAD move. Shared
/// with `ChromePopoverPresenterTests`.
final class ChromePopoverStubGit: GitServicing {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Checkout refused" }
    }

    func repositoryRoot(for url: URL) async throws -> URL { url }
    func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
    func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
    func headContents(of path: String, root: URL) async throws -> String? { nil }
    func revert(_ file: ChangedFile, root: URL) async throws {}
    func references(root: URL) async throws -> [String] {
        ["refs/heads/main", "refs/heads/topic", "refs/remotes/origin/main"]
    }
    var currentName = "main"

    func currentBranch(root: URL) async throws -> BranchRef? {
        BranchRef.build(fromRefnames: ["refs/heads/\(currentName)"], current: currentName).first
    }
    func checkout(branch: String, root: URL) async throws { throw Refused() }
}
#endif
