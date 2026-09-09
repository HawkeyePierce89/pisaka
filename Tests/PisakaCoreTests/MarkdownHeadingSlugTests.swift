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
}
