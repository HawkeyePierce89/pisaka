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
    private var writeGate: Gate?
    private var classifyGate: Gate?
    private var consoleReadGate: Gate?
    private var consoleWriteGate: Gate?
    private var openFailure: Error?
    private var writeSteps: [Result<DatabaseWriteOutcome, Error>] = []
    private var classifySteps: [String: [Result<DatabaseConsoleClassification, Error>]] = [:]
    private var consoleReadSteps: [String: [Result<DatabaseConsoleAnswer, Error>]] = [:]
    private var consoleWriteSteps: [Result<DatabaseWriteOutcome, Error>] = []
    private var runStorage: [DatabaseStatement] = []
    private var openedStorage: [URL] = []
    private var writeStorage: [DatabaseWriteTransaction] = []
    private var classifyStorage: [String] = []
    private var consoleReadStorage: [String] = []
    private var consoleReadLimitStorage: [Int] = []
    private var consoleWriteStorage: [DatabaseConsoleTransaction] = []
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

    /// Answer every `performWrite(_:)` with `outcome`.
    ///
    /// Unlike a run, a write is **not** keyed by SQL text: a transaction is a
    /// list of statements and the model composes it from a plan the test already
    /// asserted elsewhere, so keying by text would mean restating the composed
    /// `UPDATE` byte-for-byte in every write test just to script an answer. What
    /// the write path is actually about is the *outcome* — committed, rolled back
    /// at zero, rolled back at many, thrown — and what was handed over is read
    /// back out of `writeTransactions`.
    func serveWrite(_ outcome: DatabaseWriteOutcome) {
        scriptWrites([.success(outcome)])
    }

    /// Answer `performWrite(_:)` with a committed write of `affectedRows` rows.
    func serveCommittedWrite(affectedRows: Int = 1) {
        serveWrite(DatabaseWriteOutcome(affectedRows: affectedRows, isCommitted: true))
    }

    /// Answer `performWrite(_:)` with a rollback at `affectedRows` — the "the row
    /// changed underneath you" shape at zero, and the "that identity was not
    /// unique" shape above one.
    func serveRolledBackWrite(affectedRows: Int) {
        serveWrite(DatabaseWriteOutcome(affectedRows: affectedRows, isCommitted: false))
    }

    /// Answer each write in turn, the last one sticking — the same rule the run
    /// script follows, so "the second write also…" needs no extra machinery.
    func serveWrites(sequence outcomes: [DatabaseWriteOutcome]) {
        scriptWrites(outcomes.map { .success($0) })
    }

    /// Fail every `performWrite(_:)` with `error`.
    func failWrite(with error: Error = DatabaseError.busy(message: "database is locked")) {
        scriptWrites([.failure(error)])
    }

    /// Hold every `performWrite(_:)` until the gate is released — the window a
    /// test supersedes an in-flight write in, or starts a second one in.
    func holdWrite(on gate: Gate) {
        lock.lock()
        writeGate = gate
        lock.unlock()
    }

    private func scriptWrites(_ newSteps: [Result<DatabaseWriteOutcome, Error>]) {
        lock.lock()
        writeSteps = newSteps
        lock.unlock()
    }

    // MARK: - Scripting the console half

    /// Classify `text` as `classification`, replacing any script it had.
    ///
    /// Keyed by the reader's text, like a run and unlike a write: the whole point
    /// of the console path is that the text is carried verbatim, so a test that
    /// scripts one text and asserts another was sent is asserting exactly the
    /// rule that matters.
    func serveClassification(_ text: String, _ classification: DatabaseConsoleClassification) {
        scriptClassifications(text, [.success(classification)])
    }

    /// Classify `text` as `kinds`, optionally stopping at a deferral carrying
    /// SQLite's message — the migration-shaped script's whole shape in one call.
    func serveClassification(
        _ text: String,
        kinds: [DatabaseConsoleStatementKind],
        deferredWith message: String? = nil
    ) {
        let deferral = message.map { DatabaseConsoleClassification.Deferral(index: kinds.count, message: $0) }
        serveClassification(text, DatabaseConsoleClassification(kinds: kinds, deferral: deferral))
    }

    /// Classify `text` with each element in turn, the last one sticking.
    func serveClassifications(_ text: String, sequence classifications: [DatabaseConsoleClassification]) {
        scriptClassifications(text, classifications.map { .success($0) })
    }

    /// Fail every `classifyConsole(_:)` of `text` — the "not about the text at
    /// all" failure the seam reserves a throw for, never a deferral.
    func failClassification(_ text: String, with error: Error = DatabaseError.closed) {
        scriptClassifications(text, [.failure(error)])
    }

    /// Answer every `runConsoleRead(_:rowLimit:)` of `text` with `answer`.
    func serveConsoleRead(_ text: String, with answer: DatabaseConsoleAnswer) {
        scriptConsoleReads(text, [.success(answer)])
    }

    /// Answer `runConsoleRead(_:rowLimit:)` of `text` with an answer built from
    /// `columns` and `rows`.
    func serveConsoleRead(
        _ text: String,
        columns: [String],
        rows: [[DatabaseValue]],
        isTruncated: Bool = false
    ) {
        serveConsoleRead(
            text,
            with: DatabaseConsoleAnswer(columnNames: columns, rows: rows, isTruncated: isTruncated)
        )
    }

    /// Answer `text` with each element in turn, the last one sticking.
    func serveConsoleReads(_ text: String, sequence answers: [DatabaseConsoleAnswer]) {
        scriptConsoleReads(text, answers.map { .success($0) })
    }

    /// Fail every `runConsoleRead(_:rowLimit:)` of `text`.
    func failConsoleRead(_ text: String, with error: Error = DatabaseError.sqlError(message: "no such table")) {
        scriptConsoleReads(text, [.failure(error)])
    }

    /// Answer every `performConsoleWrite(_:)` with `outcome`.
    ///
    /// Not keyed by text, for `serveWrite(_:)`'s reason: what the console write
    /// path is about is the outcome, and what was handed over is read back out of
    /// `consoleTransactions` — where the text is, verbatim.
    func serveConsoleWrite(_ outcome: DatabaseWriteOutcome) {
        scriptConsoleWrites([.success(outcome)])
    }

    /// Answer `performConsoleWrite(_:)` with a committed batch of `affectedRows`
    /// rows. A committed zero is an ordinary outcome here — a `DELETE` that
    /// matched nothing, a `CREATE TABLE` — and not the collision it is for a cell
    /// edit.
    func serveCommittedConsoleWrite(affectedRows: Int = 1) {
        serveConsoleWrite(DatabaseWriteOutcome(affectedRows: affectedRows, isCommitted: true))
    }

    /// Answer each console write in turn, the last one sticking.
    func serveConsoleWrites(sequence outcomes: [DatabaseWriteOutcome]) {
        scriptConsoleWrites(outcomes.map { .success($0) })
    }

    /// Fail every `performConsoleWrite(_:)` with `error` — the shape a prepare
    /// failure on a deferred statement arrives in, which rolls the batch back.
    func failConsoleWrite(with error: Error = DatabaseError.sqlError(message: "no such table: x")) {
        scriptConsoleWrites([.failure(error)])
    }

    /// Hold every `classifyConsole(_:)` until the gate is released.
    func holdClassification(on gate: Gate) {
        lock.lock()
        classifyGate = gate
        lock.unlock()
    }

    /// Hold every `runConsoleRead(_:rowLimit:)` until the gate is released — the
    /// window a superseding console run is started in.
    func holdConsoleRead(on gate: Gate) {
        lock.lock()
        consoleReadGate = gate
        lock.unlock()
    }

    /// Hold every `performConsoleWrite(_:)` until the gate is released.
    func holdConsoleWrite(on gate: Gate) {
        lock.lock()
        consoleWriteGate = gate
        lock.unlock()
    }

    private func scriptClassifications(
        _ text: String,
        _ newSteps: [Result<DatabaseConsoleClassification, Error>]
    ) {
        lock.lock()
        classifySteps[text] = newSteps
        lock.unlock()
    }

    private func scriptConsoleReads(_ text: String, _ newSteps: [Result<DatabaseConsoleAnswer, Error>]) {
        lock.lock()
        consoleReadSteps[text] = newSteps
        lock.unlock()
    }

    private func scriptConsoleWrites(_ newSteps: [Result<DatabaseWriteOutcome, Error>]) {
        lock.lock()
        consoleWriteSteps = newSteps
        lock.unlock()
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

    /// The transactions `performWrite(_:)` was handed, verbatim and in call
    /// order — the URL it was told to open, the statements with every bound
    /// value, and the affected-row count Core required.
    var writeTransactions: [DatabaseWriteTransaction] {
        lock.lock()
        defer { lock.unlock() }
        return writeStorage
    }

    /// How many writes were asked for, including the ones that threw.
    var writeCount: Int { writeTransactions.count }

    /// Every text handed to `classifyConsole(_:)` or
    /// `runConsoleRead(_:rowLimit:)`, in call order — verbatim, which is what a
    /// test asserting "the reader's text was not rewritten" reads.
    var consoleTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return classifyStorage + consoleReadStorage
    }

    /// The texts `classifyConsole(_:)` was asked about, in call order.
    var classifiedTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return classifyStorage
    }

    /// The texts `runConsoleRead(_:rowLimit:)` was asked to run, in call order.
    var consoleReadTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return consoleReadStorage
    }

    /// The row caps `runConsoleRead(_:rowLimit:)` was given, in call order —
    /// where the assertion that the cap travels as a number rather than as an
    /// appended `LIMIT` reads its evidence.
    var consoleReadRowLimits: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return consoleReadLimitStorage
    }

    /// The transactions `performConsoleWrite(_:)` was handed, verbatim and in
    /// call order — the URL, the reader's text and the read cap inside it.
    var consoleTransactions: [DatabaseConsoleTransaction] {
        lock.lock()
        defer { lock.unlock() }
        return consoleWriteStorage
    }

    /// How many console writes were asked for, including the ones that threw.
    var consoleWriteCount: Int { consoleTransactions.count }

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

    /// Records the transaction, then answers the script.
    ///
    /// Deliberately **not** gated on `isOpenStorage`: a write is a separate,
    /// short-lived read-write connection the implementation opens for itself, so
    /// whether this instance's read connection happens to be open says nothing
    /// about it. An unscripted write throws for the same reason an unscripted
    /// statement does — a test that forgot to script one must fail as a failure.
    func performWrite(_ transaction: DatabaseWriteTransaction) async throws -> DatabaseWriteOutcome {
        lock.lock()
        writeStorage.append(transaction)
        let gate = writeGate
        var queue = writeSteps
        let step = queue.first
        if queue.count > 1 {
            queue.removeFirst()
            writeSteps = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else {
            throw Failure.notScripted(sql: transaction.statements.map(\.sql).joined(separator: "; "))
        }
        return try step.get()
    }

    /// Records the text, then answers the script.
    ///
    /// A scripted classification round-trips **unchanged**, deferral included: it
    /// is the classifier's whole answer and the policy's whole input, so a fake
    /// that normalised any part of it would be testing itself.
    func classifyConsole(_ text: String) async throws -> DatabaseConsoleClassification {
        lock.lock()
        classifyStorage.append(text)
        let open = isOpenStorage
        lock.unlock()

        // Asked before anything is consumed or held, for `run(_:)`'s reason: a
        // classification against a connection that is not open is the
        // connection's answer, not the script's.
        guard open else { throw DatabaseError.closed }

        lock.lock()
        let gate = classifyGate
        var queue = classifySteps[text] ?? []
        let step = queue.first
        if queue.count > 1 {
            queue.removeFirst()
            classifySteps[text] = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notScripted(sql: text) }
        return try step.get()
    }

    /// Records the text and the cap it was given, then answers the script.
    func runConsoleRead(_ text: String, rowLimit: Int) async throws -> DatabaseConsoleAnswer {
        lock.lock()
        consoleReadStorage.append(text)
        consoleReadLimitStorage.append(rowLimit)
        let open = isOpenStorage
        lock.unlock()

        guard open else { throw DatabaseError.closed }

        lock.lock()
        let gate = consoleReadGate
        var queue = consoleReadSteps[text] ?? []
        let step = queue.first
        if queue.count > 1 {
            queue.removeFirst()
            consoleReadSteps[text] = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notScripted(sql: text) }
        return try step.get()
    }

    /// Records the transaction, then answers the script.
    ///
    /// Not gated on `isOpenStorage`, for `performWrite(_:)`'s reason: a console
    /// mutation is its own short-lived read-write connection.
    func performConsoleWrite(_ transaction: DatabaseConsoleTransaction) async throws -> DatabaseWriteOutcome {
        lock.lock()
        consoleWriteStorage.append(transaction)
        let gate = consoleWriteGate
        var queue = consoleWriteSteps
        let step = queue.first
        if queue.count > 1 {
            queue.removeFirst()
            consoleWriteSteps = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notScripted(sql: transaction.text) }
        return try step.get()
    }
}
