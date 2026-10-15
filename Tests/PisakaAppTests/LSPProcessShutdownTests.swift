#if os(macOS)
import Foundation
import XCTest
import PisakaCore
@testable import Pisaka

/// D43 against a real process: the polite shutdown gives a server its exit
/// grace before any signal, and the transport's own grace before the kill.
///
/// `swift test` sees the ordering only on `ScriptedLSPTransport`, which has no
/// process to signal; whether `closeInput()` really leaves the server running,
/// whether `terminate()` really sends `SIGTERM` first and whether the escalation
/// really ends a server that survives it are facts about `Process` and pipes,
/// and this bundle is the only place they execute.
///
/// The fixture (`Fixtures/lsp-ignores-exit.sh`, read through `#filePath` and run
/// by `/bin/sh`, so it needs no executable bit) answers `initialize`, ignores
/// `exit` and stdin EOF, and writes a marker when `SIGTERM` arrives without
/// dying of it. The session's exit grace is held by a gate rather than a clock,
/// so "no signal inside the first grace" is asserted causally; the transport's
/// grace is a real (small) one, because it lives on a reap queue that has no
/// seam, and only its far side — the process gone — is waited for.
final class LSPProcessShutdownTests: XCTestCase {
    /// The session's exit grace, parked until the test lets it go.
    private final class GraceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var isStarted = false
        private var isReleased = false

        var started: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isStarted
        }

        var wait: @Sendable (TimeInterval) async -> Void {
            { [self] _ in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    isStarted = true
                    if isReleased {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            isReleased = true
            let parked = waiter
            waiter = nil
            lock.unlock()
            parked?.resume()
        }
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lsp-ignores-exit.sh")
    }

    private func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    func testAServerThatIgnoresExitIsSignalledOnlyAfterTheGraceAndKilledAfterTheSecond() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPProcessShutdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("term-marker")

        let transport = try LSPProcessTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [fixtureURL().path, marker.path],
            directory: directory,
            terminationGrace: 0.5
        )
        let pid = transport.processIdentifier
        defer { if isAlive(pid) { kill(pid, SIGKILL) } }

        let graces = GraceGate()
        defer { graces.release() }
        let session = LSPSession(
            transport: transport,
            // The fixture never answers `shutdown`; its budget is spent quickly.
            budgets: LSPSession.Budgets(handshake: 10, shutdown: 0.1),
            exitGraceWait: graces.wait
        )
        try await session.start(processID: nil, rootURI: nil)

        let shuttingDown = Task { await session.shutdown() }
        await waitFor("the exit grace to start") { graces.started }

        // Inside the first grace: `exit` sent, stdin closed, no signal.
        XCTAssertTrue(isAlive(pid), "a server ignoring exit is still running inside its grace")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "SIGTERM arrived inside the exit grace"
        )

        graces.release()
        await shuttingDown.value

        // After it: SIGTERM, which this server traps and survives…
        await waitFor("SIGTERM to reach the server") {
            FileManager.default.fileExists(atPath: marker.path)
        }
        // …until the transport's own grace runs out and SIGKILL ends it.
        await waitFor("the server to be killed") { !isAlive(pid) }
    }
}
#endif
