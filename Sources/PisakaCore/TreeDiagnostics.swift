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

/// The project tree's view of the diagnostic store: kept current on every
/// store change (by ``TreeDiagnosticsIndex``, one file at a time), then asked
/// per row with no file-system call.
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
/// then read from the table — one key read, whatever the store holds, its
/// descent a handful of trie levels — and `resolve(_:)` reports the reads so a
/// test can pin that.
///
/// The table is a persistent hash trie (``MarkTrie``), so a value the tree still
/// holds shares every node a later move does not write: across a publication a
/// one-file move copies only the nodes on its keys' paths — the file's depth
/// times the trie's, which grows with the logarithm of the marked keys, never
/// with their number (see ``TreeDiagnosticsIndex``). Hashing is the process's
/// own, so every lookup built in one run is shaped the same way.
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

    // `fileprivate(set)`: written only by ``TreeDiagnosticsIndex`` below, which
    // keeps the spellings empty whenever the table is, so the synthesized
    // equality still makes a lookup that marks nothing equal ``empty``.
    fileprivate(set) var spellings: [[String]]
    fileprivate(set) var table: MarkTrie

    /// The lookup with nothing in it: every row answers `none`. What the tree
    /// holds with no folder open and right after a folder change.
    public static let empty = TreeDiagnostics(spellings: [], table: MarkTrie())

    private init(spellings: [[String]], table: MarkTrie) {
        self.spellings = spellings
        self.table = table
    }

    /// The mark stored under `key`, whose hash is `hash`.
    fileprivate func mark(atKey key: String, hash: Int) -> TreeDiagnosticMark {
        table.value(forKey: key, hash: hash) ?? .none
    }

    public init(store: DiagnosticStore, root: Root) {
        self = TreeDiagnosticsIndex(store: store, root: root).lookup
    }

    /// The mark one store entry contributes: its worst severity, narrowed —
    /// `none` for no entry, an all-clear one, or information and hints alone.
    static func mark(of entry: DiagnosticStore.Entry?) -> TreeDiagnosticMark {
        entry?.severities.max().map(TreeDiagnosticMark.init) ?? .none
    }

    /// The mark of the row at `url`.
    public func mark(for url: URL) -> TreeDiagnosticMark {
        resolve(url).mark
    }

    /// The answer together with the number of table reads it took — the seam
    /// the cost bound is pinned through.
    func resolve(_ url: URL) -> (mark: TreeDiagnosticMark, probes: Int) {
        guard let key = Self.key(for: url, spellings: spellings) else { return (.none, 0) }
        let joined = key.joined(separator: "/")
        return (mark(atKey: joined, hash: joined.hashValue), 1)
    }

    /// The root-relative components of `url`, or `nil` when it lies under
    /// none of the spellings — the root itself is the empty key. Lexical: the
    /// URL is standardized, never resolved.
    fileprivate static func key(for url: URL, spellings: [[String]]) -> [String]? {
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

/// The bookkeeping that keeps a ``TreeDiagnostics`` current one file at a
/// time, so a store mutation touching one document costs that file's depth
/// rather than a rebuild over every diagnosed file.
///
/// A rebuild per mutation is quadratic exactly where this feature lives: a
/// server reporting on the whole workspace pushes once per file, and every
/// keystroke in a flagged file shifts its set. So each key keeps a **tally** —
/// how many files at or below it are worst-marked `error`, how many `warning`
/// — and its mark is read off the tally: a file whose mark falls can lower a
/// folder's only when no other file below still holds it up, which a running
/// maximum cannot tell and a count can. Each recorded file remembers its own
/// mark and the keys of its ancestry, so the root-relative key is computed
/// once per file, not once per change.
///
/// ``lookup`` is the published value; only its table changes per record, and
/// only when some key's mark does. Built by ``DiagnosticsModel`` and kept
/// there: the bookkeeping is never published, so a copy the tree holds shares
/// only the table. The first write after a publication therefore copies what
/// it writes through (copy-on-write, the tree still holding the old value):
/// each trie node on the written key's path once — a branch's children, a
/// leaf's keys, both bounded by ``MarkTrie``'s constants — never the whole
/// table, which a flat dictionary would copy on every push of a
/// workspace-wide burst, nor a slice proportional to it, which a fixed split
/// would. ``copiedEntries`` counts those copies apart from ``steps``; a record
/// that changes no mark writes nothing and copies nothing.
struct TreeDiagnosticsIndex {
    private struct Tally {
        var errors = 0
        var warnings = 0

        var mark: TreeDiagnosticMark {
            errors > 0 ? .error : warnings > 0 ? .warning : .none
        }

        mutating func add(_ mark: TreeDiagnosticMark, _ delta: Int) {
            switch mark {
            case .error: errors += delta
            case .warning: warnings += delta
            case .none: break
            }
        }
    }

    private struct FileRecord {
        let mark: TreeDiagnosticMark
        /// The file's own key first, then each ancestor's, ending at the root's
        /// empty key.
        let keys: [String]
    }

    private(set) var lookup = TreeDiagnostics.empty
    private let spellings: [[String]]
    private var tallies: [String: Tally] = [:]
    private var files: [URL: FileRecord] = [:]

    /// Keys visited by ``record(_:for:)`` since this index was made — the seam
    /// the per-change cost bound is pinned through, counted apart from the
    /// table writes it pays for.
    private(set) var steps = 0

    /// Which trie nodes copy-on-write has paid for since the last
    /// ``notePublished()``, and the entries those copies cost.
    private var ledger = MarkTrie.CopyLedger()

    /// Entries copied by the first write through each trie node since this
    /// index was made — a branch's children or a leaf's keys, what
    /// copy-on-write pays when a published value still shares the node.
    var copiedEntries: Int { ledger.copied }

    init(root: TreeDiagnostics.Root) {
        spellings = root.spellings
    }

    init(store: DiagnosticStore, root: TreeDiagnostics.Root) {
        self.init(root: root)
        for (url, entry) in store.entriesByURL {
            record(TreeDiagnostics.mark(of: entry), for: url)
        }
    }

    /// `url`'s worst mark is now `mark`: move its tally along its ancestry and
    /// rewrite the marks that changed. Returns whether ``lookup`` changed.
    /// A file under neither spelling contributes nothing.
    @discardableResult
    mutating func record(_ mark: TreeDiagnosticMark, for url: URL) -> Bool {
        let fileKey = url.standardizedFileURL
        let previous = files[fileKey]
        let oldMark = previous?.mark ?? .none
        guard oldMark != mark else { return false }
        let keys: [String]
        if let previous {
            keys = previous.keys
        } else {
            guard var components = TreeDiagnostics.key(for: fileKey, spellings: spellings) else { return false }
            var ancestry = [components.joined(separator: "/")]
            while !components.isEmpty {
                components.removeLast()
                ancestry.append(components.joined(separator: "/"))
            }
            keys = ancestry
        }
        files[fileKey] = mark == .none ? nil : FileRecord(mark: mark, keys: keys)

        var changed = false
        for key in keys {
            steps += 1
            var tally = tallies[key] ?? Tally()
            tally.add(oldMark, -1)
            tally.add(mark, 1)
            let newMark = tally.mark
            tallies[key] = newMark == .none ? nil : tally
            let hash = key.hashValue
            if lookup.mark(atKey: key, hash: hash) != newMark {
                lookup.table.update(newMark == .none ? nil : newMark, forKey: key, hash: hash, ledger: &ledger)
                changed = true
            }
        }
        if changed {
            lookup.spellings = lookup.table.count == 0 ? [] : spellings
        }
        return changed
    }

    /// ``lookup`` was handed out: every node is shared again until written.
    mutating func notePublished() {
        ledger.notePublished()
    }
}

/// The marks table: a hash trie whose nodes are values, so a copy shares every
/// node and a write copies only the nodes on its key's path (copy-on-write,
/// node by node) — what keeps a move after a publication bounded by the
/// trie's depth rather than by the number of marked keys.
///
/// Each level reads ``bitsPerLevel`` more bits of the key's hash, low bits
/// first. A node is a **branch** — ``fanout`` children, no keys of its own —
/// exactly when more than ``leafCapacity`` keys lie under it and its level is
/// above ``maxLevel``, where the hash has run out of bits; otherwise it is a
/// **leaf** holding its keys in one dictionary. A write splits a leaf that
/// outgrows the capacity and collapses a branch that falls back within it, so
/// the shape is a pure function of the key set — which is what lets the
/// synthesized equality compare contents, and a table emptied by removals
/// equal a fresh one. Equality and every read short-circuit on shared storage,
/// so comparing a value against its own successor costs the written path.
struct MarkTrie: Equatable, Sendable {
    /// Children per branch: one per value of ``bitsPerLevel`` hash bits.
    static let fanout = 1 << bitsPerLevel
    static let bitsPerLevel = 5
    /// The most keys a leaf above ``maxLevel`` holds before it splits.
    static let leafCapacity = 16
    /// The level whose nodes are always leaves: past it the hash has no bits
    /// left to tell keys apart, so a full-hash collision shares a leaf.
    static let maxLevel = (Int.bitWidth + bitsPerLevel - 1) / bitsPerLevel

    /// Keys at or below this node.
    private(set) var count = 0
    /// A leaf's keys; empty in a branch.
    private var entries: [String: TreeDiagnosticMark] = [:]
    /// A branch's ``fanout`` children; empty in a leaf.
    private var children: [MarkTrie] = []

    /// Where copy-on-write has paid since the last publication: each node is
    /// copied by the first write through it while a published value shares
    /// it, so the ledger charges a node once per publication, by its size.
    struct CopyLedger {
        private(set) var copied = 0
        private var written: Set<MarkTrieNodeID> = []

        fileprivate mutating func charge(level: Int, hash: Int, size: Int) {
            let mask = level == 0 ? 0 : (1 << (level * MarkTrie.bitsPerLevel)) &- 1
            if written.insert(MarkTrieNodeID(level: level, prefix: hash & mask)).inserted {
                copied += size
            }
        }

        mutating func notePublished() {
            written.removeAll(keepingCapacity: true)
        }
    }

    /// The child slot `hash` takes at `level`.
    private static func slot(_ hash: Int, _ level: Int) -> Int {
        (hash >> (level * bitsPerLevel)) & (fanout - 1)
    }

    /// The value stored under `key`, whose hash is `hash`.
    func value(forKey key: String, hash: Int, level: Int = 0) -> TreeDiagnosticMark? {
        if children.isEmpty { return entries[key] }
        return children[Self.slot(hash, level)].value(forKey: key, hash: hash, level: level + 1)
    }

    /// Store `mark` under `key`, or remove the key when `mark` is `nil`,
    /// charging `ledger` for each node the write passes through.
    mutating func update(
        _ mark: TreeDiagnosticMark?,
        forKey key: String,
        hash: Int,
        level: Int = 0,
        ledger: inout CopyLedger
    ) {
        ledger.charge(level: level, hash: hash, size: children.isEmpty ? entries.count : children.count)
        if children.isEmpty {
            if let mark {
                entries[key] = mark
            } else {
                entries.removeValue(forKey: key)
            }
            count = entries.count
            if count > Self.leafCapacity && level < Self.maxLevel { split(level: level) }
            return
        }
        let child = Self.slot(hash, level)
        let before = children[child].count
        children[child].update(mark, forKey: key, hash: hash, level: level + 1, ledger: &ledger)
        count += children[child].count - before
        if count <= Self.leafCapacity { collapse() }
    }

    /// Turn this overfull leaf into a branch, its keys moved into freshly built
    /// children — which nothing published shares, so a scratch ledger takes
    /// their charges.
    private mutating func split(level: Int) {
        let moved = entries
        entries = [:]
        children = Array(repeating: MarkTrie(), count: Self.fanout)
        var fresh = CopyLedger()
        for (key, mark) in moved {
            let hash = key.hashValue
            children[Self.slot(hash, level)].update(mark, forKey: key, hash: hash, level: level + 1, ledger: &fresh)
        }
    }

    /// Turn this branch, now within a leaf's capacity, back into a leaf.
    private mutating func collapse() {
        var gathered: [String: TreeDiagnosticMark] = [:]
        gathered.reserveCapacity(count)
        gather(into: &gathered)
        children = []
        entries = gathered
    }

    private func gather(into gathered: inout [String: TreeDiagnosticMark]) {
        if children.isEmpty {
            gathered.merge(entries) { _, new in new }
        } else {
            for child in children { child.gather(into: &gathered) }
        }
    }

    /// The deepest level any node reaches — the seam a test reads to bound a
    /// write's path by the trie's actual depth.
    var depth: Int {
        children.isEmpty ? 0 : 1 + (children.map(\.depth).max() ?? 0)
    }
}

/// One trie node's identity for ``MarkTrie/CopyLedger``: its level and the
/// hash bits that lead to it, which no other node at that level shares.
private struct MarkTrieNodeID: Hashable {
    let level: Int
    let prefix: Int
}
