import Foundation

/// The chrome of a served document page, as CSS colour strings — the one source
/// both served pages take: the Markdown preview (`MarkdownPreviewTheme.chrome`)
/// and the problem statement (`LeetCodeStatementDocument.Theme`).
///
/// **Every field is a `ChromeColorRole`.** `role(for:)` is the whole mapping,
/// and `init(appearance:value:)` fills a value from it, so a page never names a
/// colour of its own — only which role each of its meanings takes.
///
/// **`light` and `dark` are a fallback, restated.** iOS reads them (it has no
/// palette), and a Core test can assert them. macOS replaces them *wholesale*
/// with the value `ChromePalette.documentPageChrome(in:)` derives from the
/// palette, so no restated string survives on that platform; the app-layer
/// test pinning these blocks equal to that derivation is the net that keeps the
/// two platforms drawing the same page.
///
/// **The page ground is `bgEditor`; a code block is `bgCanvas`.** A served page
/// has a surface of its own and sits beside the editor as the same paper, while
/// a fenced block is a recess showing the window ground beneath it. A code block
/// draws **no border** on either page, so the difference between those two
/// grounds is the only thing separating a block from the page, and the two
/// roles must stay distinguishable. Only a change that adds a border to a code
/// block may revisit that pair.
///
/// **One line colour, `hairline`**, because the closed vocabulary names exactly
/// one: the former table-grid colour collapsed into `border`. The full
/// reasoning — why the vocabulary requires it, what it costs in both
/// appearances, and what the remedy would be — is `core-theme.md`'s part five
/// (e).
public struct DocumentPageChrome: Equatable, Sendable {
    /// The page's own ground.
    public let background: String
    /// Body text.
    public let text: String
    /// Muted text: a caption, a difficulty line, a blockquote.
    public let secondaryText: String
    public let link: String
    /// The fill behind `<code>`, `<pre>` and a table's header row.
    public let codeBackground: String
    /// The page's one line colour: a rule, a table grid, a quote bar.
    public let border: String
    /// `"light"` or `"dark"`, emitted as CSS `color-scheme` — taken from the
    /// appearance, and not a colour.
    public let colorScheme: String

    public init(
        background: String,
        text: String,
        secondaryText: String,
        link: String,
        codeBackground: String,
        border: String,
        colorScheme: String
    ) {
        self.background = background
        self.text = text
        self.secondaryText = secondaryText
        self.link = link
        self.codeBackground = codeBackground
        self.border = border
        self.colorScheme = colorScheme
    }

    /// The six colour fields, closed.
    public enum Field: CaseIterable, Hashable, Sendable {
        case background
        case text
        case secondaryText
        case link
        case codeBackground
        case border
    }

    /// The role each page meaning takes — the whole mapping.
    public static func role(for field: Field) -> ChromeColorRole {
        switch field {
        case .background: return .bgEditor
        case .text: return .textPrimary
        case .secondaryText: return .textSecondary
        case .link: return .accent
        case .codeBackground: return .bgCanvas
        case .border: return .hairline
        }
    }

    /// Fills every field from its role through `value`, and `colorScheme` from
    /// the appearance. The app layer hands in the palette's CSS reading.
    public init(appearance: ChromeAppearance, value: (ChromeColorRole) -> String) {
        self.init(
            background: value(Self.role(for: .background)),
            text: value(Self.role(for: .text)),
            secondaryText: value(Self.role(for: .secondaryText)),
            link: value(Self.role(for: .link)),
            codeBackground: value(Self.role(for: .codeBackground)),
            border: value(Self.role(for: .border)),
            colorScheme: appearance.rawValue
        )
    }

    /// The field's value, by `Field`.
    public subscript(field: Field) -> String {
        switch field {
        case .background: return background
        case .text: return text
        case .secondaryText: return secondaryText
        case .link: return link
        case .codeBackground: return codeBackground
        case .border: return border
        }
    }

    /// The palette's light entries for the six roles, restated.
    public static let light = DocumentPageChrome(
        background: "#ffffff",
        text: "#1d1d1f",
        secondaryText: "#6e6e73",
        link: "#2f6fe0",
        codeBackground: "#f5f5f7",
        border: "#d1d1d6",
        colorScheme: "light"
    )

    /// The palette's dark entries for the six roles, restated.
    public static let dark = DocumentPageChrome(
        background: "#2f3136",
        text: "#dfe1e5",
        secondaryText: "#a0a3aa",
        link: "#4f8dff",
        codeBackground: "#1e1f22",
        border: "#393b40",
        colorScheme: "dark"
    )

    /// The restated block a preference resolves to in an app currently running
    /// light or dark — the same signature as `ChromeAppearance.resolved`.
    public static func resolved(
        _ preference: ThemePreference,
        systemPrefersDark: Bool
    ) -> DocumentPageChrome {
        switch ChromeAppearance.resolved(preference, systemPrefersDark: systemPrefersDark) {
        case .light: return .light
        case .dark: return .dark
        }
    }
}
