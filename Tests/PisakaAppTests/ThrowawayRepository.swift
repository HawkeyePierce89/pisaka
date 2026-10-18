#if os(macOS)
import Foundation

/// Throwaway git repositories under one scratch directory, for the suites that
/// run the real `git` (`GitCLIServiceRepositoryTests`,
/// `GitChangeControllerRepositoryTests`).
///
/// The helper's own git runs with the global and system configuration masked
/// (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`), so a signing,
/// hook or default-branch setting on the machine cannot change the fixture.
/// The code under test inherits the process environment, as it does in the app.
struct ThrowawayRepository {
    let scratch: URL

    func makeRepository(_ name: String) throws -> URL {
        let repo = scratch.appendingPathComponent(name, isDirectory: true)
        try git(["init", "-q", "-b", "main", repo.path], in: scratch)
        try git(["config", "user.name", "Pisaka Tests"], in: repo)
        try git(["config", "user.email", "tests@pisaka.invalid"], in: repo)
        return repo
    }

    func commitFile(_ path: String, contents: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        try git(["add", "--", path], in: repo)
        try git(["commit", "-q", "-m", "add \(path)"], in: repo)
    }

    func currentBranch(in repo: URL) throws -> String {
        try git(["branch", "--show-current"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs `git` in `directory` with the machine's configuration masked and
    /// fails the call on a non-zero exit, returning stdout.
    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let stdout = Pipe()
        // stderr goes to a file rather than a second pipe: reading two pipes one
        // after the other deadlocks once git fills the unread one.
        let errorLog = scratch.appendingPathComponent("helper-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: errorLog)
        defer { try? stderr.close() }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let err = (try? Data(contentsOf: errorLog)) ?? Data()
        guard process.terminationStatus == 0 else {
            throw HelperFailure(
                arguments: arguments,
                stderr: String(decoding: err, as: UTF8.self)
            )
        }
        return String(decoding: out, as: UTF8.self)
    }

    private struct HelperFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let stderr: String
        var description: String { "git \(arguments.joined(separator: " ")) failed: \(stderr)" }
    }
}

#endif
