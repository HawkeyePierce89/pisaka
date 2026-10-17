import Foundation

/// Expand / Shrink Selection's decisions: which ranges an expansion steps
/// through, and which one comes next. Pure, Foundation-only, `NSString`/UTF-16
/// like every other editor engine.
///
/// The app reads the syntax tree — the chain of *named* nodes enclosing the
/// selection, innermost first — and hands their ranges here as plain
/// `NSRange`s; this rule never sees a tree. A language with no grammar gets
/// `fallbackCandidates`, built from the text alone.
///
/// The candidate list is an ordered ladder, not a set of nested ranges:
/// `next` takes the first rung that strictly contains the current selection,
/// so a rung equal to the selection (an identifier node after the word step,
/// a node equal to its parent) or one that does not contain it is passed over
/// rather than special-cased where the list is built.
public enum SelectionExpansionRule {

    /// The ordered candidates for expanding `selection`:
    ///
    /// 1. **The word** — the identifier, by `IdentifierScanner`'s
    ///    language-aware rule, that the selection lies within. Outside string
    ///    content only the character the selection starts *on* counts, so a
    ///    caret on punctuation (including the `(` right after a name) gets no
    ///    word step and goes straight to its node. Inside string content —
    ///    `stringContent`, where the tree has no node smaller than the whole
    ///    literal — the word step is always tried, and a caret just past a word
    ///    takes that word, the keyboard's probe.
    /// 2. **Each named ancestor**, innermost first. When an ancestor's first and
    ///    last characters are one bracket pair (`()`, `[]`, `{}`), its inner
    ///    contents come immediately before it, so `f(a, b)` offers `a, b`
    ///    before `(a, b)`. Empty contents are not a rung.
    /// 3. **The line** (or lines) holding the selection, without its
    ///    terminator.
    /// 4. **The document.**
    ///
    /// Duplicate ranges are dropped, keeping the first. Ancestor ranges outside
    /// the text are dropped rather than trusted.
    public static func candidates(
        text: NSString,
        selection: NSRange,
        language: SyntaxLanguage?,
        ancestors: [NSRange],
        stringContent: Bool
    ) -> [NSRange] {
        var result: [NSRange] = []
        if let word = word(text: text, selection: selection, language: language, stringContent: stringContent) {
            result.append(word)
        }
        for ancestor in ancestors where isInside(ancestor, text: text) {
            if let contents = bracketContents(of: ancestor, in: text) {
                result.append(contents)
            }
            result.append(ancestor)
        }
        appendLineAndDocument(to: &result, text: text, selection: selection)
        return deduplicated(result)
    }

    /// The candidates for a language with no grammar: the word, then each
    /// enclosing bracket pair outward — its contents, then the pair itself —
    /// by `BracketMatchEngine.enclosingPair`, then the line, then the document.
    ///
    /// The pairs are raw characters with no string or comment awareness, the
    /// boundary the bracket engine draws everywhere.
    public static func fallbackCandidates(
        text: NSString,
        selection: NSRange,
        language: SyntaxLanguage?
    ) -> [NSRange] {
        var result: [NSRange] = []
        if let word = word(text: text, selection: selection, language: language, stringContent: false) {
            result.append(word)
        }
        if isInside(selection, text: text) {
            var around = selection
            while let pair = BracketMatchEngine.enclosingPair(text: text, around: around) {
                let whole = NSRange(location: pair.open.location, length: NSMaxRange(pair.close) - pair.open.location)
                if let contents = bracketContents(of: whole, in: text) {
                    result.append(contents)
                }
                result.append(whole)
                around = whole
            }
        }
        appendLineAndDocument(to: &result, text: text, selection: selection)
        return deduplicated(result)
    }

    /// The first candidate that strictly contains `selection` — contains it
    /// and is not equal to it — or `nil` when the ladder has no further rung.
    public static func next(selection: NSRange, candidates: [NSRange]) -> NSRange? {
        candidates.first { candidate in
            candidate != selection
                && candidate.location <= selection.location
                && NSMaxRange(candidate) >= NSMaxRange(selection)
        }
    }

    // MARK: - Rungs

    private static func word(
        text: NSString,
        selection: NSRange,
        language: SyntaxLanguage?,
        stringContent: Bool
    ) -> NSRange? {
        guard isInside(selection, text: text) else { return nil }
        let match = stringContent
            ? IdentifierScanner.identifier(in: text, at: selection.location, language: language)
            : IdentifierScanner.identifier(in: text, containing: selection.location, language: language)
        guard let range = match?.range,
              range.location <= selection.location,
              NSMaxRange(range) >= NSMaxRange(selection) else { return nil }
        return range
    }

    /// The inside of `range` when its first and last characters are one
    /// bracket pair and something sits between them.
    private static func bracketContents(of range: NSRange, in text: NSString) -> NSRange? {
        guard range.length > 2 else { return nil }
        let first = text.character(at: range.location)
        let last = text.character(at: NSMaxRange(range) - 1)
        guard let opener = UnicodeScalar(first).map(Character.init),
              let closer = UnicodeScalar(last).map(Character.init),
              BracketMatchEngine.openerToCloser[opener] == closer else { return nil }
        return NSRange(location: range.location + 1, length: range.length - 2)
    }

    private static func appendLineAndDocument(to result: inout [NSRange], text: NSString, selection: NSRange) {
        if isInside(selection, text: text) {
            result.append(lineWithoutTerminator(text: text, selection: selection))
        }
        result.append(NSRange(location: 0, length: text.length))
    }

    /// `lineRange(for:)` with the trailing separator trimmed — the same
    /// LF/CR/CRLF/NEL/LS/PS set `LineStartIndex` splits on.
    private static func lineWithoutTerminator(text: NSString, selection: NSRange) -> NSRange {
        let line = text.lineRange(for: selection)
        var end = NSMaxRange(line)
        while end > line.location, LineStartIndex.isLineSeparator(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func isInside(_ range: NSRange, text: NSString) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0
            && NSMaxRange(range) <= text.length
    }

    private static func deduplicated(_ ranges: [NSRange]) -> [NSRange] {
        var seen: [NSRange] = []
        for range in ranges where !seen.contains(range) {
            seen.append(range)
        }
        return seen
    }
}

/// The selections Expand Selection stepped away from, so Shrink Selection can
/// walk back along exactly the same path. The editor pushes the selection it
/// is about to replace on each expansion, pops on each shrink, and resets on
/// any selection change it did not make itself and on any edit.
public struct SelectionExpansionHistory: Equatable {
    private var stack: [NSRange] = []

    public init() {}

    /// Whether there is anything to shrink back to.
    public var isEmpty: Bool { stack.isEmpty }

    /// Record `selection` as the step an expansion is leaving.
    public mutating func push(_ selection: NSRange) {
        stack.append(selection)
    }

    /// The selection the last expansion left, removed from the history, or
    /// `nil` when there is none — Shrink then has nothing to do.
    public mutating func pop() -> NSRange? {
        stack.popLast()
    }

    /// Forget every step.
    public mutating func reset() {
        stack.removeAll()
    }
}
