# PisakaCore — git service protocol, status & blame

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `GitError.swift` — a `GitServicing` failure the model surfaces to the user:
    `public enum GitError: Error, Equatable, LocalizedError` with cases
    `gitUnavailable`, `notARepository(stderr:)`, `revertFailed(reason:)`,
    `checkoutFailed(reason:)` (a refused branch checkout — carries the exact git
    message naming the conflicting files), `fetchFailed(reason:)` (a failed
    `fetch`), `pullFailed(reason:)` (a refused `pull --ff-only` — a base branch
    that has diverged from its upstream, whose divergence git's own words name), `credentialsRequired(host:)` (the branch-switcher's iOS HTTPS
    path — no PAT stored for `host`), and the commit dialog's pair
    `commitFailed(reason:)` / `pushFailed(reason:)`. Those two are deliberately
    **not** one case: `reason` carries git's stderr verbatim (for the commonest
    failure — a `pre-commit`/`commit-msg` hook refusing — the hook's output *is*
    the explanation, and paraphrasing it would throw away the only thing saying
    what to fix), and "the commit was created, the push was not" is a distinct
    state the dialog must report as such, because retrying it as a commit would
    create a second one. Its
    `errorDescription` switch carries the human text (the `notARepository` empty-
    stderr fallback to "This folder is not a git repository.", the trimmed stderr
    otherwise, the `revertFailed`/`checkoutFailed`/`fetchFailed`/`pullFailed`/`commitFailed`/
    `pushFailed` reason, and
    `credentialsRequired` → "Add a Personal Access Token for <host> in Settings").
    Lives in Core (not the
    `Process`-backed `GitCLIService`) so `LocalChangesModel`'s
    `errorMessage = error.localizedDescription` is meaningful and unit-testable —
    the `FileIconColor`/`FileStatus` move-semantics-into-Core precedent.
  - `GitServicing.swift` — git access for the Local Changes view, abstracted
    behind a protocol whose four methods are all `async throws`
    (`repositoryRoot(for:)`, `changedFiles(root:)`, `headContents(of:root:)`, and
    the one mutating call `revert(_:root:)`) — so every `git` run happens off the
    main thread (the real `GitCLIService` bridges `Process` onto a serial queue) —
    so `LocalChangesModel` is testable with a stub.
    `repositoryRoot(for:)` resolves the working-tree top level for a (possibly
    nested) opened folder so every other call runs against one consistent root:
    `git status` paths are relative to the directory git runs in, while
    `git show HEAD:<path>` is always repo-root-relative, so running from a
    subdirectory would make the two disagree (and surface `../` paths outside the
    opened folder). `revert(_:root:)` discards a file's local changes back to its
    `HEAD` version (destructive/irreversible, so the view layer always confirms
    first); its doc comment specifies the per-`FileStatus` behavior (restore from
    `HEAD` for tracked files; delete for the no-`HEAD` added/untracked cases) and
    it `throws` so the model can surface a failure. Foundation-only declaration
    (no `Process`); the real `Process`-backed `GitCLIService` lives in `Pisaka`,
    the same protocol-behind-injectable-stub split as `FileServicing`. Four more
    `async throws` methods back the Log view, all defaulted in a protocol extension
    (`commitChanges`/`references` → `[]`, `fileContents` → `nil`) so non-Log stubs
    keep compiling: `commits(filter:limit:root:)` (the history list — the real
    service runs `git log` with `Commit.prettyFormat`, topo order + `--parents`,
    constrained by `LogFilter.gitArguments()` and capped at `limit`),
    `references(root:)` (full branch/tag refnames for the filter picker, most-useful
    first — local branches, remotes, then tags), `commitChanges(hash:root:)` (the
    commit's files vs its *first* parent — a merge is the mainline diff, not a
    combined one; a root commit diffs against the empty tree), and
    `fileContents(at:path:root:)` (a file's contents at a revision/hash, `nil` when
    absent there — the model reads the new side at the commit and the old side at
    its first parent to build a `LineDiff`). Two more `async throws` methods back
    the conflict resolver, all defaulted in the protocol extension (`blob` → `nil`,
    `stage`/`stageRemoval` → no-op) so non-merge stubs keep compiling:
    `blob(stage:path:root:)`
    (the contents of the merge index `stage`-numbered entry — `1` base, `2` ours,
    `3` theirs — `nil` when that stage is absent, which is a *meaningful* case: no
    `1` is add/add with no common ancestor, no `2`/`3` is a modify/delete), the
    mutating `stage(path:root:)` (`git add` the resolved working file), and the
    mutating `stageRemoval(path:root:)` (`git rm -f` the file — used when a
    modify/delete conflict is resolved to the deleted side, so apply stages a
    deletion rather than an empty file). Four more `async throws` methods back the
    branch-switcher, all defaulted in the protocol extension so existing stubs keep
    compiling: `currentBranch(root:) -> BranchRef?` (defaulted `nil`; the branch
    *list* reuses the existing `references(root:)`, so no `branches(...)` method is
    added — only `currentBranch` is new), and the three mutations
    `checkout(branch:root:)`, `createAndCheckout(name:startPoint:root:)`, and
    `fetch(remote:root:)` (each defaulted to `throw GitError.gitUnavailable` — the
    existing "this stub/service can't do it" signal; there is no
    `GitError.unsupported`). One more `async throws` method backs the editor
    gutter's annotate column, defaulted to `[]` in the protocol extension so every
    existing stub — and the iOS `LibGit2Service`, which has no gutter — keeps
    compiling untouched: `blame(fileURL:) -> [BlameLine?]`, one entry per file line
    in final-line order (`nil` where the output carried no data for that line). It
    is a **worktree blame**: it describes the bytes currently *on disk*, not what an
    editor buffer holds, so a buffer with unsaved edits is ahead of what it answers
    and the column can sit offset by whole lines until the next save recomputes it —
    an accepted, self-healing inaccuracy documented in full on `BlameController`.
    Deliberately no `--contents` variant (blaming a temp copy of the buffer would
    blame a file git has never seen, and every unsaved line comes back uncommitted
    anyway; saving on toggle would make a read-only inspection command write the
    user's file). The signature deliberately **deviates from the `(path:root:)`
    shape** the rest of the protocol uses and takes an *absolute file URL*: the
    caller is the editor, which holds a workspace URL rather than a repo-relative
    path and has no repository root at hand, so the implementation runs git with the
    file's own directory as the working directory and lets git discover the
    repository — no `repositoryRoot(for:)` round-trip on a path the user is merely
    looking at. It throws when the file is outside a repository (or git is
    unavailable, or the blame otherwise exits non-zero); the caller swallows that
    and leaves the column empty.
    Seven more `async throws` methods back the **commit dialog**, again all
    defaulted in the protocol extension so every existing stub and the iOS
    `LibGit2Service` (which has no commit UI) compile untouched.
    `headBlob(of:root:) -> Data?` is the byte-level HEAD accessor, defaulted
    `nil`, and its contract is the point: **`nil` means "the path is absent from
    HEAD" and is decided by git's exit code**, never by decodability — the bytes
    come back raw and classifying them is `GitBlobText`'s job. It exists because
    `headContents(of:root:) -> String?` is unfit for the classification: a
    `String?` **conflates the two questions**, since the only value it has for
    "absent" is the one it would also need for "present but undecodable". Which
    way it fails depends on the decode, and both ways are wrong — `GitCLIService`
    decodes stdout *lossily*, so a binary blob arrives as plausible U+FFFD-laden
    text, while a strict decode would make it indistinguishable from absence. Under
    either reading a file that is **binary in HEAD and text in the worktree**
    classifies as wholly *added*, with selectable per-line units over a falsely
    empty old side. `commitContext(root:)` and `identity(root:)` are defaulted to
    `throw GitError.gitUnavailable` rather than to some empty value, deliberately:
    unlike `references(root:) -> []` there is no honest "nothing" for either, and
    a fabricated context would let `CommitGate` reach a verdict from fiction (that
    pushing is impossible, or that no merge is in progress) precisely where the
    gate stands in for git's own protections. `setLocalIdentity(name:email:root:)`
    writes **local config only** — fixing one repository's author must never
    change every other repository on the machine — `headMessage(root:)` is
    defaulted `nil` (an honest "there is no previous message to reuse"),
    `commit(_:message:amend:root:)` builds the commit in a throw-away
    `GIT_INDEX_FILE` and runs a **real `git commit`** against it (see
    `GitCLIService`), and `push(_:root:)` executes a `PushPlan`. The last two are
    defaulted to `throw GitError.gitUnavailable`.
    One more mutating method backs the Pull Requests feature's post-merge tail,
    defaulted the same way: `pull(root:)`, whose whole contract is
    **`git pull --ff-only` and nothing else**. The `--ff-only` is not a default it
    could be talked out of — its one caller has just switched to the base branch
    of a pull request GitHub merged, so the only honest outcome is "advance to
    what the remote already has", and a merge commit, a rebase or a conflicted
    worktree would be that feature writing history nobody asked for, inside a
    writer bracket, on a branch the user has not looked at yet. It names **no
    remote and no refspec**: the checked-out branch's upstream is git's own
    answer, and naming one here would let the call pull a branch the tail never
    switched to. A non-zero exit throws `GitError.pullFailed(reason:)` with git's
    trimmed stderr; `GitCLIService` runs it on the same serial queue under
    `GIT_TERMINAL_PROMPT=0` as every other command, and **iOS is left at the
    protocol default** — the tail is macOS only, and libgit2 gains nothing from a
    fast-forward it has no caller for (`core-github.md`).
  - `ChangedFile.swift` — `FileStatus` (`modified, added, deleted, renamed,
    untracked, conflicted` — a color-free semantic enum like `FileIconColor`;
    `.conflicted` is a file left in a merge-conflict state, surfaced with a purple
    "C" badge and routed to the 3-pane merge editor instead of the diff viewer) and
    `ChangedFile` (a single file differing from `HEAD`: repo-relative `path` —
    the new path for a rename — `status`, `oldPath` set only for renames, and
    `id == path` for stable identity across refreshes).
  - `GitStatusParser.swift` — pure `static func parse(_ output: String) ->
    [ChangedFile]` over `git status --porcelain=v2` output. Handles the `1`
    (ordinary), `2` (rename/copy — new and old paths TAB-separated), `u`
    (unmerged — `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`, 10 fixed
    fields before the path, mapped to `.conflicted`), and `?` (untracked) record
    types, skipping `!` ignored / `#` header lines; maps the two-character `XY`
    field to a `FileStatus` (rename → `.renamed`; a *copy*, whose source is
    untouched, → `.added` of the new path with no `oldPath`, so a revert removes
    only the copy and never restores/`rm`s the source; then add/delete, else
    modified). The path is the unsplit remainder of the line, so paths with spaces
    survive intact (the `u` record's path is likewise the unsplit remainder after
    its 10 fields, and a short/malformed `u` line is skipped). Foundation-only; the
    off-by-one-prone field splitting is unit-tested in Core while the `Process`
    call lives in `GitCLIService`.
  - `BlameLine.swift` — the editor gutter's git-blame value type + the
    `git blame --porcelain` parser, Foundation-only (the `GitStatusParser`/`Commit`
    split: the grammar handling is unit-tested in Core, the `Process` invocation
    lives in `GitCLIService`). `public struct BlameLine: Equatable` carries `hash`
    (full commit hash — identity, and the key the view memoizes a rendered label
    under), `author`, `date` (a **raw ISO-8601 string** in `%aI`'s exact shape, so
    `Commit.date`'s convention holds and the two are interchangeable to a
    view-layer formatter; Core stays locale-free) and `summary`, plus a computed
    `isUncommitted` — the all-zero hash git gives a working-tree line that is in no
    commit yet (git spells its author `Not Committed Yet`). That is a *different
    fact* from a `nil` entry in the parser's output, which means "no blame data for
    this line at all"; both draw blank but the two stay distinct in the model.
    `public enum BlameParser { static func parse(_ output: String) -> [BlameLine?] }`
    returns one entry per file line in final-line order. **`--porcelain`, not
    `--line-porcelain`, is a deliberate choice**: porcelain emits a commit's
    metadata block *once* and later lines of the same commit carry only their
    header, so the parser keeps a `hash → metadata` table (~10 lines of code)
    instead of re-reading several times the output for a megabyte-scale file;
    placements are reconciled against that table after the whole output is read,
    and a test feeds a repeated commit with no metadata block to pin it. **The TAB
    rule — content is recognized before anything else.** Each blamed line's own
    source text is emitted prefixed with a single TAB, and that prefix is the *only*
    thing separating file content from the metadata grammar, which ordinary source
    code forges trivially: a Swift line reading `author Evil <x@y>` is byte for byte
    a valid `author` field, and one reading
    `0000000000000000000000000000000000000000 1 2 3` is a valid group header. So the
    parse loop's **first** test on every line is `hasPrefix("\t")` — such a line is
    consumed as content (closing the current group's metadata block) and never
    reaches the header or field matching. Getting that order wrong does not crash:
    it silently rewrites an author, or invents a whole group at a bogus line number,
    *from the file's own text* — which is why it is stated as a rule and pinned by
    fixtures spelled exactly like a header, an `author`, a `summary`, a `boundary`
    and a `previous`. A group header is
    `<40-hex sha> <orig-line> <final-line> [<num-lines>]` and entries are placed by
    the **final** line number (a gap stays `nil` rather than shifting later lines
    up); of the field lines the parser reads `author`, `author-time`, `author-tz`
    and `summary`, and **every other field falls off the end of the switch**, which
    deliberately covers the two shapes a naive "first token, rest is value" split
    mis-handles — **`boundary`** (a lone keyword line with *no* value) and
    **`previous <sha> <path>`** (whose second token is 40 hex characters, so it must
    not be mistaken for a header or for the group's own hash). Neither carries
    anything the column shows, so both are ignored rather than special-cased, and
    both are pinned by fixtures — including one where a field-shaped line follows
    the content with *no* TAB, which is the branch's one effect the other fixtures
    cannot observe (a TAB-prefixed line is inert anyway: it yields a 41-character
    "hash" and a `"\tauthor"` key, both of which fall through on their own).
    **Records are separated at the scalar LF, via `components(separatedBy: "\n")`
    and not `split(separator: "\n")`** — `String` compares by *grapheme cluster* and
    `\r\n` is one cluster unequal to `"\n"`, so on a CRLF checkout (whose content
    lines git emits verbatim, carrying their own CR) a grapheme-level split would
    not break there: each content line would fuse with the **following group
    header**, that fused string starts with a TAB, and the TAB rule would eat the
    header. Every annotation after the first vanishes, silently, with no error — the
    same class of failure the TAB rule itself guards against, which is why both a
    CRLF-content and a wholly-CRLF fixture pin it. The scalar split is also what
    makes the trailing-CR strip on each record meaningful.
    **Date synthesis:** porcelain gives
    `author-time <epoch>` + `author-tz <+0300>`, not an ISO string, so the parser
    synthesizes `2026-08-04T19:55:07+03:00` through one reusable `DateFormatter`
    (`en_US_POSIX`, `yyyy-MM-dd'T'HH:mm:ss`, `TimeZone(secondsFromGMT:)`) plus the
    offset re-spelled with a colon; a malformed/absent tz is `+00:00`, a missing
    epoch yields an empty `date`, and there is one formatter per parse rather than
    per line. **Robustness:** unknown/garbage lines skipped, a truncated final group
    kept with the hash it does have and empty fields, a missing field an empty
    string, a non-numeric/non-positive line number ignored, empty output → `[]`.
    Nothing traps. Unit-tested in `BlameParserTests`.
  - `BlameAlignment.swift` — pure placement of a `[BlameLine?]` blame result onto
    the editor's line starts (Foundation-only, `getCharacters` chunked like
    `BracketDepthScanner`). It exists because the two sides disagree about what a
    line *is*: `git blame` emits one entry per **LF-delimited** line and knows no
    other separator, while `LineStartIndex` — and so the gutter, the minimap and
    TextKit — also splits on a lone CR, NEL (U+0085), LS (U+2028) and PS (U+2029).
    A file carrying any of those has *more* displayed lines than git reported
    entries, so indexing the array by buffer line shifted every annotation after
    that character onto the wrong line: the wrong author and date, on a **clean,
    saved** buffer, reproduced identically by every recompute. That is a different
    failure from the whole-line offset `BlameController` documents and accepts —
    that one is bounded by the next save, this one never heals — and a misaligned
    author is exactly what `BlameShift`'s "blank is honest; a wrong author is not"
    rule refuses. `aligned(_:toLineStartsIn:lineStarts:)` maps a buffer line to
    the git line it is *part of*: the number of LFs strictly before its start. Two
    buffer lines split by a lone CR therefore share one annotation (correct — git
    saw them as one line), the result is exactly `lineStarts.count` long (the
    `annotations.count == lineCount` invariant `BlameShift` maintains, so the
    pad/truncate it replaced is subsumed), and for a file whose only separators are
    LF/CRLF the mapping is the **identity**, so the ordinary case is unchanged (a
    test pins that in both spellings). A line start outside the content is clamped
    rather than trapping and a non-ascending array degrades instead of rescanning
    backwards. Unit-tested in `BlameAlignmentTests`, including a chunk-seam
    fixture.
  - `BlameShift.swift` — pure incremental shift of a `[BlameLine?]` array across
    one text edit, so the annotation column keeps pointing at the lines it was
    loaded for while the user types instead of sliding onto their neighbours
    (Foundation-only, the `LineStartIndex.updated` shape). `public enum BlameShift
    { static func updated(previous: [BlameLine?], previousLineStarts: [Int],
    newLineStarts: [Int], editedRange: NSRange, changeInLength: Int) -> [BlameLine?]
    }`. It is **pure arithmetic over line-start arrays** — no `NSString`, no
    scanning, no content comparison — because the gutter already holds both arrays
    at the moment of the edit (`LineStartIndex.updated` produces the new one from
    the old), so passing them in costs nothing and buys the structural invariant
    that makes the result safe to index by line: `result.count ==
    newLineStarts.count`, always. **The touched span**, with `loc =
    editedRange.location` and `oldEnd = loc + editedRange.length - changeInLength`
    (the end of the replaced region in *pre-edit* coordinates): `first` = index of
    the last `previousLineStarts <= loc`; `last` = index of the last
    `previousLineStarts <= max(loc, oldEnd - 1)` — the line containing the **last
    character actually removed**, not the position just past it. *Why `oldEnd - 1`,
    clamped up to `loc`*: `oldEnd` is an exclusive bound, so on a whole-line
    deletion it lands exactly on the *next* line's start and pulls an untouched line
    into the span — with line starts `[0, 10, 20, 30]`, deleting line 1 entirely
    (`loc = 10`, 10 units removed, `oldEnd = 20`) gives `last = 2` under an `oldEnd`
    rule and discards old line 2's annotation although its content survived intact;
    with `max(loc, oldEnd - 1) = 19` the span is `1…1`, contributes zero new lines,
    and old lines 2–3 pass through the untouched-suffix branch carrying their own.
    The `max(loc, …)` clamp is what keeps a pure **insertion** correct (`oldEnd ==
    loc`, so a bare `oldEnd - 1` would reach back into the *previous* line and drag
    it into the span): there `last == first`, one line touched. Lines before `first`
    and after `last` are kept verbatim — their content is untouched, only their
    index shifts — so neither can migrate onto a foreign line. **Annotations survive
    only when the span's line count is unchanged**: `newSpanLength =
    newLineStarts.count - first - (previous.count - last - 1)` is *derived from the
    arrays* rather than guessed, and when it equals `last - first + 1` the edit was
    structure-preserving inside the span, so its annotations are copied position for
    position (an ordinary keystroke leaves the line's annotation in place — the
    deliberate inaccuracy the post-save recompute fixes); when the count differs —
    an Enter split, an insertion at a line start, a multi-line paste, a deletion
    joining two lines, a whole-line deletion (`newSpanLength == 0`, contributing
    nothing) — the **whole span becomes `nil`**. *Why not "the first touched line
    keeps its annotation"*: that weaker rule hands a real annotation to a line the
    user just created (inserting at a line start, or Enter at column 0, makes the
    first new line brand-new and empty, attributed to the previous line's commit).
    Tying survival to an unchanged line count makes it a structural property, at the
    cost of blanking a joined line — which the next save recomputes anyway. **Blank
    is honest; a wrong author is not.** The one boundary the arithmetic cannot see
    is a deletion of *exactly* a line separator (Backspace at column 0): the
    following line's start disappears without its index falling inside the span, so
    the joined line inherits the second line's annotation rather than blanking —
    distinguishing that needs the line's content, which this function deliberately
    does not read, and the next recompute settles it. **Fallback:** any inconsistent
    input returns `[BlameLine?](repeating: nil, count: newLineStarts.count)` — an
    honest "unknown" at the right length, never a drifted array — built *lazily* in
    a local `blank()` rather than up front, since this runs once per keystroke and
    the common path discards it (materializing one `nil` per document line per
    character typed is precisely the whole-document work the incremental shift
    exists to avoid). The checks are: `previous.count != previousLineStarts.count`;
    a line-start array not anchored at `0` (including an empty one); a negative
    `editedRange.location`/`length`; an `oldEnd` before `loc`, computed with
    `addingReportingOverflow`/`subtractingReportingOverflow` so a degenerate
    `NSNotFound` range falls back instead of trapping; and a negative
    `newSpanLength`. Deliberately **not** checked (and documented as such on the
    type, so it is not re-derived as an oversight): an edit lying wholly *past the
    end* of the previous text — line starts alone do not carry the buffer length, so
    catching it would need a further parameter for a case the only caller
    (`NSTextStorage.editedRange`) cannot produce; such an edit clamps to the final
    line and yields a shifted array rather than a blank one.
    Unit-tested in `BlameShiftTests`, including a deterministic-LCG fuzz
    block in `LineStartIndexTests`' shape asserting on every step that the length
    matches, that every line outside the span carries exactly its own annotation,
    and that inside it the span either kept its annotations position for position or
    is entirely `nil`.
