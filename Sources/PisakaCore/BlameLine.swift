import Foundation

/// One line's git-blame annotation: who last changed it, when, and in which
/// commit.
///
/// A deliberately small value type carrying only what the gutter's annotation
/// column draws: the full commit `hash` (identity, and the key the view layer
/// memoizes a rendered label under), the `author` name, the `date` as a raw
/// ISO-8601 string, and the commit's single-line `summary`.
///
/// The `date` follows ``Commit/date``'s convention — it is kept as **text**, in
/// the exact shape `git log`'s `%aI` produces (`2026-08-04T19:55:07+03:00`), so
/// Core stays free of locale/formatting concerns and the two types are
/// interchangeable to a view-layer formatter. `git blame --porcelain` does not
/// emit an ISO string, so ``BlameParser`` synthesizes one from the
/// `author-time`/`author-tz` pair it does emit. It is empty when the output
/// carried no `author-time`.
///
/// ``isUncommitted`` reports the all-zero hash git uses for a line that is in
/// the working tree but not in any commit yet (a line the user added since the
/// last commit). Such a line has a real `author` — git spells it
/// `Not Committed Yet` — but nothing to attribute, so the view draws it blank.
/// That is a *different fact* from a `nil` entry in the parser's output, which
/// means "no blame data for this line at all"; the two stay distinct in the
/// model even though both render as blank.
public struct BlameLine: Equatable {
    public let hash: String
    public let author: String
    public let date: String
    public let summary: String

    public init(hash: String, author: String, date: String, summary: String) {
        self.hash = hash
        self.author = author
        self.date = date
        self.summary = summary
    }

    /// Whether this line is in the working tree but not in any commit — git
    /// reports it with an all-zero hash. An empty hash is "no hash", not the
    /// zero hash, so it reports `false`.
    public var isUncommitted: Bool {
        !hash.isEmpty && hash.allSatisfy { $0 == "0" }
    }
}

/// Pure parser for `git blame --porcelain` output.
///
/// Foundation-only and side-effect-free, so the grammar handling is unit-tested
/// in Core; the `Process` invocation that produces the output lives in
/// `GitCLIService`.
///
/// ## Why `--porcelain` and not `--line-porcelain`
///
/// In `--porcelain` a commit's metadata block is emitted **once**, and every
/// later line attributed to the same commit carries only its header line (the
/// hash plus line numbers). `--line-porcelain` repeats the whole block for every
/// line, which for a megabyte-scale file is several times the output for
/// information already known. So the parser keeps a `hash → metadata` table and
/// resolves repeat headers through it — about ten lines of code for a large
/// constant factor of I/O, and the reason
/// ``BlameParser/parse(_:)`` reconciles placements against that table *after*
/// reading the whole output rather than as it goes.
///
/// ## The TAB rule — content is recognized before anything else
///
/// Each blamed line's **own source text** is emitted on its own line prefixed
/// with a single TAB. That prefix is the only thing separating file content from
/// the metadata grammar, and the grammar is otherwise trivially forgeable by
/// ordinary source code: a Swift line reading `author Evil <x@y>` is, byte for
/// byte, a valid `author` field, and a fixture line reading
/// `0000000000000000000000000000000000000000 1 2 3` is a valid group header.
///
/// So the parse loop's **first** test on every line is `hasPrefix("\t")`: such a
/// line is consumed as content (it closes the current group's metadata block)
/// and never reaches the header or field matching. Getting this order wrong does
/// not crash — it silently rewrites an author, or invents a whole group at a
/// bogus line number, from the file's own text, which is why it is stated as a
/// rule and pinned by fixtures spelled exactly like a header, an `author`, a
/// `boundary` and a `previous`.
///
/// ## Grammar actually handled
///
/// A group header is `<40-hex sha> <orig-line> <final-line> [<num-lines>]`, and
/// entries are placed by the **final** line number (so a gap in the output stays
/// `nil` instead of shifting later lines up). Between headers come the field
/// lines, of which the parser reads `author`, `author-time`, `author-tz` and
/// `summary`. Every other field falls off the end of the switch and is skipped,
/// which deliberately covers the two shapes a naive "first token, rest is value"
/// split can mis-handle:
///
/// - **`boundary`** — a lone keyword line with *no value*, emitted for a commit
///   at the boundary of the traversal.
/// - **`previous <sha> <path>`** — the parent commit and the file's path there;
///   its second token is 40 hex characters, so it must not be mistaken for a
///   header or for the group's own hash.
///
/// Neither carries anything the annotation column shows, so both are ignored
/// rather than special-cased — but both are pinned by fixtures.
///
/// ## Robustness
///
/// Unknown/garbage lines are skipped, a truncated final group keeps the hash it
/// does have with empty fields rather than being dropped, a missing metadata
/// field yields an empty string, a non-numeric or non-positive line number is
/// ignored, and empty output yields `[]`. Nothing here traps.
///
/// Records are separated at the **scalar** LF and a trailing CR is stripped, so a
/// file checked out with CRLF endings — whose content lines git emits verbatim,
/// carrying their own CR — parses exactly like an LF one. See the note on the
/// parse loop for why a grapheme-level split silently loses every annotation
/// after the first there.
public enum BlameParser {
    /// The mutable metadata accumulated for one commit hash while scanning.
    private struct Metadata {
        var author = ""
        var time: String?
        var tz: String?
        var summary = ""
    }

    /// Parse `git blame --porcelain` output into one entry per file line, in
    /// final-line order.
    ///
    /// The result is sized by the highest final line number seen; a line the
    /// output said nothing about is `nil` ("no data for this line"), which is
    /// deliberately distinct from a ``BlameLine`` whose ``BlameLine/isUncommitted``
    /// is true.
    public static func parse(_ output: String) -> [BlameLine?] {
        var metadata: [String: Metadata] = [:]
        var placements: [(hash: String, finalLine: Int)] = []
        var currentHash: String?
        // A content line closes the metadata block, so a field line can only be
        // captured between a header and the group's source line.
        var inMetadataBlock = false
        var lineCount = 0

        // `components(separatedBy:)`, **not** `split(separator: "\n")`: `String`
        // compares by grapheme cluster, and `\r\n` is a single cluster that is not
        // equal to `"\n"`. A file checked out with CRLF endings emits its content
        // lines as `\t<text>\r` + git's own `\n`, so a grapheme-level split would
        // not break there — the content line and the *next group header* would fuse
        // into one string, that string starts with a TAB, and the header would be
        // consumed as content. Every annotation after the first would silently
        // vanish. Splitting at the scalar level breaks the pair and makes the
        // trailing-CR strip below meaningful.
        for rawLine in output.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }

            // THE TAB RULE — see the type's doc comment. This test must stay
            // first: a source line is allowed to look exactly like any part of
            // the grammar, and only this prefix tells them apart.
            if line.hasPrefix("\t") {
                inMetadataBlock = false
                continue
            }

            if let header = parseHeader(line) {
                currentHash = header.hash
                inMetadataBlock = true
                if metadata[header.hash] == nil { metadata[header.hash] = Metadata() }
                if header.finalLine >= 1 {
                    placements.append((header.hash, header.finalLine))
                    lineCount = max(lineCount, header.finalLine)
                }
                continue
            }

            guard inMetadataBlock, let hash = currentHash else { continue }
            let field = splitField(line)
            switch field.key {
            case "author": metadata[hash]?.author = field.value
            case "author-time": metadata[hash]?.time = field.value
            case "author-tz": metadata[hash]?.tz = field.value
            case "summary": metadata[hash]?.summary = field.value
            default: break // boundary, previous, committer*, filename, anything new.
            }
        }

        // One formatter per parse, not per line.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var resolved: [String: BlameLine] = [:]
        var result = [BlameLine?](repeating: nil, count: lineCount)
        for placement in placements {
            if resolved[placement.hash] == nil {
                let meta = metadata[placement.hash] ?? Metadata()
                resolved[placement.hash] = BlameLine(
                    hash: placement.hash,
                    author: meta.author,
                    date: isoDate(time: meta.time, tz: meta.tz, formatter: formatter),
                    summary: meta.summary
                )
            }
            result[placement.finalLine - 1] = resolved[placement.hash]
        }
        return result
    }

    /// `<40-hex sha> <orig-line> <final-line> [<num-lines>]`.
    ///
    /// `num-lines` describes the group's size but every line still carries its
    /// own header, so nothing is expanded from it — it is simply tolerated.
    private static func parseHeader(_ line: String) -> (hash: String, finalLine: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let hash = String(parts[0])
        guard hash.count == 40, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        guard Int(parts[1]) != nil, let finalLine = Int(parts[2]) else { return nil }
        return (hash, finalLine)
    }

    /// A field line is `<key> <value>`, the value being the whole remainder
    /// (author names and summaries contain spaces). A valueless line —
    /// `boundary` — yields an empty value and falls through the switch.
    private static func splitField(_ line: String) -> (key: String, value: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[line.startIndex..<space]), String(line[line.index(after: space)...]))
    }

    /// Synthesize `%aI`'s exact shape from porcelain's `author-time` epoch and
    /// `author-tz` offset, so ``BlameLine/date`` and ``Commit/date`` are
    /// interchangeable to a formatter. A missing/malformed tz is treated as
    /// `+00:00`; a missing epoch yields an empty string.
    ///
    /// The spelled offset is derived from the **resolved** time zone rather than
    /// from the parsed number, so the two halves of the string can never disagree:
    /// `offsetSeconds` accepts any syntactically valid `±HHMM`, including one
    /// outside the ±18 h `TimeZone(secondsFromGMT:)` allows (a hand-crafted commit
    /// object can carry `+9999`), and a rejected offset falls back to UTC — a
    /// wall-clock time in UTC labelled `+100:39` would name an instant days off.
    private static func isoDate(time: String?, tz: String?, formatter: DateFormatter) -> String {
        guard let time, let epoch = TimeInterval(time) else { return "" }
        let offset = offsetSeconds(tz) ?? 0
        let zone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        formatter.timeZone = zone
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
            + spelledOffset(zone.secondsFromGMT())
    }

    /// `±HHMM` → seconds east of UTC; `nil` for anything else.
    private static func offsetSeconds(_ tz: String?) -> Int? {
        guard let tz, tz.count == 5 else { return nil }
        let sign: Int
        switch tz.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let digits = tz.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2))
        else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// Seconds east of UTC → `+03:00` / `-05:30` (ISO-8601's colon form).
    private static func spelledOffset(_ seconds: Int) -> String {
        let magnitude = abs(seconds)
        return String(
            format: "%@%02d:%02d",
            seconds < 0 ? "-" : "+",
            magnitude / 3600,
            (magnitude % 3600) / 60
        )
    }
}
