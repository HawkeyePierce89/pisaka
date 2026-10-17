import Foundation

/// Which occurrence highlight a selection asks for: the identifier's
/// occurrences (R2), the selected string's other exact matches (R3), or none.
///
/// One decision, made once per settle, so the two highlights can never both
/// paint: a selection that is exactly one identifier is the identifier's
/// question and never also a string match, and a caret is only ever the
/// identifier's.
///
/// Pure, Foundation-only, `NSString`/UTF-16 like every other editor engine.
public enum OccurrenceHighlightRule {

    /// What the settled selection asks to have highlighted.
    public enum Mode: Equatable, Sendable {
        /// The identifier the caret is in or touching, or that the selection
        /// covers exactly.
        case identifier(IdentifierScanner.Match)
        /// The selected text itself, matched literally.
        case selectionMatch(String)
        case none
    }

    /// The most selection matches that are painted. Past this many — the
    /// selection included — the answer is empty, not the first fifty: a
    /// selection that common (`= `, `()`) is noise across the file, and a
    /// truncated set would paint the top of the file and not the rest.
    public static let selectionMatchCap = 50

    /// The mode for `selection` in `text`.
    ///
    /// - **Identifier:** an empty selection (a caret) in or touching an
    ///   identifier — `IdentifierScanner.identifier(in:at:)`'s two probes, so the
    ///   caret just past `name|` counts — or a selection equal to exactly one
    ///   identifier.
    /// - **Selection match:** any other non-empty selection that lies within
    ///   one line (no `LineStartIndex` separator inside it), is at least two
    ///   UTF-16 units long and is not all whitespace.
    /// - **None:** anything else, including a selection out of the text.
    public static func mode(text: NSString, selection: NSRange, language: SyntaxLanguage?) -> Mode {
        guard selection.location != NSNotFound,
              selection.location >= 0,
              NSMaxRange(selection) <= text.length else { return .none }

        if selection.length == 0 {
            return IdentifierScanner.identifier(in: text, at: selection.location, language: language)
                .map(Mode.identifier) ?? .none
        }
        if let word = IdentifierScanner.identifier(in: text, containing: selection.location, language: language),
           word.range == selection {
            return .identifier(word)
        }

        guard selection.length >= 2 else { return .none }
        for index in selection.location..<NSMaxRange(selection)
        where LineStartIndex.isLineSeparator(text.character(at: index)) {
            return .none
        }
        let selected = text.substring(with: selection)
        guard !selected.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) else { return .none }
        return .selectionMatch(selected)
    }

    /// The selection matches to paint for `selected`: every exact match,
    /// itself included, or `[]` past `selectionMatchCap`; `nil` when the scan's
    /// budget ran out.
    public static func selectionMatches(
        of selected: String,
        in text: NSString,
        budget: Int = OccurrenceScan.maximumWorkUnits
    ) -> [NSRange]? {
        guard let matches = OccurrenceScan.exactMatches(
            of: selected, in: text, budget: budget, limit: selectionMatchCap + 1
        ) else { return nil }
        return matches.count > selectionMatchCap ? [] : matches
    }
}
