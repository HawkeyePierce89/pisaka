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
/// `captureText` is what the buffer is right now — which the app hands straight
/// back to `LocalHistoryModel.captureBuffers(event:urls:root:texts:)` under
/// ``event`` before it replaces anything, so a restore is reversible from the
/// history as well as by one ⌘Z. Pairing them in one value is what keeps the
/// capture from being a step a caller can forget: there is no way to hold a
/// restore plan and not hold the bytes it is about to displace.
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

    /// What the buffer holds now, to be captured under ``event`` first.
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

    /// The file the window is showing, or `nil` before the first `open` (and
    /// after one that was refused).
    @Published public private(set) var fileURL: URL?

    /// `fileURL`'s path under the project root — what the store is keyed by, and
    /// what the window titles itself with.
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

    /// The side-by-side rows for `selected` (left) against the buffer the caller
    /// passed to `select(_:currentText:)` (right).
    @Published public private(set) var diffRows: [DiffRow] = []

    /// Whether a listing or a content load is in flight. Only the newest one can
    /// clear it; see the type's note.
    @Published public private(set) var isLoading = false

    /// Whether the window should show its empty state: a file is targeted, its
    /// listing has landed, and there is nothing in it.
    public var isEmpty: Bool { fileURL != nil && !isLoading && revisions.isEmpty }

    // MARK: - Dependencies

    /// The very same store value the capture model writes through.
    private let store: LocalHistoryStore

    /// The project root the current file was opened under. Held rather than
    /// re-derived so a content load cannot key itself differently from the
    /// listing that produced the row.
    private var root: URL?

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
    /// hop away. A url that is not a file under `root` (or no root at all) leaves
    /// the window empty rather than reporting anything — the same refusal the
    /// capture side makes, for the same reason.
    public func open(file: URL, root: URL?) {
        generation += 1
        let generation = self.generation

        revisions = []
        selected = nil
        selectedContent = nil
        diffRows = []

        guard let root, let relativePath = LocalHistoryModel.relativePath(of: file, under: root) else {
            self.fileURL = nil
            self.relativePath = nil
            self.root = nil
            isLoading = false
            return
        }

        fileURL = file
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

    /// Show `snapshot` against `currentText`, loading its content and computing
    /// the diff off the main actor.
    ///
    /// `selected` moves synchronously so the list's highlight follows the click
    /// immediately; the content and the rows follow when they land, and only if
    /// nothing has superseded them. Passing `nil` clears the pane, which is why
    /// it takes no hop at all.
    public func select(_ snapshot: LocalHistorySnapshot?, currentText: String) {
        generation += 1
        let generation = self.generation

        selected = snapshot
        selectedContent = nil
        diffRows = []

        guard let snapshot, let root, let relativePath else {
            isLoading = false
            return
        }

        isLoading = true
        let store = self.store
        Task {
            let loaded = await offMain { () -> (String, [DiffRow])? in
                guard let text = store.content(of: snapshot, root: root, relativePath: relativePath) else {
                    return nil
                }
                return (text, LineDiff.rows(old: text, new: currentText))
            }
            guard generation == self.generation else { return }
            selectedContent = loaded?.0
            diffRows = loaded?.1 ?? []
            isLoading = false
        }
    }

    // MARK: - Restore

    /// The plan for restoring the selected revision over `currentText`, or `nil`
    /// when there is nothing to do.
    ///
    /// Pure, and deliberately answers `nil` in the two cases where a restore
    /// would be a no-op the user could not tell from a bug: nothing is selected
    /// (or its content is not in hand — a revision reclaimed between the listing
    /// and the click), and a revision whose text the buffer already holds.
    /// Refusing the identical case is what keeps a restore from marking a clean
    /// tab dirty and writing a `.restore` snapshot of bytes that are already the
    /// newest revision.
    public func restore(currentText: String) -> LocalHistoryRestore? {
        guard let fileURL, let root, let relativePath,
              let snapshot = selected, let text = selectedContent else { return nil }
        guard text != currentText else { return nil }
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
