#if os(macOS) || os(iOS)
import Foundation
import Neon
import RangeState
import XCTest
@testable import Pisaka

/// A highlight request superseded by an edit re-queues **its own range carried
/// through the edits since**, never the whole document: invalidating `.all`
/// drops the validator's whole valid set, so every keystroke landing during a
/// request would re-query the full file. Only edits already gone from the log
/// fall back to `.all`. The reasoning is in `app-editor-overlays.md`.
@MainActor
final class StyleGenerationRequeueTests: XCTestCase {
    private func range(_ target: RangeTarget, file: StaticString = #filePath, line: UInt = #line) -> NSRange? {
        guard case let .range(range) = target else {
            XCTFail("expected a bounded range, got \(target)", file: file, line: line)
            return nil
        }
        return range
    }

    func testNoEditSinceKeepsTheRange() {
        let generation = StyleGeneration()
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 100)
        XCTAssertEqual(range(target), NSRange(location: 10, length: 5))
    }

    func testAnEditAfterTheRangeLeavesItAlone() {
        let generation = StyleGeneration()
        generation.recordEdit(in: NSRange(location: 50, length: 0), delta: 3)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 103)
        XCTAssertEqual(range(target), NSRange(location: 10, length: 5))
    }

    func testAnEditBeforeTheRangeShiftsIt() {
        let generation = StyleGeneration()
        generation.recordEdit(in: NSRange(location: 2, length: 0), delta: 4)
        generation.recordEdit(in: NSRange(location: 0, length: 3), delta: -3)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 101)
        XCTAssertEqual(range(target), NSRange(location: 11, length: 5))
    }

    func testAnOverlappingEditWidensTheRangeOverTheReplacement() {
        let generation = StyleGeneration()
        // Replace [12, 20) with 2 characters: the range [10, 15) reaches into
        // the replacement, so it now covers [10, 14) — through its end.
        generation.recordEdit(in: NSRange(location: 12, length: 8), delta: -6)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 94)
        XCTAssertEqual(range(target), NSRange(location: 10, length: 4))
    }

    func testASameLengthOvertypeInsideTheRangeKeepsIt() {
        let generation = StyleGeneration()
        generation.recordEdit(in: NSRange(location: 12, length: 1), delta: 0)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 100)
        XCTAssertEqual(range(target), NSRange(location: 10, length: 5))
    }

    func testOnlyEditsSinceTheRequestAreApplied() {
        let generation = StyleGeneration()
        generation.recordEdit(in: NSRange(location: 0, length: 0), delta: 100)
        generation.recordEdit(in: NSRange(location: 0, length: 0), delta: 1)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 1, length: 200)
        XCTAssertEqual(range(target), NSRange(location: 11, length: 5))
    }

    func testTheRangeIsClampedToTheCurrentLength() {
        let generation = StyleGeneration()
        generation.recordEdit(in: NSRange(location: 8, length: 92), delta: -92)
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 50), since: 0, length: 8)
        XCTAssertEqual(range(target), NSRange(location: 8, length: 0))
    }

    func testEditsGoneFromTheLogFallBackToTheWholeDocument() {
        let generation = StyleGeneration()
        for _ in 0..<300 {
            generation.recordEdit(in: NSRange(location: 0, length: 0), delta: 1)
        }
        let target = generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 0, length: 300)
        guard case .all = target else { return XCTFail("expected .all, got \(target)") }
        // An edit still in the log is carried, not escalated.
        XCTAssertEqual(range(generation.requeueTarget(for: NSRange(location: 10, length: 5), since: 299, length: 300)),
                       NSRange(location: 11, length: 5))
    }
}
#endif
