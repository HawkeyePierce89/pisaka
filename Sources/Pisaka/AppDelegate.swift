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
    private var isAwaitingTeardown = false

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
        // A second ⌘Q while the first is still waiting changes nothing: the one
        // reply below answers it.
        guard !isAwaitingTeardown else { return .terminateLater }
        guard let teardown = languageServerTeardown?() else { return .terminateNow }
        isAwaitingTeardown = true
        Task { @MainActor in
            await teardown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
