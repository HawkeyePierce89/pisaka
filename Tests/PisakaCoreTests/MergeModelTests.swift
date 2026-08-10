import XCTest
@testable import PisakaCore

@MainActor
final class MergeModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")

    // MARK: - Stubs

    private enum StubError: Error, LocalizedError {
        case boom
        var errorDescription: String? { "boom" }
    }

    /// In-memory `GitServicing`: returns canned merge-stage blobs keyed by
    /// (stage, path), records staged paths, and can throw on `blob`/`stage`.
    private final class StubGit: GitServicing {
        /// Blob contents keyed by "<stage>:<path>"; a missing key → `nil` (a
        /// missing stage, as real git reports for add/add or modify/delete).
        var blobs: [String: String] = [:]
        var blobError: Error?
        var stageError: Error?
        var stageRemovalError: Error?
        /// Paths passed to `stage`, in call order.
        var stagedPaths: [String] = []
        /// Paths passed to `stageRemoval`, in call order.
        var removedPaths: [String] = []

        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func blob(stage: Int, path: String, root: URL) async throws -> String? {
            if let blobError { throw blobError }
            return blobs["\(stage):\(path)"]
        }

        func stage(path: String, root: URL) async throws {
            if let stageError { throw stageError }
            stagedPaths.append(path)
        }

        func stageRemoval(path: String, root: URL) async throws {
            if let stageRemovalError { throw stageRemovalError }
            removedPaths.append(path)
        }
    }

    /// In-memory `FileServicing`: records writes, can throw on write.
    private final class StubFiles: FileServicing {
        var writtenByPath: [String: String] = [:]
        var writeError: Error?

        func read(url: URL) throws -> String {
            if let text = writtenByPath[url.path] { return text }
            throw CocoaError(.fileReadNoSuchFile)
        }
        func write(_ text: String, to url: URL) throws {
            if let writeError { throw writeError }
            writtenByPath[url.path] = text
        }
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func isExecutableFile(at url: URL) -> Bool { false }
    }

    private func makeModel(git: StubGit, files: StubFiles = StubFiles()) -> MergeModel {
        MergeModel(gitService: git, fileService: files)
    }

    private let conflicted = ChangedFile(path: "a.swift", status: .conflicted)

    // MARK: - load

    func testLoadBuildsDocumentFromStages() async {
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "base\n",
            "2:a.swift": "ours\n",
            "3:a.swift": "theirs\n",
        ]
        let model = makeModel(git: git)

        await model.load(file: conflicted, root: root)

        let doc = try? XCTUnwrap(model.document)
        XCTAssertEqual(doc?.conflictCount, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.file, conflicted)
        XCTAssertEqual(model.root, root)
        XCTAssertFalse(model.isFullyResolved) // starts unresolved
    }

    func testLoadWithMissingBaseStageTreatedAsEmpty() async {
        // add/add: no `:1` base, both sides add different content → one conflict
        // with an empty base span.
        let git = StubGit()
        git.blobs = [
            "2:a.swift": "ours line\n",
            "3:a.swift": "theirs line\n",
        ]
        let model = makeModel(git: git)

        await model.load(file: conflicted, root: root)

        let doc = try? XCTUnwrap(model.document)
        XCTAssertEqual(doc?.conflictCount, 1)
        if case let .conflict(hunk)? = doc?.regions.first {
            XCTAssertEqual(hunk.base, [])
            XCTAssertEqual(hunk.ours, ["ours line"])
            XCTAssertEqual(hunk.theirs, ["theirs line"])
        } else {
            XCTFail("expected a conflict region")
        }
    }

    func testLoadWithNoUnmergedStagesRefusesAndDoesNotBuildDocument() async {
        // Neither an "ours" nor a "theirs" stage exists — the file is not actually in
        // a merge conflict (e.g. a stale Local Changes snapshot). Building a document
        // would yield a zero-conflict, "fully resolved" empty document whose Apply
        // would clobber the file with "".
        let git = StubGit() // no blobs
        let model = makeModel(git: git)

        await model.load(file: conflicted, root: root)

        XCTAssertNil(model.document)
        XCTAssertFalse(model.isFullyResolved)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLoadFailureSurfacesErrorAndClearsDocument() async {
        let git = StubGit()
        git.blobError = StubError.boom
        let model = makeModel(git: git)

        await model.load(file: conflicted, root: root)

        XCTAssertNil(model.document)
        XCTAssertEqual(model.errorMessage, "boom")
    }

    // MARK: - accept

    func testAcceptUpdatesResolutionAndFullyResolved() async {
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "base\n",
            "2:a.swift": "ours\n",
            "3:a.swift": "theirs\n",
        ]
        let model = makeModel(git: git)
        await model.load(file: conflicted, root: root)

        XCTAssertFalse(model.isFullyResolved)
        model.accept(.ours, at: 0)

        XCTAssertEqual(model.document?.resolution(at: 0), .ours)
        XCTAssertTrue(model.isFullyResolved)
        XCTAssertEqual(model.unresolvedCount, 0)
    }

    func testAcceptOutOfRangeIsNoOp() async {
        let git = StubGit()
        git.blobs = ["2:a.swift": "ours\n", "3:a.swift": "theirs\n"]
        let model = makeModel(git: git)
        await model.load(file: conflicted, root: root)

        model.accept(.ours, at: 5) // out of range
        XCTAssertFalse(model.isFullyResolved)
    }

    // MARK: - apply

    func testApplyWritesResolvedTextAndStages() async {
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "base\n",
            "2:a.swift": "ours\n",
            "3:a.swift": "theirs\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.theirs, at: 0)

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "theirs\n")
        XCTAssertEqual(git.stagedPaths, ["a.swift"])
        XCTAssertNil(model.errorMessage)
    }

    func testApplyRefusedWhileUnresolved() async {
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "base\n",
            "2:a.swift": "ours\n",
            "3:a.swift": "theirs\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)

        let ok = await model.apply()

        XCTAssertFalse(ok)
        XCTAssertTrue(files.writtenByPath.isEmpty) // nothing written
        XCTAssertTrue(git.stagedPaths.isEmpty)     // nothing staged
        XCTAssertNotNil(model.errorMessage)
    }

    func testApplyWriteFailureSurfacesErrorAndDoesNotStage() async {
        let git = StubGit()
        git.blobs = ["2:a.swift": "ours\n", "3:a.swift": "theirs\n"]
        let files = StubFiles()
        files.writeError = StubError.boom
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.ours, at: 0)

        let ok = await model.apply()

        XCTAssertFalse(ok)
        XCTAssertTrue(git.stagedPaths.isEmpty) // never reached staging
        XCTAssertEqual(model.errorMessage, "boom")
    }

    func testApplyBeforeLoadReturnsFalse() async {
        let model = makeModel(git: StubGit())

        let ok = await model.apply()

        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, "No merge is loaded.")
    }

    // MARK: - trailingNewline heuristic (via resolvedText)

    func testTrailingNewlineTakenFromOurs() async {
        // No-conflict doc (all three sides identical) so it's fully resolved with
        // zero conflicts and `resolvedText` is observable. `ours` ends in "\n".
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\n", "2:a.swift": "a\n", "3:a.swift": "a\n",
        ]
        let model = makeModel(git: git)
        await model.load(file: conflicted, root: root)

        XCTAssertTrue(model.isFullyResolved) // zero conflicts
        XCTAssertEqual(model.document?.resolvedText, "a\n")
    }

    func testNoTrailingNewlineWhenOursLacksOne() async {
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a", "2:a.swift": "a", "3:a.swift": "a",
        ]
        let model = makeModel(git: git)
        await model.load(file: conflicted, root: root)

        XCTAssertEqual(model.document?.resolvedText, "a") // no trailing "\n"
    }

    func testTrailingNewlineFallsThroughToTheirsWhenOursEmpty() async {
        // `ours` is empty (skipped by the "present and non-empty" rule), so the
        // heuristic consults `theirs`, which ends in "\n". theirs-only insertion
        // auto-merges to a single stable region.
        let git = StubGit()
        git.blobs = [
            "2:a.swift": "", "3:a.swift": "b\n",
        ]
        let model = makeModel(git: git)
        await model.load(file: conflicted, root: root)

        XCTAssertTrue(model.isFullyResolved)
        XCTAssertEqual(model.document?.resolvedText, "b\n")
    }

    func testApplyModifyDeleteResolvedToDeletedSideStagesRemoval() async {
        // modify/delete: base present, "ours" deleted (no `:2`), "theirs" modified.
        // Resolving to the deleted (empty) side must stage a *removal*, not write an
        // empty file.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\nb\nc\n",
            "3:a.swift": "a\nB\nc\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.ours, at: 0) // the empty (deleted) side

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(git.removedPaths, ["a.swift"])
        XCTAssertTrue(git.stagedPaths.isEmpty)          // never staged as a file
        XCTAssertTrue(files.writtenByPath.isEmpty)      // never wrote an empty file
        XCTAssertNil(model.errorMessage)
    }

    func testApplyModifyDeleteResolvedToModifiedSideWritesNormally() async {
        // Same modify/delete conflict, but resolved to the *modified* side: a normal
        // write + stage of the kept content, not a removal.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\nb\nc\n",
            "3:a.swift": "a\nB\nc\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.theirs, at: 0) // the modified side

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "a\nB\nc\n")
        XCTAssertEqual(git.stagedPaths, ["a.swift"])
        XCTAssertTrue(git.removedPaths.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testApplyModifyDeleteCustomEmptedToEmptyWritesEmptyFile() async {
        // modify/delete, but the user edits the result down to empty via `.custom`
        // instead of selecting the deleted side. An empty `resolvedText` must NOT be
        // mistaken for a deletion: the user chose to keep an (empty) tracked file, so
        // apply writes + stages it rather than `git rm`-ing it.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\nb\nc\n",
            "3:a.swift": "a\nB\nc\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.custom(""), at: 0) // emptied by hand, not the deleted side

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "")
        XCTAssertEqual(git.stagedPaths, ["a.swift"])
        XCTAssertTrue(git.removedPaths.isEmpty) // not a deletion
    }

    func testApplyModifyDeleteWithEmptyModifiedSideWritesEmptyFile() async {
        // modify/delete where the *present* side is itself an empty blob (one branch
        // deleted the file, the other truncated it to empty). Both sides resolve to
        // empty content, so there is no conflict to choose a side for — apply must
        // keep the empty tracked file (theirs' empty blob), not infer a deletion from
        // the empty output bytes.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\nb\nc\n",
            "3:a.swift": "", // present but empty
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)

        XCTAssertTrue(model.isFullyResolved) // no conflict to resolve
        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "")
        XCTAssertEqual(git.stagedPaths, ["a.swift"])
        XCTAssertTrue(git.removedPaths.isEmpty) // not a deletion
    }

    func testApplyModifyDeleteDeletedSideIsTheirsStagesRemoval() async {
        // Mirror of the `.ours`-deleted case but with *theirs* the absent/deleted
        // side: resolving to the deleted side (`.theirs` here) stages a removal,
        // confirming the decision keys off which absent stage was selected, not a
        // fixed side.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\nb\nc\n",
            "2:a.swift": "a\nB\nc\n", // ours modified; theirs (`:3`) absent
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.theirs, at: 0) // the empty (deleted) side

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(git.removedPaths, ["a.swift"])
        XCTAssertTrue(git.stagedPaths.isEmpty)
        XCTAssertTrue(files.writtenByPath.isEmpty)
    }

    func testApplyEmptyCustomResolutionOnNonModifyDeleteWritesEmptyFile() async {
        // A genuinely-empty resolution of a modify/modify conflict (both stages
        // present) writes an empty file — the deletion path is gated on modify/delete
        // so emptying a normally-conflicted file is not mistaken for a deletion.
        let git = StubGit()
        git.blobs = [
            "1:a.swift": "a\n",
            "2:a.swift": "ours\n",
            "3:a.swift": "theirs\n",
        ]
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.custom(""), at: 0)

        let ok = await model.apply()

        XCTAssertTrue(ok)
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "")
        XCTAssertEqual(git.stagedPaths, ["a.swift"])
        XCTAssertTrue(git.removedPaths.isEmpty)
    }

    func testApplyStageFailureSurfacesError() async {
        let git = StubGit()
        git.blobs = ["2:a.swift": "ours\n", "3:a.swift": "theirs\n"]
        git.stageError = StubError.boom
        let files = StubFiles()
        let model = makeModel(git: git, files: files)
        await model.load(file: conflicted, root: root)
        model.accept(.bothOursFirst, at: 0)

        let ok = await model.apply()

        XCTAssertFalse(ok)
        // The write still happened (file is on disk) but staging failed, so the
        // model reports the failure rather than claiming success.
        XCTAssertEqual(files.writtenByPath["/repo/a.swift"], "ours\ntheirs\n")
        XCTAssertEqual(model.errorMessage, "boom")
    }
}
