#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// Owns the embedded terminal's live sessions and the active tab.
///
/// Thin view-layer state (like `WorkspaceModel` is for the editor, but with no
/// pure logic to test beyond `TerminalLaunch`): it creates/closes/activates
/// sessions and terminates their shells. Switching tabs only changes `activeID`,
/// never the `sessions` array, so a running shell is never recreated.
final class TerminalSessionsModel: ObservableObject {
    /// All open terminal sessions, in tab order.
    @Published private(set) var sessions: [TerminalSession] = []

    /// The currently shown session, or `nil` when there are none.
    @Published private(set) var activeID: UUID?

    /// Monotonic counter so tab titles ("Terminal 1", "Terminal 2", …) stay unique
    /// even as earlier tabs are closed.
    private var sessionCounter = 0

    /// Session key (`"run:"`/`"test:"` prefix + canonical file path) → the id of the
    /// dedicated session launched for it, so a repeat run/test of the same file
    /// reuses (recreates) its dedicated tab instead of piling up a new one each
    /// time. The prefix keeps a file's run and test sessions independent. An entry
    /// is dropped when its session is closed (manual close → next run is fresh).
    private var runSessions: [String: UUID] = [:]

    /// The appearance the terminal was last themed for, remembered so a session
    /// created *later* (a new tab, a Run/Test session) is born in the right colors
    /// instead of flashing SwiftTerm's dark defaults.
    ///
    /// Deliberately a plain stored property rather than `@Published`: applying a
    /// theme recolors the AppKit views directly and bypasses SwiftUI entirely, so
    /// publishing it would only invalidate the panel for a redraw that changes
    /// nothing.
    private var appearance: NSAppearance?

    /// Observer for `NSColor.systemColorsDidChangeNotification`, removed on deinit.
    private var systemColorsObserver: NSObjectProtocol?

    /// Subscribes to system color changes so the terminal keeps following the user's
    /// **accent color**, which the caret and selection are derived from.
    ///
    /// The panel host's `viewDidChangeEffectiveAppearance` hook covers a light/dark
    /// switch, but an accent change leaves the effective appearance untouched and so
    /// fires no such callback — without this the sessions would keep the old accent
    /// until the panel happened to be remounted. Re-applying is safe to do on every
    /// notification: each session compares the resolved `TerminalTheme.ThemeKey` and
    /// ignores a request that changes nothing (see `TerminalSession.applyTheme`), so
    /// an unrelated system color change never resets colors the terminal itself set
    /// through OSC 4/10/11/12.
    init() {
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let appearance = self.appearance else { return }
            self.applyTheme(for: appearance)
        }
    }

    deinit {
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
        }
    }

    /// The active session, or `nil` when there are none.
    var activeSession: TerminalSession? {
        guard let activeID else { return nil }
        return sessions.first { $0.id == activeID }
    }

    /// Remembers `appearance` and recolors **every** live session for it — not just
    /// the active one, so switching to a tab that was off screen during the change
    /// never reveals the old theme (nothing else would recolor it: an inactive
    /// session's view is out of the hierarchy and gets no appearance callback of
    /// its own).
    ///
    /// Idempotent, so the panel host (and the accent-color observer above) can call
    /// it on mount and on every appearance change without tracking whether the
    /// colors actually changed: each session skips a request whose resolved colors
    /// it already carries, which is what keeps a tab switch from resetting colors
    /// the terminal itself set through OSC 4/10/11 (see
    /// `TerminalSession.applyTheme(for:)`).
    func applyTheme(for appearance: NSAppearance) {
        self.appearance = appearance
        for session in sessions {
            session.applyTheme(for: appearance)
        }
    }

    /// Colors a freshly created session before it is ever drawn, so a new tab does
    /// not appear in SwiftTerm's dark defaults and then flip.
    ///
    /// `NSApp.effectiveAppearance` is only a fallback for the window between app
    /// launch and the panel host's first mount: a theme forced through
    /// `ThemePreference` is applied by SwiftUI's `.preferredColorScheme` to the
    /// *window*, not the application, so it is not visible here. The host corrects
    /// the color from the container's own `effectiveAppearance` on the same
    /// main-loop turn, and from then on `appearance` is the remembered truth.
    private func applyCurrentTheme(to session: TerminalSession) {
        session.applyTheme(for: appearance ?? NSApp.effectiveAppearance)
    }

    /// Creates a new session in `projectRoot` (or the home directory when no folder
    /// is open) and makes it active. The shell and working directory are resolved
    /// by `PisakaCore.TerminalLaunch`.
    @discardableResult
    func newSession(projectRoot: URL?) -> TerminalSession {
        sessionCounter += 1
        let shell = TerminalLaunch.shell(environment: ProcessInfo.processInfo.environment)
        let workingDirectory = TerminalLaunch.workingDirectory(
            projectRoot: projectRoot,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let session = TerminalSession(
            title: "Terminal \(sessionCounter)",
            shell: shell,
            workingDirectory: workingDirectory
        )
        applyCurrentTheme(to: session)
        sessions.append(session)
        activeID = session.id
        return session
    }

    /// Runs `url`'s file in a dedicated "Run:" session: the shell is resolved by
    /// `PisakaCore.TerminalLaunch`, the working directory is passed in (resolved by
    /// `RunCommand.workingDirectory`), and `command` (from `RunCommand`) is typed
    /// into the fresh shell. A previous live run session for the *same* file
    /// (keyed by canonical path) is closed first so the tab is recreated rather
    /// than accumulating, mirroring a "re-run" replacing the old output.
    @discardableResult
    func runFile(url: URL, command: String, workingDirectory: URL, title: String) -> TerminalSession {
        run(
            sessionKey: "run:" + url.resolvingSymlinksInPath().path,
            command: command,
            workingDirectory: workingDirectory,
            title: title
        )
    }

    /// Runs `url`'s per-file test in a dedicated "Test:" session, mirroring
    /// `runFile` but under a `"test:"`-prefixed key so a file's run and test
    /// sessions are independent (each reuses/recreates only its own tab). The
    /// `command` comes from `PisakaCore.TestCommand`, the working directory from
    /// `TestCommand.workingDirectory`.
    @discardableResult
    func testFile(url: URL, command: String, workingDirectory: URL, title: String) -> TerminalSession {
        run(
            sessionKey: "test:" + url.resolvingSymlinksInPath().path,
            command: command,
            workingDirectory: workingDirectory,
            title: title
        )
    }

    /// Shared body for `runFile`/`testFile`: closes any still-live session under
    /// `sessionKey`, creates a fresh shell (resolved by `PisakaCore.TerminalLaunch`)
    /// in `workingDirectory`, makes it active, records it under `sessionKey`, and
    /// types `command` into it.
    @discardableResult
    private func run(sessionKey: String, command: String, workingDirectory: URL, title: String) -> TerminalSession {
        if let existingID = runSessions[sessionKey], sessions.contains(where: { $0.id == existingID }) {
            close(id: existingID)
        }
        let shell = TerminalLaunch.shell(environment: ProcessInfo.processInfo.environment)
        let session = TerminalSession(
            title: title,
            shell: shell,
            workingDirectory: workingDirectory
        )
        applyCurrentTheme(to: session)
        sessions.append(session)
        activeID = session.id
        runSessions[sessionKey] = session.id
        session.run(command: command)
        return session
    }

    /// Makes `id` the active tab. A no-op for an unknown id; never recreates the
    /// session.
    func activate(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Closes the session: terminates its shell, drops the tab, and re-selects a
    /// neighbor (the previous tab, else the new first) so the panel never lands on
    /// a now-missing session. A no-op for an unknown id.
    func close(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminate()
        // Resolve the next active tab from the order *before* removal (the pure
        // index math lives in `TerminalTabs`), then drop the closed session.
        let nextActive = TerminalTabs.activeIDAfterClosing(
            id, order: sessions.map(\.id), active: activeID
        )
        sessions.remove(at: index)
        activeID = nextActive
        // A manually closed run session must not be reused by a later run of the
        // same file — drop any mapping pointing at it so the next run is fresh.
        runSessions = runSessions.filter { $0.value != id }
    }

    /// Terminates every shell and clears the tabs. Called on app termination so no
    /// shell processes leak.
    func terminateAll() {
        for session in sessions {
            session.terminate()
        }
        sessions.removeAll()
        activeID = nil
        runSessions.removeAll()
    }
}

#endif
