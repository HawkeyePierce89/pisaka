import XCTest
@testable import PisakaCore

/// `TreeGitStatus` — the project tree's per-row git lookup — and
/// `TreeGitState`'s spoken composition, one test per rule.
final class TreeGitStatusTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/pisaka-tree-status/repo")

    private func lookup(
        _ files: [ChangedFile],
        ignored: [String] = [],
        repositoryRoot: URL? = nil,
        openedFolder: URL? = nil
    ) -> TreeGitStatus {
        TreeGitStatus(
            snapshot: GitStatusSnapshot(changedFiles: files, ignoredPaths: ignored),
            repositoryRoot: repositoryRoot ?? root,
            openedFolder: openedFolder ?? root
        )
    }

    private func row(_ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    // MARK: - Change states

    func testAFileTakesItsOwnState() {
        let status = lookup([
            ChangedFile(path: "m.swift", status: .modified),
            ChangedFile(path: "a.swift", status: .added),
            ChangedFile(path: "u.swift", status: .untracked),
            ChangedFile(path: "c.swift", status: .conflicted),
        ])
        XCTAssertEqual(status.state(for: row("m.swift")), .modified)
        XCTAssertEqual(status.state(for: row("a.swift")), .added)
        XCTAssertEqual(status.state(for: row("u.swift")), .added)
        XCTAssertEqual(status.state(for: row("c.swift")), .conflict)
        XCTAssertEqual(status.state(for: row("clean.swift")), .plain)
    }

    func testARenameColoursTheNewPathAndTheOldPathContributesNothing() {
        let status = lookup([
            ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        ])
        XCTAssertEqual(status.state(for: row("new/name.swift")), .modified)
        XCTAssertEqual(status.state(for: row("new")), .modified)
        XCTAssertEqual(status.state(for: row("old/name.swift")), .plain)
        XCTAssertEqual(status.state(for: row("old")), .plain)
    }

    func testADeletionCountsForItsAncestorsAsModifiedNeverConflict() {
        let status = lookup([ChangedFile(path: "dir/sub/gone.swift", status: .deleted)])
        XCTAssertEqual(status.state(for: row("dir/sub")), .modified)
        XCTAssertEqual(status.state(for: row("dir")), .modified)
        XCTAssertEqual(status.state(for: row("")), .modified)
    }

    func testFolderAggregationIsTransitiveFromTheFlatListAlone() {
        let status = lookup([ChangedFile(path: "a/b/c/d/e.swift", status: .added)])
        for folder in ["a/b/c/d", "a/b/c", "a/b", "a", ""] {
            XCTAssertEqual(status.state(for: row(folder)), .added, folder)
        }
        XCTAssertEqual(status.state(for: row("a/b/other")), .plain)
        XCTAssertEqual(status.state(for: row("z")), .plain)
    }

    func testFolderTakesTheStrongestChangeBelowIt() {
        let mixed = lookup([
            ChangedFile(path: "src/new.swift", status: .untracked),
            ChangedFile(path: "src/edit.swift", status: .modified),
        ])
        XCTAssertEqual(mixed.state(for: row("src")), .modified)

        let untrackedOnly = lookup([ChangedFile(path: "src/new.swift", status: .untracked)])
        XCTAssertEqual(untrackedOnly.state(for: row("src")), .added)

        // Order-independent: the conflict is recorded after the weaker states
        // that already climbed to the root, and still reaches every ancestor.
        let conflict = lookup([
            ChangedFile(path: "src/edit.swift", status: .modified),
            ChangedFile(path: "src/new.swift", status: .untracked),
            ChangedFile(path: "src/deep/merge.swift", status: .conflicted),
        ])
        XCTAssertEqual(conflict.state(for: row("src/deep")), .conflict)
        XCTAssertEqual(conflict.state(for: row("src")), .conflict)
        XCTAssertEqual(conflict.state(for: row("")), .conflict)
        XCTAssertEqual(conflict.state(for: row("src/edit.swift")), .modified)
    }

    func testAWhollyUntrackedDirectoryIsAddedWithoutARecordOfItsOwn() {
        // `-uall` lists the directory's files, never the directory itself.
        let status = lookup([
            ChangedFile(path: "fresh/one.swift", status: .untracked),
            ChangedFile(path: "fresh/nested/two.swift", status: .untracked),
        ])
        XCTAssertEqual(status.state(for: row("fresh")), .added)
        XCTAssertEqual(status.state(for: row("fresh/nested")), .added)
    }

    // MARK: - Ignore

    func testIgnoreIsInheritedByAncestryAsAPrefixOfWholeComponents() {
        let status = lookup([], ignored: ["build", "notes.log"])
        XCTAssertEqual(status.state(for: row("build")), .ignored)
        XCTAssertEqual(status.state(for: row("build/out")), .ignored)
        XCTAssertEqual(status.state(for: row("build/out/app.o")), .ignored)
        XCTAssertEqual(status.state(for: row("notes.log")), .ignored)
        XCTAssertEqual(status.state(for: row("build-tools")), .plain)
        XCTAssertEqual(status.state(for: row("build-tools/run.sh")), .plain)
    }

    func testIgnoredNeverAggregatesUpward() {
        let status = lookup([], ignored: ["web/node_modules"])
        XCTAssertEqual(status.state(for: row("web/node_modules")), .ignored)
        XCTAssertEqual(status.state(for: row("web")), .plain)
        XCTAssertEqual(status.state(for: row("")), .plain)
    }

    func testATrackedChangeOutranksIgnore() {
        let status = lookup(
            [ChangedFile(path: "vendor/patched.c", status: .modified)],
            ignored: ["vendor/other.c", "vendor/lib"]
        )
        XCTAssertEqual(status.state(for: row("vendor/patched.c")), .modified)
        XCTAssertEqual(status.state(for: row("vendor")), .modified)
        XCTAssertEqual(status.state(for: row("vendor/other.c")), .ignored)
        XCTAssertEqual(status.state(for: row("vendor/lib/x.c")), .ignored)

        // A force-added file inside a wholly ignored directory shows its change,
        // and so does the ignored folder; unlisted siblings stay ignored.
        let forced = lookup(
            [ChangedFile(path: "out/keep.txt", status: .added)],
            ignored: ["out"]
        )
        XCTAssertEqual(forced.state(for: row("out/keep.txt")), .added)
        XCTAssertEqual(forced.state(for: row("out")), .added)
        XCTAssertEqual(forced.state(for: row("out/junk.bin")), .ignored)
    }

    // MARK: - Empty and spellings

    func testTheEmptyLookupAnswersPlain() {
        let empty = TreeGitStatus.empty
        XCTAssertEqual(empty.state(for: row("")), .plain)
        XCTAssertEqual(empty.state(for: row("any/thing.swift")), .plain)
        XCTAssertEqual(empty.resolve(row("any/thing.swift")).probes, 0)
        XCTAssertEqual(empty, TreeGitStatus.empty)
    }

    func testAURLOutsideEverySpellingAnswersPlain() {
        let status = lookup([ChangedFile(path: "a.swift", status: .modified)], ignored: ["a"])
        let outside = URL(fileURLWithPath: "/pisaka-tree-status/elsewhere/a.swift")
        XCTAssertEqual(status.state(for: outside), .plain)
        // A sibling sharing the root's name prefix is outside, too.
        let lookalike = URL(fileURLWithPath: "/pisaka-tree-status/repo-copy/a.swift")
        XCTAssertEqual(status.state(for: lookalike), .plain)
    }

    func testAnOpenedSubfolderResolvesKeysThroughItsPrefix() {
        let folder = root.appendingPathComponent("packages/core")
        let status = lookup(
            [
                ChangedFile(path: "packages/core/Sources/a.swift", status: .modified),
                ChangedFile(path: "packages/other/b.swift", status: .conflicted),
            ],
            ignored: ["packages/core/.build"],
            openedFolder: folder
        )
        XCTAssertEqual(status.state(for: folder), .modified)
        XCTAssertEqual(status.state(for: folder.appendingPathComponent("Sources")), .modified)
        XCTAssertEqual(status.state(for: folder.appendingPathComponent("Sources/a.swift")), .modified)
        XCTAssertEqual(status.state(for: folder.appendingPathComponent(".build/debug")), .ignored)
        XCTAssertEqual(status.state(for: folder.appendingPathComponent("README.md")), .plain)
    }

    func testARowURLIsStandardizedLexically() {
        let status = lookup([ChangedFile(path: "src/a.swift", status: .modified)])
        let dotted = URL(fileURLWithPath: root.path + "/src/./x/../a.swift")
        XCTAssertEqual(status.state(for: dotted), .modified)
        let trailingSlash = URL(fileURLWithPath: root.path + "/src/", isDirectory: true)
        XCTAssertEqual(status.state(for: trailingSlash), .modified)
    }

    func testASymlinkedSpellingOfTheOpenedFolderMatchesThroughItsCanonicalSpelling() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("TreeGitStatusTests-\(UUID().uuidString)")
        let repository = scratch.appendingPathComponent("repo")
        let package = repository.appendingPathComponent("pkg")
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let link = scratch.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: package)

        let canonicalFolder = CanonicalPath.canonical(link)
        XCTAssertNotEqual(canonicalFolder.path, link.standardizedFileURL.path)

        // git reports a fully resolved top level — realpath(3)'s spelling, which
        // keeps the `/private` Foundation's resolution strips — and the user
        // opened the link.
        let resolved = try XCTUnwrap(realpath(repository.path, nil))
        defer { free(resolved) }
        let gitRoot = URL(fileURLWithPath: String(cString: resolved))
        let status = TreeGitStatus(
            snapshot: GitStatusSnapshot(
                changedFiles: [ChangedFile(path: "pkg/a.swift", status: .modified)],
                ignoredPaths: ["pkg/out"]
            ),
            repositoryRoot: gitRoot,
            openedFolder: link
        )
        // A listing spelled under the folder's resolved spelling…
        XCTAssertEqual(status.state(for: canonicalFolder.appendingPathComponent("a.swift")), .modified)
        XCTAssertEqual(status.state(for: canonicalFolder.appendingPathComponent("out/x")), .ignored)
        // …and one spelled under the link as the user spelled it.
        XCTAssertEqual(status.state(for: link.appendingPathComponent("a.swift")), .modified)
        XCTAssertEqual(status.state(for: link), .modified)
    }

    // MARK: - Cost

    func testProbeCountIsBoundedByDepthNotByRecordCount() {
        func probes(recordCount: Int) -> [Int] {
            var files: [ChangedFile] = []
            var ignored: [String] = []
            for index in 0..<recordCount {
                files.append(ChangedFile(path: "gen/d\(index % 37)/f\(index).swift", status: .modified))
                ignored.append("cache/c\(index)")
            }
            files.append(ChangedFile(path: "hit/x.swift", status: .added))
            ignored.append("ign")
            let status = lookup(files, ignored: ignored)
            return [
                status.resolve(row("hit/x.swift")).probes,
                status.resolve(row("a/b/c/d.swift")).probes,
                status.resolve(row("ign/b/c/d.swift")).probes,
                status.resolve(row("")).probes,
            ]
        }
        let small = probes(recordCount: 10)
        let large = probes(recordCount: 10_000)
        XCTAssertEqual(small, large)
        // A change-table hit is one read; a four-deep miss is that read plus one
        // set read per level; the root row is one read.
        XCTAssertEqual(large, [1, 5, 5, 1])
        for (path, count) in zip(["hit/x.swift", "a/b/c/d.swift", "ign/b/c/d.swift", ""], large) {
            let depth = path.isEmpty ? 0 : path.split(separator: "/").count
            XCTAssertLessThanOrEqual(count, depth + 1, path)
        }
    }

    // MARK: - Spoken state

    func testSpokenNames() {
        XCTAssertEqual(TreeGitState.conflict.spokenName, "Conflicted")
        XCTAssertEqual(TreeGitState.modified.spokenName, "Modified")
        XCTAssertEqual(TreeGitState.added.spokenName, "Added")
        XCTAssertEqual(TreeGitState.ignored.spokenName, "Ignored")
        XCTAssertNil(TreeGitState.plain.spokenName)
    }

    func testAccessibilityValueForBothRowKinds() {
        XCTAssertEqual(
            TreeGitState.accessibilityValue(state: .modified, mark: .none, row: .file, isTestRow: false, isDependencyRoot: false),
            "Modified"
        )
        XCTAssertEqual(
            TreeGitState.accessibilityValue(state: .plain, mark: .none, row: .file, isTestRow: false, isDependencyRoot: false), ""
        )
        XCTAssertEqual(
            TreeGitState.accessibilityValue(
                state: .conflict, mark: .none, row: .folder(isExpanded: true), isTestRow: false, isDependencyRoot: false
            ),
            "expanded, Conflicted"
        )
        XCTAssertEqual(
            TreeGitState.accessibilityValue(
                state: .ignored, mark: .none, row: .folder(isExpanded: false), isTestRow: false, isDependencyRoot: false
            ),
            "collapsed, Ignored"
        )
        XCTAssertEqual(
            TreeGitState.accessibilityValue(
                state: .plain, mark: .none, row: .folder(isExpanded: true), isTestRow: false, isDependencyRoot: false
            ),
            "expanded"
        )
        XCTAssertEqual(
            TreeGitState.accessibilityValue(
                state: .plain, mark: .none, row: .folder(isExpanded: false), isTestRow: false, isDependencyRoot: false
            ),
            "collapsed"
        )
    }

    /// Every combination of git word, diagnostics word and neither, for both
    /// row kinds: the git word first, the diagnostics word after it, a folder's
    /// expansion word before both.
    func testAccessibilityValueComposesTheDiagnosticMark() {
        let file: [(TreeGitState, TreeDiagnosticMark, String)] = [
            (.modified, .error, "Modified, has errors"),
            (.added, .warning, "Added, has warnings"),
            (.plain, .error, "has errors"),
            (.plain, .warning, "has warnings"),
            (.conflict, .none, "Conflicted"),
            (.plain, .none, ""),
        ]
        for (state, mark, expected) in file {
            XCTAssertEqual(
                TreeGitState.accessibilityValue(state: state, mark: mark, row: .file, isTestRow: false, isDependencyRoot: false),
                expected
            )
        }
        let folder: [(TreeGitState, TreeDiagnosticMark, Bool, String)] = [
            (.modified, .error, true, "expanded, Modified, has errors"),
            (.ignored, .warning, false, "collapsed, Ignored, has warnings"),
            (.plain, .error, false, "collapsed, has errors"),
            (.plain, .warning, true, "expanded, has warnings"),
            (.added, .none, true, "expanded, Added"),
            (.plain, .none, false, "collapsed"),
        ]
        for (state, mark, isExpanded, expected) in folder {
            XCTAssertEqual(
                TreeGitState.accessibilityValue(
                    state: state, mark: mark, row: .folder(isExpanded: isExpanded), isTestRow: false, isDependencyRoot: false
                ),
                expected
            )
        }
    }

    /// Every position of the test row's `Test` word: after a folder's
    /// expansion word, before the git word and the diagnostics words, and alone
    /// on a plain, clean file.
    func testAccessibilityValueSpeaksTheTestWordInItsPlace() {
        let file: [(TreeGitState, TreeDiagnosticMark, String)] = [
            (.plain, .none, "Test"),
            (.modified, .none, "Test, Modified"),
            (.added, .error, "Test, Added, has errors"),
            (.plain, .warning, "Test, has warnings"),
        ]
        for (state, mark, expected) in file {
            XCTAssertEqual(
                TreeGitState.accessibilityValue(state: state, mark: mark, row: .file, isTestRow: true, isDependencyRoot: false),
                expected
            )
        }
        let folder: [(TreeGitState, TreeDiagnosticMark, Bool, String)] = [
            (.plain, .none, true, "expanded, Test"),
            (.plain, .none, false, "collapsed, Test"),
            (.modified, .none, true, "expanded, Test, Modified"),
            (.ignored, .none, false, "collapsed, Test, Ignored"),
            (.plain, .error, true, "expanded, Test, has errors"),
            (.conflict, .warning, false, "collapsed, Test, Conflicted, has warnings"),
        ]
        for (state, mark, isExpanded, expected) in folder {
            XCTAssertEqual(
                TreeGitState.accessibilityValue(
                    state: state, mark: mark, row: .folder(isExpanded: isExpanded), isTestRow: true,
                    isDependencyRoot: false
                ),
                expected
            )
        }
    }

    /// A row that is not a test row speaks exactly what it spoke before the
    /// word existed: the value is the non-test composition, word for word, for
    /// every state, mark and row kind.
    func testAccessibilityValueOfANonTestRowIsUnchanged() {
        let rows: [TreeGitState.RowKind] = [.file, .folder(isExpanded: true), .folder(isExpanded: false)]
        for state in TreeGitState.allCases {
            for mark in TreeDiagnosticMark.allCases {
                for row in rows {
                    let words = [state.spokenName, mark.spokenName].compactMap { $0 }
                    let expected: String
                    switch row {
                    case .file: expected = words.joined(separator: ", ")
                    case .folder(let isExpanded):
                        expected = ([isExpanded ? "expanded" : "collapsed"] + words).joined(separator: ", ")
                    }
                    let value = TreeGitState.accessibilityValue(
                        state: state, mark: mark, row: row, isTestRow: false, isDependencyRoot: false
                    )
                    XCTAssertEqual(value, expected, "\(state) \(mark) \(row)")
                    XCTAssertFalse(value.contains("Test"), "\(state) \(mark) \(row)")
                    XCTAssertFalse(value.contains("Dependencies"), "\(state) \(mark) \(row)")
                }
            }
        }
    }

    /// A dependency root folder's `Dependencies` word, alone after the
    /// expansion word on either expansion, and in its place among the others:
    /// after the expansion word, before `Test`, the git word and the
    /// diagnostics words.
    func testAccessibilityValueSpeaksTheDependenciesWordInItsPlace() {
        let alone: [(TreeGitState, TreeDiagnosticMark, Bool, String)] = [
            (.plain, .none, true, "expanded, Dependencies"),
            (.plain, .none, false, "collapsed, Dependencies"),
            (.modified, .none, true, "expanded, Dependencies, Modified"),
            (.ignored, .none, false, "collapsed, Dependencies, Ignored"),
            (.plain, .error, true, "expanded, Dependencies, has errors"),
            (.added, .warning, false, "collapsed, Dependencies, Added, has warnings"),
        ]
        let withTest: [(TreeGitState, TreeDiagnosticMark, Bool, String)] = [
            (.plain, .none, true, "expanded, Dependencies, Test"),
            (.modified, .none, true, "expanded, Dependencies, Test, Modified"),
            (.conflict, .error, false, "collapsed, Dependencies, Test, Conflicted, has errors"),
            (.modified, .warning, true, "expanded, Dependencies, Test, Modified, has warnings"),
        ]
        for (isTestRow, cases) in [(false, alone), (true, withTest)] {
            for (state, mark, isExpanded, expected) in cases {
                XCTAssertEqual(
                    TreeGitState.accessibilityValue(
                        state: state, mark: mark, row: .folder(isExpanded: isExpanded), isTestRow: isTestRow,
                        isDependencyRoot: true
                    ),
                    expected
                )
            }
        }
    }

    /// A file is never a dependency root, so `isDependencyRoot` is ignored for
    /// `.file`: passed `true`, a file speaks exactly what it speaks passed
    /// `false`, for every state, mark and test answer.
    func testAccessibilityValueOfAFileIgnoresTheDependencyRootFlag() {
        for state in TreeGitState.allCases {
            for mark in TreeDiagnosticMark.allCases {
                for isTestRow in [false, true] {
                    let flagged = TreeGitState.accessibilityValue(
                        state: state, mark: mark, row: .file, isTestRow: isTestRow, isDependencyRoot: true
                    )
                    let unflagged = TreeGitState.accessibilityValue(
                        state: state, mark: mark, row: .file, isTestRow: isTestRow, isDependencyRoot: false
                    )
                    XCTAssertEqual(flagged, unflagged, "\(state) \(mark) \(isTestRow)")
                    XCTAssertFalse(flagged.contains("Dependencies"), "\(state) \(mark) \(isTestRow)")
                }
            }
        }
    }

    func testStatusToChangeStateMappingIsTotal() {
        let expected: [FileStatus: TreeGitState] = [
            .conflicted: .conflict,
            .modified: .modified,
            .renamed: .modified,
            .deleted: .modified,
            .added: .added,
            .untracked: .added,
        ]
        XCTAssertEqual(Set(expected.keys), Set(FileStatus.allCases))
        for (status, state) in expected {
            XCTAssertEqual(TreeGitState.changeState(for: status), state, "\(status)")
        }
    }
}
