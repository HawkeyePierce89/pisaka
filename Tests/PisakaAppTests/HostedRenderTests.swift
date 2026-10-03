#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// `HostedRender`'s own cost rule: sampling a rendered bitmap opens no window.
///
/// `matches` and `extent` compare a pixel against a swatch of the role, and a
/// swatch is rendered in a window of its own. Rendering one per call once let a
/// suite scanning a strip pixel by pixel open thousands of windows in two
/// minutes and take the machine's WindowServer down, so the swatch is cached
/// per `(role, ground, appearance)`. This suite samples one role thousands of
/// times, alternating its dark and light values, and asserts two things after
/// an `autoreleasepool` drain:
///
/// - the app holds no more windows than before plus two (one swatch per
///   appearance — the light key is cached like the dark one);
/// - the WindowServer spent almost no window numbers meanwhile. A closed
///   swatch window is released when the pool drains and leaves `NSApp.windows`,
///   so the count alone stays flat even while every call opens a window. The
///   window number a fresh window is given is not reused, so the distance
///   between a probe window's number before the loop and another's after it
///   bounds how many windows the loop opened. The bound is loose (other
///   processes draw numbers from the same counter) and is still two orders of
///   magnitude below what one window per sample spends.
@MainActor
final class HostedRenderTests: XCTestCase {

    func testRepeatedSamplingOpensNoFurtherWindows() throws {
        let render = try HostedRender(
            size: CGSize(width: 40, height: 20),
            root: ChromeTheme(.dark).color(.bgPanel).frame(width: 40, height: 20)
        )
        defer { render.window.close() }

        let before = Self.windowNumbers()
        let firstProbe = Self.probeWindowNumber()
        autoreleasepool {
            for sample in 0..<5_000 {
                let x = CGFloat(sample % 40)
                let y = CGFloat(sample / 40 % 20)
                _ = render.matches(.accentTint, atX: x, y: y, appearance: sample.isMultiple(of: 2) ? .dark : .light)
            }
        }
        let secondProbe = Self.probeWindowNumber()
        let after = Self.windowNumbers()

        XCTAssertLessThanOrEqual(
            after.count, before.count + 2,
            "sampling left windows behind: before \(before.sorted()), after \(after.sorted())"
        )
        XCTAssertLessThan(
            secondProbe - firstProbe, 50,
            "5000 samples spent \(secondProbe - firstProbe) window numbers — a swatch is rendered per call again"
        )
    }

    /// The numbers of the windows the app holds, after draining released ones.
    private static func windowNumbers() -> Set<Int> {
        autoreleasepool { Set(NSApp.windows.map(\.windowNumber)) }
    }

    /// The window number a fresh, immediately closed window is given now.
    private static func probeWindowNumber() -> Int {
        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            return window.windowNumber
        }
    }
}
#endif
