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
        /// Per-server provisioning consent (D15), as one dictionary of
        /// server id → `LSPServerConsent.rawValue`.
        ///
        /// One key holding a dictionary rather than one key per server, because
        /// the set of servers is *data* (`LSPDownloadableServer`, and the
        /// manifest behind it) and changes when the app ships a new one: a
        /// key-per-server scheme spreads that data across the defaults domain
        /// and leaves a key behind for every server ever removed, while this
        /// shape lets an id that no longer exists be read, ignored and
        /// eventually written back out of existence.
        public static let lspServerConsent = "settings.lspServerConsent"
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

    /// What the user has answered about each downloadable language server
    /// (D15), keyed by `LSPDownloadableServer.id`. An id with no entry is
    /// `unasked` — which is why `.unasked` is never *stored*: absence already
    /// spells it, and writing it would be a second spelling of the same fact.
    ///
    /// Published so the Settings surface redraws when a banner answer lands, and
    /// `private(set)` so every write goes through `setConsent(_:for:)` and the
    /// "asked once" invariant lives in one method.
    @Published public private(set) var lspServerConsent: [String: LSPServerConsent] {
        didSet {
            defaults.set(lspServerConsent.mapValues(\.rawValue), forKey: Keys.lspServerConsent)
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
        // Read entry by entry rather than as a whole `[String: String]` cast: a
        // single value of the wrong type — or a raw value this app version does
        // not know — must cost that one server its answer and nothing else. A
        // whole-dictionary cast would fail outright and silently re-ask about
        // every server the user has already answered for.
        let storedConsent = (defaults.dictionary(forKey: Keys.lspServerConsent) ?? [:])
            .compactMapValues { ($0 as? String).flatMap(LSPServerConsent.init(rawValue:)) }

        self.tabOrientation = orientation
        self.themePreference = theme
        self.fontSize = storedFont
        self.lspServerConsent = storedConsent
    }

    /// The answer recorded for `serverID`. Never asked, an id this app version
    /// does not ship, and a stored value it cannot parse all answer `unasked` —
    /// the state in which the banner is allowed to ask and nothing installs on
    /// its own.
    public func consent(for serverID: String) -> LSPServerConsent {
        lspServerConsent[serverID] ?? .unasked
    }

    /// Record an answer. `unasked` *forgets* the entry rather than storing the
    /// word, so the persisted dictionary only ever holds real answers.
    ///
    /// An answer equal to the one already recorded writes nothing. Assigning into
    /// the `@Published` dictionary would republish the whole store and re-run the
    /// `didSet` that writes `UserDefaults` — and this store *is* observed by
    /// `ContentView`, so a no-op consent write re-evaluates the project tree, the
    /// tab list and the editor. `LSPProvisioningModel.install(_:)` records
    /// `.accepted` on every call, including the already-accepted ones that D15's
    /// silent half makes on tab opens, which is exactly where that cost would land.
    public func setConsent(_ consent: LSPServerConsent, for serverID: String) {
        guard self.consent(for: serverID) != consent else { return }
        lspServerConsent[serverID] = consent == .unasked ? nil : consent
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
