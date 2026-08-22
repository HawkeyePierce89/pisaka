import XCTest
@testable import PisakaCore

final class WorkspaceModelTests: XCTestCase {
    func testNewFileCreatesUntitledAndSelectsIt() {
        let model = WorkspaceModel()
        let file = model.newFile()

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.openFiles.first?.id, file.id)
        XCTAssertEqual(model.selectedID, file.id)
        XCTAssertEqual(file.displayName, "Untitled")
        XCTAssertNil(file.url)
        XCTAssertFalse(file.isDirty)
    }

    func testOpenReadsContentsAndAddsTab() throws {
        let url = try writeTempFile(contents: "hello world")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.selectedID, file.id)
        XCTAssertEqual(file.text, "hello world")
        XCTAssertEqual(file.displayName, url.lastPathComponent)
        XCTAssertFalse(file.isDirty)
    }

    func testUpdateTextSetsIsDirty() {
        let model = WorkspaceModel()
        let file = model.newFile()

        model.updateText("edited", for: file.id)

        let updated = model.openFiles.first
        XCTAssertEqual(updated?.text, "edited")
        XCTAssertTrue(updated?.isDirty == true)
    }

    func testMarkSavedClearsIsDirty() {
        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("edited", for: file.id)

        model.markSaved(for: file.id)

        let saved = model.openFiles.first
        XCTAssertFalse(saved?.isDirty == true)
        XCTAssertEqual(saved?.savedText, "edited")
    }

    func testTextForReturnsCurrentBufferAndTracksEdits() {
        let model = WorkspaceModel()
        let file = model.newFile()
        XCTAssertEqual(model.text(for: file.id), "")

        model.updateText("typed", for: file.id)

        // Reflects the live buffer, so a snapshot taken earlier can detect that
        // the user edited the file in between.
        XCTAssertEqual(model.text(for: file.id), "typed")
    }

    func testTextForUnknownIDIsNil() {
        let model = WorkspaceModel()
        model.newFile()

        XCTAssertNil(model.text(for: UUID()))
    }

    func testIsDirtyTracksUnsavedEdits() {
        let model = WorkspaceModel()
        let file = model.newFile()
        XCTAssertFalse(model.isDirty(for: file.id)) // fresh buffer is clean

        model.updateText("typed", for: file.id)
        XCTAssertTrue(model.isDirty(for: file.id)) // unsaved edit

        model.markSaved(for: file.id)
        XCTAssertFalse(model.isDirty(for: file.id)) // saved → clean again
    }

    func testIsDirtyForUnknownIDIsFalse() {
        let model = WorkspaceModel()
        model.newFile()

        XCTAssertFalse(model.isDirty(for: UUID()))
    }

    func testUpdateTextWithUnknownIDIsNoOp() {
        let model = WorkspaceModel()
        model.newFile()

        model.updateText("ghost", for: UUID())

        XCTAssertEqual(model.openFiles.first?.text, "")
    }

    func testOpeningAlreadyOpenFileSelectsExistingTab() throws {
        let url = try writeTempFile(contents: "shared")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let first = try model.open(url: url)
        // Edit the open buffer so a re-open must not discard the in-flight work.
        model.updateText("edited but unsaved", for: first.id)

        let second = model.newFile() // select something else first
        model.select(second.id)

        let reopened = try model.open(url: url)

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(model.openFiles.filter { $0.url == url }.count, 1)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.selectedFile?.text, "edited but unsaved")
    }

    func testOpeningSameFileViaEquivalentPathSelectsExistingTab() throws {
        let url = try writeTempFile(contents: "shared")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let first = try model.open(url: url)

        // Reach the same file via an unstandardized path (extra "." component).
        let dir = url.deletingLastPathComponent()
        let unstandardized = dir.appendingPathComponent(".")
            .appendingPathComponent(url.lastPathComponent)

        let reopened = try model.open(url: unstandardized)

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.selectedID, first.id)
    }

    func testOpenPropagatesReadErrorAndLeavesWorkspaceUnchanged() {
        let model = WorkspaceModel(fileService: StubFileService(readError: StubError.boom))

        XCTAssertThrowsError(try model.open(url: URL(fileURLWithPath: "/no/such/file")))
        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testOpenPreservesInsertionOrder() throws {
        let urlA = try writeTempFile(contents: "a")
        let urlB = try writeTempFile(contents: "b")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let model = WorkspaceModel()
        let first = try model.open(url: urlA)
        let second = try model.open(url: urlB)

        XCTAssertEqual(model.openFiles.map(\.id), [first.id, second.id])
    }

    func testSelectChangesSelectedFile() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()

        XCTAssertEqual(model.selectedFile?.id, second.id)

        model.select(first.id)

        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.selectedFile?.id, first.id)
    }

    func testSelectWithUnknownIDIsNoOp() {
        let model = WorkspaceModel()
        let file = model.newFile()

        model.select(UUID())

        XCTAssertEqual(model.selectedID, file.id)
        XCTAssertEqual(model.selectedFile?.id, file.id)
    }

    func testSelectedFileIsNilWhenNoneOpen() {
        let model = WorkspaceModel()
        XCTAssertNil(model.selectedFile)
    }

    func testNewFilePreservesInsertionOrder() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()
        let third = model.newFile()

        XCTAssertEqual(model.openFiles.map(\.id), [first.id, second.id, third.id])
    }

    func testSelectedFileReflectsDirtyIndicator() {
        let model = WorkspaceModel()
        let file = model.newFile()

        XCTAssertFalse(model.selectedFile?.isDirty == true)

        model.updateText("changed", for: file.id)

        XCTAssertTrue(model.selectedFile?.isDirty == true)

        model.markSaved(for: file.id)

        XCTAssertFalse(model.selectedFile?.isDirty == true)
    }

    func testEditingSelectedFileSetsDirtyIndicator() {
        let model = WorkspaceModel()
        model.newFile()

        XCTAssertFalse(model.selectedFile?.isDirty == true)

        // Simulates the editor writing back through the per-file binding.
        model.updateText("typed in the editor", for: model.selectedID!)

        XCTAssertEqual(model.selectedFile?.text, "typed in the editor")
        XCTAssertTrue(model.selectedFile?.isDirty == true)
    }

    func testSwitchingFilesPreservesIndependentText() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()

        model.select(first.id)
        model.updateText("contents of first", for: first.id)

        model.select(second.id)
        XCTAssertEqual(model.selectedFile?.text, "")
        model.updateText("contents of second", for: second.id)

        // Switching back must restore the first file's own text untouched.
        model.select(first.id)
        XCTAssertEqual(model.selectedFile?.id, first.id)
        XCTAssertEqual(model.selectedFile?.text, "contents of first")

        model.select(second.id)
        XCTAssertEqual(model.selectedFile?.text, "contents of second")
    }

    // MARK: - Save / Save As

    func testSaveExistingFileWritesToDiskAndClearsDirty() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("edited contents", for: file.id)
        XCTAssertTrue(model.selectedFile?.isDirty == true)

        let result = try model.save(for: file.id)

        XCTAssertEqual(result, .saved)
        XCTAssertFalse(model.selectedFile?.isDirty == true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "edited contents")
    }

    func testSaveUntitledRequiresSaveAs() throws {
        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("draft", for: file.id)

        let result = try model.save(for: file.id)

        XCTAssertEqual(result, .needsSaveAs)
        // No url assigned and still dirty: nothing was written.
        XCTAssertNil(model.selectedFile?.url)
        XCTAssertTrue(model.selectedFile?.isDirty == true)
    }

    func testSaveAsAssignsUrlAndNameAndClearsDirty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("saved via panel", for: file.id)

        try model.saveAs(url: url, for: file.id)

        let saved = model.openFiles.first
        XCTAssertEqual(saved?.url, url)
        XCTAssertEqual(saved?.displayName, url.lastPathComponent)
        XCTAssertFalse(saved?.isDirty == true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "saved via panel")
    }

    func testSaveWithUnknownIDReturnsNeedsSaveAs() throws {
        let model = WorkspaceModel()
        let result = try model.save(for: UUID())
        XCTAssertEqual(result, .needsSaveAs)
    }

    func testSaveWriteFailureKeepsFileDirty() throws {
        let model = WorkspaceModel(
            fileService: StubFileService(readResult: "on disk", writeError: StubError.boom)
        )
        let file = try model.open(url: URL(fileURLWithPath: "/some/file.txt"))
        model.updateText("unsaved edit", for: file.id)

        XCTAssertThrowsError(try model.save(for: file.id))
        // A failed write must not advance savedText / clear the dirty flag.
        XCTAssertTrue(model.selectedFile?.isDirty == true)
        XCTAssertEqual(model.openFiles.first?.savedText, "on disk")
    }

    func testSaveAsWriteFailureKeepsFileDirtyAndUnassigned() {
        let model = WorkspaceModel(fileService: StubFileService(writeError: StubError.boom))
        let file = model.newFile()
        model.updateText("draft", for: file.id)

        XCTAssertThrowsError(
            try model.saveAs(url: URL(fileURLWithPath: "/some/file.txt"), for: file.id)
        )
        // The url is assigned only after a successful write.
        XCTAssertNil(model.openFiles.first?.url)
        XCTAssertTrue(model.selectedFile?.isDirty == true)
    }

    func testSaveAsOntoAnotherOpenTabsPathIsRejected() throws {
        let urlA = try writeTempFile(contents: "file A on disk")
        defer { try? FileManager.default.removeItem(at: urlA) }

        let model = WorkspaceModel()
        let opened = try model.open(url: urlA)

        // A separate Untitled buffer that the user tries to Save As over file A.
        let draft = model.newFile()
        model.updateText("draft overwriting A", for: draft.id)

        XCTAssertThrowsError(try model.saveAs(url: urlA, for: draft.id)) { error in
            XCTAssertEqual(error as? WorkspaceModel.SaveAsError, .destinationAlreadyOpen)
        }

        // The draft is untouched (no url, still dirty) and no second buffer for
        // A's path exists — the original tab still solely owns it.
        let draftAfter = model.openFiles.first { $0.id == draft.id }
        XCTAssertNil(draftAfter?.url)
        XCTAssertTrue(draftAfter?.isDirty == true)
        XCTAssertEqual(model.openFiles.filter { $0.url == urlA }.map(\.id), [opened.id])
        // The file on disk was not overwritten with the draft's contents.
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), "file A on disk")
    }

    func testSaveAsOntoEquivalentPathOfOpenTabIsRejected() throws {
        let urlA = try writeTempFile(contents: "file A")
        defer { try? FileManager.default.removeItem(at: urlA) }

        let model = WorkspaceModel()
        try model.open(url: urlA)
        let draft = model.newFile()

        // Same destination reached via an unstandardized path (extra ".").
        let dir = urlA.deletingLastPathComponent()
        let equivalent = dir.appendingPathComponent(".")
            .appendingPathComponent(urlA.lastPathComponent)

        XCTAssertThrowsError(try model.saveAs(url: equivalent, for: draft.id)) { error in
            XCTAssertEqual(error as? WorkspaceModel.SaveAsError, .destinationAlreadyOpen)
        }
    }

    func testSaveAsToFilesOwnUrlIsAllowed() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("rewritten in place", for: file.id)

        // Save As back onto the file's own path must not be rejected as a
        // duplicate (the tab is allowed to target the url it already owns).
        XCTAssertNoThrow(try model.saveAs(url: url, for: file.id))
        XCTAssertFalse(model.openFiles.first?.isDirty == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "rewritten in place")
    }

    func testSaveAsWithUnknownIDIsNoOp() throws {
        let model = WorkspaceModel(fileService: StubFileService(writeError: StubError.boom))
        // A throwing write would surface if saveAs reached it; an unknown id
        // must short-circuit before any write.
        XCTAssertNoThrow(try model.saveAs(url: URL(fileURLWithPath: "/x"), for: UUID()))
    }

    func testMarkSavedWithUnknownIDIsNoOp() {
        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("edited", for: file.id)

        model.markSaved(for: UUID())

        XCTAssertTrue(model.openFiles.first?.isDirty == true)
    }

    // MARK: - External text replacement

    func testReplaceTextReplacesBufferAndBumpsRevision() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()

        XCTAssertEqual(model.textReplacementRevision(for: file.id), 0)

        XCTAssertTrue(model.replaceText("replaced", for: file.id))

        XCTAssertEqual(model.openFiles.first?.text, "replaced")
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 1)
        // Like `updateText`, the replacement leaves the saved baseline alone, so
        // the tab is dirty and saving stays the user's call.
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
    }

    func testReplaceTextWithUnknownIDIsNoOp() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        model.updateText("draft", for: file.id)

        XCTAssertFalse(model.replaceText("replaced", for: UUID()))

        XCTAssertEqual(model.openFiles.first?.text, "draft")
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 0)
    }

    func testUpdateTextDoesNotBumpReplacementRevision() {
        // The editing path: every keystroke routes through `updateText`, so a bump
        // there would make the editor drop the user's undo stack as they type.
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()

        model.updateText("a", for: file.id)
        model.updateText("ab", for: file.id)

        XCTAssertEqual(model.textReplacementRevision(for: file.id), 0)
    }

    func testReplaceTextRevisionIsPerFileAndMonotonic() {
        let model = WorkspaceModel(fileService: StubFileService())
        let first = model.newFile()
        let second = model.newFile()

        model.replaceText("one", for: first.id)
        model.replaceText("two", for: first.id)

        // Replacing one buffer must not look like a replacement of the other —
        // the editor would otherwise drop an untouched tab's undo history.
        XCTAssertEqual(model.textReplacementRevision(for: first.id), 2)
        XCTAssertEqual(model.textReplacementRevision(for: second.id), 0)
    }

    func testReloadFromDiskBumpsReplacementRevision() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        try "reverted on disk".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(model.reloadFromDisk(id: file.id))

        // A reload replaces the buffer just as `replaceText` does, and can target
        // a tab that is not on screen (a post-revert or post-merge resync).
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 1)
    }

    func testFailedReloadFromDiskDoesNotBumpReplacementRevision() {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "on disk"))
        let file = model.newFile()

        // A url-less buffer is never read, so nothing was replaced.
        XCTAssertFalse(model.reloadFromDisk(id: file.id))
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 0)
    }

    func testClosingFileDropsItsReplacementRevision() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        model.replaceText("replaced", for: file.id)
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 1)

        model.close(id: file.id, force: true)

        // The map must not accumulate entries for tabs that are no longer open.
        XCTAssertNil(model.textReplacementRevisions[file.id])
        XCTAssertEqual(model.textReplacementRevision(for: file.id), 0)
    }

    // MARK: - Reload from disk

    func testReloadFromDiskReplacesTextAndClearsDirty() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("local edits", for: file.id)
        XCTAssertTrue(model.selectedFile?.isDirty == true)

        // Simulate an external change (e.g. a revert restoring HEAD).
        try "reverted on disk".write(to: url, atomically: true, encoding: .utf8)

        let reloaded = model.reloadFromDisk(id: file.id)

        XCTAssertTrue(reloaded)
        let after = model.openFiles.first
        XCTAssertEqual(after?.text, "reverted on disk")
        XCTAssertEqual(after?.savedText, "reverted on disk")
        XCTAssertFalse(after?.isDirty == true)
    }

    func testReloadFromDiskWithUnknownIDIsNoOp() {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "on disk"))
        model.newFile()

        XCTAssertFalse(model.reloadFromDisk(id: UUID()))
    }

    func testReloadFromDiskOnUntitledBufferIsNoOp() {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "on disk"))
        let file = model.newFile()
        model.updateText("draft", for: file.id)

        // A url-less buffer has nothing to read from disk; reload is a no-op and
        // must not clobber the in-memory draft.
        XCTAssertFalse(model.reloadFromDisk(id: file.id))
        XCTAssertEqual(model.openFiles.first?.text, "draft")
        XCTAssertTrue(model.openFiles.first?.isDirty == true)
    }

    func testReloadFromDiskReadFailureLeavesBufferUnchanged() throws {
        let url = try writeTempFile(contents: "original")
        // Note: no defer-remove — the file is deleted mid-test on purpose.

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("unsaved edit", for: file.id)

        // Delete the file so the next read throws (missing file).
        try FileManager.default.removeItem(at: url)

        let reloaded = model.reloadFromDisk(id: file.id)

        XCTAssertFalse(reloaded)
        // A failed read must leave the in-memory buffer untouched (still dirty).
        let after = model.openFiles.first
        XCTAssertEqual(after?.text, "unsaved edit")
        XCTAssertTrue(after?.isDirty == true)
    }

    // MARK: - Reconcile saved baseline

    func testReconcileSavedBaselineMakesSavedBufferDirtyWhenDiskDiffers() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)

        // The user edited and *saved* during an in-flight revert: the buffer now
        // looks clean (text == savedText == "user edit").
        model.updateText("user edit", for: file.id)
        try model.save(for: file.id)
        XCTAssertFalse(model.openFiles.first?.isDirty == true)

        // git then reverted the file on disk back to HEAD behind the app's back.
        try "reverted on disk".write(to: url, atomically: true, encoding: .utf8)

        let reconciled = model.reconcileSavedBaseline(id: file.id)

        XCTAssertTrue(reconciled)
        let after = model.openFiles.first
        // The edit is preserved (text untouched)…
        XCTAssertEqual(after?.text, "user edit")
        // …but the baseline now reflects disk, so the tab is dirty and closing it
        // will prompt instead of silently discarding the edit.
        XCTAssertEqual(after?.savedText, "reverted on disk")
        XCTAssertTrue(after?.isDirty == true)
    }

    func testReconcileSavedBaselineStaysCleanWhenBufferMatchesDisk() throws {
        let url = try writeTempFile(contents: "same")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        // Buffer equals what is on disk — reconciling must leave it clean.
        XCTAssertFalse(model.openFiles.first?.isDirty == true)

        XCTAssertTrue(model.reconcileSavedBaseline(id: file.id))
        XCTAssertFalse(model.openFiles.first?.isDirty == true)
    }

    func testReconcileSavedBaselineWithDeletedFileForcesNonEmptyBufferDirty() throws {
        let url = try writeTempFile(contents: "original")
        // No defer-remove: deleted mid-test on purpose.

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("user edit", for: file.id)
        try model.save(for: file.id)
        XCTAssertFalse(model.openFiles.first?.isDirty == true)

        // The revert deleted the file (e.g. an added/untracked file reverted).
        try FileManager.default.removeItem(at: url)

        XCTAssertTrue(model.reconcileSavedBaseline(id: file.id))
        let after = model.openFiles.first
        // A deleted file is treated as empty on-disk content: the non-empty
        // buffer becomes dirty (its content survives and can be re-saved).
        XCTAssertEqual(after?.text, "user edit")
        XCTAssertEqual(after?.savedText, "")
        XCTAssertTrue(after?.isDirty == true)
    }

    func testReconcileSavedBaselineWithUnknownIDIsNoOp() {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "on disk"))
        model.newFile()

        XCTAssertFalse(model.reconcileSavedBaseline(id: UUID()))
    }

    func testReconcileSavedBaselineOnUntitledBufferIsNoOp() {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "on disk"))
        let file = model.newFile()
        model.updateText("draft", for: file.id)

        // A url-less buffer has no on-disk baseline to reconcile against; a no-op
        // that leaves the draft untouched.
        XCTAssertFalse(model.reconcileSavedBaseline(id: file.id))
        XCTAssertEqual(model.openFiles.first?.text, "draft")
    }

    // MARK: - fileID(forURL:)

    func testFileIDMatchesEquivalentButDifferentURLForm() throws {
        // The revert resync builds its url from the resolved repo root, which can
        // differ in form from the url the tab was opened with (unstandardized
        // `.`/`..`, trailing slash, `/tmp` vs `/private/tmp`). The lookup must
        // still find the tab — raw `==` would miss it.
        let url = try writeTempFile(contents: "x")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = WorkspaceModel()
        let file = try model.open(url: url)

        // Re-derive the same file through a non-standardized path.
        let dir = url.deletingLastPathComponent()
        let messy = dir
            .appendingPathComponent(".")
            .appendingPathComponent(url.lastPathComponent)

        XCTAssertNotEqual(messy, url) // the raw forms genuinely differ…
        XCTAssertEqual(model.fileID(forURL: messy), file.id) // …but canonically match.
    }

    func testFileIDReturnsNilWhenNoTabTargetsURL() {
        let model = WorkspaceModel()
        model.newFile() // an url-less Untitled buffer must never match.

        XCTAssertNil(model.fileID(forURL: URL(fileURLWithPath: "/repo/missing.swift")))
    }

    // MARK: - treeRevision

    func testTreeRevisionStartsAtZeroAndIncrementsOnBump() {
        let model = WorkspaceModel()
        XCTAssertEqual(model.treeRevision, 0)

        model.bumpTreeRevision()
        XCTAssertEqual(model.treeRevision, 1)

        model.bumpTreeRevision()
        XCTAssertEqual(model.treeRevision, 2)
    }

    // MARK: - renamePath

    func testRenamePathRetargetsSingleFileAndPreservesDirty() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let from = URL(fileURLWithPath: "/project/old.swift")
        let to = URL(fileURLWithPath: "/project/new.swift")
        let file = try model.open(url: from)
        // Edit so we can confirm the rename preserves dirty state.
        model.updateText("edited", for: file.id)
        XCTAssertTrue(model.openFiles.first?.isDirty == true)

        model.renamePath(from: from, to: to)

        let after = model.openFiles.first
        XCTAssertEqual(after?.url, to)
        XCTAssertEqual(after?.displayName, "new.swift")
        // Dirty state and text are untouched by the rename.
        XCTAssertEqual(after?.text, "edited")
        XCTAssertTrue(after?.isDirty == true)
    }

    func testRenamePathRewritesPrefixOfEveryNestedTabOnFolderRename() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let a = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        let b = try model.open(url: URL(fileURLWithPath: "/project/src/util/b.swift"))

        model.renamePath(
            from: URL(fileURLWithPath: "/project/src"),
            to: URL(fileURLWithPath: "/project/lib")
        )

        let aAfter = model.openFiles.first { $0.id == a.id }
        let bAfter = model.openFiles.first { $0.id == b.id }
        XCTAssertEqual(aAfter?.url, URL(fileURLWithPath: "/project/lib/a.swift"))
        XCTAssertEqual(bAfter?.url, URL(fileURLWithPath: "/project/lib/util/b.swift"))
    }

    func testRenamePathRetargetsFolderTabItselfAndNestedTabsTogether() throws {
        // A folder rename must both retarget a tab whose url is exactly the
        // folder (the `fromCanonical` branch) and rewrite the prefix of nested
        // tabs (the `relativeComponents` branch) in the same call.
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let folderTab = try model.open(url: URL(fileURLWithPath: "/project/src"))
        let nested = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))

        model.renamePath(
            from: URL(fileURLWithPath: "/project/src"),
            to: URL(fileURLWithPath: "/project/lib")
        )

        XCTAssertEqual(
            model.openFiles.first { $0.id == folderTab.id }?.url,
            URL(fileURLWithPath: "/project/lib")
        )
        XCTAssertEqual(
            model.openFiles.first { $0.id == nested.id }?.url,
            URL(fileURLWithPath: "/project/lib/a.swift")
        )
    }

    func testRenamePathLeavesUnrelatedAndSiblingPrefixTabsUntouched() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let keep = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))
        // A sibling whose name merely shares the renamed folder's prefix
        // (`/project/src` vs `/project/srcfile.swift`) must NOT be rewritten —
        // matching is component-based, not a raw string prefix.
        let sibling = try model.open(url: URL(fileURLWithPath: "/project/srcfile.swift"))

        model.renamePath(
            from: URL(fileURLWithPath: "/project/src"),
            to: URL(fileURLWithPath: "/project/lib")
        )

        XCTAssertEqual(
            model.openFiles.first { $0.id == keep.id }?.url,
            URL(fileURLWithPath: "/project/keep.swift")
        )
        XCTAssertEqual(
            model.openFiles.first { $0.id == sibling.id }?.url,
            URL(fileURLWithPath: "/project/srcfile.swift")
        )
    }

    func testRenamePathMatchesEquivalentButDifferentURLForm() throws {
        // The tab is opened with a real path; the rename's `from` is reached via
        // an equivalent unstandardized form. Canonical matching must still retarget.
        let url = try writeTempFile(contents: "x")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = WorkspaceModel()
        let file = try model.open(url: url)

        let dir = url.deletingLastPathComponent()
        let messyFrom = dir.appendingPathComponent(".").appendingPathComponent(url.lastPathComponent)
        let to = dir.appendingPathComponent("renamed.txt")

        model.renamePath(from: messyFrom, to: to)

        XCTAssertEqual(model.openFiles.first { $0.id == file.id }?.url, to)
    }

    // MARK: - closeFiles(under:)

    func testCloseFilesUnderClosesTheMatchingFileTab() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let a = try model.open(url: URL(fileURLWithPath: "/project/a.swift"))
        let b = try model.open(url: URL(fileURLWithPath: "/project/b.swift"))

        model.closeFiles(under: URL(fileURLWithPath: "/project/a.swift"))

        XCTAssertEqual(model.openFiles.map(\.id), [b.id])
        _ = a
    }

    func testCloseFilesUnderClosesEveryNestedTabAndLeavesOthersOpen() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let nested1 = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        let nested2 = try model.open(url: URL(fileURLWithPath: "/project/src/util/b.swift"))
        let keep = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))
        // A sibling sharing the folder's name prefix must survive.
        let sibling = try model.open(url: URL(fileURLWithPath: "/project/srcfile.swift"))

        model.closeFiles(under: URL(fileURLWithPath: "/project/src"))

        XCTAssertEqual(model.openFiles.map(\.id), [keep.id, sibling.id])
        _ = (nested1, nested2)
    }

    func testCloseFilesUnderMovesSelectionWhenSelectedTabIsClosed() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let first = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))
        let doomed = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        model.select(doomed.id)

        model.closeFiles(under: URL(fileURLWithPath: "/project/src"))

        // The deleted tab is gone and the selection falls back to a surviving tab.
        XCTAssertEqual(model.openFiles.map(\.id), [first.id])
        XCTAssertEqual(model.selectedID, first.id)
    }

    func testCloseFilesUnderKeepsSelectionWhenSelectedTabIsUnaffected() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let selected = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))
        let doomed = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        model.select(selected.id)

        model.closeFiles(under: URL(fileURLWithPath: "/project/src"))

        // The unrelated selected tab is untouched while the nested tab closes.
        XCTAssertEqual(model.openFiles.map(\.id), [selected.id])
        XCTAssertEqual(model.selectedID, selected.id)
        _ = doomed
    }

    func testCloseFilesUnderIsNoOpForUnrelatedPath() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let a = try model.open(url: URL(fileURLWithPath: "/project/a.swift"))
        let b = try model.open(url: URL(fileURLWithPath: "/project/b.swift"))

        model.closeFiles(under: URL(fileURLWithPath: "/project/other"))

        XCTAssertEqual(model.openFiles.map(\.id), [a.id, b.id])
    }

    // MARK: - planRename / applyRenamePlan (pre-mutation capture)

    func testPlanRenameCapturesSingleAndNestedTabs() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let folderTab = try model.open(url: URL(fileURLWithPath: "/project/src"))
        let nested = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        let unrelated = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))

        let plan = model.planRename(
            from: URL(fileURLWithPath: "/project/src"),
            to: URL(fileURLWithPath: "/project/lib")
        )

        XCTAssertEqual(
            plan,
            [
                WorkspaceModel.RenameRetarget(
                    id: folderTab.id, newURL: URL(fileURLWithPath: "/project/lib")),
                WorkspaceModel.RenameRetarget(
                    id: nested.id, newURL: URL(fileURLWithPath: "/project/lib/a.swift"))
            ]
        )
        // Capturing the plan does not mutate any tab.
        XCTAssertEqual(model.openFiles.first { $0.id == folderTab.id }?.url,
                       URL(fileURLWithPath: "/project/src"))
        _ = unrelated
    }

    func testApplyRenamePlanRetargetsAndIgnoresClosedTab() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let a = try model.open(url: URL(fileURLWithPath: "/project/a.swift"))
        let b = try model.open(url: URL(fileURLWithPath: "/project/b.swift"))

        // A plan entry for a tab that has since closed is silently ignored.
        model.close(id: b.id, force: true)
        model.applyRenamePlan([
            WorkspaceModel.RenameRetarget(id: a.id, newURL: URL(fileURLWithPath: "/project/a2.swift")),
            WorkspaceModel.RenameRetarget(id: b.id, newURL: URL(fileURLWithPath: "/project/b2.swift"))
        ])

        XCTAssertEqual(model.openFiles.map(\.url), [URL(fileURLWithPath: "/project/a2.swift")])
    }

    func testPlanRenameMovesFolderAcrossDirectoriesKeepingTabIdentityAndState() throws {
        // The drag-and-drop case: the folder keeps its name and changes parent,
        // which is the same `planRename` + `applyRenamePlan` pair a rename uses.
        // What must survive the move is everything a tab *is* apart from its path:
        // its identity (so its viewport memory, keyed by id, still finds it), its
        // buffer and its dirty state.
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let folderTab = try model.open(url: URL(fileURLWithPath: "/project/src"))
        let nested = try model.open(url: URL(fileURLWithPath: "/project/src/a.swift"))
        let deep = try model.open(url: URL(fileURLWithPath: "/project/src/deep/b.swift"))
        let unrelated = try model.open(url: URL(fileURLWithPath: "/project/keep.swift"))
        model.updateText("edited", for: nested.id)

        var viewports = EditorViewportMemory()
        viewports.record(
            EditorViewport(selection: NSRange(location: 3, length: 0), topCharacterOffset: 2),
            for: nested.id
        )

        let from = URL(fileURLWithPath: "/project/src")
        let to = URL(fileURLWithPath: "/project/lib/src")
        let plan = model.planRename(from: from, to: to)
        model.applyRenamePlan(plan)

        // Every tab at or beneath the folder now names its new home; the folder
        // itself keeps its last component, only its parent changed.
        XCTAssertEqual(model.openFiles.first { $0.id == folderTab.id }?.url, to)
        XCTAssertEqual(
            model.openFiles.first { $0.id == nested.id }?.url,
            URL(fileURLWithPath: "/project/lib/src/a.swift")
        )
        XCTAssertEqual(
            model.openFiles.first { $0.id == deep.id }?.url,
            URL(fileURLWithPath: "/project/lib/src/deep/b.swift")
        )
        // An unrelated tab is untouched — and no tab was opened or closed.
        XCTAssertEqual(
            model.openFiles.first { $0.id == unrelated.id }?.url,
            URL(fileURLWithPath: "/project/keep.swift")
        )
        XCTAssertEqual(model.openFiles.map(\.id), [folderTab.id, nested.id, deep.id, unrelated.id])

        // Identity, buffer and dirty state survive: only `url` changed.
        let movedNested = try XCTUnwrap(model.openFiles.first { $0.id == nested.id })
        XCTAssertEqual(movedNested.text, "edited")
        XCTAssertEqual(movedNested.savedText, "code")
        XCTAssertTrue(movedNested.isDirty)
        XCTAssertFalse(try XCTUnwrap(model.openFiles.first { $0.id == deep.id }).isDirty)
        // The viewport memory is keyed by that preserved identity, so the moved
        // tab still resolves its caret and scroll anchor.
        XCTAssertEqual(
            viewports.viewport(for: movedNested.id, clampedToLength: movedNested.text.utf16.count),
            EditorViewport(selection: NSRange(location: 3, length: 0), topCharacterOffset: 2)
        )
    }

    func testPlanRenameMatchesSymlinkedTabBeforeMoveButNotAfter() throws {
        // A tab opened through a symlink to the renamed target must be captured by
        // a plan taken *before* the on-disk move: once the move renames the target
        // away the symlink dangles, so canonical matching can no longer resolve it
        // and a plan taken *after* the move would silently miss the tab.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        let renamed = dir.appendingPathComponent("renamed.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        let file = try model.open(url: link)

        // Before the move, the symlinked tab canonicalizes to `target`, so it is
        // captured (retargeted to the new real path).
        let planBefore = model.planRename(from: target, to: renamed)
        XCTAssertEqual(planBefore, [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamed)])

        // After the move, `link` dangles and no longer matches `target` — a plan
        // taken now would miss the tab (the regression this ordering prevents).
        try FileManager.default.moveItem(at: target, to: renamed)
        XCTAssertEqual(model.planRename(from: target, to: renamed), [])
    }

    // MARK: - tabIDs(under:) / closeFiles(ids:)

    func testCloseFilesByIDsClosesOnlyListedTabs() throws {
        let model = WorkspaceModel(fileService: StubFileService(readResult: "code"))
        let a = try model.open(url: URL(fileURLWithPath: "/project/a.swift"))
        let b = try model.open(url: URL(fileURLWithPath: "/project/b.swift"))
        let c = try model.open(url: URL(fileURLWithPath: "/project/c.swift"))

        model.closeFiles(ids: [a.id, c.id])

        XCTAssertEqual(model.openFiles.map(\.id), [b.id])
    }

    func testTabIDsUnderMatchesSymlinkedTabBeforeRemovalButNotAfter() throws {
        // The delete counterpart of the rename test: a tab opened through a symlink
        // to the deleted item must be captured by `tabIDs(under:)` taken *before*
        // the removal, since the symlink dangles afterward.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        let file = try model.open(url: link)

        XCTAssertEqual(model.tabIDs(under: target), [file.id])

        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(model.tabIDs(under: target), [])
    }

    func testTabIDsUnderSymlinkEntryDoesNotMatchTargetTab() throws {
        // Deleting a *symlink entry* removes only the link, not its referent, so a
        // tab opened directly on the referent must not be matched (and force-closed,
        // losing edits). The operation side keeps the entry's final component
        // literal, so `link.txt` no longer resolves to `real.txt`.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        let file = try model.open(url: target)

        // Deleting the symlink leaves the tab on the real file untouched...
        XCTAssertEqual(model.tabIDs(under: link), [])
        // ...while deleting the real file still matches it.
        XCTAssertEqual(model.tabIDs(under: target), [file.id])
    }

    func testPlanRenameSymlinkEntryDoesNotRetargetTargetTab() throws {
        // The rename counterpart: renaming a symlink retargets only references to
        // the link, never a tab opened directly on its (unmoved) referent.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        let renamedLink = dir.appendingPathComponent("link2.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        _ = try model.open(url: target)

        XCTAssertEqual(model.planRename(from: link, to: renamedLink), [])
    }

    func testPlanRenameRetargetsTabOpenedOnTheRenamedSymlinkItself() throws {
        // A tab opened *directly on the symlink* must be retargeted when that
        // symlink is renamed: the link entry itself moves, so the tab's url
        // (which canonicalizes to the referent) must follow the new link path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        let renamedLink = dir.appendingPathComponent("link2.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        let file = try model.open(url: link)

        XCTAssertEqual(
            model.planRename(from: link, to: renamedLink),
            [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamedLink)]
        )
    }

    func testTabIDsUnderClosesTabOpenedOnTheDeletedSymlinkItself() throws {
        // The delete counterpart: a tab opened directly on the symlink must be
        // closed when that symlink is deleted (the link the tab points at is gone).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let model = WorkspaceModel()
        let file = try model.open(url: link)

        XCTAssertEqual(model.tabIDs(under: link), [file.id])
    }

    func testPlanRenameRetargetsTabNestedUnderRenamedSymlinkDirectory() throws {
        // Renaming a symlink-to-directory must retarget a tab opened through it:
        // `linkdir/a.txt` canonicalizes to `realdir/a.txt` (which the canonical
        // test misses against the literal `linkdir` entry), but the link the tab
        // descends through is being renamed, so the tab follows the new link path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let realDir = dir.appendingPathComponent("realdir")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let nested = realDir.appendingPathComponent("a.txt")
        try "x".write(to: nested, atomically: true, encoding: .utf8)
        let linkDir = dir.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        let renamedDir = dir.appendingPathComponent("linkdir2")

        let model = WorkspaceModel()
        let file = try model.open(url: linkDir.appendingPathComponent("a.txt"))

        XCTAssertEqual(
            model.planRename(from: linkDir, to: renamedDir),
            [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamedDir.appendingPathComponent("a.txt"))]
        )
        XCTAssertEqual(model.tabIDs(under: linkDir), [file.id])
    }

    func testPlanRenameMatchesSymlinkEntryReachedViaDifferentAncestorAlias() throws {
        // The tree operates on a symlink entry *through a symlinked project root*
        // (`linkroot/entry.txt`), while the tab remembers the same entry via its
        // canonical parent (`realroot/entry.txt`). The lexical paths diverge at the
        // ancestor (linkroot vs realroot) and the canonical test resolves the final
        // symlink to its referent, so the entry-identity test (ancestors
        // canonicalized, final component literal) is what keeps them matched.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let realRoot = base.appendingPathComponent("realroot")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The entry's referent lives outside the root so canonicalization differs
        // from the entry path itself.
        let target = base.appendingPathComponent("elsewhere.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let entry = realRoot.appendingPathComponent("entry.txt")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
        let linkRoot = base.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let model = WorkspaceModel()
        // Tab remembers the canonical-parent spelling of the symlink entry.
        let file = try model.open(url: entry)
        // Operation arrives through the symlinked project root.
        let operationFrom = linkRoot.appendingPathComponent("entry.txt")
        let renamed = linkRoot.appendingPathComponent("entry2.txt")

        XCTAssertEqual(
            model.planRename(from: operationFrom, to: renamed),
            [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamed)]
        )
        XCTAssertEqual(model.tabIDs(under: operationFrom), [file.id])
    }

    func testPlanRenameSymlinkEntryViaAliasStillSpareTabOnReferent() throws {
        // Counterpart guard: with the same symlinked-root setup, a tab opened on
        // the *referent* (not the link) must NOT be matched — renaming the symlink
        // entry leaves the referent untouched. Its entry identity keeps the
        // referent's own final component, so it differs from the operated entry.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let realRoot = base.appendingPathComponent("realroot")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("elsewhere.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let entry = realRoot.appendingPathComponent("entry.txt")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
        let linkRoot = base.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let model = WorkspaceModel()
        // Tab opened directly on the referent file, not the link.
        _ = try model.open(url: target)
        let operationFrom = linkRoot.appendingPathComponent("entry.txt")
        let renamed = linkRoot.appendingPathComponent("entry2.txt")

        XCTAssertTrue(model.planRename(from: operationFrom, to: renamed).isEmpty)
        XCTAssertTrue(model.tabIDs(under: operationFrom).isEmpty)
    }

    func testReconcilesTabNestedUnderSymlinkDirectoryReachedViaAliasedRoot() throws {
        // The combined case: the tree operates on a symlink *directory* entry
        // through a symlinked project root (`linkroot/linkdir`), while a tab
        // descends through that symlink via its canonical-parent spelling
        // (`realroot/linkdir/a.txt`). The lexical paths diverge at the ancestor
        // (linkroot vs realroot), the canonical test resolves `linkdir` to its
        // referent (`target/a.txt`), and the immediate-parent entry identity also
        // resolves `linkdir` — so only the depth-aligned ancestor entry identity
        // (operated `linkdir` kept literal) keeps the nested tab matched, so the
        // now-dangling tab is retargeted on rename and closed on delete.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let realRoot = base.appendingPathComponent("realroot")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The symlink directory's referent lives outside the root so the tab's
        // canonical path differs from its lexical (through-the-link) path.
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let linkDir = realRoot.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: target)
        let linkRoot = base.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let model = WorkspaceModel()
        // Tab opened through the symlink directory via the canonical-root spelling.
        let file = try model.open(url: realRoot.appendingPathComponent("linkdir/a.txt"))
        // Operation arrives through the symlinked project root.
        let operationFrom = linkRoot.appendingPathComponent("linkdir")
        let renamed = linkRoot.appendingPathComponent("linkdir2")

        XCTAssertEqual(
            model.planRename(from: operationFrom, to: renamed),
            [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamed.appendingPathComponent("a.txt"))]
        )
        XCTAssertEqual(model.tabIDs(under: operationFrom), [file.id])
    }

    func testReconcilesTabNestedUnderSymlinkDirectoryReachedViaDifferentDepthAlias() throws {
        // Like the combined case above, but the aliased root has a *different path
        // depth* than its target: `shortlink` (one component under base) points at
        // `deep/project/root` (three components under base). The earlier
        // depth-aligned matching truncated the tab's lexical path to the operation
        // entry's component count, which lands on the wrong ancestor — or, when the
        // tab's lexical path is the shorter one, skips the comparison entirely —
        // leaving a stale tab after rename/delete. Per-ancestor entry-identity
        // matching absorbs the depth difference, so the nested tab is still
        // retargeted on rename and closed on delete.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let realRoot = base
            .appendingPathComponent("deep")
            .appendingPathComponent("project")
            .appendingPathComponent("root")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        // The symlink directory's referent lives outside the root so the tab's
        // canonical path differs from its lexical (through-the-link) path.
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let linkDir = realRoot.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: target)
        // The aliased root is a single component under `base` — a *shorter* path
        // than the three-component `deep/project/root` it points at.
        let shortRoot = base.appendingPathComponent("shortlink")
        try FileManager.default.createSymbolicLink(at: shortRoot, withDestinationURL: realRoot)

        let model = WorkspaceModel()
        // Tab opened through the symlink directory via the *short* aliased root.
        let file = try model.open(url: shortRoot.appendingPathComponent("linkdir/a.txt"))
        // Operation arrives through the canonical (deep) root spelling.
        let operationFrom = realRoot.appendingPathComponent("linkdir")
        let renamed = realRoot.appendingPathComponent("linkdir2")

        XCTAssertEqual(
            model.planRename(from: operationFrom, to: renamed),
            [WorkspaceModel.RenameRetarget(id: file.id, newURL: renamed.appendingPathComponent("a.txt"))]
        )
        XCTAssertEqual(model.tabIDs(under: operationFrom), [file.id])
    }

    func testNestedSymlinkDirViaAliasStillSpareTabOnReferent() throws {
        // Counterpart guard for the combined case: a tab opened on the symlink
        // directory's *referent* (`target/a.txt`, the canonical path) must NOT be
        // matched — operating on the link leaves the referent reachable, so the
        // tab's remembered url stays valid. Its ancestor entry identity keeps the
        // referent's own component (`target`), differing from the operated `linkdir`.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let realRoot = base.appendingPathComponent("realroot")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let linkDir = realRoot.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: target)
        let linkRoot = base.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let model = WorkspaceModel()
        // Tab opened directly on the referent file, not through the link.
        _ = try model.open(url: target.appendingPathComponent("a.txt"))
        let operationFrom = linkRoot.appendingPathComponent("linkdir")
        let renamed = linkRoot.appendingPathComponent("linkdir2")

        XCTAssertTrue(model.planRename(from: operationFrom, to: renamed).isEmpty)
        XCTAssertTrue(model.tabIDs(under: operationFrom).isEmpty)
    }

    // MARK: - Closing

    func testCloseCleanFileRemovesItImmediately() {
        let model = WorkspaceModel()
        let file = model.newFile()

        let result = model.close(id: file.id)

        XCTAssertEqual(result, .closed)
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    func testCloseDirtyFileRequiresConfirmationAndKeepsTab() {
        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("unsaved", for: file.id)

        let result = model.close(id: file.id)

        XCTAssertEqual(result, .needsConfirmation)
        // The model must not remove a dirty file without an explicit decision.
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.openFiles.first?.id, file.id)
    }

    func testForceCloseRemovesDirtyFileWithoutSaving() {
        let model = WorkspaceModel()
        let file = model.newFile()
        model.updateText("unsaved", for: file.id)

        let result = model.close(id: file.id, force: true)

        XCTAssertEqual(result, .closed)
        XCTAssertTrue(model.openFiles.isEmpty)
    }

    func testClosingSelectedSelectsNextNeighbor() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()
        let third = model.newFile()

        model.select(second.id)
        model.close(id: second.id)

        // The tab that shifted into the slot (the next one) becomes selected.
        XCTAssertEqual(model.openFiles.map(\.id), [first.id, third.id])
        XCTAssertEqual(model.selectedID, third.id)
    }

    func testClosingSelectedLastTabSelectsPreviousNeighbor() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()

        model.select(second.id)
        model.close(id: second.id)

        XCTAssertEqual(model.selectedID, first.id)
    }

    func testClosingNonSelectedTabKeepsSelection() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()

        model.select(second.id)
        model.close(id: first.id)

        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.openFiles.map(\.id), [second.id])
    }

    func testClosingLastTabClearsSelection() {
        let model = WorkspaceModel()
        let file = model.newFile()

        model.close(id: file.id)

        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedFile)
    }

    func testCloseWithUnknownIDIsNoOp() {
        let model = WorkspaceModel()
        let file = model.newFile()

        let result = model.close(id: UUID())

        XCTAssertEqual(result, .closed)
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.selectedID, file.id)
    }

    // MARK: - Project root

    func testProjectRootIsNilInitially() {
        let model = WorkspaceModel()
        XCTAssertNil(model.projectRoot)
    }

    func testOpenFolderSetsProjectRoot() {
        let model = WorkspaceModel()
        let folder = URL(fileURLWithPath: "/some/project", isDirectory: true)

        model.openFolder(url: folder)

        XCTAssertEqual(model.projectRoot, folder)
    }

    func testOpenFolderDoesNotChangeOpenFilesOrSelection() {
        let model = WorkspaceModel()
        let first = model.newFile()
        let second = model.newFile()
        model.select(first.id)

        model.openFolder(url: URL(fileURLWithPath: "/some/project", isDirectory: true))

        XCTAssertEqual(model.openFiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedID, first.id)
    }

    func testChildrenReturnsStubDirectoryEntries() throws {
        let dir = URL(fileURLWithPath: "/project", isDirectory: true)
        let entries = [
            DirectoryEntry(url: dir.appendingPathComponent("src", isDirectory: true), isDirectory: true),
            DirectoryEntry(url: dir.appendingPathComponent("README.md"), isDirectory: false)
        ]
        let model = WorkspaceModel(fileService: StubFileService(directoryEntries: entries))

        let result = try model.children(of: dir)

        XCTAssertEqual(result, entries)
    }

    func testChildrenPropagatesDirectoryError() {
        let model = WorkspaceModel(fileService: StubFileService(directoryError: StubError.boom))

        XCTAssertThrowsError(try model.children(of: URL(fileURLWithPath: "/nope"))) { error in
            // The model must surface the underlying error unchanged (the tree
            // view relies on the throw to beep), not swallow or wrap it.
            XCTAssertEqual(error as? StubError, .boom)
        }
    }

    func testChildrenListsNestedDirectoryFromDisk() throws {
        // The tree view relies on children(of:) returning a directory's real
        // contents (sorted folders-first) so it can recurse into subfolders.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sub = root.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "# readme".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "code".write(to: sub.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let model = WorkspaceModel()

        let top = try model.children(of: root)
        XCTAssertEqual(top.map(\.name), ["src", "README.md"])
        XCTAssertEqual(top.map(\.isDirectory), [true, false])

        // Recurse into the subdirectory the same way the view does.
        let subEntry = try XCTUnwrap(top.first { $0.isDirectory })
        let nested = try model.children(of: subEntry.url)
        XCTAssertEqual(nested.map(\.name), ["main.swift"])
    }

    // MARK: - saveAllDirty

    func testSaveAllDirtySavesMultipleTitledFiles() throws {
        let urlA = try writeTempFile(contents: "a original")
        let urlB = try writeTempFile(contents: "b original")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let model = WorkspaceModel()
        let fileA = try model.open(url: urlA)
        let fileB = try model.open(url: urlB)
        model.updateText("a edited", for: fileA.id)
        model.updateText("b edited", for: fileB.id)

        let saved = model.saveAllDirty()

        XCTAssertEqual(Set(saved), [urlA, urlB])
        XCTAssertTrue(model.openFiles.allSatisfy { !$0.isDirty })
        XCTAssertEqual(try String(contentsOf: urlA, encoding: .utf8), "a edited")
        XCTAssertEqual(try String(contentsOf: urlB, encoding: .utf8), "b edited")
    }

    func testSaveAllDirtySkipsCleanFiles() throws {
        let urlClean = try writeTempFile(contents: "clean on disk")
        let urlDirty = try writeTempFile(contents: "dirty original")
        defer {
            try? FileManager.default.removeItem(at: urlClean)
            try? FileManager.default.removeItem(at: urlDirty)
        }

        let model = WorkspaceModel()
        try model.open(url: urlClean)
        let dirty = try model.open(url: urlDirty)
        model.updateText("dirty edited", for: dirty.id)

        let saved = model.saveAllDirty()

        XCTAssertEqual(saved, [urlDirty])
        // The clean file was never rewritten.
        XCTAssertEqual(try String(contentsOf: urlClean, encoding: .utf8), "clean on disk")
    }

    func testSaveAllDirtySkipsUntitledBuffer() throws {
        let url = try writeTempFile(contents: "titled original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let titled = try model.open(url: url)
        model.updateText("titled edited", for: titled.id)
        let untitled = model.newFile()
        model.updateText("draft", for: untitled.id)

        let saved = model.saveAllDirty()

        XCTAssertEqual(saved, [url])
        // The url-less buffer is never written and stays dirty.
        let untitledNow = model.openFiles.first { $0.id == untitled.id }
        XCTAssertNil(untitledNow?.url)
        XCTAssertTrue(untitledNow?.isDirty == true)
    }

    func testSaveAllDirtyIsIdempotent() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("edited", for: file.id)

        XCTAssertEqual(model.saveAllDirty(), [url])
        // Nothing is dirty now, so a second call writes nothing.
        XCTAssertEqual(model.saveAllDirty(), [])
    }

    func testSaveAllDirtyWithNoOpenFilesReturnsEmpty() {
        let model = WorkspaceModel()
        XCTAssertEqual(model.saveAllDirty(), [])
    }

    func testSaveAllDirtyWithOnlyDirtyUntitledReturnsEmpty() {
        let model = WorkspaceModel()
        let untitled = model.newFile()
        model.updateText("draft", for: untitled.id)

        // The only dirty buffer is url-less, so nothing is written and the
        // method returns [] without prompting — and the buffer stays dirty.
        XCTAssertEqual(model.saveAllDirty(), [])
        let untitledNow = model.openFiles.first { $0.id == untitled.id }
        XCTAssertNil(untitledNow?.url)
        XCTAssertTrue(untitledNow?.isDirty == true)
    }

    func testSaveAllDirtyRetriesPreviouslyFailedFileOnceWritable() throws {
        let url = URL(fileURLWithPath: "/bad/file.txt")
        let service = RecordingFileService(failURLs: [url])
        let model = WorkspaceModel(fileService: service)

        let file = try model.open(url: url)
        model.updateText("edited", for: file.id)

        // First attempt fails: the file stays dirty and is not returned.
        XCTAssertEqual(model.saveAllDirty(), [])
        XCTAssertTrue(model.openFiles.first { $0.id == file.id }?.isDirty == true)

        // The write becomes possible (e.g. permissions restored). A later
        // autosave must not have cached the failure — it writes and clears.
        service.failURLs = []
        XCTAssertEqual(model.saveAllDirty(), [url])
        XCTAssertFalse(model.openFiles.first { $0.id == file.id }?.isDirty == true)
        XCTAssertEqual(service.written[url], "edited")
    }

    func testSaveAllDirtyWriteFailureSkipsFileAndContinues() throws {
        let urlGood = URL(fileURLWithPath: "/good/file.txt")
        let urlBad = URL(fileURLWithPath: "/bad/file.txt")
        let service = RecordingFileService(failURLs: [urlBad])
        let model = WorkspaceModel(fileService: service)

        // Both files start from a known on-disk baseline via the stub read.
        let good = try model.open(url: urlGood)
        let bad = try model.open(url: urlBad)
        model.updateText("good edited", for: good.id)
        model.updateText("bad edited", for: bad.id)

        let saved = model.saveAllDirty()

        XCTAssertEqual(saved, [urlGood])
        // The bad file stays dirty; the good one is clean.
        let goodNow = model.openFiles.first { $0.id == good.id }
        let badNow = model.openFiles.first { $0.id == bad.id }
        XCTAssertFalse(goodNow?.isDirty == true)
        XCTAssertTrue(badNow?.isDirty == true)
        // Bytes written match the good file's text; the bad write was attempted
        // but threw, so it recorded nothing.
        XCTAssertEqual(service.written[urlGood], "good edited")
        XCTAssertNil(service.written[urlBad])
    }

    // MARK: - Disk revision token
    //
    // Every assertion here pins the *observable* contract stated on
    // `diskRevisions` — the affected file's token differs and no other file's
    // does — never the arithmetic. A future refactor routing one mutator through
    // another (a `save(for:)` that delegates to `markSaved`) would bump twice and
    // change nothing a consumer can see, so these must stay green through it.

    func testDiskRevisionIsZeroForUnknownID() {
        let model = WorkspaceModel(fileService: StubFileService())
        model.newFile()

        XCTAssertEqual(model.diskRevision(for: UUID()), 0)
    }

    /// **Every** save must change the token, not just the first one.
    ///
    /// The rest of these tests capture one baseline and perform one mutation, so
    /// they hold for an implementation that merely *marks* a file as having
    /// changed once (`diskRevisions[id] = 1`). `BlameController` compares the token
    /// against the last value it saw, so under such an implementation it would
    /// reload the annotation column on the first save of a tab and then never
    /// again — the column silently frozen at the first version for the rest of the
    /// session. Comparing against a baseline re-captured *between* mutations pins
    /// the property that actually matters, still without asserting any increment.
    func testEverySaveChangesTheDiskRevisionAgain() throws {
        let url = try writeTempFile(contents: "on disk")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)

        for pass in 1...3 {
            let before = diskTokens(of: model)
            model.updateText("edited \(pass)", for: file.id)
            XCTAssertEqual(try model.save(for: file.id), .saved)

            assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        }
    }

    /// The same property across the *other* mutators, so a token that only ever
    /// moves once per file is caught whichever site is asked first.
    func testDiskRevisionChangesAgainAcrossDifferentMutators() throws {
        let url = try writeTempFile(contents: "on disk")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)

        var before = diskTokens(of: model)
        model.markSaved(for: file.id)
        assertDiskRevisions(of: model, changedFor: [file.id], from: before)

        before = diskTokens(of: model)
        try "changed underneath".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.reloadFromDisk(id: file.id))
        assertDiskRevisions(of: model, changedFor: [file.id], from: before)

        before = diskTokens(of: model)
        XCTAssertTrue(model.reconcileSavedBaseline(id: file.id))
        assertDiskRevisions(of: model, changedFor: [file.id], from: before)

        before = diskTokens(of: model)
        model.updateText("edited", for: file.id)
        XCTAssertEqual(try model.save(for: file.id), .saved)
        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
    }

    func testMarkSavedChangesOnlyThatFilesDiskRevision() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        let other = model.newFile()
        model.updateText("edited", for: file.id)
        let before = diskTokens(of: model)

        model.markSaved(for: file.id)

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    func testMarkSavedWithUnknownIDLeavesEveryDiskRevisionUntouched() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        model.updateText("edited", for: file.id)
        let before = diskTokens(of: model)

        model.markSaved(for: UUID())

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testSaveChangesOnlyThatFilesDiskRevision() throws {
        let url = try writeTempFile(contents: "on disk")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        let other = model.newFile()
        model.updateText("edited", for: file.id)
        let before = diskTokens(of: model)

        XCTAssertEqual(try model.save(for: file.id), .saved)

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    func testSaveOfURLLessBufferLeavesEveryDiskRevisionUntouched() {
        // `.needsSaveAs`: nothing was written, so no file on disk changed.
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        model.updateText("edited", for: file.id)
        let before = diskTokens(of: model)

        XCTAssertEqual(try? model.save(for: file.id), .needsSaveAs)

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testFailedSaveLeavesEveryDiskRevisionUntouched() throws {
        let url = try writeTempFile(contents: "on disk")
        defer { try? FileManager.default.removeItem(at: url) }

        let service = RecordingFileService(failURLs: [url])
        let model = WorkspaceModel(fileService: service)
        let file = try model.open(url: url)
        model.updateText("edited", for: file.id)
        let before = diskTokens(of: model)

        XCTAssertThrowsError(try model.save(for: file.id))

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testSaveAllDirtyChangesOnlyTheWrittenFilesDiskRevisions() throws {
        let urlGood = try writeTempFile(contents: "good")
        let urlBad = try writeTempFile(contents: "bad")
        let urlClean = try writeTempFile(contents: "clean")
        defer {
            try? FileManager.default.removeItem(at: urlGood)
            try? FileManager.default.removeItem(at: urlBad)
            try? FileManager.default.removeItem(at: urlClean)
        }

        let service = RecordingFileService(failURLs: [urlBad])
        let model = WorkspaceModel(fileService: service)
        let good = try model.open(url: urlGood)
        let bad = try model.open(url: urlBad)
        let clean = try model.open(url: urlClean)
        let untitled = model.newFile()
        model.updateText("good edited", for: good.id)
        model.updateText("bad edited", for: bad.id)
        model.updateText("untitled edited", for: untitled.id)
        let before = diskTokens(of: model)

        XCTAssertEqual(model.saveAllDirty(), [urlGood])

        // Only the file actually written moved: the failed write, the clean file
        // and the url-less buffer all still correspond to the bytes they did.
        assertDiskRevisions(of: model, changedFor: [good.id], from: before)
        XCTAssertEqual(model.diskRevision(for: bad.id), 0)
        XCTAssertEqual(model.diskRevision(for: clean.id), 0)
        XCTAssertEqual(model.diskRevision(for: untitled.id), 0)
    }

    func testSaveAllDirtyWithNothingToSaveLeavesEveryDiskRevisionUntouched() throws {
        let url = try writeTempFile(contents: "on disk")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        model.updateText("edited", for: file.id)
        XCTAssertEqual(model.saveAllDirty(), [url])
        let before = diskTokens(of: model)

        // Idempotent: the second call finds nothing dirty and writes nothing.
        XCTAssertEqual(model.saveAllDirty(), [])

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testSaveAsChangesOnlyThatFilesDiskRevision() throws {
        let url = try writeTempFile(contents: "")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = model.newFile()
        let other = model.newFile()
        model.updateText("fresh contents", for: file.id)
        let before = diskTokens(of: model)

        try model.saveAs(url: url, for: file.id)

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    func testRejectedSaveAsLeavesEveryDiskRevisionUntouched() throws {
        let url = try writeTempFile(contents: "taken")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        try model.open(url: url)
        let other = model.newFile()
        model.updateText("would clobber", for: other.id)
        let before = diskTokens(of: model)

        XCTAssertThrowsError(try model.saveAs(url: url, for: other.id))

        // Nothing was written, so no buffer's on-disk content changed.
        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testReloadFromDiskChangesOnlyThatFilesDiskRevision() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        let other = model.newFile()
        try "reverted on disk".write(to: url, atomically: true, encoding: .utf8)
        let before = diskTokens(of: model)

        XCTAssertTrue(model.reloadFromDisk(id: file.id))

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    /// A reload that reads back exactly what the buffer already holds replaced
    /// nothing, so the *replacement* token stays put. Every post-operation resync
    /// reloads *every* open tab under the repository while typically rewriting none
    /// of them (a commit ordinarily touches no file), and a bump there is read
    /// downstream as "this buffer was replaced": the editor would drop that file's
    /// undo stack on the next tab switch, silently, with nothing on screen changed.
    func testReloadFromDiskWithIdenticalContentsMovesNoReplacementToken() throws {
        let url = try writeTempFile(contents: "unchanged")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        let replacementBefore = model.textReplacementRevision(for: file.id)

        // Still a successful reload — `false` means "could not be read", which
        // makes the caller close the tab.
        XCTAssertTrue(model.reloadFromDisk(id: file.id))

        XCTAssertEqual(model.textReplacementRevision(for: file.id), replacementBefore)
        XCTAssertEqual(model.text(for: file.id), "unchanged")
        XCTAssertFalse(model.isDirty(for: file.id))
    }

    /// The *disk* token moves even for a byte-identical read, and only that file's.
    /// It means "the on-disk content this buffer corresponds to changed", which is
    /// what the caller asserted by asking for a reload at all: after a commit or a
    /// branch checkout a file whose bytes match on both sides still belongs to
    /// different history, so its worktree `git blame` moved. Skipping the bump left
    /// the gutter naming the previous branch's authors with nothing to correct it.
    func testReloadFromDiskWithIdenticalContentsStillMovesTheDiskToken() throws {
        let url = try writeTempFile(contents: "unchanged")
        defer { try? FileManager.default.removeItem(at: url) }
        let otherURL = try writeTempFile(contents: "untouched")
        defer { try? FileManager.default.removeItem(at: otherURL) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        _ = try model.open(url: otherURL)
        let before = diskTokens(of: model)

        XCTAssertTrue(model.reloadFromDisk(id: file.id))

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
    }

    /// The no-op guard tests *both* sides of the buffer, not just `text`. A dirty
    /// buffer whose text happens to equal the file on disk — a checkout or a
    /// formatting hook landing on exactly what the user typed — still has a stale
    /// `savedText`, so skipping the reload there would leave the tab permanently
    /// dirty and its disk token permanently behind, with nothing to correct it.
    ///
    /// The two assignments are judged separately, though: the baseline advances
    /// while the *replacement* token stays put, because nothing replaced the
    /// buffer. Bumping it here is the same silent undo-stack loss the conditional
    /// bump exists to prevent — with the file's text unchanged, on screen there is
    /// nothing at all to explain it.
    func testReloadFromDiskAdvancesTheBaselineWhenOnlySavedTextDiffers() throws {
        let url = try writeTempFile(contents: "one")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        // The user typed exactly what a later external write puts on disk.
        model.updateText("two", for: file.id)
        try "two".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.isDirty(for: file.id))
        let diskBefore = diskTokens(of: model)
        let replacementBefore = model.textReplacementRevision(for: file.id)

        XCTAssertTrue(model.reloadFromDisk(id: file.id))

        XCTAssertFalse(model.isDirty(for: file.id))
        XCTAssertEqual(model.text(for: file.id), "two")
        assertDiskRevisions(of: model, changedFor: [file.id], from: diskBefore)
        XCTAssertEqual(model.textReplacementRevision(for: file.id), replacementBefore)
    }

    func testFailedReloadFromDiskLeavesEveryDiskRevisionUntouched() {
        let model = WorkspaceModel(fileService: StubFileService(readError: StubError.boom))
        let urlLess = model.newFile()
        let before = diskTokens(of: model)

        // A url-less buffer is never read...
        XCTAssertFalse(model.reloadFromDisk(id: urlLess.id))
        // ...and neither is an unknown id.
        XCTAssertFalse(model.reloadFromDisk(id: UUID()))

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testFailedDiskReadDuringReloadLeavesEveryDiskRevisionUntouched() throws {
        let url = try writeTempFile(contents: "original")
        let model = WorkspaceModel()
        let file = try model.open(url: url)
        let other = model.newFile()
        let before = diskTokens(of: model)

        // The file is gone, so the read inside `reloadFromDisk` fails and the
        // buffer is left untouched — nothing about it corresponds to new bytes.
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(model.reloadFromDisk(id: file.id))

        assertDiskRevisions(of: model, changedFor: [], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    func testReconcileSavedBaselineChangesOnlyThatFilesDiskRevision() throws {
        let url = try writeTempFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = WorkspaceModel()
        let file = try model.open(url: url)
        let other = model.newFile()
        try "changed by git".write(to: url, atomically: true, encoding: .utf8)
        let before = diskTokens(of: model)

        XCTAssertTrue(model.reconcileSavedBaseline(id: file.id))

        assertDiskRevisions(of: model, changedFor: [file.id], from: before)
        XCTAssertEqual(model.diskRevision(for: other.id), 0)
    }

    func testNoOpReconcileSavedBaselineLeavesEveryDiskRevisionUntouched() {
        let model = WorkspaceModel(fileService: StubFileService())
        let urlLess = model.newFile()
        let before = diskTokens(of: model)

        XCTAssertFalse(model.reconcileSavedBaseline(id: urlLess.id))
        XCTAssertFalse(model.reconcileSavedBaseline(id: UUID()))

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testTypingDoesNotChangeAnyDiskRevision() {
        // The buffer moves; the file on disk does not. This is the whole reason
        // the token is separate from `textReplacementRevisions`.
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        let before = diskTokens(of: model)

        model.updateText("a", for: file.id)
        model.updateText("ab", for: file.id)
        model.replaceText("replaced from outside", for: file.id)

        assertDiskRevisions(of: model, changedFor: [], from: before)
    }

    func testClosingFileDropsItsDiskRevision() {
        let model = WorkspaceModel(fileService: StubFileService())
        let file = model.newFile()
        model.updateText("edited", for: file.id)
        model.markSaved(for: file.id)
        XCTAssertNotEqual(model.diskRevision(for: file.id), 0)

        model.close(id: file.id, force: true)

        // The map must not accumulate entries for tabs that are no longer open.
        XCTAssertNil(model.diskRevisions[file.id])
        XCTAssertEqual(model.diskRevision(for: file.id), 0)
    }

    // MARK: - Session restore

    func testRestoreSessionOpensTabsInOrderAndRestoresSelection() {
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .untitled(text: "scratch"), .file(path: "/p/b.txt")],
            selectedIndex: 2
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["a.txt", "Untitled", "b.txt"])
        XCTAssertEqual(model.openFiles.map(\.text), ["alpha", "scratch", "beta"])
        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)

        // A restored titled tab must be *clean*: `savedText` is the contents just
        // read, so it neither prompts on close nor is rewritten by the first
        // autosave. Only the Untitled buffer comes back dirty (hot exit).
        XCTAssertEqual(model.openFiles.map(\.savedText), ["alpha", "", "beta"])
        XCTAssertEqual(model.openFiles.map(\.isDirty), [false, true, false])
    }

    func testRestoreSessionSelectsTheRecordedTabRatherThanTheLastOne() {
        // Every other selection test happens to expect the tab the *fallback* would
        // also pick, so none of them can tell the recorded-index mapping from
        // `openFiles.last`. Here the recorded selection is the middle record and one
        // earlier record is skipped, so the two answers differ: index 1 names
        // `a.txt` among the *stored* records, which is the first tab restored, while
        // the fallback would land on `b.txt`.
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/gone.txt"), .file(path: "/p/a.txt"), .file(path: "/p/b.txt")],
            selectedIndex: 1
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["a.txt", "b.txt"])
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
        XCTAssertNotEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionSelectsAnUntitledRecordByItsIndex() {
        // The same mapping over an Untitled record, and with a *later* tab present
        // so the fallback would disagree.
        let service = PathContentsFileService(contents: ["/p/b.txt": "beta"])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.untitled(text: "scratch"), .file(path: "/p/b.txt")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["Untitled", "b.txt"])
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
    }

    func testRestoreSessionSkipsUnreadableFileAndKeepsRecordedSelection() {
        // Only `b.txt` exists; the record for the vanished `a.txt` must be skipped
        // silently and the recorded selection (index 1 — an index into the records
        // *as stored*, which the skip does not shift) still land on `b.txt`.
        let service = PathContentsFileService(contents: ["/p/b.txt": "beta"])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .file(path: "/p/b.txt")],
            selectedIndex: 1
        ))

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.openFiles.first?.displayName, "b.txt")
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
    }

    func testRestoreSessionSkipsRecordNamingNeitherPathNorText() {
        // The future-version tab: decoded fine, means nothing to this build, so it
        // is skipped exactly like an unreadable file — including for the selection.
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), SessionTab(), .file(path: "/p/b.txt")],
            selectedIndex: 2
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["a.txt", "b.txt"])
        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionSelectingASkippedRecordFallsBackToLastTab() {
        let service = PathContentsFileService(contents: ["/p/a.txt": "alpha"])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .file(path: "/p/gone.txt")],
            selectedIndex: 1
        ))

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionRestoresUntitledBufferAsDirty() {
        let model = WorkspaceModel(fileService: PathContentsFileService())

        model.restoreSession(EditorSession(tabs: [.untitled(text: "hot exit")], selectedIndex: 0))

        let restored = model.openFiles.first
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertNil(restored?.url)
        XCTAssertEqual(restored?.text, "hot exit")
        XCTAssertEqual(restored?.savedText, "")
        XCTAssertTrue(restored?.isDirty == true)
        XCTAssertEqual(model.selectedID, restored?.id)
    }

    func testRestoreSessionDedupsTwoSpellingsOfOnePath() {
        // Both spellings are readable, so a failure to dedup would open two tabs
        // rather than being masked by the second read throwing.
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/sub/../a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        // `b.txt` trails the duplicate so the fallback (the last tab) is a
        // *different* answer than the dedup hit — without it the assertion below
        // would hold even if the duplicate record mapped to no tab at all.
        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .file(path: "/p/sub/../a.txt"), .file(path: "/p/b.txt")],
            selectedIndex: 1
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["a.txt", "b.txt"])
        // The duplicate record is not "skipped": it resolves to the tab already
        // restored for it, so the selection lands there rather than on a fallback.
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
        XCTAssertNotEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionOutOfRangeSelectionFallsBackToLastTab() {
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .file(path: "/p/b.txt")],
            selectedIndex: 9
        ))

        XCTAssertEqual(model.openFiles.count, 2)
        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionMissingSelectionFallsBackToLastTab() {
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/a.txt"), .file(path: "/p/b.txt")],
            selectedIndex: nil
        ))

        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionEmptySessionIsANoOp() {
        let model = WorkspaceModel(fileService: PathContentsFileService())

        model.restoreSession(EditorSession())

        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.projectRoot)
    }

    func testRestoreSessionWithOnlyUnrestorableRecordsLeavesSelectionUntouched() {
        let model = WorkspaceModel(fileService: PathContentsFileService())
        let scratch = model.newFile()

        let restoredAny = model.restoreSession(
            EditorSession(tabs: [.file(path: "/p/gone.txt")], selectedIndex: 0)
        )

        XCTAssertEqual(model.openFiles.map(\.id), [scratch.id])
        XCTAssertEqual(model.selectedID, scratch.id)
        // What the caller needs in order to describe this in a *stored* session:
        // non-empty tabs are not the question, whether any of them became a tab is.
        XCTAssertFalse(restoredAny)
        XCTAssertFalse(model.restoreSession(EditorSession()))
    }

    func testRestoreSessionReportsThatSomethingRestored() {
        let service = PathContentsFileService(contents: ["/p/a.txt": "alpha"])
        let model = WorkspaceModel(fileService: service)

        XCTAssertTrue(model.restoreSession(EditorSession(
            tabs: [.file(path: "/p/gone.txt"), .file(path: "/p/a.txt")],
            selectedIndex: 0
        )))
        XCTAssertEqual(model.openFiles.map(\.displayName), ["a.txt"])
    }

    func testRestoreSessionKeepsTabsAlreadyOpenAndSelectsTheRestoredOne() {
        // The first Open Folder of a run applies the incoming project's session
        // through `restoreSession` rather than `replaceSession`, precisely so an
        // unsaved Untitled buffer typed before any folder was open is carried into
        // the project instead of being force-closed under the no-folder key — a key
        // launch restore can only reach while it is the catalog's head, which
        // opening a folder takes.
        let service = PathContentsFileService(contents: ["/b/x.txt": "ex"])
        let model = WorkspaceModel(fileService: service)
        let scratch = model.newFile()
        model.updateText("notes typed before any folder was open", for: scratch.id)

        model.restoreSession(EditorSession(
            folderPath: "/b",
            tabs: [.file(path: "/b/x.txt")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["Untitled", "x.txt"])
        XCTAssertEqual(model.openFiles.first?.text, "notes typed before any folder was open")
        XCTAssertTrue(model.openFiles[0].isDirty)
        XCTAssertEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testRestoreSessionLeavesProjectRootUntouched() {
        let service = PathContentsFileService(contents: ["/p/a.txt": "alpha"])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            folderPath: "/p",
            tabs: [.file(path: "/p/a.txt")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertNil(model.projectRoot)
    }

    func testRestoreSessionPrefersThePathOfARecordCarryingBothFields() {
        // `snapshot` never emits such a record, but the permissive decoder accepts
        // one (a hand-edited blob, or a future version that adds `text` to a titled
        // tab), so the precedence is pinned rather than left to read off the code:
        // the path wins and the file's own contents are what the tab shows.
        let service = PathContentsFileService(contents: ["/p/a.txt": "on disk"])
        let model = WorkspaceModel(fileService: service)

        model.restoreSession(EditorSession(
            tabs: [SessionTab(path: "/p/a.txt", text: "from the session")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertEqual(model.openFiles.first?.text, "on disk")
        XCTAssertFalse(model.openFiles.first?.isDirty == true)
    }

    func testSnapshotAndRestoreAgreeOnTheSelectedIndexConvention() {
        // The seam: `snapshot` writes an index into the records it *stored* (past a
        // dropped empty Untitled buffer) and `restoreSession` reads it back the same
        // way. Tested end to end through `SessionStore` so an encoding change cannot
        // silently break the round trip either.
        let service = PathContentsFileService(contents: [
            "/p/a.txt": "alpha",
            "/p/b.txt": "beta"
        ])
        let source = WorkspaceModel(fileService: service)
        _ = try? source.open(url: URL(fileURLWithPath: "/p/a.txt"))
        let dropped = source.newFile() // empty Untitled — not stored
        let kept = source.newFile()
        source.updateText("scratch", for: kept.id)
        _ = try? source.open(url: URL(fileURLWithPath: "/p/b.txt"))
        source.select(kept.id)
        XCTAssertEqual(source.openFiles.count, 4)
        XCTAssertEqual(source.text(for: dropped.id), "")

        let defaults = UserDefaults(suiteName: "session.roundtrip.\(UUID().uuidString)")!
        let store = SessionStore(defaults: defaults)
        store.save(EditorSession.snapshot(
            openFiles: source.openFiles,
            selectedID: source.selectedID,
            projectRoot: nil
        ))
        defer { store.clear() }

        let restored = WorkspaceModel(fileService: service)
        restored.restoreSession(store.loadLastOpened()!)

        XCTAssertEqual(restored.openFiles.map(\.displayName), ["a.txt", "Untitled", "b.txt"])
        XCTAssertEqual(restored.openFiles.map(\.text), ["alpha", "scratch", "beta"])
        // The selected buffer was the *second* stored record, not the last tab.
        XCTAssertEqual(restored.selectedID, restored.openFiles[1].id)
    }

    func testTheCarriedPreFolderTabsAreWhatGetsStoredForTheProject() {
        // The regression this guards: the first Open Folder of a run carries the
        // pre-folder tabs into the project (`restoreSession`, not
        // `replaceSession`), but what the app *promotes* to the catalog head must
        // be the merge, not the incoming entry alone. `noteProjectSwitch` seeds
        // `SessionController.lastWritten` with the post-swap live snapshot, and
        // that marker suppresses every later equal write including the quit-time
        // flush — so an unmerged promotion leaves the carried Untitled buffer on
        // screen, absent from the store, and gone at the next launch. Reproduced
        // here at the Core level: the app's two Core calls in its order, the store
        // in the middle, and a fresh model reading the head back.
        let service = PathContentsFileService(contents: ["/b/x.txt": "ex"])
        let model = WorkspaceModel(fileService: service)
        let scratch = model.newFile()
        model.updateText("notes typed before any folder was open", for: scratch.id)

        // What `openFolder(url:)` does for the `hadFolder == false` branch.
        let folder = URL(fileURLWithPath: "/b")
        model.openFolder(url: folder)
        let incoming = EditorSession(
            folderPath: folder.path,
            tabs: [.file(path: "/b/x.txt")],
            selectedIndex: 0
        )
        let carried = EditorSession.snapshot(
            openFiles: model.openFiles,
            selectedID: model.selectedID,
            projectRoot: folder
        )
        let restoredAny = model.restoreSession(incoming)
        let promoted = EditorSession.merging(
            incoming,
            onto: carried,
            incomingRestoredAny: restoredAny
        )

        let defaults = UserDefaults(suiteName: "session.carried.\(UUID().uuidString)")!
        let store = SessionStore(defaults: defaults)
        defer { store.clear() }
        store.save(promoted)

        // The promoted entry is a superset of the live model — the invariant the
        // suppressed debounce rests on — so the scratch survives being filed.
        let live = EditorSession.snapshot(
            openFiles: model.openFiles,
            selectedID: model.selectedID,
            projectRoot: model.projectRoot
        )
        XCTAssertEqual(promoted, live)
        XCTAssertEqual(store.loadLastOpened(), promoted)
        XCTAssertEqual(store.session(forFolder: folder), promoted)

        let relaunched = WorkspaceModel(fileService: service)
        relaunched.restoreSession(store.loadLastOpened()!)

        XCTAssertEqual(relaunched.openFiles.map(\.displayName), ["Untitled", "x.txt"])
        XCTAssertEqual(relaunched.openFiles.first?.text, "notes typed before any folder was open")
        XCTAssertEqual(relaunched.selectedID, relaunched.openFiles.last?.id)
    }

    func testAnEntirelyUnrestorableProjectSessionDoesNotStealTheCarriedSelection() {
        // Same first-Open-Folder path, with the project's stored tab pointing at a
        // file that is gone. Nothing of it restores, so the selection stays on the
        // carried tab it was on — and the session filed for the project has to
        // record *that*, not the incoming index, or the next launch skips the same
        // record again and falls back to the last carried tab instead.
        let service = PathContentsFileService(contents: ["/elsewhere/n.txt": "en"])
        let model = WorkspaceModel(fileService: service)
        let carriedFile = try! model.open(url: URL(fileURLWithPath: "/elsewhere/n.txt"))
        let scratch = model.newFile()
        model.updateText("notes", for: scratch.id)
        model.select(carriedFile.id)

        let folder = URL(fileURLWithPath: "/b")
        model.openFolder(url: folder)
        let incoming = EditorSession(
            folderPath: folder.path,
            tabs: [.file(path: "/b/gone.txt")],
            selectedIndex: 0
        )
        let carried = EditorSession.snapshot(
            openFiles: model.openFiles,
            selectedID: model.selectedID,
            projectRoot: folder
        )
        let restoredAny = model.restoreSession(incoming)
        let promoted = EditorSession.merging(
            incoming,
            onto: carried,
            incomingRestoredAny: restoredAny
        )

        XCTAssertFalse(restoredAny)
        XCTAssertEqual(model.selectedID, carriedFile.id)
        // The stored record is kept, the selection is the live one.
        XCTAssertEqual(promoted.tabs, carried.tabs + incoming.tabs)
        XCTAssertEqual(promoted.selectedIndex, 0)

        let relaunched = WorkspaceModel(fileService: service)
        relaunched.restoreSession(promoted)

        XCTAssertEqual(relaunched.openFiles.map(\.displayName), ["n.txt", "Untitled"])
        XCTAssertEqual(relaunched.selectedID, relaunched.openFiles.first?.id)
    }

    // MARK: - Project switch (isCurrentProjectRoot / replaceSession)

    func testReplaceSessionDropsTheOutgoingTabsAndOpensTheIncomingOnes() {
        let service = PathContentsFileService(contents: [
            "/a/one.txt": "one",
            "/a/two.txt": "two",
            "/b/x.txt": "ex",
            "/b/y.txt": "why"
        ])
        let model = WorkspaceModel(fileService: service)
        _ = try? model.open(url: URL(fileURLWithPath: "/a/one.txt"))
        _ = try? model.open(url: URL(fileURLWithPath: "/a/two.txt"))

        model.replaceSession(with: EditorSession(
            folderPath: "/b",
            tabs: [.file(path: "/b/x.txt"), .file(path: "/b/y.txt")],
            selectedIndex: 0
        ))

        // Project A's tabs are gone, not appended to.
        XCTAssertEqual(model.openFiles.map(\.displayName), ["x.txt", "y.txt"])
        XCTAssertEqual(model.openFiles.map(\.text), ["ex", "why"])
        // The recorded selection, not the fallback (which would be the last tab).
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
        XCTAssertNotEqual(model.selectedID, model.openFiles.last?.id)
    }

    func testReplaceSessionWithAnEmptySessionEmptiesTheEditor() {
        // A folder opened for the first time has no stored session, so the app
        // hands over an empty one. `restoreSession`'s "an empty session is a no-op"
        // rule must not preserve the outgoing project's tabs or selection here —
        // the force-close half is what makes the swap total.
        let service = PathContentsFileService(contents: ["/a/one.txt": "one"])
        let model = WorkspaceModel(fileService: service)
        _ = try? model.open(url: URL(fileURLWithPath: "/a/one.txt"))
        XCTAssertNotNil(model.selectedID)

        model.replaceSession(with: EditorSession())

        XCTAssertTrue(model.openFiles.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testReplaceSessionForceClosesDirtyTitledAndUntitledTabs() {
        // Both kinds of dirty buffer go, with no `.needsConfirmation` path: the app
        // has already refused the switch if a dirty *titled* buffer failed to flush,
        // and an untitled one traveled into the outgoing snapshot.
        let service = PathContentsFileService(contents: [
            "/a/one.txt": "one",
            "/b/x.txt": "ex"
        ])
        let model = WorkspaceModel(fileService: service)
        let titled = try? model.open(url: URL(fileURLWithPath: "/a/one.txt"))
        model.updateText("edited but never saved", for: titled!.id)
        let untitled = model.newFile()
        model.updateText("scratch", for: untitled.id)
        XCTAssertEqual(model.openFiles.map(\.isDirty), [true, true])

        model.replaceSession(with: EditorSession(
            folderPath: "/b",
            tabs: [.file(path: "/b/x.txt")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["x.txt"])
        XCTAssertFalse(model.openFiles.contains { $0.id == titled?.id || $0.id == untitled.id })
    }

    func testReplaceSessionRestoresAnUntitledRecordDirtyWithItsText() {
        // An untitled scratch buffer is the one thing with nowhere on disk to live,
        // so it travels inside its project's session and must come back editable and
        // dirty — closing it asks for confirmation exactly as before the switch.
        let service = PathContentsFileService(contents: ["/a/one.txt": "one"])
        let model = WorkspaceModel(fileService: service)
        _ = try? model.open(url: URL(fileURLWithPath: "/a/one.txt"))

        model.replaceSession(with: EditorSession(
            folderPath: "/b",
            tabs: [.untitled(text: "notes for B")],
            selectedIndex: 0
        ))

        let restored = model.openFiles.first
        XCTAssertEqual(model.openFiles.count, 1)
        XCTAssertNil(restored?.url)
        XCTAssertEqual(restored?.text, "notes for B")
        XCTAssertTrue(restored?.isDirty == true)
        XCTAssertEqual(model.selectedID, restored?.id)
    }

    func testReplaceSessionSkipsUnreadableRecordsSilently() {
        // Inherited from `restoreSession` verbatim: a file that moved since the
        // incoming project was last open costs its own tab and nothing else.
        let service = PathContentsFileService(contents: ["/b/y.txt": "why"])
        let model = WorkspaceModel(fileService: service)
        _ = model.newFile()

        model.replaceSession(with: EditorSession(
            folderPath: "/b",
            tabs: [.file(path: "/b/gone.txt"), .file(path: "/b/y.txt")],
            selectedIndex: 1
        ))

        XCTAssertEqual(model.openFiles.map(\.displayName), ["y.txt"])
        XCTAssertEqual(model.selectedID, model.openFiles.first?.id)
    }

    func testReplaceSessionLeavesProjectRootUntouched() {
        // The folder half of a switch is the app's job (it has to register the
        // change with the watcher, Local Changes, the Log, …), so the tab half must
        // not move `projectRoot` behind its back.
        let service = PathContentsFileService(contents: ["/b/x.txt": "ex"])
        let model = WorkspaceModel(fileService: service)
        model.openFolder(url: URL(fileURLWithPath: "/a", isDirectory: true))

        model.replaceSession(with: EditorSession(
            folderPath: "/b",
            tabs: [.file(path: "/b/x.txt")],
            selectedIndex: 0
        ))

        XCTAssertEqual(model.projectRoot?.path, "/a")
    }

    func testIsCurrentProjectRootMatchesAcrossSpellingsOfOneFolder() {
        let model = WorkspaceModel(fileService: PathContentsFileService())
        model.openFolder(url: URL(fileURLWithPath: "/tmp", isDirectory: true))

        // Re-opening the folder already open must read as a re-open, not a switch,
        // however the incoming url happens to be spelled: the `/private` symlink,
        // a trailing slash, a `.`/`..` detour.
        XCTAssertTrue(model.isCurrentProjectRoot(URL(fileURLWithPath: "/tmp", isDirectory: true)))
        XCTAssertTrue(model.isCurrentProjectRoot(URL(fileURLWithPath: "/private/tmp")))
        XCTAssertTrue(model.isCurrentProjectRoot(URL(fileURLWithPath: "/tmp/")))
        XCTAssertTrue(model.isCurrentProjectRoot(URL(fileURLWithPath: "/tmp/sub/..")))
    }

    func testIsCurrentProjectRootIsFalseForASiblingDirectory() {
        let model = WorkspaceModel(fileService: PathContentsFileService())
        model.openFolder(url: URL(fileURLWithPath: "/projects/alpha", isDirectory: true))

        XCTAssertFalse(model.isCurrentProjectRoot(URL(fileURLWithPath: "/projects/beta", isDirectory: true)))
        // A prefix relationship is not a match either, in either direction.
        XCTAssertFalse(model.isCurrentProjectRoot(URL(fileURLWithPath: "/projects", isDirectory: true)))
        XCTAssertFalse(model.isCurrentProjectRoot(URL(fileURLWithPath: "/projects/alpha/sub", isDirectory: true)))
    }

    func testIsCurrentProjectRootIsFalseWhenNoFolderIsOpen() {
        // The first Open Folder of a run has to read as a switch, so the incoming
        // project's stored session gets applied rather than skipped.
        let model = WorkspaceModel(fileService: PathContentsFileService())

        XCTAssertNil(model.projectRoot)
        XCTAssertFalse(model.isCurrentProjectRoot(URL(fileURLWithPath: "/projects/alpha", isDirectory: true)))
    }

    // MARK: - Helpers

    /// The current disk-content token of every open file, for the before/after
    /// comparison the `diskRevisions` contract is stated in.
    private func diskTokens(of model: WorkspaceModel) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: model.openFiles.map { ($0.id, model.diskRevision(for: $0.id)) })
    }

    /// Assert the observable `diskRevisions` contract: every id in `changed` has a
    /// token *different* from the one captured in `before`, and every other
    /// captured id's token is unchanged. Deliberately a `!=` comparison — never
    /// `== before + 1` — so a mutator that comes to bump twice by delegating to
    /// another stays green.
    private func assertDiskRevisions(
        of model: WorkspaceModel,
        changedFor changed: Set<UUID>,
        from before: [UUID: Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // An id expected to change that was never captured would otherwise be
        // asserted by nothing at all — the loop below only walks `before` — so the
        // whole call could pass vacuously on a typo or a stale id.
        for id in changed where before[id] == nil {
            XCTFail("expected \(id) to have been captured in the baseline", file: file, line: line)
        }
        for (id, previous) in before {
            let now = model.diskRevision(for: id)
            if changed.contains(id) {
                XCTAssertNotEqual(now, previous, "expected \(id) to record a disk change", file: file, line: line)
            } else {
                XCTAssertEqual(now, previous, "expected \(id) to record no disk change", file: file, line: line)
            }
        }
    }

    private func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private enum StubError: Error, Equatable { case boom }

/// In-memory `FileServicing` for exercising the model's read/write error paths
/// without touching the file system.
private struct StubFileService: FileServicing {
    var readResult = ""
    var readError: Error?
    var writeError: Error?
    var directoryEntries: [DirectoryEntry] = []
    var directoryError: Error?

    func read(url: URL) throws -> String {
        if let readError { throw readError }
        return readResult
    }

    func write(_ text: String, to url: URL) throws {
        if let writeError { throw writeError }
    }

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
        if let directoryError { throw directoryError }
        return directoryEntries
    }

    func isExecutableFile(at url: URL) -> Bool { false }
}

/// In-memory `FileServicing` serving contents **by path**, throwing for a path it
/// does not know — the shape session restore needs, where "this file no longer
/// exists" is the case under test and every other read must still succeed.
private struct PathContentsFileService: FileServicing {
    var contents: [String: String] = [:]

    func read(url: URL) throws -> String {
        guard let text = contents[url.path] else { throw StubError.boom }
        return text
    }

    func write(_ text: String, to url: URL) throws {}

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }

    func isExecutableFile(at url: URL) -> Bool { false }
}

/// In-memory `FileServicing` that records the bytes written per url and can be
/// told to fail the write for specific urls — used to exercise `saveAllDirty()`'s
/// per-file write-failure-skips-and-continues behavior and verify exact contents.
private final class RecordingFileService: FileServicing {
    var readResult = ""
    var failURLs: Set<URL>
    private(set) var written: [URL: String] = [:]

    init(failURLs: Set<URL> = []) {
        self.failURLs = failURLs
    }

    func read(url: URL) throws -> String { readResult }

    func write(_ text: String, to url: URL) throws {
        if failURLs.contains(url) { throw StubError.boom }
        written[url] = text
    }

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }

    func isExecutableFile(at url: URL) -> Bool { false }
}
