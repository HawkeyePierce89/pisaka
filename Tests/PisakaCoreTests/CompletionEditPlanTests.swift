import XCTest
@testable import PisakaCore

/// The auto-import rule (D4), pinned without an `NSTextView`: which edits are
/// applied in which order, where the caret lands, and every shape that must be
/// refused instead of applied.
final class CompletionEditPlanTests: XCTestCase {
    // MARK: - Helpers

    private func primary(_ range: NSRange, _ newText: String) -> CompletionEdit {
        CompletionEdit(range: range, newText: newText, role: .primary)
    }

    private func additional(_ range: NSRange, _ newText: String) -> CompletionEdit {
        CompletionEdit(range: range, newText: newText, role: .additional)
    }

    /// Apply a plan the way the editor will, so the tests assert the *resulting
    /// buffer* rather than just the order of the list.
    private func apply(_ plan: CompletionEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits {
            result.replaceCharacters(in: edit.range, with: edit.newText)
        }
        return result as String
    }

    private func rejection<T>(_ result: Result<T, CompletionEditPlan.Rejection>) -> CompletionEditPlan.Rejection? {
        guard case .failure(let reason) = result else { return nil }
        return reason
    }

    // MARK: - The auto-import case

    /// The payoff: an `import` line inserted *above* the completion point, with
    /// the caret still landing after the completed symbol.
    func testAnImportBeforeTheCompletionPointLeavesTheCaretAfterTheSymbol() throws {
        let text = "import Foundation\nlet x = Gre\n"
        let typedWord = NSRange(location: 26, length: 3)  // "Gre"
        XCTAssertEqual((text as NSString).substring(with: typedWord), "Gre")

        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 18, length: 0), "import Greetings\n")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )

        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            apply(plan, to: text),
            "import Foundation\nimport Greetings\nlet x = Greeter\n"
        )
        // 26 (word start) + 7 ("Greeter") + 17 (the import line inserted before it)
        XCTAssertEqual(plan.caretOffset, 50)
        XCTAssertEqual(
            (apply(plan, to: text) as NSString).substring(to: plan.caretOffset),
            "import Foundation\nimport Greetings\nlet x = Greeter"
        )
    }

    /// Edits are handed back strictly last-to-first, so a caller can apply them
    /// one after another without any offset arithmetic of its own.
    func testEditsAreOrderedLastToFirst() throws {
        let text = "aaa bbb ccc"
        let result = CompletionEditPlan.make(
            edits: [
                additional(NSRange(location: 0, length: 3), "AAA"),
                primary(NSRange(location: 4, length: 3), "BBB"),
                additional(NSRange(location: 8, length: 3), "CCC")
            ],
            in: text as NSString,
            replacing: NSRange(location: 4, length: 3),
            typed: "bbb"
        )

        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(plan.edits.map(\.range.location), [8, 4, 0])
        XCTAssertEqual(apply(plan, to: text), "AAA BBB CCC")
    }

    /// An edit *after* the completion point cannot move the caret: it is applied
    /// first (last-to-first), and everything before it keeps its offsets.
    func testAnEditAfterTheCompletionPointDoesNotMoveTheCaret() throws {
        let text = "let x = Gre\n// tail\n"
        let typedWord = NSRange(location: 8, length: 3)

        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 12, length: 7), "// TAIL")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )

        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(plan.caretOffset, 15)
        XCTAssertEqual(apply(plan, to: text), "let x = Greeter\n// TAIL\n")
    }

    /// Several `additionalTextEdits` — two imports and a qualifier — all shift
    /// the caret by their own net length change, and only the ones before it.
    func testMultipleAdditionalEditsEachShiftTheCaret() throws {
        let text = "\n\nlet x = Gre\n"
        let typedWord = NSRange(location: 10, length: 3)

        let result = CompletionEditPlan.make(
            edits: [
                additional(NSRange(location: 0, length: 0), "import A\n"),   // +9
                additional(NSRange(location: 1, length: 1), ""),             // -1
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 14, length: 0), "// after\n")   // after: no shift
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )

        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(plan.caretOffset, 10 + 7 + 9 - 1)
        XCTAssertEqual(apply(plan, to: text), "import A\n\nlet x = Greeter\n// after\n")
    }

    /// A primary edit wider than the client's prefix range — what a server that
    /// decides for itself what the completion replaces sends — is honoured, and
    /// the caret still lands after the inserted text.
    func testAPrimaryEditWiderThanTheTypedWordIsHonoured() throws {
        let text = "value.gre"
        let typedWord = NSRange(location: 6, length: 3)

        let result = CompletionEditPlan.make(
            edits: [primary(NSRange(location: 0, length: 9), "value.greet()")],
            in: text as NSString,
            replacing: typedWord,
            typed: "gre"
        )

        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(apply(plan, to: text), "value.greet()")
        XCTAssertEqual(plan.caretOffset, 13)
    }

    // MARK: - Rejections

    func testAnEmptyEditListIsRejectedForHavingNoPrimaryEdit() {
        let result = CompletionEditPlan.make(
            edits: [],
            in: "let x = Gre" as NSString,
            replacing: NSRange(location: 8, length: 3),
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .noPrimaryEdit)
    }

    func testAdditionalEditsWithNoPrimaryAreRejected() {
        let result = CompletionEditPlan.make(
            edits: [additional(NSRange(location: 0, length: 0), "import A\n")],
            in: "let x = Gre" as NSString,
            replacing: NSRange(location: 8, length: 3),
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .noPrimaryEdit)
    }

    func testTwoPrimaryEditsAreRejected() {
        let text = "aaa bbb"
        let result = CompletionEditPlan.make(
            edits: [
                primary(NSRange(location: 0, length: 3), "AAA"),
                primary(NSRange(location: 4, length: 3), "BBB")
            ],
            in: text as NSString,
            replacing: NSRange(location: 0, length: 3),
            typed: "aaa"
        )
        XCTAssertEqual(rejection(result), .multiplePrimaryEdits)
    }

    func testOverlappingEditsAreRejected() {
        let text = "abcdefghij"
        let result = CompletionEditPlan.make(
            edits: [
                primary(NSRange(location: 0, length: 5), "X"),
                additional(NSRange(location: 3, length: 4), "Y")
            ],
            in: text as NSString,
            replacing: NSRange(location: 0, length: 5),
            typed: "abcde"
        )
        XCTAssertEqual(rejection(result), .overlappingEdits)
    }

    /// Two insertions at one offset are not *geometrically* overlapping, but
    /// nothing says which comes first — so they are refused rather than ordered
    /// by guess.
    func testTwoInsertionsAtTheSameOffsetAreRejected() {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 0, length: 0), "import A\n"),
                additional(NSRange(location: 0, length: 0), "import B\n")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .overlappingEdits)
    }

    /// An insertion at exactly the start of a replaced range is the same
    /// ambiguity wearing a different shape.
    func testAnInsertionAtTheStartOfAReplacedRangeIsRejected() {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 8, length: 0), "@")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .overlappingEdits)
    }

    /// An insertion at the *end* of a replaced range has a defined order, so it
    /// is allowed.
    func testAnInsertionAtTheEndOfAReplacedRangeIsAllowed() throws {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 11, length: 0), "()")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(apply(plan, to: text), "let x = Greeter()")
        XCTAssertEqual(plan.caretOffset, 15)
    }

    func testAnEditPastTheEndOfTheBufferIsRejected() {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: 50, length: 0), "import A\n")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .outOfRange)
    }

    func testANegativeEditRangeIsRejected() {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [
                primary(typedWord, "Greeter"),
                additional(NSRange(location: -1, length: 2), "x")
            ],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .outOfRange)
    }

    /// A primary edit that stops short of the typed word would leave the typed
    /// characters behind, appended to the completion.
    func testAPrimaryEditThatDoesNotCoverTheTypedWordIsRejected() {
        let text = "let x = Gre"
        let typedWord = NSRange(location: 8, length: 3)
        let result = CompletionEditPlan.make(
            edits: [primary(NSRange(location: 8, length: 2), "Greeter")],
            in: text as NSString,
            replacing: typedWord,
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .primaryEditMissesTypedWord)
    }

    // MARK: - Staleness

    /// The list was computed behind a debounce; by the time an item is
    /// committed the user may have typed on. The offsets are then someone
    /// else's, so the plan refuses rather than editing whatever now sits there.
    func testEditsAgainstAChangedBufferAreRejected() {
        // The request saw "Gre"; the buffer now reads "Gro".
        let result = CompletionEditPlan.make(
            edits: [primary(NSRange(location: 8, length: 3), "Greeter")],
            in: "let x = Gro" as NSString,
            replacing: NSRange(location: 8, length: 3),
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .bufferChanged)
    }

    /// The commonest form of the same thing: the buffer shrank, so the typed
    /// word's range no longer exists at all.
    func testAShrunkBufferIsRejectedRatherThanClamped() {
        let result = CompletionEditPlan.make(
            edits: [primary(NSRange(location: 8, length: 3), "Greeter")],
            in: "let x" as NSString,
            replacing: NSRange(location: 8, length: 3),
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .bufferChanged)
    }

    /// The word moved (an import was added above by something else) — the text
    /// at the recorded range is different, which is what is checked.
    func testAMovedTypedWordIsRejected() {
        let result = CompletionEditPlan.make(
            edits: [primary(NSRange(location: 8, length: 3), "Greeter")],
            in: "import X\nlet x = Gre" as NSString,
            replacing: NSRange(location: 8, length: 3),
            typed: "Gre"
        )
        XCTAssertEqual(rejection(result), .bufferChanged)
    }

    /// A member completion legitimately has an empty typed word (the caret sits
    /// right after the dot), and that must still plan.
    func testAnEmptyTypedWordAfterADotStillPlans() throws {
        let text = "value."
        let typedWord = NSRange(location: 6, length: 0)
        let result = CompletionEditPlan.make(
            edits: [primary(typedWord, "greet")],
            in: text as NSString,
            replacing: typedWord,
            typed: ""
        )
        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(apply(plan, to: text), "value.greet")
        XCTAssertEqual(plan.caretOffset, 11)
    }

    // MARK: - Re-expressing edits over an insertion that already happened

    /// The three shapes, in isolation: before the typed word, after it, and the
    /// primary edit spanning it.
    func testShiftingMovesOnlyWhatLiesAtOrPastTheTypedWord() {
        let typedWord = NSRange(location: 26, length: 3)  // "Gre"
        // Replaced by "Greeter" — four units longer.
        let importLine = additional(NSRange(location: 18, length: 0), "import Greetings\n")
        XCTAssertEqual(
            importLine.shifted(afterReplacingTypedWord: typedWord, withLength: 7),
            importLine
        )
        XCTAssertEqual(
            additional(NSRange(location: 40, length: 2), "()")
                .shifted(afterReplacingTypedWord: typedWord, withLength: 7),
            additional(NSRange(location: 44, length: 2), "()")
        )
        XCTAssertEqual(
            primary(typedWord, "Greeter").shifted(afterReplacingTypedWord: typedWord, withLength: 7),
            primary(NSRange(location: 26, length: 7), "Greeter")
        )
    }

    /// A primary edit *wider* than the typed word keeps its start and grows by
    /// the same difference, so it still covers exactly the text it meant to.
    func testShiftingGrowsAWiderPrimaryEditRatherThanMovingIt() {
        let typedWord = NSRange(location: 10, length: 3)
        XCTAssertEqual(
            primary(NSRange(location: 6, length: 7), "greet()")
                .shifted(afterReplacingTypedWord: typedWord, withLength: 5),
            primary(NSRange(location: 6, length: 9), "greet()")
        )
    }

    /// The member case: nothing was typed, so the typed word is empty and the
    /// primary edit is a zero-length insertion sitting exactly on it.
    ///
    /// Geometrically that edit is indistinguishable from one lying "wholly after
    /// the word", and reading it as such would slide it past the preview instead
    /// of growing it to cover it — after which `make` refuses the plan and the
    /// auto-import is silently dropped. The role is what tells the two apart.
    func testAZeroLengthPrimaryEditOnAnEmptyTypedWordGrowsOverThePreview() throws {
        let live = "let x = worker.greet"
        let typedWord = NSRange(location: 15, length: 0)  // the caret after `worker.`
        let preview = "greet"
        let edits = [
            primary(typedWord, "greet"),
            additional(NSRange(location: 0, length: 0), "import Greetings\n")
        ]
        XCTAssertEqual(
            edits[0].shifted(afterReplacingTypedWord: typedWord, withLength: 5),
            primary(NSRange(location: 15, length: 5), "greet")
        )
        // An *additional* edit at the same offset is still "after the word" and
        // still slides: only the primary one spans it.
        XCTAssertEqual(
            additional(typedWord, "()").shifted(afterReplacingTypedWord: typedWord, withLength: 5),
            additional(NSRange(location: 20, length: 0), "()")
        )

        let result = CompletionEditPlan.make(
            edits: edits.map { $0.shifted(afterReplacingTypedWord: typedWord, withLength: 5) },
            in: live as NSString,
            replacing: NSRange(location: 15, length: 5),
            typed: preview
        )
        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(apply(plan, to: live), "import Greetings\nlet x = worker.greet")
        XCTAssertEqual(plan.caretOffset, 37)
    }

    /// Nothing moves when the replacement is the same length as the typed word
    /// — the ordinary case of a preview that happens to match.
    func testShiftingByZeroIsIdentity() {
        let typedWord = NSRange(location: 4, length: 3)
        let edits = [primary(typedWord, "abc"), additional(NSRange(location: 0, length: 0), "x")]
        for edit in edits {
            XCTAssertEqual(edit.shifted(afterReplacingTypedWord: typedWord, withLength: 3), edit)
        }
    }

    /// The arrow-key case end to end: AppKit previewed a row into the buffer, so
    /// the request's edits are re-expressed over the preview and still produce
    /// the auto-imported result with the caret after the symbol.
    func testAPreviewedRowStillPlansAgainstTheLiveBuffer() throws {
        let requested = "import Foundation\nlet x = Gre\n"
        let typedWord = NSRange(location: 26, length: 3)  // "Gre"
        let edits = [
            primary(typedWord, "Greeter"),
            additional(NSRange(location: 18, length: 0), "import Greetings\n")
        ]
        // The user arrowed onto a different row first, so the buffer now holds
        // that row's text where "Gre" was.
        let preview = "GreeterFactory"
        let live = "import Foundation\nlet x = GreeterFactory\n"
        XCTAssertEqual(
            (requested as NSString).replacingCharacters(in: typedWord, with: preview),
            live
        )
        let liveTypedWord = NSRange(location: 26, length: (preview as NSString).length)

        let result = CompletionEditPlan.make(
            edits: edits.map { $0.shifted(afterReplacingTypedWord: typedWord, withLength: liveTypedWord.length) },
            in: live as NSString,
            replacing: liveTypedWord,
            typed: preview
        )
        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            apply(plan, to: live),
            "import Foundation\nimport Greetings\nlet x = Greeter\n"
        )
        XCTAssertEqual(plan.caretOffset, 50)
    }

    /// D4's race, in coordinates: the plain text went in first and the import
    /// arrived afterwards, so re-expressing the *whole* edit set over the
    /// insertion re-applies the symbol as a no-op and adds only the import —
    /// and moves the caret down by the line it inserted above.
    func testAResolvedImportAppliesOverAnInsertionThatAlreadyHappened() throws {
        let typedWord = NSRange(location: 26, length: 3)  // "Gre"
        let edits = [
            primary(typedWord, "Greeter"),
            additional(NSRange(location: 18, length: 0), "import Greetings\n")
        ]
        // AppKit already inserted the plain text, because the resolve had not
        // landed when the user hit Return.
        let live = "import Foundation\nlet x = Greeter\n"
        let inserted = NSRange(location: 26, length: 7)

        let result = CompletionEditPlan.make(
            edits: edits.map { $0.shifted(afterReplacingTypedWord: typedWord, withLength: inserted.length) },
            in: live as NSString,
            replacing: inserted,
            typed: "Greeter"
        )
        let plan = try XCTUnwrap(try? result.get())
        XCTAssertEqual(
            apply(plan, to: live),
            "import Foundation\nimport Greetings\nlet x = Greeter\n"
        )
        XCTAssertEqual(plan.caretOffset, 50)
    }

    /// The shift accounts for the *editor's* own writes and nothing else: a
    /// deletion at the completion point after the insertion is refused rather
    /// than applied over whatever is there now.
    ///
    /// A change elsewhere in the buffer still reads correctly at these offsets
    /// and is therefore not this rule's job — the follow-up path additionally
    /// requires the whole buffer to be untouched since the insertion, which is
    /// D4's stated condition and is checked in the editor, against the text.
    func testAFollowUpAgainstAnEditedCompletionPointIsRejected() {
        let typedWord = NSRange(location: 26, length: 3)
        let edits = [
            primary(typedWord, "Greeter"),
            additional(NSRange(location: 18, length: 0), "import Greetings\n")
        ]
        let live = "import Foundation\nlet x = Greete\n"  // a character deleted again
        let result = CompletionEditPlan.make(
            edits: edits.map { $0.shifted(afterReplacingTypedWord: typedWord, withLength: 7) },
            in: live as NSString,
            replacing: NSRange(location: 26, length: 7),
            typed: "Greeter"
        )
        XCTAssertEqual(rejection(result), .bufferChanged)
    }

    // MARK: - The seam's defaults

    /// A tree-sitter item carries no edits and no resolve handle, so nothing
    /// about phase 1's insertion path changes.
    func testATreeSitterItemCarriesNoEditsAndNoResolveHandle() {
        let item = CompletionItem(text: "Worker", kind: .type, isFromCurrentFile: true)
        XCTAssertTrue(item.edits.isEmpty)
        XCTAssertNil(item.resolveHandle)
    }

    /// `DefinitionRequest.text` defaults to empty — the compatibility that makes
    /// a forgotten call site possible, and therefore the thing the LSP
    /// provider's D2 guard exists to catch.
    func testDefinitionRequestTextDefaultsToEmpty() {
        let request = DefinitionRequest(identifier: "run", fileURL: nil, offset: 12)
        XCTAssertEqual(request.text, "")
        XCTAssertEqual(
            DefinitionRequest(identifier: "run", fileURL: nil, offset: 12, text: "func run() {}").text,
            "func run() {}"
        )
    }
}
