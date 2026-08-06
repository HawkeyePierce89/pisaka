import Foundation

/// The file mode a partial commit has to name explicitly, and the two decisions
/// around it — parsing what git records, and reconciling it with what is on disk.
///
/// Pure and Foundation-only, in Core for the `ShellQuote`/`BlameParser`/
/// `GitStatusParser` reason: the `Process` invocation and the `lstat` belong to
/// `GitCLIService`, but the parse and the reconciliation are off-by-one-prone
/// decisions whose failure is *silent* — a wrong mode drops an executable bit, or
/// records a symlink whose target is a whole file's text, with nothing reporting
/// an error and the damage visible only on a later checkout. So they live here
/// under tests.
///
/// A whole file never needs any of this: it enters the commit through
/// `CommitPlanEntry.addFromWorktree`, i.e. git stages the working file and
/// resolves its own mode. Only assembled (`addContent`) blobs do.
public enum GitFileMode {
    /// An ordinary file, and git's own default for anything unreadable.
    public static let regular = "100644"
    /// An ordinary file with the owner-execute bit set.
    public static let executable = "100755"
    /// A symbolic link, whose blob content is the link's target string.
    public static let symlink = "120000"

    /// The mode field of one `git ls-tree` record (`100644 blob <sha>\t<path>`),
    /// or `nil` when the output carries none.
    ///
    /// The mode is the leading run of digits; anything else — empty output (the
    /// path is not in the tree), a message, a leading space — yields `nil` so the
    /// caller falls back to the working file rather than staging a mode it
    /// invented.
    public static func parse(lsTreeOutput: String) -> String? {
        let mode = lsTreeOutput.prefix { $0.isNumber }
        return mode.isEmpty ? nil : String(mode)
    }

    /// The git mode of a working file with the given `lstat` facts.
    public static func worktree(isSymlink: Bool, isExecutable: Bool) -> String {
        if isSymlink { return symlink }
        return isExecutable ? executable : regular
    }

    /// The mode to stage for an assembled blob whose path already exists at
    /// `HEAD`, given what git records there and what the working file actually is.
    ///
    /// Keeping `head` is the point of reading it at all: committing three lines of
    /// an executable script must not silently drop its exec bit, and the working
    /// file's own permissions may differ from what the repository records (a
    /// checkout on a volume that loses them, `core.fileMode=false`).
    ///
    /// The one case where the recorded mode must **not** be kept is a *typechange*
    /// — a path that was a symlink and is now a regular file, or the reverse. git
    /// reports it as an ordinary modification (porcelain's `T`, which
    /// `GitStatusParser` maps to `.modified`), so such a file reaches the dialog as
    /// selectable text on both sides: a link contributes its target string, a
    /// regular file its contents. The link/non-link distinction is therefore never
    /// inherited from `head`; only the exec bit is.
    ///
    /// **Neither direction of a typechange may record a link, and that is the whole
    /// point of the function.** The reverse direction is the obvious one: staging
    /// assembled text under a recorded `120000` would commit a symlink whose target
    /// is that entire text. The *forward* direction (a regular file at `HEAD`
    /// replaced by a link in the worktree) reaches exactly the same corruption from
    /// the other side — the worktree mode is `120000` while the assembled bytes are
    /// a mixture of the old file's lines and the link's target — so taking the
    /// worktree mode wholesale is not safe either. A blob this app assembled is
    /// text it produced line by line and is never a link target, so a typechange
    /// resolves to `regular` whenever the worktree is the link. git validates
    /// neither mode, so nothing else would report the mistake: it surfaces only as
    /// a broken link on a later checkout.
    public static func reconciled(head: String, worktree: String) -> String {
        let headIsLink = head == symlink
        let worktreeIsLink = worktree == symlink
        guard headIsLink == worktreeIsLink else {
            return worktreeIsLink ? regular : worktree
        }
        return head
    }
}
