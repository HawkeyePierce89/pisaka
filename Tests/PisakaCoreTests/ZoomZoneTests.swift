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

    func testMainWindowWalkOverEditorAndTerminalPicksTheOneUnderThePointer() {
        // The walk `ZoomHitTest.candidates(under:in:depth:)` performs collects
        // *every* conforming view whose visible rect contains the point, so with
        // the bottom terminal panel open the list can legitimately hold both
        // kinds only when they overlap — which they do not, but the resolver must
        // not depend on that. Whichever is deeper is the one the pointer is
        // actually inside.
        let editor = ZoomSurfaceCandidate(kind: .code, depth: 7)
        let terminal = ZoomSurfaceCandidate(kind: .terminal, depth: 11)

        XCTAssertEqual(
            ZoomZone.resolve(pointer: .insideApp([editor, terminal]), focusedSurface: .code),
            .terminal
        )
        XCTAssertEqual(
            ZoomZone.resolve(
                pointer: .insideApp([editor, ZoomSurfaceCandidate(kind: .terminal, depth: 3)]),
                focusedSurface: .terminal
            ),
            .code
        )
    }

    func testAStatementMarkerBesideTheEditorResolvesToCodeEitherWay() {
        // The LeetCode pane sits beside the editor in the same window and is a
        // code surface too, so a gesture anywhere across the pair means the same
        // thing — the answer must not depend on which one the walk reached first
        // or how deep the pane's marker happens to sit.
        let editor = ZoomSurfaceCandidate(kind: .code, depth: 7)
        let marker = ZoomSurfaceCandidate(kind: .code, depth: 14)

        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([editor, marker]), focusedSurface: nil), .code)
        XCTAssertEqual(ZoomZone.resolve(pointer: .insideApp([marker, editor]), focusedSurface: nil), .code)
    }

    func testChromeAroundASurfaceStaysInterface() {
        // The panel's tab strip, the Find in Files toolbar and the statement
        // pane's own header are all *inside* windows that contain code and
        // terminal surfaces, and none of them declares one — so the walk returns
        // an empty list there and the gesture goes to the interface. This is the
        // case that makes "no candidates" the ordinary answer rather than an
        // error, on a window where surfaces certainly exist.
        XCTAssertEqual(
            ZoomZone.resolve(pointer: .insideApp([]), focusedSurface: .terminal),
            .interface
        )
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
