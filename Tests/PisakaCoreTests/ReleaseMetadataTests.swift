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
/// contents; the file itself only carries the two keys App Store Connect
/// validation wants. Both of them are easy to get subtly wrong:
///
///  * `LSApplicationCategoryType` must be a real UTI from Apple's list — a typo
///    is accepted by the build and rejected by validation;
///  * `ITSAppUsesNonExemptEncryption` must be a **Boolean** `false`. Written by
///    hand (or through a build setting that stringifies) it easily becomes the
///    string `"NO"`, which the export-compliance check does not recognise, so
///    every upload keeps asking the encryption question the key exists to
///    pre-answer. Asserting the *type*, not just the truthiness, is the point.
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
                       ["LSApplicationCategoryType", "ITSAppUsesNonExemptEncryption"],
                       """
                       Resources/Info.plist is a partial plist merged into Xcode's generated one. \
                       Anything Xcode can generate (CFBundleName, the version keys, the \
                       per-destination scene keys) belongs in project.yml as GENERATE_INFOPLIST_FILE \
                       output or an INFOPLIST_KEY_* setting, not here.
                       """)
    }

    // MARK: - Reading the committed resources

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func loadInfoPlist(file: StaticString = #filePath,
                               line: UInt = #line) throws -> [String: Any] {
        let url = Self.repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any],
                             "Resources/Info.plist is not a plist dictionary", file: file, line: line)
    }
}
