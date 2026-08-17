import XCTest
@testable import PisakaCore

/// The one place hover markup is interpreted (D25), pinned rule by rule: what
/// becomes code and what becomes prose, every construct that is degraded rather
/// than shown raw, the "empty is no answer" rule, order preservation, and the
/// line cap.
final class HoverContentTests: XCTestCase {
    // MARK: - Helpers

    private func content(_ elements: [LSPHoverElement]) -> HoverContent? {
        HoverContent(hoverElements: elements)
    }

    private func markdown(_ value: String) -> HoverContent? {
        content([.markup(kind: .markdown, value: value)])
    }

    private func prose(_ value: String) -> String? {
        guard let content = markdown(value) else { return nil }
        XCTAssertEqual(content.segments.count, 1, "expected one prose segment, got \(content.segments)")
        XCTAssertFalse(content.segments[0].isCode)
        return content.segments[0].text
    }

    // MARK: - Element kinds

    func testAMarkedStringObjectIsOneCodeSegmentWhole() {
        let content = self.content([.code(language: "swift", value: "func greet(_ name: String) -> String")])
        XCTAssertEqual(
            content?.segments,
            [.code("func greet(_ name: String) -> String", language: "swift")]
        )
        XCTAssertEqual(content?.isTruncated, false)
    }

    /// The point of the two kinds: a signature full of `*`, `_` and `<>` is not
    /// markup, and reading it as markup is how `Array<T>` loses its `<T>`.
    func testACodeElementIsNeverDegraded() {
        let source = "func f<T>(_ x: *T, _ y: some_type) -> [__C.Thing] // `note`"
        XCTAssertEqual(
            content([.code(language: "swift", value: source)])?.segments,
            [.code(source, language: "swift")]
        )
    }

    func testAnEmptyLanguageIsNoLanguage() {
        XCTAssertEqual(
            content([.code(language: nil, value: "let x = 1")])?.segments,
            [.code("let x = 1", language: nil)]
        )
    }

    /// A `plaintext` `MarkupContent` is text, not markup: the server said so, and
    /// stripping its asterisks would corrupt exactly the answers that took care
    /// to avoid markup in the first place.
    func testPlaintextIsNotInterpretedAsMarkdown() {
        XCTAssertEqual(
            content([.markup(kind: .plaintext, value: "a * b and *not emphasis* and `ticks`")])?.segments,
            [.prose("a * b and *not emphasis* and `ticks`")]
        )
    }

    func testPlaintextIsStillNormalizedForWhitespace() {
        XCTAssertEqual(
            content([.markup(kind: .plaintext, value: "\n\nleading   \n\n\n\ntwo  \n\n")])?.segments,
            [.prose("leading\n\ntwo")]
        )
    }

    /// Normalization is *line-wise*: blank lines go from both ends and trailing
    /// whitespace goes from every line, but a line's leading indentation is left
    /// alone — every line's, including the first. Stripping the first line's and
    /// keeping the rest is the one shape that is certainly wrong, and it is what
    /// trimming the joined block silently produced.
    func testProseIndentationIsTreatedTheSameOnEveryLine() {
        XCTAssertEqual(
            content([.markup(kind: .plaintext, value: "\n    func f()\n        where T: P\n\n")])?.segments,
            [.prose("    func f()\n        where T: P")]
        )
    }

    // MARK: - Fenced code blocks

    func testAFencedBlockBecomesACodeSegmentAndItsInfoStringTheLanguage() {
        let content = markdown("""
        ```swift
        func greet() -> String
        ```
        """)
        XCTAssertEqual(content?.segments, [.code("func greet() -> String", language: "swift")])
    }

    func testAFenceWithNoInfoStringHasNoLanguage() {
        XCTAssertEqual(
            markdown("```\nplain\n```")?.segments,
            [.code("plain", language: nil)]
        )
    }

    func testOnlyTheFirstWordOfTheInfoStringIsTheLanguage() {
        XCTAssertEqual(
            markdown("```rust ignore\nfn main() {}\n```")?.segments,
            [.code("fn main() {}", language: "rust")]
        )
    }

    func testTildeFencesAndLongerFencesAreFencesToo() {
        XCTAssertEqual(
            markdown("~~~~go\nfunc main() {}\n~~~~")?.segments,
            [.code("func main() {}", language: "go")]
        )
    }

    func testAFenceMayBeIndentedAndClosedByALongerRun() {
        XCTAssertEqual(
            markdown("  ```swift\n  let x = 1\n  ````")?.segments,
            [.code("  let x = 1", language: "swift")]
        )
    }

    func testCodeInsideAFenceKeepsItsIndentationAndItsInteriorBlankLines() {
        let content = markdown("""
        ```swift
        struct S {

            let x: Int
        }
        ```
        """)
        XCTAssertEqual(
            content?.segments,
            [.code("struct S {\n\n    let x: Int\n}", language: "swift")]
        )
    }

    func testCodeInsideAFenceIsNotDegraded() {
        XCTAssertEqual(
            markdown("```swift\nlet a = b * c // [see](url) **here**\n```")?.segments,
            [.code("let a = b * c // [see](url) **here**", language: "swift")]
        )
    }

    /// A server that forgets the closing fence still meant the rest to be code.
    func testAnUnterminatedFenceTakesTheRestOfTheElement() {
        XCTAssertEqual(
            markdown("intro\n```swift\nfunc f()\nfunc g()")?.segments,
            [.prose("intro"), .code("func f()\nfunc g()", language: "swift")]
        )
    }

    func testAnEmptyFenceContributesNothing() {
        XCTAssertNil(markdown("```swift\n```"))
        XCTAssertEqual(markdown("```swift\n\n```\nafter")?.segments, [.prose("after")])
    }

    /// The whole reason for two kinds, in the shape rust-analyzer and
    /// sourcekit-lsp actually send: signature, documentation, signature.
    func testProseAndCodeAlternateInTheOrderTheServerWroteThem() {
        let content = markdown("""
        ```swift
        func greet() -> String
        ```
        Greets somebody.

        ```swift
        func greet(_ name: String) -> String
        ```
        """)
        XCTAssertEqual(
            content?.segments,
            [
                .code("func greet() -> String", language: "swift"),
                .prose("Greets somebody."),
                .code("func greet(_ name: String) -> String", language: "swift"),
            ]
        )
    }

    // MARK: - Prose degrading

    func testInlineCodeLosesItsBackticksAndKeepsItsContentsVerbatim() {
        XCTAssertEqual(prose("Returns `Array<T>` when `a*b*c` holds"), "Returns Array<T> when a*b*c holds")
    }

    func testADoubleBacktickSpanIsAlsoACodeSpan() {
        XCTAssertEqual(prose("write ``a ` b`` here"), "write a ` b here")
    }

    func testAnUnbalancedBacktickStaysLiteral() {
        XCTAssertEqual(prose("a ` b"), "a ` b")
    }

    func testEmphasisAndStrongMarkersAreDropped() {
        XCTAssertEqual(prose("*one* **two** ***three***"), "one two three")
        XCTAssertEqual(prose("_one_ __two__"), "one two")
        XCTAssertEqual(prose("intra*word*emphasis"), "intrawordemphasis")
    }

    /// The rule that keeps a symbol spelled the way the code spells it — and the
    /// arithmetic that is not markup either.
    ///
    /// Underscores *inside* a word are never emphasis (Markdown says so, and it
    /// is the difference between `some_identifier_name` and `someidentifiername`
    /// on screen); a pair wrapping a word is, which is why a server that means
    /// the literal `__init__` sends it fenced or backticked, as they all do.
    func testUnderscoresInsideWordsAndLoneAsterisksSurvive() {
        XCTAssertEqual(prose("some_identifier_name and a_b_c"), "some_identifier_name and a_b_c")
        XCTAssertEqual(prose("width * height"), "width * height")
        XCTAssertEqual(prose("`__init__` stays"), "__init__ stays")
    }

    /// A delimiter nothing closes is text, which is CommonMark's rule and the
    /// only one that leaves a symbol spelled the way the code spells it.
    ///
    /// Every case here is prose a real server writes: `w*h` and `5*3` in a
    /// formula, `*ptr` in a C or Rust doc comment, `_private` naming a field.
    /// Dropping the delimiter would rename each of them — the popover's one
    /// unforgivable failure, since a wrong name reads as the code's, not as the
    /// renderer's.
    func testAnUnmatchedEmphasisDelimiterStaysLiteral() {
        XCTAssertEqual(prose("The area is w*h square units."), "The area is w*h square units.")
        XCTAssertEqual(prose("Dereference with *ptr to read it."), "Dereference with *ptr to read it.")
        XCTAssertEqual(prose("Use _private fields sparingly."), "Use _private fields sparingly.")
        XCTAssertEqual(prose("5*3 = 15"), "5*3 = 15")
        // ...and a matched pair on the same line still goes, so the rule is
        // "unmatched", not "never".
        XCTAssertEqual(prose("*emphasis* beside w*h"), "emphasis beside w*h")
    }

    func testHeadingsLoseTheirMarker() {
        XCTAssertEqual(prose("# Title"), "Title")
        XCTAssertEqual(prose("### Deeper ###"), "Deeper")
        XCTAssertEqual(prose("####### not a heading"), "####### not a heading")
        XCTAssertEqual(prose("#hashtag"), "#hashtag")
        // A closing run is only a marker when whitespace precedes it, so a
        // language whose name ends in `#` keeps its name.
        XCTAssertEqual(prose("# Learn C#"), "Learn C#")
        XCTAssertEqual(prose("## F# basics ##"), "F# basics")
        // A heading that is *only* a closing run has no text left, and no text is
        // no answer.
        XCTAssertNil(markdown("# ###"))
    }

    func testListBulletsKeepABullet() {
        XCTAssertEqual(prose("- one\n* two\n+ three"), "• one\n• two\n• three")
        XCTAssertEqual(prose("- one\n  - nested"), "• one\n  • nested")
    }

    func testOrderedListsKeepTheirNumbers() {
        XCTAssertEqual(prose("1. first\n2. second"), "1. first\n2. second")
    }

    func testLinksAndImagesKeepTheirTextAndLoseTheUrl() {
        XCTAssertEqual(prose("see [the docs](https://example.com/very/long)"), "see the docs")
        XCTAssertEqual(prose("![a diagram](img.png) follows"), "a diagram follows")
        XCTAssertEqual(prose("emphasised [*link*](u)"), "emphasised link")
        // A reference-style link is *not* read as one: see
        // `testDoublyBracketedExpressionsAreLeftAsText`.
        XCTAssertEqual(prose("a [reference][ref] link"), "a [reference][ref] link")
    }

    /// Brackets with nothing linked behind them are text, not a label.
    ///
    /// The mirror of the unclosed-emphasis rule, and it matters for the same
    /// reason: `[]byte`, `map[string]int` and `[T; N]` are how Go and Rust spell
    /// *types* in the unfenced prose beside a signature, so reading every
    /// balanced `[…]` as a link label answers `byte`, `mapstringint` and `T; N` —
    /// a wrong name in the one popover whose job is naming things.
    func testBracketsWithNoLinkTargetAreLeftAsText() {
        XCTAssertEqual(prose("returns []byte from the reader"), "returns []byte from the reader")
        XCTAssertEqual(prose("a map[string]int value"), "a map[string]int value")
        XCTAssertEqual(prose("the element at data[index] is used"), "the element at data[index] is used")
        XCTAssertEqual(prose("slice [T; N] here"), "slice [T; N] here")
        // An image whose `!` opens nothing linked is text too, `!` included.
        XCTAssertEqual(prose("negate ![flag] first"), "negate ![flag] first")
        // A target that is opened and never closed is not a target either.
        XCTAssertEqual(prose("see [the docs](https://example.com"), "see [the docs](https://example.com")
        // Inline markup *inside* such a bracket run is still degraded, because the
        // brackets are the only thing being kept.
        XCTAssertEqual(prose("keep [a *b* c] here"), "keep [a b c] here")
    }

    /// The same rule, for the shape a reference-style link is indistinguishable
    /// from: only a `(destination)` makes a `[…]` a link.
    ///
    /// `a[i][j]` is a doubly-indexed expression in every language a server
    /// answers for and is also exactly CommonMark's collapsed-reference syntax,
    /// so the two cannot both be honoured. Reference links lose: their
    /// definitions (`[ref]: url`) are never sent inside a hover string — there
    /// is no document for them to live in — so reading one costs a real name and
    /// buys nothing.
    func testDoublyBracketedExpressionsAreLeftAsText() {
        XCTAssertEqual(prose("the value matrix[i][j] is used"), "the value matrix[i][j] is used")
        XCTAssertEqual(prose("grid[x][y] and a[b][c]"), "grid[x][y] and a[b][c]")
        // Including the image spelling of the same shape.
        XCTAssertEqual(prose("negate ![flag][ref] first"), "negate ![flag][ref] first")
    }

    /// A rule leaves the blank line it was standing in — the separation it meant
    /// survives, the glyph does not, and the blank-line collapse keeps a run of
    /// rules from opening a hole.
    func testHorizontalRulesAreDropped() {
        XCTAssertEqual(prose("above\n\n---\n\nbelow"), "above\n\nbelow")
        XCTAssertEqual(prose("above\n***\nbelow"), "above\n\nbelow")
        XCTAssertEqual(prose("above\n___\nbelow"), "above\n\nbelow")
        XCTAssertEqual(prose("above\n- - -\nbelow"), "above\n\nbelow")
        XCTAssertNil(markdown("---"))
    }

    func testStrayHtmlTagsAreDropped() {
        XCTAssertEqual(prose("a <b>bold</b> word"), "a bold word")
        XCTAssertEqual(prose("line<br/>break"), "linebreak")
        XCTAssertEqual(prose("<p class=\"x\">text</p>"), "text")
    }

    /// The `<` that is not a tag: generics and comparisons read as themselves.
    ///
    /// The single-parameter forms are the ones that matter and the ones a
    /// spec-faithful reader gets wrong: `<T>` and `<u8>` are *valid* raw HTML by
    /// CommonMark's grammar, and they are also how rust-analyzer, gopls and
    /// sourcekit-lsp all spell a generic in the prose beside a signature. An
    /// answer of `Vec` where the server said `Vec<u8>` is wrong, not plain.
    func testAngleBracketsThatAreNotTagsSurvive() {
        XCTAssertEqual(prose("Dictionary<String, Int> when a < b"), "Dictionary<String, Int> when a < b")
        XCTAssertEqual(prose("<https://example.com>"), "<https://example.com>")
        XCTAssertEqual(prose("Returns a Vec<u8> of bytes."), "Returns a Vec<u8> of bytes.")
        XCTAssertEqual(prose("The value is Array<T> here."), "The value is Array<T> here.")
        XCTAssertEqual(prose("Wraps an Option<String> value."), "Wraps an Option<String> value.")
        XCTAssertEqual(prose("Boxed as Box<B> and Set<S>."), "Boxed as Box<B> and Set<S>.")
    }

    /// A `<` that merely *looks* like a tag opening must not license a scan to
    /// the next `>`: everything between them is prose, and deleting it loses a
    /// clause of documentation rather than a glyph of markup.
    func testATagLikeOpeningNeverSwallowsTheTextAfterIt() {
        XCTAssertEqual(prose("Compare a<b and x<y>z"), "Compare a<b and x<y>z")
        XCTAssertEqual(prose("Holds when i<n>0 for all i."), "Holds when i<n>0 for all i.")
        // An unterminated real tag is left alone too, rather than eating the line.
        XCTAssertEqual(prose("a <b class=\"x and more"), "a <b class=\"x and more")
    }

    func testEscapedPunctuationLosesItsBackslash() {
        XCTAssertEqual(prose("a \\* b and \\_c\\_"), "a * b and _c_")
    }

    /// Blank lines go from both ends and trailing whitespace from every line —
    /// but leading indentation stays, on the first line exactly as on the third.
    /// Trimming the joined block instead took the first line's and left the
    /// rest's, which is the one reading no server can have meant.
    func testRunsOfBlankLinesCollapseAndEdgeWhitespaceGoes() {
        XCTAssertEqual(prose("\n\n  one   \n\n\n\n   two\n  \n"), "  one\n\n   two")
    }

    // MARK: - Emptiness

    func testEmptinessInEveryShapeIsNoContentAtAll() {
        XCTAssertNil(content([]))
        XCTAssertNil(content([.markup(kind: .markdown, value: "")]))
        XCTAssertNil(content([.markup(kind: .plaintext, value: "   \n\t\n  ")]))
        XCTAssertNil(content([.code(language: "swift", value: "")]))
        XCTAssertNil(content([.code(language: "swift", value: "\n  \n")]))
        XCTAssertNil(markdown("**  **"))
        XCTAssertNil(markdown("<div>\n</div>"))
    }

    func testAnEmptyElementBesideARealOneIsSimplyDropped() {
        let content = self.content([
            .code(language: "swift", value: "  \n "),
            .markup(kind: .markdown, value: "Real."),
        ])
        XCTAssertEqual(content?.segments, [.prose("Real.")])
    }

    func testTheFailableInitRefusesSegmentsThatCarryNothing() {
        XCTAssertNil(HoverContent(segments: []))
        XCTAssertNil(HoverContent(segments: [.prose("   "), .code("\n")]))
        XCTAssertEqual(
            HoverContent(segments: [.prose(" "), .prose("kept")])?.segments,
            [.prose("kept")]
        )
    }

    func testAnEmptyHoverResponseIsNoContent() {
        XCTAssertNil(HoverContent(LSPHoverResponse(elements: [])))
        XCTAssertNotNil(HoverContent(LSPHoverResponse(elements: [.code(language: "go", value: "func f()")])))
    }

    // MARK: - Order across elements

    func testMultipleElementsStaySeparateSegmentsInOrder() {
        let content = self.content([
            .code(language: "swift", value: "func f()"),
            .markup(kind: .markdown, value: "Does a thing."),
            .code(language: nil, value: "f()"),
        ])
        XCTAssertEqual(
            content?.segments,
            [
                .code("func f()", language: "swift"),
                .prose("Does a thing."),
                .code("f()", language: nil),
            ]
        )
    }

    // MARK: - Truncation

    private func lines(_ count: Int, prefix: String = "line") -> String {
        (1...count).map { "\(prefix) \($0)" }.joined(separator: "\n")
    }

    func testContentUnderTheCapIsReturnedUnchanged() {
        let content = try! XCTUnwrap(markdown(lines(5)))
        let capped = content.truncated(toLineCount: 10)
        XCTAssertEqual(capped, content)
        XCTAssertFalse(capped.isTruncated)
        XCTAssertEqual(capped.lineCount, 5)
    }

    func testContentExactlyAtTheCapIsNotTruncated() {
        let content = try! XCTUnwrap(markdown(lines(4)))
        XCTAssertFalse(content.truncated(toLineCount: 4).isTruncated)
    }

    func testContentOverTheCapIsCutAndSaysSo() {
        let content = try! XCTUnwrap(markdown(lines(10)))
        let capped = content.truncated(toLineCount: 3)
        XCTAssertTrue(capped.isTruncated)
        XCTAssertEqual(capped.lineCount, 3)
        XCTAssertEqual(capped.segments, [.prose("line 1\nline 2\nline 3")])
    }

    /// The cap counts lines across the whole answer, and a segment cut in half
    /// keeps its kind and its language — half a code block is still code.
    func testTruncationSpansSegmentsAndKeepsTheKindOfThePartialOne() {
        let content = try! XCTUnwrap(markdown("""
        one
        two
        ```swift
        func a()
        func b()
        func c()
        ```
        """))
        let capped = content.truncated(toLineCount: 4)
        XCTAssertEqual(
            capped.segments,
            [.prose("one\ntwo"), .code("func a()\nfunc b()", language: "swift")]
        )
        XCTAssertTrue(capped.isTruncated)
    }

    func testTruncationDropsWholeSegmentsPastTheCap() {
        let content = try! XCTUnwrap(markdown("one\ntwo\n```swift\nfunc a()\n```"))
        let capped = content.truncated(toLineCount: 2)
        XCTAssertEqual(capped.segments, [.prose("one\ntwo")])
    }

    /// There is no empty popover, so there is no zero-line cap either.
    func testACapBelowOneLineStillKeepsALine() {
        let content = try! XCTUnwrap(markdown(lines(3)))
        for limit in [0, -1, Int.min] {
            let capped = content.truncated(toLineCount: limit)
            XCTAssertEqual(capped.segments, [.prose("line 1")])
            XCTAssertTrue(capped.isTruncated)
        }
    }

    func testTruncationIsIdempotentAtTheSameLimit() {
        let content = try! XCTUnwrap(markdown(lines(10)))
        let once = content.truncated(toLineCount: 4)
        XCTAssertEqual(once.truncated(toLineCount: 4), once)
    }

    func testTheDefaultCapIsTheDeclaredMaximum() {
        let content = try! XCTUnwrap(markdown(lines(HoverContent.maximumLineCount + 5)))
        XCTAssertEqual(content.truncated().lineCount, HoverContent.maximumLineCount)
        XCTAssertTrue(content.truncated().isTruncated)
    }

    // MARK: - Truncating a line

    /// A line count bounds nothing on its own: the answer's size is the server's
    /// to choose, and the renderer lays the string out on the main thread.
    func testALineLongerThanTheCapIsCutAndSaysSo() {
        let content = try! XCTUnwrap(markdown(String(repeating: "x", count: 50)))
        let capped = content.truncated(toLineCount: 10, lineLength: 20)
        XCTAssertEqual(capped.segments, [.prose(String(repeating: "x", count: 20))])
        XCTAssertTrue(capped.isTruncated)
    }

    func testALineExactlyAtTheLengthCapIsNotCut() {
        let content = try! XCTUnwrap(markdown(String(repeating: "x", count: 20)))
        let capped = content.truncated(toLineCount: 10, lineLength: 20)
        XCTAssertEqual(capped, content)
        XCTAssertFalse(capped.isTruncated)
    }

    /// Every line is bounded, not just the first — and the segment's kind and
    /// language survive the cut, exactly as they do for the line cap.
    func testEveryLineIsCutAndTheSegmentKeepsItsKind() {
        let content = try! XCTUnwrap(markdown("""
        ```swift
        aaaaaa
        bb
        cccccc
        ```
        """))
        let capped = content.truncated(toLineCount: 10, lineLength: 3)
        XCTAssertEqual(capped.segments, [.code("aaa\nbb\nccc", language: "swift")])
        XCTAssertTrue(capped.isTruncated)
    }

    /// The cut lands on a `Character` boundary, so a popover can never draw half
    /// a grapheme — the cap is a bound on work, not a licence to corrupt text.
    func testALineIsCutOnACharacterBoundary() {
        let content = try! XCTUnwrap(markdown("é🇺🇦👩‍👩‍👧‍👦x"))
        let capped = try! XCTUnwrap(content.truncated(toLineCount: 10, lineLength: 3).segments.first)
        XCTAssertEqual(capped.text, "é🇺🇦👩‍👩‍👧‍👦")
    }

    /// There is no empty popover, so there is no zero-character cap either.
    func testACapBelowOneCharacterStillKeepsACharacter() {
        let content = try! XCTUnwrap(markdown("abc"))
        for limit in [0, -1, Int.min] {
            let capped = content.truncated(toLineCount: 10, lineLength: limit)
            XCTAssertEqual(capped.segments, [.prose("a")])
            XCTAssertTrue(capped.isTruncated)
        }
    }

    func testLineLengthTruncationIsIdempotentAtTheSameLimit() {
        let content = try! XCTUnwrap(markdown("abcdef\nghijkl"))
        let once = content.truncated(toLineCount: 10, lineLength: 3)
        XCTAssertEqual(once.truncated(toLineCount: 10, lineLength: 3), once)
        XCTAssertTrue(once.truncated(toLineCount: 10, lineLength: 3).isTruncated)
    }

    func testTheDefaultLineLengthCapIsTheDeclaredMaximum() {
        let long = String(repeating: "x", count: HoverContent.maximumLineLength + 5)
        let content = try! XCTUnwrap(markdown(long))
        let capped = content.truncated()
        XCTAssertEqual(capped.segments.first?.text.count, HoverContent.maximumLineLength)
        XCTAssertTrue(capped.isTruncated)
    }

    /// Both dimensions at once, which is the shape a runaway answer actually has.
    func testBothCapsApplyTogether() {
        let content = try! XCTUnwrap(markdown(lines(10, prefix: "aaaaaaaa")))
        let capped = content.truncated(toLineCount: 2, lineLength: 5)
        XCTAssertEqual(capped.segments, [.prose("aaaaa\naaaaa")])
        XCTAssertTrue(capped.isTruncated)
    }

    // MARK: - The constants

    func testTheFeaturesTwoConstantsLiveHere() {
        XCTAssertEqual(HoverContent.dwellDelay, 0.35, accuracy: 0.0001)
        XCTAssertGreaterThan(HoverContent.maximumLineCount, 1)
        XCTAssertGreaterThan(HoverContent.maximumLineLength, 1)
    }

    // MARK: - A whole answer, end to end

    /// The shape a real server sends, read once: signature, documentation with
    /// a heading, a list and a link, then a second fenced block.
    func testARealisticAnswerReadsAsSegments() {
        let content = markdown("""
        ```swift
        func decode<T>(_ type: T.Type) throws -> T
        ```

        ---

        # Decode

        Decodes a value of the **given** type from `data`.

        - Throws `DecodingError` on failure
        - See [the guide](https://example.com/guide)

        <br/>

        ```swift
        let value = try decode(Thing.self)
        ```
        """)
        XCTAssertEqual(
            content?.segments,
            [
                .code("func decode<T>(_ type: T.Type) throws -> T", language: "swift"),
                .prose(
                    """
                    Decode

                    Decodes a value of the given type from data.

                    • Throws DecodingError on failure
                    • See the guide
                    """
                ),
                .code("let value = try decode(Thing.self)", language: "swift"),
            ]
        )
    }
}
