import XCTest
@testable import PisakaCore

final class DisplayPathTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/tester")

    // MARK: - Inside the open project root

    func testFileInsideRootYieldsSuffixWithoutTheRootName() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/proj/backend/src/a.ts"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["backend", "src", "a.ts"]
        )
    }

    func testFileDirectlyAtTheRootYieldsJustItsName() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/proj/main.ts"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["main.ts"]
        )
    }

    func testRootItselfIsNotUnderItselfSoItFallsBackToTheAbsolutePath() {
        // Strictly-under, mirroring `CanonicalPath.relativeComponents`.
        let root = URL(fileURLWithPath: "/Users/tester/dev/proj")
        XCTAssertEqual(
            DisplayPath.components(fileURL: root, projectRoot: root, home: home),
            ["~", "dev", "proj"]
        )
    }

    func testTrailingSlashOnTheRootStillMatches() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/proj/src/a.ts"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj/"),
                home: home
            ),
            ["src", "a.ts"]
        )
    }

    func testSiblingDirectorySharingTheRootsNamePrefixIsNotInsideTheRoot() {
        // "/…/projx" is not under "/…/proj" — a component comparison, not a
        // string prefix.
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/projx/a.ts"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["~", "dev", "projx", "a.ts"]
        )
    }

    // MARK: - Outside the root / no root open

    /// The full three-branch fall-through with a project open: neither the root
    /// nor home contains the file, so it is shown as a plain absolute path.
    func testFileOutsideBothTheOpenRootAndHomeIsShownAbsolute() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Volumes/Data/scratch/a.txt"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["Volumes", "Data", "scratch", "a.txt"]
        )
    }

    func testFileOutsideTheRootButInsideHomeIsAbbreviated() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/notes/todo.md"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["~", "notes", "todo.md"]
        )
    }

    func testFileOutsideHomeHasNoAbbreviationAndNoLeadingSeparatorComponent() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Volumes/Data/scratch/a.txt"),
                projectRoot: nil,
                home: home
            ),
            ["Volumes", "Data", "scratch", "a.txt"]
        )
    }

    func testHomeItselfIsNotAbbreviatedSinceItIsNotStrictlyUnderItself() {
        XCTAssertEqual(
            DisplayPath.components(fileURL: home, projectRoot: nil, home: home),
            ["Users", "tester"]
        )
    }

    func testSiblingDirectorySharingHomesNamePrefixIsNotAbbreviated() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester2/a.txt"),
                projectRoot: nil,
                home: home
            ),
            ["Users", "tester2", "a.txt"]
        )
    }

    func testNoRootOpenAndFileInHomeIsAbbreviated() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/proj/src/a.ts"),
                projectRoot: nil,
                home: home
            ),
            ["~", "dev", "proj", "src", "a.ts"]
        )
    }

    func testFileAtTheFilesystemRootYieldsItsNameOnly() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/a.txt"),
                projectRoot: nil,
                home: home
            ),
            ["a.txt"]
        )
    }

    // MARK: - Standardization

    func testUnstandardizedPathsAreStandardizedOnBothSides() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Users/tester/dev/proj/src/./sub/../a.ts"),
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/other/../proj"),
                home: home
            ),
            ["src", "a.ts"]
        )
    }

    func testUnstandardizedAbsolutePathIsStandardized() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: URL(fileURLWithPath: "/Volumes/Data/./x/../a.txt"),
                projectRoot: nil,
                home: home
            ),
            ["Volumes", "Data", "a.txt"]
        )
    }

    // MARK: - Untitled

    func testNoURLYieldsUntitled() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: nil,
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            ["Untitled"]
        )
    }

    /// The "Untitled" literal is duplicated from `OpenFile.displayName` rather
    /// than shared through a constant — this test is what keeps the two paired,
    /// so a rename of the tab-list fallback is caught here and not by the user
    /// seeing two different words for the same buffer.
    func testUntitledMatchesOpenFileDisplayName() {
        XCTAssertEqual(
            DisplayPath.components(
                fileURL: nil,
                projectRoot: URL(fileURLWithPath: "/Users/tester/dev/proj"),
                home: home
            ),
            [OpenFile(url: nil).displayName]
        )
    }

    // MARK: - Symlinks (real temporary directories)

    /// (a) The project root opened *through* a symlink, the file spelled
    /// canonically: the canonical probe resolves both sides and the file is
    /// still shown relative to the root.
    func testRootOpenedThroughSymlinkStillMatchesCanonicallySpelledFile() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        XCTAssertEqual(
            DisplayPath.components(
                fileURL: fixture.realFile,
                projectRoot: fixture.link,
                home: home
            ),
            ["src", "a.swift"]
        )
    }

    /// (b) The file opened *through* a symlink to the root, the root spelled
    /// canonically — the mirror image of (a).
    func testFileOpenedThroughSymlinkedRootStillMatchesCanonicalRoot() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        XCTAssertEqual(
            DisplayPath.components(
                fileURL: fixture.link.appendingPathComponent("src/a.swift"),
                projectRoot: fixture.real,
                home: home
            ),
            ["src", "a.swift"]
        )
    }

    /// A symlink *inside* the root pointing outside it: canonically the file
    /// lives elsewhere, but the tab's own path is lexically under the root, so
    /// the lexical probe shows it relative to the root rather than as an absolute
    /// path to the referent.
    func testSymlinkInsideTheRootPointingOutsideIsShownRelativeToTheRoot() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        let outside = fixture.dir.appendingPathComponent("outside.swift")
        try Data().write(to: outside)
        let alias = fixture.real.appendingPathComponent("src/alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        XCTAssertEqual(
            DisplayPath.components(fileURL: alias, projectRoot: fixture.real, home: home),
            ["src", "alias.swift"]
        )
    }

    /// A symlink *inside* the root pointing *back inside* it (pnpm's
    /// `node_modules/foo -> .pnpm/foo@1.0.0/node_modules/foo` shape): both probes
    /// match, so the lexical one wins and the bar shows the path as the user
    /// opened it — the same segments the project tree and the tab show — rather
    /// than the referent's expansion under a name never opened.
    func testSymlinkInsideTheRootPointingInsideIsShownAsOpened() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        let target = fixture.real.appendingPathComponent("src/sub/real.swift")
        try Data().write(to: target)
        let alias = fixture.real.appendingPathComponent("src/alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertEqual(
            DisplayPath.components(fileURL: alias, projectRoot: fixture.real, home: home),
            ["src", "alias.swift"]
        )
    }

    // MARK: - Single source of truth: no drift from `WorkspaceModel`

    /// `DisplayPath` and `WorkspaceModel` must agree on "this file is the one
    /// open in that tab / inside this root". Both go through `CanonicalPath`, so
    /// a tab the model finds through a *differently spelled* url is also shown
    /// relative to the root, whichever spelling each side used.
    func testAgreesWithWorkspaceModelAcrossPathSpellings() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        let spellings = [
            fixture.realFile,
            fixture.link.appendingPathComponent("src/a.swift"),
            fixture.real.appendingPathComponent("src/./a.swift"),
            fixture.real.appendingPathComponent("src/sub/../a.swift"),
        ]
        let roots = [fixture.real, fixture.link]

        for opened in spellings {
            let model = WorkspaceModel()
            try model.open(url: opened)
            let openedID = try XCTUnwrap(model.selectedID)

            for lookup in spellings {
                XCTAssertEqual(
                    model.fileID(forURL: lookup),
                    openedID,
                    "model should match \(lookup.path) against a tab opened as \(opened.path)"
                )
            }
            for root in roots {
                XCTAssertEqual(
                    DisplayPath.components(fileURL: opened, projectRoot: root, home: home),
                    ["src", "a.swift"],
                    "tab \(opened.path) under root \(root.path)"
                )
            }
        }
    }

    /// The negative direction of the same agreement: a sibling path the model
    /// does *not* consider the open tab is also not shown relative to the root —
    /// it falls through to the absolute branch. Drift in the permissive direction
    /// (one side matching a path the other rejects) fails here.
    func testDisagreementWithWorkspaceModelIsAlsoConsistent() throws {
        let fixture = try SymlinkFixture()
        defer { fixture.cleanUp() }

        let model = WorkspaceModel()
        try model.open(url: fixture.realFile)

        // A sibling of the opened root, sharing its name prefix.
        let siblingRoot = fixture.dir.appendingPathComponent("realx")
        let sibling = siblingRoot.appendingPathComponent("src/a.swift")

        XCTAssertNil(model.fileID(forURL: sibling))
        XCTAssertNotEqual(
            DisplayPath.components(fileURL: sibling, projectRoot: fixture.real, home: home),
            ["src", "a.swift"]
        )
        XCTAssertEqual(
            DisplayPath.components(fileURL: sibling, projectRoot: fixture.real, home: home),
            Array(sibling.standardizedFileURL.pathComponents.dropFirst())
        )
    }
}

/// A real on-disk directory with a symlinked alias of the project root:
///
///     <dir>/real/src/a.swift
///     <dir>/real/src/sub/          (so a `src/sub/../a.swift` spelling is readable —
///                                   `open(2)` does not standardize a path)
///     <dir>/link -> <dir>/real
private struct SymlinkFixture {
    let dir: URL
    let real: URL
    let link: URL
    let realFile: URL

    init() throws {
        let fm = FileManager.default
        dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        real = dir.appendingPathComponent("real")
        link = dir.appendingPathComponent("link")
        realFile = real.appendingPathComponent("src/a.swift")
        do {
            try fm.createDirectory(at: real.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
            try Data().write(to: realFile)
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
        } catch {
            // The call site's `defer { cleanUp() }` is only registered once `init`
            // returns, so a partial setup must remove its own temp directory.
            cleanUp()
            throw error
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }
}
