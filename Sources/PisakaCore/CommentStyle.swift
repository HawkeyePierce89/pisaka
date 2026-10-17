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
        switch language {
        case .swift, .javascript, .typescript, .tsx, .go, .rust:
            return .line("//")
        case .python, .yaml, .dockerfile, .dotenv, .gitignore, .shell, .make:
            return .line("#")
        case .editorconfig:
            // The format accepts `;` too, but `#` is the spec's primary line comment.
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

    /// The comment style for `language` in `context`: JSX children in
    /// javascript, typescript or tsx comment as `{/* … */}`, because `//` there
    /// is text the page renders, not a comment. Every other pairing answers
    /// `style(for:)`, so this stays the single table.
    public static func style(for language: SyntaxLanguage, context: CommentContext) -> CommentStyle? {
        switch (language, context) {
        case (.javascript, .jsxChildren), (.typescript, .jsxChildren), (.tsx, .jsxChildren):
            return .block(open: "{/*", close: "*/}")
        default:
            return style(for: language)
        }
    }

    /// Where a line sits, read off the syntax-tree ancestors enclosing its
    /// first non-whitespace offset, **innermost first**. `startsAtLineOffset`
    /// is true when the node starts exactly at that offset: ancestor kinds alone
    /// cannot tell a child line (`<span>` opening the line) from a continuation
    /// line inside a multi-line opening tag (`/>` closing it), so the flag is
    /// part of the input.
    ///
    /// The first listed kind met decides:
    /// - `jsx_attribute` answers `.code` — the line is inside an attribute;
    /// - `jsx_expression` that does **not** start at the line offset answers
    ///   `.code` — the line is inside `{…}`; one that does is a child of its
    ///   parent like an element is, answering `.jsxChildren` only when that
    ///   parent is a `jsx_element`. That is what lets ⌘/ undo its own wrap: a
    ///   commented child line `{/* … */}` parses as a `jsx_expression` holding
    ///   the comment, and `//` in front of any child `{…}` would be rendered
    ///   text;
    /// - `jsx_text` answers `.jsxChildren`;
    /// - `jsx_element`, `jsx_self_closing_element`, `jsx_opening_element` or
    ///   `jsx_closing_element` that does **not** start at the line offset
    ///   answers `.code`, because the line is inside a tag; one that does
    ///   answers `.jsxChildren` only when its element — the node itself, or for
    ///   an opening/closing element the `jsx_element` it belongs to — has a
    ///   `jsx_element` parent, and `.code` otherwise (the root element of a
    ///   `return (…)` is code);
    /// - unlisted kinds are skipped and the walk continues;
    /// - reaching the root answers `.code`.
    ///
    /// There is no `jsx_fragment` case: the pinned TSX grammar has no such
    /// node, and a fragment `<>…</>` is a `jsx_element` whose opening element
    /// has no name, so its children are answered by the element rule.
    public static func context(ancestors: [(kind: String, startsAtLineOffset: Bool)]) -> CommentContext {
        for (index, ancestor) in ancestors.enumerated() {
            switch ancestor.kind {
            case "jsx_attribute":
                return .code
            case "jsx_expression":
                guard ancestor.startsAtLineOffset, index + 1 < ancestors.count else { return .code }
                return ancestors[index + 1].kind == "jsx_element" ? .jsxChildren : .code
            case "jsx_text":
                return .jsxChildren
            case "jsx_element", "jsx_self_closing_element", "jsx_opening_element", "jsx_closing_element":
                guard ancestor.startsAtLineOffset else { return .code }
                let isTag = ancestor.kind == "jsx_opening_element" || ancestor.kind == "jsx_closing_element"
                var elementIndex = index
                if isTag {
                    guard index + 1 < ancestors.count, ancestors[index + 1].kind == "jsx_element" else { return .code }
                    elementIndex = index + 1
                }
                let parentIndex = elementIndex + 1
                guard parentIndex < ancestors.count else { return .code }
                return ancestors[parentIndex].kind == "jsx_element" ? .jsxChildren : .code
            default:
                continue
            }
        }
        return .code
    }

    /// The delimiters Toggle Block Comment (⌥⌘/) wraps a selection in, or
    /// `nil` for a language with no block comment syntax: `/* */` for the
    /// C-family languages and css, `<!-- -->` for html, and `{/* */}` in JSX
    /// children of javascript, typescript or tsx — where `/* */` would be text
    /// the page renders.
    ///
    /// A table of its own rather than read off `style(for:)`, which names the
    /// *line* style where a language has both.
    public static func blockDelimiters(
        for language: SyntaxLanguage, context: CommentContext
    ) -> BlockCommentDelimiters? {
        switch language {
        case .javascript, .typescript, .tsx:
            return context == .jsxChildren
                ? BlockCommentDelimiters(open: "{/*", close: "*/}")
                : BlockCommentDelimiters(open: "/*", close: "*/")
        case .swift, .go, .rust, .css:
            return BlockCommentDelimiters(open: "/*", close: "*/")
        case .html:
            return BlockCommentDelimiters(open: "<!--", close: "-->")
        case .json, .markdown, .python, .yaml, .dockerfile, .dotenv, .gitignore,
             .shell, .make, .editorconfig, .sql:
            return nil
        }
    }

    /// The languages `blockDelimiters(for:context:)` answers. Closed, and with
    /// `languagesWithoutBlockComments` a partition of `SyntaxLanguage.allCases`,
    /// pinned by set equality.
    public static let languagesWithBlockComments: Set<SyntaxLanguage> = [
        .swift, .javascript, .typescript, .tsx, .go, .rust, .css, .html,
    ]

    /// The languages with no block comment syntax: ⌥⌘/ runs the line toggle in
    /// the ones that have a line comment, and is a no-op beep in json and
    /// markdown (`languagesWithoutComments`).
    public static let languagesWithoutBlockComments: Set<SyntaxLanguage> = [
        .json, .markdown, .python, .yaml, .dockerfile, .dotenv, .gitignore,
        .shell, .make, .editorconfig, .sql,
    ]

    /// The languages that have no comment syntax to toggle.
    ///
    /// Toggling a comment in these languages is a silent no-op. The absence
    /// is recorded explicitly so the union of this set and the styled languages
    /// exactly covers `SyntaxLanguage.allCases`.
    public static let languagesWithoutComments: Set<SyntaxLanguage> = [
        .json, .markdown
    ]
}

/// A block comment's opening and closing delimiters.
public struct BlockCommentDelimiters: Equatable, Sendable {
    public let open: String
    public let close: String

    public init(open: String, close: String) {
        self.open = open
        self.close = close
    }
}

/// Where a line sits for Toggle Comment: ordinary code, or the children of a
/// JSX element, where a comment must be written `{/* … */}`.
public enum CommentContext: Equatable, Sendable {
    case code
    case jsxChildren
}
