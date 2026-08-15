import XCTest

/// Static verification that the Sparkle updater is confined to one macOS-gated
/// file and compiled out of DEBUG builds.
///
/// A repository-file suite in the `LSPSourceGatingTests` mould: it reads
/// `Sources/` through `#filePath` with Foundation only, so it runs in
/// `swift test` without an Xcode build — which is the whole point here, because
/// `swift test` compiles `PisakaCore` alone and no gate in this repository can
/// otherwise see either rule.
///
/// **Why the compiler cannot catch this.** `SoftwareUpdater.swift` documents the
/// DEBUG rule as a hard requirement: under `#if DEBUG` no
/// `SPUStandardUpdaterController` is constructed, the framework is not even
/// imported, nothing fetches the feed and Sparkle's first-launch "check
/// automatically?" consent prompt never appears. Removing the `#if !DEBUG`
/// around `import Sparkle`, or lifting the controller out of the `#else` branch,
/// **compiles cleanly in both configurations** — so nothing fails, and the
/// damage is quiet and persistent: a development build raises Sparkle's consent
/// prompt against a feed that may carry no releases yet, and the *answer* is
/// persisted per bundle identifier, so a later release build inherits whatever a
/// developer clicked. The second rule is the ordinary platform one — Sparkle is
/// the one dependency carrying `destinationFilters: [macOS]`, so an `import
/// Sparkle` that escaped `#if os(macOS)` would break the iOS build with an error
/// naming something several layers from the mistake.
///
/// **Comments and string literals are stripped before anything is matched**, for
/// the reason `LSPSourceGatingTests` states: `SoftwareUpdater.swift`'s own
/// documentation discusses `SPUStandardUpdaterController` and `SPUUpdater` at
/// length, `PisakaApp.swift` names the framework in prose, and rewording
/// documentation to appease a test is the wrong direction entirely. That suite's
/// `strippingCommentsAndStringLiterals` is reused rather than reimplemented: it
/// is a single-pass state machine that understands nested block comments and
/// multi-line literals, and it carries its own self-test. The line-at-a-time
/// version this file grew first stripped `//` *before* literals, so any line
/// carrying a URL — of which `Sources/Pisaka` has many — was truncated at the
/// `//` inside the string and everything after it became invisible to a sweep
/// whose only value is being exhaustive.
final class SparkleSourceGatingTests: XCTestCase {
    /// The one file allowed to touch Sparkle.
    private static let updaterFile = "SoftwareUpdater.swift"

    /// Sparkle's public class prefix. Everything the app could reach for —
    /// `SPUStandardUpdaterController`, `SPUUpdater`, `SPUUserDriver` — carries it.
    private static let sparkleTypePrefix = "SPU"

    /// `import Sparkle` appears in exactly one file, and inside both gates.
    func testSparkleIsImportedOnlyByTheUpdaterAndOnlyOutsideDEBUG() throws {
        let importers = try appSourceFiles()
            .filter { code(of: $0).contains { $0 == "import Sparkle" } }
            .map { $0.lastPathComponent }
            .sorted()

        XCTAssertEqual(importers, [Self.updaterFile], """
            `import Sparkle` belongs in \(Self.updaterFile) and nowhere else — it is the app's \
            entire Sparkle surface, and the only file the macOS/DEBUG gating is written in. \
            Found it in: \(importers).
            """)

        let lines = code(of: try updaterURL())
        XCTAssertEqual(lines.first, "#if os(macOS)", """
            \(Self.updaterFile) must open with `#if os(macOS)`. Sparkle's manifest is macOS-only \
            and it is the one dependency carrying `destinationFilters: [macOS]`, so anything here \
            that reaches the iOS compile breaks that build.
            """)

        let importIndex = try XCTUnwrap(lines.firstIndex(of: "import Sparkle"),
                                        "\(Self.updaterFile) no longer imports Sparkle")
        // The *live* directive stack at the import, not "`#if !DEBUG` appears
        // somewhere earlier in the file": a closed `#if !DEBUG` … `#endif` block
        // followed by a bare `import Sparkle` would satisfy the weaker reading
        // while importing the framework unconditionally, which is precisely the
        // change this asserts against.
        let stacks = try conditionStacks(of: lines)
        XCTAssertTrue(stacks[importIndex].contains(.notDebug), """
            `import Sparkle` must sit inside a live `#if !DEBUG`. Importing it unconditionally is \
            not a harmless tidy-up: see this suite's doc comment — it is the first half of arming \
            the updater in development builds, whose consent answer is then inherited by release \
            builds through the shared bundle identifier.
            """)
    }

    /// Every `SPU…` reference lives in the `#else` (non-DEBUG) branch.
    ///
    /// The import gate alone is not enough: a controller constructed in the
    /// shared part of the file would fail to *compile* in DEBUG, but one moved
    /// into the `#if DEBUG` branch beside it would compile and quietly start the
    /// updater in development builds — which is the failure being prevented.
    func testSparkleTypesAreReferencedOnlyInTheNonDEBUGBranch() throws {
        let all = try appSourceFiles()
        let referencing = all
            .filter { code(of: $0).contains { $0.contains(Self.sparkleTypePrefix) } }
            .map { $0.lastPathComponent }
            .sorted()
        XCTAssertEqual(referencing, [Self.updaterFile], """
            Sparkle's `\(Self.sparkleTypePrefix)…` types must not be referenced outside \
            \(Self.updaterFile). The updater deliberately republishes one `Bool` rather than \
            exposing the updater object, so nothing else in the app needs Sparkle's types. Found \
            references in: \(referencing).
            """)

        // Walk the file's conditional-compilation nesting and record the branch
        // each `SPU…` reference is in.
        let lines = code(of: try updaterURL())
        let stacks = try conditionStacks(of: lines)
        let offenders = zip(lines, stacks)
            .filter { $0.0.contains(Self.sparkleTypePrefix) && $0.1.contains(.debug) }
            .map(\.0)

        XCTAssertTrue(offenders.isEmpty, """
            \(Self.updaterFile) references Sparkle from inside a `#if DEBUG` branch: \(offenders). \
            The DEBUG branch must construct no updater at all — that absence *is* the mechanism, \
            and there is deliberately no stub, scheme argument or defaults key behind it.
            """)
    }

    /// The updater is the only thing outside the iOS layer with a DEBUG-only
    /// branch — the precondition CI's macOS job now rests on.
    ///
    /// `.github/workflows/ci.yml` *switched* its macOS job from Debug to Release
    /// rather than adding a second one, so that the `#if !DEBUG` updater is
    /// compiled on every PR instead of first appearing inside the release
    /// archive. The cost is stated in that file's own comment: macOS-gated code
    /// under `#if DEBUG` is now built by **no** CI job at all — the iOS job cannot
    /// stand in, because every macOS file is inside `#if os(macOS)` and the iOS
    /// compile never reaches it. That trade is acceptable "only because there is
    /// exactly one such block outside `Sources/Pisaka/iOS/` and it is the
    /// updater's two no-op declarations", and nothing enforced that sentence.
    ///
    /// So the moment a `#if DEBUG` block with real content appears in any other
    /// macOS file, it ships compiled by nobody and breaks on a developer's machine
    /// — with the stated precondition silently false. This is the rule failing;
    /// the fix is a third, macOS-Debug CI job, not a wider allow-list here.
    ///
    /// A `#else` closing a `#if !DEBUG` counts, exactly as `#if DEBUG` does: the
    /// walker models branches rather than condition text for that reason, and the
    /// updater itself is the proof the two shapes are interchangeable.
    func testDEBUGOnlyBranchesOutsideTheIOSLayerAreConfinedToTheUpdater() throws {
        let candidates = try appSourceFiles().filter {
            !$0.pathComponents.contains("iOS")
        }
        XCTAssertFalse(candidates.isEmpty, "found no Swift files outside Sources/Pisaka/iOS")

        var withDebugBranches: [String] = []
        for url in candidates {
            let lines = code(of: url)
            let stacks = try conditionStacks(of: lines, in: url.lastPathComponent)
            if stacks.contains(where: { $0.contains(.debug) }) {
                withDebugBranches.append(url.lastPathComponent)
            }
        }

        XCTAssertEqual(withDebugBranches.sorted(), [Self.updaterFile], """
            \(Self.updaterFile) must be the only file outside Sources/Pisaka/iOS with a DEBUG-only \
            branch. Found: \(withDebugBranches.sorted()). See this test's doc comment — CI builds \
            macOS in Release only, so a `#if DEBUG` branch here is compiled by no CI job at all. \
            If the new block is real code rather than a no-op, ci.yml needs a third, macOS-Debug \
            job before it can be trusted.
            """)
    }

    // MARK: - Conditional-compilation nesting

    /// What one `#if` condition says about `DEBUG`.
    ///
    /// Modelling this as three cases rather than matching the condition *text*
    /// is the fix for a real hole: the first version of this walker pushed
    /// `"!DEBUG"` and rewrote its `#else` to `"!(!DEBUG)"`, then asked whether
    /// the stack contained the literal `"DEBUG"` — so the most natural
    /// restructuring of `SoftwareUpdater.swift` (collapsing its two `#if`s into
    /// one `#if !DEBUG` / `#else`) moved the DEBUG branch somewhere the walker
    /// could no longer see, and an `SPU…` reference placed there would compile in
    /// both configurations and ship an armed updater in development builds.
    enum DebugCondition: Equatable {
        /// Compiled only when `DEBUG` is defined.
        case debug
        /// Compiled only when it is not.
        case notDebug
        /// Says nothing about `DEBUG` (`os(macOS)`, and everything else).
        case unrelated

        var negated: DebugCondition {
            switch self {
            case .debug: return .notDebug
            case .notDebug: return .debug
            case .unrelated: return .unrelated
            }
        }

        /// Strict on purpose. Anything mentioning `DEBUG` that is not exactly
        /// `!DEBUG` counts as a DEBUG branch, so a compound condition
        /// (`#if DEBUG && FOO`) is *flagged* rather than waved through — the
        /// right direction for a check whose failure asks a human to look.
        init(condition: String) {
            let normalized = condition
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            guard normalized.contains("DEBUG") else { self = .unrelated; return }
            self = normalized == "!DEBUG" ? .notDebug : .debug
        }
    }

    /// The directive stack in force at each line, parallel to `lines`.
    ///
    /// `#endif` pops defensively rather than with a bare `removeLast()`: an
    /// unbalanced file would otherwise trap and take the whole test process down,
    /// turning "one rule is violated" into "no rule was checked". The balance is
    /// asserted instead, as its own failure.
    private func conditionStacks(of lines: [String],
                                 in fileName: String = SparkleSourceGatingTests.updaterFile,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> [[DebugCondition]] {
        var stack: [DebugCondition] = []
        var stacks: [[DebugCondition]] = []
        var unbalanced = false

        for entry in lines {
            if entry.hasPrefix("#if ") {
                stack.append(DebugCondition(condition: String(entry.dropFirst(4))))
            } else if entry.hasPrefix("#elseif ") {
                if stack.isEmpty { unbalanced = true }
                else { stack[stack.count - 1] = DebugCondition(condition: String(entry.dropFirst(8))) }
            } else if entry == "#else" {
                if stack.isEmpty { unbalanced = true }
                else { stack[stack.count - 1] = stack[stack.count - 1].negated }
            } else if entry == "#endif" {
                if stack.isEmpty { unbalanced = true } else { stack.removeLast() }
            }
            stacks.append(stack)
        }

        XCTAssertFalse(unbalanced || !stack.isEmpty, """
            \(fileName)'s conditional-compilation directives do not balance, so this \
            suite cannot tell which branch anything is in. Fix the file — or, if the directives \
            are fine, this walker no longer understands the shape they are written in.
            """, file: file, line: line)
        return stacks
    }

    // MARK: - Reading the app sources

    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>
        .appendingPathComponent("Sources/Pisaka")

    private func updaterURL() throws -> URL {
        let url = Self.appSources.appendingPathComponent(Self.updaterFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), """
            Sources/Pisaka/\(Self.updaterFile) is gone. If the updater was renamed, rename it here \
            too — a sweep that silently finds nothing is a passing suite that checks nothing.
            """)
        return url
    }

    private func appSourceFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.appSources,
                                           includingPropertiesForKeys: nil),
            "cannot enumerate Sources/Pisaka")
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no Swift files under Sources/Pisaka")
        return files
    }

    /// A file's code: comments and string literals stripped, blank lines
    /// dropped, each line trimmed. See the type doc for why this is mandatory
    /// rather than tidy, and why the stripping itself is `LSPSourceGatingTests`'
    /// state machine rather than a second line-at-a-time one.
    private func code(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return LSPSourceGatingTests.strippingCommentsAndStringLiterals(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
