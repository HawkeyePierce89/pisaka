#if os(iOS)
import Foundation
import PisakaCore
import libgit2

/// A rename revert that failed after partially changing the working tree.
///
/// The iOS peer of `GitCLIService`'s `InterruptedRevert`: a rename revert restores
/// the old path from `HEAD`, then removes the new path; a failure between those
/// steps leaves the old path already restored. This carries the repo-relative
/// paths that actually changed so `LocalChangesModel` resyncs only those open tabs
/// (see `PartialRevertError`). `localizedDescription` defers to the underlying
/// libgit2/filesystem error so the user sees the real cause.
struct LibGit2InterruptedRevert: PartialRevertError, LocalizedError {
    let changedPaths: [String]
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// libgit2-backed implementation of `GitServicing`, the iOS counterpart to the
/// macOS `Process`-backed `GitCLIService`. There is no `git` CLI on iOS, so the
/// real git surface is implemented directly against the libgit2 C API
/// (`ibrahimcetin/libgit2`, compiled from source so it links natively for every
/// Apple destination).
///
/// It produces the *same* `ChangedFile`/`FileStatus`/`GitError` values the CLI
/// parsers produce, so `LocalChangesModel` (and its stub-backed tests in Core)
/// behave identically across platforms. Every libgit2 call runs on a dedicated
/// serial queue — mirroring `GitCLIService.run` — so the cooperative pool is never
/// blocked and repository access is serialized.
///
/// Phase 2 (Task 7) implements the Local Changes surface: `repositoryRoot`,
/// `changedFiles`, `headContents`, `blob` (index stage), and `revert`. Phase 3
/// (Task 9) adds the Log surface: `commits` (a `LogFilter`/`limit`-honouring
/// revwalk), `references`, `commitChanges`, and `fileContents`. Phase 4 (Task 10)
/// adds the conflict-resolution staging mutations `stage` (`git add` the resolved
/// working file) and `stageRemoval` (`git rm -f` for a modify/delete resolved to
/// the deleted side).
final class LibGit2Service: GitServicing, @unchecked Sendable {
    /// libgit2 requires a one-time global init (ref-counted, thread-safe). Run it
    /// exactly once per process via a lazily-evaluated static; the app never shuts
    /// libgit2 down, so there is no matching `git_libgit2_shutdown`.
    private static let bootstrap: Void = {
        git_libgit2_init()
    }()

    /// A dedicated serial queue for the blocking libgit2 work, shared across
    /// instances. Keeping it off the Swift concurrency cooperative pool means a slow
    /// repository operation never starves the pool's limited threads, and
    /// serializing every call also serializes repository access so two overlapping
    /// calls cannot race the same `.git` state — the same rationale as
    /// `GitCLIService`'s serial queue.
    private static let queue = DispatchQueue(label: "LibGit2Service.run")

    /// Brackets each git operation with the security-scoped access grant covering its
    /// repository, so the direct `FileManager`/libgit2 filesystem access succeeds on a
    /// real device (where a picked folder is inaccessible outside an active scope).
    /// `nil` — the simulator, the unit tests, app-container repos — runs unbracketed.
    private let scopeProvider: SecurityScopeProviding?

    /// The Personal-Access-Token store consulted by `fetch`'s credentials callback
    /// (the iOS Keychain wrapper in the real app). `nil` — no callback is installed,
    /// so `fetch` stays the public-repo-only path (Task 8); the Local Changes / Log /
    /// merge services never fetch, so they leave it `nil`.
    private let credentialStore: CredentialStore?

    init(scopeProvider: SecurityScopeProviding? = nil, credentialStore: CredentialStore? = nil) {
        self.scopeProvider = scopeProvider
        self.credentialStore = credentialStore
        _ = Self.bootstrap
    }

    // MARK: - Read surface

    /// The absolute top level of the working tree containing `url`.
    ///
    /// `git_repository_discover` walks up from the (possibly nested) opened folder
    /// to the `.git` directory; opening it and reading its work-dir yields the repo
    /// root, so every other call runs against one consistent root — exactly what
    /// `git rev-parse --show-toplevel` does on macOS. A discovery/open failure
    /// surfaces as `notARepository`.
    func repositoryRoot(for url: URL) async throws -> URL {
        try await run(scope: url) {
            var buf = git_buf()
            guard git_repository_discover(&buf, url.path, 0, nil) == 0 else {
                git_buf_dispose(&buf)
                throw GitError.notARepository(stderr: Self.lastError())
            }
            defer { git_buf_dispose(&buf) }

            var repo: OpaquePointer?
            guard git_repository_open(&repo, buf.ptr) == 0, let repo else {
                throw GitError.notARepository(stderr: Self.lastError())
            }
            defer { git_repository_free(repo) }

            guard let workdir = git_repository_workdir(repo) else {
                throw GitError.notARepository(stderr: "")
            }
            return URL(fileURLWithPath: String(cString: workdir), isDirectory: true)
        }
    }

    /// The files differing from `HEAD` in the repository at `root`.
    ///
    /// Mirrors `git status --porcelain=v2 -uall`: every untracked file listed
    /// individually, renames detected on both the head→index and index→workdir
    /// sides. The per-entry status bitmask is mapped to the same `FileStatus`
    /// precedence `GitStatusParser` uses (conflict → rename → untracked → add →
    /// delete → modified), so the produced `ChangedFile` values match the CLI path.
    func changedFiles(root: URL) async throws -> [ChangedFile] {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            var options = git_status_options()
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
            options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            options.flags = UInt32(
                GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
                    | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
                    | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
                    | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
            )

            var list: OpaquePointer?
            guard git_status_list_new(&list, repo, &options) == 0, let list else {
                throw GitError.notARepository(stderr: Self.lastError())
            }
            defer { git_status_list_free(list) }

            var files: [ChangedFile] = []
            let count = git_status_list_entrycount(list)
            for index in 0..<count {
                guard let entry = git_status_byindex(list, index) else { continue }
                if let file = Self.changedFile(from: entry.pointee) { files.append(file) }
            }
            return files
        }
    }

    /// The contents of `path` (repo-relative) at `HEAD`, or `nil` when the file does
    /// not exist there (a new/untracked file, or an unborn `HEAD`).
    func headContents(of path: String, root: URL) async throws -> String? {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            return Self.blobContents(repo: repo, revision: "HEAD", path: path)
        }
    }

    /// The contents of the `stage`-numbered index entry for the conflicted `path`,
    /// or `nil` when that stage does not exist.
    ///
    /// Reads the merge-index entry directly (`git_index_get_bypath(idx, path,
    /// stage)`): a missing stage (no common ancestor for add/add, the removed side
    /// of a modify/delete) returns `nil` exactly like the CLI's `git show :N:path`
    /// missing-object mapping.
    func blob(stage: Int, path: String, root: URL) async throws -> String? {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            var index: OpaquePointer?
            guard git_repository_index(&index, repo) == 0, let index else {
                throw GitError.notARepository(stderr: Self.lastError())
            }
            defer { git_index_free(index) }

            guard let entry = git_index_get_bypath(index, path, Int32(stage)) else { return nil }
            var oid = entry.pointee.id
            return Self.blobString(repo: repo, oid: &oid)
        }
    }

    // MARK: - Branch surface

    /// The currently checked-out local branch, or `nil` for an unborn HEAD (a fresh
    /// repo before the first commit) or a detached HEAD (pointing straight at a
    /// commit, on no branch).
    ///
    /// The libgit2 analogue of `git symbolic-ref --short HEAD`: an unborn/detached
    /// HEAD has no current local branch (→ `nil`), otherwise the resolved HEAD
    /// reference is a `refs/heads/<short>` branch, mapped to a `BranchRef` carrying
    /// the full refname (stable identity, matching the shape `references(root:)`
    /// returns), marked `isCurrent`.
    func currentBranch(root: URL) async throws -> BranchRef? {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            if git_repository_head_unborn(repo) == 1 { return nil }
            if git_repository_head_detached(repo) == 1 { return nil }

            var head: OpaquePointer?
            guard git_repository_head(&head, repo) == 0, let head else { return nil }
            defer { git_reference_free(head) }

            guard let namePtr = git_reference_name(head) else { return nil }
            let full = String(cString: namePtr)
            guard full.hasPrefix("refs/heads/") else { return nil }
            let short = String(full.dropFirst("refs/heads/".count))
            guard !short.isEmpty else { return nil }
            return BranchRef(
                name: full,
                isRemote: false,
                remoteName: nil,
                shortName: short,
                isCurrent: true
            )
        }
    }

    /// Check out the local branch `branch` (a short name, e.g. `main`).
    ///
    /// The libgit2 analogue of `git checkout <branch>`: a *safe* checkout of the
    /// branch tree (git refuses to overwrite conflicting local changes) followed by
    /// pointing HEAD at the branch. On `GIT_ECONFLICT` throw
    /// `GitError.checkoutFailed(reason:)` naming the conflicting paths libgit2
    /// reports, so the widget can show exactly what blocked the switch.
    func checkout(branch: String, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            try Self.checkoutBranch(branch, repo: repo)
        }
    }

    /// Create the branch `name` starting at `startPoint` (any ref/hash — a local
    /// branch, `origin/master`, `HEAD`) and check it out, in one step — the libgit2
    /// analogue of `git checkout -b <name> <startPoint>`.
    ///
    /// The caller validates `name` via `GitRefName.isValid(_:)` and, for a remote
    /// start point, fetches first. The start point is peeled to its commit,
    /// `git_branch_create`d, then checked out (safe). A bad start point or a
    /// blocked checkout throws `GitError.checkoutFailed(reason:)`.
    func createAndCheckout(name: String, startPoint: String, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            var startObject: OpaquePointer?
            guard git_revparse_single(&startObject, repo, startPoint) == 0, let startObject else {
                throw GitError.checkoutFailed(
                    reason: Self.checkoutReason("Could not resolve start point “\(startPoint)”.")
                )
            }
            defer { git_object_free(startObject) }

            var commit: OpaquePointer?
            guard git_object_peel(&commit, startObject, GIT_OBJECT_COMMIT) == 0, let commit else {
                throw GitError.checkoutFailed(
                    reason: Self.checkoutReason("“\(startPoint)” does not name a commit.")
                )
            }
            defer { git_object_free(commit) }

            var branchRef: OpaquePointer?
            guard git_branch_create(&branchRef, repo, name, commit, 0) == 0, let branchRef else {
                throw GitError.checkoutFailed(reason: Self.checkoutReason(Self.lastError()))
            }
            defer { git_reference_free(branchRef) }

            do {
                try Self.checkoutBranch(name, repo: repo)
            } catch {
                // The branch was created but the checkout failed. Undo the create so the
                // operation is all-or-nothing and a retry with the same name works —
                // matching `git checkout -b`, which never leaves the branch behind on a
                // blocked checkout.
                //
                // For the common `GIT_ECONFLICT` case (a dirty working tree),
                // `checkoutBranch` fails at `git_checkout_tree`, before
                // `git_repository_set_head`: HEAD was not moved, the new branch is not
                // current, and `git_branch_delete` cleanly rolls the whole operation
                // back. But `checkoutBranch` can also fail *after* `git_checkout_tree`
                // succeeds, at `git_repository_set_head` — there the worktree has already
                // been rewritten to the new branch's tree while we then delete the
                // branch, leaving a rewritten worktree on the previous HEAD. That is the
                // same non-atomicity `git checkout -b` itself has (worktree updated, ref
                // move can still fail), not a separate bug — so the rollback is left as
                // is.
                git_branch_delete(branchRef)
                throw error
            }
        }
    }

    /// Fetch `remote` into the repository at `root` over HTTPS.
    ///
    /// Part B (Task 8) wires the real libgit2 network transport: `git_remote_lookup`
    /// + `git_remote_fetch` with default `git_fetch_options`, going out over the
    /// built-in Apple TLS backend the pinned libgit2 ships (no `git` subprocess,
    /// which is impossible on iOS). Passing `nil` refspecs uses the remote's
    /// configured fetch refspecs — the same set `git fetch <remote>` uses — so the
    /// remote-tracking refs (`refs/remotes/<remote>/*`) advance and a subsequent
    /// create-from-`origin/…` sees the fetched commit.
    ///
    /// When a `credentialStore` is present (the real iOS app) a
    /// `GIT_CREDENTIAL_USERPASS_PLAINTEXT` credentials callback is installed (Task 9):
    /// it supplies the PAT stored for the remote's host (`GitCredentials.resolve`,
    /// keyed by `RemoteHost.host(fromRemoteURL:)`), so a **private** HTTPS repo
    /// fetches. A missing token for that host maps to `GitError.credentialsRequired`
    /// (the view directs the user to Settings), and a non-HTTPS origin — which a PAT
    /// can never authenticate on iOS (SSH is exec-based and unavailable) — fails up
    /// front with a clear "HTTPS origin required" message. A **public** repo never
    /// triggers the callback, so it fetches with or without a stored token. When
    /// `credentialStore` is `nil` no callback is installed and this stays the
    /// public-repo-only path.
    func fetch(remote: String, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            var remotePointer: OpaquePointer?
            guard git_remote_lookup(&remotePointer, repo, remote) == 0, let remotePointer else {
                throw GitError.fetchFailed(reason: Self.fetchReason(Self.lastError()))
            }
            defer { git_remote_free(remotePointer) }

            var options = git_fetch_options()
            git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))

            // Install the credentials callback only when a store is present; the
            // context outlives the synchronous fetch (see `withExtendedLifetime`).
            var context: CredentialContext?
            if let store = self.credentialStore {
                let remoteURL = git_remote_url(remotePointer).map { String(cString: $0) } ?? ""
                // A non-HTTPS origin can never be fetched on iOS — fail early with a
                // clear message rather than a cryptic transport error.
                guard RemoteHost.host(fromRemoteURL: remoteURL) != nil else {
                    throw GitError.fetchFailed(reason: Self.nonHTTPSFetchReason(remote))
                }
                let ctx = CredentialContext(store: store, remoteURL: remoteURL)
                context = ctx
                options.callbacks.payload = Unmanaged.passUnretained(ctx).toOpaque()
                options.callbacks.credentials = { cred, _, _, _, payload in
                    guard let payload else { return -1 }
                    let ctx = Unmanaged<CredentialContext>.fromOpaque(payload).takeUnretainedValue()
                    // Guard against libgit2 retrying a rejected token forever.
                    if ctx.attempted { return -1 }
                    ctx.attempted = true
                    let resolution = GitCredentials.resolve(remoteURL: ctx.remoteURL, store: ctx.store)
                    ctx.resolution = resolution
                    switch resolution {
                    case .credential(let credential):
                        return git_credential_userpass_plaintext_new(
                            cred, credential.username, credential.token
                        )
                    case .missingToken, .nonHTTPSRemote:
                        return -1
                    }
                }
            }

            // `nil` refspecs → the remote's configured fetch refspecs; `nil` reflog
            // message → libgit2's default ("fetch").
            let result = git_remote_fetch(remotePointer, nil, &options, nil)
            // The callback context must outlive the synchronous fetch above.
            withExtendedLifetime(context) {}
            guard result == 0 else {
                switch context?.resolution {
                case .missingToken(let host):
                    throw GitError.credentialsRequired(host: host)
                case .nonHTTPSRemote:
                    throw GitError.fetchFailed(reason: Self.nonHTTPSFetchReason(remote))
                default:
                    throw GitError.fetchFailed(reason: Self.fetchReason(Self.lastError()))
                }
            }
        }
    }

    /// The message for a fetch refused because the remote is not an HTTPS URL — the
    /// PAT-over-HTTPS path is the only iOS network transport (SSH is exec-based).
    private static func nonHTTPSFetchReason(_ remote: String) -> String {
        "The “\(remote)” remote is not an HTTPS URL. iOS can only fetch over HTTPS with a Personal Access Token — an SSH remote (git@…) is not supported."
    }

    /// A non-blank fetch failure reason: the trimmed libgit2/transport message, or a
    /// generic fallback when it is empty.
    private static func fetchReason(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not fetch from the remote." : trimmed
    }

    // MARK: - Conflict staging

    /// Stage the resolved working file at `path` (the `git add -- <path>`
    /// equivalent): `git_index_add_bypath` reads the working-tree file into the
    /// index at stage 0, which also clears the unmerged stages (1/2/3) for that
    /// path — recording the conflict resolution exactly as `git add` does. A
    /// failure surfaces as `GitError.notARepository` so `MergeModel.apply` can
    /// report it without claiming success.
    func stage(path: String, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            try Self.withIndex(repo: repo) { index in
                guard git_index_add_bypath(index, path) == 0 else {
                    throw GitError.notARepository(stderr: Self.lastError())
                }
            }
        }
    }

    /// Resolve a conflict to a deletion: delete the working-tree file, then remove
    /// `path` from the index (all stages, clearing the unmerged entries) — the
    /// `git rm -f -- <path>` equivalent used when a modify/delete conflict is
    /// resolved to the deleted side. A failure surfaces as `GitError`.
    ///
    /// The working-tree file is deleted *first*, then the index is updated (the order
    /// `git rm` uses). If the file deletion fails we throw before touching the index,
    /// so the conflict stays unresolved in the index rather than leaving the
    /// resolved-index / stale-working-file partial state `MergeModel.apply` cannot
    /// represent (and which a retry could not recover from — a second
    /// `git_index_remove_bypath` of an already-removed entry would itself fail).
    func stageRemoval(path: String, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            try Self.removeWorktreeFile(path, root: root)
            try Self.withIndex(repo: repo) { index in
                guard git_index_remove_bypath(index, path) == 0 else {
                    throw GitError.notARepository(stderr: Self.lastError())
                }
            }
        }
    }

    /// Open the repository index, run `body` against it, and write it back. Frees
    /// the index on exit. A failure to open or write surfaces as
    /// `GitError.notARepository`.
    private static func withIndex(repo: OpaquePointer, _ body: (OpaquePointer) throws -> Void) throws {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_index_free(index) }
        try body(index)
        guard git_index_write(index) == 0 else {
            throw GitError.notARepository(stderr: lastError())
        }
    }

    // MARK: - Log surface

    /// The commit history of the repository at `root`, most recent first.
    ///
    /// The libgit2 analogue of `git log --topo-order --parents -n <limit>` plus the
    /// `LogFilter` constraints: a `git_revwalk` in topological order, seeded from the
    /// filter's ref selection (`.all` → every ref under `refs/*`; `.ref` → that named
    /// ref), with the author/date dimensions applied as in-walk predicates and the
    /// path dimension applied via history simplification (see
    /// `walkWithPathSimplification`). It produces the *same* `Commit` values the CLI
    /// `Commit.parse` path produces — full hash, parent hashes (first parent first),
    /// author, ISO-8601 author date, subject, and the bare ref decorations that point
    /// at each commit — so `CommitLogModel` and `CommitGraphLayout` behave identically
    /// across platforms.
    ///
    /// Note: the path filter walks the full reachable history (diffing each commit
    /// against its first parent) to simplify parent pointers; on a very large
    /// repository this is more expensive than git's optimized pathspec walk. The
    /// common ref/author/date cases stop as soon as `limit` commits are collected.
    func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            let decorations = Self.refDecorations(repo: repo)
            return try Self.walkCommits(repo: repo, filter: filter, limit: limit, decorations: decorations)
        }
    }

    /// The branch/tag ref names in the repository at `root`, for the Log filter bar's
    /// ref picker — **full** refnames (`refs/heads/main`, `refs/remotes/origin/main`,
    /// `refs/tags/v1.0`), local branches first, then remotes, then tags, each bucket
    /// sorted for stable ordering. The full name (not the short form) is the picker's
    /// unambiguous `git log` revision, exactly as `GitCLIService.references` returns.
    func references(root: URL) async throws -> [String] {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            return Self.listReferences(repo: repo)
        }
    }

    /// The files changed by `hash` relative to its first parent (the empty tree for a
    /// root commit), with rename detection — the libgit2 analogue of `git diff-tree
    /// --name-status -M -m --first-parent --root <hash>`. Each `git_diff_delta` maps
    /// to the same `ChangedFile`/`FileStatus` `CommitChangesParser` produces (a copy
    /// reports only the new path as `.added`, matching the CLI). A merge diffs against
    /// its first parent (the mainline change set).
    func commitChanges(hash: String, root: URL) async throws -> [ChangedFile] {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            return try Self.changes(repo: repo, hash: hash)
        }
    }

    /// The contents of `path` (repo-relative) at the commit-ish `revision`, or `nil`
    /// when the file does not exist there — the libgit2 analogue of
    /// `git show <revision>:<path>`. Reuses the `revision:path` blob lookup
    /// `headContents` uses, so a missing object (the parent side of an added file)
    /// yields `nil` rather than throwing, exactly like the CLI path.
    func fileContents(at revision: String, path: String, root: URL) async throws -> String? {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }
            return Self.blobContents(repo: repo, revision: revision, path: path)
        }
    }

    // MARK: - Revert

    /// Discard the local changes to `file`, restoring its `HEAD` version.
    ///
    /// Matches the macOS service's per-`FileStatus` behaviour:
    /// - `.modified`/`.deleted`/`.conflicted`: force-checkout the file's `HEAD`
    ///   tree entry, restoring both the working tree and the index.
    /// - `.added`: unstage (`git_index_remove_bypath` + write) and delete the
    ///   working file (it has no `HEAD` version). A failure that already removed the
    ///   worktree file reports it via `LibGit2InterruptedRevert`.
    /// - `.untracked`: delete the working file (git does not track it).
    /// - `.renamed`: restore `oldPath` from `HEAD`, then unstage+remove the new
    ///   path. Refuse if something already occupies `oldPath` (so an unrelated file
    ///   recreated there is never clobbered). The two steps are not atomic, so a
    ///   failure after the first throws `LibGit2InterruptedRevert` naming the paths
    ///   already changed.
    ///
    /// (The macOS CLI's extra case-only-rename / hard-link disambiguation exists to
    /// work around `git checkout`+`git rm` being two non-atomic *processes*; the
    /// libgit2 index operations here are a single in-process index write, so that
    /// corner does not arise the same way.)
    func revert(_ file: ChangedFile, root: URL) async throws {
        try await run(scope: root) {
            let repo = try self.openRepo(at: root)
            defer { git_repository_free(repo) }

            switch file.status {
            case .modified, .deleted, .conflicted:
                try Self.checkout(file.path, repo: repo)

            case .added:
                let url = root.appendingPathComponent(file.path)
                // `lstat` (via `pathExists`), not `FileManager.fileExists`, so a
                // dangling symlink is probed faithfully — matching the macOS `remove`.
                let existedBefore = Self.pathExists(url)
                do {
                    try Self.unstageAndDelete(file.path, repo: repo, root: root)
                } catch {
                    let removed = existedBefore && !Self.pathExists(url)
                    throw LibGit2InterruptedRevert(
                        changedPaths: removed ? [file.path] : [],
                        underlying: error
                    )
                }

            case .untracked:
                try Self.removeWorktreeFile(file.path, root: root)

            case .renamed:
                try Self.revertRename(file, repo: repo, root: root)
            }
        }
    }

    // MARK: - libgit2 helpers (run on the serial queue)

    /// Undo a rename: restore `oldPath` from `HEAD`, then unstage+remove the new
    /// path. Refuses to clobber an occupied `oldPath`; reports a between-steps
    /// failure via `LibGit2InterruptedRevert`.
    private static func revertRename(_ file: ChangedFile, repo: OpaquePointer, root: URL) throws {
        guard let oldPath = file.oldPath else {
            // No recorded old path: fall back to undoing the new side like an add.
            try unstageAndDelete(file.path, repo: repo, root: root)
            return
        }

        let oldURL = root.appendingPathComponent(oldPath)
        // `lstat` (via `pathExists`), not `FileManager.fileExists`, so a *dangling*
        // symlink occupying the old path is still caught (fileExists dereferences
        // and would miss it) — matching `GitCLIService.revertRename`.
        if pathExists(oldURL) {
            throw GitError.revertFailed(
                reason: "“\(oldPath)” already exists; refusing to overwrite it while undoing the rename."
            )
        }

        var changed: [String] = []
        do {
            try checkout(oldPath, repo: repo)
            changed.append(oldPath)
            try unstageAndDelete(file.path, repo: repo, root: root)
        } catch {
            throw LibGit2InterruptedRevert(changedPaths: changed, underlying: error)
        }
    }

    /// Force-checkout `path` from `HEAD`'s tree, restoring its working-tree and
    /// index state (the `git checkout HEAD -- <path>` equivalent).
    ///
    /// Two steps, because `git_checkout_tree` alone does not match the CLI for a
    /// *staged-only* change (the index differs from `HEAD` while the working tree
    /// already equals `HEAD`): its baseline-to-target diff is empty (both are
    /// `HEAD`) and the working file already matches, so no blob update fires and the
    /// staged index entry is left untouched — the file would stay in Local Changes.
    /// `git checkout HEAD -- <path>` resets *both* the index and the working tree, so
    /// after the worktree checkout we also `git_reset_default` the index entry to
    /// `HEAD` (a no-op when the checkout already updated it).
    private static func checkout(_ path: String, repo: OpaquePointer) throws {
        var headObject: OpaquePointer?
        guard git_revparse_single(&headObject, repo, "HEAD") == 0, let headObject else {
            throw GitError.revertFailed(reason: lastError())
        }
        defer { git_object_free(headObject) }

        var tree: OpaquePointer?
        guard git_object_peel(&tree, headObject, GIT_OBJECT_TREE) == 0, let tree else {
            throw GitError.revertFailed(reason: lastError())
        }
        defer { git_tree_free(tree) }

        var commit: OpaquePointer?
        guard git_object_peel(&commit, headObject, GIT_OBJECT_COMMIT) == 0, let commit else {
            throw GitError.revertFailed(reason: lastError())
        }
        defer { git_object_free(commit) }

        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)

        let cPath = strdup(path)
        defer { free(cPath) }
        var pointers: [UnsafeMutablePointer<CChar>?] = [cPath]
        try pointers.withUnsafeMutableBufferPointer { buffer in
            var paths = git_strarray(strings: buffer.baseAddress, count: 1)
            options.paths = paths
            guard git_checkout_tree(repo, tree, &options) == 0 else {
                throw GitError.revertFailed(reason: lastError())
            }
            // Reset the index entry for `path` to HEAD as well, so a staged-only
            // change is unstaged — matching `git checkout HEAD -- <path>`.
            guard git_reset_default(repo, commit, &paths) == 0 else {
                throw GitError.revertFailed(reason: lastError())
            }
        }
    }

    /// A mutable box collecting the conflicting paths libgit2's checkout notify
    /// callback reports (the callback is a capture-free C function pointer, so it
    /// receives the box through the `notify_payload` pointer).
    private final class ConflictPaths {
        var paths: [String] = []
    }

    /// Carries the credential store + remote URL into the capture-free C credentials
    /// callback (via the fetch options `payload`) and records the resolution outcome,
    /// so a fetch failure can be mapped to `credentialsRequired`/an HTTPS-required
    /// message. `attempted` guards against libgit2 retrying a rejected token forever.
    private final class CredentialContext {
        let store: CredentialStore
        let remoteURL: String
        var resolution: CredentialResolution?
        var attempted = false

        init(store: CredentialStore, remoteURL: String) {
            self.store = store
            self.remoteURL = remoteURL
        }
    }

    /// Safe-checkout the local branch `name` and point HEAD at it — the shared
    /// worker behind `checkout` and `createAndCheckout`. Looks up the branch, peels
    /// it to a tree, `git_checkout_tree`s it with a conflict-collecting notify
    /// callback, then `git_repository_set_head`s. A `GIT_ECONFLICT` result throws
    /// `GitError.checkoutFailed` naming the collected paths; any other non-zero
    /// result throws with libgit2's last error.
    private static func checkoutBranch(_ name: String, repo: OpaquePointer) throws {
        var branchRef: OpaquePointer?
        guard git_branch_lookup(&branchRef, repo, name, GIT_BRANCH_LOCAL) == 0, let branchRef else {
            throw GitError.checkoutFailed(reason: checkoutReason("No such branch “\(name)”."))
        }
        defer { git_reference_free(branchRef) }

        var tree: OpaquePointer?
        guard git_reference_peel(&tree, branchRef, GIT_OBJECT_TREE) == 0, let tree else {
            throw GitError.checkoutFailed(reason: checkoutReason(lastError()))
        }
        defer { git_object_free(tree) }

        var options = git_checkout_options()
        git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        options.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

        let collector = ConflictPaths()
        options.notify_flags = UInt32(GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue)
        options.notify_payload = Unmanaged.passUnretained(collector).toOpaque()
        options.notify_cb = { _, path, _, _, _, payload in
            guard let payload, let path else { return 0 }
            let collector = Unmanaged<ConflictPaths>.fromOpaque(payload).takeUnretainedValue()
            collector.paths.append(String(cString: path))
            return 0
        }

        let result = git_checkout_tree(repo, tree, &options)
        // `collector` must outlive the synchronous checkout call above.
        withExtendedLifetime(collector) {}
        if result == GIT_ECONFLICT.rawValue {
            throw GitError.checkoutFailed(reason: conflictMessage(collector.paths))
        }
        guard result == 0 else {
            throw GitError.checkoutFailed(reason: checkoutReason(lastError()))
        }

        guard let namePtr = git_reference_name(branchRef) else {
            throw GitError.checkoutFailed(reason: checkoutReason(""))
        }
        guard git_repository_set_head(repo, String(cString: namePtr)) == 0 else {
            throw GitError.checkoutFailed(reason: checkoutReason(lastError()))
        }
    }

    /// A human-readable checkout-conflict message naming the collected paths, or a
    /// generic fallback (libgit2's last error, else a fixed string) when none were
    /// collected — so `errorDescription` is never blank.
    private static func conflictMessage(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return checkoutReason(lastError()) }
        let list = paths.map { "  \($0)" }.joined(separator: "\n")
        return "Your local changes to the following files would be overwritten by switching branches:\n\(list)"
    }

    /// A non-blank checkout failure reason: the trimmed message, or a generic
    /// fallback when it is empty.
    private static func checkoutReason(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not switch branches." : trimmed
    }

    /// Remove `path` from the index (all stages) and delete its working-tree file —
    /// the `git rm -f -- <path>` equivalent used to undo an added/renamed-new file.
    private static func unstageAndDelete(_ path: String, repo: OpaquePointer, root: URL) throws {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else {
            throw GitError.revertFailed(reason: lastError())
        }
        defer { git_index_free(index) }

        git_index_remove_bypath(index, path)
        guard git_index_write(index) == 0 else {
            throw GitError.revertFailed(reason: lastError())
        }

        try removeWorktreeFile(path, root: root)
    }

    /// Delete the working-tree file at `path` (relative to `root`) safely — the iOS
    /// peer of `GitCLIService.removeUntracked`, used by every iOS worktree deletion
    /// (untracked revert, added/rename-new unstage, modify/delete stage-removal).
    ///
    /// `FileManager.removeItem` on a full path is unsafe against a stale status
    /// snapshot: if a parent directory was swapped for a symlink it follows it out of
    /// the repository, and if the path itself became a *directory* it recurses and
    /// destroys unrelated contents. So we never hand a full path to the OS — we walk
    /// each component down from the trusted `root` with `openat(O_NOFOLLOW |
    /// O_DIRECTORY)` (a symlinked component fails with `ELOOP`/`ENOTDIR` rather than
    /// being followed) and `unlinkat(..., 0)` the final name (never recurses, so a
    /// directory yields `EPERM`/`EISDIR` — a refusal, not a recursive wipe; it also
    /// removes a final symlink itself rather than its target). `ENOENT` anywhere is
    /// success — nothing left to discard.
    private static func removeWorktreeFile(_ path: String, root: URL) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last else { return }

        // The repo root is the trusted anchor; it is opened normally, every
        // component below it uses `O_NOFOLLOW`.
        var dirFD = open(root.path, O_RDONLY | O_DIRECTORY)
        guard dirFD >= 0 else {
            if errno == ENOENT { return }
            throw GitError.revertFailed(
                reason: "Could not delete “\(path)”: \(String(cString: strerror(errno)))."
            )
        }

        for component in components.dropLast() {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            let openErrno = errno
            close(dirFD)
            guard next >= 0 else {
                if openErrno == ENOENT { return }
                if openErrno == ELOOP || openErrno == ENOTDIR {
                    throw GitError.revertFailed(
                        reason: "“\(path)” is no longer a plain file inside the repository; refusing to delete it."
                    )
                }
                throw GitError.revertFailed(
                    reason: "Could not delete “\(path)”: \(String(cString: strerror(openErrno)))."
                )
            }
            dirFD = next
        }

        let removed = unlinkat(dirFD, fileName, 0)
        let unlinkErrno = errno
        close(dirFD)
        guard removed != 0 else { return }
        switch unlinkErrno {
        case ENOENT:
            return
        case EPERM, EISDIR:
            throw GitError.revertFailed(
                reason: "“\(path)” is now a directory; refusing to delete it recursively."
            )
        default:
            throw GitError.revertFailed(
                reason: "Could not delete “\(path)”: \(String(cString: strerror(unlinkErrno)))."
            )
        }
    }

    /// Map a libgit2 status entry to a `ChangedFile`, using the same status
    /// precedence as `GitStatusParser` so both code paths agree.
    private static func changedFile(from entry: git_status_entry) -> ChangedFile? {
        let status = entry.status.rawValue
        func has(_ flag: git_status_t) -> Bool { (status & flag.rawValue) != 0 }

        func newPath() -> String? {
            if let delta = entry.index_to_workdir, let p = delta.pointee.new_file.path {
                return String(cString: p)
            }
            if let delta = entry.head_to_index, let p = delta.pointee.new_file.path {
                return String(cString: p)
            }
            return nil
        }
        func oldPath(_ delta: UnsafeMutablePointer<git_diff_delta>?) -> String? {
            guard let delta, let p = delta.pointee.old_file.path else { return nil }
            return String(cString: p)
        }

        let resolvedStatus: FileStatus
        var renamedFrom: String?

        if has(GIT_STATUS_CONFLICTED) {
            resolvedStatus = .conflicted
        } else if has(GIT_STATUS_INDEX_RENAMED) {
            resolvedStatus = .renamed
            renamedFrom = oldPath(entry.head_to_index)
        } else if has(GIT_STATUS_WT_RENAMED) {
            resolvedStatus = .renamed
            renamedFrom = oldPath(entry.index_to_workdir)
        } else if has(GIT_STATUS_WT_NEW)
                    && !has(GIT_STATUS_INDEX_NEW)
                    && !has(GIT_STATUS_INDEX_MODIFIED)
                    && !has(GIT_STATUS_INDEX_DELETED) {
            resolvedStatus = .untracked
        } else if has(GIT_STATUS_INDEX_NEW) {
            resolvedStatus = .added
        } else if has(GIT_STATUS_INDEX_DELETED) || has(GIT_STATUS_WT_DELETED) {
            resolvedStatus = .deleted
        } else {
            resolvedStatus = .modified
        }

        guard let path = newPath() else { return nil }
        return ChangedFile(path: path, status: resolvedStatus, oldPath: renamedFrom)
    }

    /// The contents of the blob at `revision:path` (e.g. `HEAD:src/file.swift`), or
    /// `nil` when the revision or the path within it is absent.
    private static func blobContents(repo: OpaquePointer, revision: String, path: String) -> String? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repo, revision) == 0, let object else { return nil }
        defer { git_object_free(object) }

        var tree: OpaquePointer?
        guard git_object_peel(&tree, object, GIT_OBJECT_TREE) == 0, let tree else { return nil }
        defer { git_tree_free(tree) }

        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else { return nil }
        defer { git_tree_entry_free(entry) }

        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
        guard let oid = git_tree_entry_id(entry) else { return nil }

        var copiedOID = oid.pointee
        return blobString(repo: repo, oid: &copiedOID)
    }

    /// Look up the blob `oid` in `repo` and decode its raw bytes as UTF-8.
    private static func blobString(repo: OpaquePointer, oid: inout git_oid) -> String? {
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, &oid) == 0, let blob else { return nil }
        defer { git_blob_free(blob) }

        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let raw = git_blob_rawcontent(blob) else { return "" }
        return String(decoding: Data(bytes: raw, count: size), as: UTF8.self)
    }

    /// Open the repository at `root` (already the resolved working-tree top).
    private func openRepo(at root: URL) throws -> OpaquePointer {
        var repo: OpaquePointer?
        guard git_repository_open(&repo, root.path) == 0, let repo else {
            throw GitError.notARepository(stderr: Self.lastError())
        }
        return repo
    }

    /// Whether anything (including a dangling symlink) occupies `url`, via `lstat`.
    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return errno != ENOENT
    }

    /// The last libgit2 error message for the current thread, or "" when none.
    private static func lastError() -> String {
        guard let error = git_error_last(), let message = error.pointee.message else { return "" }
        return String(cString: message)
    }

    // MARK: - Log helpers (run on the serial queue)

    /// Walk the commit history per `filter`, newest first, capped at `limit`.
    ///
    /// Ref-only/author/date filters take the fast path: a topo-order revwalk seeded
    /// from the ref selection, applying the author/date predicate in-walk and stopping
    /// at `limit`. A path filter routes to `walkWithPathSimplification`, which must
    /// rewrite parent pointers, so it cannot stop early.
    private static func walkCommits(
        repo: OpaquePointer,
        filter: LogFilter,
        limit: Int,
        decorations: [String: [String]]
    ) throws -> [Commit] {
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repo) == 0, let walk else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, UInt32(GIT_SORT_TOPOLOGICAL.rawValue))
        pushRefs(walk: walk, repo: repo, selection: filter.refSelection)

        if let path = filter.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return walkWithPathSimplification(
                repo: repo, walk: walk, filter: filter, path: path,
                limit: limit, decorations: decorations
            )
        }

        var result: [Commit] = []
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }
            guard matches(commit: commit, filter: filter) else { continue }
            result.append(makeCommit(commit, decorations: decorations))
            if result.count >= limit { break }
        }
        return result
    }

    /// Walk with git-style path simplification: keep only commits that touch `path`
    /// (and pass the author/date predicate) and rewrite each kept commit's parent
    /// pointers to its nearest kept ancestors, so the branch graph stays contiguous
    /// (the `--parents` parent-rewriting the CLI relies on). Because a parent may be
    /// simplified away, the whole reachable history must be walked before the result
    /// can be assembled, so this path cannot stop at `limit` mid-walk.
    private static func walkWithPathSimplification(
        repo: OpaquePointer,
        walk: OpaquePointer,
        filter: LogFilter,
        path: String,
        limit: Int,
        decorations: [String: [String]]
    ) -> [Commit] {
        // Newest-first order plus, per hash, its original parents / the built Commit /
        // whether it is kept (touches the path and passes author+date).
        var order: [String] = []
        var info: [String: (parents: [String], commit: Commit, kept: Bool)] = [:]

        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }
            let built = makeCommit(commit, decorations: decorations)
            let kept = commitTouchesPath(repo: repo, commit: commit, path: path)
                && matches(commit: commit, filter: filter)
            order.append(built.hash)
            info[built.hash] = (built.parents, built, kept)
        }

        // rewritten(hash) = nearest kept ancestors of `hash`. Computed oldest-first so
        // every parent's value is already known: a kept commit maps to itself, a
        // dropped commit to the union of its parents' rewrites.
        var rewritten: [String: [String]] = [:]
        for hash in order.reversed() {
            guard let node = info[hash] else { continue }
            if node.kept {
                rewritten[hash] = [hash]
            } else {
                rewritten[hash] = simplifiedParents(of: node.parents, rewritten: rewritten)
            }
        }

        var result: [Commit] = []
        for hash in order {
            guard let node = info[hash], node.kept else { continue }
            let parents = simplifiedParents(of: node.parents, rewritten: rewritten)
            let c = node.commit
            result.append(Commit(
                hash: c.hash, parents: parents, author: c.author,
                date: c.date, subject: c.subject, refs: c.refs
            ))
            if result.count >= limit { break }
        }
        return result
    }

    /// The order-preserving, de-duplicated union of the rewrites of `parents`.
    private static func simplifiedParents(
        of parents: [String],
        rewritten: [String: [String]]
    ) -> [String] {
        var acc: [String] = []
        var seen = Set<String>()
        for parent in parents {
            for ancestor in rewritten[parent] ?? [] where seen.insert(ancestor).inserted {
                acc.append(ancestor)
            }
        }
        return acc
    }

    /// Seed the revwalk from the filter's ref selection: `.all` pushes every ref under
    /// `refs/*` *and* `HEAD`; a named `.ref` pushes that ref (falling back to a
    /// revision peel), and a blank name degrades to all refs, mirroring
    /// `LogFilter.gitArguments()`. A missing ref simply yields an empty walk rather
    /// than throwing.
    private static func pushRefs(walk: OpaquePointer, repo: OpaquePointer, selection: LogFilter.RefSelection) {
        switch selection {
        case .all:
            pushAllRefs(walk: walk)
        case .ref(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pushAllRefs(walk: walk)
                return
            }
            if git_revwalk_push_ref(walk, trimmed) == 0 { return }
            // Not a pushable refname: resolve it as a revision and push its commit.
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, trimmed) == 0, let object else { return }
            defer { git_object_free(object) }
            var commit: OpaquePointer?
            guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0, let commit else { return }
            defer { git_object_free(commit) }
            if let oidPtr = git_object_id(commit) {
                var oid = oidPtr.pointee
                git_revwalk_push(walk, &oid)
            }
        }
    }

    /// Push every ref under `refs/*` plus `HEAD` — the libgit2 equivalent of
    /// `git log --all`, which the git docs define as "all the refs in refs/, along
    /// with HEAD". Pushing `HEAD` explicitly so a detached, otherwise-unreferenced
    /// HEAD commit (e.g. a commit made while detached, on no branch) still appears —
    /// the `refs/*` glob alone would drop it, diverging from the macOS `--all` path.
    /// A push of an unborn/absent HEAD fails harmlessly (ignored).
    private static func pushAllRefs(walk: OpaquePointer) {
        _ = git_revwalk_push_glob(walk, "refs/*")
        _ = git_revwalk_push_head(walk)
    }

    /// Whether `commit` satisfies the author and date dimensions of `filter`. The
    /// author is matched case-insensitively as a substring of "name <email>" (a
    /// pragmatic stand-in for git's `--author` regex); the date bounds compare the
    /// commit time inclusively (`since` ≤ time ≤ `until`).
    private static func matches(commit: OpaquePointer, filter: LogFilter) -> Bool {
        if let author = filter.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            let signature = git_commit_author(commit)
            let name = signature?.pointee.name.map { String(cString: $0) } ?? ""
            let email = signature?.pointee.email.map { String(cString: $0) } ?? ""
            if "\(name) <\(email)>".range(of: author, options: .caseInsensitive) == nil { return false }
        }
        let time = TimeInterval(git_commit_time(commit))
        if let since = filter.since, time < since.timeIntervalSince1970 { return false }
        if let until = filter.until, time > until.timeIntervalSince1970 { return false }
        return true
    }

    /// Build a `Commit` value from a libgit2 commit, attaching any ref decorations
    /// pointing at it. The date is the author date as a strict UTC ISO-8601 string
    /// (the view formats it for display), matching `Commit`'s locale-free contract.
    private static func makeCommit(_ commit: OpaquePointer, decorations: [String: [String]]) -> Commit {
        let hash = git_commit_id(commit).map { oidString($0) } ?? ""
        var parents: [String] = []
        for index in 0..<git_commit_parentcount(commit) {
            if let parentID = git_commit_parent_id(commit, index) {
                parents.append(oidString(parentID))
            }
        }
        let signature = git_commit_author(commit)
        let author = signature?.pointee.name.map { String(cString: $0) } ?? ""
        let date = signature.map { isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0.pointee.when.time))) } ?? ""
        let subject = git_commit_summary(commit).map { String(cString: $0) } ?? ""
        return Commit(
            hash: hash, parents: parents, author: author,
            date: date, subject: subject, refs: decorations[hash] ?? []
        )
    }

    /// Map every branch/tag ref to the bare decoration name (`main`, `origin/main`,
    /// `v1.0`) of the commit it points at, peeling annotated tags — the libgit2
    /// equivalent of git's `%D` decoration (after `Commit.parseRefs` strips prefixes).
    private static func refDecorations(repo: OpaquePointer) -> [String: [String]] {
        var map: [String: [String]] = [:]
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        guard git_reference_iterator_new(&iterator, repo) == 0, let iterator else { return map }
        defer { git_reference_iterator_free(iterator) }

        var reference: OpaquePointer?
        while git_reference_next(&reference, iterator) == 0 {
            guard let reference else { continue }
            defer { git_reference_free(reference) }
            guard let namePtr = git_reference_name(reference) else { continue }
            guard let short = shortDecorationName(String(cString: namePtr)) else { continue }
            var object: OpaquePointer?
            guard git_reference_peel(&object, reference, GIT_OBJECT_COMMIT) == 0, let object else { continue }
            defer { git_object_free(object) }
            guard let oidPtr = git_object_id(object) else { continue }
            map[oidString(oidPtr), default: []].append(short)
        }
        return map
    }

    /// The bare decoration name for a full refname, or `nil` for a ref that is not a
    /// branch/remote/tag (so HEAD and other pseudo-refs are not decorated).
    private static func shortDecorationName(_ full: String) -> String? {
        if full.hasPrefix("refs/heads/") { return String(full.dropFirst("refs/heads/".count)) }
        if full.hasPrefix("refs/remotes/") { return String(full.dropFirst("refs/remotes/".count)) }
        if full.hasPrefix("refs/tags/") { return String(full.dropFirst("refs/tags/".count)) }
        return nil
    }

    /// Full refnames for the filter picker — heads, then remotes, then tags, each
    /// bucket sorted.
    private static func listReferences(repo: OpaquePointer) -> [String] {
        var heads: [String] = []
        var remotes: [String] = []
        var tags: [String] = []
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        guard git_reference_iterator_new(&iterator, repo) == 0, let iterator else { return [] }
        defer { git_reference_iterator_free(iterator) }

        var namePtr: UnsafePointer<CChar>?
        while git_reference_next_name(&namePtr, iterator) == 0 {
            guard let namePtr else { continue }
            let name = String(cString: namePtr)
            if name.hasPrefix("refs/heads/") {
                heads.append(name)
            } else if name.hasPrefix("refs/remotes/") {
                remotes.append(name)
            } else if name.hasPrefix("refs/tags/") {
                tags.append(name)
            }
        }
        return heads.sorted() + remotes.sorted() + tags.sorted()
    }

    /// The files changed by `hash` vs its first parent (empty tree for a root commit),
    /// with rename detection — see `commitChanges`.
    private static func changes(repo: OpaquePointer, hash: String) throws -> [ChangedFile] {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repo, hash) == 0, let object else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0, let commit else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_object_free(commit) }

        var newTree: OpaquePointer?
        guard git_commit_tree(&newTree, commit) == 0, let newTree else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_tree_free(newTree) }

        var oldTree: OpaquePointer? = firstParentTree(of: commit)
        defer { if let oldTree { git_tree_free(oldTree) } }

        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &options) == 0, let diff else {
            throw GitError.notARepository(stderr: lastError())
        }
        defer { git_diff_free(diff) }

        var findOptions = git_diff_find_options()
        git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        findOptions.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
        git_diff_find_similar(diff, &findOptions)

        var files: [ChangedFile] = []
        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index) else { continue }
            if let file = changedFile(fromDelta: delta.pointee) { files.append(file) }
        }
        return files
    }

    /// The tree of `commit`'s first parent, or `nil` for a root commit (caller owns
    /// and frees the returned tree).
    private static func firstParentTree(of commit: OpaquePointer) -> OpaquePointer? {
        guard git_commit_parentcount(commit) > 0 else { return nil }
        var parent: OpaquePointer?
        guard git_commit_parent(&parent, commit, 0) == 0, let parent else { return nil }
        defer { git_commit_free(parent) }
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, parent) == 0 else { return nil }
        return tree
    }

    /// Whether `commit` touches `path` relative to its first parent, via a pathspec-
    /// limited tree diff (used by the path-filter history simplification).
    private static func commitTouchesPath(repo: OpaquePointer, commit: OpaquePointer, path: String) -> Bool {
        var newTree: OpaquePointer?
        guard git_commit_tree(&newTree, commit) == 0, let newTree else { return false }
        defer { git_tree_free(newTree) }
        var oldTree: OpaquePointer? = firstParentTree(of: commit)
        defer { if let oldTree { git_tree_free(oldTree) } }

        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        var touched = false
        let cPath = strdup(path)
        defer { free(cPath) }
        var pointers: [UnsafeMutablePointer<CChar>?] = [cPath]
        pointers.withUnsafeMutableBufferPointer { buffer in
            options.pathspec = git_strarray(strings: buffer.baseAddress, count: 1)
            var diff: OpaquePointer?
            if git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &options) == 0, let diff {
                touched = git_diff_num_deltas(diff) > 0
                git_diff_free(diff)
            }
        }
        return touched
    }

    /// Map a libgit2 diff delta to a `ChangedFile`, matching `CommitChangesParser`'s
    /// status mapping (a copy reports only the new path as `.added`).
    private static func changedFile(fromDelta delta: git_diff_delta) -> ChangedFile? {
        func newPath() -> String? { delta.new_file.path.map { String(cString: $0) } }
        func oldPath() -> String? { delta.old_file.path.map { String(cString: $0) } }

        let status = delta.status
        if status == GIT_DELTA_ADDED {
            return newPath().map { ChangedFile(path: $0, status: .added) }
        } else if status == GIT_DELTA_DELETED {
            return oldPath().map { ChangedFile(path: $0, status: .deleted) }
        } else if status == GIT_DELTA_MODIFIED || status == GIT_DELTA_TYPECHANGE {
            return newPath().map { ChangedFile(path: $0, status: .modified) }
        } else if status == GIT_DELTA_RENAMED {
            guard let path = newPath() else { return nil }
            return ChangedFile(path: path, status: .renamed, oldPath: oldPath())
        } else if status == GIT_DELTA_COPIED {
            return newPath().map { ChangedFile(path: $0, status: .added) }
        }
        return nil
    }

    /// The hex string of an oid (via libgit2's thread-local formatting buffer; safe
    /// because every libgit2 call here runs on the serial queue).
    private static func oidString(_ oid: UnsafePointer<git_oid>) -> String {
        guard let cString = git_oid_tostr_s(oid) else { return "" }
        return String(cString: cString)
    }

    /// Strict UTC ISO-8601, matching `Commit`'s locale-free date contract.
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Concurrency

    /// Run the synchronous libgit2 `body` on the serial queue, bridged to `async` —
    /// mirroring `GitCLIService.run` so the cooperative pool is never blocked and
    /// repository access stays serialized. `scope` is the url whose security-scoped
    /// grant must be active for `body`'s filesystem access (the repository root, or
    /// the discovery url for `repositoryRoot`); the grant is acquired on the queue
    /// just around `body`.
    private func run<T>(scope: URL, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let value = try self.withSecurityScope(covering: scope) { try body() }
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run `body` under the covering security scope when a provider is present, else
    /// run it directly (simulator / tests / app-container repos need no scope).
    private func withSecurityScope<T>(covering target: URL, _ body: () throws -> T) throws -> T {
        guard let scopeProvider else { return try body() }
        return try scopeProvider.withSecurityScope(covering: target, body)
    }
}
#endif
