#if os(macOS)
import Combine
import Foundation
import PisakaCore

/// Writes the editor session (the opened folder, the open tabs, the selected tab,
/// and the text of Untitled buffers) to `SessionStore` continuously, so a launch
/// can bring the last session back — including after a crash or a force-quit, not
/// only after an ordinary quit.
///
/// Shaped like `AutosaveController`: idempotent `start`, Combine subscriptions on
/// the model's published state, a main-queue debounce, `stop()`/`deinit`
/// teardown, and a synchronous `flushNow()` for exit. All the decisions — what a
/// session records, which buffers are worth storing, where the selection lands —
/// live in `EditorSession.snapshot` (pure, unit-tested), so this stays the thin
/// trigger→action wiring the repo convention wants of the view layer.
///
/// Sessions are stored **per project**, and nothing about that is visible here:
/// `store.save(_:)` is an *upsert into the session catalog, keyed by the snapshot's
/// own `folderPath`*, which promotes that project to the catalog's head (the head
/// being what launch restore follows). So this controller keeps writing one
/// snapshot of the live model and the store decides where it lands — which is
/// exactly why a project switch persists the outgoing project's tabs simply by
/// calling `flushNow()` *before* `projectRoot` moves. The incoming half is
/// `noteProjectSwitch(promoting:)`, called after the swap. The snapshot is always
/// of the live model at fire time, so no half-swapped state is writable.
///
/// An **empty session is written like any other**: a user who closed every tab
/// and quit must come back to an empty editor rather than have the session before
/// last resurrected.
///
/// It deliberately registers **no `willTerminateNotification` observer of its
/// own**. The snapshot has to be taken *after* autosave's termination flush — a
/// dirty titled file's contents are not persisted here, so the session is only
/// truthful once those buffers have reached disk — and resting that ordering on
/// the relative registration order of two independent notification observers
/// would make it invisible and fragile. Instead `AutosaveController.flushNow()`
/// is internal and `PisakaApp` calls both flushes back to back from one place,
/// where the order is written down.
final class SessionController {
    /// Fixed debounce: how long after the last change to the workspace state the
    /// session is written. Shorter than autosave's idle delay — writing a small
    /// plist is cheap and a fresher session means less lost on a crash — and not
    /// user-configurable, per the chosen scope.
    private let writeDelay: TimeInterval = 1.0

    private weak var model: WorkspaceModel?
    private var store: SessionStore?

    /// The last session actually written, so an unchanged snapshot is not written
    /// again — see `writeSession()`.
    private var lastWritten: EditorSession?

    /// Whether the workspace has actually changed since `start`. Raised by the
    /// *raw* trigger, before the debounce, and read by `flushNow()` — see there for
    /// why the quit path needs the same "nothing has changed yet" rule the
    /// `dropFirst()`s give the debounced path, and why raising it any later would
    /// reintroduce a different loss.
    private var hasObservedChange = false

    private var cancellables: Set<AnyCancellable> = []

    /// Begin observing the workspace and writing the session. Call *after* a
    /// restored session has been applied to the model, so a half-built state
    /// cannot overwrite what was saved.
    func start(model: WorkspaceModel, store: SessionStore) {
        // Idempotent, for `AutosaveController`'s reason: `.onAppear` can fire more
        // than once (a reopened window, a second `WindowGroup` scene), and
        // re-subscribing would stack subscriptions and write the session several
        // times per change.
        guard self.model == nil else { return }
        self.model = model
        self.store = store

        // The three subscriptions below are a **trigger only** — none of them
        // carries the state that gets written. The snapshot is always taken from
        // the *live* model when the debounce fires, never from a value captured in
        // the closure: a `@Published` value is delivered *before* the property is
        // committed (so the captured `openFiles` is the pre-change one), and the
        // other two properties are not part of that delivery at all. A cached
        // snapshot would therefore be stale, and the debounce would make it stay
        // stale until the next change.
        //
        // Each leg is `dropFirst()`ed — `AutosaveController`'s rule for
        // `$selectedID`, and load-bearing here. A `@Published` publisher replays
        // its *current* value to every new subscriber, so without it merely
        // subscribing fires the trigger and the session is rewritten ~1 s after
        // launch with no user change at all. That write is harmless when restore
        // was faithful and destructive when it was not: a folder on a volume that
        // is not mounted yet, or files deleted since the last run, are skipped
        // silently by design — and an unconditional launch write would persist
        // that truncated session over the recorded one before the user has
        // touched anything. Nothing is lost by waiting for a real change: a first
        // launch that stores no session is indistinguishable from one that stores
        // an empty one, since `loadLastOpened()` returning `nil` and an empty
        // session both restore nothing.
        let trigger = Publishers.Merge3(
            model.$openFiles.dropFirst().map { _ in () },
            model.$selectedID.dropFirst().map { _ in () },
            model.$projectRoot.dropFirst().map { _ in () }
        )

        trigger
            // Raised *before* the debounce, deliberately: a change made less than
            // `writeDelay` before Cmd+Q must still let `flushNow()` through — that
            // window is exactly what the quit-time flush exists to save. Setting it
            // from the debounced sink instead would drop it.
            .handleEvents(receiveOutput: { [weak self] _ in self?.hasObservedChange = true })
            .debounce(for: .seconds(writeDelay), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.writeSession() }
            .store(in: &cancellables)
    }

    /// Stop observing and release all subscriptions. Called from `deinit`; safe to
    /// call more than once.
    func stop() {
        cancellables.removeAll()
    }

    deinit { stop() }

    /// Write the session synchronously, bypassing the debounce. Called on quit
    /// (from `PisakaApp`'s `willTerminateNotification` observer, *after*
    /// `AutosaveController.flushNow()`), where a debounced write would never fire
    /// before the process exits — and on a **project switch**, where the outgoing
    /// project's snapshot has to be taken while `projectRoot` still names it, since
    /// that is what `save(_:)`'s keyed upsert files it under.
    ///
    /// It bypasses the debounce but **not** the "nothing has changed yet" rule the
    /// `dropFirst()`s give the debounced path, and that guard is load-bearing rather
    /// than an optimization: `lastWritten` is still `nil` until the first write, so
    /// without it a launch whose restore recovered nothing — a folder on a volume
    /// that is not mounted yet, files deleted since the last run — would persist
    /// that empty snapshot over the recorded session on the next Cmd+Q, with the
    /// user having touched nothing. That is precisely the loss `start`'s
    /// `dropFirst()`s prevent one second after launch, and it must not come back one
    /// quit later.
    ///
    /// The switch path leans on the same guard for a second, sharper case: launch
    /// restore opens the recorded folder *before* `start` is called, so the
    /// pre-switch flush there runs against a controller that has no model at all.
    /// The guard makes it the no-op it must be — an unguarded snapshot would file
    /// the empty live model under the no-folder workspace's key and take that
    /// project's stored untitled buffer with it.
    func flushNow() {
        guard hasObservedChange else { return }
        writeSession()
    }

    /// Register the project just switched *to*: promote `session` — the entry as it
    /// is **stored**, not as it was restored — to the catalog head, and treat the
    /// swap the app just performed as already written.
    ///
    /// Two things need this. First, promotion becomes immediate rather than resting
    /// on the 1 s debounce the swap arms, so a crash in that second still records
    /// which project the user is in. Second, and the reason it exists: applying a
    /// session **silently skips records this build cannot open** (a file deleted
    /// since, a volume not mounted yet), and the swap itself mutates `openFiles`,
    /// `selectedID` and `projectRoot` — so the debounced write that follows would
    /// persist that truncated restore over the recorded session with the user having
    /// touched nothing. That is exactly the loss `start`'s `dropFirst()`s prevent at
    /// launch, and the switch path reaches it by the same route. Seeding
    /// `lastWritten` with the post-swap snapshot makes `writeSession()`'s
    /// equal-snapshot guard suppress it; a genuine user change afterwards produces a
    /// different snapshot and writes normally.
    ///
    /// **The caller owes one invariant: `session` must be a superset of what the
    /// live model holds after the swap.** The seeding above suppresses not just the
    /// debounce the swap arms but *every* later equal write, `flushNow()` on quit
    /// included — so whatever `session` omits is not merely unwritten now, it is
    /// unwritable until the user changes something. A *superset* is exactly the
    /// intent (the records restore skipped are kept rather than truncated away); a
    /// subset silently destroys the difference. The replacing switch satisfies it
    /// trivially by promoting the stored entry the model was just filled from; the
    /// carrying one — the first Open Folder of a run — has to merge the tabs it
    /// carried in, which is what `EditorSession.merging(_:onto:)` is for.
    ///
    /// A no-op before `start`, which is what launch restore wants: it opens the
    /// recorded folder before the controller has a model, and the head is already
    /// that project.
    func noteProjectSwitch(promoting session: EditorSession) {
        guard let model, let store else { return }
        store.save(session)
        lastWritten = EditorSession.snapshot(
            openFiles: model.openFiles,
            selectedID: model.selectedID,
            projectRoot: model.projectRoot
        )
    }

    /// Snapshot the live model and persist it. An empty session is stored like any
    /// other — see the type's doc comment.
    ///
    /// A snapshot equal to the one last written is **not** written again. The
    /// trigger includes `$openFiles`, which republishes on every keystroke (the
    /// editor binding routes each edit through `updateText`), so in the steady
    /// state of typing in a titled file the session is byte-identical to the
    /// previous one — yet each debounce would otherwise cost a full
    /// `PropertyListEncoder` pass plus a `UserDefaults` write on the main thread,
    /// and limit 2 on `EditorSession` (Untitled text is uncapped) makes that pass
    /// proportional to a scratch buffer the user is not even editing.
    private func writeSession() {
        guard let model, let store else { return }
        let session = EditorSession.snapshot(
            openFiles: model.openFiles,
            selectedID: model.selectedID,
            projectRoot: model.projectRoot
        )
        guard session != lastWritten else { return }
        store.save(session)
        lastWritten = session
    }
}

#endif
