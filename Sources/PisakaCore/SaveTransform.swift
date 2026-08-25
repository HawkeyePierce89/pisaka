import Foundation

/// What one save changes: the edits, the bytes that result, and where the
/// positions that must survive land afterwards.
///
/// `replacements` are expressed against the **original** text, sorted by
/// ascending location and never overlapping, exactly like `TabInsertionPlan`'s
/// — which is what lets a view apply them **back-to-front** inside one
/// `beginEditing`/`endEditing` bracket: applying the last one first leaves every
/// earlier range's offsets untouched, so the whole save is one undoable step and
/// one change notification. `IndentReplacement` is reused verbatim, as
/// `IndentUnitRule` already does: a (range, replacement) pair is a
/// (range, replacement) pair whichever rule produced it.
///
/// An **empty plan is the answer for every case this feature must not touch** —
/// no `.editorconfig`, a configuration stating none of the three properties, or
/// a buffer that already satisfies all of them. `text` is then the original
/// string byte for byte, so a caller may write it unconditionally without first
/// asking whether anything happened.
public struct SaveTransformPlan: Equatable {
    /// The edits, against the original text: ascending, non-overlapping.
    public let replacements: [IndentReplacement]
    /// The text those edits produce — the bytes that must reach the disk, the
    /// buffer and the saved baseline alike.
    public let text: String

    public init(replacements: [IndentReplacement], text: String) {
        self.replacements = replacements
        self.text = text
    }

    /// Nothing to do; `text` is the input, unchanged.
    public var isEmpty: Bool { replacements.isEmpty }

    /// Where a UTF-16 offset in the original text lands in `text`.
    ///
    /// The arithmetic lives here and nowhere else, so the caret, each selection
    /// endpoint and the scroll anchor are all remapped by the same three rules:
    ///
    /// - an offset at or before an edit's start is **unchanged** by it. "At the
    ///   start" is deliberately counted as *before*: an insertion is
    ///   zero-length, and the only insertion this engine emits sits at the end
    ///   of the file, where treating the caret as after it would push the reader
    ///   onto the newly created empty line for no reason.
    /// - an offset at or after an edit's end shifts by that edit's net length.
    /// - an offset **inside** an edit is clamped into the replacement rather
    ///   than left to chance: it keeps its distance from the edit's start, up to
    ///   the replacement's own length. A deletion (a trimmed whitespace run)
    ///   therefore collapses to the edit's start, and an offset between a CR and
    ///   its LF lands at the end of whatever replaced the pair.
    ///
    /// `NSNotFound` and negative offsets are returned untouched: they name no
    /// position, and inventing one for them would turn "no selection" into a
    /// caret somewhere.
    public func remappedOffset(_ offset: Int) -> Int {
        guard offset != NSNotFound, offset >= 0 else { return offset }
        var shift = 0
        for edit in replacements {
            let start = edit.range.location
            let end = NSMaxRange(edit.range)
            if offset <= start { break }
            let replacementLength = (edit.replacement as NSString).length
            if offset >= end {
                shift += replacementLength - edit.range.length
            } else {
                return start + shift + min(offset - start, replacementLength)
            }
        }
        return offset + shift
    }

    /// A range remapped through its two ends, which is the only definition that
    /// stays correct when an edit falls *inside* the selection (both ends move
    /// by different amounts) as well as when one lands on an end.
    public func remappedRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound, range.location >= 0 else { return range }
        let location = remappedOffset(range.location)
        let end = remappedOffset(NSMaxRange(range))
        return NSRange(location: location, length: max(0, end - location))
    }

    /// The selection and the scroll anchor of one tab, both remapped — what the
    /// view restores after applying the plan.
    public func remappedViewport(_ viewport: EditorViewport) -> EditorViewport {
        EditorViewport(
            selection: remappedRange(viewport.selection),
            topCharacterOffset: remappedOffset(viewport.topCharacterOffset)
        )
    }
}

/// The one engine that decides what a save rewrites.
///
/// This is the single deliberate exception to the EditorConfig layer's founding
/// principle that *existing content is never reformatted*: a **save**, and
/// nothing else, may rewrite trailing whitespace and line terminators, and only
/// when the project's own `.editorconfig` asks for it. Opening a file, closing
/// it, switching tabs and editing an `.editorconfig` still change nothing, and
/// indentation is still never rewritten.
///
/// Three properties are consumed, composed into one plan in a **stated order**:
///
/// 1. `end_of_line` — every LF, CR and CRLF terminator differing from the target
///    becomes the target.
/// 2. `trim_trailing_whitespace` — the run of spaces and tabs before each
///    terminator (and at end of file) is deleted, except on a spared line.
/// 3. `insert_final_newline` — a file not ending in a terminator gains exactly
///    one.
///
/// The order is what the third step reads, not the order the edits are applied
/// in: every edit is expressed against the **original** offsets, so composing
/// them needs no intermediate buffer and the position remap stays exact. Only
/// the final-terminator decision has to look through the earlier steps — a last
/// line that trimming empties is already terminated by the line before it, and
/// must not gain a second terminator.
///
/// **The spared line.** Autosave here is aggressive (idle, tab switch, focus
/// loss, termination), so trimming the line the caret is on would delete the
/// indentation someone had just typed and was about to type into, mid-thought.
/// Every line holding a protected position — the caret, and each endpoint of a
/// selection — therefore keeps its trailing whitespace; the very next save after
/// the caret moves away trims it. A buffer with no protected positions (one not
/// open in an editor) is trimmed in full.
///
/// **The stated limit.** `end_of_line`'s vocabulary names LF, CR and CRLF and
/// nothing else, while the editor splits lines on NEL, LS and PS too. Those
/// three are left exactly as they are: folding a separator the property never
/// named into one it did would be this engine inventing a rule the configuration
/// did not state.
///
/// Pure and Foundation-only, on `NSString` UTF-16 offsets like every other
/// editor engine here. The views apply what it answers and compute nothing.
public enum SaveTransform {

    /// The terminators `end_of_line` can name, and therefore the only ones
    /// normalization may replace.
    static let normalizableTerminators: Set<String> = ["\n", "\r", "\r\n"]

    /// The terminator appended when nothing else says which: the file states no
    /// `end_of_line` and contains no terminator of its own.
    static let defaultTerminator = "\n"

    /// What saving `text` under `config` changes.
    ///
    /// `protectedPositions` are UTF-16 offsets into `text` whose lines are
    /// spared from trimming — pass the caret and both endpoints of every
    /// selection when the buffer is open in an editor, and nothing at all when
    /// it is not. They affect trimming only: a terminator is normalized and a
    /// final newline appended under the caret exactly as anywhere else, because
    /// neither can delete something the user just typed.
    public static func plan(
        text: String,
        config: EditorConfigProperties,
        protectedPositions: [Int] = []
    ) -> SaveTransformPlan {
        let target = config.endOfLine?.terminator
        let trims = config.trimTrailingWhitespace == true
        let appendsFinalNewline = config.insertFinalNewline == true
        // The case a project without `.editorconfig` takes, and the one a
        // configuration stating only part 1's indentation properties takes: no
        // scan, no allocation, the input returned as it arrived.
        guard target != nil || trims || appendsFinalNewline else {
            return SaveTransformPlan(replacements: [], text: text)
        }

        let ns = text as NSString
        let lines = TerminatedLines.ranges(text)
        // An empty buffer has no line to terminate and no whitespace to trim.
        guard let lastLine = lines.last else {
            return SaveTransformPlan(replacements: [], text: text)
        }

        let spared = trims ? sparedLines(lines, positions: protectedPositions) : []
        var replacements: [IndentReplacement] = []
        var trimmedFromLastLine = 0
        for (index, line) in lines.enumerated() {
            // Per line, the trim (inside the content) precedes the terminator
            // edit (immediately after it), so appending in line order already
            // yields the ascending, non-overlapping list the contract promises.
            if trims, !spared.contains(index) {
                let run = trailingWhitespace(in: ns, content: line.content)
                if run.length > 0 {
                    replacements.append(IndentReplacement(range: run, replacement: ""))
                    if index == lines.count - 1 { trimmedFromLastLine = run.length }
                }
            }
            if let target, let edit = terminatorEdit(for: line, target: target, in: ns) {
                replacements.append(edit)
            }
        }

        if appendsFinalNewline,
           let terminator = finalTerminator(
               lines: lines,
               lastLine: lastLine,
               trimmedFromLastLine: trimmedFromLastLine,
               target: target,
               in: ns
           ) {
            replacements.append(IndentReplacement(
                range: NSRange(location: ns.length, length: 0),
                replacement: terminator
            ))
        }

        guard !replacements.isEmpty else { return SaveTransformPlan(replacements: [], text: text) }
        let result = NSMutableString(string: text)
        for edit in replacements.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return SaveTransformPlan(replacements: replacements, text: result as String)
    }

    // MARK: - The three transforms

    /// The replacement normalizing this line's terminator, or `nil` when there
    /// is nothing to do — an unterminated final line, a terminator already equal
    /// to the target, or one of the three separators the property does not name.
    private static func terminatorEdit(
        for line: TerminatedLineRange,
        target: String,
        in ns: NSString
    ) -> IndentReplacement? {
        guard line.terminator.length > 0 else { return nil }
        let existing = ns.substring(with: line.terminator)
        guard normalizableTerminators.contains(existing), existing != target else { return nil }
        return IndentReplacement(range: line.terminator, replacement: target)
    }

    /// The trailing run of spaces and tabs in `content`, empty when there is
    /// none. Only those two characters: anything else — including the separators
    /// `end_of_line` does not name — is content as far as trimming is concerned.
    private static func trailingWhitespace(in ns: NSString, content: NSRange) -> NSRange {
        var start = NSMaxRange(content)
        while start > content.location {
            let character = ns.character(at: start - 1)
            guard character == 0x20 || character == 0x09 else { break }
            start -= 1
        }
        return NSRange(location: start, length: NSMaxRange(content) - start)
    }

    /// The terminator to append at end of file, or `nil` when none should be.
    ///
    /// Nothing is appended when the file already ends in a terminator (never
    /// doubled, and equally never *removed*), nor when trimming empties the last
    /// line — the line before it already terminates the text — nor when that
    /// leaves the whole buffer empty, since an empty buffer has no line to
    /// terminate.
    ///
    /// Which terminator: the configured one when `end_of_line` states it,
    /// otherwise the file's own last terminator, otherwise LF. Reading the file's
    /// own answer rather than defaulting to LF is what keeps a CRLF file that
    /// states no `end_of_line` from gaining a lone LF at the end.
    private static func finalTerminator(
        lines: [TerminatedLineRange],
        lastLine: TerminatedLineRange,
        trimmedFromLastLine: Int,
        target: String?,
        in ns: NSString
    ) -> String? {
        guard lastLine.terminator.length == 0 else { return nil }
        guard lastLine.content.length - trimmedFromLastLine > 0 else { return nil }
        if let target { return target }
        let previous = lines.count >= 2 ? ns.substring(with: lines[lines.count - 2].terminator) : ""
        return previous.isEmpty ? defaultTerminator : previous
    }

    // MARK: - The spared lines

    /// The indices of the lines holding a protected position.
    ///
    /// A position sits on the line whose *enclosing* range (content and
    /// terminator together) contains it, so a caret parked at the end of a line's
    /// content — the case the rule exists for — spares that line rather than the
    /// next one, while a caret at column zero spares only the line it is on. A
    /// position at (or past) the end of the text belongs to the last line, which
    /// is where the caret at end of file is.
    private static func sparedLines(_ lines: [TerminatedLineRange], positions: [Int]) -> Set<Int> {
        var spared: Set<Int> = []
        for position in positions {
            guard position != NSNotFound, let index = lineIndex(containing: position, in: lines) else { continue }
            spared.insert(index)
        }
        return spared
    }

    /// Binary search over the tiling `enclosing` ranges — they start where the
    /// previous one ended and the last ends at the text's end, which is what
    /// makes the search well-defined without a separator table of its own.
    private static func lineIndex(containing offset: Int, in lines: [TerminatedLineRange]) -> Int? {
        guard let last = lines.last else { return nil }
        let clamped = min(max(offset, 0), NSMaxRange(last.enclosing))
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = lines[middle].enclosing
            if clamped < range.location {
                high = middle - 1
            } else if clamped >= NSMaxRange(range) {
                low = middle + 1
            } else {
                return middle
            }
        }
        // Only reachable for an offset at the very end of the text, which no
        // half-open range contains.
        return lines.count - 1
    }
}
