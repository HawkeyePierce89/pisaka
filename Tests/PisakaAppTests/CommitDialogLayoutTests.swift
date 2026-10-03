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
@MainActor
final class CommitDialogLayoutTests: XCTestCase {

    func testTheDialogAtScaleOne() async throws {
        try await assertDialog(scale: 1)
    }

    func testTheDialogAtScaleOnePointEight() async throws {
        try await assertDialog(scale: 1.8)
    }

    private func assertDialog(scale: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        let metrics = InterfaceMetrics(scale: scale)
        let model = CommitDialogModel(gitService: StubGit(), fileService: StubFiles())
        await model.load(root: URL(fileURLWithPath: "/repo"))
        model.message = "subject"
        XCTAssertTrue(model.canCommitAndPush, "the fixture must offer Commit and Push", file: file, line: line)

        let suite = "CommitDialogLayoutTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(defaults: defaults)

        let theme = ChromeTheme(.dark)
        let panel = theme.color(.bgPanel)
        let width = metrics.scaled(1000)
        let height = metrics.scaled(640)
        let render = try HostedRender(
            size: CGSize(width: width, height: height),
            root: CommitDialogView(model: model, settings: settings)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, theme)
        )
        addTeardownBlock { @MainActor in render.window.close() }

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
            stride(from: height - step, to: height - metrics.scaled(120), by: -step).first {
                render.matches(.hairline, atX: width / 2, y: $0, ground: panel)
            },
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
        let buttons = inkClusters(
            in: render,
            rows: footerTop..<(height - step),
            columns: (width / 2)..<width,
            mergeGap: metrics.scaled(4)
        )
        XCTAssertEqual(buttons.count, 3, "the footer's right end did not draw three buttons: \(buttons)",
                       file: file, line: line)
        guard buttons.count == 3 else { return }
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
                upstream: "origin/main",
                remotes: ["origin"],
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
