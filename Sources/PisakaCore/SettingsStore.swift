import Foundation

/// Persisted user preferences: tab orientation, theme, the three zoom zones'
/// scales (the shared editor font size — which *is* the code zone, there is no
/// second setting — the terminal font size and the interface scale), and
/// whether the editor offers completions at all
/// (`completionEnabled`). A plain Foundation-only `ObservableObject` (the `WorkspaceModel`
/// precedent) so it stays testable and free of any SwiftUI/AppKit dependency —
/// the Preferences UI and the act of applying each setting are thin view-layer
/// wiring on top.
///
/// `UserDefaults` is injected (`init(defaults:)`) so tests run against an
/// isolated `UserDefaults(suiteName:)` rather than the shared domain. Each
/// `@Published` change is written straight back through `didSet`; each of the
/// three zoom scales is clamped to its `ZoomScaleRule`'s range on every write so
/// neither a Stepper nor a zoom gesture nor a corrupt persisted value can drive
/// it out of range. The zone-keyed `scale(for:)` / `stepZoom(_:by:)` /
/// `resetZoom(_:)` trio is what the app layer uses, so a view never has to know
/// which property backs which zone.
public final class SettingsStore: ObservableObject {
    /// Stable persisted keys — must not be renamed.
    public enum Keys {
        public static let tabOrientation = "settings.tabOrientation"
        public static let themePreference = "settings.themePreference"
        public static let fontSize = "settings.fontSize"
        /// Whether the editor offers completions at all.
        ///
        /// A stable key like the rest, and deliberately **one** flag rather than
        /// one per platform: the macOS AppKit popup and the iOS accessory strip
        /// are two presentations of the same preference, so a user who turns
        /// completion off on an iPad and opens the same defaults domain on a Mac
        /// must find it off there too. It is also the single source of truth for
        /// every surface that shows the state — the status-bar button, the
        /// Preferences checkbox and the iOS Settings row all read and write this
        /// one property, so they cannot disagree.
        public static let completionEnabled = "settings.completionEnabled"
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

        /// The terminal zoom zone's font size, in points.
        ///
        /// A key of its own rather than a reuse of `fontSize`: the whole point of
        /// the three zones is that the code and the terminal grow independently,
        /// so they cannot share a stored value. Absent means 13 — SwiftTerm's own
        /// default — which is why an existing install sees no change until it
        /// zooms the terminal.
        public static let terminalFontSize = "settings.terminalFontSize"
        /// The interface zoom zone's scale, as a multiplier (1.0 = unchanged).
        ///
        /// A multiplier and not a point size, because the zone covers fonts,
        /// paddings, frames, icon sizes and row heights at once; there is no one
        /// number to store, only the factor every one of them is derived from.
        public static let interfaceScale = "settings.interfaceScale"
    }

    public static let minFontSize: Double = ZoomScaleRule.editorFont.minimum
    public static let maxFontSize: Double = ZoomScaleRule.editorFont.maximum
    public static let defaultFontSize: Double = ZoomScaleRule.editorFont.defaultValue
    public static let fontSizeStep: Double = ZoomScaleRule.editorFont.step

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

    /// The terminal zone's font size, in points. Default 13 (SwiftTerm's own),
    /// so nothing about a terminal changes until the user zooms it.
    ///
    /// The `fontSize` write discipline, verbatim: clamped inside `didSet`, with
    /// the re-entrant assignment reaching a fixed point on the second pass, so
    /// neither a Preferences stepper, a zoom gesture nor a corrupt persisted
    /// value can drive it out of range.
    @Published public var terminalFontSize: Double {
        didSet {
            let clamped = ZoomScaleRule.terminalFont.clamp(terminalFontSize)
            if clamped != terminalFontSize {
                terminalFontSize = clamped
                return
            }
            defaults.set(terminalFontSize, forKey: Keys.terminalFontSize)
        }
    }

    /// The interface zone's scale, as a multiplier. Default 1.0 — every metric
    /// derived from it then equals the constant it replaced, which is what makes
    /// the interface sweep invisible at rest.
    @Published public var interfaceScale: Double {
        didSet {
            let clamped = ZoomScaleRule.interfaceScale.clamp(interfaceScale)
            if clamped != interfaceScale {
                interfaceScale = clamped
                return
            }
            defaults.set(interfaceScale, forKey: Keys.interfaceScale)
        }
    }

    /// Whether the editor offers completions, on both platforms. Default on.
    ///
    /// Off is **total**: neither the automatic popup/strip nor an explicitly
    /// invoked completion (⌃Space, Find > Complete, AppKit's stock ⌥⎋/F5)
    /// produces anything. The narrower JetBrains behaviour — auto-popup off,
    /// explicit invocation still alive — was considered and deliberately not
    /// taken here: it needs a second piece of state (the reason a completion was
    /// asked for) threaded through every entry point, and a switch labelled
    /// "off" that still pops up a list on a keystroke combination is the worse
    /// default. It stays a possible follow-up rather than an omission.
    ///
    /// Nothing in the intelligence stack is torn down when this goes off: no
    /// language server is stopped, no session shut down, the registry is
    /// untouched and the symbol index keeps walking and refreshing — only
    /// completion *requests* stop being made and completion *UI* stops being
    /// shown. That is what makes the toggle instant and free in both directions,
    /// and it is why go-to-definition is entirely unaffected.
    @Published public var completionEnabled: Bool {
        didSet { defaults.set(completionEnabled, forKey: Keys.completionEnabled) }
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
    ///
    /// **Blankness is decided on the trimmed value; the path is stored as the
    /// user's file system spells it.** Trimming the stored string as well would
    /// rewrite a real folder — both platforms permit a directory name with a
    /// leading or trailing space, and `NSOpenPanel`/the document picker hand back
    /// exactly that path — into a *different*, absent one. The session would keep
    /// writing to the folder the user picked (the model's `solutionsFolder` is
    /// assigned from the same `URL`, untrimmed) while the next launch resolved the
    /// trimmed spelling and created a second folder beside it, leaving earlier
    /// solutions in a directory the app no longer looks at.
    @Published public var leetCodeFolderPath: String? {
        didSet {
            let cleaned = leetCodeFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = leetCodeFolderPath, let cleaned, !cleaned.isEmpty {
                defaults.set(path, forKey: Keys.leetCodeFolderPath)
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
        // The two other zoom zones, read exactly like the font size and for the
        // same reasons: `object(forKey:)` so an absent key is told from a stored
        // 0, the cast so a value of the wrong type falls back instead of reading
        // as zero, and the rule's clamp so a non-finite or out-of-range stored
        // value collapses to the default rather than surviving into the UI.
        let storedTerminalFont = (defaults.object(forKey: Keys.terminalFontSize) as? Double)
            .map(ZoomScaleRule.terminalFont.clamp) ?? ZoomScaleRule.terminalFont.defaultValue
        let storedInterfaceScale = (defaults.object(forKey: Keys.interfaceScale) as? Double)
            .map(ZoomScaleRule.interfaceScale.clamp) ?? ZoomScaleRule.interfaceScale.defaultValue
        // The `fontSize` precedent, for the same reason and one more: `bool(forKey:)`
        // reads a missing key as `false`, so every user who has never touched this
        // preference would launch with completion silently off. `object(forKey:)`
        // tells "unset" from a stored `false`, and a value of the wrong type (an
        // older build, a hand-edited domain) fails the cast and falls back to on
        // rather than disabling a feature nobody asked to disable.
        let storedCompletion = (defaults.object(forKey: Keys.completionEnabled) as? Bool) ?? true
        // Read entry by entry rather than as a whole `[String: String]` cast: a
        // single value of the wrong type — or a raw value this app version does
        // not know — must cost that one server its answer and nothing else. A
        // whole-dictionary cast would fail outright and silently re-ask about
        // every server the user has already answered for.
        let storedConsent = (defaults.dictionary(forKey: Keys.lspServerConsent) ?? [:])
            .compactMapValues { ($0 as? String).flatMap(LSPServerConsent.init(rawValue:)) }

        // Blank is absent, in both directions: a key holding `""` (an older build,
        // a hand-edited domain) must read back as "not configured" rather than as
        // a folder whose path is the empty string. The *test* is on the trimmed
        // value and the *answer* is the stored one, for the reason written on the
        // property: a folder name may legitimately end in a space.
        let storedFolder = defaults.string(forKey: Keys.leetCodeFolderPath)
        let storedFolderIsBlank = storedFolder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
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
        self.terminalFontSize = storedTerminalFont
        self.interfaceScale = storedInterfaceScale
        self.completionEnabled = storedCompletion
        self.lspServerConsent = storedConsent
        self.leetCodeFolderPath = storedFolderIsBlank ? nil : storedFolder
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
    /// the valid range. The zoom path calls this with `+1`/`-1`.
    ///
    /// Now one spelling of `ZoomScaleRule.editorFont.stepped(_:by:)` — same
    /// range, same step, same result for every value on the grid, which every
    /// value produced by the Stepper, the shortcuts or a fresh install is.
    public func stepFontSize(by steps: Double) {
        fontSize = ZoomScaleRule.editorFont.stepped(fontSize, by: steps)
    }

    /// The editor font size's clamp. Unchanged in behavior and still the entry
    /// point `LeetCodeStatementDocument` and the tests use; the rule behind it
    /// is now shared with the two other zoom zones.
    public static func clampFontSize(_ value: Double) -> Double {
        ZoomScaleRule.editorFont.clamp(value)
    }

    // MARK: - Zoom zones

    /// The current scale of `zone` — a point size for `code`/`terminal`, a
    /// multiplier for `interface`.
    ///
    /// The zone-keyed trio below exists so no view has to know which stored
    /// property backs which zone: the pointer resolves a `ZoomZone` and the
    /// gesture, the menu item and the accumulator all speak that one word.
    public func scale(for zone: ZoomZone) -> Double {
        switch zone {
        case .code: return fontSize
        case .terminal: return terminalFontSize
        case .interface: return interfaceScale
        }
    }

    /// Step `zone` by `steps` whole steps (positive = larger), through the same
    /// grid-snapping, clamping arithmetic every zone shares.
    public func stepZoom(_ zone: ZoomZone, by steps: Double) {
        setScale(ZoomScaleRule.rule(for: zone).stepped(scale(for: zone), by: steps), for: zone)
    }

    /// Return `zone` to its resting value — 13 pt for the two fonts, 100% for
    /// the interface. Only the zone under the pointer resets; the other two are
    /// untouched, which is what makes the zones independent in both directions.
    public func resetZoom(_ zone: ZoomZone) {
        setScale(ZoomScaleRule.rule(for: zone).defaultValue, for: zone)
    }

    /// The one writer behind `stepZoom`/`resetZoom`. Each property's own `didSet`
    /// still clamps, so this cannot be the place a bad value slips in.
    private func setScale(_ value: Double, for zone: ZoomZone) {
        switch zone {
        case .code: fontSize = value
        case .terminal: terminalFontSize = value
        case .interface: interfaceScale = value
        }
    }
}
