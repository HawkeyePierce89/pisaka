import XCTest
@testable import PisakaCore

/// D39's rule as arithmetic: a backlog is what crosses the ceiling, never one
/// message on its own, and what the write queue drains is what the pipe took.
///
/// The two tests that matter are a pair: the *same total volume* of bytes
/// crosses the ceiling when nothing drains, and never crosses when each admit is
/// followed by its drain. A budget that counted bytes ever written rather than
/// bytes still pending would pass the first and fail the second, which is the
/// whole distinction between "this server is slow" and "this server is dead".
final class LSPWriteBudgetTests: XCTestCase {
    /// The number is pinned because it is documented in two places (D39 and the
    /// transport's own doc comment) and read by a third (the applier); a silent
    /// change to any of them should land here.
    func testTheDefaultCeilingIs32MiB() {
        XCTAssertEqual(LSPWriteBudget.defaultCeiling, 33_554_432)
        XCTAssertEqual(LSPWriteBudget().ceiling, LSPWriteBudget.defaultCeiling)
        XCTAssertEqual(LSPWriteBudget().pendingByteCount, 0)
    }

    func testABacklogThatNeverDrainsCrossesTheCeiling() {
        var budget = LSPWriteBudget(ceiling: 1_000)
        for _ in 0..<10 {
            XCTAssertEqual(budget.admit(100), .queued)
        }
        XCTAssertEqual(budget.pendingByteCount, 1_000)
        XCTAssertEqual(budget.admit(1), .overCeiling)
    }

    /// The same 1 001 bytes as above, admitted one message at a time with the
    /// pipe keeping up. Nothing crosses, because nothing is ever pending.
    func testTheSameVolumeWithADrainAfterEachAdmitNeverCrosses() {
        var budget = LSPWriteBudget(ceiling: 1_000)
        for _ in 0..<10 {
            XCTAssertEqual(budget.admit(100), .queued)
            budget.drain(100)
        }
        XCTAssertEqual(budget.admit(1), .queued)
        XCTAssertEqual(budget.pendingByteCount, 1)
    }

    /// One `didOpen` carrying a file larger than the ceiling is a big write, not
    /// a dead server: with nothing pending the answer is always `.queued`.
    func testTheFirstAdmitIsAcceptedAtAnySize() {
        var budget = LSPWriteBudget(ceiling: 1_000)
        XCTAssertEqual(budget.admit(50_000), .queued)
        XCTAssertEqual(budget.pendingByteCount, 50_000)

        // And it stays over the line until it drains: the next message, however
        // small, is refused rather than added to a backlog already past it.
        XCTAssertEqual(budget.admit(1), .overCeiling)
        budget.drain(50_000)
        XCTAssertEqual(budget.admit(1), .queued)
    }

    func testACrossingMessageIsNotCountedAsPending() {
        var budget = LSPWriteBudget(ceiling: 1_000)
        XCTAssertEqual(budget.admit(900), .queued)
        XCTAssertEqual(budget.admit(200), .overCeiling)
        XCTAssertEqual(budget.pendingByteCount, 900, "a refused message was never queued")

        // The boundary itself is not a crossing: exactly at the ceiling is fine.
        XCTAssertEqual(budget.admit(100), .queued)
        XCTAssertEqual(budget.pendingByteCount, 1_000)
    }

    func testDrainingPastZeroClamps() {
        var budget = LSPWriteBudget(ceiling: 1_000)
        XCTAssertEqual(budget.admit(100), .queued)
        budget.drain(400)
        XCTAssertEqual(budget.pendingByteCount, 0)
        budget.drain(400)
        XCTAssertEqual(budget.pendingByteCount, 0)
        XCTAssertEqual(budget.admit(1_000), .queued, "a clamped budget is an empty one")
    }
}
