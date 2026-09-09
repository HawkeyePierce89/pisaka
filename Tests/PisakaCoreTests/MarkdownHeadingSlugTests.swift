import XCTest
@testable import PisakaCore

/// The heading-anchor rule: a heading's flattened text in, an `id` out.
///
/// The rule is asserted here on its own, and asserted *again* end to end in
/// `MarkdownLinkRuleTests` — where a rendered link's `href` is resolved the way
/// the web view resolves it and handed to `MarkdownLinkRule`. This suite is
/// about the sentence the rule states; that one is about the two halves agreeing.
final class MarkdownHeadingSlugTests: XCTestCase {

    // MARK: - The rule

    func testTheSlugIsLowercased() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "A Heading"), "a-heading")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "SHOUTING"), "shouting")
    }

    /// Everything outside the four classes is removed, and removal is not
    /// substitution: `C++ & D` loses three characters and keeps the two spaces
    /// that surrounded them, so it slugs with a run of hyphens rather than one.
    func testPunctuationIsRemovedRatherThanFolded() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "What's new?"), "whats-new")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "C++ & D"), "c--d")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "Section 3.1: names"), "section-31-names")
    }

    /// A hyphen the heading already spelled survives; a space becomes one.
    func testSpacesBecomeHyphensAndHyphensSurvive() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "read-only mode"), "read-only-mode")
    }

    /// "Space" is the ASCII space and nothing else — a tab is *removed*, which
    /// is the detail a reader assumes the other way. `a\tb` is therefore `ab`,
    /// not `a-b`.
    func testATabIsRemovedRatherThanFoldedToAHyphen() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "a\tb"), "ab")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "a\u{00A0}b"), "ab")
    }

    /// Letter and digit are Unicode's, so a non-English document has anchors.
    func testNonASCIILettersAndDigitsSurvive() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "Привет мир"), "привет-мир")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "Größe 2"), "größe-2")
    }

    /// An underscore survives, like a hyphen: GFM's punctuation set does not
    /// contain `_`, so `## snake_case` is `#snake_case` there and must be here.
    /// Dropping it would send every anchor copied from a rendered README — and
    /// every one an author typed by reading the heading — to nothing at all.
    func testUnderscoresSurvive() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "snake_case"), "snake_case")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "__init__"), "__init__")
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "The indent_style property"), "the-indent_style-property")
    }

    /// A heading with nothing nameable in it answers `nil` — not `""`, which
    /// would be an `id` no fragment can name while still looking like a target.
    func testAHeadingWithNothingNameableHasNoSlug() {
        XCTAssertNil(MarkdownHeadingSlug.slug(forText: ""))
        XCTAssertNil(MarkdownHeadingSlug.slug(forText: "!?.,"))
        XCTAssertNil(MarkdownHeadingSlug.slug(forText: "\t\n"))
    }

    /// A heading of only spaces is *not* nothing: the spaces are hyphens, which
    /// is a nameable id and the same answer GFM gives.
    func testAHeadingOfOnlySpacesSlugsToHyphens() {
        XCTAssertEqual(MarkdownHeadingSlug.slug(forText: "  "), "--")
    }

    // MARK: - The allocator

    func testRepeatsAreSuffixedInDocumentOrder() {
        var slugs = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(slugs.allocate(forText: "x"), "x")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-1")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-2")
        XCTAssertEqual(slugs.allocate(forText: "y"), "y")
    }

    /// Two headings whose *texts* differ but whose slugs do not are the same
    /// repeat, which is what makes the rule about the id rather than the words.
    func testTwoHeadingsSharingASlugAreOneRepeat() {
        var slugs = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(slugs.allocate(forText: "The Rule"), "the-rule")
        XCTAssertEqual(slugs.allocate(forText: "the rule!"), "the-rule-1")
    }

    /// The interesting collision: a document that spells the suffixed form
    /// itself. Counting per base alone would hand out `x-1` twice, and the
    /// second link would silently reach the first heading.
    func testASlugThatAlreadyEndsInASuffixDoesNotCollide() {
        var slugs = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(slugs.allocate(forText: "x"), "x")
        XCTAssertEqual(slugs.allocate(forText: "x 1"), "x-1")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-2")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-3")
    }

    /// The same collision reached from the other side: the explicit form comes
    /// *after* the suffix was handed out, so the search has to skip it too.
    func testAnExplicitSuffixArrivingLaterIsStillDistinct() {
        var slugs = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(slugs.allocate(forText: "x"), "x")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-1")
        XCTAssertEqual(slugs.allocate(forText: "x 1"), "x-1-1")
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-2")
    }

    /// Every id one allocator hands out is distinct, which is the property the
    /// two cases above are instances of.
    func testEveryAllocatedIDIsDistinct() {
        var slugs = MarkdownHeadingSlug.Allocator()
        let texts = ["x", "x", "x 1", "x", "x 2", "x", "y", "x-1", "x"]
        let allocated = texts.compactMap { slugs.allocate(forText: $0) }
        XCTAssertEqual(allocated.count, texts.count)
        XCTAssertEqual(Set(allocated).count, allocated.count, "\(allocated)")
    }

    /// An unnameable heading takes no number with it: it answers `nil` and the
    /// next repeat of a real slug is unaffected.
    func testAnUnnameableHeadingAllocatesNothing() {
        var slugs = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(slugs.allocate(forText: "x"), "x")
        XCTAssertNil(slugs.allocate(forText: "!!"))
        XCTAssertNil(slugs.allocate(forText: "!!"))
        XCTAssertEqual(slugs.allocate(forText: "x"), "x-1")
    }

    /// A fresh allocator starts over, which is what makes a render a pure
    /// function of its tree: the same document rendered twice is the same markup.
    func testAFreshAllocatorStartsOver() {
        var first = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(first.allocate(forText: "x"), "x")
        var second = MarkdownHeadingSlug.Allocator()
        XCTAssertEqual(second.allocate(forText: "x"), "x")
    }

    // MARK: - Reserved ids

    /// A reserved id is taken before the walk begins, so the heading that would
    /// have had it is suffixed instead. This is how the renderer keeps a heading
    /// off the container id the shell itself ships.
    func testAReservedIDIsNotHandedOut() {
        var slugs = MarkdownHeadingSlug.Allocator(reserving: ["content"])
        XCTAssertEqual(slugs.allocate(forText: "Content"), "content-1")
        XCTAssertEqual(slugs.allocate(forText: "Content"), "content-2")
    }

    /// Reserving something the document never names changes nothing.
    func testAReservationNoHeadingWantsIsInert() {
        var slugs = MarkdownHeadingSlug.Allocator(reserving: ["content"])
        XCTAssertEqual(slugs.allocate(forText: "Notes"), "notes")
    }

    // MARK: - The diagram id family

    /// No slug this rule can answer carries an ASCII capital.
    ///
    /// The page's *other* id family — the one `preview.js` hands mermaid, which
    /// mermaid removes an existing element for before it draws — is an unbounded
    /// sequence and so cannot be reserved the way the container id is. What
    /// keeps a heading off it is this alphabet: the rule lowercases before it
    /// filters, so a prefix carrying a capital is unreachable from any heading
    /// text at all. Asserted over inputs from four scripts, because "lowercased"
    /// is Unicode's answer rather than ASCII's and a Cherokee or Georgian
    /// capital is exactly the kind of thing that would fold the other way.
    func testNoSlugCarriesAnASCIICapital() {
        let texts = [
            "PisakaDiagram1", "PISAKA DIAGRAM 1", "Pisaka_Diagram-1",
            "ПРИВЕТ Мир", "ΑΘΉΝΑ Δοκιμή", "ᏣᎳᏋ", "ႨႩႪ", "Straße ẞ",
            "MiXeD CaSe 42",
        ]
        for text in texts {
            let slug = MarkdownHeadingSlug.slug(forText: text)
            XCTAssertNotNil(slug, text)
            XCTAssertFalse(slug?.contains(where: { $0.isASCII && $0.isUppercase }) ?? true, """
                “\(text)” slugs to “\(slug ?? "")”, which carries an ASCII capital. The diagram id \
                family is kept out of a heading's reach by that alphabet alone: a slug that can \
                spell one can name an element mermaid deletes before it renders.
                """)
        }
    }

    /// …and the prefix `preview.js` builds a diagram id from carries one, which
    /// is the other half of the same property.
    func testTheDiagramIDPrefixIsUnreachableFromAnyHeading() {
        let prefix = MarkdownPreviewPage.diagramElementIDPrefix
        XCTAssertTrue(prefix.contains(where: { $0.isASCII && $0.isUppercase }), """
            MarkdownPreviewPage.diagramElementIDPrefix is “\(prefix)”, which carries no ASCII \
            capital — so a heading could slug to a diagram id, and mermaid would remove that \
            heading from the page the first time any fence rendered.
            """)
        // The whole id, not just the prefix: what mermaid is handed is the
        // prefix and a decimal counter, and it is that string a heading must
        // not be able to spell.
        var slugs = MarkdownHeadingSlug.Allocator()
        for sequence in 1...3 {
            let diagramID = "\(prefix)\(sequence)"
            XCTAssertNotEqual(slugs.allocate(forText: diagramID), diagramID)
        }
    }
}
