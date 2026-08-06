import Foundation

/// Pure, testable launch-parameter resolution for the embedded terminal.
///
/// The PTY, rendering, and lifecycle all live in the `Pisaka` view layer (a
/// macOS-only concern, like `CodeEditorView`/`GitCLIService`); only this
/// branch-free parameter resolution lives in Core so it stays Foundation-only
/// and unit-tested.
public enum TerminalLaunch {
    /// The shell to launch: the user's `$SHELL` when set and not blank, else
    /// `/bin/zsh` (the macOS default). A whitespace-only value is treated as unset
    /// rather than passed to `forkpty` as a bogus executable path (matching the
    /// blank-input handling in `FileName`/`LogFilter`).
    public static func shell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"],
           !shell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    /// The working directory a new session starts in: the opened `projectRoot`
    /// when there is one, else the user's `home` directory.
    public static func workingDirectory(projectRoot: URL?, home: URL) -> URL {
        projectRoot ?? home
    }
}
