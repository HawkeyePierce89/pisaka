import Foundation

/// Pure, testable diff3 three-way merge. Given a common `base` and the two
/// divergent versions `ours`/`theirs`, it splits all three into logical lines
/// (the same separator semantics as `LineDiff.splitLines`, so every line tool
/// agrees on what a line is), aligns each side against the base with the same
/// capped LCS as `LineDiff`, and walks the two alignments together to produce an
/// ordered list of `MergeRegion`s:
///
/// - lines unchanged in both sides → `.stable` (verbatim base content),
/// - a span changed by only one side → `.stable` (that side's content, auto-merged),
/// - a span both sides changed *identically* → `.stable` (the agreed content),
/// - a span both sides changed *differently* → `.conflict`.
///
/// Adjacent stable lines are coalesced into one region. Foundation-only, so it
/// lives in `PisakaCore` and is unit-tested like `LineDiff`/`MinimapModel`.
public enum ThreeWayMerge {
    /// Build the ordered merge regions for the three full texts.
    public static func regions(base: String, ours: String, theirs: String) -> [MergeRegion] {
        regions(
            baseLines: LineDiff.splitLines(base),
            oursLines: LineDiff.splitLines(ours),
            theirsLines: LineDiff.splitLines(theirs)
        )
    }

    // MARK: - Core (on already-split logical lines)

    private enum Side { case ours, theirs }

    /// One contiguous span where a side differs from the base, expressed in
    /// base-line coordinates (`oStart`, `oLen`) plus the side's replacement
    /// length (`sideLen`). Derived from the base→side LCS match list; consecutive
    /// hunks of one side never overlap.
    private struct SideHunk {
        let oStart: Int
        let oLen: Int
        let sideLen: Int
        let side: Side
    }

    static func regions(baseLines: [String], oursLines: [String], theirsLines: [String]) -> [MergeRegion] {
        let baseCount = baseLines.count
        var hunks = sideHunks(base: baseLines, side: oursLines, sideCount: oursLines.count, tag: .ours)
        hunks += sideHunks(base: baseLines, side: theirsLines, sideCount: theirsLines.count, tag: .theirs)
        // Order by base position, breaking ties deterministically (ours before
        // theirs) since Swift's sort is not guaranteed stable.
        hunks.sort { a, b in
            a.oStart != b.oStart ? a.oStart < b.oStart : sideRank(a.side) < sideRank(b.side)
        }

        var regions: [MergeRegion] = []
        var currO = 0    // next base line to emit
        var currA = 0    // next `oursLines` index aligned to currO
        var currB = 0    // next `theirsLines` index aligned to currB
        var i = 0

        func appendStable(_ lines: [String]) {
            guard !lines.isEmpty else { return }
            if case let .stable(prev) = regions.last {
                regions[regions.count - 1] = .stable(prev + lines)
            } else {
                regions.append(.stable(lines))
            }
        }

        while i < hunks.count {
            let first = hunks[i]
            let regionOStart = first.oStart

            // Stable lines before the region: identical in all three (the base
            // lines map 1:1 into both sides, so advance all three cursors).
            if regionOStart > currO {
                let len = regionOStart - currO
                appendStable(Array(baseLines[currO..<regionOStart]))
                currA += len
                currB += len
                currO = regionOStart
            }

            // Collect this hunk plus every following hunk that overlaps it in base
            // coordinates. Overlap is strict (`<`): a hunk that merely *abuts* the
            // region (its base span starts exactly where the region ends) is an
            // independent change on a different base line and must auto-merge, not
            // conflict — e.g. ours edits line b and theirs edits the following line
            // c. The one exception is two *pure insertions* at the same base gap
            // (each zero base length at the same point — e.g. add/add over an empty
            // base): they don't overlap by the strict test yet are genuinely the
            // same insertion point, so group a zero-length insertion at the region's
            // end only while the region so far is itself zero-width there (never an
            // insertion merely adjacent to a base-consuming change).
            var regionOEnd = first.oStart + first.oLen
            var collected: [SideHunk] = [first]
            i += 1
            while i < hunks.count {
                let next = hunks[i]
                let overlaps = next.oStart < regionOEnd
                let coincidentInsertion = next.oStart == regionOEnd
                    && next.oLen == 0
                    && regionOEnd == regionOStart
                guard overlaps || coincidentInsertion else { break }
                regionOEnd = max(regionOEnd, next.oStart + next.oLen)
                collected.append(next)
                i += 1
            }

            let regionOLen = regionOEnd - regionOStart
            let aoLen = collected.filter { $0.side == .ours }.reduce(0) { $0 + $1.oLen }
            let asLen = collected.filter { $0.side == .ours }.reduce(0) { $0 + $1.sideLen }
            let boLen = collected.filter { $0.side == .theirs }.reduce(0) { $0 + $1.oLen }
            let bsLen = collected.filter { $0.side == .theirs }.reduce(0) { $0 + $1.sideLen }

            // Side length over the region = kept base lines (mapped 1:1) plus the
            // side's replacement lines for the changed spans.
            let aLen = (regionOLen - aoLen) + asLen
            let bLen = (regionOLen - boLen) + bsLen

            let oursRegion = Array(oursLines[currA..<currA + aLen])
            let theirsRegion = Array(theirsLines[currB..<currB + bLen])
            let baseRegion = Array(baseLines[regionOStart..<regionOEnd])

            let hasOurs = collected.contains { $0.side == .ours }
            let hasTheirs = collected.contains { $0.side == .theirs }

            if hasOurs && hasTheirs {
                // Both sides touched this span. Reconcile false conflicts before
                // emitting one: identical edits, or one side effectively unchanged.
                if oursRegion == theirsRegion {
                    appendStable(oursRegion)
                } else if oursRegion == baseRegion {
                    appendStable(theirsRegion)
                } else if theirsRegion == baseRegion {
                    appendStable(oursRegion)
                } else {
                    regions.append(.conflict(ConflictHunk(
                        base: baseRegion, ours: oursRegion, theirs: theirsRegion
                    )))
                }
            } else if hasOurs {
                appendStable(oursRegion)
            } else {
                appendStable(theirsRegion)
            }

            currO = regionOEnd
            currA += aLen
            currB += bLen
        }

        // Trailing stable lines after the last hunk.
        if currO < baseCount {
            appendStable(Array(baseLines[currO..<baseCount]))
        }

        return regions
    }

    // MARK: - Helpers

    private static func sideRank(_ side: Side) -> Int { side == .ours ? 0 : 1 }

    /// The differing spans between `base` and one side, as `SideHunk`s in base
    /// coordinates, derived from the LCS match list (gaps between consecutive
    /// matches, including before the first / after the last match).
    private static func sideHunks(base: [String], side: [String], sideCount: Int, tag: Side) -> [SideHunk] {
        let matches = LineDiff.matchedPairs(base, side)
        var hunks: [SideHunk] = []
        var prevO = -1
        var prevS = -1
        // Walk matches plus a trailing sentinel at the end of both sequences.
        for (o, s) in matches.map({ ($0.old, $0.new) }) + [(base.count, sideCount)] {
            let oStart = prevO + 1
            let sStart = prevS + 1
            let oLen = o - oStart
            let sideLen = s - sStart
            if oLen > 0 || sideLen > 0 {
                hunks.append(SideHunk(oStart: oStart, oLen: oLen, sideLen: sideLen, side: tag))
            }
            prevO = o
            prevS = s
        }
        return hunks
    }
}
