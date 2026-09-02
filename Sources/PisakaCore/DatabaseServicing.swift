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
/// `affectedRows`. Part 2b's console is written against this same member.
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
        throw DatabaseError.sqlError(message: "This database connection is read-only.")
    }
}
