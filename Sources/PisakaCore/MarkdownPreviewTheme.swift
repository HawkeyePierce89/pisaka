import Foundation

/// Every colour the Markdown preview draws with, as CSS colour strings.
///
/// The `LeetCodeStatementDocument.Theme` mould, one size larger. Nothing here
/// reads `NSColor`, `UIColor` or the system appearance — Core may not import
/// AppKit/UIKit, and a page that is a pure function of its inputs is one a unit
/// test can assert light and dark differ in. The view layer resolves the
/// appearance it is actually running in and passes the answer across
/// (`SyntaxTheme.markdownPreviewTheme(prefersDark:)`), so the resolution happens
/// once, where the appearance lives.
///
/// The theme is larger than the statement panel's six strings for one reason:
/// the preview highlights code, and the colours it highlights with must be the
/// *editor's own*. A fenced Swift block in the preview and the same block in the
/// text view beside it are the same code read twice, so a second palette would
/// be a second opinion about what a keyword looks like. `codeColors` therefore
/// carries one entry per ``SyntaxTokenKind`` — the same closed vocabulary the
/// editor's attribute provider resolves — and the app derives it from the
/// editor's table rather than restating it.
///
/// The colours reach the page as CSS custom properties, one per field and one
/// per token kind (``cssVariableName(for:)``); the stylesheet and the
/// highlight-class rules read those properties and nothing else, which is what
/// lets a theme change re-write the shell without touching the body.
public struct MarkdownPreviewTheme: Equatable, Sendable {

    /// The page's background — the surface the preview pane reads as.
    public let background: String
    /// Body text.
    public let text: String
    /// Muted text: a blockquote's content and a table's header row.
    public let secondaryText: String
    /// Link text. Also what an autolink is drawn in.
    public let link: String
    /// The fill behind `<code>` and `<pre>`. A code fence is most of a technical
    /// document, so this is the colour that decides whether the pane reads as one
    /// surface or two.
    public let codeBackground: String
    /// Thematic breaks and the blockquote bar.
    public let border: String
    /// A table's cell borders. Separate from `border` because a table draws a
    /// grid of them — a weight that reads as structure between cells would read
    /// as a scar across a paragraph.
    public let tableBorder: String
    /// `"light"` or `"dark"`, emitted as CSS `color-scheme` so the web view's own
    /// scrollbars and the disabled task-item checkboxes match the page rather
    /// than staying stubbornly light inside a dark pane.
    public let colorScheme: String
    /// One colour per token kind, keyed by the editor's own semantic vocabulary.
    ///
    /// A dictionary rather than one stored property per kind because the page
    /// emits these by iterating ``SyntaxTokenKind/allCases`` and the class table
    /// maps into the same key space; ``color(for:)`` is what makes reading it
    /// total.
    public let codeColors: [SyntaxTokenKind: String]

    public init(
        background: String,
        text: String,
        secondaryText: String,
        link: String,
        codeBackground: String,
        border: String,
        tableBorder: String,
        colorScheme: String,
        codeColors: [SyntaxTokenKind: String]
    ) {
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.link = link
        self.codeBackground = codeBackground
        self.border = border
        self.tableBorder = tableBorder
        self.colorScheme = colorScheme
        self.codeColors = codeColors
    }

    /// The colour for a token kind, falling back to `text`.
    ///
    /// Total by construction rather than by hoping the dictionary is complete: a
    /// missing entry would otherwise emit an empty CSS custom property, and a
    /// custom property with no value makes every rule that reads it invalid —
    /// one absent kind would strip the colour off unrelated tokens rather than
    /// off its own. Body text is the honest fallback, being what an unhighlighted
    /// run is already drawn in.
    public func color(for kind: SyntaxTokenKind) -> String {
        codeColors[kind] ?? text
    }

    /// The CSS custom-property name a token kind's colour travels under.
    ///
    /// Spelled here, in the type that owns the colours, so the page shell and the
    /// highlight-class rules cannot disagree about it. The names are stable
    /// strings rather than a derivation from the case names: a Swift case rename
    /// must not silently re-point a stylesheet.
    public static func cssVariableName(for kind: SyntaxTokenKind) -> String {
        switch kind {
        case .keyword: return "--code-keyword"
        case .string: return "--code-string"
        case .comment: return "--code-comment"
        case .number: return "--code-number"
        case .type: return "--code-type"
        case .function: return "--code-function"
        case .variable: return "--code-variable"
        case .constant: return "--code-constant"
        case .operator: return "--code-operator"
        case .punctuation: return "--code-punctuation"
        case .property: return "--code-property"
        case .parameter: return "--code-parameter"
        case .label: return "--code-label"
        case .plain: return "--code-plain"
        }
    }

    /// The light theme.
    ///
    /// The chrome colours are `LeetCodeStatementDocument.Theme.light`'s, plus a
    /// table border: the two panes sit in the same window and there is no reason
    /// for one document surface to be a different white from the other. They are
    /// untouched by the code palette below and stay that way — the chrome is
    /// shared with the other document surface in the window.
    ///
    /// The `codeColors` block is the editor palette's light variants, restated
    /// here only so the domain layer has a complete theme to test and to fall
    /// back on. It is not a second opinion: the app overwrites every entry from
    /// the editor's own table at run time through `withCodeColors(_:)`, which is
    /// the mechanism that must keep working and must not be reimplemented. The
    /// two copies now state the same values, so the screen no longer reports a
    /// broken derivation; a test does.
    public static let light = MarkdownPreviewTheme(
        background: "#ffffff",
        text: "#1d1d1f",
        secondaryText: "#6e6e73",
        link: "#0066cc",
        codeBackground: "#f2f2f7",
        border: "#d2d2d7",
        tableBorder: "#c7c7cc",
        colorScheme: "light",
        codeColors: [
            .keyword: "#8250b0",
            .string: "#4f7942",
            .comment: "#8a8a90",
            .number: "#a5652d",
            .type: "#2b6a83",
            .function: "#2f5fa8",
            .variable: "#1d1d1f",
            .constant: "#a5652d",
            .operator: "#6e6e73",
            .punctuation: "#6e6e73",
            .property: "#2f6b63",
            .parameter: "#1d1d1f",
            .label: "#2f6fe0",
            .plain: "#1d1d1f",
        ]
    )

    /// The dark theme — the light one's counterpart, field for field.
    ///
    /// Its chrome is likewise out of the code palette's reach. The `codeColors`
    /// block is the editor palette's dark variants, restated for the same reason
    /// the light ones are: the domain layer needs a complete theme to test and to
    /// fall back on, while the app replaces the whole block from the editor's
    /// table through `withCodeColors(_:)`.
    public static let dark = MarkdownPreviewTheme(
        background: "#1e1e1e",
        text: "#e8e8ed",
        secondaryText: "#9a9aa0",
        link: "#6bb3ff",
        codeBackground: "#2a2a2e",
        border: "#3a3a3e",
        tableBorder: "#4a4a4e",
        colorScheme: "dark",
        codeColors: [
            .keyword: "#b48ead",
            .string: "#9db97b",
            .comment: "#6b6e76",
            .number: "#c9976c",
            .type: "#6a9fb5",
            .function: "#7aa6da",
            .variable: "#dfe1e5",
            .constant: "#c9976c",
            .operator: "#a0a3aa",
            .punctuation: "#a0a3aa",
            .property: "#7fa8a0",
            .parameter: "#dfe1e5",
            .label: "#4f8dff",
            .plain: "#dfe1e5",
        ]
    )

    /// The theme a preference resolves to in an app currently running light or
    /// dark. `ThemePreference.system` carries no colour by itself, so the caller
    /// supplies the answer to that question and this mapping stays total —
    /// `LeetCodeStatementDocument.Theme.resolved(_:systemPrefersDark:)`'s
    /// argument, and its signature.
    public static func resolved(
        _ preference: ThemePreference,
        systemPrefersDark: Bool
    ) -> MarkdownPreviewTheme {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemPrefersDark ? .dark : .light
        }
    }

    /// A copy of this theme carrying another code palette, with the chrome
    /// untouched.
    ///
    /// The app's one use: keep Core's chrome, replace the code colours with the
    /// editor's resolved ones. A dedicated member rather than a re-spelled
    /// initializer call at the call site, so adding a chrome colour later does
    /// not silently drop out of the app's copy.
    public func withCodeColors(_ colors: [SyntaxTokenKind: String]) -> MarkdownPreviewTheme {
        MarkdownPreviewTheme(
            background: background,
            text: text,
            secondaryText: secondaryText,
            link: link,
            codeBackground: codeBackground,
            border: border,
            tableBorder: tableBorder,
            colorScheme: colorScheme,
            codeColors: colors
        )
    }
}
