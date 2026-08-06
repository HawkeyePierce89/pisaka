import Foundation

/// A single git branch reference surfaced in the branch-switcher widget.
///
/// Pure value type (the `ChangedFile`/`DirectoryEntry` precedent): built from
/// the *full* refnames `GitServicing.references(root:)` returns
/// (`refs/heads/main`, `refs/remotes/origin/master`) plus the current branch's
/// short name. `name` keeps the full refname (stable identity, and the exact
/// revision a checkout/`createAndCheckout` start point needs); `shortName` is
/// what the widget displays. `isRemote`/`remoteName` classify it, `isCurrent`
/// marks the checked-out branch.
public struct BranchRef: Equatable, Identifiable {
    /// The full refname, e.g. `refs/heads/main` or `refs/remotes/origin/master`.
    public let name: String
    public let isRemote: Bool
    /// The remote name for a remote branch (`origin`), else `nil`.
    public let remoteName: String?
    /// The display/short name: `main`, or `origin/master` for a remote branch.
    public let shortName: String
    public let isCurrent: Bool

    public init(
        name: String,
        isRemote: Bool,
        remoteName: String?,
        shortName: String,
        isCurrent: Bool
    ) {
        self.name = name
        self.isRemote = isRemote
        self.remoteName = remoteName
        self.shortName = shortName
        self.isCurrent = isCurrent
    }

    /// Stable identity from the full refname.
    public var id: String { name }

    private static let localPrefix = "refs/heads/"
    private static let remotePrefix = "refs/remotes/"
    private static let tagPrefix = "refs/tags/"

    /// Build the branch list from full refnames + the current short branch name.
    ///
    /// Drops tags (`refs/tags/…`) and any symbolic `.../HEAD` ref (e.g.
    /// `refs/remotes/origin/HEAD`), builds a `BranchRef` for each local
    /// (`refs/heads/…`) and remote (`refs/remotes/<remote>/…`) branch, marks the
    /// one whose short name equals `current` (a detached HEAD passes `nil`, so
    /// none is current), and sorts by short name case-insensitively. Locals sort
    /// ahead of remotes so the caller can split without re-sorting.
    public static func build(fromRefnames refnames: [String], current: String?) -> [BranchRef] {
        var refs: [BranchRef] = []
        for refname in refnames {
            if refname.hasPrefix(localPrefix) {
                let short = String(refname.dropFirst(localPrefix.count))
                if short.isEmpty { continue }
                refs.append(BranchRef(
                    name: refname,
                    isRemote: false,
                    remoteName: nil,
                    shortName: short,
                    isCurrent: short == current
                ))
            } else if refname.hasPrefix(remotePrefix) {
                let rest = String(refname.dropFirst(remotePrefix.count))
                // rest == "<remote>/<branch...>"; drop the "<remote>/HEAD" symref.
                guard let slash = rest.firstIndex(of: "/") else { continue }
                let remote = String(rest[rest.startIndex..<slash])
                let branch = String(rest[rest.index(after: slash)...])
                if remote.isEmpty || branch.isEmpty { continue }
                if branch == "HEAD" { continue }
                refs.append(BranchRef(
                    name: refname,
                    isRemote: true,
                    remoteName: remote,
                    shortName: rest,
                    isCurrent: false
                ))
            }
            // Tags and anything else are ignored.
        }
        return refs.sorted { a, b in
            if a.isRemote != b.isRemote { return !a.isRemote }
            return a.shortName.localizedCaseInsensitiveCompare(b.shortName) == .orderedAscending
        }
    }

    /// The local branches, in `build` order.
    public static func locals(_ refs: [BranchRef]) -> [BranchRef] {
        refs.filter { !$0.isRemote }
    }

    /// The remote branches, in `build` order.
    public static func remotes(_ refs: [BranchRef]) -> [BranchRef] {
        refs.filter { $0.isRemote }
    }

    /// Case-insensitive substring filter over short names; a blank query passes
    /// everything through (trimmed).
    public static func filtered(_ refs: [BranchRef], query: String) -> [BranchRef] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return refs }
        return refs.filter { $0.shortName.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}
