#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// Scrolling the project tree lists nothing.
///
/// **The property.** The pinned stack measures expanded folders through
/// preferences in the content's coordinate space, which a scroll never moves,
/// and reads the scroll offset into an object only the stack observes. So a
/// scroll changes one offset value and causes no directory read and no link
/// query: nothing in a scroll frame reaches the file system.
///
/// **How it is measured.** The tree's listing memo exposes no count, so the
/// count is taken at the file-service seam instead, which is strictly
/// stronger — it also catches link queries. A counting `FileServicing` wrapper
/// of the real `FileService` is injected through `WorkspaceModel(fileService:)`
/// and counts every protocol call. One window: a temporary project `p` with
/// `a/` holding sixty files and `b/` five, a reveal of `a/f00` to expand `a`
/// without scrolling — the centre anchor clamps to the top, so nothing pins
/// and no animated scroll is left to race the ones below. After it settles the
/// count is recorded and one capture finds **no** stack: no hairline down a
/// column right of every (short) name. The hosting `NSScrollView`'s clip view
/// is then scrolled to four offsets — the way a wheel scroll arrives, through
/// AppKit — settling after each, and the count must never have moved while the
/// clip view's origin did. One capture at the final offset then finds the
/// stack's hairline at the first slot's bottom edge and `a`'s pinned chevron in
/// that slot. Only the AppKit scrolls can have put them there, which proves
/// SwiftUI observed them.
@MainActor
final class TreeStickyScrollListingTests: XCTestCase {

    func testScrollingTheTreeListsNothing() throws {
        let root = try makeProject()
        let files = CountingFileService()
        let model = WorkspaceModel(fileService: files)
        model.openFolder(url: root)
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("a/f00"), root: root)
        )

        let render = try HostedRender(
            size: CGSize(width: 240, height: 300),
            root: ProjectTreeView(model: model, reveal: reveal)
                .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let scrollView = try XCTUnwrap(Self.scrollView(in: render.host), "the tree hosts no NSScrollView")
        let clip = scrollView.contentView
        XCTAssertGreaterThan(files.calls, 0, "the tree listed nothing — the seam is not the one the tree reads")
        let settled = files.calls

        // The landing: unscrolled, so no stack and no stack hairline.
        let metrics = InterfaceMetrics(scale: 1)
        let header = metrics.scaled(ChromeGeometry.sidebarHeaderHeight)
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 1, "the reveal of a/f00 scrolled the tree")
        try render.capture()
        XCTAssertNil(hairline(in: render, below: header, rowHeight: rowHeight),
                     "a stack hairline is drawn before any scroll — the final capture would prove nothing")

        for offset in [100.0, 400.0, 700.0, 1_000.0] {
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(clip)
            render.settle()
            XCTAssertEqual(clip.bounds.origin.y, offset, accuracy: 1,
                           "the clip view did not scroll to \(offset)")
            XCTAssertEqual(files.calls, settled,
                           "scrolling to \(offset) reached the file service \(files.calls - settled) time(s)")
        }

        // SwiftUI observed the AppKit-driven scroll — the way a wheel scroll
        // arrives: the stack's hairline now runs at the first slot's bottom
        // edge, and `a`'s pinned copy draws its chevron in that slot, at the
        // depth-1 chevron slot. A chevron, not `a`'s own one-point guide,
        // which runs through that column in the rows the copy covers.
        try render.capture()
        let rule = try XCTUnwrap(hairline(in: render, below: header, rowHeight: rowHeight),
                                 "no stack hairline after the AppKit scroll")
        XCTAssertEqual(rule, header + rowHeight, accuracy: 2 / render.pixelScale,
                       "the stack's hairline does not run at the first slot's bottom edge")
        let slotX = metrics.scaled(ChromeGeometry.treeIndentStep) + metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = try XCTUnwrap(
            ink(in: render, x: slotX..<(slotX + metrics.scaled(TreeRowLayout.chevronWidth)),
                rows: header..<(header + rowHeight)),
            "no pinned chevron in the first row slot after the AppKit scroll"
        )
        XCTAssertGreaterThan(chevron.width, metrics.scaled(TreeRowLayout.chevronWidth) / 3,
                             "the first slot's depth-1 chevron column holds a rule, not a pinned chevron")
    }

    // MARK: - Helpers

    /// A real temporary project `p` — a short name, so no name reaches the
    /// hairline's column: `a/` holding sixty files, `b/` five.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("tree-sticky-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p")
        for (folder, count) in [("a", 60), ("b", 5)] {
            let dir = root.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0..<count {
                try Data().write(to: dir.appendingPathComponent(String(format: "f%02d", index)))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }

    /// The bottom edge of the `hairline` run down a column right of every name
    /// and left of the scroller, within two rows under `header`, or `nil` when
    /// that column holds none. Reads the one bitmap.
    private func hairline(in render: HostedRender, below header: CGFloat, rowHeight: CGFloat) -> CGFloat? {
        let step = 1 / render.pixelScale
        let edge = render.bounds.width * 0.6
        let rule = stride(from: header + step, to: header + 2 * rowHeight, by: step).filter {
            render.matches(.hairline, atX: edge, y: $0)
        }
        return rule.last.map { $0 + step }
    }

    /// The bounding box of every pixel in `x` × `rows` that differs from the
    /// row's ground — sampled at the row's leading edge — or `nil` when the
    /// region is clean. Reads the one bitmap.
    private func ink(in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>) -> CGRect? {
        let step = 1 / render.pixelScale
        guard let ground = render.color(atX: step, y: (rows.lowerBound + rows.upperBound) / 2) else { return nil }
        var box: CGRect?
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step) {
                guard let color = render.color(atX: px, y: py),
                      abs(color.redComponent - ground.redComponent) > 0.08
                        || abs(color.greenComponent - ground.greenComponent) > 0.08
                        || abs(color.blueComponent - ground.blueComponent) > 0.08 else { continue }
                let pixel = CGRect(x: px, y: py, width: step, height: step)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}

/// The real `FileService`, counting every protocol call — the defaulted ones
/// too, which is why each is implemented here rather than inherited.
private final class CountingFileService: FileServicing {
    private let base = FileService()
    private(set) var calls = 0

    func read(url: URL) throws -> String {
        calls += 1
        return try base.read(url: url)
    }

    func write(_ text: String, to url: URL) throws {
        calls += 1
        try base.write(text, to: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
        calls += 1
        return try base.contentsOfDirectory(at: url)
    }

    func createFile(at url: URL) throws {
        calls += 1
        try base.createFile(at: url)
    }

    func createDirectory(at url: URL) throws {
        calls += 1
        try base.createDirectory(at: url)
    }

    func ensureDirectory(at url: URL) throws {
        calls += 1
        try base.ensureDirectory(at: url)
    }

    func move(from source: URL, to destination: URL) throws {
        calls += 1
        try base.move(from: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        calls += 1
        try base.removeItem(at: url)
    }

    func symbolicLinkDestination(at url: URL) -> String? {
        calls += 1
        return base.symbolicLinkDestination(at: url)
    }

    func fileByteCount(at url: URL) -> Int? {
        calls += 1
        return base.fileByteCount(at: url)
    }

    func fileStamp(at url: URL) -> FileStamp? {
        calls += 1
        return base.fileStamp(at: url)
    }

    func isExecutableFile(at url: URL) -> Bool {
        calls += 1
        return base.isExecutableFile(at: url)
    }

    func readTextIfNotBinary(url: URL, maxBytes: Int) throws -> String? {
        calls += 1
        return try base.readTextIfNotBinary(url: url, maxBytes: maxBytes)
    }
}
#endif
