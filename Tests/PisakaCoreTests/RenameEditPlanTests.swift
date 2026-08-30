import XCTest
@testable import PisakaCore

/// The rename engine's two moments — build and apply — and the five
/// refusals that keep a rename all-or-nothing.
///
/// This is the one Core file whose output is a *write*, so the cases here are
/// weighted towards everything that must stop one: a server naming a file outside
/// the project, coordinates that do not fit the text in hand, two edits that
/// overlap, and a file that moved between the answer and the apply.
final class RenameEditPlanTests: XCTestCase {

    // MARK: - Fixtures

    private let root = URL(fileURLWithPath: "/p/root")

    private func uri(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    /// The LSP range covering `length` units from `character` on `line`.
    private func range(line: Int, character: Int, length: Int) -> LSPRange {
        LSPRange(
            start: LSPPosition(line: line, character: character),
            end: LSPPosition(line: line, character: character + length)
        )
    }

    private func edit(line: Int, character: Int, length: Int, newText: String) -> LSPTextEdit {
        LSPTextEdit(range: range(line: line, character: character, length: length), newText: newText)
    }

    private func texts(_ pairs: [String: String]) -> (URL) -> String? {
        { url in pairs[url.path] }
    }

    // MARK: - Construction

    /// The two wire spellings are two ways of saying one thing; a plan that
    /// differed between them would make a rename depend on which shape the server
    /// happened to pick.
    func testBothWorkspaceEditSpellingsProduceTheSamePlan() {
        let text = "let count = 1\nprint(count)\n"
        let file = "/p/root/a.swift"
        let edits = [
            edit(line: 0, character: 4, length: 5, newText: "total"),
            edit(line: 1, character: 6, length: 5, newText: "total"),
        ]
        let changes = LSPWorkspaceEdit(documents: [LSPDocumentEdits(uri: uri(file), edits: edits)])
        let documentChanges = LSPWorkspaceEdit(
            documents: [LSPDocumentEdits(uri: uri(file), version: 7, edits: edits)]
        )
        let sources = texts([file: text])

        let fromChanges = try? RenameEditPlan.make(from: changes, root: root, texts: sources).get()
        let fromDocuments = try? RenameEditPlan.make(
            from: documentChanges, root: root, texts: sources
        ).get()

        XCTAssertNotNil(fromChanges)
        XCTAssertEqual(fromChanges, fromDocuments)
        XCTAssertEqual(fromChanges?.files.count, 1)
        XCTAssertEqual(fromChanges?.editCount, 2)
        XCTAssertEqual(fromChanges?.files.first?.relativePath, "a.swift")
        XCTAssertEqual(
            fromChanges?.files.first?.edits.map(\.expectedText),
            ["count", "count"]
        )
    }

    /// Ordering is by canonical path so an unordered `changes` map and a
    /// server-chosen `documentChanges` order both capture, verify and write in the
    /// same order on every run.
    func testFilesAreOrderedByPath() {
        let one = [edit(line: 0, character: 0, length: 3, newText: "bar")]
        let plan = try? RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri("/p/root/z.swift"), edits: one),
                LSPDocumentEdits(uri: uri("/p/root/a.swift"), edits: one),
                LSPDocumentEdits(uri: uri("/p/root/m.swift"), edits: one),
            ]),
            root: root,
            texts: texts([
                "/p/root/z.swift": "foo\n", "/p/root/a.swift": "foo\n", "/p/root/m.swift": "foo\n",
            ])
        ).get()

        XCTAssertEqual(
            plan?.files.map(\.relativePath),
            ["a.swift", "m.swift", "z.swift"]
        )
        XCTAssertEqual(plan?.fileURLs.map(\.lastPathComponent), ["a.swift", "m.swift", "z.swift"])
    }

    /// `documentChanges` is a list: one document may appear twice, and the two
    /// entries' edits are one file's edits. Sorting them apart would leave a
    /// descending pair no back-to-front application survives.
    func testTwoEntriesForOneFileAreMergedAndSortedTogether() {
        let text = "foo foo foo\n"
        let file = "/p/root/a.swift"
        let plan = try? RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(
                    uri: uri(file), edits: [edit(line: 0, character: 8, length: 3, newText: "bar")]
                ),
                LSPDocumentEdits(
                    uri: uri(file),
                    edits: [
                        edit(line: 0, character: 0, length: 3, newText: "bar"),
                        edit(line: 0, character: 4, length: 3, newText: "bar"),
                    ]
                ),
            ]),
            root: root,
            texts: texts([file: text])
        ).get()

        XCTAssertEqual(plan?.files.count, 1)
        XCTAssertEqual(plan?.files.first?.edits.map(\.range.location), [0, 4, 8])
        XCTAssertEqual(plan?.files.first?.applied(to: text)?.text, "bar bar bar\n")
    }

    /// A document with no edits is not a file the rename touches, so it must not
    /// reach the capture's target list.
    func testADocumentWithNoEditsIsNotAFileInThePlan() {
        let plan = try? RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [LSPDocumentEdits(uri: uri("/p/root/a.swift"), edits: [])]),
            root: root,
            texts: texts(["/p/root/a.swift": "foo\n"])
        ).get()

        XCTAssertEqual(plan?.files, [])
        XCTAssertTrue(plan?.isEmpty == true)
        XCTAssertEqual(plan?.editCount, 0)
    }

    // MARK: - Refusals

    func testOverlappingEditsInOneFileAreRefused() {
        let file = "/p/root/a.swift"
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(file), edits: [
                    edit(line: 0, character: 0, length: 5, newText: "bar"),
                    edit(line: 0, character: 3, length: 4, newText: "baz"),
                ]),
            ]),
            root: root,
            texts: texts([file: "abcdefgh\n"])
        )

        XCTAssertEqual(result.refusal, .overlapping(URL(fileURLWithPath: file)))
    }

    /// Two zero-length edits at one offset do not overlap by the ascending test
    /// and are still two answers to one question.
    func testTwoEmptyEditsAtOneOffsetAreRefused() {
        let file = "/p/root/a.swift"
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(file), edits: [
                    edit(line: 0, character: 2, length: 0, newText: "x"),
                    edit(line: 0, character: 2, length: 0, newText: "y"),
                ]),
            ]),
            root: root,
            texts: texts([file: "abcdefgh\n"])
        )

        XCTAssertEqual(result.refusal, .overlapping(URL(fileURLWithPath: file)))
    }

    func testAFileOutsideTheRootIsRefused() {
        let outside = "/p/elsewhere/a.swift"
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(outside), edits: [
                    edit(line: 0, character: 0, length: 3, newText: "bar"),
                ]),
            ]),
            root: root,
            texts: texts([outside: "foo\n"])
        )

        XCTAssertEqual(result.refusal, .outsideRoot(URL(fileURLWithPath: outside)))
    }

    /// The root itself is not inside the root: a `WorkspaceEdit` naming the
    /// directory is not a file this can rewrite.
    func testTheRootItselfIsOutsideTheRoot() {
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(root.path), edits: [
                    edit(line: 0, character: 0, length: 3, newText: "bar"),
                ]),
            ]),
            root: root,
            texts: texts([root.path: "foo\n"])
        )

        XCTAssertEqual(result.refusal?.fileURL?.lastPathComponent, "root")
    }

    /// A server resolves the path *it* sees. A project opened as `/tmp/…` is
    /// answered about as `/private/tmp/…` on this platform, and a lexical prefix
    /// test would refuse every rename in such a project. The comparison is
    /// canonical, so both spellings name one file.
    func testThePrivateSpellingOfTheRootIsStillInsideIt() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rename-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = base.appendingPathComponent("a.swift")
        try "foo\n".write(to: file, atomically: true, encoding: .utf8)
        // The other spelling of the same file, as a server would resolve it.
        let resolved = URL(fileURLWithPath: "/private" + file.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))

        let plan = try RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: resolved.absoluteString, edits: [
                    edit(line: 0, character: 0, length: 3, newText: "bar"),
                ]),
            ]),
            root: base,
            texts: { _ in "foo\n" }
        ).get()

        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files.first?.relativePath, "a.swift")
    }

    func testANonFileURIIsRefused() {
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: "untitled:Untitled-1", edits: [
                    edit(line: 0, character: 0, length: 3, newText: "bar"),
                ]),
            ]),
            root: root,
            texts: { _ in "foo\n" }
        )

        XCTAssertEqual(result.refusal, .notAFile(uri: "untitled:Untitled-1"))
        XCTAssertNil(result.refusal?.fileURL)
    }

    func testAFileWhoseTextCannotBeReadIsRefused() {
        let file = "/p/root/a.swift"
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(file), edits: [
                    edit(line: 0, character: 0, length: 3, newText: "bar"),
                ]),
            ]),
            root: root,
            texts: { _ in nil }
        )

        XCTAssertEqual(result.refusal, .unreadable(URL(fileURLWithPath: file)))
    }

    /// `LSPPositionMap` clamps, rightly, for every caller that is navigating. A
    /// write is the one case where the clamp is the bug, so coordinates that do
    /// not exist in the text refuse instead of landing somewhere plausible.
    func testCoordinatesThatDoNotFitTheTextAreRefused() {
        let file = "/p/root/a.swift"
        let cases: [(String, LSPRange)] = [
            ("a line past the end", range(line: 9, character: 0, length: 3)),
            ("a character past the line", range(line: 0, character: 40, length: 3)),
            (
                "an end before its start",
                LSPRange(
                    start: LSPPosition(line: 1, character: 2),
                    end: LSPPosition(line: 0, character: 1)
                )
            ),
        ]

        for (name, wire) in cases {
            let result = RenameEditPlan.make(
                from: LSPWorkspaceEdit(documents: [
                    LSPDocumentEdits(uri: uri(file), edits: [LSPTextEdit(range: wire, newText: "bar")]),
                ]),
                root: root,
                texts: texts([file: "let foo = 1\nprint(foo)\n"])
            )
            XCTAssertEqual(result.refusal, .unmappable(URL(fileURLWithPath: file)), name)
        }
    }

    /// A position between the two halves of a CRLF is a coordinate the editor's
    /// own text has no offset for; clamping it would move the write.
    func testAPositionInsideACRLFIsRefused() {
        let file = "/p/root/a.swift"
        let result = RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: [
                LSPDocumentEdits(uri: uri(file), edits: [
                    LSPTextEdit(
                        range: LSPRange(
                            start: LSPPosition(line: 0, character: 4),
                            end: LSPPosition(line: 1, character: 0)
                        ),
                        newText: "bar"
                    ),
                ]),
            ]),
            root: root,
            texts: texts([file: "foo\r\nfoo\r\n"])
        )

        XCTAssertEqual(result.refusal, .unmappable(URL(fileURLWithPath: file)))
    }

    /// Every refusal says something, and says it about the file it is about.
    func testEveryRefusalRendersANonEmptyReason() {
        let url = URL(fileURLWithPath: "/p/root/a.swift")
        let refusals: [RenameRefusal] = [
            .notAFile(uri: "untitled:1"), .outsideRoot(url), .unreadable(url),
            .unmappable(url), .overlapping(url),
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.reason.isEmpty)
        }
        for refusal in refusals.dropFirst() {
            XCTAssertTrue(refusal.reason.contains("a.swift"), refusal.reason)
            XCTAssertEqual(refusal.fileURL, url)
        }
    }

    // MARK: - Verification

    /// Verification is not a step of its own: `apply` re-reads every file and
    /// vouches for all of them before writing any. These cases pin what that pass
    /// answers, through the one method that performs it.

    /// A file that shrank past a range's end must answer "stale", not trap.
    func testAShorterTextIsStaleRatherThanATrap() throws {
        let text = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(root: root, files: ["a.swift": "let"])
        let plan = try makePlan(file: "/p/root/a.swift", text: text)

        XCTAssertEqual(
            plan.apply(bufferText: { _ in nil }, fileService: tree),
            .stale(tree.url("a.swift"))
        )
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// The texts verification sees come from the open buffer where one exists — a
    /// buffer whose unsaved edits moved the range is stale even though the disk
    /// copy still matches.
    func testVerificationSeesTheBufferRatherThanTheDisk() throws {
        let disk = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(root: root, files: ["a.swift": disk])
        let plan = try makePlan(file: "/p/root/a.swift", text: disk)

        XCTAssertEqual(
            plan.apply(bufferText: { _ in "// typed since\n" + disk }, fileService: tree),
            .stale(tree.url("a.swift"))
        )
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// The first mismatch names itself and stops; the answer to "which files are
    /// stale" changes nothing a caller does.
    func testVerificationNamesTheFileThatMoved() throws {
        let text = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(
            root: root,
            // One space inserted at the head: every range in `b` now holds
            // something else.
            files: ["a.swift": text, "b.swift": " " + text]
        )
        let plan = try makePlan(files: ["/p/root/a.swift": text, "/p/root/b.swift": text])

        XCTAssertEqual(
            plan.apply(bufferText: { _ in nil }, fileService: tree),
            .stale(tree.url("b.swift"))
        )
    }

    /// Verification asks `NSString`'s sameness question, not Swift's.
    ///
    /// The discriminating case is a *singleton* composition — U+212B ANGSTROM
    /// SIGN and U+00C5 are canonically equivalent, one UTF-16 unit each, and
    /// different bytes — because it keeps every offset in the plan valid while
    /// changing what the text actually holds. Swift's `==` is canonical
    /// equivalence and vouches for it; the plan's ranges are UTF-16 offsets
    /// measured against exact bytes, and rewriting a buffer the server was never
    /// shown is the thing verification exists to refuse. This is the rule
    /// `SaveTransformController.applyRestore` and `LocalHistoryBrowserModel
    /// .plannedRestore` already ask, and it is the premise `PisakaApp.applyRename`
    /// names when it matches an open tab byte-for-byte.
    func testVerificationComparesBytesRatherThanCanonicalEquivalence() {
        let expected = "\u{212B}ngstrom"
        let equivalent = "\u{00C5}ngstrom"
        XCTAssertEqual(expected, equivalent, "the two spellings are canonically equivalent")
        XCTAssertEqual(
            (expected as NSString).length,
            (equivalent as NSString).length,
            "…and the same UTF-16 length, so every offset in the plan stays in bounds"
        )
        XCTAssertNotEqual(Array(expected.utf8), Array(equivalent.utf8), "…and are different bytes")

        let file = RenameFilePlan(
            fileURL: root.appendingPathComponent("a.swift"),
            relativePath: "a.swift",
            edits: [
                RenameEdit(
                    range: NSRange(location: 0, length: (expected as NSString).length),
                    newText: "Renamed",
                    expectedText: expected
                ),
            ]
        )

        XCTAssertTrue(file.holds(in: expected))
        XCTAssertFalse(
            file.holds(in: equivalent),
            "a buffer holding other bytes must read as stale, not as a match"
        )
    }

    // MARK: - Application

    func testAppliedRewritesEveryEditAndRemapsPositions() throws {
        let file = "/p/root/a.swift"
        let text = "let count = 1\nprint(count)\nlet other = count\n"
        let plan = try makePlan(file: file, text: text, identifier: "count", newName: "total")

        let applied = try XCTUnwrap(plan.files.first?.applied(to: text))

        XCTAssertEqual(applied.text, "let total = 1\nprint(total)\nlet other = total\n")
        XCTAssertEqual(applied.replacements.count, 3)
        // A caret before every edit does not move; one after them all shifts by
        // the net length of the three.
        XCTAssertEqual(applied.remappedOffset(0), 0)
        XCTAssertEqual(
            applied.remappedOffset((text as NSString).length),
            (applied.text as NSString).length
        )
    }

    /// The line terminator is not part of any edit, so a CRLF file comes back with
    /// its terminators byte-for-byte.
    func testAppliedPreservesCRLFTerminators() throws {
        let file = "/p/root/a.swift"
        let text = "let count = 1\r\nprint(count)\r\n"
        let plan = try makePlan(file: file, text: text, identifier: "count", newName: "n")

        let applied = try XCTUnwrap(plan.files.first?.applied(to: text))

        XCTAssertEqual(applied.text, "let n = 1\r\nprint(n)\r\n")
    }

    /// The last gate before a write: `applied(to:)` re-checks what verification
    /// checked, because the text it is handed is the one being rewritten.
    func testAppliedRefusesTextThePlanWasNotBuiltAgainst() throws {
        let file = "/p/root/a.swift"
        let plan = try makePlan(file: file, text: "let count = 1\nprint(count)\n")

        XCTAssertNil(plan.files.first?.applied(to: "let count = 1\n"))
        XCTAssertNil(plan.files.first?.applied(to: "let amount = 1\nprint(amount)\n"))
    }

    func testEveryFileInAMultiFilePlanAppliesIndependently() throws {
        let first = "/p/root/a.swift"
        let second = "/p/root/b.swift"
        let text = "let count = 1\nprint(count)\n"
        let plan = try makePlan(files: [first: text, second: text], newName: "total")

        for file in plan.files {
            XCTAssertEqual(file.applied(to: text)?.text, "let total = 1\nprint(total)\n")
        }
    }

    // MARK: - The new name

    /// The dialog's two refusals, which are the only two things it may say — and
    /// the empty field, which it says nothing about.
    func testTheNameRuleAcceptsAnIdentifierThatDiffers() {
        XCTAssertNil(RenameNameRule.rejection(of: "total", replacing: "count"))
        XCTAssertNil(RenameNameRule.rejection(of: "_total2", replacing: "count"))
        XCTAssertNil(RenameNameRule.rejection(of: "счётчик", replacing: "count"))
    }

    func testTheNameRuleRefusesAnythingThatIsNotOneIdentifier() {
        for name in ["two words", "a.b", "1st", "total()", "a-b", " total"] {
            XCTAssertEqual(
                RenameNameRule.rejection(of: name, replacing: "count"),
                "A symbol name must be a single identifier.",
                "\(name) is not a single identifier"
            )
        }
    }

    func testTheNameRuleRefusesTheNameItAlreadyHas() {
        XCTAssertEqual(
            RenameNameRule.rejection(of: "count", replacing: "count"),
            "The new name must differ from the current one."
        )
    }

    /// Incomplete input, not a mistake: the dialog disables OK for a blank field
    /// and shows no red line under it.
    func testTheNameRuleSaysNothingAboutABlankField() {
        XCTAssertNil(RenameNameRule.rejection(of: "", replacing: "count"))
    }

    // MARK: - Applying

    /// The disk half and the buffer half of one apply, told apart by which files
    /// a tab holds — decision 5's whole shape, asserted rather than described.
    func testFilesWithNoBufferAreWrittenAndFilesWithOneComeBackAsRewrites() throws {
        let text = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(root: root, files: ["a.swift": text, "b.swift": text])
        let plan = try makePlan(files: ["/p/root/a.swift": text, "/p/root/b.swift": text])

        let outcome = plan.apply(
            bufferText: { url in url.lastPathComponent == "a.swift" ? text : nil },
            fileService: tree
        )

        guard case .applied(let application) = outcome else {
            return XCTFail("expected the plan to apply, got \(outcome)")
        }
        XCTAssertNil(application.writeFailure)
        // `a.swift` has a tab: nothing was written for it, and the caller is
        // handed the plan to apply through the editor instead.
        XCTAssertEqual(application.filesWritten, [tree.url("b.swift")])
        XCTAssertEqual(application.bufferRewrites.map(\.fileURL), [tree.url("a.swift")])
        XCTAssertEqual(
            application.bufferRewrites.first?.plan.text,
            "let total = 1\nprint(total)\n"
        )
        // The buffer's file is untouched on disk — writing under an open tab is
        // the one thing this split exists to prevent.
        XCTAssertEqual(tree.files["a.swift"], text)
        XCTAssertEqual(tree.files["b.swift"], "let total = 1\nprint(total)\n")
    }

    /// The buffer beats the disk, and it is the buffer's text that is rewritten:
    /// a dirty tab is what the user is looking at.
    func testABufferIsPreferredOverTheDiskCopy() throws {
        let text = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(root: root, files: ["a.swift": text])
        let plan = try makePlan(file: "/p/root/a.swift", text: text)
        let buffer = text + "// typed since\n"

        let outcome = plan.apply(bufferText: { _ in buffer }, fileService: tree)

        guard case .applied(let application) = outcome else {
            return XCTFail("expected the plan to apply, got \(outcome)")
        }
        XCTAssertTrue(application.filesWritten.isEmpty)
        XCTAssertEqual(
            application.bufferRewrites.first?.plan.text,
            "let total = 1\nprint(total)\n// typed since\n"
        )
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// **The abort path.** One stale file and every other file — including the
    /// ones whose edits were perfectly applicable — is left byte-identical, with
    /// nothing written at all.
    func testAStaleFileAbortsBeforeAnythingIsWritten() throws {
        let text = "let count = 1\nprint(count)\n"
        let moved = "// inserted behind the app\n" + text
        let tree = StubFileTree(root: root, files: ["a.swift": text, "b.swift": moved])
        let plan = try makePlan(files: ["/p/root/a.swift": text, "/p/root/b.swift": text])

        let outcome = plan.apply(bufferText: { _ in nil }, fileService: tree)

        XCTAssertEqual(outcome, .stale(tree.url("b.swift")))
        XCTAssertEqual(tree.files["a.swift"], text)
        XCTAssertEqual(tree.files["b.swift"], moved)
        XCTAssertTrue(
            tree.writtenPaths.isEmpty,
            "Verification of every file must precede the first write, or one stale file leaves a project "
                + "half-renamed."
        )
    }

    /// A file that cannot be read at apply time is stale, for the same reason a
    /// changed one is: it was readable when the plan was built.
    func testAFileThatCannotBeReadIsStale() throws {
        let text = "let count = 1\nprint(count)\n"
        let tree = StubFileTree(root: root, files: ["a.swift": text])
        tree.unreadableFiles = ["a.swift"]
        let plan = try makePlan(file: "/p/root/a.swift", text: text)

        XCTAssertEqual(
            plan.apply(bufferText: { _ in nil }, fileService: tree),
            .stale(tree.url("a.swift"))
        )
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// A write that fails after another has landed is reported, never swallowed:
    /// the bytes that changed have changed, and only Local History can put them
    /// back.
    func testAFailedWriteNamesItselfAndKeepsWhatLanded() throws {
        let text = "let count = 1\nprint(count)\n"
        let renamed = "let total = 1\nprint(total)\n"
        // Three files with the failure on the *middle* one, so the contract's
        // second half — "this one and anything after it did not" — has a file to
        // be about. Two files could only ever assert the first half.
        let tree = StubFileTree(
            root: root,
            files: ["a.swift": text, "b.swift": text, "c.swift": text]
        )
        tree.writeFailures = ["b.swift"]
        let plan = try makePlan(
            files: ["/p/root/a.swift": text, "/p/root/b.swift": text, "/p/root/c.swift": text]
        )

        let outcome = plan.apply(bufferText: { _ in nil }, fileService: tree)

        guard case .applied(let application) = outcome else {
            return XCTFail("expected a reported failure, got \(outcome)")
        }
        XCTAssertEqual(application.writeFailure, tree.url("b.swift"))
        XCTAssertEqual(application.filesWritten, [tree.url("a.swift")])
        XCTAssertEqual(tree.files["a.swift"], renamed)
        XCTAssertEqual(tree.files["b.swift"], text)
        XCTAssertEqual(
            tree.files["c.swift"],
            text,
            "A write after the failure would leave bytes on disk that `filesWritten` does not name."
        )
        XCTAssertEqual(tree.writtenPaths, ["a.swift"])
    }

    /// A plan with no edits writes nothing and asks for nothing — the case the
    /// command refuses before it ever raises the bracket.
    func testAnEmptyPlanTouchesNothing() {
        let tree = StubFileTree(root: root, files: ["a.swift": "let count = 1\n"])
        let plan = RenameEditPlan(files: [])

        XCTAssertEqual(
            plan.apply(bufferText: { _ in nil }, fileService: tree),
            .applied(RenameApplication(bufferRewrites: [], filesWritten: []))
        )
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    // MARK: - Helpers

    /// A plan renaming every occurrence of `identifier` in each file's text —
    /// what a server's answer amounts to, built here so a test states the text and
    /// the name rather than a list of coordinates.
    private func makePlan(
        file: String,
        text: String,
        identifier: String = "count",
        newName: String = "total"
    ) throws -> RenameEditPlan {
        try makePlan(files: [file: text], identifier: identifier, newName: newName)
    }

    private func makePlan(
        files: [String: String],
        identifier: String = "count",
        newName: String = "total"
    ) throws -> RenameEditPlan {
        let documents = files.keys.sorted().map { path -> LSPDocumentEdits in
            let text = files[path] ?? ""
            return LSPDocumentEdits(
                uri: uri(path),
                edits: wireEdits(of: identifier, in: text, newName: newName)
            )
        }
        return try RenameEditPlan.make(
            from: LSPWorkspaceEdit(documents: documents),
            root: root,
            texts: texts(files)
        ).get()
    }

    /// Every whole-word occurrence of `identifier`, spelled in the protocol's
    /// coordinates — the shape a server answers in.
    private func wireEdits(of identifier: String, in text: String, newName: String) -> [LSPTextEdit] {
        let source = text as NSString
        let lineStarts = LSPPositionMap.lineStarts(in: source)
        var edits: [LSPTextEdit] = []
        var searched = NSRange(location: 0, length: source.length)
        while true {
            let found = source.range(of: identifier, options: [], range: searched)
            guard found.location != NSNotFound else { break }
            edits.append(
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPositionMap.position(
                            forOffset: found.location, lineStarts: lineStarts, length: source.length
                        ),
                        end: LSPPositionMap.position(
                            forOffset: NSMaxRange(found), lineStarts: lineStarts, length: source.length
                        )
                    ),
                    newText: newName
                )
            )
            let next = NSMaxRange(found)
            searched = NSRange(location: next, length: source.length - next)
        }
        return edits
    }
}

private extension Result where Failure == RenameRefusal {
    /// The refusal, or `nil` for a plan — the shape every refusal case asserts in.
    var refusal: RenameRefusal? {
        switch self {
        case .success: return nil
        case .failure(let refusal): return refusal
        }
    }
}
