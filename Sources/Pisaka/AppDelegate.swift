#if os(macOS)
import AppKit

/// Promotes the process to a regular GUI app when launched as a bare SwiftPM
/// executable (`swift run`). Without this it runs as an accessory process: no
/// Dock icon and the menu bar stays owned by the launching terminal.
///
/// Also the one place a quit can be *held* (D43): the language servers' polite
/// goodbye runs from `applicationShouldTerminate`, before the process starts
/// going away, rather than from the `willTerminate` observer, which is too late
/// for anything `async`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by `PisakaApp` once its workspace exists — the adaptor builds
    /// the delegate before the app struct, so the workspace can only arrive
    /// through a closure. Answers the teardown to wait for, or `nil` when no
    /// server is alive or launching and the quit may go at once.
    var languageServerTeardown: (@MainActor () -> (@MainActor () async -> Void)?)?

    /// Installed by `PisakaApp` beside `languageServerTeardown`, and asked
    /// **first**, before any teardown is requested: it puts the external-change
    /// question (Overwrite / Reload / Cancel) for each dirty tab whose file
    /// changed on disk. `.cancel` cancels the quit with nothing torn down and
    /// nothing flushed; `.proceed` may carry work to wait for — the Local History
    /// captures the answers queued — before the process is let go. The first
    /// round alternates with the flush until a flush skips nothing; after the
    /// teardown's wait it is asked again (`askUntilFlushed()`), for a conflict
    /// that arose during the wait.
    var externalChangeQuestion: (@MainActor () -> ExternalChangeQuitAnswer)?

    /// Installed beside `externalChangeQuestion`: the quit's own flush
    /// (`AutosaveController.flushNow(abandoningBuffers: true)`), answering `true`
    /// when it skipped a tab in conflict. Run in the same synchronous stretch as
    /// each round of the question, right after it, so the question and the write
    /// are one step: a file another process changed after that round is skipped
    /// here and sends the quit back to the question, instead of being skipped
    /// silently by the `willTerminate` flush with the edits lost. The first round
    /// flushes **before** the language-server teardown is requested, so a Cancel
    /// in that round leaves the servers running. The `willTerminate` flush then
    /// finds nothing dirty.
    var flushBeforeTermination: (@MainActor () -> Bool)?
    private var isAwaitingTeardown = false

    /// Native window tabbing is off before any window exists. The app has one
    /// `WindowGroup` window and its own editor tabs; left on, AppKit adds Window
    /// menu "Show Next Tab / Show Previous Tab" items bound to ⌃Tab / ⌃⇧Tab, which
    /// no source scan can see and which would take those chords from the
    /// editor-tab commands. `MenuShortcutUniquenessTests` pins this assignment.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quit waits for the servers to leave on their own (D43): `shutdownAll()`
    /// sends each one `shutdown` → `exit`, closes its stdin and gives it one exit
    /// grace — concurrently across servers — before any signal, and only then is
    /// the termination allowed to proceed. Nothing to wait for answers
    /// `.terminateNow` at once. The `willTerminate` observer's `terminateNow()`
    /// stays the fallback for anything this did not reach.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminate { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// The quit's whole sequence, with the deferred answer taken as `reply` so a
    /// headless test can observe it without terminating its host. It asks, then
    /// flushes, then tears down:
    ///
    /// 1. The first round runs synchronously on the main actor: the question, then
    ///    the flush, again until a flush skips nothing. A Cancel there answers
    ///    `.terminateCancel` with nothing flushed by the quit and no teardown
    ///    requested — the language servers keep running.
    /// 2. Only then is `languageServerTeardown` read. Nothing to wait for — no
    ///    server and no Local History capture — answers `.terminateNow`.
    /// 3. Otherwise the reply is deferred: the captures and the teardown are
    ///    awaited, then `askUntilFlushed()` asks about whatever fell into conflict
    ///    during the wait, the one case where a Cancel after the teardown is still
    ///    reachable.
    @MainActor
    func shouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        // A second ⌘Q while the first is still waiting changes nothing: the one
        // reply below answers it.
        guard !isAwaitingTeardown else { return .terminateLater }
        var pending: [@MainActor () async -> Void] = []
        repeat {
            switch externalChangeQuestion?() {
            case .cancel:
                return .terminateCancel
            case .proceed(let awaiting):
                if let awaiting { pending.append(awaiting) }
            case nil:
                break
            }
        } while !flushLeftNoConflict()
        if let teardown = languageServerTeardown?() { pending.append(teardown) }
        guard !pending.isEmpty else { return .terminateNow }
        isAwaitingTeardown = true
        Task { @MainActor in
            for work in pending { await work() }
            let proceed = await askUntilFlushed()
            isAwaitingTeardown = false
            reply(proceed)
        }
        return .terminateLater
    }

    /// The question again, once the wait is over. The first round already
    /// flushed, so this one finds only what fell into conflict during the wait.
    /// The window stays live while the quit waits — buffers still take
    /// edits and the disk still moves — and another process can change a file even
    /// between a round and the flush, so a dirty tab can fall into conflict after
    /// any round. Asked until a round finds nothing left to ask *and* the flush
    /// right after it skips nothing (each answer leaves its tab out of conflict, so
    /// this ends), or the user cancels. That last round, the flush and the reply run
    /// in one synchronous stretch on the main actor, so no edit or disk sync slips
    /// in between them. A cancel after a flush leaves the buffers it wrote saved,
    /// trimmed in full as an abandoning save trims. Cancelling here keeps the app
    /// running with its language servers already gone; they start again on the
    /// next request that needs one.
    @MainActor
    private func askUntilFlushed() async -> Bool {
        while true {
            switch externalChangeQuestion?() {
            case .cancel:
                return false
            case .proceed(let awaiting?):
                await awaiting()
            case .proceed(nil), nil:
                if flushLeftNoConflict() { return true }
            }
        }
    }

    /// Runs `flushBeforeTermination`; `true` when nothing was left in conflict.
    @MainActor
    private func flushLeftNoConflict() -> Bool {
        !(flushBeforeTermination?() ?? false)
    }
}

/// The quit's answer to the external-change question
/// (`AppDelegate.externalChangeQuestion`).
enum ExternalChangeQuitAnswer {
    /// The user cancelled one of the questions: the quit does not happen.
    case cancel
    /// Quit, after `awaiting` (when present) has finished.
    case proceed(awaiting: (@MainActor () async -> Void)?)
}
#endif
