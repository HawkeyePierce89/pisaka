import Foundation
@testable import PisakaCore

/// A `DatabaseServicing` that answers from a script instead of from SQLite.
///
/// The `ScriptedLeetCodeTransport` principle applied to a database connection:
/// everything interesting about the viewer — which statement a page load
/// composes, what a sort toggle re-queries, which of two overlapping loads
/// publishes, what a failure mid-paging leaves on screen — is *sequencing and
/// failure handling*, and none of it needs a real file. What it needs is a seam
/// that can answer a recorded result set, fail on demand, and be held mid-flight
/// while a test changes the world.
///
/// Answers are keyed by **SQL text alone, not by the whole statement**, which is
/// the one thing to know before writing a test against it. A page query is the
/// same text on every page — only its bound `LIMIT`/`OFFSET` differ — so keying
/// by the statement would force every test to restate the parameters it is
/// trying to *assert*. Instead a test scripts the text once and then asserts what
/// was bound, out of `statements(for:)`.
///
/// Three further behaviours are worth knowing:
///
/// - A key's script is a queue and **the last step is sticky**: script one answer
///   and every call gets it, script three and the third answers forever after.
///   That is what lets "paging asks three times" be an assertion about
///   `count(for:)` rather than about how many stubs were consumed.
/// - An **unscripted statement throws** rather than answering an empty result
///   set. A test that forgot to script something must fail as a failure, not as
///   an empty table three layers away.
/// - `run` before `open(url:)` — or after `close()` — throws
///   `DatabaseError.closed`, exactly as the real connection does. The fake is not
///   more forgiving than the thing it stands in for.
///
/// Thread safety is an `NSLock` over every stored property, not a main-actor hop:
/// the seam is `async` and is awaited from the main actor, so its body runs on
/// the cooperative pool. Nothing here reaches into a `StubFileTree` (which is the
/// shared mutable state the repo's cooperative-pool rule is actually about); the
/// fake owns its own storage and guards all of it.
final class ScriptedDatabaseService: DatabaseServicing, @unchecked Sendable {

    enum Failure: Error, LocalizedError, Equatable {
        /// Nothing was scripted for this SQL text.
        case notScripted(sql: String)

        var errorDescription: String? {
            switch self {
            case .notScripted(let sql):
                return "No scripted result for “\(sql)”."
            }
        }
    }

    private struct Step {
        let answer: Result<DatabaseResultSet, Error>
    }

    private let lock = NSLock()
    private var steps: [String: [Step]] = [:]
    private var gates: [String: Gate] = [:]
    private var openGate: Gate?
    private var closeGate: Gate?
    private var openFailure: Error?
    private var runStorage: [DatabaseStatement] = []
    private var openedStorage: [URL] = []
    private var closeCountStorage = 0
    private var isOpenStorage = false

    // MARK: - Scripting

    /// Answer `sql` with `resultSet`, replacing any script it had.
    func serve(_ sql: String, with resultSet: DatabaseResultSet) {
        script(sql, [Step(answer: .success(resultSet))])
    }

    /// Answer `sql` with a result set built from `columns` and `rows`.
    func serve(_ sql: String, columns: [String], rows: [[DatabaseValue]]) {
        serve(sql, with: DatabaseResultSet(columnNames: columns, rows: rows))
    }

    /// Answer `sql` with each element in turn, the last one sticking.
    func serve(_ sql: String, sequence resultSets: [DatabaseResultSet]) {
        script(sql, resultSets.map { Step(answer: .success($0)) })
    }

    /// Fail every run of `sql`.
    func fail(_ sql: String, with error: Error = DatabaseError.sqlError(message: "no such table")) {
        script(sql, [Step(answer: .failure(error))])
    }

    /// Fail the first run of `sql` and answer the rest with `resultSet` — the
    /// "it worked on the retry" shape.
    func fail(
        _ sql: String,
        once error: Error = DatabaseError.sqlError(message: "no such table"),
        thenServe resultSet: DatabaseResultSet
    ) {
        script(sql, [Step(answer: .failure(error)), Step(answer: .success(resultSet))])
    }

    /// Fail `open(url:)` with `error`.
    func failOpen(with error: Error = DatabaseError.notADatabase(message: "file is not a database")) {
        lock.lock()
        openFailure = error
        lock.unlock()
    }

    /// Stop failing `open(url:)` — the "and then it worked" half of a retry,
    /// which is the only way a test can assert that a failed open leaves the
    /// connection re-openable rather than latched shut.
    func clearOpenFailure() {
        lock.lock()
        openFailure = nil
        lock.unlock()
    }

    /// Hold every run of `sql` until the gate is released — the window a test
    /// starts a second, superseding load in.
    ///
    /// Blocking is sound because `run(_:)` is `nonisolated async`: the model
    /// `await`s it from the main actor, so the body runs on the cooperative pool
    /// and the main actor stays free to publish the state the test is staging.
    /// That is `Gate`'s whole premise.
    func hold(_ sql: String, on gate: Gate) {
        lock.lock()
        gates[sql] = gate
        lock.unlock()
    }

    /// Hold `open(url:)` until the gate is released.
    func holdOpen(on gate: Gate) {
        lock.lock()
        openGate = gate
        lock.unlock()
    }

    /// Hold `close()` until the gate is released — the window a test resumes a
    /// *superseded* load in, which is the only place `DatabaseViewerModel.reload`
    /// and an in-flight `load` can interleave.
    func holdClose(on gate: Gate) {
        lock.lock()
        closeGate = gate
        lock.unlock()
    }

    private func script(_ sql: String, _ newSteps: [Step]) {
        lock.lock()
        steps[sql] = newSteps
        lock.unlock()
    }

    // MARK: - What was asked

    /// Every statement run, in call order — the parameters included, which is
    /// where a paging assertion reads its `LIMIT`/`OFFSET` from.
    var runStatements: [DatabaseStatement] {
        lock.lock()
        defer { lock.unlock() }
        return runStorage
    }

    /// The SQL texts run, in call order.
    var runSQL: [String] { runStatements.map(\.sql) }

    /// The statements that ran `sql`, in call order.
    func statements(for sql: String) -> [DatabaseStatement] {
        runStatements.filter { $0.sql == sql }
    }

    /// How many times `sql` was run.
    func count(for sql: String) -> Int {
        statements(for: sql).count
    }

    /// The URLs `open(url:)` was called with, in call order.
    var openedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return openedStorage
    }

    /// How many times `close()` was called — including the calls that closed
    /// nothing, because "closed exactly once" is an assertion about the caller.
    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCountStorage
    }

    /// Whether a connection is currently open.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpenStorage
    }

    // MARK: - DatabaseServicing

    func open(url: URL) async throws {
        lock.lock()
        openedStorage.append(url)
        let gate = openGate
        let failure = openFailure
        lock.unlock()

        gate?.wait()

        if let failure { throw failure }

        lock.lock()
        isOpenStorage = true
        lock.unlock()
    }

    func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet {
        lock.lock()
        runStorage.append(statement)
        let open = isOpenStorage
        lock.unlock()

        // Asked before anything is consumed or held: a run against a connection
        // that is not open is the connection's answer, not the script's, so it
        // must not eat a step the next run is expecting.
        guard open else { throw DatabaseError.closed }

        lock.lock()
        let gate = gates[statement.sql]
        var queue = steps[statement.sql] ?? []
        let step = queue.first
        // The last step sticks; earlier ones are consumed.
        if queue.count > 1 {
            queue.removeFirst()
            steps[statement.sql] = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notScripted(sql: statement.sql) }
        return try step.answer.get()
    }

    func close() async {
        lock.lock()
        let gate = closeGate
        lock.unlock()

        gate?.wait()

        lock.lock()
        closeCountStorage += 1
        isOpenStorage = false
        lock.unlock()
    }
}
