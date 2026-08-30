import Foundation

/// Everything the app needs to carry out one restore, decided here and executed
/// there.
///
/// **A plan, not an action** — the `SaveTransformPlan` / `PushPlan` shape. The
/// browser model reads the store and knows which revision is selected; only the
/// app layer can replace a buffer through the live text view, so the decision
/// travels as a value and the model itself writes nothing to the worktree ever.
///
/// It carries *both* texts on purpose. `text` is what the buffer becomes, and
/// `captureText` is what the window was showing as "now" — which the app
/// captures under ``event`` before it replaces anything, so a restore is
/// reversible from the history as well as by one ⌘Z. Pairing them in one value
/// is what keeps the capture from being a step a caller can forget: there is no
/// way to hold a restore plan and not hold the bytes it is about to displace.
///
/// `captureText` is a *fallback*, not the authority: the app opens a tab first,
/// and a buffer it had to open can hold more than the window could read (the
/// window reads disk under a 1 MiB ceiling; `WorkspaceModel.open` has none), so
/// the app snapshots what it is actually about to displace and falls back to
/// this only when there is no buffer to ask. See `restoreFromLocalHistory`.
public struct LocalHistoryRestore: Equatable {
    /// The file being restored, spelled the way the caller opened it.
    public let fileURL: URL

    /// The project root the revision was stored under — the store is keyed by
    /// it, so the pre-restore capture needs it too.
    public let root: URL

    /// `fileURL`'s path under `root`.
    public let relativePath: String

    /// The revision the replacement text came from, so the app can name it in a
    /// confirmation or an undo label.
    public let snapshot: LocalHistorySnapshot

    /// What the window was showing as "now" — the pre-restore capture's fallback
    /// when the app has no buffer to read the displaced text off.
    public let captureText: String

    /// What the buffer becomes.
    public let text: String

    /// The label the pre-restore capture is taken under. A constant rather than
    /// a field: there is one reason this plan exists, and spelling it once keeps
    /// the app from inventing a second wording for it.
    public static let event: LocalHistoryEvent = .restore

    public init(
        fileURL: URL,
        root: URL,
        relativePath: String,
        snapshot: LocalHistorySnapshot,
        captureText: String,
        text: String
    ) {
        self.fileURL = fileURL
        self.root = root
        self.relativePath = relativePath
        self.snapshot = snapshot
        self.captureText = captureText
        self.text = text
    }
}

/// What the file being browsed holds *right now* — the "new" side of every diff
/// and the text a restore displaces — in the two shapes the app can answer it.
///
/// **A value, not a `String`, because the two answers cost different things.**
/// When a tab holds the file, the text is already main-actor state and reading it
/// is a dictionary lookup, so it travels as ``text(_:)`` and nothing is deferred.
/// When no tab does, the answer is a disk read under the same ceiling the capture
/// side uses, and that read has no business on the main thread: it travels as
/// ``deferred(_:)`` and the model resolves it **off the main actor**, inside the
/// hop it already makes for the revision's content and the diff. Same content,
/// same ceiling, same empty-string fallback — one fewer main-thread read.
///
/// The closure is `@Sendable` because that is where it runs. It is also only ever
/// called when there is something to diff: clearing the pane takes no hop, so a
/// deselection no longer costs a file read at all.
public enum LocalHistoryCurrentText: Sendable {
    /// Text already in hand — the open buffer.
    case text(String)

    /// Text that must be read, resolved off the main actor.
    case deferred(@Sendable () -> String)

    /// The text itself. Called on the browser model's private queue, never on the
    /// main actor.
    func resolve() -> String {
        switch self {
        case let .text(text): return text
        case let .deferred(read): return read()
        }
    }
}

/// The Local History window's state: which file it is showing, that file's
/// revisions, which one is selected, and the diff between it and the buffer.
///
/// **A pure reader over the store the capture model already owns.** It is handed
/// the same `LocalHistoryStore` value — one store, one layout, one policy,
/// however many readers — and it never captures, never prunes and never writes.
/// Like the symbol index, it therefore neither raises
/// `autosave.suspend()`/`localChanges.beginRevert()` nor is gated by them; the
/// one write a restore causes is the *app's*, through the ordinary buffer path,
/// and this model only describes it (``LocalHistoryRestore``).
///
/// **One generation token, captured synchronously before every hop.** Listing,
/// content loading and the diff are all off-main work whose result may come back
/// to a window that has since been retargeted at another file or moved to another
/// revision, and the codebase's rule for that is one monotonic counter bumped
/// *before* the first `await` and re-checked after every suspension. Superseded
/// work publishes **nothing at all** — not the rows, not the diff, and not
/// `isLoading`, so the newest work in flight is always the one that turns the
/// spinner off.
///
/// The token is shared by listing and selection rather than split in two,
/// because the two are one conversation: a selection only exists against a
/// listing, and a retarget must cancel an in-flight content load as surely as it
/// cancels an in-flight listing.
///
/// **Retargeting clears before it loads.** `open(file:root:)` empties the rows,
/// the selection and the diff synchronously, so the window never shows one
/// file's revisions — or worse, one file's content diffed against another's
/// buffer — while the new listing is in flight.
///
/// **A file with no history is empty, not broken.** Almost every file in a
/// project has never been saved by this app, and the store answers a missing
/// directory with an empty list rather than an error; ``isEmpty`` is what the
/// window renders its "No history for this file yet." state from. There is no
/// error state in this model at all, matching the rest of the feature: a
/// listing that cannot be read is an empty history.
@MainActor
public final class LocalHistoryBrowserModel: ObservableObject {

    // MARK: - Published state

    /// The file the window is showing, or `nil` before the first `open`.
    ///
    /// It holds the file of a *refused* open too — one outside the project root,
    /// or opened with no root at all — because the window has to say something
    /// about that file, and a window that forgot which file it was asked about
    /// can only be blank. What a refusal clears is `relativePath`, which is what
    /// the store is keyed by; see ``isUnsupportedTarget``.
    @Published public private(set) var fileURL: URL?

    /// `fileURL`'s path under the project root — what the store is keyed by, and
    /// what the window titles itself with. `nil` when the file cannot be keyed
    /// at all.
    @Published public private(set) var relativePath: String?

    /// The file's stored revisions, newest first.
    @Published public private(set) var revisions: [LocalHistorySnapshot] = []

    /// The revision whose content the right pane is diffing, or `nil` when none
    /// is chosen.
    @Published public private(set) var selected: LocalHistorySnapshot?

    /// The selected revision's text, or `nil` when nothing is selected — or when
    /// the revision was reclaimed by retention between the listing and the click,
    /// which is genuinely reachable and is treated as "nothing to show" rather
    /// than as a failure.
    @Published public private(set) var selectedContent: String?

    /// The side-by-side rows for `selected` (left) against the current text the
    /// caller passed to `select(_:currentText:)` (right).
    @Published public private(set) var diffRows: [DiffRow] = []

    /// What restoring the selected revision would do, or `nil` when there is
    /// nothing to do — which is also what disables the window's Restore button.
    ///
    /// **The enablement and the action are the same value**, which is the point of
    /// publishing a plan rather than exposing a predicate the view calls on click:
    /// the button now agrees with the diff pane it sits under, because both are
    /// answered from the very text the diff was computed against. A predicate
    /// asked at click time can only re-read the current text, and a window whose
    /// button says "restorable" while its rows say "identical" is the disagreement
    /// this removes.
    ///
    /// It is `nil` in the three cases where a restore would be a no-op the user
    /// could not tell from a bug: nothing is selected; the selected revision's
    /// content is not in hand (reclaimed by retention between the listing and the
    /// click); and a revision whose text the buffer already holds. Refusing the
    /// identical case is what keeps a restore from marking a clean tab dirty and
    /// writing a `.restore` snapshot of bytes that are already the newest
    /// revision.
    ///
    /// **The sameness test is `NSString`'s, not `String`'s**, and that is the same
    /// hazard `SaveTransformController.applyRestore` guards one layer up: Swift's
    /// `==` compares by canonical equivalence, so it calls a decomposed and a
    /// precomposed spelling of one word equal — while this feature identifies a
    /// revision by SHA-256 over its *UTF-8 bytes*, which stores those two
    /// spellings as genuinely different revisions. Comparing canonically here
    /// would refuse to plan the one restore that does change bytes, silently: the
    /// button is armed, the click does nothing, and the buffer keeps the encoding
    /// the user asked to replace.
    @Published public private(set) var restorePlan: LocalHistoryRestore?

    /// Whether a listing or a content load is in flight. Only the newest one can
    /// clear it; see the type's note.
    @Published public private(set) var isLoading = false

    /// Whether the window should show its empty state: a file is targeted, its
    /// listing has landed, and there is nothing in it. True for a refused target
    /// as well — a file the store cannot key has no revisions and never will,
    /// which is a fact about the file, not a failure to report.
    public var isEmpty: Bool { fileURL != nil && !isLoading && revisions.isEmpty }

    /// Whether the targeted file is one this feature cannot key at all: outside
    /// the project root, or opened with no project root at all.
    ///
    /// The window renders a different sentence for it than for a file that
    /// simply has no revisions yet, because the two are different answers: one
    /// gets a history the moment it is saved, the other never does.
    public var isUnsupportedTarget: Bool { fileURL != nil && relativePath == nil }

    // MARK: - Dependencies

    /// The very same store value the capture model writes through.
    private let store: LocalHistoryStore

    /// The project root the current file was opened under. Held rather than
    /// re-derived so a content load cannot key itself differently from the
    /// listing that produced the row.
    private var root: URL?

    /// What the last landed selection resolved ``LocalHistoryCurrentText`` to —
    /// the very text ``diffRows`` was computed against, and therefore the only
    /// honest right-hand side of the sameness question ``restorePlan`` asks.
    /// Cleared wherever the selection is.
    private var resolvedCurrentText: String?

    /// See the type's note.
    private var generation = 0

    /// Where the reads run. Serial and utility, the capture model's arrangement
    /// for the same reason: this object stays `@MainActor` and no directory read,
    /// no file read and no diff ever lands on the main thread.
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.local-history.browser", qos: .utility)

    public init(store: LocalHistoryStore) {
        self.store = store
    }

    // MARK: - Targeting

    /// Point the window at `file` under `root` and load its revisions.
    ///
    /// The clearing half happens *now*, synchronously: whatever the window was
    /// showing belonged to another file, and the listing that replaces it is one
    /// hop away. A url that is not a file under `root` (or no root at all) is
    /// *targeted but unkeyed* — the same refusal the capture side makes, for the
    /// same reason — and the window says so rather than reporting anything; see
    /// ``isUnsupportedTarget``.
    ///
    /// The selection lives here rather than in the window for the same reason
    /// the rows do: a retarget clears it, and a window holding its own copy
    /// would have to echo that clear back through `select(_:currentText:)`,
    /// cancelling the listing this call just started.
    public func open(file: URL, root: URL?) {
        generation += 1
        let generation = self.generation

        revisions = []
        selected = nil
        selectedContent = nil
        diffRows = []
        restorePlan = nil
        resolvedCurrentText = nil
        fileURL = file

        guard let root, let relativePath = LocalHistoryModel.relativePath(of: file, under: root) else {
            self.relativePath = nil
            self.root = nil
            isLoading = false
            return
        }

        self.relativePath = relativePath
        self.root = root
        isLoading = true

        let store = self.store
        Task {
            let listed = await offMain { store.revisions(root: root, relativePath: relativePath) }
            guard generation == self.generation else { return }
            revisions = listed
            isLoading = false
        }
    }

    // MARK: - Selection

    /// Show `snapshot` against what the file holds now, loading its content,
    /// resolving that current text and computing the diff off the main actor.
    ///
    /// `selected` moves synchronously so the list's highlight follows the click
    /// immediately; the content, the rows and the restore plan follow when they
    /// land, and only if nothing has superseded them. Passing `nil` clears the
    /// pane, which is why it takes no hop at all — and therefore why a
    /// deselection never resolves a ``LocalHistoryCurrentText/deferred(_:)`` and
    /// never reads disk.
    ///
    /// **The current text is resolved inside the hop this call already makes.**
    /// The revision's bytes are read there and the diff is computed there, so a
    /// disk copy of the current text belongs in the same place rather than on the
    /// main actor before it; see ``LocalHistoryCurrentText``.
    ///
    /// **Clearing an already-clear pane is not a new question**, and must not
    /// count as one: the generation token is what supersedes work in flight, so
    /// a caller echoing back the clear `open(file:root:)` has just made would
    /// otherwise discard the listing that call started and leave a file that has
    /// history looking as though it has none.
    public func select(_ snapshot: LocalHistorySnapshot?, currentText: LocalHistoryCurrentText) {
        if snapshot == nil, selected == nil, selectedContent == nil, diffRows.isEmpty { return }

        generation += 1

        selected = snapshot
        selectedContent = nil
        diffRows = []
        restorePlan = nil
        resolvedCurrentText = nil

        guard let snapshot, root != nil, relativePath != nil else {
            isLoading = false
            return
        }

        load(snapshot, currentText: currentText)
    }

    /// Re-ask the standing selection's question against the current text.
    ///
    /// **The window is a snapshot, and one part of that snapshot became an
    /// action.** Everything the pane shows was resolved when the selection
    /// landed, which was fine while it was all read-only; now the same resolved
    /// text also decides whether ``restorePlan`` exists, and therefore whether
    /// the Restore button is live. Left alone, a window held open across an edit
    /// in another window greys Restore out for a revision the buffer no longer
    /// holds — the panes merely go stale, but the button *refuses*, which is
    /// strictly worse than the click-time question it replaced.
    ///
    /// So the window re-asks when it becomes key: the user came back to it, the
    /// buffer is whatever it is now, and the diff and the button are recomputed
    /// together so they still agree. Unlike ``select(_:currentText:)`` this does
    /// **not** clear the panes first — there is nothing to hide, and blanking
    /// them on every focus would flicker — but it takes the generation token on
    /// the same terms, so a refresh and a click racing each other resolve in
    /// issue order. No selection means no question, and no read: a `.deferred`
    /// current text is not resolved and disk is not touched.
    public func refreshSelection(currentText: LocalHistoryCurrentText) {
        guard let snapshot = selected, root != nil, relativePath != nil else { return }
        generation += 1
        load(snapshot, currentText: currentText)
    }

    /// The one hop both entry points make: resolve the current text, read the
    /// revision and compute the diff off the main actor, then publish all of it —
    /// the restore plan included — only if nothing has superseded it.
    ///
    /// The generation token is bumped by the *caller*, synchronously, before this
    /// runs; it is read here and re-checked after the hop.
    private func load(_ snapshot: LocalHistorySnapshot, currentText: LocalHistoryCurrentText) {
        guard let root, let relativePath else { return }
        let generation = self.generation

        isLoading = true
        let store = self.store
        Task {
            let loaded = await offMain { () -> (current: String, content: String?, rows: [DiffRow]) in
                let current = currentText.resolve()
                guard let text = store.content(of: snapshot, root: root, relativePath: relativePath) else {
                    return (current, nil, [])
                }
                return (current, text, LineDiff.rows(old: text, new: current))
            }
            guard generation == self.generation else { return }
            resolvedCurrentText = loaded.current
            selectedContent = loaded.content
            diffRows = loaded.rows
            restorePlan = plannedRestore()
            isLoading = false
        }
    }

    // MARK: - Restore

    /// Build ``restorePlan`` from the state the landed selection just published.
    ///
    /// Private and total: every refusal is spelled here, so the sameness question
    /// — and the byte-wise `NSString` comparison that answers it — exists exactly
    /// once in the app. The reasoning for both lives on ``restorePlan``, which is
    /// what the window reads.
    private func plannedRestore() -> LocalHistoryRestore? {
        guard let fileURL, let root, let relativePath,
              let snapshot = selected, let text = selectedContent,
              let currentText = resolvedCurrentText else { return nil }
        guard !(text as NSString).isEqual(to: currentText) else { return nil }
        return LocalHistoryRestore(
            fileURL: fileURL,
            root: root,
            relativePath: relativePath,
            snapshot: snapshot,
            captureText: currentText,
            text: text
        )
    }

    // MARK: - Private

    /// Run `work` on the private serial queue and resume with its result — the
    /// `ProjectSearchModel.offMain(_:)` shape, so blocking file I/O never lands
    /// on the main thread while the model itself stays `@MainActor`.
    private func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
