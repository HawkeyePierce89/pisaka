import Foundation

/// Git access for the Local Changes view, abstracted so the model can be tested
/// with a stub that simulates a repo without shelling out to `git`. Reads the
/// working tree (`changedFiles`, `headContents`) plus the one mutating,
/// destructive call (`revert`).
///
/// Mirrors the protocol-behind-injectable-stub split of `FileServicing`: the
/// declaration lives in Core (Foundation-only, no `Process`); the real,
/// `Process`-backed implementation (`GitCLIService`) lives in the `Pisaka`
/// view target.
public protocol GitServicing {
    /// The absolute top level of the working tree containing `url`.
    ///
    /// Opened folders may be a subdirectory of a repository; resolving the repo
    /// root first lets every other call run against one consistent root, so
    /// `git status` paths and `git show HEAD:<path>` lookups agree (status paths
    /// are relative to the directory git runs in, while `HEAD:<path>` is always
    /// repo-root-relative — running from a subdirectory makes the two disagree
    /// and can also surface `../` paths outside the opened folder).
    func repositoryRoot(for url: URL) async throws -> URL

    /// The files differing from `HEAD` in the repository at `root`.
    func changedFiles(root: URL) async throws -> [ChangedFile]

    /// The commit history of the repository at `root`, most recent first, subject
    /// to `filter` and capped at `limit` commits.
    ///
    /// Drives the Log view's list. The implementation runs `git log` with the
    /// topological ordering and `--parents` decoration the graph layout needs, and
    /// the exact `--pretty` format `Commit.parse` expects (`Commit.prettyFormat`),
    /// then parses the output. `filter` supplies the revision/ref/path constraints
    /// (the default filter spans all refs); `limit` bounds how many commits are
    /// returned so the initial load and "Load more" stay responsive.
    func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit]

    /// The branch/tag ref names available in the repository at `root`, for the Log
    /// filter bar's ref picker (most-useful first: local branches, then remotes,
    /// then tags). Drives only the *choices* offered; the chosen ref is fed back
    /// through `LogFilter.refSelection`. Defaulted in a protocol extension to `[]`
    /// so non-Log stubs need not implement it; the real `GitCLIService` overrides
    /// it.
    func references(root: URL) async throws -> [String]

    /// The contents of `path` (repo-relative) as it exists at `HEAD`, or `nil`
    /// when the file does not exist at `HEAD` (a new/untracked file).
    func headContents(of path: String, root: URL) async throws -> String?

    /// The raw bytes of `path` (repo-relative) as it exists at `HEAD`, or `nil`
    /// when the path is **absent from HEAD** (a new/untracked file).
    ///
    /// The contract is deliberately narrow and is what distinguishes this from
    /// `headContents(of:root:)`: `nil` means *absence and nothing else*, decided
    /// by git's own exit code, and the bytes are returned **raw** — decoding is
    /// `GitBlobText`'s job, and whether they decode has no bearing on whether the
    /// path exists.
    ///
    /// `headContents` cannot serve the commit dialog for exactly that reason. Its
    /// `String?` conflates the two questions, and `GitCLIService` decodes stdout
    /// *lossily*, so a binary `HEAD` blob comes back as plausible-looking garbage
    /// (or, under a strict decode, as indistinguishable from absence) — and a file
    /// that is binary in `HEAD` but text in the worktree is then classified as
    /// wholly *added*, offering per-line selection against a falsely empty old
    /// side. Committing a subset of those "added" lines would write a truncated
    /// text file over binary content, with nothing anywhere reporting an error.
    ///
    /// Defaulted in a protocol extension to `nil` so every existing stub — and the
    /// iOS `LibGit2Service`, which has no commit dialog — keeps compiling
    /// untouched; the real `GitCLIService` overrides it.
    func headBlob(of path: String, root: URL) async throws -> Data?

    /// The files changed by the commit `hash` relative to its first parent.
    ///
    /// Drives the Log view's commit-detail file list. A merge commit is diffed
    /// against its *first* parent only (the mainline change set), not a combined
    /// diff against all parents; a root commit is diffed against the empty tree
    /// (so every file shows as added). Renames are detected and carry their
    /// `oldPath`. Defaulted in a protocol extension to `[]` so non-Log stubs need
    /// not implement it; the real `GitCLIService` overrides it.
    func commitChanges(hash: String, root: URL) async throws -> [ChangedFile]

    /// The contents of `path` (repo-relative) as it exists at the commit-ish
    /// `revision` (a hash), or `nil` when the file does not exist there (e.g. the
    /// added side of a file that did not exist in the parent).
    ///
    /// Lets the Log view build a commit-vs-parent diff via `LineDiff`: the model
    /// reads the new side at the commit's own hash and the old side at the first
    /// parent's hash. Defaulted in a protocol extension to `nil` so non-Log stubs
    /// need not implement it; the real `GitCLIService` overrides it.
    func fileContents(at revision: String, path: String, root: URL) async throws -> String?

    /// Discard the local changes to `file`, restoring its `HEAD` version.
    ///
    /// This is destructive and irreversible — the working-tree change is thrown
    /// away — so the view layer always confirms before calling it. Behavior
    /// depends on `file.status`:
    /// - `.modified`, `.deleted`: restore the working tree + index from `HEAD`.
    /// - `.renamed`: restore the original path from `HEAD` and remove the new
    ///   path, so both sides of the rename are undone.
    /// - `.added`: unstage and remove the working file (it has no `HEAD` version).
    /// - `.untracked`: delete the working file (git does not track it).
    ///
    /// Throws on failure (e.g. a non-zero git exit) so the model can surface it.
    /// A revert can leave the working tree partly changed even when it fails — a
    /// rename revert is two on-disk steps and can fail *between* them, and a
    /// `checkout` writes the worktree before a late index-write failure that still
    /// exits non-zero. When that happens the thrown error conforms to
    /// `PartialRevertError` so the caller can resync only the paths that actually
    /// changed (see that protocol). A failure that conforms reports `changedPaths`;
    /// any other failure changed nothing.
    func revert(_ file: ChangedFile, root: URL) async throws

    /// The contents of the `stage`-numbered index entry for the conflicted `path`
    /// (repo-relative), or `nil` when that stage does not exist.
    ///
    /// During a merge conflict git keeps up to three index stages for a path:
    /// `1` = the common ancestor (base), `2` = "ours", `3` = "theirs". A missing
    /// stage is a real, meaningful case — `1` absent is an add/add conflict (no
    /// common ancestor), and `2`/`3` absent is a modify/delete (one side removed
    /// the file) — so the implementation maps the missing-object exit to `nil`
    /// rather than throwing, mirroring `headContents`/`fileContents`. Drives the
    /// 3-pane merge editor (`MergeModel`). Defaulted in a protocol extension to
    /// `nil` so non-merge stubs keep compiling; the real `GitCLIService` overrides
    /// it.
    func blob(stage: Int, path: String, root: URL) async throws -> String?

    /// Stage the resolved working-tree file at `path` (repo-relative) via
    /// `git add`, marking the conflict resolved in the index.
    ///
    /// Called after the merge editor writes the resolved text to disk; a non-zero
    /// git exit throws so the model can surface it without claiming success.
    /// Defaulted in a protocol extension to a no-op so non-merge stubs keep
    /// compiling; the real `GitCLIService` overrides it.
    func stage(path: String, root: URL) async throws

    /// Resolve a conflict by *removing* `path` (repo-relative) from the working
    /// tree and staging its deletion via `git rm -f`.
    ///
    /// Used by the merge editor when a modify/delete conflict is resolved to the
    /// deleted side: writing the (empty) resolved text and `git add`ing it would
    /// stage an empty *file* instead of the deletion the user chose, so apply takes
    /// this path instead. A non-zero git exit throws so the model can surface it.
    /// Defaulted in a protocol extension to a no-op so non-merge stubs keep
    /// compiling; the real `GitCLIService` overrides it.
    func stageRemoval(path: String, root: URL) async throws

    /// The currently checked-out local branch of the repository at `root`, or
    /// `nil` for a detached HEAD (or an unborn HEAD before the first commit).
    ///
    /// Drives the branch-switcher widget's "current branch" label and the marking
    /// of the current entry in the branch list. The branch *list* itself comes from
    /// the existing `references(root:)` (full refnames) fed through
    /// `BranchRef.build(fromRefnames:current:)` — no separate `branches(...)`
    /// method is added; only `currentBranch` is new. Defaulted in a protocol
    /// extension to `nil` so existing stubs keep compiling.
    func currentBranch(root: URL) async throws -> BranchRef?

    /// Check out the local branch `branch` (a short name, e.g. `main`) in the
    /// repository at `root`.
    ///
    /// A dirty working tree may block the checkout (git refuses to overwrite local
    /// changes): a non-zero exit throws `GitError.checkoutFailed(reason:)` carrying
    /// git's message, which names the conflicting files so the widget can show it.
    /// Defaulted in a protocol extension to `throw GitError.gitUnavailable` so
    /// non-branch stubs keep compiling.
    func checkout(branch: String, root: URL) async throws

    /// Create a new branch `name` starting at `startPoint` (any ref — a local
    /// branch, `origin/master`, `HEAD`, a hash) and check it out, in one step.
    ///
    /// The caller validates `name` via `GitRefName.isValid(_:)` first, and fetches
    /// beforehand when `startPoint` is a remote ref. A non-zero exit throws
    /// `GitError.checkoutFailed(reason:)`. Defaulted in a protocol extension to
    /// `throw GitError.gitUnavailable`.
    func createAndCheckout(name: String, startPoint: String, root: URL) async throws

    /// Fetch `remote` (e.g. `origin`) into the repository at `root`, updating its
    /// remote-tracking refs.
    ///
    /// Needed before creating a branch off a remote ref so the start point is up to
    /// date. macOS inherits the system git's credentials; on iOS this uses libgit2
    /// over HTTPS (Part B) and throws `GitError.credentialsRequired(host:)` when a
    /// private repo needs a PAT that is not stored. A non-zero exit / network
    /// failure throws `GitError.fetchFailed(reason:)`. Defaulted in a protocol
    /// extension to `throw GitError.gitUnavailable`.
    func fetch(remote: String, root: URL) async throws

    /// The repository state the commit dialog decides from: an unborn/detached
    /// HEAD, the current branch and its upstream, the configured remotes, and any
    /// operation (merge, rebase, cherry-pick, revert) the repository is in the
    /// middle of.
    ///
    /// Read once when the dialog opens; every decision made from it is pure
    /// (`CommitGate`, `PushPlan`). Defaulted in a protocol extension to
    /// `throw GitError.gitUnavailable` rather than to some empty value: unlike
    /// `references(root:) -> []` there is no honest "nothing" here, and a
    /// fabricated context would let the gate reach a verdict from fiction — decide
    /// that pushing is impossible, or that no merge is in progress — which is the
    /// one thing that must not happen when the dialog's blocks stand in for git's
    /// own protections.
    func commitContext(root: URL) async throws -> CommitContext

    /// The author git would record for a commit made in `root` right now, with
    /// each field labelled by the config level it came from.
    ///
    /// The label is the point of the feature (see `CommitIdentity`): the effective
    /// value is what git will write, and the source says whether this repository
    /// supplied it or something above it did. Implemented as `git config --local
    /// --get` alongside `git config --get` per field, fed through
    /// `CommitIdentity.resolve(...)`. Defaulted to `throw GitError.gitUnavailable`
    /// for the reason `commitContext` is: an identity invented by a default would
    /// be indistinguishable from a real answer, and this one is shown to the user
    /// as the author of their commit.
    func identity(root: URL) async throws -> CommitIdentity

    /// Write `name`/`email` into the repository's **local** config
    /// (`git config --local user.name/user.email`).
    ///
    /// Local only, always: fixing one repository's author must never change the
    /// identity of every other repository on the machine, so nothing in this
    /// feature touches the global config. Defaulted to
    /// `throw GitError.gitUnavailable`.
    func setLocalIdentity(name: String, email: String, root: URL) async throws

    /// The message of the current `HEAD` commit, or `nil` when there is none (an
    /// unborn HEAD) or it could not be read.
    ///
    /// Offered into an empty message field when Amend is turned on. `nil` is an
    /// honest answer here — "there is no previous message to reuse" — so unlike
    /// the two above this one is defaulted to `nil` rather than to a throw.
    func headMessage(root: URL) async throws -> String?

    /// Create a commit from `plan` with `message`, amending `HEAD` when `amend`.
    ///
    /// The implementation builds the commit in a **throw-away index**
    /// (`GIT_INDEX_FILE` seeded with `read-tree HEAD`), applies the plan's entries
    /// to it, and runs a real `git commit` against it — a real commit rather than
    /// `commit-tree` so `pre-commit`/`commit-msg` hooks and git's own author
    /// resolution keep working, and so the hooks see exactly the content being
    /// committed through `git diff --cached`. A successful commit is followed by a
    /// single `git reset --quiet` on the *real* index, the one deliberate touch of
    /// it (see `CommitPlan` for what that discards and why).
    ///
    /// Throws `GitError.commitFailed(reason:)` carrying git's stderr on any
    /// non-zero exit, having left the real index and `HEAD` untouched. Defaulted
    /// to `throw GitError.gitUnavailable`.
    func commit(_ plan: CommitPlan, message: String, amend: Bool, root: URL) async throws

    /// Push per `plan` — a plain `git push` for a branch that has an upstream, or
    /// `git push --set-upstream <remote> <branch>` for one that does not.
    ///
    /// Called only after a successful commit, and only for an available plan
    /// (`PushPlan.unavailable` is never passed). A non-zero exit throws
    /// `GitError.pushFailed(reason:)` — which the dialog reports as "commit
    /// created, push failed" rather than as a failed commit. Defaulted to
    /// `throw GitError.gitUnavailable`.
    func push(_ plan: PushPlan, root: URL) async throws

    /// Fast-forward the checked-out branch from its upstream: `git pull --ff-only`
    /// in `root`, **and nothing else**.
    ///
    /// `--ff-only` is the whole contract, not a default this call could be talked
    /// out of. The one caller is the post-merge tail, which has just switched to
    /// the base branch of a pull request GitHub merged, so the only honest outcome
    /// is "advance to what the remote already has". Anything else a plain `pull`
    /// would do — a merge commit, a rebase, a conflicted worktree — would be this
    /// feature writing history nobody asked for, inside a writer bracket, on a
    /// branch the user has not looked at yet. A branch that cannot fast-forward is
    /// a state to *report*, and git's refusal names the divergence.
    ///
    /// No remote or refspec is named: the checked-out branch's upstream is git's
    /// own answer, and naming one here would let this call pull a branch the tail
    /// never switched to. A non-zero exit throws `GitError.pullFailed(reason:)`
    /// carrying git's own words. Defaulted in a protocol extension to
    /// `throw GitError.gitUnavailable` so every existing stub keeps compiling —
    /// and iOS is deliberately left at that default: the post-merge tail is macOS
    /// only, and libgit2 gains nothing from a fast-forward it has no caller for.
    func pull(root: URL) async throws

    /// Blame the file at `fileURL`, returning one entry per line of the file in
    /// final-line order (`nil` where the output carried no data for that line).
    ///
    /// This is a **worktree blame**: it describes the bytes currently *on disk*,
    /// not whatever an editor buffer holds. A buffer with unsaved edits is
    /// therefore ahead of what this answers, so the gutter's annotation column can
    /// sit offset by whole lines until the next save recomputes it — an accepted,
    /// self-healing inaccuracy documented in full on the view layer's
    /// `BlameController`. Deliberately no `--contents` variant: blaming a temp
    /// copy of the buffer would blame a file git has never seen (every unsaved
    /// line comes back uncommitted anyway), and saving on toggle would make a
    /// read-only inspection command write the user's file.
    ///
    /// The signature deliberately deviates from the `(path:root:)` shape the rest
    /// of this protocol uses and takes an **absolute file URL** instead: the
    /// caller here is the editor, which holds a workspace URL rather than a
    /// repo-relative path and has no repository root at hand. The implementation
    /// runs git with the file's own directory as the working directory and lets
    /// git discover the repository, so no `repositoryRoot(for:)` round-trip is
    /// needed on a path the user is merely looking at.
    ///
    /// Throws when the file is **outside a repository** (or git is unavailable, or
    /// the blame otherwise exits non-zero); the caller swallows the failure and
    /// leaves the column empty. Defaulted in a protocol extension to `[]` so every
    /// existing stub — and the iOS `LibGit2Service`, which has no gutter to
    /// annotate — keeps compiling untouched.
    func blame(fileURL: URL) async throws -> [BlameLine?]
}

/// Defaults for the Log-only methods so stubs that simulate just the Local Changes
/// surface (and never touch commit detail) keep compiling without implementing
/// them — the same protocol-extension-default pattern `FileServicing` uses for its
/// optional tree-mutation methods. The real `Process`-backed `GitCLIService`
/// overrides both.
public extension GitServicing {
    func headBlob(of path: String, root: URL) async throws -> Data? { nil }

    func commitChanges(hash: String, root: URL) async throws -> [ChangedFile] { [] }

    func fileContents(at revision: String, path: String, root: URL) async throws -> String? { nil }

    func references(root: URL) async throws -> [String] { [] }

    func blob(stage: Int, path: String, root: URL) async throws -> String? { nil }

    func stage(path: String, root: URL) async throws {}

    func stageRemoval(path: String, root: URL) async throws {}

    func currentBranch(root: URL) async throws -> BranchRef? { nil }

    func checkout(branch: String, root: URL) async throws { throw GitError.gitUnavailable }

    func createAndCheckout(name: String, startPoint: String, root: URL) async throws {
        throw GitError.gitUnavailable
    }

    func fetch(remote: String, root: URL) async throws { throw GitError.gitUnavailable }

    func blame(fileURL: URL) async throws -> [BlameLine?] { [] }

    func commitContext(root: URL) async throws -> CommitContext {
        throw GitError.gitUnavailable
    }

    func identity(root: URL) async throws -> CommitIdentity { throw GitError.gitUnavailable }

    func setLocalIdentity(name: String, email: String, root: URL) async throws {
        throw GitError.gitUnavailable
    }

    func headMessage(root: URL) async throws -> String? { nil }

    func commit(_ plan: CommitPlan, message: String, amend: Bool, root: URL) async throws {
        throw GitError.gitUnavailable
    }

    func push(_ plan: PushPlan, root: URL) async throws { throw GitError.gitUnavailable }

    func pull(root: URL) async throws { throw GitError.gitUnavailable }
}

/// A `revert` failure that also reports which repo-relative paths it had already
/// changed on disk before failing.
///
/// A rename revert restores the old path from `HEAD` *then* removes the new path;
/// it can fail after the first step, leaving the old path restored. A single-file
/// `checkout` is likewise non-atomic — it writes the worktree before committing
/// the index, so a late index-write failure can exit non-zero with the worktree
/// already restored. A model catching the error cannot otherwise tell what
/// reached disk — guessing risks reloading/closing an open tab on a path the
/// revert never touched (discarding unsaved edits there). The service conforms
/// its interrupted-revert error to this so the caller resyncs exactly the changed
/// paths and nothing more. A failure that did not change disk does not conform.
public protocol PartialRevertError: Error {
    /// The repo-relative paths whose on-disk state changed before the failure.
    var changedPaths: [String] { get }
}
