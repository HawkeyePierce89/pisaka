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
/// `xcrun --find` answers nothing, this type answers `nil`, the transport factory
/// throws `launchFailed`, and `LSPWorkspace` spends one restart on the failure —
/// which is why the answer is *cached, including the negative one*: without that,
/// a machine with no toolchain would fork `xcrun` once per keystroke forever.
///
/// The cache is per app run, not per folder: `DEVELOPER_DIR` is read from the
/// environment the app was launched with and cannot change under a running
/// process, and someone who runs `xcode-select` mid-session gets the old
/// toolchain until the next launch. Stated rather than papered over — the
/// alternative is invalidation logic for an event nobody has ever hit.
enum LSPToolchain {
    /// Resolved paths, keyed by tool name. The value is itself optional, so a
    /// *recorded* "not found" is distinguishable from "not looked up yet" and is
    /// never re-run.
    private static let lock = NSLock()
    private static var resolved: [String: String?] = [:]

    /// The absolute path to `name` inside the active toolchain, or `nil` when the
    /// lookup fails for any reason (no Xcode, no command line tools, a
    /// `DEVELOPER_DIR` pointing at nothing, `xcrun` itself missing).
    ///
    /// Blocking, and deliberately so: it is one `xcrun` per tool per app run, and
    /// making it `async` would push a `Task` hop into `LSPWorkspace`'s transport
    /// factory — which is synchronous precisely because launching a process is
    /// something the main-actor turn that decided to launch it can just do. Call
    /// `prewarm()` at startup and the first real lookup is a dictionary hit.
    static func toolPath(named name: String) -> String? {
        lock.lock()
        if let cached = resolved[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = locate(name)

        lock.lock()
        // Last writer wins. Two concurrent lookups of the same tool run `xcrun`
        // twice and agree on the answer; a lock held across the subprocess would
        // block whoever asked for a *different* tool behind it.
        resolved[name] = found
        lock.unlock()
        return found
    }

    /// Resolve `launch` to an executable path, or `nil` when there is nothing to
    /// run.
    ///
    /// `.executable(path:)` — what phase 2b's node-based servers will use — is
    /// checked for existence and the executable bit here rather than being handed
    /// to `Process` to fail on, so both launch kinds report "not on this machine"
    /// the same way and `LSPWorkspace` sees one failure shape.
    static func executablePath(for launch: LSPServerDescription.Launch) -> String? {
        switch launch {
        case .toolchainTool(let name):
            return toolPath(named: name)
        case .executable(let path):
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
    }

    /// Kick off resolution off the main thread.
    ///
    /// `xcrun` is fast when the toolchain is warm and takes a noticeable moment
    /// when it is not, and the first ⌘-click in a cold project is exactly when it
    /// would otherwise run — on the main actor, inside the launch turn. Called
    /// from app startup, this moves that cost to a background queue before anyone
    /// asks. Purely an optimisation: correctness does not depend on it, and a
    /// lookup that arrives first simply fills the same cache.
    static func prewarm(_ registry: LSPServerRegistry = .standard) {
        let names: [String] = registry.descriptions.compactMap { description in
            guard case .toolchainTool(let name) = description.launch else { return nil }
            return name
        }
        guard !names.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for name in names { _ = toolPath(named: name) }
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
