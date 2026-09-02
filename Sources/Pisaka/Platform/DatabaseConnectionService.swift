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
///
/// **The SQL console is the one text this file is handed that Core did not
/// compose**, and it changes nothing about the split: the reader's text arrives
/// verbatim, is never re-split, re-spelled or appended to, and this layer still
/// decides nothing about it — `sqlite3_stmt_readonly` says what each statement
/// is and `DatabaseConsolePlan` decides what that means. The three console
/// members are the only place a tail pointer is walked, and the only place a
/// number rather than a `LIMIT` bounds a result.
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
    ///
    /// **The nil tail pointer is deliberate and must stay.** This path compiles
    /// the first statement in `statement.sql` and ignores anything after it,
    /// which is exactly right for a statement `DatabaseQuery` composed — there is
    /// never a second one — and exactly wrong for text somebody typed. The
    /// console's text therefore goes through `enumerateStatements(in:on:…)`
    /// instead, which walks the tail; making this one do both would give the cell
    /// edit's path a multi-statement door nobody asked it to have.
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

    // MARK: - The console

    /// Prepare `text` **statement by statement through the tail**, handing each
    /// prepared statement to `body` in order and running nothing `body` does not
    /// step itself.
    ///
    /// The machinery `execute(_:on:)` deliberately does not have. That path
    /// passes a nil tail pointer, which is exactly right for the single statement
    /// `DatabaseQuery` composes and exactly wrong for the reader's text, where it
    /// would silently compile the first statement and drop everything after it.
    /// So all three console members come through here, and "how many statements
    /// does this text hold" is SQLite's own answer rather than a splitter of ours
    /// guessing which semicolon ends a statement — which is not a thing a
    /// semicolon reliably does, inside a string literal, a comment or a trigger
    /// body.
    ///
    /// Each prepare is handed the remainder of the text and reports where the
    /// statement it compiled ended; the next one starts there. A stretch that
    /// compiles to no statement at all — trailing whitespace, a comment, a bare
    /// `;` — yields a nil statement, is not counted and never reaches `body`.
    ///
    /// **A prepare failure ends the loop and is reported to `onPrepareFailure`
    /// rather than thrown from here**, because whether it is fatal is the
    /// caller's question and not this loop's: classification keeps it as its
    /// horizon (`DatabaseConsoleClassification.Deferral`), while both run paths
    /// pass a handler that throws. The index reported is the number of statements
    /// already delivered to `body`, which is the zero-based index of the one that
    /// failed.
    ///
    /// The text travels as one C string with a `-1` length, so SQLite reads it to
    /// the first NUL. That is the same NUL a stored text *value* is deliberately
    /// read past further down this file, and the difference is who typed it: a
    /// value's bytes are the database's and must survive the round trip, while a
    /// NUL inside SQL the reader typed ends the text as far as every SQLite entry
    /// point is concerned, so honouring it here is the truthful reading rather
    /// than a limitation.
    private func enumerateStatements(
        in text: String,
        on handle: OpaquePointer,
        onPrepareFailure: (Int32, String, Int) throws -> Void,
        body: (OpaquePointer, Int) throws -> Void
    ) throws {
        try text.withCString { start in
            var cursor: UnsafePointer<CChar> = start
            var index = 0
            while cursor.pointee != 0 {
                var prepared: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let code = sqlite3_prepare_v2(handle, cursor, -1, &prepared, &tail)
                guard code == SQLITE_OK else {
                    let message = Self.message(from: handle)
                    // A failed prepare may still have produced a statement, and
                    // the loop ends here either way — so it is released before
                    // the caller is told anything.
                    sqlite3_finalize(prepared)
                    try onPrepareFailure(code, message, index)
                    return
                }
                if let prepared {
                    // Released on every exit from this statement's turn, the
                    // throwing ones included.
                    defer { sqlite3_finalize(prepared) }
                    try body(prepared, index)
                    index += 1
                }
                // The tail is the only thing that advances the loop, so a prepare
                // that reported none — or reported no progress at all — ends it
                // rather than compiling the same bytes forever.
                guard let tail, tail > cursor else { return }
                cursor = tail
            }
        }
    }

    /// What each statement of `text` is, in order, **running none of them**.
    ///
    /// On the tab's own read-only connection, which costs nothing and changes
    /// nothing: preparing resolves a statement's names and decides its kind
    /// without executing it, and preparing a *mutating* statement on a read-only
    /// connection succeeds — SQLite refuses a write at step time, not at prepare
    /// time. Nothing here steps, so a `BEGIN` among the statements opens no
    /// transaction and the connection is left exactly as it was found.
    ///
    /// The kind is `sqlite3_stmt_readonly`'s answer carried across unchanged; see
    /// `DatabaseConsoleStatementKind` for why this layer has no opinion of its
    /// own about what a statement does.
    ///
    /// **A prepare failure is returned, not thrown** (seam rule 2): it becomes
    /// the classification's deferral with SQLite's verbatim message, because
    /// prepare resolves names against the schema as it stands *now* and the
    /// statements before the failure have not run yet — a text that creates a
    /// table and then inserts into it cannot be classified past the insert, and
    /// refusing it would be inventing a failure the database never had. What is
    /// still thrown is a failure that is not about the text: no connection.
    func classifyConsole(_ text: String) async throws -> DatabaseConsoleClassification {
        guard let handle else { throw DatabaseError.closed }

        var kinds: [DatabaseConsoleStatementKind] = []
        var deferral: DatabaseConsoleClassification.Deferral?
        try enumerateStatements(
            in: text,
            on: handle,
            onPrepareFailure: { _, message, index in
                deferral = DatabaseConsoleClassification.Deferral(index: index, message: message)
            },
            body: { prepared, _ in
                kinds.append(sqlite3_stmt_readonly(prepared) != 0 ? .read : .write)
            }
        )
        return DatabaseConsoleClassification(kinds: kinds, deferral: deferral)
    }

    /// Run an entirely read-only `text` in order on the tab's connection and
    /// answer the **last** statement that produced columns.
    ///
    /// Only ever reached with a fully classified read-only text — that is
    /// `DatabaseConsolePlan.Decision.read`, the one decision that gets here — so
    /// the refusal below is belt and braces against a text whose meaning changed
    /// between the classification and this run: a statement SQLite does not
    /// report read-only is refused rather than stepped, because the read path is
    /// not where a write is decided.
    ///
    /// `rowLimit` is enforced by **stepping**, never by appending a `LIMIT` to
    /// the reader's text: rows are kept up to the cap and then one further step
    /// decides whether more remained. A statement answering no columns
    /// contributes nothing and is not a failure — it ran, it said nothing, and
    /// an earlier answer stands.
    func runConsoleRead(_ text: String, rowLimit: Int) async throws -> DatabaseConsoleAnswer {
        guard let handle else { throw DatabaseError.closed }
        // Seam rule 4, and on this connection it is the load-bearing half: the
        // tab keeps reading through this handle for the rest of its life.
        defer { restoreAutocommit(on: handle) }

        let limit = max(0, rowLimit)
        var answer = DatabaseConsoleAnswer()
        try enumerateStatements(
            in: text,
            on: handle,
            onPrepareFailure: { code, message, _ in throw Self.error(code: code, message: message) },
            body: { prepared, _ in
                guard sqlite3_stmt_readonly(prepared) != 0 else {
                    throw DatabaseError.sqlError(message: Self.notReadOnlyRefusal)
                }
                let columnNames = (0..<sqlite3_column_count(prepared)).map { index in
                    sqlite3_column_name(prepared, index).map { String(cString: $0) } ?? ""
                }
                var rows: [[DatabaseValue]] = []
                var isTruncated = false
                while true {
                    let stepCode = sqlite3_step(prepared)
                    if stepCode == SQLITE_ROW {
                        // A row arriving with the cap already full **is** the
                        // truncation: that one extra step is how "more remained"
                        // is learned, and it is the only reason to step past the
                        // cap at all.
                        if rows.count >= limit {
                            isTruncated = true
                            break
                        }
                        rows.append(columnNames.indices.map { value(of: prepared, at: Int32($0)) })
                        continue
                    }
                    if stepCode == SQLITE_DONE { break }
                    throw Self.error(code: stepCode, message: Self.message(from: handle))
                }
                // The last statement with columns wins, and a statement without
                // any leaves whatever the one before it answered.
                guard !columnNames.isEmpty else { return }
                answer = DatabaseConsoleAnswer(columnNames: columnNames, rows: rows, isTruncated: isTruncated)
            }
        )
        return answer
    }

    /// Run `transaction.text` **whole, as one transaction**, on a connection of
    /// its own, and answer what it changed.
    ///
    /// The console's counterpart to `performWrite(_:)`, and deliberately not it,
    /// on both counts that differ. The **shape**: this carries one string and
    /// prepares each statement *as it is reached*, after the statements before it
    /// have run, which is the only way a text whose later statements depend on
    /// what its earlier ones create can run at all — and it is why classification
    /// stopping short of the end is a horizon rather than a refusal. A prepare
    /// failure here is therefore an ordinary failure that takes the whole batch
    /// down with it. The **count**: there is no required total. The text is the
    /// reader's own, so a commit stands at whatever it reached, and "no rows
    /// changed" is a real outcome for a `DELETE` that matched nothing or a
    /// `CREATE TABLE` rather than the collision the same number means for a cell
    /// edit.
    ///
    /// Everything else is `performWrite(_:)`'s bracket, for `performWrite(_:)`'s
    /// reasons: a short-lived read-write connection at the transaction's own url
    /// (never creating), foreign keys on before the `BEGIN` where the setting is
    /// not a no-op, `BEGIN IMMEDIATE` so the write lock is taken up front,
    /// closed on every path, and a WAL checkpoint after a commit so the tracked
    /// bytes actually move.
    func performConsoleWrite(_ transaction: DatabaseConsoleTransaction) async throws -> DatabaseWriteOutcome {
        let connection = try Self.openReadWrite(at: transaction.url)
        defer {
            // Closing rolls back on its own; asking first is what keeps seam
            // rule 4 one line in one place rather than an inference about
            // SQLite's teardown.
            restoreAutocommit(on: connection)
            sqlite3_close_v2(connection)
        }

        _ = try execute(DatabaseQuery.foreignKeysOn, on: connection)
        _ = try execute(DatabaseQuery.beginImmediate, on: connection)
        do {
            var affectedRows = 0
            try enumerateStatements(
                in: transaction.text,
                on: connection,
                onPrepareFailure: { code, message, _ in throw Self.error(code: code, message: message) },
                body: { prepared, _ in
                    affectedRows += try stepConsoleStatement(
                        prepared,
                        on: connection,
                        readRowLimit: transaction.readRowLimit
                    )
                }
            )
            // Only when a transaction is still open: a text that committed its
            // own would otherwise fail here with "cannot commit - no transaction
            // is active", turning a batch that already landed into a reported
            // failure.
            if sqlite3_get_autocommit(connection) == 0 {
                _ = try execute(DatabaseQuery.commit, on: connection)
            }
            // Never allowed to turn a write that succeeded into a failure: a
            // checkpoint that could not run leaves the batch committed and
            // durable, which is what this outcome reports.
            _ = try? execute(DatabaseQuery.walCheckpoint, on: connection)
            return DatabaseWriteOutcome(affectedRows: affectedRows, isCommitted: true)
        } catch {
            // Undo whatever ran before the failure, then report the failure
            // itself — `try?` for the reason `performWrite(_:)` gives: replacing
            // the statement's own message with the rollback's would lose the
            // sentence that explains what went wrong.
            _ = try? execute(DatabaseQuery.rollback, on: connection)
            throw error
        }
    }

    /// Step one statement of a console batch and answer the rows it changed.
    ///
    /// The cap applies to a **read-only** statement only. One inside a mutating
    /// batch is stepped because a statement nobody steps never runs at all, and
    /// its rows are discarded — the batch reports an affected-row total and shows
    /// no rows — so a `SELECT` over a large table is abandoned rather than walked
    /// for nothing. A cap of zero still steps once, for that same reason. A
    /// statement that is **not** read-only is stepped to completion whatever the
    /// cap says: `INSERT … RETURNING` answers columns *and* writes, and
    /// abandoning it would half-perform it.
    private func stepConsoleStatement(
        _ prepared: OpaquePointer,
        on connection: OpaquePointer,
        readRowLimit: Int
    ) throws -> Int {
        let isReadOnly = sqlite3_stmt_readonly(prepared) != 0
        var rowsSeen = 0
        while true {
            let stepCode = sqlite3_step(prepared)
            if stepCode == SQLITE_ROW {
                rowsSeen += 1
                if isReadOnly, rowsSeen >= max(0, readRowLimit) { break }
                continue
            }
            if stepCode == SQLITE_DONE { break }
            throw Self.error(code: stepCode, message: Self.message(from: connection))
        }
        // `sqlite3_changes` answers the *connection's* last modification and a
        // read does not reset it — the trap `execute(_:on:)` guards against, with
        // the same guard: a read-only statement contributes nothing to the total.
        return isReadOnly ? 0 : Int(sqlite3_changes(connection))
    }

    /// Roll back a transaction the reader's own text left open.
    ///
    /// Seam rule 4: a console run leaves the connection in autocommit. Without
    /// this a bare `BEGIN` typed into the console would freeze the tab's read
    /// snapshot for the life of the tab — every later page would answer out of a
    /// transaction nobody can see, and no change another process made would ever
    /// appear again.
    ///
    /// `try?` because this runs on the way out, including out of a failure: a
    /// rollback that cannot run has nothing to add to the sentence that explains
    /// what actually went wrong.
    private func restoreAutocommit(on connection: OpaquePointer) {
        guard sqlite3_get_autocommit(connection) == 0 else { return }
        _ = try? execute(DatabaseQuery.rollback, on: connection)
    }

    /// What the read path says about a statement SQLite does not report
    /// read-only.
    ///
    /// Ours, not SQLite's, because SQLite never saw it: the statement is refused
    /// before it is stepped, so there is no library message to quote. It names
    /// the state rather than blaming the reader — a text whose meaning changed
    /// between the classification and the run is exactly what this catches, and
    /// pressing Run again re-classifies it and asks for the confirmation a write
    /// is owed.
    private static let notReadOnlyRefusal =
        "This statement can change the database, so it was not run on the read connection. "
        + "Run the text again to confirm the change."

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
