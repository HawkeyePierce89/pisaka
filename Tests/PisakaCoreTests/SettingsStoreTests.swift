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

        // And back on again — the round trip has to work in both directions.
        // (Unset-vs-stored-`false`, the distinction `bool(forKey:)` cannot make,
        // is pinned by `testAnAbsentCompletionKeyReadsAsOn`, not here: this test
        // always writes a value first, so both reads agree on every fixture.)
        second.completionEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).completionEnabled)
    }

    /// `bool(forKey:)` would read a missing key as `false` and launch every user
    /// who has never touched the preference with completion silently off; the
    /// lenient `object(forKey:)` read tells unset from a stored `false`, and a
    /// value of the wrong type falls back to on rather than disabling a feature
    /// nobody asked to disable.
    ///
    /// Every fixture here is one a coercing read gets *wrong*: `bool(forKey:)`
    /// falls back to `NSString.boolValue`, so `"no"`/`"0"` come back `false` and a
    /// `Data`/array comes back `false` too — completion silently off for a user
    /// who never asked. (A `"yes"` fixture would prove nothing: both reads answer
    /// `true` for it, so it cannot tell the implementations apart.)
    func testAWrongTypedStoredCompletionFlagFallsBackToOn() {
        let wrongTypedValues: [Any] = ["no", "0", "off", Data(), ["a"], Date(timeIntervalSince1970: 0)]
        for (index, wrongTyped) in wrongTypedValues.enumerated() {
            // One suite per fixture — the loop must not depend on the previous
            // iteration's writes, and the names stay plain (a suite name is a
            // defaults domain, not a description string).
            let defaults = makeDefaults("\(#function).\(index)")
            defaults.set(wrongTyped, forKey: SettingsStore.Keys.completionEnabled)

            XCTAssertTrue(
                SettingsStore(defaults: defaults).completionEnabled,
                "a \(type(of: wrongTyped)) value of \(wrongTyped) must not disable completion"
            )
        }
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

    // MARK: - The three zoom zones

    func testFreshStoreRestsAtEveryZonesDefault() {
        let store = SettingsStore(defaults: makeDefaults())

        // "Nothing changes at 100%": a fresh install draws its terminal at
        // SwiftTerm's own 13 pt and its chrome at exactly today's constants.
        XCTAssertEqual(store.terminalFontSize, 13)
        XCTAssertEqual(store.interfaceScale, 1.0)
        for zone in ZoomZone.allCases {
            XCTAssertEqual(store.scale(for: zone), ZoomScaleRule.rule(for: zone).defaultValue, "\(zone)")
        }
    }

    func testScaleForZoneReadsTheBackingProperty() {
        let store = SettingsStore(defaults: makeDefaults())
        store.fontSize = 17
        store.terminalFontSize = 21
        store.interfaceScale = 1.5

        XCTAssertEqual(store.scale(for: .code), 17)
        XCTAssertEqual(store.scale(for: .terminal), 21)
        XCTAssertEqual(store.scale(for: .interface), 1.5)
    }

    func testSteppingAZoneLeavesTheOtherTwoAlone() {
        // The independence the whole feature rests on, asserted in every
        // direction rather than assumed from the three separate properties.
        for zone in ZoomZone.allCases {
            let store = SettingsStore(defaults: makeDefaults("\(#function).\(zone)"))
            store.stepZoom(zone, by: 2)

            for other in ZoomZone.allCases {
                let rule = ZoomScaleRule.rule(for: other)
                let expected = other == zone
                    ? rule.stepped(rule.defaultValue, by: 2)
                    : rule.defaultValue
                XCTAssertEqual(store.scale(for: other), expected, "\(zone) moved \(other)")
            }
        }
    }

    func testResettingAZoneReturnsOnlyItToItsDefault() {
        let store = SettingsStore(defaults: makeDefaults())
        store.fontSize = 20
        store.terminalFontSize = 20
        store.interfaceScale = 1.6

        store.resetZoom(.terminal)
        XCTAssertEqual(store.terminalFontSize, 13)
        XCTAssertEqual(store.fontSize, 20, "resetting the terminal reset the code zone too")
        XCTAssertEqual(store.interfaceScale, 1.6)

        store.resetZoom(.interface)
        XCTAssertEqual(store.interfaceScale, 1.0)
        XCTAssertEqual(store.fontSize, 20)

        store.resetZoom(.code)
        XCTAssertEqual(store.fontSize, SettingsStore.defaultFontSize)
    }

    func testTheCodeZoneIsTheEditorFontSizeAndNotASecondSetting() {
        // No second "code zoom" value exists: stepping the zone and stepping the
        // font size are the same write, in both directions.
        let store = SettingsStore(defaults: makeDefaults())
        store.stepZoom(.code, by: 3)
        XCTAssertEqual(store.fontSize, 16)
        XCTAssertEqual(store.scale(for: .code), 16)

        store.stepFontSize(by: -1)
        XCTAssertEqual(store.scale(for: .code), 15)
    }

    func testZoneSteppingClampsAtBothBounds() {
        for zone in ZoomZone.allCases {
            let rule = ZoomScaleRule.rule(for: zone)
            let store = SettingsStore(defaults: makeDefaults("\(#function).\(zone)"))

            store.stepZoom(zone, by: 1000)
            XCTAssertEqual(store.scale(for: zone), rule.maximum, "\(zone) above")
            store.stepZoom(zone, by: -1000)
            XCTAssertEqual(store.scale(for: zone), rule.minimum, "\(zone) below")
        }
    }

    func testZoomingUpAndBackDownReturnsEveryZoneToExactlyItsDefault() {
        let store = SettingsStore(defaults: makeDefaults())

        for zone in ZoomZone.allCases {
            for _ in 0..<4 { store.stepZoom(zone, by: 1) }
            for _ in 0..<4 { store.stepZoom(zone, by: -1) }
            XCTAssertEqual(
                store.scale(for: zone), ZoomScaleRule.rule(for: zone).defaultValue,
                "\(zone) did not come back to its resting value"
            )
        }
    }

    func testTerminalSizeAndInterfaceScaleAreClampedOnWrite() {
        let store = SettingsStore(defaults: makeDefaults())

        store.terminalFontSize = 1
        XCTAssertEqual(store.terminalFontSize, ZoomScaleRule.terminalFont.minimum)
        store.terminalFontSize = 500
        XCTAssertEqual(store.terminalFontSize, ZoomScaleRule.terminalFont.maximum)

        store.interfaceScale = 0.1
        XCTAssertEqual(store.interfaceScale, ZoomScaleRule.interfaceScale.minimum)
        store.interfaceScale = 9
        XCTAssertEqual(store.interfaceScale, ZoomScaleRule.interfaceScale.maximum)
    }

    func testNonFiniteZoomWritesCollapseToTheDefault() {
        // The same unbounded-recursion guard the editor font size has: a NaN
        // surviving the clamp would make `clamped != value` always true.
        let store = SettingsStore(defaults: makeDefaults())

        store.terminalFontSize = .nan
        XCTAssertEqual(store.terminalFontSize, ZoomScaleRule.terminalFont.defaultValue)
        store.terminalFontSize = .infinity
        XCTAssertEqual(store.terminalFontSize, ZoomScaleRule.terminalFont.defaultValue)

        store.interfaceScale = .nan
        XCTAssertEqual(store.interfaceScale, ZoomScaleRule.interfaceScale.defaultValue)
        store.interfaceScale = -.infinity
        XCTAssertEqual(store.interfaceScale, ZoomScaleRule.interfaceScale.defaultValue)
    }

    // MARK: - The terminal zone and its Preferences row

    func testTerminalZoomStepsOnePointAtATimeThroughTheZoneAPI() {
        // What the app layer actually pushes into the live sessions: whole point
        // sizes, one per step, from SwiftTerm's own default.
        let store = SettingsStore(defaults: makeDefaults())

        store.stepZoom(.terminal, by: 1)
        XCTAssertEqual(store.terminalFontSize, 14)
        store.stepZoom(.terminal, by: 3)
        XCTAssertEqual(store.terminalFontSize, 17)
        store.stepZoom(.terminal, by: -5)
        XCTAssertEqual(store.terminalFontSize, 12)

        // …and the same value read back through the zone-keyed accessor the
        // controller uses, so neither surface needs to know which property holds
        // it.
        XCTAssertEqual(store.scale(for: .terminal), store.terminalFontSize)
    }

    func testTheStoreAcceptsTheTerminalRulesBoundsAndItsStepMatchesAZoomStep() {
        // The half of "the Preferences stepper cannot leave the zoom grid" that a
        // store test can actually see: the bounds the row presents survive the
        // clamp-on-write, and a stepper press moves by exactly what a zoom step
        // moves by. That the *row* reads those numbers from `ZoomScaleRule` rather
        // than restating them is a fact about a view, asserted statically by
        // `ZoomSourceGatingTests`.
        let rule = ZoomScaleRule.terminalFont
        let store = SettingsStore(defaults: makeDefaults())

        store.terminalFontSize = rule.minimum
        XCTAssertEqual(store.terminalFontSize, rule.minimum, "the stepper's lower bound is clamped away")
        store.terminalFontSize = rule.maximum
        XCTAssertEqual(store.terminalFontSize, rule.maximum, "the stepper's upper bound is clamped away")

        // A stepper press and a zoom step move by the same amount from the same
        // place, so the two surfaces can never drift apart the way two
        // independent step constants would.
        store.terminalFontSize = rule.defaultValue
        store.terminalFontSize += rule.step
        let byStepper = store.terminalFontSize
        store.resetZoom(.terminal)
        store.stepZoom(.terminal, by: 1)
        XCTAssertEqual(store.terminalFontSize, byStepper)
    }

    func testTheThreeScalesRoundTripAcrossAFreshStore() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.fontSize = 18
        first.terminalFontSize = 15
        first.interfaceScale = 1.3

        // The relaunch: all three zones must survive one, independently.
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.fontSize, 18)
        XCTAssertEqual(second.terminalFontSize, 15)
        XCTAssertEqual(second.interfaceScale, 1.3)
    }

    func testOutOfRangeZoomWritesReachDiskClamped() {
        let defaults = makeDefaults()

        let first = SettingsStore(defaults: defaults)
        first.terminalFontSize = 500
        first.interfaceScale = 0.01

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.terminalFontSize, ZoomScaleRule.terminalFont.maximum)
        XCTAssertEqual(second.interfaceScale, ZoomScaleRule.interfaceScale.minimum)
    }

    func testPersistedZoomValuesAreClampedOnLoad() {
        let defaults = makeDefaults()
        defaults.set(1000.0, forKey: SettingsStore.Keys.terminalFontSize)
        defaults.set(-4.0, forKey: SettingsStore.Keys.interfaceScale)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.terminalFontSize, ZoomScaleRule.terminalFont.maximum)
        XCTAssertEqual(store.interfaceScale, ZoomScaleRule.interfaceScale.minimum)
    }

    func testAbsentWrongTypedOrNonFinitePersistedZoomValuesFallBack() {
        // Absent (a user who has never zoomed), the wrong type (an older build, a
        // hand-edited domain) and non-finite must all read as the default rather
        // than as 0 — a 0 pt terminal font or a 0× interface would be unusable.
        let empty = makeDefaults("\(#function).absent")
        XCTAssertNil(empty.object(forKey: SettingsStore.Keys.terminalFontSize))
        XCTAssertNil(empty.object(forKey: SettingsStore.Keys.interfaceScale))
        let fresh = SettingsStore(defaults: empty)
        XCTAssertEqual(fresh.terminalFontSize, 13)
        XCTAssertEqual(fresh.interfaceScale, 1.0)

        let wrongType = makeDefaults("\(#function).wrongType")
        wrongType.set("huge", forKey: SettingsStore.Keys.terminalFontSize)
        wrongType.set(["scale": 2], forKey: SettingsStore.Keys.interfaceScale)
        let coerced = SettingsStore(defaults: wrongType)
        XCTAssertEqual(coerced.terminalFontSize, 13)
        XCTAssertEqual(coerced.interfaceScale, 1.0)

        let nonFinite = makeDefaults("\(#function).nonFinite")
        nonFinite.set(Double.nan, forKey: SettingsStore.Keys.terminalFontSize)
        nonFinite.set(Double.infinity, forKey: SettingsStore.Keys.interfaceScale)
        let collapsed = SettingsStore(defaults: nonFinite)
        XCTAssertEqual(collapsed.terminalFontSize, 13)
        XCTAssertEqual(collapsed.interfaceScale, 1.0)
    }

    func testZoomKeysAreStable() {
        // Renaming either key resets that zone for every user who had zoomed it.
        XCTAssertEqual(SettingsStore.Keys.terminalFontSize, "settings.terminalFontSize")
        XCTAssertEqual(SettingsStore.Keys.interfaceScale, "settings.interfaceScale")
        // And the code zone keeps writing where it always has — it *is* the
        // editor font size, not a new setting beside it.
        XCTAssertEqual(SettingsStore.Keys.fontSize, "settings.fontSize")
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
