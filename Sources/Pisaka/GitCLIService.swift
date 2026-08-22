#if os(macOS)
import Foundation
import PisakaCore

/// A rename revert that failed after partially changing the working tree.
///
/// A rename revert restores the old path from `HEAD`, then removes the new path;
/// a failure between those steps leaves the old path already restored. This
/// carries the repo-relative paths that actually changed so `LocalChangesModel`
/// resyncs only those open tabs (see `PartialRevertError`). `localizedDescription`
/// defers to the underlying git/filesystem error so the user sees the real cause.
struct InterruptedRevert: PartialRevertError, LocalizedError {
    let changedPaths: [String]
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// `Process`-backed implementation of `GitServicing`, shelling out to the `git`
/// CLI. This is the real, macOS-only counterpart to the pure parsing/model code
/// in `PisakaCore`: it keeps all `Process` use in the view target, feeding raw
/// `git` output to Core's `GitStatusParser` and returning Foundation values.
struct GitCLIService: GitServicing {
    /// The absolute top level of the working tree containing `url`, via
    /// `git rev-parse --show-toplevel`.
    ///
    /// The Local Changes view runs every other git call against this resolved
    /// root rather than the (possibly nested) opened folder, so `git status`
    /// paths come out repo-root-relative and therefore match the
    /// `git show HEAD:<path>` lookups (which are always repo-root-relative). A
    /// non-zero exit (the folder is not inside a repo / `git` cannot interpret
    /// it) surfaces as `notARepository`, the same as `changedFiles`.
    func repositoryRoot(for url: URL) async throws -> URL {
        let result = try await run(["rev-parse", "--show-toplevel"], in: url)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The files differing from `HEAD` in the repository at `root`.
    ///
    /// Runs `git status --porcelain=v2 -uall` (stable, machine-readable output;
    /// `-uall` lists every untracked file individually rather than collapsing a
    /// directory) and hands stdout to `GitStatusParser.parse`.
    func changedFiles(root: URL) async throws -> [ChangedFile] {
        // `-c core.quotePath=false` keeps non-ASCII paths (Cyrillic, CJK, emoji,
        // accented Latin) raw in the output. Git's default quotes them with
        // C-style octal escapes, which `GitStatusParser` does not unquote — the
        // escaped path would then fail both `git show HEAD:<path>` and the
        // working-copy read, so the diff would come up empty for such files.
        let result = try await run(
            ["-c", "core.quotePath=false", "status", "--porcelain=v2", "-uall"],
            in: root
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return GitStatusParser.parse(result.stdout)
    }

    /// The commit history of the repository at `root`, most recent first.
    ///
    /// Runs `git log --topo-order --parents -n <limit> --pretty=format:<format>`
    /// plus `filter`'s revision/ref/path arguments (the default filter contributes
    /// `--all`), with the exact format `Commit.parse` expects, and feeds stdout to
    /// the pure parser.
    ///
    /// `--topo-order` keeps a branch's commits contiguous (never interleaving
    /// parallel branches by date), which the graph layout in a later stage relies
    /// on. `--parents` prints each commit's parent hashes so merges (multiple
    /// parents) and roots (none) are visible. A merge commit appears once with all
    /// its parents listed; this is the full ancestry walk, not a first-parent-only
    /// history, so the graph can draw every branch line.
    ///
    /// A non-zero exit (not a repo, git missing, a bad filter ref) surfaces as
    /// `GitError.notARepository` so the model can report it.
    func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] {
        // `-c core.quotePath=false` keeps non-ASCII characters raw in `%D` ref
        // names and subjects, matching the `changedFiles` rationale.
        let arguments =
            ["-c", "core.quotePath=false", "log", "--topo-order", "--parents",
             "-n", String(limit), "--pretty=format:\(Commit.prettyFormat)"]
            + filter.gitArguments()
        let result = try await run(arguments, in: root)
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return Commit.parse(result.stdout)
    }

    /// The branch/tag ref names in the repository at `root`, for the Log filter
    /// bar's ref picker.
    ///
    /// Runs `git for-each-ref --format=%(refname)` over `refs/heads`,
    /// `refs/remotes`, and `refs/tags` — local branches first, then remote-tracking
    /// branches, then tags — and returns each **full** refname (e.g.
    /// `refs/heads/main`, `refs/remotes/origin/main`, `refs/tags/v1.0`). The full
    /// name, not `:short`, is deliberate: a branch and a tag can share a short name
    /// (both `v1.0`), and `git log v1.0` would then be *ambiguous* — git silently
    /// resolves it by its own precedence (tags win over heads), so picking the
    /// branch would show the tag's history. The full refname is unambiguous as the
    /// positional revision `LogFilter` passes to `git log`; the filter bar shortens
    /// it for display only. `--format` keeps the output one name per line with no
    /// decoration, so the result is a plain split on newlines with blanks dropped.
    /// A non-zero exit (not a repo, git missing) surfaces as
    /// `GitError.notARepository`; an empty repository simply yields `[]`.
    func references(root: URL) async throws -> [String] {
        // `-c core.quotePath=false` keeps non-ASCII ref names raw, matching the
        // other calls.
        let result = try await run(
            ["-c", "core.quotePath=false", "for-each-ref",
             "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"],
            in: root
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The contents of `path` (repo-relative) at `HEAD`, or `nil` when the file
    /// does not exist there (a new/untracked file, or any path git cannot resolve
    /// at `HEAD`).
    ///
    /// `git show HEAD:<path>` exits non-zero for a missing object; we map that to
    /// `nil` rather than throwing, so a new file simply diffs against an empty
    /// left side. Non-repo / git-missing still surface as thrown errors via
    /// `run`.
    func headContents(of path: String, root: URL) async throws -> String? {
        let result = try await run(["show", "HEAD:\(path)"], in: root)
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdout
    }

    /// The raw bytes of `path` (repo-relative) at `HEAD`, or `nil` when the path is
    /// **absent from HEAD**.
    ///
    /// Same command as `headContents`, two deliberate differences — both of which
    /// are the reason the commit dialog cannot reuse that method (see
    /// `GitServicing.headBlob(of:root:)`). Absence is decided by git's **exit
    /// code** alone, so a blob that happens not to decode is emphatically *not*
    /// reported as missing; and the bytes come back through `stdoutData`, raw,
    /// because `stdout` is decoded lossily and would turn a binary blob into
    /// plausible-looking U+FFFD-laden text. Classifying them is `GitBlobText`'s
    /// job. Non-repo / git-missing still surface as thrown errors via `run`.
    func headBlob(of path: String, root: URL) async throws -> Data? {
        let result = try await run(["show", "HEAD:\(path)"], in: root)
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdoutData
    }

    /// The files changed by `hash` relative to its first parent.
    ///
    /// Runs `git diff-tree --no-commit-id --name-status -r -M -m --first-parent --root
    /// <hash>` and feeds stdout to `CommitChangesParser.parse`:
    /// - `--name-status` emits one `STATUS\t<path>` (or `R/C<score>\t<old>\t<new>`)
    ///   record per file — exactly what the parser consumes.
    /// - `-r` recurses into subtrees (otherwise only top-level entries show).
    /// - `-M` enables rename detection so a move surfaces as `.renamed` with its
    ///   `oldPath` rather than a delete+add pair.
    /// - `-m --first-parent` makes a *merge* commit diff against its first parent
    ///   only (the mainline change set), not a combined diff against all parents.
    ///   `--first-parent` alone is not enough: `diff-tree` suppresses a merge's diff
    ///   entirely unless `-m` (or `-c`/`--cc`) is given, so without `-m` a merge
    ///   commit produces *no* output and the detail pane shows "No changed files".
    ///   `-m` on its own would emit a per-parent diff against every parent, so it is
    ///   paired with `--first-parent` to keep just the mainline side. (For a
    ///   non-merge or root commit `-m` is a no-op — there is only one parent / the
    ///   empty tree to diff against.)
    /// - `--root` diffs a root commit against the empty tree, so its files show as
    ///   added rather than producing no output.
    ///
    /// A non-zero exit (not a repo, git missing, a bad hash) surfaces as
    /// `GitError.notARepository` so the model can report it.
    func commitChanges(hash: String, root: URL) async throws -> [ChangedFile] {
        // `-c core.quotePath=false` keeps non-ASCII paths raw, matching `changedFiles`.
        let result = try await run(
            ["-c", "core.quotePath=false", "diff-tree", "--no-commit-id",
             "--name-status", "-r", "-M", "-m", "--first-parent", "--root", hash],
            in: root
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return CommitChangesParser.parse(result.stdout)
    }

    /// The contents of `path` (repo-relative) at the commit-ish `revision`, or
    /// `nil` when the file does not exist there.
    ///
    /// `git show <revision>:<path>` exits non-zero for a missing object (the path
    /// did not exist at that revision — e.g. the parent side of an added file); we
    /// map that to `nil` so the diff gets an empty side, exactly like
    /// `headContents`. Non-repo / git-missing still surface as thrown errors.
    func fileContents(at revision: String, path: String, root: URL) async throws -> String? {
        let result = try await run(["show", "\(revision):\(path)"], in: root)
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdout
    }

    /// The contents of the `stage`-numbered index entry for the conflicted `path`,
    /// or `nil` when that stage does not exist.
    ///
    /// `git show :<N>:<path>` reads the merge index stage (`1` base, `2` ours,
    /// `3` theirs). A missing stage exits non-zero (no such object) — an add/add
    /// conflict has no `:1`, a modify/delete has no `:2`/`:3` — which we map to
    /// `nil` exactly like `headContents`. Non-repo / git-missing still surface as
    /// thrown errors via `run`.
    func blob(stage: Int, path: String, root: URL) async throws -> String? {
        let result = try await run(["show", ":\(stage):\(path)"], in: root)
        guard result.exitCode == 0 else {
            return nil
        }
        return result.stdout
    }

    /// Stage the resolved working file at `path` via `git add -- <path>`.
    ///
    /// Run after the merge editor writes the resolved text, this records the
    /// resolution in the index (clearing the unmerged stages). A non-zero exit
    /// surfaces as `GitError.notARepository` so the model can report it without
    /// claiming a successful apply.
    func stage(path: String, root: URL) async throws {
        let result = try await run(["add", "--", path], in: root)
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
    }

    /// Resolve a conflict to a deletion by removing `path` and staging the removal
    /// via `git rm -f -- <path>`.
    ///
    /// Run by the merge editor when a modify/delete conflict is resolved to the
    /// deleted side: `git rm -f` removes the working file (still present as the
    /// modified side during the conflict) and records the deletion in the index,
    /// clearing the unmerged stages. A non-zero exit surfaces as
    /// `GitError.notARepository` so the model can report it without claiming a
    /// successful apply.
    func stageRemoval(path: String, root: URL) async throws {
        let result = try await run(["rm", "-f", "--", path], in: root)
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
    }

    // MARK: - Blame

    /// Per-line authorship of the file at `fileURL`, one entry per file line in
    /// final-line order (`nil` where the output carried no data for a line).
    ///
    /// Runs `git -c core.quotePath=false blame --porcelain -- <name>` with the
    /// file's **own parent directory** as the working directory, which is the whole
    /// reason this method takes an absolute file URL instead of the `(path:root:)`
    /// pair the rest of the protocol uses (see `GitServicing.blame(fileURL:)`): the
    /// caller is the editor gutter, which holds a workspace URL and no repository
    /// root, and running from the file's directory lets git discover the repository
    /// itself — so there is no `repositoryRoot(for:)` round-trip on a path the user
    /// is merely looking at, and a file outside any repository simply exits
    /// non-zero. Because the working directory *is* the file's directory, the
    /// pathspec is the bare `lastPathComponent`, passed after `--` so a name
    /// starting with `-` cannot be read as an option.
    ///
    /// `-c core.quotePath=false` matches every other call here (`changedFiles`,
    /// `commits`, `commitChanges`, `references`): git's default C-style octal
    /// quoting of non-ASCII bytes would mangle the `filename` field the porcelain
    /// output carries. The blame path does not read that field, so the flag is
    /// consistency rather than a live fix — which is exactly why it is set here too,
    /// so no call site is the odd one out.
    ///
    /// `--porcelain` (not `--line-porcelain`) is deliberate and `BlameParser` is
    /// built for it: commit metadata appears once per commit and later lines of the
    /// same commit carry only the hash, so the output is a fraction of the size on
    /// the megabyte-scale files this must stay responsive on.
    ///
    /// The parse deliberately happens **here**, not in the caller: this method is
    /// not `@MainActor`, so both the subprocess (dispatched onto `run`'s dedicated
    /// serial queue) and `BlameParser.parse` — an O(output) walk that on a large
    /// file is the more expensive half — stay off the main thread. Returning the
    /// raw string for the main-actor `BlameController` to parse would put that walk
    /// straight back onto the typing path.
    ///
    /// No `--contents` variant is used: the command blames the bytes **on disk** by
    /// design. Blaming a temp copy of the editor buffer would blame a file git has
    /// never seen (every unsaved line comes back uncommitted anyway), and saving on
    /// toggle would make a read-only inspection command write the user's file — the
    /// accepted dirty-buffer trade recorded in full on `BlameController`.
    ///
    /// A non-zero exit (the file is outside a repository, the path is untracked,
    /// git cannot interpret it) surfaces as `GitError.notARepository`, matching
    /// every other non-`nil`-mapping call here; the controller swallows it and
    /// leaves the column empty.
    func blame(fileURL: URL) async throws -> [BlameLine?] {
        let result = try await run(
            ["-c", "core.quotePath=false", "blame", "--porcelain",
             "--", fileURL.lastPathComponent],
            in: fileURL.deletingLastPathComponent(),
            on: Self.blameQueue
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
        return BlameParser.parse(result.stdout)
    }

    // MARK: - Branch switcher

    /// The currently checked-out local branch of the repository at `root`, or
    /// `nil` for a detached or unborn HEAD.
    ///
    /// `git symbolic-ref --short HEAD` prints the short branch name (`main`) when
    /// HEAD points at a branch and exits non-zero for a detached HEAD (it points
    /// straight at a commit) — mapped to `nil`, exactly like `headContents` maps a
    /// missing object. An unborn HEAD (a fresh repo before the first commit) also
    /// yields no branch here. The result is fed into a `BranchRef` carrying the
    /// full `refs/heads/<short>` refname (stable identity, matching the shape
    /// `references(root:)` returns), marked `isCurrent`. Non-repo / git-missing
    /// still surface as thrown errors via `run`.
    func currentBranch(root: URL) async throws -> BranchRef? {
        let result = try await run(["symbolic-ref", "--short", "HEAD"], in: root)
        guard result.exitCode == 0 else {
            return nil
        }
        let short = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty else { return nil }
        return BranchRef(
            name: "refs/heads/\(short)",
            isRemote: false,
            remoteName: nil,
            shortName: short,
            isCurrent: true
        )
    }

    /// Check out the local branch `branch` via `git checkout <branch>`.
    ///
    /// A dirty working tree can make git refuse the switch (it will not overwrite
    /// local changes); on a non-zero exit we throw `GitError.checkoutFailed(reason:)`
    /// carrying git's stderr, which names the conflicting files so the widget can
    /// show exactly what blocked the switch. `run` already throws
    /// `GitError.gitUnavailable` if git cannot launch.
    func checkout(branch: String, root: URL) async throws {
        let result = try await run(["checkout", branch], in: root)
        guard result.exitCode == 0 else {
            throw GitError.checkoutFailed(reason: checkoutReason(result.stderr))
        }
    }

    /// Create branch `name` starting at `startPoint` (any ref/hash) and check it
    /// out in one step, via `git checkout -b <name> <startPoint>`.
    ///
    /// The caller validates `name` via `GitRefName.isValid(_:)` and, for a remote
    /// start point, fetches first so the ref is up to date. A non-zero exit (an
    /// invalid start point git rejects, or a dirty tree blocking the switch) throws
    /// `GitError.checkoutFailed(reason:)` with git's stderr.
    func createAndCheckout(name: String, startPoint: String, root: URL) async throws {
        let result = try await run(["checkout", "-b", name, startPoint], in: root)
        guard result.exitCode == 0 else {
            throw GitError.checkoutFailed(reason: checkoutReason(result.stderr))
        }
    }

    /// Fetch `remote` (e.g. `origin`) via `git fetch <remote>`, updating the
    /// remote-tracking refs.
    ///
    /// The system git inherits the user's configured credentials (keychain/helper),
    /// so this needs no credentials plumbing on macOS. A non-zero exit (network
    /// failure, auth refused, unknown remote) throws `GitError.fetchFailed(reason:)`
    /// with git's stderr.
    func fetch(remote: String, root: URL) async throws {
        let result = try await run(["fetch", remote], in: root)
        guard result.exitCode == 0 else {
            throw GitError.fetchFailed(reason: fetchReason(result.stderr))
        }
    }

    /// The human-readable reason for a failed checkout: git's trimmed stderr (it
    /// names the conflicting files), or a generic fallback when stderr is empty so
    /// `errorDescription` is never blank.
    private func checkoutReason(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not switch branches." : trimmed
    }

    /// The human-readable reason for a failed fetch: git's trimmed stderr, or a
    /// generic fallback when stderr is empty.
    private func fetchReason(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Could not fetch from the remote." : trimmed
    }

    /// Discard the local changes to `file`, restoring its `HEAD` version.
    ///
    /// Destructive and irreversible (the view layer confirms first). Dispatches
    /// on `file.status`:
    /// - `.modified`, `.deleted`: `git checkout HEAD -- <path>` restores both the
    ///   index and the working tree from `HEAD`.
    /// - `.renamed`: restore the original via `git checkout HEAD -- <oldPath>` and
    ///   remove the new path with `git rm -f -- <path>`, undoing both sides. These
    ///   are two on-disk steps; a failure after the first throws an
    ///   `InterruptedRevert` reporting what changed (see below).
    /// - `.added`: `git rm -f -- <path>` unstages and removes the working file (it
    ///   has no `HEAD` version to restore).
    /// - `.untracked`: remove the working file directly via `unlink` (git does not
    ///   track it, so there is nothing to check out).
    ///
    /// A non-zero git exit surfaces as `GitError.notARepository` so the model can
    /// report it.
    func revert(_ file: ChangedFile, root: URL) async throws {
        switch file.status {
        case .modified, .deleted, .conflicted:
            // A conflicted file is reverted by checking out the `HEAD` (ours)
            // version, the same plumbing as a plain modification; the merge editor
            // is the normal path, but a revert still discards the file's changes.
            try await checkout(file.path, root: root)
        case .renamed:
            try await revertRename(file, root: root)
        case .added:
            // `git rm` unlinks the worktree file before the index write that may
            // fail (see `remove`). On such a failure the working file is already
            // gone, so report it as changed (`InterruptedRevert` conforms to
            // `PartialRevertError`) — otherwise the model would treat this atomic
            // single command as "changed nothing" and leave a stale tab open on a
            // file that no longer exists. If the worktree file is still present the
            // removal did not take effect, so report nothing (reloading a tab the
            // revert never touched could discard unsaved edits there).
            do {
                try await remove(file.path, root: root)
            } catch let failure as RemoveFailure {
                throw InterruptedRevert(
                    changedPaths: failure.removedWorktreeFile ? [file.path] : [],
                    underlying: failure.underlying
                )
            }
        case .untracked:
            try removeUntracked(file.path, root: root)
        }
    }

    /// Undo a rename: restore `oldPath` from `HEAD`, then remove the new `path`.
    ///
    /// The two steps are not atomic, so failures are wrapped in `InterruptedRevert`
    /// carrying the paths that actually changed — the model resyncs only those
    /// (reporting a path the revert never touched could discard unsaved edits in
    /// an open tab there). Before restoring, refuse if something already occupies
    /// `oldPath`: a staged rename can coexist with a new *untracked* file recreated
    /// at the old path, and `git checkout HEAD -- <oldPath>` would silently
    /// overwrite that unrelated file. The old path should be vacant after a rename
    /// (it was moved away), so an occupied one means an unexpected file we must not
    /// clobber — *unless* it is the renamed file itself: on a case-insensitive
    /// volume a case-only rename (`foo.swift` → `Foo.swift`) leaves both names
    /// pointing at one inode, which is undone with `git mv` instead (see below).
    private func revertRename(_ file: ChangedFile, root: URL) async throws {
        var changed: [String] = []
        do {
            if let oldPath = file.oldPath {
                let oldURL = root.appendingPathComponent(oldPath)
                // `lstat`, not `FileManager.fileExists`: the latter follows a
                // symlink and so misses a *dangling* one, letting `git checkout`
                // silently overwrite it. `lstat` reports the link itself, so the
                // guard refuses to clobber any entity occupying `oldPath`.
                if pathExists(oldURL) {
                    // `oldPath` is occupied. On a case-insensitive volume (the
                    // macOS default) a case-only rename — `foo.swift` → `Foo.swift`
                    // — collapses both names onto a single inode, so `lstat(oldPath)`
                    // resolves the *renamed* file itself, not an unrelated occupant.
                    // The normal checkout-then-`rm` undo would then restore `oldPath`
                    // and immediately `git rm` that very same inode, deleting the
                    // file it just restored. So when `oldPath` and the new path are
                    // the same file (same device+inode), undo the rename with
                    // `git mv` (which moves via a temporary name, preserving the
                    // inode) and then `checkout` to also restore `HEAD` content for
                    // a rename+modify. Anything *else* at `oldPath` is an unrelated
                    // file we must not clobber, so refuse as before.
                    let newURL = root.appendingPathComponent(file.path)
                    // Same inode alone is *not* proof of a case-only rename: two
                    // distinct names hard-linked to one inode (e.g. an untracked
                    // `a.txt` re-created over the vacated old path of a staged
                    // `a.txt`→`b.txt` rename) also share device+inode, yet they are
                    // genuinely different files. `git mv b.txt a.txt` there is a
                    // no-op `rename(2)` (POSIX: renaming a file onto a hard link of
                    // itself does nothing), so the new path would survive while the
                    // revert reported success. A true case-only rename differs from
                    // its old path *only* by case, so require that too — anything
                    // else falls through to the safe refusal below.
                    //
                    // Case-fold + inode is *still* not enough on a case-sensitive
                    // volume: there `foo` and `Foo` are two distinct directory
                    // entries, so a genuine case-only rename actually *moves* the
                    // file (leaving `oldPath` vacant — this branch wouldn't run),
                    // while two case-differing hard links to one inode remain
                    // genuinely different files that share device+inode and fold
                    // equal. `git mv` there no-ops the same way, leaving the new
                    // path. The `git mv` undo is sound *only* on a case-insensitive
                    // volume, where `foo`/`Foo` cannot both exist as distinct
                    // entries — so require that too; otherwise refuse safely.
                    let isCaseOnlyRename = oldPath.caseInsensitiveCompare(file.path) == .orderedSame
                    guard isCaseOnlyRename, sameFile(oldURL, newURL),
                          isCaseInsensitiveVolume(oldURL) else {
                        throw GitError.revertFailed(
                            reason: "“\(oldPath)” already exists; refusing to overwrite it while undoing the rename."
                        )
                    }
                    try await move(from: file.path, to: oldPath, root: root)
                    changed.append(file.path)
                    do {
                        try await checkout(oldPath, root: root)
                    } catch let error where !(error is PartialRevertError) {
                        // The `git mv` renamed the (shared) inode, but this checkout
                        // failed to restore its `HEAD` content *and* its probe did
                        // not confirm a worktree restore (which would surface as a
                        // `PartialRevertError`). So the new path still holds the
                        // un-restored working copy: drop it from the changed set
                        // before failing, or the model would reload the open tab
                        // there and discard unsaved edits for content the revert
                        // never restored — the same mistake the `checkout`/`remove`
                        // probes avoid by reporting only confirmed-final state. A
                        // *confirmed* restore (`PartialRevertError`, not caught
                        // here) keeps the new path reported: the single inode reached
                        // `HEAD` and is reachable under both names on the
                        // case-insensitive volume this branch runs on.
                        changed.removeAll { $0 == file.path }
                        throw error
                    }
                    changed.append(oldPath)
                    return
                }
                try await checkout(oldPath, root: root)
                changed.append(oldPath)
            }
            try await remove(file.path, root: root)
            changed.append(file.path)
        } catch let failure as RemoveFailure {
            // `git rm` removes the worktree file before the index write that may
            // fail; if it actually vanished, fold it into the changed set so the
            // tab is closed, otherwise leave it out (don't disturb an open tab the
            // revert never touched).
            if failure.removedWorktreeFile { changed.append(file.path) }
            throw InterruptedRevert(changedPaths: changed, underlying: failure.underlying)
        } catch let partial as PartialRevertError {
            // The `checkout` of `oldPath` is itself non-atomic and can throw a
            // partial-revert error naming the path it already restored on disk
            // (a late index-write failure after the worktree was written). Merge
            // those paths with what this method changed so the restored old path
            // is still resynced — re-wrapping with only the local `changed` (empty
            // here, since the throw preempts its `append`) would lose the signal,
            // leaving a clean tab to re-save stale content over the restore.
            throw InterruptedRevert(
                changedPaths: changed + partial.changedPaths,
                underlying: partial
            )
        } catch {
            throw InterruptedRevert(changedPaths: changed, underlying: error)
        }
    }

    /// `git checkout HEAD -- <path>` in `root`, throwing on a non-zero exit.
    ///
    /// `git checkout` is *not* atomic: it writes the worktree file (`checkout_entry`)
    /// before committing the index (`write_locked_index`), so a late index-write
    /// failure (disk full, an unwritable `.git/index`) can leave the worktree
    /// already restored to `HEAD` while still exiting non-zero. On a non-zero exit
    /// we therefore ask git whether the worktree now matches `HEAD` for this path:
    /// if it does, the revert *did* change disk, so it is reported via
    /// `InterruptedRevert` (conforms to `PartialRevertError`) and the model reloads
    /// the open tab — otherwise a clean tab would keep its stale pre-revert content
    /// and silently re-save it over the restore.
    ///
    /// But "matches `HEAD` now" is not enough: a `.modified` file can be staged-only
    /// (index differs from `HEAD` while the worktree already equals it — e.g. stage
    /// an edit, then edit the worktree back). A failed checkout there reset only the
    /// index, never touching the worktree, yet the worktree matches `HEAD` both
    /// before and after. So we record whether it matched *before* the checkout and
    /// report a change only on an actual differ→match transition; reporting a
    /// non-transition would make the model reload the open tab and discard unsaved
    /// edits for a worktree the revert never wrote. If the worktree still differs
    /// (or already matched before), the checkout did not restore it here, so we
    /// report nothing.
    private func checkout(_ path: String, root: URL) async throws {
        // Capture the pre-checkout state; the probe below needs it to distinguish
        // an actual worktree restore from an index-only change that left the
        // worktree already matching `HEAD`.
        let matchedHeadBefore = await worktreeMatchesHead(path, root: root)
        let result = try await run(["checkout", "HEAD", "--", path], in: root)
        guard result.exitCode == 0 else {
            let underlying = GitError.notARepository(stderr: result.stderr)
            if !matchedHeadBefore, await worktreeMatchesHead(path, root: root) {
                throw InterruptedRevert(changedPaths: [path], underlying: underlying)
            }
            throw underlying
        }
    }

    /// `git mv -f -- <from> <to>` in `root`, throwing on a non-zero exit.
    ///
    /// Used only to undo a case-only rename on a case-insensitive volume, where
    /// `from` and `to` name the same inode: `git mv` renames via a temporary name
    /// so the single inode survives, whereas a plain checkout-then-`rm` would
    /// delete it (see `revertRename`).
    private func move(from: String, to: String, root: URL) async throws {
        let result = try await run(["mv", "-f", "--", from, to], in: root)
        guard result.exitCode == 0 else {
            throw GitError.notARepository(stderr: result.stderr)
        }
    }

    /// Whether `a` and `b` resolve to the same on-disk file (same device + inode),
    /// without following a final symlink (`lstat`).
    ///
    /// On a case-insensitive volume a case-only rename leaves the new path and the
    /// old path as two names for one inode; `revertRename` pairs this with a
    /// case-fold path comparison (same inode alone does not prove a case-only
    /// rename — a distinct-name hard link shares an inode too) before undoing it
    /// with `git mv` rather than refusing or deleting the restored file. A failed
    /// `lstat` on either side answers `false` (treat them as distinct), so the
    /// rename guard falls through to its safe refusal.
    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat()
        var sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Whether the volume backing `url` is case-insensitive (the macOS default —
    /// APFS/HFS+ in their non-case-sensitive formats).
    ///
    /// The `git mv` undo of a case-only rename (see `revertRename`) is sound only
    /// here: it relies on `foo` and `Foo` being a single directory entry, so that
    /// `sameFile` + a case-fold match unambiguously identify *the renamed file
    /// itself*. On a case-sensitive volume `foo` and `Foo` are distinct entries, so
    /// two case-differing hard links can share an inode while being genuinely
    /// different files — a false positive `sameFile` cannot rule out — and `git mv`
    /// would no-op, silently leaving the new path. A failed lookup answers `false`
    /// (refuse, surfacing an error, rather than risk a silent no-op revert).
    private func isCaseInsensitiveVolume(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
              let caseSensitive = values.volumeSupportsCaseSensitiveNames else {
            return false
        }
        return !caseSensitive
    }

    /// Whether the worktree at `path` now matches `HEAD`, via
    /// `git diff --quiet HEAD -- <path>` (exit 0 ⇒ no difference). Used only to
    /// learn whether a failed `checkout` had already restored the worktree.
    /// `git diff <commit>` compares the working tree directly against the commit
    /// (ignoring the index, which the failed checkout may have left un-updated), so
    /// this answers exactly "did the file content reach `HEAD`?" and handles binary
    /// files correctly. A launch failure conservatively answers `false` (report
    /// nothing rather than risk reloading over unsaved edits).
    private func worktreeMatchesHead(_ path: String, root: URL) async -> Bool {
        guard let result = try? await run(["diff", "--quiet", "HEAD", "--", path], in: root) else {
            return false
        }
        return result.exitCode == 0
    }

    /// Delete an untracked working file at `path` (relative to `root`).
    ///
    /// `git status --porcelain=v2 -uall` lists untracked *files* individually
    /// (never a bare directory), so the recorded path should always resolve to a
    /// regular file. But the status snapshot can go stale before the revert runs.
    ///
    /// Two stale-snapshot hazards, both closed here:
    /// - The path turned into a *directory*: a recursive delete would destroy
    ///   unrelated contents. `unlinkat(..., 0)` removes a single entry and never
    ///   recurses (it fails on a directory), so `EPERM`/`EISDIR` becomes a refusal.
    /// - A parent *directory* was replaced by a *symlink* pointing outside the
    ///   repo: resolving an absolute path with `unlink` follows that symlink and
    ///   would delete a file outside the repository. So we never hand a full path
    ///   to the kernel — we walk each component down from `root` with
    ///   `openat(..., O_NOFOLLOW | O_DIRECTORY)` (a symlinked component fails with
    ///   `ELOOP`/`ENOTDIR` instead of being followed) and `unlinkat` the final
    ///   name relative to the safely-resolved parent. `unlinkat` (like `unlink`)
    ///   removes a final symlink itself rather than its target.
    ///
    /// `ENOENT` anywhere along the walk (the path or a parent already vanished) is
    /// success — nothing left to discard.
    private func removeUntracked(_ path: String, root: URL) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last else { return }

        // The repo root is the trusted anchor (from `git rev-parse --show-toplevel`),
        // so it is opened normally; every component *below* it uses `O_NOFOLLOW`.
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

    /// A `git rm` that exited non-zero, recording whether the worktree file was
    /// already removed. `git rm` unlinks the worktree file *before* writing the
    /// updated index, so a late index-write failure returns non-zero with the file
    /// already gone; callers use `removedWorktreeFile` to report exactly the paths
    /// that actually changed (and no more — over-reporting risks discarding unsaved
    /// edits in an open tab the revert never touched).
    private struct RemoveFailure: Error {
        let removedWorktreeFile: Bool
        let underlying: Error
    }

    /// `git rm -f -- <path>` in `root`. On a non-zero exit, probes the worktree
    /// (git removes the file before the index write that may fail) and throws
    /// `RemoveFailure` recording whether the file is now gone.
    ///
    /// "Now gone" alone is not enough: the worktree file may already have been
    /// missing before `git rm` ran (a stale `.added` snapshot whose file vanished
    /// out of band, so the `rm` fails with nothing to remove). Reporting that as
    /// removed would make the model close the open tab and discard unsaved edits
    /// for a deletion we never performed. So we record whether it existed *before*
    /// and report removal only on an actual existed→gone transition.
    private func remove(_ path: String, root: URL) async throws {
        let url = root.appendingPathComponent(path)
        let existedBefore = pathExists(url)
        let result = try await run(["rm", "-f", "--", path], in: root)
        guard result.exitCode == 0 else {
            let removed = existedBefore && !pathExists(url)
            throw RemoveFailure(
                removedWorktreeFile: removed,
                underlying: GitError.notARepository(stderr: result.stderr)
            )
        }
    }

    /// Whether *something* exists at `url`, without following a final symlink.
    ///
    /// `lstat` (unlike `FileManager.fileExists`, which follows symlinks and so
    /// misses a dangling one) reports a symlink itself — used both to refuse
    /// clobbering an occupied rename target and to probe whether `git rm` actually
    /// removed a worktree file.
    ///
    /// Only `ENOENT` (the path is confidently absent) counts as "missing"; any
    /// other `lstat` failure (e.g. `EACCES` because a parent became unreadable)
    /// leaves the answer unknown, so we report `true` conservatively. Both callers
    /// want that: the rename guard then refuses rather than risk clobbering a
    /// possibly-present target, and the `git rm` probe does not report a path as
    /// removed (and so will not reload/close an open tab) unless it truly vanished.
    private func pathExists(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return errno != ENOENT
    }

    // MARK: - Commit dialog

    /// The repository state the commit dialog decides from.
    ///
    /// Six reads, each answering exactly one question, because the questions are
    /// genuinely independent and conflating them is how a fresh repository gets
    /// misread:
    /// - `rev-parse --absolute-git-dir` locates the git directory (also the one
    ///   probe that distinguishes "not a repository" from every state below, so a
    ///   context is never fabricated for a directory git cannot interpret);
    /// - `rev-parse --verify --quiet HEAD` fails exactly on an **unborn** HEAD;
    /// - `symbolic-ref --short --quiet HEAD` gives the branch name and fails
    ///   exactly on a **detached** HEAD — note it still *succeeds* on an unborn
    ///   one, which is why the two flags cannot be derived from a single call;
    /// - `@{upstream}` resolves the tracking ref, failing when there is none;
    /// - `git remote` lists the remotes (already sorted, which is what makes
    ///   `PushPlan`'s "first remote" choice stable);
    /// - the git directory's own entry names feed `InProgressOperation.detect`,
    ///   which matches them exactly.
    func commitContext(root: URL) async throws -> CommitContext {
        let gitDir = try await run(["rev-parse", "--absolute-git-dir"], in: root)
        guard gitDir.exitCode == 0 else {
            throw GitError.notARepository(stderr: gitDir.stderr)
        }
        let gitDirPath = gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let head = try await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)
        let symbolic = try await run(["symbolic-ref", "--short", "--quiet", "HEAD"], in: root)
        let branch = symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranch = (symbolic.exitCode == 0 && !branch.isEmpty) ? branch : nil

        let upstreamResult = try await run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            in: root
        )
        let upstreamName = upstreamResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = (upstreamResult.exitCode == 0 && !upstreamName.isEmpty) ? upstreamName : nil

        let remotesResult = try await run(["remote"], in: root)
        let remotes = remotesResult.exitCode == 0
            ? remotesResult.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            : []

        // **Fails closed.** An unreadable git directory must not collapse into an
        // empty marker list: `InProgressOperation.detect([])` is `nil`, i.e. "no
        // operation in progress", and because the commit is built in a throw-away
        // `GIT_INDEX_FILE` git itself never raises `cannot do a partial commit
        // during a merge` — that block is the last line of defence, so a listing
        // failure during a real merge would record it as an ordinary one-parent
        // commit, silently dropping the second parent and the resolutions. The
        // throw reaches `load` as `errorMessage`, which leaves the dialog visibly
        // refusing rather than quietly permitting.
        let markerNames: [String]
        do {
            markerNames = try FileManager.default.contentsOfDirectory(atPath: gitDirPath)
        } catch {
            throw GitError.notARepository(
                stderr: "Could not read the git directory: \(error.localizedDescription)"
            )
        }

        // The same `rev-parse` that decides `isUnbornHEAD` already printed the hash,
        // so pinning the commit an amend would rewrite costs no extra subprocess.
        let headHashText = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headHash = (head.exitCode == 0 && !headHashText.isEmpty) ? headHashText : nil

        return CommitContext(
            isUnbornHEAD: head.exitCode != 0,
            isDetachedHEAD: currentBranch == nil,
            currentBranch: currentBranch,
            upstream: upstream,
            remotes: remotes,
            inProgress: InProgressOperation.detect(markerNames: markerNames),
            headHash: headHash
        )
    }

    /// The author git would record right now, each field labelled with the config
    /// level it came from.
    ///
    /// Four reads per the `CommitIdentity.resolve` contract: `git config --local
    /// --get <key>` says whether *this repository* supplied the field, `git config
    /// --get <key>` says what git actually resolved to (and is the value shown, and
    /// the value committed under). An unset key exits non-zero, which maps to
    /// `nil` — the pure resolver turns that into `.unset` and the gate blocks.
    ///
    /// Reading config alone is only truthful because `commit` unsets the identity
    /// environment variables git would otherwise prefer — see
    /// `identityEnvironmentKeys`.
    func identity(root: URL) async throws -> CommitIdentity {
        // Sequential rather than concurrent: every `run` lands on the same serial
        // queue, so there is no parallelism to win here — only four continuations
        // queued behind each other.
        let localName = try await configValue(["--local", "--get", "user.name"], root: root)
        let localEmail = try await configValue(["--local", "--get", "user.email"], root: root)
        let effectiveName = try await configValue(["--get", "user.name"], root: root)
        let effectiveEmail = try await configValue(["--get", "user.email"], root: root)
        return CommitIdentity.resolve(
            localName: localName,
            localEmail: localEmail,
            effectiveName: effectiveName,
            effectiveEmail: effectiveEmail
        )
    }

    /// Write `name`/`email` into the repository's **local** config.
    ///
    /// `--local`, always: fixing one repository's author must never change the
    /// identity of every other repository on the machine, so nothing here ever
    /// touches `--global`. A non-zero exit surfaces as `GitError.commitFailed`
    /// carrying git's stderr — the case is named for the commit path, but the
    /// dialog only ever shows `reason`, and the reason spells out that it was the
    /// config write that failed.
    func setLocalIdentity(name: String, email: String, root: URL) async throws {
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let result = try await run(["config", "--local", key, value], in: root)
            guard result.exitCode == 0 else {
                throw GitError.commitFailed(
                    reason: failureReason(
                        result,
                        fallback: "Could not write “\(key)” to the repository's git config."
                    )
                )
            }
        }
    }

    /// The message of the current `HEAD` commit, or `nil` when there is none.
    ///
    /// `git log -1 --pretty=%B` prints the raw subject and body; an unborn HEAD
    /// simply exits non-zero, which is an honest `nil` ("nothing to reuse") rather
    /// than an error — Amend offers this into an empty message field and does
    /// without it when there is none.
    func headMessage(root: URL) async throws -> String? {
        let result = try await run(["log", "-1", "--pretty=%B"], in: root)
        guard result.exitCode == 0 else { return nil }
        let message = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Create the commit `plan` describes, amending `HEAD` when `amend`.
    ///
    /// **The mechanism.** A scratch directory holds a throw-away index, pointed at
    /// through a `GIT_INDEX_FILE` *override* on every step (see `run` for why it
    /// must be merged over the inherited environment rather than replace it). The
    /// index is seeded with `read-tree HEAD` — `read-tree --empty` on an unborn
    /// HEAD — so it starts as an exact copy of what is already committed; the
    /// plan's entries are then applied to it, and a **real `git commit`** runs
    /// against it.
    ///
    /// **Why a real commit and not `commit-tree`.** Plumbing would produce the same
    /// object and lose everything around it: `pre-commit`/`commit-msg` hooks would
    /// not run, and git's own author/committer resolution (config, `GIT_AUTHOR_*`,
    /// `user.signingkey` and the rest) would have to be reimplemented here. As a
    /// bonus, because the hooks inherit `GIT_INDEX_FILE`, a hook running `git diff
    /// --cached` sees exactly the content being committed — the selected lines,
    /// not the real index.
    ///
    /// **The real index is touched once, on success**, by a `git reset --quiet`
    /// with *no* override. That is the deliberate discard `CommitPlan` documents: a
    /// manual `git add` from the terminal, and the staged half of a formatting
    /// hook's work, are unstaged (their worktree edits remain as local changes). A
    /// failure of that final reset is deliberately **not** propagated: the commit
    /// already exists at that point, and reporting a failure would make the caller
    /// present a created commit as a failed one — inviting a retry that would
    /// commit twice. The cost is a residual staged entry the user can clear
    /// themselves.
    ///
    /// Any failure *before* the commit throws `GitError.commitFailed` carrying
    /// git's own output (a refusing hook's stderr *is* the explanation) with the
    /// real index and `HEAD` untouched, and the scratch directory is removed on
    /// every outcome via `defer`.
    func commit(_ plan: CommitPlan, message: String, amend: Bool, root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pisaka-commit-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw GitError.commitFailed(
                reason: "Could not create a temporary index: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        // `GIT_TERMINAL_PROMPT=0` for the same reason `push` sets it, and with more
        // exposure: this path executes the repository's own `pre-commit`/
        // `commit-msg` hooks, plus GPG signing when `commit.gpgsign` is on. Anything
        // that decides to prompt blocks forever — the sheet's Commit *and* Cancel
        // are disabled while `isRunning`, so the dialog cannot be dismissed, and
        // every other git call in the app queues behind this one on the shared
        // serial queue and silently stops working. Failing fast with git's own
        // message is the honest outcome; credential helpers still answer, needing no
        // terminal. It is inherited by the hooks and by any git they shell out to.
        let environment = [
            "GIT_INDEX_FILE": scratch.appendingPathComponent("index").path,
            "GIT_TERMINAL_PROMPT": "0"
        ]

        // Seed the throw-away index from what is already committed. An unborn HEAD
        // has no tree to read, so the first commit of a repository starts empty.
        let hasHead = try await run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)
        try await indexStep(
            hasHead.exitCode == 0 ? ["read-tree", "HEAD"] : ["read-tree", "--empty"],
            in: root,
            environment: environment
        )

        for entry in plan.entries {
            switch entry {
            case let .addFromWorktree(path):
                // Hand git the working file itself: it resolves the symlink, the
                // exec bit, clean filters and `core.autocrlf` exactly as `git add`
                // would. This is what makes "everything selected = the worktree
                // bytes" structural rather than a property of the builder.
                try await indexStep(
                    ["update-index", "--add", "--", path],
                    in: root,
                    environment: environment
                )
            case let .addContent(path, content, modeSource):
                let blobURL = scratch.appendingPathComponent("blob-\(UUID().uuidString)")
                do {
                    try content.write(to: blobURL, atomically: true, encoding: .utf8)
                } catch {
                    throw GitError.commitFailed(
                        reason: "Could not stage the assembled contents of “\(path)”: "
                            + error.localizedDescription
                    )
                }
                // `--path=<repo path>` is what makes the scratch file irrelevant:
                // git applies the clean filters and `core.autocrlf` rules that
                // belong to the *committed* path, so an assembled blob is hashed
                // exactly as staging that path would hash it.
                let hashed = try await run(
                    ["hash-object", "-w", "--path=\(path)", "--", blobURL.path],
                    in: root,
                    environment: environment
                )
                guard hashed.exitCode == 0 else {
                    throw GitError.commitFailed(
                        reason: failureReason(
                            hashed,
                            fallback: "Could not hash the assembled contents of “\(path)”."
                        )
                    )
                }
                let sha = hashed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sha.isEmpty else {
                    throw GitError.commitFailed(
                        reason: "Could not hash the assembled contents of “\(path)”."
                    )
                }
                let mode = try await fileMode(modeSource, entryPath: path, root: root)
                try await indexStep(
                    ["update-index", "--add", "--cacheinfo", "\(mode),\(sha),\(path)"],
                    in: root,
                    environment: environment
                )
            case let .removePath(path):
                try await indexStep(
                    ["update-index", "--force-remove", "--", path],
                    in: root,
                    environment: environment
                )
            }
        }

        // The message goes through a file rather than `-m`: it is multi-line user
        // text and `-F` passes it verbatim, with no argv length limit and no
        // per-line reassembly.
        let messageURL = scratch.appendingPathComponent("COMMIT_MSG")
        do {
            try message.write(to: messageURL, atomically: true, encoding: .utf8)
        } catch {
            throw GitError.commitFailed(
                reason: "Could not write the commit message: \(error.localizedDescription)"
            )
        }

        var arguments = ["commit", "-F", messageURL.path]
        if amend { arguments.append("--amend") }
        let committed = try await run(
            arguments,
            in: root,
            environment: environment,
            unsetting: Self.identityEnvironmentKeys
        )
        guard committed.exitCode == 0 else {
            throw GitError.commitFailed(
                reason: failureReason(committed, fallback: "Could not create the commit.")
            )
        }

        // The one deliberate touch of the *real* index — no environment override.
        // Its failure is swallowed: the commit above already exists.
        _ = try? await run(["reset", "--quiet"], in: root)
    }

    /// Push per `plan`: a plain `git push` for a branch that already has an
    /// upstream (git resolves the refspec itself, which may well be named
    /// differently from the local branch), or `--set-upstream` for one that does
    /// not.
    ///
    /// Only ever called after a successful commit, so a non-zero exit throws
    /// `GitError.pushFailed` — a case of its own precisely so the dialog reports
    /// "commit created, push failed" rather than presenting the commit as lost. An
    /// `.unavailable` plan should never reach here (the checkbox is disabled); it
    /// throws its own reason rather than pushing something unnamed.
    func push(_ plan: PushPlan, root: URL) async throws {
        let arguments: [String]
        switch plan {
        case .push:
            arguments = ["push"]
        case let .setUpstream(remote, branch):
            arguments = ["push", "--set-upstream", remote, branch]
        case let .unavailable(reason):
            throw GitError.pushFailed(reason: reason.message)
        }
        // `GIT_TERMINAL_PROMPT=0` because push is the one command here that
        // routinely needs authentication. Without it, a remote whose credentials
        // are not cached makes git block on a prompt it can never be answered
        // through: `isRunning` stays raised so the sheet's Commit button is
        // disabled forever, and — since every other call shares this service's
        // serial queue — the Local Changes refresh, the Log, the branch widget and
        // every later git operation queue behind it and silently stop working.
        // Failing fast with git's own "could not read Username" is the honest
        // outcome; the credential helper still answers, since it needs no terminal.
        let result = try await run(arguments, in: root, environment: ["GIT_TERMINAL_PROMPT": "0"])
        guard result.exitCode == 0 else {
            throw GitError.pushFailed(
                reason: failureReason(result, fallback: "Could not push to the remote.")
            )
        }
    }

    /// One step against the throw-away index, failing the whole commit with git's
    /// own output on a non-zero exit.
    private func indexStep(
        _ arguments: [String],
        in root: URL,
        environment: [String: String]
    ) async throws {
        let result = try await run(arguments, in: root, environment: environment)
        guard result.exitCode == 0 else {
            throw GitError.commitFailed(
                reason: failureReason(
                    result,
                    fallback: "“git \(arguments.joined(separator: " "))” failed."
                )
            )
        }
    }

    /// The file mode for an assembled blob, which no file on disk carries.
    ///
    /// `.head` reads the mode git already records (so committing three lines of an
    /// executable script never silently drops its exec bit); a path with no `HEAD`
    /// entry has only the working file to take it from. Anything unreadable falls
    /// back to a regular file, the mode git itself defaults to.
    ///
    /// The recorded mode is **reconciled against the working file's actual type**
    /// (`GitFileMode.reconciled(head:worktree:)`): a path that changed between a
    /// symlink and a regular file arrives here as an ordinary modification, and
    /// staging assembled text under a recorded `120000` would commit a symlink
    /// whose target is that whole text.
    ///
    /// `entryPath` is the path the entry writes to, which for a rename is *not*
    /// the path the mode is read from — the working file only exists under the new
    /// name, so that is what has to be stat'ed for the type.
    private func fileMode(
        _ source: CommitModeSource,
        entryPath: String,
        root: URL
    ) async throws -> String {
        let worktree = worktreeMode(root.appendingPathComponent(entryPath))
        switch source {
        case let .head(path):
            let result = try await run(["ls-tree", "HEAD", "--", path], in: root)
            guard result.exitCode == 0,
                  let head = GitFileMode.parse(lsTreeOutput: result.stdout) else {
                return worktree
            }
            return GitFileMode.reconciled(head: head, worktree: worktree)
        case .worktree:
            return worktree
        }
    }

    /// The git mode of the working file at `url` — `120000` for a symlink,
    /// `100755` when the owner-execute bit is set, `100644` otherwise (and for an
    /// unreadable path, git's own default).
    private func worktreeMode(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return GitFileMode.regular }
        return GitFileMode.worktree(
            isSymlink: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
            isExecutable: info.st_mode & mode_t(S_IXUSR) != 0
        )
    }

    /// A single `git config` value, or `nil` when the key is unset (a non-zero
    /// exit) or set to nothing but whitespace.
    private func configValue(_ arguments: [String], root: URL) async throws -> String? {
        let result = try await run(["config"] + arguments, in: root)
        guard result.exitCode == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The human-readable reason for a failed commit/push step.
    ///
    /// stderr first, but **stdout is not ignored**: git connects a hook's streams
    /// to its own, and a `pre-commit` hook that explains itself on stdout is the
    /// commonest failure this feature has — dropping it would leave the user with
    /// a blank refusal. `fallback` covers a command that failed silently.
    private func failureReason(_ result: ProcessResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? fallback : stdout
    }

    // MARK: - Process plumbing

    private struct ProcessResult {
        let exitCode: Int32
        /// Stdout exactly as git wrote it.
        ///
        /// The raw bytes are what is *stored*, because the decode below is *lossy*
        /// (`String(decoding:as: UTF8.self)` replaces invalid bytes with U+FFFD),
        /// which is right for every text-producing call here and wrong for
        /// `headBlob`, whose whole contract is "the bytes as they are, decoding is
        /// someone else's job" (see `GitServicing.headBlob(of:root:)`).
        let stdoutData: Data
        let stderrData: Data

        /// The decoded forms, computed **on demand** rather than stored.
        ///
        /// Decoding eagerly meant `headBlob` — the method added precisely to avoid
        /// a lossy decode, and which reads only `stdoutData` — still allocated a
        /// multi-megabyte string of U+FFFD for every binary blob it fetched, once
        /// per changed file per load and again per pre-commit re-read. No call site
        /// reads either property more than a couple of times per result, so
        /// re-decoding on access costs nothing measurable and the binary path stops
        /// decoding at all.
        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { String(decoding: stderrData, as: UTF8.self) }

        init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
            self.exitCode = exitCode
            self.stdoutData = stdoutData
            self.stderrData = stderrData
        }
    }

    /// A dedicated serial queue for the blocking `git` subprocess work, shared
    /// across `GitCLIService` instances. Keeping it off the Swift concurrency
    /// cooperative pool means a slow `git` run never starves the pool's limited
    /// threads, and serializing every run also serializes repository access so two
    /// overlapping calls cannot race the same `.git` state.
    private static let queue = DispatchQueue(label: "GitCLIService.run")

    /// A second serial queue carrying **only** `blame`.
    ///
    /// `blame --porcelain` is the slowest command in this file — seconds on a
    /// large file with deep history — and, unlike every other call here, it is
    /// issued *automatically*: the annotation column reloads on every tab switch
    /// to an annotated file and on every `diskRevision` bump, i.e. on every
    /// autosave. On the shared `queue` it would head-of-line block the whole git
    /// surface behind it, stalling the post-save Local Changes refresh, the Log
    /// fetch, the branch widget and a checkout on work whose result the user did
    /// not ask for and which is often discarded as superseded anyway.
    ///
    /// Splitting it off is safe precisely because `blame` is **read-only**: the
    /// serialization on `queue` exists so two calls cannot race the same `.git`
    /// state, and a read that overlaps a mutation can at worst observe the
    /// repository mid-change — which surfaces as a stale or failed blame, both of
    /// which the controller already swallows into an empty column. It stays a
    /// *serial* queue so several blames still cannot pile subprocesses on top of
    /// each other.
    private static let blameQueue = DispatchQueue(label: "GitCLIService.blame")

    /// The environment variables `commit` unsets so that **git config is what the
    /// dialog says it is**.
    ///
    /// `identity(root:)` resolves the author line from `git config` alone, and the
    /// dialog states the level each field came from — the whole point of the line
    /// being that no repository commits under a name nobody looked at. But git
    /// prefers `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` and
    /// `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` over config, and falls back to
    /// `EMAIL` for an unset `user.email` — and every git call here inherits the
    /// app's environment (see `run`), which carries those through whenever Pisaka
    /// was launched from a shell that exported them. Left in place they break the
    /// line in *both* directions: the dialog shows the config identity while git
    /// records the environment's one, and a repository with no configured identity
    /// blocks with "Set the commit author's name and email first." although git
    /// would have committed happily.
    ///
    /// Unsetting them for the commit makes config authoritative, so the displayed
    /// identity is the recorded one and `CommitGate.identityIncomplete` is a true
    /// statement about what git would do. It is *removal*, not an empty value:
    /// git treats an exported-but-empty `GIT_AUTHOR_NAME` as a name. The hooks the
    /// commit runs inherit the scrubbed environment too, which is the same
    /// consistency one level down. `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` are
    /// deliberately left alone — they set the commit's dates, which this dialog
    /// neither displays nor claims anything about.
    private static let identityEnvironmentKeys = [
        "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",
        "GIT_COMMITTER_NAME",
        "GIT_COMMITTER_EMAIL",
        "EMAIL"
    ]

    /// Launch `git` with `arguments` in `directory`, capturing stdout/stderr.
    ///
    /// Bridges the blocking `Process` call to `async`: it dispatches the
    /// synchronous body onto a dedicated serial queue and resumes a
    /// `withCheckedThrowingContinuation`, so the caller's main-actor (or
    /// cooperative-pool) thread is never blocked on the subprocess. `queue`
    /// defaults to the shared `GitCLIService.queue`; only the read-only `blame`
    /// passes `blameQueue`, for the head-of-line reason documented there.
    ///
    /// Throws `GitError.gitUnavailable` only when the process cannot be launched
    /// at all (git missing); a non-zero exit is reported via `ProcessResult` so
    /// each caller decides how to interpret it. `-z`/NUL-delimited output is not
    /// needed here: porcelain v2's `1`/`2` records keep paths on the tail of the
    /// line and `GitStatusParser` reads them as the unsplit remainder, so spaces
    /// survive without extra quoting. Non-ASCII paths are kept raw via
    /// `-c core.quotePath=false` on the `status` call (see `changedFiles`); only
    /// paths with a literal tab/newline/quote/backslash would still be quoted —
    /// a rare edge case the MVP accepts.
    ///
    /// `environment` is an **override merged over the inherited environment**, not
    /// a replacement, and that distinction is load-bearing rather than stylistic.
    /// The launch goes through `/usr/bin/env`, and `Process.environment` is never
    /// assigned here, so today every run inherits the app's environment wholesale.
    /// Assigning it — say `["GIT_INDEX_FILE": …]` for the commit path — would wipe
    /// `PATH` (so `/usr/bin/env git` would stop finding git at all), `HOME` (git
    /// would lose the global config, taking author resolution and credential
    /// helpers with it) and everything a `pre-commit` hook expects to find when it
    /// shells out to a formatter. So the parameter's entries are layered *on top
    /// of* `ProcessInfo.processInfo.environment`, the override winning per key; the
    /// default empty dictionary reproduces today's plain inheritance exactly, which
    /// is why no existing call site changes.
    ///
    /// `unsetting` is the same mechanism in the other direction: keys **removed**
    /// from the inherited environment before the override is layered on. Setting a
    /// variable to the empty string is not the same thing to git — an empty
    /// `GIT_AUTHOR_NAME` is a name it will try to use — so "make git behave as if
    /// this were never exported" needs a genuine removal. Its only caller is
    /// `commit`; see `identityEnvironmentKeys` for why.
    private func run(
        _ arguments: [String],
        in directory: URL,
        on queue: DispatchQueue = GitCLIService.queue,
        environment: [String: String] = [:],
        unsetting removedKeys: [String] = []
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try Self.runBlocking(
                        arguments,
                        in: directory,
                        environment: environment,
                        unsetting: removedKeys
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The synchronous `Process` body of `run`, executed on one of the serial
    /// queues above. `environment` is merged over the inherited environment and
    /// `removedKeys` are dropped from it first — see `run` for why it must never
    /// replace it, and why removal is not the same as an empty value.
    private static func runBlocking(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        unsetting removedKeys: [String] = []
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty || !removedKeys.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for key in removedKeys { merged.removeValue(forKey: key) }
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // No command here ever has anything to read from stdin, and inheriting the
        // app's would hand git (or `ssh`) a controlling terminal to prompt on when
        // the app was launched from a shell — a prompt nobody can answer, on a
        // serial queue every other git call queues behind.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitError.gitUnavailable
        }

        // Drain both pipes concurrently before waiting. Reading stdout to EOF
        // first and stderr only afterwards would deadlock if git fills the
        // stderr pipe buffer (~64KB) before closing stdout: git would block
        // writing stderr, never close stdout, and the stdout read would never
        // return. So read stderr on a background queue while we read stdout.
        var errData = Data()
        let errQueue = DispatchQueue(label: "GitCLIService.stderr")
        errQueue.async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        errQueue.sync {} // wait for the stderr read to finish
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: outData,
            stderrData: errData
        )
    }
}

#endif
