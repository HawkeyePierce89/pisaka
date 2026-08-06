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
    }

    func testEnumsAreCaseIterable() {
        XCTAssertEqual(TabOrientation.allCases, [.vertical, .horizontal])
        XCTAssertEqual(ThemePreference.allCases, [.system, .light, .dark])
    }
}
