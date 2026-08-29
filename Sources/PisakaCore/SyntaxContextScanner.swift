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
        return scan(text: text, upTo: offset, language: language)
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

    // MARK: - Scanning

    private static func scan(text: NSString, upTo offset: Int, language: SyntaxLanguage) -> SyntaxContext {
        let vocab = SyntaxContextVocabulary.vocabulary(for: language)
        var stack: [Frame] = []
        var idx = 0

        // Chunked bulk-read following BracketDepthScanner's pattern.
        // The loop is sequential; look-aheads use direct character(at:) so
        // delimiters straddling a chunk boundary are not missed.
        let length = text.length
        var buffer = [unichar](repeating: 0, count: min(chunkSize, max(length, 1)))
        var chunkStart = 0
        var chunkCount = 0
        if length > 0 {
            chunkCount = min(chunkSize, length)
            text.getCharacters(buffer.withUnsafeMutableBufferPointer { $0.baseAddress! },
                               range: NSRange(location: 0, length: chunkCount))
        }

        func charAt(_ pos: Int) -> unichar? {
            guard pos >= 0, pos < length else { return nil }
            if pos >= chunkStart, pos < chunkStart + chunkCount {
                return buffer[pos - chunkStart]
            }
            // Fall back to direct access for look-ahead beyond current chunk.
            return text.character(at: pos)
        }

        func ensureChunk(for pos: Int) {
            guard pos >= 0, pos < length else { return }
            if pos >= chunkStart, pos < chunkStart + chunkCount { return }
            chunkStart = (pos / chunkSize) * chunkSize
            chunkCount = min(chunkSize, length - chunkStart)
            text.getCharacters(buffer.withUnsafeMutableBufferPointer { $0.baseAddress! },
                               range: NSRange(location: chunkStart, length: chunkCount))
        }

        while idx < offset {
            ensureChunk(for: idx)
            let ch = charAt(idx) ?? 0
            let top = stack.last
            let next: Int
            switch top {
            case .none:
                next = advanceCode(at: idx, offset: offset, text: text, vocab: vocab, stack: &stack)
            case .some(.lineComment):
                next = advanceLineComment(at: idx, ch: ch, stack: &stack)
            case .some(.blockComment):
                next = advanceBlockComment(at: idx, offset: offset, text: text, stack: &stack)
            case .some(.string):
                next = advanceString(at: idx, offset: offset, text: text, ch: ch, stack: &stack)
            case .some(.hole):
                next = advanceHole(at: idx, offset: offset, text: text, vocab: vocab, stack: &stack)
            }
            idx = next
        }

        // Determine context from final stack
        if let top = stack.last {
            switch top {
            case .string: return .string
            case .lineComment, .blockComment: return .comment
            case .hole: return .code
            }
        }
        return .code
    }

    // MARK: - State helpers

    private static func advanceCode(
        at idx: Int, offset: Int, text: NSString,
        vocab: SyntaxContextVocabulary.Vocabulary, stack: inout [Frame]
    ) -> Int {
        if let m = stringMatch(at: idx, text: text, forms: vocab.stringForms),
           idx + m.totalLen <= offset {
            stack.append(.string(form: m.form, pound: m.pound, isRaw: m.isRaw, hasF: m.hasF))
            return idx + m.totalLen
        }
        if let c = commentMatch(at: idx, text: text, forms: vocab.commentForms),
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
        at idx: Int, offset: Int, text: NSString, stack: inout [Frame]
    ) -> Int {
        guard case .blockComment(let open, let close, let nestable, let depth) = stack.last else {
            return idx + 1
        }
        if nestable, isMatch(at: idx, pattern: open, text: text),
           idx + open.utf16.count <= offset {
            stack[stack.count - 1] = .blockComment(open: open, close: close, nestable: nestable, depth: depth + 1)
            return idx + open.utf16.count
        }
        if isMatch(at: idx, pattern: close, text: text), idx + close.utf16.count <= offset {
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
        at idx: Int, offset: Int, text: NSString, ch: unichar, stack: inout [Frame]
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
           isMatch(at: idx, pattern: "{{", text: text) || isMatch(at: idx, pattern: "}}", text: text) {
            return idx + 2
        }
        if let holeLen = holeOpenLength(at: idx, text: text, form: form, pound: pound, hasF: hasF),
           let kind = holeKind(for: form), idx + holeLen <= offset {
            stack.append(.hole(kind: kind, depth: 0, pound: pound))
            return idx + holeLen
        }
        if form.escape == .doubledDelimiter {
            let closeWithPound = form.close + String(repeating: "#", count: pound)
            if idx + closeWithPound.utf16.count * 2 <= offset,
               isMatch(at: idx, pattern: closeWithPound + closeWithPound, text: text) {
                return idx + closeWithPound.utf16.count * 2
            }
        }
        if form.escape == .backslash, !isRaw,
           let escLen = backslashEscapeLength(at: idx, text: text, pound: pound, allowsPound: form.allowsPoundPadding),
           idx + escLen <= offset {
            return idx + escLen
        }
        let closeDelim = form.close + String(repeating: "#", count: pound)
        if idx + closeDelim.utf16.count <= offset, isMatch(at: idx, pattern: closeDelim, text: text) {
            stack.removeLast()
            return idx + closeDelim.utf16.count
        }
        return idx + 1
    }

    private static func advanceHole(
        at idx: Int, offset: Int, text: NSString,
        vocab: SyntaxContextVocabulary.Vocabulary, stack: inout [Frame]
    ) -> Int {
        guard case .hole(let kind, let depth, let pound) = stack.last else {
            return idx + 1
        }
        if idx + 1 <= offset, isHoleClose(at: idx, text: text, kind: kind, depth: depth) {
            if depth == 0 {
                stack.removeLast()
            } else {
                stack[stack.count - 1] = .hole(kind: kind, depth: depth - 1, pound: pound)
            }
            return idx + 1
        }
        if idx + 1 <= offset, isHoleNestedOpen(at: idx, text: text, kind: kind) {
            stack[stack.count - 1] = .hole(kind: kind, depth: depth + 1, pound: pound)
            return idx + 1
        }
        if let m = stringMatch(at: idx, text: text, forms: vocab.stringForms), idx + m.totalLen <= offset {
            stack.append(.string(form: m.form, pound: m.pound, isRaw: m.isRaw, hasF: m.hasF))
            return idx + m.totalLen
        }
        if let c = commentMatch(at: idx, text: text, forms: vocab.commentForms), idx + c.len <= offset {
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

    private static func isMatch(at idx: Int, pattern: String, text: NSString) -> Bool {
        let plen = pattern.utf16.count
        guard idx >= 0, idx + plen <= text.length else { return false }
        let pat = pattern as NSString
        for i in 0..<plen where text.character(at: idx + i) != pat.character(at: i) { return false }
        return true
    }

    private struct StringMatch {
        let form: SyntaxContextVocabulary.StringForm
        let pound: Int
        let isRaw: Bool
        let hasF: Bool
        let totalLen: Int
    }

    private static func stringMatch(at idx: Int, text: NSString, forms: [SyntaxContextVocabulary.StringForm]) -> StringMatch? {
        // Try longest open first
        let sorted = forms.sorted { $0.open.utf16.count > $1.open.utf16.count }
        var best: StringMatch?
        for form in sorted {
            if let m = matchForm(form, at: idx, text: text) {
                if best == nil || m.totalLen > best!.totalLen {
                    best = m
                }
            }
        }
        return best
    }

    private static func matchForm(_ form: SyntaxContextVocabulary.StringForm, at idx: Int, text: NSString) -> StringMatch? {
        var pos = idx
        var isRaw = false
        var hasF = false
        var pound = 0
        // Prefix letters
        if let allowed = form.allowedPrefixLetters {
            var consumed = 0
            var tmpHasF = false
            var tmpIsRaw = false
            while pos < text.length, consumed < 4 {
                let ch = text.character(at: pos)
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
            while pos < text.length, text.character(at: pos) == 35 { // '#'
                pound += 1
                pos += 1
                if pound > 10 { break }
            }
        }
        guard isMatch(at: pos, pattern: form.open, text: text) else { return nil }
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

    private static func commentMatch(at idx: Int, text: NSString, forms: [SyntaxContextVocabulary.CommentForm]) -> CommentMatch? {
        for form in forms {
            switch form {
            case .line(let token, let anchor):
                guard isMatch(at: idx, pattern: token, text: text) else { continue }
                guard isAnchorSatisfied(anchor, at: idx, text: text) else { continue }
                return CommentMatch(form: form, len: token.utf16.count)
            case .block(let open, _, _):
                guard isMatch(at: idx, pattern: open, text: text) else { continue }
                // Block comments are not anchored
                return CommentMatch(form: form, len: open.utf16.count)
            }
        }
        return nil
    }

    private static func isAnchorSatisfied(_ anchor: SyntaxContextVocabulary.LineAnchor, at idx: Int, text: NSString) -> Bool {
        switch anchor {
        case .anywhere:
            return true
        case .lineStart:
            return isAtLineStart(at: idx, text: text)
        case .afterWhitespace:
            if isAtLineStart(at: idx, text: text) { return true }
            guard idx > 0 else { return true }
            let prev = text.character(at: idx - 1)
            return isWhitespace(prev) || isLineSeparator(prev)
        }
    }

    private static func isAtLineStart(at idx: Int, text: NSString) -> Bool {
        if idx == 0 { return true }
        // Find last line separator before idx
        var lineStart = 0
        var i = idx - 1
        while i >= 0 {
            if isLineSeparator(text.character(at: i)) {
                lineStart = i + 1
                break
            }
            i -= 1
        }
        // Check from lineStart to idx-1 all whitespace
        for p in lineStart..<idx {
            let c = text.character(at: p)
            if !isWhitespace(c) { return false }
        }
        return true
    }

    private static func holeKind(for form: SyntaxContextVocabulary.StringForm) -> SyntaxContextVocabulary.InterpolationHole? {
        form.hole
    }

    private static func holeOpenLength(
        at idx: Int, text: NSString,
        form: SyntaxContextVocabulary.StringForm, pound: Int, hasF: Bool
    ) -> Int? {
        guard let hole = form.hole else { return nil }
        switch hole {
        case .jsTemplate:
            guard isMatch(at: idx, pattern: "${", text: text) else { return nil }
            return 2
        case .swiftInterpolation:
            // \ + pound * # + (
            guard text.character(at: idx) == 92 else { return nil } // '\'
            var pos = idx + 1
            for _ in 0..<pound {
                guard pos < text.length, text.character(at: pos) == 35 else { return nil }
                pos += 1
            }
            guard pos < text.length, text.character(at: pos) == 40 else { return nil } // '('
            return 1 + pound + 1
        case .pythonFString:
            guard hasF else { return nil }
            guard idx < text.length, text.character(at: idx) == 123 else { return nil } // '{'
            // {{ is literal, not hole
            if idx + 1 < text.length, text.character(at: idx + 1) == 123 { return nil }
            // Also avoid '{' that is part of '}}' previously handled
            return 1
        }
    }

    private static func backslashEscapeLength(
        at idx: Int, text: NSString, pound: Int, allowsPound: Bool
    ) -> Int? {
        guard idx < text.length, text.character(at: idx) == 92 else { return nil } // '\'
        if allowsPound {
            var pos = idx + 1
            for _ in 0..<pound {
                guard pos < text.length, text.character(at: pos) == 35 else { return nil }
                pos += 1
            }
            guard pos < text.length else { return nil }
            return 1 + pound + 1
        } else {
            guard idx + 1 < text.length else { return nil }
            return 2
        }
    }

    private static func isHoleClose(at idx: Int, text: NSString, kind: SyntaxContextVocabulary.InterpolationHole, depth: Int) -> Bool {
        guard idx < text.length else { return false }
        let ch = text.character(at: idx)
        switch kind {
        case .jsTemplate, .pythonFString:
            return ch == 125 // '}'
        case .swiftInterpolation:
            return ch == 41 // ')'
        }
    }

    private static func isHoleNestedOpen(at idx: Int, text: NSString, kind: SyntaxContextVocabulary.InterpolationHole) -> Bool {
        guard idx < text.length else { return false }
        let ch = text.character(at: idx)
        switch kind {
        case .jsTemplate, .pythonFString:
            return ch == 123 // '{'
        case .swiftInterpolation:
            return ch == 40 // '('
        }
    }
}
