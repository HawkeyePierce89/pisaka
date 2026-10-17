import Foundation

/// Pure block indent / outdent: Tab on a multi-line selection and Shift+Tab on
/// any caret or selection.
///
/// Both answers are a `RangeEditPlan` the app applies through its one
/// multi-range bracket, so a whole block moves as one undo step. The `unit` is
/// Enter's — `IndentUnitRule.unit`, EditorConfig first and the inference second
/// — handed in by the caller; this engine never decides it.
///
/// **Touched lines** follow `ToggleCommentEngine`'s rule: a range touches every
/// line from the one holding its start to the one holding its end, except that
/// a non-empty range ending exactly at a line start does not touch that line. A
/// caret touches its own line. Lines touched by several ranges are touched
/// once — the ranges' line sets merge, so overlapping and adjacent ranges never
/// indent a line twice.
///
/// Lines are split through `LineStartIndex`, so LF, CR, CRLF, NEL, LS and PS
/// all delimit a line, and a terminator is never part of what is edited.
public enum BlockIndentEngine {
    /// The width a tab unit stands for when outdenting a space-indented line:
    /// the inference's own fallback width, four.
    public static let tabUnitSpaceWidth = 4

    /// Whether Tab should indent the block rather than replace the selection:
    /// true when any range contains a line separator — it spans more than one
    /// line, or covers a whole line including its terminator. A selection
    /// inside one line, a whole terminator-less last line, and a caret all
    /// answer false, keeping plain Tab's behaviour for them.
    public static func isBlockSelection(text: NSString, ranges: [NSRange]) -> Bool {
        let lines = Lines(text: text)
        return ranges.contains { raw in
            let range = clamped(raw, length: text.length)
            guard range.length > 0 else { return false }
            return lines.index(of: range.location) != lines.index(of: NSMaxRange(range))
        }
    }

    /// Insert `unit` at the start of every touched non-blank line.
    ///
    /// Blank and whitespace-only lines are left alone, so indenting never
    /// creates trailing whitespace. Each selection keeps covering the same
    /// text: an endpoint at a line's start stays at that line's start — so a
    /// selection starting at column 0 also covers the inserted unit — and every
    /// other endpoint moves with its line.
    public static func indent(text: NSString, ranges: [NSRange], unit: String) -> RangeEditPlan {
        guard !unit.isEmpty else { return .empty }
        let lines = Lines(text: text)
        let clampedRanges = ranges.map { clamped($0, length: text.length) }
        var edits: [IndentReplacement] = []
        for line in touchedLines(lines: lines, ranges: clampedRanges) where !lines.isBlank(line) {
            edits.append(IndentReplacement(range: NSRange(location: lines.start(of: line), length: 0), replacement: unit))
        }
        return plan(edits: edits, ranges: clampedRanges)
    }

    /// Remove at most one unit of leading indentation from every touched line,
    /// for a caret and a selection alike.
    ///
    /// - A line starting with a tab loses that one tab, whatever the unit — the
    ///   mixed-indentation rule: one Shift+Tab undoes one level however the
    ///   level was written.
    /// - Otherwise it loses up to the unit's width in leading spaces, or the
    ///   shorter run that exists. A tab unit's width is `tabUnitSpaceWidth`.
    /// - A line with no leading whitespace is left alone.
    ///
    /// An empty plan means no line changed. Carets and selection endpoints shift
    /// left with their text, clamped at the line start when the removed
    /// indentation held them.
    public static func outdent(text: NSString, ranges: [NSRange], unit: String) -> RangeEditPlan {
        let width = unitWidth(unit)
        guard width > 0 else { return .empty }
        let lines = Lines(text: text)
        let clampedRanges = ranges.map { clamped($0, length: text.length) }
        var edits: [IndentReplacement] = []
        for line in touchedLines(lines: lines, ranges: clampedRanges) {
            let start = lines.start(of: line)
            let contentsEnd = lines.contentsEnd(of: line)
            guard start < contentsEnd else { continue }
            var removal = 0
            if text.character(at: start) == 0x09 {
                removal = 1
            } else {
                while removal < width, start + removal < contentsEnd, text.character(at: start + removal) == 0x20 {
                    removal += 1
                }
            }
            if removal > 0 {
                edits.append(IndentReplacement(range: NSRange(location: start, length: removal), replacement: ""))
            }
        }
        return plan(edits: edits, ranges: clampedRanges)
    }

    // MARK: - Helpers

    private static func unitWidth(_ unit: String) -> Int {
        if unit == "\t" { return tabUnitSpaceWidth }
        return unit.utf16.count
    }

    /// The touched lines of every range, merged and ascending.
    private static func touchedLines(lines: Lines, ranges: [NSRange]) -> [Int] {
        var touched = Set<Int>()
        for range in ranges {
            let first = lines.index(of: range.location)
            var last = lines.index(of: NSMaxRange(range))
            if range.length > 0, NSMaxRange(range) == lines.start(of: last) {
                last -= 1
            }
            for line in first...max(first, last) {
                touched.insert(line)
            }
        }
        return touched.sorted()
    }

    /// Edits only ever sit at or start from a line start, so mapping every
    /// endpoint biased `.before` keeps an endpoint at a line start in front of
    /// that line's insertion and moves every other endpoint with its text.
    private static func plan(edits: [IndentReplacement], ranges: [NSRange]) -> RangeEditPlan {
        guard !edits.isEmpty, let shell = RangeEditPlan(edits: edits, selections: []) else { return .empty }
        let selections = ranges.map { range -> NSRange in
            let start = shell.mapped(offset: range.location, bias: .before)
            let end = shell.mapped(offset: NSMaxRange(range), bias: .before)
            return NSRange(location: start, length: max(0, end - start))
        }
        return RangeEditPlan(edits: edits, selections: selections) ?? .empty
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// The text's lines as `LineStartIndex` counts them.
    private struct Lines {
        let text: NSString
        let starts: [Int]

        init(text: NSString) {
            self.text = text
            self.starts = LineStartIndex.offsets(in: text)
        }

        /// The line holding `offset`: the last line starting at or before it.
        func index(of offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        func start(of line: Int) -> Int { starts[line] }

        /// The line's end, its terminator excluded.
        func contentsEnd(of line: Int) -> Int {
            let start = starts[line]
            var end = line + 1 < starts.count ? starts[line + 1] : text.length
            guard end > start, LineStartIndex.isLineSeparator(text.character(at: end - 1)) else { return end }
            let last = text.character(at: end - 1)
            end -= 1
            if last == 0x0A, end > start, text.character(at: end - 1) == 0x0D {
                end -= 1
            }
            return end
        }

        /// Empty, or whitespace only.
        func isBlank(_ line: Int) -> Bool {
            let end = contentsEnd(of: line)
            var offset = start(of: line)
            while offset < end {
                let ch = text.character(at: offset)
                guard let scalar = Unicode.Scalar(ch), CharacterSet.whitespaces.contains(scalar) else { return false }
                offset += 1
            }
            return true
        }
    }
}
