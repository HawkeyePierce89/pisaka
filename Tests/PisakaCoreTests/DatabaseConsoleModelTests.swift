import XCTest
@testable import PisakaCore

/// The console model against `ScriptedDatabaseService`: what Run sends, what it
/// refuses to send, what a confirmation gates, and what each answer publishes.
///
/// Every sentence asserted here is compared against `DatabaseConsolePlan`'s own
/// rather than a literal — `DatabaseConsolePlanTests` is where the wording is
/// pinned — so a change to a sentence moves both halves together.
@MainActor
final class DatabaseConsoleModelTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/Project/app.sqlite")

    // MARK: - Reading

    func testAReadPublishesRowsColumnsAndTheFooter() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT id, label FROM items"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(
            text,
            columns: ["id", "label"],
            rows: [[.integer(1), .text("one")], [.integer(2), .null]]
        )
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(model.answer?.columnNames, ["id", "label"])
        XCTAssertEqual(model.answer?.rows, [[.integer(1), .text("one")], [.integer(2), .null]])
        XCTAssertEqual(model.footer, DatabaseConsolePlan.resultFooter(rowCount: 2, isTruncated: false))
        XCTAssertNil(model.message)
        XCTAssertNil(model.affectedRows)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testTheTextIsClassifiedBeforeAnythingRunsAndIsCarriedVerbatim() async {
        let service = ScriptedDatabaseService()
        let text = "  SELECT 1 ;\n-- a trailing comment\n"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(service.classifiedTexts, [text], "The text is classified, spelled exactly as typed")
        XCTAssertEqual(service.consoleReadTexts, [text], "…and run the same way, never re-spelled")
    }

    func testTheCapTravelsAsANumberRatherThanAnAppendedLimit() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT * FROM items"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["id"], rows: [])
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(service.consoleReadRowLimits, [DatabaseConsolePlan.rowLimit])
        XCTAssertEqual(service.consoleReadTexts, [text], "No LIMIT is appended to the reader's text")
    }

    func testTruncationReachesTheFooter() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT * FROM big"
        let rows = (0..<DatabaseConsolePlan.rowLimit).map { [DatabaseValue.integer(Int64($0))] }
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["id"], rows: rows, isTruncated: true)
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(model.answer?.isTruncated, true)
        XCTAssertEqual(
            model.footer,
            DatabaseConsolePlan.resultFooter(rowCount: DatabaseConsolePlan.rowLimit, isTruncated: true)
        )
    }

    func testAnEmptyTextSaysThereIsNothingToRunAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let text = "   \n-- nothing here\n"
        service.serveClassification(text, DatabaseConsoleClassification())
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(model.message, DatabaseConsolePlan.nothingToRunMessage)
        XCTAssertNil(model.answer)
        XCTAssertEqual(service.consoleReadTexts, [])
        XCTAssertEqual(service.consoleWriteCount, 0)
    }

    func testAReadOnlyPrefixThenADeferralIsRefusedWithSQLitesMessageAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1; SELECT * FROM gone;"
        service.serveClassification(text, kinds: [.read], deferredWith: "no such table: gone")
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(model.message, "no such table: gone", "SQLite's own words, verbatim")
        XCTAssertEqual(service.consoleReadTexts, [], "A read cannot have created what the next statement needs")
        XCTAssertEqual(service.consoleWriteCount, 0)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testAFailedRunLeavesThePreviousResultAndItsFooterStanding() async {
        let service = ScriptedDatabaseService()
        let first = "SELECT 1"
        let second = "SELECT * FROM gone"
        service.serveClassification(first, kinds: [.read])
        service.serveConsoleRead(first, columns: ["1"], rows: [[.integer(1)]])
        service.serveClassification(second, kinds: [.read])
        service.failConsoleRead(second, with: DatabaseError.sqlError(message: "no such table: gone"))
        let model = await openedConsole(service)

        await model.run(first)
        let standing = model.answer
        let standingFooter = model.footer

        await model.run(second)

        XCTAssertEqual(model.message, "no such table: gone")
        XCTAssertEqual(model.answer, standing, "A failed run replaces nothing")
        XCTAssertEqual(model.footer, standingFooter)
    }

    func testAClassificationThatThrowsIsPublishedAsItsOwnSentence() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.failClassification(text, with: DatabaseError.closed)
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(model.message, DatabaseError.closed.message)
        XCTAssertEqual(service.consoleReadTexts, [])
        XCTAssertFalse(model.isRunning)
    }

    // MARK: - The confirmation

    func testAMutatingTextAsksAndRunsNothingUntilItIsConfirmed() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items WHERE id = 1"
        let classification = DatabaseConsoleClassification(kinds: [.write])
        service.serveClassification(text, classification)
        let model = await openedConsole(service)

        await model.run(text)

        XCTAssertEqual(
            model.pendingConfirmation,
            DatabaseConsoleModel.PendingConfirmation(
                prompt: DatabaseConsolePlan.confirmationPrompt(for: classification),
                text: text
            )
        )
        XCTAssertEqual(service.consoleWriteCount, 0, "Nothing is sent until the reader agrees")
        XCTAssertEqual(service.consoleReadTexts, [], "…and a mutating batch never goes down the read path")
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isWriting)
    }

    func testDecliningRunsNothingAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let text = "DROP TABLE items"
        service.serveClassification(text, kinds: [.write])
        let model = await openedConsole(service)

        await model.run(text)
        model.cancel()

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(service.consoleWriteCount, 0)
        XCTAssertNil(model.message, "Being asked and saying no is not a failure to explain")
        XCTAssertNil(model.footer)
    }

    func testConfirmingSendsTheTextVerbatimInOneTransactionAndReportsTheCount() async {
        let service = ScriptedDatabaseService()
        let text = "UPDATE items SET label = 'x';\nDELETE FROM items WHERE id = 2;"
        service.serveClassification(text, kinds: [.write, .write])
        service.serveCommittedConsoleWrite(affectedRows: 3)
        let model = await openedConsole(service)

        await model.run(text)
        await model.confirm()

        XCTAssertEqual(
            service.consoleTransactions,
            [DatabaseConsoleTransaction(url: url, text: text, readRowLimit: DatabaseConsolePlan.rowLimit)]
        )
        XCTAssertEqual(model.affectedRows, 3)
        XCTAssertEqual(model.footer, DatabaseConsolePlan.affectedRowsFooter(3))
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isWriting)
        XCTAssertFalse(model.isRunning)
    }

    func testACommittedMutationShowsNoRows() async {
        let service = ScriptedDatabaseService()
        let read = "SELECT 1"
        let write = "INSERT INTO items VALUES (3, 'three')"
        service.serveClassification(read, kinds: [.read])
        service.serveConsoleRead(read, columns: ["1"], rows: [[.integer(1)]])
        service.serveClassification(write, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        let model = await openedConsole(service)

        await model.run(read)
        await model.run(write)
        await model.confirm()

        XCTAssertNil(model.answer, "A mutating batch reports a count and shows no rows")
        XCTAssertEqual(model.footer, DatabaseConsolePlan.affectedRowsFooter(1))
    }

    func testAWritePrefixThenADeferralAsksRunsAndReportsSQLitesSentenceForTheDeferredStatement() async {
        let service = ScriptedDatabaseService()
        let text = "CREATE TABLE x(a); INSERT INTO x VALUES(1);"
        let classification = DatabaseConsoleClassification(
            kinds: [.write],
            deferral: DatabaseConsoleClassification.Deferral(index: 1, message: "no such table: x")
        )
        var didWriteCount = 0
        var refreshCount = 0
        service.serveClassification(text, classification)
        service.failConsoleWrite(with: DatabaseError.sqlError(message: "no such table: x"))
        let model = await openedConsole(
            service,
            didWrite: { didWriteCount += 1 },
            refreshAfterWrite: { refreshCount += 1 }
        )

        await model.run(text)
        XCTAssertEqual(
            model.pendingConfirmation?.prompt,
            DatabaseConsolePlan.confirmationPrompt(for: classification),
            "A writing prefix makes the deferral a horizon, not a refusal"
        )

        await model.confirm()

        XCTAssertEqual(service.consoleWriteCount, 1, "The batch ran — the rest is classified as it runs")
        XCTAssertEqual(model.message, "no such table: x")
        XCTAssertNil(model.footer, "A rolled-back batch reports no count")
        XCTAssertNil(model.affectedRows)
        XCTAssertEqual(didWriteCount, 0, "Nothing committed, so nothing on disk is stale")
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(model.isWriting)
    }

    func testARollbackWithoutAThrowSaysTheDatabaseWasNotChanged() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        var didWriteCount = 0
        service.serveClassification(text, kinds: [.write])
        service.serveConsoleWrite(DatabaseWriteOutcome(affectedRows: 4, isCommitted: false))
        let model = await openedConsole(service, didWrite: { didWriteCount += 1 })

        await model.run(text)
        await model.confirm()

        XCTAssertEqual(model.message, DatabaseConsoleModel.rolledBackMessage)
        XCTAssertNil(model.affectedRows)
        XCTAssertEqual(didWriteCount, 0)
    }

    func testPressingRunAgainDropsAPendingConfirmation() async {
        let service = ScriptedDatabaseService()
        let write = "DROP TABLE items"
        let read = "SELECT 1"
        service.serveClassification(write, kinds: [.write])
        service.serveClassification(read, kinds: [.read])
        service.serveConsoleRead(read, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(service)

        await model.run(write)
        await model.run(read)

        XCTAssertNil(model.pendingConfirmation, "A new Run is a new question")
        await model.confirm()
        XCTAssertEqual(service.consoleWriteCount, 0, "…and there is nothing left to agree to")
    }

    // MARK: - The refusals

    func testTheGateRefusesAConfirmedMutationAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        var isBlocked = false
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        let model = await openedConsole(service, isWriteBlocked: { isBlocked })

        await model.run(text)
        // The gate is asked at the moment of sending, not before the prompt: it
        // can rise while the reader is reading the confirmation.
        isBlocked = true
        await model.confirm()

        XCTAssertEqual(model.message, DatabaseConsolePlan.gateBlockedMessage)
        XCTAssertEqual(service.consoleWriteCount, 0)
    }

    func testAReadIsNotRefusedWhileTheGateIsUp() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(service, isWriteBlocked: { true })

        await model.run(text)

        XCTAssertEqual(model.answer?.rows, [[.integer(1)]])
        XCTAssertNil(model.message, "The gate is about writes; a read is not one")
    }

    func testASecondConsoleMutationIsRefusedWhileTheFirstIsInFlight() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let gate = Gate()
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        service.holdConsoleWrite(on: gate)
        let model = await openedConsole(service)

        await model.run(text)
        let first = Task { await model.confirm() }
        await waitUntil { gate.reached }

        // The second run classifies while the first write is still in flight, so
        // its confirmation lands on a tab that already has one.
        await model.run(text)
        await model.confirm()

        XCTAssertEqual(model.message, DatabaseConsolePlan.runInFlightMessage)
        XCTAssertEqual(service.consoleWriteCount, 1, "One write per tab: the second was refused, not queued")
        gate.release()
        await first.value
    }

    func testACellEditInFlightRefusesAConsoleMutation() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        let model = await openedConsole(service, isOtherWriteInFlight: { true })

        await model.run(text)
        await model.confirm()

        XCTAssertEqual(model.message, DatabaseConsolePlan.runInFlightMessage)
        XCTAssertEqual(service.consoleWriteCount, 0)
    }

    // MARK: - The order after a commit, and supersession

    func testACommittedMutationPublishesTheFooterThenTellsTheAppThenRefreshes() async {
        let service = ScriptedDatabaseService()
        let text = "CREATE TABLE t(a)"
        var log: [String] = []
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 0)
        var model: DatabaseConsoleModel?
        let console = await openedConsole(
            service,
            didWrite: { log.append("didWrite(\(model?.footer ?? "nil"))") },
            refreshAfterWrite: { log.append("refresh(\(model?.footer ?? "nil"))") }
        )
        model = console

        await console.run(text)
        await console.confirm()

        XCTAssertEqual(
            log,
            [
                "didWrite(\(DatabaseConsolePlan.affectedRowsFooter(0)))",
                "refresh(\(DatabaseConsolePlan.affectedRowsFooter(0)))",
            ],
            "The footer is published first, then the app is told, then the tab re-reads"
        )
        XCTAssertEqual(console.footer, DatabaseConsolePlan.affectedRowsFooter(0))
        XCTAssertEqual(console.affectedRows, 0, "A committed zero is a real outcome, not a collision")
    }

    func testASupersededRunPublishesNothing() async {
        let service = ScriptedDatabaseService()
        let slow = "SELECT * FROM slow"
        let quick = "SELECT 1"
        let gate = Gate()
        service.serveClassification(slow, kinds: [.read])
        service.serveConsoleRead(slow, columns: ["slow"], rows: [[.text("stale")]])
        service.holdConsoleRead(on: gate)
        service.serveClassification(quick, kinds: [.read])
        service.serveConsoleRead(quick, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(service)

        let first = Task { await model.run(slow) }
        await waitUntil { gate.reached }

        // The second run supersedes the first before it can publish. The fake
        // holds every console read, so both are suspended at the gate and the
        // order they resume in does not matter: whichever way round, the first
        // run's token has already been superseded and it publishes nothing.
        let second = Task { await model.run(quick) }
        await waitUntil { service.consoleReadTexts.count == 2 }
        gate.release()
        gate.release()
        await first.value
        await second.value

        XCTAssertEqual(model.answer?.columnNames, ["1"], "The superseded read published nothing")
        XCTAssertNil(model.message)
    }

    func testASupersededMutationPublishesNothingButStillTellsTheApp() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let read = "SELECT 1"
        let gate = Gate()
        var didWriteCount = 0
        var refreshCount = 0
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 2)
        service.holdConsoleWrite(on: gate)
        service.serveClassification(read, kinds: [.read])
        service.serveConsoleRead(read, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(
            service,
            didWrite: { didWriteCount += 1 },
            refreshAfterWrite: { refreshCount += 1 }
        )

        await model.run(text)
        let writing = Task { await model.confirm() }
        await waitUntil { gate.reached }

        await model.run(read)
        gate.release()
        await writing.value

        XCTAssertEqual(didWriteCount, 1, "The file changed on disk whatever the screen has moved on to")
        XCTAssertEqual(refreshCount, 0, "…but nothing about the screen is re-read for a superseded run")
        XCTAssertNil(model.affectedRows)
        XCTAssertEqual(model.footer, DatabaseConsolePlan.resultFooter(rowCount: 1, isTruncated: false))
        XCTAssertEqual(model.answer?.rows, [[.integer(1)]], "The newer run's answer stands")
        XCTAssertFalse(model.isWriting, "The write that raised the flag is the only thing that can lower it")
    }

    // MARK: - Stopping

    func testStopSendsNothingFurtherAndLowersTheFlags() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["1"], rows: [[.integer(1)]])
        let model = await openedConsole(service)

        await model.run(text)
        model.stop()
        await model.run(text)

        XCTAssertEqual(service.classifiedTexts.count, 1, "A stopped console sends nothing at all")
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isWriting)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.answer?.rows, [[.integer(1)]], "What was on screen stays on screen")
    }

    func testStopDropsAPendingConfirmationSoNothingCanBeAgreedToAfterwards() async {
        let service = ScriptedDatabaseService()
        let text = "DROP TABLE items"
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        let model = await openedConsole(service)

        await model.run(text)
        model.stop()
        await model.confirm()

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(service.consoleWriteCount, 0)
    }

    // MARK: - Helpers

    /// A console over an opened connection.
    ///
    /// The open matters: the fake refuses a classification against a connection
    /// that is not open with `DatabaseError.closed`, exactly as the real one
    /// does, so a test that skipped it would be asserting about a closed
    /// connection rather than about the console.
    private func openedConsole(
        _ service: ScriptedDatabaseService,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false },
        isOtherWriteInFlight: @escaping @MainActor () -> Bool = { false },
        didWrite: @escaping @MainActor () -> Void = {},
        refreshAfterWrite: @escaping @MainActor () async -> Void = {}
    ) async -> DatabaseConsoleModel {
        try? await service.open(url: url)
        let model = DatabaseConsoleModel(service: service, fileURL: { self.url })
        model.connect(
            fileURL: { self.url },
            isWriteBlocked: isWriteBlocked,
            isOtherWriteInFlight: isOtherWriteInFlight,
            didWrite: didWrite,
            refreshAfterWrite: refreshAfterWrite
        )
        return model
    }

    /// A condition-wait that fails loudly — `DatabaseViewerModelTests`' shape and
    /// for its reason: the work being staged starts on the main actor, so a spin
    /// that only yields never lets the queued task reach the gate at all.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the gated call", file: file, line: line)
    }
}
