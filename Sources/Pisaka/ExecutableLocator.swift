#if os(macOS)
import Foundation
import PisakaCore

/// Where a program somebody else installed is on *this* Mac: the one definition
/// of the search, and the `PATH` it must be run under.
///
/// Lifted verbatim from `LSPRustToolchainService`, which is now one of its two
/// callers; the other is `GitHubCLIProcessTransport`. Every decision below —
/// the three steps, their order, and why the second half of the answer exists at
/// all — was written there and is restated here because this is where it now
/// lives. **`LSPGoToolchainService` is deliberately not a caller**: it carries a
/// directory list and a set of decisions of its own, and folding it in would mean
/// changing them. One definition, two callers, pinned by
/// `GitHubSourceGatingTests`.
///
/// Nothing here launches anything. The one step that costs a subprocess — the
/// login shell — is handed out as a closure, because *how* a program is run
/// (which registry the child goes in, which deadline it gets, what happens to it
/// on quit) is the caller's business and differs between the two.
enum ExecutableLocator {
    /// A program and the `PATH` it must be run with.
    ///
    /// **The second half is never empty and always contains the first.** It is
    /// load-bearing rather than decorative: a program found through a
    /// version-manager shim re-execs something it looks up on `PATH`, so running
    /// it back under launchd's four directories fails on exactly the machines the
    /// login-shell step was added for. `gh pr checkout` needs to find `git` the
    /// same way.
    struct Found: Equatable {
        let path: String
        let searchPath: String
    }

    /// Run a program and hand back its standard output, or `nil` if it could not
    /// be run or did not exit zero.
    ///
    /// The caller owns the deadline, the child registry and the teardown; this
    /// type owns which program is run and how its answer is read.
    typealias ProgramRunner = (_ executable: URL, _ arguments: [String]) -> String?

    /// The first `name` that exists, cheapest lookup first.
    ///
    /// Order is the decision. The inherited `PATH` comes first because an app
    /// started from a terminal should use the program that terminal would have
    /// run. `wellKnownDirectories` comes next because it is a handful of `stat`s
    /// and covers the mainstream installs. The login shell comes **last**, because
    /// it is the only step that costs a subprocess and the only one that can find
    /// a version-manager shim (`asdf`, `mise`, a prefix nobody else guesses) — so
    /// it runs exactly on the machines that need it.
    static func locate(
        _ name: String,
        wellKnownDirectories: [String],
        runningProgram: ProgramRunner
    ) -> Found? {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let inherited = pathEntries(inheritedPath)
        if let found = firstExecutable(named: name, in: inherited) {
            return Found(path: found, searchPath: inheritedPath)
        }
        if let found = firstExecutable(named: name, in: wellKnownDirectories) {
            // The one branch that has to *build* a `PATH` rather than report one:
            // the app's environment was not what found this program, a few `stat`s
            // were. Prepended rather than appended so this is the copy that runs
            // even if a later entry has another, which keeps the program this
            // answer names and the program anything resolving it by name later
            // finds the same one.
            let directory = (found as NSString).deletingLastPathComponent
            let rest = inherited.filter { $0 != directory }
            return Found(path: found, searchPath: ([directory] + rest).joined(separator: ":"))
        }
        guard let login = loginShellPath(runningProgram: runningProgram) else { return nil }
        guard let found = firstExecutable(named: name, in: pathEntries(login)) else { return nil }
        return Found(path: found, searchPath: login)
    }

    /// What the user's login shell thinks `PATH` is, or `nil`.
    ///
    /// Three decisions, all of them the ones `LSPRustToolchainService` wrote.
    /// `-l` and not `-i`: a login shell reads the profile files where `PATH` is
    /// actually assembled, while an interactive one additionally reads the rc
    /// files, where a prompt framework may print, ask, or simply take a second.
    /// `PATH` is asked for rather than `command -v <name>`, so that what comes
    /// back is a list of directories the caller then checks itself — a shell
    /// function or alias would answer `command -v` with something that is not a
    /// path, and the failure would be a launch error later rather than a lookup
    /// that simply found nothing. And it is asked for by running `env` and reading
    /// the `PATH=` line rather than by interpolating `"$PATH"`, because in fish
    /// `PATH` is a *list* variable that expands space-separated, which
    /// `pathEntries` — splitting on `:`, as `PATH` is defined — would read as one
    /// bogus directory.
    static func loginShellPath(runningProgram: ProgramRunner) -> String? {
        let shell = TerminalLaunch.shell(environment: ProcessInfo.processInfo.environment)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        guard let output = runningProgram(URL(fileURLWithPath: shell), ["-l", "-c", "/usr/bin/env"]) else {
            return nil
        }
        let path = output
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("PATH=") }
            .map { String($0.dropFirst("PATH=".count)) }?
            .trimmingCharacters(in: .whitespaces)
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// A `PATH`-shaped string as directories, blanks dropped.
    static func pathEntries(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The first `directory/name` that is actually executable, in the order given.
    static func firstExecutable(named name: String, in directories: [String]) -> String? {
        executables(named: name, in: directories).first
    }

    /// Every executable of that name on the list, in order and without repeats.
    ///
    /// The duplicate rule is what makes this usable as a *probe* list rather than
    /// as a listing: `LSPRustToolchainService.locateRustAnalyzer` concatenates the
    /// discovered `PATH` with the well-known directories, and `~/.cargo/bin` is
    /// routinely on both — a second look at the same file would spend a second
    /// subprocess to reach the same answer.
    static func executables(named name: String, in directories: [String]) -> [String] {
        let manager = FileManager.default
        var found: [String] = []
        var seen: Set<String> = []
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name).path
            guard seen.insert(candidate).inserted else { continue }
            if manager.isExecutableFile(atPath: candidate) { found.append(candidate) }
        }
        return found
    }
}

#endif
