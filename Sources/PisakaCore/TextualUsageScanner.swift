import Foundation

/// The honest half of Find Usages: every place one text spells an identifier as
/// a **whole word**.
///
/// This is what answers when no language server serves the language — or when
/// the one that does has nothing to say. It knows nothing about scope, imports
/// or types, so what it finds are *occurrences of a name*, and the panel says so
/// (`UsageProvenance.textual`). The alternative was to answer nothing at all,
/// which for the languages this editor supports without a server would make the
/// command a menu item that never works.
///
/// **The boundary rule is not restated here.** A candidate substring is a usage
/// exactly when `IdentifierScanner.identifier(in:at:)` — the same call a
/// ⌘-click makes — resolves *that* range to *that* text at the candidate's own
/// start offset. So `foo` is found in `foo.bar` and `foo(1)` but not inside
/// `foobar`, `_foo` or `foo_`, and a Unicode name (`имя`, `número`) works because
/// the scanner's classification is Unicode-based rather than ASCII. The one
/// consequence worth naming out loud is the scanner's trim rule, inherited whole:
/// a run that *starts* with digits is not an identifier, so `123foo` reports
/// `foo` — exactly as ⌘-clicking that `f` would resolve `foo`. Delegating means
/// inheriting the surprises too, which is cheaper than two rules that agree
/// almost always. Asking the
/// existing rule instead of re-deriving one from
/// `isIdentifierStart`/`isIdentifierContinuation` is deliberate: a second
/// spelling of "where does a word end" could drift from the one that decides
/// what ⌘-click and completion see, and the whole value of a textual answer is
/// that the words it lists are the words the editor itself recognizes.
///
/// A regular expression was the other candidate and is the wrong tool twice
/// over: an identifier may contain characters a pattern would have to escape,
/// and `\b` is ASCII-shaped in a way that would quietly disagree with the
/// scanner about every non-ASCII name.
///
/// Pure, Foundation-only and `NSString`/UTF-16 like every other editor engine,
/// so a range it returns can be handed straight to the text view.
public enum TextualUsageScanner {

    /// One whole-word occurrence: where it is, which line the gutter would print
    /// beside it, and the single line the panel row shows.
    public struct Match: Equatable, Sendable {
        /// UTF-16 range of the occurrence in the scanned text.
        public let range: NSRange
        /// 1-based display line, counted with the editor's own separators
        /// (`LineStartIndex`), so the number in the row is the number in the
        /// gutter — including for the separators the protocol does not know
        /// about (NEL/LS/PS) and for CRLF, which is one break.
        public let line: Int
        /// The clipped line the row draws, with the occurrence inside it —
        /// `ProjectSearchModel.preview`, so a usages row and a Find in Files row
        /// read alike and clip alike (a minified bundle's single 200 KB line must
        /// not become a 200 KB row).
        public let preview: MatchPreview

        public init(range: NSRange, line: Int, preview: MatchPreview) {
            self.range = range
            self.line = line
            self.preview = preview
        }
    }

    /// Every whole-word occurrence of `identifier` in `text`, in ascending
    /// order.
    ///
    /// Answers `[]` — never a partial or approximate list — for a query that is
    /// not one identifier: empty, or anything `IdentifierScanner.isIdentifier(_:)`
    /// refuses (`run(_:)`, `.btn-primary`, `9foo`, a phrase with a space). Such a
    /// query cannot occur as a word by construction, so scanning for it would be
    /// spending a project walk to find nothing; and taking it as a plain
    /// substring search would silently turn this command into a different one.
    ///
    /// Matching is `.literal` — exact UTF-16 units, no canonical equivalence —
    /// because the ranges are handed to a text view: a match found by folding a
    /// decomposed accent into a precomposed one would name a span of a different
    /// length than the identifier the caller asked about.
    public static func matches(of identifier: String, in text: NSString) -> [Match] {
        guard IdentifierScanner.isIdentifier(identifier), text.length > 0 else { return [] }

        let needle = identifier as NSString
        guard needle.length <= text.length else { return [] }

        // **The ranges first, the line index only if there are any**
        // (`TextSearchEngine.matches`'s rule, and for a sharper reason here). The
        // index is a full pass over the text, and this scanner is run against
        // *every file the project walk yields* — the overwhelming majority of
        // which contain the name nowhere. Building it up front would make the
        // textual answer, which is the only answer for every language without a
        // server, read each of those files twice to report nothing.
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart <= text.length - needle.length {
            let remaining = NSRange(location: searchStart, length: text.length - searchStart)
            let found = text.range(of: identifier, options: .literal, range: remaining)
            guard found.location != NSNotFound else { break }

            if isWholeWord(found, of: identifier, in: text) {
                ranges.append(found)
            }
            // Advance past this occurrence rather than past its start: identifiers
            // cannot overlap themselves as whole words, and stepping one unit
            // would rescan the same name once per character of it.
            searchStart = NSMaxRange(found)
        }
        guard !ranges.isEmpty else { return [] }

        let lineStarts = LineStartIndex.offsets(in: text)
        return ranges.map { found in
            let line = TextSearchEngine.lineNumber(forOffset: found.location, in: lineStarts)
            return Match(
                range: found,
                line: line,
                preview: ProjectSearchModel.preview(
                    for: SearchMatch(range: found, lineNumber: line),
                    in: text
                )
            )
        }
    }

    /// Whether the occupied range really is a standalone word — the one question
    /// this file asks, delegated whole to the scanner that owns the answer.
    private static func isWholeWord(_ range: NSRange, of identifier: String, in text: NSString) -> Bool {
        guard let word = IdentifierScanner.identifier(in: text, at: range.location) else { return false }
        return word.range == range && word.text == identifier
    }
}
