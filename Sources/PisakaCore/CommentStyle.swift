import Foundation

/// The syntactic shape of a comment in a programming language.
///
/// One style is assigned per language. The set of languages is closed, and
/// every language must either explicitly carry a style or explicitly declare
/// it has none (via `languagesWithoutComments`), so a new language added to
/// `SyntaxLanguage` forces a deliberate decision.
public enum CommentStyle: Equatable {
    /// A comment that runs from the token to the end of the line.
    case line(String)

    /// A comment that wraps a span of text in opening and closing delimiters.
    case block(open: String, close: String)

    /// Returns the comment style for the given language, or `nil` if the
    /// language has no comment syntax.
    public static func style(for language: SyntaxLanguage) -> CommentStyle? {
        if languagesWithoutComments.contains(language) {
            return nil
        }

        switch language {
        case .swift, .javascript, .typescript, .go, .rust:
            return .line("//")
        case .python, .yaml, .dockerfile, .dotenv, .gitignore:
            return .line("#")
        case .sql:
            return .line("--")
        case .css:
            return .block(open: "/*", close: "*/")
        case .html:
            return .block(open: "<!--", close: "-->")
        case .json, .markdown:
            // Handled by languagesWithoutComments above, but the compiler
            // requires the switch to be exhaustive.
            return nil
        }
    }

    /// The languages that have no comment syntax to toggle.
    ///
    /// Toggling a comment in these languages is a silent no-op. The absence
    /// is recorded explicitly so the union of this set and the styled languages
    /// exactly covers `SyntaxLanguage.allCases`.
    public static let languagesWithoutComments: Set<SyntaxLanguage> = [
        .json, .markdown
    ]
}
