import Foundation

/// The lexing vocabulary that decides whether a caret is inside a string literal
/// or a comment, per language.
///
/// This type does not scan — see `SyntaxContextScanner` — it only declares *what*
/// each language considers a string or a comment, and whether being inside that
/// string should suppress completion.
///
/// The split between "recognized" and "gating" is deliberate: JSON, YAML, HTML
/// and dotenv strings are *lexed* (so a `#` inside a quoted YAML scalar is not
/// mistaken for a comment) but do not suppress completion, because their strings
/// *are* the document's vocabulary — buffer-word completion of a repeated key,
/// class name or variable is the only completion those files have. Markdown has
/// no vocabulary at all and is completely ungated. The reasons for each decision
/// are carried on the vocabulary entry for the language, not only in the plan.
public enum SyntaxContextVocabulary {

    // MARK: - Value types

    /// How a string literal treats its closing delimiter when it appears inside.
    public enum EscapeRule: Equatable, Sendable {
        /// No escape processing — the close delimiter always ends the literal.
        case none
        /// A preceding unescaped backslash escapes the next character.
        case backslash
        /// The closing delimiter is escaped by doubling it (`''` inside `'…'`).
        case doubledDelimiter
    }

    /// Where a line comment token is recognized.
    public enum LineAnchor: Equatable, Sendable {
        /// The token starts a comment wherever it appears.
        case anywhere
        /// Only when it is the first non-ignored character on the line.
        case lineStart
        /// At the start of the line or after whitespace.
        case afterWhitespace
    }

    /// Whether a string literal contains interpolation holes that re-open code.
    public enum InterpolationHole: Equatable, Sendable {
        /// JavaScript/TypeScript template literal `${…}`.
        case jsTemplate
        /// Swift `\(…)` and `\#(…)` — pound count must match the string's.
        case swiftInterpolation
        /// Python f-string `{…}` — `{{`/`}}` are literal braces.
        case pythonFString
    }

    /// One quoted form a language recognizes as a string.
    public struct StringForm: Equatable, Sendable, Hashable {
        public let open: String
        public let close: String
        public let spansLines: Bool
        public let escape: EscapeRule
        /// Lowercased prefix letters that may appear before `open` (e.g. `r`, `b`,
        /// `f` for Python). `nil` means no prefix is recognized.
        public let allowedPrefixLetters: Set<Character>?
        public let allowsPoundPadding: Bool
        public let hole: InterpolationHole?

        public init(
            open: String,
            close: String,
            spansLines: Bool,
            escape: EscapeRule,
            allowedPrefixLetters: Set<Character>? = nil,
            allowsPoundPadding: Bool = false,
            hole: InterpolationHole? = nil
        ) {
            self.open = open
            self.close = close
            self.spansLines = spansLines
            self.escape = escape
            self.allowedPrefixLetters = allowedPrefixLetters
            self.allowsPoundPadding = allowsPoundPadding
            self.hole = hole
        }
    }

    /// One comment form a language recognizes.
    public enum CommentForm: Equatable, Sendable, Hashable {
        case line(token: String, anchor: LineAnchor)
        case block(open: String, close: String, nestable: Bool)
    }

    /// The full vocabulary for one language.
    public struct Vocabulary: Equatable, Sendable {
        public let stringForms: [StringForm]
        public let commentForms: [CommentForm]
        /// When `false` the language's strings are recognized but never suppress
        /// completion (see the type's documentation).
        public let stringsSuppressCompletion: Bool

        public init(
            stringForms: [StringForm],
            commentForms: [CommentForm],
            stringsSuppressCompletion: Bool
        ) {
            self.stringForms = stringForms
            self.commentForms = commentForms
            self.stringsSuppressCompletion = stringsSuppressCompletion
        }
    }

    // MARK: - Closed sets

    /// Languages that declare no string vocabulary at all — no `symbols.scm` is
    /// not the reason; these formats simply have no quoted-string concept that
    /// a lexing pass needs to know about.
    public static let languagesWithoutStringVocabulary: Set<SyntaxLanguage> = [
        .markdown, .gitignore, .editorconfig,
    ]

    // MARK: - Accessors

    /// The vocabulary for `language`, covering all 16 `SyntaxLanguage` cases.
    public static func vocabulary(for language: SyntaxLanguage) -> Vocabulary {
        Vocabulary(
            stringForms: stringForms(for: language),
            commentForms: commentForms(for: language),
            stringsSuppressCompletion: stringsSuppressCompletion(for: language)
        )
    }

    /// The string forms for `language`.
    public static func stringForms(for language: SyntaxLanguage) -> [StringForm] {
        switch language {
        case .swift:
            return swiftStringForms
        case .javascript, .typescript:
            return jsStringForms
        case .python:
            return pythonStringForms
        case .go:
            return goStringForms
        case .rust:
            return rustStringForms
        case .css:
            return cssStringForms
        case .sql:
            return sqlStringForms
        case .dockerfile:
            return dockerfileStringForms
        case .json:
            return jsonStringForms
        case .yaml:
            return yamlStringForms
        case .html:
            return htmlStringForms
        case .dotenv:
            return dotenvStringForms
        case .gitignore, .editorconfig, .markdown:
            return []
        }
    }

    /// The comment forms for `language`.
    public static func commentForms(for language: SyntaxLanguage) -> [CommentForm] {
        switch language {
        case .swift:
            return [.line(token: "//", anchor: .anywhere), .block(open: "/*", close: "*/", nestable: true)]
        case .javascript, .typescript:
            return [.line(token: "//", anchor: .anywhere), .block(open: "/*", close: "*/", nestable: false)]
        case .python:
            return [.line(token: "#", anchor: .anywhere)]
        case .go:
            return [.line(token: "//", anchor: .anywhere), .block(open: "/*", close: "*/", nestable: false)]
        case .rust:
            return [.line(token: "//", anchor: .anywhere), .block(open: "/*", close: "*/", nestable: true)]
        case .css:
            return [.block(open: "/*", close: "*/", nestable: false)]
        case .sql:
            return [.line(token: "--", anchor: .anywhere), .block(open: "/*", close: "*/", nestable: false)]
        case .dockerfile:
            return [.line(token: "#", anchor: .lineStart)]
        case .json:
            return []
        case .yaml:
            return [.line(token: "#", anchor: .afterWhitespace)]
        case .html:
            return [.block(open: "<!--", close: "-->", nestable: false)]
        case .dotenv:
            return [.line(token: "#", anchor: .lineStart)]
        case .gitignore:
            return [.line(token: "#", anchor: .lineStart)]
        case .editorconfig:
            return [.line(token: "#", anchor: .lineStart), .line(token: ";", anchor: .lineStart)]
        case .markdown:
            return []
        }
    }

    /// Whether strings of `language` suppress completion. `false` for the four
    /// document-vocabulary languages whose strings *are* the content to complete.
    public static func stringsSuppressCompletion(for language: SyntaxLanguage) -> Bool {
        switch language {
        case .json, .yaml, .html, .dotenv:
            return false
        case .swift, .javascript, .typescript, .python, .go, .rust, .css, .sql, .dockerfile:
            return true
        case .markdown, .gitignore, .editorconfig:
            return false
        }
    }

    /// Whether `language` can produce a context that suppresses completion.
    /// `markdown` and `json` never do — the former has no vocabulary, the latter
    /// has only ungated strings and no comments — so callers can skip scanning
    /// entirely.
    public static func canSuppressCompletion(_ language: SyntaxLanguage) -> Bool {
        let v = vocabulary(for: language)
        if !v.commentForms.isEmpty { return true }
        if !v.stringForms.isEmpty && v.stringsSuppressCompletion { return true }
        return false
    }

    // MARK: - Per-language string tables

    /// Swift: `"…"` single-line and `"""…"""` multi-line, both pound-padded
    /// (`#"…"#`, `##"…"##`). Escape is `\` plus the string's `N` hashes.
    /// Interpolation `\(…)` / `\#(…)` re-opens code. Pound padding is not a
    /// separate form — the delimiter's `open`/`close` carry the base quotes and
    /// `allowsPoundPadding` says the scanner must count surrounding `#`.
    private static let swiftStringForms: [StringForm] = [
        StringForm(
            open: "\"",
            close: "\"",
            spansLines: false,
            escape: .backslash,
            allowsPoundPadding: true,
            hole: .swiftInterpolation
        ),
        StringForm(
            open: "\"\"\"",
            close: "\"\"\"",
            spansLines: true,
            escape: .backslash,
            allowsPoundPadding: true,
            hole: .swiftInterpolation
        ),
    ]

    /// JavaScript / TypeScript: `'…'` and `"…"` single-line with `\` escape,
    /// plus `` `…` `` multi-line template with `${…}` holes. Regex literals are
    /// deliberately not modeled — distinguishing `/` division from a regex opener
    /// needs a parser, not a lexical scan (stated limit).
    private static let jsStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .backslash),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
        StringForm(open: "`", close: "`", spansLines: true, escape: .backslash, hole: .jsTemplate),
    ]

    /// Python: `'…'`, `"…"` single-line and `'''…'''`, `"""…"""` multi-line.
    /// Prefixes `r`, `b`, `u`, `f` may combine in any order/case; `r` makes `\`
    /// inert, `f` enables `{…}` holes where `{{`/`}}` are literal.
    private static let pythonStringForms: [StringForm] = [
        StringForm(
            open: "'",
            close: "'",
            spansLines: false,
            escape: .backslash,
            allowedPrefixLetters: ["r", "b", "u", "f"],
            hole: .pythonFString
        ),
        StringForm(
            open: "\"",
            close: "\"",
            spansLines: false,
            escape: .backslash,
            allowedPrefixLetters: ["r", "b", "u", "f"],
            hole: .pythonFString
        ),
        StringForm(
            open: "'''",
            close: "'''",
            spansLines: true,
            escape: .backslash,
            allowedPrefixLetters: ["r", "b", "u", "f"],
            hole: .pythonFString
        ),
        StringForm(
            open: "\"\"\"",
            close: "\"\"\"",
            spansLines: true,
            escape: .backslash,
            allowedPrefixLetters: ["r", "b", "u", "f"],
            hole: .pythonFString
        ),
    ]

    /// Go: `"…"` single-line `\` escape, `` `…` `` raw multi-line with no escapes,
    /// and `'…'` rune single-line. The rune form is a single character but still a
    /// gated island — completing inside it is never useful.
    private static let goStringForms: [StringForm] = [
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
        StringForm(open: "`", close: "`", spansLines: true, escape: .none),
        StringForm(open: "'", close: "'", spansLines: false, escape: .backslash),
    ]

    /// Rust: `"…"` with `\` escape (spans lines — Rust string literals may contain
    /// unescaped newlines and an unterminated one must run to the buffer end).
    /// Raw forms `r"…"`, `r#"…"#`, `br#"…"#` have no escapes and are gated as well.
    /// `'` is deliberately **not** a string delimiter — a lifetime `&'a` would open
    /// a bogus literal, and a char literal is one character wide and never worth
    /// completing inside.
    private static let rustStringForms: [StringForm] = [
        StringForm(open: "\"", close: "\"", spansLines: true, escape: .backslash),
        StringForm(
            open: "\"",
            close: "\"",
            spansLines: true,
            escape: .none,
            allowedPrefixLetters: ["r", "b"],
            allowsPoundPadding: true
        ),
    ]

    /// CSS: `'…'` and `"…"` single-line with `\` escape.
    private static let cssStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .backslash),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
    ]

    /// SQL: `'…'` multi-line with doubled-delimiter escape (`''`). `"` is
    /// deliberately not modeled — it quotes an identifier, which is exactly the
    /// thing worth completing, so gating it would silence quoted column names.
    private static let sqlStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: true, escape: .doubledDelimiter),
    ]

    /// Dockerfile: `'…'` and `"…"` single-line with `\` escape.
    private static let dockerfileStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .backslash),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
    ]

    /// JSON: `"…"` single-line `\` escape, **not gating** — strings *are* the
    /// document's vocabulary (keys, values), so gating would silence the only
    /// completion the file has. Still lexed so the scanner stays correct.
    private static let jsonStringForms: [StringForm] = [
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
    ]

    /// YAML: `'…'` with doubled escape and `"…"` with `\` escape, both
    /// single-line and **not gating** — same reason as JSON, and the strings must
    /// still be lexed so a `#` inside a quoted scalar is not mistaken for a
    /// comment. `#` is a comment only at line start or after whitespace.
    private static let yamlStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .doubledDelimiter),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .backslash),
    ]

    /// HTML: `'…'` and `"…"` single-line with no escapes, **not gating** — a
    /// class name or attribute value is buffer-word vocabulary, and `<!--` inside
    /// a value is not a comment. Raw text inside `<script>`/`<style>` is not
    /// modeled (stated limit: embedded-language bodies need a second grammar).
    private static let htmlStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .none),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .none),
    ]

    /// dotenv: `'…'` and `"…"` single-line, **not gating** — variable names and
    /// values are the completion vocabulary, so gating would silence them. Still
    /// lexed for the same completeness.
    private static let dotenvStringForms: [StringForm] = [
        StringForm(open: "'", close: "'", spansLines: false, escape: .none),
        StringForm(open: "\"", close: "\"", spansLines: false, escape: .none),
    ]
}
