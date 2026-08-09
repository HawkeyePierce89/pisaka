#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPGoToolchainDiscovering` **and** `LSPGoModuleInstalling`: where
/// `go` and `gopls` are on *this* Mac, and what `go install` means here (D18/D20).
///
/// One file for both seams, unlike 2b's `LSPDownloadService`/`LSPArchiveUnpacker`
/// pair, because they are not two technologies: both are "run the user's `go` and
/// read what it says". Splitting them would duplicate the process plumbing below
/// twice over to keep two five-line functions apart.
///
/// **Core learns no paths.** Everything in this file — `$GOBIN`, `$GOPATH/bin`,
/// `~/go/bin`, the login `PATH`, `/usr/local/go/bin`, Homebrew's two prefixes — is
/// machine-specific knowledge of exactly the kind D9 keeps out of the domain
/// library, which is why the seam carries an `LSPGoToolchainReport` rather than a
/// search. Every *rule* about what that report permits lives in
/// `LSPGoplsProvisioningModel` and is unit-tested with no Go toolchain anywhere in
/// sight; this file is untested by repository convention, like the two seams above
/// and like `LSPProcessTransport`, so it is kept to the decisions it actually
/// makes: where to look, in what order, and what counts as a failure.
///
/// **Nothing is downloaded by this app and nothing global is touched** (D17/D20).
/// The install points `GOBIN` at a staging directory the model owns and inherits
/// the environment otherwise untouched: no `$PATH` edit, no `~/go/bin`, no `sudo`,
/// no package manager. Module integrity is Go's own checksum database, verified by
/// the toolchain doing the build, which is that ecosystem's equivalent of 2b's
/// pinned SHA-256s and which this app therefore does not reimplement.
///
/// `@unchecked Sendable` over an `NSLock`, the `LSPProcessTransport` arrangement:
/// the lock guards the cached discovery and the live-child registry, is never held
/// across a subprocess wait, and every launched process is reachable from
/// `terminateNow()` so a quit mid-build leaves no `go` behind.
final class LSPGoToolchainService: LSPGoToolchainDiscovering, LSPGoModuleInstalling, @unchecked Sendable {
    /// Where the blocking work runs. Concurrent, so a discovery started at launch
    /// and an install started by the banner do not queue behind each other — and
    /// so the install, which is minutes, cannot hold up anything else at all.
    private static let queue = DispatchQueue(
        label: "LSPGoToolchainService",
        qos: .utility,
        attributes: .concurrent
    )

    /// Directories that hold a `go` on a machine whose `PATH` this app never saw.
    ///
    /// A Finder-launched app inherits `launchd`'s `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains no `go` on any machine —
    /// so without these, "did you start Pisaka from a terminal?" would decide
    /// whether Go got a language server. The three cover every mainstream install:
    /// the official pkg/tarball, and Homebrew on both architectures.
    private static let wellKnownGoDirectories = [
        "/usr/local/go/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// How long the login shell gets to print its `PATH` before it is killed.
    ///
    /// Short on purpose: this runs on every launch of every Mac that has no `go`
    /// in the two cheap places, which is most of them, and a login shell that
    /// takes longer than this is one whose profile is doing something (a version
    /// manager resolving over the network, a prompt framework) that the answer is
    /// not worth waiting on. A timeout is not an error here — it is one more way
    /// of finding no toolchain.
    private static let shellDeadline: DispatchTimeInterval = .seconds(5)

    /// How long `go env` gets. It reads a config file and prints two lines; ten
    /// seconds is "this `go` is not answering" rather than "this is slow".
    private static let goEnvDeadline: DispatchTimeInterval = .seconds(10)

    /// How long `go install` gets before it is killed.
    ///
    /// `LSPArchiveUnpacker.deadline`'s reasoning, and its numbers scaled to what
    /// is being waited for: the model keeps the row `.installing` and refuses
    /// Remove until this returns, so a build that never finishes is not a slow
    /// install but a dead one — for the rest of the app run, with nothing said and
    /// no way back but quitting. A cold `go install` of gopls downloads its module
    /// graph and compiles it, which is minutes on a slow link; thirty is far above
    /// any real duration and far below "never", which is the only number it is
    /// really competing with. A timeout throws, the model discards its staging
    /// tree, and the row lands on the "not installed + Retry" state every other
    /// failure produces.
    private static let installDeadline: DispatchTimeInterval = .seconds(30 * 60)

    /// How long a killed child gets to actually die, and its drains to finish.
    private static let teardownGrace: DispatchTimeInterval = .seconds(5)

    private let lock = NSLock()

    /// The one discovery, cached **including the negative answer**.
    ///
    /// `LSPToolchain`'s discipline, for its reason: a machine with no Go toolchain
    /// must not spawn a login shell every time something asks. A `Task` rather than
    /// a stored value so two callers arriving before the first answer await one
    /// search instead of starting two. Per app run, not per folder — a `go`
    /// installed while Pisaka is running is picked up at the next launch, stated
    /// rather than papered over with invalidation logic for an event nobody has
    /// hit.
    private var discoveryTask: Task<LSPGoToolchainReport, Never>?

    /// Every child this service has running, so `terminateNow()` can end them all.
    private var children: [Int: ChildProcess] = [:]
    private var nextChildToken = 0
    private var isTornDown = false

    init() {}

    // MARK: - Discovery

    func discover() async -> LSPGoToolchainReport {
        let task: Task<LSPGoToolchainReport, Never>
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
    /// Blocking from top to bottom — three possible subprocesses and a handful of
    /// `stat`s — so it runs on `queue` and never on the cooperative pool, let alone
    /// the main thread. The model calls `discover()` from app startup, so by the
    /// time anyone opens a `.go` file the answer is already a stored value.
    private func resolveReport() async -> LSPGoToolchainReport {
        await withCheckedContinuation { (continuation: CheckedContinuation<LSPGoToolchainReport, Never>) in
            Self.queue.async {
                continuation.resume(returning: self.search())
            }
        }
    }

    /// `go`, then what `go` says about where its programs go.
    ///
    /// A `go` that cannot answer `go env` is reported as **no toolchain**, not as a
    /// toolchain with an unknown `GOBIN`: the one thing this report is used for is
    /// deciding whether gopls can be built and run, and a `go` that does not
    /// answer its own environment will not build anything either. Reporting it as
    /// present would offer an Install that cannot work and register a discovered
    /// gopls that would answer nothing.
    private func search() -> LSPGoToolchainReport {
        guard let goPath = locateGo() else { return .missing }
        guard let environment = goEnvironment(goPath: goPath) else { return .missing }
        return .found(goPath: goPath, goplsPath: locateGopls(environment: environment))
    }

    /// The first `go` that exists, cheapest lookup first.
    ///
    /// Order is the decision. The inherited `PATH` comes first because a Pisaka
    /// started from a terminal should use the `go` that terminal would have run.
    /// The well-known directories come next because they are three `stat`s and
    /// cover the mainstream installs. The login shell comes **last**, because it is
    /// the only step here that costs a subprocess and it is the only one that can
    /// find a version-manager shim (`asdf`, `mise`, `goenv`) — so it runs exactly
    /// on the machines that need it, and on the machines with no Go at all, once
    /// per app run.
    private func locateGo() -> String? {
        let inherited = Self.pathEntries(ProcessInfo.processInfo.environment["PATH"])
        if let found = Self.firstExecutable(named: "go", in: inherited) { return found }
        if let found = Self.firstExecutable(named: "go", in: Self.wellKnownGoDirectories) { return found }
        return Self.firstExecutable(named: "go", in: Self.pathEntries(loginShellPath()))
    }

    /// `GOBIN` and `GOPATH` as this `go` resolves them — which is not the same as
    /// reading the environment: both can come from `go env -w`'s config file, and
    /// `GOPATH` has a default (`~/go`) that is never in the environment at all.
    ///
    /// Two names in one call, so the answer is two lines in a known order rather
    /// than two subprocesses. An empty first line is an unset `GOBIN`, which is
    /// the ordinary case.
    private func goEnvironment(goPath: String) -> (gobin: String, gopath: String)? {
        guard let result = try? run(
            URL(fileURLWithPath: goPath),
            ["env", "GOBIN", "GOPATH"],
            deadline: Self.goEnvDeadline
        ), result.status == 0 else { return nil }

        let lines = result.standardOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (lines.first ?? "", lines.count > 1 ? lines[1] : "")
    }

    /// A gopls the *user* installed, if there is one.
    ///
    /// Says nothing about this app's own copy, which the model reads off its
    /// install root instead — and which wins when both exist (D19). The three
    /// places are `go install`'s own: `$GOBIN` when set, then `bin` under each
    /// `GOPATH` element, then `~/go/bin`, which `GOPATH`'s default already covers
    /// and which is listed anyway because it costs one `stat` and is the answer
    /// people actually give when asked where gopls is.
    private func locateGopls(environment: (gobin: String, gopath: String)) -> String? {
        var directories: [String] = []
        if !environment.gobin.isEmpty { directories.append(environment.gobin) }
        directories += Self.pathEntries(environment.gopath).map { $0 + "/bin" }
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("go/bin", isDirectory: true).path
        )
        return Self.firstExecutable(named: LSPGopls.executableName, in: directories)
    }

    /// What the user's login shell thinks `PATH` is, or `nil`.
    ///
    /// `-l` and not `-i`: a login shell reads the profile files where `PATH` is
    /// actually assembled, while an interactive one additionally reads the rc
    /// files, where a prompt framework may print, ask, or simply take a second.
    /// stdin is `/dev/null` for `LSPToolchain.locate`'s reason — nothing here has
    /// anything to answer with, and a shell waiting on a prompt nobody can see
    /// would sit until the deadline.
    ///
    /// `PATH` is asked for rather than `command -v go`, so that what comes back is
    /// a list of directories this file then checks itself. A shell function or an
    /// alias named `go` would answer `command -v` with something that is not a
    /// path, and the failure would be a launch error minutes later rather than a
    /// lookup that simply found nothing.
    private func loginShellPath() -> String? {
        let shell = TerminalLaunch.shell(environment: ProcessInfo.processInfo.environment)
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        guard let result = try? run(
            URL(fileURLWithPath: shell),
            ["-l", "-c", "printf %s \"$PATH\""],
            deadline: Self.shellDeadline
        ), result.status == 0 else { return nil }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Installing

    /// One `go install <module>@<version>` with `GOBIN` pointed at `binDirectory`.
    ///
    /// The environment is inherited wholesale and exactly one variable is added,
    /// which is the whole of "nothing global is touched": the user's `GOMODCACHE`,
    /// `GOCACHE`, `GOPROXY`, `GOPRIVATE` and proxy settings all keep working
    /// because none of them is replaced. Sharing those caches is one of the two
    /// recorded known limits — a private `GOPATH` would re-download and rebuild the
    /// world for no benefit — and `GOTOOLCHAIN`'s default (`auto`, so an older
    /// toolchain may fetch a newer one to build with) is the other.
    ///
    /// The returned URL is where `go install` puts the program: `$GOBIN` plus the
    /// module path's last element. It is *checked* by the model against
    /// `LSPGopls.executableSubpath` rather than trusted (D12), so this file does
    /// not duplicate that check — a build that exits 0 having written nothing is
    /// reported by the model as `executableMissing`, which is the precise sentence
    /// for it.
    func install(
        module: String,
        version: String,
        using goExecutablePath: String,
        into binDirectory: URL
    ) async throws -> URL {
        let child = ChildProcess()
        // Registered here as well as in `run`, and the earlier of the two is the
        // one that matters: cancellation can arrive in the window between this call
        // and the queue getting round to launching anything, which is exactly where
        // a quit during a first-launch build lands. Registering one box twice costs
        // a dictionary entry and cancels it twice, which `ChildProcess.cancel()` is
        // written to survive.
        guard let token = register(child) else { throw Failure.cancelled }
        defer { release(token) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                Self.queue.async {
                    do {
                        try self.runInstall(
                            module: module,
                            version: version,
                            goExecutablePath: goExecutablePath,
                            binDirectory: binDirectory,
                            child: child
                        )
                        continuation.resume(
                            returning: binDirectory.appendingPathComponent(Self.programName(of: module))
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // A quit, or a folder switch that dropped the model, must not leave a
            // `go` — and a `go` compiling gopls has a whole tree of children of its
            // own, all of which die with it. `LSPProcessTransport`'s rule, and the
            // release check (`pgrep -f 'gopls|go install'` empty after a quit) is
            // what it is written against.
            child.cancel()
        }
    }

    private func runInstall(
        module: String,
        version: String,
        goExecutablePath: String,
        binDirectory: URL,
        child: ChildProcess
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GOBIN"] = binDirectory.path

        let result = try run(
            URL(fileURLWithPath: goExecutablePath),
            ["install", "\(module)@\(version)"],
            environment: environment,
            // Run from the staging tree, which is inside no module. `go install
            // pkg@version` documents that it ignores the current directory's
            // `go.mod`, and this is the cheapest way not to depend on that: the
            // app's own working directory is wherever it was launched from, which
            // on a developer's Mac is quite often a Go module.
            currentDirectory: binDirectory,
            deadline: Self.installDeadline,
            child: child
        )

        guard result.status == 0 else {
            throw Failure.buildFailed(status: result.status, message: result.standardError)
        }
    }

    /// The name `go install` gives the program it builds: the module path's last
    /// element. `golang.org/x/tools/gopls` → `gopls`, which is what
    /// `LSPGopls.executableName` independently states and what the model checks
    /// for.
    private static func programName(of module: String) -> String {
        String(module.split(separator: "/").last ?? "")
    }

    // MARK: - Teardown

    /// End every child this service has running, now.
    ///
    /// Called from the app's terminate observer beside `LSPWorkspace.terminateNow()`
    /// so an install in flight goes with the rest. Idempotent, and permanent: a
    /// service that has been torn down refuses to launch anything else, which
    /// closes the window between the observer firing and a `.go` tab open landing
    /// on `prepareForOpening`.
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

    /// Why a build did not produce a binary.
    ///
    /// Bare reason phrases, for `LSPDownloadService.Failure`'s reason:
    /// `LSPGoplsProvisioningModel` wraps whatever this throws into
    /// `LSPGoInstallError.buildFailed(reason:)`, taking this error's
    /// `localizedDescription`, so a second attribution here would surface as two
    /// sentences about one failure.
    enum Failure: Error, LocalizedError {
        /// `go` is not where the report said it was, or could not be launched.
        case goUnavailable(String)
        /// It ran and refused: a compile error, an unreachable module proxy, a
        /// disk with no room.
        case buildFailed(status: Int32, message: String)
        /// It ran and never finished, so it was killed (see `installDeadline`).
        case timedOut
        /// The app is quitting, or the attempt was cancelled before it started.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .goUnavailable(let reason):
                return "The Go toolchain could not be run. \(reason)"
            case let .buildFailed(status, message):
                return message.isEmpty ? "“go install” exited with status \(status)." : message
            case .timedOut:
                return "“go install” did not finish and was stopped."
            case .cancelled:
                return "The installation was stopped."
            }
        }
    }

    // MARK: - Running one program

    private struct Result {
        let status: Int32
        let standardOutput: String
        /// The tail of stderr, already trimmed to a sentence — this is what a
        /// Settings row shows, so it is never the whole stream.
        let standardError: String
    }

    /// A drained, deadlined subprocess: the one piece of machinery all three
    /// call sites share.
    ///
    /// Blocking from top to bottom, which is why it only ever runs on `queue`.
    /// The shape is `LSPArchiveUnpacker.run`'s, minus stdin: two output streams
    /// drained on their own queues so neither can fill a pipe buffer and wedge the
    /// child (`GitCLIService`/`LSPToolchain`'s deadlock rule — `go build` writing
    /// one line per package makes that a real volume here, not a theoretical one),
    /// the exit waited for with a deadline, and a `SIGTERM`→`SIGKILL` teardown for
    /// anything that misses it.
    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        deadline: DispatchTimeInterval,
        child: ChildProcess? = nil
    ) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.goUnavailable("\(executable.path) is not there.")
        }

        // Every child goes in the registry, not only the install's: a quit during
        // discovery must not leave a login shell or a `go env` behind either, and
        // the deadline they carry is a backstop rather than a reason to skip this.
        let child = child ?? ChildProcess()
        guard let token = register(child) else { throw Failure.cancelled }
        defer { release(token) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // Nothing here has anything to read, and a child waiting on a prompt
        // nobody can see would sit until the deadline (`LSPToolchain.locate`'s
        // rule). `go` asking for VCS credentials is the case that makes this more
        // than hygiene.
        process.standardInput = FileHandle.nullDevice

        // Assigned before `run()`, the only order in which it is guaranteed to
        // fire: `go env` can be launched, answered and reaped before the next
        // statement on this thread runs.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard child.adopt(process) else { throw Failure.cancelled }

        do {
            try process.run()
        } catch {
            throw Failure.goUnavailable(error.localizedDescription)
        }

        let streams = DispatchGroup()
        let standardOutput = Buffer()
        let standardError = Buffer()
        DispatchQueue(label: "LSPGoToolchainService.stdout").async(group: streams) {
            standardOutput.store(output.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue(label: "LSPGoToolchainService.stderr").async(group: streams) {
            standardError.store(errors.fileHandleForReading.readDataToEndOfFile())
        }

        // The exit is waited for rather than the drains, because the drains are the
        // thing that can outlive it: a pipe stays readable while any descriptor for
        // its write end is open — and `go build` hands its own descriptors to the
        // compiler and linker it spawns.
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            ChildProcess.terminate(process)
            _ = streams.wait(timeout: .now() + Self.teardownGrace)
            throw Failure.timedOut
        }

        // Bounded for the same reason: a drain blocked on a descriptor something
        // else inherited would otherwise reinstate exactly the unbounded wait this
        // method exists to avoid. The status is what decides the outcome; the
        // drains only decorate it.
        _ = streams.wait(timeout: .now() + Self.teardownGrace)
        process.waitUntilExit()

        // A build that was killed by `cancel()` exits non-zero with whatever it had
        // written so far, which would otherwise be reported as an ordinary build
        // failure — a sentence in the Settings row about a quit the user asked for.
        if child.wasCancelled { throw Failure.cancelled }

        return Result(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutput.value, as: UTF8.self),
            standardError: Self.lastLines(of: standardError.value)
        )
    }

    /// What `go` last complained about, as a sentence.
    ///
    /// The tail rather than the whole stream: a failing build reports one line per
    /// package plus a compiler diagnostic per error, and what ends up in a Settings
    /// row should be readable. Three lines rather than one, because `go`'s actual
    /// reason is regularly the line above the last (`# golang.org/x/tools/gopls`
    /// heads a block, and "no required module provides package …" is followed by a
    /// hint line). Capped, because nothing stops a path from being enormous.
    private static func lastLines(of diagnostics: Data) -> String {
        let lines = String(decoding: diagnostics, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " ")
        return tail.count > 300 ? String(tail.prefix(300)) + "…" : tail
    }

    /// A child's output, written by one queue and read by another.
    ///
    /// `LSPArchiveUnpacker.Diagnostics`' reason: on the timeout path the deadline
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
    /// `install` registers this the moment it is called and the `Process` is
    /// created several statements later, on another queue. `adopt` refusing after
    /// a cancel is what stops a quit from being followed by a launch.
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

        /// Idempotent, and safe to call on a box whose process has already exited or
        /// was never launched — `terminateNow()` cancels everything it has, and
        /// `install`'s two registrations mean one box can be cancelled twice.
        func cancel() {
            lock.lock()
            isCancelled = true
            let running = process
            lock.unlock()
            guard let running, running.isRunning else { return }
            Self.terminate(running)
        }

        /// `SIGTERM`, a grace period, then `SIGKILL` — `LSPProcessTransport.stop`'s
        /// teardown, for its reason: a `go` wedged badly enough to miss a deadline
        /// is one that may also ignore a polite signal, and leaving it holding a
        /// staging directory that is about to be deleted is worse than killing it.
        ///
        /// The escalation runs on its own queue so a caller with a deadline to keep
        /// — or a terminate observer with a whole app to quit — is not held up by
        /// somebody else's grace period.
        static func terminate(_ process: Process) {
            process.terminate()
            let pid = process.processIdentifier
            reapQueue.async {
                let deadline = Date().addingTimeInterval(terminationGrace)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                // `pid > 0` guards the one genuinely dangerous mistake here:
                // `kill(0, …)` signals the whole process group, i.e. Pisaka itself.
                // A process that never launched reports 0, and this is the check
                // `TerminalSession.terminate()` and `LSPProcessTransport.stop()`
                // both make for the same reason.
                if process.isRunning, pid > 0 { kill(pid, SIGKILL) }
                process.waitUntilExit()
            }
        }

        /// How long `SIGTERM` gets before `SIGKILL`. `LSPProcessTransport`'s two
        /// seconds: the release check is `pgrep -f 'gopls|go install'` coming back
        /// empty after a quit, and a build that is still linking will not honour a
        /// polite signal quickly.
        private static let terminationGrace: TimeInterval = 2

        private static let reapQueue = DispatchQueue(
            label: "LSPGoToolchainService.reap",
            attributes: .concurrent
        )
    }

    // MARK: - Paths

    /// A `PATH`-shaped string as directories, blanks dropped. `PATH` and `GOPATH`
    /// are both colon-separated lists, so one helper reads both.
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
