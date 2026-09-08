#if os(macOS)
import Foundation
import XCTest
@testable import Pisaka

/// The download collector's ceiling rule, driven headlessly.
///
/// D14 says the delegate measures each arriving chunk against the room still
/// allowed *before* it appends anything, cancels the task itself when a chunk
/// does not fit, and records its own reason first so a self-caused cancellation
/// surfaces as the size failure rather than as "cancelled". `ScriptedDownloader`
/// runs no URLSession and so can see none of that; this suite calls the
/// `URLSessionDataDelegate` methods directly instead — no server, no socket, no
/// network of any kind.
///
/// **The data task is never resumed**, and it is created from a session the
/// collector is *not* the delegate of: were it the delegate, `cancel()` would
/// deliver a real `didCompleteWithError` that could race the completion the test
/// feeds and resume the same continuation twice. It is otherwise inert — the one
/// case that reads it, `testTheRefusingChunkCancelsTheTask`, is asking whether
/// the delegate cancelled it, which is the only thing a never-resumed task's
/// state can be evidence of.
final class BoundedBodyCollectorTests: XCTestCase {
    private let url = URL(string: "http://127.0.0.1:1/never-resumed")!

    // MARK: - Helpers

    /// A collector, plus the session and never-resumed task its callbacks take.
    private func makeCollector(maximumByteCount: Int) -> (BoundedBodyCollector, URLSession, URLSessionDataTask) {
        let collector = BoundedBodyCollector(maximumByteCount: maximumByteCount)
        let session = URLSession(configuration: .ephemeral)
        return (collector, session, session.dataTask(with: URLRequest(url: url)))
    }

    private func httpResponse(statusCode: Int) -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil) else {
            fatalError("HTTPURLResponse(url:statusCode:httpVersion:headerFields:) returned nil")
        }
        return response
    }

    /// Feeds the response callback the way URLSession would, and answers the
    /// disposition the collector chose.
    @discardableResult
    private func feedResponse(
        _ response: URLResponse,
        to collector: BoundedBodyCollector,
        session: URLSession,
        task: URLSessionDataTask
    ) -> URLSession.ResponseDisposition? {
        var disposition: URLSession.ResponseDisposition?
        collector.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
        return disposition
    }

    /// The 200 every body case opens with. Asserts the disposition at the
    /// caller's line, so a refusal here is not reported inside this helper.
    private func feedOKResponse(
        to collector: BoundedBodyCollector,
        session: URLSession,
        task: URLSessionDataTask,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let disposition = feedResponse(httpResponse(statusCode: 200), to: collector, session: session, task: task)
        XCTAssertEqual(disposition, .allow, file: file, line: line)
    }

    private func assertIsTooLarge(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let failure = error as? LSPDownloadService.Failure else {
            XCTFail("expected LSPDownloadService.Failure, got \(error)", file: file, line: line)
            return
        }
        guard case .tooLarge = failure else {
            XCTFail("expected .tooLarge, got \(failure)", file: file, line: line)
            return
        }
    }

    /// Whatever the collector resolved the continuation with, under a bound.
    ///
    /// Every case here stages its whole scenario *synchronously* — `attach`, the
    /// delegate callbacks, then the completion — inside the continuation closure,
    /// on one thread, with no URLSession running: nothing there races anything,
    /// and the continuation is resumed before `stage` returns. What remains
    /// asynchronous is only the handoff from the staging `Task` to this one, and
    /// that is exactly what the expectation is: the wait may be entered before the
    /// task has run at all, so it is a wait on a signal that must arrive rather
    /// than on a window that may already have closed. Nothing about the staged
    /// scenario is being raced or interleaved, which is why the bound may be a
    /// blunt one: it covers the single regression the staging itself cannot
    /// survive, a completion path that stops resuming at all. Unbounded that is a
    /// bundle hung to the job's timeout with nothing naming the case responsible;
    /// bounded, the case fails in seconds, says so, and every other case in the
    /// bundle still runs.
    ///
    /// The expectation is what reports that hang; `NeverResumed` is only the
    /// fallback that lets this hand back a `Result` rather than an optional, so
    /// no case has to unwrap one. It is not a second, independent report of the
    /// timeout: a staging task that resumes just past the bound still writes its
    /// real outcome before the read below, and such a case would pass its own
    /// assertion and fail on the wait alone.
    private func resolve(
        _ stage: @escaping (CheckedContinuation<Data, Error>) -> Void
    ) async -> Result<Data, Error> {
        let resumed = XCTestExpectation(description: "the collector resumed the continuation")
        let outcome = ResolutionBox()
        Task {
            do {
                outcome.value = .success(try await withCheckedThrowingContinuation(stage))
            } catch {
                outcome.value = .failure(error)
            }
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: Self.resolutionTimeout)
        return outcome.value ?? .failure(NeverResumed())
    }

    /// Generous by design: the staged work is a handful of synchronous calls on
    /// no network at all, so anything approaching this is the hang and not a
    /// loaded machine.
    private static let resolutionTimeout: TimeInterval = 10

    /// The fallback for a bound that expired with nothing written.
    private struct NeverResumed: Error {}

    /// The staged run's answer, handed back across the task boundary under a
    /// lock: on the bound's timeout path that run is still out there and may yet
    /// write, so the read is not merely ordered by the expectation.
    private final class ResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Data, Error>?

        var value: Result<Data, Error>? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    // MARK: - The inclusive ceiling

    func testChunkExactlyFillingTheMaximumIsKeptAndReturnedWhole() async throws {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }
        let payload = Data(repeating: 0x41, count: 8)

        let outcome = await resolve { continuation in
            collector.attach(continuation)
            self.feedOKResponse(to: collector, session: session, task: task)
            collector.urlSession(session, dataTask: task, didReceive: payload)
            collector.urlSession(session, task: task, didCompleteWithError: nil)
        }

        let body = try outcome.get()
        XCTAssertEqual(body, payload)
    }

    /// The body is *accumulated*, and the ceiling is measured against what is
    /// already in it rather than against the chunk alone: five bytes then three,
    /// under a maximum of eight, is a full body and not two refusals. Replacing
    /// the append with an assignment, or resetting `roomLeft` per chunk, fails
    /// here — which no single-chunk case can see.
    func testFittingChunksAccumulateInOrderUpToTheInclusiveCeiling() async throws {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }
        let first = Data(repeating: 0x41, count: 5)
        let second = Data(repeating: 0x42, count: 3)

        let outcome = await resolve { continuation in
            collector.attach(continuation)
            self.feedOKResponse(to: collector, session: session, task: task)
            collector.urlSession(session, dataTask: task, didReceive: first)
            collector.urlSession(session, dataTask: task, didReceive: second)
            XCTAssertEqual(collector.heldByteCount, 8)
            XCTAssertEqual(collector.peakHeldByteCount, 8)
            XCTAssertNil(collector.recordedRefusal)
            collector.urlSession(session, task: task, didCompleteWithError: nil)
        }

        let body = try outcome.get()
        XCTAssertEqual(body, first + second)
    }

    // MARK: - The order

    func testChunkPastTheMaximumIsRefusedWithoutBeingAppended() {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }
        feedOKResponse(to: collector, session: session, task: task)

        // A chunk that fits, so the refusal below has something to be measured
        // against rather than starting from an empty body.
        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x41, count: 5))
        XCTAssertEqual(collector.heldByteCount, 5)
        XCTAssertNil(collector.recordedRefusal)

        // Six more would make eleven. Read synchronously, immediately after the
        // callback and before any completion.
        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x42, count: 6))
        XCTAssertEqual(collector.heldByteCount, 0)
        guard case .some(.tooLarge) = collector.recordedRefusal else {
            XCTFail("expected a recorded .tooLarge, got \(String(describing: collector.recordedRefusal))")
            return
        }
        // The assertion that is about the *order* and not merely the outcome:
        // the refused chunk was never resident, so nothing ever outgrew the
        // capacity reserved for the pin. A collector that appended first and
        // measured afterwards reaches eleven here before dropping the body,
        // and the two are indistinguishable by any other reading.
        XCTAssertEqual(collector.peakHeldByteCount, 5)
    }

    /// The refusal ends the transfer. `cancel()` is asynchronous, so URLSession
    /// keeps delivering what is already in flight; the collector must not start
    /// a second body out of it — an empty one, whose reserved capacity went with
    /// the refused body, regrown by doubling. Without the latch the three-byte
    /// chunk below fits the freshly emptied buffer and is appended.
    func testChunksArrivingAfterARefusalAreNotAccumulated() {
        let (collector, session, task) = makeCollector(maximumByteCount: 4)
        defer { session.invalidateAndCancel() }
        feedOKResponse(to: collector, session: session, task: task)

        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x41, count: 5))
        XCTAssertEqual(collector.heldByteCount, 0)

        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x42, count: 3))
        XCTAssertEqual(collector.heldByteCount, 0)
        XCTAssertEqual(collector.peakHeldByteCount, 0)
        guard case .some(.tooLarge) = collector.recordedRefusal else {
            XCTFail("expected the recorded .tooLarge to survive, got \(String(describing: collector.recordedRefusal))")
            return
        }
    }

    /// The delegate stops the transfer itself rather than leaving it to the
    /// twenty-minute resource timeout. The task is created suspended and never
    /// resumed, so anything other than `.suspended` afterwards is the collector's
    /// `cancel()` — deleting that call leaves it suspended and fails here.
    func testTheRefusingChunkCancelsTheTask() {
        let (collector, session, task) = makeCollector(maximumByteCount: 4)
        defer { session.invalidateAndCancel() }
        feedOKResponse(to: collector, session: session, task: task)
        XCTAssertEqual(task.state, .suspended)

        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x41, count: 5))

        XCTAssertNotEqual(task.state, .suspended)
    }

    // MARK: - The response's own refusals

    func testNonSuccessStatusIsRefusedAsUnexpectedStatus() {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }

        let disposition = feedResponse(httpResponse(statusCode: 404), to: collector, session: session, task: task)

        XCTAssertEqual(disposition, .cancel)
        guard case .some(.unexpectedStatus(404)) = collector.recordedRefusal else {
            XCTFail("expected .unexpectedStatus(404), got \(String(describing: collector.recordedRefusal))")
            return
        }
    }

    func testNonHTTPResponseIsRefusedAsNotHTTP() {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)

        let disposition = feedResponse(response, to: collector, session: session, task: task)

        XCTAssertEqual(disposition, .cancel)
        guard case .some(.notHTTP) = collector.recordedRefusal else {
            XCTFail("expected .notHTTP, got \(String(describing: collector.recordedRefusal))")
            return
        }
    }

    /// The first reason recorded is the one thrown. A 404 whose error page then
    /// runs past the ceiling must still say "the server responded 404" — the
    /// sentence someone debugging an unpublished tarball needs — rather than
    /// blaming the size of the page that explained it.
    func testTheFirstRecordedReasonIsTheOneThrown() async {
        let (collector, session, task) = makeCollector(maximumByteCount: 4)
        defer { session.invalidateAndCancel() }

        let outcome = await resolve { continuation in
            collector.attach(continuation)
            self.feedResponse(self.httpResponse(statusCode: 404), to: collector, session: session, task: task)
            collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x41, count: 64))
            collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        }

        switch outcome {
        case .success:
            XCTFail("expected the call to throw")
        case .failure(let error):
            guard let failure = error as? LSPDownloadService.Failure else {
                XCTFail("expected LSPDownloadService.Failure, got \(error)")
                return
            }
            guard case .unexpectedStatus(404) = failure else {
                XCTFail("expected .unexpectedStatus(404), got \(failure)")
                return
            }
        }
    }

    func testFirstChunkPastTheMaximumIsNeverResident() {
        let (collector, session, task) = makeCollector(maximumByteCount: 4)
        defer { session.invalidateAndCancel() }
        feedOKResponse(to: collector, session: session, task: task)

        collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x43, count: 4096))

        XCTAssertEqual(collector.heldByteCount, 0)
        XCTAssertEqual(collector.peakHeldByteCount, 0)
    }

    // MARK: - The cancellation mapping

    func testSelfCausedCancellationResolvesAsTooLargeAndNotAsCancelled() async {
        let (collector, session, task) = makeCollector(maximumByteCount: 4)
        defer { session.invalidateAndCancel() }

        let outcome = await resolve { continuation in
            collector.attach(continuation)
            self.feedOKResponse(to: collector, session: session, task: task)
            collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x44, count: 5))
            // What URLSession answers a cancelled task with, whoever cancelled it.
            collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        }

        switch outcome {
        case .success:
            XCTFail("expected the call to throw")
        case .failure(let error):
            assertIsTooLarge(error)
        }
    }

    func testForeignErrorWithNothingRecordedResolvesAsThatError() async {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }

        let outcome = await resolve { continuation in
            collector.attach(continuation)
            self.feedOKResponse(to: collector, session: session, task: task)
            collector.urlSession(session, task: task, didCompleteWithError: URLError(.notConnectedToInternet))
        }

        switch outcome {
        case .success:
            XCTFail("expected the call to throw")
        case .failure(let error):
            XCTAssertNil(error as? LSPDownloadService.Failure)
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}

#endif
