import Combine
import XCTest
@testable import PisakaCore

final class SettingsStoreTests: XCTestCase {
    /// A fresh, isolated `UserDefaults` suite per test so stores never read or
    /// write the shared standard domain.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SettingsStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsOnFreshStore() {
        let store = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.tabOrientation, .vertical)
        XCTAssertEqual(store.themePreference, .system)
        XCTAssertEqual(store.fontSize, SettingsStore.defaultFontSize)
        XCTAssertEqual(store.fontSize, 13)
        // Default *on*: a user who has never opened Preferences gets completion.
        XCTAssertTrue(store.completionEnabled)
    }

    func testFontSizeClampsBelowMin() {
        let store = SettingsStore(defaults: makeDefaults())
        store.fontSize = 1
        XCTAssertEqual(store.fontSize, SettingsStore.minFontSize)
        XCTAssertEqual(store.fontSize, 8)
    }

    func testFontSizeClampsAboveMax() {
        let store = SettingsStore(defaults: makeDefaults())
        store.fontSize = 100
        XCTAssertEqual(store.fontSize, SettingsStore.maxFontSize)
        XCTAssertEqual(store.fontSize, 32)
    }

    func testStepHelperStaysClampedAtBounds() {
        let store = SettingsStore(defaults: makeDefaults())

        store.fontSize = SettingsStore.maxFontSize
        store.stepFontSize(by: 5)
        XCTAssertEqual(store.fontSize, SettingsStore.maxFontSize)

        store.fontSize = SettingsStore.minFontSize
        store.stepFontSize(by: -5)
        XCTAssertEqual(store.fontSize, SettingsStore.minFontSize)
    }

    func testStepHelperStepsWithinRange() {
        let store = SettingsStore(defaults: makeDefaults())
        store.fontSize = 13
        store.stepFontSize(by: 2)
        XCTAssertEqual(store.fontSize, 15)
        store.stepFontSize(by: -1)
        XCTAssertEqual(store.fontSize, 14)
    }

    func testPersistenceRoundTrip() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.tabOrientation = .horizontal
        first.themePreference = .dark
        first.fontSize = 20
        first.completionEnabled = false

        // A second store over the same suite reads the persisted values back.
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.tabOrientation, .horizontal)
        XCTAssertEqual(second.themePreference, .dark)
        XCTAssertEqual(second.fontSize, 20)
        XCTAssertFalse(second.completionEnabled)

        // And back on again — the round trip has to work in both directions, since
        // `false` is the value a plain `bool(forKey:)` read cannot tell from unset.
        second.completionEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).completionEnabled)
    }

    /// `bool(forKey:)` would read a missing key as `false` and launch every user
    /// who has never touched the preference with completion silently off; the
    /// lenient `object(forKey:)` read tells unset from a stored `false`, and a
    /// value of the wrong type falls back to on rather than disabling a feature
    /// nobody asked to disable.
    func testAWrongTypedStoredCompletionFlagFallsBackToOn() {
        let defaults = makeDefaults()
        defaults.set("yes", forKey: SettingsStore.Keys.completionEnabled)

        XCTAssertTrue(SettingsStore(defaults: defaults).completionEnabled)
    }

    func testAnAbsentCompletionKeyReadsAsOn() {
        let defaults = makeDefaults()
        XCTAssertNil(defaults.object(forKey: SettingsStore.Keys.completionEnabled))

        XCTAssertTrue(SettingsStore(defaults: defaults).completionEnabled)
    }

    func testNonFiniteFontSizeCollapsesToDefault() {
        let store = SettingsStore(defaults: makeDefaults())

        // A NaN must not survive the clamp: `min`/`max` propagate NaN, which would
        // make the `didSet`'s `clamped != fontSize` (NaN != NaN) always true and
        // recurse without bound. It collapses to the finite default instead.
        store.fontSize = .nan
        XCTAssertEqual(store.fontSize, SettingsStore.defaultFontSize)

        store.fontSize = .infinity
        XCTAssertEqual(store.fontSize, SettingsStore.defaultFontSize)

        XCTAssertEqual(SettingsStore.clampFontSize(.nan), SettingsStore.defaultFontSize)
    }

    func testNonFinitePersistedFontSizeCollapsesToDefaultOnLoad() {
        let defaults = makeDefaults()
        defaults.set(Double.nan, forKey: SettingsStore.Keys.fontSize)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fontSize, SettingsStore.defaultFontSize)
    }

    func testOutOfRangeFontSizeWriteIsPersistedClamped() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.fontSize = 100
        first.fontSize = 1

        // The clamped value (not the raw out-of-range one) must reach disk, so a
        // second store over the same suite reads back the bound, not 1 or nothing.
        let belowStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(belowStore.fontSize, SettingsStore.minFontSize)

        first.fontSize = 100
        let aboveStore = SettingsStore(defaults: defaults)
        XCTAssertEqual(aboveStore.fontSize, SettingsStore.maxFontSize)
    }

    func testPersistedFontSizeIsClampedOnLoad() {
        let defaults = makeDefaults()
        defaults.set(1000.0, forKey: SettingsStore.Keys.fontSize)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.fontSize, SettingsStore.maxFontSize)
    }

    func testUnknownPersistedEnumFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("sideways", forKey: SettingsStore.Keys.tabOrientation)
        defaults.set("solarized", forKey: SettingsStore.Keys.themePreference)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.tabOrientation, .vertical)
        XCTAssertEqual(store.themePreference, .system)
    }

    func testStableRawValues() {
        XCTAssertEqual(TabOrientation.vertical.rawValue, "vertical")
        XCTAssertEqual(TabOrientation.horizontal.rawValue, "horizontal")
        XCTAssertEqual(ThemePreference.system.rawValue, "system")
        XCTAssertEqual(ThemePreference.light.rawValue, "light")
        XCTAssertEqual(ThemePreference.dark.rawValue, "dark")

        // The consent values reach `UserDefaults` verbatim and are read back by
        // every future version of the app: renaming one silently re-asks about a
        // server the user already answered for.
        XCTAssertEqual(LSPServerConsent.unasked.rawValue, "unasked")
        XCTAssertEqual(LSPServerConsent.accepted.rawValue, "accepted")
        XCTAssertEqual(LSPServerConsent.declined.rawValue, "declined")
        XCTAssertEqual(SettingsStore.Keys.lspServerConsent, "settings.lspServerConsent")
        // The one flag both platforms consult: renaming it turns completion back
        // on for every user who had turned it off.
        XCTAssertEqual(SettingsStore.Keys.completionEnabled, "settings.completionEnabled")
    }

    func testEnumsAreCaseIterable() {
        XCTAssertEqual(TabOrientation.allCases, [.vertical, .horizontal])
        XCTAssertEqual(ThemePreference.allCases, [.system, .light, .dark])
        XCTAssertEqual(LSPServerConsent.allCases, [.unasked, .accepted, .declined])
    }

    // MARK: - Language-server consent (D15)

    func testConsentIsUnaskedForEverythingOnAFreshStore() {
        let store = SettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.lspServerConsent, [:])
        for server in LSPDownloadableServer.allCases {
            XCTAssertEqual(store.consent(for: server.id), .unasked)
        }
        // An id this app version does not ship is `unasked` too — the question
        // "may I install it" has no other sensible answer for a server that does
        // not exist.
        XCTAssertEqual(store.consent(for: "no-such-server"), .unasked)
    }

    func testConsentRoundTripsAcrossAFreshStore() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.setConsent(.accepted, for: LSPDownloadableServer.typescript.id)
        first.setConsent(.declined, for: LSPDownloadableServer.python.id)

        // The relaunch: "asked once" is only true if the answer survives one.
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.consent(for: LSPDownloadableServer.typescript.id), .accepted)
        XCTAssertEqual(second.consent(for: LSPDownloadableServer.python.id), .declined)
    }

    func testSettingConsentBackToUnaskedForgetsTheEntry() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.setConsent(.declined, for: LSPDownloadableServer.python.id)
        first.setConsent(.unasked, for: LSPDownloadableServer.python.id)

        XCTAssertEqual(first.lspServerConsent, [:], "unasked was stored rather than forgotten")
        XCTAssertEqual(SettingsStore(defaults: defaults).consent(for: LSPDownloadableServer.python.id), .unasked)
    }

    /// `ContentView` observes this store, so republishing it re-evaluates the tree,
    /// the tab list and the editor. `LSPProvisioningModel.install(_:)` records
    /// `.accepted` on every call — including the already-accepted ones D15's silent
    /// half makes on tab opens — so an unchanged answer has to be a no-op rather
    /// than a write.
    func testRecordingTheSameConsentTwicePublishesNothingTheSecondTime() {
        let store = SettingsStore(defaults: makeDefaults())
        var notifications = 0
        let subscription = store.objectWillChange.sink { _ in notifications += 1 }
        defer { subscription.cancel() }

        store.setConsent(.accepted, for: LSPDownloadableServer.typescript.id)
        XCTAssertEqual(notifications, 1)

        store.setConsent(.accepted, for: LSPDownloadableServer.typescript.id)
        store.setConsent(.accepted, for: LSPDownloadableServer.typescript.id)
        XCTAssertEqual(notifications, 1, "an unchanged consent republished the whole store")

        // An answer that really changed still lands, in both directions.
        store.setConsent(.declined, for: LSPDownloadableServer.typescript.id)
        XCTAssertEqual(notifications, 2)
        store.setConsent(.unasked, for: LSPDownloadableServer.typescript.id)
        XCTAssertEqual(notifications, 3)
        store.setConsent(.unasked, for: LSPDownloadableServer.typescript.id)
        XCTAssertEqual(notifications, 3, "forgetting an already-absent entry republished the store")
        XCTAssertEqual(store.lspServerConsent, [:])
    }

    func testAnUnreadableStoredConsentCostsThatServerAndNoOther() {
        let defaults = makeDefaults()
        defaults.set(
            [
                LSPDownloadableServer.typescript.id: "maybe",
                LSPDownloadableServer.python.id: "accepted",
                "legacy-server": "declined",
            ],
            forKey: SettingsStore.Keys.lspServerConsent
        )

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.consent(for: LSPDownloadableServer.typescript.id), .unasked)
        XCTAssertEqual(store.consent(for: LSPDownloadableServer.python.id), .accepted)
        // An id from a version that shipped a server this one does not is read,
        // kept and simply never asked about.
        XCTAssertEqual(store.consent(for: "legacy-server"), .declined)
    }

    // MARK: - LeetCode

    func testLeetCodeDefaultsOnAFreshStore() {
        let store = SettingsStore(defaults: makeDefaults())

        // Unset, not empty: nothing has been chosen, and `LeetCodeModel` reports
        // `folderUnavailable` rather than writing into some fallback directory.
        XCTAssertNil(store.leetCodeFolderPath)
        XCTAssertNil(store.leetCodeFolderURL)
        XCTAssertNil(store.leetCodeFolderBookmark)
        XCTAssertEqual(store.leetCodeLanguage, LeetCodeSolutionFile.defaultLanguage)
        XCTAssertEqual(store.leetCodeLanguage.langSlug, "swift")
    }

    func testLeetCodeSettingsRoundTrip() {
        let defaults = makeDefaults()
        let bookmark = Data([0x62, 0x6f, 0x6f, 0x6b])

        let first = SettingsStore(defaults: defaults)
        first.leetCodeFolderPath = "/Users/someone/Documents/LeetCode"
        first.leetCodeFolderBookmark = bookmark
        first.leetCodeLanguage = LeetCodeSolutionFile.language(forLangSlug: "python3")!

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.leetCodeFolderPath, "/Users/someone/Documents/LeetCode")
        XCTAssertEqual(second.leetCodeFolderURL?.path, "/Users/someone/Documents/LeetCode")
        XCTAssertEqual(second.leetCodeFolderBookmark, bookmark)
        XCTAssertEqual(second.leetCodeLanguage.langSlug, "python3")
        XCTAssertEqual(second.leetCodeLanguage.language, .python)
    }

    /// "Not configured" must have exactly one spelling, in both directions: a
    /// blank value written is forgotten, and a blank value already in the domain
    /// reads back as absent rather than as a folder whose path is `""`.
    func testABlankLeetCodeFolderIsForgottenRatherThanStored() {
        let defaults = makeDefaults()

        let store = SettingsStore(defaults: defaults)
        store.leetCodeFolderPath = "/tmp/LeetCode"
        store.leetCodeFolderPath = "   "
        XCTAssertNil(store.leetCodeFolderPath)
        XCTAssertNil(defaults.string(forKey: SettingsStore.Keys.leetCodeFolderPath))

        defaults.set("   ", forKey: SettingsStore.Keys.leetCodeFolderPath)
        defaults.set(Data(), forKey: SettingsStore.Keys.leetCodeFolderBookmark)
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertNil(reloaded.leetCodeFolderPath)
        XCTAssertNil(reloaded.leetCodeFolderBookmark)
    }

    /// Blankness is decided on the trimmed value, but the path itself is stored
    /// verbatim: both platforms permit a directory name with a trailing space, and
    /// trimming the stored string would point every later launch at a *different*,
    /// absent folder while this session kept writing to the real one.
    func testALeetCodeFolderPathIsStoredVerbatim() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.leetCodeFolderPath = "/tmp/LeetCode "
        XCTAssertEqual(store.leetCodeFolderPath, "/tmp/LeetCode ")
        XCTAssertEqual(
            defaults.string(forKey: SettingsStore.Keys.leetCodeFolderPath),
            "/tmp/LeetCode "
        )
        XCTAssertEqual(store.leetCodeFolderURL?.path, "/tmp/LeetCode ")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.leetCodeFolderPath, "/tmp/LeetCode ")
        XCTAssertEqual(reloaded.leetCodeFolderURL?.path, "/tmp/LeetCode ")
    }

    /// A slug this build does not offer — LeetCode has a dozen more languages, and
    /// this app may drop one — falls back rather than leaving the picker on
    /// something it cannot seed a file in.
    func testAnUnofferableStoredLanguageFallsBack() {
        let defaults = makeDefaults()
        defaults.set("kotlin", forKey: SettingsStore.Keys.leetCodeLanguage)

        XCTAssertEqual(
            SettingsStore(defaults: defaults).leetCodeLanguage,
            LeetCodeSolutionFile.defaultLanguage
        )
    }

    func testLeetCodeKeysAreStable() {
        XCTAssertEqual(SettingsStore.Keys.leetCodeFolderPath, "settings.leetcode.folderPath")
        XCTAssertEqual(
            SettingsStore.Keys.leetCodeFolderBookmark,
            "settings.leetcode.folderBookmark"
        )
        XCTAssertEqual(SettingsStore.Keys.leetCodeLanguage, "settings.leetcode.language")
    }

    func testAConsentValueOfTheWrongTypeDoesNotDiscardTheWholeDictionary() {
        let defaults = makeDefaults()
        defaults.set(
            [
                LSPDownloadableServer.typescript.id: 7,
                LSPDownloadableServer.python.id: "declined",
            ] as [String: Any],
            forKey: SettingsStore.Keys.lspServerConsent
        )

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.consent(for: LSPDownloadableServer.typescript.id), .unasked)
        XCTAssertEqual(
            store.consent(for: LSPDownloadableServer.python.id), .declined,
            "one malformed entry re-asked about every server"
        )
    }
}
