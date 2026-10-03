#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The commit dialog, hosted in a real window and measured off a rendered
/// bitmap.
///
/// **The design.** Top to bottom: the "Commit Changes" strip, 44 high; the
/// message box at full width, 20 from the sheet's edges and the rules around
/// it, counted in code-font lines; the file list, 260 wide, beside the diff;
/// and the 64-high footer, whose right end reads Cancel, Commit, then Commit
/// and Push on the `accent` ground — the one primary.
///
/// **How it is measured.** The dialog is rendered once per scale over one
/// loaded modified file with a message typed (so no status sentence stands
/// between the content and the footer), and every sample is read out of that
/// one bitmap. Each rule is a `hairline` row or column found by a scan; the
/// box's top and side edges are its first pixels off the panel ground, its
/// bottom its border's `hairline` row; the buttons are the
/// runs of inked columns across the footer's right half, clustered.
///
/// **The push reason.** One extra render, at scale one, over the same fixture
/// with no remote — so the push plan is unavailable and the footer carries its
/// reason as one line after Amend. The footer keeps its 64, the reason's ink lies
/// strictly between Amend's last ink and Cancel's first, and the left-hand
/// controls and the three buttons sit exactly where the available render put them.
@MainActor
final class CommitDialogLayoutTests: XCTestCase {

    func testTheDialogAtScaleOne() async throws {
        let available = try await assertDialog(scale: 1)
        try await assertPushReasonFooter(matching: available)
    }

    func testTheDialogAtScaleOnePointEight() async throws {
        _ = try await assertDialog(scale: 1.8)
    }

    /// The available render's footer ink, clustered across the full width.
    private struct FooterInk {
        let clusters: [Range<CGFloat>]
        let width: CGFloat
        var buttons: [Range<CGFloat>] { clusters.filter { $0.lowerBound >= width / 2 } }
        var leading: [Range<CGFloat>] { clusters.filter { $0.lowerBound < width / 2 } }
    }

    /// Render the dialog over `git` once, at `scale`, with a message typed.
    private func render(git: StubGit, scale: Double) async throws -> (CommitDialogModel, SettingsStore, HostedRender) {
        let metrics = InterfaceMetrics(scale: scale)
        let model = CommitDialogModel(gitService: git, fileService: StubFiles())
        await model.load(root: URL(fileURLWithPath: "/repo"))
        model.message = "subject"

        let suite = "CommitDialogLayoutTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)

        let theme = ChromeTheme(.dark)
        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(1000), height: metrics.scaled(640)),
            root: CommitDialogView(model: model, settings: settings)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return (model, settings, render)
    }

    /// The footer's top rule, scanning up from the bottom edge.
    private func footerRule(in render: HostedRender, metrics: InterfaceMetrics) -> CGFloat? {
        let width = metrics.scaled(1000)
        let height = metrics.scaled(640)
        let panel = ChromeTheme(.dark).color(.bgPanel)
        let step = 1 / render.pixelScale
        return stride(from: height - step, to: height - metrics.scaled(120), by: -step).first {
            render.matches(.hairline, atX: width / 2, y: $0, ground: panel)
        }
    }

    private func assertPushReasonFooter(
        matching available: FooterInk, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let metrics = InterfaceMetrics(scale: 1)
        let git = StubGit()
        git.remotes = []
        git.upstream = nil
        let (model, _, render) = try await render(git: git, scale: 1)
        XCTAssertNotNil(model.pushUnavailableMessage, "the fixture must make the push unavailable",
                        file: file, line: line)
        XCTAssertTrue(model.canCommit, "the fixture must leave Commit enabled", file: file, line: line)

        let width = metrics.scaled(1000)
        let height = metrics.scaled(640)
        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let step = 1 / render.pixelScale
        let rule = try XCTUnwrap(footerRule(in: render, metrics: metrics),
                                 "no rule above the footer with the push reason shown", file: file, line: line)
        XCTAssertEqual(
            height - (rule + hairline), metrics.scaled(CommitDialogLayout.footerHeight), accuracy: 1,
            "the push reason changed the footer's height", file: file, line: line
        )

        let clusters = inkClusters(
            in: render,
            rows: (rule + hairline + step)..<(height - step),
            columns: 0..<width,
            mergeGap: metrics.scaled(4)
        )
        let amendEnd = try XCTUnwrap(available.leading.last?.upperBound, "no Amend ink in the available render",
                                     file: file, line: line)
        let cancelStart = try XCTUnwrap(available.buttons.first?.lowerBound, "no Cancel in the available render",
                                        file: file, line: line)

        // The left-hand controls and the three buttons are where they were.
        let before = clusters.filter { $0.upperBound <= amendEnd + step }
        let buttons = clusters.filter { $0.lowerBound >= cancelStart - step }
        XCTAssertEqual(before.count, available.leading.count, "the author and Amend moved: \(before)",
                       file: file, line: line)
        for (got, want) in zip(before, available.leading) {
            XCTAssertEqual(got.lowerBound, want.lowerBound, accuracy: 1, "the author or Amend moved",
                           file: file, line: line)
        }
        XCTAssertEqual(buttons.count, 3, "the footer's right end did not draw three buttons: \(buttons)",
                       file: file, line: line)
        for (got, want) in zip(buttons, available.buttons) {
            XCTAssertEqual(got.lowerBound, want.lowerBound, accuracy: 1, "a button moved", file: file, line: line)
            XCTAssertEqual(got.upperBound, want.upperBound, accuracy: 1, "a button moved", file: file, line: line)
        }

        // The reason's ink: present, and strictly between Amend and Cancel.
        let reason = clusters.filter { $0.lowerBound > amendEnd + step && $0.upperBound < cancelStart - step }
        XCTAssertFalse(reason.isEmpty, "no push reason ink between Amend and Cancel", file: file, line: line)
        XCTAssertEqual(before.count + reason.count + buttons.count, clusters.count,
                       "footer ink outside the author, Amend, the reason and the buttons: \(clusters)",
                       file: file, line: line)
    }

    private func assertDialog(
        scale: Double, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> FooterInk {
        let metrics = InterfaceMetrics(scale: scale)
        let (model, settings, render) = try await render(git: StubGit(), scale: scale)
        XCTAssertTrue(model.canCommitAndPush, "the fixture must offer Commit and Push", file: file, line: line)
        XCTAssertNil(model.pushUnavailableMessage, "the fixture must show no push reason", file: file, line: line)

        let theme = ChromeTheme(.dark)
        let panel = theme.color(.bgPanel)
        let width = metrics.scaled(1000)
        let height = metrics.scaled(640)

        let hairline = metrics.scaled(ChromeGeometry.hairlineWidth)
        let step = 1 / render.pixelScale
        let blankX = width - metrics.scaled(40)

        // The header: its bottom rule closes a 44-point strip.
        let headerRule = try XCTUnwrap(
            stride(from: step, to: metrics.scaled(100), by: step).first {
                render.matches(.hairline, atX: blankX, y: $0, ground: panel)
            },
            "no rule under the header at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            headerRule + hairline, metrics.scaled(ChromeGeometry.dialogEdgeStripHeight), accuracy: 1,
            "the header is not 44 points high at scale \(scale)", file: file, line: line
        )
        let headerBottom = headerRule + hairline

        // The message box: 20 below the header and 20 in from the leading edge,
        // and as tall as four lines of the code font.
        let boxTop = try XCTUnwrap(
            stride(from: headerBottom + step, to: headerBottom + metrics.scaled(60), by: step).first {
                isInk(render.color(atX: width / 2, y: $0))
            },
            "no message box below the header at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            boxTop - headerBottom, metrics.scaled(CommitDialogLayout.messagePadding), accuracy: 1,
            "the message box is not 20 below the header at scale \(scale)", file: file, line: line
        )
        let boxMiddle = boxTop + metrics.scaled(10)
        let boxLeading = try XCTUnwrap(
            stride(from: step, to: metrics.scaled(60), by: step).first {
                isInk(render.color(atX: $0, y: boxMiddle))
            },
            "no message box edge at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            boxLeading, metrics.scaled(CommitDialogLayout.messagePadding), accuracy: 1,
            "the message box is not 20 in from the leading edge at scale \(scale)", file: file, line: line
        )
        let boxTrailing = try XCTUnwrap(
            stride(from: width - step, to: width - metrics.scaled(60), by: -step).first {
                isInk(render.color(atX: $0, y: boxMiddle))
            },
            "no message box trailing edge at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            width - (boxTrailing + step), metrics.scaled(CommitDialogLayout.messagePadding), accuracy: 1,
            "the message box is not full width less 20 at scale \(scale)", file: file, line: line
        )
        // The box's bottom border is its first `hairline` row past the top one
        // (its inside is `bgEditor`, too near the panel ground to tell by ink).
        let boxBottomBorder = try XCTUnwrap(
            stride(from: boxTop + metrics.scaled(4), to: boxTop + metrics.scaled(200), by: step).first {
                render.matches(.hairline, atX: width / 2, y: $0, ground: panel)
            },
            "the message box never ends at scale \(scale)", file: file, line: line
        )
        let boxBottom = boxBottomBorder + hairline
        let lineHeight = NSLayoutManager().defaultLineHeight(
            for: NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        )
        XCTAssertEqual(
            boxBottom - boxTop, lineHeight * 4, accuracy: 1,
            "the message box is not four code-font lines high at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            boxBottom - boxTop, 68, accuracy: 8,
            "the message box is not about 68 points high at the default code size", file: file, line: line
        )
        // …and 20 above the rule that closes its strip.
        let messageRule = try XCTUnwrap(
            stride(from: boxBottom, to: boxBottom + metrics.scaled(60), by: step).first {
                render.matches(.hairline, atX: blankX, y: $0, ground: panel)
            },
            "no rule under the message box at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            messageRule - boxBottom, metrics.scaled(CommitDialogLayout.messagePadding), accuracy: 1,
            "the message box is not 20 above its rule at scale \(scale)", file: file, line: line
        )

        // The footer: its top rule opens a 64-point strip at the bottom.
        let footerRule = try XCTUnwrap(
            footerRule(in: render, metrics: metrics),
            "no rule above the footer at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            height - (footerRule + hairline), metrics.scaled(CommitDialogLayout.footerHeight), accuracy: 1,
            "the footer is not 64 points high at scale \(scale)", file: file, line: line
        )

        // The file list: the divider's hairline at 260, in the band between the
        // message rule and the footer.
        let listBand = footerRule - metrics.scaled(20)
        let dividerX = try XCTUnwrap(
            stride(from: metrics.scaled(100), to: metrics.scaled(600), by: step).first {
                render.matches(.hairline, atX: $0, y: listBand, ground: panel)
            },
            "no divider beside the file list at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            dividerX, metrics.scaled(CommitDialogLayout.fileListWidth), accuracy: 1,
            "the file list is not 260 points wide at scale \(scale)", file: file, line: line
        )

        // The buttons, leading first across the footer's right half: Cancel,
        // Commit, Commit and Push — the last the one on the accent ground.
        let footerTop = footerRule + hairline + step
        let ink = FooterInk(
            clusters: inkClusters(
                in: render,
                rows: footerTop..<(height - step),
                columns: 0..<width,
                mergeGap: metrics.scaled(4)
            ),
            width: width
        )
        let buttons = ink.buttons
        XCTAssertEqual(buttons.count, 3, "the footer's right end did not draw three buttons: \(buttons)",
                       file: file, line: line)
        guard buttons.count == 3 else { return ink }
        let footerMiddle = footerTop + metrics.scaled(CommitDialogLayout.footerHeight) / 2
        let accented = buttons.map { button in
            stride(from: button.lowerBound, to: button.upperBound, by: step).contains {
                render.matches(.accent, atX: $0, y: footerMiddle, ground: panel)
            }
        }
        XCTAssertEqual(accented, [false, false, true],
                       "Commit and Push is not the last button and the only primary at scale \(scale)",
                       file: file, line: line)
        XCTAssertEqual(
            width - buttons[2].upperBound, metrics.scaled(CommitDialogLayout.messagePadding), accuracy: 1,
            "the primary does not end 20 from the trailing edge at scale \(scale)", file: file, line: line
        )
        return ink
    }

    // MARK: - Sampling (all off the one bitmap)

    /// The panel ground, rendered once per process through `HostedRender`'s cache.
    private var ground: NSColor? { HostedRender.swatch(.bgPanel, ground: nil) }

    /// Whether `color` is off the panel ground.
    private func isInk(_ color: NSColor?) -> Bool {
        guard let color, let ground else { return false }
        return abs(color.redComponent - ground.redComponent) > 0.03
            || abs(color.greenComponent - ground.greenComponent) > 0.03
            || abs(color.blueComponent - ground.blueComponent) > 0.03
    }

    /// The columns holding any ink within the band, merged into clusters across
    /// gaps narrower than `mergeGap`.
    private func inkClusters(
        in render: HostedRender, rows: Range<CGFloat>, columns: Range<CGFloat>, mergeGap: CGFloat
    ) -> [Range<CGFloat>] {
        let step = 1 / render.pixelScale
        var clusters: [Range<CGFloat>] = []
        for x in stride(from: columns.lowerBound, to: columns.upperBound, by: step) {
            let inked = stride(from: rows.lowerBound, to: rows.upperBound, by: step).contains {
                isInk(render.color(atX: x, y: $0))
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

    /// One modified text file on a branch with an upstream, under a complete
    /// identity — so Commit and Push is offered.
    private final class StubGit: GitServicing {
        var upstream: String? = "origin/main"
        var remotes = ["origin"]
        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] {
            [ChangedFile(path: "Sources/a.txt", status: .modified)]
        }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { "one\ntwo\n" }
        func headBlob(of path: String, root: URL) async throws -> Data? { Data("one\ntwo\n".utf8) }
        func revert(_ file: ChangedFile, root: URL) async throws {}
        func commitContext(root: URL) async throws -> CommitContext {
            CommitContext(
                isUnbornHEAD: false,
                isDetachedHEAD: false,
                currentBranch: "main",
                upstream: upstream,
                remotes: remotes,
                inProgress: nil
            )
        }
        func identity(root: URL) async throws -> CommitIdentity {
            CommitIdentity(name: "Ada", email: "ada@example.com", nameSource: .local, emailSource: .local)
        }
    }

    private final class StubFiles: FileServicing {
        func read(url: URL) throws -> String { "one\nTWO\nthree\n" }
        func write(_ text: String, to url: URL) throws {}
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? { nil }
        func isExecutableFile(at url: URL) -> Bool { false }
    }
}
#endif
