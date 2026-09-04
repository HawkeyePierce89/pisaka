import XCTest

/// Static verification of the Pull Requests feature's cross-layer rules.
///
/// A repository-file suite in the `DatabaseViewerSourceGatingTests` shape: it
/// reads `Sources/` through `#filePath` with Foundation only and matches against
/// **comment-stripped** text, so a rule cannot be satisfied by a comment that
/// merely describes it. Every file this suite reads states its own rules in
/// prose and several of them quote the very tokens matched below — the
/// coordinator's doc comment spells `autosave.suspend()`, the transport's spells
/// `gh --version`, `ExecutableLocator`'s spells `gh pr checkout` — so a raw
/// `contains` over the source would stay green after the call site it names is
/// deleted, and would fail the moment somebody explained the rule.
///
/// **Two strippers, deliberately.** Most rules read
/// `LSPSourceGatingTests.strippingCommentsAndStringLiterals`, this repository's
/// usual scanner. The `gh`-vocabulary rule cannot: `--json` and `"pr", "list"`
/// *are* string literals, so that scanner would delete the very thing the rule
/// is about and pass on an app file that ran `gh` behind Core's back. It reads
/// `strippingComments(_:)` below instead — the same scanner with the literals
/// kept — and the doc comment on that function says so.
///
/// **Why the compiler cannot see any of this:**
///
/// 1. `Process` is a Foundation type. `PisakaCore` must stay Foundation-only
///    *and* free of subprocesses so the domain logic is portable and testable;
///    an app-side file that ran `gh` itself would compile perfectly and would be
///    a second place that knows what a `gh` argument list looks like.
/// 2. The compiler cannot keep the argument vocabulary in one place. This is
///    `DatabaseQuery`'s rule applied to a second composed language: Core spells
///    every flag so the whole vocabulary can be asserted byte for byte in a
///    target that links no `Process`. An app file appending `--json` to a
///    command builds and runs and puts a second schema in a file no parser test
///    ever reads.
/// 3. The compiler cannot ensure the app-side files are macOS-gated; without
///    `#if os(macOS)` they would break the iOS build, which has no `gh`, no
///    subprocesses at all, and no surface for any of this.
/// 4. The compiler cannot see that `gh pr checkout` stays inside the writer
///    bracket. It is the app's eighth gated worktree operation, and a checkout
///    reached through a second site — or through none — compiles, runs, and
///    moves the worktree out from under a revert that has already snapshotted
///    it. The gate travels as an injected closure precisely so that no file
///    under the feature names `autosave` or `localChanges` at all, which is a
///    rule about absence and therefore invisible to every other test.
/// 5. The compiler cannot count the definitions of the discovery search. It was
///    lifted out of `LSPRustToolchainService` so there is one answer to "where is
///    a program somebody else installed"; a second hand-rolled `PATH` walk
///    compiles and diverges silently, on exactly the machines nobody testing has.
/// 6. The compiler cannot see where a refresh is triggered from. Freshness here
///    is event-driven by decision (G9) — a branch change, the panel becoming
///    visible, a completed write — and a trigger added in the scene would work
///    while putting the feature's behaviour in the one file the ticket forbids
///    growing, where no doc comment describes it.
/// 7. The compiler cannot see polling. `Timer`, `DispatchQueue.asyncAfter` and
///    `Task.sleep` all compile, and a two-second repeat in the panel would look
///    like a responsive feature while spending a GitHub API call every two
///    seconds for as long as the panel is open.
///
/// **The one stated exception.** `GitHubCLIProcessTransport.swift` is exempt from
/// the no-polling ban: its command deadline and its SIGTERM→SIGKILL teardown
/// grace are lifted verbatim from `LSPRustToolchainService` (a `Thread.sleep`
/// loop plus `DispatchSemaphore.wait(timeout:)`) and are a *per-command bound* on
/// a child process, not a repeating read of anything. It is still held to the
/// `Timer` half of the ban, because a timer there could only be a repeat.
final class GitHubSourceGatingTests: XCTestCase {

    // MARK: - The feature's files

    /// The Core half. Everything that decides anything: the seam values, the
    /// argument vocabulary, the one schema file, the availability decision, the
    /// two sheets' pure halves and the model.
    private static let expectedCoreFiles: Set<String> = [
        "GitHubAPI.swift",
        "GitHubAvailability.swift",
        "GitHubCLI.swift",
        "GitHubCommands.swift",
        "GitHubCreatePlan.swift",
        "GitHubMergePlan.swift",
        "GitHubPullRequest.swift",
        "GitHubVersion.swift",
        "PullRequestModel.swift",
    ]

    /// The app half: the transport, the shared locator, the coordinator and the
    /// three surfaces.
    private static let expectedAppFiles: Set<String> = [
        "ExecutableLocator.swift",
        "GitHubCLIProcessTransport.swift",
        "NewPullRequestSheet.swift",
        "PullRequestCoordinator.swift",
        "PullRequestIndicatorView.swift",
        "PullRequestsPanelView.swift",
    ]

    /// The three views, which are the surfaces the no-polling ban covers on the
    /// app side.
    private static let viewFiles: Set<String> = [
        "NewPullRequestSheet.swift",
        "PullRequestIndicatorView.swift",
        "PullRequestsPanelView.swift",
    ]

    /// Matched by name rather than by a hand-kept list alone, so a file added
    /// later falls under these rules the moment it exists — and fails the
    /// inventory test until somebody says, here, that it is part of the feature.
    private static let filePrefixes = ["GitHub", "PullRequest", "NewPullRequest", "ExecutableLocator"]

    // MARK: - Reading

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    private func featureFiles(under relativeDirectory: String) throws -> [URL] {
        try swiftFiles(under: relativeDirectory).filter { url in
            Self.filePrefixes.contains { url.lastPathComponent.hasPrefix($0) }
        }
    }

    private func source(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The usual reading: comments *and* string literals gone.
    private func code(of url: URL) throws -> String {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(try source(of: url))
    }

    private func code(ofFileNamed name: String, under relativeDirectory: String) throws -> String {
        try code(of: Self.repositoryRoot.appendingPathComponent(relativeDirectory + "/" + name))
    }

    private func occurrences(of pattern: String, in code: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Swift source with its comments removed and its **string literals kept**.
    ///
    /// The one reading the `gh`-vocabulary rule can use, and used by nothing
    /// else. Literals are tracked rather than ignored — a `//` inside a URL is
    /// not the start of a comment — but their contents survive, which is the
    /// whole point: the rule is about a flag being *spelled*, and the ordinary
    /// scanner deletes exactly the text that would prove it.
    static func strippingComments(_ source: String) -> String {
        enum State {
            case code
            case lineComment
            case blockComment(depth: Int)
            case string
            case multilineString
        }

        let characters = Array(source)
        var result = ""
        var state = State.code
        var index = 0

        func matches(_ text: String, at position: Int) -> Bool {
            let needle = Array(text)
            guard position + needle.count <= characters.count else { return false }
            return Array(characters[position..<(position + needle.count)]) == needle
        }

        while index < characters.count {
            let character = characters[index]
            switch state {
            case .code:
                if matches("//", at: index) {
                    state = .lineComment
                    index += 2
                } else if matches("/*", at: index) {
                    state = .blockComment(depth: 1)
                    index += 2
                } else if matches("\"\"\"", at: index) {
                    state = .multilineString
                    result.append("\"\"\"")
                    index += 3
                } else {
                    if character == "\"" { state = .string }
                    result.append(character)
                    index += 1
                }
            case .lineComment:
                if character == "\n" {
                    state = .code
                    result.append(character)
                }
                index += 1
            case .blockComment(let depth):
                if matches("/*", at: index) {
                    state = .blockComment(depth: depth + 1)
                    index += 2
                } else if matches("*/", at: index) {
                    state = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    index += 2
                } else {
                    // Newlines survive so the stripped text keeps its line shape.
                    if character == "\n" { result.append(character) }
                    index += 1
                }
            case .string:
                result.append(character)
                if character == "\\", index + 1 < characters.count {
                    result.append(characters[index + 1])
                    index += 2
                } else {
                    // The closing quote, or an unterminated literal running into a
                    // newline: either way the scanner is back in code.
                    if character == "\"" || character == "\n" { state = .code }
                    index += 1
                }
            case .multilineString:
                if matches("\"\"\"", at: index) {
                    state = .code
                    result.append("\"\"\"")
                    index += 3
                } else {
                    result.append(character)
                    index += 1
                }
            }
        }
        return result
    }

    func testTheCommentStripperKeepsLiterals() {
        XCTAssertEqual(Self.strippingComments("let a = \"--json\" // --draft"), "let a = \"--json\" ")
        XCTAssertEqual(Self.strippingComments("let u = \"https://x\"\nlet b = 1"), "let u = \"https://x\"\nlet b = 1")
        XCTAssertEqual(Self.strippingComments("a /* --base */ b"), "a  b")
    }

    // MARK: - The inventory

    /// Both halves of the feature, by set equality.
    ///
    /// Everything below is scoped to these two lists, so a new file that nothing
    /// here knows about would otherwise be exempt from every rule in the suite.
    func testTheFeaturesFilesAreTheOnesThisSuiteChecks() throws {
        XCTAssertEqual(
            Set(try featureFiles(under: "Sources/PisakaCore").map(\.lastPathComponent)),
            Self.expectedCoreFiles,
            "A Core file joined or left the feature. Add it here — every rule below is scoped to this list, so "
                + "an unlisted file is a file none of them apply to."
        )
        XCTAssertEqual(
            Set(try featureFiles(under: "Sources/Pisaka").map(\.lastPathComponent)),
            Self.expectedAppFiles,
            "An app file joined or left the feature. Add it here, and say in the doc comment which side of the "
                + "seam it is on: the platform gating, the Process rule and the argument-vocabulary rule are "
                + "all read off this set."
        )
    }

    // MARK: - Platform gating

    func testEveryAppSideFileIsMacOSGated() throws {
        for url in try featureFiles(under: "Sources/Pisaka") {
            let firstLine = try code(of: url)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            XCTAssertEqual(
                firstLine,
                "#if os(macOS)",
                "\(url.lastPathComponent) must open with #if os(macOS). The feature is macOS-only: it runs a "
                    + "subprocess, which iOS does not have, and an ungated file would break the iOS build."
            )
        }
    }

    func testTheIOSLayerNamesNoneOfTheFeature() throws {
        for url in try swiftFiles(under: "Sources/Pisaka/iOS") {
            let code = try self.code(of: url)
            XCTAssertEqual(
                try occurrences(
                    of: "PullRequest|GitHubCLI|GitHubCommands|GitHubAPI|GitHubAvailability|GitHubVersion"
                        + "|GitHubCreatePlan|ExecutableLocator",
                    in: code
                ),
                0,
                "\(url.lastPathComponent) must not name the Pull Requests feature. There is no iOS surface for "
                    + "it in part 1 and no way to run `gh` there at all, so a reference here is either dead or "
                    + "a build failure waiting for the next iOS change."
            )
        }
    }

    // MARK: - `Process` (G1)

    func testProcessRunsGhInExactlyOneAppFile() throws {
        var naming: Set<String> = []
        for url in try featureFiles(under: "Sources/Pisaka") {
            guard LSPSourceGatingTests.containsToken("Process", in: try code(of: url)) else { continue }
            naming.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            naming,
            ["GitHubCLIProcessTransport.swift"],
            "One file runs `gh`. A second launcher is a second set of answers to the deadline, the "
                + "environment overlay, the teardown and the child registry a quit has to reach — and "
                + "ExecutableLocator is deliberately not one of them: it takes the login shell as a closure "
                + "precisely so that *how* a program is run stays the caller's business."
        )
    }

    func testCoreNeverNamesProcess() throws {
        for url in try swiftFiles(under: "Sources/PisakaCore") {
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("Process", in: try code(of: url)),
                "\(url.lastPathComponent) must not name Process: PisakaCore is Foundation-only and "
                    + "subprocess-free so the domain logic stays portable and `swift test` stays a fast, "
                    + "dependency-free gate."
            )
        }
    }

    // MARK: - The `gh` vocabulary (G6)

    /// The flags, as they are spelled on a command line.
    private static let bannedFlags = [
        "--json",
        "--base",
        "--draft",
        "--version",
        "--head",
        "--state",
        "--limit",
        "--title",
        "--body",
    ]

    /// The subcommands, in both the shapes they could be written in: as adjacent
    /// quoted arguments (how `GitHubCommands` writes them) and as one string (how
    /// somebody shelling out by hand would).
    private static let bannedSubcommands = [
        "\"pr\"\\s*,\\s*\"list\"": "pr list",
        "\"pr\"\\s*,\\s*\"checks\"": "pr checks",
        "\"pr\"\\s*,\\s*\"create\"": "pr create",
        "\"pr\"\\s*,\\s*\"checkout\"": "pr checkout",
        "\"auth\"\\s*,\\s*\"status\"": "auth status",
        "\"repo\"\\s*,\\s*\"view\"": "repo view",
    ]

    /// How many factories compose each subcommand. All ones but `pr list`, which
    /// is two: seven commands are reached through eight factories, because the
    /// current-branch lookup is `pr list` with a `--head` filter rather than a
    /// command of its own.
    private static let subcommandFactories = ["pr list": 2]

    /// The files the ban covers: the whole app half of the feature plus the two
    /// scene files it touches.
    ///
    /// Scoped rather than swept over `Sources/Pisaka` because two of these
    /// spellings are not GitHub's — `LSPRustToolchainService` probes `cargo` with
    /// a perfectly legitimate `--version` — and a rule that failed on those would
    /// be about the string rather than about who composes a `gh` command.
    private func vocabularyScopedFiles() throws -> [URL] {
        try featureFiles(under: "Sources/Pisaka") + ["PisakaApp.swift", "ContentView.swift"].map {
            Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/" + $0)
        }
    }

    func testNoGhArgumentIsSpelledInTheAppLayer() throws {
        for url in try vocabularyScopedFiles() {
            let code = Self.strippingComments(try source(of: url))
            for flag in Self.bannedFlags {
                XCTAssertFalse(
                    code.contains(flag),
                    "\(url.lastPathComponent) spells \(flag). Every `gh` argument lives in "
                        + "GitHubCommands.swift, which is what lets the whole vocabulary be asserted byte for "
                        + "byte in a target that links no Process."
                )
            }
            for (pattern, spelling) in Self.bannedSubcommands {
                XCTAssertEqual(
                    try occurrences(of: pattern, in: code) + (code.contains(spelling) ? 1 : 0),
                    0,
                    "\(url.lastPathComponent) spells `gh \(spelling)`. The app layer runs argument lists it is "
                        + "handed; it composes none."
                )
            }
        }
    }

    /// And the other half of the same rule: the vocabulary really is in that one
    /// file, so the ban above cannot pass because the words moved somewhere the
    /// scope does not reach.
    func testTheWholeVocabularyIsSpelledInTheCommandsFile() throws {
        let commands = Self.strippingComments(
            try source(of: Self.repositoryRoot.appendingPathComponent("Sources/PisakaCore/GitHubCommands.swift"))
        )
        for flag in Self.bannedFlags {
            XCTAssertTrue(
                commands.contains(flag),
                "GitHubCommands.swift no longer spells \(flag). Either the command changed — say so, here — or "
                    + "the argument moved to a file the ban above does not read."
            )
        }
        for (pattern, spelling) in Self.bannedSubcommands {
            let expected = Self.subcommandFactories[spelling] ?? 1
            XCTAssertEqual(
                try occurrences(of: pattern, in: commands),
                expected,
                "GitHubCommands.swift must compose `gh \(spelling)` exactly \(expected) time(s): eight "
                    + "factories over seven commands is what makes the argument-list tests exhaustive, and a "
                    + "ninth composition is a command nothing asserts byte for byte."
            )
        }
    }

    // MARK: - The eighth gated operation (G12)

    func testTheCheckoutReachesTheWriterBracketThroughExactlyOneSite() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "runBranchOperation\\(\\.pullRequest", in: app),
            1,
            "The scene hands its writer bracket over once, as the coordinator's runCheckout. A second site is "
                + "a second answer to what a checkout suspends, snapshots and resyncs."
        )

        let coordinator = try code(ofFileNamed: "PullRequestCoordinator.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "runBracket\\s*\\{|runBracket\\(", in: coordinator),
            1,
            "The coordinator is the one place an operation is put inside the bracket — the model composes the "
                + "command and hands it out, and this is where it is run."
        )

        var naming: Set<String> = []
        for url in try featureFiles(under: "Sources/Pisaka") {
            guard LSPSourceGatingTests.containsToken("runBracket", in: try code(of: url)) else { continue }
            naming.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            naming,
            ["PullRequestCoordinator.swift"],
            "Only the coordinator holds the bracket. A view reaching it directly would run a worktree rewrite "
                + "from the surface that is about to be redrawn by it."
        )
    }

    func testNoFileUnderTheFeatureNamesTheWriterGate() throws {
        let files = try featureFiles(under: "Sources/PisakaCore") + featureFiles(under: "Sources/Pisaka")
        for url in files {
            let code = try self.code(of: url)
            for gate in ["autosave", "localChanges"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(gate, in: code),
                    "\(url.lastPathComponent) must not name `\(gate)`. The feature is a reader that *consults* "
                        + "the gate and never raises it, and the way that stays true is that the question "
                        + "arrives as an injected closure wired in the scene alone."
                )
            }
        }
    }

    // MARK: - The discovery helper (G7)

    func testTheExecutableLocatorHasOneDefinitionAndTwoCallers() throws {
        var naming: Set<String> = []
        for url in try swiftFiles(under: "Sources/Pisaka") {
            guard LSPSourceGatingTests.containsToken("ExecutableLocator", in: try code(of: url)) else { continue }
            naming.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            naming,
            ["ExecutableLocator.swift", "GitHubCLIProcessTransport.swift", "LSPRustToolchainService.swift"],
            "One definition, two callers. LSPGoToolchainService is deliberately not a third: it carries its "
                + "own directory list and its own decisions, and folding it in would mean changing them. A "
                + "fourth file here is either a new caller (say so) or a second hand-rolled PATH walk, which "
                + "diverges silently on exactly the machines the login-shell step exists for."
        )

        let locator = try code(ofFileNamed: "ExecutableLocator.swift", under: "Sources/Pisaka")
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("Process", in: locator),
            "The locator launches nothing. The one step that costs a subprocess is handed in as a closure, "
                + "because the deadline, the child registry and the teardown differ between its two callers."
        )

        let rust = try code(ofFileNamed: "LSPRustToolchainService.swift", under: "Sources/Pisaka")
        for member in ["locate", "pathEntries", "executables"] {
            XCTAssertGreaterThan(
                try occurrences(of: "ExecutableLocator\\.\(member)\\b", in: rust),
                0,
                "LSPRustToolchainService must reach \(member) through the shared locator rather than keeping a "
                    + "copy of it: the search order, the login-shell decisions and the duplicate rule are one "
                    + "answer, not two."
            )
        }
        for kept in ["func loginShellPath", "func pathEntries", "func executables"] {
            XCTAssertEqual(
                try occurrences(of: kept, in: rust),
                0,
                "LSPRustToolchainService must not redeclare \(kept): the definition moved to ExecutableLocator, "
                    + "and a copy left behind here is the divergence this extraction removed."
            )
        }
    }

    // MARK: - Where the refresh triggers live (G9)

    func testTheRefreshTriggersLiveInTheCoordinatorAndThePanelViewOnly() throws {
        var naming: Set<String> = []
        for url in try featureFiles(under: "Sources/Pisaka") {
            let code = try self.code(of: url)
            guard try occurrences(of: "\\brefresh\\s*\\(|\\bpanelShown\\s*\\(", in: code) > 0 else { continue }
            naming.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            naming,
            ["PullRequestCoordinator.swift", "PullRequestsPanelView.swift"],
            "The coordinator holds the branch subscription and the post-operation refreshes; the panel view "
                + "holds the panel-shown call, because the panel's own view is where 'the panel is on screen' "
                + "is actually known. A third file is a trigger nobody documented."
        )

        let panel = try code(ofFileNamed: "PullRequestsPanelView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "\\.onAppear", in: panel),
            1,
            "One .onAppear, and it is the panel-shown trigger. A second would re-read for a row appearing "
                + "inside the list, which is a scroll turning into an API call."
        )
        XCTAssertEqual(
            try occurrences(of: "coordinator\\.panelShown\\(\\)", in: panel),
            1,
            "…and it calls panelShown() exactly once."
        )
    }

    func testTheSceneNamesNoRefreshTrigger() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "pullRequests\\s*\\.", in: app),
            2,
            "The scene touches the coordinator exactly twice: it wires it, and it tears it down. Every "
                + "refresh trigger lives in the coordinator or in the panel's own view — PisakaApp.swift is at "
                + "its measured file_length ceiling, and the ticket forbids growing it for behaviour that has "
                + "a file of its own."
        )
        XCTAssertEqual(
            try occurrences(of: "pullRequests\\.start\\(", in: app),
            1,
            "…the first of the two is the start(…) call."
        )
        XCTAssertEqual(
            try occurrences(of: "pullRequests\\.terminateNow\\(\\)", in: app),
            1,
            "…and the second is the terminate observer's, beside the language servers' own. A `gh pr "
                + "checkout` in flight has a `git` beneath it rewriting a worktree, and nothing else in the "
                + "app can reach it once the process is going away."
        )
        XCTAssertEqual(
            try occurrences(of: "pullRequests\\.(refresh|panelShown)", in: app),
            0,
            "…and neither of them is a refresh: freshness is event-driven and every event lives in the "
                + "coordinator or the panel view."
        )

        let content = try code(ofFileNamed: "ContentView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "panelShown|pullRequests\\.refresh|model\\.refresh", in: content),
            0,
            "The window chrome draws the feature; it does not decide when the feature reads. Its two "
                + "references are the panel branch and the indicator, both of which are handed the model."
        )
    }

    // MARK: - No polling (G9)

    /// The ban, and its one stated exception.
    ///
    /// Freshness here is event-driven: three triggers, each of them a thing that
    /// actually happened. A sleep or a timer in any of these files could only be
    /// a repeat, and a repeat is a GitHub API call spent per tick for as long as
    /// a panel stays open.
    func testTheFeatureNeverPolls() throws {
        let core = try featureFiles(under: "Sources/PisakaCore")
        let views = try featureFiles(under: "Sources/Pisaka")
            .filter { Self.viewFiles.contains($0.lastPathComponent) }
        XCTAssertEqual(
            Set(views.map(\.lastPathComponent)),
            Self.viewFiles,
            "The three views must exist; if one was renamed, this rule is looking in the wrong place."
        )

        for url in core + views {
            let code = try self.code(of: url)
            for term in ["Timer", "asyncAfter", "Task\\.sleep", "Thread\\.sleep", "DispatchSemaphore"] {
                XCTAssertEqual(
                    try occurrences(of: term, in: code),
                    0,
                    "\(url.lastPathComponent) must not name \(term). In a Core model or one of the three views "
                        + "a sleep or a timer *is* polling; the only stated exception is "
                        + "GitHubCLIProcessTransport.swift, whose sleeps bound one child process rather than "
                        + "repeating a read."
                )
            }
        }
    }

    func testTheTransportsExceptionIsBoundedRatherThanRepeating() throws {
        let transport = try code(ofFileNamed: "GitHubCLIProcessTransport.swift", under: "Sources/Pisaka")
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("Timer", in: transport),
            "The transport's exception covers a command deadline and a teardown grace — both one-shot bounds "
                + "on a child process, both lifted from LSPRustToolchainService. A Timer could only be a "
                + "repeat, which is the thing the exception is not."
        )
        XCTAssertEqual(
            try occurrences(of: "asyncAfter", in: transport),
            0,
            "…and the deadline is enforced on the blocking queue the child is waited on, not by scheduling "
                + "work to come back later."
        )
    }
}
