import Foundation

/// What a project-tree row's *name* says about git — the one answer the name's
/// colour and the row's spoken state are both drawn from.
///
/// Closed, and declared highest precedence first — the order the synthesized
/// `Comparable` follows, so a *lesser* state is a *stronger* one: a folder
/// holding a conflict and an edit is a conflict, an edit outranks an addition,
/// and every change state outranks ignore. `plain` is the absence of an
/// answer — outside a repository, an unchanged tracked file, a URL the lookup
/// cannot place — and carries no word, so a plain row reads exactly as it did
/// before git state was shown at all.
public enum TreeGitState: CaseIterable, Comparable, Hashable, Sendable {
    /// The path, or something below it, is unmerged.
    case conflict
    /// The path, or something below it, is modified, renamed onto or deleted.
    case modified
    /// The path, or something below it, is added (a copy included) or untracked.
    case added
    /// The path, or one of its ancestors, is ignored by git.
    case ignored
    /// Nothing git reported touches this row.
    case plain

    /// The state as a word, for the row's accessibility value; `nil` for
    /// `plain`, which has nothing to say.
    public var spokenName: String? {
        switch self {
        case .conflict: return "Conflicted"
        case .modified: return "Modified"
        case .added: return "Added"
        case .ignored: return "Ignored"
        case .plain: return nil
        }
    }

    /// The change state a status record contributes to its path and every
    /// ancestor. A rename contributes through its new path alone (the record's
    /// `path`; `oldPath` is never read), and a deletion counts as an edit to the
    /// folders it vanished from.
    static func changeState(for status: FileStatus) -> TreeGitState {
        switch status {
        case .conflicted: return .conflict
        case .modified, .renamed, .deleted: return .modified
        case .added, .untracked: return .added
        }
    }

    /// Which kind of row is being spoken for: a folder already says whether it
    /// is expanded, and the git state follows that word rather than replacing it.
    public enum RowKind: Equatable, Sendable {
        case file
        case folder(isExpanded: Bool)
    }

    /// A row's accessibility value, its words joined by `", "`: for a file,
    /// `"Test"` when the row is a test row (`TreeTestRule`), then the git
    /// state's word, then the diagnostic mark's words, each when there is one,
    /// or `""` when none is; for a folder, `"expanded"` / `"collapsed"` first,
    /// then `"Dependencies"` when the row is a dependency root
    /// (`DependencyFolderRule`), then each of the file's words that exists, in
    /// the same order.
    ///
    /// `isTestRow` and `isDependencyRoot` are required, with no default, so no
    /// call site can silently leave either unspoken: the wash the tree paints a
    /// test row with is colour alone, the dependency root's caption is a
    /// secondary-text word a listener never reaches, and these words are what
    /// carry them. `isDependencyRoot` is ignored for `.file` — a file is never
    /// a dependency root, so a file's words are the same whatever it is passed.
    public static func accessibilityValue(
        state: TreeGitState, mark: TreeDiagnosticMark, row: RowKind, isTestRow: Bool, isDependencyRoot: Bool
    ) -> String {
        let words = [isTestRow ? "Test" : nil, state.spokenName, mark.spokenName].compactMap { $0 }
        switch row {
        case .file:
            return words.joined(separator: ", ")
        case .folder(let isExpanded):
            let lead = [isExpanded ? "expanded" : "collapsed", isDependencyRoot ? "Dependencies" : nil]
            return (lead.compactMap { $0 } + words).joined(separator: ", ")
        }
    }
}

/// The project tree's view of one `git status` answer: built once per refresh,
/// then asked per row with no file-system call and no git call.
///
/// **Built** from the snapshot, the repository root git resolved and the opened
/// folder, in time linear in the records times their depth:
///
/// - every changed path and each of its ancestors, up to and including the
///   repository root's empty key, keeps the strongest change state recorded at
///   or below it — so a folder answers for everything beneath it whether or not
///   it is expanded, and a wholly untracked directory is `added` with no record
///   of its own;
/// - ignored paths go into a set and **never aggregate upward**: ignore reaches
///   a row only by ancestry, downward, or a folder holding an ignored directory
///   would be dimmed itself.
///
/// **Asked** with a row URL as the tree holds it. The URL is standardized
/// lexically and stripped of whichever root spelling it lies under — the opened
/// folder standardized and canonical (each mapped to the folder's prefix inside
/// the repository), then the repository root standardized and canonical — giving
/// a repo-relative key. The tree spells rows under the folder as the user
/// spelled it, while git reports a resolved top level, which is why the opened
/// folder is an input at all. The change table is read first, so a tracked
/// change outranks ignore; only on a miss are the key and its ancestors checked
/// against the ignored set. One dictionary read plus at most one set read per
/// level: the cost is bounded by the row's depth, never by the number of
/// records, and `resolve(_:)` reports it so a test can pin that.
///
/// The answer is git's alone — the gitignore matcher is not consulted — and the
/// lookup only reads, so it neither raises the writer gate nor is gated by it.
public struct TreeGitStatus: Equatable, Sendable {
    /// One way of spelling a directory the tree's rows may lie under, with the
    /// repo-relative components that directory stands for.
    private struct RootSpelling: Equatable, Sendable {
        let components: [String]
        let prefix: [String]
    }

    private let spellings: [RootSpelling]
    private let changeStates: [String: TreeGitState]
    private let ignored: Set<String>

    /// The lookup with nothing in it: every row answers `plain`. What the tree
    /// holds outside a repository, before the first refresh lands and after a
    /// refresh fails.
    public static let empty = TreeGitStatus(spellings: [], changeStates: [:], ignored: [])

    private init(spellings: [RootSpelling], changeStates: [String: TreeGitState], ignored: Set<String>) {
        self.spellings = spellings
        self.changeStates = changeStates
        self.ignored = ignored
    }

    public init(snapshot: GitStatusSnapshot, repositoryRoot: URL, openedFolder: URL) {
        let prefix = LocalChangesModel.projectPrefix(folder: openedFolder, repositoryRoot: repositoryRoot)
        let prefixComponents = prefix.isEmpty ? [] : prefix.components(separatedBy: "/")
        let folderSpelled = openedFolder.standardizedFileURL
        let rootSpelled = repositoryRoot.standardizedFileURL
        // Duplicates are harmless: `key(for:)` stops at the first match, and two
        // equal spellings carry the same prefix.
        let spellings = [
            (folderSpelled, prefixComponents),
            (CanonicalPath.canonical(folderSpelled), prefixComponents),
            (rootSpelled, []),
            (CanonicalPath.canonical(rootSpelled), []),
        ].map { RootSpelling(components: $0.0.pathComponents, prefix: $0.1) }

        var changeStates: [String: TreeGitState] = [:]
        for file in snapshot.changedFiles {
            let state = TreeGitState.changeState(for: file.status)
            var components = file.path.split(separator: "/", omittingEmptySubsequences: true)
            while true {
                let key = components.joined(separator: "/")
                // Every ancestor of a recorded key already holds at least that
                // key's state, so the first ancestor at least as strong ends the
                // climb without changing the answer.
                if let existing = changeStates[key], existing <= state { break }
                changeStates[key] = state
                if components.isEmpty { break }
                components.removeLast()
            }
        }

        self.init(
            spellings: spellings,
            changeStates: changeStates,
            ignored: Set(snapshot.ignoredPaths)
        )
    }

    /// The git state of the row at `url`.
    public func state(for url: URL) -> TreeGitState {
        resolve(url).state
    }

    /// The answer together with the number of table and set reads it took —
    /// the seam the cost bound is pinned through.
    func resolve(_ url: URL) -> (state: TreeGitState, probes: Int) {
        guard let key = key(for: url) else { return (.plain, 0) }
        var probes = 1
        if let change = changeStates[key.joined(separator: "/")] { return (change, probes) }
        var ancestry = key[...]
        while !ancestry.isEmpty {
            probes += 1
            if ignored.contains(ancestry.joined(separator: "/")) { return (.ignored, probes) }
            ancestry = ancestry.dropLast()
        }
        return (.plain, probes)
    }

    /// The repo-relative components of `url`, or `nil` when it lies under none
    /// of the root spellings. Lexical: the URL is standardized, never resolved.
    private func key(for url: URL) -> [String]? {
        let components = url.standardizedFileURL.pathComponents
        for spelling in spellings {
            if components == spelling.components { return spelling.prefix }
            if let below = CanonicalPath.relativeComponents(of: components, under: spelling.components) {
                return spelling.prefix + below
            }
        }
        return nil
    }
}
