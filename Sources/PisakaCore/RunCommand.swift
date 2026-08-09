import Foundation

/// Pure, testable resolution of how to *run* the editor's current file in the
/// embedded terminal.
///
/// The PTY/session lifecycle lives in the `Pisaka` view layer (a macOS-only
/// concern, like `TerminalLaunch`/`TerminalSession`); only this branch-free
/// command/quoting/directory resolution lives in Core so it stays
/// Foundation-only and unit-tested (the `TerminalLaunch`/`FileIcon` precedent).
public enum RunCommand {
    /// Lowercased file extension → the runner tokens that precede the quoted
    /// path. Mirrors `FileIcon`/`SyntaxLanguage`'s extension-map pattern.
    private static let runners: [String: [String]] = [
        "ts": ["npx", "tsx"],
        "tsx": ["npx", "tsx"],
        "js": ["node"],
        "mjs": ["node"],
        "cjs": ["node"],
        "py": ["python3"],
        "swift": ["swift"],
        // `go run <file>` compiles and runs that one file, so a `main` split
        // across several files of a package needs `go run .` from the terminal.
        // Every entry in this map runs a single file — that is the map's shape,
        // not a Go-specific shortfall.
        "go": ["go", "run"],
        "sh": ["bash"],
        "bash": ["bash"],
    ]

    /// The shell command that runs `fileName` (at `absolutePath`), or `nil` when
    /// the file's extension has no known runner. The path is shell-quoted so
    /// spaces and shell metacharacters survive intact.
    public static func command(forFileName fileName: String, absolutePath: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let tokens = runners[ext] else { return nil }
        return tokens.joined(separator: " ") + " " + ShellQuote.quote(absolutePath)
    }

    /// Whether `fileName`'s extension has a known runner (drives the "Run"
    /// context-menu item and the ⌘R menu enablement).
    public static func canRun(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return runners[ext] != nil
    }

    /// The directory the run session starts in: the opened `projectRoot` when
    /// there is one, else the file's own folder.
    public static func workingDirectory(projectRoot: URL?, fileURL: URL) -> URL {
        projectRoot ?? fileURL.deletingLastPathComponent()
    }
}
