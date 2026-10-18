import Combine
import XCTest
@testable import PisakaCore

/// `OpenFile.diskStamp`: the file stamp recorded at every baseline site, through
/// the same helper that bumps `diskRevisions`, plus the stamp-only refresh that
/// moves neither token and publishes nothing when the stamp did not move.
///
/// Every test runs against `StubFileTree`, whose stamps are size-derived (so a
/// write of different-length text is a new stamp) and overridable per path (so a
/// test can stage "the stamp moved, the content did not").
final class WorkspaceModelDiskStampTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/pisaka-disk-stamp-tests")

    private func makeTree() -> StubFileTree {
        StubFileTree(root: root, files: ["a.txt": "on disk", "b.txt": "other"])
    }

    /// A stamp no size-derived stamp can equal, for staging a moved stamp.
    private func stagedStamp(_ seconds: TimeInterval) -> FileStamp {
        FileStamp(byteCount: 999, modificationDate: Date(timeIntervalSince1970: seconds))
    }

    private func file(_ model: WorkspaceModel, _ id: UUID) -> OpenFile {
        model.openFiles.first { $0.id == id }!
    }

    // MARK: - The seven baseline sites

    /// Each site, run on a fresh model, must move **both** the stamp (to the
    /// disk's current one) and the disk-revision token — collected into two sets
    /// and pinned equal to the full list, so a site that moves one without the
    /// other, or neither, fails by name.
    func testEveryBaselineSiteSetsTheStampAndTheDiskRevisionTogether() throws {
        typealias Site = (WorkspaceModel, StubFileTree, UUID) throws -> UUID
        let sites: [String: Site] = [
            "open": { model, tree, _ in
                try model.open(url: tree.url("b.txt")).id
            },
            "markSaved": { model, tree, id in
                model.updateText("edited", for: id)
                tree.stampOverrides["a.txt"] = self.stagedStamp(1)
                model.markSaved(for: id)
                return id
            },
            "save": { model, _, id in
                model.updateText("edited by save", for: id)
                try model.save(for: id)
                return id
            },
            "saveAllDirty": { model, _, id in
                model.updateText("edited by autosave", for: id)
                model.saveAllDirty()
                return id
            },
            "saveAs": { model, tree, id in
                model.updateText("saved elsewhere", for: id)
                try model.saveAs(url: tree.url("c.txt"), for: id)
                return id
            },
            "reloadFromDisk": { model, tree, id in
                tree.files["a.txt"] = "changed outside"
                model.reloadFromDisk(id: id)
                return id
            },
            "reconcileSavedBaseline": { model, tree, id in
                model.updateText("kept edit", for: id)
                tree.files["a.txt"] = "changed outside"
                model.reconcileSavedBaseline(id: id)
                return id
            },
        ]

        var stampMoved: Set<String> = []
        var revisionMoved: Set<String> = []
        for (name, site) in sites {
            let tree = makeTree()
            let model = WorkspaceModel(fileService: tree)
            let opened = try model.open(url: tree.url("a.txt")).id
            // A stamp the site must replace, so "it set the stamp" is not satisfied
            // by the one `open` already left there. Planted through the stamp-only
            // refresh, the one way in that is not itself a baseline site.
            tree.stampOverrides["a.txt"] = stagedStamp(0)
            model.refreshDiskStamp(for: opened)
            tree.stampOverrides["a.txt"] = nil
            let revisionBefore = model.diskRevision(for: opened)

            let id = try site(model, tree, opened)

            let tab = file(model, id)
            let expected = tree.fileStamp(at: tab.url!)
            XCTAssertNotNil(expected, name)
            if tab.diskStamp == expected, tab.diskStamp != stagedStamp(0) { stampMoved.insert(name) }
            let before = id == opened ? revisionBefore : 0
            if model.diskRevision(for: id) != before { revisionMoved.insert(name) }
        }

        let all = Set(sites.keys)
        XCTAssertEqual(stampMoved, all, "sites that set the disk stamp")
        XCTAssertEqual(revisionMoved, all, "sites that bumped the disk revision")
    }

    func testTheStampAfterASaveIsThePostWriteOne() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        let preWrite = file(model, id).diskStamp
        XCTAssertEqual(preWrite, FileStamp(byteCount: "on disk".utf8.count, modificationDate: nil))

        model.updateText("a rather longer buffer", for: id)
        try model.save(for: id)

        XCTAssertEqual(
            file(model, id).diskStamp,
            FileStamp(byteCount: "a rather longer buffer".utf8.count, modificationDate: nil)
        )
        XCTAssertNotEqual(file(model, id).diskStamp, preWrite)
    }

    /// Another writer landing between the save's write and its stamp must not
    /// have its stamp recorded beside the editor's `savedText`: the read-back
    /// disagrees, no stamp is adopted, and the next check reads the disk — here
    /// reloading the clean tab — instead of skipping the read for good. Each of
    /// the three writing sites goes through the same post-write helper.
    func testAWriterLandingBetweenTheWriteAndTheStampIsNotHidden() throws {
        let sites: [String: (WorkspaceModel, StubFileTree, UUID) throws -> Void] = [
            "save": { model, _, id in try model.save(for: id) },
            "saveAllDirty": { model, _, _ in model.saveAllDirty() },
            "saveAs": { model, tree, id in try model.saveAs(url: tree.url("a.txt"), for: id) },
        ]
        for (name, site) in sites {
            let tree = makeTree()
            let model = WorkspaceModel(fileService: tree)
            let id = try model.open(url: tree.url(name == "saveAs" ? "b.txt" : "a.txt")).id
            model.updateText("the editor's text", for: id)
            var written = false
            tree.onWrite = { written = $0 == "a.txt" || written }
            tree.onStamp = { path in
                guard written, path == "a.txt" else { return }
                written = false
                tree.files["a.txt"] = "another writer"
            }

            try site(model, tree, id)
            tree.onStamp = nil
            XCTAssertNil(file(model, id).diskStamp, name)

            XCTAssertEqual(model.checkDisk(id: id), .reload, name)
            XCTAssertEqual(file(model, id).text, "another writer", name)
        }
    }

    func testAFailedReloadMovesNeitherTheStampNorTheToken() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        let stamp = file(model, id).diskStamp
        let revision = model.diskRevision(for: id)
        tree.unreadableFiles.insert("a.txt")
        tree.stampOverrides["a.txt"] = stagedStamp(5)

        XCTAssertFalse(model.reloadFromDisk(id: id))

        XCTAssertEqual(file(model, id).diskStamp, stamp)
        XCTAssertEqual(model.diskRevision(for: id), revision)
    }

    func testReconcilingAgainstADeletedFileRecordsNoStamp() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        tree.files["a.txt"] = nil

        XCTAssertTrue(model.reconcileSavedBaseline(id: id))

        XCTAssertNil(file(model, id).diskStamp)
    }

    // MARK: - Tabs that carry no stamp

    func testUntitledAndViewerTabsCarryNoStamp() throws {
        let tree = StubFileTree(root: root, files: ["app.sqlite": "SQLite format 3"])
        let model = WorkspaceModel(fileService: tree, viewerTabsEnabled: true)
        let untitled = model.newFile()
        model.updateText("typed", for: untitled.id)
        model.markSaved(for: untitled.id)
        let viewer = try model.open(url: tree.url("app.sqlite"))

        XCTAssertNil(file(model, untitled.id).diskStamp)
        XCTAssertNil(file(model, viewer.id).diskStamp)
        XCTAssertNil(OpenFile(viewerFor: tree.url("app.sqlite")).diskStamp)
        XCTAssertFalse(model.refreshDiskStamp(for: untitled.id))
        XCTAssertFalse(model.refreshDiskStamp(for: viewer.id))
    }

    // MARK: - Stamp-only refresh

    func testAStampOnlyRefreshMovesNeitherToken() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        let disk = model.diskRevision(for: id)
        let replacement = model.textReplacementRevision(for: id)
        tree.stampOverrides["a.txt"] = stagedStamp(7)

        XCTAssertTrue(model.refreshDiskStamp(for: id))

        XCTAssertEqual(file(model, id).diskStamp, stagedStamp(7))
        XCTAssertEqual(model.diskRevision(for: id), disk)
        XCTAssertEqual(model.textReplacementRevision(for: id), replacement)
        XCTAssertEqual(file(model, id).text, "on disk")
        XCTAssertEqual(file(model, id).savedText, "on disk")
    }

    func testAStampOnlyRefreshWithAnEqualStampPublishesNothing() throws {
        let tree = makeTree()
        let model = WorkspaceModel(fileService: tree)
        let id = try model.open(url: tree.url("a.txt")).id
        var publications = 0
        let subscription = model.$openFiles.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        XCTAssertFalse(model.refreshDiskStamp(for: id))
        XCTAssertFalse(model.refreshDiskStamp(for: id))

        XCTAssertEqual(publications, 0)

        // The control: a moved stamp does publish, so the zero above is the
        // comparison at work and not a subscription that never fires.
        tree.stampOverrides["a.txt"] = stagedStamp(8)
        XCTAssertTrue(model.refreshDiskStamp(for: id))
        XCTAssertEqual(publications, 1)
    }
}
