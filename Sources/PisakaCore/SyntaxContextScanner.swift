import Foundation

/// The syntactic region the caret sits in.
public enum SyntaxContext: Equatable, Sendable {
    case code
    case string
    case comment
}

/// Answers whether the caret is inside a string literal or a comment,
/// per language.
///
/// The table of what counts as a string or a comment lives in
/// `SyntaxContextVocabulary`; this type only walks the buffer.
///
/// The context at offset `k` is the state after consuming characters
/// `[0, k)`. That yields the boundary rule without special-casing:
/// just before an opening delimiter is code, just after it is string.
/// A single-line string that is never closed ends at the line separator,
/// so an unterminated `'` cannot poison the rest of the file; a
/// multi-line form runs to the end of the buffer.
///
/// One `Scan` object carries a whole call: the buffer, the chunk, the
/// once-ordered string forms and the two validator cursors. Every helper takes
/// it in place of a bare `NSString`, so there is exactly one way to read a
/// character and exactly one place the per-scan work is done.
public enum SyntaxContextScanner {

    internal static let chunkSize = 4096

    // MARK: - Public API

    /// The syntactic context at `offset` in `text` for `language`.
    public static func context(
        in text: NSString,
        at offset: Int,
        language: SyntaxLanguage
    ) -> SyntaxContext {
        let length = text.length
        guard offset > 0, offset <= length else { return .code }
        return runScan(text: text, upTo: offset, language: language).context
    }

    /// Whether completion should be suppressed at `offset` in `text` for
    /// `language`.
    ///
    /// Short-circuits through `SyntaxContextVocabulary.canSuppressCompletion(_:)`
    /// so languages that can never suppress pay no scan.
    public static func suppressesCompletion(
        in text: NSString,
        at offset: Int,
        language: SyntaxLanguage
    ) -> Bool {
        guard SyntaxContextVocabulary.canSuppressCompletion(language) else { return false }
        let length = text.length
        guard offset >= 0, offset <= length else { return false }
        let ctx = context(in: text, at: offset, language: language)
        switch ctx {
        case .code:
            return false
        case .comment:
            return true
        case .string:
            return SyntaxContextVocabulary.stringsSuppressCompletion(for: language)
        }
    }

    /// How many characters the two validated-open walks — YAML flow depth and
    /// HTML inside-tag — visited while answering one `context(in:at:language:)`
    /// call.
    ///
    /// A test seam and nothing else: no app code reads this, and it is
    /// `internal` rather than `public` for that reason. It exists so the
    /// characterization suite can assert those two walks scale roughly
    /// linearly with the document without consulting a clock — a walk restarted
    /// from offset zero for every candidate quote blows the count up by an
    /// order of magnitude, which is a difference no scheduling noise can hide
    /// and no wall-clock bound can measure honestly.
    internal static func validatorStepCount(
        in text: NSString,
        at offset: Int,
        language: SyntaxLanguage
    ) -> Int {
        let length = text.length
        guard offset > 0, offset <= length else { return 0 }
        return runScan(text: text, upTo: offset, language: language).steps
    }

    // MARK: - The per-scan reader

    /// Everything one scan needs, built once per call.
    ///
    /// It exists to settle three things the walk used to redo per character or
    /// per candidate:
    ///
    /// * **The chunk.** The bulk read used to be filled by the outer loop and
    ///   then bypassed by every helper, each of which read `NSString` directly
    ///   — the buffer was half-used. Every read now goes through
    ///   `character(at:)`, so the bulk read is actually spent. A look-ahead
    ///   past the loaded chunk still falls back to a direct read instead of
    ///   re-loading, so alternating near/far reads cannot thrash the buffer.
    /// * **The string forms.** Ordered longest-open-first once here rather than
    ///   sorted again at every offset the walk considers.
    /// * **The two validator cursors.** See `yamlFlowDepth(upTo:scan:)` and
    ///   `isInsideHtmlTag(at:scan:)` for the rule that keeps a resumed walk's
    ///   answers *identical* to a walk from zero rather than merely close.
    private final class Scan {
        let text: NSString
        let length: Int
        let language: SyntaxLanguage
        let vocab: SyntaxContextVocabulary.Vocabulary
        /// Longest open delimiter first, so the walk tries `"""` before `"`.
        let orderedStringForms: [SyntaxContextVocabulary.StringForm]

        private var buffer: [unichar]
        private var chunkStart = 0
        private var chunkCount = 0

        var yamlCursor = YamlFlowCursor()
        var htmlCursor = HtmlTagCursor()
        /// See `SyntaxContextScanner.validatorStepCount(in:at:language:)`.
        private(set) var validatorSteps = 0

        init(text: NSString, language: SyntaxLanguage) {
            self.text = text
            self.length = text.length
            self.language = language
            let vocab = SyntaxContextVocabulary.vocabulary(for: language)
            self.vocab = vocab
            self.orderedStringForms = vocab.stringForms.sorted { $0.open.utf16.count > $1.open.utf16.count }
            self.buffer = [unichar](repeating: 0, count: min(SyntaxContextScanner.chunkSize, max(length, 1)))
            if length > 0 {
                chunkCount = min(SyntaxContextScanner.chunkSize, length)
                load(at: 0, count: chunkCount)
            }
        }

        /// The character at `pos`, or `0` when `pos` is outside the buffer.
        ///
        /// Every call site guards its own bounds before it cares about the
        /// answer; the zero is what the outer loop already substituted and is
        /// never mistaken for content.
        func character(at pos: Int) -> unichar {
            guard pos >= 0, pos < length else { return 0 }
            if pos >= chunkStart, pos < chunkStart + chunkCount {
                return buffer[pos - chunkStart]
            }
            // Look-ahead beyond the loaded chunk reads through, deliberately:
            // re-loading here would thrash the buffer for a two-character peek.
            return text.character(at: pos)
        }

        /// Moves the loaded chunk so `pos` falls inside it. Called by the outer
        /// loop only — the sequential walk is what the bulk read pays for.
        func ensureChunk(for pos: Int) {
            guard pos >= 0, pos < length else { return }
            if pos >= chunkStart, pos < chunkStart + chunkCount { return }
            chunkStart = (pos / SyntaxContextScanner.chunkSize) * SyntaxContextScanner.chunkSize
            chunkCount = min(SyntaxContextScanner.chunkSize, length - chunkStart)
            load(at: chunkStart, count: chunkCount)
        }

        func isMatch(at idx: Int, pattern: String) -> Bool {
            let plen = pattern.utf16.count
            guard idx >= 0, idx + plen <= length else { return false }
            let pat = pattern as NSString
            for i in 0..<plen where character(at: idx + i) != pat.character(at: i) { return false }
            return true
        }

        func countValidatorStep() {
            validatorSteps += 1
        }

        private func load(at start: Int, count: Int) {
            buffer.withUnsafeMutableBufferPointer {
                text.getCharacters($0.baseAddress!, range: NSRange(location: start, length: count))
            }
        }
    }

    /// The resumable state of `yamlFlowDepth(upTo:scan:)`.
    private struct YamlFlowCursor {
        var position = 0
        var depth = 0
        var inSingle = false
        var inDouble = false
    }

    /// The resumable state of `isInsideHtmlTag(at:scan:)`.
    private struct HtmlTagCursor {
        var position = 0
        var inTag = false
        var inSingle = false
        var inDouble = false
    }

    // MARK: - Scanning

    private static func runScan(
        text: NSString,
        upTo offset: Int,
        language: SyntaxLanguage
    ) -> (context: SyntaxContext, steps: Int) {
        let scan = Scan(text: text, language: language)
        var stack: [Frame] = []
        var idx = 0

        // Chunked bulk-read following BracketDepthScanner's pattern. The loop
        // is sequential, so it is the one place worth moving the chunk;
        // look-aheads read through `Scan.character(at:)`, which falls back past
        // the chunk's end so delimiters straddling a boundary are not missed.
        while idx < offset {
            scan.ensureChunk(for: idx)
            let ch = scan.character(at: idx)
            let top = stack.last
            let next: Int
            switch top {
            case .none:
                next = advanceCode(at: idx, offset: offset, scan: scan, stack: &stack)
            case .some(.lineComment):
                next = advanceLineComment(at: idx, ch: ch, stack: &stack)
            case .some(.blockComment):
                next = advanceBlockComment(at: idx, offset: offset, scan: scan, stack: &stack)
            case .some(.string):
                next = advanceString(at: idx, offset: offset, scan: scan, ch: ch, stack: &stack)
            case .some(.hole):
                next = advanceHole(at: idx, offset: offset, scan: scan, stack: &stack)
            }
            idx = next
        }

        // Determine context from final stack
        if let top = stack.last {
            switch top {
            case .string: return (.string, scan.validatorSteps)
            case .lineComment, .blockComment: return (.comment, scan.validatorSteps)
            case .hole: return (.code, scan.validatorSteps)
            }
        }
        return (.code, scan.validatorSteps)
    }

    // MARK: - State helpers

    private static func advanceCode(
        at idx: Int, offset: Int, scan: Scan, stack: inout [Frame]
    ) -> Int {
        if let m = stringMatch(at: idx, scan: scan),
           idx + m.totalLen <= offset,
           isValidStringOpen(at: idx, scan: scan, match: m) {
            stack.append(.string(form: m.form, pound: m.pound, isRaw: m.isRaw, hasF: m.hasF))
            return idx + m.totalLen
        }
        if let c = commentMatch(at: idx, scan: scan),
           idx + c.len <= offset {
            switch c.form {
            case .line:
                stack.append(.lineComment)
                return idx + c.len
            case .block(let open, let close, let nestable):
                stack.append(.blockComment(open: open, close: close, nestable: nestable, depth: 1))
                return idx + open.utf16.count
            }
        }
        return idx + 1
    }

    private static func advanceLineComment(at idx: Int, ch: unichar, stack: inout [Frame]) -> Int {
        if isLineSeparator(ch) { stack.removeLast() }
        return idx + 1
    }

    private static func advanceBlockComment(
        at idx: Int, offset: Int, scan: Scan, stack: inout [Frame]
    ) -> Int {
        guard case .blockComment(let open, let close, let nestable, let depth) = stack.last else {
            return idx + 1
        }
        if nestable, scan.isMatch(at: idx, pattern: open),
           idx + open.utf16.count <= offset {
            stack[stack.count - 1] = .blockComment(open: open, close: close, nestable: nestable, depth: depth + 1)
            return idx + open.utf16.count
        }
        if scan.isMatch(at: idx, pattern: close), idx + close.utf16.count <= offset {
            if depth > 1 {
                stack[stack.count - 1] = .blockComment(open: open, close: close, nestable: nestable, depth: depth - 1)
            } else {
                stack.removeLast()
            }
            return idx + close.utf16.count
        }
        return idx + 1
    }

    private static func advanceString(
        at idx: Int, offset: Int, scan: Scan, ch: unichar, stack: inout [Frame]
    ) -> Int {
        guard case .string(let form, let pound, let isRaw, let hasF) = stack.last else {
            return idx + 1
        }
        if !form.spansLines, isLineSeparator(ch) {
            stack.removeLast()
            return idx + 1
        }
        if form.allowedPrefixLetters != nil, hasF,
           idx + 2 <= offset,
           scan.isMatch(at: idx, pattern: "{{") || scan.isMatch(at: idx, pattern: "}}") {
            return idx + 2
        }
        if let holeLen = holeOpenLength(at: idx, scan: scan, form: form, pound: pound, hasF: hasF),
           let kind = holeKind(for: form), idx + holeLen <= offset {
            stack.append(.hole(kind: kind, depth: 0, pound: pound))
            return idx + holeLen
        }
        if form.escape == .doubledDelimiter {
            let closeWithPound = form.close + String(repeating: "#", count: pound)
            if idx + closeWithPound.utf16.count * 2 <= offset,
               scan.isMatch(at: idx, pattern: closeWithPound + closeWithPound) {
                return idx + closeWithPound.utf16.count * 2
            }
        }
        if form.escape == .backslash, !isRaw,
           let escLen = backslashEscapeLength(at: idx, scan: scan, pound: pound, allowsPound: form.allowsPoundPadding),
           idx + escLen <= offset {
            return idx + escLen
        }
        let closeDelim = form.close + String(repeating: "#", count: pound)
        if idx + closeDelim.utf16.count <= offset, scan.isMatch(at: idx, pattern: closeDelim) {
            stack.removeLast()
            return idx + closeDelim.utf16.count
        }
        return idx + 1
    }

    private static func advanceHole(
        at idx: Int, offset: Int, scan: Scan, stack: inout [Frame]
    ) -> Int {
        guard case .hole(let kind, let depth, let pound) = stack.last else {
            return idx + 1
        }
        if idx + 1 <= offset, isHoleClose(at: idx, scan: scan, kind: kind, depth: depth) {
            if depth == 0 {
                stack.removeLast()
            } else {
                stack[stack.count - 1] = .hole(kind: kind, depth: depth - 1, pound: pound)
            }
            return idx + 1
        }
        if idx + 1 <= offset, isHoleNestedOpen(at: idx, scan: scan, kind: kind) {
            stack[stack.count - 1] = .hole(kind: kind, depth: depth + 1, pound: pound)
            return idx + 1
        }
        if let m = stringMatch(at: idx, scan: scan), idx + m.totalLen <= offset {
            stack.append(.string(form: m.form, pound: m.pound, isRaw: m.isRaw, hasF: m.hasF))
            return idx + m.totalLen
        }
        if let c = commentMatch(at: idx, scan: scan), idx + c.len <= offset {
            switch c.form {
            case .line:
                stack.append(.lineComment)
                return idx + c.len
            case .block(let open, let close, let nestable):
                stack.append(.blockComment(open: open, close: close, nestable: nestable, depth: 1))
                return idx + open.utf16.count
            }
        }
        return idx + 1
    }

    // MARK: - Frame

    private enum Frame {
        case string(form: SyntaxContextVocabulary.StringForm, pound: Int, isRaw: Bool, hasF: Bool)
        case lineComment
        case blockComment(open: String, close: String, nestable: Bool, depth: Int)
        case hole(kind: SyntaxContextVocabulary.InterpolationHole, depth: Int, pound: Int)
    }

    // MARK: - Helpers

    private static func isLineSeparator(_ ch: unichar) -> Bool {
        LineStartIndex.isLineSeparator(ch)
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        ch == 32 || ch == 9 // space, tab
    }

    private struct StringMatch {
        let form: SyntaxContextVocabulary.StringForm
        let pound: Int
        let isRaw: Bool
        let hasF: Bool
        let totalLen: Int
    }

    private static func stringMatch(at idx: Int, scan: Scan) -> StringMatch? {
        // Longest open first — the order is settled once, at `Scan`'s
        // construction, rather than re-sorted at every offset.
        var best: StringMatch?
        for form in scan.orderedStringForms {
            if let m = matchForm(form, at: idx, scan: scan) {
                if best == nil || m.totalLen > best!.totalLen {
                    best = m
                }
            }
        }
        return best
    }

    private static func matchForm(
        _ form: SyntaxContextVocabulary.StringForm, at idx: Int, scan: Scan
    ) -> StringMatch? {
        var pos = idx
        var isRaw = false
        var hasF = false
        var pound = 0
        // Prefix letters
        if let allowed = form.allowedPrefixLetters {
            var consumed = 0
            var tmpHasF = false
            var tmpIsRaw = false
            while pos < scan.length, consumed < 4 {
                let ch = scan.character(at: pos)
                guard isAsciiLetter(ch) else { break }
                let lower = toLower(ch)
                guard let scalar = UnicodeScalar(lower) else { break }
                let lc = Character(scalar)
                guard allowed.contains(lc) else { break }
                // Collect
                if lc == "r" { tmpIsRaw = true }
                if lc == "f" { tmpHasF = true }
                consumed += 1
                pos += 1
            }
            // If we consumed letters, they are part of match; but we need to try
            // with consumed count as prefix length. If no prefix but form allows it, also valid with 0.
            // To find a match we try the consumed prefix length we have; but there could be shorter prefix that matches?
            // Greedy is fine - we consumed maximal allowed prefix run.
            isRaw = tmpIsRaw
            hasF = tmpHasF
            // If form is for Python, hasF indicates f-string; store it.
            // Note: pos already advanced by consumed.
        }
        // Pound padding
        if form.allowsPoundPadding {
            while pos < scan.length, scan.character(at: pos) == 35 { // '#'
                pound += 1
                pos += 1
                if pound > 10 { break }
            }
        }
        // Raw forms (no escape + pound padding) require an `r` prefix — a bare `b`
        // is the byte-string form (`b"…"`) with normal escapes, not raw.
        if form.escape == .none, form.allowsPoundPadding, !isRaw, form.allowedPrefixLetters != nil {
            return nil
        }
        guard scan.isMatch(at: pos, pattern: form.open) else { return nil }
        let totalLen = (pos - idx) + form.open.utf16.count
        return StringMatch(form: form, pound: pound, isRaw: isRaw, hasF: hasF, totalLen: totalLen)
    }

    private static func isAsciiLetter(_ ch: unichar) -> Bool {
        (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)
    }

    private static func toLower(_ ch: unichar) -> unichar {
        if ch >= 65 && ch <= 90 { return ch + 32 }
        return ch
    }

    private struct CommentMatch {
        let form: SyntaxContextVocabulary.CommentForm
        let len: Int
    }

    private static func commentMatch(at idx: Int, scan: Scan) -> CommentMatch? {
        for form in scan.vocab.commentForms {
            switch form {
            case .line(let token, let anchor):
                guard scan.isMatch(at: idx, pattern: token) else { continue }
                guard isAnchorSatisfied(anchor, at: idx, scan: scan) else { continue }
                return CommentMatch(form: form, len: token.utf16.count)
            case .block(let open, _, _):
                guard scan.isMatch(at: idx, pattern: open) else { continue }
                // Block comments are not anchored
                return CommentMatch(form: form, len: open.utf16.count)
            }
        }
        return nil
    }

    private static func isAnchorSatisfied(
        _ anchor: SyntaxContextVocabulary.LineAnchor, at idx: Int, scan: Scan
    ) -> Bool {
        switch anchor {
        case .anywhere:
            return true
        case .trueLineStart:
            // Column zero exactly: no whitespace tolerance, because the one
            // language holding this anchor (gitignore) reads an indented token
            // as a literal pattern character rather than a comment opener.
            if idx == 0 { return true }
            return isLineSeparator(scan.character(at: idx - 1))
        case .afterIndent:
            return isAfterIndent(at: idx, scan: scan)
        case .afterWhitespace:
            if isAfterIndent(at: idx, scan: scan) { return true }
            guard idx > 0 else { return true }
            let prev = scan.character(at: idx - 1)
            return isWhitespace(prev) || isLineSeparator(prev)
        }
    }

    /// Whether `idx` is the first non-whitespace position on its line — the line
    /// may be indented, but nothing else may precede the token.
    private static func isAfterIndent(at idx: Int, scan: Scan) -> Bool {
        if idx == 0 { return true }
        // Find last line separator before idx
        var lineStart = 0
        var i = idx - 1
        while i >= 0 {
            if isLineSeparator(scan.character(at: i)) {
                lineStart = i + 1
                break
            }
            i -= 1
        }
        // Check from lineStart to idx-1 all whitespace
        for p in lineStart..<idx {
            let c = scan.character(at: p)
            if !isWhitespace(c) { return false }
        }
        return true
    }

    private static func holeKind(for form: SyntaxContextVocabulary.StringForm) -> SyntaxContextVocabulary.InterpolationHole? {
        form.hole
    }

    private static func holeOpenLength(
        at idx: Int, scan: Scan,
        form: SyntaxContextVocabulary.StringForm, pound: Int, hasF: Bool
    ) -> Int? {
        guard let hole = form.hole else { return nil }
        switch hole {
        case .jsTemplate:
            guard scan.isMatch(at: idx, pattern: "${") else { return nil }
            return 2
        case .swiftInterpolation:
            // \ + pound * # + (
            guard scan.character(at: idx) == 92 else { return nil } // '\'
            var pos = idx + 1
            for _ in 0..<pound {
                guard pos < scan.length, scan.character(at: pos) == 35 else { return nil }
                pos += 1
            }
            guard pos < scan.length, scan.character(at: pos) == 40 else { return nil } // '('
            return 1 + pound + 1
        case .pythonFString:
            guard hasF else { return nil }
            guard idx < scan.length, scan.character(at: idx) == 123 else { return nil } // '{'
            // {{ is literal, not hole
            if idx + 1 < scan.length, scan.character(at: idx + 1) == 123 { return nil }
            // Also avoid '{' that is part of '}}' previously handled
            return 1
        }
    }

    private static func backslashEscapeLength(
        at idx: Int, scan: Scan, pound: Int, allowsPound: Bool
    ) -> Int? {
        guard idx < scan.length, scan.character(at: idx) == 92 else { return nil } // '\'
        if allowsPound {
            var pos = idx + 1
            for _ in 0..<pound {
                guard pos < scan.length, scan.character(at: pos) == 35 else { return nil }
                pos += 1
            }
            guard pos < scan.length else { return nil }
            return 1 + pound + 1
        } else {
            guard idx + 1 < scan.length else { return nil }
            return 2
        }
    }

    private static func isHoleClose(
        at idx: Int, scan: Scan, kind: SyntaxContextVocabulary.InterpolationHole, depth: Int
    ) -> Bool {
        guard idx < scan.length else { return false }
        let ch = scan.character(at: idx)
        switch kind {
        case .jsTemplate, .pythonFString:
            return ch == 125 // '}'
        case .swiftInterpolation:
            return ch == 41 // ')'
        }
    }

    private static func isHoleNestedOpen(
        at idx: Int, scan: Scan, kind: SyntaxContextVocabulary.InterpolationHole
    ) -> Bool {
        guard idx < scan.length else { return false }
        let ch = scan.character(at: idx)
        switch kind {
        case .jsTemplate, .pythonFString:
            return ch == 123 // '{'
        case .swiftInterpolation:
            return ch == 40 // '('
        }
    }

    // MARK: - Ungated string gating

    private static func isValidStringOpen(at idx: Int, scan: Scan, match: StringMatch) -> Bool {
        // Gated languages accept any configured delimiter; the false-positive
        // masking only matters where strings are *recognized* but not gating.
        if SyntaxContextVocabulary.stringsSuppressCompletion(for: scan.language) { return true }
        // Languages without string vocabulary never reach here, but guard anyway.
        if scan.vocab.stringForms.isEmpty { return true }
        switch scan.language {
        case .html:
            return isAttributeStringOpen(at: idx, scan: scan)
        case .yaml:
            return isYamlStringOpen(at: idx, scan: scan)
        case .json:
            return isJsonStringOpen(at: idx, scan: scan)
        case .dotenv:
            return isDotenvStringOpen(at: idx, scan: scan)
        default:
            return true
        }
    }

    private static func isAttributeStringOpen(at idx: Int, scan: Scan) -> Bool {
        // Attribute values are `=` + optional whitespace + quote, but only
        // inside a tag (`<…>`). Walk back skipping spaces/tabs; the first
        // non-whitespace must be `=`, and there must be an unclosed `<`
        // before that `=`.
        var pos = idx - 1
        while pos >= 0 {
            let ch = scan.character(at: pos)
            if ch == 32 || ch == 9 {
                pos -= 1
                continue
            }
            guard ch == 61 else { return false } // '='
            break
        }
        if pos < 0 { return false }
        // Verify we are inside a tag. Scan forward to the quote while tracking
        // quoted attribute values, so a `>` inside an earlier `data="a > b"`
        // does not look like the tag's close. Single-line strings reset at any
        // line separator; `<!-- -->` comments are skipped outside tags.
        return isInsideHtmlTag(at: idx, scan: scan)
    }

    /// Whether `target` sits inside an HTML tag, resuming the scan's cursor.
    ///
    /// The walk is *resumable*: a scan asks this at each candidate quote and
    /// those targets only ever increase, so the cursor carries (position,
    /// in-tag, in-single, in-double) forward instead of re-walking from offset
    /// zero every time. A backwards query restarts from zero — the scan's
    /// monotonic candidate order never issues one, and that fallback is what
    /// makes the resumed answers *identical* rather than merely usually
    /// identical.
    ///
    /// Two of the walk's decisions consult `target` itself: a `<!--` whose
    /// fourth character sits at or past it, and a comment that finds no `-->`
    /// before it. A state reached through either is a fact about *this* query,
    /// not about the buffer, so the cursor commits the state from before that
    /// character and the rest of the answer is computed without being recorded.
    /// The answer returned is always the full walk's, clamps included.
    ///
    /// The first of the two is **unreachable through today's vocabulary** and is
    /// kept as a guard on that vocabulary rather than as a case that occurs: the
    /// only caller is `isAttributeStringOpen`, so `target` is always the offset
    /// of a string opener, and HTML's two string forms are the single characters
    /// `'` and `"` with no prefix letters — while the offsets this branch needs
    /// `target` to be (`idx + 1…3` of a `<!--`) hold `!`, `-`, `-`. Give HTML a
    /// multi-character or prefixed opener and it becomes live, which is the
    /// reason it is not deleted; nothing in the suite exercises it, and a test
    /// could only reach it by constructing a vocabulary that does not exist.
    private static func isInsideHtmlTag(at target: Int, scan: Scan) -> Bool {
        var cursor = scan.htmlCursor
        if target < cursor.position { cursor = HtmlTagCursor() }
        var idx = cursor.position
        var inTag = cursor.inTag
        var inSingle = cursor.inSingle
        var inDouble = cursor.inDouble
        var clamped: HtmlTagCursor?

        while idx < target {
            let before = HtmlTagCursor(position: idx, inTag: inTag, inSingle: inSingle, inDouble: inDouble)
            scan.countValidatorStep()
            let ch = scan.character(at: idx)
            if isLineSeparator(ch) {
                inSingle = false
                inDouble = false
                idx += 1
                continue
            }
            if inSingle {
                if ch == 39 { inSingle = false } // "'"
                idx += 1
                continue
            }
            if inDouble {
                if ch == 34 { inDouble = false } // '"'
                idx += 1
                continue
            }
            if inTag {
                if ch == 39 {
                    inSingle = true
                } else if ch == 34 {
                    inDouble = true
                } else if ch == 62 { // '>'
                    inTag = false
                }
                idx += 1
                continue
            }
            // Outside tag — skip HTML comments so their `>` does not open.
            if ch == 60, idx + 4 <= scan.length, scan.isMatch(at: idx, pattern: "<!--") {
                guard idx + 4 <= target else {
                    // The `<!--` is cut off by this query's target, so the `<`
                    // opens a tag for *this* answer only.
                    if clamped == nil { clamped = before }
                    inTag = true
                    idx += 1
                    continue
                }
                // Advance to after the next "-->" or to target if unclosed.
                var end = idx + 4
                var closed = false
                while end + 3 <= scan.length, end + 3 <= target {
                    scan.countValidatorStep()
                    if scan.isMatch(at: end, pattern: "-->") {
                        end += 3
                        closed = true
                        break
                    }
                    end += 1
                }
                // Unclosed *within the buffer* is a fact; unclosed only because
                // the target cut the search short is not, so it stops the
                // cursor here rather than teaching it a truncated comment.
                if !closed, end + 3 <= scan.length, clamped == nil { clamped = before }
                idx = min(end, target)
                continue
            }
            if ch == 60 { // '<'
                inTag = true
            }
            idx += 1
        }
        scan.htmlCursor = clamped
            ?? HtmlTagCursor(position: idx, inTag: inTag, inSingle: inSingle, inDouble: inDouble)
        return inTag
    }

    private static func isYamlStringOpen(at idx: Int, scan: Scan) -> Bool {
        if idx == 0 { return true }
        let prev = scan.character(at: idx - 1)
        if (prev >= 65 && prev <= 90) || (prev >= 97 && prev <= 122) || (prev >= 48 && prev <= 57) || prev == 95 || prev == 45 {
            return false
        }
        // YAML quoted scalars start at value position. A bare `:` always
        // introduces a value; `[`/`{` and a bare line-start (after
        // indentation) do as well. Comma and dash are context-sensitive:
        // `,` only in flow context and `-` only as a block-sequence
        // indicator — otherwise `key: say, "hello` or `say - "hello` are
        // plain scalars where the quote is literal and `#` is a comment.
        var pos = idx - 1
        while pos >= 0, isWhitespace(scan.character(at: pos)) { pos -= 1 }
        if pos < 0 { return true }
        if isAfterIndent(at: idx, scan: scan) { return isYamlLineStartValueAllowed(at: idx, scan: scan) }
        let ch = scan.character(at: pos)
        if ch == 58 {
            // ':' is a value indicator only when followed by separation
            // whitespace (space/tab). Without it the colon is literal
            // inside a block plain scalar (e.g. `foo:"bar`).
            if idx == pos + 1 { return false }
            return true
        }
        if ch == 91 || ch == 123 { // '[' '{'
            return isYamlFlowBracketValueOpen(at: pos, scan: scan)
        }
        if ch == 44 {
            // Flow comma: only inside a flow collection (`[…]` / `{…}`).
            // The previous heuristic checked the token before the comma for a
            // quoted-string close, but that rejects valid flow entries like
            // `list: [a, "hel # still"]` where the comma follows a plain
            // scalar or number. Distinguish by scanning for an unclosed flow
            // bracket before the comma instead — outside flow the comma is
            // part of a block plain scalar (`say, "hello`).
            return isInsideYamlFlow(at: pos, scan: scan)
        }
        if ch == 45 {
            // Block sequence dash: only when the dash is the first
            // non-whitespace on the line (indent + '-').
            return isFirstNonWhitespaceOnLine(at: pos, scan: scan)
        }
        return false
    }

    private static func isYamlFlowBracketValueOpen(at bracketPos: Int, scan: Scan) -> Bool {
        // A `[` / `{` only starts a flow value at positions where YAML allows
        // one: after `:`, inside flow after `,`, after another *valid* flow
        // opener, after a block-sequence `-` that is the first non-whitespace
        // on its line, or as the first non-whitespace on the line itself.
        // Otherwise the bracket is literal text inside a block plain scalar
        // (`say [`). The `,` case is flow-depth sensitive, so the check
        // consults the validated depth up to the bracket.
        var scanPos = bracketPos - 1
        while scanPos >= 0, isWhitespace(scan.character(at: scanPos)) { scanPos -= 1 }
        if scanPos < 0 { return true }
        if scanPos < lineStart(before: bracketPos, scan: scan) { return true }
        let prev = scan.character(at: scanPos)
        if prev == 58 {
            if bracketPos == scanPos + 1 { return false }
            return true
        }
        // Depth before this bracket determines whether a preceding ',' or
        // nested '['/'{' is itself inside flow.
        let depthBefore = yamlFlowDepth(upTo: bracketPos, scan: scan)
        if prev == 44 { return depthBefore > 0 } // ',' only inside flow
        if prev == 91 || prev == 123 { return depthBefore > 0 } // '[' '{' only when already in flow
        if prev == 45 {
            return isFirstNonWhitespaceOnLine(at: scanPos, scan: scan)
        }
        return false
    }

    private static func isYamlLineStartValueAllowed(at idx: Int, scan: Scan) -> Bool {
        let start = lineStart(before: idx, scan: scan)
        if start == 0 { return true }
        var prevPos = start - 1
        while prevPos >= 0, isLineSeparator(scan.character(at: prevPos)) { prevPos -= 1 }
        while prevPos >= 0, isWhitespace(scan.character(at: prevPos)) { prevPos -= 1 }
        // Skip trailing comment-only lines.
        while prevPos >= 0 {
            let checkLineStart = lineStart(before: prevPos, scan: scan)
            var firstNonWs = -1
            for point in checkLineStart...prevPos {
                let ch = scan.character(at: point)
                if !isWhitespace(ch), !isLineSeparator(ch) {
                    firstNonWs = point
                    break
                }
            }
            if firstNonWs >= 0, scan.character(at: firstNonWs) == 35, isYamlCommentStart(at: firstNonWs, scan: scan) {
                prevPos = checkLineStart - 1
                while prevPos >= 0, isLineSeparator(scan.character(at: prevPos)) { prevPos -= 1 }
                while prevPos >= 0, isWhitespace(scan.character(at: prevPos)) { prevPos -= 1 }
                continue
            }
            break
        }
        if prevPos < 0 { return true }
        let ch = scan.character(at: prevPos)
        if (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || (ch >= 48 && ch <= 57) || ch == 95 || ch == 45 {
            return false
        }
        return true
    }

    private static func isYamlCommentStart(at idx: Int, scan: Scan) -> Bool {
        if idx == 0 { return true }
        if isAfterIndent(at: idx, scan: scan) { return true }
        let prev = scan.character(at: idx - 1)
        return isWhitespace(prev) || isLineSeparator(prev)
    }

    /// The offset just after the line separator preceding `pos`, or `0`.
    private static func lineStart(before pos: Int, scan: Scan) -> Int {
        var idx = pos - 1
        while idx >= 0 {
            if isLineSeparator(scan.character(at: idx)) { return idx + 1 }
            idx -= 1
        }
        return 0
    }

    /// Whether everything between `pos`'s line start and `pos` is whitespace —
    /// the "indent then indicator" shape a block-sequence `-` must have.
    private static func isFirstNonWhitespaceOnLine(at pos: Int, scan: Scan) -> Bool {
        let start = lineStart(before: pos, scan: scan)
        for point in start..<pos where !isWhitespace(scan.character(at: point)) { return false }
        return true
    }

    private static func isInsideYamlFlow(at commaPos: Int, scan: Scan) -> Bool {
        yamlFlowDepth(upTo: commaPos, scan: scan) > 0
    }

    /// Validated flow depth over `[0, limit)`, resuming the scan's cursor.
    ///
    /// Only brackets that are genuine flow openers contribute. A '['/'{' inside
    /// a block plain scalar (`say [`) is literal and must not inflate depth,
    /// otherwise a later `, "` masquerades as a flow comma and opens an ungated
    /// string inside a real `#` comment (e.g. `key: say [a, "hello # hel`).
    ///
    /// Resumable on the same terms as `isInsideHtmlTag(at:scan:)`: the limits a
    /// scan issues only increase, so the cursor carries (position, depth,
    /// in-single, in-double) forward, and a backwards query — which that
    /// monotonic order never issues — restarts from zero rather than guessing.
    ///
    /// Two decisions here consult `limit`: a `''` escape whose second quote
    /// sits at or past it, and a `#` comment that runs past it. Neither state
    /// is a fact about the buffer, so the cursor stops at the character before
    /// it and this query's answer is finished uncommitted.
    private static func yamlFlowDepth(upTo limit: Int, scan: Scan) -> Int {
        var cursor = scan.yamlCursor
        if limit < cursor.position { cursor = YamlFlowCursor() }
        var idx = cursor.position
        var depth = cursor.depth
        var inSingle = cursor.inSingle
        var inDouble = cursor.inDouble
        var clamped: YamlFlowCursor?

        while idx < limit {
            let before = YamlFlowCursor(position: idx, depth: depth, inSingle: inSingle, inDouble: inDouble)
            scan.countValidatorStep()
            let ch = scan.character(at: idx)
            if isLineSeparator(ch) {
                inSingle = false
                inDouble = false
                idx += 1
                continue
            }
            if inSingle {
                if ch == 39 {
                    if idx + 1 < limit, scan.character(at: idx + 1) == 39 {
                        idx += 2
                        continue
                    }
                    // A `''` whose second quote sits at or past the limit reads
                    // as a close for this query and as an escape for a longer
                    // one, so the cursor must not learn it.
                    if idx + 1 < scan.length, scan.character(at: idx + 1) == 39, clamped == nil {
                        clamped = before
                    }
                    inSingle = false
                }
                idx += 1
                continue
            }
            if inDouble {
                if ch == 92 {
                    idx += 2
                    continue
                }
                if ch == 34 {
                    inDouble = false
                }
                idx += 1
                continue
            }
            if ch == 35, isYamlCommentStart(at: idx, scan: scan) {
                idx += 1
                while idx < limit, !isLineSeparator(scan.character(at: idx)) {
                    scan.countValidatorStep()
                    idx += 1
                }
                // The comment ran past the limit: for a longer query it keeps
                // running, so this position is not a state worth remembering.
                if idx >= limit, limit < scan.length, clamped == nil { clamped = before }
                continue
            }
            if ch == 39 {
                inSingle = true
            } else if ch == 34 {
                inDouble = true
            } else if ch == 91 || ch == 123 {
                if isValidYamlFlowOpener(at: idx, scan: scan, depthBefore: depth) {
                    depth += 1
                }
            } else if ch == 93 || ch == 125 {
                if depth > 0 { depth -= 1 }
            }
            idx += 1
        }
        scan.yamlCursor = clamped
            ?? YamlFlowCursor(position: idx, depth: depth, inSingle: inSingle, inDouble: inDouble)
        return depth
    }

    private static func isValidYamlFlowOpener(at pos: Int, scan: Scan, depthBefore: Int) -> Bool {
        var scanPos = pos - 1
        while scanPos >= 0, isWhitespace(scan.character(at: scanPos)) { scanPos -= 1 }
        if scanPos < 0 { return true }
        if scanPos < lineStart(before: pos, scan: scan) { return true }
        let prev = scan.character(at: scanPos)
        if prev == 58 {
            if pos == scanPos + 1 { return false }
            return true
        }
        if prev == 44 { return depthBefore > 0 }
        if prev == 91 || prev == 123 { return depthBefore > 0 }
        if prev == 45 {
            return isFirstNonWhitespaceOnLine(at: scanPos, scan: scan)
        }
        return false
    }

    private static func isJsonStringOpen(at idx: Int, scan: Scan) -> Bool {
        if idx == 0 { return true }
        let prev = scan.character(at: idx - 1)
        if (prev >= 65 && prev <= 90) || (prev >= 97 && prev <= 122) || (prev >= 48 && prev <= 57) || prev == 95 || prev == 45 {
            return false
        }
        var pos = idx - 1
        while pos >= 0, isWhitespace(scan.character(at: pos)) { pos -= 1 }
        if pos < 0 { return true }
        if isAfterIndent(at: idx, scan: scan) { return true }
        let ch = scan.character(at: pos)
        return ch == 58 || ch == 44 || ch == 91 || ch == 123 // ':', ',', '[', '{'
    }

    private static func isDotenvStringOpen(at idx: Int, scan: Scan) -> Bool {
        if idx == 0 { return true }
        let prev = scan.character(at: idx - 1)
        if (prev >= 65 && prev <= 90) || (prev >= 97 && prev <= 122) || (prev >= 48 && prev <= 57) || prev == 95 || prev == 45 {
            return false
        }
        var pos = idx - 1
        while pos >= 0, isWhitespace(scan.character(at: pos)) { pos -= 1 }
        if pos < 0 { return false }
        return scan.character(at: pos) == 61 // '='
    }
}
