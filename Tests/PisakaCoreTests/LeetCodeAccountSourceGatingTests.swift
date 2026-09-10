import XCTest

/// Static verification of where the LeetCode account is resolved (decision L27).
///
/// A repository-file suite in the established shape: it reads `Sources/Pisaka`
/// through `#filePath` with Foundation only, and matches against **comment- and
/// literal-stripped** text through `LSPSourceGatingTests
/// .strippingCommentsAndStringLiterals`. The stripping is load-bearing, not
/// tidy — every file this suite reads quotes its own rule in prose (the sheet's
/// `signIn()` explains the await in a comment that names
/// `resolveAccount()`), so a raw `contains` would stay green on a comment
/// describing a call site that has been deleted.
///
/// **The inventory.**
///
/// 1. `refreshUserStatus` is spelled in **no** file under `Sources/Pisaka`. The
///    confirmation request is Core's to start — resolution starts it, once, and
///    the model owns the moment — so the app layer having no caller *at all* is
///    a stronger and more durable statement than naming the two files that used
///    to call it at launch. A launch-time confirmation re-introduced anywhere in
///    the app tree fails here, whatever file it is put in.
/// 2. Resolution — `resolveAccount` and `awaitAccountResolution` together — is
///    reachable from exactly **four** app files, pinned by set equality:
///    `LeetCodeOpenProblemSheet.swift`, `SettingsView.swift`,
///    `iOS/LeetCodeRoute_iOS.swift` and `iOS/SettingsView_iOS.swift`. Three of
///    them render account state and resolve on appear; the first also holds the
///    menu's await-then-decide (`LeetCodeCommands.signIn()`), which lives beside
///    the sheet rather than in `PisakaApp.swift` because that file sits exactly
///    at its measured `file_length`/`type_body_length` ceiling and a feature's
///    share there is the wiring line and nothing else.
///
///    The **set is the whole rule**, and `PisakaApp.swift`'s absence from it is
///    the point: that is the file the launch-time `onAppear` used to live in, so
///    its spelling resolution at all is the regression this suite exists to
///    catch. No count pin is needed on top — the app tree naming resolution in
///    those four files and nowhere else says it straight.
///
/// **Why the compiler cannot see any of this:** a launch-time
/// `refreshUserStatus()`, or a `resolveAccount()` in the scene's `onAppear`,
/// compiles and runs perfectly. Its only symptom is a Keychain read and a
/// network round trip on every launch of a session that never opens the feature
/// — and, on an ad-hoc-signed build, a confirmation dialog in front of an editor
/// nobody asked to sign in from. Nothing crashes, no test fails, and no pixel is
/// wrong; only a suite counting call sites keeps the moment where it was put.
final class LeetCodeAccountSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let appTree = "Sources/Pisaka"

    // MARK: - Reading

    /// Every app-tree Swift file, paired with its path relative to
    /// `Sources/Pisaka` so a failure names `iOS/SettingsView_iOS.swift` rather
    /// than an absolute path, and so the two `SettingsView` files stay distinct.
    private func appFiles() throws -> [(name: String, code: String)] {
        let directory = Self.repositoryRoot.appendingPathComponent(Self.appTree)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        let prefix = directory.standardizedFileURL.path + "/"
        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                let path = url.standardizedFileURL.path
                let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
                let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                    try String(contentsOf: url, encoding: .utf8)
                )
                return (name: name, code: code)
            }
    }

    private func appFilesNaming(_ identifiers: [String]) throws -> Set<String> {
        var naming: Set<String> = []
        for file in try appFiles() where identifiers.contains(
            where: { LSPSourceGatingTests.containsToken($0, in: file.code) }
        ) {
            naming.insert(file.name)
        }
        return naming
    }

    /// The enumeration really did reach the app tree. Without this, both rules
    /// below pass vacuously the day the layout moves.
    func testTheAppTreeIsWhereThisSuiteThinksItIs() throws {
        let names = Set(try appFiles().map(\.name))
        XCTAssertTrue(
            names.contains("PisakaApp.swift"),
            "The app tree must contain PisakaApp.swift; if it moved, this suite is looking in the wrong place "
                + "and every rule below is passing on an empty set."
        )
        XCTAssertTrue(
            names.contains("iOS/RootView_iOS.swift"),
            "The enumeration must descend into iOS/; a shallow read would hide two of the four resolving "
                + "surfaces and the iOS launch site this rule is about."
        )
    }

    // MARK: - The confirmation is Core's to start

    func testNoAppFileStartsTheAccountConfirmation() throws {
        XCTAssertEqual(
            try appFilesNaming(["refreshUserStatus"]),
            [],
            "refreshUserStatus() belongs to Core: resolution starts the one confirmation, at first use. An app "
                + "file naming it is a launch-time — or otherwise app-timed — request the model no longer "
                + "controls."
        )
    }

    // MARK: - Where resolution is reachable from

    func testResolutionIsReachableFromExactlyTheFourRenderingSurfaces() throws {
        XCTAssertEqual(
            try appFilesNaming(["resolveAccount", "awaitAccountResolution"]),
            [
                "LeetCodeOpenProblemSheet.swift",
                "SettingsView.swift",
                "iOS/LeetCodeRoute_iOS.swift",
                "iOS/SettingsView_iOS.swift",
            ],
            "Resolution is reachable from the four surfaces that render account state (the macOS sheet and "
                + "Preferences tab, the iOS account screen and Settings section) — the first of which also "
                + "holds the menu's await-then-decide. PisakaApp.swift is excluded outright: it is where the "
                + "launch-time confirmation used to live, so resolution appearing there is the regression."
        )
    }
}
