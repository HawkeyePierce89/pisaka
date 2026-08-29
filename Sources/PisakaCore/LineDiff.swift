import Foundation

/// How a single side-by-side diff row relates the two panes.
///
/// A color-free, semantic enum like `FileStatus`/`SyntaxTokenKind` — the view
/// layer maps each case to a row background. `unchanged` and `modified` rows
/// carry both sides; `added` carries only the right (new) side; `removed` only
/// the left (old) side.
public enum DiffRowKind: Equatable {
    case unchanged
    case added
    case removed
    case modified
}

/// One line on one side of a diff: its 1-based line number within that side and
/// its text (separator stripped, like the editor's logical lines).
public struct DiffLine: Equatable {
    public let number: Int
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

/// One aligned row of a side-by-side diff. A `nil` side is a filler block that
/// keeps the two panes vertically aligned; the other side is then always a real
/// line. The invariant by kind:
/// - `.added`   → `left == nil`, `right != nil`
/// - `.removed` → `left != nil`, `right == nil`
/// - `.unchanged`/`.modified` → both present
public struct DiffRow: Equatable {
    public let kind: DiffRowKind
    public let left: DiffLine?
    public let right: DiffLine?

    public init(kind: DiffRowKind, left: DiffLine?, right: DiffLine?) {
        self.kind = kind
        self.left = left
        self.right = right
    }
}

/// Pure, testable side-by-side line diff. Splits both texts into logical lines
/// (using the same Unicode separator semantics as the editor — see
/// `LineStartIndex` — so the gutter and the diff agree on what a line is), runs
/// an LCS line diff, and emits aligned `[DiffRow]` with filler on the side that
/// lacks a line. Foundation-only, so it lives in `PisakaCore`.
public enum LineDiff {
    /// Build aligned side-by-side rows comparing `old` (left/`HEAD`) to `new`
    /// (right/working copy).
    public static func rows(old: String, new: String) -> [DiffRow] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        let ops = diffOps(oldLines, newLines)

        var rows: [DiffRow] = []
        // Deletes/inserts inside one contiguous hunk are paired into `.modified`
        // rows (up to the smaller count) before any leftover removed/added rows,
        // so a one-line edit shows as a single aligned modified row rather than a
        // separate remove + add.
        var pendingDeletes: [Int] = []
        var pendingInserts: [Int] = []

        func flushHunk() {
            let paired = min(pendingDeletes.count, pendingInserts.count)
            for k in 0..<paired {
                let o = pendingDeletes[k], n = pendingInserts[k]
                rows.append(DiffRow(
                    kind: .modified,
                    left: DiffLine(number: o + 1, text: oldLines[o]),
                    right: DiffLine(number: n + 1, text: newLines[n])
                ))
            }
            for k in paired..<pendingDeletes.count {
                let o = pendingDeletes[k]
                rows.append(DiffRow(
                    kind: .removed,
                    left: DiffLine(number: o + 1, text: oldLines[o]),
                    right: nil
                ))
            }
            for k in paired..<pendingInserts.count {
                let n = pendingInserts[k]
                rows.append(DiffRow(
                    kind: .added,
                    left: nil,
                    right: DiffLine(number: n + 1, text: newLines[n])
                ))
            }
            pendingDeletes.removeAll(keepingCapacity: true)
            pendingInserts.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case let .equal(o, n):
                flushHunk()
                rows.append(DiffRow(
                    kind: .unchanged,
                    left: DiffLine(number: o + 1, text: oldLines[o]),
                    right: DiffLine(number: n + 1, text: newLines[n])
                ))
            case let .delete(o):
                pendingDeletes.append(o)
            case let .insert(n):
                pendingInserts.append(n)
            }
        }
        flushHunk()
        return rows
    }

    // MARK: - Line splitting

    /// Split `text` into logical lines using the same separators the editor's
    /// gutter/minimap count (LF, CR, CRLF pair, NEL, U+2028, U+2029), with the
    /// separator stripped. Empty text yields no lines, and a trailing separator
    /// does not add a phantom empty line (so `"a\nb"` and `"a\nb\n"` both split to
    /// `["a", "b"]`) — the difference is a trailing-newline concern left to the
    /// view, not a logical line.
    ///
    /// This is a **projection** of `TerminatedLines.split`, deliberately not a
    /// second implementation of the same rule: a diff row's index is the selection
    /// unit of a partial commit, whose content is assembled through
    /// `TerminatedLines`, so the two must agree on what a line is for every
    /// separator. Keeping one algorithm makes that structural rather than a
    /// coincidence to be re-verified (`TerminatedLinesTests` fuzzes the equality
    /// anyway, as a lock against un-projecting this).
    static func splitLines(_ text: String) -> [String] {
        TerminatedLines.split(text).map(\.content)
    }

    // MARK: - Alignment seam for ThreeWayMerge

    /// The matched (equal) line-index pairs between `oldLines` and `newLines`, in
    /// increasing order — the LCS alignment underlying `rows`, exposed for
    /// `ThreeWayMerge` so the diff3 reuses the same capped-LCS semantics and
    /// separator-stripped lines as the side-by-side diff. Module-internal (like
    /// `splitLines`), so it stays out of the public surface.
    static func matchedPairs(_ oldLines: [String], _ newLines: [String]) -> [(old: Int, new: Int)] {
        diffOps(oldLines, newLines).compactMap { op in
            if case let .equal(o, n) = op { return (old: o, new: n) }
            return nil
        }
    }

    // MARK: - LCS diff

    private enum Op {
        case equal(Int, Int) // (old index, new index)
        case delete(Int)     // old index
        case insert(Int)     // new index
    }

    /// Cap on the LCS DP matrix size (cells). The classic LCS diff is `O(k*l)`
    /// time and space over the *differing* middle (after common prefix/suffix is
    /// stripped); a single diff pane never benefits from a finer alignment of a
    /// block this large, and an uncapped matrix on two huge, fully-divergent
    /// files would allocate gigabytes and freeze the main thread. Above the cap
    /// the middle is emitted as a plain replace instead. At 8M cells the
    /// transient `[Int]` buffer is ~64 MB and the scan runs in well under the
    /// time of the click that triggers it.
    private static let maxMatrixCells = 8_000_000

    /// Diff `oldLines` against `newLines`, producing an ordered op list with
    /// absolute indices into each array.
    ///
    /// Common leading/trailing lines are matched directly (the typical case is a
    /// small edit in an otherwise-identical file), so only the differing middle
    /// goes through the quadratic LCS. This keeps both memory and time bounded for
    /// large files, and lets the middle fall back to a plain replace when even it
    /// is too large to align cell-by-cell.
    private static func diffOps(_ oldLines: [String], _ newLines: [String]) -> [Op] {
        let n = oldLines.count
        let m = newLines.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }

        // Common prefix.
        var prefix = 0
        while prefix < n && prefix < m && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        // Common suffix (not overlapping the prefix on either side).
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix
            && oldLines[n - 1 - suffix] == newLines[m - 1 - suffix] {
            suffix += 1
        }

        var ops: [Op] = []
        for i in 0..<prefix { ops.append(.equal(i, i)) }

        let oldLo = prefix, oldHi = n - suffix // middle = [lo, hi)
        let newLo = prefix, newHi = m - suffix
        let k = oldHi - oldLo
        let l = newHi - newLo

        if k == 0 {
            for j in newLo..<newHi { ops.append(.insert(j)) }
        } else if l == 0 {
            for i in oldLo..<oldHi { ops.append(.delete(i)) }
        } else if k * l > maxMatrixCells {
            // Pathologically large divergent block: skip the quadratic matrix and
            // emit a plain replace (all deletes then all inserts). The row builder
            // pairs them into aligned `.modified` rows.
            for i in oldLo..<oldHi { ops.append(.delete(i)) }
            for j in newLo..<newHi { ops.append(.insert(j)) }
        } else {
            ops.append(contentsOf: middleOps(oldLines, newLines, oldLo, oldHi, newLo, newHi))
        }

        for t in 0..<suffix { ops.append(.equal(n - suffix + t, m - suffix + t)) }
        return ops
    }

    /// Classic LCS dynamic-programming diff over the half-open middle ranges
    /// `oldLines[oldLo..<oldHi]` / `newLines[newLo..<newHi]`, returning ops with
    /// absolute indices. Uses one flat `(k+1)*(l+1)` buffer rather than a nested
    /// array-of-arrays (a single contiguous allocation, so the `maxMatrixCells`
    /// cap maps directly to the bytes held).
    private static func middleOps(
        _ oldLines: [String], _ newLines: [String],
        _ oldLo: Int, _ oldHi: Int, _ newLo: Int, _ newHi: Int
    ) -> [Op] {
        let k = oldHi - oldLo
        let l = newHi - newLo
        let width = l + 1
        // dp[i*width + j] = LCS length of the middle suffixes starting at i / j.
        var dp = [Int](repeating: 0, count: (k + 1) * width)
        for i in stride(from: k - 1, through: 0, by: -1) {
            let oi = oldLines[oldLo + i]
            for j in stride(from: l - 1, through: 0, by: -1) {
                if oi == newLines[newLo + j] {
                    dp[i * width + j] = dp[(i + 1) * width + (j + 1)] + 1
                } else {
                    dp[i * width + j] = max(dp[(i + 1) * width + j], dp[i * width + (j + 1)])
                }
            }
        }

        var ops: [Op] = []
        var i = 0
        var j = 0
        while i < k && j < l {
            if oldLines[oldLo + i] == newLines[newLo + j] {
                ops.append(.equal(oldLo + i, newLo + j))
                i += 1
                j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + (j + 1)] {
                ops.append(.delete(oldLo + i))
                i += 1
            } else {
                ops.append(.insert(newLo + j))
                j += 1
            }
        }
        while i < k { ops.append(.delete(oldLo + i)); i += 1 }
        while j < l { ops.append(.insert(newLo + j)); j += 1 }
        return ops
    }
}
