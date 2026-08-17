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
        memory.record(EditorViewport(selection: NSRange(location: 3, length: 0), topCharacterOffset: 0), for: dropped)
        memory.record(EditorViewport(selection: NSRange(location: 4, length: 0), topCharacterOffset: 0), for: kept)

        memory.forget(dropped)

        XCTAssertNil(memory.viewport(for: dropped, clampedToLength: 100))
        XCTAssertNotNil(memory.viewport(for: kept, clampedToLength: 100))
    }

    func testForgettingAnUnknownFileIsANoOp() {
        var memory = EditorViewportMemory()
        let kept = UUID()
        memory.record(EditorViewport(selection: NSRange(location: 4, length: 0), topCharacterOffset: 0), for: kept)

        memory.forget(UUID())

        XCTAssertNotNil(memory.viewport(for: kept, clampedToLength: 100))
    }

    func testPruneDropsClosedFilesAndKeepsOpenOnes() {
        var memory = EditorViewportMemory()
        let open = UUID()
        let alsoOpen = UUID()
        let closed = UUID()
        for fileID in [open, alsoOpen, closed] {
            memory.record(EditorViewport(selection: NSRange(location: 1, length: 0), topCharacterOffset: 1), for: fileID)
        }

        memory.prune(keeping: [open, alsoOpen])

        XCTAssertNotNil(memory.viewport(for: open, clampedToLength: 100))
        XCTAssertNotNil(memory.viewport(for: alsoOpen, clampedToLength: 100))
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
        XCTAssertEqual(clamped.selection, NSRange(location: 20, length: 0))
        XCTAssertEqual(clamped.topCharacterOffset, 20)
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

    func testAnchorPastTheNewEndIsClampedToTheEnd() {
        let viewport = EditorViewport(selection: NSRange(location: 0, length: 0), topCharacterOffset: 500)
        XCTAssertEqual(viewport.clamped(toLength: 20).topCharacterOffset, 20)
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

    func testMemoryClampsOnRead() {
        var memory = EditorViewportMemory()
        let fileID = UUID()
        memory.record(EditorViewport(selection: NSRange(location: 80, length: 10), topCharacterOffset: 70), for: fileID)

        XCTAssertEqual(
            memory.viewport(for: fileID, clampedToLength: 12),
            EditorViewport(selection: NSRange(location: 12, length: 0), topCharacterOffset: 12)
        )
    }
}
