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

        /// Where LeetCode solution files are written, as a plain file-system
        /// path.
        ///
        /// A path and not a bookmark, because the macOS app ships no
        /// `.entitlements` and enables no App Sandbox: it can reach a folder the
        /// user picked in an `NSOpenPanel` on every later launch by path alone,
        /// exactly as an opened project root is. iOS cannot, which is what the
        /// next key is for — the *path* is still written on both platforms, since
        /// it is what the Settings row shows.
        public static let leetCodeFolderPath = "settings.leetcode.folderPath"
        /// The security-scoped bookmark for the same folder — **iOS only**.
        ///
        /// A second key rather than a second encoding of the first, so the
        /// platform that does not need it never writes it and the path stays
        /// readable on its own.
        public static let leetCodeFolderBookmark = "settings.leetcode.folderBookmark"
        /// The language new solution files are seeded in, as LeetCode's own slug
        /// (`swift`, `python3`, `golang`).
        ///
        /// The *slug* rather than a `SyntaxLanguage` raw value, because it is
        /// LeetCode's vocabulary that decides which snippet a problem is opened
        /// with, and a stored value naming a language this build no longer offers
        /// must fall back rather than resolve to something adjacent.
        public static let leetCodeLanguage = "settings.leetcode.language"
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

    /// The LeetCode folder as the user chose it, or `nil` when none has been
    /// chosen yet.
    ///
    /// **Unset is not empty.** Assigning `nil` — or a string that is blank once
    /// trimmed — *removes* the key rather than storing `""`, so "not configured"
    /// has exactly one spelling and `LeetCodeModel` reports `folderUnavailable`
    /// instead of trying to write into the current working directory.
    @Published public var leetCodeFolderPath: String? {
        didSet {
            let cleaned = leetCodeFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleaned, !cleaned.isEmpty {
                if cleaned != leetCodeFolderPath {
                    leetCodeFolderPath = cleaned
                    return
                }
                defaults.set(cleaned, forKey: Keys.leetCodeFolderPath)
            } else {
                if leetCodeFolderPath != nil {
                    leetCodeFolderPath = nil
                    return
                }
                defaults.removeObject(forKey: Keys.leetCodeFolderPath)
            }
        }
    }

    /// The iOS security-scoped bookmark for that folder, or `nil` on macOS and
    /// before one has been chosen. Empty data is stored as absence for the same
    /// reason the path is: a bookmark that resolves to nothing is not a bookmark.
    @Published public var leetCodeFolderBookmark: Data? {
        didSet {
            if let bookmark = leetCodeFolderBookmark, !bookmark.isEmpty {
                defaults.set(bookmark, forKey: Keys.leetCodeFolderBookmark)
            } else {
                if leetCodeFolderBookmark != nil {
                    leetCodeFolderBookmark = nil
                    return
                }
                defaults.removeObject(forKey: Keys.leetCodeFolderBookmark)
            }
        }
    }

    /// The language the Open Problem picker starts on.
    ///
    /// Held as the whole `LeetCodeLanguage` row rather than as a slug so the
    /// "unparsable falls back" rule is structural: there is no way to *hold* a
    /// language this build does not offer, and what reaches `UserDefaults` is
    /// always a slug that reads back.
    @Published public var leetCodeLanguage: LeetCodeLanguage {
        didSet { defaults.set(leetCodeLanguage.langSlug, forKey: Keys.leetCodeLanguage) }
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

        // Blank is absent, in both directions: a key holding `""` (an older build,
        // a hand-edited domain) must read back as "not configured" rather than as
        // a folder whose path is the empty string.
        let storedFolder = defaults.string(forKey: Keys.leetCodeFolderPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedBookmark = defaults.data(forKey: Keys.leetCodeFolderBookmark)
        // A slug this build does not offer — LeetCode's `kotlin`, or one this app
        // dropped — falls back to the default rather than leaving the picker on a
        // language it cannot seed a file in.
        let storedLanguage = (defaults.string(forKey: Keys.leetCodeLanguage))
            .flatMap(LeetCodeSolutionFile.language(forLangSlug:))
            ?? LeetCodeSolutionFile.defaultLanguage

        self.tabOrientation = orientation
        self.themePreference = theme
        self.fontSize = storedFont
        self.lspServerConsent = storedConsent
        self.leetCodeFolderPath = (storedFolder?.isEmpty ?? true) ? nil : storedFolder
        self.leetCodeFolderBookmark = (storedBookmark?.isEmpty ?? true) ? nil : storedBookmark
        self.leetCodeLanguage = storedLanguage
    }

    /// The configured LeetCode folder as a URL, or `nil` when unset.
    ///
    /// The one place the persisted *string* becomes a `URL`, so both platforms and
    /// every call site spell it identically.
    public var leetCodeFolderURL: URL? {
        leetCodeFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
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
