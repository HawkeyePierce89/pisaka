import Foundation

/// Places a `git blame` result — numbered by **LF-delimited** lines — onto the
/// editor's own line starts, which follow a *wider* separator set.
///
/// This exists because the two sides genuinely disagree about what a line is.
/// `git blame` emits one entry per LF-delimited line and knows no other
/// separator, while `LineStartIndex` (and so the gutter, the minimap and TextKit)
/// also splits on a lone CR, NEL (U+0085), LS (U+2028) and PS (U+2029). A file
/// carrying any of those has *more* displayed lines than git reported entries, so
/// indexing the blame array directly by buffer line silently shifts every
/// annotation after that character onto the wrong line — the wrong author and the
/// wrong date, on a clean saved buffer, reproduced identically by every
/// recompute. That is a different failure from the whole-line offset
/// `BlameController` documents and accepts: that one is bounded by the next save,
/// this one never heals. "Blank is honest; a wrong author is not" is the rule
/// `BlameShift` is built around, and a *misaligned* author is worse than either.
///
/// The mapping is the direct one: a buffer line is attributed to the git line it
/// is part of, i.e. the number of LFs strictly before its start. Two buffer lines
/// split by a lone CR therefore share one annotation — correct, since git saw
/// them as one line — and the result is exactly `lineStarts.count` long, which is
/// the `annotations.count == lineCount` invariant `BlameShift` then maintains.
/// For a file with no separator other than LF/CRLF the mapping is the identity,
/// so the ordinary case is unchanged (a test pins exactly that).
///
/// The scan reads the text through `getCharacters(_:range:)` in chunks of
/// ``chunkSize`` units rather than per character, for `BracketDepthScanner`'s
/// reason: `NSString.character(at:)` is an objc message send per character, which
/// on a megabyte-scale file is a real cost even for a pass that runs once per
/// blame load rather than per keystroke.
public enum BlameAlignment {
    /// UTF-16 units read per `getCharacters(_:range:)` call.
    internal static let chunkSize = 4096

    /// Map `lines` (one entry per LF-delimited line, in final-line order) onto
    /// `lineStarts` (ascending UTF-16 offsets into `content`, as
    /// `LineStartIndex.offsets(in:)` produces).
    ///
    /// The result always has exactly `lineStarts.count` entries: a buffer line
    /// whose git line has no entry — the trailing empty line, or any line past the
    /// end of a blame that describes a shorter file — is `nil`. A `lineStarts`
    /// entry outside `content` is clamped rather than trapping, and a non-ascending
    /// array (which the only caller cannot produce) degrades to reusing the count
    /// reached so far instead of rescanning backwards.
    public static func aligned(
        _ lines: [BlameLine?],
        toLineStartsIn content: NSString,
        lineStarts: [Int]
    ) -> [BlameLine?] {
        var result = [BlameLine?](repeating: nil, count: lineStarts.count)
        guard !lineStarts.isEmpty, !lines.isEmpty else { return result }

        let length = content.length
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var scanned = 0    // offset up to which LFs have been counted
        var lfCount = 0    // LFs strictly before `scanned`
        var index = 0

        while index < lineStarts.count {
            let target = min(max(lineStarts[index], 0), length)
            if scanned >= target {
                if lfCount < lines.count { result[index] = lines[lfCount] }
                index += 1
                continue
            }
            let end = min(scanned + chunkSize, target)
            let span = end - scanned
            buffer.withUnsafeMutableBufferPointer { raw in
                content.getCharacters(raw.baseAddress!, range: NSRange(location: scanned, length: span))
                for k in 0..<span where raw[k] == 0x0A { lfCount += 1 }
            }
            scanned = end
        }
        return result
    }
}
