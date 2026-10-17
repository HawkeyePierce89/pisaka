import XCTest
@testable import PisakaCore

/// Pins Expand / Shrink Selection's ladder: the word, each named ancestor with
/// its bracket contents first, the line, the document; the text-only fallback
/// over nested brackets; the strict-containment `next`; and the history Shrink
/// walks back along.
final class SelectionExpansionRuleTests: XCTestCase {

    private func range(_ needle: String, in text: NSString) -> NSRange {
        let found = text.range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "fixture lacks \(needle)")
        return found
    }

    private func caret(_ offset: Int) -> NSRange { NSRange(location: offset, length: 0) }

    /// Walks `next` from `start` until the ladder is exhausted.
    private func walk(from start: NSRange, candidates: [NSRange]) -> [NSRange] {
        var steps: [NSRange] = []
        var current = start
        while let step = SelectionExpansionRule.next(selection: current, candidates: candidates) {
            steps.append(step)
            current = step
        }
        return steps
    }

    // MARK: - The ladder over a hand-built ancestor chain

    func testExpansionOrderOverAncestorChain() {
        let text = "let a = 1\nfoo(bar, baz);\nlet b = 2" as NSString
        let identifier = range("bar", in: text)
        let arguments = range("(bar, baz)", in: text)
        let call = range("foo(bar, baz)", in: text)
        let statement = range("foo(bar, baz);", in: text)
        let candidates = SelectionExpansionRule.candidates(
            text: text,
            selection: caret(identifier.location + 1),
            language: .typescript,
            ancestors: [identifier, arguments, call, statement],
            stringContent: false
        )
        XCTAssertEqual(candidates, [
            identifier,
            range("bar, baz", in: text),
            arguments,
            call,
            statement,
            NSRange(location: 0, length: text.length),
        ], "the line equals the statement and is dropped as a duplicate")

        XCTAssertEqual(walk(from: caret(identifier.location + 1), candidates: candidates), candidates)
    }

    func testLineComesAfterTheAncestorsWithoutItsTerminator() {
        let text = "x\n  call(a)\r\ny" as NSString
        let call = range("call(a)", in: text)
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: caret(call.location), language: .javascript, ancestors: [call], stringContent: false
        )
        XCTAssertEqual(candidates, [
            range("call", in: text),
            call,
            range("  call(a)", in: text),
            NSRange(location: 0, length: text.length),
        ])
    }

    func testEqualRangeIsSkipped() {
        let text = "alpha beta" as NSString
        let word = range("beta", in: text)
        let candidates = [word, word, NSRange(location: 0, length: text.length)]
        XCTAssertEqual(
            SelectionExpansionRule.next(selection: word, candidates: candidates),
            NSRange(location: 0, length: text.length)
        )
    }

    func testCandidateThatDoesNotContainTheSelectionIsSkipped() {
        let selection = NSRange(location: 4, length: 6)
        let candidates = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 10), NSRange(location: 2, length: 9)]
        XCTAssertEqual(SelectionExpansionRule.next(selection: selection, candidates: candidates), candidates[2])
        XCTAssertNil(SelectionExpansionRule.next(selection: selection, candidates: [selection]))
    }

    // MARK: - The word step

    func testWordStepInsideAString() {
        let text = "say(\"hello world\")" as NSString
        let fragment = range("hello world", in: text)
        let string = range("\"hello world\"", in: text)
        let world = range("world", in: text)
        let ancestors = [fragment, string, range("(\"hello world\")", in: text), NSRange(location: 0, length: text.length)]

        let inside = SelectionExpansionRule.candidates(
            text: text, selection: caret(world.location + 2), language: .javascript,
            ancestors: ancestors, stringContent: true
        )
        XCTAssertEqual(inside.first, world)
        XCTAssertEqual(SelectionExpansionRule.next(selection: caret(world.location + 2), candidates: inside), world)

        // A caret just past a word in string content takes that word.
        let pastWord = SelectionExpansionRule.candidates(
            text: text, selection: caret(NSMaxRange(world)), language: .javascript,
            ancestors: ancestors, stringContent: true
        )
        XCTAssertEqual(pastWord.first, world)
    }

    func testPunctuationCaretGoesStraightToItsNode() {
        let text = "foo(bar)" as NSString
        let arguments = range("(bar)", in: text)
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: caret(arguments.location), language: .typescript,
            ancestors: [arguments, NSRange(location: 0, length: text.length)], stringContent: false
        )
        XCTAssertEqual(candidates.first, range("bar", in: text), "contents, not a word")
        XCTAssertFalse(candidates.contains(range("foo", in: text)), "the caret after `foo` sits on `(`")
        // The contents start after the `(` and so do not contain the caret
        // before it: the first step is the node itself.
        XCTAssertEqual(
            SelectionExpansionRule.next(selection: caret(arguments.location), candidates: candidates),
            arguments
        )
    }

    func testWordStepUsesTheLanguageBoundary() {
        let text = "x = $store.value" as NSString
        let dollar = range("$store", in: text)
        let js = SelectionExpansionRule.candidates(
            text: text, selection: caret(dollar.location + 2), language: .javascript, ancestors: [], stringContent: false
        )
        XCTAssertEqual(js.first, dollar)
        let swift = SelectionExpansionRule.candidates(
            text: text, selection: caret(dollar.location + 2), language: .swift, ancestors: [], stringContent: false
        )
        XCTAssertEqual(swift.first, range("store", in: text))
    }

    func testSelectionSpanningPastAWordGetsNoWordStep() {
        let text = "one two" as NSString
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: NSRange(location: 1, length: 4), language: nil, ancestors: [], stringContent: false
        )
        XCTAssertEqual(candidates, [NSRange(location: 0, length: 7)], "the line equals the document")
    }

    // MARK: - Contents before brackets

    func testContentsComeBeforeEveryBracketedAncestor() {
        let text = "{ [1, 2] }" as NSString
        let array = range("[1, 2]", in: text)
        let block = NSRange(location: 0, length: text.length)
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: caret(array.location + 1), language: .javascript,
            ancestors: [array, block], stringContent: false
        )
        XCTAssertEqual(candidates, [
            range("1, 2", in: text),
            array,
            range(" [1, 2] ", in: text),
            block,
        ])
    }

    func testMismatchedOrEmptyEndsGiveNoContents() {
        let text = "(a] ()" as NSString
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: caret(4), language: nil,
            ancestors: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 2)], stringContent: false
        )
        XCTAssertEqual(candidates, [
            NSRange(location: 0, length: 3), NSRange(location: 4, length: 2), NSRange(location: 0, length: 6)
        ])
    }

    func testAncestorOutsideTheTextIsDropped() {
        let text = "ab" as NSString
        let candidates = SelectionExpansionRule.candidates(
            text: text, selection: caret(0), language: nil,
            ancestors: [NSRange(location: 0, length: 9), NSRange(location: NSNotFound, length: 0)], stringContent: false
        )
        XCTAssertEqual(candidates, [NSRange(location: 0, length: 2)])
    }

    // MARK: - The text-only fallback

    func testFallbackChainOverNestedBrackets() {
        let text = "head\nf(a, [b, {c: d}])\ntail" as NSString
        let start = caret(range("c:", in: text).location)
        let candidates = SelectionExpansionRule.fallbackCandidates(text: text, selection: start, language: nil)
        XCTAssertEqual(candidates, [
            range("c", in: text),
            range("c: d", in: text),
            range("{c: d}", in: text),
            range("b, {c: d}", in: text),
            range("[b, {c: d}]", in: text),
            range("a, [b, {c: d}]", in: text),
            range("(a, [b, {c: d}])", in: text),
            range("f(a, [b, {c: d}])", in: text),
            NSRange(location: 0, length: text.length),
        ])
        XCTAssertEqual(walk(from: start, candidates: candidates), candidates)
    }

    func testFallbackWithoutBracketsIsWordLineDocument() {
        let text = "alpha\nbeta gamma\n" as NSString
        let candidates = SelectionExpansionRule.fallbackCandidates(
            text: text, selection: caret(range("gamma", in: text).location), language: nil
        )
        XCTAssertEqual(candidates, [
            range("gamma", in: text), range("beta gamma", in: text), NSRange(location: 0, length: text.length)
        ])
    }

    func testFallbackOnEmptyText() {
        XCTAssertEqual(
            SelectionExpansionRule.fallbackCandidates(text: "" as NSString, selection: caret(0), language: nil),
            [NSRange(location: 0, length: 0)]
        )
        XCTAssertNil(SelectionExpansionRule.next(selection: caret(0), candidates: [NSRange(location: 0, length: 0)]))
    }

    // MARK: - History

    func testHistoryPushPopReset() {
        var history = SelectionExpansionHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.pop())

        history.push(caret(3))
        history.push(NSRange(location: 2, length: 4))
        XCTAssertFalse(history.isEmpty)
        XCTAssertEqual(history.pop(), NSRange(location: 2, length: 4))
        XCTAssertEqual(history.pop(), caret(3))
        XCTAssertNil(history.pop())

        history.push(caret(1))
        history.reset()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.pop())
    }

    func testExpandThenShrinkReturnsAlongTheSamePath() {
        let text = "f(a, [b])" as NSString
        let start = caret(range("b", in: text).location)
        let candidates = SelectionExpansionRule.fallbackCandidates(text: text, selection: start, language: nil)
        var history = SelectionExpansionHistory()
        var current = start
        var path = [start]
        while let step = SelectionExpansionRule.next(selection: current, candidates: candidates) {
            history.push(current)
            current = step
            path.append(step)
        }
        var back: [NSRange] = [current]
        while let previous = history.pop() {
            back.append(previous)
        }
        XCTAssertEqual(back, path.reversed())
    }
}
