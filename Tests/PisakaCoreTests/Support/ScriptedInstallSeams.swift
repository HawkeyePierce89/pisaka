import Foundation
@testable import PisakaCore

/// The two seams `LSPInstallEngine` reaches through (D14), faked deterministically.
///
/// The `ScriptedLSPTransport` principle applied to provisioning: the engine's
/// interesting behavior is all *ordering and failure handling* — verify before
/// unpack, one rename, nothing touched outside staging when something goes wrong
/// — and none of it needs a network or a `tar` to exercise. What it needs is a
/// downloader that can hand over the wrong bytes on demand and an unpacker that
/// can fail after the download succeeded, which is what these are.
///
/// The canned bytes are **derived from the URL** rather than random, and that is
/// load-bearing: it lets the unpacker tell which archive it was handed without a
/// second registration channel, so "the bytes that were verified are the bytes
/// that were unpacked" is something the tests can actually assert rather than
/// assume.
enum ScriptedArchive {
    /// The bytes standing in for the archive served at `url`.
    static func bytes(for url: URL) -> Data {
        Data("archive:\(url.absoluteString)".utf8)
    }

    /// The digest of those bytes, in the form `LSPArtifact.sha256` pins.
    ///
    /// Computed rather than written down, which is only legitimate because
    /// `SHA256` is verified against the published FIPS vectors in its own suite:
    /// here the digest is not what is under test, the comparison is.
    static func checksum(for url: URL) -> String {
        SHA256.hexadecimalDigest(of: bytes(for: url))
    }
}

/// A downloader answering canned bytes per URL — or an error, or nothing at all
/// until a `Gate` is released.
final class ScriptedDownloader: LSPArtifactDownloading, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        /// The transport failed: no network, TLS rejected, a 500.
        case offline
        /// Nothing was stubbed for this URL — a test asked for something it did
        /// not set up, which must look like a failure rather than like success
        /// with empty bytes.
        case notStubbed

        var errorDescription: String? {
            switch self {
            case .offline: return "The Internet connection appears to be offline."
            case .notStubbed: return "No stub for this URL."
            }
        }
    }

    private enum Answer {
        case data(Data)
        case failure(Error)
    }

    private let lock = NSLock()
    private var answers: [URL: Answer] = [:]
    private var gates: [URL: Gate] = [:]
    private var requested: [URL] = []

    /// Serve `url` with its canned bytes — the stub for a download that works.
    func serve(_ url: URL) {
        serve(url, bytes: ScriptedArchive.bytes(for: url))
    }

    /// Serve `url` with bytes of the test's choosing — how a mirror handing over
    /// something other than what the manifest pinned is staged.
    func serve(_ url: URL, bytes: Data) {
        lock.lock()
        answers[url] = .data(bytes)
        lock.unlock()
    }

    func fail(_ url: URL, with error: Error = Failure.offline) {
        lock.lock()
        answers[url] = .failure(error)
        lock.unlock()
    }

    /// Hold every request for `url` until the gate is released — the window a
    /// test asserts `state(of:)` is `installing` in, and the one it starts a
    /// second, coalescing `install` from.
    ///
    /// Blocking is sound here because the seam is `nonisolated`: the engine
    /// `await`s it from the main actor, so the call runs on the cooperative pool
    /// and the main actor stays free — `Gate`'s whole premise.
    func hold(_ url: URL, on gate: Gate) {
        lock.lock()
        gates[url] = gate
        lock.unlock()
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func requestCount(for url: URL) -> Int {
        requestedURLs.filter { $0 == url }.count
    }

    func data(from url: URL) async throws -> Data {
        // Recorded before the wait, so a test can see the request has arrived
        // while it is still being held. The locking is factored into a
        // synchronous method rather than written inline: `lock()`/`unlock()` in
        // an `async` body is a hard error under the Swift 6 language mode, and
        // there is no suspension point between the two here anyway.
        let (gate, answer) = claim(url)
        gate?.wait()

        switch answer {
        case .data(let data): return data
        case .failure(let error): throw error
        case nil: throw Failure.notStubbed
        }
    }

    private func claim(_ url: URL) -> (Gate?, Answer?) {
        lock.lock()
        defer { lock.unlock() }
        requested.append(url)
        return (gates[url], answers[url])
    }
}

/// The Go toolchain as the app would report it (D18), scripted.
///
/// The whole seam is one answer, so the fake is one stored value plus a counter:
/// what the model's rules turn on is *which* report it got, and the counter is
/// what pins "discovery runs once per app run, including the negative answer".
final class ScriptedGoDiscovery: LSPGoToolchainDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var report: LSPGoToolchainReport
    private var calls = 0
    private var gate: Gate?

    init(_ report: LSPGoToolchainReport) {
        self.report = report
    }

    /// No `go` anywhere.
    static var missing: ScriptedGoDiscovery { ScriptedGoDiscovery(.missing) }

    /// A toolchain, with or without a gopls the user installed themselves.
    static func found(
        go goPath: String = "/usr/local/go/bin/go",
        gopls goplsPath: String? = nil
    ) -> ScriptedGoDiscovery {
        ScriptedGoDiscovery(.found(goPath: goPath, goplsPath: goplsPath))
    }

    /// Hold the search until the gate is released — the window a test asserts
    /// `pending` in. Blocking is sound for `ScriptedDownloader.hold(_:on:)`'s
    /// reason: the seam is `nonisolated`, so it runs on the cooperative pool.
    func hold(on gate: Gate) {
        lock.lock()
        self.gate = gate
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func discover() async -> LSPGoToolchainReport {
        let (gate, answer) = claim()
        gate?.wait()
        return answer
    }

    private func claim() -> (Gate?, LSPGoToolchainReport) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return (gate, report)
    }
}

/// `go install` as a value: it writes one file where `GOBIN` points, or it does
/// not.
///
/// The three interesting outcomes are all here, because all three are rules the
/// model has to have: a build that works, a build that fails (no network, a
/// compile error, a cancelled quit), and a build that *reports success and
/// produces nothing* — the one the `executableMissing` guard exists for, and the
/// one that would otherwise commit a version directory naming an executable that
/// is not there.
final class ScriptedGoInstaller: LSPGoModuleInstalling, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case buildFailed

        var errorDescription: String? { "build failed: no required module provides package" }
    }

    enum Outcome {
        /// Writes the binary at `<binDirectory>/gopls` and answers its URL.
        case builds
        /// Answers a URL for a binary it never wrote.
        case buildsNothing
        case fails(Error)
    }

    /// One call, recorded whole — the pin and the toolchain are what a test
    /// asserts `go install` was asked for.
    struct Call: Equatable {
        let module: String
        let version: String
        let goExecutablePath: String
        let binDirectory: URL
    }

    private let tree: StubFileTree
    private let lock = NSLock()
    private var outcome: Outcome = .builds
    private var gate: Gate?
    private var recorded: [Call] = []

    init(writingInto tree: StubFileTree) {
        self.tree = tree
    }

    func setOutcome(_ outcome: Outcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func hold(on gate: Gate) {
        lock.lock()
        self.gate = gate
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func install(
        module: String,
        version: String,
        using goExecutablePath: String,
        into binDirectory: URL
    ) async throws -> URL {
        // Recorded before the wait, so a test can see the build has started
        // while it is still being held.
        let (gate, outcome) = record(
            Call(
                module: module,
                version: version,
                goExecutablePath: goExecutablePath,
                binDirectory: binDirectory
            )
        )
        gate?.wait()

        let executable = binDirectory.appendingPathComponent("gopls")
        switch outcome {
        case .fails(let error):
            throw error
        case .buildsNothing:
            return executable
        case .builds:
            // The write hops to the main actor, for `ScriptedUnpacker.unpack`'s
            // reason: this seam is `nonisolated async`, and `StubFileTree` is a
            // plain dictionary the model reads from the main actor.
            try await MainActor.run {
                try tree.write("#!gopls \(version)", to: executable)
            }
            return executable
        }
    }

    private func record(_ call: Call) -> (Gate?, Outcome) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return (gate, outcome)
    }
}

/// An unpacker that writes a canned tree into a `StubFileTree` — or fails.
final class ScriptedUnpacker: LSPArchiveUnpacking, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case corrupt

        var errorDescription: String? { "The archive could not be read." }
    }

    /// One call, recorded whole: the bytes handed over, where they were to go,
    /// and the strip depth the manifest asked for.
    struct Call: Equatable {
        let archive: Data
        let format: LSPArchiveFormat
        let destination: URL
        let stripComponents: Int
    }

    private let tree: StubFileTree
    private let lock = NSLock()
    private var trees: [Data: [String: String]] = [:]
    private var failures: Set<Data> = []
    private var recorded: [Call] = []

    init(writingInto tree: StubFileTree) {
        self.tree = tree
    }

    /// What the archive served at `url` expands into, as subpath → contents,
    /// relative to wherever it is unpacked.
    func stub(_ url: URL, tree entries: [String: String]) {
        lock.lock()
        trees[ScriptedArchive.bytes(for: url)] = entries
        lock.unlock()
    }

    /// Fail when handed the archive served at `url` — a truncated tarball that
    /// nonetheless hashed correctly cannot happen, but a `tar` that dies on a
    /// full disk can.
    func fail(_ url: URL) {
        lock.lock()
        failures.insert(ScriptedArchive.bytes(for: url))
        lock.unlock()
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) -> ([String: String]?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return (trees[call.archive], failures.contains(call.archive))
    }

    func unpack(
        _ archive: Data,
        format: LSPArchiveFormat,
        into destination: URL,
        stripComponents: Int
    ) async throws {
        // Synchronous, for the reason `ScriptedDownloader.claim(_:)` states.
        let (entries, fails) = record(
            Call(
                archive: archive,
                format: format,
                destination: destination,
                stripComponents: stripComponents
            )
        )

        if fails { throw Failure.corrupt }

        // An unregistered archive still materialises *something*, so a test that
        // does not care what is inside a component still gets a directory that
        // exists — which is what `state(of:)` reads.
        let contents = entries ?? ["payload": String(decoding: archive, as: UTF8.self)]

        // The writes hop to the main actor, and they have to. This method is a
        // `nonisolated async` protocol requirement, so it runs on the cooperative
        // pool — that is the whole point of the seam, and it is what keeps the
        // engine from holding the main actor while 53 MB moves. But `StubFileTree`
        // is a plain dictionary with no synchronisation over its contents, and the
        // engine reads it *from the main actor* (`state(of:)` is a directory
        // listing) while another component's install is unpacking. Writing from
        // this thread is then two threads in one `Dictionary`, which is not a
        // flaky assertion but a corrupted hash table — it showed up as an
        // intermittent SIGSEGV in whichever test happened to overlap two installs.
        // Only the tree mutation hops; the recording above stays here, under the
        // lock, so "which archive was unpacked where" is still observed off-actor.
        try await MainActor.run {
            for (subpath, text) in contents.sorted(by: { $0.key < $1.key }) {
                let url = subpath
                    .split(separator: "/")
                    .reduce(destination) { $0.appendingPathComponent(String($1)) }
                try tree.write(text, to: url)
            }
        }
    }
}
