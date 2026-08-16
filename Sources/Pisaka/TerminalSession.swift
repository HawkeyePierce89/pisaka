#if os(macOS)
import AppKit
import SwiftTerm
import PisakaCore

/// One live shell session in the embedded terminal: a stable identity, a display
/// title, and the `LocalProcessTerminalView` that hosts the PTY-backed shell.
///
/// This is intentionally thin view-layer code (like `CodeEditorView`): the only
/// pure, testable part — resolving which shell to launch and in which directory —
/// lives in `PisakaCore.TerminalLaunch`. The session is created with those already
/// resolved values and immediately starts the shell process.
final class TerminalSession: Identifiable {
    /// Stable identity, so the tab bar and the model can refer to a session across
    /// SwiftUI redraws without recreating its running shell.
    let id = UUID()

    /// Title shown on the tab. Assigned by `TerminalSessionsModel` at creation; not
    /// renamed at runtime (YAGNI: no tab rename).
    let title: String

    /// The AppKit view that renders the terminal and owns the PTY-backed shell.
    /// Retained for the session's whole lifetime so switching tabs only swaps which
    /// view is in the hierarchy — it never restarts the shell.
    let terminalView: LocalProcessTerminalView

    /// Starts a shell process in `workingDirectory`.
    ///
    /// SwiftTerm 1.5.0's *view-level* `startProcess` does not take a working
    /// directory, but the module-internal `LocalProcess.startProcess` does — and we
    /// already reach that instance through `Mirror` (see `terminate()`), so we pass
    /// `workingDirectory` straight through it. This avoids mutating the app-wide
    /// current directory (which would race any concurrent relative-path work and,
    /// if the `chdir` silently failed, start the shell in the wrong place).
    ///
    /// Only if the (exact-version-pinned) reflection ever fails to find the process
    /// do we fall back to the cwd-swap the view API forces — point the process cwd
    /// at `workingDirectory` just long enough for the `forkpty` (the child inherits
    /// it) then restore it, the same approach SwiftTerm's own sample app uses.
    init(title: String, shell: String, workingDirectory: URL) {
        self.title = title
        self.terminalView = LocalProcessTerminalView(frame: .zero)

        // Launch as a login shell: argv[0] prefixed with "-" is the Unix convention
        // that tells the shell to source the user's login profile.
        let execName = "-" + (shell as NSString).lastPathComponent

        if let process = Self.localProcess(of: terminalView) {
            process.startProcess(executable: shell, execName: execName, currentDirectory: workingDirectory.path)
        } else {
            let fileManager = FileManager.default
            let previousDirectory = fileManager.currentDirectoryPath
            fileManager.changeCurrentDirectoryPath(workingDirectory.path)
            defer { fileManager.changeCurrentDirectoryPath(previousDirectory) }
            terminalView.startProcess(executable: shell, execName: execName)
        }
    }

    /// Types `command` into the shell as if the user had entered it (a trailing
    /// newline submits it). The session's login shell and working directory are
    /// already set at launch, so no `cd` is needed — the resolved run command
    /// carries the (shell-quoted) file path.
    func run(command: String) {
        terminalView.send(txt: command + "\n")
    }

    /// The colors this session currently carries, or `nil` while it still carries
    /// SwiftTerm's own defaults.
    ///
    /// Keyed by the *resolved colors* (`TerminalTheme.ThemeKey`), not by
    /// `NSAppearance.Name`: the caret and selection are semantic system colors that
    /// follow the user's accent color, which changes them while the appearance name
    /// stays `.aqua`/`.darkAqua` — a name-keyed guard would keep every live session
    /// on the old accent indefinitely.
    private var appliedTheme: TerminalTheme.ThemeKey?

    /// Recolors this session for `appearance` (the built-in light/dark palettes in
    /// `TerminalTheme`), skipping the work when it already carries exactly those
    /// colors.
    ///
    /// The recolor happens on the live `LocalProcessTerminalView`: the shell process,
    /// its PTY and the whole scrollback are untouched, so a theme change repaints
    /// what is already on screen rather than restarting anything.
    ///
    /// The unchanged-theme guard is not just an optimization. Applying a theme is a
    /// full *reset* of exactly the state the terminal's own escape sequences write
    /// to: `installColors` reinstalls the ANSI-16 palette (SwiftTerm's
    /// `installPalette` assigns `ansiColors = defaultAnsiColors`, discarding every
    /// OSC 4 entry a program or the user's profile set) and
    /// `setBackgroundColor`/`setForegroundColor`/`caretColor` overwrite what OSC
    /// 10/11/12 set. The panel host calls in on every mount and every tab switch —
    /// and each call recolors *all* sessions — so without the guard an ordinary tab
    /// switch would silently undo those. A real theme change still resets them:
    /// there the app theme deliberately wins.
    ///
    /// The guard compares the whole resolved `ThemeKey` rather than the appearance
    /// name, so an accent-color change (which alters the caret and selection without
    /// altering the name) is a real change and does re-apply.
    func applyTheme(for appearance: NSAppearance) {
        let theme = TerminalTheme.key(for: appearance)
        guard appliedTheme != theme else { return }
        appliedTheme = theme
        TerminalTheme.apply(to: terminalView, appearance: appearance)
    }

    /// The point size this session's font currently carries, or `nil` while it
    /// still carries SwiftTerm's own default font.
    private var appliedFontSize: Double?

    /// Redraws this session at `size` points, the terminal zoom zone's persisted
    /// value (`SettingsStore.terminalFontSize`).
    ///
    /// The font is built exactly the way SwiftTerm builds its own default —
    /// `NSFont.monospacedSystemFont(ofSize:weight: .regular)`, which at the
    /// zone's default of 13 (`NSFont.systemFontSize`) is the very font the view
    /// was already drawing with. So a fresh install at 100% is byte-identical to
    /// today, and only a deliberate zoom changes anything.
    ///
    /// Setting `TerminalView.font` re-derives the whole font set, recomputes the
    /// cell dimensions and `resize`s the terminal to the new column/row count —
    /// which resizes the *PTY* — so the running shell reflows to the new size
    /// rather than being restarted. The scrollback and the process are untouched.
    ///
    /// The unchanged-size guard is load-bearing for the same reason
    /// `applyTheme(for:)`'s is, and then some: SwiftTerm's setter also calls
    /// `selectNone()`, so an unconditional assignment would drop the user's
    /// selection. This is called from the window root on every settings change
    /// *and* on mount, and each call fans out over every live session, so without
    /// the guard an unrelated preference edit would clear a selection in a
    /// terminal the user never touched — and pay a full font-set rebuild and PTY
    /// resize per session for it.
    func applyFont(size: Double) {
        guard appliedFontSize != size else { return }
        appliedFontSize = size
        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// Sends `SIGTERM` to the shell so a closed tab / app quit doesn't leak it.
    ///
    /// Only signals a *live* child: if the shell already exited its `shellPid` is
    /// stale (and may have been reused by an unrelated process), and if the launch
    /// failed `shellPid` is 0 — `kill(0, SIGTERM)` would signal our whole process
    /// group. SwiftTerm's `LocalProcess.terminate()` does neither check, so we gate
    /// on the public `running`/`shellPid` before calling it.
    func terminate() {
        guard let process = Self.localProcess(of: terminalView) else { return }
        guard process.running, process.shellPid > 0 else { return }
        process.terminate()
    }

    /// Reaches SwiftTerm 1.5.0's view-internal `LocalProcess` through `Mirror`.
    ///
    /// Note the terminal's zoom surface is declared on SwiftTerm's *view* class
    /// below, not here: the pointer walk finds `NSView`s, and a session is not
    /// one.
    /// The dependency is pinned to an exact version (see `Package.swift`), so the
    /// stored-property name (`process`) stays stable.
    private static func localProcess(of view: LocalProcessTerminalView) -> LocalProcess? {
        for child in Mirror(reflecting: view).children where child.label == "process" {
            return child.value as? LocalProcess
        }
        return nil
    }
}

/// SwiftTerm's terminal view *is* the terminal zoom zone's surface.
///
/// Declared as an extension on the dependency's own class because that is the
/// view the pointer is over: it is what `TerminalPanelView` puts on screen, and
/// there is no subclass of ours between it and the user. The conformance carries
/// no behavior — the app's one event monitor does the work — which is what makes
/// extending a third-party class here harmless.
///
/// `TerminalView` rather than `LocalProcessTerminalView`: the subclass inherits
/// it, and the base class is the one that actually draws the cells the pointer
/// is over.
extension TerminalView: ZoomSurfaceProviding {
    var zoomSurfaceKind: ZoomSurfaceKind { .terminal }
}

#endif
