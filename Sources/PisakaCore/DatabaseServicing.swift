import Foundation

/// A `DatabaseServicing` failure, carrying the library's own words.
///
/// Every case but `closed` holds a `message` that is the text SQLite produced,
/// **verbatim**. Nothing in this layer swallows, paraphrases or summarises a
/// failure: "file is not a database", "database is locked" and "no such column:
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
/// **Part 2 adds its members here**, defaulted the way `GitServicing`'s later
/// arrivals were: the transactional write with its affected-row check, and the
/// console's mutating-statement path. Nothing about the read-only surface needs
/// revisiting for them, which is why `DatabaseResultSet` already carries
/// `affectedRows`.
public protocol DatabaseServicing: Sendable {
    /// Open the database at `url` for this connection.
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
}

public extension DatabaseServicing {
    /// Defaulted so a stub that holds no resource — a fixed-answer fake in a test
    /// that never opens anything — need not implement it. The real service
    /// overrides it; so does `ScriptedDatabaseService`, which counts the calls.
    func close() async {}
}
