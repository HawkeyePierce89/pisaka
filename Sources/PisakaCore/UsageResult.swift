import Foundation

/// One place an identifier is used — the row the usages panel draws and the
/// editor navigates to.
///
/// **A location, not a declaration**, for `DefinitionCandidate`'s reason (D8) and
/// then some: the question "where is this used" has no kind in its answer at all,
/// not even the optional one a definition carries, because every row is by
/// construction a *reference* rather than a thing that was declared. So the type
/// is flat: a file, a buffer range, the line the gutter would print beside it, the
/// path the group header shows, and the one line of text a row displays.
///
/// `isTextual` is the honesty flag. A row from a language server is a semantic
/// reference — the server resolved the symbol and this is genuinely it — while a
/// row from `TextualUsageScanner` is a whole-word string match that may name a
/// completely unrelated symbol with the same spelling. The two are the same shape
/// and must never be presented as the same claim, so the provenance travels with
/// the row rather than only with the answer that carries it: a panel that lost the
/// distinction would be a panel confidently listing coincidences.
public struct UsageResult: Equatable, Sendable {
    /// The file the usage is in.
    public let fileURL: URL
    /// UTF-16 range of the occurrence in that file, in the coordinates of the text
    /// the row was computed against — the open buffer where one existed, the disk
    /// copy otherwise.
    public let range: NSRange
    /// 1-based display line of `range`, counted with the editor's own separators
    /// (`LineStartIndex`) rather than with the protocol's (D1), so the number in
    /// the row is the number in the gutter.
    public let line: Int
    /// The file's path below the project root, or its file name when it lives
    /// outside one — precomputed here for `DefinitionCandidate.relativePath`'s
    /// reason: the root is the provider's knowledge, and both platforms must spell
    /// the same file identically.
    public let relativePath: String
    /// The single line the row shows, with the occurrence's range inside it —
    /// Find in Files' shape, so a usages row and a search row read alike.
    public let preview: MatchPreview
    /// Whether this row is a whole-word text match rather than a resolved
    /// reference. See the type's note: this is a claim about how much the row
    /// means, not a display detail.
    public let isTextual: Bool

    public init(
        fileURL: URL,
        range: NSRange,
        line: Int,
        relativePath: String,
        preview: MatchPreview,
        isTextual: Bool
    ) {
        self.fileURL = fileURL
        self.range = range
        self.line = line
        self.relativePath = relativePath
        self.preview = preview
        self.isTextual = isTextual
    }
}

/// How much a set of usage rows *means* — the one thing the panel must never
/// blur.
///
/// `semantic` rows came from a language server that resolved the symbol: every
/// row is genuinely this symbol, and nothing that merely spells the same. A
/// `textual` answer is `TextualUsageScanner`'s whole-word scan, which knows
/// nothing about scope, shadowing or types: `count` in one file may be a local
/// variable and in the next a property of an unrelated type. Both are useful;
/// only one is a claim about the program, so the panel says which it is holding.
///
/// Two cases and no third: an answer is *never* a mixture. The model asks the
/// server first and falls to the scan only when the server produced nothing at
/// all (decision 1), so there is no state in which half the rows mean one thing
/// and half the other — and a `mixed` case would be exactly the blur this type
/// exists to prevent.
public enum UsageProvenance: String, Equatable, Sendable {
    /// A language server resolved the symbol; each row is a reference to it.
    case semantic
    /// A whole-word text scan; each row merely spells the identifier.
    case textual
}

/// One complete answer to "where is this used" — the identifier that was asked
/// about, the rows in the order the panel draws them, what they mean, and
/// whether the cap bit.
///
/// The rows reaching this type have already been through `make`'s hygiene, which
/// is the whole reason the type exists rather than the model publishing a bare
/// array: dedup, ordering and the cap are three rules with edge cases worth
/// testing once, and a second caller assembling rows by hand would be a second
/// spelling of them.
public struct UsagesAnswer: Equatable, Sendable {
    /// **The most usages one answer may carry.**
    ///
    /// Deliberately far below Find in Files' 10 000: that cap is sized for
    /// arbitrary patterns over a whole project, where a broad pattern legitimately
    /// matches thousands of lines someone then narrows. This list answers one
    /// question about one name, and an identifier used more than two thousand
    /// times is not a list anyone reads to the end — it is a signal to ask a
    /// narrower question. The cap is stated in the header when it bites, so a
    /// truncated answer is never mistaken for a complete one.
    public static let cap = 2_000

    /// The identifier the question was about, exactly as it is spelled in the
    /// buffer — the panel header's subject, and what `clearIfNaming(_:)` compares
    /// after a rename.
    public let identifier: String
    /// The rows, deduplicated, ordered and capped by `make`.
    public let rows: [UsageResult]
    /// What the rows mean. See `UsageProvenance`.
    public let provenance: UsageProvenance
    /// Whether `rows` is the head of a longer list — set only by `make`, and only
    /// when the cap actually removed something.
    public let isTruncated: Bool

    public init(
        identifier: String,
        rows: [UsageResult],
        provenance: UsageProvenance,
        isTruncated: Bool
    ) {
        self.identifier = identifier
        self.rows = rows
        self.provenance = provenance
        self.isTruncated = isTruncated
    }

    /// Whether there is nothing to draw. An empty answer is still an answer —
    /// the panel says "no usages", it does not stay on the previous question's
    /// rows.
    public var isEmpty: Bool { rows.isEmpty }

    /// The hygiene, applied in the one order that makes each step mean what it
    /// says: **dedup, then order, then cap**.
    ///
    /// - **Dedup** by *(canonical file, range)*. Canonical because the two
    ///   sources of rows spell files differently on purpose — a server answers
    ///   with the path it resolved (`/private/tmp/…` for a project opened as
    ///   `/tmp/…`), the walk answers with the path the user opened — and two rows
    ///   pointing at the same bytes are one usage however they are spelled. The
    ///   first row wins, so a caller that put the better-formed spelling first
    ///   keeps it.
    /// - **Order**: the requesting file first, then relative path, then buffer
    ///   offset. The requesting file leads because the usages nearest the caret
    ///   are the ones the question was really about, and scrolling to find the
    ///   line you started on is the first thing that makes such a panel feel
    ///   wrong. Everything after it is alphabetical by the path the row displays,
    ///   so the grouping the panel draws is the grouping the order implies.
    /// - **Cap** last, so what survives is the head of the list the user is
    ///   reading rather than an arbitrary two thousand of the raw answer.
    ///
    /// `requestingFile` is optional because the textual scan can be asked from a
    /// tab whose file has been deleted underneath it; `nil` simply drops the
    /// first ordering key.
    public static func make(
        identifier: String,
        rows: [UsageResult],
        provenance: UsageProvenance,
        requestingFile: URL?
    ) -> UsagesAnswer {
        let deduplicated = deduplicated(rows)
        let ordered = ordered(deduplicated, requestingFile: requestingFile)
        return UsagesAnswer(
            identifier: identifier,
            rows: Array(ordered.prefix(cap)),
            provenance: provenance,
            isTruncated: ordered.count > cap
        )
    }

    /// One row per *(canonical file, range)*, keeping the first.
    static func deduplicated(_ rows: [UsageResult]) -> [UsageResult] {
        struct Key: Hashable {
            let path: String
            let location: Int
            let length: Int
        }

        var seen = Set<Key>()
        var kept: [UsageResult] = []
        kept.reserveCapacity(rows.count)
        // The canonical path is computed once per row and cached by spelling: a
        // two-thousand-row answer over a hundred files would otherwise resolve
        // symlinks two thousand times for a hundred distinct results.
        var canonicalPaths: [String: String] = [:]
        for row in rows {
            let spelled = row.fileURL.path
            let canonical: String
            if let cached = canonicalPaths[spelled] {
                canonical = cached
            } else {
                canonical = CanonicalPath.canonical(row.fileURL).path
                canonicalPaths[spelled] = canonical
            }
            let key = Key(path: canonical, location: row.range.location, length: row.range.length)
            if seen.insert(key).inserted { kept.append(row) }
        }
        return kept
    }

    /// The requesting file first, then relative path, then the file itself, then
    /// buffer offset.
    ///
    /// **The file path is a key of its own and not a formality**: `relativePath`
    /// is a *display* path, and two different files legitimately share one — every
    /// row outside the project root falls back to `lastPathComponent`, so a
    /// server naming two crates' `lib.rs` produces two files with one displayed
    /// name. Ordering on the display path alone would interleave their rows by
    /// offset, and `UsageFileGroup.grouped` — which groups *consecutive* runs of
    /// one file — would then emit the same file as two separate groups, which the
    /// panel draws with a duplicate `ForEach` identity. Sorting by the file path
    /// keeps every file's rows contiguous whatever they display as.
    ///
    /// The sort is stable in the only way that matters — the comparator is a
    /// total order on *(isRequestingFile, relativePath, path, location, length)*,
    /// so two rows can compare equal only when they are duplicates dedup already
    /// removed.
    static func ordered(_ rows: [UsageResult], requestingFile: URL?) -> [UsageResult] {
        let requestingPath = requestingFile.map { CanonicalPath.canonical($0).path }
        var canonicalPaths: [String: String] = [:]
        func isRequesting(_ row: UsageResult) -> Bool {
            guard let requestingPath else { return false }
            let spelled = row.fileURL.path
            if let cached = canonicalPaths[spelled] { return cached == requestingPath }
            let canonical = CanonicalPath.canonical(row.fileURL).path
            canonicalPaths[spelled] = canonical
            return canonical == requestingPath
        }

        return rows.sorted { lhs, rhs in
            let lhsFirst = isRequesting(lhs)
            let rhsFirst = isRequesting(rhs)
            if lhsFirst != rhsFirst { return lhsFirst }
            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
            if lhs.fileURL.path != rhs.fileURL.path { return lhs.fileURL.path < rhs.fileURL.path }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.range.length < rhs.range.length
        }
    }
}

extension UsageResult {
    /// The range a row activation may reveal in `text` — the file's contents *as
    /// they are when the row is clicked* — or `nil` when the row no longer
    /// describes that buffer and the file should simply be opened.
    ///
    /// **Why a row can be stale at all.** Every row is a position in a text that
    /// was read once: the disk copy the walk scanned, the buffer the server was
    /// told about. Between that read and the click the user may have typed in the
    /// file, an operation may have rewritten it, or a rename may have moved every
    /// occurrence — and the panel keeps its rows across all three, because
    /// re-running a project walk on every keystroke to keep a list honest is not a
    /// trade anyone would take.
    ///
    /// **So the check is the text itself, not the geometry.** A range is worth
    /// revealing only when the bytes it covers still spell the identifier the
    /// answer is about. That rejects both failure modes at once: a range now past
    /// the end of a shortened buffer (which would raise on `NSString`, i.e. crash
    /// the click) and a range still inside a *changed* buffer, where the same
    /// offsets now cover something else entirely — the "reveal of the wrong span"
    /// that is worse than no reveal, because it silently claims a usage is there.
    ///
    /// **The degradation is opening the file with no selection**, which is the
    /// honest outcome: the user asked to see a place, the place is gone, and the
    /// file they asked about is still the right file to be looking at.
    ///
    /// A consequence worth stating: a semantic row whose server returned a range
    /// *wider* than the name — a qualified reference, say — degrades to open-only
    /// even when nothing changed, because its text is not the identifier. Every
    /// server this app speaks to answers `textDocument/references` with the name's
    /// own range, so this is a theoretical loss; and the direction it fails in is
    /// the one that cannot mislead.
    public func revealRange(naming identifier: String, in text: NSString) -> NSRange? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        guard range.location <= text.length, NSMaxRange(range) <= text.length else { return nil }
        guard text.substring(with: range) == identifier else { return nil }
        return range
    }
}
