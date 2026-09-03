import Foundation
@testable import PisakaCore

/// A `GitHubCLITransport` that answers from a script instead of from `gh`.
///
/// `ScriptedDatabaseService`'s principle applied to a process seam, and for the
/// same reason: everything interesting about this feature — which commands a
/// refresh runs and in which order, what a superseded answer is allowed to
/// publish, what a failed list leaves on screen, whether `pr checks` is judged
/// on its exit status — is *sequencing and failure handling*, and none of it
/// needs a `gh` on the machine. The test target cannot link `Process` at all,
/// which is the whole point of the seam.
///
/// Answers are keyed by the **argument list**, which is the one thing to know
/// before writing a test against it. That is deliberately the same value
/// `GitHubCommands` composes, so a test scripts a command by handing over the
/// factory's own answer — `cli.serve(GitHubCommands.version(), stdout: …)` —
/// and a change to an argument list shows up as an unscripted call rather than
/// as a silently different assertion. The working directory and the deadline are
/// *not* part of the key: they are properties of where the command runs, are
/// asserted out of the call log, and keying on them would force every test to
/// restate the root it is trying to assert.
///
/// Three further behaviours, lifted from the database fake because they earned
/// their keep there:
///
/// - A key's script is a queue and **the last step is sticky**: script one
///   answer and every call gets it, script three and the third answers forever
///   after. That is what lets "the second refresh sees a signed-out `gh`" be two
///   scripted steps rather than a mid-test re-script.
/// - An **unscripted call throws** rather than answering an empty result. A test
///   that forgot to script something must fail as a failure, not as an empty
///   pull request list three layers away.
/// - A **`Gate` per key** holds a call mid-flight, so a test can stage a second,
///   superseding refresh in the window the first one is suspended in.
///
/// Thread safety is an `NSLock` over every stored property rather than a
/// main-actor hop: `run(_:)` is `async` on a non-actor type, so its body runs on
/// the cooperative pool while the model awaits it from the main actor — which is
/// exactly what makes the gates' blocking sound, and is `Gate`'s premise.
final class ScriptedGitHubCLI: GitHubCLITransport, @unchecked Sendable {

    enum Failure: Error, LocalizedError, Equatable {
        /// Nothing was scripted for this argument list.
        case notScripted(arguments: [String])

        var errorDescription: String? {
            switch self {
            case .notScripted(let arguments):
                return "No scripted answer for “gh \(arguments.joined(separator: " "))”."
            }
        }
    }

    private let lock = NSLock()
    private var steps: [[String]: [Result<GitHubCommandResult, Error>]] = [:]
    private var gates: [[String]: Gate] = [:]
    private var commandStorage: [GitHubCommand] = []

    // MARK: - Scripting

    /// Answer `arguments` with `result`, replacing any script it had.
    func serve(_ arguments: [String], _ result: GitHubCommandResult) {
        script(arguments, [.success(result)])
    }

    /// Answer `arguments` with a result built from its three parts.
    func serve(_ arguments: [String], stdout: String = "", stderr: String = "", status: Int32 = 0) {
        serve(arguments, GitHubCommandResult(standardOutput: stdout, standardError: stderr, status: status))
    }

    /// Answer `command`'s argument list — the form nearly every test uses, so
    /// the factory that composes a command is also the thing that scripts it.
    func serve(_ command: GitHubCommand, _ result: GitHubCommandResult) {
        serve(command.arguments, result)
    }

    /// Answer `command`'s argument list with a result built from its three parts.
    func serve(_ command: GitHubCommand, stdout: String = "", stderr: String = "", status: Int32 = 0) {
        serve(command.arguments, stdout: stdout, stderr: stderr, status: status)
    }

    /// Answer `arguments` with each element in turn, the last one sticking.
    func serve(_ arguments: [String], sequence results: [GitHubCommandResult]) {
        script(arguments, results.map { .success($0) })
    }

    /// Answer `command` with each element in turn, the last one sticking.
    func serve(_ command: GitHubCommand, sequence results: [GitHubCommandResult]) {
        serve(command.arguments, sequence: results)
    }

    /// Throw `error` for every run of `arguments` — the transport's own three
    /// failures, which arrive before `gh` has said anything.
    func fail(_ arguments: [String], with error: Error = GitHubCLIError.notInstalled) {
        script(arguments, [.failure(error)])
    }

    /// Throw `error` for every run of `command`.
    func fail(_ command: GitHubCommand, with error: Error = GitHubCLIError.notInstalled) {
        fail(command.arguments, with: error)
    }

    /// Hold every run of `arguments` until the gate is released — the window a
    /// test starts a second, superseding refresh in.
    func hold(_ arguments: [String], on gate: Gate) {
        lock.lock()
        gates[arguments] = gate
        lock.unlock()
    }

    /// Hold every run of `command` until the gate is released.
    func hold(_ command: GitHubCommand, on gate: Gate) {
        hold(command.arguments, on: gate)
    }

    /// Script the two probes of a signed-in `gh` of `version` — the prefix of
    /// every refresh that gets as far as listing anything.
    func serveReady(version: String = "2.99.0") {
        serve(GitHubCommands.version(), stdout: "gh version \(version) (2026-09-01)\n")
        serve(GitHubCommands.authStatus(), stderr: "github.com\n  ✓ Logged in to github.com account someone\n")
    }

    private func script(_ arguments: [String], _ newSteps: [Result<GitHubCommandResult, Error>]) {
        lock.lock()
        steps[arguments] = newSteps
        lock.unlock()
    }

    // MARK: - What was asked

    /// Every command run, in call order — the working directory, the deadline
    /// and the re-location flag included, which is where an assertion about
    /// *where* a command ran reads its evidence.
    var commands: [GitHubCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commandStorage
    }

    /// The argument lists run, in call order — the feature's call log, and what
    /// an ordering assertion ("the push ran before `pr create`") reads.
    var argumentLists: [[String]] { commands.map(\.arguments) }

    /// The first word after the subcommand, for the readable form of an ordering
    /// assertion: `["--version", "auth status", "pr list", "pr checks"]`.
    var trace: [String] {
        argumentLists.map { arguments in
            arguments.first == "pr" || arguments.first == "repo" || arguments.first == "auth"
                ? arguments.prefix(2).joined(separator: " ")
                : (arguments.first ?? "")
        }
    }

    /// How many times `arguments` was run.
    func count(for arguments: [String]) -> Int {
        argumentLists.filter { $0 == arguments }.count
    }

    /// How many times `command`'s argument list was run.
    func count(for command: GitHubCommand) -> Int {
        count(for: command.arguments)
    }

    // MARK: - GitHubCLITransport

    func run(_ command: GitHubCommand) async throws -> GitHubCommandResult {
        lock.lock()
        commandStorage.append(command)
        let gate = gates[command.arguments]
        var queue = steps[command.arguments] ?? []
        let step = queue.first
        // The last step sticks; earlier ones are consumed.
        if queue.count > 1 {
            queue.removeFirst()
            steps[command.arguments] = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notScripted(arguments: command.arguments) }
        return try step.get()
    }
}
