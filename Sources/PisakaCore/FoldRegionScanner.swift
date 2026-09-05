import Foundation

/// The fallback answer to "what can be folded here" — the one used whenever no
/// language server serves the file, which on most projects is most files.
///
/// Pure and Foundation-only like the editor's other engines
/// (`BracketDepthScanner`, `IndentLevelScanner`, `IndentEngine`), counting
/// UTF-16 units over an `NSString` the caller already holds. It decides where a
/// block *is*; it never decides what a block *means*, so every region it answers
/// carries no `kind`.
///
/// **Two sources, one answer.**
///
/// - *Brackets.* Every matched pair `BracketDepthScanner` reports
///   (`isUnmatched == false`) whose opener and closer sit on different lines. The
///   pairing is re-derived from that scanner's own output rather than re-scanned,
///   so there is exactly one place in the repository that decides which `}`
///   closes which `{` for a whole document — including how it treats crossed and
///   orphaned brackets, which is a decision this engine must not take a second
///   opinion on.
/// - *Indentation.* A line followed by lines indented deeper, ending at the first
///   line back at the header's level or shallower. Levels come from
///   `IndentLevelScanner`, driven by the `IndentLevelWidths` the caller was
///   handed — the same widths the indentation painting uses and, one step back,
///   the same unit `IndentUnitRule` already answered for Enter. Nothing here
///   re-derives an indentation unit.
///
/// **The rules it owns.**
///
/// - Both sources require **two or more lines**: a block that hides nothing is
///   not a block, which `FoldRegion`'s refusing initializer states one level
///   down.
/// - Blank and whitespace-only lines *inside* an indentation block belong to it
///   and never end it; blank lines *after* it are trimmed off, so a block always
///   ends on its last real line and folding it never swallows the empty line
///   that separates it from what follows.
/// - Two candidates sharing a `headerLine` merge into one — one line, one
///   chevron — and **the bracket candidate wins**, because a brace says where a
///   block ends and indentation only guesses. Between two brackets opening on
///   the same line the longer wins, which is `FoldRegion`'s ordering key read
///   straight through.
/// - No comment regions and no import regions: naming a block needs a grammar,
///   and this engine has none. A server that has one answers those instead.
///
/// **Cost.** One pass over the bracket tokens plus one levelled pass, both
/// already chunked or bounded by the engines that produce them, plus a linear
/// merge over the lines. That is the same order of work the rainbow-bracket scan
/// already does on every debounce, which is what makes it cheap enough to run on
/// the main actor after one.
public enum FoldRegionScanner {

    /// Every foldable region in `text`, in `FoldRegion`'s ordering — one region
    /// per header line, header lines ascending.
    ///
    /// `widths` drives the indentation half only; the bracket half needs no
    /// configuration at all. Widths that cannot describe an indentation (either
    /// of them zero or less) answer the bracket half alone, never a trap and
    /// never a loop — `IndentLevelScanner`'s own rule, applied here by asking it.
    public static func scan(text: NSString, widths: IndentLevelWidths) -> [FoldRegion] {
        let length = text.length
        guard length > 0 else { return [] }
        let lines = TerminatedLines.ranges(in: text, range: NSRange(location: 0, length: length))
        // One line cannot hide a second one, whichever source is asked.
        guard lines.count > 1 else { return [] }

        var candidates = bracketCandidates(in: text, lines: lines)
        candidates.append(contentsOf: indentationCandidates(in: text, lines: lines, widths: widths))
        return merged(candidates)
    }

    // MARK: - One candidate

    /// A region plus which source proposed it, so the merge can prefer the
    /// bracket one. The flag exists only between the two halves and this file's
    /// merge; it is never part of the answer.
    private struct Candidate {
        let region: FoldRegion
        let isBracket: Bool
    }

    /// The region hiding everything between the end of `header`'s content and
    /// the end of `last`'s content, or `nil` when the two lines cannot describe
    /// one (which the initializer, not this function, decides).
    private static func region(header: Int, last: Int, lines: [TerminatedLineRange]) -> FoldRegion? {
        let start = NSMaxRange(lines[header].content)
        let end = NSMaxRange(lines[last].content)
        return FoldRegion(
            hiddenRange: NSRange(location: start, length: end - start),
            headerLine: header,
            kind: nil
        )
    }

    // MARK: - Brackets

    private static let openParen = unichar(UInt8(ascii: "("))
    private static let openBracket = unichar(UInt8(ascii: "["))
    private static let openBrace = unichar(UInt8(ascii: "{"))

    /// Every matched bracket pair that spans more than one line, as a region
    /// headed by the opener's line.
    ///
    /// The stack re-pairs `BracketDepthScanner`'s matched tokens, which are
    /// well-nested by that scanner's construction: a closer arriving on an empty
    /// stack cannot happen and is skipped rather than trapped on, so a future
    /// change over there degrades to a missing chevron instead of a crash.
    private static func bracketCandidates(in text: NSString, lines: [TerminatedLineRange]) -> [Candidate] {
        var candidates: [Candidate] = []
        var openers: [Int] = []
        for token in BracketDepthScanner.scan(text: text) where !token.isUnmatched {
            let character = text.character(at: token.location)
            if character == openParen || character == openBracket || character == openBrace {
                openers.append(token.location)
                continue
            }
            guard let opener = openers.popLast() else { continue }
            let headerLine = lineIndex(of: opener, in: lines)
            let closerLine = lineIndex(of: token.location, in: lines)
            guard closerLine > headerLine else { continue }
            if let region = region(header: headerLine, last: closerLine, lines: lines) {
                candidates.append(Candidate(region: region, isBracket: true))
            }
        }
        return candidates
    }

    /// The index of the line `location` falls on — the last line starting at or
    /// before it. Binary search, so the bracket half stays `O(b log n)` rather
    /// than walking the lines again per bracket.
    private static func lineIndex(of location: Int, in lines: [TerminatedLineRange]) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].enclosing.location <= location {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    // MARK: - Indentation

    /// A header line followed by deeper lines, per the rules above.
    ///
    /// One pass with a stack of open headers: a line at level `L` closes every
    /// header at level `L` or deeper, and each of those ends at the last
    /// **non-blank** line seen before it — which is both the "shallower line ends
    /// the block" rule and the trailing-blank trim, in one place rather than two.
    private static func indentationCandidates(
        in text: NSString,
        lines: [TerminatedLineRange],
        widths: IndentLevelWidths
    ) -> [Candidate] {
        guard widths.unitWidth > 0, widths.tabWidth > 0 else { return [] }
        let measured = measure(lines: lines, in: text, widths: widths)

        var candidates: [Candidate] = []
        var stack: [(line: Int, level: Int)] = []
        var lastContentLine = -1

        func close(_ header: Int) {
            guard lastContentLine > header else { return }
            if let region = region(header: header, last: lastContentLine, lines: lines) {
                candidates.append(Candidate(region: region, isBracket: false))
            }
        }

        for index in 0..<lines.count where !measured[index].isBlank {
            let level = measured[index].level
            while let top = stack.last, top.level >= level {
                stack.removeLast()
                close(top.line)
            }
            stack.append((line: index, level: level))
            lastContentLine = index
        }
        while let top = stack.popLast() {
            close(top.line)
        }
        return candidates
    }

    /// What the indentation half needs to know about one line.
    private struct MeasuredLine {
        /// One past the level of the line's last indentation block — 0 for a
        /// line that starts in column zero. It is a step function of the column
        /// the content starts at, which is all the comparisons below need.
        let level: Int
        /// Empty, or nothing but the whitespace the levelled runs already
        /// covered. Such a line neither opens a block nor ends one.
        let isBlank: Bool
    }

    /// Both facts for every line, from **one** levelled pass over the whole
    /// text: the runs come back ascending, so a single cursor walks them
    /// alongside the lines instead of asking the scanner once per line.
    ///
    /// Blankness is read off the same runs rather than by a second character
    /// walk: `IndentLevelScanner` stops at the first character that is neither a
    /// space nor a tab, so a line whose runs reach the end of its content had
    /// nothing else on it.
    private static func measure(
        lines: [TerminatedLineRange],
        in text: NSString,
        widths: IndentLevelWidths
    ) -> [MeasuredLine] {
        let runs = IndentLevelScanner.runs(
            in: text,
            range: NSRange(location: 0, length: text.length),
            widths: widths
        )
        var measured: [MeasuredLine] = []
        measured.reserveCapacity(lines.count)
        var cursor = 0
        for line in lines {
            let contentEnd = NSMaxRange(line.content)
            var level = 0
            var whitespaceEnd = line.content.location
            while cursor < runs.count, runs[cursor].range.location < contentEnd {
                level = runs[cursor].level + 1
                whitespaceEnd = NSMaxRange(runs[cursor].range)
                cursor += 1
            }
            measured.append(MeasuredLine(level: level, isBlank: whitespaceEnd == contentEnd))
        }
        return measured
    }

    // MARK: - The merge

    /// One region per header line, in `FoldRegion`'s ordering: the bracket
    /// candidate wins a shared header line, and between two of the same source
    /// the longer one does.
    private static func merged(_ candidates: [Candidate]) -> [FoldRegion] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.region.headerLine != rhs.region.headerLine {
                return lhs.region.headerLine < rhs.region.headerLine
            }
            if lhs.isBracket != rhs.isBracket { return lhs.isBracket }
            return lhs.region < rhs.region
        }
        var regions: [FoldRegion] = []
        for candidate in ordered where candidate.region.headerLine != regions.last?.headerLine {
            regions.append(candidate.region)
        }
        return regions
    }
}
