#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The Log's refresh controls, the trailing view `LogFilterBar` measures through
/// `ViewThatFits`.
///
/// **The contract.** Loading never changes the controls' width: the spinner's
/// slot is always laid out and only faded, so the strip cannot flip between its
/// layouts while the history loads. And a faded slot draws nothing.
///
/// **How it is measured.** The controls are rendered once per state, two
/// `HostedRender`s, with no ground of their own, so the window's ground shows
/// wherever they draw nothing. The widths compared are the hosting views'
/// fitting widths. The spinner's slot is the leading `spinnerSide` points of
/// the controls, which are centred in the window; it is scanned column by
/// column against the ground read at the window's corner. The loading render
/// must find ink there — which proves the slot is where the scan looks — and
/// the idle render must find none.
@MainActor
final class LogRefreshControlsLayoutTests: XCTestCase {

    func testLoadingKeepsTheWidthAndTheIdleSlotIsBlank() throws {
        let loading = try render(isLoading: true)
        let idle = try render(isLoading: false)

        XCTAssertGreaterThan(idle.host.fittingSize.width, 0)
        XCTAssertEqual(
            loading.host.fittingSize.width, idle.host.fittingSize.width,
            "loading changed the trailing width ViewThatFits measures"
        )

        XCTAssertTrue(hasInk(inSpinnerSlotOf: loading), "the loading controls draw no spinner where the scan looks")
        XCTAssertFalse(hasInk(inSpinnerSlotOf: idle), "the idle controls draw the spinner's ink")
    }

    private func render(isLoading: Bool) throws -> HostedRender {
        let render = try HostedRender(
            size: CGSize(width: 120, height: 40),
            root: CommitLogRefreshControls(isLoading: isLoading, isEnabled: true, onRefresh: {})
                .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }

    /// Whether any pixel of the spinner's slot differs from the window's ground.
    private func hasInk(inSpinnerSlotOf render: HostedRender) -> Bool {
        guard let ground = render.color(atX: 0, y: 0) else { return false }
        let fitting = render.host.fittingSize.width
        let originX = (render.bounds.width - fitting) / 2
        let side = CGFloat(ChromeGeometry.spinnerSide)
        let step = 1 / render.pixelScale
        for x in stride(from: originX, to: originX + side, by: step) {
            let ink = render.extent(atX: x) { color in
                guard let color else { return false }
                return abs(color.redComponent - ground.redComponent) > 0.02
                    || abs(color.greenComponent - ground.greenComponent) > 0.02
                    || abs(color.blueComponent - ground.blueComponent) > 0.02
            }
            if ink != nil { return true }
        }
        return false
    }
}
#endif
