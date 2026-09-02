import XCTest
@testable import PisakaCore

/// The seam itself, and the scripted fake that stands in for it everywhere else.
///
/// The fake is about to carry the whole viewer-model suite, so the assumptions
/// those tests will make — the sticky last step, the call log keyed by SQL text
/// while the parameters stay readable, an unscripted statement failing loudly,
/// failure injection, and a gate that really does hold a call open — are pinned
/// here. A fake whose behaviour is only implied by the tests that use it fails
/// them for the wrong reason.
final class DatabaseServicingTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/Project/app.sqlite")
    private let listSQL = "SELECT name FROM sqlite_master"
    private let pageSQL = "SELECT * FROM \"people\" LIMIT ? OFFSET ?"

    // MARK: - The protocol's shape

    /// `close()` is defaulted so a stub that owns no resource compiles without
    /// it — the `GitServicing` precedent, and what keeps part 2's additions from
    /// breaking every existing conformer.
    func testCloseIsDefaultedForAPartialStub() async throws {
        struct FixedAnswerStub: DatabaseServicing {
            func open(url: URL) async throws {}
            func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet {
                DatabaseResultSet(columnNames: ["one"], rows: [[.integer(1)]])
            }
        }

        let stub = FixedAnswerStub()
        try await stub.open(url: url)
        let result = try await stub.run(DatabaseStatement("SELECT 1"))
        XCTAssertEqual(result.rows, [[.integer(1)]])
        await stub.close()
    }

    // MARK: - Answers

    func testAServedStatementAnswersItsResultSet() async throws {
        let service = ScriptedDatabaseService()
        service.serve(listSQL, columns: ["name"], rows: [[.text("people")], [.text("orders")]])

        try await service.open(url: url)
        let result = try await service.run(DatabaseStatement(listSQL))

        XCTAssertEqual(result.columnNames, ["name"])
        XCTAssertEqual(result.rows, [[.text("people")], [.text("orders")]])
    }

    /// The property the paging tests depend on: script once, asked any number of
    /// times, and the assertion is about the count rather than about how many
    /// stubs were written.
    func testTheLastScriptedStepIsSticky() async throws {
        let service = ScriptedDatabaseService()
        service.serve(
            pageSQL,
            sequence: [
                DatabaseResultSet(columnNames: ["id"], rows: [[.integer(1)]]),
                DatabaseResultSet(columnNames: ["id"], rows: [[.integer(2)]]),
            ]
        )
        try await service.open(url: url)

        let first = try await service.run(DatabaseStatement(pageSQL, parameters: [.integer(1), .integer(0)]))
        let second = try await service.run(DatabaseStatement(pageSQL, parameters: [.integer(1), .integer(1)]))
        let third = try await service.run(DatabaseStatement(pageSQL, parameters: [.integer(1), .integer(2)]))

        XCTAssertEqual(first.rows, [[.integer(1)]])
        XCTAssertEqual(second.rows, [[.integer(2)]])
        XCTAssertEqual(third.rows, [[.integer(2)]], "The last step must stick")
        XCTAssertEqual(service.count(for: pageSQL), 3)
    }

    /// A test that forgot to script something must fail as a failure, not as an
    /// empty table three layers away.
    func testAnUnscriptedStatementThrows() async throws {
        let service = ScriptedDatabaseService()
        try await service.open(url: url)

        do {
            _ = try await service.run(DatabaseStatement("SELECT nothing"))
            XCTFail("An unscripted statement must throw")
        } catch let failure as ScriptedDatabaseService.Failure {
            XCTAssertEqual(failure, .notScripted(sql: "SELECT nothing"))
            XCTAssertEqual(failure.errorDescription?.contains("SELECT nothing"), true)
        }
    }

    // MARK: - The call log

    /// Keyed by SQL text, but the parameters stay readable — which is exactly the
    /// split the paging assertions need: one key, three different offsets.
    func testTheLogKeepsEveryBoundParameterInCallOrder() async throws {
        let service = ScriptedDatabaseService()
        service.serve(pageSQL, with: DatabaseResultSet(columnNames: ["id"]))
        try await service.open(url: url)

        for offset in [0, 100, 200] {
            _ = try await service.run(
                DatabaseStatement(pageSQL, parameters: [.integer(100), .integer(Int64(offset))])
            )
        }

        XCTAssertEqual(service.count(for: pageSQL), 3)
        XCTAssertEqual(
            service.statements(for: pageSQL).map(\.parameters),
            [
                [.integer(100), .integer(0)],
                [.integer(100), .integer(100)],
                [.integer(100), .integer(200)],
            ]
        )
    }

    func testTheLogRecordsEveryStatementIncludingUnscriptedOnes() async throws {
        let service = ScriptedDatabaseService()
        service.serve(listSQL, with: DatabaseResultSet(columnNames: ["name"]))
        try await service.open(url: url)

        _ = try await service.run(DatabaseStatement(listSQL))
        _ = try? await service.run(DatabaseStatement("SELECT nothing"))

        XCTAssertEqual(service.runSQL, [listSQL, "SELECT nothing"])
        XCTAssertEqual(service.count(for: "SELECT nothing"), 1)
        XCTAssertEqual(service.count(for: "SELECT never asked"), 0)
    }

    func testOpenAndCloseAreRecorded() async throws {
        let service = ScriptedDatabaseService()

        XCTAssertFalse(service.isOpen)
        XCTAssertEqual(service.openedURLs, [])

        try await service.open(url: url)
        XCTAssertTrue(service.isOpen)
        XCTAssertEqual(service.openedURLs, [url])

        await service.close()
        XCTAssertFalse(service.isOpen)
        XCTAssertEqual(service.closeCount, 1)
    }

    /// The tab owner closes on tab close and again at termination rather than
    /// tracking which already happened, so the seam — and the fake — must count
    /// the second call without complaining about it.
    func testClosingTwiceIsCountedAndHarmless() async throws {
        let service = ScriptedDatabaseService()
        try await service.open(url: url)

        await service.close()
        await service.close()

        XCTAssertEqual(service.closeCount, 2)
        XCTAssertFalse(service.isOpen)
    }

    // MARK: - Failure injection

    func testAFailedStatementThrowsWhatWasInjected() async throws {
        let service = ScriptedDatabaseService()
        service.fail(listSQL, with: DatabaseError.sqlError(message: "no such table: sqlite_master"))
        try await service.open(url: url)

        do {
            _ = try await service.run(DatabaseStatement(listSQL))
            XCTFail("The injected failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "no such table: sqlite_master"))
        }
    }

    func testFailingOnceThenServingIsTheRetryShape() async throws {
        let service = ScriptedDatabaseService()
        service.fail(listSQL, thenServe: DatabaseResultSet(columnNames: ["name"], rows: [[.text("people")]]))
        try await service.open(url: url)

        do {
            _ = try await service.run(DatabaseStatement(listSQL))
            XCTFail("The first run must fail")
        } catch {
            // Expected.
        }

        let retried = try await service.run(DatabaseStatement(listSQL))
        XCTAssertEqual(retried.rows, [[.text("people")]])
        XCTAssertEqual(service.count(for: listSQL), 2)
    }

    /// The "this file is not a database" case, which the viewer model must land
    /// in an error state rather than in an empty table list.
    func testOpenCanBeFailed() async {
        let service = ScriptedDatabaseService()
        service.failOpen()

        do {
            try await service.open(url: url)
            XCTFail("The injected open failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .notADatabase(message: "file is not a database"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.openedURLs, [url], "A refused open is still an attempt worth logging")
        XCTAssertFalse(service.isOpen)
    }

    /// The fake is not more forgiving than the connection it stands in for: a run
    /// with nothing open is `DatabaseError.closed`, and it does not eat the step
    /// the next run is expecting.
    func testRunningWithoutAnOpenConnectionIsClosed() async throws {
        let service = ScriptedDatabaseService()
        service.serve(listSQL, columns: ["name"], rows: [[.text("people")]])

        do {
            _ = try await service.run(DatabaseStatement(listSQL))
            XCTFail("A run against a closed connection must throw")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .closed)
        }

        try await service.open(url: url)
        let result = try await service.run(DatabaseStatement(listSQL))
        XCTAssertEqual(result.rows, [[.text("people")]], "The refused run must not have consumed the step")
    }

    func testRunningAfterCloseIsClosed() async throws {
        let service = ScriptedDatabaseService()
        service.serve(listSQL, columns: ["name"], rows: [[.text("people")]])
        try await service.open(url: url)
        _ = try await service.run(DatabaseStatement(listSQL))
        await service.close()

        do {
            _ = try await service.run(DatabaseStatement(listSQL))
            XCTFail("A run after close must throw")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Holding a call open

    /// The window every superseded-load test is staged in: the gate really does
    /// suspend the call, the caller really is still waiting, and releasing it
    /// really does deliver the scripted answer.
    func testAHeldStatementStaysInFlightUntilTheGateIsReleased() async throws {
        let service = ScriptedDatabaseService()
        service.serve(listSQL, columns: ["name"], rows: [[.text("people")]])
        let gate = Gate()
        service.hold(listSQL, on: gate)
        try await service.open(url: url)

        let finished = Recorder()
        let running = Task {
            let result = try await service.run(DatabaseStatement(self.listSQL))
            await finished.record(result)
        }

        await gate.waitUntilReached()
        let recordedWhileHeld = await finished.value
        XCTAssertNil(recordedWhileHeld, "The call must still be in flight while the gate holds it")

        gate.release()
        try await running.value

        await waitFor("the held statement to answer") { await finished.value != nil }
        let delivered = await finished.value
        XCTAssertEqual(delivered?.rows, [[.text("people")]])
    }

    func testOpenCanBeHeldToo() async throws {
        let service = ScriptedDatabaseService()
        let gate = Gate()
        service.holdOpen(on: gate)

        let opened = Task { try await service.open(url: self.url) }

        await gate.waitUntilReached()
        XCTAssertFalse(service.isOpen, "The connection must not be open while the gate holds it")

        gate.release()
        try await opened.value
        XCTAssertTrue(service.isOpen)
    }

    // MARK: - The write member

    /// The seam's write half is defaulted, so a stub that owns no write
    /// connection still conforms — and it refuses *honestly* rather than
    /// answering a zero-row rollback, which the model would otherwise read back
    /// to the reader as "this row changed underneath you".
    func testPerformWriteIsDefaultedToAnHonestReadOnlyRefusal() async {
        struct FixedAnswerStub: DatabaseServicing {
            func open(url: URL) async throws {}
            func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet {
                DatabaseResultSet(columnNames: ["one"], rows: [[.integer(1)]])
            }
        }

        let transaction = DatabaseWriteTransaction(
            url: url,
            statements: [DatabaseStatement("UPDATE \"people\" SET \"name\" = ?", parameters: [.text("Ada")])],
            requiredAffectedRows: 1
        )

        do {
            _ = try await FixedAnswerStub().performWrite(transaction)
            XCTFail("A conformer with no write half must refuse")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "This database connection is read-only."))
            XCTAssertEqual(error.errorDescription, "This database connection is read-only.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// What the write tests in the model suite read their assertions out of: the
    /// transaction arrives verbatim — the URL it was told to open, every bound
    /// value, and the affected-row count Core required.
    func testTheScriptedServiceRecordsTheTransactionVerbatim() async throws {
        let service = ScriptedDatabaseService()
        service.serveCommittedWrite()

        let statement = DatabaseStatement(
            "UPDATE \"people\" SET \"name\" = ? WHERE rowid IS ? AND \"name\" IS ?",
            parameters: [.text("Ada"), .integer(7), .null]
        )
        let transaction = DatabaseWriteTransaction(url: url, statements: [statement], requiredAffectedRows: 1)

        let outcome = try await service.performWrite(transaction)

        XCTAssertEqual(outcome, DatabaseWriteOutcome(affectedRows: 1, isCommitted: true))
        XCTAssertEqual(service.writeTransactions, [transaction])
        XCTAssertEqual(service.writeTransactions.first?.url, url)
        XCTAssertEqual(service.writeTransactions.first?.statements, [statement])
        XCTAssertEqual(service.writeTransactions.first?.requiredAffectedRows, 1)
        XCTAssertEqual(service.writeCount, 1)
    }

    /// A write is its own connection, so the read connection being closed says
    /// nothing about it — the fake must not gate one on the other.
    func testAWriteDoesNotRequireTheReadConnectionToBeOpen() async throws {
        let service = ScriptedDatabaseService()
        service.serveCommittedWrite()

        XCTAssertFalse(service.isOpen)
        let outcome = try await service.performWrite(transaction())

        XCTAssertTrue(outcome.isCommitted)
        XCTAssertEqual(service.writeCount, 1)
    }

    /// The two rollback shapes the model tells apart: nothing matched, and the
    /// identity was not unique after all.
    func testRolledBackOutcomesCarryTheirCounts() async throws {
        let service = ScriptedDatabaseService()

        service.serveRolledBackWrite(affectedRows: 0)
        let stale = try await service.performWrite(transaction())
        XCTAssertEqual(stale, DatabaseWriteOutcome(affectedRows: 0, isCommitted: false))

        service.serveRolledBackWrite(affectedRows: 3)
        let ambiguous = try await service.performWrite(transaction())
        XCTAssertEqual(ambiguous, DatabaseWriteOutcome(affectedRows: 3, isCommitted: false))
    }

    /// The same sticky-last-step rule the run script follows, so "and the second
    /// write…" needs no extra machinery.
    func testTheLastScriptedWriteSticks() async throws {
        let service = ScriptedDatabaseService()
        service.serveWrites(
            sequence: [
                DatabaseWriteOutcome(affectedRows: 1, isCommitted: true),
                DatabaseWriteOutcome(affectedRows: 0, isCommitted: false),
            ]
        )

        let first = try await service.performWrite(transaction())
        let second = try await service.performWrite(transaction())
        let third = try await service.performWrite(transaction())

        XCTAssertTrue(first.isCommitted)
        XCTAssertFalse(second.isCommitted)
        XCTAssertFalse(third.isCommitted, "The last step must stick")
        XCTAssertEqual(service.writeCount, 3)
    }

    func testAFailedWriteThrowsWhatWasInjected() async {
        let service = ScriptedDatabaseService()
        service.failWrite()

        do {
            _ = try await service.performWrite(transaction())
            XCTFail("The injected write failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .busy(message: "database is locked"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.writeCount, 1, "A refused write is still an attempt worth logging")
    }

    func testAnUnscriptedWriteThrows() async {
        let service = ScriptedDatabaseService()

        do {
            _ = try await service.performWrite(transaction())
            XCTFail("An unscripted write must throw")
        } catch let failure as ScriptedDatabaseService.Failure {
            XCTAssertEqual(failure, .notScripted(sql: "UPDATE \"people\" SET \"name\" = ? WHERE rowid IS ?"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// The window the model suite stages a superseding selection — or a second
    /// write — in: the gate really does hold the write open.
    func testAHeldWriteStaysInFlightUntilTheGateIsReleased() async throws {
        let service = ScriptedDatabaseService()
        service.serveCommittedWrite()
        let gate = Gate()
        service.holdWrite(on: gate)

        let finished = OutcomeRecorder()
        let running = Task {
            let outcome = try await service.performWrite(self.transaction())
            await finished.record(outcome)
        }

        await gate.waitUntilReached()
        let recordedWhileHeld = await finished.value
        XCTAssertNil(recordedWhileHeld, "The write must still be in flight while the gate holds it")

        gate.release()
        try await running.value

        await waitFor("the held write to answer") { await finished.value != nil }
        let delivered = await finished.value
        XCTAssertEqual(delivered, DatabaseWriteOutcome(affectedRows: 1, isCommitted: true))
    }

    // MARK: - Support

    /// A one-statement transaction the write assertions above share.
    private func transaction() -> DatabaseWriteTransaction {
        DatabaseWriteTransaction(
            url: url,
            statements: [
                DatabaseStatement(
                    "UPDATE \"people\" SET \"name\" = ? WHERE rowid IS ?",
                    parameters: [.text("Ada"), .integer(7)]
                ),
            ],
            requiredAffectedRows: 1
        )
    }

    /// A sink an off-main write writes into, polled the same way `Recorder` is.
    private actor OutcomeRecorder {
        private(set) var value: DatabaseWriteOutcome?
        func record(_ outcome: DatabaseWriteOutcome) { value = outcome }
    }

    /// A sink an off-main call writes into, polled by the assertions rather than
    /// assumed to have landed after any particular number of hops.
    private actor Recorder {
        private(set) var value: DatabaseResultSet?
        func record(_ result: DatabaseResultSet) { value = result }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}
