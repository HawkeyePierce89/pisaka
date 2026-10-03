#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The bottom bar's measurements, read off the real `BottomBar` rendered to a
/// bitmap at interface scale 1.0 and 1.8.
///
/// **What it pins.** The design's bar: the panel toggles are 22-point squares
/// two points apart, the completion switch the last of them at the bar's
/// trailing padding; the active toggle's ground is `accentTint` (not the
/// stronger tint it used to be); and the widgets at the leading end start at
/// the bar's padding and sit 14 points apart.
///
/// **How it is hosted — and the one seam.** The bar is `BottomBar`, its own
/// view in `ContentView.swift`, hosted alone on the `bgPanel` ground the window
/// root paints under it, with the theme and the metrics injected the way the
/// root injects them. That struct exists for this suite: the whole window root
/// was hosted first and does not settle in a headless window in any useful time
/// (one render ran past four minutes), so the bar was lifted out of it into a
/// view the root constructs — the drawing is the same code, and the ground and
/// the `.zIndex(1)` stay the root's (`BottomPanelSourceGatingTests`). No
/// project is open, so nothing runs git, and the Pull Requests model is never
/// asked anything, so the indicator draws nothing; the project→branch gap is
/// the widget gap this suite can see.
///
/// **How it is measured.** A toggle is an icon-only square whose ground is
/// drawn only while it is active, so its extent is the set of columns holding
/// an `accentTint` pixel (over `bgPanel`) anywhere in the bar's band — the
/// union over rows, so neither the glyph in the middle nor the rounded corners
/// shorten it — and its height the same pixels' extent down its centre column.
/// Two renders give three squares: Usages and the completion switch active
/// together, then Problems alone; the two panels are neighbours, so their gap is
/// the toggle gap directly, and the Usages-to-switch distance spans the Pull
/// Requests toggle and two more gaps.
///
/// A widget gap is the widest ink-free run of columns at the bar's leading end
/// — ink meaning any pixel in the bar's band that is not its ground. The glyphs
/// do not fill their slots, so the run is the gap *plus* the trailing chevron's
/// and the branch glyph's own insets; each inset is measured independently by
/// rendering that glyph alone through the same helper and pipeline, so the gap
/// is never measured against itself.
///
/// **What it costs.** Each state is rendered once and every scan reads that
/// one bitmap; the reference colours are `HostedRender`'s cached swatches, so
/// no scan opens a window (`HostedRenderTests`), and each column's samples are
/// drained in their own `autoreleasepool`.
@MainActor
final class BottomBarLayoutTests: XCTestCase {

    func testTheTogglesAreSquaresTwoPointsApartAtScaleOne() throws {
        try assertToggles(scale: 1)
    }

    func testTheTogglesAreSquaresTwoPointsApartAtScaleOnePointEight() throws {
        try assertToggles(scale: 1.8)
    }

    func testTheWidgetsAreFourteenPointsApartAtScaleOne() throws {
        try assertWidgets(scale: 1)
    }

    func testTheWidgetsAreFourteenPointsApartAtScaleOnePointEight() throws {
        try assertWidgets(scale: 1.8)
    }

    func testTheCaretReadoutSitsTenPointsAfterTheTogglesAtScaleOne() throws {
        try assertReadout(scale: 1)
    }

    func testTheCaretReadoutSitsTenPointsAfterTheTogglesAtScaleOnePointEight() throws {
        try assertReadout(scale: 1.8)
    }

    // MARK: - Toggles

    private func assertToggles(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let side = metrics.scaled(ChromeGeometry.bottomBarToggleSide)
        let gap = metrics.scaled(2)

        let both = try render(scale: scale, panel: .usages, completionOn: true)
        let bothRuns = both.activeGroundRuns()
        XCTAssertEqual(
            bothRuns.count, 2,
            "expected the Usages and completion squares on accentTint at scale \(scale), got \(bothRuns)",
            file: file, line: line
        )
        let alone = try render(scale: scale, panel: .problems, completionOn: false)
        let aloneRuns = alone.activeGroundRuns()
        XCTAssertEqual(
            aloneRuns.count, 1,
            "expected the Problems square alone on accentTint at scale \(scale), got \(aloneRuns)",
            file: file, line: line
        )
        guard bothRuns.count == 2, let problems = aloneRuns.first else { return }
        let usages = bothRuns[0]
        let completion = bothRuns[1]

        for (name, run, render) in [("Problems", problems, alone), ("Usages", usages, both), ("completion", completion, both)] {
            XCTAssertEqual(
                run.maxX - run.minX, side, accuracy: 1,
                "the \(name) toggle is not \(ChromeGeometry.bottomBarToggleSide) points wide at scale \(scale)",
                file: file, line: line
            )
            let height = try XCTUnwrap(
                render.activeGroundHeight(atX: (run.minX + run.maxX) / 2),
                "no accentTint down the \(name) toggle's centre", file: file, line: line
            )
            XCTAssertEqual(
                height, side, accuracy: 1,
                "the \(name) toggle is not \(ChromeGeometry.bottomBarToggleSide) points tall at scale \(scale)",
                file: file, line: line
            )
        }
        XCTAssertEqual(
            usages.minX - problems.maxX, gap, accuracy: 1,
            "neighbouring toggles are not two points apart at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            completion.minX - usages.maxX, side + 2 * gap, accuracy: 1,
            "Usages, Pull Requests and the completion switch are not packed two points apart at scale \(scale)",
            file: file, line: line
        )
        XCTAssertEqual(
            completion.maxX, both.width - metrics.scaled(ChromeGeometry.barPaddingX), accuracy: 1,
            "the completion switch does not end at the bar's trailing padding at scale \(scale)",
            file: file, line: line
        )
    }

    // MARK: - Caret readout

    /// The completion switch is drawn active so its square's trailing edge is
    /// the last toggle's; the readout's first ink sits ten points past it plus
    /// the text's own leading side bearing, measured by rendering the same text
    /// alone so the gap is never measured against itself.
    private func assertReadout(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let readout = "Ln 12, Col 5 · UTF-8 · Swift"
        let bar = try render(scale: scale, panel: .problems, completionOn: true, caretReadout: readout)
        let runs = bar.activeGroundRuns()
        XCTAssertEqual(runs.count, 2, "expected the Problems and completion squares at scale \(scale), got \(runs)",
                       file: file, line: line)
        let completion = try XCTUnwrap(runs.last, file: file, line: line)
        let ink = try XCTUnwrap(
            bar.inkRuns(from: completion.maxX + 1, upToX: bar.width).first,
            "nothing drawn after the completion switch at scale \(scale)", file: file, line: line
        )
        let text = try TextInsets(readout, metrics: metrics)
        XCTAssertEqual(
            ink.minX - completion.maxX - text.leading, metrics.scaled(10), accuracy: 1,
            "the caret readout is not 10 points after the last toggle at scale \(scale)", file: file, line: line
        )
        let lastInk = try XCTUnwrap(bar.inkRuns(from: completion.maxX + 1, upToX: bar.width).last)
        XCTAssertEqual(
            lastInk.maxX + text.trailing, bar.width - metrics.scaled(ChromeGeometry.barPaddingX), accuracy: 1,
            "the caret readout does not end at the bar's trailing padding at scale \(scale)", file: file, line: line
        )
    }

    // MARK: - Widgets

    private func assertWidgets(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let bar = try render(scale: scale, panel: .problems, completionOn: false)
        let chevron = try GlyphInsets(.chevronDown, size: 10, metrics: metrics)
        let branch = try GlyphInsets(.gitBranch, size: 12, metrics: metrics)
        let package = try GlyphInsets(.package, size: 12, metrics: metrics)

        // Only the leading half: the toggles live at the trailing end.
        let runs = bar.inkRuns(upToX: bar.width / 2)
        let firstInk = try XCTUnwrap(runs.first, "the bar's leading end draws nothing", file: file, line: line)
        XCTAssertEqual(
            firstInk.minX, metrics.scaled(ChromeGeometry.barPaddingX) + package.leading, accuracy: 1,
            "the project widget does not start at the bar's padding at scale \(scale)", file: file, line: line
        )

        // The first gap wider than anything inside a widget (4 points plus a
        // glyph's inset, or a space between words) is the widget gap.
        let threshold = metrics.scaled(10)
        let gaps = zip(runs, runs.dropFirst()).map { $1.minX - $0.maxX }
        let widgetGap = try XCTUnwrap(
            gaps.first { $0 > threshold },
            "no gap between the project and branch widgets at scale \(scale): \(runs)", file: file, line: line
        )
        XCTAssertEqual(
            widgetGap - chevron.trailing - branch.leading, metrics.scaled(14), accuracy: 1,
            "the project and branch widgets are not 14 points apart at scale \(scale)", file: file, line: line
        )
    }

    // MARK: - Hosting

    private func render(
        scale: Double,
        panel: BottomPanel,
        completionOn: Bool,
        caretReadout: String = ""
    ) throws -> BottomBarRender {
        let suite = "pisaka.tests.bottomBar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(completionOn, forKey: SettingsStore.Keys.completionEnabled)
        let metrics = InterfaceMetrics(scale: scale)
        let bar = BottomBar(
            branchSwitcher: BranchSwitcherModel(gitService: GitCLIService()),
            pullRequestModel: PullRequestCoordinator(transport: NoGitHubCLI()).model,
            activePanel: panel,
            settings: SettingsStore(defaults: defaults),
            caretReadout: caretReadout
        )
        let render = try BottomBarRender(bar: bar, metrics: metrics)
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }
}

/// A `gh` that is never installed, so nothing could run a process.
private struct NoGitHubCLI: GitHubCLITransport {
    func run(_ command: GitHubCommand) async throws -> GitHubCommandResult {
        throw GitHubCLIError.notInstalled
    }
}

/// `BottomBar` in a borderless window (`HostedRender`) on the ground the window
/// root paints under it.
@MainActor
private final class BottomBarRender {
    private let render: HostedRender
    private let metrics: InterfaceMetrics
    var window: NSWindow { render.window }
    var width: CGFloat { render.bounds.width }
    private var height: CGFloat { render.bounds.height }
    private let ground = ChromeTheme(.dark).color(.bgPanel)

    init(bar: BottomBar, metrics: InterfaceMetrics) throws {
        self.metrics = metrics
        let size = CGSize(width: 1000 * metrics.scale, height: metrics.scaled(ChromeGeometry.bottomBarHeight))
        let root = bar
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .frame(width: size.width, height: size.height)
            .background(ChromeTheme(.dark).color(.bgPanel))
        render = try HostedRender(size: size, root: root)
    }

    private var rows: [CGFloat] {
        Array(stride(from: 0, to: height, by: 1 / render.pixelScale))
    }

    /// The x extents of the columns holding an `accentTint` pixel anywhere in
    /// the bar — the active toggles' grounds.
    func activeGroundRuns() -> [(minX: CGFloat, maxX: CGFloat)] {
        let ys = rows
        return runs(upToX: width) { x in
            ys.contains { render.matches(.accentTint, atX: x, y: $0, ground: ground) }
        }
    }

    /// The height of the `accentTint` pixels down column `x`.
    func activeGroundHeight(atX x: CGFloat) -> CGFloat? {
        render.extent(of: .accentTint, atX: x, ground: ground).map { $0.maxY - $0.minY }
    }

    /// The x extents of the columns carrying any ink — a pixel that is not the
    /// bar's ground.
    func inkRuns(from origin: CGFloat = 0, upToX limit: CGFloat) -> [(minX: CGFloat, maxX: CGFloat)] {
        let ys = rows
        return runs(from: origin, upToX: limit) { x in ys.contains { !render.matches(.bgPanel, atX: x, y: $0) } }
    }

    private func runs(
        from origin: CGFloat = 0,
        upToX limit: CGFloat,
        where hit: (CGFloat) -> Bool
    ) -> [(minX: CGFloat, maxX: CGFloat)] {
        let step = 1 / render.pixelScale
        var result: [(minX: CGFloat, maxX: CGFloat)] = []
        var start: CGFloat?
        var x: CGFloat = (origin * render.pixelScale).rounded(.down) / render.pixelScale
        while x < limit {
            if autoreleasepool(invoking: { hit(x) }) {
                if start == nil { start = x }
            } else if let open = start {
                result.append((open, x))
                start = nil
            }
            x += step
        }
        if let open = start { result.append((open, x)) }
        return result
    }
}

/// How far a glyph's ink sits inside its slot on each side, measured by
/// rendering it alone through `DesignGlyphImage` on the bar's ground.
@MainActor
private struct GlyphInsets {
    let leading: CGFloat
    let trailing: CGFloat

    init(_ glyph: DesignGlyph, size: Double, metrics: InterfaceMetrics) throws {
        let slot = metrics.scaled(size)
        let pad = metrics.scaled(8)
        let ground = ChromeTheme(.dark).color(.bgPanel)
        let root = DesignGlyphImage(glyph, size: size, slot: size, role: .textSecondary)
            .padding(pad)
            .background(ground)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
        let render = try HostedRender(size: CGSize(width: slot + 2 * pad, height: slot + 2 * pad), root: root)
        defer { render.window.close() }
        let step = 1 / render.pixelScale
        let ys = Array(stride(from: pad, to: pad + slot, by: step))
        let ink = stride(from: 0, to: slot + 2 * pad, by: step).filter { x in
            autoreleasepool { ys.contains { !render.matches(.bgPanel, atX: x, y: $0) } }
        }
        let first = try XCTUnwrap(ink.first, "\(glyph) draws no ink")
        let last = try XCTUnwrap(ink.last)
        leading = first - pad
        trailing = pad + slot - (last + step)
    }
}
/// How far a caret readout's ink sits inside its text frame on each side,
/// measured by rendering it alone at the bar's font and colour.
@MainActor
private struct TextInsets {
    let leading: CGFloat
    let trailing: CGFloat

    init(_ text: String, metrics: InterfaceMetrics) throws {
        let pad = metrics.scaled(8)
        let label = Text(text)
            .font(metrics.scaledFont(.subheadline))
            .lineLimit(1)
            .fixedSize()
        let width = NSHostingView(rootView: label).fittingSize.width
        let height = metrics.scaled(ChromeGeometry.bottomBarHeight)
        let ground = ChromeTheme(.dark).color(.bgPanel)
        let root = label
            .foregroundStyle(ChromeTheme(.dark).color(.textSecondary))
            .frame(width: width, height: height)
            .padding(.horizontal, pad)
            .background(ground)
        let render = try HostedRender(size: CGSize(width: width + 2 * pad, height: height), root: root)
        defer { render.window.close() }
        let step = 1 / render.pixelScale
        let ys = Array(stride(from: 0, to: height, by: step))
        let ink = stride(from: 0, to: width + 2 * pad, by: step).filter { x in
            autoreleasepool { ys.contains { !render.matches(.bgPanel, atX: x, y: $0) } }
        }
        let first = try XCTUnwrap(ink.first, "the readout draws no ink")
        let last = try XCTUnwrap(ink.last)
        leading = first - pad
        trailing = pad + width - (last + step)
    }
}
#endif
