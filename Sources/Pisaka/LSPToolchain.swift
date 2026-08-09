#if os(macOS)
import Foundation
import PisakaCore

/// Where a language server's executable actually is on *this* machine.
///
/// `LSPServerDescription.Launch` is a description, not a path (D9): Core cannot
/// run `xcrun`, and hard-coding `/Applications/Xcode.app/…/sourcekit-lsp` would
/// break the moment someone runs `xcode-select`, installs a beta alongside a
/// release, or exports `DEVELOPER_DIR`. Resolution is therefore the app's job,
/// and it is exactly one shell-out.
///
/// **Nothing is bundled and nothing is downloaded.** If the machine has no Xcode,
/// `xcrun --find` answers nothing, this type answers `.missing`, the transport
/// factory throws `launchFailed`, and `LSPWorkspace` spends one restart on the
/// failure — which is why the answer is *cached, including the negative one*:
/// without that, a machine with no toolchain would fork `xcrun` once per keystroke
/// forever.
///
/// **Nothing here blocks its caller.** The one caller is a `@MainActor` transport
/// factory, so the lookup runs on a background queue and the answer is whatever is
/// already recorded — see `Resolution`.
///
/// The cache is per app run, not per folder: `DEVELOPER_DIR` is read from the
/// environment the app was launched with and cannot change under a running
/// process, and someone who runs `xcode-select` mid-session gets the old
/// toolchain until the next launch. Stated rather than papered over — the
/// alternative is invalidation logic for an event nobody has ever hit.
enum LSPToolchain {
    /// What is known about a launch description right now — **without running
    /// anything**.
    ///
    /// `pending` is the case that makes this type worth having. There is no
    /// blocking lookup in this file's API, deliberately: the only caller is
    /// `LSPWorkspace`'s transport factory, which is `@MainActor` and called
    /// synchronously inside the launch turn, so a `waitUntilExit` reachable from
    /// there is a main-thread stall of however long a cold `xcrun` takes — the one
    /// thing D7's whole "answer from tree-sitter and start the server behind it"
    /// shape exists to prevent. So an unresolved tool answers `pending`, the
    /// factory refuses *without* spending restart budget, that one request falls
    /// back, and the background lookup this starts makes every later one a
    /// dictionary hit.
    enum Resolution: Equatable {
        case found(String)
        /// Looked up and not on this machine (no Xcode, no command line tools, a
        /// `DEVELOPER_DIR` pointing at nothing, `xcrun` itself missing). Recorded,
        /// so it is never looked up again.
        case missing
        /// Not looked up yet. A lookup is now running.
        case pending
    }

    /// Resolved paths, keyed by tool name. The value is itself optional, so a
    /// *recorded* "not found" is distinguishable from "not looked up yet" and is
    /// never re-run.
    private static let lock = NSLock()
    private static var resolved: [String: String?] = [:]
    /// Tools whose lookup is running right now, so two callers arriving before the
    /// first answer starts one `xcrun`, not two.
    private static var inFlight: Set<String> = []

    /// What is known about `launch`, and — for a toolchain tool nothing has looked
    /// up yet — a background lookup started on the way out.
    ///
    /// `.executable(path:)` — what phase 2b's node-based servers will use — is
    /// answered from a `stat` rather than deferred: there is no subprocess to wait
    /// for, so there is nothing to be `pending` about.
    static func resolution(for launch: LSPServerDescription.Launch) -> Resolution {
        switch launch {
        case .toolchainTool(let name):
            lock.lock()
            let cached = resolved[name]
            lock.unlock()
            switch cached {
            case .some(.some(let path)): return .found(path)
            case .some(.none): return .missing
            case .none:
                startResolution(of: name)
                return .pending
            }
        case .executable(let path):
            return FileManager.default.isExecutableFile(atPath: path) ? .found(path) : .missing
        }
    }

    /// Kick off resolution off the main thread.
    ///
    /// `xcrun` is fast when the toolchain is warm and takes a noticeable moment
    /// when it is not, and the first ⌘-click in a cold project is exactly when it
    /// would otherwise be wanted. Called from app startup, this has the answer
    /// cached before anyone asks; without it, the first request answers from
    /// tree-sitter and the second is semantic.
    static func prewarm(_ registry: LSPServerRegistry = .standard) {
        for description in registry.descriptions {
            guard case .toolchainTool(let name) = description.launch else { continue }
            startResolution(of: name)
        }
    }

    /// Run one `xcrun` for `name` on a background queue, unless the answer is
    /// already recorded or a lookup is already running for it.
    private static func startResolution(of name: String) {
        lock.lock()
        guard resolved[name] == nil, inFlight.insert(name).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        // `.userInitiated` rather than `.utility`: the prewarm is speculative, but
        // a lookup started by `resolution(for:)` has a user waiting on the *next*
        // request being semantic instead of falling back again.
        DispatchQueue.global(qos: .userInitiated).async {
            let found = locate(name)
            lock.lock()
            resolved[name] = found
            inFlight.remove(name)
            lock.unlock()
        }
    }

    /// The one shell-out: `xcrun --find <name>`.
    ///
    /// Run through `/usr/bin/xcrun` directly rather than `/usr/bin/env xcrun`,
    /// because this is a fixed system path and going through `env` would let a
    /// `PATH` entry decide which `xcrun` resolves the toolchain. The environment
    /// is inherited wholesale and untouched, which is precisely how `DEVELOPER_DIR`
    /// is honoured — `xcrun` reads it itself, so there is nothing to implement.
    ///
    /// stdin is `/dev/null` for `GitCLIService.runBlocking`'s reason (nothing here
    /// has anything to read, and a prompt nobody can answer would hang a queue);
    /// stderr is captured and dropped, since "xcrun: error: unable to find utility"
    /// is an ordinary answer here, not something to show anyone (D7: no alerts,
    /// ever).
    private static func locate(_ name: String) -> String? {
        let executable = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--find", name]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes are drained before waiting, for `GitCLIService`'s deadlock
        // reason: `xcrun` writing more than a pipe buffer of diagnostics while we
        // block on `waitUntilExit` would wedge both sides. The volumes here are
        // tiny, but the shape is the one that stays correct when they are not.
        let errorQueue = DispatchQueue(label: "LSPToolchain.stderr")
        errorQueue.async { _ = errors.fileHandleForReading.readDataToEndOfFile() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errorQueue.sync {}
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

#endif
