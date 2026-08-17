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

    /// A line the length cap cuts does not end the answer: the lines after it are
    /// still content, and the cap is a bound on what is drawn rather than a
    /// tripwire that swallows the rest.
    func testTheLinesAfterAnOverlongOneSurvive() {
        let content = try! XCTUnwrap(
            HoverContent(segments: [.code("\(String(repeating: "x", count: 50))\nfunc f()\nfunc g()")])
        )
        let capped = content.truncated(toLineCount: 10, lineLength: 4)
        XCTAssertEqual(capped.segments, [.code("xxxx\nfunc\nfunc")])
        XCTAssertTrue(capped.isTruncated)
    }

    /// A payload a language server is free to make enormous (`LSPFraming` carries
    /// up to 64 MB), cut to the cap — and cut by the *initializer*, which is the
    /// half of the rule an assertion can state. `truncated` then finds nothing
    /// left to do, which is what makes the renderer's main-thread work bounded by
    /// the popover rather than by the answer.
    func testAHugeSingleLineIsCutToTheCapWhenTheContentIsBuilt() {
        let huge = String(repeating: "x", count: 4_000_000)
        let content = try! XCTUnwrap(HoverContent(segments: [.code("\(huge)\ntail")]))
        XCTAssertEqual(
            content.segments,
            [.code("\(String(repeating: "x", count: HoverContent.maximumLineLength))\ntail")]
        )
        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.truncated(), content)
    }

    /// Interior blank lines are lines: they count against the cap and they are
    /// kept, which is the one shape a line-by-line reader can get wrong in both
    /// directions.
    func testInteriorBlankLinesCountAndAreKept() {
        let content = try! XCTUnwrap(HoverContent(segments: [.prose("a\n\nb\n\nc")]))
        XCTAssertEqual(content.lineCount, 5)
        let capped = content.truncated(toLineCount: 3, lineLength: 10)
        XCTAssertEqual(capped.segments, [.prose("a\n\nb")])
        XCTAssertTrue(capped.isTruncated)
    }

    /// Both dimensions at once, which is the shape a runaway answer actually has.
    func testBothCapsApplyTogether() {
        let content = try! XCTUnwrap(markdown(lines(10, prefix: "aaaaaaaa")))
        let capped = content.truncated(toLineCount: 2, lineLength: 5)
        XCTAssertEqual(capped.segments, [.prose("aaaaa\naaaaa")])
        XCTAssertTrue(capped.isTruncated)
    }

    // MARK: - The no-empty-popover invariant, on the initializer's own terms

    /// `HoverMarkup` never hands over a segment with a blank first line, but the
    /// public initializer is reachable without it — and `truncated` keeps a
    /// *prefix* of a segment's lines, so a blank first line is the one shape that
    /// can be cut down to nothing at all.
    func testTheCheckingInitializerStripsBlankEdgeLinesFromASegment() {
        let content = try! XCTUnwrap(HoverContent(segments: [.prose("\n \n  indented\n\n")]))
        XCTAssertEqual(content.segments, [.prose("  indented")])
    }

    /// The hang guard is the initializer's, so it holds for *every* line of every
    /// segment however the content was built — that is what lets the renderer walk
    /// the text without first measuring the server's answer.
    func testTheCheckingInitializerClipsEveryLineToTheLengthCapAndSaysSo() {
        let long = String(repeating: "x", count: HoverContent.maximumLineLength + 5)
        let content = try! XCTUnwrap(
            HoverContent(segments: [.code("short\n\(long)"), .prose(long)])
        )
        XCTAssertTrue(content.isTruncated)
        for segment in content.segments {
            for line in segment.lines {
                XCTAssertLessThanOrEqual(line.count, HoverContent.maximumLineLength)
            }
        }
    }

    /// A line under the cap is not a line the initializer touches, and untouched
    /// content is not truncated content.
    func testTheCheckingInitializerLeavesShortLinesAloneAndSaysNothing() {
        let content = try! XCTUnwrap(HoverContent(segments: [.code("func f()\nfunc g()")]))
        XCTAssertEqual(content.segments, [.code("func f()\nfunc g()")])
        XCTAssertFalse(content.isTruncated)
    }

    /// The character cap alone bounds nothing the renderer pays for: a grapheme
    /// cluster has no size limit, so a megabyte of combining marks is *one*
    /// character and passes it whole. The byte cap is what turns "at most twenty
    /// short lines" into "at most a bounded amount of text to lay out".
    func testAMegabyteSingleGraphemeLineDoesNotSurviveTheLengthCap() {
        let blob = "a" + String(repeating: "\u{0301}", count: 500_000)
        XCTAssertEqual(blob.count, 1)  // the whole point: one Character, one megabyte
        let content = try! XCTUnwrap(HoverContent(segments: [.code("\(blob)\nfunc f()")]))
        XCTAssertEqual(content.segments, [.code("func f()")])
        XCTAssertTrue(content.isTruncated)
    }

    /// A cluster too big for the byte cap is dropped whole rather than halved, and
    /// content that is nothing but such a cluster is no content — the same
    /// no-empty-popover rule the empty answer obeys.
    func testContentThatIsNothingButAnOversizedGraphemeIsNoContent() {
        let blob = "a" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertNil(HoverContent(segments: [.prose(blob)]))
    }

    /// The byte cap cuts on a `Character` boundary, so a clipped line is still
    /// text: whole clusters, none halved, and inside both bounds.
    func testTheByteCapCutsOnGraphemeBoundaries() {
        let family = "👨‍👩‍👧‍👦"  // one Character, 25 UTF-8 bytes
        let line = String(repeating: family, count: 2_000)
        let content = try! XCTUnwrap(HoverContent(segments: [.code(line)]))
        XCTAssertTrue(content.isTruncated)
        let clipped = try! XCTUnwrap(content.segments.first).text
        XCTAssertLessThanOrEqual(clipped.utf8.count, HoverContent.maximumLineUTF8Length)
        XCTAssertGreaterThan(clipped.utf8.count, HoverContent.maximumLineUTF8Length - family.utf8.count)
        XCTAssertEqual(clipped, String(repeating: family, count: clipped.count))
    }

    /// The byte cap is generous enough that ordinary non-ASCII text never meets
    /// it: it is a hang guard, not a "no CJK past here" rule.
    func testOrdinaryMultibyteTextIsNotClipped() {
        let line = String(repeating: "型", count: 300)  // 900 UTF-8 bytes
        let content = try! XCTUnwrap(HoverContent(segments: [.prose(line)]))
        XCTAssertEqual(content.segments, [.prose(line)])
        XCTAssertFalse(content.isTruncated)
    }

    /// Clipping happens *before* the blank edges go, so the one line that clips
    /// down to nothing but indentation cannot become a segment with nothing to
    /// draw — the same no-empty-popover rule, at the other end of the pipe.
    func testALineThatClipsDownToWhitespaceIsNotKeptAsASegment() {
        let indented = String(repeating: " ", count: HoverContent.maximumLineLength + 10) + "x"
        XCTAssertNil(HoverContent(segments: [.prose(indented)]))
        let content = try! XCTUnwrap(
            HoverContent(segments: [.prose(indented), .code("func f()")])
        )
        XCTAssertEqual(content.segments, [.code("func f()")])
        XCTAssertTrue(content.isTruncated)
    }

    func testTruncatingContentWithBlankLeadingLinesStillDrawsSomething() {
        let content = try! XCTUnwrap(HoverContent(segments: [.prose("\n\nfoo\nbar")]))
        let capped = content.truncated(toLineCount: 1)
        XCTAssertEqual(capped.segments, [.prose("foo")])
        XCTAssertTrue(capped.isTruncated)
    }

    /// A length cap small enough to leave a first line's indentation and nothing
    /// else. The cap loses rather than the invariant: an answer too big for the
    /// cap is still an answer, an empty popover is not.
    func testALengthCapThatWouldLeaveOnlyWhitespaceKeepsTheAnswerWhole() {
        let content = try! XCTUnwrap(HoverContent(segments: [.code("    func f()")]))
        let capped = content.truncated(toLineCount: 10, lineLength: 2)
        XCTAssertEqual(capped, content)
        XCTAssertFalse(capped.isTruncated)
    }

    /// Whatever the caps, every segment that survives carries something drawable.
    func testNoCapEverProducesABlankSegment() {
        let content = try! XCTUnwrap(
            HoverContent(segments: [.code("  a\n\n  b"), .prose("c\n\nd")])
        )
        for limit in 1...6 {
            for length in 1...4 {
                let capped = content.truncated(toLineCount: limit, lineLength: length)
                XCTAssertFalse(capped.segments.isEmpty)
                for segment in capped.segments {
                    XCTAssertFalse(
                        segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "blank segment at limit \(limit), length \(length)"
                    )
                }
            }
        }
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

    // MARK: The caps run before the interpreter

    /// A line longer than the character cap is cut *before* `HoverMarkup` reads
    /// it, so the superlinear inline pass can never walk an unbounded line. The
    /// pathological shape — an opener that never closes — used to cost eighteen
    /// seconds for eighty kilobytes; a cap after the parse would have paid it.
    func testUnclosedLinkOpenersAreClippedBeforeInterpretation() {
        let markdown = String(repeating: "[a](", count: 20_000)
        let start = Date()
        let content = HoverContent(hoverElements: [.markup(kind: .markdown, value: markdown)])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(content?.isTruncated, true)
        XCTAssertLessThanOrEqual(
            content?.segments.first?.text.count ?? .max,
            HoverContent.maximumLineLength
        )
        XCTAssertLessThan(elapsed, 2)
    }

    /// The same guard on the byte cap's side: one very long line of ordinary
    /// text reaches the interpreter already bounded.
    func testALongLineIsBoundedBeforeInterpretationAndMarkedTruncated() {
        let markdown = String(repeating: "a", count: HoverContent.maximumLineLength + 500)
        let content = HoverContent(hoverElements: [.markup(kind: .markdown, value: markdown)])
        XCTAssertEqual(content?.segments.count, 1)
        XCTAssertEqual(content?.segments.first?.text.count, HoverContent.maximumLineLength)
        XCTAssertEqual(content?.isTruncated, true)
    }

    /// Clipping before the parse must not change an answer that fits: a short
    /// element is interpreted exactly as before and is not marked truncated.
    func testClippingBeforeInterpretationLeavesOrdinaryAnswersAlone() {
        let content = HoverContent(hoverElements: [
            .markup(kind: .markdown, value: "See [the guide](https://example.com) for `Box<T>`.")
        ])
        XCTAssertEqual(content?.segments, [.prose("See the guide for Box<T>.")])
        XCTAssertEqual(content?.isTruncated, false)
    }

    /// A label degrades by recursion, so nesting is stack depth the *server*
    /// chooses. Past the nesting bound the bracket is text — the same answer an
    /// unmatched one gets — and nothing overflows.
    func testDeeplyNestedLabelsDoNotRecurseWithoutBound() {
        // Short enough that the length cap alone would not save this: the depth
        // bound is what stops the recursion.
        let depth = 300
        let markdown = String(repeating: "[", count: depth)
            + "x"
            + String(repeating: "](u)", count: depth)
        XCTAssertLessThan(markdown.count, HoverContent.maximumLineLength)
        let content = HoverContent(hoverElements: [.markup(kind: .markdown, value: markdown)])
        // It survives, it is bounded, and the label it was nesting is still text.
        XCTAssertNotNil(content)
        XCTAssertLessThanOrEqual(
            content?.segments.first?.text.count ?? .max,
            HoverContent.maximumLineLength
        )
        XCTAssertEqual(content?.segments.first?.text.contains("x"), true)
    }

    /// The same shape run where the recursion used to overflow: on a
    /// cooperative-pool thread, which is where `LSPIntelligenceProvider` reads a
    /// hover answer and whose stack is a fraction of the main thread's.
    func testDeeplyNestedLabelsSurviveOffTheMainThread() async {
        let depth = 5_000
        let markdown = String(repeating: "[", count: depth)
            + "x"
            + String(repeating: "](u)", count: depth)
        let lineCount = await Task.detached {
            HoverContent(hoverElements: [.markup(kind: .markdown, value: markdown)])?.lineCount
        }.value
        XCTAssertEqual(lineCount, 1)
    }

    /// Nesting the reader *does* follow is unaffected by the bound: a label
    /// inside a label is still degraded, not left as markup.
    func testNestingWithinTheBoundIsStillDegraded() {
        let content = HoverContent(hoverElements: [
            .markup(kind: .markdown, value: "[an [inner](https://b) label](https://a)")
        ])
        XCTAssertEqual(content?.segments, [.prose("an inner label")])
    }


    // MARK: - The line-count guard

    /// The guard's reason for existing: a server answering with far more lines
    /// than the popover can draw is bounded *before* the markup reader walks
    /// them, not after `truncated(toLineCount:)` throws them away.
    func testAnAnswerOfManyLinesIsBoundedBeforeItIsInterpreted() {
        let lines = HoverContent.maximumInterpretedLineCount * 50
        let markdown = Array(repeating: "x", count: lines).joined(separator: "\n")
        let content = HoverContent(hoverElements: [.markup(kind: .markdown, value: markdown)])
        XCTAssertEqual(content?.lineCount, HoverContent.maximumInterpretedLineCount)
        XCTAssertEqual(content?.isTruncated, true)
    }

    /// The budget is spent over the elements together. A payload of many small
    /// elements is the same threat as one big one, so a per-element bound would
    /// be no bound at all.
    func testTheLineBudgetIsSpentAcrossElementsTogether() {
        let elements = Array(
            repeating: LSPHoverElement.markup(kind: .plaintext, value: "a\nb\nc\nd\ne"),
            count: HoverContent.maximumInterpretedLineCount
        )
        let content = HoverContent(hoverElements: elements)
        XCTAssertEqual(content?.lineCount, HoverContent.maximumInterpretedLineCount)
        XCTAssertEqual(content?.isTruncated, true)
    }

    /// Elements dropped for want of budget are content lost, and the marker is
    /// how the popover says so — even when nothing in the elements that *were*
    /// read had to be cut.
    func testElementsLeftUnreadMarkTheAnswerTruncated() {
        let filler = Array(repeating: "x", count: HoverContent.maximumInterpretedLineCount)
            .joined(separator: "\n")
        let content = HoverContent(hoverElements: [
            .code(language: "swift", value: filler),
            .markup(kind: .plaintext, value: "never read"),
        ])
        XCTAssertEqual(content?.isTruncated, true)
        XCTAssertEqual(content?.segments.count, 1)
        XCTAssertEqual(content?.segments.first?.text.contains("never read"), false)
    }

    /// The guard must never be what cuts a real answer: an ordinary hover — a
    /// signature and a paragraph — passes it whole and unmarked.
    func testAnOrdinaryAnswerIsNotTouchedByTheLineGuard() {
        let content = HoverContent(hoverElements: [
            .code(language: "swift", value: "func f() -> Int"),
            .markup(kind: .markdown, value: "Does a thing.\n\nTwice."),
        ])
        XCTAssertEqual(content?.isTruncated, false)
        XCTAssertEqual(
            content?.segments,
            [.code("func f() -> Int", language: "swift"), .prose("Does a thing.\n\nTwice.")]
        )
    }

    /// The bound leaves the drawn popover room: the twenty lines the renderer
    /// shows sit well inside what the reader is handed.
    func testTheLineGuardLeavesTheRendererItsFullCap() {
        XCTAssertGreaterThan(
            HoverContent.maximumInterpretedLineCount,
            HoverContent.maximumLineCount
        )
    }

    /// The bounded split is the unbounded one, stopped: same lines, same
    /// separators — `\r\n` and a bare `\r` are each one break — and a text that
    /// ends on a terminator has a trailing empty line like any other.
    func testTheBoundedSplitAgreesWithTheUnboundedOne() {
        for text in ["a\r\nb\rc\nd", "", "\n", "a\n", "\r\n\r\n", "one line", "a\n\nb"] {
            let bounded = HoverMarkup.lines(of: text, limit: .max)
            XCTAssertEqual(bounded.lines, HoverMarkup.lines(of: text), "text: \(text.debugDescription)")
            XCTAssertFalse(bounded.didClip, "text: \(text.debugDescription)")
        }
    }

    /// Running the budget out exactly on a trailing empty line is not content
    /// lost, so it does not raise the flag.
    func testABudgetSpentOnATrailingEmptyLineIsNotAClip() {
        XCTAssertEqual(HoverMarkup.lines(of: "a\nb", limit: 2).didClip, false)
        XCTAssertEqual(HoverMarkup.lines(of: "a\nb\n", limit: 2).didClip, false)
        XCTAssertEqual(HoverMarkup.lines(of: "a\nb\nc", limit: 2).didClip, true)
    }

}
