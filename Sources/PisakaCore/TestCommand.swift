import Foundation

/// The project signals used to detect a test runner: the names of the entries at
/// the project root (config files like `vitest.config.ts`, `Gemfile`)
/// plus the raw contents of a fixed set of manifests (keyed by file name, e.g.
/// `"package.json"`), so `TestCommand` stays pure — the view layer gathers the
/// listing/contents through `FileServicing` and hands them in.
public struct ProjectTestEvidence: Equatable {
    public let rootEntryNames: Set<String>
    public let manifests: [String: String]

    public init(rootEntryNames: Set<String>, manifests: [String: String]) {
        self.rootEntryNames = rootEntryNames
        self.manifests = manifests
    }
}

/// The outcome of resolving how to test a file: a ready-to-run shell command, or
/// a signal that the language's runner could not be detected (JS/TS only — every
/// other supported language has a single canonical runner).
public enum TestResult: Equatable {
    case command(String)
    case runnerUndetected
}

/// Pure, testable resolution of how to *test* the editor's current file in the
/// embedded terminal, mirroring `RunCommand`. The PTY/session lifecycle lives in
/// the `Pisaka` view layer (a macOS-only concern); only this branch-free
/// detection/command/quoting resolution lives in Core so it stays
/// Foundation-only and unit-tested (the `RunCommand`/`TerminalLaunch` precedent).
public enum TestCommand {
    /// The lowercased extensions that resolve to the JavaScript/TypeScript
    /// runner catalog (vitest/jest/mocha).
    private static let jsExtensions: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"
    ]

    /// Whether `fileName` is a test file for its language, per each ecosystem's
    /// naming convention. Drives the "Run Test" context-menu item and the ⌘U menu
    /// enablement.
    public static func isTestFile(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if jsExtensions.contains(ext) {
            return fileName.contains(".test.") || fileName.contains(".spec.")
        }
        switch ext {
        case "py":
            return fileName.hasPrefix("test_") || fileName.hasSuffix("_test.py")
        case "rb":
            return fileName.hasSuffix("_spec.rb") || fileName.hasSuffix("_test.rb")
        case "php":
            return fileName.hasSuffix("Test.php")
        case "exs":
            return fileName.hasSuffix("_test.exs")
        case "go":
            return fileName.hasSuffix("_test.go")
        case "swift":
            return fileName.hasSuffix("Tests.swift") || fileName.hasSuffix("Test.swift")
        case "rs":
            return true
        default:
            return false
        }
    }

    /// The shell command that tests `fileName` (at `absolutePath`), given the
    /// project's detection `evidence`. `<file>`/`<dir>` are shell-quoted via
    /// `ShellQuote` so spaces and shell metacharacters survive intact.
    /// `.runnerUndetected` for JS/TS with no detectable runner, or an unknown
    /// extension; every other supported language always resolves.
    public static func command(
        forFileName fileName: String,
        absolutePath: String,
        evidence: ProjectTestEvidence
    ) -> TestResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let file = ShellQuote.quote(absolutePath)
        let dir = ShellQuote.quote((absolutePath as NSString).deletingLastPathComponent)

        if jsExtensions.contains(ext) {
            return jsRunner(file: file, evidence: evidence)
        }
        switch ext {
        case "py":
            return .command("pytest " + file)
        case "rb":
            let runner = fileName.hasSuffix("_spec.rb") ? "rspec" : "ruby"
            let prefix = evidence.rootEntryNames.contains("Gemfile") ? "bundle exec " : ""
            return .command(prefix + runner + " " + file)
        case "php":
            return .command("./vendor/bin/phpunit " + file)
        case "exs":
            return .command("mix test " + file)
        case "go":
            return .command("go test " + dir)
        case "rs":
            return .command("cargo test")
        case "swift":
            return .command("swift test")
        default:
            return .runnerUndetected
        }
    }

    /// The directory the test session starts in: the opened `projectRoot` when
    /// there is one, else the file's own folder — the same resolution as
    /// `RunCommand.workingDirectory`, so run and test sessions agree on cwd.
    public static func workingDirectory(projectRoot: URL?, fileURL: URL) -> URL {
        RunCommand.workingDirectory(projectRoot: projectRoot, fileURL: fileURL)
    }

    // MARK: - JS/TS runner selection (first matched signal wins)

    private static func jsRunner(file: String, evidence: ProjectTestEvidence) -> TestResult {
        if hasVitest(evidence) { return .command("npx vitest run " + file) }
        if hasJest(evidence) { return .command("npx jest " + file) }
        if hasMocha(evidence) { return .command("npx mocha " + file) }
        return .runnerUndetected
    }

    private static func packageJSONContains(_ needle: String, _ e: ProjectTestEvidence) -> Bool {
        (e.manifests["package.json"] ?? "").contains(needle)
    }

    private static func hasVitest(_ e: ProjectTestEvidence) -> Bool {
        e.rootEntryNames.contains(where: { $0.hasPrefix("vitest.config.") })
            || packageJSONContains("vitest", e)
    }

    private static func hasJest(_ e: ProjectTestEvidence) -> Bool {
        e.rootEntryNames.contains(where: { $0.hasPrefix("jest.config.") })
            || packageJSONContains("jest", e)
    }

    private static func hasMocha(_ e: ProjectTestEvidence) -> Bool {
        e.rootEntryNames.contains(where: { $0.hasPrefix(".mocharc") })
            || packageJSONContains("mocha", e)
    }
}
