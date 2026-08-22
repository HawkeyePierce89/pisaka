import XCTest
@testable import PisakaCore

/// The traversal tests, moved here verbatim in behavior when `collectFiles` and
/// `relativePath` left `ProjectSearchModel` for the shared `ProjectFileWalk`.
/// They now call the walk directly rather than through a search, so a failure
/// names the traversal rule that broke instead of the feature that noticed.
final class ProjectFileWalkTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project")

    private func walk(_ stub: StubFileTree, mask: [String] = []) -> [String] {
        ProjectFileWalk.collectFiles(root: root, maskPatterns: mask, fileService: stub)
            .map { ProjectFileWalk.relativePath(of: $0, under: root) }
    }

    // MARK: - Exclusions

    func testTraversalSkipsGitDirectoryAndHonorsNestedGitignore() {
        let stub = StubFileTree(root: root, files: [
            ".gitignore": "build/\n*.log\n",
            "a.swift": "",
            "app.log": "",
            "build/generated.swift": "",
            ".git/COMMIT_EDITMSG": "",
            "sub/.gitignore": "!keep.log\n",
            "sub/keep.log": "",
            "sub/drop.log": "",
            "sub/b.swift": "",
        ])

        // `.gitignore` itself is an ordinary, indexable/searchable file — only
        // `.git` and `.DS_Store` are the traversal's own exclusions.
        XCTAssertEqual(
            walk(stub),
            [".gitignore", "a.swift", "sub/.gitignore", "sub/b.swift", "sub/keep.log"]
        )
    }

    func testTraversalDoesNotDescendIntoSymlinkedDirectory() {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "",
            "link/looped.swift": "",
        ])
        stub.symlinks = ["link"]

        XCTAssertEqual(walk(stub), ["a.swift"])
    }

    func testTraversalSkipsSymlinkedFiles() {
        let stub = StubFileTree(root: root, files: [
            "real.swift": "",
            "link.swift": "",
        ])
        // A symlink to a *file* dereferences to `isDirectory == false`, so it is
        // indistinguishable from an ordinary entry in the listing: without the
        // explicit probe it would be searched (duplicating its target's matches)
        // and, on Replace All, overwritten with a regular file.
        stub.symlinks = ["link.swift"]

        XCTAssertEqual(walk(stub), ["real.swift"])
    }

    func testUnreadableDirectoryIsSkippedRatherThanFailingTheWalk() {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "",
            "secret/b.swift": "",
        ])
        stub.unreadableDirectories = ["secret"]

        XCTAssertEqual(walk(stub), ["a.swift"])
    }

    /// The distinction `collectFilesIfReadable` exists for: a nested directory
    /// that cannot be listed loses only its own files, but an unreadable *root*
    /// loses everything — so it must not answer the same `[]` an empty project
    /// does. `SymbolIndexModel.refresh` removes what the walk stopped producing,
    /// and cannot tell those apart on its own.
    func testUnreadableRootIsDistinguishedFromAnEmptyProject() {
        let stub = StubFileTree(root: root, files: ["a.swift": ""])
        stub.unreadableDirectories = [""]

        XCTAssertNil(
            ProjectFileWalk.collectFilesIfReadable(root: root, maskPatterns: [], fileService: stub)
        )
        XCTAssertEqual(walk(stub), [])

        let empty = StubFileTree(root: root, files: [:])
        XCTAssertEqual(
            ProjectFileWalk.collectFilesIfReadable(root: root, maskPatterns: [], fileService: empty)?
                .count,
            0
        )
    }

    /// An unreadable directory *below* the root keeps the walk succeeding — the
    /// documented "one permission-denied folder must not blank the whole result
    /// list" rule, which the root's new `nil` must not have widened.
    func testUnreadableNestedDirectoryStillYieldsAReadableWalk() {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "",
            "secret/b.swift": "",
        ])
        stub.unreadableDirectories = ["secret"]

        XCTAssertEqual(
            ProjectFileWalk.collectFilesIfReadable(root: root, maskPatterns: [], fileService: stub)?
                .map { ProjectFileWalk.relativePath(of: $0, under: root) },
            ["a.swift"]
        )
    }

    func testFilesOfADirectoryComeBeforeItsSubdirectories() {
        let stub = StubFileTree(root: root, files: [
            "sub/deep.swift": "",
            "b.swift": "",
            "a.swift": "",
        ])

        XCTAssertEqual(walk(stub), ["a.swift", "b.swift", "sub/deep.swift"])
    }

    // MARK: - Mask

    func testMaskFiltersByFileName() {
        let stub = StubFileTree(root: root, files: [
            "a.ts": "",
            "b.tsx": "",
            "c.js": "",
            "d.ts.map": "",
        ])

        XCTAssertEqual(walk(stub, mask: ["*.ts", "*.tsx"]), ["a.ts", "b.tsx"])
        XCTAssertEqual(walk(stub, mask: []).count, 4)
    }

    func testMatchesMaskTreatsNoPatternsAsEverything() {
        XCTAssertTrue(ProjectFileWalk.matchesMask(name: "anything.bin", patterns: []))
        XCTAssertTrue(ProjectFileWalk.matchesMask(name: "a.ts", patterns: ["*.ts"]))
        XCTAssertFalse(ProjectFileWalk.matchesMask(name: "a.js", patterns: ["*.ts"]))
    }

    // MARK: - Relative paths

    func testRelativePathStripsTheRoot() {
        XCTAssertEqual(
            ProjectFileWalk.relativePath(of: root.appendingPathComponent("src/a.swift"), under: root),
            "src/a.swift"
        )
        XCTAssertEqual(
            ProjectFileWalk.relativePath(
                of: root.appendingPathComponent("src/a.swift"),
                under: URL(fileURLWithPath: "/project/")
            ),
            "src/a.swift"
        )
    }

    func testRelativePathDegradesToTheFileNameOutsideTheRoot() {
        let outside = URL(fileURLWithPath: "/elsewhere/a.swift")
        XCTAssertEqual(ProjectFileWalk.relativePath(of: outside, under: root), "a.swift")
        // A sibling directory sharing the root's name prefix is *not* inside it.
        XCTAssertEqual(
            ProjectFileWalk.relativePath(of: URL(fileURLWithPath: "/projectx/a.swift"), under: root),
            "a.swift"
        )
    }

    func testRelativePathWithoutARootIsTheFileName() {
        XCTAssertEqual(
            ProjectFileWalk.relativePath(of: URL(fileURLWithPath: "/a/b/c.swift"), under: nil),
            "c.swift"
        )
    }
}
