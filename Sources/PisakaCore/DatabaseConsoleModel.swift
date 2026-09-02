import Foundation

/// The SQL console's flow: what Run does, what the reader is asked before a
/// mutation, what is published when an answer arrives, and what is refused.
///
/// `DatabaseViewerModel`'s shape, one layer down — a `@MainActor
/// ObservableObject` whose I/O is the same injected `DatabaseServicing` the tab
/// holds, whose published state is only ever touched on the main actor, and
/// whose overlapping runs are ordered by a monotonic generation token bumped in
/// each run's **synchronous prefix**. Foundation only: every sentence it puts on
/// screen that SQLite did not write comes from `DatabaseConsolePlan`, and the
/// only SQL it ever handles is the reader's own, carried verbatim.
///
/// **One token, not two.** The tab counts its listing and its page apart because
/// they are independently re-triggerable; the console has exactly one thing that
/// re-triggers — pressing Run — and classification, the read and the confirmed
/// mutation are all phases of that one thing. A superseded run publishes
/// *nothing*: not its rows, not its footer, not its message, not its spinner.
/// `didWrite` is the one stated exception, for `DatabaseViewerModel
/// .updateCell`'s reason — it is about the file on disk and not about the screen.
///
/// **Its own message slot.** The console's failures are published here rather
/// than into the tab's `errorMessage`, in both directions: a page turn never
/// writes or clears the console's sentence, and a console failure never blanks
/// the banner above the grid. The two surfaces are different questions the
/// reader asked at different moments, and one answer overwriting the other would
/// leave whichever lost with no explanation at all.
///
/// **The console never raises the disk-writer gate and only consults one**,
/// exactly as the cell edit does — it is the same seventh-bracket rule, asked by
/// a second surface. It does not name the gate, the tab's URL or the tab: all
/// five arrive as closures the owner wires once, so a rename is followed for
/// free and no file under the console names `localChanges`.
@MainActor
public final class DatabaseConsoleModel: ObservableObject {

    /// A mutating text waiting for the reader's answer: what they are asked, and
    /// the text `confirm()` will send **verbatim** if they agree.
    ///
    /// The text is carried here rather than re-read from the input, and that is
    /// the whole reason this is a value and not a bare `String?` prompt: the pane
    /// owns the input as transient `@State` and the reader may go on typing while
    /// the confirmation sits in front of them. What runs is what was classified,
    /// which is what the prompt describes — anything else would ask about one
    /// text and run another.
    public struct PendingConfirmation: Equatable, Sendable {
        /// The sentence composed by `DatabaseConsolePlan.confirmationPrompt(for:)`
        /// and shown verbatim.
        public let prompt: String
        /// The reader's text, exactly as it was classified.
        public let text: String

        public init(prompt: String, text: String) {
            self.prompt = prompt
            self.text = text
        }
    }

    /// The last console read's answer, or `nil` when no read has answered yet.
    ///
    /// Replaced by the next read that answers, cleared by a committed mutation
    /// (which shows no rows and reports a count instead), and **left untouched by
    /// every failure** — a result that failed to be replaced is still the result
    /// the reader was reading, and blanking it would destroy the only context the
    /// message under it has.
    @Published public private(set) var answer: DatabaseConsoleAnswer?

    /// The sentence under the result area: how many rows arrived and whether they
    /// were capped, or how many rows a committed mutation changed. Composed by
    /// `DatabaseConsolePlan`.
    @Published public private(set) var footer: String?

    /// **The console's own message slot** — SQLite's sentence for a failure, or
    /// one of the three the console owns (the gate, a write in flight, nothing to
    /// run). Never written or cleared by anything the tab's grid does.
    @Published public private(set) var message: String?

    /// The rows the last committed mutation changed, or `nil` when the last thing
    /// to answer was not one. Published beside `footer` because the number is the
    /// *whole* report of a mutating batch and a surface may want it apart from
    /// the sentence.
    @Published public private(set) var affectedRows: Int?

    /// Whether any console work is in flight — classification, a read, or a
    /// confirmed mutation. What the pane disables Run on.
    @Published public private(set) var isRunning = false

    /// Whether a confirmed console mutation is in flight.
    ///
    /// Read by the tab (`DatabaseViewerModel.isWriteInFlight`) so the paging
    /// buttons and the sort headers disable while **any** write is running, the
    /// console's included: a page turn landing mid-batch would publish rows from
    /// a half-applied transaction.
    @Published public private(set) var isWriting = false

    /// The mutation awaiting the reader's answer, or `nil` when nothing is being
    /// asked. Published by `run(_:)` and answered by `confirm()`/`cancel()`.
    @Published public private(set) var pendingConfirmation: PendingConfirmation?

    private let service: DatabaseServicing

    /// The five closures the owner wires once, none of which the console could
    /// hold as a value without going stale or naming something it must not.
    ///
    /// - `fileURL`: the tab's URL **as it is now**. A viewer tab outlives the
    ///   path it was opened at — a rename retargets it — so the URL a mutation
    ///   opens read-write is asked for at the moment the mutation is composed
    ///   rather than copied at construction.
    /// - `isWriteBlocked`: the disk-writer gate, wired in the scene to the same
    ///   flag ⌘S and the cell edit refuse on. Asked here so no file under the
    ///   console names it.
    /// - `isOtherWriteInFlight`: whether the *tab* has a write running — the
    ///   grid's cell edit. One write per tab, and the console can only see its
    ///   own, so the other half is asked for. The two share a refusal rather than
    ///   each claiming the file is free.
    /// - `didWrite`: run after a mutation **committed**, so Local Changes learns
    ///   the file is modified.
    /// - `refreshAfterWrite`: re-read what the file now says — the listing, the
    ///   selection, the count and the page — because a console batch may have
    ///   created or dropped the very table the grid is showing.
    ///
    /// `var` rather than `let` because the tab builds the console inside its own
    /// `init` and can only capture itself once every stored property is in place;
    /// `connect(...)` is called exactly once, by the owner, immediately after.
    /// Defaulted so a console constructed on its own — in a test of the read path
    /// — is a complete object rather than one that traps.
    private var fileURL: @MainActor () -> URL
    private var isWriteBlocked: @MainActor () -> Bool
    private var isOtherWriteInFlight: @MainActor () -> Bool
    private var didWrite: @MainActor () -> Void
    private var refreshAfterWrite: @MainActor () async -> Void

    /// Ordering token for the whole run — see the type's note on why there is
    /// only one.
    private var generation = 0

    /// Whether the tab has closed. Latched by `stop()`, so a run resuming into a
    /// tab that is gone publishes nothing and a Run pressed after it sends
    /// nothing at all.
    private var isStopped = false

    /// - Parameters:
    ///   - service: the seam — the **same instance the tab holds**, because a
    ///     connection is one file and the console's reads run on the tab's own
    ///     read connection.
    ///   - fileURL: where that file is now.
    public init(service: DatabaseServicing, fileURL: @escaping @MainActor () -> URL) {
        self.service = service
        self.fileURL = fileURL
        self.isWriteBlocked = { false }
        self.isOtherWriteInFlight = { false }
        self.didWrite = {}
        self.refreshAfterWrite = {}
    }

    /// Wire the owner's four remaining closures. Called once, by the tab, from
    /// its own `init` — see the closures' note for why it is a second call.
    func connect(
        fileURL: @escaping @MainActor () -> URL,
        isWriteBlocked: @escaping @MainActor () -> Bool,
        isOtherWriteInFlight: @escaping @MainActor () -> Bool,
        didWrite: @escaping @MainActor () -> Void,
        refreshAfterWrite: @escaping @MainActor () async -> Void
    ) {
        self.fileURL = fileURL
        self.isWriteBlocked = isWriteBlocked
        self.isOtherWriteInFlight = isOtherWriteInFlight
        self.didWrite = didWrite
        self.refreshAfterWrite = refreshAfterWrite
    }

    // MARK: - Running

    /// What Run does with the reader's text.
    ///
    /// **Nothing runs until the text has been classified as far as it can be.**
    /// The order is the feature: `classifyConsole(_:)` prepares statement by
    /// statement through the tail and executes none of them, and only then does
    /// `DatabaseConsolePlan.decide(_:)` — and nothing else — say what happens.
    /// Four answers and no fifth: there was nothing to run, SQLite's prepare
    /// failure is the answer, the reader is asked, or it is a read.
    ///
    /// A pending confirmation from a previous Run is dropped here rather than
    /// answered: pressing Run again is a new question, and leaving the old prompt
    /// up would let the reader agree to a text they have since replaced.
    public func run(_ text: String) async {
        guard !isStopped else { return }
        generation += 1
        let token = generation
        pendingConfirmation = nil
        isRunning = true

        let classification: DatabaseConsoleClassification
        do {
            classification = try await service.classifyConsole(text)
        } catch {
            guard token == generation else { return }
            publishFailure(error)
            return
        }
        guard token == generation else { return }

        switch DatabaseConsolePlan.decide(classification) {
        case .nothingToRun:
            message = DatabaseConsolePlan.nothingToRunMessage
            isRunning = false
        case .refuse(let sqliteMessage):
            // SQLite's own words, and nothing runs: everything classified before
            // the failure is read-only, so a read cannot have created what the
            // next statement needs and running the prefix first would only be a
            // pointless read before the same refusal.
            message = sqliteMessage
            isRunning = false
        case .confirmWrite(let prompt):
            pendingConfirmation = PendingConfirmation(prompt: prompt, text: text)
            // Nothing is in flight while the reader reads the prompt, so the
            // spinner comes down and Run is live again — pressing it re-asks.
            isRunning = false
        case .read:
            await performRead(text, token: token)
        }
    }

    /// Run a fully classified, entirely read-only text and publish what the last
    /// statement that answered columns said.
    ///
    /// The cap travels as a number (`DatabaseConsolePlan.rowLimit`) and is
    /// enforced by the app half stepping; **nothing is ever appended to the
    /// reader's text**.
    private func performRead(_ text: String, token: Int) async {
        do {
            let read = try await service.runConsoleRead(text, rowLimit: DatabaseConsolePlan.rowLimit)
            guard token == generation else { return }
            answer = read
            footer = DatabaseConsolePlan.resultFooter(rowCount: read.rows.count, isTruncated: read.isTruncated)
            // A read is not a mutation, so the last mutation's count goes with the
            // result it described: left standing it would sit beside a table of
            // rows and read as a claim about them.
            affectedRows = nil
            message = nil
            isRunning = false
        } catch {
            guard token == generation else { return }
            publishFailure(error)
        }
    }

    // MARK: - Answering the confirmation

    /// Drop the pending confirmation and change nothing at all.
    ///
    /// Not a failure and not a refusal: the reader was asked and said no, and
    /// there is nothing to explain. No message, no footer, and the previous
    /// result stands.
    public func cancel() {
        pendingConfirmation = nil
    }

    /// Send the classified text as one transaction, once every refusal has been
    /// asked.
    ///
    /// The refusals, in this order, with **nothing sent** until all of them pass:
    ///
    /// 1. **The disk-writer gate**, asked *here* rather than before the prompt.
    ///    The reader takes as long as they take to read a confirmation, and a
    ///    checkout can start inside that window and be replacing this very file;
    ///    the answer that matters is the one at the moment of sending.
    /// 2. **One write per tab** — the console's own or the grid's cell edit. A
    ///    second write is refused rather than queued, for the cell edit's reason:
    ///    the first is still deciding what the file says.
    ///
    /// A **page load in flight is deliberately not a refusal**, which is the one
    /// place this list is shorter than `updateCell`'s. A cell edit is planned
    /// against the row on screen and is meaningless if that row is being
    /// replaced; a console batch is planned against nothing on screen at all —
    /// it is the reader's own text about the whole database — so refusing it
    /// because the grid happens to be turning a page would be an unrelated
    /// coincidence dressed up as a rule.
    ///
    /// Then one `performConsoleWrite(_:)` on a separate, short-lived read-write
    /// connection at the tab's **current** URL, carrying the text verbatim.
    public func confirm() async {
        guard !isStopped, let pending = pendingConfirmation else { return }
        pendingConfirmation = nil

        if isWriteBlocked() {
            message = DatabaseConsolePlan.gateBlockedMessage
            return
        }
        guard !isWriting, !isOtherWriteInFlight() else {
            message = DatabaseConsolePlan.runInFlightMessage
            return
        }

        // Captured, never bumped: the confirmation is the second half of the run
        // that asked for it, so it publishes under that run's token and a newer
        // Run pressed since supersedes it.
        let token = generation
        let transaction = DatabaseConsoleTransaction(
            url: fileURL(),
            text: pending.text,
            readRowLimit: DatabaseConsolePlan.rowLimit
        )
        isWriting = true
        isRunning = true

        do {
            let outcome = try await service.performConsoleWrite(transaction)
            // Lowered on **every** path, superseded included, for the cell edit's
            // reason: nothing but a confirmed console mutation ever raises it, so
            // the run that raised it is the only thing that can lower it. Left up,
            // the tab refuses every later write for its life. `isRunning` is the
            // opposite case and is left to whichever run superseded this one —
            // only `run(_:)` bumps the token, so a superseded confirmation means a
            // newer run raised that flag for itself.
            isWriting = false
            let isCurrent = token == generation
            if isCurrent { isRunning = false }

            guard outcome.isCommitted else {
                if isCurrent { message = Self.rolledBackMessage }
                return
            }
            if isCurrent {
                affectedRows = outcome.affectedRows
                footer = DatabaseConsolePlan.affectedRowsFooter(outcome.affectedRows)
                // A mutating batch shows no rows — it reports its affected-row
                // total and nothing else — so a previous read's table goes with
                // the footer that described it.
                answer = nil
                message = nil
            }
            // Told before the supersession guard and outside it, because it is not
            // about the screen: a committed batch changed a tracked file on disk
            // whether or not this tab still shows what it changed, and Local
            // Changes would otherwise go on calling the database unmodified.
            didWrite()
            guard isCurrent else { return }
            // Last, and awaited: a batch may have created or dropped the very
            // table the grid is showing, so the listing, the selection, the count
            // and the page are all re-read before the run is over.
            await refreshAfterWrite()
        } catch {
            isWriting = false
            guard token == generation else { return }
            publishFailure(error)
        }
    }

    // MARK: - Stopping

    /// Stop the console — what the tab's `close()` calls.
    ///
    /// The token is bumped and the flags come down, exactly as the tab does for
    /// its two loads: work still in flight resumes to find itself superseded and
    /// publishes nothing into a tab that is gone. Latched, so a Run pressed after
    /// it sends nothing at all rather than running statements against a
    /// connection that has been released.
    ///
    /// The last result and the last message are **left standing**: this lowers
    /// flags, and a surface still drawing a closed tab for one frame should draw
    /// what it drew before rather than blank.
    public func stop() {
        isStopped = true
        generation += 1
        isRunning = false
        isWriting = false
        pendingConfirmation = nil
    }

    // MARK: - The console's own message slot

    /// Publish a failure's sentence and take the spinner down, leaving everything
    /// else exactly as it was.
    ///
    /// A failed run replaces nothing: the previous result, its footer and the
    /// last mutation's count all stand under the message, because they are still
    /// the last thing that actually happened.
    private func publishFailure(_ error: Error) {
        message = error.localizedDescription
        isRunning = false
    }

    /// What a mutation that returned without committing is told as.
    ///
    /// The seam's console write commits on success at whatever total it reached —
    /// "no rows changed" is an ordinary outcome — so this is not the cell edit's
    /// count collision but a transaction the app half rolled back without
    /// throwing. It has no words of SQLite's to quote, so it says the one thing
    /// the reader needs: the file is untouched.
    static let rolledBackMessage =
        "The transaction was rolled back, so this database was not changed."
}
