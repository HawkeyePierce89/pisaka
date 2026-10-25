import Foundation

/// Which rows the project tree draws for one folder's listing: a file, a plain
/// folder, or a **chain** — a run of folders each holding nothing but the next,
/// drawn as one `a/b/c` row whose expansion goes straight to the last folder's
/// contents.
///
/// **The rule is applied to a listing's entries only.** The project root is
/// never one of them — the view builds the root node as itself — which is what
/// keeps the root out of every chain.
///
/// **A folder qualifies** when it is not in `separated` and its listing is
/// exactly one entry that is a directory. For each directory entry `d`:
///
/// - `d` a symbolic link → a plain folder row, never listed;
/// - `d`'s listing fails → a plain folder row (nothing is remembered for the
///   failure, so the row's own expansion retries as before);
/// - otherwise `d` is listed and the walk appends the single child `e` while the
///   last segment qualifies and the chain is shorter than `maximumSegments`,
///   checking `e` first: in `separated` → stop before it; a symbolic link →
///   append it as the **tail** without listing it; its listing fails → stop
///   before it (it becomes a plain row under the tail); otherwise append and
///   list it.
///
/// A chain of one segment is a plain folder row. Every failure while probing is
/// **silent**: it shapes the answer and never throws out of the rule.
public enum TreeChainRule {
    /// The longest chain the walk builds. The last segment is still listed, so
    /// its listing is the tail's contents and the rest of the run appears as
    /// that tail's children.
    public static let maximumSegments = 32

    /// The key a folder is remembered under — in `separated` and in the listing
    /// memo alike: the url as the tree spells it, standardized and never
    /// resolved, so this adds no canonicalisation site of its own.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// The rows to draw for `parentListing`, in its order.
    ///
    /// - Parameters:
    ///   - parentListing: the folder's own listing, read by the caller.
    ///   - separated: the keys (`key(for:)`) of folders the user asked to see
    ///     as separate folders.
    ///   - isSymbolicLink: whether a url is a symbolic link — a link query,
    ///     never a listing.
    ///   - list: the listing function every probe reads through.
    public static func rows(
        in parentListing: [DirectoryEntry],
        separated: Set<String>,
        isSymbolicLink: (URL) -> Bool,
        list: (URL) throws -> [DirectoryEntry]
    ) -> [TreeRow] {
        parentListing.map { entry in
            row(for: entry, separated: separated, isSymbolicLink: isSymbolicLink, list: list)
        }
    }

    private static func row(
        for entry: DirectoryEntry,
        separated: Set<String>,
        isSymbolicLink: (URL) -> Bool,
        list: (URL) throws -> [DirectoryEntry]
    ) -> TreeRow {
        guard entry.isDirectory else { return .file(entry) }
        guard !isSymbolicLink(entry.url), let headListing = try? list(entry.url) else {
            return .folder(entry, offersShowAsOneRow: false)
        }
        guard !separated.contains(key(for: entry.url)) else {
            return .folder(entry, offersShowAsOneRow: holdsOneFolder(headListing))
        }

        var segments = [entry]
        var tailListing: [DirectoryEntry]? = headListing
        while let listing = tailListing, holdsOneFolder(listing), segments.count < maximumSegments {
            let next = listing[0]
            if separated.contains(key(for: next.url)) { break }
            if isSymbolicLink(next.url) {
                segments.append(next)
                tailListing = nil
                break
            }
            guard let nextListing = try? list(next.url) else { break }
            segments.append(next)
            tailListing = nextListing
        }

        guard segments.count > 1 else { return .folder(entry, offersShowAsOneRow: false) }
        return .chain(TreeChain(segments: segments, tailListing: tailListing))
    }

    /// The listing half of "qualifies": exactly one entry, and it is a directory.
    private static func holdsOneFolder(_ listing: [DirectoryEntry]) -> Bool {
        listing.count == 1 && listing[0].isDirectory
    }
}

/// One row of the project tree, as `TreeChainRule` answers it.
public enum TreeRow: Equatable, Identifiable {
    /// A file entry.
    case file(DirectoryEntry)
    /// A folder drawn as itself. `offersShowAsOneRow` is true exactly when the
    /// folder is separated by the user *and* would otherwise qualify.
    case folder(DirectoryEntry, offersShowAsOneRow: Bool)
    /// A run of at least two folders drawn as one row.
    case chain(TreeChain)

    /// The entry's url, or the chain's head. A folder keeps its identity as it
    /// turns from plain to chain and back, which is what lets the view keep its
    /// state (expansion above all) across a reshape.
    public var id: URL {
        switch self {
        case .file(let entry), .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.identity
        }
    }

    /// Whether this row still offers the way down to an open draft — the
    /// question a reload asks of its rows, for a draft anchored below the
    /// reloaded folder.
    ///
    /// `anchor` is the folder the draft writes into (a create's parent, a
    /// rename's containing directory) and `renamed` the entry a rename names.
    /// A plain entry leads when it is renamed, or when it is a folder holding
    /// the anchor. A chain leads only when the anchor is its tail or lies under
    /// it, or when the draft renames its tail: a draft anchored on an inner
    /// segment is no longer drawn anywhere. Containment is
    /// `ScopedFileAccess.path(_:isWithin:)` over standardized paths only.
    public func leads(toDraftAnchor anchor: URL, renaming renamed: URL?) -> Bool {
        let anchorPath = anchor.standardizedFileURL.path
        let renamedPath = renamed?.standardizedFileURL.path
        switch self {
        case .file(let entry):
            return renamedPath == entry.url.standardizedFileURL.path
        case .folder(let entry, _):
            let path = entry.url.standardizedFileURL.path
            return renamedPath == path || ScopedFileAccess.path(anchorPath, isWithin: path)
        case .chain(let chain):
            let tailPath = chain.tail.url.standardizedFileURL.path
            return renamedPath == tailPath || ScopedFileAccess.path(anchorPath, isWithin: tailPath)
        }
    }
}

/// A run of folders drawn as one row, with every operation's address as data.
///
/// The row stands for the head's subtree and shows the tail's contents, so
/// what is *about the row* addresses the head (identity, delete, drag, the
/// diagnostic mark, the spoken git state) and what is *about its contents*
/// addresses the tail (contents, create, rename, drop).
public struct TreeChain: Equatable {
    /// The folders, head first; at least two.
    public let segments: [DirectoryEntry]
    /// The tail's listing as the walk read it, handed down as the row's
    /// contents; `nil` for a symbolic-link tail, which loads on expansion.
    public let tailListing: [DirectoryEntry]?

    public init(segments: [DirectoryEntry], tailListing: [DirectoryEntry]?) {
        precondition(segments.count >= 2, "a chain has at least two segments")
        self.segments = segments
        self.tailListing = tailListing
    }

    public var head: DirectoryEntry { segments[0] }
    public var tail: DirectoryEntry { segments[segments.count - 1] }
    /// Every segment but the tail — drawn as text before a rename field.
    public var leadingSegments: [DirectoryEntry] { Array(segments.dropLast()) }
    /// The folder heading the row drawn under the head once the chain is shown
    /// as separate folders — the second segment. Unfolding an *expanded* chain
    /// opens it on first appearance, so nothing the user was looking at
    /// disappears.
    public var remainderHead: URL { segments[1].url }

    /// The row id, expansion key and unfold key.
    public var identity: URL { head.url }
    public var contentsDirectory: URL { tail.url }
    public var createTarget: URL { tail.url }
    public var renameTarget: DirectoryEntry { tail }
    public var deleteTarget: URL { head.url }
    public var dragSource: URL { head.url }
    public var dropDestination: URL { tail.url }
    public var diagnosticMarkURL: URL { head.url }
    public var spokenGitStateURL: URL { head.url }
    /// Each segment's url, for its own git colouring.
    public var gitStatusURLs: [URL] { segments.map(\.url) }

    /// The segment names joined with `/`.
    public var label: String { segments.map(\.name).joined(separator: "/") }

    /// The names a rename of the tail must not collide with: the listing of the
    /// tail's parent segment, which is the tail alone (the field excludes the
    /// entry's own name, as it does for any rename).
    public var renameSiblings: [String] { [tail.name] }

    public var renameTitle: String { "Rename \"\(tail.name)\"" }
    public var deleteTitle: String { "Delete \"\(label)\"" }
    public static let showAsSeparateFoldersTitle = "Show as Separate Folders"
    /// The title a separated, qualifying plain folder row offers.
    public static let showAsOneRowTitle = "Show as One Row"

    /// Each segment's reveal spelling, head first: the head's reveal url, then
    /// one segment name appended per level — the same spelling
    /// `TreeRevealRule` builds, so a reveal request matches every segment.
    public func revealURLs(underHeadRevealURL headRevealURL: URL) -> [URL] {
        var directory = headRevealURL
        var answer = [headRevealURL]
        for segment in segments.dropFirst() {
            directory = directory.appendingPathComponent(segment.name, isDirectory: true)
            answer.append(directory)
        }
        return answer
    }
}

/// One listing per directory per tree revision: the memo every node's load —
/// the parent's chain probe included — lists through, so the listing read while
/// probing a chain's tail is the one that tail's row shows when expanded, and
/// the order in which a parent and an already-expanded child load never causes
/// a second read within one revision.
///
/// **Successes only are remembered.** A failed listing is thrown to the caller
/// and re-read on the next ask, which keeps the tree's collapse/re-expand retry
/// exactly as it was. Asking under a different revision forgets everything
/// first; `reset()` does the same for a project-root change. Keyed by
/// `TreeChainRule.key(for:)`, the spelling `separated` uses, so the memo adds no
/// canonicalisation site of its own.
///
/// The memo lists only when asked; it never lists on its own.
public final class TreeListingMemo {
    private let list: (URL) throws -> [DirectoryEntry]
    private var revision: Int?
    private var listings: [String: [DirectoryEntry]] = [:]

    /// - Parameter list: the listing function a miss reads through.
    public init(list: @escaping (URL) throws -> [DirectoryEntry]) {
        self.list = list
    }

    /// The listing of `url` under `revision`: the remembered one when this
    /// revision already read it, otherwise a fresh read, remembered on success.
    public func listing(of url: URL, revision: Int) throws -> [DirectoryEntry] {
        if self.revision != revision {
            listings.removeAll()
            self.revision = revision
        }
        let key = TreeChainRule.key(for: url)
        if let remembered = listings[key] { return remembered }
        let listing = try list(url)
        listings[key] = listing
        return listing
    }

    /// Forget every listing — a project-root change.
    public func reset() {
        listings.removeAll()
        revision = nil
    }
}
