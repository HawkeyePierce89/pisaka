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
    /// Whether sparing left trailing whitespace this configuration asked to
    /// trim — i.e. a protected line carried a run that trimming would otherwise
    /// have deleted.
    ///
    /// This is what makes the spared line a **deferral** rather than a silent
    /// exemption. Sparing promises "the next save after the caret leaves trims
    /// it", and nothing else in the engine or the app could otherwise tell a
    /// buffer that owes a trim from one that is already conforming: both answer
    /// an empty plan. A caller that saves on its own schedule — the autosave —
    /// re-offers exactly the buffers this flags, so the promise has something to
    /// come true on even when the user never edits that file again.
    ///
    /// Deliberately *not* "there were protected positions": a caret sitting on a
    /// line with nothing to trim owes nothing, and re-offering that buffer on
    /// every tick would put a whole-file scan per open tab on the main thread
    /// forever.
    public let deferredTrim: Bool

    public init(replacements: [IndentReplacement], text: String, deferredTrim: Bool = false) {
        self.replacements = replacements
        self.text = text
        self.deferredTrim = deferredTrim
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
/// open in an editor, or one being abandoned) is trimmed in full.
///
/// Sparing is a **deferral, and the deferral is tracked**: a plan that spared a
/// run says so through `SaveTransformPlan.deferredTrim`, so the caller can
/// re-offer that buffer instead of leaving the promise resting on the user
/// happening to edit the same file again. Without it the promise is simply false
/// for the commonest flow there is — type, pause, let the idle autosave write,
/// never touch the file again — and the run stays on disk for good.
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

    /// Whether `config` asks a save to change anything at all.
    ///
    /// The three on-save properties, and only them. Stated once here — rather
    /// than restated at each call site — because it is asked in two places for
    /// two reasons: `plan` uses it to return the input untouched without a scan,
    /// and a caller uses it to skip the work it would have to do *before* it can
    /// even call `plan`. On macOS that work is reading `NSTextView.string`, which
    /// materializes a fresh copy of the whole buffer; paying it on every autosave
    /// tick of every project without an `.editorconfig` is exactly the cost this
    /// feature promised not to add.
    ///
    /// Safe as a pre-filter: `protectedPositions` can only *remove* edits, so a
    /// configuration stating none of the three yields an empty plan whatever the
    /// caret is doing.
    public static func rewrites(under config: EditorConfigProperties) -> Bool {
        config.endOfLine != nil
            || config.trimTrailingWhitespace == true
            || config.insertFinalNewline == true
    }

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
        // The case a project without `.editorconfig` takes, and the one a
        // configuration stating only part 1's indentation properties takes: no
        // scan, no allocation, the input returned as it arrived.
        guard rewrites(under: config) else {
            return SaveTransformPlan(replacements: [], text: text)
        }
        let target = config.endOfLine?.terminator
        let trims = config.trimTrailingWhitespace == true
        let appendsFinalNewline = config.insertFinalNewline == true

        let ns = text as NSString
        let lines = TerminatedLines.ranges(text)
        // An empty buffer has no line to terminate and no whitespace to trim.
        guard let lastLine = lines.last else {
            return SaveTransformPlan(replacements: [], text: text)
        }

        let spared = trims ? sparedLines(lines, positions: protectedPositions) : []
        var replacements: [IndentReplacement] = []
        // Set by a spared line that actually carried a run — the trim this save
        // owes the next one. See `SaveTransformPlan.deferredTrim`.
        var deferredTrim = false
        for (index, line) in lines.enumerated() {
            // Per line, the trim (inside the content) precedes the terminator
            // edit (immediately after it), so appending in line order already
            // yields the ascending, non-overlapping list the contract promises.
            if trims {
                let run = trailingWhitespace(in: ns, content: line.content)
                if run.length > 0 {
                    if spared.contains(index) {
                        deferredTrim = true
                    } else {
                        replacements.append(IndentReplacement(range: run, replacement: ""))
                    }
                }
            }
            if let target, let edit = terminatorEdit(for: line, target: target, in: ns) {
                replacements.append(edit)
            }
        }

        // The last line's trailing run, measured whether or not sparing kept it
        // *this* time — the final-terminator decision has to read the trim the
        // configuration asks for, not the one this particular caret position
        // allowed. See `finalTerminator`.
        let lastLineTrimLength = trims ? trailingWhitespace(in: ns, content: lastLine.content).length : 0
        if appendsFinalNewline,
           let terminator = finalTerminator(
               lines: lines,
               lastLine: lastLine,
               lastLineTrimLength: lastLineTrimLength,
               target: target,
               in: ns
           ) {
            replacements.append(IndentReplacement(
                range: NSRange(location: ns.length, length: 0),
                replacement: terminator
            ))
        }

        guard !replacements.isEmpty else {
            return SaveTransformPlan(replacements: [], text: text, deferredTrim: deferredTrim)
        }
        return SaveTransformPlan(
            replacements: replacements,
            text: applied(replacements, to: ns),
            deferredTrim: deferredTrim
        )
    }

    /// The text `replacements` produce, built in **one forward pass**: the gap
    /// before each edit, then that edit's replacement, then the tail.
    ///
    /// Deliberately not "copy the buffer and apply the edits into it". A whole-file
    /// `end_of_line` normalization emits one edit *per line*, and every in-place
    /// replacement on a mutable string shifts the rest of the buffer, so that
    /// shape is quadratic in the file — seconds of a synchronous autosave tick on
    /// a large file, for a string this function is only asked to produce once.
    /// Appending is linear because the edits arrive ascending and non-overlapping,
    /// which is exactly what the plan's contract already promises.
    private static func applied(_ replacements: [IndentReplacement], to ns: NSString) -> String {
        let result = NSMutableString(capacity: ns.length)
        var cursor = 0
        for edit in replacements {
            if edit.range.location > cursor {
                result.append(ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)))
            }
            result.append(edit.replacement)
            cursor = NSMaxRange(edit.range)
        }
        if cursor < ns.length {
            result.append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return result as String
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
    /// `lastLineTrimLength` is the run trimming **would** delete from the last
    /// line, measured whether or not the caret spared that line on this save.
    /// Reading the spared answer instead would make the appended terminator
    /// depend on where the caret happened to be at an autosave tick: a
    /// whitespace-only last line under the caret would be terminated, the next
    /// save (the caret now elsewhere) would trim the whitespace it just
    /// terminated, and the file would keep a blank line nobody typed — a fixed
    /// point *different* from the one the same buffer reaches with the caret
    /// anywhere else. Sparing is a deferral of the trim, not a change of what the
    /// file should end up being, so only the trim edit itself honours it.
    ///
    /// Which terminator: the configured one when `end_of_line` states it,
    /// otherwise the file's own last terminator, otherwise LF. Reading the file's
    /// own answer rather than defaulting to LF is what keeps a CRLF file that
    /// states no `end_of_line` from gaining a lone LF at the end.
    private static func finalTerminator(
        lines: [TerminatedLineRange],
        lastLine: TerminatedLineRange,
        lastLineTrimLength: Int,
        target: String?,
        in ns: NSString
    ) -> String? {
        guard lastLine.terminator.length == 0 else { return nil }
        guard lastLine.content.length - lastLineTrimLength > 0 else { return nil }
        if let target { return target }
        let previous = lines.count >= 2 ? ns.substring(with: lines[lines.count - 2].terminator) : ""
        return previous.isEmpty ? defaultTerminator : previous
    }

    // MARK: - The spared lines

    /// The protected positions a text view's selection state contributes: a bare
    /// caret gives its location, a selection gives **both** of its endpoints.
    ///
    /// Stated here rather than at the call site because it is a decision, not a
    /// conversion: the middle-drag column selection makes several carets a
    /// first-class state, so the argument is the *whole* `selectedRanges` array
    /// and an autosave landing on one of them spares every line it sits on, not
    /// just the first. `NSNotFound` ranges (no selection) contribute nothing.
    public static func protectedPositions(forSelectedRanges ranges: [NSRange]) -> [Int] {
        ranges.flatMap { range -> [Int] in
            guard range.location != NSNotFound, range.location >= 0 else { return [] }
            return range.length == 0 ? [range.location] : [range.location, NSMaxRange(range)]
        }
    }

    /// The indices of the lines holding a protected position.
    ///
    /// A position sits on the line whose *enclosing* range (content and
    /// terminator together) contains it, so a caret parked at the end of a line's
    /// content — the case the rule exists for — spares that line rather than the
    /// next one, while a caret at column zero spares only the line it is on. A
    /// position at (or past) the end of the text belongs to the last line, which
    /// is where the caret at end of file is.
    ///
    /// `NSNotFound` and negatives name no position and are dropped rather than
    /// resolved into one, the same posture `remappedOffset` takes: inventing a
    /// line for them would silently spare a line nobody is on.
    private static func sparedLines(_ lines: [TerminatedLineRange], positions: [Int]) -> Set<Int> {
        var spared: Set<Int> = []
        for position in positions {
            guard position != NSNotFound, position >= 0,
                  let index = lineIndex(containing: position, in: lines) else { continue }
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
