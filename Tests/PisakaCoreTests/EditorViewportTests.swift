import XCTest
@testable import PisakaCore

final class EditorViewportTests: XCTestCase {

    // MARK: - The memory's record / forget / prune contract

    func testUnrecordedFileAnswersNil() {
        let memory = EditorViewportMemory()
        XCTAssertNil(memory.viewport(for: UUID(), clampedToLength: 100))
    }

    func testRecordedViewportRoundTrips() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        let viewport = EditorViewport(selection: NSRange(location: 42, length: 7), topCharacterOffset: 30)
        memory.record(viewport, for: fileID)
        XCTAssertEqual(memory.viewport(for: fileID, clampedToLength: 100), viewport)
    }

    func testRecordingTwiceKeepsTheNewerViewport() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        memory.record(EditorViewport(selection: NSRange(location: 1, length: 0), topCharacterOffset: 0), for: fileID)
        let newer = EditorViewport(selection: NSRange(location: 9, length: 2), topCharacterOffset: 5)
        memory.record(newer, for: fileID)
        XCTAssertEqual(memory.viewport(for: fileID, clampedToLength: 100), newer)
    }

    func testForgetDropsOnlyThatEntry() {
        var memory = EditorViewportMemory()
        let dropped = UUID()
        let kept = UUID()
        let keptViewport = EditorViewport(selection: NSRange(location: 4, length: 2), topCharacterOffset: 3)
        memory.record(EditorViewport(selection: NSRange(location: 30, length: 0), topCharacterOffset: 20), for: dropped)
        memory.record(keptViewport, for: kept)

        memory.forget(dropped)

        XCTAssertNil(memory.viewport(for: dropped, clampedToLength: 100))
        // Asserted by value, not by presence: a `forget` that clobbered its
        // neighbour's entry would still leave *something* under `kept`.
        XCTAssertEqual(memory.viewport(for: kept, clampedToLength: 100), keptViewport)
    }

    func testForgettingAnUnknownFileIsANoOp() {
        var memory = EditorViewportMemory()
        let kept = UUID()
        let keptViewport = EditorViewport(selection: NSRange(location: 4, length: 1), topCharacterOffset: 2)
        memory.record(keptViewport, for: kept)

        memory.forget(UUID())

        XCTAssertEqual(memory.viewport(for: kept, clampedToLength: 100), keptViewport)
    }

    func testPruneDropsClosedFilesAndKeepsOpenOnesWithTheirOwnViewports() {
        var memory = EditorViewportMemory()
        let open = UUID()
        let alsoOpen = UUID()
        let closed = UUID()
        // Deliberately distinguishable: three identical viewports would let a
        // prune that paired the surviving ids with the wrong values pass — which
        // in the editor is tab A jumping to tab B's position after a tab close.
        let openViewport = EditorViewport(selection: NSRange(location: 10, length: 3), topCharacterOffset: 8)
        let alsoOpenViewport = EditorViewport(selection: NSRange(location: 40, length: 0), topCharacterOffset: 37)
        memory.record(openViewport, for: open)
        memory.record(alsoOpenViewport, for: alsoOpen)
        memory.record(EditorViewport(selection: NSRange(location: 70, length: 5), topCharacterOffset: 65), for: closed)

        memory.prune(keeping: [open, alsoOpen])

        XCTAssertEqual(memory.viewport(for: open, clampedToLength: 100), openViewport)
        XCTAssertEqual(memory.viewport(for: alsoOpen, clampedToLength: 100), alsoOpenViewport)
        XCTAssertNil(memory.viewport(for: closed, clampedToLength: 100))
    }

    func testPruningToTheEmptySetDropsEverything() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        memory.record(EditorViewport(selection: NSRange(location: 1, length: 0), topCharacterOffset: 1), for: fileID)

        memory.prune(keeping: [])

        XCTAssertNil(memory.viewport(for: fileID, clampedToLength: 100))
    }

    // MARK: - Clamping

    func testInBoundsViewportIsUnchanged() {
        let viewport = EditorViewport(selection: NSRange(location: 10, length: 5), topCharacterOffset: 8)
        XCTAssertEqual(viewport.clamped(toLength: 100), viewport)
    }

    func testCaretPastTheNewEndLandsOnTheEnd() {
        let viewport = EditorViewport(selection: NSRange(location: 90, length: 0), topCharacterOffset: 0)
        let clamped = viewport.clamped(toLength: 20)
        XCTAssertEqual(clamped.selection, NSRange(location: 20, length: 0))
    }

    func testSelectionStraddlingTheNewEndIsTruncatedNotDropped() {
        let viewport = EditorViewport(selection: NSRange(location: 15, length: 30), topCharacterOffset: 0)
        let clamped = viewport.clamped(toLength: 20)
        XCTAssertEqual(clamped.selection, NSRange(location: 15, length: 5))
    }

    func testCaretExactlyAtTheEndStaysThereRatherThanCollapsingToZero() {
        let viewport = EditorViewport(selection: NSRange(location: 20, length: 0), topCharacterOffset: 20)
        let clamped = viewport.clamped(toLength: 20)
        // The caret may sit at `length`; the anchor may not — it has to name a
        // character the layout can be asked about, so it stops one short.
        XCTAssertEqual(clamped.selection, NSRange(location: 20, length: 0))
        XCTAssertEqual(clamped.topCharacterOffset, 19)
    }

    func testSelectionStartingExactlyAtTheEndKeepsItsLocation() {
        // The case `NSIntersectionRange` would answer `{0, 0}` for.
        let viewport = EditorViewport(selection: NSRange(location: 20, length: 4), topCharacterOffset: 0)
        let clamped = viewport.clamped(toLength: 20)
        XCTAssertEqual(clamped.selection, NSRange(location: 20, length: 0))
    }

    func testNotFoundLocationCollapsesToZero() {
        let viewport = EditorViewport(selection: NSRange(location: NSNotFound, length: 0), topCharacterOffset: 12)
        let clamped = viewport.clamped(toLength: 100)
        XCTAssertEqual(clamped.selection, NSRange(location: 0, length: 0))
        // The anchor is independent of the selection and survives.
        XCTAssertEqual(clamped.topCharacterOffset, 12)
    }

    func testNegativeLocationCollapsesToZero() {
        let viewport = EditorViewport(selection: NSRange(location: -3, length: 5), topCharacterOffset: 0)
        XCTAssertEqual(viewport.clamped(toLength: 100).selection, NSRange(location: 0, length: 0))
    }

    func testAnchorPastTheNewEndLandsOnTheLastCharacterNotPastIt() {
        let viewport = EditorViewport(selection: NSRange(location: 0, length: 0), topCharacterOffset: 500)
        XCTAssertEqual(viewport.clamped(toLength: 20).topCharacterOffset, 19)
    }

    func testNegativeAnchorIsClampedToZero() {
        let viewport = EditorViewport(selection: NSRange(location: 0, length: 0), topCharacterOffset: -7)
        XCTAssertEqual(viewport.clamped(toLength: 20).topCharacterOffset, 0)
    }

    func testEmptyBufferCollapsesEverythingToZero() {
        let viewport = EditorViewport(selection: NSRange(location: 30, length: 4), topCharacterOffset: 25)
        let clamped = viewport.clamped(toLength: 0)
        XCTAssertEqual(clamped.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(clamped.topCharacterOffset, 0)
    }

    func testSingleCharacterBufferAnchorsOnThatCharacter() {
        // `max(0, length - 1)` and `length` differ here, which is the boundary
        // between "names a character" and "names the end".
        let viewport = EditorViewport(selection: NSRange(location: 9, length: 0), topCharacterOffset: 9)
        let clamped = viewport.clamped(toLength: 1)
        XCTAssertEqual(clamped.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(clamped.topCharacterOffset, 0)
    }

    func testNegativeBufferLengthCollapsesEverythingToZero() {
        // Nothing in the app should produce a negative length, but the clamp's
        // whole job is that whatever comes out is safe to hand `setSelectedRange`.
        let viewport = EditorViewport(selection: NSRange(location: 5, length: 5), topCharacterOffset: 5)
        let clamped = viewport.clamped(toLength: -1)
        XCTAssertEqual(clamped.selection, NSRange(location: 0, length: 0))
        XCTAssertEqual(clamped.topCharacterOffset, 0)
    }

    func testNegativeSelectionLengthCollapsesToAZeroLengthCaret() {
        let viewport = EditorViewport(selection: NSRange(location: 5, length: -4), topCharacterOffset: 5)
        XCTAssertEqual(viewport.clamped(toLength: 100).selection, NSRange(location: 5, length: 0))
    }

    func testMemoryClampsOnRead() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        memory.record(EditorViewport(selection: NSRange(location: 80, length: 10), topCharacterOffset: 70), for: fileID)

        XCTAssertEqual(
            memory.viewport(for: fileID, clampedToLength: 12),
            EditorViewport(selection: NSRange(location: 12, length: 0), topCharacterOffset: 11)
        )
    }

    func testClampingOnReadLeavesTheStoredViewportIntact() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        let recorded = EditorViewport(selection: NSRange(location: 80, length: 10), topCharacterOffset: 70)
        memory.record(recorded, for: fileID)

        // A read against a momentarily short buffer (a background tab caught
        // mid-rewrite) must not overwrite the record: the next visit, against the
        // full text, has to get the position back rather than a truncated one.
        _ = memory.viewport(for: fileID, clampedToLength: 12)

        XCTAssertEqual(memory.viewport(for: fileID, clampedToLength: 100), recorded)
    }
}
