import Combine
import XCTest
@testable import PisakaCore

/// `WorkspaceModel`'s external-change state: the observed-disk-side map, the
/// `checkDisk(id:)` / `syncAllWithDisk()` pass that fills it, and the guarded
/// write funnels — `save(for:onExternalChange:)` and `saveAllDirty()` — that
/// refuse to write over a change made outside the app.
///
/// `StubFileTree`'s stamps are size-derived, so "changed outside" is staged with
/// text of a different length, or with an explicit stamp override where the
/// length must stay.
final class WorkspaceModelExternalChangeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/pisaka-external-change-tests")

    private func makeTree() -> StubFileTree {
        StubFileTree(root: root, files: ["a.txt": "on disk", "b.txt": "other"])
    }

    private func file(_ model: WorkspaceModel, _ id: UUID) -> OpenFile {
        model.openFiles.first { $0.id == id }!
    }

    /// A model with `a.txt` open and edited, and the file changed outside since.
    private func makeConflict() throws -> (StubFileTree, WorkspaceModel, UUID) {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        model.updateText("my edit", for: id)
        tree.files["a.txt"] = "changed outside the app"
        return (tree, model, id)
    }

    // MARK: - checkDisk

    func testADirtyTabWhoseFileChangedIsRecordedAsAConflictWithTheStampUntouched() throws {
        let (_, model, id) = try makeConflict()
        let stamp = file(model, id).diskStamp

        XCTAssertEqual(model.checkDisk(id: id), .conflict(diskText: "changed outside the app"))

        XCTAssertTrue(model.isInExternalConflict(id))
        XCTAssertEqual(model.externalConflictIDs, [id])
        XCTAssertEqual(model.diskText(forConflict: id), "changed outside the app")
        XCTAssertEqual(file(model, id).diskStamp, stamp)
        XCTAssertEqual(file(model, id).text, "my edit")
    }

    func testAnUnreadableDiskSideIsAConflictThatComparesAsEmpty() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        model.updateText("my edit", for: id)
        tree.unreadableFiles.insert("a.txt")
        tree.stampOverrides["a.txt"] = FileStamp(byteCount: 1, modificationDate: nil)

        XCTAssertEqual(model.checkDisk(id: id), .conflict(diskText: nil))
        XCTAssertTrue(model.isInExternalConflict(id))
        XCTAssertEqual(model.diskText(forConflict: id), "")
    }

    func testACleanTabReloadsWithTheTokensPerReloadFromDisk() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        let disk = model.diskRevision(for: id)
        let replacement = model.textReplacementRevision(for: id)
        tree.files["a.txt"] = "rewritten by a tool"

        let result = model.syncAllWithDisk()

        XCTAssertEqual(result, WorkspaceModel.DiskSyncResult(reloaded: [id], conflicts: []))
        XCTAssertEqual(file(model, id).text, "rewritten by a tool")
        XCTAssertEqual(file(model, id).savedText, "rewritten by a tool")
        XCTAssertNotEqual(model.diskRevision(for: id), disk)
        XCTAssertNotEqual(model.textReplacementRevision(for: id), replacement)
        XCTAssertEqual(file(model, id).diskStamp, tree.fileStamp(at: tree.url("a.txt")))
    }

    func testABufferAlreadyEqualToTheDiskAdoptsTheBaselineWithoutReplacingTheBuffer() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        model.updateText("typed the same thing", for: id)
        tree.files["a.txt"] = "typed the same thing"
        let replacement = model.textReplacementRevision(for: id)

        XCTAssertEqual(model.checkDisk(id: id), .adoptBaseline)

        XCTAssertFalse(model.isDirty(for: id))
        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertEqual(model.textReplacementRevision(for: id), replacement)
    }

    // MARK: - The derived conflict state

    func testEditingTheBufferByHandToTheDiskTextEndsTheConflict() throws {
        let (_, model, id) = try makeConflict()
        model.checkDisk(id: id)
        XCTAssertTrue(model.isInExternalConflict(id))

        model.updateText("changed outside the app", for: id)

        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertEqual(model.externalConflictIDs, [])
        XCTAssertNil(model.diskText(forConflict: id))
    }

    /// The clean-but-stale case, pinned end to end: back at `savedText` the tab
    /// is clean but stays in conflict, autosave has nothing to write, and the next
    /// check reloads it as a clean tab and clears the entry.
    func testAConflictedTabEditedBackToSavedTextStaysInConflictUntilTheNextCheckReloadsIt() throws {
        let (tree, model, id) = try makeConflict()
        model.checkDisk(id: id)

        model.updateText("on disk", for: id)
        XCTAssertFalse(model.isDirty(for: id))
        XCTAssertTrue(model.isInExternalConflict(id))

        let batch = model.saveAllDirty()
        XCTAssertEqual(batch, WorkspaceModel.SaveBatchResult(saved: [], skippedConflicts: []))
        XCTAssertEqual(tree.files["a.txt"], "changed outside the app")
        XCTAssertTrue(tree.writtenPaths.isEmpty)
        XCTAssertTrue(model.isInExternalConflict(id))

        XCTAssertEqual(model.checkDisk(id: id), .reload)
        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertNil(model.observedDiskSides[id])
        XCTAssertEqual(file(model, id).text, "changed outside the app")
    }

    func testSaveAsToAnotherPathEndsTheConflict() throws {
        let (tree, model, id) = try makeConflict()
        model.checkDisk(id: id)

        try model.saveAs(url: tree.url("elsewhere.txt"), for: id)

        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertNil(model.observedDiskSides[id])
        XCTAssertEqual(tree.files["a.txt"], "changed outside the app")
        XCTAssertEqual(tree.files["elsewhere.txt"], "my edit")
    }

    func testCloseEndsTheConflict() throws {
        let (_, model, id) = try makeConflict()
        model.checkDisk(id: id)

        model.close(id: id, force: true)

        XCTAssertTrue(model.observedDiskSides.isEmpty)
        XCTAssertEqual(model.externalConflictIDs, [])
    }

    func testEveryBaselineSiteClearsTheEntry() throws {
        typealias Site = (WorkspaceModel, StubFileTree, UUID) throws -> Void
        let sites: [String: Site] = [
            "markSaved": { model, _, id in model.markSaved(for: id) },
            "overwrite": { model, _, id in try model.overwriteExternalChange(id) },
            "reloadFromDisk": { model, _, id in model.reloadDiscardingEdits(id) },
            "reconcileSavedBaseline": { model, _, id in model.reconcileSavedBaseline(id: id) },
        ]
        var cleared: Set<String> = []
        for (name, site) in sites {
            let (tree, model, id) = try makeConflict()
            model.checkDisk(id: id)
            XCTAssertNotNil(model.observedDiskSides[id], name)
            try site(model, tree, id)
            if model.observedDiskSides[id] == nil { cleared.insert(name) }
        }
        XCTAssertEqual(cleared, Set(sites.keys))
    }

    // MARK: - The guarded save

    func testARefusedSaveWritesNothingAndLeavesTheBaselineTheStampAndTheTokensAlone() throws {
        let (tree, model, id) = try makeConflict()
        let before = file(model, id)
        let disk = model.diskRevision(for: id)
        let replacement = model.textReplacementRevision(for: id)

        XCTAssertThrowsError(try model.save(for: id)) { error in
            XCTAssertEqual(error as? WorkspaceModel.SaveError, .externalChange)
        }

        XCTAssertTrue(tree.writtenPaths.isEmpty)
        XCTAssertEqual(tree.files["a.txt"], "changed outside the app")
        XCTAssertEqual(file(model, id).savedText, before.savedText)
        XCTAssertEqual(file(model, id).text, "my edit")
        XCTAssertEqual(file(model, id).diskStamp, before.diskStamp)
        XCTAssertEqual(model.diskRevision(for: id), disk)
        XCTAssertEqual(model.textReplacementRevision(for: id), replacement)
        XCTAssertTrue(model.isInExternalConflict(id))
    }

    func testTheOverwritePolicyWritesOverAChangedFile() throws {
        let (tree, model, id) = try makeConflict()

        XCTAssertEqual(try model.save(for: id, onExternalChange: .overwrite), .saved)

        XCTAssertEqual(tree.files["a.txt"], "my edit")
        XCTAssertFalse(model.isDirty(for: id))
        XCTAssertFalse(model.isInExternalConflict(id))
    }

    func testAMissingFileIsStillRecreatedOnSave() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        model.updateText("my edit", for: id)
        tree.files["a.txt"] = nil

        XCTAssertEqual(try model.save(for: id), .saved)

        XCTAssertEqual(tree.files["a.txt"], "my edit")
        XCTAssertFalse(model.isInExternalConflict(id))
    }

    func testAnUnchangedFileSavesAsBefore() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        model.updateText("my edit", for: id)

        XCTAssertEqual(try model.save(for: id), .saved)
        XCTAssertEqual(tree.files["a.txt"], "my edit")
    }

    // MARK: - The autosave batch

    func testTheAutosaveBatchSkipsAndReportsAConflictWhileWritingTheOthers() throws {
        let (tree, model, conflicted) = try makeConflict()
        let other = try model.open(url: tree.url("b.txt")).id
        model.updateText("other, edited", for: other)

        let batch = model.saveAllDirty()

        XCTAssertEqual(batch.saved, [tree.url("b.txt")])
        XCTAssertEqual(batch.skippedConflicts, [conflicted])
        XCTAssertEqual(tree.files["b.txt"], "other, edited")
        XCTAssertEqual(tree.files["a.txt"], "changed outside the app")
        XCTAssertTrue(model.isDirty(for: conflicted))
        XCTAssertTrue(model.isInExternalConflict(conflicted))
        XCTAssertEqual(tree.writtenPaths, ["b.txt"])
    }

    // MARK: - Publishing nothing when nothing changed

    func testAPassOverUnchangedFilesPublishesNothing() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let a = try model.open(url: tree.url("a.txt")).id
        try model.open(url: tree.url("b.txt"))
        model.updateText("edited", for: a)
        var files = 0
        var sides = 0
        let filesSink = model.$openFiles.dropFirst().sink { _ in files += 1 }
        let sidesSink = model.$observedDiskSides.dropFirst().sink { _ in sides += 1 }
        defer {
            filesSink.cancel()
            sidesSink.cancel()
        }

        XCTAssertEqual(model.syncAllWithDisk(), WorkspaceModel.DiskSyncResult(reloaded: [], conflicts: []))
        model.syncAllWithDisk()

        XCTAssertEqual(files, 0)
        XCTAssertEqual(sides, 0)
    }

    func testASecondPassOverAnAlreadyRecordedConflictPublishesNothing() throws {
        let (tree, model, id) = try makeConflict()
        try model.open(url: tree.url("b.txt"))
        XCTAssertEqual(model.syncAllWithDisk().conflicts, [id])
        var files = 0
        var sides = 0
        let filesSink = model.$openFiles.dropFirst().sink { _ in files += 1 }
        let sidesSink = model.$observedDiskSides.dropFirst().sink { _ in sides += 1 }
        defer {
            filesSink.cancel()
            sidesSink.cancel()
        }

        XCTAssertEqual(model.syncAllWithDisk(), WorkspaceModel.DiskSyncResult(reloaded: [], conflicts: [id]))

        XCTAssertEqual(files, 0)
        XCTAssertEqual(sides, 0)
        // The control: a conflict that genuinely changes does publish.
        tree.files["a.txt"] = "changed outside again, longer"
        model.syncAllWithDisk()
        XCTAssertEqual(sides, 1)
        XCTAssertEqual(files, 0)
    }
}
