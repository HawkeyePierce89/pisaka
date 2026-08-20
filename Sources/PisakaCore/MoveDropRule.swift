import Foundation

/// Why a drag-and-drop move in the project tree cannot happen.
///
/// A `LocalizedError` on purpose: a refusal that *does* reach the drop reports
/// through the *same* failure path as every other project-tree file operation
/// (`reportFileOperationFailure(_:)` → `NSAlert(error:)`), so the tree needs no
/// alert code of its own and the wording lives beside the rule that produced it
/// — the same arrangement `FileServiceError` and `EntryPathIssue` already use.
/// Which refusals reach it is a short list; see "How a refusal reaches the user"
/// on `MoveDropRule`.
///
/// The texts name the entry (and, for a collision, the folder) and are written
/// here rather than borrowed from `FileManager`: its own messages describe a
/// *failed system call*, while every case below is a decision this engine made
/// before touching the disk.
public enum MoveDropRefusal: Error, LocalizedError, Equatable {
    /// The drop landed on the folder the entry already lives in. Not a failure:
    /// the user aimed at a no-op, so nothing is reported (`isSilent`).
    case unchangedLocation
    /// The drop landed on the dragged entry itself (canonically — see the note
    /// on symlinks in `MoveDropRule`).
    case ontoItself
    /// The drop landed inside the dragged folder's own subtree, which would move
    /// a directory into itself.
    case intoOwnDescendant
    /// The destination folder already holds an entry with that name. Carries
    /// both names so the message can point at the collision.
    case nameTaken(name: String, folder: String)
    /// The dragged entry vanished between the drag starting and the drop
    /// landing (deleted in Finder, moved by a git operation).
    case sourceMissing(name: String)
    /// The destination folder could not be listed — it vanished, or it is not
    /// readable.
    case targetMissing(name: String)

    /// Whether this refusal should pass without a word to the user.
    ///
    /// True for `unchangedLocation` alone: dropping an entry back into the
    /// folder it is already in is how a user cancels a drag they thought better
    /// of, and an alert for it would be noise. Every other case is something the
    /// user asked for and did not get, so it is reported *if it gets that far* —
    /// the hover answer refuses most of them before a drop can be performed at
    /// all, which is why this flag guards a path a structural refusal cannot
    /// normally reach. It is kept as the rule's own statement of intent: any
    /// caller that reaches `moveItem` by another route (or a SwiftUI that ever
    /// routes an unvalidated drop there) must not turn a cancelled drag into an
    /// alert.
    public var isSilent: Bool { self == .unchangedLocation }

    public var errorDescription: String? {
        switch self {
        case .unchangedLocation:
            return "The item is already in that folder."
        case .ontoItself:
            return "An item cannot be moved onto itself."
        case .intoOwnDescendant:
            return "A folder cannot be moved inside itself."
        case let .nameTaken(name, folder):
            return "\"\(name)\" already exists in \"\(folder)\"."
        case let .sourceMissing(name):
            return "\"\(name)\" no longer exists."
        case let .targetMissing(name):
            return "The folder \"\(name)\" is no longer available."
        }
    }
}

/// What a drag-and-drop move in the project tree should do.
public enum MoveDropDecision: Equatable {
    /// The move may run, landing at `destination`.
    case move(destination: URL)
    /// The move may not run, for this reason.
    case refuse(MoveDropRefusal)
}

/// The one place that decides whether a project-tree drag may land on a folder,
/// and where the dragged entry would end up.
///
/// Two halves, one vocabulary:
///
/// - `structuralDecision(source:into:)` is **disk-free** — pure path arithmetic
///   over `CanonicalPath`: identity, ancestry and the drop-onto-current-parent
///   no-op, the three answers no directory listing can change.
/// - `decision(source:into:fileService:)` runs those same rules first and then
///   adds the two facts only the disk knows (does the destination already hold
///   that name, is the dragged entry still there).
///
/// **The full decision is the one the view asks — for the hover as well as for
/// the drop.** A highlight drawn from the structural half alone would light a
/// row up for a collision it cannot see, and the drop would then refuse what the
/// row had just promised; so the view asks this one and memoizes it per
/// `(source, target)` pair instead, which is what makes the expensive half
/// affordable — it runs once per row *entered*, not once per mouse-moved event.
/// `structuralDecision` is therefore the separately-tested first half rather
/// than a second call site, and both returning the same `MoveDropDecision` is
/// what keeps the highlight and the move on one destination rule.
///
/// ## How a refusal reaches the user — mostly, it does not
///
/// SwiftUI runs `performDrop` only for a drop `validateDrop` accepted, and
/// `validateDrop` is this engine. So the ordinary refusals — a collision, a
/// self-drop, a descendant, the same-parent no-op — never reach
/// `PisakaApp.moveItem(at:into:)` at all: the row stays unlit, the pointer shows
/// the refusal cursor, and releasing does nothing. That *is* the feedback, and
/// it is the right one for a gesture whose whole answer is visible while it is
/// being made.
///
/// The alert path exists for what the hover answer cannot have caught.
/// `moveItem` re-asks behind the writer gate, at the moment the move would
/// happen, so a destination that gained the name — or a source that vanished —
/// between the hover and the release is *reported* rather than silently
/// dropped. `isSilent` marks the one refusal that must stay quiet even there.
///
/// ## Why identity and ancestry are canonical, not textual
///
/// A tree row and the url a caller computed can spell the same file differently
/// — `/tmp` vs `/private/tmp`, a trailing slash, a `.` component, a symlinked
/// project root. A textual comparison would let a drag "onto itself" through
/// whenever the two spellings differ, and `FileService.move` would then either
/// fail obscurely or, worse, succeed at something the user did not ask for. So
/// both questions go through `CanonicalPath`, exactly as
/// `WorkspaceModel.planRename(from:to:)` matches tabs — the two must agree,
/// since the plan is what carries open tabs across the very move this engine
/// authorized.
///
/// ## Symlinks are refused conservatively
///
/// `CanonicalPath.canonical(_:)` resolves symlinks, so a row that *is* a symlink
/// pointing at the destination folder canonicalizes onto it and is refused as
/// `ontoItself` — even though moving the link entry itself would be a
/// well-defined operation. Likewise, dropping a symlinked folder into something
/// under its referent reads as `intoOwnDescendant`. That is deliberate and
/// consistent with `planRename`, which resolves the same way: a rare, ambiguous
/// drag is refused with a clear message instead of being carried out under a
/// reading the user may not share.
///
/// ## The collision check is not the last word
///
/// The name check compares the exact last path component against the
/// destination's listing, which cannot see the collision a *case-insensitive*
/// volume would produce (`README.md` dropped beside an existing `readme.md`).
/// `FileService.move` refuses to clobber and raises
/// `FileServiceError.alreadyExists`, and that stays the backstop — this check
/// exists to suppress the drop *highlight* early and to phrase the refusal in
/// the tree's own words, not to be the only guard.
///
/// ## Spelling
///
/// The destination is `<the folder as the user spelled it>/<the source's last
/// component>` — a move never renames. Spelled paths are stored, canonical
/// paths compared, per the project's path rule.
public enum MoveDropRule {

    /// The disk-free half: identity, ancestry and the no-op, decided from the
    /// paths alone.
    public static func structuralDecision(source: URL, into folder: URL) -> MoveDropDecision {
        // Compared as *paths*, not as `URL`s: a url built for a directory keeps a
        // trailing slash that survives standardization, so two spellings of one
        // folder can canonicalize to unequal `URL` values while naming the same
        // path. Every other canonical comparison in the project
        // (`SymbolIndex`, `EditorSession`, `LeetCodeModel`) keys on `.path` for
        // this reason.
        let canonicalSource = CanonicalPath.canonical(source)
        let canonicalFolder = CanonicalPath.canonical(folder)

        guard canonicalSource.path != canonicalFolder.path else { return .refuse(.ontoItself) }

        if CanonicalPath.relativeComponents(
            of: canonicalFolder.pathComponents,
            under: canonicalSource.pathComponents
        ) != nil {
            return .refuse(.intoOwnDescendant)
        }

        // The entry's *spelled* parent, not the resolved one: a symlink row lives
        // in the directory that holds the link, so dropping it beside its referent
        // is a genuine move rather than a no-op.
        let parent = CanonicalPath.canonical(source.deletingLastPathComponent())
        guard parent.path != canonicalFolder.path else { return .refuse(.unchangedLocation) }

        return .move(destination: folder.appendingPathComponent(source.lastPathComponent))
    }

    /// The full decision: the structural rules plus the two disk facts.
    ///
    /// The destination folder is listed first (an unlistable folder is
    /// `targetMissing`) for the name collision, and the source is then confirmed
    /// still present in its own parent's listing. Both listings are why this is
    /// the *drop* question and the memoized one, never the per-mouse-move one.
    public static func decision(
        source: URL,
        into folder: URL,
        fileService: FileServicing
    ) -> MoveDropDecision {
        let structural = structuralDecision(source: source, into: folder)
        guard case .move = structural else { return structural }

        let name = source.lastPathComponent

        let destinationEntries: [DirectoryEntry]
        do {
            destinationEntries = try fileService.contentsOfDirectory(at: folder)
        } catch {
            return .refuse(.targetMissing(name: folder.lastPathComponent))
        }
        if destinationEntries.contains(where: { $0.url.lastPathComponent == name }) {
            return .refuse(.nameTaken(name: name, folder: folder.lastPathComponent))
        }

        let siblings: [DirectoryEntry]
        do {
            siblings = try fileService.contentsOfDirectory(at: source.deletingLastPathComponent())
        } catch {
            return .refuse(.sourceMissing(name: name))
        }
        guard siblings.contains(where: { $0.url.lastPathComponent == name }) else {
            return .refuse(.sourceMissing(name: name))
        }

        return structural
    }
}
