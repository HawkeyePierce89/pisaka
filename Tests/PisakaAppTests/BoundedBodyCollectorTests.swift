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
/// **The data task is a prop.** It exists only because the delegate cancels one,
/// it is never resumed, and it is created from a session the collector is *not*
/// the delegate of: were it the delegate, `cancel()` would deliver a real
/// `didCompleteWithError` that could race the completion the test feeds and
/// resume the same continuation twice.
final class BoundedBodyCollectorTests: XCTestCase {
    private let url = URL(string: "http://127.0.0.1:1/never-resumed")!

    // MARK: - Helpers

    /// A collector, plus the session and never-resumed task its callbacks take.
    private func makeCollector(maximumByteCount: Int) -> (BoundedBodyCollector, URLSession, URLSessionDataTask) {
        let collector = BoundedBodyCollector(maximumByteCount: maximumByteCount)
        let session = URLSession(configuration: .ephemeral)
        return (collector, session, session.dataTask(with: URLRequest(url: url)))
    }

    private func okResponse() -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            fatalError("HTTPURLResponse(url:statusCode:httpVersion:headerFields:) returned nil")
        }
        return response
    }

    /// Feeds the response callback the way URLSession would, and asserts the
    /// disposition the collector answers with.
    private func feedOKResponse(
        to collector: BoundedBodyCollector,
        session: URLSession,
        task: URLSessionDataTask
    ) {
        var disposition: URLSession.ResponseDisposition?
        collector.urlSession(session, dataTask: task, didReceive: okResponse()) { disposition = $0 }
        XCTAssertEqual(disposition, .allow)
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

    // MARK: - The inclusive ceiling

    func testChunkExactlyFillingTheMaximumIsKeptAndReturnedWhole() async throws {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }
        let payload = Data(repeating: 0x41, count: 8)

        let body: Data = try await withCheckedThrowingContinuation { continuation in
            collector.attach(continuation)
            feedOKResponse(to: collector, session: session, task: task)
            collector.urlSession(session, dataTask: task, didReceive: payload)
            collector.urlSession(session, task: task, didCompleteWithError: nil)
        }

        XCTAssertEqual(body, payload)
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
        XCTAssertLessThanOrEqual(collector.peakHeldByteCount, 8)
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

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                collector.attach(continuation)
                feedOKResponse(to: collector, session: session, task: task)
                collector.urlSession(session, dataTask: task, didReceive: Data(repeating: 0x44, count: 5))
                // What URLSession answers a cancelled task with, whoever cancelled it.
                collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
            }
            XCTFail("expected the call to throw")
        } catch {
            assertIsTooLarge(error)
        }
    }

    func testForeignErrorWithNothingRecordedResolvesAsThatError() async {
        let (collector, session, task) = makeCollector(maximumByteCount: 8)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                collector.attach(continuation)
                feedOKResponse(to: collector, session: session, task: task)
                collector.urlSession(session, task: task, didCompleteWithError: URLError(.notConnectedToInternet))
            }
            XCTFail("expected the call to throw")
        } catch {
            XCTAssertNil(error as? LSPDownloadService.Failure)
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}

#endif
