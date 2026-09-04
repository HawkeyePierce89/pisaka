#if os(macOS)
import Foundation
import PisakaCore

/// The real `GitHubCLITransport`: the **one** file in this app that runs a
/// `Process` for `gh` (G1).
///
/// It knows nothing about what any of it means. Core composes every argument list
/// (`GitHubCommands`), parses every answer (`GitHubAPI`) and decides every
/// sentence; this file finds a `gh`, starts it, drains it, bounds it and hands
/// back both streams and the status verbatim. It never retries a command, never
/// reads a status and never looks at a byte of output — except the one program it
/// runs that is not `gh`, the login shell whose `PATH` it reads through
/// `ExecutableLocator`.
///
/// **Discovery is per refresh, not per command, and not per app run (G7).** The
/// located `gh` is cached **together with the `PATH` that found it**, and is
/// re-located only when one of three things is true:
///
/// 1. the command carries `refreshesExecutableLocation` — which exactly one
///    factory does, `GitHubCommands.version()`, the first command of every
///    refresh. That is how the rule is expressed without this file ever spelling
///    `--version`, and it is why a `gh` installed a moment ago from the embedded
///    terminal is picked up by the very next refresh;
/// 2. the cached path is no longer an executable file on disk (`brew uninstall`,
///    an upgrade that moved it);
/// 3. launching it failed, in which case the search is re-run once and the
///    command retried before the failure is reported.
///
/// A refresh is three or four commands. One login-shell spawn per refresh is the
/// budget; one per command is not. The cache being defeated by the refresh's own
/// version probe is the point — it is deliberately *not* an app-run cache, unlike
/// `LSPRustToolchainService`'s, because `gh` is a thing the user is actively
/// being told to install.
///
/// `@unchecked Sendable` over an `NSLock`, `LSPRustToolchainService`'s
/// arrangement: the lock guards the cached location and the live-child registry,
/// is never held across a subprocess wait, and every launched process is
/// reachable from `terminateNow()` — which signals each child's whole *process
/// group*, so a quit during a `gh pr checkout` leaves behind neither `gh` nor the
/// `git` it shelled out to.
final class GitHubCLIProcessTransport: GitHubCLITransport, @unchecked Sendable {
    /// Where the blocking work runs. Concurrent because a `pr checkout` holds its
    /// thread for as long as a fetch takes, and the panel must still be able to
    /// ask something else.
    private static let queue = DispatchQueue(
        label: "GitHubCLIProcessTransport",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The binary name. The one `gh` word in the app layer, and not an argument:
    /// `GitHubSourceGatingTests` pins that no `gh` *argument* is spelled outside
    /// `GitHubCommands.swift`, which is a rule about the vocabulary, not about
    /// the executable this file has to name in order to look for it.
    private static let executableName = "gh"

    /// Directories that hold a `gh` on a machine whose `PATH` this app never saw.
    ///
    /// A Finder-launched app inherits `launchd`'s `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains no `gh` on any machine —
    /// so without these, "did you start Pisaka from a terminal?" would decide
    /// whether the panel says "not installed". Homebrew's two prefixes lead
    /// because `brew install gh` is the instruction this app itself prints;
    /// MacPorts' follows.
    private static let wellKnownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    /// How long the login shell gets to print its `PATH` before it is killed.
    /// `LSPRustToolchainService.shellDeadline`, for its reason: a profile slow
    /// enough to miss this is one whose answer is not worth waiting on, and a
    /// timeout here is not an error — it is one more way of finding no `gh`.
    private static let shellDeadline: TimeInterval = 5

    /// How long a killed child gets to actually die, and its drains to finish.
    private static let teardownGrace: DispatchTimeInterval = .seconds(5)

    private let lock = NSLock()

    /// The `gh` this transport is currently using, and the `PATH` that found it.
    private var located: ExecutableLocator.Found?

    /// Every child this transport has running, so `terminateNow()` can end them
    /// all.
    private var children: [Int: ChildProcess] = [:]
    private var nextChildToken = 0
    private var isTornDown = false

    init() {}

    // MARK: - The seam

    func run(_ command: GitHubCommand) async throws -> GitHubCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try self.perform(command))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Locate, run, and — on a launch failure alone — locate once more and run
    /// again.
    ///
    /// The retry is trigger (3) of the caching rule and is deliberately narrow: a
    /// `gh` that started and exited non-zero is an *answer* and is returned
    /// untouched, while a `gh` that could not be started is a stale cache in every
    /// case anyone has hit (an upgrade replacing the file mid-refresh). A timeout
    /// is never retried — it has already spent the command's whole deadline.
    private func perform(_ command: GitHubCommand) throws -> GitHubCommandResult {
        let executable = try resolve(relocating: command.refreshesExecutableLocation)
        do {
            return try execute(command, using: executable)
        } catch GitHubCLIError.launchFailed {
            guard !hasBeenTornDown else { throw GitHubCLIError.launchFailed(message: "Pisaka is quitting.") }
            return try execute(command, using: try resolve(relocating: true))
        }
    }

    /// The cached `gh`, or a fresh search.
    ///
    /// Triggers (1) and (2) of the rule live in the two conditions below; the
    /// negative answer is **not** cached — a machine with no `gh` re-searches on
    /// the next refresh, which is exactly the machine an install is about to
    /// happen on.
    private func resolve(relocating: Bool) throws -> ExecutableLocator.Found {
        if !relocating, let cached = cachedLocation,
           FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }
        let found = ExecutableLocator.locate(
            Self.executableName,
            wellKnownDirectories: Self.wellKnownDirectories,
            runningProgram: { [self] executable, arguments in
                runLoginShell(executable, arguments)
            }
        )
        cachedLocation = found
        guard let found else { throw GitHubCLIError.notInstalled }
        return found
    }

    private var cachedLocation: ExecutableLocator.Found? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return located
        }
        set {
            lock.lock()
            located = newValue
            lock.unlock()
        }
    }

    /// The locator's one subprocess, run the way every child here is run: in the
    /// registry, under `shellDeadline`, with its output taken only when it exited
    /// zero.
    private func runLoginShell(_ executable: URL, _ arguments: [String]) -> String? {
        guard let result = try? runProcess(
            executable,
            arguments,
            environment: nil,
            workingDirectory: nil,
            deadline: Self.shellDeadline
        ), result.status == 0 else { return nil }
        return result.standardOutput
    }

    /// One `gh` invocation, under Core's non-interactive overlay and in the
    /// repository root.
    ///
    /// The environment is `GitHubCLIEnvironment.merged(over:searchPath:)` — the
    /// inherited environment with the overlay applied and the discovered `PATH`
    /// substituted, so a user's own `GH_HOST` or `GH_TOKEN` survives while the
    /// prompting, the pager, the colour and the update notifier are all off, and
    /// so the `git` that `gh pr checkout` shells out to is findable. The working
    /// directory is the command's, because that is how `gh` resolves which
    /// repository this is (G6).
    private func execute(_ command: GitHubCommand, using executable: ExecutableLocator.Found) throws -> GitHubCommandResult {
        let output = try runProcess(
            URL(fileURLWithPath: executable.path),
            command.arguments,
            environment: GitHubCLIEnvironment.merged(
                over: ProcessInfo.processInfo.environment,
                searchPath: executable.searchPath
            ),
            workingDirectory: command.workingDirectory,
            deadline: command.deadline
        )
        return GitHubCommandResult(
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            status: output.status
        )
    }

    // MARK: - Teardown

    /// End every child this transport has running, now.
    ///
    /// Called from the app's terminate observer beside the other services'.
    /// Idempotent, and permanent: a transport that has been torn down refuses to
    /// launch anything else, which closes the window between the observer firing
    /// and a refresh reaching `run(_:)`. The children it is really written for are
    /// the login shell and `gh pr checkout` — the first can sit for its whole
    /// deadline running somebody's profile, the second is a `git` fetch that would
    /// otherwise be re-parented to `launchd` and go on rewriting the worktree of a
    /// project nobody has open any more.
    func terminateNow() {
        lock.lock()
        isTornDown = true
        let running = Array(children.values)
        children.removeAll()
        lock.unlock()
        for child in running { child.cancel() }
    }

    private var hasBeenTornDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTornDown
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

    // MARK: - Running one program

    private struct Output {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// A drained, deadlined subprocess: the one piece of machinery this file has.
    ///
    /// Blocking from top to bottom, which is why it only ever runs on `queue`. The
    /// shape is `LSPRustToolchainService.run`'s, and every decision in it is that
    /// method's: both pipes are drained on queues of their own, because a pipe
    /// nobody reads fills and a child blocked writing into it never exits (the
    /// deadlock rule `GitCLIService` and `LSPToolchain` both carry, and `gh pr
    /// list --json` with fifty rollups is a real several-hundred-kilobyte answer);
    /// stdin is `/dev/null`, because a `gh` that decided to prompt would otherwise
    /// sit until the deadline; the *exit* is waited for rather than the drains,
    /// because the drains are the thing that can outlive it; and both waits after
    /// the exit are bounded, so a descriptor something else inherited cannot
    /// reinstate the unbounded wait this method exists to avoid.
    ///
    /// The only three things it decides are the three `GitHubCLIError` cases. A
    /// non-zero status is not one of them.
    private func runProcess(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        deadline: TimeInterval
    ) throws -> Output {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GitHubCLIError.notInstalled
        }

        let child = ChildProcess()
        guard let token = register(child) else {
            throw GitHubCLIError.launchFailed(message: "Pisaka is quitting.")
        }
        defer { release(token) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // Assigned before `run()`, the only order in which it is guaranteed to
        // fire: `gh --version` can be launched, answered and reaped before the
        // next statement on this thread runs.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard child.adopt(process) else {
            throw GitHubCLIError.launchFailed(message: "Pisaka is quitting.")
        }

        do {
            try process.run()
        } catch {
            throw GitHubCLIError.launchFailed(message: error.localizedDescription)
        }

        // Re-checked *after* the launch, and this is not belt and braces: `adopt`
        // closes the window before the `Process` exists, but a `cancel()` landing
        // between it and `run()` finds a process that is not running yet, returns
        // without signalling anything — and the statement above then launches it.
        // What that leaves behind is a `git` fetch re-parented to `launchd` after
        // the app that asked has quit. `terminateNow()` cannot help: it has
        // already emptied the registry.
        if child.wasCancelled {
            ChildProcess.terminate(process)
            throw GitHubCLIError.launchFailed(message: "Pisaka is quitting.")
        }

        let streams = DispatchGroup()
        let standardOutput = Buffer()
        let standardError = Buffer()
        DispatchQueue(label: "GitHubCLIProcessTransport.stdout").async(group: streams) {
            standardOutput.store(output.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue(label: "GitHubCLIProcessTransport.stderr").async(group: streams) {
            standardError.store(errors.fileHandleForReading.readDataToEndOfFile())
        }

        if exited.wait(timeout: .now() + deadline) == .timedOut {
            ChildProcess.terminate(process)
            _ = streams.wait(timeout: .now() + Self.teardownGrace)
            throw GitHubCLIError.timedOut(seconds: deadline)
        }

        _ = streams.wait(timeout: .now() + Self.teardownGrace)
        process.waitUntilExit()

        // A child killed by `cancel()` exits non-zero with whatever it had written
        // so far, which would otherwise read as "`gh` answered this". Reported as
        // a launch failure rather than as a result for that reason — and it is the
        // one launch failure `perform` must not retry, which is why it re-asks the
        // torn-down flag before it does.
        if child.wasCancelled {
            throw GitHubCLIError.launchFailed(message: "Pisaka is quitting.")
        }

        return Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutput.value, as: UTF8.self),
            standardError: String(decoding: standardError.value, as: UTF8.self)
        )
    }

    /// A child's output, written by one queue and read by another.
    ///
    /// `LSPRustToolchainService.Buffer`'s reason: on the timeout path the deadline
    /// can expire while a drain is still inside `readDataToEndOfFile`, and reading
    /// the same storage from two threads is a data race whatever the timing
    /// usually is.
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
    /// `LSPRustToolchainService.ChildProcess` verbatim, for its reasons: the box
    /// exists because cancellation can arrive *before* the process does, and
    /// `adopt` refusing after a cancel is what stops a quit from being followed by
    /// a launch.
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
        /// or was never launched.
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
        /// `LSPRustToolchainService.ChildProcess.terminate`'s reason applied to the
        /// children that have it here: `gh pr checkout` is a parent that shells out
        /// to `git`, and a login shell is a parent that has just run a profile —
        /// anything either started is re-parented to `launchd` rather than ended
        /// when the parent is.
        ///
        /// The negative pid is safe because Foundation launches every child as its
        /// own process-group leader, and it is *checked* rather than assumed: the
        /// group is signalled only while `getpgid(pid) == pid`, so if that ever
        /// stopped being true the signal would narrow back to the single process
        /// instead of widening to a group that contains Pisaka itself.
        static func terminate(_ process: Process) {
            // Read before anything is signalled, while the child is certainly
            // still there. `pid > 0` guards the one genuinely dangerous mistake:
            // `kill(0, …)` — and `kill(-0, …)` — signals the whole process group,
            // i.e. Pisaka itself.
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
                // `gh` that honoured `SIGTERM` promptly still leaves behind the
                // `git` it had already spawned, so the group has to be finished off
                // whether or not the parent missed its deadline. `ESRCH` from a
                // group that is already gone is the ordinary answer.
                if let group { kill(-group, SIGKILL) }
                process.waitUntilExit()
            }
        }

        /// How long `SIGTERM` gets before `SIGKILL`. `LSPProcessTransport`'s two
        /// seconds.
        private static let terminationGrace: TimeInterval = 2

        private static let reapQueue = DispatchQueue(
            label: "GitHubCLIProcessTransport.reap",
            attributes: .concurrent
        )
    }
}

#endif
