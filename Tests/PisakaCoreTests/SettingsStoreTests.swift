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

        // A second store over the same suite reads the persisted values back.
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.tabOrientation, .horizontal)
        XCTAssertEqual(second.themePreference, .dark)
        XCTAssertEqual(second.fontSize, 20)
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
