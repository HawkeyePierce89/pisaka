#if os(macOS)
import SwiftUI
import PisakaCore

/// How the chrome's **colours** reach the views: one environment value carrying
/// a `ChromeTheme`, injected at exactly the roots that already inject the
/// interface scale.
///
/// Deliberately the same shape as `InterfaceScaleEnvironment.swift`, modifier
/// for modifier — the two are applied side by side at every root, and a reader
/// who has understood one has understood this one. Three rules the
/// surface-by-surface sweep obeys, stated once here:
///
/// - **Nothing resolves a role itself.** A view asks
///   `theme.color(.textSecondary)`; which of the palette's two value sets that
///   reads, and what the value is, live in `ChromePalette`. A view that spells a
///   colour — a hex literal, or one of the system's semantic colours — fails
///   `ChromeThemeSourceGatingTests` rather than merely looking slightly wrong.
/// - **The modifier is applied only at roots.** Applying it lower would not be
///   wrong so much as meaningless: the value is inherited by construction,
///   including by sheets and popovers presented from a themed root, so a second
///   application below one can only ever re-state what is already there.
/// - **The default is the resting one.** A view the sweep has not reached, or one
///   in a preview with no root modifier, reads the dark theme — the primary
///   appearance — and draws something legible rather than nothing.
private struct ChromeThemeKey: EnvironmentKey {
    static let defaultValue = ChromeTheme(.dark)
}

extension EnvironmentValues {
    /// The chrome's colours for this view tree. The dark theme until a root
    /// applies `.chromeThemed(_:)`.
    var chromeTheme: ChromeTheme {
        get { self[ChromeThemeKey.self] }
        set { self[ChromeThemeKey.self] = newValue }
    }
}

/// Injects the chrome's resolved theme into a view tree.
///
/// Takes the `SettingsStore` and observes it, for the reason `InterfaceScaled`
/// does: `themePreference` is `@Published`, so a Preferences edit re-evaluates
/// the root and the new theme flows down with no relaunch.
///
/// `ThemePreference.system` carries no appearance by itself, so the modifier
/// reads `@Environment(\.colorScheme)` to answer that question. It sits *above*
/// each root's `.preferredColorScheme(...)` in the modifier chain — a modifier
/// applied later wraps the environment write rather than descending from it —
/// so the scheme it reads is the system's own, which is exactly what `.system`
/// means. The two forced preferences never consult it.
private struct ChromeThemed: ViewModifier {
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(
            \.chromeTheme,
            ChromeTheme(
                ChromeAppearance.resolved(
                    settings.themePreference,
                    systemPrefersDark: colorScheme == .dark
                )
            )
        )
    }
}

extension View {
    /// Apply the chrome's theme to this view tree. Applied at each SwiftUI root,
    /// immediately beside `.interfaceScaled(_:)` — the two sets are asserted to
    /// be the same set, from `ZoomSourceGatingTests`' own declaration of it, so a
    /// root that gains one modifier and forgets the other fails in one place.
    func chromeThemed(_ settings: SettingsStore) -> some View {
        modifier(ChromeThemed(settings: settings))
    }
}

/// The root's own theme.
///
/// For the same reason `SettingsStore.interfaceMetrics` exists: a view that
/// applies `.chromeThemed(self)` cannot read the value it just injected, an
/// environment write reaching descendants rather than the view that made it. A
/// root that needs to draw chrome in its own body resolves it from the same
/// store the modifier reads; every other view declares
/// `@Environment(\.chromeTheme)`.
extension SettingsStore {
    /// The chrome theme for the stored preference, given the system's current
    /// appearance.
    func chromeTheme(systemPrefersDark: Bool) -> ChromeTheme {
        ChromeTheme(
            ChromeAppearance.resolved(themePreference, systemPrefersDark: systemPrefersDark)
        )
    }
}

#endif
