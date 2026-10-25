import Foundation

/// What a project-tree row says about diagnostics: the worst severity known at
/// or below it, narrowed to the two the tree marks.
///
/// Closed, and declared weakest first — the order the synthesized `Comparable`
/// follows, so `error` outranks `warning`, which outranks `none`, and `max`
/// is the aggregation. Information and hints give `none`: the mark answers
/// "is something broken here", the header's own rule, not "was anything said".
public enum TreeDiagnosticMark: CaseIterable, Comparable, Hashable, Sendable {
    /// Nothing at or below this row is an error or a warning.
    case none
    /// The worst diagnostic at or below this row is a warning.
    case warning
    /// An error is reported at or below this row.
    case error

    /// The severity the mark stands for — what the tree hands
    /// `ChromeColorRole.diagnosticRole(for:)`, so no view switches over a
    /// severity itself. `nil` for `none`, which draws nothing.
    public var severity: DiagnosticSeverity? {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .none: return nil
        }
    }

    /// The mark as words, for the row's accessibility value; `nil` for `none`,
    /// which has nothing to say.
    public var spokenName: String? {
        switch self {
        case .error: return "has errors"
        case .warning: return "has warnings"
        case .none: return nil
        }
    }

    /// The mark one diagnostic severity contributes.
    init(_ severity: DiagnosticSeverity) {
        switch severity {
        case .error: self = .error
        case .warning: self = .warning
        case .information, .hint: self = .none
        }
    }
}

/// The project tree's view of the diagnostic store: built on every store
/// change, then asked per row with no file-system call.
///
/// **Built** from the store and the opened folder's two spellings, resolved
/// once per folder change (``Root``), in time linear in the diagnosed files
/// times their depth: each entry of either kind — a buffer's mapped set and a
/// closed file's positional one alike — contributes its worst severity, made
/// relative to the first spelling its standardized path lies under, lexically;
/// an entry under neither spelling contributes nothing. That key and every
/// ancestor, up to and including the root's empty key, keep the strongest mark
/// recorded at or below it, so a folder answers for everything beneath it
/// whether or not it is expanded.
///
/// **Asked** with a row URL as the tree holds it: the URL is standardized and
/// stripped of whichever spelling it lies under, giving the same relative key,
/// then read from the table — one dictionary read, whatever the store holds,
/// and `resolve(_:)` reports it so a test can pin that.
///
/// Equality is synthesized over the spellings and the table, and the table is a
/// pure function of each file's worst severity — so a keystroke that shifts a
/// flagged file's offsets without changing its worst severity builds an equal
/// lookup, which is what lets the publisher skip an unchanged value. A lookup
/// that marks nothing *is* ``empty``, whatever folder it was built for: with no
/// mark to find, the spellings answer nothing, so a folder change that empties
/// the store publishes the same value a model with no folder holds.
///
/// A **reader**: it neither raises the writer gate nor is gated by it.
public struct TreeDiagnostics: Equatable, Sendable {
    /// The opened folder's two spellings — standardized, as the tree spells its
    /// rows, and canonical, as a server may spell what it reports — as path
    /// components. Resolving the canonical one is the only file-system call in
    /// this type, which is why it is a value of its own: built once per folder
    /// change, never per build or per row.
    public struct Root: Equatable, Sendable {
        let spellings: [[String]]

        public init(_ folder: URL) {
            spellings = [
                folder.standardizedFileURL.pathComponents,
                CanonicalPath.canonical(folder).pathComponents,
            ]
        }
    }

    private let spellings: [[String]]
    private let marks: [String: TreeDiagnosticMark]

    /// The lookup with nothing in it: every row answers `none`. What the tree
    /// holds with no folder open and right after a folder change.
    public static let empty = TreeDiagnostics(spellings: [], marks: [:])

    private init(spellings: [[String]], marks: [String: TreeDiagnosticMark]) {
        self.spellings = spellings
        self.marks = marks
    }

    public init(store: DiagnosticStore, root: Root) {
        var marks: [String: TreeDiagnosticMark] = [:]
        for (url, entry) in store.entriesByURL {
            guard let worst = entry.severities.max() else { continue }
            let mark = TreeDiagnosticMark(worst)
            guard mark != .none,
                  var components = Self.key(for: url, spellings: root.spellings) else { continue }
            while true {
                let key = components.joined(separator: "/")
                // Every ancestor of a recorded key already holds at least that
                // key's mark, so the first one at least as strong ends the climb
                // without changing the answer.
                if let existing = marks[key], existing >= mark { break }
                marks[key] = mark
                if components.isEmpty { break }
                components.removeLast()
            }
        }
        self.init(spellings: marks.isEmpty ? [] : root.spellings, marks: marks)
    }

    /// The mark of the row at `url`.
    public func mark(for url: URL) -> TreeDiagnosticMark {
        resolve(url).mark
    }

    /// The answer together with the number of table reads it took — the seam
    /// the cost bound is pinned through.
    func resolve(_ url: URL) -> (mark: TreeDiagnosticMark, probes: Int) {
        guard let key = Self.key(for: url, spellings: spellings) else { return (.none, 0) }
        return (marks[key.joined(separator: "/")] ?? .none, 1)
    }

    /// The root-relative components of `url`, or `nil` when it lies under
    /// none of the spellings — the root itself is the empty key. Lexical: the
    /// URL is standardized, never resolved.
    private static func key(for url: URL, spellings: [[String]]) -> [String]? {
        let components = url.standardizedFileURL.pathComponents
        for spelling in spellings {
            if components == spelling { return [] }
            if let below = CanonicalPath.relativeComponents(of: components, under: spelling) {
                return below
            }
        }
        return nil
    }
}
