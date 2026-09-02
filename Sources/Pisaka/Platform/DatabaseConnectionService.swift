#if os(macOS)
import Foundation
import PisakaCore
import SQLite3

/// The app half of `DatabaseServicing`: one SQLite connection, and nothing that
/// knows what any of it means.
///
/// **The only file in the repository that imports the system SQLite module**, and
/// `DatabaseViewerSourceGatingTests` pins that. It is the `GitCLIService` /
/// `LSPProcessTransport` position one level down: Core composes every byte of SQL
/// (`DatabaseQuery`) and reads every answer (`DatabaseSchema`, `DatabaseValue`),
/// while this hands the text to `sqlite3_prepare_v2`, binds a list of values it
/// never inspects, and hands back columns and rows. Nothing here decides
/// anything, which is what keeps the decidable half testable behind
/// `ScriptedDatabaseService` in a target that must not link SQLite.
///
/// An `actor` rather than a lock: a `sqlite3 *` opened without
/// `SQLITE_OPEN_FULLMUTEX` is not safe on two threads, and the model can have a
/// page load and a listing refresh in flight at once. Serializing them on the
/// actor is the cheapest correct answer and needs no queue of its own.
///
/// **Every failure carries SQLite's own sentence.** `sqlite3_errmsg` says "file
/// is not a database", "database is locked", "no such column: foo"; each names
/// what went wrong better than any sentence written here would, so the message
/// travels verbatim inside a `DatabaseError` and this layer swallows nothing.
actor DatabaseConnectionService: DatabaseServicing {

    /// How long a statement waits for another writer before reporting `.busy`.
    ///
    /// Set immediately after the open, before any statement can run, which is the
    /// whole point: without it SQLite returns `SQLITE_BUSY` the instant a lock is
    /// contended, and a viewer opened over a database another process is writing
    /// would flash an error rather than wait the moment out. Five seconds is long
    /// enough to ride out an ordinary transaction and short enough that a *held*
    /// lock reports rather than hangs the tab forever.
    private static let busyTimeoutMilliseconds: Int32 = 5_000

    /// SQLite's marker for "copy this buffer, I may free it" — what a bound text
    /// value uses, because the Swift array backing it dies at the end of the call
    /// and `SQLITE_STATIC` would leave the statement pointing at freed memory.
    /// (A bound blob carries no buffer at all; see the `.blob` case in `bind`.)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The open connection, or `nil` before `open(url:)` and after `close()`.
    private var handle: OpaquePointer?

    // MARK: - DatabaseServicing

    func open(url: URL) async throws {
        // A second open on the same instance would leak the first handle. A
        // connection is one file (the seam says so), so the tab owner makes one
        // service per tab and this never legitimately happens.
        if handle != nil { return }

        var connection: OpaquePointer?
        // Read-only, because part 1's viewer is one, and deliberately without
        // `SQLITE_OPEN_CREATE`: the file was probed into existence by
        // `WorkspaceModel.open(url:)`, and a typo that reached here must report
        // rather than quietly conjure an empty database.
        //
        // The flag is load-bearing, not decorative. A read-*write* handle is not
        // a reader at the file level: closing the last connection to a WAL
        // database checkpoints it and deletes the `-wal`/`-shm` sidecars, which
        // rewrites the tracked `.db` file — so merely opening and closing a
        // viewer tab would show the file as modified in Local Changes, with no
        // writer gate held and no user action that asked for a write. It also
        // takes write locks that contend with whatever else has the database
        // open. A read-only connection can do neither. **Part 2's write path did
        // not change this**: a cell update opens its own short-lived read-write
        // connection in `performWrite(_:)` below, runs its transaction and closes
        // it, so the tab's own connection stays a reader for its whole life and a
        // tab nobody edited still never touches the file.
        let code = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard code == SQLITE_OK, let connection else {
            // The handle is usually non-nil even on failure, and it is the only
            // thing that knows *why*; `sqlite3_errstr` is the fallback for the
            // out-of-memory case where there is no handle at all.
            let message = connection.map { Self.message(from: $0) } ?? Self.message(for: code)
            sqlite3_close_v2(connection)
            throw Self.openError(code: code, message: message)
        }
        sqlite3_busy_timeout(connection, Self.busyTimeoutMilliseconds)
        handle = connection
    }

    func run(_ statement: DatabaseStatement) async throws -> DatabaseResultSet {
        guard let handle else { throw DatabaseError.closed }
        return try execute(statement, on: handle)
    }

    /// Prepare, bind, step and read `statement` on `handle`.
    ///
    /// Split out of `run(_:)` because the write path runs the *same* mechanics on
    /// a different connection: `performWrite(_:)` opens one of its own, and every
    /// statement inside its transaction — the bracket included — goes through
    /// here. One prepare/bind/step is one implementation, or the two connections
    /// would eventually disagree about what binding a text value or reading a
    /// blob means.
    private func execute(
        _ statement: DatabaseStatement,
        on handle: OpaquePointer
    ) throws -> DatabaseResultSet {
        var prepared: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(handle, statement.sql, -1, &prepared, nil)
        guard prepareCode == SQLITE_OK, let prepared else {
            let message = Self.message(from: handle)
            sqlite3_finalize(prepared)
            throw Self.error(code: prepareCode, message: message)
        }
        // Every exit from here on releases the statement — including the throwing
        // ones, which is the leak `defer` exists to make impossible.
        defer { sqlite3_finalize(prepared) }

        try bind(statement.parameters, to: prepared, on: handle)

        let columnNames = (0..<sqlite3_column_count(prepared)).map { index in
            sqlite3_column_name(prepared, index).map { String(cString: $0) } ?? ""
        }

        var rows: [[DatabaseValue]] = []
        while true {
            let stepCode = sqlite3_step(prepared)
            if stepCode == SQLITE_ROW {
                rows.append(columnNames.indices.map { value(of: prepared, at: Int32($0)) })
                continue
            }
            if stepCode == SQLITE_DONE { break }
            throw Self.error(code: stepCode, message: Self.message(from: handle))
        }

        // `sqlite3_changes` reports the last modification on the *connection*, not
        // on this statement, and a `SELECT` does not reset it — so asking it after
        // a read would answer with whatever the previous write did. The seam
        // promises zero for a read, and `sqlite3_stmt_readonly` is what makes that
        // promise true: part 1 sends nothing else, and part 2's write path would
        // otherwise read a stale count as its "exactly one row touched" check.
        let affectedRows = sqlite3_stmt_readonly(prepared) != 0 ? 0 : Int(sqlite3_changes(handle))

        return DatabaseResultSet(
            columnNames: columnNames,
            rows: rows,
            affectedRows: affectedRows
        )
    }

    /// The backstop for a connection nobody closed.
    ///
    /// `close()` is the normal path and the tab owner drives it, but it is
    /// `async`, so every route to it is a `Task` hop that a torn-down owner — or a
    /// process on its way out — may never run. Releasing the handle here costs
    /// nothing when `close()` already did (it nils the handle first) and is the
    /// only thing standing between a dropped service and a leaked `sqlite3 *`
    /// with its file descriptor.
    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() async {
        // Idempotent by construction: the tab owner closes on tab close and again
        // at termination rather than tracking which already happened, and the
        // seam promises a second call is safe.
        guard let handle else { return }
        self.handle = nil
        // `_v2` rather than `sqlite3_close`: it defers the release if anything is
        // somehow still unfinalized instead of returning `SQLITE_BUSY` and
        // leaving the connection open forever.
        sqlite3_close_v2(handle)
    }

    // MARK: - Writing

    /// Run `transaction` on a **connection of its own**, opened read-write at the
    /// transaction's url, and closed before this returns.
    ///
    /// Not on `handle`, and this is the point of the member rather than an
    /// implementation detail. The tab's connection is opened `SQLITE_OPEN_READONLY`
    /// and stays that way for its whole life, so a tab nobody edited never takes a
    /// write lock at all; a write that is *asked for* holds one, for as long as it
    /// takes to run, and no longer. What closing this connection does **not** do
    /// is tidy a WAL database up: SQLite checkpoints and unlinks the `-wal`/`-shm`
    /// sidecars only on the close of the *last* connection to the database, and
    /// the tab's read-only one is still open — and could not do it either, since a
    /// read-only handle cannot checkpoint. On a WAL database the sidecars
    /// therefore outlive the edit. What must **not** outlive it is the edit's
    /// absence from the file itself, which is why a commit is followed here by
    /// `DatabaseQuery.walCheckpoint`: sidecars staying beside the database is
    /// untidy, whereas the tracked bytes not moving would make Local Changes,
    /// `git commit` and the only undo the viewer offers all miss the edit.
    /// The url is the transaction's own because a viewer tab
    /// outlives the path it was opened at — a rename retargets it — and Core's
    /// `fileURL` is the one thing that is current.
    ///
    /// **No `SQLITE_OPEN_CREATE`**, for the read path's reason and one more: a
    /// database that has been moved away since the page was read must report, not
    /// be conjured empty and then written into.
    ///
    /// The affected-row rule is enforced here because this is the only place it
    /// *can* be — with the transaction still open. This compares two numbers and
    /// commits or rolls back on the answer; what either outcome means to the reader
    /// is `DatabaseViewerModel`'s to say.
    func performWrite(_ transaction: DatabaseWriteTransaction) async throws -> DatabaseWriteOutcome {
        let connection = try Self.openReadWrite(at: transaction.url)
        // Closed on every path, the throwing ones included — the same reason the
        // prepared statement above is finalized in a `defer`. A leaked write
        // handle would hold the write lock for the life of the app.
        defer { sqlite3_close_v2(connection) }

        // Before the `BEGIN`, where it is not a no-op, and on this connection
        // because the setting is per-connection: without it a foreign key is the
        // one declared constraint SQLite does not check, so an edit that orphans a
        // row would commit and report success. See `DatabaseQuery.foreignKeysOn`.
        _ = try execute(DatabaseQuery.foreignKeysOn, on: connection)
        _ = try execute(DatabaseQuery.beginImmediate, on: connection)
        do {
            var affectedRows = 0
            for statement in transaction.statements {
                affectedRows += try execute(statement, on: connection).affectedRows
            }
            let isCommitted = affectedRows == transaction.requiredAffectedRows
            _ = try execute(isCommitted ? DatabaseQuery.commit : DatabaseQuery.rollback, on: connection)
            if isCommitted {
                // After the commit, outside the transaction, and never allowed to
                // turn a write that succeeded into a failure: a checkpoint that
                // could not run leaves the edit committed and durable, which is
                // what the outcome below reports. See `DatabaseQuery.walCheckpoint`
                // for why a WAL database needs it at all.
                _ = try? execute(DatabaseQuery.walCheckpoint, on: connection)
            }
            return DatabaseWriteOutcome(affectedRows: affectedRows, isCommitted: isCommitted)
        } catch {
            // Undo whatever ran before the failure, then report the failure itself.
            // `try?` because a rollback that fails has nothing further to say: the
            // close below ends the transaction either way, and replacing the
            // statement's own message with the rollback's would lose the sentence
            // that explains what actually went wrong.
            _ = try? execute(DatabaseQuery.rollback, on: connection)
            throw error
        }
    }

    /// Open a second connection at `url` read-write, with the read path's busy
    /// timeout.
    ///
    /// The timeout matters more here than it does for a read: `BEGIN IMMEDIATE`
    /// asks for the write lock up front, so a database another process is writing
    /// makes this wait the five seconds out rather than refusing the edit the
    /// instant a lock is contended.
    private static func openReadWrite(at url: URL) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { Self.message(from: $0) } ?? Self.message(for: code)
            sqlite3_close_v2(connection)
            throw Self.openError(code: code, message: message)
        }
        sqlite3_busy_timeout(connection, Self.busyTimeoutMilliseconds)
        return connection
    }

    // MARK: - Binding

    /// Bind `parameters` positionally, 1-based, through the library's typed calls.
    ///
    /// Positional and typed, never interpolated: a bound value cannot change the
    /// statement's grammar, which is the whole reason `DatabaseQuery` binds
    /// everything that *can* be bound.
    private func bind(
        _ parameters: [DatabaseValue],
        to prepared: OpaquePointer,
        on handle: OpaquePointer
    ) throws {
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch parameter {
            case .integer(let value):
                code = sqlite3_bind_int64(prepared, index, value)
            case .real(let value):
                code = sqlite3_bind_double(prepared, index, value)
            case .text(let value):
                // Bound by **byte count**, never as a C string: SQLite TEXT may
                // legally contain U+0000, and the `-1` length that stops at the
                // first NUL would silently truncate a value the reader three
                // functions below deliberately reads whole. The two halves of the
                // round trip agree or the seam loses bytes.
                let bytes = Array(value.utf8CString)
                // `count - 1` drops the terminator the explicit length makes
                // unnecessary; the copy `transient` asks for happens before this
                // array goes out of scope.
                code = sqlite3_bind_text(prepared, index, bytes, Int32(bytes.count - 1), Self.transient)
            case .blob:
                // **Refused, not guessed.** A `DatabaseValue` blob carries its
                // length and nothing else (see the case's own note), so there is
                // no faithful binding of one: `sqlite3_bind_zeroblob` would bind a
                // blob of that length read as zeros — a *different value* from
                // whatever the reader saw — and `sqlite3_bind_blob` with a nil
                // pointer would bind SQL NULL, a different value again. Writing
                // either one over the cell it meant to edit would report
                // `SQLITE_OK` at every layer while the bytes were gone.
                //
                // Nothing in the repository binds a blob today: `DatabaseQuery`
                // binds integers only. Part 2's cell writes must carry the bytes
                // in a value that *has* them, and this refusal is what says so
                // when it lands, rather than a comment nobody re-reads.
                throw DatabaseError.sqlError(
                    message: "A blob value carries its length only and cannot be bound as a parameter."
                )
            case .null:
                code = sqlite3_bind_null(prepared, index)
            }
            guard code == SQLITE_OK else {
                throw Self.error(code: code, message: Self.message(from: handle))
            }
        }
    }

    // MARK: - Reading

    /// One cell, read back by the **storage class it actually holds** rather than
    /// by the column's declared type.
    ///
    /// SQLite's type affinity means a column declared `INTEGER` may store text,
    /// so reading by declaration would either lie about the value or convert it
    /// silently. `sqlite3_column_type` answers what is really there, which is
    /// exactly the five cases `DatabaseValue` is closed over.
    private func value(of prepared: OpaquePointer, at index: Int32) -> DatabaseValue {
        switch sqlite3_column_type(prepared, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(prepared, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(prepared, index))
        case SQLITE_TEXT:
            // Read by byte count rather than as a C string: SQLite TEXT may
            // legally contain U+0000, and `String(cString:)` would stop at the
            // first one and hand back a silently truncated value. The count is
            // asked *after* the pointer, the order the library documents.
            guard let text = sqlite3_column_text(prepared, index) else { return .text("") }
            let count = Int(sqlite3_column_bytes(prepared, index))
            guard count > 0 else { return .text("") }
            let buffer = UnsafeBufferPointer(start: text, count: count)
            return .text(String(decoding: buffer, as: UTF8.self))
        case SQLITE_BLOB:
            // The length alone, and **the bytes are never copied**: the value the
            // grid renders is a placeholder naming the size, and a page holds two
            // hundred rows of cells that may each be a gigabyte. `sqlite3_column_
            // bytes` on a column already known to be `SQLITE_BLOB` performs no
            // conversion — it answers the length of what is there — so this asks
            // for the one fact anybody reads and leaves the bytes in the
            // statement's own memory, which the next `step` reuses.
            return .blob(byteCount: Int(sqlite3_column_bytes(prepared, index)))
        default:
            return .null
        }
    }

    // MARK: - Failures

    /// SQLite's own words for whatever last went wrong on `handle`.
    private static func message(from handle: OpaquePointer) -> String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "Unknown SQLite error."
    }

    /// SQLite's words for a result code, used only where there is no handle to
    /// ask.
    private static func message(for code: Int32) -> String {
        sqlite3_errstr(code).map { String(cString: $0) } ?? "Unknown SQLite error."
    }

    /// The failure an `open` reports. Everything that is not a recognized
    /// condition is `.cannotOpen`, because that is what it was.
    private static func openError(code: Int32, message: String) -> DatabaseError {
        switch code & 0xFF {
        case SQLITE_NOTADB: return .notADatabase(message: message)
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy(message: message)
        default: return .cannotOpen(message: message)
        }
    }

    /// The failure a prepare, bind or step reports.
    ///
    /// The low byte only: SQLite returns *extended* result codes here
    /// (`SQLITE_BUSY_SNAPSHOT`, `SQLITE_READONLY_DBMOVED`), and comparing an
    /// extended code against the primary constant matches nothing — so a locked
    /// database would arrive as a generic SQL error and the viewer would stop
    /// telling a contended write apart from a typo.
    private static func error(code: Int32, message: String) -> DatabaseError {
        switch code & 0xFF {
        case SQLITE_NOTADB: return .notADatabase(message: message)
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy(message: message)
        default: return .sqlError(message: message)
        }
    }
}
#endif
