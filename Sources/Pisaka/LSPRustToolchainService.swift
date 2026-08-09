#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPRustToolchainDiscovering`: where `cargo` and `rust-analyzer` are
/// on *this* Mac (D23).
///
/// One seam and no second one, unlike Go's file: rust-analyzer publishes official
/// prebuilt binaries, so installing it is `LSPInstallEngine.install(_:)` over the
/// pinned manifest component and the download/unpack pair 2b already has (D21).
/// What is left for this file is the half Core may not do — looking at the disk
/// and running a program to confirm what it found.
///
/// **Core learns no paths.** The inherited `PATH`, `~/.cargo/bin`, Homebrew's two
/// prefixes and the login shell's own `$PATH` are all machine-specific knowledge
/// of exactly the kind D9 keeps out of the domain library, which is why the seam
/// carries an `LSPRustToolchainReport` rather than a search. Every *rule* about
/// what that report permits lives in `LSPRustProvisioningModel` and is unit-tested
/// with no Rust toolchain anywhere in sight; this file is untested by repository
/// convention, like `LSPGoToolchainService` and `LSPDownloadService`, so it is
/// kept to the decisions it actually makes: where to look, in what order, and what
/// counts as not finding anything.
///
/// **Nothing here installs, downloads or writes.** It reads directory entries and
/// runs two programs with `--version`. The one thing it can spawn that is not
/// instant is a login shell, and that runs last and once (see `locateCargo`).
///
/// `@unchecked Sendable` over an `NSLock`, `LSPGoToolchainService`'s arrangement:
/// the lock guards the cached discovery and the live-child registry, is never held
/// across a subprocess wait, and every launched process is reachable from
/// `terminateNow()` — which signals each child's whole *process group*, so a quit
/// during discovery leaves behind neither the login shell nor whatever a profile
/// had it running.
final class LSPRustToolchainService: LSPRustToolchainDiscovering, @unchecked Sendable {
    /// Where the blocking work runs. Concurrent for `LSPGoToolchainService.queue`'s
    /// reason — this is a launch-time search that must never be behind anything
    /// else — even though this service, having no install, only ever has one job.
    private static let queue = DispatchQueue(
        label: "LSPRustToolchainService",
        qos: .utility,
        attributes: .concurrent
    )

    /// The binary name rustup, Homebrew and the official builds all use.
    ///
    /// Spelled here rather than read off `LSPComponent.rustAnalyzer` deliberately:
    /// what this file looks for is a copy of the program *somebody else* put on
    /// this Mac, so the name is a fact about rustup and Homebrew rather than about
    /// the artifact this app pins. The app's own copy is not searched for at all —
    /// the model reads it off the install root, and it wins when both exist (D24).
    private static let rustAnalyzerExecutableName = "rust-analyzer"

    /// Directories that hold a `cargo` on a machine whose `PATH` this app never
    /// saw.
    ///
    /// A Finder-launched app inherits `launchd`'s `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains no `cargo` on any
    /// machine — so without these, "did you start Pisaka from a terminal?" would
    /// decide whether Rust got a language server. `~/.cargo/bin` leads because it
    /// is where rustup puts both `cargo` and the `rust-analyzer` proxy, and rustup
    /// is how nearly everyone has Rust; Homebrew's two prefixes cover the rest.
    private static var wellKnownCargoDirectories: [String] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    /// How long the login shell gets to print its `PATH` before it is killed.
    ///
    /// `LSPGoToolchainService.shellDeadline`, for its reason and with more force:
    /// this runs on every launch of every Mac that has no Rust at all, which is
    /// most of them, and a profile slow enough to miss this is one whose answer is
    /// not worth waiting on. A timeout is not an error here — it is one more way
    /// of finding no toolchain.
    private static let shellDeadline: DispatchTimeInterval = .seconds(5)

    /// How long a `--version` probe gets. It prints one line; ten seconds is
    /// "this program is not answering" rather than "this is slow".
    private static let probeDeadline: DispatchTimeInterval = .seconds(10)

    /// How long a killed child gets to actually die, and its drains to finish.
    private static let teardownGrace: DispatchTimeInterval = .seconds(5)

    private let lock = NSLock()

    /// The one discovery, cached **including the negative answer**.
    ///
    /// `LSPToolchain`'s discipline, for its reason: a machine with no Rust must
    /// not spawn a login shell every time something asks. A `Task` rather than a
    /// stored value so two callers arriving before the first answer await one
    /// search instead of starting two. Per app run, not per folder — a `cargo`
    /// installed while Pisaka is running is picked up at the next launch, stated
    /// rather than papered over with invalidation logic for an event nobody has
    /// hit.
    private var discoveryTask: Task<LSPRustToolchainReport, Never>?

    /// Every child this service has running, so `terminateNow()` can end them all.
    private var children: [Int: ChildProcess] = [:]
    private var nextChildToken = 0
    private var isTornDown = false

    init() {}

    // MARK: - Discovery

    func discover() async -> LSPRustToolchainReport {
        let task: Task<LSPRustToolchainReport, Never>
        lock.lock()
        if let existing = discoveryTask {
            task = existing
        } else {
            task = Task { await self.resolveReport() }
            discoveryTask = task
        }
        lock.unlock()
        return await task.value
    }

    /// The search, moved off whatever called it.
    ///
    /// Blocking from top to bottom — up to three subprocesses and a handful of
    /// `stat`s — so it runs on `queue` and never on the cooperative pool, let alone
    /// the main thread. The model calls `discover()` from app startup, so by the
    /// time anyone opens a `.rs` file the answer is already a stored value.
    private func resolveReport() async -> LSPRustToolchainReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LSPRustToolchainReport, Never>) in
            Self.queue.async {
                continuation.resume(returning: self.search())
            }
        }
    }

    /// A `cargo` that answers, and then whatever rust-analyzer is beside it.
    ///
    /// A `cargo` that cannot answer `cargo --version` is reported as **no
    /// toolchain**, not as a toolchain at a path: the one thing this report is
    /// used for is deciding whether rust-analyzer can be offered and run, and
    /// rust-analyzer shells out to `cargo` to build the project model. Reporting a
    /// broken one as present would offer a 13 MB download that installs a server
    /// answering nothing, and burn D7's restart budget doing it — which is D23's
    /// whole subject. A rustup shim whose toolchain has been removed is the case
    /// that makes this more than hygiene: the file is there and executable, and it
    /// exits non-zero the moment it is asked anything.
    private func search() -> LSPRustToolchainReport {
        guard let found = locateCargo() else { return .missing }
        guard probe(found.path, environment: environment(searchPath: found.searchPath)) else {
            return .missing
        }
        return .found(
            cargoPath: found.path,
            searchPath: found.searchPath,
            rustAnalyzerPath: locateRustAnalyzer(searchPath: found.searchPath)
        )
    }

    /// A `cargo` and the `PATH` it must be run with.
    ///
    /// **The second half is never `nil` and always contains the first.**
    /// `LSPGoToolchainService.FoundGo`'s invariant, and it is load-bearing for the
    /// same reason one step further along: this `PATH` is what Core hands the
    /// server as its `environment` overlay (D23), and rust-analyzer resolves
    /// `cargo` by name off `PATH` exactly as gopls resolves `go`. A `searchPath`
    /// that merely said "the app's own environment was enough to *find* it" would
    /// be true for the well-known directories and useless to the server, so that
    /// branch prepends the directory it found instead.
    private struct FoundCargo {
        let path: String
        let searchPath: String
    }

    /// The first `cargo` that exists, cheapest lookup first.
    ///
    /// Order is the decision, and it is `LSPGoToolchainService.locateGo`'s. The
    /// inherited `PATH` comes first because a Pisaka started from a terminal should
    /// use the `cargo` that terminal would have run. The well-known directories
    /// come next because they are three `stat`s and cover the mainstream installs —
    /// and `~/.cargo/bin` leading them is why the common case, a rustup user who
    /// already has rust-analyzer, costs no subprocess at all. The login shell comes
    /// **last**, because it is the only step here that costs one and the only one
    /// that can find a version-manager shim (`asdf`, `mise`, `rustup` installed
    /// somewhere unusual) — so it runs exactly on the machines that need it, and on
    /// the machines with no Rust at all, once per app run.
    ///
    /// A `cargo` found in the last of those is carried **with** the `PATH` that
    /// found it, and that is the half without which the step buys nothing: a
    /// version-manager `cargo` is a shim that re-execs something it looks up on
    /// `PATH`, so running it back under launchd's four directories fails the probe
    /// and reports "no toolchain" on exactly the machines this step was added for.
    private func locateCargo() -> FoundCargo? {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let inherited = Self.pathEntries(inheritedPath)
        if let found = Self.firstExecutable(named: "cargo", in: inherited) {
            return FoundCargo(path: found, searchPath: inheritedPath)
        }
        if let found = Self.firstExecutable(named: "cargo", in: Self.wellKnownCargoDirectories) {
            // The one branch that has to *build* a `PATH` rather than report one:
            // the app's environment was not what found this `cargo`, three `stat`s
            // were. Prepended rather than appended so this is the `cargo` that
            // runs even if a later entry has another, which keeps the toolchain
            // the report names and the toolchain the server resolves the same one.
            let directory = (found as NSString).deletingLastPathComponent
            let rest = inherited.filter { $0 != directory }
            return FoundCargo(path: found, searchPath: ([directory] + rest).joined(separator: ":"))
        }
        guard let login = loginShellPath() else { return nil }
        guard let found = Self.firstExecutable(named: "cargo", in: Self.pathEntries(login)) else {
            return nil
        }
        return FoundCargo(path: found, searchPath: login)
    }

    /// A rust-analyzer the *user* already has, if there is one that works.
    ///
    /// Says nothing about this app's own copy, which the model reads off its
    /// install root instead — and which wins when both exist (D24). The places are
    /// the `PATH` that found the `cargo`, then the well-known directories, so a
    /// Homebrew `cargo` and a rustup `rust-analyzer` on the same Mac still find
    /// each other.
    ///
    /// **It is probed like `cargo` is, and this is the reason the probe exists at
    /// all.** rustup installs a `rust-analyzer` *proxy* into `~/.cargo/bin` whether
    /// or not the component behind it was ever added, so on the single most common
    /// Rust setup an unprobed search finds an executable file that exits non-zero
    /// with "not installed for the toolchain" the instant anything asks it
    /// anything. Registering that would put a Settings row reading "installed
    /// (found on this Mac)" in front of a user whose Rust files silently answer
    /// from the tree-sitter index — the D23 failure with a different first cause.
    /// The cost is one subprocess, and only on machines that have a candidate.
    private func locateRustAnalyzer(searchPath: String) -> String? {
        let directories = Self.pathEntries(searchPath) + Self.wellKnownCargoDirectories
        guard let found = Self.firstExecutable(
            named: Self.rustAnalyzerExecutableName,
            in: directories
        ) else { return nil }
        guard probe(found, environment: environment(searchPath: searchPath)) else { return nil }
        return found
    }

    /// Does this program answer `--version` successfully?
    ///
    /// The cheapest question that distinguishes "a working program" from "a file
    /// with the execute bit set", which is the whole of what both call sites need.
    /// The output is not read: what it says is a version string this app has no
    /// policy about — a discovered rust-analyzer is used at whatever version it is
    /// (a recorded known limit), and any `cargo` that answers can build a project
    /// model.
    private func probe(_ executablePath: String, environment: [String: String]) -> Bool {
        guard let result = try? run(
            URL(fileURLWithPath: executablePath),
            ["--version"],
            environment: environment,
            deadline: Self.probeDeadline
        ) else { return false }
        return result.status == 0
    }

    /// What the user's login shell thinks `PATH` is, or `nil`.
    ///
    /// `LSPGoToolchainService.loginShellPath()` verbatim in its three decisions, so
    /// only they are restated here. `-l` and not `-i`: a login shell reads the
    /// profile files where `PATH` is actually assembled, while an interactive one
    /// additionally reads the rc files, where a prompt framework may print, ask, or
    /// simply take a second. `PATH` is asked for rather than `command -v cargo`, so
    /// that what comes back is a list of directories this file then checks itself —
    /// a shell function or alias named `cargo` would answer `command -v` with
    /// something that is not a path, and the failure would be a launch error later
    /// rather than a lookup that simply found nothing. And it is asked for by
    /// running `env` and reading the `PATH=` line rather than by interpolating
    /// `"$PATH"`, because in fish `PATH` is a *list* variable that expands
    /// space-separated, which `pathEntries` — splitting on `:`, as `PATH` is
    /// defined — would read as one bogus directory.
    ///
    /// stdin is `/dev/null` for `LSPToolchain.locate`'s reason: nothing here has
    /// anything to answer with, and a shell waiting on a prompt nobody can see
    /// would sit until the deadline.
    private func loginShellPath() -> String? {
        let shell = TerminalLaunch.shell(environment: ProcessInfo.processInfo.environment)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        guard let result = try? run(
            URL(fileURLWithPath: shell),
            ["-l", "-c", "/usr/bin/env"],
            deadline: Self.shellDeadline
        ), result.status == 0 else { return nil }
        let path = result.standardOutput
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("PATH=") }
            .map { String($0.dropFirst("PATH=".count)) }?
            .trimmingCharacters(in: .whitespaces)
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// The environment a probe runs under: everything inherited, with one variable
    /// replaced.
    ///
    /// The `PATH` that found the `cargo`, so a shim can re-exec what it needs and
    /// so the probe is asked under the same environment Core will later hand the
    /// server (D23). Nothing else is set — rustup's `RUSTUP_HOME`, `CARGO_HOME`,
    /// `RUSTUP_TOOLCHAIN` and any proxy settings are all inherited untouched, which
    /// is what makes the probe's answer the answer for the real thing rather than
    /// for a program run in an environment nothing else uses.
    private func environment(searchPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        return environment
    }

    // MARK: - Teardown

    /// End every child this service has running, now.
    ///
    /// Called from the app's terminate observer beside `LSPWorkspace.terminateNow()`
    /// and `LSPGoToolchainService.terminateNow()`. Idempotent, and permanent: a
    /// service that has been torn down refuses to launch anything else, which
    /// closes the window between the observer firing and a `.rs` tab open reaching
    /// `discover()`. The one thing it is really written for is the login shell —
    /// the only child here that can outlive a quit, since a profile that hangs is
    /// exactly why it has a deadline in the first place.
    func terminateNow() {
        lock.lock()
        isTornDown = true
        let running = Array(children.values)
        children.removeAll()
        lock.unlock()
        for child in running { child.cancel() }
    }

    private func register(_ child: ChildProcess) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else { return nil }
        nextChildToken += 1
        children[nextChildToken] = child
        return nextChildToken
    }

    private func release(_ token: Int) {
        lock.lock()
        children[token] = nil
        lock.unlock()
    }

    // MARK: - Failures

    /// Why a program produced no answer.
    ///
    /// Never surfaced anywhere: every caller here turns a throw into "not found",
    /// because that is the only thing this seam can say (`LSPRustToolchainReport`
    /// has no failure case, D23). The cases exist so the `run` below can be the
    /// same shape as `LSPGoToolchainService`'s rather than return an optional and
    /// lose the distinction at the one place a future caller might want it.
    private enum Failure: Error {
        /// The program is not where the search said it was, or could not be
        /// launched.
        case unavailable
        /// It ran and never finished, so it was killed.
        case timedOut
        /// The app is quitting, or the attempt was cancelled before it started.
        case cancelled
    }

    // MARK: - Running one program

    private struct Result {
        let status: Int32
        let standardOutput: String
    }

    /// A drained, deadlined subprocess: the one piece of machinery both call sites
    /// share.
    ///
    /// Blocking from top to bottom, which is why it only ever runs on `queue`. The
    /// shape is `LSPGoToolchainService.run`'s, minus the diagnostics: nothing here
    /// reports a failure to anybody, so stderr is drained and discarded rather than
    /// kept. It is still *drained* — a pipe nobody reads fills, and a child blocked
    /// writing into it never exits, which is the deadlock rule `GitCLIService` and
    /// `LSPToolchain` both carry. A login shell printing a profile's worth of
    /// warnings is the case that makes it real here.
    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        deadline: DispatchTimeInterval
    ) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.unavailable
        }

        // Every child goes in the registry, and the deadline it carries is a
        // backstop rather than a reason to skip that: a quit must not leave a login
        // shell behind, and a login shell is precisely the child that can sit for
        // the whole five seconds.
        let child = ChildProcess()
        guard let token = register(child) else { throw Failure.cancelled }
        defer { release(token) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Nothing here has anything to read, and a child waiting on a prompt
        // nobody can see would sit until the deadline (`LSPToolchain.locate`'s
        // rule). A profile that asks something on startup is the case for it.
        process.standardInput = FileHandle.nullDevice

        // Assigned before `run()`, the only order in which it is guaranteed to
        // fire: `cargo --version` can be launched, answered and reaped before the
        // next statement on this thread runs.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard child.adopt(process) else { throw Failure.cancelled }

        do {
            try process.run()
        } catch {
            throw Failure.unavailable
        }

        // Re-checked *after* the launch, and this is not belt and braces: `adopt`
        // closes the window before the `Process` exists, but a `cancel()` landing
        // between it and `run()` finds a process that is not running yet, returns
        // without signalling anything — and the statement above then launches it.
        // What that leaves behind is a login shell running somebody's profile,
        // re-parented to `launchd`, after the app that asked has quit.
        // `terminateNow()` cannot help: it has already emptied the registry.
        if child.wasCancelled {
            ChildProcess.terminate(process)
            throw Failure.cancelled
        }

        let streams = DispatchGroup()
        let standardOutput = Buffer()
        DispatchQueue(label: "LSPRustToolchainService.stdout").async(group: streams) {
            standardOutput.store(output.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue(label: "LSPRustToolchainService.stderr").async(group: streams) {
            _ = errors.fileHandleForReading.readDataToEndOfFile()
        }

        // The exit is waited for rather than the drains, because the drains are the
        // thing that can outlive it: a pipe stays readable while any descriptor for
        // its write end is open, and a login shell hands its own descriptors to
        // whatever a profile started in the background.
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            ChildProcess.terminate(process)
            _ = streams.wait(timeout: .now() + Self.teardownGrace)
            throw Failure.timedOut
        }

        // Bounded for the same reason: a drain blocked on a descriptor something
        // else inherited would otherwise reinstate exactly the unbounded wait this
        // method exists to avoid. The status is what decides the outcome; the
        // output only decorates it.
        _ = streams.wait(timeout: .now() + Self.teardownGrace)
        process.waitUntilExit()

        // A child killed by `cancel()` exits non-zero with whatever it had written
        // so far, which would otherwise read as "this `cargo` does not work" — a
        // quit turned into a permanent, cached "no Rust toolchain" for the run that
        // is ending anyway, and a wrong answer to any caller still awaiting it.
        if child.wasCancelled { throw Failure.cancelled }

        return Result(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutput.value, as: UTF8.self)
        )
    }

    /// A child's output, written by one queue and read by another.
    ///
    /// `LSPGoToolchainService.Buffer`'s reason: on the timeout path the deadline
    /// can expire while a drain is still inside `readDataToEndOfFile`, and reading
    /// the same storage from two threads is a data race whatever the timing usually
    /// is.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// One launched-or-about-to-be-launched child, and the ability to kill it from
    /// somewhere else.
    ///
    /// The box exists because cancellation can arrive *before* the process does:
    /// `run` registers this several statements before the `Process` is launched,
    /// and the whole search runs on another queue. `adopt` refusing after a cancel
    /// is what stops a quit from being followed by a launch.
    private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }

        /// Take ownership of `process`, or refuse because cancellation already
        /// happened — in which case the caller must not launch it.
        func adopt(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { return false }
            self.process = process
            return true
        }

        /// Idempotent, and safe to call on a box whose process has already exited
        /// or was never launched — `terminateNow()` cancels everything it has.
        func cancel() {
            lock.lock()
            isCancelled = true
            let running = process
            lock.unlock()
            guard let running, running.isRunning else { return }
            Self.terminate(running)
        }

        /// `SIGTERM`, a grace period, then `SIGKILL` — `LSPProcessTransport.stop`'s
        /// teardown, **signalled as a process group** for
        /// `LSPGoToolchainService.ChildProcess.terminate`'s reason applied to the
        /// child that has it here: a `--version` probe is one process, but a login
        /// shell is a parent that has just run a profile, and anything that profile
        /// started is re-parented to `launchd` rather than ended when the shell is.
        ///
        /// The negative pid is safe because Foundation launches every child as its
        /// own process-group leader, and it is *checked* rather than assumed: the
        /// group is signalled only while `getpgid(pid) == pid`, so if that ever
        /// stopped being true the signal would narrow back to the single process
        /// instead of widening to a group that contains Pisaka itself.
        ///
        /// The escalation runs on its own queue so a caller with a deadline to keep
        /// — or a terminate observer with a whole app to quit — is not held up by
        /// somebody else's grace period.
        static func terminate(_ process: Process) {
            // Read before anything is signalled, while the child is certainly still
            // there: once it has exited and been reaped there is no group left to
            // ask about. `pid > 0` guards the one genuinely dangerous mistake here:
            // `kill(0, …)` — and `kill(-0, …)` — signals the whole process group,
            // i.e. Pisaka itself. A process that never launched reports 0, and this
            // is the check `TerminalSession.terminate()` and
            // `LSPProcessTransport.stop()` both make for the same reason.
            let pid = process.processIdentifier
            let group: pid_t? = pid > 0 && getpgid(pid) == pid ? pid : nil

            process.terminate()
            if let group { kill(-group, SIGTERM) }

            reapQueue.async {
                let deadline = Date().addingTimeInterval(terminationGrace)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning, pid > 0 { kill(pid, SIGKILL) }
                // Unconditional, unlike the line above, and that is the point: a
                // shell that honoured `SIGTERM` promptly still leaves behind
                // whatever its profile had already spawned, so the group has to be
                // finished off whether or not the parent missed its deadline.
                // `ESRCH` from a group that is already gone is the ordinary answer.
                if let group { kill(-group, SIGKILL) }
                process.waitUntilExit()
            }
        }

        /// How long `SIGTERM` gets before `SIGKILL`. `LSPProcessTransport`'s two
        /// seconds.
        private static let terminationGrace: TimeInterval = 2

        private static let reapQueue = DispatchQueue(
            label: "LSPRustToolchainService.reap",
            attributes: .concurrent
        )
    }

    // MARK: - Paths

    /// A `PATH`-shaped string as directories, blanks dropped.
    private static func pathEntries(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// The first `directory/name` that is actually executable, in the order given.
    private static func firstExecutable(named name: String, in directories: [String]) -> String? {
        let manager = FileManager.default
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name).path
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

#endif
