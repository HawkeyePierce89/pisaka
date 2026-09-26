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

    /// The page's chrome — ground, text, link, code ground and its one line
    /// colour — as the one value both served pages take.
    ///
    /// **Shared by construction, not by assertion.** It *is* a
    /// ``DocumentPageChrome``, the type the problem statement's theme is too, so
    /// the two document surfaces in the window cannot disagree about what white
    /// the page is; every field names a `ChromeColorRole`
    /// (``DocumentPageChrome/role(for:)``). The page emits `border` for the
    /// thematic break, the blockquote bar *and* a table's grid — one line colour,
    /// because the closed vocabulary names one.
    public let chrome: DocumentPageChrome
    /// One colour per token kind, keyed by the editor's own semantic vocabulary.
    ///
    /// A dictionary rather than one stored property per kind because the page
    /// emits these by iterating ``SyntaxTokenKind/allCases`` and the class table
    /// maps into the same key space; ``color(for:)`` is what makes reading it
    /// total.
    public let codeColors: [SyntaxTokenKind: String]

    public init(
        chrome: DocumentPageChrome,
        codeColors: [SyntaxTokenKind: String]
    ) {
        self.chrome = chrome
        self.codeColors = codeColors
    }

    /// The colour for a token kind, falling back to the chrome's `text`.
    ///
    /// Total by construction rather than by hoping the dictionary is complete: a
    /// missing entry would otherwise emit an empty CSS custom property, and a
    /// custom property with no value makes every rule that reads it invalid —
    /// one absent kind would strip the colour off unrelated tokens rather than
    /// off its own. Body text is the honest fallback, being what an unhighlighted
    /// run is already drawn in.
    public func color(for kind: SyntaxTokenKind) -> String {
        codeColors[kind] ?? chrome.text
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
    /// The chrome is ``DocumentPageChrome/light`` — the value the statement page
    /// takes too — so this theme spells no chrome literal of its own. It is
    /// untouched by the code palette below and stays that way.
    ///
    /// Both halves are restated fallbacks the app replaces wholesale, each
    /// through its own member, and each pinned by its own pair of app-layer
    /// tests. The `codeColors` block is the editor palette's light variants, restated
    /// here only so the domain layer has a complete theme to test and to fall
    /// back on. It is not a second opinion: the app overwrites every entry from
    /// the editor's own table at run time through `withCodeColors(_:)`, which is
    /// the mechanism that must keep working and must not be reimplemented. The
    /// two copies now state the same values, so the screen no longer reports a
    /// broken derivation; two tests do, and they are separate on purpose —
    /// `SyntaxThemeTests.testThePreviewThemeCarriesTheEditorsPaletteInBothAppearances`
    /// pins that the derivation carries the editor's table, and
    /// `testTheDomainLayersRestatedCodeColoursEqualTheEditorTable` pins that this
    /// block still states the same values, which the first cannot see because
    /// `withCodeColors(_:)` replaces it wholesale. The chrome half is the same
    /// shape: `withChrome(_:)` takes the value `ChromePalette.documentPageChrome(in:)`
    /// derives, one test pins that the derivation carries the palette, and a
    /// separate one pins that ``DocumentPageChrome/light``/``DocumentPageChrome/dark``
    /// still state the palette's values.
    public static let light = MarkdownPreviewTheme(
        chrome: .light,
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
    /// Its chrome is ``DocumentPageChrome/dark``, likewise out of the code
    /// palette's reach. The `codeColors`
    /// block is the editor palette's dark variants, restated for the same reason
    /// the light ones are: the domain layer needs a complete theme to test and to
    /// fall back on, while the app replaces the whole block from the editor's
    /// table through `withCodeColors(_:)`.
    public static let dark = MarkdownPreviewTheme(
        chrome: .dark,
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
    /// The app's one use: replace the code colours with the editor's resolved
    /// ones. A dedicated member rather than a re-spelled initializer call at the
    /// call site, so the chrome cannot silently drop out of the app's copy.
    public func withCodeColors(_ colors: [SyntaxTokenKind: String]) -> MarkdownPreviewTheme {
        MarkdownPreviewTheme(chrome: chrome, codeColors: colors)
    }

    /// A copy of this theme carrying another chrome, with the code colours
    /// untouched — ``withCodeColors(_:)``'s counterpart.
    ///
    /// The app's one use: replace the restated chrome wholesale with the value
    /// the palette derives, so on macOS no restated chrome string survives.
    public func withChrome(_ chrome: DocumentPageChrome) -> MarkdownPreviewTheme {
        MarkdownPreviewTheme(chrome: chrome, codeColors: codeColors)
    }
}
