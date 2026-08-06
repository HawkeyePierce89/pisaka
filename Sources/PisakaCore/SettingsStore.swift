import Foundation

/// Persisted user preferences: tab orientation, theme, and the shared editor
/// font size. A plain Foundation-only `ObservableObject` (the `WorkspaceModel`
/// precedent) so it stays testable and free of any SwiftUI/AppKit dependency —
/// the Preferences UI and the act of applying each setting are thin view-layer
/// wiring on top.
///
/// `UserDefaults` is injected (`init(defaults:)`) so tests run against an
/// isolated `UserDefaults(suiteName:)` rather than the shared domain. Each
/// `@Published` change is written straight back through `didSet`; `fontSize` is
/// clamped to `[minFontSize, maxFontSize]` on every write so neither the
/// Stepper nor the Cmd+scroll path nor a corrupt persisted value can drive it
/// out of range.
public final class SettingsStore: ObservableObject {
    /// Stable persisted keys — must not be renamed.
    public enum Keys {
        public static let tabOrientation = "settings.tabOrientation"
        public static let themePreference = "settings.themePreference"
        public static let fontSize = "settings.fontSize"
    }

    public static let minFontSize: Double = 8
    public static let maxFontSize: Double = 32
    public static let defaultFontSize: Double = 13
    public static let fontSizeStep: Double = 1

    // Instance mirrors so the view layer can read them off a store instance too.
    public let minFontSize = SettingsStore.minFontSize
    public let maxFontSize = SettingsStore.maxFontSize
    public let defaultFontSize = SettingsStore.defaultFontSize
    public let fontSizeStep = SettingsStore.fontSizeStep

    @Published public var tabOrientation: TabOrientation {
        didSet { defaults.set(tabOrientation.rawValue, forKey: Keys.tabOrientation) }
    }

    @Published public var themePreference: ThemePreference {
        didSet { defaults.set(themePreference.rawValue, forKey: Keys.themePreference) }
    }

    @Published public var fontSize: Double {
        didSet {
            let clamped = SettingsStore.clampFontSize(fontSize)
            // Assigning inside didSet re-enters didSet once more; the second pass
            // sees an already-clamped value, so it is a no-op fixed point.
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(fontSize, forKey: Keys.fontSize)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let orientation = (defaults.string(forKey: Keys.tabOrientation))
            .flatMap(TabOrientation.init(rawValue:)) ?? .vertical
        let theme = (defaults.string(forKey: Keys.themePreference))
            .flatMap(ThemePreference.init(rawValue:)) ?? .system
        // `object(forKey:)` distinguishes "unset" (nil → default) from a stored 0.
        let storedFont = (defaults.object(forKey: Keys.fontSize) as? Double)
            .map(SettingsStore.clampFontSize) ?? SettingsStore.defaultFontSize

        self.tabOrientation = orientation
        self.themePreference = theme
        self.fontSize = storedFont
    }

    /// Step the font size by `delta` whole steps (positive = larger), clamped to
    /// the valid range. The Cmd+scroll path calls this with `+1`/`-1`.
    public func stepFontSize(by steps: Double) {
        fontSize = SettingsStore.clampFontSize(fontSize + steps * fontSizeStep)
    }

    public static func clampFontSize(_ value: Double) -> Double {
        // A non-finite value (NaN/±inf) must collapse to a finite default, not be
        // returned as-is: `min`/`max` propagate NaN (every comparison is false), so
        // a NaN would survive the clamp and then make the `fontSize` `didSet`'s
        // `clamped != fontSize` (NaN != NaN) always true — recursing without bound.
        guard value.isFinite else { return defaultFontSize }
        return min(max(value, minFontSize), maxFontSize)
    }
}
