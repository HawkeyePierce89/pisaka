import Foundation

/// The changed spans inside one modified diff row, as UTF-16 ranges into each
/// side's line text (separator stripped, as `DiffLine.text` holds it).
///
/// Ascending and non-overlapping on each side, with touching spans already
/// merged. Either side may be empty — a pure insertion inside a line marks the
/// new side alone.
public struct WordDiffRanges: Equatable, Sendable {
    public let old: [NSRange]
    public let new: [NSRange]

    public init(old: [NSRange], new: [NSRange]) {
        self.old = old
        self.new = new
    }
}

/// Word-level emphasis for one modified row: which tokens of the old line and
/// of the new line the other side does not share.
///
/// **Tokens.** A token is a run of word characters (Unicode letters — combining
/// marks included — decimal digits and `_`), a run of whitespace, or one other
/// Unicode scalar. Tokens compare by their exact UTF-16 units, never by
/// canonical equivalence, so a precomposed and a decomposed `é` differ here as
/// they differ on disk.
///
/// **Diff.** The common token prefix and suffix are stripped, an LCS runs over
/// what is left, and every unmatched token becomes a range; touching ranges are
/// merged. Ranges are UTF-16 offsets into the side's text, so a surrogate pair
/// is one token two units long.
///
/// **Threshold.** A row whose change is most of the line is a rewrite, and
/// emphasising nearly all of it says nothing the row's wash does not: `nil`
/// when the changed non-whitespace units on the longer side (by UTF-16 length;
/// the new side on a tie) exceed 60% of that side's non-whitespace units.
///
/// **Budget.** The LCS is charged in matrix cells against two ceilings: one per
/// row (`maximumRowCells`) and one shared by every row of a diff build
/// (`maximumBuildCells`), which the caller threads through as a `Work`. Over
/// either, the row gets `nil`, and a build whose ceiling is spent answers `nil`
/// for every later row. The table is allocated one row at a time *after* that
/// row is charged, so a minified line never allocates past its ceiling.
/// Bookkeeping is double-entry (`OccurrenceScan.Work`'s pattern and reasoning):
/// each DP row is `spend`-charged its width before it is filled, and each cell
/// filled is `record`ed from inside the fill loop, so a test can tell a ceiling
/// that stopped the LCS from one that was merely never charged.
///
/// Pure, Foundation-only.
public enum WordDiff {

    /// The per-row ceiling, in LCS matrix cells.
    public static let maximumRowCells = 250_000

    /// The ceiling one diff build shares across all its rows, in LCS matrix cells.
    public static let maximumBuildCells = 4_000_000

    /// The changed share of the longer side's non-whitespace units, as
    /// `numerator / denominator`, above which a row is left whole.
    static let thresholdNumerator = 3
    static let thresholdDenominator = 5

    /// The ranges for one modified row, charged against the caller's per-build
    /// `work`; `nil` for a rewrite (the threshold) or when a ceiling ran out.
    public static func ranges(old: String, new: String, work: inout Work) -> WordDiffRanges? {
        guard !work.isExhausted else { return nil }
        var row = Work(budget: min(maximumRowCells, work.budget))
        let result = ranges(old: old, new: new, rowWork: &row)
        work.record(row.performed)
        work.spend(row.charged)
        return result
    }

    /// The ranges for one row on its own, under a fresh build ceiling.
    public static func ranges(old: String, new: String) -> WordDiffRanges? {
        var work = Work(budget: maximumBuildCells)
        return ranges(old: old, new: new, work: &work)
    }

    // MARK: - Work bookkeeping

    /// The ceiling and the work actually done under it, booked separately; see
    /// `EditorConfigGlob.MatchWork` for why the pair is two numbers and two
    /// calls, never one.
    public struct Work {
        /// The ceiling this `Work` started with.
        let ceiling: Int
        /// What is left of the ceiling; at or below zero once it is spent.
        private(set) var budget: Int
        /// LCS cells really filled, whatever was charged.
        private(set) var performed = 0

        public init(budget: Int) {
            self.ceiling = budget
            self.budget = budget
        }

        /// What has been charged so far.
        var charged: Int { ceiling - budget }

        /// Records `cells` of work just done. Always paired with the `spend(_:)`
        /// that pays for it.
        mutating func record(_ cells: Int) {
            performed += cells
        }

        /// Charges `cost` cells of the ceiling.
        mutating func spend(_ cost: Int) {
            budget -= cost
        }

        var isExhausted: Bool { budget <= 0 }
    }

    // MARK: - The row

    /// The test seam: one row against a per-row `Work` the caller owns, so a
    /// test reads both what was left of the ceiling and what was performed.
    static func ranges(old: String, new: String, rowWork work: inout Work) -> WordDiffRanges? {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)

        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count,
              oldTokens[prefix].units == newTokens[prefix].units {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].units == newTokens[newTokens.count - 1 - suffix].units {
            suffix += 1
        }
        let oldMiddle = Array(oldTokens[prefix..<(oldTokens.count - suffix)])
        let newMiddle = Array(newTokens[prefix..<(newTokens.count - suffix)])

        guard let (oldChanged, newChanged) = unmatched(oldMiddle, newMiddle, work: &work) else {
            return nil
        }

        let oldIsMeasured = old.utf16.count > new.utf16.count
        let measured = oldIsMeasured ? oldMiddle : newMiddle
        let measuredChanged = oldIsMeasured ? oldChanged : newChanged
        let total = nonWhitespaceUnits(oldIsMeasured ? oldTokens : newTokens)
        let changed = nonWhitespaceUnits(measuredChanged.map { measured[$0] })
        if changed * thresholdDenominator > total * thresholdNumerator { return nil }

        return WordDiffRanges(
            old: merged(oldChanged.map { oldMiddle[$0].range }),
            new: merged(newChanged.map { newMiddle[$0].range })
        )
    }

    /// The indices of the tokens of each side the LCS leaves unmatched;
    /// `nil` when the row's ceiling ran out first.
    private static func unmatched(_ a: [Token], _ b: [Token], work: inout Work) -> ([Int], [Int])? {
        let m = a.count, n = b.count
        if m == 0 || n == 0 { return (Array(0..<m), Array(0..<n)) }

        // table[i][j]: the LCS length of a[i...] and b[j...]. Each row is
        // charged its width before it is allocated and filled.
        var table = [[Int32]](repeating: [], count: m + 1)
        table[m] = [Int32](repeating: 0, count: n + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            work.spend(n)
            if work.budget < 0 { return nil }
            var row = [Int32](repeating: 0, count: n + 1)
            let below = table[i + 1]
            for j in stride(from: n - 1, through: 0, by: -1) {
                work.record(1)
                row[j] = a[i].units == b[j].units ? below[j + 1] + 1 : max(below[j], row[j + 1])
            }
            table[i] = row
        }

        var oldChanged: [Int] = [], newChanged: [Int] = []
        var i = 0, j = 0
        while i < m, j < n {
            if a[i].units == b[j].units {
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                oldChanged.append(i)
                i += 1
            } else {
                newChanged.append(j)
                j += 1
            }
        }
        oldChanged.append(contentsOf: i..<m)
        newChanged.append(contentsOf: j..<n)
        return (oldChanged, newChanged)
    }

    // MARK: - Tokens

    enum TokenKind { case word, whitespace, other }

    struct Token {
        let kind: TokenKind
        let units: [UInt16]
        let range: NSRange
    }

    private static let wordCharacters = CharacterSet.letters
        .union(.decimalDigits)
        .union(CharacterSet(charactersIn: "_"))

    /// `text` split into word runs, whitespace runs and single other scalars,
    /// each with its UTF-16 range.
    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var units: [UInt16] = []
        var kind: TokenKind?
        var start = 0, offset = 0

        func flush() {
            if let kind, !units.isEmpty {
                result.append(Token(kind: kind, units: units, range: NSRange(location: start, length: offset - start)))
            }
            units.removeAll(keepingCapacity: true)
            start = offset
        }

        for scalar in text.unicodeScalars {
            let scalarKind: TokenKind
            if wordCharacters.contains(scalar) {
                scalarKind = .word
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalarKind = .whitespace
            } else {
                scalarKind = .other
            }
            if scalarKind != kind || scalarKind == .other { flush() }
            kind = scalarKind
            units.append(contentsOf: scalar.utf16)
            offset += scalar.utf16.count
        }
        flush()
        return result
    }

    private static func nonWhitespaceUnits(_ tokens: [Token]) -> Int {
        tokens.reduce(0) { $0 + ($1.kind == .whitespace ? 0 : $1.range.length) }
    }

    /// Ascending ranges with every touching pair joined into one.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSRange(
                    location: last.location,
                    length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}
