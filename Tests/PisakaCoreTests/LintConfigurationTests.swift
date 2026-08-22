import XCTest
@testable import PisakaCore

/// Static verification of the two SwiftLint configuration files — the
/// documents this repository makes its style authority.
///
/// `.swiftlint.yml` (root) and `Tests/.swiftlint.yml` (the nested child whose
/// relaxations apply to the test tree only) are data, not code, so nothing in
/// `swift test` would notice them changing. This suite reads both through
/// `#filePath`, in the `ReleaseWorkflowTests` mould: Foundation only, matched
/// against comment-stripped lines through the shared `YAMLLineMatching`
/// helper, so a setting that survives only inside a comment cannot satisfy an
/// assertion about the live setting.
///
/// Pinned here because each is the exact regression this ticket exists to
/// prevent or the shape another layer depends on:
///
///  * both config files exist at all;
///  * the root declares a three-component `swiftlint_version:` — the one pin
///    the pre-commit hook and the CI lint job read their enforcement target
///    from (SwiftLint itself only warns on a mismatch);
///  * `trailing_comma` carries `mandatory_comma: true` — the deliberate flip
///    of the tool default; silently reverting to the default would turn the
///    conformance sweep into hundreds of new violations nobody asked for;
///  * the root `included:` names `Sources` and `Tests` — drop either and the
///    linter silently judges less than the whole first-party tree;
///  * the child's `disabled_rules` equals its documented five-rule set **by
///    set equality**, so quietly widening the test-tree exemptions (adding a
///    rule here is free, removing a line of lint coverage) fails the suite;
///  * every *in-file* exemption — a lint-disable comment anywhere under
///    `Sources/` or `Tests/` — equals the small documented set by path, rule
///    and count, so an exemption added silently in a source file fails here
///    instead of passing review unnoticed.
final class LintConfigurationTests: XCTestCase {
    func testBothConfigurationFilesExist() throws {
        for relativePath in [Self.rootConfigPath, Self.childConfigPath] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repositoryRoot.appendingPathComponent(relativePath).path
            ), "missing \(relativePath) — the style authority must stay committed")
        }
    }

    func testRootDeclaresAThreeComponentSwiftLintVersion() throws {
        let prefix = "swiftlint_version:"
        let line = try XCTUnwrap(
            try activeRootLines().first { $0.hasPrefix(prefix) },
            ".swiftlint.yml must declare swiftlint_version: — the pin the hook and CI enforce"
        )
        let version = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let components = version.split(separator: ".")
        XCTAssertEqual(components.count, 3,
                       "swiftlint_version must be a three-component version, got \(version)")
        XCTAssertTrue(components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
                      "swiftlint_version components must be numeric, got \(version)")
    }

    func testTrailingCommaIsMandatory() throws {
        let block = try XCTUnwrap(topLevelBlock("trailing_comma", in: try rootText()),
                                  ".swiftlint.yml has no trailing_comma block")
        XCTAssertEqual(block.filter { $0 == "mandatory_comma: true" }.count, 1,
                       """
                       trailing_comma must configure mandatory_comma: true — the deliberate \
                       opposite of the tool default. Reverting it silently reopens every \
                       collection literal in the tree.
                       """)
        XCTAssertFalse(block.contains("mandatory_comma: false"),
                       "trailing_comma.mandatory_comma must not be false")
    }

    func testRootIncludedNamesSourcesAndTests() throws {
        let included = try XCTUnwrap(topLevelBlock("included", in: try rootText()),
                                     ".swiftlint.yml has no included: block")
        let paths = Set(included.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil })
        XCTAssertEqual(paths, ["Sources", "Tests"],
                       "included: must name exactly the two first-party trees")
    }

    func testChildDisabledRulesEqualTheDocumentedSet() throws {
        let child = try XCTUnwrap(topLevelBlock("disabled_rules", in: try childText()),
                                  "Tests/.swiftlint.yml has no disabled_rules block")
        let rules = Set(child.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil })
        XCTAssertEqual(rules, Self.documentedChildExemptions,
                       """
                       Tests/.swiftlint.yml disables something other than the documented \
                       test-tree exemptions. Widen the set only by changing BOTH this file \
                       and the documented set here — an unexplained exemption is lint \
                       coverage lost.
                       """)
    }

    /// Every in-file lint exemption under `Sources/` and `Tests/`, counted by
    /// (relative path, rule), must equal this dictionary.
    ///
    /// The config files are the authority for relaxations; a disable command
    /// inside a source file is an *additional*, easily-forgotten exemption that
    /// no `.yml` diff would ever reveal — which is exactly how it slips past
    /// review. The narrowest legal form (`:next`/`:previous`/`:this`) and any
    /// file-wide disable are all caught here; each entry's reason lives beside
    /// the marker it counts. A new exemption means changing BOTH the source
    /// file and this dictionary, with the reason written down.
    func testInFileExemptionsEqualTheDocumentedSet() throws {
        // Assembled from parts so this file — which necessarily discusses the
        // command to pin its uses — never matches its own needle below.
        let marker = "// swiftlint:" + "disable"
        var counts: [String: [String: Int]] = [:]

        for tree in ["Sources", "Tests"] {
            for url in try swiftFiles(under: tree) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let relativePath = tree + String(url.path.dropFirst(
                    Self.repositoryRoot.appendingPathComponent(tree).path.count))
                for line in text.components(separatedBy: .newlines) {
                    guard let markerRange = line.range(of: marker) else { continue }
                    var remainder = String(line[markerRange.upperBound...])
                    for scope in ["next", "previous", "this"]
                    where remainder.hasPrefix(":\(scope)") {
                        remainder = String(remainder.dropFirst(scope.count + 1))
                    }
                    let rules = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .map(String.init)
                        .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0 == "_" } }
                    for rule in rules.isEmpty ? ["(every rule)"] : rules {
                        counts[relativePath, default: [:]][rule, default: 0] += 1
                    }
                }
            }
        }

        XCTAssertEqual(counts, Self.documentedInFileExemptions,
                       """
                       An in-file lint exemption appeared, moved, disappeared or changed \
                       count. In-file disables are exemptions outside the authority of the \
                       two configuration files; add or change one only by updating both the \
                       source comment (with its written reason) and documentedInFileExemptions \
                       here.
                       """)
    }

    // MARK: - Data

    private static let rootConfigPath = ".swiftlint.yml"
    private static let childConfigPath = "Tests/.swiftlint.yml"

    /// The test-tree exemptions, as `Tests/.swiftlint.yml` documents them.
    private static let documentedChildExemptions: Set<String> = [
        "force_try",
        "file_length",
        "type_body_length",
        "function_body_length",
        "nesting",
    ]

    /// The in-file exemptions, counted by (relative path, rule). Both entries
    /// are indivisible literals whose lines cannot wrap:
    ///
    ///  * `LeetCodeAPITests` — the exact GraphQL wire bodies asserted verbatim;
    ///  * `LSPProvisioningManifestTests` — pinned-artifact rows, each one
    ///    id/file/byte-count/SHA-256 tuple kept on a single line.
    private static let documentedInFileExemptions: [String: [String: Int]] = [
        "Tests/PisakaCoreTests/LeetCodeAPITests.swift": ["line_length": 2],
        "Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift": ["line_length": 7],
    ]

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func rootText() throws -> String {
        try read(Self.rootConfigPath)
    }

    private func childText() throws -> String {
        try read(Self.childConfigPath)
    }

    private func activeRootLines() throws -> [String] {
        activeYAMLLines(of: try rootText())
    }

    private func read(_ relativePath: String) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file under `tree` (relative to the repository root),
    /// sorted, descending past nothing hidden (`.build`, `.git`, …).
    private func swiftFiles(under tree: String) throws -> [URL] {
        var files: [URL] = []

        func walk(_ directory: URL) throws {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if item.lastPathComponent.hasPrefix(".") { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                else { continue }
                if isDirectory.boolValue {
                    try walk(item)
                } else if item.pathExtension == "swift" {
                    files.append(item)
                }
            }
        }

        try walk(Self.repositoryRoot.appendingPathComponent(tree))
        return files
    }
}
