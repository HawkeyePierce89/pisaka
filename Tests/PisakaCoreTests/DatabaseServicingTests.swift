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

    // MARK: - The console members

    /// All three console members are defaulted, so a stub that owns no console
    /// half still conforms — and each refuses *honestly*. An empty
    /// classification would read to the policy as "this text holds no
    /// statements", and an empty answer as "your query matched nothing"; both
    /// would be sentences about a connection that never looked.
    func testTheConsoleMembersAreDefaultedToHonestRefusals() async {
        struct FixedAnswerStub: DatabaseServicing {
            func open(url: URL) async throws {}
            func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet {
                DatabaseResultSet(columnNames: ["one"], rows: [[.integer(1)]])
            }
        }

        let stub = FixedAnswerStub()

        do {
            _ = try await stub.classifyConsole("SELECT 1")
            XCTFail("A conformer with no console half must refuse to classify")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "This database connection has no SQL console."))
            XCTAssertEqual(error.errorDescription, "This database connection has no SQL console.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await stub.runConsoleRead("SELECT 1", rowLimit: DatabaseConsolePlan.rowLimit)
            XCTFail("A conformer with no console half must refuse to read")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "This database connection has no SQL console."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await stub.performConsoleWrite(consoleTransaction())
            XCTFail("A conformer with no console half must refuse to write")
        } catch let error as DatabaseError {
            XCTAssertEqual(
                error,
                .sqlError(message: "This database connection is read-only."),
                "A console write refuses with the write refusal, which is what the reader is being told"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// The whole classification round-trips unchanged — deferral included. It is
    /// the policy's entire input, so a fake that normalised any part of it would
    /// be testing itself.
    func testAScriptedClassificationRoundTripsUnchanged() async throws {
        let service = ScriptedDatabaseService()
        let text = "CREATE TABLE x(a); INSERT INTO x VALUES(1);"
        service.serveClassification(text, kinds: [.write], deferredWith: "no such table: x")

        try await service.open(url: url)
        let classification = try await service.classifyConsole(text)

        XCTAssertEqual(classification.kinds, [.write])
        XCTAssertEqual(classification.deferral?.index, 1)
        XCTAssertEqual(classification.deferral?.message, "no such table: x")
        XCTAssertFalse(classification.isComplete)
        XCTAssertTrue(classification.isMutating)
        XCTAssertEqual(service.classifiedTexts, [text], "The reader's text arrives verbatim")
    }

    /// A complete read-only classification is the shape the policy answers
    /// `.read` to, and the only one the read member is ever handed.
    func testACompleteReadOnlyClassificationRoundTripsToo() async throws {
        let service = ScriptedDatabaseService()
        let text = "PRAGMA foreign_keys; SELECT * FROM people;"
        service.serveClassification(text, kinds: [.read, .read])

        try await service.open(url: url)
        let classification = try await service.classifyConsole(text)

        XCTAssertEqual(classification.kinds, [.read, .read])
        XCTAssertNil(classification.deferral)
        XCTAssertEqual(DatabaseConsolePlan.decide(classification), .read)
    }

    /// The same sticky-last-step rule everything else in the fake follows.
    func testTheLastScriptedClassificationAndConsoleReadStick() async throws {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.serveClassifications(
            text,
            sequence: [
                DatabaseConsoleClassification(kinds: [.read]),
                DatabaseConsoleClassification(kinds: [.read, .write]),
            ]
        )
        service.serveConsoleReads(
            text,
            sequence: [
                DatabaseConsoleAnswer(columnNames: ["a"], rows: [[.integer(1)]]),
                DatabaseConsoleAnswer(columnNames: ["a"], rows: [[.integer(2)]]),
            ]
        )
        try await service.open(url: url)

        _ = try await service.classifyConsole(text)
        let secondKinds = try await service.classifyConsole(text).kinds
        let thirdKinds = try await service.classifyConsole(text).kinds
        XCTAssertEqual(secondKinds, [.read, .write])
        XCTAssertEqual(thirdKinds, [.read, .write], "The last step must stick")

        _ = try await service.runConsoleRead(text, rowLimit: 500)
        let second = try await service.runConsoleRead(text, rowLimit: 500)
        let third = try await service.runConsoleRead(text, rowLimit: 500)
        XCTAssertEqual(second.rows, [[.integer(2)]])
        XCTAssertEqual(third.rows, [[.integer(2)]], "The last step must stick")

        XCTAssertEqual(service.classifiedTexts.count, 3)
        XCTAssertEqual(service.consoleReadTexts.count, 3)
    }

    /// The cap travels as a number — nothing appended to the text — which is
    /// what this reads back.
    func testAConsoleReadRecordsItsTextAndTheCapItWasGiven() async throws {
        let service = ScriptedDatabaseService()
        let text = "SELECT * FROM people"
        service.serveConsoleRead(text, columns: ["name"], rows: [[.text("Ada")]], isTruncated: true)

        try await service.open(url: url)
        let answer = try await service.runConsoleRead(text, rowLimit: DatabaseConsolePlan.rowLimit)

        XCTAssertEqual(answer.columnNames, ["name"])
        XCTAssertEqual(answer.rows, [[.text("Ada")]])
        XCTAssertTrue(answer.isTruncated)
        XCTAssertEqual(service.consoleReadTexts, [text])
        XCTAssertEqual(service.consoleReadRowLimits, [500])
        XCTAssertEqual(service.consoleTexts, [text], "A read with no classification beside it is the whole log")
    }

    /// Every text handed over, whichever member took it — the log a "nothing
    /// rewrote the reader's text" assertion reads. The two texts differ and the
    /// read is asked for *first*, so the assertion reads the log's documented
    /// shape — classifications, then reads — rather than passing on whichever
    /// order the calls happened to be made in.
    func testTheConsoleTextLogHoldsClassificationsThenReads() async throws {
        let service = ScriptedDatabaseService()
        let classified = "SELECT 1;"
        let read = "SELECT 2;"
        service.serveClassification(classified, kinds: [.read])
        service.serveConsoleRead(read, columns: ["2"], rows: [[.integer(2)]])

        try await service.open(url: url)
        _ = try await service.runConsoleRead(read, rowLimit: 500)
        _ = try await service.classifyConsole(classified)

        XCTAssertEqual(service.consoleTexts, [classified, read])
        XCTAssertEqual(service.classifiedTexts, [classified])
        XCTAssertEqual(service.consoleReadTexts, [read])
    }

    /// The transaction arrives verbatim: the URL, the reader's text untouched,
    /// and the cap a read-only statement inside the batch may be stepped to.
    func testTheScriptedServiceRecordsTheConsoleTransactionVerbatim() async throws {
        let service = ScriptedDatabaseService()
        service.serveCommittedConsoleWrite(affectedRows: 3)

        let transaction = consoleTransaction()
        let outcome = try await service.performConsoleWrite(transaction)

        XCTAssertEqual(outcome, DatabaseWriteOutcome(affectedRows: 3, isCommitted: true))
        XCTAssertEqual(service.consoleTransactions, [transaction])
        XCTAssertEqual(service.consoleTransactions.first?.url, url)
        XCTAssertEqual(
            service.consoleTransactions.first?.text,
            "DELETE FROM people WHERE id > 2;\n-- and a comment\nUPDATE people SET name = 'Ada';",
            "The reader's text is carried verbatim — comments, newlines and all"
        )
        XCTAssertEqual(service.consoleTransactions.first?.readRowLimit, DatabaseConsolePlan.rowLimit)
        XCTAssertEqual(service.consoleWriteCount, 1)
    }

    /// A console write is its own short-lived connection, so the read connection
    /// being closed says nothing about it — and a committed zero is an ordinary
    /// outcome here, unlike the cell edit's.
    func testAConsoleWriteNeedsNoOpenReadConnectionAndMayCommitZero() async throws {
        let service = ScriptedDatabaseService()
        service.serveCommittedConsoleWrite(affectedRows: 0)

        XCTAssertFalse(service.isOpen)
        let outcome = try await service.performConsoleWrite(consoleTransaction())

        XCTAssertEqual(outcome, DatabaseWriteOutcome(affectedRows: 0, isCommitted: true))
        XCTAssertEqual(service.consoleWriteCount, 1)
    }

    func testTheLastScriptedConsoleWriteSticks() async throws {
        let service = ScriptedDatabaseService()
        service.serveConsoleWrites(
            sequence: [
                DatabaseWriteOutcome(affectedRows: 2, isCommitted: true),
                DatabaseWriteOutcome(affectedRows: 0, isCommitted: false),
            ]
        )

        let first = try await service.performConsoleWrite(consoleTransaction())
        let second = try await service.performConsoleWrite(consoleTransaction())
        let third = try await service.performConsoleWrite(consoleTransaction())

        XCTAssertEqual(first.affectedRows, 2)
        XCTAssertFalse(second.isCommitted)
        XCTAssertFalse(third.isCommitted, "The last step must stick")
        XCTAssertEqual(service.consoleWriteCount, 3)
    }

    /// The shape a prepare failure on a deferred statement arrives in: an
    /// ordinary throw carrying SQLite's words, which rolls the batch back.
    func testAFailedConsoleWriteThrowsWhatWasInjected() async {
        let service = ScriptedDatabaseService()
        service.failConsoleWrite()

        do {
            _ = try await service.performConsoleWrite(consoleTransaction())
            XCTFail("The injected console-write failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "no such table: x"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.consoleWriteCount, 1, "A refused write is still an attempt worth logging")
    }

    /// A failure that is **not about the text** is thrown rather than deferred —
    /// a deferral says SQLite failed to prepare something, and this one never
    /// looked.
    func testAFailedClassificationThrowsRatherThanDeferring() async throws {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.failClassification(text)
        try await service.open(url: url)

        do {
            _ = try await service.classifyConsole(text)
            XCTFail("The injected classification failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAFailedConsoleReadThrowsWhatWasInjected() async throws {
        let service = ScriptedDatabaseService()
        let text = "SELECT * FROM missing"
        service.failConsoleRead(text)
        try await service.open(url: url)

        do {
            _ = try await service.runConsoleRead(text, rowLimit: 500)
            XCTFail("The injected console-read failure must be thrown")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .sqlError(message: "no such table"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// A test that forgot to script a console call must fail as a failure, not
    /// as an empty answer three layers away.
    func testUnscriptedConsoleCallsThrow() async throws {
        let service = ScriptedDatabaseService()
        try await service.open(url: url)

        do {
            _ = try await service.classifyConsole("SELECT nothing")
            XCTFail("An unscripted classification must throw")
        } catch let failure as ScriptedDatabaseService.Failure {
            XCTAssertEqual(failure, .notScripted(sql: "SELECT nothing"))
        }

        do {
            _ = try await service.runConsoleRead("SELECT nothing", rowLimit: 500)
            XCTFail("An unscripted console read must throw")
        } catch let failure as ScriptedDatabaseService.Failure {
            XCTAssertEqual(failure, .notScripted(sql: "SELECT nothing"))
        }

        do {
            _ = try await service.performConsoleWrite(consoleTransaction())
            XCTFail("An unscripted console write must throw")
        } catch let failure as ScriptedDatabaseService.Failure {
            XCTAssertEqual(failure, .notScripted(sql: consoleTransaction().text))
        }
    }

    /// The fake is not more forgiving than the connection it stands in for: both
    /// read-path console members answer `closed` before consuming a step, so the
    /// next call still finds the script it was given.
    func testTheConsoleReadPathRefusesAClosedConnectionWithoutConsumingAStep() async throws {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["a"], rows: [[.integer(1)]])

        do {
            _ = try await service.classifyConsole(text)
            XCTFail("Classifying a closed connection must throw")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .closed)
        }
        do {
            _ = try await service.runConsoleRead(text, rowLimit: 500)
            XCTFail("Reading through a closed connection must throw")
        } catch let error as DatabaseError {
            XCTAssertEqual(error, .closed)
        }

        try await service.open(url: url)
        let kinds = try await service.classifyConsole(text).kinds
        let rows = try await service.runConsoleRead(text, rowLimit: 500).rows
        XCTAssertEqual(kinds, [.read])
        XCTAssertEqual(rows, [[.integer(1)]])
    }

    /// The window the model suite stages a superseding console run in: each of
    /// the three gates really does hold its call open.
    func testEachConsoleMemberCanBeHeldOnAGate() async throws {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM people"
        service.serveClassification(text, kinds: [.write])
        service.serveConsoleRead(text, columns: [], rows: [])
        service.serveCommittedConsoleWrite()
        try await service.open(url: url)

        let classifyGate = Gate()
        service.holdClassification(on: classifyGate)
        let classified = ClassificationRecorder()
        let classifying = Task {
            await classified.record(try await service.classifyConsole(text))
        }
        await classifyGate.waitUntilReached()
        let whileClassifying = await classified.value
        XCTAssertNil(whileClassifying, "The classification must still be in flight")
        classifyGate.release()
        try await classifying.value
        await waitFor("the held classification to answer") { await classified.value != nil }

        let readGate = Gate()
        service.holdConsoleRead(on: readGate)
        let read = AnswerRecorder()
        let reading = Task {
            await read.record(try await service.runConsoleRead(text, rowLimit: 500))
        }
        await readGate.waitUntilReached()
        let whileReading = await read.value
        XCTAssertNil(whileReading, "The console read must still be in flight")
        readGate.release()
        try await reading.value
        await waitFor("the held console read to answer") { await read.value != nil }

        let writeGate = Gate()
        service.holdConsoleWrite(on: writeGate)
        let written = OutcomeRecorder()
        let writing = Task {
            await written.record(try await service.performConsoleWrite(self.consoleTransaction()))
        }
        await writeGate.waitUntilReached()
        let whileWriting = await written.value
        XCTAssertNil(whileWriting, "The console write must still be in flight")
        writeGate.release()
        try await writing.value
        await waitFor("the held console write to answer") { await written.value != nil }
        let delivered = await written.value
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

    /// A console transaction the console assertions above share — text carried
    /// verbatim, comments and newlines included.
    private func consoleTransaction() -> DatabaseConsoleTransaction {
        DatabaseConsoleTransaction(
            url: url,
            text: "DELETE FROM people WHERE id > 2;\n-- and a comment\nUPDATE people SET name = 'Ada';",
            readRowLimit: DatabaseConsolePlan.rowLimit
        )
    }

    /// A sink an off-main classification writes into.
    private actor ClassificationRecorder {
        private(set) var value: DatabaseConsoleClassification?
        func record(_ classification: DatabaseConsoleClassification) { value = classification }
    }

    /// A sink an off-main console read writes into.
    private actor AnswerRecorder {
        private(set) var value: DatabaseConsoleAnswer?
        func record(_ answer: DatabaseConsoleAnswer) { value = answer }
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
