import XCTest
@testable import PisakaCore

/// `CompletionNarrowingRule.decide`, row by row: what narrows the retained list,
/// what asks again, and what forgets it.
final class CompletionNarrowingRuleTests: XCTestCase {
    private let retained = RetainedCompletionList(handle: 7, wordStart: 40, typed: "fo")

    private func decide(
        retained: RetainedCompletionList?? = nil,
        wordStart: Int = 40,
        typed: String,
        explicit: Bool = false,
        trigger: Bool = false,
        newline: Bool = false,
        jumped: Bool = false
    ) -> CompletionNarrowingRule.Decision {
        CompletionNarrowingRule.decide(
            retained: retained ?? self.retained,
            wordStart: wordStart,
            typed: typed,
            explicit: explicit,
            typedTriggerCharacter: trigger,
            insertedNewline: newline,
            caretJumped: jumped
        )
    }

    func testTypingOnInsideTheAnsweredWordNarrows() {
        XCTAssertEqual(decide(typed: "foo"), .narrow)
        XCTAssertEqual(decide(typed: "foob"), .narrow)
        XCTAssertEqual(decide(typed: "fo"), .narrow, "the answered word itself")
    }

    func testABackspaceThatStaysAtOrAboveTheAnsweredWordNarrows() {
        let shorter = RetainedCompletionList(handle: 7, wordStart: 40, typed: "fo")
        XCTAssertEqual(decide(retained: shorter, typed: "foo"), .narrow)
        XCTAssertEqual(decide(retained: shorter, typed: "fo"), .narrow)
    }

    /// A server that filters on its side answered the longer word without what
    /// the shorter one also matches, so a backspace below the answer asks again.
    func testABackspaceBelowTheAnsweredWordAsksAgain() {
        let longer = RetainedCompletionList(handle: 7, wordStart: 40, typed: "foob")
        XCTAssertEqual(decide(retained: longer, typed: "foo"), .request)
        XCTAssertEqual(decide(retained: longer, typed: "f"), .request)
    }

    func testAnEmptiedWordDropsTheRetainedListAndSaysNothingElse() {
        XCTAssertEqual(decide(typed: ""), .dropRetained)
        XCTAssertEqual(decide(retained: .some(nil), typed: ""), .dropRetained)
        XCTAssertEqual(decide(typed: "", explicit: true), .dropRetained)
    }

    func testAWordThatNoLongerSharesTheAnsweredSpellingAsksAgain() {
        XCTAssertEqual(decide(typed: "fa"), .request)
        XCTAssertEqual(decide(typed: "bar"), .request)
    }

    func testAWordThatStartsElsewhereAsksAgain() {
        XCTAssertEqual(decide(wordStart: 39, typed: "ofo"), .request)
        XCTAssertEqual(decide(wordStart: 41, typed: "o"), .request)
    }

    func testEveryNewSituationAsksAgainEvenInsideTheWord() {
        XCTAssertEqual(decide(typed: "foo", explicit: true), .request)
        XCTAssertEqual(decide(typed: "foo", trigger: true), .request)
        XCTAssertEqual(decide(typed: "foo", newline: true), .request)
        XCTAssertEqual(decide(typed: "foo", jumped: true), .request)
    }

    func testNothingRetainedAsksAgain() {
        XCTAssertEqual(decide(retained: .some(nil), typed: "foo"), .request)
    }

    func testAMemberListAnsweredForAnEmptyWordNarrowsWhateverIsTypedAfterIt() {
        let member = RetainedCompletionList(handle: 3, wordStart: 40, typed: "")
        XCTAssertEqual(decide(retained: member, typed: "g"), .narrow)
    }

    func testTheWordsAreComparedInUTF16Units() {
        let composed = RetainedCompletionList(handle: 1, wordStart: 40, typed: "caf\u{E9}")
        XCTAssertEqual(
            decide(retained: composed, typed: "cafe\u{301}x"), .request,
            "a decomposed spelling is a different word in the buffer's coordinates"
        )
    }
}
