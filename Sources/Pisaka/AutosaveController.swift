#if os(macOS)
import AppKit
import Combine
import PisakaCore

/// JetBrains-style autosave: writes every dirty titled file to disk
/// automatically, on four triggers — idle (a short debounce after the last
/// keystroke), tab switch (the selected file changes), focus loss (the app
/// deactivates), and app termination (Cmd+Q / quit). Untitled (url-less) buffers
/// are never written; the action itself lives in `WorkspaceModel.saveAllDirty()`
/// (pure, unit-tested), so this controller is just the thin trigger→action
/// wiring (and the suspend gate), consistent with keeping `Pisaka` views thin.
///
/// Suspendable: an in-flight git revert (`PisakaApp.revertChanges`) is a second,
/// uncoordinated disk writer. Without gating, an autosave firing mid-revert could
/// write a buffer back to disk that the revert is concurrently discarding (racing
/// `git checkout`) and corrupt the revert's snapshot-based resync. The revert
/// brackets itself with `suspend()`/`resume()` so no autosave fires for the full
/// duration of its revert + resync.
final class AutosaveController {
    /// Fixed idle debounce: how long after the last `openFiles` change (in
    /// practice, the last keystroke) an idle autosave fires. Not user-configurable
    /// and there is no on/off toggle, per the chosen scope.
    private let idleDelay: TimeInterval = 2.0

    private weak var model: WorkspaceModel?
    private var onSaved: ((_ saved: [URL], _ createdFile: Bool) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    /// Suspend gate for **both** the regular triggers and the termination flush.
    /// Incremented only by an in-flight git revert (`PisakaApp.revertChanges`),
    /// which is a competing disk writer: an autosave firing mid-revert would race
    /// `git checkout`, and a quit landing mid-revert must let the revert's
    /// intentional discard win over the flush — so this gates `flushNow` too. A
    /// counter (not a boolean) so overlapping/nested reverts each balance their own
    /// `suspend()`/`resume()`.
    private var suspendCount = 0

    /// Suspend gate for the regular triggers **only** — deliberately *not* the
    /// termination flush. Incremented while a close-confirmation modal is open
    /// (`PisakaApp.closeFile`): the idle debounce, a GCD main-queue timer, fires
    /// inside the modal's nested run loop and would autosave the file before the
    /// user answers "Don't Save". But there is no revert racing the disk here, so a
    /// quit landing while the modal is open must still flush every *other* dirty
    /// file — folding this into `suspendCount` would suppress the quit-time save of
    /// unrelated edits (data loss). A counter for the same nesting reason.
    private var modalSuspendCount = 0

    /// Regular triggers (idle/focus-loss/tab-switch) are gated while *either*
    /// counter is raised; the termination flush is gated by `suspendCount` alone.
    private var isRegularSuspended: Bool { suspendCount > 0 || modalSuspendCount > 0 }

    /// Latches after a write-failure beep so repeated failed autosaves don't stack
    /// beeps; cleared again whenever an autosave leaves nothing dirty-but-titled.
    private var didBeepForFailure = false

    /// Set when a trigger fires while suspended (the debounce/tab-switch/focus-loss
    /// tick is otherwise dropped with no retry — Combine won't re-deliver it until
    /// the next upstream emission). It is replayed once *all* gates clear (both
    /// counters back to zero), so a brief suspend (an in-flight revert) stays transparent
    /// to the idle-autosave guarantee rather than silently swallowing a pending save
    /// of an unrelated dirty file.
    private var pendingAutosave = false

    /// Begin observing the triggers. `onSaved` is invoked (on the main thread,
    /// after a successful autosave that wrote at least one file) so the caller can
    /// refresh Local Changes — nothing watches the filesystem on *its* behalf (the
    /// macOS FSEvents `ProjectWatcher` feeds only the project tree), so a save must
    /// re-run `git status` explicitly.
    ///
    /// Its `createdFile` argument reports whether at least one of those writes
    /// *created* its file rather than overwriting it (see `missingDirtyPaths(in:)`),
    /// so the caller can bump the project tree for it: the watcher drops our own
    /// events (`kFSEventStreamCreateFlagIgnoreSelf`), and an autosave that recreates
    /// a file deleted out of band changes tree membership.
    ///
    /// Its `saved` argument names the urls actually written, for the same
    /// `IgnoreSelf` reason one level further on: the app's `.editorconfig` cache
    /// has no watcher behind it either, so an autosave of a `.editorconfig` is
    /// invisible unless the caller is told which files this tick wrote.
    func start(model: WorkspaceModel, onSaved: @escaping (_ saved: [URL], _ createdFile: Bool) -> Void) {
        // Idempotent: `.onAppear` can fire more than once (e.g. a window reopened),
        // and re-subscribing would stack observers and double every autosave. Bail
        // if already wired.
        guard self.model == nil else { return }
        self.model = model
        self.onSaved = onSaved

        // Idle trigger: autosave a short delay after the last `openFiles` change.
        // `saveAllDirty()` itself mutates `openFiles` (advances `savedText`), which
        // republishes `$openFiles` and re-arms this debounce — but that re-fire is a
        // no-op write because `saveAllDirty()` is idempotent (nothing is dirty
        // anymore), so the loop terminates after one extra idle tick. Other
        // non-keystroke republishes (newFile/open/markSaved/reload) likewise cost at
        // most one idempotent re-fire.
        model.$openFiles
            .debounce(for: .seconds(idleDelay), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.performAutosave() }
            .store(in: &cancellables)

        // Tab-switch trigger: flush all dirty files when the selection changes, so
        // the previously-edited file is written before the new one is shown.
        // `selectedID` also changes on tab *close* (including revert-driven
        // force-closes) — harmless here: a clean/closed file writes nothing
        // (idempotence), and revert-driven closes happen while autosave is suspended.
        model.$selectedID
            .dropFirst()
            .sink { [weak self] _ in self?.performAutosave() }
            .store(in: &cancellables)

        let center = NotificationCenter.default

        // Focus-loss trigger: autosave when the app deactivates. The handler hops to
        // the main actor before touching the model (mutated only on the main thread).
        observers.append(
            center.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.performAutosave() }
            }
        )

        // Termination trigger: flush synchronously on quit.
        // `willResignActiveNotification` does NOT fire when the frontmost app is quit
        // directly (Cmd+Q) — macOS runs `applicationShouldTerminate` →
        // `applicationWillTerminate` without deactivating — so focus-loss alone loses
        // every edit made in the last idle-debounce window before quitting. This
        // notification is delivered on the main thread as the run loop ends and the
        // process is about to exit, so a direct *synchronous* write (no debounce, no
        // async hop) is both safe and the only thing guaranteed to complete before
        // the process dies. `flushNow()` skips `onSaved` — the app is quitting and
        // there is no Local Changes UI left to refresh.
        observers.append(
            center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flushNow()
            }
        )
    }

    /// Stop observing and release all subscriptions. Called from `deinit`; safe to
    /// call more than once.
    func stop() {
        cancellables.removeAll()
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    deinit { stop() }

    /// Suspend autosave for an in-flight git revert (re-entrant). Paired with
    /// `resume()`; while the count is `> 0` both `performAutosave` and `flushNow`
    /// early-return (the revert's discard wins, even at quit).
    func suspend() { suspendCount += 1 }

    /// Resume autosave, balancing one `suspend()`. Never drops below zero; replays
    /// a deferred autosave once *all* gates are clear.
    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        replayPendingIfReady()
    }

    /// Suspend the regular triggers (idle/focus-loss/tab-switch) for an open
    /// close-confirmation modal (re-entrant), leaving the termination flush free to
    /// write unrelated dirty files on quit. Paired with `resumeFromModal()`.
    func suspendForModal() { modalSuspendCount += 1 }

    /// Resume the regular triggers, balancing one `suspendForModal()`. Never drops
    /// below zero; replays a deferred autosave once *all* gates are clear.
    func resumeFromModal() {
        guard modalSuspendCount > 0 else { return }
        modalSuspendCount -= 1
        replayPendingIfReady()
    }

    /// Run a deferred autosave (a trigger that fired while suspended) once both
    /// gates are clear, so a suspend window doesn't lose a pending save.
    private func replayPendingIfReady() {
        guard !isRegularSuspended, pendingAutosave else { return }
        pendingAutosave = false
        performAutosave()
    }

    /// The debounced / focus-loss / tab-switch path: save all dirty titled files
    /// and, when at least one was written, refresh Local Changes via `onSaved`.
    private func performAutosave() {
        guard let model else { return }
        // Suspended (revert or open close-confirmation modal): record that a save is
        // owed and bail. The deferred save replays when *all* gates clear, so the
        // dropped tick isn't lost forever (Combine won't re-deliver the debounce
        // until the next edit).
        guard !isRegularSuspended else { pendingAutosave = true; return }
        pendingAutosave = false
        // Probe *before* the write: `write(_:to:)` creates a missing file, so a tab
        // whose file was deleted out of band is put back on disk by this autosave —
        // a change of tree membership the watcher will not report (it drops our own
        // events). Only these creating writes are reported; an ordinary overwrite
        // leaves every listing identical and stays silent, which is exactly the
        // frequent self-noise `kFSEventStreamCreateFlagIgnoreSelf` exists to drop.
        let missingBeforeWrite = missingDirtyPaths(in: model)
        let saved = model.saveAllDirty()
        if !saved.isEmpty {
            onSaved?(saved, saved.contains { missingBeforeWrite.contains($0.path) })
        }
        // A file that is still dirty *and* has a url means its write failed
        // (`saveAllDirty()` swallows per-file write errors). Beep once, non-modally
        // — autosave fires unattended and must never surface an alert.
        let writeFailed = model.openFiles.contains { $0.isDirty && $0.url != nil }
        if writeFailed {
            if !didBeepForFailure {
                didBeepForFailure = true
                PlatformFeedback.warning()
            }
        } else {
            didBeepForFailure = false
        }
    }

    /// Paths of the dirty *titled* buffers that do not exist on disk right now — the
    /// ones whose next write creates the file instead of overwriting it. Only dirty
    /// titled buffers are probed (the rest are never written), so the common
    /// nothing-to-save re-fire costs no syscall at all. A dangling symlink reads as
    /// missing here (`fileExists` dereferences), which at worst yields one extra,
    /// idempotent tree bump.
    private func missingDirtyPaths(in model: WorkspaceModel) -> Set<String> {
        var paths: Set<String> = []
        for file in model.openFiles where file.isDirty {
            guard let url = file.url, !FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            paths.insert(url.path)
        }
        return paths
    }

    /// The termination path: respect the *revert* suspend gate only — a quit landing
    /// mid-revert is a rare corner where the revert's intentional discard wins, which
    /// is acceptable — but NOT `modalSuspendCount`, so a quit while a close-confirmation
    /// modal is open still flushes every dirty titled file (the modal gate exists only
    /// to stop the idle debounce from pre-empting "Don't Save", not to drop the
    /// quit-time save of unrelated edits). Writes synchronously before the process
    /// exits.
    ///
    /// `reportingSaves` is what separates the two callers. On the **quit** path it
    /// stays `false`: there is no tree left to bump and no panel left to refresh on
    /// the way out, so the probe and `onSaved` are both skipped (see the
    /// `willTerminateNotification` comment). `openCommitDialog` flushes
    /// *mid-session* — the dialog reads disk, so every dirty buffer has to reach it
    /// first — and there the side effects are mandatory rather than pointless: this
    /// writes files exactly as `performAutosave` does, so without them the Local
    /// Changes panel keeps describing the pre-flush disk state (visibly wrong the
    /// moment the user cancels the dialog, and only corrected by some unrelated
    /// later refresh), and a buffer whose file had been deleted out of band is put
    /// back on disk with no `treeRevision` bump to reveal it — the watcher drops
    /// our own writes, so nothing else ever would.
    ///
    /// Internal rather than private because `PisakaApp` calls it directly from its
    /// own `willTerminateNotification` observer, immediately before
    /// `SessionController.flushNow()`: the session snapshot does not persist the
    /// contents of dirty *titled* files, so it is only truthful once they have
    /// reached disk, and that ordering must be written down in one place instead of
    /// resting on the relative registration order of two independent observers.
    /// Calling it twice on the same quit is harmless — `saveAllDirty()` is
    /// idempotent, so the second run writes nothing.
    func flushNow(reportingSaves: Bool = false) {
        guard suspendCount == 0, let model else { return }
        guard reportingSaves else {
            model.saveAllDirty()
            return
        }
        // The `performAutosave` sequence: probe before the write (a creating write
        // is a change of tree membership the watcher will not report), then report
        // only when something was actually written.
        let missingBeforeWrite = missingDirtyPaths(in: model)
        let saved = model.saveAllDirty()
        guard !saved.isEmpty else { return }
        onSaved?(saved, saved.contains { missingBeforeWrite.contains($0.path) })
    }
}

#endif
