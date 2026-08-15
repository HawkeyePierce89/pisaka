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
/// documentation to appease a test is the wrong direction entirely.
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
        XCTAssertTrue(lines[..<importIndex].contains("#if !DEBUG"), """
            `import Sparkle` must sit inside `#if !DEBUG`. Importing it unconditionally is not a \
            harmless tidy-up: see this suite's doc comment — it is the first half of arming the \
            updater in development builds, whose consent answer is then inherited by release \
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
        var stack: [String] = []
        var inDebugBranch = false
        var offenders: [String] = []
        for line in code(of: try updaterURL()) {
            if line.hasPrefix("#if ") {
                stack.append(String(line.dropFirst(4)))
            } else if line == "#else" {
                if let last = stack.last { stack[stack.count - 1] = "!(\(last))" }
            } else if line == "#endif" {
                stack.removeLast()
            }
            inDebugBranch = stack.contains("DEBUG")

            if line.contains(Self.sparkleTypePrefix) && inDebugBranch {
                offenders.append(line)
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(Self.updaterFile) references Sparkle from inside a `#if DEBUG` branch: \(offenders). \
            The DEBUG branch must construct no updater at all — that absence *is* the mechanism, \
            and there is deliberately no stub, scheme argument or defaults key behind it.
            """)
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
    /// rather than tidy.
    private func code(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [String] = []
        var inBlockComment = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlockComment = false
            }
            if let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound ..< line.endIndex) {
                    line = String(line[..<start.lowerBound]) + String(line[end.upperBound...])
                } else {
                    line = String(line[..<start.lowerBound])
                    inBlockComment = true
                }
            }
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            // Strip string literals: a documentation-shaped assertion message
            // must not satisfy or break a source-level check.
            line = line.replacingOccurrences(of: #""(\\.|[^"\\])*""#,
                                             with: #""""#,
                                             options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }
}
