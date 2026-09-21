import Foundation

/// Which of the palette's two value sets the chrome is drawn from.
///
/// Two values and no third: the palette carries a dark and a light entry per
/// `ChromeColorRole`, so this is the whole question a colour resolution has to
/// answer.
public enum ChromeAppearance: String, CaseIterable, Hashable, Sendable {
    case dark
    case light

    /// The appearance a preference resolves to in an app currently running light
    /// or dark. `ThemePreference.system` carries no appearance by itself, so the
    /// caller supplies the answer to that question and this mapping stays total.
    ///
    /// The third instance of a signature this repository already spells twice —
    /// `MarkdownPreviewTheme.resolved(_:systemPrefersDark:)` and
    /// `LeetCodeStatementDocument.Theme.resolved(_:systemPrefersDark:)` — kept
    /// identical on purpose, so a reader who has met either has met this one.
    public static func resolved(
        _ preference: ThemePreference,
        systemPrefersDark: Bool
    ) -> ChromeAppearance {
        switch preference {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemPrefersDark ? .dark : .light
        }
    }
}
