#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// A SwiftUI view hosted in a borderless window and rendered to a bitmap once
/// its layout has settled — the shared harness of the chrome layout suites that
/// measure what a view *draws* rather than what it reports.
///
/// **Settling is a condition, not a window.** A view whose second layout pass
/// is driven by state (a measured width fed back into a frame) lands on a later
/// run-loop turn than the first, so a fixed wait passes or fails by the
/// machine's load. `settle()` turns the run loop until every view's frame in the
/// hosted tree is unchanged across two consecutive turns, and fails loudly if
/// it never is.
///
/// Colours are compared against a swatch of the same role rendered through the
/// same pipeline, because the cached bitmap applies a colour-space conversion
/// the palette's raw values do not carry. A translucent role (the diff washes)
/// is compared on the ground it is drawn over.
@MainActor
final class HostedRender {
    let window: NSWindow
    let host: NSView
    private var rep: NSBitmapImageRep
    /// Bitmap pixels per point.
    private(set) var pixelScale: CGFloat

    var bounds: CGRect { host.bounds }
    var pixelsWide: Int { rep.pixelsWide }

    init<V: View>(size: CGSize, file: StaticString = #filePath, line: UInt = #line, root: V) throws {
        let host = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host
        Self.settle(host, file: file, line: line)
        rep = try Self.bitmap(of: host)
        pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
    }

    /// Turns the run loop until the hosted tree's frames hold still for two
    /// consecutive turns; `XCTFail` if they have not after two seconds.
    func settle(file: StaticString = #filePath, line: UInt = #line) {
        Self.settle(host, file: file, line: line)
    }

    private static func settle(_ host: NSView, file: StaticString, line: UInt) {
        let deadline = Date().addingTimeInterval(2)
        var previous: [CGRect] = []
        var stableTurns = 0
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
            let frames = frames(in: host)
            stableTurns = frames == previous ? stableTurns + 1 : 0
            if stableTurns >= 2 { return }
            previous = frames
        }
        XCTFail("the hosted layout never settled", file: file, line: line)
    }

    /// Re-renders the bitmap from the view as it is now.
    func capture() throws {
        rep = try Self.bitmap(of: host)
        pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
    }

    private static func bitmap(of host: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func color(atX x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * pixelScale), y: Int(y * pixelScale))?.usingColorSpace(.sRGB)
    }

    func color(atPixelX x: Int, y: CGFloat) -> NSColor? {
        rep.colorAt(x: x, y: Int(y * pixelScale))?.usingColorSpace(.sRGB)
    }

    /// Whether the pixel at (`x`, `y`) points is `role`'s dark value over `ground`.
    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat, ground: Color? = nil) -> Bool {
        guard let expected = Self.swatch(role, ground: ground) else { return false }
        return Self.close(color(atX: x, y: y), expected)
    }

    /// The vertical extent, in points, of the pixels in column `x` painted
    /// `role` over `ground`.
    func extent(of role: ChromeColorRole, atX x: CGFloat, ground: Color? = nil) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let expected = Self.swatch(role, ground: ground) else { return nil }
        return extent(atX: x) { Self.close($0, expected) }
    }

    /// The vertical extent, in points, of the pixels in column `x` that satisfy `test`.
    func extent(atX x: CGFloat, where test: (NSColor?) -> Bool) -> (minY: CGFloat, maxY: CGFloat)? {
        let rows = stride(from: 0, to: host.bounds.height, by: 1 / pixelScale).filter { test(color(atX: x, y: $0)) }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (first, last + 1 / pixelScale)
    }

    private static func close(_ c: NSColor?, _ expected: NSColor) -> Bool {
        guard let c else { return false }
        return abs(c.redComponent - expected.redComponent) < 0.02
            && abs(c.greenComponent - expected.greenComponent) < 0.02
            && abs(c.blueComponent - expected.blueComponent) < 0.02
    }

    private static func swatch(_ role: ChromeColorRole, ground: Color?) -> NSColor? {
        let host = NSHostingView(rootView: Rectangle().fill(ChromeTheme(.dark).color(role))
            .frame(width: 4, height: 4)
            .background(ground ?? .clear))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 4, height: 4),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
    }

    private static func frames(in view: NSView) -> [CGRect] {
        [view.frame] + view.subviews.flatMap(frames(in:))
    }
}
#endif
