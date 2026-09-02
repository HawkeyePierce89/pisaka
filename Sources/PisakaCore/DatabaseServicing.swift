import Foundation

/// A `DatabaseServicing` failure, carrying the library's own words.
///
/// Every case but `closed` holds a `message` that is the text SQLite produced,
/// **verbatim** — with one stated exception: `sqlError` is also what an
/// implementation refuses with when it is handed a parameter it cannot bind
/// faithfully (a `DatabaseValue.blob`, which carries a length and no bytes), a
/// failure SQLite never sees and therefore has no words for. Nothing in this
/// layer swallows, paraphrases or summarises a failure: "file is not a database", "database is locked" and "no such column:
/// foo" each name precisely what went wrong and what to do about it, and any
/// sentence this app writes instead would be a worse one. The cases exist only
/// so the viewer can tell the three it reacts to differently apart from a
/// generic SQL error — not so the message can be dropped.
///
/// Lives in Core, like `GitError`, so the human-readable `errorDescription` the
/// viewer publishes is unit-testable without linking SQLite.
public enum DatabaseError: Error, Equatable, Sendable {
    /// The file could not be opened at all — missing, unreadable, or a directory.
    case cannotOpen(message: String)
    /// The file opened but does not hold a database (SQLite reports this only
    /// when the header is first read, which is why it is not `cannotOpen`).
    case notADatabase(message: String)
    /// Another writer holds the database and the busy timeout expired.
    case busy(message: String)
    /// A statement failed to prepare, bind or step.
    case sqlError(message: String)
    /// A statement was run against a connection that is not open — either never
    /// opened, or closed while the work was in flight. Ours, not the library's,
    /// so it carries no message of SQLite's to quote.
    case closed
}

extension DatabaseError: LocalizedError {
    /// What the failure says, which for four of the five cases is what SQLite
    /// said. Without this the viewer's `error.localizedDescription` would fall
    /// back to "operation couldn't be completed (PisakaCore.DatabaseError error
    /// N)" and throw away the only sentence that explains anything.
    public var errorDescription: String? { message }

    /// The failure's text.
    public var message: String {
        switch self {
        case .cannotOpen(let message),
             .notADatabase(let message),
             .busy(let message),
             .sqlError(let message):
            return message
        case .closed:
            return "The database connection is closed."
        }
    }
}

/// One write, whole: the file it runs against, the statements it is made of, and
/// the number of rows it is only allowed to commit if it changed.
///
/// **The affected-row rule travels as data because rollback has to happen inside
/// the connection's life.** Core cannot decide "commit or roll back" after the
/// fact — by the time an outcome reached it the connection would already be
/// gone, and re-opening one to undo a write is a second write with its own
/// failure modes. So the rule is composed here, handed across the seam, and
/// enforced by the app half at the one moment it can be: with the transaction
/// still open. The app half compares two numbers; it decides nothing else, and
/// what the answer *means* is read back in Core.
///
/// **The URL is carried explicitly rather than inherited from the read
/// connection**: a viewer tab outlives the path it was opened at — a rename
/// retargets it and `reload(at:)` follows — so the model's current `fileURL` is
/// the one thing that is true at the moment the write is composed. It is also
/// what lets the write be a *separate, short-lived* read-write connection while
/// the tab's own connection stays read-only.
///
/// `statements` are run in the order given, inside the transaction the
/// implementation opens; `DatabaseQuery.beginImmediate`, `.commit` and
/// `.rollback` are not among them, because those are the implementation's own
/// bracket rather than the plan's content.
public struct DatabaseWriteTransaction: Equatable, Sendable {
    /// The database to open read-write for this transaction.
    public var url: URL
    /// The statements to run, in order, inside the transaction.
    public var statements: [DatabaseStatement]
    /// The accumulated affected-row count that permits a commit. Any other total
    /// — smaller or larger — is a rollback.
    public var requiredAffectedRows: Int

    public init(url: URL, statements: [DatabaseStatement], requiredAffectedRows: Int) {
        self.url = url
        self.statements = statements
        self.requiredAffectedRows = requiredAffectedRows
    }
}

/// What a write did: how many rows it changed, and whether that was allowed to
/// stand.
///
/// Two numbers and no sentence, on purpose. A count of zero means the row the
/// `WHERE` named is no longer there in the shape it was addressed by — someone
/// else changed it — and a count above the required one means the identity was
/// not unique after all; both are *rolled back*, and both deserve to be said
/// differently to the reader. Which sentence each gets is Core's call
/// (`DatabaseViewerModel`), not the connection's, so nothing here is phrased.
public struct DatabaseWriteOutcome: Equatable, Sendable {
    /// The rows the statements changed in total, whether or not it committed.
    public var affectedRows: Int
    /// Whether the transaction committed. `false` means it was rolled back and
    /// the file is untouched.
    public var isCommitted: Bool

    public init(affectedRows: Int, isCommitted: Bool) {
        self.affectedRows = affectedRows
        self.isCommitted = isCommitted
    }
}

/// What a console read answered.
///
/// **The last statement in the reader's text that produced columns**, and only
/// that one. A console text may hold several statements and they all run, in
/// order, on the tab's read connection — but a result *table* can show one
/// answer, and the last one is the one the reader was building towards
/// (`SELECT` after a `PRAGMA`, a query after the `EXPLAIN` that set it up). A
/// statement answering no columns at all contributes nothing here and is not a
/// failure: it ran, it said nothing, and an earlier answer stands.
///
/// `isTruncated` is **that same statement's**, never the batch's: it says the
/// cap was reached and rows past it were dropped, which the app half learns by
/// stepping one row further than the cap it was given.
///
/// A text whose statements all answered no columns leaves an empty
/// `columnNames` and no rows — the honest "it ran and said nothing" state, which
/// `DatabaseConsolePlan.resultFooter(rowCount:isTruncated:)` words as "No rows".
public struct DatabaseConsoleAnswer: Equatable, Sendable {
    /// The result columns in order, named as the statement declared them.
    public var columnNames: [String]
    /// The rows, each holding exactly `columnNames.count` values.
    public var rows: [[DatabaseValue]]
    /// Whether the cap was reached and rows past it dropped.
    public var isTruncated: Bool

    public init(columnNames: [String] = [], rows: [[DatabaseValue]] = [], isTruncated: Bool = false) {
        self.columnNames = columnNames
        self.rows = rows
        self.isTruncated = isTruncated
    }
}

/// One console mutation, whole: the file, the reader's text **verbatim**, and
/// how far a read-only statement inside it may be stepped.
///
/// The counterpart of `DatabaseWriteTransaction` and deliberately not the same
/// type, for two reasons that are each sufficient. The first is the count:
/// a cell edit commits only when it changed exactly the number of rows Core
/// required, while a console batch is the reader's own text and commits at
/// whatever total it reaches — "no rows changed" is a real outcome for a
/// `DELETE` that matched nothing or a `CREATE TABLE`, not the collision it means
/// for a cell edit. The second is the shape: this carries **one string**, not a
/// list of statements, because SQLite prepares one statement at a time and the
/// statements after the first cannot be prepared until the ones before them have
/// *run* — which is the whole reason a migration-shaped text classifies only as
/// far as its first unresolvable name.
///
/// The URL is carried explicitly for `DatabaseWriteTransaction`'s reason: a
/// viewer tab outlives the path it was opened at, and this is what lets the
/// batch run on a separate, short-lived read-write connection while the tab's
/// own stays read-only.
public struct DatabaseConsoleTransaction: Equatable, Sendable {
    /// The database to open read-write for this transaction.
    public var url: URL
    /// The reader's text, exactly as they typed it. Nothing appends to it,
    /// re-splits it or re-spells it anywhere on this path.
    public var text: String
    /// How far a statement SQLite reports **read-only** may be stepped before it
    /// is abandoned and its rows discarded.
    ///
    /// A mutating batch reports its affected-row total and shows no rows, so a
    /// query inside one is stepped only because a statement that is never
    /// stepped never runs — and a `SELECT` over a large table would otherwise
    /// walk it for nothing. **A statement that is not read-only is always
    /// stepped to completion**, whatever this says: abandoning one half-performs
    /// it, and `INSERT … RETURNING` — which answers columns *and* writes — is
    /// the case that makes the distinction necessary rather than tidy.
    public var readRowLimit: Int

    public init(url: URL, text: String, readRowLimit: Int) {
        self.url = url
        self.text = text
        self.readRowLimit = readRowLimit
    }
}

/// The whole app/Core boundary of the database viewer: open a file, run
/// statements, close.
///
/// The same split `LeetCodeTransport`, `LSPTransport` and `GitServicing` already
/// make, for the same reason. Core composes **every byte of SQL** and every bound
/// value (`DatabaseQuery` is the only thing in the repository that writes SQL),
/// decides what an answer means (`DatabaseSchema`, `DatabasePage`) and how a
/// value is rendered (`DatabaseValue`). The app half owns the C API — one
/// connection, prepare/bind/step/finalize — and knows nothing about what any of
/// it means: it is handed a string and a list of values and hands back columns
/// and rows. That is what keeps the decidable half testable behind
/// `ScriptedDatabaseService` in a target that must not link SQLite.
///
/// A connection is **one file**: `open(url:)` is called once per instance and
/// `close()` ends it. An implementation is free to serialize its work (the real
/// one is an `actor`), and `close()` must be safe to call twice — the tab owner
/// closes on tab close and again at termination rather than tracking which
/// already happened.
///
/// **The write half arrives here defaulted**, the way `GitServicing`'s later
/// members did: `performWrite(_:)` is the transactional write with its
/// affected-row check, and every conformer that has no write connection — a
/// fixed-answer stub in a test, a future read-only adapter — inherits an honest
/// refusal rather than a compile error. Nothing about the read-only surface
/// needed revisiting for it, which is why `DatabaseResultSet` already carries
/// `affectedRows`.
///
/// **The console's three members arrive the same way, and change none of the
/// four above.** `performWrite(_:)` and `DatabaseWriteOutcome` are untouched by
/// part 2b: the cell edit's exact-count rule — commit only when the total equals
/// `requiredAffectedRows` — stands byte for byte, and the console runs through
/// `performConsoleWrite(_:)` instead, which has a different count rule and
/// carries a string rather than a statement list. Two members, two rules, no
/// shared trap: a multi-statement text sent through `performWrite(_:)` would
/// silently run only its first statement, because that path prepares each
/// `DatabaseStatement` with a nil tail pointer, which is exactly right for the
/// single statement `DatabaseQuery` composes and exactly wrong for the reader's
/// text.
///
/// **Four rules the app half owes the console**, none of which Core can enforce
/// from this side:
///
/// 1. The reader's **text is carried verbatim** — never re-split, re-spelled or
///    appended to. This is the *one stated exception* to "Core composes every
///    byte of SQL": `DatabaseQuery` is still the only thing in the repository
///    that *writes* SQL, and the console's SQL is not written by anyone here —
///    it is the reader's, passed through. No `LIMIT` is ever appended to it; the
///    cap is enforced by stepping, which is why it travels as a number.
/// 2. `classifyConsole(_:)` **does not throw on a prepare failure.** It returns
///    what it classified plus a `DatabaseConsoleClassification.Deferral`
///    carrying SQLite's verbatim message, because whether that failure is fatal
///    depends on what came before it — a read-only prefix makes it the answer, a
///    writing prefix makes it merely the horizon — and that is
///    `DatabaseConsolePlan.decide(_:)`'s decision, not the seam's. It throws
///    only for a failure that is not about the text at all: no connection, and
///    the like.
/// 3. The read run **steps only statements SQLite itself reports read-only**,
///    and refuses any other rather than writing through the read path. It is
///    only ever handed a fully classified read-only text, so this is belt and
///    braces against a text whose meaning changed between the classification and
///    the run.
/// 4. A console run **leaves the connection in autocommit.** A statement that
///    opened a transaction of its own is rolled back before the member returns,
///    so a stray `BEGIN` in the console cannot freeze the tab's read snapshot for
///    the life of the tab.
public protocol DatabaseServicing: Sendable {
    /// Open the database at `url` for this connection.
    ///
    /// **A second open must be harmless.** One is called for per instance, but
    /// two loads racing each other can both find the connection unopened and both
    /// ask — so an implementation holding a handle already answers without
    /// opening a second one (which is also what keeps the first from leaking)
    /// rather than throwing at a caller that did nothing wrong.
    ///
    /// - Throws: `DatabaseError.cannotOpen` when the file cannot be opened, and
    ///   `DatabaseError.notADatabase` when it opened but holds something else.
    ///   Which of the two arrives is SQLite's judgement, not this layer's: the
    ///   header is not read until the first statement runs, so a file that is not
    ///   a database may well open here and fail later.
    func open(url: URL) async throws

    /// Run `statement` and return what it answered.
    ///
    /// - Throws: `DatabaseError.closed` when no connection is open, `.busy` when
    ///   the busy timeout expired, and `.sqlError` carrying SQLite's message for
    ///   anything else.
    func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet

    /// Release the connection. Safe to call on an instance that never opened one,
    /// and safe to call twice.
    func close() async

    /// Run `transaction` on a **separate, short-lived read-write connection** and
    /// answer what it did.
    ///
    /// Deliberately not routed through this instance's connection: the viewer's
    /// own is opened read-only and stays that way, and the write is opened at the
    /// transaction's own `url`, run and closed before this returns — which is
    /// also why termination's best-effort `closeAll()` remains correct, since a
    /// viewer tab never holds unflushed write state.
    ///
    /// An implementation opens read-write (never creating), brackets the
    /// statements in `DatabaseQuery.beginImmediate` … `.commit`/`.rollback`,
    /// accumulates each statement's `affectedRows`, commits **only** when the
    /// total equals `transaction.requiredAffectedRows`, rolls back on every other
    /// path including a throw, and closes on all of them.
    ///
    /// - Throws: the same `DatabaseError` cases the read path throws, carrying
    ///   SQLite's own words — `.cannotOpen` when the file cannot be opened
    ///   read-write, `.busy` when the write lock could not be taken inside the
    ///   busy timeout, `.sqlError` for anything a statement failed at.
    func performWrite(_ transaction: DatabaseWriteTransaction) async throws -> DatabaseWriteOutcome

    /// Read `text` statement by statement through the tail and answer what each
    /// one is — **running none of them**.
    ///
    /// Preparing a statement resolves its names and decides its kind without
    /// executing anything, and preparing a *mutating* statement on a read-only
    /// connection succeeds (SQLite refuses at step time, not at prepare time),
    /// which is what makes this free and side-effect-free on the tab's own
    /// connection. Each statement's kind is `sqlite3_stmt_readonly`'s answer,
    /// carried across unchanged.
    ///
    /// - Returns: the kinds in statement order, plus the deferral when a prepare
    ///   failed — see rule 2 above: **a prepare failure is returned, not
    ///   thrown**.
    /// - Throws: `DatabaseError.closed` when no connection is open, and the
    ///   other cases only for a failure that is not about the text.
    func classifyConsole(_ text: String) async throws -> DatabaseConsoleClassification

    /// Run a fully classified, entirely read-only `text` in order on this
    /// connection and answer the last statement that produced columns.
    ///
    /// `rowLimit` caps the rows kept — `DatabaseConsolePlan.rowLimit`, which the
    /// implementation enforces by stepping at most that many rows and then one
    /// row further to learn whether more remained. Nothing is appended to the
    /// text to achieve it.
    ///
    /// - Throws: `DatabaseError.closed` when no connection is open, `.busy` when
    ///   the busy timeout expired, and `.sqlError` carrying SQLite's message for
    ///   anything else — including a statement this path refuses to step because
    ///   SQLite does not report it read-only (rule 3).
    func runConsoleRead(_ text: String, rowLimit: Int) async throws -> DatabaseConsoleAnswer

    /// Run `transaction.text` **whole, as one transaction**, on a separate,
    /// short-lived read-write connection and answer what it changed.
    ///
    /// The console's counterpart to `performWrite(_:)` and deliberately not it:
    /// each statement is prepared **as it is reached**, after the statements
    /// before it have run, which is the only way a text whose later statements
    /// depend on what its earlier ones create can run at all — and it is why
    /// classification stopping short is not a refusal. A prepare failure here is
    /// therefore an ordinary failure that rolls the whole batch back.
    ///
    /// **The count rule is not the cell edit's**: this commits on success at
    /// whatever total it reached, because the text is the reader's and "no rows
    /// changed" is a real outcome for a `DELETE` that matched nothing or a
    /// `CREATE TABLE`. A step or prepare failure anywhere rolls everything back.
    ///
    /// **A text that rolls itself back answers `isCommitted: false`**, and it is
    /// the one outcome here that is neither a failure nor a change: a `ROLLBACK`
    /// the reader typed as the last thing in the text, with nothing committed
    /// anywhere in it, leaves the file untouched and must be said so rather than
    /// reported as a batch that changed the rows it undid. Anything the text
    /// rolled back stops counting towards `affectedRows`; anything that ran after
    /// a rollback still counts.
    ///
    /// - Throws: the same `DatabaseError` cases `performWrite(_:)` throws,
    ///   carrying SQLite's own words.
    func performConsoleWrite(_ transaction: DatabaseConsoleTransaction) async throws -> DatabaseWriteOutcome
}

public extension DatabaseServicing {
    /// Defaulted so a stub that holds no resource — a fixed-answer fake in a test
    /// that never opens anything — need not implement it. The real service
    /// overrides it; so does `ScriptedDatabaseService`, which counts the calls.
    func close() async {}

    /// Defaulted to an honest refusal rather than to a silent no-op: a conformer
    /// that has no write half is *read-only*, and a caller that asks it to write
    /// must hear so. Answering `DatabaseWriteOutcome(affectedRows: 0,
    /// isCommitted: false)` instead would be indistinguishable from "the row
    /// changed underneath you" — the model would tell the reader their edit
    /// collided with someone else's, about a connection that was never going to
    /// write anything.
    ///
    /// `sqlError` because it is the case that carries a message and SQLite has no
    /// words for a failure it never saw — the same reason a blob parameter that
    /// cannot be bound faithfully refuses through it.
    func performWrite(_ transaction: DatabaseWriteTransaction) async throws -> DatabaseWriteOutcome {
        throw DatabaseError.sqlError(message: readOnlyRefusal)
    }

    /// Defaulted for `performWrite(_:)`'s reason, and refusing with the same
    /// sentence: a conformer with no console half cannot classify anything, and
    /// answering an empty classification instead would read to the policy as
    /// "this text holds no statements" — the console would say there was nothing
    /// to run about a text full of them.
    ///
    /// The refusal is **thrown, not deferred**: a deferral says SQLite failed to
    /// prepare a statement and carries its words, and there is no connection here
    /// that ever saw one.
    func classifyConsole(_ text: String) async throws -> DatabaseConsoleClassification {
        throw DatabaseError.sqlError(message: consoleRefusal)
    }

    /// Defaulted to the same honest refusal. Answering an empty
    /// `DatabaseConsoleAnswer` would be indistinguishable from a query that
    /// matched nothing.
    func runConsoleRead(_ text: String, rowLimit: Int) async throws -> DatabaseConsoleAnswer {
        throw DatabaseError.sqlError(message: consoleRefusal)
    }

    /// Defaulted to `performWrite(_:)`'s refusal, for `performWrite(_:)`'s
    /// reason: a rolled-back zero-row outcome would tell the reader their batch
    /// ran and changed nothing, about a connection that was never going to write.
    func performConsoleWrite(_ transaction: DatabaseConsoleTransaction) async throws -> DatabaseWriteOutcome {
        throw DatabaseError.sqlError(message: readOnlyRefusal)
    }
}

/// What a conformer with no write connection says when asked to write. One
/// sentence, shared by both write members, because the reader is being told the
/// same thing.
private let readOnlyRefusal = "This database connection is read-only."

/// What a conformer with no console half says. Its own sentence: classification
/// and a console read are not writes, so "read-only" would be an answer to a
/// question nobody asked.
private let consoleRefusal = "This database connection has no SQL console."
