import XCTest
@testable import PisakaCore

/// Static verification of the release-metadata resources that ship in the app
/// bundle but have no Swift code behind them — the kind of file whose mistakes
/// only surface at App Store Connect upload time, long after the build is green.
///
/// Written in the `VendoredGrammarQueryTests`/`DependencyPinTests` style: it
/// reads the repository's own files through `#filePath`, with Foundation only,
/// so the Core target stays dependency-free and the check runs in `swift test`
/// rather than requiring an Xcode build.
///
/// `Resources/Info.plist` is a *partial* plist. `GENERATE_INFOPLIST_FILE` stays
/// on, so Xcode merges its generated per-destination keys into this file's
/// contents; the file itself only carries the keys Xcode cannot generate — the
/// two App Store Connect validation wants and the two Sparkle reads. All four
/// are easy to get subtly wrong, and none of them fails a build:
///
///  * `LSApplicationCategoryType` must be a real UTI from Apple's list — a typo
///    is accepted by the build and rejected by validation;
///  * `ITSAppUsesNonExemptEncryption` must be a **Boolean** `false`. Written by
///    hand (or through a build setting that stringifies) it easily becomes the
///    string `"NO"`, which the export-compliance check does not recognise, so
///    every upload keeps asking the encryption question the key exists to
///    pre-answer. Asserting the *type*, not just the truthiness, is the point.
///  * `SUFeedURL` is read only by an *installed* copy, months after the build:
///    a wrong host, scheme or asset name ships as an app that quietly never
///    finds an update again.
///  * `SUPublicEDKey` is base64-decoded by Sparkle, and a key that lost a
///    character still decodes — to the wrong number of bytes. The committed
///    value is a deliberate, well-formed placeholder (see the plist's own
///    comment), so the shape is all this suite can assert; the release
///    workflow's preflight is what refuses to ship while it is still there.
///
/// `Resources/PrivacyInfo.xcprivacy` is checked the same way, and for the same
/// reason: nothing in the build fails when a required-reason category is wrong,
/// missing or coded with the wrong reason string — it surfaces as an App Store
/// Connect rejection or, worse, as a privacy report that misdescribes the app.
/// The accessed-API assertion is deliberately *set equality* on category/reason
/// pairs rather than a "contains" check, so a category added without an audit,
/// dropped after a refactor, or silently re-coded fails here until the manifest
/// and the audit recorded in `docs/architecture/core-services.md` are reconciled.
final class ReleaseMetadataTests: XCTestCase {
    /// The category the app ships under. A code editor is a developer tool.
    private static let expectedCategory = "public.app-category.developer-tools"

    func testPartialInfoPlistDeclaresTheDeveloperToolsCategory() throws {
        let plist = try loadInfoPlist()
        let category = try XCTUnwrap(plist["LSApplicationCategoryType"] as? String,
                                     "Resources/Info.plist has no string LSApplicationCategoryType")
        XCTAssertEqual(category, Self.expectedCategory,
                       "the App Store category must be a valid UTI from Apple's list")
    }

    func testPartialInfoPlistPreAnswersExportComplianceWithARealBoolean() throws {
        let plist = try loadInfoPlist()
        let raw = try XCTUnwrap(plist["ITSAppUsesNonExemptEncryption"],
                                "Resources/Info.plist has no ITSAppUsesNonExemptEncryption key")
        let number = try XCTUnwrap(raw as? NSNumber,
                                   """
                                   ITSAppUsesNonExemptEncryption must be a Boolean (<false/>), not \
                                   \(type(of: raw)) — a string "NO" is not recognised by the \
                                   export-compliance check and every upload keeps asking.
                                   """)
        XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID(),
                       "ITSAppUsesNonExemptEncryption is a number but not a Boolean")
        XCTAssertFalse(number.boolValue,
                       """
                       The app's only cryptography is HTTPS/TLS from Apple frameworks and libgit2's \
                       Apple TLS backend — the standard exemption, so this must stay false.
                       """)
    }

    func testPartialInfoPlistCarriesOnlyTheKeysXcodeCannotGenerate() throws {
        let plist = try loadInfoPlist()
        XCTAssertEqual(Set(plist.keys),
                       ["LSApplicationCategoryType", "ITSAppUsesNonExemptEncryption",
                        "SUFeedURL", "SUPublicEDKey"],
                       """
                       Resources/Info.plist is a partial plist merged into Xcode's generated one. \
                       Anything Xcode can generate (CFBundleName, the version keys, the \
                       per-destination scene keys) belongs in project.yml as GENERATE_INFOPLIST_FILE \
                       output or an INFOPLIST_KEY_* setting, not here. The two Sparkle keys are here \
                       because they have no INFOPLIST_KEY_* equivalent — GENERATE_INFOPLIST_FILE \
                       cannot produce them at all — and not SUEnableAutomaticChecks or \
                       SUScheduledCheckInterval, whose absence is what makes Sparkle run its own \
                       first-launch consent prompt instead of deciding for the user.
                       """)
    }

    // MARK: - Sparkle

    /// The feed URL is baked into every shipped copy and is read by nothing in
    /// this repository, so a typo in it is invisible until an installed build
    /// silently stops finding updates. Assert the shape that has to hold:
    /// HTTPS (Sparkle refuses an insecure feed unless the app opts out, which it
    /// does not), on `github.com` (the releases redirect this scheme depends on),
    /// and named `appcast.xml` — the last of which is half of a cross-file
    /// invariant: `ReleaseWorkflowTests` asserts the release workflow attaches
    /// the asset under exactly that name, which is what makes GitHub's
    /// `releases/latest/download/appcast.xml` redirect resolve.
    func testPartialInfoPlistCarriesAWellFormedSparkleFeedURL() throws {
        let plist = try loadInfoPlist()
        let raw = try XCTUnwrap(plist["SUFeedURL"] as? String,
                                "Resources/Info.plist has no string SUFeedURL — Sparkle has no feed to check")
        let url = try XCTUnwrap(URL(string: raw), "SUFeedURL is not a parseable URL: \(raw)")

        XCTAssertEqual(url.scheme, "https", """
            SUFeedURL must be HTTPS. Sparkle 2 refuses a plain-HTTP feed unless the app explicitly \
            opts out, and the appcast is the one thing that tells an installed copy what to \
            download — served over HTTP it is trivially tamperable.
            """)
        XCTAssertEqual(url.host, "github.com", """
            SUFeedURL must point at github.com: the whole scheme rests on GitHub's \
            releases/latest/download/<asset> redirect always resolving to the newest release's \
            asset of that name.
            """)
        XCTAssertEqual(url.lastPathComponent, "appcast.xml", """
            The feed's last path component is the release *asset name* GitHub resolves the \
            latest-download redirect against. It must stay appcast.xml, matching the name the \
            release workflow attaches (asserted from the other side in ReleaseWorkflowTests).
            """)
    }

    /// Assert the *shape* of the ed25519 public key: 32 bytes of well-formed
    /// base64. A truncated, re-wrapped or otherwise corrupted key fails here,
    /// while the committed placeholder passes by design — that is the whole
    /// point of choosing a structurally valid placeholder.
    ///
    /// Verifying that it is the *right* key is structurally impossible in this
    /// suite: the matching private half exists only in the
    /// `SPARKLE_PRIVATE_EDDSA_KEY` repository secret, and nothing in
    /// `swift test` can reach it. The two checks that do cover that are the
    /// release workflow's preflight (which refuses to run while the placeholder
    /// is still here, so no release can ship signed by a key installed copies do
    /// not trust) and the one-time manual end-to-end update pass recorded in
    /// `docs/RELEASING.md`.
    func testPartialInfoPlistCarriesAWellFormedSparklePublicKey() throws {
        let plist = try loadInfoPlist()
        let raw = try XCTUnwrap(plist["SUPublicEDKey"] as? String,
                                "Resources/Info.plist has no string SUPublicEDKey")
        let key = try XCTUnwrap(Data(base64Encoded: raw), """
            SUPublicEDKey is not valid base64: “\(raw)”. Sparkle base64-decodes this string and \
            refuses every update if it cannot — copy bin/generate_keys' output verbatim, on one \
            line, with no whitespace.
            """)
        XCTAssertEqual(key.count, 32, """
            SUPublicEDKey must decode to exactly 32 bytes — an ed25519 public key — and decodes to \
            \(key.count). A key that is short by a character or two still base64-decodes, so the \
            byte count is the check that catches a truncated paste.
            """)
    }

    // MARK: - Privacy manifest

    func testPrivacyManifestDeclaresNoTrackingAndNoCollectedData() throws {
        let manifest = try loadPrivacyManifest()

        let tracking = try XCTUnwrap(manifest["NSPrivacyTracking"] as? NSNumber,
                                     "PrivacyInfo.xcprivacy has no Boolean NSPrivacyTracking")
        XCTAssertEqual(CFGetTypeID(tracking), CFBooleanGetTypeID(),
                       "NSPrivacyTracking must be a Boolean (<false/>), not a string or a number")
        XCTAssertFalse(tracking.boolValue,
                       "the app has no advertising or analytics SDK and does no cross-app tracking")

        let domains = try XCTUnwrap(manifest["NSPrivacyTrackingDomains"] as? [Any],
                                    "PrivacyInfo.xcprivacy has no NSPrivacyTrackingDomains array")
        XCTAssertTrue(domains.isEmpty,
                      "NSPrivacyTrackingDomains must stay empty while NSPrivacyTracking is false")

        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [Any],
                                      "PrivacyInfo.xcprivacy has no NSPrivacyCollectedDataTypes array")
        XCTAssertTrue(collected.isEmpty,
                      """
                      The app has no telemetry and no network egress beyond the user's own git \
                      remotes; everything it stores is local. Adding a collected data type means \
                      that stopped being true.
                      """)
    }

    /// Set equality, not containment: the audit behind these two entries is
    /// recorded in `docs/architecture/core-services.md`, and a category added,
    /// dropped or re-coded without redoing that audit must fail here.
    func testPrivacyManifestDeclaresExactlyTheAuditedRequiredReasonAPIs() throws {
        let manifest = try loadPrivacyManifest()
        let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                                  "PrivacyInfo.xcprivacy has no NSPrivacyAccessedAPITypes array")

        var declared: Set<Pair> = []
        for entry in types {
            let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String,
                                         "an accessed-API entry has no string NSPrivacyAccessedAPIType")
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String],
                                        "\(category) has no NSPrivacyAccessedAPITypeReasons string array")
            XCTAssertFalse(reasons.isEmpty, "\(category) declares no reason code")
            for reason in reasons { declared.insert(Pair(category: category, reason: reason)) }
        }

        XCTAssertEqual(declared, Self.expectedAccessedAPIs, Self.accessedAPIMismatchMessage)
    }

    /// One declared `(category, reason)` pair, compared as a set element.
    private struct Pair: Hashable, CustomStringConvertible {
        let category: String
        let reason: String
        var description: String { "\(category)/\(reason)" }
    }

    /// `UserDefaults` (`SettingsStore`/`BookmarkStore`/`SessionStore`), the
    /// `lstat` probes in `GitCLIService`/`LibGit2Service`, and — from a *linked
    /// dependency* rather than from `Sources/` — libgit2's `mach_absolute_time`.
    /// The audit that produced this set, and the binary-symbol check that has to
    /// back it up, are recorded in `docs/architecture/core-services.md`.
    private static let expectedAccessedAPIs: Set<Pair> = [
        Pair(category: "NSPrivacyAccessedAPICategoryUserDefaults", reason: "CA92.1"),
        Pair(category: "NSPrivacyAccessedAPICategoryFileTimestamp", reason: "3B52.1"),
        Pair(category: "NSPrivacyAccessedAPICategorySystemBootTime", reason: "35F9.1"),
    ]

    private static let accessedAPIMismatchMessage = """
        The declared required-reason APIs must match the audit in \
        docs/architecture/core-services.md exactly: UserDefaults/CA92.1 (access limited to the \
        app itself — no app group), FileTimestamp/3B52.1 (timestamps of files the user \
        specifically granted access to via the open panel / document picker) and \
        SystemBootTime/35F9.1 (libgit2's git_time_monotonic, which calls mach_absolute_time to \
        measure elapsed time inside the app and never sends it off-device). 3B52.1 and not \
        DDA9.1 because the app never displays a file timestamp — blame dates come from git's \
        --porcelain output, not from stat. Note that the audit covers the *linked binary*, not \
        just Sources/: libgit2 and the tree-sitter grammars compile from C source into the app \
        and ship no privacy manifest of their own, so their required-reason calls have to be \
        declared here.
        """

    // MARK: - The wiring that puts them in the bundle

    /// Everything above verifies the *contents* of three files. None of it
    /// notices if they stop shipping: drop `INFOPLIST_FILE`, the
    /// `PrivacyInfo.xcprivacy` resource entry and the `Resources/Licenses`
    /// folder reference from `project.yml` and the whole suite stays green,
    /// while CI's unsigned builds succeed too — a resource that is not copied is
    /// not a build error. The result would be an app with no App Store category,
    /// no privacy manifest and an Acknowledgements screen that says the bundle is
    /// broken. So assert the four lines that do the wiring.
    func testProjectStillShipsTheReleaseMetadataResources() throws {
        let settings = try activeProjectLines()

        func assertDeclares(_ needle: String, _ what: String) {
            XCTAssertTrue(settings.contains(consecutively: needle), """
                project.yml no longer declares \(what) (looked for “\(needle)”). The file is still \
                in the repository and still passes its content checks, but it would not reach the \
                app bundle.
                """)
        }

        assertDeclares("INFOPLIST_FILE: Resources/Info.plist",
                       "Resources/Info.plist as the partial Info.plist")
        assertDeclares("GENERATE_INFOPLIST_FILE: YES",
                       "generated Info.plist keys (the partial plist is merged into them, not a replacement)")
        // Both resource entries are matched as the *two-line pair* they are,
        // indentation included, rather than line by line. A bare
        // `project.contains("type: folder")` would be satisfied by any folder
        // reference anywhere in the file, so turning Resources/Licenses into a
        // plain group while some unrelated entry kept a `type: folder` would
        // leave this test green — and the same for the privacy manifest losing
        // its `buildPhase: resources` companion, which is what actually copies
        // it. Anchoring each needle to its own `- path:` line is the difference
        // between asserting the wiring and asserting that the words appear.
        assertDeclares("""
            - path: Resources/PrivacyInfo.xcprivacy
                    buildPhase: resources
            """,
                       "PrivacyInfo.xcprivacy as a top-level bundle resource")
        // A folder reference, not a group: the loader resolves `licenses.json`
        // and the texts through a `Licenses/` *subdirectory* of the bundle, which
        // only a `type: folder` entry produces. As a plain group the files would
        // land flat in Resources/ and every lookup would miss.
        assertDeclares("""
            - path: Resources/Licenses
                    type: folder
            """,
                       "Resources/Licenses as a folder reference")
        // Same shape, same reason, quieter failure: `SymbolQueryTests` checks
        // that every language's `symbols.scm` exists and is well-formed, and all
        // of that stays green when the directory stops being copied into the
        // bundle. `SymbolQueryCatalog` would then find no query for any
        // language, and every file would index zero symbols — which is
        // indistinguishable from a project that declares nothing. A folder
        // reference specifically, because the catalog resolves each query
        // through a `Queries/<language>/` *subdirectory* of the bundle.
        assertDeclares("""
            - path: Resources/Queries
                    type: folder
            """,
                       "Resources/Queries as a folder reference")
    }

    /// The launch screen is the one App Store requirement in this area that no
    /// file in `Resources/` carries: it is a single build setting, and without it
    /// the generated iOS Info.plist has no `UILaunchScreen` at all. A SwiftUI
    /// `@main` app ships no storyboard, so nothing else supplies one —
    /// `GENERATE_INFOPLIST_FILE` alone does not add the key. The build stays
    /// green either way (a missing launch screen is not a compile error), and
    /// the failure only shows up as an App Store Connect validation rejection,
    /// or before that as an app running letterboxed in compatibility mode. So
    /// assert the setting itself, in the same spirit as the resource wiring
    /// above.
    func testProjectGeneratesTheIOSLaunchScreen() throws {
        let settings = try activeProjectLines()

        XCTAssertTrue(settings.contains(consecutively: "INFOPLIST_KEY_UILaunchScreen_Generation: YES"), """
            project.yml no longer asks Xcode to generate the iOS launch screen. Apple has \
            required a launch screen of every app built against the iOS 13+ SDK since April \
            2020: App Store Connect validation rejects the upload, and until then the app runs \
            letterboxed in compatibility mode with no iPad multitasking. Nothing in the build \
            or in Resources/ would report this — restore \
            INFOPLIST_KEY_UILaunchScreen_Generation: YES, or add a launch storyboard and this \
            assertion's replacement.
            """)
    }

    /// File sharing is the same kind of single build setting as the launch
    /// screen below: nothing in `Resources/` carries it, the build stays green
    /// without it, and the failure is purely behavioural — the LeetCode
    /// integration's default solutions folder (`Documents/LeetCode`, chosen so
    /// no picker and no bookmark are needed) silently stops being visible in
    /// the Files app, which no test of Core logic can see.
    func testProjectExposesTheIOSDocumentsInFiles() throws {
        let settings = try activeProjectLines()

        XCTAssertTrue(settings.contains(consecutively: "INFOPLIST_KEY_UIFileSharingEnabled: YES"), """
            project.yml no longer exposes the iOS app container's Documents directory in \
            the Files app. The LeetCode solutions folder defaults to Documents/LeetCode on \
            iOS, and without UIFileSharingEnabled those files are reachable only from inside \
            the app — the README advertises Files visibility, so removing the key ships a \
            documented feature that quietly does not work. Restore \
            INFOPLIST_KEY_UIFileSharingEnabled: YES, or update the README, core-leetcode.md \
            and this assertion together.
            """)
    }

    /// `project.yml`'s *active* settings: every line that is neither blank nor a
    /// comment, trimmed, in file order.
    ///
    /// The two tests above used to match their needles against the raw file with
    /// `String.contains`, which cannot tell a live setting from a commented-out
    /// one — `# INFOPLIST_FILE: Resources/Info.plist` contains
    /// `INFOPLIST_FILE: Resources/Info.plist` as a substring, so disabling any of
    /// these four settings by prefixing a `#` left both tests green while the
    /// resource stopped reaching the bundle. That is exactly the failure they
    /// exist to catch, and it is not a hypothetical shape for this file:
    /// `project.yml` is heavily commented and its comments already quote these
    /// setting names verbatim. Stripping comments first is the same thing
    /// `LicenseCoverageTests.loadProjectDefinition` and
    /// `DependencyPinTests.loadDeclaredPackages` do to the same file.
    private func activeProjectLines(file: StaticString = #filePath,
                                    line: UInt = #line) throws -> [String] {
        let lines = try text(atRepositoryPath: "project.yml")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertFalse(lines.isEmpty,
                       "parsed no settings out of project.yml — the file's shape changed",
                       file: file, line: line)
        return lines
    }

    // MARK: - Reading the committed resources

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func text(atRepositoryPath path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func loadPlist(atRepositoryPath path: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(path))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any],
                             "\(path) is not a plist dictionary", file: file, line: line)
    }

    private func loadInfoPlist(file: StaticString = #filePath,
                               line: UInt = #line) throws -> [String: Any] {
        try loadPlist(atRepositoryPath: "Resources/Info.plist", file: file, line: line)
    }

    private func loadPrivacyManifest(file: StaticString = #filePath,
                                     line: UInt = #line) throws -> [String: Any] {
        try loadPlist(atRepositoryPath: "Resources/PrivacyInfo.xcprivacy", file: file, line: line)
    }
}

// `contains(consecutively:)` — whole-line equality over a consecutive run, which
// is what rules out a commented-out or merely-quoted setting and what keeps the
// two-line resource entries anchored to their own `- path:` line — lives in
// `Support/YAMLLineMatching.swift`, shared with `ReleaseWorkflowTests`.
