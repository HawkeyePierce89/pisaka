#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// `AppDelegate`'s quit ordering, which `swift test` cannot see because it is
/// the delegate's own wiring: the quit **asks, then flushes, then tears down**.
///
/// - a conflicted round answered `.proceed`, then the flush, then the
///   language-server teardown factory, in that order;
/// - a Cancel on the first question answers `.terminateCancel` with the
///   teardown factory never invoked and the flush never run;
/// - a flush that skips a conflict sends the quit back to the question before
///   any teardown is requested;
/// - no live server and no conflict answers `.terminateNow` after exactly one
///   flush;
/// - a conflict introduced during the teardown wait is asked about once the
///   wait is over, and a Cancel there replies `false`;
/// - every round's Local History wait is awaited, even with no server alive,
///   and a post-wait flush that skips a conflict asks again before replying.
///
/// Every collaborator is a recording closure; the deferred reply is observed
/// through `shouldTerminate(reply:)`, so the test host is never terminated, and
/// the teardown wait is staged by a rendezvous the teardown itself waits on,
/// never by a clock.
@MainActor
final class QuitOrderTests: XCTestCase {
    /// A one-shot signal the teardown closure suspends on until the test opens it.
    @MainActor
    private final class Rendezvous {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let resumed = waiters
            waiters = []
            resumed.forEach { $0.resume() }
        }
    }

    func testTheQuitAsksThenFlushesThenTearsDown() async {
        let delegate = AppDelegate()
        var events: [String] = []
        var conflicted = true
        delegate.externalChangeQuestion = {
            events.append("question")
            guard conflicted else { return .proceed(awaiting: nil) }
            conflicted = false
            return .proceed(awaiting: { events.append("history") })
        }
        delegate.flushBeforeTermination = {
            events.append("flush")
            return false
        }
        delegate.languageServerTeardown = {
            events.append("teardown requested")
            return { events.append("teardown") }
        }
        let replied = expectation(description: "the deferred reply arrived")
        var answer: Bool?
        let immediate = delegate.shouldTerminate { answer = $0; replied.fulfill() }

        XCTAssertEqual(immediate, .terminateLater)
        XCTAssertEqual(events, ["question", "flush", "teardown requested"],
                       "the first round asks and flushes before the teardown is requested")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(answer, true)
        XCTAssertEqual(events, ["question", "flush", "teardown requested", "history", "teardown", "question", "flush"])
    }

    func testACancelOnTheFirstRoundNeitherFlushesNorTearsDown() {
        let delegate = AppDelegate()
        var flushes = 0
        var teardownRequests = 0
        delegate.externalChangeQuestion = { .cancel }
        delegate.flushBeforeTermination = { flushes += 1; return false }
        delegate.languageServerTeardown = {
            teardownRequests += 1
            return {}
        }

        let immediate = delegate.shouldTerminate { _ in XCTFail("a cancelled quit is answered at once") }

        XCTAssertEqual(immediate, .terminateCancel)
        XCTAssertEqual(flushes, 0)
        XCTAssertEqual(teardownRequests, 0)
    }

    func testAFlushThatSkipsAConflictAsksAgainBeforeAnyTeardown() {
        let delegate = AppDelegate()
        var events: [String] = []
        var questions = 0
        delegate.externalChangeQuestion = {
            questions += 1
            events.append("question")
            // The second round is the one the skipped conflict sent the quit back to.
            return questions == 2 ? .cancel : .proceed(awaiting: nil)
        }
        delegate.flushBeforeTermination = {
            events.append("flush")
            return true
        }
        delegate.languageServerTeardown = {
            events.append("teardown requested")
            return {}
        }

        let immediate = delegate.shouldTerminate { _ in XCTFail("a cancelled quit is answered at once") }

        XCTAssertEqual(immediate, .terminateCancel)
        XCTAssertEqual(events, ["question", "flush", "question"])
    }

    func testNoServerAndNoConflictTerminatesNowAfterOneFlush() {
        let delegate = AppDelegate()
        var questions = 0
        var flushes = 0
        var teardownRequests = 0
        delegate.externalChangeQuestion = { questions += 1; return .proceed(awaiting: nil) }
        delegate.flushBeforeTermination = { flushes += 1; return false }
        delegate.languageServerTeardown = { teardownRequests += 1; return nil }

        let immediate = delegate.shouldTerminate { _ in XCTFail("nothing to wait for answers at once") }

        XCTAssertEqual(immediate, .terminateNow)
        XCTAssertEqual(questions, 1)
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(teardownRequests, 1)
    }

    func testEveryRoundsWaitIsAwaitedAndThePostWaitFlushAsksAgain() async {
        let delegate = AppDelegate()
        var events: [String] = []
        var questions = 0
        var flushAnswers = [true, false, true, false]
        delegate.externalChangeQuestion = {
            questions += 1
            events.append("question")
            switch questions {
            case 1: return .proceed(awaiting: { events.append("history A") })
            case 2: return .proceed(awaiting: { events.append("history B") })
            default: return .proceed(awaiting: nil)
            }
        }
        delegate.flushBeforeTermination = {
            events.append("flush")
            return flushAnswers.removeFirst()
        }
        delegate.languageServerTeardown = { nil }
        let replied = expectation(description: "the deferred reply arrived")
        var answer: Bool?
        let immediate = delegate.shouldTerminate { answer = $0; replied.fulfill() }

        XCTAssertEqual(immediate, .terminateLater, "a Local History wait alone defers the reply")
        XCTAssertEqual(events, ["question", "flush", "question", "flush"])
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(answer, true)
        XCTAssertEqual(events, [
            "question", "flush", "question", "flush",
            "history A", "history B",
            "question", "flush", "question", "flush",
        ])
    }

    func testAConflictDuringTheTeardownWaitIsAskedAndACancelRepliesFalse() async {
        let delegate = AppDelegate()
        let rendezvous = Rendezvous()
        var conflictDuringWait = false
        var teardowns = 0
        delegate.externalChangeQuestion = { conflictDuringWait ? .cancel : .proceed(awaiting: nil) }
        delegate.flushBeforeTermination = { false }
        let tearingDown = expectation(description: "the teardown is waiting")
        delegate.languageServerTeardown = {
            {
                teardowns += 1
                tearingDown.fulfill()
                await rendezvous.wait()
            }
        }
        let replied = expectation(description: "the deferred reply arrived")
        var answer: Bool?
        let immediate = delegate.shouldTerminate { answer = $0; replied.fulfill() }
        XCTAssertEqual(immediate, .terminateLater)

        await fulfillment(of: [tearingDown], timeout: 5)
        // A second ⌘Q while the teardown waits is answered by the one reply.
        XCTAssertEqual(delegate.shouldTerminate { _ in XCTFail("only the first quit replies") }, .terminateLater)
        conflictDuringWait = true
        rendezvous.open()

        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(answer, false)
        XCTAssertEqual(teardowns, 1)
    }
}
#endif
