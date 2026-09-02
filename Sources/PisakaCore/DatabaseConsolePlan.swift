import Foundation

/// What one prepared statement of the console's text turns out to be.
///
/// SQLite's answer (`sqlite3_stmt_readonly`), carried across the seam unchanged
/// — never a judgement of ours. The library knows what every statement in every
/// version of its own grammar does, including the ones this app has never heard
/// of, and a classifier written here would be a second, worse opinion that
/// diverges the first time SQLite gains a keyword. Two cases because SQLite
/// answers one bit; there is no third.
public enum DatabaseConsoleStatementKind: String, Equatable, Hashable, Sendable, CaseIterable {
    /// SQLite reports the statement read-only. It runs on the tab's own
    /// read connection and needs no confirmation.
    case read
    /// SQLite reports the statement able to change the database. Its presence is
    /// what turns the whole text into a confirmed, transactional run.
    case write
}

/// What the console's text turned out to be — **as far as it could be read**.
///
/// Classification prepares the text statement by statement through the tail and
/// runs none of them, which is what makes "how many statements are here, and
/// which of them write" an answer rather than a guess. But preparing is not
/// free of the schema: SQLite resolves object names at *prepare* time against
/// the schema **as it stands now**, so a text whose later statements depend on
/// what its earlier ones create cannot be classified to the end.
/// `CREATE TABLE x(a); INSERT INTO x VALUES(1);` stops at the `INSERT` with
/// `no such table: x`; an `ALTER TABLE` followed by a statement naming the new
/// column stops the same way. Both scripts are perfectly correct and run fine
/// **in order** — refusing them because a look-ahead could not see through them
/// would be this layer inventing a failure the database never had.
///
/// So the horizon is part of the answer: `kinds` holds what was classified, in
/// statement order, and `deferral` — when it is there — says that the statement
/// at `classifiedCount` failed to prepare, carrying SQLite's verbatim message.
///
/// **A deferral is not an error by itself.** Whether it is depends entirely on
/// what came before it, which is `DatabaseConsolePlan.decide(_:)`'s decision and
/// not this type's: after a read-only prefix the failure is final (a read cannot
/// have created what the next statement needs), while after a write it is merely
/// the horizon, and the rest is classified as it runs inside the transaction.
///
/// A text that held **no statements at all** — blank, or only comments — is
/// empty and complete. That is a state, not a failure: nothing prepared because
/// there was nothing to prepare.
public struct DatabaseConsoleClassification: Equatable, Sendable {

    /// Where classification stopped, and what SQLite said when it did.
    public struct Deferral: Equatable, Sendable {
        /// The zero-based index of the statement that failed to prepare — which
        /// is always the count already classified, since classification stops at
        /// the first failure and never resumes past it.
        public let index: Int
        /// SQLite's own message from that prepare, verbatim. This is the
        /// sentence the reader is shown when the policy decides the failure is
        /// the answer, so nothing here paraphrases it.
        public let message: String

        public init(index: Int, message: String) {
            self.index = max(0, index)
            self.message = message
        }
    }

    /// What each statement is, in the order the text spells them, up to the
    /// horizon.
    public let kinds: [DatabaseConsoleStatementKind]

    /// The horizon, or `nil` when the whole text classified.
    ///
    /// Its `index` is **derived, never trusted**: the statement that failed to
    /// prepare is the one after the last one classified, so it is `kinds.count`
    /// and there is no second number that could disagree with it. That is also
    /// what makes "a deferral at index 0 alongside a write at index 0" not a
    /// case the policy has to handle — it cannot be constructed.
    public let deferral: Deferral?

    public init(kinds: [DatabaseConsoleStatementKind] = [], deferral: Deferral? = nil) {
        self.kinds = kinds
        self.deferral = deferral.map { Deferral(index: kinds.count, message: $0.message) }
    }

    /// How many statements were classified — never how many the text holds,
    /// which is unknowable past a deferral.
    public var classifiedCount: Int { kinds.count }

    /// Whether the whole text classified.
    public var isComplete: Bool { deferral == nil }

    /// Whether nothing classified at all. Together with `isComplete` this is the
    /// "there was nothing here" state; on its own it is also what a syntax error
    /// in the very first statement leaves behind.
    public var isEmpty: Bool { kinds.isEmpty }

    /// How many of the classified statements SQLite says can change the
    /// database.
    public var writeCount: Int { kinds.filter { $0 == .write }.count }

    /// Whether any classified statement writes — which is what makes the whole
    /// text a mutation to be confirmed, however many reads sit beside it.
    public var isMutating: Bool { writeCount > 0 }
}

/// The console's whole pure decision: what happens when Run is pressed, what the
/// reader is asked, what the footers say, and how far a read may go.
///
/// A caseless namespace rather than a value type, for the same reason
/// `DatabaseQuery` is one: nothing here has state. Every sentence the console
/// puts on screen that SQLite did not write is composed here and shown verbatim
/// by the pane, so the surface decides nothing and the wording is assertable
/// without a UI.
public enum DatabaseConsolePlan {

    /// What Run does with a classified text. Four answers, and no fifth.
    public enum Decision: Equatable, Sendable {
        /// The text held no statements. Nothing runs and nothing is asked.
        case nothingToRun
        /// Classification stopped, and nothing classified before it writes — so
        /// the prepare failure **is** the answer, carrying SQLite's message. A
        /// read cannot have created what the next statement needs, so running
        /// the prefix first would not change the outcome; it would only be a
        /// pointless read before the same refusal.
        case refuse(message: String)
        /// At least one classified statement writes. The reader is shown
        /// `prompt` and nothing is sent until they agree.
        case confirmWrite(prompt: String)
        /// A complete, non-empty, entirely read-only text. **This is the only
        /// answer that reaches the read member**, which is why that member never
        /// has to reason about a deferral.
        case read
    }

    /// Decide what Run does.
    ///
    /// The order of the three questions is the policy: a write anywhere in the
    /// classified prefix outranks a horizon (the batch is mutating and the rest
    /// is classified as it runs), a horizon with no write outranks emptiness (a
    /// syntax error at statement one classifies nothing, and is a refusal rather
    /// than "nothing to run"), and emptiness outranks the read path.
    public static func decide(_ classification: DatabaseConsoleClassification) -> Decision {
        if classification.isMutating {
            return .confirmWrite(prompt: confirmationPrompt(for: classification))
        }
        if let deferral = classification.deferral {
            return .refuse(message: deferral.message)
        }
        if classification.isEmpty {
            return .nothingToRun
        }
        return .read
    }

    // MARK: - What the reader is asked

    /// The heading over the confirmation — the question itself, in one short
    /// sentence.
    ///
    /// Composed here rather than in the pane for the pane's stated rule: it
    /// writes no English of its own beyond the labels on its controls. It exists
    /// because a dialog has two text slots and they are not interchangeable: the
    /// heading is drawn bold, centred and sized for a question, while the body is
    /// the slot a paragraph reads in. `confirmationPrompt(for:)` is a paragraph —
    /// four sentences at its longest — and put in the heading it is both the
    /// least readable place available and the one at risk of truncation, which
    /// would cut the transaction sentence's exception clause first: the tail of
    /// the paragraph, and the part the promise is only true with.
    public static let confirmationTitle = "Run this SQL?"

    /// The confirmation the reader answers before a mutating text runs.
    ///
    /// Composed here and shown verbatim by the pane. It says four things, and
    /// each of them is something the reader cannot see for themselves: how many
    /// statements were classified, how many of those change the database, what
    /// the one transaction the batch runs in does and does not guarantee, and —
    /// when classification stopped short — that the remainder is classified as it
    /// runs inside that same transaction, so a failure there takes everything
    /// with it. When the batch also holds a read it says the last thing too:
    /// rows a query inside a mutating batch produces are **not** shown, because
    /// the batch runs on the short-lived write connection and reports its
    /// affected-row total alone.
    ///
    /// **The transaction sentence carries its own exception**, because the
    /// promise is not unconditional and the reader is being asked to rely on it:
    /// the app half brackets the text in a `BEGIN IMMEDIATE` of its own, but the
    /// text is the reader's, and any statement in it that *ends* a transaction
    /// closes *that* bracket — after which every statement following runs in
    /// autocommit and is durable whatever fails later.
    ///
    /// **Ending it, not committing it**, which is the wider half and the easy one
    /// to state too narrowly: a `ROLLBACK` the text performs closes the bracket
    /// exactly as a `COMMIT` does, and while it undoes what was still pending, the
    /// statements after it commit themselves one by one — so
    /// `INSERT …; ROLLBACK; INSERT …; INSERT INTO missing …;` leaves the second
    /// insert durable even though the batch as a whole failed. A promise phrased
    /// around `COMMIT` alone would be a guarantee this layer cannot keep.
    ///
    /// Nothing here can tell whether the text holds either without parsing it,
    /// which decision 1 forbids and which `sqlite3_stmt_readonly` cannot answer
    /// either (it reports transaction control **read-only**, since neither
    /// changes rows itself). So the exception is stated rather than detected, and
    /// the outcome the reader is shown afterwards is honest about it
    /// independently — the app half counts committed and pending rows apart with
    /// its rollback witness, and `DatabaseConsoleModel` tells the write hook on
    /// the failure path for exactly this reason.
    ///
    /// Singular and plural are spelled out rather than dodged with "1
    /// statement(s)": this sentence is the one moment the reader is asked to
    /// take responsibility for a write, and it should read like a sentence.
    public static func confirmationPrompt(for classification: DatabaseConsoleClassification) -> String {
        var sentences = [
            "Classified \(statementsPhrase(classification.classifiedCount)), \(writesClause(classification)).",
            transactionSentence(classification),
        ]
        if !classification.isComplete {
            sentences.append(
                "The rest of the text is classified as it runs, inside the same transaction, "
                + "so a failure there is rolled back the same way."
            )
        }
        if classification.writeCount < classification.classifiedCount {
            sentences.append("Rows any query among them returns are not shown.")
        }
        return sentences.joined(separator: " ")
    }

    private static func statementsPhrase(_ count: Int) -> String {
        count == 1 ? "1 statement" : "\(count) statements"
    }

    private static func writesClause(_ classification: DatabaseConsoleClassification) -> String {
        let writes = classification.writeCount
        guard writes < classification.classifiedCount else {
            return classification.classifiedCount == 1
                ? "which changes the database"
                : "all of which change the database"
        }
        return writes == 1
            ? "1 of which changes the database"
            : "\(writes) of which change the database"
    }

    private static func transactionSentence(_ classification: DatabaseConsoleClassification) -> String {
        // One statement that is also the whole text is the only case that reads
        // as "it"; a deferred single statement is not, because more of the text
        // follows it into the same transaction.
        //
        // It is also the only case that can promise the rollback **without** the
        // exception: this sentence is composed for a mutating batch, so the one
        // classified statement is the write itself, and a text of one statement
        // has no room for a `COMMIT` or a `ROLLBACK` beside it. Every other shape
        // does — the deferred single statement included, which is why it takes
        // the plural sentence here as well as for its grammar.
        guard classification.classifiedCount == 1, classification.isComplete else {
            return "They run as one transaction: if any of them fails, the whole of it is rolled back — "
                + "unless the text ends that transaction itself, with a commit or a rollback of its own, "
                + "after which what it already committed, and everything running past that point, stays."
        }
        return "It runs as one transaction: if it fails, the whole of it is rolled back."
    }

    // MARK: - How far a read goes

    /// The most rows one console read answers.
    ///
    /// **Its own number, deliberately not `DatabasePage.defaultSize`.** The grid
    /// pages because a page is something the reader can turn: 200 rows is a
    /// position in a table, and the next 200 are one click away. A console
    /// result is not paged — the reader's text is theirs, and appending a
    /// `LIMIT`/`OFFSET` to it would be this layer rewriting SQL it promised to
    /// carry verbatim — so this number is a *cap*, the point past which rows are
    /// dropped and the footer says so. A cap and a page size answer different
    /// questions, and tying them together would mean a change to either silently
    /// moved the other.
    ///
    /// 500 because a result that large is already past reading and is on its way
    /// to being a query the reader should narrow, while still being generous
    /// enough that ordinary exploratory queries are never truncated at all.
    /// Enforced by the app half, which steps at most this many rows and then one
    /// row further to learn whether more remained.
    public static let rowLimit = 500

    // MARK: - What the footers say

    /// The footer under a console read's result table.
    ///
    /// `rowCount` is what actually arrived — never the cap, and never what the
    /// query would have answered, which is a number nobody here knows. A
    /// truncated result therefore says the one number it has and then the one
    /// fact the number alone does not carry: that the query had more to say.
    /// Repeating the same count in both halves would read as a rendering fault
    /// and would state nothing twice.
    public static func resultFooter(rowCount: Int, isTruncated: Bool) -> String {
        let rows = max(0, rowCount)
        guard rows > 0 else { return "No rows" }
        let counted = rows == 1 ? "1 row" : "\(rows) rows"
        guard isTruncated else { return counted }
        return "\(counted) shown · more rows remain"
    }

    /// The footer after a committed console mutation.
    ///
    /// The affected-row total is the *whole* report: a mutating batch shows no
    /// rows, so this number is the only thing the reader learns about what
    /// happened, and "No rows changed" after a committed transaction is a real
    /// and honest outcome (a `DELETE` that matched nothing, a `CREATE TABLE`)
    /// rather than the failure the same count means for a cell edit.
    public static func affectedRowsFooter(_ affectedRows: Int) -> String {
        let rows = max(0, affectedRows)
        guard rows > 0 else { return "No rows changed" }
        return rows == 1 ? "1 row changed" : "\(rows) rows changed"
    }

    // MARK: - The refusals the console owns

    /// Refused because a worktree-mutating operation is in flight.
    ///
    /// One of the three sentences here that SQLite has no words for, because
    /// SQLite never saw the attempt: the disk-writer gate is this app's, and a
    /// console mutation asks it immediately before sending — a checkout may be
    /// replacing this very file.
    public static let gateBlockedMessage =
        "The project is being changed on disk right now, so this database cannot be written to. "
        + "Try again when that finishes."

    /// Refused because this tab already has a write in flight — the console's
    /// own, or the grid's cell edit. One write per tab, so the two share the
    /// refusal rather than each claiming the file is free.
    public static let runInFlightMessage =
        "A change to this database is already being written. Wait for it to finish and try again."

    /// Said when Run is pressed on a text that holds no statements at all.
    /// A state and not a failure, but one worth saying: pressing Run and seeing
    /// nothing move is otherwise indistinguishable from a console that broke.
    public static let nothingToRunMessage = "There is no statement to run."
}
