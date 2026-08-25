import XCTest
@testable import PisakaCore

/// The on-save transform as the app actually runs it: a real `.editorconfig`
/// tree, a real `EditorConfigModel`, a real `WorkspaceModel`, and the same
/// three-step chain the macOS funnel performs — resolve the properties, ask
/// `SaveTransform` for the plan, apply it to the buffer — followed by the save
/// the funnel exists to precede.
///
/// `SaveTransformController` itself lives in `Sources/Pisaka` and is untested by
/// convention, so what is pinned here is the part that has to be right no matter
/// which of its two application paths runs: after a save, **the buffer, the saved
/// baseline and the bytes on disk are the same string**, the tab is clean, and a
/// project that states none of the three properties is written byte for byte as
/// it is today, moving exactly the revision tokens it moves today.
@MainActor
final class SaveTransformIntegrationTests: XCTestCase {

    // MARK: - The funnel, in Core terms

    /// The Core half of `SaveTransformController.prepareForSave`, reproduced
    /// exactly: resolve through the cache, plan, and rewrite the buffer.
    ///
    /// The app's own half chooses only *how* the buffer is rewritten — through
    /// the live text view when the editor still holds it, through
    /// `WorkspaceModel.replaceText(_:for:)` when it does not — and both land the
    /// same string in the model, which is what every assertion below reads.
    /// `protecting` is the caret/selection the editor would hand over; the empty
    /// default is the buffer nobody is looking at (and the shape iOS saves in).
    @discardableResult
    private func prepareForSave(
        _ id: UUID,
        in model: WorkspaceModel,
        editorConfig: EditorConfigModel,
        protecting positions: [Int] = []
    ) -> SaveTransformPlan {
        guard let file = model.openFiles.first(where: { $0.id == id }), let url = file.url else {
            return SaveTransformPlan(replacements: [], text: "")
        }
        let plan = SaveTransform.plan(
            text: file.text,
            config: editorConfig.properties(for: url),
            protectedPositions: positions
        )
        if !plan.isEmpty { model.replaceText(plan.text, for: id) }
        return plan
    }

    private func tree(_ files: [String: String]) -> StubFileTree {
        StubFileTree(root: URL(fileURLWithPath: "/project"), files: files)
    }

    /// A workspace and a config cache over the same tree, with `path` opened.
    private func staged(
        _ files: [String: String],
        opening path: String
    ) throws -> (tree: StubFileTree, model: WorkspaceModel, config: EditorConfigModel, id: UUID) {
        let tree = tree(files)
        let model = WorkspaceModel(fileService: tree)
        let config = EditorConfigModel(fileService: tree, projectRoot: tree.root)
        let file = try model.open(url: tree.url(path))
        return (tree, model, config, file.id)
    }

    // MARK: - The buffer, the baseline and the bytes agree

    func testATransformedSaveLeavesTheTabCleanAndAllThreeCopiesIdentical() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ntrim_trailing_whitespace = true\ninsert_final_newline = true\n",
            "a.swift": "let a = 1\n",
        ], opening: "a.swift")
        // An edit that leaves the buffer needing both transforms: a trailing run
        // on the middle line and no final terminator at all.
        staged.model.updateText("let a = 1   \nlet b = 2", for: staged.id)
        XCTAssertTrue(staged.model.isDirty(for: staged.id))

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertEqual(try staged.model.save(for: staged.id), .saved)

        let expected = "let a = 1\nlet b = 2\n"
        XCTAssertEqual(staged.model.text(for: staged.id), expected, "the buffer holds the transformed text")
        XCTAssertEqual(staged.tree.files["a.swift"], expected, "and so do the bytes on disk")
        XCTAssertFalse(
            staged.model.isDirty(for: staged.id),
            "the baseline advanced to the same text, so the tab is clean rather than dirty-again"
        )
    }

    func testTheSecondSaveOfTheSameBufferWritesNothingNew() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ntrim_trailing_whitespace = true\nend_of_line = lf\n",
            "a.swift": "let a = 1\n",
        ], opening: "a.swift")
        staged.model.updateText("let a = 1\t\r\nlet b = 2  \r\n", for: staged.id)

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        try staged.model.save(for: staged.id)
        let afterFirst = staged.tree.files["a.swift"]
        let writesAfterFirst = staged.tree.writtenPaths.count

        // Idempotence, end to end: the plan for the transformed text is empty, so
        // nothing rewrites the buffer, nothing is dirty, and `save` — which writes
        // unconditionally — writes the very same bytes.
        let second = prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertTrue(second.isEmpty, "the transformed buffer must plan no further edits")
        XCTAssertFalse(staged.model.isDirty(for: staged.id))
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], afterFirst)
        XCTAssertEqual(staged.tree.writtenPaths.count, writesAfterFirst + 1, "the same bytes, written again")
    }

    // MARK: - The positions the save must not lose

    func testTheRemappedSelectionAndAnchorComeFromTheEngine() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ntrim_trailing_whitespace = true\n",
            "a.swift": "",
        ], opening: "a.swift")
        //  0123456789…
        // "aa   \nbb   \ncc"  — two trailing runs, both before the positions below.
        staged.model.updateText("aa   \nbb   \ncc", for: staged.id)
        // The caret sits on the last line, which has no trailing run of its own,
        // so nothing is spared and both runs are trimmed.
        let viewport = EditorViewport(selection: NSRange(location: 13, length: 1), topCharacterOffset: 6)

        let plan = prepareForSave(
            staged.id,
            in: staged.model,
            editorConfig: staged.config,
            protecting: [viewport.selection.location, NSMaxRange(viewport.selection)]
        )

        XCTAssertEqual(staged.model.text(for: staged.id), "aa\nbb\ncc")
        // Six characters of whitespace vanished before the anchor and the caret:
        // three before offset 6, six before offset 13.
        XCTAssertEqual(plan.remappedViewport(viewport), EditorViewport(
            selection: NSRange(location: 7, length: 1),
            topCharacterOffset: 3
        ))
    }

    func testTheCaretLineSurvivesTheSaveAndIsTrimmedByTheNextOneAfterTheCaretMoves() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ntrim_trailing_whitespace = true\n",
            "a.swift": "",
        ], opening: "a.swift")
        // Someone typed an indent on line 2 and the idle autosave fired.
        staged.model.updateText("if x {\n    \n}\n", for: staged.id)

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config, protecting: [11])
        try staged.model.save(for: staged.id)
        XCTAssertEqual(
            staged.tree.files["a.swift"],
            "if x {\n    \n}\n",
            "the indentation under the caret is what the spared-line rule exists to protect"
        )

        // The caret moved away (to the top of the file); the next save trims it.
        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config, protecting: [0])
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], "if x {\n\n}\n")
    }

    func testABufferWithNoProtectedPositionsIsTrimmedInFull() throws {
        // The background tab an autosave catches, and the shape the iOS save has:
        // no editor hands over a caret, so no line is spared.
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ntrim_trailing_whitespace = true\n",
            "a.swift": "",
        ], opening: "a.swift")
        staged.model.updateText("if x {\n    \n}\n", for: staged.id)

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], "if x {\n\n}\n")
    }

    // MARK: - The autosave shape: several buffers, one tick

    func testAnAutosaveTickTransformsEveryDirtyTitledBufferAndWritesThemAll() throws {
        let tree = tree([
            ".editorconfig": "root = true\n[*]\nend_of_line = crlf\ninsert_final_newline = true\n",
            "a.swift": "a\r\n",
            "b.swift": "b\r\n",
            "c.swift": "c\r\n",
        ])
        let model = WorkspaceModel(fileService: tree)
        let config = EditorConfigModel(fileService: tree, projectRoot: tree.root)
        let a = try model.open(url: tree.url("a.swift")).id
        let b = try model.open(url: tree.url("b.swift")).id
        let clean = try model.open(url: tree.url("c.swift")).id
        model.updateText("a1\na2", for: a)
        model.updateText("b1\nb2", for: b)

        // Exactly what `AutosaveController` hands the funnel: the dirty, titled ids.
        let dirty = model.openFiles.filter { $0.isDirty && $0.url != nil }.map(\.id)
        XCTAssertEqual(Set(dirty), [a, b])
        for id in dirty { prepareForSave(id, in: model, editorConfig: config) }
        let written = model.saveAllDirty()

        XCTAssertEqual(Set(written.map(\.lastPathComponent)), ["a.swift", "b.swift"])
        XCTAssertEqual(tree.files["a.swift"], "a1\r\na2\r\n")
        XCTAssertEqual(tree.files["b.swift"], "b1\r\nb2\r\n")
        XCTAssertEqual(tree.files["c.swift"], "c\r\n", "a clean tab is not in the set and is never rewritten")
        XCTAssertFalse(model.isDirty(for: clean))
    }

    // MARK: - The iOS save

    func testTheIOSSaveTransformsTheClosingBufferAndWritesWhatTheConfigurationAsked() throws {
        // iOS has exactly one save — the close confirmation — and it runs the same
        // Core chain with no editor attached: no caret is handed over, because the
        // buffer is on its way out. All three properties at once, so the composed
        // plan is what reaches the disk.
        let staged = try staged([
            ".editorconfig": """
            root = true
            [*]
            end_of_line = crlf
            trim_trailing_whitespace = true
            insert_final_newline = true
            """,
            "a.swift": "",
        ], opening: "a.swift")
        staged.model.updateText("let a = 1  \nlet b = 2\t", for: staged.id)

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertEqual(try staged.model.save(for: staged.id), .saved)

        let expected = "let a = 1\r\nlet b = 2\r\n"
        XCTAssertEqual(staged.tree.files["a.swift"], expected)
        XCTAssertEqual(staged.model.text(for: staged.id), expected)
        XCTAssertFalse(
            staged.model.isDirty(for: staged.id),
            "the tab is clean, so closing it after this save prompts nothing further"
        )
    }

    func testTheIOSSaveOfAProjectWithoutAConfigurationWritesTheBufferByteForByte() throws {
        let staged = try staged(["a.swift": ""], opening: "a.swift")
        let edited = "let a = 1  \r\nlet b = 2   "
        staged.model.updateText(edited, for: staged.id)

        XCTAssertTrue(prepareForSave(staged.id, in: staged.model, editorConfig: staged.config).isEmpty)
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], edited)
    }

    // MARK: - Enter and the save agree about the terminator

    func testAReturnSplicedTerminatorSurvivesTheNextSaveUntouched() throws {
        // The two halves of `end_of_line`, composed the way the coordinators
        // compose them: the Return handler splices the configured terminator, and
        // the save that follows therefore finds nothing to normalize. Enter writing
        // LF into a CRLF project would instead leave the save to come back and fix
        // the one line that was just typed.
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\nend_of_line = crlf\n",
            "a.swift": "",
        ], opening: "a.swift")
        staged.model.updateText("if x {\r\n}", for: staged.id)

        let config = staged.config.properties(for: staged.tree.url("a.swift"))
        let terminator = config.endOfLine?.terminator ?? "\n"
        XCTAssertEqual(terminator, "\r\n")
        // Return pressed just inside the brace, exactly as the coordinators call it.
        let text = staged.model.text(for: staged.id) as NSString? ?? ""
        let edit = IndentEngine.newlineIndentation(
            text: text,
            location: 6,
            unit: "    ",
            terminator: terminator
        )
        let typed = text.replacingCharacters(
            in: NSRange(location: 6, length: edit.consumeAfter),
            with: edit.text
        )
        staged.model.updateText(typed, for: staged.id)

        let plan = prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertTrue(plan.isEmpty, "what Enter spliced is already what the configuration asked for")
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], typed)
        XCTAssertTrue(typed.hasPrefix("if x {\r\n"), "the terminator Enter wrote is the configured one")
    }

    // MARK: - A project without `.editorconfig` behaves exactly as before

    func testWithoutAConfigurationTheBytesAndEveryRevisionTokenAreUnchanged() throws {
        let staged = try staged(["a.swift": "let a = 1\n"], opening: "a.swift")
        // Trailing whitespace, CRLF terminators and no final newline — everything
        // the three properties would touch, in a project that asks for none of it.
        let edited = "let a = 1  \r\n\tlet b = 2   "
        staged.model.updateText(edited, for: staged.id)
        let replacementsBefore = staged.model.textReplacementRevision(for: staged.id)
        let diskBefore = staged.model.diskRevision(for: staged.id)

        let plan = prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertTrue(plan.isEmpty, "no configuration must plan no edits at all")
        try staged.model.save(for: staged.id)

        XCTAssertEqual(staged.tree.files["a.swift"], edited, "byte for byte what the buffer held")
        XCTAssertEqual(
            staged.model.textReplacementRevision(for: staged.id),
            replacementsBefore,
            "nothing rewrote the buffer, so no tab loses its undo stack"
        )
        XCTAssertEqual(
            staged.model.diskRevision(for: staged.id),
            diskBefore + 1,
            "the save moves the disk token exactly once, as it does today"
        )
    }

    func testAConfigurationStatingOnlyIndentationPropertiesChangesNothing() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\nindent_style = space\nindent_size = 2\ntab_width = 4\n",
            "a.swift": "",
        ], opening: "a.swift")
        let edited = "let a = 1  \r\nlet b = 2"
        staged.model.updateText(edited, for: staged.id)

        let plan = prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)
        XCTAssertTrue(plan.isEmpty, "part 1's properties are not part 2's; none of them triggers a rewrite")
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], edited)
    }

    func testAFileOutsideTheConfiguredSectionIsNotTransformed() throws {
        let staged = try staged([
            ".editorconfig": "root = true\n[*.md]\ntrim_trailing_whitespace = true\n",
            "a.swift": "",
        ], opening: "a.swift")
        let edited = "let a = 1   \n"
        staged.model.updateText(edited, for: staged.id)

        XCTAssertTrue(prepareForSave(staged.id, in: staged.model, editorConfig: staged.config).isEmpty)
        try staged.model.save(for: staged.id)
        XCTAssertEqual(staged.tree.files["a.swift"], edited)
    }

    // MARK: - The off-screen cost is real and bounded

    func testRewritingABufferThroughTheModelBumpsItsTextReplacementToken() throws {
        // The background-tab path: there is no editor holding this buffer, so the
        // rewrite goes through `replaceText`, whose token bump is what makes the
        // editor drop that tab's undo stack and remembered viewport when it is
        // next displayed. Stated as a test so the cost cannot be lost silently.
        let staged = try staged([
            ".editorconfig": "root = true\n[*]\ninsert_final_newline = true\n",
            "a.swift": "",
        ], opening: "a.swift")
        staged.model.updateText("let a = 1", for: staged.id)
        let before = staged.model.textReplacementRevision(for: staged.id)

        prepareForSave(staged.id, in: staged.model, editorConfig: staged.config)

        XCTAssertEqual(staged.model.text(for: staged.id), "let a = 1\n")
        XCTAssertEqual(staged.model.textReplacementRevision(for: staged.id), before + 1)
    }
}
