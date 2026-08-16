import XCTest
@testable import PisakaCore

/// The pointer rule: which zone a gesture targets, given what is under the
/// pointer and what is focused.
final class ZoomZoneTests: XCTestCase {
    // MARK: - Inside the app

    func testNoCandidatesResolveToInterface() {
        // Over the project tree, a toolbar, the tab strip: nothing declares a
        // surface, and that *is* the interface answer rather than a failure.
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([]), focusedSurface: nil), .interface)
        // A focused surface must not leak in while the pointer is over chrome —
        // that is the whole point of pointer targeting.
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([]), focusedSurface: .code), .interface)
        XCTAssertEqual(
            ZoomZone.resolve(pointer: .insideApp([]), focusedSurface: .terminal),
            .interface
        )
    }

    func testSingleCandidateResolvesToItsZone() {
        XCTAssertEqual(
            ZoomZone.resolve(
                pointer: .insideApp([ZoomSurfaceCandidate(kind: .code, depth: 4)]),
                focusedSurface: nil
            ),
            .code
        )
        XCTAssertEqual(
            ZoomZone.resolve(
                pointer: .insideApp([ZoomSurfaceCandidate(kind: .terminal, depth: 4)]),
                focusedSurface: .code
            ),
            .terminal
        )
    }

    func testDeepestCandidateWinsRegardlessOfOrder() {
        let shallow = ZoomSurfaceCandidate(kind: .code, depth: 2)
        let deep = ZoomSurfaceCandidate(kind: .terminal, depth: 7)

        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([shallow, deep]), focusedSurface: nil), .terminal)
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([deep, shallow]), focusedSurface: nil), .terminal)
    }

    func testTiesResolveToTheFirstCandidateInScanOrder() {
        // Not a layout this app produces, but the answer must be stable rather
        // than undefined: scan order decides.
        let code = ZoomSurfaceCandidate(kind: .code, depth: 5)
        let terminal = ZoomSurfaceCandidate(kind: .terminal, depth: 5)

        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([code, terminal]), focusedSurface: nil), .code)
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([terminal, code]), focusedSurface: nil), .terminal)
    }

    // MARK: - The shapes the hit-test walker actually produces

    func testEditorNestedInScrollViewInsideSplitViewResolvesToCode() {
        // The main window: the editor's text view is the deepest thing under the
        // pointer, and nothing shallower may outvote it.
        let candidates = [ZoomSurfaceCandidate(kind: .code, depth: 6)]
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp(candidates), focusedSurface: .terminal), .code)
    }

    func testTerminalUnderTheBottomPanelChromeResolvesToTerminal() {
        // The panel's own chrome declares no surface, so the only candidate is
        // SwiftTerm's view; the tab strip above it stays interface because the
        // pointer there produces no candidate at all (covered above).
        let candidates = [ZoomSurfaceCandidate(kind: .terminal, depth: 9)]
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp(candidates), focusedSurface: .code), .terminal)
    }

    func testAMarkerInsideAListRowResolvesToCode() {
        // Find-in-Files rows and the statement body are SwiftUI-drawn code
        // surfaces marked by a zero-cost representable, nested deep inside the
        // list's own view tree; the marker is what makes them targetable.
        let candidates = [ZoomSurfaceCandidate(kind: .code, depth: 12)]
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp(candidates), focusedSurface: nil), .code)
    }

    // MARK: - Outside every app window

    func testOutsideAppFallsBackToTheFocusedSurface() {
        XCTAssertEqual(ZoomZone.resolve(pointer: .outsideApp, focusedSurface: .code), .code)
        XCTAssertEqual(ZoomZone.resolve(pointer: .outsideApp, focusedSurface: .terminal), .terminal)
    }

    func testOutsideAppWithoutAFocusedSurfaceResolvesToInterface() {
        XCTAssertEqual(ZoomZone.resolve(pointer: .outsideApp, focusedSurface: nil), .interface)
    }

    // MARK: - The vocabulary

    func testSurfaceKindWidensToItsZone() {
        XCTAssertEqual(ZoomSurfaceKind.code.zone, .code)
        XCTAssertEqual(ZoomSurfaceKind.terminal.zone, .terminal)
        // `.interface` is never a surface — the two-case enum is what makes that
        // state unrepresentable, so assert the case list itself.
        XCTAssertEqual(ZoomSurfaceKind.allCases, [.code, .terminal])
        XCTAssertEqual(ZoomZone.allCases, [.code, .terminal, .interface])
    }
}
