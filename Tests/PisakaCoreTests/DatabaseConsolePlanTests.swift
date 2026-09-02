import XCTest
@testable import PisakaCore

/// The SQL console's pure vocabulary and its whole confirmation policy.
///
/// Every decision the console makes that is not SQLite's lives here, so it is
/// asserted directly: no connection, no model, no `await`. The cases that matter
/// most are the two halves of the horizon rule — a prepare failure after a
/// read-only prefix is the answer, the same failure after a write is merely
/// where classification stopped — because that pair is the difference between
/// refusing a correct migration script and running it.
final class DatabaseConsolePlanTests: XCTestCase {

    // MARK: - Helpers

    private func classification(
        _ kinds: [DatabaseConsoleStatementKind],
        deferredWith message: String? = nil
    ) -> DatabaseConsoleClassification {
        DatabaseConsoleClassification(
            kinds: kinds,
            deferral: message.map { DatabaseConsoleClassification.Deferral(index: kinds.count, message: $0) }
        )
    }

    // MARK: - The bookkeeping

    func testAnEmptyClassificationIsEmptyAndComplete() {
        let empty = DatabaseConsoleClassification()
        XCTAssertEqual(empty.classifiedCount, 0)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.isComplete)
        XCTAssertEqual(empty.writeCount, 0)
        XCTAssertFalse(empty.isMutating)
    }

    func testBookkeepingCountsKindsInStatementOrder() {
        let mixed = classification([.read, .write, .read, .write, .write])
        XCTAssertEqual(mixed.classifiedCount, 5)
        XCTAssertEqual(mixed.writeCount, 3)
        XCTAssertTrue(mixed.isMutating)
        XCTAssertTrue(mixed.isComplete)
        XCTAssertFalse(mixed.isEmpty)
        XCTAssertEqual(mixed.kinds, [.read, .write, .read, .write, .write])
    }

    func testAReadOnlyClassificationIsNotMutating() {
        let reads = classification([.read, .read])
        XCTAssertEqual(reads.writeCount, 0)
        XCTAssertFalse(reads.isMutating)
    }

    func testADeferralMakesTheClassificationIncompleteWithoutMakingItAFailure() {
        let deferred = classification([.read], deferredWith: "no such table: x")
        XCTAssertFalse(deferred.isComplete)
        XCTAssertEqual(deferred.classifiedCount, 1)
        XCTAssertEqual(deferred.deferral?.message, "no such table: x")
    }

    func testTheDeferralsIndexIsTheCountClassifiedRatherThanWhateverItWasHandedIn() {
        // Derived, never trusted: the statement that failed to prepare is the one
        // after the last one classified, so there is no second number that could
        // disagree with `classifiedCount`.
        let deferred = DatabaseConsoleClassification(
            kinds: [.read, .write],
            deferral: .init(index: 99, message: "no such column: b")
        )
        XCTAssertEqual(deferred.deferral?.index, 2)
        XCTAssertEqual(deferred.deferral?.index, deferred.classifiedCount)
    }

    func testADeferralAtIndexZeroCannotSitBesideAWriteBecauseNothingClassified() {
        // The shape the policy would otherwise have to reason about: a failure at
        // statement one *and* a write at statement one. It is unconstructible —
        // index 0 means `kinds` is empty, so there is no statement of any kind.
        let atZero = DatabaseConsoleClassification(deferral: .init(index: 0, message: "near \"slect\": syntax error"))
        XCTAssertEqual(atZero.deferral?.index, 0)
        XCTAssertTrue(atZero.isEmpty)
        XCTAssertEqual(atZero.writeCount, 0)
        XCTAssertFalse(atZero.isMutating)
    }

    func testANegativeDeferralIndexIsFlooredAtZero() {
        let deferral = DatabaseConsoleClassification.Deferral(index: -4, message: "boom")
        XCTAssertEqual(deferral.index, 0)
    }

    // MARK: - The policy's four answers

    func testEmptyAndCompleteIsNothingToRun() {
        XCTAssertEqual(DatabaseConsolePlan.decide(DatabaseConsoleClassification()), .nothingToRun)
    }

    func testACompleteReadOnlyTextIsRunStraightAway() {
        XCTAssertEqual(DatabaseConsolePlan.decide(classification([.read])), .read)
        XCTAssertEqual(DatabaseConsolePlan.decide(classification([.read, .read, .read])), .read)
    }

    func testACompleteWriteOnlyTextAsksForConfirmation() {
        guard case .confirmWrite(let prompt) = DatabaseConsolePlan.decide(classification([.write])) else {
            return XCTFail("A write must be confirmed")
        }
        XCTAssertFalse(prompt.isEmpty)
    }

    func testASingleWriteAmongReadsMakesTheWholeBatchMutating() {
        guard case .confirmWrite = DatabaseConsolePlan.decide(classification([.read, .read, .write, .read])) else {
            return XCTFail("One write anywhere makes the batch a mutation")
        }
    }

    func testASingleReadStatementIsARead() {
        XCTAssertEqual(DatabaseConsolePlan.decide(classification([.read])), .read)
    }

    func testAReadOnlyPrefixThenADeferralIsRefusedWithSQLitesExactMessage() {
        // The half of the horizon rule that ends the run: a read cannot have
        // created what the next statement needs, so the prepare failure is the
        // answer and nothing is run first.
        let decision = DatabaseConsolePlan.decide(classification([.read, .read], deferredWith: "no such table: x"))
        XCTAssertEqual(decision, .refuse(message: "no such table: x"))
    }

    func testAWritePrefixThenADeferralAsksRatherThanRefuses() {
        // The other half: `CREATE TABLE x(a); INSERT INTO x VALUES(1);` classifies
        // one statement and stops, and it is a perfectly correct script.
        guard case .confirmWrite = DatabaseConsolePlan.decide(classification([.write], deferredWith: "no such table: x")) else {
            return XCTFail("A classified write means the rest is classified as it runs")
        }
    }

    func testNothingClassifiedAtAllPlusADeferralIsRefused() {
        let decision = DatabaseConsolePlan.decide(
            classification([], deferredWith: "near \"slect\": syntax error")
        )
        XCTAssertEqual(decision, .refuse(message: "near \"slect\": syntax error"))
    }

    // MARK: - The confirmation prompt

    func testThePromptSaysHowManyStatementsAndHowManyOfThemWrite() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.write, .write, .read, .read]))
        XCTAssertTrue(prompt.hasPrefix("Classified 4 statements, 2 of which change the database."), prompt)
    }

    func testThePromptIsSingularForOneStatement() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.write]))
        XCTAssertTrue(prompt.hasPrefix("Classified 1 statement, which changes the database."), prompt)
        XCTAssertTrue(prompt.contains("It runs as one transaction: if it fails, the whole of it is rolled back."), prompt)
        XCTAssertFalse(prompt.contains("statements"), prompt)
    }

    func testThePromptSaysAllOfThemWhenEveryClassifiedStatementWrites() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.write, .write, .write]))
        XCTAssertTrue(prompt.hasPrefix("Classified 3 statements, all of which change the database."), prompt)
    }

    func testThePromptSaysOneOfWhichForASingleWriteAmongReads() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.read, .write]))
        XCTAssertTrue(prompt.hasPrefix("Classified 2 statements, 1 of which changes the database."), prompt)
    }

    func testThePromptAlwaysSaysTheBatchIsOneTransactionThatRollsBackWhole() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.write, .read]))
        XCTAssertTrue(
            prompt.contains("They run as one transaction: if any of them fails, the whole of it is rolled back."),
            prompt
        )
    }

    func testASingleDeferredStatementStillReadsAsPluralBecauseMoreFollowsIt() {
        let prompt = DatabaseConsolePlan.confirmationPrompt(for: classification([.write], deferredWith: "no such table: x"))
        XCTAssertTrue(
            prompt.contains("They run as one transaction: if any of them fails, the whole of it is rolled back."),
            prompt
        )
    }

    func testThePromptSaysTheRestIsClassifiedAsItRunsOnlyWhenDeferred() {
        let deferredSentence = "The rest of the text is classified as it runs, inside the same transaction, "
            + "so a failure there rolls everything back too."

        let deferred = DatabaseConsolePlan.confirmationPrompt(for: classification([.write], deferredWith: "no such table: x"))
        XCTAssertTrue(deferred.contains(deferredSentence), deferred)

        let complete = DatabaseConsolePlan.confirmationPrompt(for: classification([.write]))
        XCTAssertFalse(complete.contains(deferredSentence), complete)
    }

    func testThePromptSaysRowsAreNotShownOnlyWhenTheBatchAlsoHoldsARead() {
        let readsSentence = "Rows any query among them returns are not shown."

        let mixed = DatabaseConsolePlan.confirmationPrompt(for: classification([.read, .write]))
        XCTAssertTrue(mixed.contains(readsSentence), mixed)

        let writesOnly = DatabaseConsolePlan.confirmationPrompt(for: classification([.write, .write]))
        XCTAssertFalse(writesOnly.contains(readsSentence), writesOnly)
    }

    func testThePromptIsWhatTheDecisionCarries() {
        let mutating = classification([.read, .write], deferredWith: "no such table: x")
        XCTAssertEqual(
            DatabaseConsolePlan.decide(mutating),
            .confirmWrite(prompt: DatabaseConsolePlan.confirmationPrompt(for: mutating))
        )
    }

    // MARK: - The cap

    func testTheRowCapIsItsOwnStatedNumberAndNotThePageSize() {
        XCTAssertEqual(DatabaseConsolePlan.rowLimit, 500)
        XCTAssertNotEqual(DatabaseConsolePlan.rowLimit, DatabasePage.defaultSize)
    }

    // MARK: - The footers

    func testTheResultFooterCountsRows() {
        XCTAssertEqual(DatabaseConsolePlan.resultFooter(rowCount: 0, isTruncated: false), "No rows")
        XCTAssertEqual(DatabaseConsolePlan.resultFooter(rowCount: 1, isTruncated: false), "1 row")
        XCTAssertEqual(DatabaseConsolePlan.resultFooter(rowCount: 42, isTruncated: false), "42 rows")
    }

    func testATruncatedResultFooterSaysBothNumbers() {
        XCTAssertEqual(
            DatabaseConsolePlan.resultFooter(rowCount: DatabaseConsolePlan.rowLimit, isTruncated: true),
            "500 rows · first 500 rows shown"
        )
    }

    func testAnEmptyResultIsNeverReportedAsTruncated() {
        XCTAssertEqual(DatabaseConsolePlan.resultFooter(rowCount: 0, isTruncated: true), "No rows")
    }

    func testANegativeRowCountIsFlooredRatherThanPrinted() {
        XCTAssertEqual(DatabaseConsolePlan.resultFooter(rowCount: -3, isTruncated: false), "No rows")
    }

    func testTheAffectedRowsFooterCountsRows() {
        XCTAssertEqual(DatabaseConsolePlan.affectedRowsFooter(0), "No rows changed")
        XCTAssertEqual(DatabaseConsolePlan.affectedRowsFooter(1), "1 row changed")
        XCTAssertEqual(DatabaseConsolePlan.affectedRowsFooter(9), "9 rows changed")
        XCTAssertEqual(DatabaseConsolePlan.affectedRowsFooter(-1), "No rows changed")
    }

    // MARK: - The refusals the console owns

    func testTheConsolesOwnRefusalsAreStatedSentences() {
        XCTAssertFalse(DatabaseConsolePlan.gateBlockedMessage.isEmpty)
        XCTAssertFalse(DatabaseConsolePlan.runInFlightMessage.isEmpty)
        XCTAssertFalse(DatabaseConsolePlan.nothingToRunMessage.isEmpty)
        // Three distinct causes, so three distinct sentences: a reader who is told
        // the same thing for a checkout in flight and for an empty editor learns
        // nothing from either.
        XCTAssertEqual(
            Set([
                DatabaseConsolePlan.gateBlockedMessage,
                DatabaseConsolePlan.runInFlightMessage,
                DatabaseConsolePlan.nothingToRunMessage,
            ]).count,
            3
        )
    }
}
