import XCTest
@testable import PisakaCore

final class BracketDepthScannerTests: XCTestCase {
    private func scan(_ s: String) -> [BracketToken] {
        BracketDepthScanner.scan(text: s as NSString)
    }

    private func token(_ location: Int, _ depth: Int, unmatched: Bool = false) -> BracketToken {
        BracketToken(location: location, depth: depth, isUnmatched: unmatched)
    }

    // MARK: - Nothing to report

    func testEmptyTextYieldsNoTokens() {
        XCTAssertEqual(scan(""), [])
    }

    func testTextWithoutBracketsYieldsNoTokens() {
        XCTAssertEqual(scan("abc def\nghi"), [])
        XCTAssertEqual(scan("let a = 1"), [])
    }

    func testQuotesAndAngleBracketsAreNotBrackets() {
        // Only ()[]{} are scanned. Quotes are their own closer (no answer without
        // a lexer, so `BracketMatchEngine` excludes them too) and `<`/`>` are
        // comparison operators far more often than brackets — completing the
        // tables with either would produce nonsense depths.
        XCTAssertEqual(scan("\"'`<>"), [])
        XCTAssertEqual(scan("a < b && c > d"), [])
    }

    // MARK: - Depth

    func testFlatSequenceIsAllDepthZero() {
        // "()()" — 0:( 1:) 2:( 3:)
        XCTAssertEqual(scan("()()"), [
            token(0, 0), token(1, 0), token(2, 0), token(3, 0)
        ])
    }

    func testNestingIncreasesDepthAndCloserGetsItsOpenersDepth() {
        // "((()))" — 0,1,2 on the openers, mirrored on the closers.
        XCTAssertEqual(scan("((()))"), [
            token(0, 0), token(1, 1), token(2, 2),
            token(3, 2), token(4, 1), token(5, 0)
        ])
    }

    func testStackIsSharedAcrossKinds() {
        // "{[()]}" — depth is one number for the whole document, so the kinds
        // stack together: 0,1,2 and back down. This is where the scanner differs
        // from `BracketMatchEngine`, which counts each kind on its own.
        XCTAssertEqual(scan("{[()]}"), [
            token(0, 0), token(1, 1), token(2, 2),
            token(3, 2), token(4, 1), token(5, 0)
        ])
    }

    func testDepthBeyondThePaletteIsReportedHonestly() {
        // Seven levels: the scanner reports 0…6 as plain Ints. Cycling a
        // five-color palette is the view's job (the `FileIconColor` precedent).
        let tokens = scan("(((((((")
        XCTAssertEqual(tokens.map(\.depth), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertTrue(tokens.allSatisfy(\.isUnmatched))
    }

    func testMatchedDepthBeyondThePaletteIsReportedHonestly() {
        XCTAssertEqual(scan("((((((()))))))").map(\.depth), [0, 1, 2, 3, 4, 5, 6, 6, 5, 4, 3, 2, 1, 0])
    }

    // MARK: - Unmatched

    func testStrayCloserIsUnmatched() {
        // ")" alone — nothing on the stack.
        XCTAssertEqual(scan(")"), [token(0, 0, unmatched: true)])
        // "()" then a stray ")": the pair is fine, the extra closer is not.
        XCTAssertEqual(scan("())"), [
            token(0, 0), token(1, 0), token(2, 0, unmatched: true)
        ])
    }

    func testCloserOfTheWrongKindIsUnmatchedAndLeavesTheStackAlone() {
        // "(]" then ")": the ']' does not pop, so the ')' still closes the '('.
        XCTAssertEqual(scan("(])"), [
            token(0, 0), token(1, 0, unmatched: true), token(2, 0)
        ])
    }

    func testLeftoverOpenerIsUnmatched() {
        XCTAssertEqual(scan("("), [token(0, 0, unmatched: true)])
        // "(()" — the outer '(' never closes; the inner pair is fine.
        XCTAssertEqual(scan("(()"), [
            token(0, 0, unmatched: true), token(1, 1), token(2, 1)
        ])
    }

    func testLeftoverOpenersKeepLocationOrdering() {
        // "{(" — both leftovers are patched to unmatched *in place*, so the
        // array stays sorted by location.
        XCTAssertEqual(scan("{(a"), [
            token(0, 0, unmatched: true), token(1, 1, unmatched: true)
        ])
    }

    func testTokensAreSortedByLocation() {
        let tokens = scan("{a(b)c[d]e}f)g")
        XCTAssertEqual(tokens.map(\.location), tokens.map(\.location).sorted())
        XCTAssertEqual(tokens, [
            token(0, 0), token(2, 1), token(4, 1),
            token(6, 1), token(8, 1), token(10, 0),
            token(12, 0, unmatched: true)
        ])
    }

    /// The two Core bracket engines answer *different* questions and therefore
    /// count depth differently, which shows up on crossed (broken) input.
    ///
    /// `BracketDepthScanner` keeps *one shared stack across all kinds* (JetBrains
    /// rainbow semantics), so in `{[(]}` the `]` arrives with `(` on top of the
    /// stack: wrong kind → unmatched, and the stack is left alone, which then
    /// leaves `{`, `[` and `(` as unmatched leftovers and the `}` closing… `(`'s
    /// kind mismatch too. Every token comes out unmatched.
    /// `BracketMatchEngine` counts *its own kind only* (the
    /// `IndentEngine.dedentOnClosing` rule) and so *does* pair `[`↔`]` here — its
    /// mirror test is `testCrossedBracketsPairPerKindUnlikeDepthScanner`.
    ///
    /// The disagreement is intended: the caret at `[` can show a highlighted pair
    /// whose brackets are painted red. Neither answer is wrong for its own
    /// question, and the input is broken code mid-typing.
    func testCrossedBracketsAllUnmatchedUnlikeMatchEngine() {
        let tokens = scan("{[(]}")
        XCTAssertEqual(tokens.map(\.location), [0, 1, 2, 3, 4])
        XCTAssertTrue(tokens.allSatisfy(\.isUnmatched), "expected every token of {[(]} unmatched, got \(tokens)")
        // In particular the two the matcher pairs.
        XCTAssertTrue(tokens[1].isUnmatched)  // '['
        XCTAssertTrue(tokens[3].isUnmatched)  // ']'
    }

    // MARK: - Surrogate pairs

    func testSurrogatePairsDoNotSkewOffsets() {
        // "😀(a)" — the emoji is two UTF-16 units, so '(' sits at index 2.
        XCTAssertEqual(scan("\u{1F600}(a)"), [token(2, 0), token(4, 0)])
        // A surrogate half is never mistaken for a bracket.
        XCTAssertEqual(scan("(\u{1F600})"), [token(0, 0), token(3, 0)])
    }

    // MARK: - Chunked reading

    /// The scan reads the buffer through `getCharacters(_:range:)` in fixed-size
    /// chunks, so a bracket landing on a chunk seam is the interesting case: the
    /// depth stack and the running location must both survive the seam. The
    /// result has to be identical to the short equivalent — chunking is an
    /// implementation detail, never visible in the output.
    func testBracketsStraddlingAChunkBoundaryScanIdentically() {
        let chunk = BracketDepthScanner.chunkSize
        // An outer pair whose opener is in chunk 0 and closer in chunk 2, with
        // an inner pair sitting exactly on the first seam.
        var s = "("
        s += String(repeating: "a", count: chunk - 2)
        s += "("  // last unit of chunk 0
        s += ")"  // first unit of chunk 1
        s += String(repeating: "b", count: chunk)
        s += ")"
        XCTAssertEqual(s.utf16.count, 2 * chunk + 2)
        let tokens = scan(s)
        XCTAssertEqual(tokens, [
            token(0, 0),
            token(chunk - 1, 1),
            token(chunk, 1),
            token(2 * chunk + 1, 0)
        ])
    }

    func testBracketAtTheExactFirstAndLastUnitOfEachChunk() {
        let chunk = BracketDepthScanner.chunkSize
        // "(" at 0 (first unit of chunk 0), ")" at chunk-1 (last unit of chunk 0),
        // "[" at chunk (first unit of chunk 1), "]" at 2*chunk-1 (last of chunk 1).
        var s = "("
        s += String(repeating: "a", count: chunk - 2)
        s += ")"
        s += "["
        s += String(repeating: "b", count: chunk - 2)
        s += "]"
        XCTAssertEqual(s.utf16.count, 2 * chunk)
        XCTAssertEqual(scan(s), [
            token(0, 0),
            token(chunk - 1, 0),
            token(chunk, 0),
            token(2 * chunk - 1, 0)
        ])
    }

    func testTextExactlyOneChunkLong() {
        let chunk = BracketDepthScanner.chunkSize
        var s = "("
        s += String(repeating: "a", count: chunk - 2)
        s += ")"
        XCTAssertEqual(s.utf16.count, chunk)
        XCTAssertEqual(scan(s), [token(0, 0), token(chunk - 1, 0)])
    }

    func testDeepNestingAcrossManyChunksMatchesTheShortEquivalent() {
        let chunk = BracketDepthScanner.chunkSize
        let filler = String(repeating: "x", count: chunk / 3)
        // Three levels, each separated by a third of a chunk, so the whole thing
        // spans several chunks and every seam falls inside filler or a bracket.
        let s = "(" + filler + "[" + filler + "{" + filler + "}" + filler + "]" + filler + ")"
        let tokens = scan(s)
        XCTAssertEqual(tokens.map(\.depth), [0, 1, 2, 2, 1, 0])
        XCTAssertTrue(tokens.allSatisfy { !$0.isUnmatched })
        XCTAssertEqual(tokens.map(\.location), [
            0,
            filler.utf16.count + 1,
            2 * filler.utf16.count + 2,
            3 * filler.utf16.count + 3,
            4 * filler.utf16.count + 4,
            5 * filler.utf16.count + 5
        ])
    }
}
