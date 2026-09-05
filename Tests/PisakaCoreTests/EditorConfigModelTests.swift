import XCTest
@testable import PisakaCore

/// Tests for the cache the editor's key handlers ask, and for the two points
/// that throw it away.
///
/// The read log is the instrument throughout: what "served from cache" means is
/// precisely that no second read reached the file service, and what an
/// invalidation means is that one did.
@MainActor
final class EditorConfigModelTests: XCTestCase {

    // MARK: - Helpers

    private func tree(_ files: [String: String], root: String = "/project") -> StubFileTree {
        StubFileTree(root: URL(fileURLWithPath: root), files: files)
    }

    private func model(_ tree: StubFileTree, root: URL?) -> EditorConfigModel {
        EditorConfigModel(fileService: tree, projectRoot: root)
    }

    // MARK: - Answering

    func testAResolvedAnswerIsServedFromCacheWithoutASecondRead() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)

        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        XCTAssertEqual(tree.readPaths, [".editorconfig"])

        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        XCTAssertEqual(tree.readPaths, [".editorconfig"], "the second answer must come from the cache")
    }

    func testAnEmptyAnswerIsCachedToo() {
        // A project with no `.editorconfig` at all is the common case; it may not
        // re-walk the hierarchy on every Enter just because it found nothing.
        let tree = tree(["src/a.swift": ""])
        let model = model(tree, root: tree.root)

        XCTAssertTrue(model.properties(for: tree.url("src/a.swift")).isEmpty)
        let firstPass = tree.readPaths
        XCTAssertTrue(model.properties(for: tree.url("src/a.swift")).isEmpty)
        XCTAssertEqual(tree.readPaths, firstPass)
    }

    func testDifferentFilesUnderOneRootEachResolveAndAreEachCached() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/.editorconfig": "[*]\nindent_size = 8\n",
            "a.swift": "",
            "src/b.swift": "",
        ])
        let model = model(tree, root: tree.root)

        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        XCTAssertEqual(model.properties(for: tree.url("src/b.swift")).indentWidth, 8)
        let afterBoth = tree.readPaths
        // Neither answer displaced the other.
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        XCTAssertEqual(model.properties(for: tree.url("src/b.swift")).indentWidth, 8)
        XCTAssertEqual(tree.readPaths, afterBoth)
    }

    func testANilURLAnswersEmpty() {
        let tree = tree([".editorconfig": "[*]\nindent_style = space\n"])
        let model = model(tree, root: tree.root)

        XCTAssertTrue(model.properties(for: nil).isEmpty)
        XCTAssertTrue(tree.readPaths.isEmpty)
    }

    func testANilRootAnswersEmpty() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: nil)

        XCTAssertTrue(model.properties(for: tree.url("a.swift")).isEmpty)
        XCTAssertTrue(tree.readPaths.isEmpty, "no root means there is nothing to walk")
    }

    func testTheModelNeverWrites() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)

        _ = model.properties(for: tree.url("a.swift"))
        model.noteProjectFilesChanged()
        _ = model.properties(for: tree.url("a.swift"))
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    // MARK: - Invalidation

    func testAnEditedConfigIsPickedUpAfterProjectFilesChanged() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)

        tree.files[".editorconfig"] = "[*]\nindent_style = space\nindent_size = 8\n"
        // Without the notification the cached answer stands — the model has no
        // way to know, which is exactly why the app calls this.
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)

        model.noteProjectFilesChanged()
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 8)
    }

    func testARootSwitchClearsEntriesFromThePreviousProject() {
        // The same file url, twice, under two different roots: the outer config
        // applies under the outer root and is above the inner one, so a cache
        // that survived the switch would answer with the previous project's
        // config.
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        XCTAssertEqual(model.properties(for: tree.url("src/a.swift")).indentWidth, 2)

        model.noteProjectRoot(tree.url("src"))
        XCTAssertTrue(
            model.properties(for: tree.url("src/a.swift")).isEmpty,
            "a config above the new root is neither read nor remembered"
        )
    }

    func testSwitchingToANilRootClearsTheCache() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)

        model.noteProjectRoot(nil)
        XCTAssertNil(model.projectRoot)
        XCTAssertTrue(model.properties(for: tree.url("a.swift")).isEmpty)
    }

    func testSwitchingBackToARootResolvesAgainstItAgain() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: nil)
        XCTAssertTrue(model.properties(for: tree.url("a.swift")).isEmpty)

        model.noteProjectRoot(tree.root)
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
    }

    func testTheSameRootAgainKeepsTheCache() {
        // SwiftUI re-assigns state freely; an idle re-assignment of the folder
        // already open may not throw the cache away.
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        let afterFirst = tree.readPaths

        model.noteProjectRoot(tree.root.appendingPathComponent("."))
        XCTAssertEqual(model.properties(for: tree.url("a.swift")).indentWidth, 2)
        XCTAssertEqual(tree.readPaths, afterFirst, "a re-spelling of the same folder is not a switch")
    }

    // MARK: - The revision

    /// The integer a reader caching something *derived* from an answer compares
    /// to notice its copy is stale — the editor's indentation widths are that
    /// reader. It has to move on both wholesale invalidations, because either
    /// one can change what a file resolves to.
    func testBothInvalidationsBumpTheRevision() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        let atStart = model.revision

        model.noteProjectFilesChanged()
        let afterFilesChanged = model.revision
        XCTAssertGreaterThan(afterFilesChanged, atStart, "a file change must be visible to a derived reader")

        model.noteProjectRoot(tree.url("src"))
        XCTAssertGreaterThan(model.revision, afterFilesChanged, "so must a folder switch")
    }

    /// Monotonic, and bumped once per invalidation: a reader compares it to the
    /// last one it saw, so a counter that ever went backwards — or stood still
    /// across a second invalidation — would hide a change.
    func testTheRevisionOnlyEverRises() {
        let tree = tree(["a.swift": ""])
        let model = model(tree, root: tree.root)

        var seen = [model.revision]
        for _ in 0..<3 {
            model.noteProjectFilesChanged()
            seen.append(model.revision)
        }
        XCTAssertEqual(seen, Array(seen[0]...seen[0] + 3), "one bump per invalidation, in order")
    }

    /// The cache's own no-op rule, read through the revision: an idle
    /// re-assignment of the folder already open keeps the cache, so it must not
    /// tell a derived reader that its answer expired either — otherwise every
    /// SwiftUI re-render would cost the editor a whole-buffer re-inference.
    func testASameRootReAssignmentDoesNotBumpTheRevision() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let model = model(tree, root: tree.root)
        let before = model.revision

        model.noteProjectRoot(tree.root)
        model.noteProjectRoot(tree.root.appendingPathComponent("."))
        XCTAssertEqual(model.revision, before)
    }
}
