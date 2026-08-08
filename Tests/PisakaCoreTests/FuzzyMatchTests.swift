import XCTest
@testable import PisakaCore

/// Pins the completion matcher: which candidates a typed query reaches at all,
/// and in what order the ranking sees them. Two rules carry the whole feature
/// and are asserted from several angles here — a fuzzy match must *start* on a
/// word boundary, and a literal prefix match keeps a constant key so the
/// pre-existing ranking is unchanged.
final class FuzzyMatchTests: XCTestCase {

    // MARK: - Word boundaries

    func testBoundaryInitialsCoverCamelHumps() {
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "ArrayBuffer"), ["a", "b"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "arrayBuffer"), ["a", "b"])
    }

    /// The last uppercase of an uppercase run followed by a lowercase is the
    /// word start — `URLSession` is reachable by `s`, and the interior `R`/`L`
    /// do not become keys of their own.
    func testBoundaryInitialsHandleUppercaseRuns() {
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "URLSession"), ["u", "s"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "URL"), ["u"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "HTTPServerDelegate"), ["h", "s", "d"])
    }

    func testBoundaryInitialsHandleSeparatorsAndDigits() {
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "snake_case"), ["s", "c"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "kebab-case"), ["k", "c"])
        // A leading underscore stays a key of its own, so `_private` is
        // reachable both by typing the underscore and by typing `p`.
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "_private"), ["_", "p"])
        // A run of separators marks the character after the run, not the
        // separators themselves.
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "foo__bar"), ["f", "b"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "base64Encoder"), ["b", "6", "e"])
    }

    func testBoundaryInitialsAreDeduplicatedAndCapped() {
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "aAa"), ["a"])
        XCTAssertEqual(
            FuzzyMatch.wordBoundaryInitials(of: "a_b_c_d_e_f_g_h_i_j"),
            ["a", "b", "c", "d", "e", "f", "g", "h"]
        )
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "").count, 0)
    }

    /// A script without case (or without ASCII word shapes) is one word — the
    /// boundary rule must never chop a name it cannot analyse.
    func testNonASCIINamesAreNotSplit() {
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "変数"), ["変"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "имя"), ["и"])
        XCTAssertEqual(FuzzyMatch.wordBoundaryInitials(of: "número"), ["n"])
    }

    // MARK: - Matching

    /// The headline case: three different spellings of the same intent all
    /// reach `ArrayBuffer`.
    func testCamelCaseQueriesReachTheirCandidate() {
        for query in ["aBu", "arrBuf", "buf", "ab", "arrayb"] {
            XCTAssertNotNil(
                FuzzyMatch.quality(of: "ArrayBuffer", matching: query),
                "\(query) should match ArrayBuffer"
            )
        }
    }

    /// The documented limit: the first typed character must land on a word
    /// boundary of the candidate, even though `rray` *is* a subsequence of
    /// `ArrayBuffer`.
    func testAQueryStartingOffAWordBoundaryDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.quality(of: "ArrayBuffer", matching: "rray"))
        XCTAssertNil(FuzzyMatch.quality(of: "ArrayBuffer", matching: "rb"))
        XCTAssertFalse(FuzzyMatch.matches("ArrayBuffer", query: "rray"))
        XCTAssertTrue(FuzzyMatch.matches("ArrayBuffer", query: "buf"))
    }

    func testANonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.quality(of: "ArrayBuffer", matching: "abz"))
        XCTAssertNil(FuzzyMatch.quality(of: "ArrayBuffer", matching: "arrayBufferX"))
        XCTAssertNil(FuzzyMatch.quality(of: "ArrayBuffer", matching: ""))
        XCTAssertNil(FuzzyMatch.quality(of: "", matching: "a"))
    }

    // MARK: - Quality ordering

    func testExactCasePrefixBeatsCaseInsensitivePrefixBeatsFuzzy() throws {
        let exact = try XCTUnwrap(FuzzyMatch.quality(of: "arrayBuffer", matching: "arr"))
        let insensitive = try XCTUnwrap(FuzzyMatch.quality(of: "ArrayBuffer", matching: "arr"))
        let fuzzy = try XCTUnwrap(FuzzyMatch.quality(of: "aXrr", matching: "arr"))

        XCTAssertEqual(exact.tier, FuzzyMatch.Quality.caseSensitivePrefixTier)
        XCTAssertEqual(insensitive.tier, FuzzyMatch.Quality.caseInsensitivePrefixTier)
        XCTAssertEqual(fuzzy.tier, FuzzyMatch.Quality.fuzzyTier)
        XCTAssertLessThan(exact, insensitive)
        XCTAssertLessThan(insensitive, fuzzy)
    }

    /// The key that keeps the pre-existing ranking bit-for-bit: two prefix
    /// matches of the same case tier are *equal*, whatever their length or
    /// shape, so the provider's later tie-breaks decide exactly as they did
    /// before fuzzy matching existed.
    func testPrefixMatchesCarryAConstantKey() throws {
        let short = try XCTUnwrap(FuzzyMatch.quality(of: "arr", matching: "arr"))
        let long = try XCTUnwrap(FuzzyMatch.quality(of: "arrayBufferSlice", matching: "arr"))
        XCTAssertEqual(short, long)
        XCTAssertTrue(short.isPrefixMatch)
        XCTAssertEqual(short.offBoundary, 0)
        XCTAssertEqual(short.span, 0)
        XCTAssertEqual(short.start, 0)
    }

    func testBoundaryHittingMatchesBeatScatteredOnes() throws {
        let boundary = try XCTUnwrap(FuzzyMatch.quality(of: "ArrayBuffer", matching: "ab"))
        let scattered = try XCTUnwrap(FuzzyMatch.quality(of: "alphabet", matching: "ab"))
        XCTAssertEqual(boundary.offBoundary, 0)
        XCTAssertEqual(scattered.offBoundary, 1)
        XCTAssertLessThan(boundary, scattered)
        XCTAssertFalse(boundary.isPrefixMatch)
    }

    func testTighterMatchesBeatLooserOnes() throws {
        let tight = try XCTUnwrap(FuzzyMatch.quality(of: "axb", matching: "ab"))
        let loose = try XCTUnwrap(FuzzyMatch.quality(of: "axxb", matching: "ab"))
        XCTAssertEqual(tight.offBoundary, loose.offBoundary)
        XCTAssertEqual(tight.span, 2)
        XCTAssertEqual(loose.span, 3)
        XCTAssertLessThan(tight, loose)
    }

    func testEarlierMatchesBeatLaterOnes() throws {
        let early = try XCTUnwrap(FuzzyMatch.quality(of: "zAb", matching: "ab"))
        let late = try XCTUnwrap(FuzzyMatch.quality(of: "zzzAb", matching: "ab"))
        XCTAssertEqual(early.offBoundary, late.offBoundary)
        XCTAssertEqual(early.span, late.span)
        XCTAssertEqual(early.start, 1)
        XCTAssertEqual(late.start, 3)
        XCTAssertLessThan(early, late)
    }

    /// The greedy walk prefers boundaries but must never *lose* a match by
    /// doing so: `abc` is a subsequence of `axbc_by` only if the walk backs off
    /// the underscore-boundary `b` it reached for first and retakes the
    /// leftmost one.
    func testTheBoundaryPreferringWalkFallsBackRatherThanFailing() throws {
        let quality = try XCTUnwrap(FuzzyMatch.quality(of: "axbc_by", matching: "abc"))
        XCTAssertEqual(quality.tier, FuzzyMatch.Quality.fuzzyTier)
        XCTAssertEqual(quality.start, 0)
        XCTAssertEqual(quality.span, 3)
        XCTAssertEqual(quality.offBoundary, 2)
    }
}
