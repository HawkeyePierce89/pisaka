import XCTest
@testable import PisakaCore

/// Tests for the `.editorconfig` hierarchy walk and merge.
///
/// The cases mirror the official EditorConfig core test suite's hierarchy
/// files — their *contents*, not their files: an actual `.editorconfig`
/// committed under `Tests/` would apply to this repository in every editor and
/// every tool that reads the format, so every sample config here is an inline
/// string fed to an in-memory `StubFileTree`.
final class EditorConfigResolverTests: XCTestCase {

    // MARK: - Helpers

    private func tree(_ files: [String: String], root: String = "/project") -> StubFileTree {
        StubFileTree(root: URL(fileURLWithPath: root), files: files)
    }

    private func resolve(
        _ path: String,
        in tree: StubFileTree,
        projectRoot: URL? = nil
    ) -> EditorConfigProperties {
        EditorConfigResolver.resolve(
            fileURL: tree.url(path),
            projectRoot: projectRoot ?? tree.root,
            fileService: tree
        )
    }

    // MARK: - The walk

    func testAConfigInTheFilesOwnDirectoryApplies() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "a.swift": "",
        ])
        let properties = resolve("a.swift", in: tree)
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 2)
    }

    func testACloserConfigOverridesAnOuterOnePerProperty() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\ncharset = utf-8\n",
            "src/.editorconfig": "[*]\nindent_size = 4\n",
            "src/a.swift": "",
        ])
        let properties = resolve("src/a.swift", in: tree)
        // Only `indent_size` was restated; the other two survive from the outer
        // file, which is what "overwriting per property" means.
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 4)
        XCTAssertEqual(properties["charset"], "utf-8")
    }

    func testTheWalkCrossesEveryInterveningDirectory() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\n",
            "a/.editorconfig": "[*]\nindent_size = 3\n",
            "a/b/.editorconfig": "[*]\ncharset = latin1\n",
            "a/b/c.swift": "",
        ])
        let properties = resolve("a/b/c.swift", in: tree)
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 3)
        XCTAssertEqual(properties["charset"], "latin1")
    }

    func testRootTrueStopsTheWalk() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/.editorconfig": "root = true\n[*]\nindent_size = 8\n",
            "src/a.swift": "",
        ])
        let properties = resolve("src/a.swift", in: tree)
        XCTAssertEqual(properties.indentWidth, 8)
        // The outer file was never consulted, so its `indent_style` is absent…
        XCTAssertNil(properties.indentStyle)
        // …and it was never even read.
        XCTAssertEqual(tree.readPaths, ["src/.editorconfig"])
    }

    func testAConfigAboveTheProjectRootIsNeverRead() {
        // The stub tree's root is the *parent* of the project, so the outer
        // config exists on disk and must still be invisible.
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = tab\nindent_size = 8\n",
            "project/.editorconfig": "[*]\nindent_style = space\n",
            "project/a.swift": "",
        ], root: "/workspace")
        let properties = EditorConfigResolver.resolve(
            fileURL: tree.url("project/a.swift"),
            projectRoot: tree.url("project"),
            fileService: tree
        )
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertNil(properties.indentWidth)
        XCTAssertEqual(tree.readPaths, ["project/.editorconfig"])
    }

    func testTheProjectRootsOwnConfigIsReadEvenWithoutRootTrue() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n",
            "src/a.swift": "",
        ])
        XCTAssertEqual(resolve("src/a.swift", in: tree).indentWidth, 2)
    }

    func testAMissingConfigIsSimplySkipped() {
        let tree = tree(["src/a.swift": ""])
        XCTAssertTrue(resolve("src/a.swift", in: tree).isEmpty)
    }

    func testAnUnreadableConfigDegradesToNoPropertiesRatherThanFailingTheWalk() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/.editorconfig": "root = true\n[*]\nindent_size = 8\n",
            "src/a.swift": "",
        ])
        tree.unreadableFiles = ["src/.editorconfig"]
        let properties = resolve("src/a.swift", in: tree)
        // The unreadable file contributed nothing — including its `root = true`,
        // so the walk continued outward and the outer file still applied.
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 2)
    }

    func testAnOversizeConfigIsSkippedTheSameWayAnUnreadableOneIs() {
        // The walk runs synchronously inside the Enter and Tab key handlers over
        // a file a clone brought in, so a `.editorconfig` far past anything a
        // person writes must not be decoded and line-split on the keystroke. Over
        // the cap degrades to "no properties from that directory" — including its
        // `root = true`, exactly as an unreadable one does.
        let padding = String(repeating: "# padding\n", count: EditorConfigResolver.maximumFileBytes / 10 + 1)
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/.editorconfig": "root = true\n[*]\nindent_size = 8\n" + padding,
            "src/a.swift": "",
        ])
        XCTAssertGreaterThan(tree.files["src/.editorconfig"]?.utf8.count ?? 0, EditorConfigResolver.maximumFileBytes)
        let properties = resolve("src/a.swift", in: tree)
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 2)
    }

    // MARK: - Section matching and order

    func testALaterMatchingSectionWinsInsideOneFile() {
        let tree = tree([
            ".editorconfig": """
            [*]
            indent_style = space
            indent_size = 2

            [*.swift]
            indent_size = 4
            """,
            "a.swift": "",
            "a.txt": "",
        ])
        XCTAssertEqual(resolve("a.swift", in: tree).indentWidth, 4)
        XCTAssertEqual(resolve("a.txt", in: tree).indentWidth, 2)
    }

    func testAnEarlierSectionStillAppliesWhereALaterOneIsSilent() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n[*.swift]\nindent_size = 4\n",
            "a.swift": "",
        ])
        let properties = resolve("a.swift", in: tree)
        XCTAssertEqual(properties.indentStyle, .space)
        XCTAssertEqual(properties.indentWidth, 4)
    }

    func testSectionGlobsMatchThePathRelativeToTheirOwnDirectory() {
        let tree = tree([
            ".editorconfig": "[src/*.swift]\nindent_size = 2\n",
            "src/.editorconfig": "[src/*.swift]\nindent_size = 9\n",
            "src/a.swift": "",
        ])
        // The outer section's `src/a.swift` matches; the inner file's identical
        // section is anchored to `src/`, where the file is just `a.swift`.
        XCTAssertEqual(resolve("src/a.swift", in: tree).indentWidth, 2)
    }

    func testANonMatchingSectionContributesNothing() {
        let tree = tree([
            ".editorconfig": "[*.py]\nindent_size = 2\n",
            "a.swift": "",
        ])
        XCTAssertTrue(resolve("a.swift", in: tree).isEmpty)
    }

    // MARK: - `unset`

    func testUnsetClearsAnInheritedProperty() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_style = space\nindent_size = 2\n",
            "src/.editorconfig": "[*]\nindent_size = unset\n",
            "src/a.swift": "",
        ])
        let properties = resolve("src/a.swift", in: tree)
        XCTAssertNil(properties["indent_size"])
        XCTAssertNil(properties.indentSize)
        XCTAssertEqual(properties.indentStyle, .space)
    }

    func testUnsetIsComparedCaseInsensitively() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n",
            "src/.editorconfig": "[*]\nindent_size = UNSET\n",
            "src/a.swift": "",
        ])
        XCTAssertNil(resolve("src/a.swift", in: tree)["indent_size"])
    }

    func testALaterSectionCanUnsetWhatAnEarlierOneInTheSameFileSet() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n[*.swift]\nindent_size = unset\n",
            "a.swift": "",
        ])
        XCTAssertNil(resolve("a.swift", in: tree)["indent_size"])
    }

    // MARK: - Unknown properties

    func testUnknownPropertiesSurviveTheMergeAndOverrideOutwardTheSameWay() {
        let tree = tree([
            ".editorconfig": "[*]\nspell_language = en-GB\nquote_type = single\n",
            "src/.editorconfig": "[*]\nquote_type = double\n",
            "src/a.swift": "",
        ])
        let properties = resolve("src/a.swift", in: tree)
        XCTAssertEqual(properties["spell_language"], "en-GB")
        XCTAssertEqual(properties["quote_type"], "double")
    }

    // MARK: - Outside the project

    func testAFileOutsideTheProjectRootResolvesToEmpty() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n",
            "a.swift": "",
        ])
        let properties = EditorConfigResolver.resolve(
            fileURL: URL(fileURLWithPath: "/elsewhere/a.swift"),
            projectRoot: tree.root,
            fileService: tree
        )
        XCTAssertTrue(properties.isEmpty)
        XCTAssertTrue(tree.readPaths.isEmpty)
    }

    func testANilProjectRootResolvesToEmpty() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n",
            "a.swift": "",
        ])
        let properties = EditorConfigResolver.resolve(
            fileURL: tree.url("a.swift"),
            projectRoot: nil,
            fileService: tree
        )
        XCTAssertTrue(properties.isEmpty)
        XCTAssertTrue(tree.readPaths.isEmpty)
    }

    func testANilFileURLResolvesToEmpty() {
        let tree = tree([".editorconfig": "[*]\nindent_size = 2\n"])
        let properties = EditorConfigResolver.resolve(
            fileURL: nil,
            projectRoot: tree.root,
            fileService: tree
        )
        XCTAssertTrue(properties.isEmpty)
    }

    func testTheProjectRootItselfIsNotInsideItself() {
        let tree = tree([".editorconfig": "[*]\nindent_size = 2\n"])
        let properties = EditorConfigResolver.resolve(
            fileURL: tree.root,
            projectRoot: tree.root,
            fileService: tree
        )
        XCTAssertTrue(properties.isEmpty)
    }

    // MARK: - Reader, never a writer

    func testTheWalkWritesNothing() {
        let tree = tree([
            ".editorconfig": "[*]\nindent_size = 2\n",
            "src/.editorconfig": "[*]\nindent_style = space\n",
            "src/a.swift": "",
        ])
        _ = resolve("src/a.swift", in: tree)
        XCTAssertTrue(tree.writtenPaths.isEmpty)
        XCTAssertTrue(tree.removedPaths.isEmpty)
        XCTAssertTrue(tree.moves.isEmpty)
    }
}
