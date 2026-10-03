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
/// `accent` ground, the next two are glyph-sized. Which glyph is which is read
/// off the same bitmap by shape: each glyph cluster's ink mask is compared with
/// a reference render of the revert and refresh glyphs alone (one extra render
/// per scale), and the in-order pairing must be the closer one. The hosting
/// view's accessibility tree cannot name them — headless, SwiftUI builds no
/// accessibility nodes, so only its AppKit scroll view is exposed. The row
/// order compares the status colour's rightmost pixel with the name's
/// leftmost `textPrimary` one.
///
/// **The inline-diff placeholders.** A selected binary or over-cap file is
/// rendered once per state; the detail area beside the list must draw
/// `textSecondary` text where the rows would sit, shaped like a reference render
/// of that state's sentence rather than of "Loading…", and no diff-row wash — its
/// two outer strips are the panel's ground and nothing else.
///
/// **The rows state: the divider paints inside its bounds.** One modified text
/// file (five lines, the third changed) is selected and its `.rows` diff
/// published — the view's own appearance-time load, waited on by polling the
/// model and the hosted tree with a deadline that fails loudly — then rendered
/// at scales 1.0 and 1.8. `DiffDividerView` once filled the rect `draw(_:)` was
/// handed, which since macOS 14 (`clipsToBounds` defaulting to `false`) is not
/// limited to its bounds, and painted `hairline` over the list and the header.
/// Positive: the modified letter's colour and the name's `textPrimary` in the
/// file row, the header's `textSecondary` path, and the divider between the
/// panes (found from the hosted `DiffContainerView`'s subviews) carrying
/// `hairline` — read as the leftmost pixel column's blend between the left
/// pane's `bgEditor` and `hairline`, against the share of that pixel the
/// one-point divider covers, because at 1.8 the split lands it on a half pixel
/// and its right half is drawn over by the right pane. Negative: no pixel
/// matching `hairline` in exactly these bands, computed from the hosted frames
/// (the list's `NSScrollView` and the `DiffContainerView`) and the panel's
/// scaled measurements, never from pixel offsets:
/// - **the file rows**, from the list's leading edge to its trailing edge (the
///   list/diff divider is past it), from the header's bottom edge to the end of
///   the second row — minus the checkbox column (`fileRowInset` plus
///   `checkboxSide`, widened by one hairline for its antialiased edge), whose
///   off-state border is a legitimate `hairline`;
/// - **the header's text band**, the header's frame above its bottom rule —
///   minus the path's own measured ink widened by two points, because
///   `textSecondary`'s antialiased edge over the panel passes through
///   `hairline`'s value.
/// The legitimate rules all lie outside: the list/diff divider at the list's
/// trailing edge, the toolbar's bottom rule above the list's top, and the
/// header's bottom rule below the header band.
///
/// **The diff window.** `DiffWindowContent` over the same rows, at scale 1:
/// once its `DiffContainerView` is in the tree, the left pane's gutter must
/// carry `textSecondary` line numbers — the defect left that whole pane
/// `hairline`.
///
/// **The render path.** Every render is `cacheDisplay(in:to:)` of the hosting
/// view (`HostedRender`), offscreen. It hands `draw(_:)` the same unclipped
/// rect the window does — the rows renders and the diff-window render all fail
/// on the unfixed divider — so no other path was needed; nothing reads the
/// screen or a window's backing, since a screen-recording API raises a system
/// permission dialog. Each diff render pins its window to the dark appearance
/// before the capture, because the diff panes are AppKit and resolve their
/// dynamic colours by it.
///
/// **Why nothing earlier saw it.** Every frame stayed correct, so no frame or
/// accessibility assertion could; and the placeholder renders draw no
/// `DiffView` at all, so no divider existed to paint over them.
///
/// **Windows.** Thirteen hosted renders: two panel renders plus two glyph
/// references (scales 1.0 and 1.8), two placeholder renders with two sentence
/// references each, two rows renders and one diff-window render — each one
/// window — plus one window per distinct swatch, cached for the process.
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

        // Which glyph is which: Revert before Refresh. The two are the same
        // size and colour, so each cluster's ink *shape* is matched against a
        // reference render of the two glyphs alone — the headless hosting view
        // builds no SwiftUI accessibility nodes to name them by (only its
        // AppKit scroll view appears there, even with app accessibility forced
        // on), so the panel's own bitmap is the one witness.
        let band = metrics.scaled(2)..<(toolbarHeight - metrics.scaled(2))
        let references = try toolbarGlyphReferences(metrics: metrics, theme: theme, ground: panel)
        let first = inkMask(in: render, rows: band, columns: clusters[1])
        let second = inkMask(in: render, rows: band, columns: clusters[2])
        let inOrder = distance(first, references.revert) + distance(second, references.refresh)
        let swapped = distance(first, references.refresh) + distance(second, references.revert)
        XCTAssertLessThan(
            inOrder, swapped,
            "the toolbar's glyphs do not read Revert then Refresh at scale \(scale)", file: file, line: line
        )

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

    func testABinaryFileShowsThePlaceholderInPlaceOfTheRows() async throws {
        let files = StubFiles()
        files.text = "a\u{0}b\n"
        try await assertPlaceholder(files: files, expected: .binary, text: "Binary file")
    }

    func testAnOverCapFileShowsThePlaceholderInPlaceOfTheRows() async throws {
        let files = StubFiles()
        files.stamp = FileStamp(byteCount: LocalChangesInlineDiff.maxSideBytes + 1, modificationDate: nil)
        try await assertPlaceholder(files: files, expected: .tooLarge, text: "Too large to show inline")
    }

    private func assertPlaceholder(
        files: StubFiles,
        expected: LocalChangesInlineDiff.Content,
        text expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp/LocalChangesLayoutTests-project")
        let changed = ChangedFile(path: "data.bin", status: .modified)
        let model = LocalChangesModel(gitService: StubGit(files: [changed]), fileService: files)
        await model.refresh(root: root)
        model.select(changed)
        await model.loadSelectionDiff(token: model.beginSelectionDiffLoad())
        XCTAssertEqual(model.selectionDiff?.content, expected, file: file, line: line)

        let theme = ChromeTheme(.dark)
        let panel = theme.color(.bgPanel)
        let render = try HostedRender(
            size: CGSize(width: 900, height: 240),
            root: LocalChangesView(model: model, projectRoot: root)
                .background(panel)
                .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
                .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }

        // The detail body: right of the list's divider, below the toolbar and
        // the detail's path header.
        let bodyTop = LocalChangesLayout.toolbarHeight + LocalChangesLayout.detailHeaderHeight + 2
        let rows = CGFloat(bodyTop)..<238
        let columns = CGFloat(330)..<898
        let text = xExtent(in: render, rows: rows, columns: columns) {
            render.matches(.textSecondary, atX: $0, y: $1, ground: panel)
        }
        XCTAssertNotNil(text, "no textSecondary placeholder where the rows would sit", file: file, line: line)

        // A row wash spans its pane's full width, so it is looked for in the
        // detail's two outer strips — one inside each side's pane — which the
        // centred placeholder never reaches (the text's own antialiased edges
        // would otherwise pass for a wash). Every pixel there must be the
        // panel's ground: a row of any kind, washed or not, fails. Read as
        // "not ground" rather than as a wash swatch, because the diff panes are
        // AppKit and resolve their dynamic colours by the window's appearance,
        // not by the SwiftUI theme this render injects.
        XCTAssertGreaterThan(text?.lowerBound ?? 0, 420, "the placeholder is not centred", file: file, line: line)
        XCTAssertLessThan(text?.upperBound ?? .infinity, 820, "the placeholder is not centred", file: file, line: line)
        for strip in [CGFloat(330)..<400, CGFloat(830)..<898] {
            let drawn = xExtent(in: render, rows: rows, columns: strip) {
                !render.matches(.bgPanel, atX: $0, y: $1)
            }
            XCTAssertNil(drawn, "the detail drew a diff row under a placeholder at \(strip)", file: file, line: line)
        }

        // Which sentence it is: every placeholder is drawn alike, so the ink is
        // read by shape — its mask compared with reference renders of the
        // expected sentence and of "Loading…", the one a stale
        // `diff.file == selected` check would leave standing — and must be the
        // closer to the expected one. ("Binary file" and "Loading…" are within
        // two points of each other in width, so width alone cannot tell.)
        guard let text else { return }
        let drawn = inkMask(in: render, rows: rows, columns: text)
        let expectedDistance = distance(drawn, try referenceMask(of: expectedText, theme: theme))
        let loadingDistance = distance(drawn, try referenceMask(of: "Loading…", theme: theme))
        XCTAssertLessThan(
            expectedDistance, loadingDistance,
            "the placeholder reads closer to \"Loading…\" than to \"\(expectedText)\"", file: file, line: line
        )
    }

    // MARK: - The divider paints inside its own bounds

    func testASelectedDiffLeavesThePanelDrawnAtScaleOne() async throws {
        try await assertSelectedDiffPanel(scale: 1)
    }

    func testASelectedDiffLeavesThePanelDrawnAtScaleOnePointEight() async throws {
        try await assertSelectedDiffPanel(scale: 1.8)
    }

    /// The panel over a published `.rows` diff: the list, the header and the
    /// two panes all draw, the divider between the panes is `hairline`, and no
    /// pixel of the list's file rows or the header's text band is.
    private func assertSelectedDiffPanel(
        scale: Double, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let metrics = InterfaceMetrics(scale: scale)
        let root = URL(fileURLWithPath: "/tmp/LocalChangesLayoutTests-project")
        let changed = ChangedFile(path: "Sources/Main.swift", status: .modified)
        let files = StubFiles()
        files.text = Self.workingText
        let model = LocalChangesModel(
            gitService: StubGit(files: [changed], head: Data(Self.headText.utf8)), fileService: files
        )
        await model.refresh(root: root)
        model.select(changed)

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
        try await settleOnDiff(render, file: file, line: line) {
            if case .rows = model.selectionDiff?.content { return true }
            return false
        }

        let container = try XCTUnwrap(Self.diffContainer(in: render.host), file: file, line: line)
        let containerFrame = render.host.convert(container.bounds, from: container)
        let listScroll = try XCTUnwrap(
            Self.views(of: NSScrollView.self, in: render.host).first { !$0.isDescendant(of: container) },
            "the list's scroll view is not in the hosted tree", file: file, line: line
        )
        let listFrame = render.host.convert(listScroll.bounds, from: listScroll)
        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let headerTop = containerFrame.minY - metrics.scaled(LocalChangesLayout.detailHeaderHeight)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let listTop = listFrame.minY + metrics.scaled(LocalChangesLayout.listPaddingY)
        // The list's two rows: the `Sources` folder, then Main.swift.
        let fileRows = containerFrame.minY..<(listTop + rowHeight * 2)
        let headerText = headerTop..<(containerFrame.minY - hairline)

        // The list draws: the modified letter and the name, in the file row.
        let listColumns = listFrame.minX..<listFrame.maxX
        let status = ChromeColorRole.changedFileRole(for: .modified)
        XCTAssertNotNil(
            xExtent(in: render, rows: fileRows, columns: listColumns) {
                render.matches(status, atX: $0, y: $1, ground: panel)
            },
            "no status letter in the file row at scale \(scale)", file: file, line: line
        )
        XCTAssertNotNil(
            xExtent(in: render, rows: fileRows, columns: listColumns) {
                render.matches(.textPrimary, atX: $0, y: $1, ground: panel)
            },
            "no file name in the file row at scale \(scale)", file: file, line: line
        )
        // The header draws its path.
        let path = try XCTUnwrap(
            xExtent(in: render, rows: headerText, columns: containerFrame.minX..<containerFrame.maxX) {
                render.matches(.textSecondary, atX: $0, y: $1, ground: panel)
            },
            "no path in the detail header at scale \(scale)", file: file, line: line
        )
        // The divider between the panes is `hairline`.
        let divider = try XCTUnwrap(
            container.subviews.first { $0 is DiffDividerView }, file: file, line: line
        )
        let dividerFrame = render.host.convert(divider.bounds, from: divider)
        let share = try XCTUnwrap(dividerLeftShare(in: render, frame: dividerFrame), file: file, line: line)
        XCTAssertEqual(
            share.painted, share.expected, accuracy: 0.15,
            "the divider between the diff panes is not hairline at scale \(scale): \(share)",
            file: file, line: line
        )

        // No `hairline` pixel in either band. The rows band runs from the
        // list's leading edge to the list/diff divider (the list's trailing
        // edge, so the divider itself is outside), minus the checkbox column,
        // whose off-state border is a legitimate `hairline` (its frame widened
        // by one hairline for the border's antialiased edge at a fractional
        // scale); it starts below the header's bottom rule. The header band is
        // the header minus that rule, and minus the path's own ink — widened
        // by two points, because `textSecondary`'s antialiased edge over the
        // panel passes through `hairline`'s value; the toolbar's rule sits
        // above both.
        let checkboxStart = listFrame.minX + metrics.scaled(LocalChangesLayout.fileRowInset)
        let checkboxEnd = checkboxStart + metrics.scaled(ChromeGeometry.checkboxSide) + hairline
        let bands: [(name: String, rows: Range<CGFloat>, columns: Range<CGFloat>)] = [
            ("the file rows before the checkbox", fileRows, listFrame.minX..<checkboxStart),
            ("the file rows past the checkbox", fileRows, checkboxEnd..<listFrame.maxX),
            ("the header before its path", headerText, containerFrame.minX..<(path.lowerBound - 2)),
            ("the header past its path", headerText, (path.upperBound + 2)..<containerFrame.maxX),
        ]
        for band in bands {
            let painted = xExtent(in: render, rows: band.rows, columns: band.columns) {
                render.matches(.hairline, atX: $0, y: $1, ground: panel)
            }
            XCTAssertNil(
                painted, "\(band.name) carry hairline pixels at \(painted.map { "\($0)" } ?? "") at scale \(scale)",
                file: file, line: line
            )
        }
    }

    /// The `hairline` share of the leftmost pixel column `frame` overlaps,
    /// read at `frame`'s vertical middle as that pixel's blend between the left
    /// pane's `bgEditor` ground and `hairline` — against the fraction of the
    /// pixel the frame covers. The divider is one point wide at a position the
    /// split computes, so at a fractional scale it straddles two pixels and
    /// neither is pure `hairline`; its right half is the right pane's (added
    /// after it, so drawn over it), which is why only the left column is read.
    private func dividerLeftShare(
        in render: HostedRender, frame: CGRect
    ) -> (painted: Double, expected: Double)? {
        guard
            let hairline = HostedRender.swatch(.hairline, ground: nil),
            let ground = HostedRender.swatch(.bgEditor, ground: nil)
        else { return nil }
        let left = frame.minX * render.pixelScale
        let column = left.rounded(.down)
        let covered = min(column + 1, frame.maxX * render.pixelScale) - left
        guard let c = render.color(atPixelX: Int(column), y: frame.midY) else { return nil }
        let shares = [
            (c.redComponent - ground.redComponent) / (hairline.redComponent - ground.redComponent),
            (c.greenComponent - ground.greenComponent) / (hairline.greenComponent - ground.greenComponent),
            (c.blueComponent - ground.blueComponent) / (hairline.blueComponent - ground.blueComponent),
        ]
        return (Double(shares.reduce(0, +) / 3), Double(covered))
    }

    /// The separate diff window's content over the same rows: the left pane's
    /// gutter draws its line numbers.
    func testTheDiffWindowDrawsItsLeftPane() async throws {
        let suite = "pisaka.tests.localChangesLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let rows = LineDiff.rows(old: Self.headText, new: Self.workingText)
        let theme = ChromeTheme(.dark)
        let render = try HostedRender(
            size: CGSize(width: 900, height: 240),
            root: DiffWindowContent(
                fileID: "Sources/Main.swift", fileName: "Main.swift",
                load: { rows }, settings: SettingsStore(defaults: defaults)
            )
        )
        addTeardownBlock { @MainActor in render.window.close() }
        try await settleOnDiff(render) { true }

        let container = try XCTUnwrap(Self.diffContainer(in: render.host))
        let leftScroll = try XCTUnwrap(container.subviews.first as? NSScrollView)
        let gutter = try XCTUnwrap(leftScroll.verticalRulerView, "the left pane has no gutter")
        let gutterFrame = render.host.convert(gutter.bounds, from: gutter)
        XCTAssertGreaterThan(gutterFrame.width, 0, "the left gutter has no width")
        let numbers = xExtent(
            in: render, rows: gutterFrame.minY..<gutterFrame.maxY, columns: gutterFrame.minX..<gutterFrame.maxX
        ) {
            render.matches(.textSecondary, atX: $0, y: $1, ground: theme.color(.bgEditor))
        }
        XCTAssertNotNil(numbers, "the left pane's gutter drew no line numbers")
    }

    /// Five lines on `HEAD`, the third changed in the working copy, so both
    /// panes carry text and gutter numbers.
    private static let headText = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5\n"
    private static let workingText = "let a = 1\nlet b = 2\nlet c = 30\nlet d = 4\nlet e = 5\n"

    /// Pins the window to the dark appearance — the diff panes are AppKit and
    /// resolve their dynamic colours by it — then turns the run loop until
    /// `ready` holds and a `DiffContainerView` is in the hosted tree, and
    /// re-renders the settled view. `XCTFail` after five seconds.
    private func settleOnDiff(
        _ render: HostedRender, file: StaticString = #filePath, line: UInt = #line, ready: () -> Bool
    ) async throws {
        render.window.appearance = NSAppearance(named: .darkAqua)
        let deadline = Date().addingTimeInterval(5)
        while !(ready() && Self.diffContainer(in: render.host) != nil) {
            guard Date() < deadline else {
                XCTFail("the diff never reached the hosted tree", file: file, line: line)
                return
            }
            render.host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        render.settle(file: file, line: line)
        try render.capture()
    }

    private static func diffContainer(in view: NSView) -> DiffContainerView? {
        views(of: DiffContainerView.self, in: view).first
    }

    private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// The ink mask of `sentence` drawn as the panel's placeholders are:
    /// `textSecondary`, the callout size, on the panel ground.
    private func referenceMask(of sentence: String, theme: ChromeTheme) throws -> Set<InkPixel> {
        let panel = theme.color(.bgPanel)
        let metrics = InterfaceMetrics(scale: 1)
        let render = try HostedRender(
            size: CGSize(width: 568, height: 60),
            root: Text(sentence)
                .foregroundStyle(theme.color(.textSecondary))
                .font(metrics.scaledFont(.callout))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(panel)
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let extent = try XCTUnwrap(xExtent(in: render, rows: 0..<60, columns: 0..<568) {
            render.matches(.textSecondary, atX: $0, y: $1, ground: panel)
        })
        return inkMask(in: render, rows: 0..<60, columns: extent)
    }

    // MARK: - Glyph shapes

    /// One pixel of ink, relative to its mask's top-left inked pixel.
    private struct InkPixel: Hashable {
        let x: Int
        let y: Int
    }

    /// The revert and refresh glyphs' ink masks, read off one render of the two
    /// alone, drawn exactly as the toolbar draws them.
    private func toolbarGlyphReferences(
        metrics: InterfaceMetrics, theme: ChromeTheme, ground: Color
    ) throws -> (revert: Set<InkPixel>, refresh: Set<InkPixel>) {
        let glyph = LocalChangesLayout.toolbarGlyphSize
        let height = metrics.scaled(LocalChangesLayout.toolbarHeight)
        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(120), height: height),
            root: HStack(spacing: metrics.scaled(30)) {
                DesignGlyphImage(.undo2, size: glyph, slot: glyph, role: .textSecondary)
                DesignGlyphImage(.refreshCw, size: glyph, slot: glyph, role: .textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ground)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let band = metrics.scaled(2)..<(height - metrics.scaled(2))
        let clusters = inkClusters(
            in: render, rows: band, columns: 0..<metrics.scaled(120), mergeGap: metrics.scaled(3)
        )
        XCTAssertEqual(clusters.count, 2, "the reference render drew \(clusters.count) glyphs, not two")
        guard clusters.count == 2 else { return ([], []) }
        return (
            inkMask(in: render, rows: band, columns: clusters[0]),
            inkMask(in: render, rows: band, columns: clusters[1])
        )
    }

    /// The inked pixels in the band, relative to the top-left inked pixel.
    private func inkMask(in render: HostedRender, rows: Range<CGFloat>, columns: Range<CGFloat>) -> Set<InkPixel> {
        guard let ground = HostedRender.swatch(.bgPanel, ground: nil) else { return [] }
        let step = 1 / render.pixelScale
        var pixels: [InkPixel] = []
        for (i, x) in stride(from: columns.lowerBound, to: columns.upperBound, by: step).enumerated() {
            for (j, y) in stride(from: rows.lowerBound, to: rows.upperBound, by: step).enumerated()
            where isInk(render.color(atX: x, y: y), ground: ground) {
                pixels.append(InkPixel(x: i, y: j))
            }
        }
        let minX = pixels.map(\.x).min() ?? 0
        let minY = pixels.map(\.y).min() ?? 0
        return Set(pixels.map { InkPixel(x: $0.x - minX, y: $0.y - minY) })
    }

    /// The Jaccard distance between two masks at their best alignment within
    /// one pixel either way, so a sub-pixel placement difference between the
    /// panel and the reference does not read as a different shape.
    private func distance(_ lhs: Set<InkPixel>, _ rhs: Set<InkPixel>) -> Double {
        var best = 1.0
        for dx in -1...1 {
            for dy in -1...1 {
                let shifted = Set(rhs.map { InkPixel(x: $0.x + dx, y: $0.y + dy) })
                let union = lhs.union(shifted).count
                guard union > 0 else { continue }
                best = min(best, 1 - Double(lhs.intersection(shifted).count) / Double(union))
            }
        }
        return best
    }

    private func isInk(_ color: NSColor?, ground: NSColor) -> Bool {
        guard let c = color else { return false }
        return abs(c.redComponent - ground.redComponent) > 0.06
            || abs(c.greenComponent - ground.greenComponent) > 0.06
            || abs(c.blueComponent - ground.blueComponent) > 0.06
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
                isInk(render.color(atX: x, y: y), ground: ground)
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
        /// The `HEAD` blob every path answers with.
        let head: Data?
        init(files: [ChangedFile], head: Data? = nil) {
            self.files = files
            self.head = head
        }
        func headBlob(of path: String, root: URL) async throws -> Data? { head }
        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { files }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}
    }

    private final class StubFiles: FileServicing {
        /// The working copy's text and stamp; configured before any load.
        var text = ""
        var stamp: FileStamp?
        func read(url: URL) throws -> String { text }
        func fileStamp(at url: URL) -> FileStamp? { stamp }
        func write(_ text: String, to url: URL) throws {}
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? { nil }
        func isExecutableFile(at url: URL) -> Bool { false }
    }
}
#endif
