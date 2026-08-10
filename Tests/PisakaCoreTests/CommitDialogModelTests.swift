import XCTest
@testable import PisakaCore

@MainActor
final class CommitDialogModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")
    private let otherRoot = URL(fileURLWithPath: "/other")

    // MARK: - Stubs

    /// In-memory `GitServicing` for the commit dialog: canned context/identity/
    /// changed files/`HEAD` blobs, plus recorders for the two mutating calls.
    private final class StubGit: GitServicing {
        var context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: "origin/main",
            remotes: ["origin"],
            inProgress: nil
        )
        var identityValue = CommitIdentity(
            name: "Ada",
            email: "ada@example.com",
            nameSource: .local,
            emailSource: .local
        )
        var headMessageValue: String?
        /// The changed-file list; `changedFilesAnswers` overrides it call by call
        /// (so a staleness test can hand the commit path a different repository
        /// than the load saw).
        var changed: [ChangedFile] = []
        var changedFilesAnswers: [[ChangedFile]] = []
        var changedFilesError: Error?
        /// `HEAD` bytes keyed by repo-relative path; a missing key → `nil`
        /// (absent from `HEAD`, as git's non-zero exit reports).
        var headBlobs: [String: Data] = [:]
        /// Every path `headBlob` was asked for, so a test can assert that a path
        /// the status already answers for (added/untracked) costs no subprocess.
        var headBlobCalls: [String] = []
        /// Runs *inside* the first `changedFiles`, i.e. while a load is suspended
        /// — the deterministic way to land a folder switch mid-load.
        var onFirstChangedFiles: (() async -> Void)?

        /// Overrides `context` call by call, so a test can hand the load, the
        /// pre-commit re-read and the pre-push re-read three different
        /// repositories. Exhausted entries fall back to `context`.
        var contextAnswers: [CommitContext] = []
        /// Runs *inside* `commitContext`, with the 1-based call index — the
        /// deterministic way to land a folder switch in a chosen window (call 1 is
        /// the load's, call 2 the pre-commit re-read's, call 3 the pre-push one's).
        var onCommitContext: ((Int) async -> Void)?
        private var contextCalls = 0

        var repositoryRootError: Error?
        var contextError: Error?
        var commitError: Error?
        var pushError: Error?
        var setIdentityError: Error?

        var committedPlans: [CommitPlan] = []
        var committedMessages: [String] = []
        var committedAmends: [Bool] = []
        var pushedPlans: [PushPlan] = []
        var setIdentityCalls: [[String]] = []
        /// Runs *inside* `commit`, while the model has its running flag raised —
        /// the deterministic way to observe re-entrancy without racing yields.
        var onCommit: (() async -> Void)?
        /// Runs *inside* `setLocalIdentity`, i.e. while the config write is still
        /// in flight — the deterministic way to observe what the gate says in the
        /// window between the author editor's Save and git having written it.
        var onSetIdentity: (() async -> Void)?

        func repositoryRoot(for url: URL) async throws -> URL {
            if let repositoryRootError { throw repositoryRootError }
            return url
        }

        func changedFiles(root: URL) async throws -> [ChangedFile] {
            if let hook = onFirstChangedFiles {
                onFirstChangedFiles = nil
                await hook()
            }
            if let changedFilesError { throw changedFilesError }
            if changedFilesAnswers.isEmpty { return changed }
            return changedFilesAnswers.removeFirst()
        }

        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func headBlob(of path: String, root: URL) async throws -> Data? {
            headBlobCalls.append(path)
            return headBlobs[path]
        }

        func commitContext(root: URL) async throws -> CommitContext {
            contextCalls += 1
            if let onCommitContext { await onCommitContext(contextCalls) }
            if let contextError { throw contextError }
            if contextAnswers.isEmpty { return context }
            return contextAnswers.removeFirst()
        }

        func identity(root: URL) async throws -> CommitIdentity { identityValue }

        func setLocalIdentity(name: String, email: String, root: URL) async throws {
            if let onSetIdentity { await onSetIdentity() }
            if let setIdentityError { throw setIdentityError }
            setIdentityCalls.append([name, email])
            identityValue = CommitIdentity(
                name: name,
                email: email,
                nameSource: .local,
                emailSource: .local
            )
        }

        func headMessage(root: URL) async throws -> String? { headMessageValue }

        func commit(_ plan: CommitPlan, message: String, amend: Bool, root: URL) async throws {
            if let onCommit { await onCommit() }
            if let commitError { throw commitError }
            committedPlans.append(plan)
            committedMessages.append(message)
            committedAmends.append(amend)
        }

        func push(_ plan: PushPlan, root: URL) async throws {
            if let pushError { throw pushError }
            pushedPlans.append(plan)
        }
    }

    /// In-memory `FileServicing`: working-tree text keyed by absolute path.
    private final class StubFiles: FileServicing {
        var contents: [String: String] = [:]
        var symlinks: [String: String] = [:]
        /// Forced failure, so a test can distinguish "unreadable" from "not there".
        var readError: Error?

        func read(url: URL) throws -> String {
            if let readError { throw readError }
            guard let text = contents[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
            return text
        }
        func write(_ text: String, to url: URL) throws { contents[url.path] = text }
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? { symlinks[url.path] }
        func isExecutableFile(at url: URL) -> Bool { false }
    }

    // MARK: - Fixtures

    private let headText = "one\ntwo\n"
    private let worktreeText = "one\nTWO\nthree\n"

    /// One modified text file: row 0 unchanged, row 1 modified, row 2 added —
    /// so units are `[1, 2]`.
    private func makeTextRepo() -> (StubGit, StubFiles) {
        let git = StubGit()
        git.changed = [ChangedFile(path: "a.txt", status: .modified)]
        git.headBlobs = ["a.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        return (git, files)
    }

    private func makeModel(git: StubGit, files: StubFiles) -> CommitDialogModel {
        CommitDialogModel(gitService: git, fileService: files)
    }

    // MARK: - Loading

    func testLoadReadsContextIdentityAndFilesWithEverythingCheckedByDefault() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.root, root)
        XCTAssertEqual(model.context, git.context)
        XCTAssertEqual(model.identity, git.identityValue)
        XCTAssertEqual(model.files.map(\.path), ["a.txt"])
        XCTAssertNil(model.errorMessage)
        // "Everything checked" is the default: a dialog opened and confirmed with
        // no further clicks commits every local change, as JetBrains' does.
        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [1, 2])
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .checked)
        XCTAssertEqual(model.selectedFileCount, 1)
        XCTAssertEqual(model.selectedPath, "a.txt")
    }

    func testLoadBuildsRowsAndUnifiedLinesFromHeadBlobAndWorktree() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "a.txt")?.facts.head, .text(headText))
        XCTAssertEqual(model.selection(for: "a.txt")?.facts.worktree, .text(worktreeText))
        let unified = model.unifiedLines(for: "a.txt")
        XCTAssertEqual(unified.map(\.kind), [.context, .removed, .added, .added])
        XCTAssertEqual(unified.map(\.unitIndex), [nil, 1, 1, 2])
    }

    /// The load yields to the main actor every `loadYieldStride` files, so a set
    /// larger than one stride exercises the chunk boundary: every file must still
    /// be read, in git's order, each with its own facts.
    ///
    /// Untracked files are deliberate — that is the change set whose per-file work
    /// never suspends on its own (no `HEAD` blob to fetch), i.e. the one the yield
    /// exists for, and an initial commit on an unborn HEAD is made of nothing else.
    func testLoadReadsEveryFileAcrossTheYieldStride() async {
        let count = CommitDialogModel.loadYieldStride * 2 + 1
        let git = StubGit()
        let files = StubFiles()
        git.changed = (0..<count).map { ChangedFile(path: "f\($0).txt", status: .untracked) }
        for index in 0..<count {
            files.contents["/repo/f\(index).txt"] = "line \(index)\n"
        }
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.files.map(\.path), (0..<count).map { "f\($0).txt" })
        XCTAssertEqual(model.selectedFileCount, count)
        // Spot-check both sides of a file on either side of each stride boundary,
        // so an off-by-one in the chunking would show up as a mismatched pairing
        // rather than only as a wrong count.
        for index in [0, CommitDialogModel.loadYieldStride, count - 1] {
            let selection = model.selection(for: "f\(index).txt")
            XCTAssertEqual(selection?.facts.head, .absent)
            XCTAssertEqual(selection?.facts.worktree, .text("line \(index)\n"))
        }
    }

    func testLoadFailureClearsStateAndSurfacesTheMessage() async {
        let (git, files) = makeTextRepo()
        git.repositoryRootError = GitError.notARepository(stderr: "fatal: not a git repository")
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.context)
        XCTAssertEqual(model.errorMessage, "fatal: not a git repository")
        XCTAssertEqual(model.block, .noRepository)
    }

    // MARK: - Preselect (the "Commit File" context-menu opening)

    /// Opened from one file's own Commit… item: that file alone starts checked and
    /// every other one starts empty, so confirming immediately commits exactly what
    /// was right-clicked. The right-hand panel shows it too.
    func testPreselectingOnePathChecksOnlyThatFile() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified),
            ChangedFile(path: "c.txt", status: .modified),
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "b.txt": Data(headText.utf8),
            "c.txt": Data(headText.utf8),
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = worktreeText
        files.contents["/repo/c.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "b.txt")

        XCTAssertEqual(model.files.map(\.path), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(model.selectedFiles.map(\.path), ["b.txt"])
        XCTAssertEqual(model.selectedFileCount, 1)
        XCTAssertEqual(model.selection(for: "b.txt")?.selectedUnits, [1, 2])
        XCTAssertEqual(model.checkboxState(for: "b.txt"), .checked)
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .unchecked)
        XCTAssertEqual(model.checkboxState(for: "c.txt"), .unchecked)
        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [])
        XCTAssertFalse(model.selection(for: "a.txt")?.isIncludedInCommit ?? true)
        // The panel shows the file the user asked to commit, not merely the first
        // row of the list.
        XCTAssertEqual(model.selectedPath, "b.txt")
        // And the plan agrees, by construction — `isIncludedInCommit` is the one
        // rule both it and `selectedFileCount` read.
        XCTAssertEqual(
            CommitPlan.build(selections: model.files).entries,
            [.addFromWorktree(path: "b.txt")]
        )
    }

    /// A whole-only file (no units at all) preselects through its file-level
    /// checkbox, which is the only signal it has: two-state `.checked`, never mixed,
    /// and an entry in the plan.
    func testPreselectingAWholeOnlyFileChecksItWholly() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "gone.txt", status: .deleted),
        ]
        git.headBlobs = ["a.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "gone.txt")

        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.units, [])
        XCTAssertEqual(model.checkboxState(for: "gone.txt"), .checked)
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .unchecked)
        XCTAssertEqual(model.selectedFileCount, 1)
        XCTAssertEqual(model.selectedPath, "gone.txt")
        XCTAssertEqual(
            CommitPlan.build(selections: model.files).entries,
            [.removePath(path: "gone.txt")]
        )
    }

    /// A rename is preselected by its **new** path — the value the Local Changes row
    /// carries and the key the rest of the pipeline indexes by.
    func testPreselectingARenamedFileMatchesItsNewPath() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "new.txt", status: .renamed, oldPath: "old.txt"),
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "old.txt": Data(headText.utf8),
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/new.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "new.txt")

        XCTAssertEqual(model.selectedFiles.map(\.path), ["new.txt"])
        XCTAssertEqual(model.checkboxState(for: "new.txt"), .checked)
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .unchecked)
        XCTAssertEqual(model.selectedPath, "new.txt")
        // …and by the new path *only*. The old path names a file that no longer
        // exists; matching it too would let a delete-and-recreate pair (an
        // untracked `old.txt` back beside the rename) preselect a file the user
        // never right-clicked.
        let byOldPath = makeModel(git: git, files: files)
        await byOldPath.load(root: root, preselectedPath: "old.txt")
        XCTAssertEqual(byOldPath.selectedFileCount, 0)
        XCTAssertEqual(byOldPath.checkboxState(for: "new.txt"), .unchecked)
        // The old path is still removed first — a preselect changes which files are
        // in the plan, never how one of them is expressed.
        XCTAssertEqual(
            CommitPlan.build(selections: model.files).entries,
            [.removePath(path: "old.txt"), .addFromWorktree(path: "new.txt")]
        )
    }

    /// The row was reverted, committed elsewhere or renamed again between the
    /// right-click and the dialog's own `git status`. Nothing is selected — the
    /// honest outcome, blocked with `.nothingSelected` — rather than falling back to
    /// selecting everything, which would answer "commit this file" by arming a
    /// commit of all of them.
    func testPreselectingAVanishedPathSelectsNothingAndBlocks() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "vanished.txt")
        model.message = "a message"

        XCTAssertEqual(model.files.map(\.path), ["a.txt"])
        XCTAssertEqual(model.selectedFileCount, 0)
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .unchecked)
        // The identity is complete and the message non-empty, so the gate reaches
        // the selection check rather than stopping at an earlier one.
        XCTAssertEqual(model.block, .nothingSelected)
        // No file to show it, so the panel falls back to the first row.
        XCTAssertEqual(model.selectedPath, "a.txt")
        XCTAssertTrue(CommitPlan.build(selections: model.files).entries.isEmpty)
    }

    /// …and it says so. Unselected *and silent* would read as the preselect having
    /// been ignored: with the message field still empty the gate answers
    /// `.emptyMessage`, so `.nothingSelected` is not even the sentence on screen
    /// until the user has typed one, and nothing would ever name the missing file.
    func testAVanishedPreselectPathIsNamedInTheErrorMessage() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "vanished.txt")

        XCTAssertEqual(
            model.errorMessage,
            CommitDialogModel.vanishedPreselectMessage(path: "vanished.txt")
        )
        XCTAssertTrue(model.errorMessage?.contains("vanished.txt") ?? false)
        // The gate's own first answer, which the notice is there to precede.
        XCTAssertEqual(model.block, .emptyMessage)
        // And it is an ordinary stale error: the first keystroke retires it and the
        // live reason takes over.
        model.message = "a message"
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.block, .nothingSelected)
    }

    /// The end of the preselect's own path: what was right-clicked is what git is
    /// asked to commit. `commit()` does not read `files` directly — it plans from
    /// `selectedFiles`, filters the *fresh* change list down to the planned paths
    /// and rebuilds each selection onto fresh facts through `withFacts` — so the
    /// single-planned-path shape is asserted here rather than inferred from
    /// `CommitPlan.build(selections:)` over the loaded list.
    func testPreselectedFileIsTheOnlyOneCommitted() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified),
            ChangedFile(path: "c.txt", status: .modified),
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "b.txt": Data(headText.utf8),
            "c.txt": Data(headText.utf8),
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = worktreeText
        files.contents["/repo/c.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "b.txt")
        git.headBlobCalls = []
        model.message = "only b"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertEqual(git.committedPlans[0].entries, [.addFromWorktree(path: "b.txt")])
        // The pre-commit re-diff covers the planned file alone: the other two are
        // still in the fresh `changedFiles` list, just not part of this commit.
        XCTAssertEqual(git.headBlobCalls, ["b.txt"])
    }

    /// A preselect belongs to the opening that asked for it: reopening the dialog
    /// with none (⌘K, the header button) must go back to checking everything, or a
    /// Commit… → Cancel → ⌘K sequence would silently arm a commit of one file.
    func testReopeningWithoutAPreselectChecksEverythingAgain() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified),
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "b.txt": Data(headText.utf8),
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root, preselectedPath: "b.txt")
        XCTAssertEqual(model.selectedFileCount, 1)

        await model.load(root: root)

        XCTAssertEqual(model.selectedFileCount, 2)
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .checked)
        XCTAssertEqual(model.checkboxState(for: "b.txt"), .checked)
        XCTAssertEqual(model.selectedPath, "a.txt")
    }

    /// The regression this whole `headBlob` path exists for: a file that is binary
    /// in `HEAD` and text in the worktree must arrive as whole-only with no units,
    /// not as "wholly added" with selectable lines over a falsely empty old side.
    func testFileBinaryInHeadArrivesWholeOnlyWithNoUnits() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "b.bin", status: .modified)]
        git.headBlobs = ["b.bin": Data([0x00, 0x01, 0x02])]
        let files = StubFiles()
        files.contents["/repo/b.bin"] = "now I am text\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        let selection = model.selection(for: "b.bin")
        XCTAssertEqual(selection?.facts.head, .binary)
        XCTAssertEqual(selection?.facts.eligibility, .wholeOnly(reason: .binaryInHead))
        XCTAssertEqual(selection?.facts.units, [])
        XCTAssertTrue(model.unifiedLines(for: "b.bin").isEmpty)
        // A whole-only file's checkbox is an ordinary two-state one — never mixed.
        XCTAssertEqual(model.checkboxState(for: "b.bin"), .checked)
        XCTAssertEqual(model.selectedFileCount, 1)
    }

    /// The dialog's right-hand panel asks exactly one question — "is there a
    /// sentence to draw instead of a diff?" — and all three whole-only categories
    /// answer it here, so the view never has to re-derive the rule.
    func testWholeOnlyMessageCoversAllThreeCategoriesAndIsAbsentForASelectableFile() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.bin", status: .modified),
            ChangedFile(path: "gone.txt", status: .deleted),
            ChangedFile(path: "crlf.txt", status: .modified),
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "b.bin": Data([0x00, 0x01]),
            "gone.txt": Data("bye\n".utf8),
            "crlf.txt": Data("a\r\nb\r\n".utf8),
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.bin"] = "now I am text\n"
        files.contents["/repo/crlf.txt"] = "a\nb\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertNil(model.wholeOnlyMessage(for: "a.txt"))
        XCTAssertEqual(model.wholeOnlyMessage(for: "b.bin"), WholeOnlyReason.binaryInHead.message)
        XCTAssertEqual(model.wholeOnlyMessage(for: "gone.txt"), WholeOnlyReason.deleted.message)
        // Selectable, with rows the panel *could* draw — and not one of them is a
        // unit, which is exactly why the placeholder wins. Since the panel draws
        // the sentence and nothing else, no line is flattened for it at all.
        XCTAssertEqual(model.selection(for: "crlf.txt")?.facts.eligibility, .selectable)
        XCTAssertFalse(model.selection(for: "crlf.txt")?.facts.rows.isEmpty ?? true)
        XCTAssertEqual(model.selection(for: "crlf.txt")?.facts.units, [])
        XCTAssertTrue(model.unifiedLines(for: "crlf.txt").isEmpty)
        XCTAssertEqual(
            model.wholeOnlyMessage(for: "crlf.txt"),
            WholeOnlyReason.noSelectableChanges.message
        )
        // An unknown path names no file, so there is nothing to say about it.
        XCTAssertNil(model.wholeOnlyMessage(for: "nope.txt"))
    }

    func testDeletedFileHasNoWorktreeSideAndNoUnits() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "gone.txt", status: .deleted)]
        git.headBlobs = ["gone.txt": Data("bye\n".utf8)]
        let model = makeModel(git: git, files: StubFiles())

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.worktree, .absent)
        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.eligibility, .wholeOnly(reason: .deleted))
        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.units, [])
    }

    /// A deleted file's `HEAD` side is never asked for. It certainly exists there,
    /// but nothing reads it: `classify` decides `.wholeOnly(.deleted)` from the
    /// status before looking, so no units are handed out and no rows are diffed,
    /// and `CommitPlan.build` emits `.removePath` without touching either side.
    /// Asking anyway spent a `git show HEAD:<path>` subprocess per deleted file at
    /// open *and* again in the pre-commit re-read — 800 of them for a `git rm -r`
    /// of a 400-file directory — each result decoded and then retained for the life
    /// of the dialog.
    func testDeletedFileNeverQueriesItsHeadBlob() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "gone.txt", status: .deleted)]
        git.headBlobs = ["gone.txt": Data("bye\n".utf8)]
        let model = makeModel(git: git, files: StubFiles())

        await model.load(root: root)

        XCTAssertEqual(git.headBlobCalls, [])
        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.head, .absent)
        // The plan is unchanged by the side never being read: still a removal.
        XCTAssertEqual(
            CommitPlan.build(selections: model.files).entries,
            [.removePath(path: "gone.txt")]
        )
    }

    /// The pre-commit re-read re-reads the whole change *list* — a file that became
    /// conflicted since is not in the plan and would otherwise be invisible to the
    /// repository-state re-check — but only re-diffs the files the commit actually
    /// includes. Reading both sides and running an LCS over an *unchecked* file
    /// produced facts nothing consumes: `CommitStaleness.check` and the `withFacts`
    /// rebuild under it both look up planned paths alone.
    func testPreCommitReReadSkipsFilesTheCommitDoesNotInclude() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified),
        ]
        git.headBlobs = ["a.txt": Data(headText.utf8), "b.txt": Data("x\n".utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = "y\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)
        XCTAssertEqual(git.headBlobCalls, ["a.txt", "b.txt"])

        model.toggleFile(path: "b.txt")
        XCTAssertFalse(model.selection(for: "b.txt")!.isIncludedInCommit)
        git.headBlobCalls = []
        model.message = "only a"

        let outcome = await model.commit()
        XCTAssertEqual(outcome, .committed)

        // Re-read for the included file only — `b.txt` is still in the fresh
        // `changedFiles` list, just not re-diffed.
        XCTAssertEqual(git.headBlobCalls, ["a.txt"])
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertEqual(git.committedPlans[0].entries, [.addFromWorktree(path: "a.txt")])
    }

    /// A file that changed on disk while *unchecked* must not abort the batch: the
    /// commit does not include it, so nothing it could invalidate is in the plan.
    /// This is the property that makes scoping the re-diff to the planned files
    /// safe rather than merely cheaper.
    func testUncheckedFileChangingOnDiskDoesNotAbortTheCommit() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified),
        ]
        git.headBlobs = ["a.txt": Data(headText.utf8), "b.txt": Data("x\n".utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = "y\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)
        model.toggleFile(path: "b.txt")
        model.message = "only a"

        // `b.txt` is rewritten under the dialog, and its status flips too.
        files.contents["/repo/b.txt"] = "something else entirely\n"
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .added),
        ]

        let outcome = await model.commit()
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedPlans[0].entries, [.addFromWorktree(path: "a.txt")])
    }

    // MARK: - Toggling

    func testToggleFileUnchecksEverythingAndBack() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.toggleFile(path: "a.txt")
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .unchecked)
        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [])
        XCTAssertEqual(model.selectedFileCount, 0)

        model.toggleFile(path: "a.txt")
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .checked)
        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [1, 2])
    }

    func testToggleUnitProducesMixedState() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.toggleUnit(1, path: "a.txt")

        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [2])
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .mixed)
        // A partially checked file still counts as one selected file.
        XCTAssertEqual(model.selectedFileCount, 1)
    }

    func testTogglingAMixedFileChecksItWholeRatherThanClearingIt() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.toggleUnit(1, path: "a.txt")

        model.toggleFile(path: "a.txt")

        XCTAssertEqual(model.checkboxState(for: "a.txt"), .checked)
        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [1, 2])
    }

    func testToggleUnitIgnoresAnIndexThatIsNotAUnit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.toggleUnit(0, path: "a.txt")      // a context row
        model.toggleUnit(99, path: "a.txt")     // out of range
        model.toggleUnit(1, path: "nope.txt")   // unknown file

        XCTAssertEqual(model.selection(for: "a.txt")?.selectedUnits, [1, 2])
    }

    func testToggleFileOnAWholeOnlyFileIsTwoState() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "b.bin", status: .modified)]
        git.headBlobs = ["b.bin": Data([0x00])]
        let files = StubFiles()
        files.contents["/repo/b.bin"] = "text\n"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.toggleFile(path: "b.bin")
        XCTAssertEqual(model.checkboxState(for: "b.bin"), .unchecked)
        XCTAssertEqual(model.selectedFileCount, 0)

        model.toggleFile(path: "b.bin")
        XCTAssertEqual(model.checkboxState(for: "b.bin"), .checked)
    }

    // MARK: - Amend and the message field

    func testAmendFillsAnEmptyMessageWithTheHeadMessage() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.setAmend(true)

        XCTAssertTrue(model.amend)
        XCTAssertEqual(model.message, "previous subject")
    }

    func testAmendFillsAWhitespaceOnlyMessage() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "   \n\t "

        model.setAmend(true)

        XCTAssertEqual(model.message, "previous subject")
    }

    func testAmendLeavesNonEmptyUserTextAlone() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "my own message"

        model.setAmend(true)

        XCTAssertEqual(model.message, "my own message")
    }

    func testTurningAmendOffRestoresThePreviousTextWhenTheFieldIsStillTheInsertedOne() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "  "

        model.setAmend(true)
        XCTAssertEqual(model.message, "previous subject")
        model.setAmend(false)

        XCTAssertFalse(model.amend)
        XCTAssertEqual(model.message, "  ")
    }

    func testTurningAmendOffKeepsAnEditedMessage() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.setAmend(true)
        model.message = "previous subject, edited"
        model.setAmend(false)

        // The user made it theirs — restoring the pre-amend text would delete work.
        XCTAssertEqual(model.message, "previous subject, edited")
    }

    func testAmendWithNoHeadMessageLeavesTheFieldEmpty() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = nil
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.setAmend(true)
        model.setAmend(false)

        XCTAssertEqual(model.message, "")
    }

    func testAmendAllowsAnEmptyFileSelectionButANonAmendCommitDoesNot() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.toggleFile(path: "a.txt")

        XCTAssertEqual(model.block, .nothingSelected)
        model.setAmend(true)
        XCTAssertNil(model.block)
        XCTAssertTrue(model.canCommit)
    }

    /// And it actually runs: an empty plan reaches git as an amend rather than
    /// being short-circuited or aborted on the way. This is the case ⌘K's
    /// enablement rule was deliberately widened for — a clean tree is exactly when
    /// a message-only amend is wanted — so the whole empty-plan path
    /// (`loadFacts([])` → `CommitStaleness.check([], [])` → `build([])`) has to
    /// carry it.
    func testAMessageOnlyAmendCommitsAnEmptyPlan() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.toggleFile(path: "a.txt")
        model.setAmend(true)
        model.message = "reworded subject"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedPlans, [CommitPlan(entries: [])])
        XCTAssertEqual(git.committedMessages, ["reworded subject"])
        XCTAssertEqual(git.committedAmends, [true])
    }

    // MARK: - The unified-diff memo

    /// The memo must return the *same* answer a fresh flatten would, on the hit
    /// path as well as the miss path. `UnifiedDiffLine.unitIndex` is what a
    /// checkbox toggles, so a stale answer means checking one line and committing
    /// another — silently, into history.
    func testUnifiedLinesAreStableAcrossRepeatedReadsAndSelectionChanges() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        let expected = CommitDiffUnits.unified(
            rows: model.selection(for: "a.txt")?.rows ?? []
        )
        XCTAssertFalse(expected.isEmpty)

        // Miss, then hit: a second read of the same path takes the cached branch.
        XCTAssertEqual(model.unifiedLines(for: "a.txt"), expected)
        XCTAssertEqual(model.unifiedLines(for: "a.txt"), expected)

        // A selection change rebuilds the element but cannot change its rows, so
        // the answer must survive it — that is the exemption `preservingUnifiedCache`
        // claims, and this is what holds it to it.
        model.toggleUnit(1, path: "a.txt")
        XCTAssertEqual(model.unifiedLines(for: "a.txt"), expected)
        model.toggleFile(path: "a.txt")
        XCTAssertEqual(model.unifiedLines(for: "a.txt"), expected)
    }

    /// And it is dropped when the rows really do change: a reload of the same path
    /// against different content must not serve the previous read's lines.
    func testUnifiedLinesAreRecomputedAfterAReloadChangesTheRows() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        let first = model.unifiedLines(for: "a.txt")

        files.contents["/repo/a.txt"] = "one\ntwo\nthree\nfour\n"
        await model.load(root: root)
        let second = model.unifiedLines(for: "a.txt")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            second,
            CommitDiffUnits.unified(rows: model.selection(for: "a.txt")?.rows ?? [])
        )
    }

    // MARK: - Gate and push plan wiring

    func testBlockReportsTheGatesReasons() async {
        let (git, files) = makeTextRepo()
        git.identityValue = CommitIdentity(
            name: "",
            email: "",
            nameSource: .unset,
            emailSource: .unset
        )
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        XCTAssertEqual(model.block, .identityIncomplete)
        XCTAssertFalse(model.canCommit)
    }

    func testEmptyMessageBlocksTheCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        XCTAssertEqual(model.block, .emptyMessage)
        model.message = "subject"
        XCTAssertNil(model.block)
    }

    func testPushPlanComesFromTheContext() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        XCTAssertEqual(model.pushPlan, .push(upstream: "origin/main"))
    }

    // MARK: - commit()

    func testSuccessfulCommitBuildsThePlanAndClearsTheMessage() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedMessages, ["subject"])
        XCTAssertEqual(git.committedAmends, [false])
        // Everything is checked, so the file is added from the worktree rather
        // than assembled — the structural "everything selected = worktree" rule.
        XCTAssertEqual(git.committedPlans, [CommitPlan(entries: [.addFromWorktree(path: "a.txt")])])
        XCTAssertEqual(model.message, "")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRunning)
    }

    func testPartialCommitAssemblesContentFromTheSelectedUnits() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.toggleUnit(2, path: "a.txt")   // keep only the modified line

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(
            git.committedPlans,
            [CommitPlan(entries: [
                .addContent(
                    path: "a.txt",
                    content: "one\nTWO\n",
                    modeSource: .head(path: "a.txt")
                )
            ])]
        )
    }

    func testCommitWhileBlockedDoesNothing() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)   // message still empty

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .blocked(.emptyMessage))
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    func testStaleSnapshotAbortsTheWholeBatchAndWritesNothing() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified)
        ]
        git.headBlobs = [
            "a.txt": Data(headText.utf8),
            "b.txt": Data("x\n".utf8)
        ]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = "y\n"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        // Somebody rewrote b.txt from outside the app after the dialog loaded it.
        files.contents["/repo/b.txt"] = "z\nand more\n"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .stale(.diffChanged(path: "b.txt")))
        XCTAssertTrue(git.committedPlans.isEmpty)
        XCTAssertEqual(model.errorMessage, CommitStaleReason.diffChanged(path: "b.txt").message)
        // Nothing was consumed from the dialog: the message survives for a retry.
        XCTAssertEqual(model.message, "subject")
    }

    func testAFileThatVanishedFromTheChangeListAbortsTheBatch() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        git.changed = []   // committed from the terminal in the meantime

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .stale(.vanished(path: "a.txt")))
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    func testAnUncheckedFileIsNotStalenessCheckedAndDoesNotBlockTheBatch() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "b.txt", status: .modified)
        ]
        git.headBlobs = ["a.txt": Data(headText.utf8), "b.txt": Data("x\n".utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        files.contents["/repo/b.txt"] = "y\n"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.toggleFile(path: "b.txt")      // not part of this commit
        files.contents["/repo/b.txt"] = "changed underneath\n"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedPlans, [CommitPlan(entries: [.addFromWorktree(path: "a.txt")])])
    }

    func testFailedCommitSurfacesStderrVerbatimAndLeavesStateAsIs() async {
        let (git, files) = makeTextRepo()
        let stderr = "pre-commit hook failed:\na.txt: 2 lint errors"
        git.commitError = GitError.commitFailed(reason: stderr)
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .failed(reason: stderr))
        XCTAssertEqual(model.errorMessage, stderr)
        XCTAssertEqual(model.message, "subject")
        XCTAssertEqual(model.checkboxState(for: "a.txt"), .checked)
        XCTAssertFalse(model.isRunning)
    }

    func testPushIsSkippedUnlessRequested() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        _ = await model.commit()

        XCTAssertTrue(git.pushedPlans.isEmpty)
    }

    func testPushAfterCommitRunsThePlan() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.pushedPlans, [.push(upstream: "origin/main")])
    }

    /// "Push after commit" is pinned at entry with the message, the amend flag and
    /// the file selection — not re-read once the commit returns. The commit is the
    /// long part (hooks, signing), so a tick landing in that window would otherwise
    /// publish to a remote the user had not armed when they pressed Commit.
    func testPushIsDecidedByTheFlagPinnedWhenCommitWasPressed() async {
        for (name, armedAtEntry) in [("armed", true), ("disarmed", false)] {
            let (git, files) = makeTextRepo()
            let model = makeModel(git: git, files: files)
            await model.load(root: root)
            model.message = "subject"
            model.pushAfterCommit = armedAtEntry
            // Flip it *inside* the commit, i.e. exactly while `isRunning` is up.
            git.onCommit = { @MainActor [weak model] in
                model?.pushAfterCommit = !armedAtEntry
            }

            _ = await model.commit()

            XCTAssertEqual(git.pushedPlans.isEmpty, !armedAtEntry, name)
        }
    }

    func testPushFailureAfterASuccessfulCommitIsItsOwnState() async {
        let (git, files) = makeTextRepo()
        let stderr = "fatal: unable to access 'https://example.com/r.git/': timed out"
        git.pushError = GitError.pushFailed(reason: stderr)
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        let outcome = await model.commit()

        // The commit is not lost and must not be retried as a commit.
        XCTAssertEqual(outcome, .committedPushFailed(reason: stderr))
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertEqual(model.errorMessage, stderr)
        XCTAssertEqual(model.message, "")
    }

    /// An unavailable plan does not push — and says so. A push the user asked for
    /// is never skipped silently: reporting `.committed` there would claim the
    /// whole gesture succeeded while half of it never ran.
    func testAnUnavailablePlanReportsTheCommitAndTheUnpushedBranch() async {
        let (git, files) = makeTextRepo()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: true,
            currentBranch: nil,
            upstream: nil,
            remotes: [],
            inProgress: nil
        )
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        let outcome = await model.commit()

        XCTAssertEqual(
            outcome,
            .committedPushFailed(reason: PushUnavailableReason.detachedHEAD.message)
        )
        XCTAssertEqual(model.errorMessage, PushUnavailableReason.detachedHEAD.message)
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertTrue(git.pushedPlans.isEmpty)
    }

    /// The push runs the plan derived from the context read *at commit time*, not
    /// the one the checkbox was drawn from at load. A `git checkout` in the
    /// embedded terminal while the sheet is up leaves the load-time plan naming
    /// the previous branch — and `.setUpstream` spells that name out, so the push
    /// would create a tracking ref for, and push, a branch the new commit is not
    /// on, while the commit itself stayed unpushed.
    func testPushUsesTheBranchReadAtCommitTimeNotAtLoad() async {
        let (git, files) = makeTextRepo()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true
        XCTAssertEqual(model.pushPlan, .setUpstream(remote: "origin", branch: "main"))

        // A checkout lands in the terminal while the sheet sits open.
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "feature",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.pushedPlans, [.setUpstream(remote: "origin", branch: "feature")])
    }

    /// The same rule the other way: a branch that gained an upstream since the
    /// load takes the plain-push branch, rather than re-running `--set-upstream`
    /// against a tracking ref that already exists.
    func testPushUsesTheUpstreamReadAtCommitTimeNotAtLoad() async {
        let (git, files) = makeTextRepo()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: "origin/main",
            remotes: ["origin"],
            inProgress: nil
        )

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.pushedPlans, [.push(upstream: "origin/main")])
    }

    /// A checkout landing *between* the commit and the push — the window the commit
    /// itself opens, since hooks and signing take seconds. Pushing then would
    /// publish, and set a tracking ref on, a branch that did not receive this
    /// commit, while the commit stayed unpushed under a success message.
    func testABranchThatMovedBetweenTheCommitAndThePushRefusesThePush() async {
        let (git, files) = makeTextRepo()
        let onMain = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let onFeature = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "feature",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        // Call 1 the load, call 2 the pre-commit re-read, call 3 the pre-push one.
        git.contextAnswers = [onMain, onMain, onFeature]
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        let outcome = await model.commit()

        XCTAssertEqual(
            outcome,
            .committedPushFailed(reason: PushUnavailableReason.branchChanged.message)
        )
        XCTAssertEqual(model.errorMessage, PushUnavailableReason.branchChanged.message)
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertTrue(git.pushedPlans.isEmpty)
    }

    /// The sibling case: the branch is still the one the push was decided for, but
    /// pushing it stopped being possible (a remote removed while the commit ran).
    /// Same reporting rule — the commit exists, the push did not happen, say which.
    func testAPlanThatBecameUnavailableBetweenTheCommitAndThePushIsReported() async {
        let (git, files) = makeTextRepo()
        let withRemote = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let withoutRemote = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: nil,
            remotes: [],
            inProgress: nil
        )
        git.contextAnswers = [withRemote, withRemote, withoutRemote]
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.pushAfterCommit = true

        let outcome = await model.commit()

        XCTAssertEqual(
            outcome,
            .committedPushFailed(reason: PushUnavailableReason.noRemote.message)
        )
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertTrue(git.pushedPlans.isEmpty)
    }

    /// A folder switch landing during the pre-commit re-read stops the commit
    /// before git is called. `.abandoned` is the contract the app branches on —
    /// "nothing ran" — so a commit composed for one repository can never be
    /// applied to the one that replaced it.
    func testAFolderSwitchDuringThePreCommitReReadAbandonsTheCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        // Call 2 is the pre-commit re-read; the switch commits inside it, so the
        // guard that follows `loadFacts` sees a superseded generation.
        git.onCommitContext = { [weak model] call in
            guard call == 2 else { return }
            _ = model?.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        }

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .abandoned)
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    /// The same guard on the failure path: a re-read that *throws* while the
    /// project is being switched must not publish the old repository's error over
    /// the new one's freshly cleared state.
    func testAFolderSwitchDuringAFailedPreCommitReReadAbandonsTheCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        git.onCommitContext = { [weak model] call in
            guard call == 2 else { return }
            _ = model?.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
            git.contextError = GitError.gitUnavailable
        }

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .abandoned)
        XCTAssertTrue(git.committedPlans.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testAmendIsPassedThroughAndClearedAfterASuccessfulCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.setAmend(true)

        _ = await model.commit()

        XCTAssertEqual(git.committedAmends, [true])
        XCTAssertFalse(model.amend)
    }

    /// Amend rewrites whatever `HEAD` is when git runs, so the commit it replaces
    /// has to be pinned like the files are. Nothing else catches this: the file
    /// facts are untouched by someone else committing, and every other
    /// `CommitContext` field describes a shape an ordinary `git commit` leaves
    /// exactly as it was — so without the hash the amend silently rewrote a commit
    /// the user had never seen, under the message of the one they had.
    func testAmendRefusesWhenHeadMovedBetweenTheLoadAndTheCommit() async {
        let (git, files) = makeTextRepo()
        git.context = Self.context(headHash: "aaa111")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        model.setAmend(true)

        // Someone commits in the embedded terminal while the sheet is up.
        git.context = Self.context(headHash: "bbb222")
        let outcome = await model.commit()

        XCTAssertEqual(outcome, .stale(.headMoved))
        XCTAssertTrue(git.committedPlans.isEmpty)
        XCTAssertEqual(model.errorMessage, CommitStaleReason.headMoved.message)
    }

    /// The same movement is *not* a refusal for an ordinary commit: there a moved
    /// HEAD is simply the new parent, which is what should happen.
    func testAMovedHeadDoesNotBlockANonAmendCommit() async {
        let (git, files) = makeTextRepo()
        git.context = Self.context(headHash: "aaa111")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        git.context = Self.context(headHash: "bbb222")
        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedAmends, [false])
    }

    private static func context(headHash: String?) -> CommitContext {
        CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: "origin/main",
            remotes: ["origin"],
            inProgress: nil,
            headHash: headHash
        )
    }

    // MARK: - A missing working file

    /// Porcelain `AD` — staged with `git add`, then deleted from the worktree —
    /// maps to `.added` (`GitStatusParser` tests `A` before `D`), so the file has no
    /// working copy despite a status that is not `.deleted`. Read as `.binary` it
    /// was described as "binary, unreadable, or very large" and, having no units,
    /// reached the executor as `.addFromWorktree` — `git update-index --add` on a
    /// path with no file, which exits 128 and, the plan being atomic, aborted the
    /// **whole** commit including every other valid file.
    func testStagedThenDeletedFileIsPlannedAsARemovalRatherThanAbortingTheBatch() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "gone.txt", status: .added),
            ChangedFile(path: "a.txt", status: .modified),
        ]
        git.headBlobs = ["a.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.contents["/repo/a.txt"] = worktreeText
        // No entry for /repo/gone.txt: the stub throws `fileReadNoSuchFile`.
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        let gone = model.files.first { $0.path == "gone.txt" }
        XCTAssertEqual(gone?.facts.worktree, .absent)
        XCTAssertEqual(gone?.facts.eligibility, .wholeOnly(reason: .deleted))
        XCTAssertEqual(model.wholeOnlyMessage(for: "gone.txt"), WholeOnlyReason.deleted.message)

        model.message = "subject"
        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        let entries = git.committedPlans.first?.entries
        XCTAssertEqual(entries?.first, .removePath(path: "gone.txt"))
        // The other file is unaffected — the point of the fix is that one missing
        // working copy no longer takes the batch down with it.
        XCTAssertTrue(entries?.contains(.addFromWorktree(path: "a.txt")) ?? false)
    }

    /// A `.deleted` status decides the side on its own, *before* anything is read.
    /// A file recreated between the status snapshot and the read would otherwise be
    /// diffed as an ordinary modification and `CommitPlan.build` would stop
    /// emitting the removal the status asked for.
    func testADeletedFileIsAbsentEvenWhenAWorkingCopyExists() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "gone.txt", status: .deleted)]
        git.headBlobs = ["gone.txt": Data(headText.utf8)]
        let files = StubFiles()
        // The file is back on disk — recreated out of band since the snapshot.
        files.contents["/repo/gone.txt"] = "recreated\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.worktree, .absent)
        XCTAssertEqual(
            model.selection(for: "gone.txt")?.facts.eligibility,
            .wholeOnly(reason: .deleted)
        )
        XCTAssertEqual(model.selection(for: "gone.txt")?.facts.units, [])

        model.message = "subject"
        _ = await model.commit()

        XCTAssertEqual(
            git.committedPlans.first?.entries,
            [.removePath(path: "gone.txt")]
        )
    }

    /// "Absent" and "unreadable" are different facts and only the first may be
    /// committed as a deletion: reading a permission error as absence would remove
    /// a file the user never asked to remove. Both Cocoa spellings of "no such
    /// file" count; any other domain does not.
    func testOnlyANoSuchFileErrorIsReadAsAbsence() async {
        let cases: [(String, Error, BlobText)] = [
            ("fileReadNoSuchFile", CocoaError(.fileReadNoSuchFile), .absent),
            ("fileNoSuchFile", CocoaError(.fileNoSuchFile), .absent),
            ("fileReadNoPermission", CocoaError(.fileReadNoPermission), .binary),
            ("posix", NSError(domain: NSPOSIXErrorDomain, code: 2), .binary),
        ]
        for (name, error, expected) in cases {
            let git = StubGit()
            git.changed = [ChangedFile(path: "a.txt", status: .modified)]
            git.headBlobs = ["a.txt": Data(headText.utf8)]
            let files = StubFiles()
            files.readError = error
            let model = makeModel(git: git, files: files)

            await model.load(root: root)

            XCTAssertEqual(model.selection(for: "a.txt")?.facts.worktree, expected, name)
        }
    }

    // MARK: - The size cap

    /// The cap has to cover both sides. Applied only to the worktree, the `HEAD`
    /// blob of a large tracked text file was read, decoded and then *retained* in
    /// `files` for the life of the dialog — and again by the pre-commit re-read —
    /// which is the memory the cap exists to bound.
    func testAHeadSideBeyondTheCapIsBinaryAndSoCommittedWhole() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "big.txt", status: .modified)]
        let oversize = String(repeating: "x", count: CommitDialogModel.maxSelectableFileBytes + 1)
        git.headBlobs = ["big.txt": Data(oversize.utf8)]
        let files = StubFiles()
        files.contents["/repo/big.txt"] = "small\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        let big = model.files.first
        XCTAssertEqual(big?.facts.head, .binary)
        XCTAssertEqual(big?.facts.eligibility, .wholeOnly(reason: .binaryInHead))
        XCTAssertTrue(big?.facts.rows.isEmpty ?? false)
        XCTAssertTrue(big?.facts.units.isEmpty ?? false)
    }

    /// The boundary itself is *inside* the cap, matching the worktree side's
    /// `<= maxBytes` rule.
    func testAHeadSideExactlyAtTheCapIsStillText() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "big.txt", status: .modified)]
        let atCap = String(repeating: "x", count: CommitDialogModel.maxSelectableFileBytes)
        git.headBlobs = ["big.txt": Data(atCap.utf8)]
        let files = StubFiles()
        files.contents["/repo/big.txt"] = "small\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.files.first?.facts.eligibility, .selectable)
    }

    // MARK: - Reopening

    /// Reopening for the *same* folder skips the folder-change reset, so the load
    /// has to clear what described the previous read itself. Leaving it published
    /// let the sheet draw the earlier snapshot's rows and checkboxes as current
    /// while the fresh read was still in flight (the loading placeholder is gated on
    /// the list being empty).
    func testReopeningTheSameFolderClearsTheStaleListBeforeTheFreshReadPublishes() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        XCTAssertEqual(model.files.count, 1)

        // The next read is suspended inside `changedFiles`; assert what the view
        // would render at that moment.
        var duringLoad: (files: Int, selected: String?, error: String?)?
        git.onFirstChangedFiles = { @MainActor in
            duringLoad = (model.files.count, model.selectedPath, model.errorMessage)
        }
        await model.load(root: root)

        XCTAssertEqual(duringLoad?.files, 0)
        XCTAssertNil(duringLoad?.selected)
        XCTAssertNil(duringLoad?.error)
    }

    /// Amend is an intent formed against the HEAD of the *previous* opening, so it
    /// must not survive a Cancel — a silently pre-ticked checkbox is how a history
    /// rewrite happens without anyone deciding to. Unwound exactly as unticking it
    /// by hand would, so HEAD's auto-inserted message is withdrawn with it.
    func testReopeningClearsAmendAndWithdrawsItsAutoInsertedMessage() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.setAmend(true)
        XCTAssertTrue(model.amend)
        XCTAssertEqual(model.message, "previous subject")

        await model.load(root: root)

        XCTAssertFalse(model.amend)
        XCTAssertEqual(model.message, "")
    }

    /// …but a message the user typed themselves is their work, not the dialog's, so
    /// reopening preserves it exactly as unticking Amend does.
    func testReopeningKeepsAMessageTheUserTyped() async {
        let (git, files) = makeTextRepo()
        git.headMessageValue = "previous subject"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "mine"
        model.setAmend(true)

        await model.load(root: root)

        XCTAssertFalse(model.amend)
        XCTAssertEqual(model.message, "mine")
    }

    // MARK: - Races

    func testFolderChangeInvalidatesTheDialog() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        let generation = model.prepareForFolderChange(root: otherRoot)

        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.context)
        XCTAssertNil(model.selectedPath)
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(model.block, .noRepository)
        XCTAssertEqual(generation, model.currentRequestGeneration)
    }

    func testPrepareForTheSameFolderIsANoOp() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        let generation = model.prepareForFolderChange(root: root)

        XCTAssertEqual(generation, model.currentRequestGeneration)
        XCTAssertEqual(model.files.map(\.path), ["a.txt"])
        XCTAssertEqual(model.message, "subject")
    }

    func testLoadWithASupersededRequestGenerationIsRejected() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        let stale = model.prepareForFolderChange(root: root)
        _ = model.prepareForFolderChange(root: otherRoot)

        await model.load(root: root, request: stale)

        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.context)
    }

    /// Two ⌘K openings of the *same* repository can interleave — the folder never
    /// changes, so the root generation cannot separate them. A slower earlier load
    /// must not publish its file list over the newer one's: the user would compose
    /// a commit against a change list they were shown as current.
    func testASlowerEarlierLoadOfTheSameFolderDoesNotOverwriteANewerOne() async {
        let (git, files) = makeTextRepo()
        git.headBlobs["b.txt"] = Data("one\n".utf8)
        files.contents["/repo/b.txt"] = "two\n"
        // The hook fires at the top of `changedFiles`, so the *inner* load dequeues
        // the first answer and the suspended outer one the second: the two loads
        // see different repositories, which is what makes an unguarded overwrite
        // observable at all.
        git.changedFilesAnswers = [
            [ChangedFile(path: "b.txt", status: .modified)],
            [ChangedFile(path: "a.txt", status: .modified)],
        ]
        let model = makeModel(git: git, files: files)
        // The second load runs to completion *inside* the first one's
        // `changedFiles`, so the first resumes into an already-published newer
        // result — deterministic, no polling.
        git.onFirstChangedFiles = { [weak model] in
            await model?.load(root: self.root)
        }

        await model.load(root: root)

        XCTAssertEqual(model.files.map(\.path), ["b.txt"])
        XCTAssertFalse(model.isLoading)
    }

    func testCommitWithAStaleOriginGenerationDoesNothing() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        let generation = model.currentRequestGeneration

        _ = model.prepareForFolderChange(root: otherRoot)
        let outcome = await model.commit(originGeneration: generation)

        XCTAssertEqual(outcome, .abandoned)
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    func testASecondCommitWhileOneIsRunningIsBlocked() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        // Re-enter from inside the in-flight commit: deterministic, no polling.
        var reentrant: CommitDialogModel.CommitOutcome?
        git.onCommit = { [weak model] in
            reentrant = await model?.commit()
        }

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(reentrant, .blocked(.alreadyRunning))
        XCTAssertEqual(git.committedPlans.count, 1)
        XCTAssertFalse(model.isRunning)
    }

    // MARK: - Identity editing

    func testSetLocalIdentityWritesLocallyAndRefreshesTheAuthorLine() async {
        let (git, files) = makeTextRepo()
        git.identityValue = CommitIdentity(
            name: "",
            email: "",
            nameSource: .unset,
            emailSource: .unset
        )
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        XCTAssertEqual(model.block, .identityIncomplete)

        let ok = await model.setLocalIdentity(name: "Ada", email: "ada@work.example")

        XCTAssertTrue(ok)
        XCTAssertEqual(git.setIdentityCalls, [["Ada", "ada@work.example"]])
        XCTAssertEqual(model.identity.signature, "Ada <ada@work.example> (local)")
        XCTAssertTrue(model.identity.isComplete)
    }

    /// The author editor dismisses on Save while the write is still queued behind
    /// the same serial git queue the commit uses, so Commit has to be blocked for
    /// that window — otherwise it records the identity being replaced, or (between
    /// the two `git config` commands) the new name beside the old email.
    func testCommitIsBlockedWhileTheIdentityWriteIsInFlight() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "Fix the thing"

        var blockDuringWrite: CommitBlock?
        var outcomeDuringWrite: CommitDialogModel.CommitOutcome?
        git.onSetIdentity = { @MainActor in
            blockDuringWrite = model.block
            outcomeDuringWrite = await model.commit()
        }

        let ok = await model.setLocalIdentity(name: "Ada", email: "ada@work.example")

        XCTAssertTrue(ok)
        XCTAssertEqual(blockDuringWrite, .identityWriteInProgress)
        XCTAssertEqual(outcomeDuringWrite, .blocked(.identityWriteInProgress))
        XCTAssertTrue(git.committedPlans.isEmpty)
        // And the flag is lowered again once the write lands, so the dialog is
        // usable rather than permanently gated.
        XCTAssertFalse(model.isWritingIdentity)
        XCTAssertNil(model.block)
    }

    func testSetLocalIdentityFailureSurfacesTheMessage() async {
        let (git, files) = makeTextRepo()
        git.setIdentityError = GitError.notARepository(stderr: "fatal: nope")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        let ok = await model.setLocalIdentity(name: "Ada", email: "ada@work.example")

        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, "fatal: nope")
    }

    // MARK: - Which side each file is read from

    /// A rename's `HEAD` side lives under its **old** path — the new one does not
    /// exist at `HEAD` at all. Reading the new path instead would make every
    /// renamed file classify as wholly *added*: every line a unit against a
    /// falsely empty old side, and the mode taken from the working file rather
    /// than from what git records, silently dropping an exec bit.
    func testRenamedFileReadsItsHeadSideFromTheOldPath() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "new.txt", status: .renamed, oldPath: "old.txt")]
        git.headBlobs = ["old.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.contents["/repo/new.txt"] = worktreeText
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(git.headBlobCalls, ["old.txt"])
        XCTAssertEqual(model.selection(for: "new.txt")?.facts.head, .text(headText))
        // A real modification, not "every line added".
        XCTAssertEqual(model.selection(for: "new.txt")?.facts.units, [1, 2])

        model.message = "rename"
        _ = await model.commit()

        XCTAssertEqual(
            git.committedPlans.first?.entries.first,
            .removePath(path: "old.txt")
        )
    }

    /// A partial commit of a rename takes its mode from the path git records it
    /// under, i.e. the *old* one.
    func testPartialRenameTakesItsModeSourceFromTheOldPath() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "new.txt", status: .renamed, oldPath: "old.txt")]
        git.headBlobs = ["old.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.contents["/repo/new.txt"] = worktreeText
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.toggleUnit(2, path: "new.txt")   // leave unit 1 selected only
        model.message = "partial rename"

        _ = await model.commit()

        guard let entry = git.committedPlans.first?.entries.last else {
            return XCTFail("no plan entry")
        }
        guard case let .addContent(path, _, modeSource) = entry else {
            return XCTFail("expected assembled content, got \(entry)")
        }
        XCTAssertEqual(path, "new.txt")
        XCTAssertEqual(modeSource, .head(path: "old.txt"))
    }

    /// A symlink's blob is its **target string**, which is what git stores. Reading
    /// *through* the link would diff (and commit) the contents of whatever it
    /// points at — possibly a file outside the repository entirely.
    func testChangedSymlinkContributesItsTargetStringNotTheTargetFile() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "link", status: .modified)]
        git.headBlobs = ["link": Data("../old-target".utf8)]
        let files = StubFiles()
        files.symlinks["/repo/link"] = "../new-target"
        // Registered so a read *through* the link would visibly succeed with the
        // wrong content rather than merely throwing.
        files.contents["/repo/link"] = "the contents of the target file"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "link")?.facts.worktree, .text("../new-target"))
    }

    /// An unreadable working file is `.binary` — "there is no text to select lines
    /// from" — so the file is offered whole. Treating it as empty text instead
    /// would draw a diff reading "every HEAD line removed", every row checkable,
    /// and checking them would commit a truncated file over content nobody could
    /// even read.
    ///
    /// The failure is a *permission* error specifically: "unreadable" and "not
    /// there" are different facts and only the latter is `.absent`, so a test that
    /// stood in for one with the other would no longer be testing this rule.
    func testUnreadableWorktreeFileIsWholeOnlyRatherThanEveryHeadLineRemoved() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "a.txt", status: .modified)]
        git.headBlobs = ["a.txt": Data(headText.utf8)]
        let files = StubFiles()
        files.readError = CocoaError(.fileReadNoPermission)
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "a.txt")?.facts.worktree, .binary)
        XCTAssertEqual(
            model.selection(for: "a.txt")?.facts.eligibility,
            .wholeOnly(reason: .binaryInWorktree)
        )
        XCTAssertEqual(model.selection(for: "a.txt")?.facts.units, [])
        XCTAssertEqual(model.unifiedLines(for: "a.txt"), [])
        XCTAssertEqual(
            model.wholeOnlyMessage(for: "a.txt"),
            WholeOnlyReason.binaryInWorktree.message
        )
    }

    /// Past `maxSelectableFileBytes` the file is whole-only rather than read (and
    /// LCS-diffed) wholly into memory on the main actor, twice per commit.
    func testWorktreeFileLargerThanTheCapIsWholeOnly() async {
        let git = StubGit()
        git.changed = [ChangedFile(path: "big.txt", status: .modified)]
        git.headBlobs = ["big.txt": Data("small\n".utf8)]
        let files = StubFiles()
        files.contents["/repo/big.txt"] = String(
            repeating: "x",
            count: CommitDialogModel.maxSelectableFileBytes + 1
        )
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertEqual(model.selection(for: "big.txt")?.facts.worktree, .binary)
        XCTAssertEqual(model.selection(for: "big.txt")?.facts.units, [])
    }

    /// Neither an added nor an untracked path can have a `HEAD` entry, so the
    /// status already answers the question and the subprocess is skipped — which
    /// matters on a repository with a large untracked build directory.
    func testAddedAndUntrackedFilesSkipTheHeadBlobSubprocess() async {
        let git = StubGit()
        git.changed = [
            ChangedFile(path: "added.txt", status: .added),
            ChangedFile(path: "new.txt", status: .untracked),
        ]
        let files = StubFiles()
        files.contents["/repo/added.txt"] = "one\n"
        files.contents["/repo/new.txt"] = "two\n"
        let model = makeModel(git: git, files: files)

        await model.load(root: root)

        XCTAssertTrue(git.headBlobCalls.isEmpty)
        XCTAssertEqual(model.selection(for: "added.txt")?.facts.head, .absent)
        XCTAssertEqual(model.selection(for: "new.txt")?.facts.head, .absent)
        // An absent HEAD side is selectable, not whole-only: the builder takes
        // `head: ""` and every line is an added unit.
        XCTAssertEqual(model.selection(for: "added.txt")?.facts.eligibility, .selectable)
        XCTAssertEqual(model.selection(for: "added.txt")?.facts.units, [0])
    }

    // MARK: - The blocks that stand in for git's own refusals

    /// git refuses to commit with unmerged entries in the index; the throw-away
    /// index means it never sees them, so this block *is* that refusal. It does
    /// not care whether the conflicted file is checked.
    func testConflictedFileBlocksTheCommitEvenWhenUnchecked() async {
        let (git, files) = makeTextRepo()
        git.changed.append(ChangedFile(path: "c.txt", status: .conflicted))
        git.headBlobs["c.txt"] = Data("base\n".utf8)
        files.contents["/repo/c.txt"] = "mine\n"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        XCTAssertEqual(model.conflictedPaths, ["c.txt"])
        XCTAssertEqual(model.block, .conflictedFiles(["c.txt"]))

        model.toggleFile(path: "c.txt")   // uncheck it — still blocked
        XCTAssertEqual(model.block, .conflictedFiles(["c.txt"]))

        let outcome = await model.commit()
        XCTAssertEqual(outcome, .blocked(.conflictedFiles(["c.txt"])))
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    /// A merge started in a terminal *after* the dialog opened must still block:
    /// the gate the button reads runs against load-time state, and the throw-away
    /// index stops git from refusing on its own, so without the pre-commit
    /// re-check the merge would be recorded as an ordinary one-parent commit.
    func testMergeStartedWhileTheDialogIsOpenBlocksTheCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        XCTAssertNil(model.block)

        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "main",
            upstream: "origin/main",
            remotes: ["origin"],
            inProgress: .merge
        )

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .blocked(.operationInProgress(.merge)))
        XCTAssertTrue(git.committedPlans.isEmpty)
        XCTAssertEqual(model.errorMessage, CommitBlock.operationInProgress(.merge).message)
    }

    /// The same for a file that became conflicted since the dialog loaded — and
    /// it is deliberately *not* covered by the staleness check, which only ever
    /// looks at the files the plan touches.
    func testConflictAppearingWhileTheDialogIsOpenBlocksTheCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        git.changedFilesAnswers = [[
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "c.txt", status: .conflicted),
        ]]
        files.contents["/repo/c.txt"] = "mine\n"

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .blocked(.conflictedFiles(["c.txt"])))
        XCTAssertTrue(git.committedPlans.isEmpty)
    }

    // MARK: - Error reporting

    /// A failure that outlived the state it described must not keep masking the
    /// live gate reason: the dialog shows `errorMessage ?? block?.message`, so a
    /// stale one leaves the Commit button disabled with no visible explanation.
    func testActingOnTheSelectionClearsTheLastFailure() async {
        let (git, files) = makeTextRepo()
        git.commitError = GitError.commitFailed(reason: "pre-commit hook refused")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        _ = await model.commit()
        XCTAssertEqual(model.errorMessage, "pre-commit hook refused")

        model.toggleFile(path: "a.txt")

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.block, .nothingSelected)
    }

    /// The rule covers all three mutators, not just `toggleFile`: the dialog shows
    /// `errorMessage ?? block?.message`, so a dead failure left standing keeps the
    /// Commit button disabled with the *wrong* explanation — or, once the live
    /// reason is one the user just created, with none they can act on.
    func testEverySelectionMutatorClearsTheLastFailure() async {
        for mutate in [
            ("toggleUnit", { (m: CommitDialogModel) in m.toggleUnit(1, path: "a.txt") }),
            ("setAmend", { (m: CommitDialogModel) in m.setAmend(true) }),
            ("toggleFile", { (m: CommitDialogModel) in m.toggleFile(path: "a.txt") }),
        ] {
            let (git, files) = makeTextRepo()
            git.commitError = GitError.commitFailed(reason: "pre-commit hook refused")
            let model = makeModel(git: git, files: files)
            await model.load(root: root)
            model.message = "subject"

            _ = await model.commit()
            XCTAssertEqual(model.errorMessage, "pre-commit hook refused", mutate.0)

            mutate.1(model)

            XCTAssertNil(model.errorMessage, mutate.0)
        }
    }

    /// Editing the *message* supersedes the last failure too — the commonest case
    /// of all, since a `commit-msg` hook refuses the message and rewriting it is
    /// the direct response. The field is bound straight to the published property,
    /// so this rides on `message`'s own `didSet` rather than on a mutator.
    func testEditingTheMessageClearsTheLastFailure() async {
        let (git, files) = makeTextRepo()
        git.commitError = GitError.commitFailed(reason: "commit-msg hook refused")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "bad subject"

        _ = await model.commit()
        XCTAssertEqual(model.errorMessage, "commit-msg hook refused")

        model.message = "PROJ-1 good subject"

        XCTAssertNil(model.errorMessage)
    }

    /// The sharper half of the same rule: *clearing* the field leaves the button
    /// disabled for `.emptyMessage` while the panel would otherwise still quote the
    /// hook — disabled with no visible explanation, exactly what the rule prevents.
    func testClearingTheMessageLeavesTheLiveGateReasonVisible() async {
        let (git, files) = makeTextRepo()
        git.commitError = GitError.commitFailed(reason: "commit-msg hook refused")
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"

        _ = await model.commit()
        XCTAssertEqual(model.errorMessage, "commit-msg hook refused")

        model.message = ""

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.block, .emptyMessage)
    }

    // MARK: - Selection

    func testSelectShowsALoadedPathAndIgnoresAnUnknownOne() async {
        let (git, files) = makeTextRepo()
        git.changed.append(ChangedFile(path: "b.txt", status: .modified))
        git.headBlobs["b.txt"] = Data("one\n".utf8)
        files.contents["/repo/b.txt"] = "two\n"
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        XCTAssertEqual(model.selectedPath, "a.txt")

        model.select(path: "b.txt")
        XCTAssertEqual(model.selectedPath, "b.txt")

        model.select(path: "nope.txt")
        XCTAssertEqual(model.selectedPath, "b.txt")
    }

    // MARK: - More races

    /// A load discarded by a folder switch returns without publishing anything —
    /// including without clearing `isLoading`, so the switch itself has to, or the
    /// dialog is stranded on its loading placeholder with no path back.
    func testLoadDiscardedByAFolderSwitchLeavesNoLoadingPlaceholder() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        git.onFirstChangedFiles = { @MainActor [weak model] in
            model?.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        }

        await model.load(root: root)

        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.context)
    }

    /// `root` is what every mutation runs against, so a folder switch must drop
    /// it: the author editor is still on screen, and writing `git config --local`
    /// into the repository the user just left is exactly the "one repository's
    /// identity" promise inverted.
    func testFolderChangeClearsRootSoIdentityCannotReachThePreviousRepository() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)

        model.prepareForFolderChange(root: otherRoot)
        XCTAssertNil(model.root)

        let ok = await model.setLocalIdentity(name: "Ada", email: "ada@work.example")

        XCTAssertFalse(ok)
        XCTAssertTrue(git.setIdentityCalls.isEmpty)
        XCTAssertEqual(model.errorMessage, CommitBlock.noRepository.message)
    }

    /// "Push after commit" is a per-project opt-in.
    func testFolderChangeClearsPushAfterCommit() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.pushAfterCommit = true

        model.prepareForFolderChange(root: otherRoot)

        XCTAssertFalse(model.pushAfterCommit)
    }

    /// A project switch landing *after* the commit was created still reports
    /// `.committed`. `.abandoned` means "nothing ran", and a caller that skipped
    /// its post-commit refreshes on it would leave a real commit unreported —
    /// with a dialog whose Commit button would happily make a second one.
    func testProjectSwitchAfterTheCommitStillReportsItCommitted() async {
        let (git, files) = makeTextRepo()
        let model = makeModel(git: git, files: files)
        await model.load(root: root)
        model.message = "subject"
        git.onCommit = { @MainActor [weak model] in
            model?.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        }

        let outcome = await model.commit()

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(git.committedMessages, ["subject"])
    }
}
