#if os(macOS)
import CoreServices
import Foundation
import PisakaCore

/// Watches the opened project folder with FSEvents and reports "something in the
/// tree changed" so the app can bump `WorkspaceModel.treeRevision` — which is what
/// makes an *external* change (a `npx @nestjs/cli new backend` in the embedded
/// terminal, a Finder rename, a `git checkout` in a console) show up in the project
/// tree without reopening the folder.
///
/// Thin and deliberately untested, per the project convention for the view layer:
/// this class is IO only (a C FSEvents stream, its queue, and its lifetime), while
/// the one decision it makes — "is this batch worth a re-read" — lives in Core as
/// the pure, unit-tested `TreeRefreshFilter`. It copies `AutosaveController`'s
/// shape: an idempotent `start(...)`, a `stop()` safe to call more than once, and
/// `deinit` teardown. macOS-only — FSEvents does not exist on iOS, where the tree
/// still refreshes only on the app's own operations.
///
/// The stream's flags are chosen as follows.
///
/// - **Directory-level events (no `kFSEventStreamCreateFlagFileEvents`).** Knowing
///   *which directory* changed is enough: the re-read is per-directory anyway
///   (`DirectoryNodeView` re-runs `children(of:)`). Two consequences for
///   `TreeRefreshFilter`: its `.git` rule is unaffected — a `git` run's writes are
///   reported as the directories `root/.git`, `root/.git/objects/xx`,
///   `root/.git/refs/heads`, all same-or-descendant of `root/.git`, so the batch is
///   dropped and the tree does not flicker — while its `.DS_Store` rule is *dormant*:
///   a Finder write to `root/.DS_Store` arrives as the directory `root`, passes the
///   filter, and causes one harmless bump (the listing excludes `.DS_Store`, so the
///   children array is unchanged and nothing visibly moves).
/// - **`kFSEventStreamCreateFlagIgnoreSelf`** — events caused by *this* process are
///   dropped before they ever reach the filter. The app's own create / rename /
///   delete already bump `treeRevision` synchronously, so a self-event would be pure
///   duplication; more importantly autosave writes a file on every idle burst / tab
///   switch / focus loss, and under dir-level events each such write reports the
///   containing directory — a recurring bump, i.e. a synchronous
///   `contentsOfDirectory` re-read of every expanded node on the main thread, for a
///   change that never alters the listing. What the flag does *not* suppress: the
///   embedded terminal's shell and every `GitCLIService` invocation are child
///   processes with their own pids, so their events still arrive normally (the
///   headline `npx … new backend` case is unaffected). The in-app writes that change
///   tree membership each bump explicitly instead, so the flag loses no coverage:
///   `PisakaApp.saveAs(id:)` (an Untitled buffer written into the project folder),
///   `PisakaApp.revertChanges` (reverting an *untracked* file is an in-process
///   `unlinkat`, not a `git` subprocess), and an ordinary Save/autosave that
///   *recreates* a file deleted out of band — `write(_:to:)` creates a missing file,
///   so the tab's file reappears on disk after the watcher already dropped it from
///   the tree. That last case is bumped only when the pre-write probe says the file
///   was actually missing (`PisakaApp.save(id:)`,
///   `AutosaveController.missingDirtyPaths(in:)`); an ordinary overwrite leaves every
///   listing identical and stays unbumped, which is the frequent self-noise this flag
///   exists to drop.
/// - **Latency `1.0` s with ordinary deferred coalescing** (no
///   `kFSEventStreamCreateFlagNoDefer`) — an `npm i` producing thousands of events
///   collapses into a handful of firings instead of a bump per file.
/// - **`kFSEventStreamCreateFlagUseCFTypes`** so the callback's paths arrive as a
///   `CFArray` of `CFString`, and `sinceWhen = kFSEventStreamEventIdSinceNow` (the
///   history before the folder was opened is of no interest).
///
/// The stream is scheduled on its own serial dispatch queue
/// (`FSEventStreamSetDispatchQueue`), so neither the callback nor the filter runs on
/// the main thread; only the final `onChange()` hops back to the main actor.
///
/// The watched root is **canonicalized** (`realpath(3)`, see `canonical(_:)`) before
/// it reaches either the stream or the filter: FSEvents reports realpath-spelled paths
/// no matter how the watched path was spelled, so a folder opened through a symlink
/// (`~/dev -> /Volumes/Data/dev`) or through a firmlink (`/tmp` → `/private/tmp`)
/// would otherwise have *every* delivered path fail `TreeRefreshFilter`'s
/// "same-or-descendant of `root`" rule and silently disable the whole feature. Only
/// the watcher canonicalizes — `WorkspaceModel.projectRoot` stays as the user
/// spelled it, since the tree's own symlink semantics depend on that.
final class ProjectWatcher {
    /// Coalescing window handed to FSEvents (seconds). See the type doc comment.
    private let latency: CFTimeInterval = 1.0

    /// The stream's own serial queue — the callback (and so `TreeRefreshFilter`)
    /// runs here, never on the main thread.
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.ProjectWatcher")

    /// The live stream, `nil` while not watching. Touched only from the main actor
    /// (`start`/`stop`).
    private var stream: FSEventStreamRef?

    /// The `+1`-retained `self` pointer handed to the stream as its context `info`,
    /// kept so `stop()` can balance the retain without re-deriving it.
    private var contextInfo: UnsafeMutableRawPointer?

    /// Guards `root`/`onChange`, which are written by `start`/`stop` (main thread)
    /// and read by the callback (`queue`) — the `SecurityScopedFileService`
    /// precedent.
    private let lock = NSLock()
    private var root: URL?
    private var onChange: (() -> Void)?

    /// Begin watching `root`, calling `onChange` on the main actor for every batch
    /// `TreeRefreshFilter` considers worth a re-read.
    ///
    /// Idempotent in the `AutosaveController.start` sense: a repeated call first
    /// tears the previous stream down, so switching the opened folder simply
    /// switches the subscription (events from the old root stop arriving).
    func start(root: URL, onChange: @escaping () -> Void) {
        stop()

        // FSEvents delivers realpath-spelled paths regardless of how the watched
        // path was spelled, and `TreeRefreshFilter` is pure string comparison — so
        // the filter's root must be canonical or it drops every event. See the type
        // doc comment.
        let watchRoot = Self.canonical(root)

        lock.lock()
        self.root = watchRoot
        self.onChange = onChange
        lock.unlock()

        // The context's `info` owns a +1 reference to `self` for the stream's
        // lifetime, balanced in `stop()` (or right here if creation fails), so the
        // callback can never run against a deallocated watcher.
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                projectWatcherCallback,
                &context,
                [watchRoot.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            // Creation failed (a path FSEvents refuses, resource exhaustion): balance
            // the retain and stay unarmed. The manual Refresh button remains the
            // fallback, so a failure here degrades rather than breaks.
            disarm(info: info)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            // Start can fail too (it "must" be balanced by `FSEventStreamStop`, so a
            // never-started stream must not be stopped later). Tear the stream down
            // here and stay unarmed rather than leaving `self.stream` set — which
            // would both look armed and trip FSEvents' stop-without-start assertion
            // at teardown. Same graceful degradation as the create-failure path.
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            disarm(info: info)
            return
        }
        self.stream = stream
        self.contextInfo = info
    }

    /// The fully resolved path, exactly as FSEvents spells the paths it delivers.
    ///
    /// `realpath(3)` and not `URL.resolvingSymlinksInPath()`: the latter resolves
    /// ordinary symlinks but deliberately *strips* a `/private` prefix, so it maps
    /// `/private/tmp` back to `/tmp` — the reverse of what is needed here (a project
    /// under `/tmp` or `/var` gets `/private/…`-spelled events). `URLResourceValues
    /// .canonicalPath` is the mirror-image half-measure: it resolves the firmlink but
    /// keeps the final component literal, so a folder opened *through* a symlink
    /// stays unresolved. `realpath` does both, and on failure (a path that no longer
    /// exists, or an unreadable parent) falls back to the url as given — the stream
    /// creation below then fails or matches nothing, which is the same graceful
    /// degradation as an unarmed watcher: the Refresh button still works.
    private static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Shared cleanup for the two `start` failure paths: balance the context retain
    /// and clear the filter state so the watcher is inert (and `stop()` a no-op).
    private func disarm(info: UnsafeMutableRawPointer) {
        lock.lock()
        self.root = nil
        self.onChange = nil
        lock.unlock()
        Unmanaged<ProjectWatcher>.fromOpaque(info).release()
    }

    /// Stop watching and release the stream. Safe to call more than once (and when
    /// never started) — the app calls it on `willTerminateNotification` so no stream
    /// outlives the process.
    func stop() {
        guard let stream else { return }
        self.stream = nil
        // Stop delivering, unschedule from the queue, then drop the stream itself —
        // the order the FSEvents API requires.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        lock.lock()
        root = nil
        onChange = nil
        lock.unlock()

        // `FSEventStreamInvalidate` does not wait for a callback already running on
        // the stream's dispatch queue, and that callback holds only an *unretained*
        // reference. Drain the queue before the balancing release below, so an
        // in-flight `handle(changedPaths:)` can never be operating on a watcher the
        // release deallocates. No deadlock risk: `handle` only ever does
        // `DispatchQueue.main.async`, never a sync hop back.
        queue.sync {}

        // Balance the `passRetained` from `start` — the stream is gone, so nothing
        // can reach the context pointer anymore. Done *last*, and with no `self`
        // access after it: this release can be the one that deallocates the watcher.
        if let info = contextInfo {
            contextInfo = nil
            Unmanaged<ProjectWatcher>.fromOpaque(info).release()
        }
    }

    /// Backstop for an instance that was never started or was already stopped: while
    /// a stream is live the context holds a strong reference, so `deinit` cannot run
    /// until `stop()` has released it (`PisakaApp` owns the watcher for the app's
    /// lifetime and stops it on termination).
    deinit { stop() }

    /// Callback body, running on `queue`. The only logic here is the Core filter —
    /// everything else (who produced the event) was already decided by the stream
    /// flags.
    fileprivate func handle(changedPaths: [String]) {
        lock.lock()
        let root = self.root
        let onChange = self.onChange
        lock.unlock()
        guard let root, let onChange else { return }
        guard TreeRefreshFilter.shouldRefresh(changedPaths: changedPaths, root: root) else {
            return
        }
        DispatchQueue.main.async { onChange() }
    }
}

/// The C callback FSEvents invokes — a global function pointer (it captures
/// nothing; the watcher arrives through the context's `info`).
private let projectWatcherCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
    // `kFSEventStreamCreateFlagUseCFTypes` means `eventPaths` is a CFArray of
    // CFString (toll-free bridged to `NSArray`), not a C string array.
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.handle(changedPaths: paths)
}

#endif
