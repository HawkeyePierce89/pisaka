import XCTest
@testable import PisakaCore

@MainActor
final class BranchSwitcherModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")

    private enum StubError: Error { case boom }

    /// In-memory `GitServicing` covering just the branch-switcher surface: canned
    /// refnames / current branch / changed files, and recording the mutating calls
    /// (with optional errors to simulate a blocked checkout, a failed create, or a
    /// failed/credentials-required fetch).
    @MainActor
    private final class StubGit: GitServicing {
        var refnames: [String] = []
        var current: BranchRef?
        var changed: [ChangedFile] = []
        var repoRoot: URL?
        /// Set to throw from `repositoryRoot`/`references`/`currentBranch`/`changedFiles`.
        var refreshError: Error?

        // recorded mutations
        var checkedOut: [String] = []
        var checkoutError: Error?
        var created: [(name: String, startPoint: String)] = []
        var createError: Error?
        var fetched: [String] = []
        var fetchError: Error?
        /// Runs inside `checkout` (before it returns) to simulate a concurrent
        /// main-actor event — e.g. a folder switch — landing during the off-main op.
        var onCheckout: (() -> Void)?

        func repositoryRoot(for url: URL) async throws -> URL {
            if let refreshError { throw refreshError }
            return repoRoot ?? url
        }

        func changedFiles(root: URL) async throws -> [ChangedFile] {
            if let refreshError { throw refreshError }
            return changed
        }

        func references(root: URL) async throws -> [String] {
            if let refreshError { throw refreshError }
            return refnames
        }

        func currentBranch(root: URL) async throws -> BranchRef? {
            if let refreshError { throw refreshError }
            return current
        }

        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func checkout(branch: String, root: URL) async throws {
            if let checkoutError { throw checkoutError }
            onCheckout?()
            checkedOut.append(branch)
            // Simulate the switch: mark that branch current on the next refresh.
            current = BranchRef(
                name: "refs/heads/\(branch)",
                isRemote: false,
                remoteName: nil,
                shortName: branch,
                isCurrent: true
            )
        }

        func createAndCheckout(name: String, startPoint: String, root: URL) async throws {
            if let createError { throw createError }
            created.append((name, startPoint))
            if !refnames.contains("refs/heads/\(name)") {
                refnames.append("refs/heads/\(name)")
            }
            current = BranchRef(
                name: "refs/heads/\(name)",
                isRemote: false,
                remoteName: nil,
                shortName: name,
                isCurrent: true
            )
        }

        func fetch(remote: String, root: URL) async throws {
            if let fetchError { throw fetchError }
            fetched.append(remote)
        }
    }

    private func makeModel(_ git: StubGit) -> BranchSwitcherModel {
        BranchSwitcherModel(gitService: git)
    }

    private func localCurrent(_ short: String) -> BranchRef {
        BranchRef(name: "refs/heads/\(short)", isRemote: false, remoteName: nil, shortName: short, isCurrent: true)
    }

    // MARK: - refresh

    func testRefreshFillsGroupsAndMarksCurrent() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/heads/feature",
            "refs/remotes/origin/main",
            "refs/remotes/origin/HEAD",
            "refs/tags/v1.0",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)

        await model.refresh(root: root)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.root, root)
        XCTAssertEqual(model.current?.shortName, "main")

        let locals = model.filteredLocalBranches
        XCTAssertEqual(locals.map(\.shortName), ["feature", "main"])
        XCTAssertTrue(locals.first { $0.shortName == "main" }?.isCurrent ?? false)
        XCTAssertFalse(locals.first { $0.shortName == "feature" }?.isCurrent ?? true)

        // Remotes drop origin/HEAD and tags.
        let remotes = model.filteredRemoteBranches
        XCTAssertEqual(remotes.map(\.shortName), ["origin/main"])
    }

    func testRefreshSetsDirtyFlag() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.changed = [ChangedFile(path: "a.swift", status: .modified)]
        let model = makeModel(git)

        await model.refresh(root: root)
        XCTAssertTrue(model.isWorkingTreeDirty)

        git.changed = []
        await model.refresh(root: root)
        XCTAssertFalse(model.isWorkingTreeDirty)
    }

    func testRefreshDetachedHeadHasNoCurrent() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.current = nil
        let model = makeModel(git)

        await model.refresh(root: root)
        XCTAssertNil(model.current)
        XCTAssertFalse(model.filteredLocalBranches.contains { $0.isCurrent })
    }

    func testRefreshFailureClearsStateAndSetsError() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        let model = makeModel(git)
        await model.refresh(root: root)
        XCTAssertFalse(model.branches.isEmpty)

        git.refreshError = GitError.notARepository(stderr: "not a repo")
        await model.refresh(root: root)
        XCTAssertTrue(model.branches.isEmpty)
        XCTAssertNil(model.current)
        XCTAssertFalse(model.isWorkingTreeDirty)
        XCTAssertEqual(model.errorMessage, "not a repo")
    }

    /// Two rapid folder switches capture their tokens synchronously via
    /// `prepareForRefresh`; a refresh carrying the *older* token must bail rather
    /// than publish over the newer folder's state, even if its task happens to run
    /// last (the out-of-order-Task hazard the sibling models guard against).
    func testPreparedRefreshRejectsSupersededOutOfOrderRequest() async {
        let rootA = URL(fileURLWithPath: "/repoA")
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        let model = makeModel(git)

        // Folder A prepared, then folder B prepared — both synchronously, in order.
        let requestA = model.prepareForRefresh(root: rootA)
        let requestB = model.prepareForRefresh(root: rootB)
        XCTAssertLessThan(requestA, requestB)

        // The older (A) task resolves last: it must discard, not publish A's list.
        git.refnames = ["refs/heads/aaa"]
        git.repoRoot = rootA
        await model.refresh(root: rootA, request: requestA)
        XCTAssertTrue(model.branches.isEmpty)
        XCTAssertNil(model.root)

        // The newer (B) task publishes.
        git.refnames = ["refs/heads/bbb"]
        git.repoRoot = rootB
        await model.refresh(root: rootB, request: requestB)
        XCTAssertEqual(model.root, rootB)
        XCTAssertEqual(model.filteredLocalBranches.map(\.shortName), ["bbb"])
    }

    /// A folder switch clears the previous repo's published list synchronously in
    /// `prepareForRefresh`, so the widget is never actionable against the repo the
    /// user just left while the new repo's refresh is in flight.
    func testPrepareForRefreshClearsPreviousRepoOnFolderSwitch() async {
        let rootA = URL(fileURLWithPath: "/repoA")
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.repoRoot = rootA
        let model = makeModel(git)

        let requestA = model.prepareForRefresh(root: rootA)
        await model.refresh(root: rootA, request: requestA)
        XCTAssertFalse(model.branches.isEmpty)

        _ = model.prepareForRefresh(root: rootB)
        XCTAssertTrue(model.branches.isEmpty)
        XCTAssertNil(model.current)
    }

    /// A folder switch must also clear `root`: the widget gates every mutation on
    /// `root != nil`, so switching from a git repo to a non-repo folder (whose
    /// refresh fails and never re-populates `root`) must not leave the previous
    /// repo's root actionable — otherwise "New Branch…" would mutate the repo the
    /// user just left.
    func testFolderSwitchToNonRepoClearsRoot() async {
        let rootA = URL(fileURLWithPath: "/repoA")
        let rootB = URL(fileURLWithPath: "/not-a-repo")
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.repoRoot = rootA
        let model = makeModel(git)

        let requestA = model.prepareForRefresh(root: rootA)
        await model.refresh(root: rootA, request: requestA)
        XCTAssertEqual(model.root, rootA)

        // Switch to a folder whose repository resolution fails.
        let requestB = model.prepareForRefresh(root: rootB)
        XCTAssertNil(model.root, "root must be cleared synchronously on the switch")
        git.refreshError = StubError.boom
        await model.refresh(root: rootB, request: requestB)
        XCTAssertNil(model.root, "a failed refresh must not restore the old repo's root")
        XCTAssertNotNil(model.errorMessage)
    }

    /// For a subfolder-opened repo the requested folder differs from the resolved
    /// repo top; `switchTo`'s trailing refresh must run against the *requested*
    /// folder so it does not trip `refresh`'s folder-switch reset and drift
    /// `lastRequestedRoot` to the repo top (which would then misread a later
    /// re-open of the same subfolder as a folder switch).
    func testSwitchToInSubfolderRepoDoesNotDriftRequestedRoot() async {
        let subfolder = URL(fileURLWithPath: "/repo/sub")
        let repoTop = URL(fileURLWithPath: "/repo")
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        git.repoRoot = repoTop
        let model = makeModel(git)

        let request = model.prepareForRefresh(root: subfolder)
        await model.refresh(root: subfolder, request: request)
        XCTAssertEqual(model.root, repoTop)

        let ok = await model.switchTo(BranchRef(
            name: "refs/heads/feature", isRemote: false, remoteName: nil,
            shortName: "feature", isCurrent: false
        ))
        XCTAssertTrue(ok)
        XCTAssertEqual(model.current?.shortName, "feature")
        XCTAssertFalse(model.branches.isEmpty)

        // `lastRequestedRoot` must still be the subfolder, so re-preparing the same
        // subfolder is *not* seen as a switch and does not clear the list.
        _ = model.prepareForRefresh(root: subfolder)
        XCTAssertFalse(
            model.branches.isEmpty,
            "requested root drifted to the repo top, so re-opening the subfolder cleared the list"
        )
    }

    // MARK: - switchTo

    func testSwitchToSuccessRefreshesAndClearsError() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let ok = await model.switchTo(BranchRef(
            name: "refs/heads/feature", isRemote: false, remoteName: nil,
            shortName: "feature", isCurrent: false
        ))
        XCTAssertTrue(ok)
        XCTAssertEqual(git.checkedOut, ["feature"])
        XCTAssertEqual(model.current?.shortName, "feature")
        XCTAssertNil(model.errorMessage)
    }

    /// A folder switch that lands during `switchTo`'s off-main checkout must
    /// supersede its trailing refresh: the refresh carries the generation pinned
    /// at `switchTo`'s entry, so once `prepareForRefresh` bumps it the trailing
    /// refresh bails rather than re-deriving a spurious "switch back" and
    /// re-publishing the old repo's branches over the new folder's cleared state.
    func testSwitchToTrailingRefreshSupersededByFolderSwitchDuringCheckout() async {
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)
        XCTAssertFalse(model.branches.isEmpty)

        // Simulate the user opening a different folder while the checkout runs:
        // `prepareForRefresh(rootB)` bumps the generation and clears the old list.
        git.onCheckout = { [weak model] in _ = model?.prepareForRefresh(root: rootB) }

        let ok = await model.switchTo(BranchRef(
            name: "refs/heads/feature", isRemote: false, remoteName: nil,
            shortName: "feature", isCurrent: false
        ))

        // The checkout itself still succeeded, but the stale trailing refresh must
        // not have re-published rootA's branches over the rootB switch.
        XCTAssertTrue(ok)
        XCTAssertEqual(git.checkedOut, ["feature"])
        XCTAssertTrue(model.branches.isEmpty)
    }

    func testSwitchToBlockedSurfacesGitMessage() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        git.checkoutError = GitError.checkoutFailed(reason: "Your local changes would be overwritten: a.swift")
        let model = makeModel(git)
        await model.refresh(root: root)

        let ok = await model.switchTo(BranchRef(
            name: "refs/heads/feature", isRemote: false, remoteName: nil,
            shortName: "feature", isCurrent: false
        ))
        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, "Your local changes would be overwritten: a.swift")
        // Current is unchanged.
        XCTAssertEqual(model.current?.shortName, "main")
    }

    func testSwitchToWithoutRefreshedRootFails() async {
        let git = StubGit()
        let model = makeModel(git)
        let ok = await model.switchTo(localCurrent("feature"))
        XCTAssertFalse(ok)
        XCTAssertTrue(git.checkedOut.isEmpty)
    }

    /// A folder switch that fully commits between the user choosing a branch and the
    /// deferred `switchTo` task starting must make the checkout bail: the app pins the
    /// refresh generation synchronously and passes it as `originGeneration`, so a
    /// mismatch (a `prepareForRefresh` bumped it in the gap) refuses to check out
    /// against the newly opened repo — even one with a same-named branch.
    func testSwitchToStaleOriginGenerationBailsBeforeCheckout() async {
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        // The app captured this before its `Task` hop.
        let origin = model.currentRefreshGeneration
        // A folder switch lands in the gap, bumping the generation.
        _ = model.prepareForRefresh(root: rootB)

        let ok = await model.switchTo(
            BranchRef(
                name: "refs/heads/feature", isRemote: false, remoteName: nil,
                shortName: "feature", isCurrent: false
            ),
            originGeneration: origin
        )
        XCTAssertFalse(ok)
        XCTAssertTrue(git.checkedOut.isEmpty)
        // A folder-switch bail leaves no message — the view fix keys its alert off this.
        XCTAssertNil(model.errorMessage)
    }

    /// A generation-mismatch bail must not *touch* an existing `errorMessage`: seed a
    /// real failure, then bump the generation same-root (which does not clear the
    /// message) and confirm the bail leaves that message verbatim and runs no checkout.
    func testSwitchToStaleOriginGenerationPreservesExistingErrorMessage() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let feature = BranchRef(
            name: "refs/heads/feature", isRemote: false, remoteName: nil,
            shortName: "feature", isCurrent: false
        )

        // Seed a non-empty `errorMessage` with a deterministic typed error.
        git.checkoutError = GitError.checkoutFailed(reason: "seeded")
        let failed = await model.switchTo(feature)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.errorMessage, "seeded")

        // Clear the error so a leaked checkout would be observable, then bump the
        // generation same-root (bumps `refreshGeneration` without clearing the message).
        git.checkoutError = nil
        let origin = model.currentRefreshGeneration
        _ = model.prepareForRefresh(root: root)

        let ok = await model.switchTo(feature, originGeneration: origin)
        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, "seeded")
        XCTAssertTrue(git.checkedOut.isEmpty)
    }

    // MARK: - createBranch

    func testCreateBranchValidFromHead() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let outcome = await model.createBranch(name: "feature", from: .head)
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(git.created.map(\.name), ["feature"])
        XCTAssertEqual(git.created.first?.startPoint, "HEAD")
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertEqual(model.current?.shortName, "feature")
        XCTAssertNil(model.errorMessage)
    }

    /// The `createBranch` peer of the `switchTo` origin-generation guard: a folder
    /// switch committed across the app's `Task` hop makes the create bail (as
    /// `.failed`, no git call) rather than create+check out the branch in the new repo.
    func testCreateBranchStaleOriginGenerationBailsBeforeGitCall() async {
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let origin = model.currentRefreshGeneration
        _ = model.prepareForRefresh(root: rootB)

        let outcome = await model.createBranch(name: "feature", from: .head, originGeneration: origin)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
        // A folder-switch bail leaves no message — the view fix keys its alert off this.
        XCTAssertNil(model.errorMessage)
    }

    /// The `createBranch` peer of the `switchTo` preservation test: a generation
    /// mismatch must not touch an already-set `errorMessage` and must run no git call.
    func testCreateBranchStaleOriginGenerationPreservesExistingErrorMessage() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        // Seed a non-empty `errorMessage` with a deterministic typed error.
        git.createError = GitError.checkoutFailed(reason: "seeded")
        let seededOutcome = await model.createBranch(name: "feature", from: .head)
        XCTAssertEqual(seededOutcome, .failed)
        XCTAssertEqual(model.errorMessage, "seeded")

        // Clear the error so a leaked create would be observable, then bump the
        // generation same-root (bumps `refreshGeneration` without clearing the message).
        git.createError = nil
        let origin = model.currentRefreshGeneration
        _ = model.prepareForRefresh(root: root)

        let outcome = await model.createBranch(name: "feature", from: .head, originGeneration: origin)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(model.errorMessage, "seeded")
        XCTAssertTrue(git.created.isEmpty)
    }

    /// An invalid name is rejected *before* the origin-generation check — name
    /// validation needs no git state, so a stale generation still reports the more
    /// specific `.invalidName`.
    func testCreateBranchInvalidNameTakesPrecedenceOverStaleGeneration() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        let model = makeModel(git)
        await model.refresh(root: root)

        let origin = model.currentRefreshGeneration
        _ = model.prepareForRefresh(root: URL(fileURLWithPath: "/repoB"))

        let outcome = await model.createBranch(name: "bad name", from: .head, originGeneration: origin)
        XCTAssertEqual(outcome, .invalidName)
        XCTAssertTrue(git.created.isEmpty)
    }

    func testCreateBranchInvalidName() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        let model = makeModel(git)
        await model.refresh(root: root)

        let outcome = await model.createBranch(name: "bad name", from: .head)
        XCTAssertEqual(outcome, .invalidName)
        XCTAssertTrue(git.created.isEmpty)
    }

    func testCreateBranchFromRemoteFetchesFirst() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/remotes/origin/master"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/master" }!
        let outcome = await model.createBranch(name: "master", from: .ref(remote))
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(git.fetched, ["origin"])
        XCTAssertEqual(git.created.first?.startPoint, "refs/remotes/origin/master")
    }

    func testCreateBranchFromRemoteFetchFailureReturnsOffline() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/remotes/origin/master"]
        git.current = localCurrent("main")
        git.fetchError = GitError.fetchFailed(reason: "could not connect")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/master" }!
        let outcome = await model.createBranch(name: "master", from: .ref(remote))
        XCTAssertEqual(outcome, .fetchUnavailable(.fetchFailed(reason: "could not connect")))
        XCTAssertTrue(git.created.isEmpty)
        // A recoverable choice, not a hard error — no errorMessage set.
        XCTAssertNil(model.errorMessage)
    }

    func testCreateBranchFromRemoteCredentialsRequiredReturnsOffline() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/remotes/origin/master"]
        git.fetchError = GitError.credentialsRequired(host: "github.com")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/master" }!
        let outcome = await model.createBranch(name: "master", from: .ref(remote))
        XCTAssertEqual(outcome, .fetchUnavailable(.credentialsRequired(host: "github.com")))
    }

    func testCreateBranchFromRemoteWithoutFetchSkipsFetch() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/remotes/origin/master"]
        git.fetchError = GitError.fetchFailed(reason: "offline")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/master" }!
        // create-from-local: skip the fetch entirely.
        let outcome = await model.createBranch(name: "master", from: .ref(remote), fetchRemote: false)
        XCTAssertEqual(outcome, .created)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertEqual(git.created.first?.startPoint, "refs/remotes/origin/master")
    }

    func testCreateBranchCreateFailureSetsError() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main"]
        git.createError = GitError.checkoutFailed(reason: "already exists")
        let model = makeModel(git)
        await model.refresh(root: root)

        let outcome = await model.createBranch(name: "feature", from: .head)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(model.errorMessage, "already exists")
    }

    // MARK: - checkoutRemote

    /// A remote branch whose same-named local already exists: `checkoutRemote`
    /// switches to that local (checkout, no create), updates `current`, and performs
    /// no fetch.
    func testCheckoutRemoteExistingLocalSwitches() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/heads/feature",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let ok = await model.checkoutRemote(remote)
        XCTAssertTrue(ok)
        XCTAssertEqual(git.checkedOut, ["feature"])
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertEqual(model.current?.shortName, "feature")
        XCTAssertNil(model.errorMessage)
    }

    /// A remote branch with no same-named local: `checkoutRemote` creates a local at
    /// the remote ref's commit (start point = the remote's full refname) and performs
    /// no fetch (DWIM checkout does not fetch).
    func testCheckoutRemoteNoLocalCreatesFromRemoteWithoutFetch() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let ok = await model.checkoutRemote(remote)
        XCTAssertTrue(ok)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertEqual(git.created.map(\.name), ["feature"])
        XCTAssertEqual(git.created.first?.startPoint, "refs/remotes/origin/feature")
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertEqual(model.current?.shortName, "feature")
        XCTAssertNil(model.errorMessage)
    }

    /// A blocked checkout of the existing local (git refuses to overwrite local
    /// changes) surfaces git's message and returns `false`.
    func testCheckoutRemoteExistingLocalBlockedSurfacesGitMessage() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/heads/feature",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        git.checkoutError = GitError.checkoutFailed(reason: "Your local changes would be overwritten: a.swift")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let ok = await model.checkoutRemote(remote)
        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, "Your local changes would be overwritten: a.swift")
        XCTAssertEqual(model.current?.shortName, "main")
    }

    /// A create failure on the create-from-remote path surfaces git's message and
    /// returns `false`.
    func testCheckoutRemoteNoLocalCreateFailureSurfacesGitMessage() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        git.createError = GitError.checkoutFailed(reason: "already exists")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let ok = await model.checkoutRemote(remote)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertEqual(model.errorMessage, "already exists")
    }

    /// MANDATORY: a stale `originGeneration` on the CREATE path must bail with
    /// `false`, make NO git call, and leave `errorMessage == nil`. After a folder
    /// switch `branches` is cleared, so the decision degrades to `.createLocal`; the
    /// delegate `createBranch` then bails on the generation mismatch before any git
    /// call — locking the "bail without a git call and without writing errorMessage"
    /// contract and pinning that a decision over already-cleared `branches` never
    /// reaches git.
    func testCheckoutRemoteStaleOriginGenerationBailsOnCreatePath() async {
        let rootB = URL(fileURLWithPath: "/repoB")
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!

        // The app captured this before its `Task` hop; a folder switch lands in the
        // gap, bumping the generation and clearing `branches`.
        let origin = model.currentRefreshGeneration
        _ = model.prepareForRefresh(root: rootB)
        XCTAssertTrue(model.branches.isEmpty)

        let ok = await model.checkoutRemote(remote, originGeneration: origin)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    /// The symmetric stale test on the `.checkoutLocal` path: with a same-named local
    /// present when captured, a stale generation still bails before any checkout and
    /// writes no `errorMessage`.
    func testCheckoutRemoteStaleOriginGenerationBailsOnCheckoutPath() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/heads/feature",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let origin = model.currentRefreshGeneration
        // Same-root bump keeps `branches` populated so the decision is still
        // `.checkoutLocal`, but the generation no longer matches.
        _ = model.prepareForRefresh(root: root)

        let ok = await model.checkoutRemote(remote, originGeneration: origin)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    /// A same-root stale test on the CREATE path that isolates the origin-generation
    /// guard from the nil-`root` guard: a *same-root* `prepareForRefresh` bumps the
    /// generation while keeping `branches` populated and `root` non-nil (unlike a
    /// different-root switch, which also nils `root` — either guard would then bail,
    /// so that test can't tell the generation guard is threaded). With no same-named
    /// local the decision stays `.createLocal`; only the origin-generation mismatch
    /// can bail here, so this fails if `checkoutRemote` drops/mis-threads
    /// `originGeneration` on the create branch.
    func testCheckoutRemoteStaleOriginGenerationBailsOnCreatePathSameRoot() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/feature",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/feature" }!
        let origin = model.currentRefreshGeneration
        // Same-root bump: `branches` stays populated (decision is `.createLocal`) and
        // `root` stays non-nil, so only the generation guard can cause the bail.
        _ = model.prepareForRefresh(root: root)

        let ok = await model.checkoutRemote(remote, originGeneration: origin)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    /// A remote branch whose DWIM-derived local name is rejected by `GitRefName`
    /// (here a leading `-`) must not silently no-op: `checkoutRemote` makes no git
    /// call and surfaces an `errorMessage` (the create-dialog path reports this via
    /// the view layer; the `Bool`-returning DWIM path must set it itself).
    func testCheckoutRemoteInvalidDerivedNameSurfacesError() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/-bad",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/-bad" }!
        let ok = await model.checkoutRemote(remote)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    /// The narrow race combining the two above: a `checkoutRemote` superseded by a
    /// folder switch whose DWIM-derived local name is *also* invalid must still bail
    /// silently (no git call, `errorMessage == nil`) — the superseded-bail contract
    /// wins over the invalid-name reporting. Without the early generation guard,
    /// `createBranch` validates the name *before* its generation check, so the stale
    /// operation would return `.invalidName` and surface an invalid-branch error for
    /// the repo the user already left. A same-root bump isolates the generation guard
    /// from the nil-`root` guard (`branches`/`root` stay populated).
    func testCheckoutRemoteStaleOriginGenerationWithInvalidNameBailsSilently() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/remotes/origin/-bad",
        ]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/-bad" }!
        let origin = model.currentRefreshGeneration
        // Same-root bump: generation no longer matches, but `branches`/`root` stay
        // populated, so only the origin-generation guard can cause the bail.
        _ = model.prepareForRefresh(root: root)

        let ok = await model.checkoutRemote(remote, originGeneration: origin)
        XCTAssertFalse(ok)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.checkedOut.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - filter

    func testFilterNarrowsBothGroups() async {
        let git = StubGit()
        git.refnames = [
            "refs/heads/main",
            "refs/heads/feature-x",
            "refs/remotes/origin/feature-y",
            "refs/remotes/origin/main",
        ]
        let model = makeModel(git)
        await model.refresh(root: root)

        model.filterText = "feature"
        XCTAssertEqual(model.filteredLocalBranches.map(\.shortName), ["feature-x"])
        XCTAssertEqual(model.filteredRemoteBranches.map(\.shortName), ["origin/feature-y"])
    }

    func testCreateBranchFromLocalRefDoesNotFetch() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/heads/feature"]
        git.current = localCurrent("main")
        let model = makeModel(git)
        await model.refresh(root: root)

        let local = model.filteredLocalBranches.first { $0.shortName == "feature" }!
        let outcome = await model.createBranch(name: "feature-2", from: .ref(local))
        XCTAssertEqual(outcome, .created)
        XCTAssertTrue(git.fetched.isEmpty)
        XCTAssertEqual(git.created.first?.startPoint, "refs/heads/feature")
    }

    func testCreateBranchWithoutRefreshedRootFails() async {
        let git = StubGit()
        let model = makeModel(git)
        let outcome = await model.createBranch(name: "feature", from: .head)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(git.created.isEmpty)
        XCTAssertTrue(git.fetched.isEmpty)
    }

    func testCreateBranchFromRemoteWrapsNonGitErrorAsFetchFailed() async {
        let git = StubGit()
        git.refnames = ["refs/heads/main", "refs/remotes/origin/master"]
        git.fetchError = StubError.boom
        let model = makeModel(git)
        await model.refresh(root: root)

        let remote = model.filteredRemoteBranches.first { $0.shortName == "origin/master" }!
        let outcome = await model.createBranch(name: "master", from: .ref(remote))
        // A non-GitError from fetch is wrapped as .fetchFailed carrying its message.
        guard case .fetchUnavailable(.fetchFailed) = outcome else {
            return XCTFail("expected .fetchUnavailable(.fetchFailed), got \(outcome)")
        }
        XCTAssertTrue(git.created.isEmpty)
    }

    // MARK: - pure helpers

    func testDefaultBranchNameForRemote() {
        let remote = BranchRef(name: "refs/remotes/origin/master", isRemote: true, remoteName: "origin", shortName: "origin/master", isCurrent: false)
        XCTAssertEqual(BranchSwitcherModel.defaultBranchName(forRemote: remote), "master")

        // Nested branch name under the remote.
        let nested = BranchRef(name: "refs/remotes/upstream/feature/x", isRemote: true, remoteName: "upstream", shortName: "upstream/feature/x", isCurrent: false)
        XCTAssertEqual(BranchSwitcherModel.defaultBranchName(forRemote: nested), "feature/x")

        // A local ref returns its short name unchanged.
        let local = BranchRef(name: "refs/heads/main", isRemote: false, remoteName: nil, shortName: "main", isCurrent: false)
        XCTAssertEqual(BranchSwitcherModel.defaultBranchName(forRemote: local), "main")
    }

    // MARK: - remoteCheckoutDecision

    /// A remote branch with no same-named local becomes a create-from-remote
    /// decision: the target local name has the `<remote>/` prefix stripped, and the
    /// start point is the remote ref itself.
    func testRemoteCheckoutDecisionNoLocalCreates() {
        let remote = BranchRef(name: "refs/remotes/origin/feature", isRemote: true, remoteName: "origin", shortName: "origin/feature", isCurrent: false)
        let branches = [
            BranchRef(name: "refs/heads/main", isRemote: false, remoteName: nil, shortName: "main", isCurrent: true),
            remote,
        ]
        XCTAssertEqual(
            BranchSwitcherModel.remoteCheckoutDecision(for: remote, among: branches),
            .createLocal(name: "feature", from: remote)
        )
    }

    /// A remote branch whose same-named local already exists becomes a checkout of
    /// that local — never a create.
    func testRemoteCheckoutDecisionExistingLocalChecksOut() {
        let remote = BranchRef(name: "refs/remotes/origin/feature", isRemote: true, remoteName: "origin", shortName: "origin/feature", isCurrent: false)
        let local = BranchRef(name: "refs/heads/feature", isRemote: false, remoteName: nil, shortName: "feature", isCurrent: false)
        let branches = [
            BranchRef(name: "refs/heads/main", isRemote: false, remoteName: nil, shortName: "main", isCurrent: true),
            local,
            remote,
        ]
        XCTAssertEqual(
            BranchSwitcherModel.remoteCheckoutDecision(for: remote, among: branches),
            .checkoutLocal(local)
        )
    }

    /// The candidate "existing local" is matched by the *stripped* name — a remote
    /// branch sharing its own full short name (`origin/feature`) must not be treated
    /// as the local, only a real `refs/heads/feature` local qualifies.
    func testRemoteCheckoutDecisionRemotesAreNotLocalCandidates() {
        let remote = BranchRef(name: "refs/remotes/origin/feature", isRemote: true, remoteName: "origin", shortName: "origin/feature", isCurrent: false)
        // Another remote with the stripped name as its short name would be a decoy if
        // remotes were considered — but they are not.
        let decoyRemote = BranchRef(name: "refs/remotes/upstream/feature", isRemote: true, remoteName: "upstream", shortName: "feature", isCurrent: false)
        let branches = [
            BranchRef(name: "refs/heads/main", isRemote: false, remoteName: nil, shortName: "main", isCurrent: true),
            decoyRemote,
            remote,
        ]
        XCTAssertEqual(
            BranchSwitcherModel.remoteCheckoutDecision(for: remote, among: branches),
            .createLocal(name: "feature", from: remote)
        )
    }
}
