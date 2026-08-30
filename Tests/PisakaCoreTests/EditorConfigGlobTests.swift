import XCTest
@testable import PisakaCore

/// Tests for EditorConfig's own glob dialect, one construct at a time.
///
/// The cases mirror the official EditorConfig core test suite's glob file — its
/// *contents*, not its files: an actual `.editorconfig` committed under `Tests/`
/// would apply to this repository in every editor and every tool that reads the
/// format, so each case is spelled inline and named after the case it mirrors.
final class EditorConfigGlobTests: XCTestCase {

    // MARK: - Helpers

    private func matches(_ pattern: String, _ path: String) -> Bool {
        EditorConfigGlob(pattern: pattern).matches(relativePath: path)
    }

    // MARK: - Anchoring: "no slash ⇒ any depth" vs. "slash ⇒ anchored"

    func testPatternWithoutSlashMatchesAtAnyDepth() {
        XCTAssertFalse(EditorConfigGlob(pattern: "*.c").anchored)
        XCTAssertTrue(matches("*.c", "a.c"))
        XCTAssertTrue(matches("*.c", "sub/a.c"))
        XCTAssertTrue(matches("*.c", "deep/sub/a.c"))
    }

    func testLeadingSlashAnchorsToTheConfigsOwnDirectory() {
        XCTAssertTrue(EditorConfigGlob(pattern: "/*.c").anchored)
        XCTAssertTrue(matches("/*.c", "a.c"))
        XCTAssertFalse(matches("/*.c", "sub/a.c"))
    }

    func testInnerSlashAnchorsWithoutALeadingSlash() {
        XCTAssertTrue(EditorConfigGlob(pattern: "sub/*.c").anchored)
        XCTAssertTrue(matches("sub/*.c", "sub/a.c"))
        XCTAssertFalse(matches("sub/*.c", "a.c"))
        XCTAssertFalse(matches("sub/*.c", "deep/sub/a.c"))
    }

    func testEscapedSlashDoesNotAnchor() {
        XCTAssertFalse(EditorConfigGlob(pattern: "a\\/b").anchored)
        // Behavior, not just the flag: the escape makes the `/` an ordinary
        // literal, so the pattern still matches at any depth and the escape is
        // not left in the token stream as a backslash of its own.
        XCTAssertTrue(matches("a\\/b", "a/b"))
        XCTAssertTrue(matches("a\\/b", "x/a/b"))
        XCTAssertFalse(matches("a\\/b", "ab"))
    }

    // MARK: - Star

    func testStarMatchesAnyRunWithinOneComponent() {
        XCTAssertTrue(matches("a*e.c", "ace.c"))
        XCTAssertTrue(matches("a*e.c", "abcde.c"))
        XCTAssertFalse(matches("*.c", "a.cpp"))
    }

    func testStarDoesNotMatchOverASlash() {
        XCTAssertFalse(matches("/a*e.c", "a/e.c"))
        XCTAssertFalse(matches("/sub/*.c", "sub/deep/a.c"))
    }

    func testStarMatchesTheEmptyRun() {
        XCTAssertTrue(matches("/a*.c", "a.c"))
    }

    // MARK: - Double star

    func testDoubleStarMatchesOverSlashes() {
        XCTAssertTrue(matches("a**z.c", "az.c"))
        XCTAssertTrue(matches("a**z.c", "a/z.c"))
        XCTAssertTrue(matches("a**z.c", "a/b/c/z.c"))
    }

    func testDoubleStarIsNotBoundToWholePathComponents() {
        // Unlike gitignore's `**`, which is only meaningful as a whole
        // component, EditorConfig's may stand for part of one.
        XCTAssertTrue(matches("/b/**z.c", "b/deep/subz.c"))
    }

    func testDoubleStarBetweenSlashesSpansDirectories() {
        XCTAssertTrue(matches("b/**/z.c", "b/x/z.c"))
        XCTAssertTrue(matches("b/**/z.c", "b/x/y/z.c"))
        XCTAssertFalse(matches("b/**/z.c", "c/x/z.c"))
    }

    func testDoubleStarBetweenSlashesAlsoStandsForZeroDirectories() {
        // The reference core translates the whole `/**/` sequence to
        // `(\/|\/.*\/)`, so the two commonest section names in the wild reach
        // the level the author meant: `[src/**/*.ts]` governs `src/index.ts` and
        // `[**/*.md]` governs a top-level `README.md`.
        XCTAssertTrue(matches("b/**/z.c", "b/z.c"))
        XCTAssertTrue(matches("src/**/*.ts", "src/index.ts"))
        XCTAssertTrue(matches("**/*.md", "README.md"))
        XCTAssertTrue(matches("/**/foo", "foo"))
        // Only where the pattern really spells `/**/`: a `**` glued to the end of
        // a component still needs the separator that follows it.
        XCTAssertFalse(matches("a**/z.c", "az.c"))
        XCTAssertFalse(matches("b/**/z.c", "b/z.cc"))
    }

    // MARK: - Question mark

    func testQuestionMarkMatchesExactlyOneCharacter() {
        XCTAssertTrue(matches("/?.c", "a.c"))
        XCTAssertFalse(matches("/?.c", "ab.c"))
        XCTAssertFalse(matches("/?.c", ".c"))
    }

    func testQuestionMarkDoesNotMatchASlash() {
        // The documented deliberate choice where the reference cores disagree.
        XCTAssertFalse(matches("/a?c.txt", "a/c.txt"))
    }

    // MARK: - Character classes

    func testCharacterClassMatchesOneListedCharacter() {
        XCTAssertTrue(matches("/[abc].c", "a.c"))
        XCTAssertTrue(matches("/[abc].c", "c.c"))
        XCTAssertFalse(matches("/[abc].c", "d.c"))
    }

    func testCharacterClassRange() {
        XCTAssertTrue(matches("/[a-z].c", "q.c"))
        XCTAssertFalse(matches("/[a-z].c", "Q.c"))
    }

    func testNegatedCharacterClass() {
        XCTAssertTrue(matches("/[!abc].c", "d.c"))
        XCTAssertFalse(matches("/[!abc].c", "a.c"))
        XCTAssertTrue(matches("/[^abc].c", "d.c"))
        XCTAssertFalse(matches("/[^abc].c", "b.c"))
    }

    func testUnclosedBracketIsALiteral() {
        XCTAssertTrue(matches("/[ab.c", "[ab.c"))
        XCTAssertFalse(matches("/[ab.c", "a.c"))
    }

    // MARK: - Braces: alternation

    func testBraceAlternation() {
        XCTAssertTrue(matches("*.{c,cpp}", "a.c"))
        XCTAssertTrue(matches("*.{c,cpp}", "a.cpp"))
        XCTAssertFalse(matches("*.{c,cpp}", "a.h"))
    }

    func testNestedBraceAlternation() {
        XCTAssertTrue(matches("{a,{b,c}}.txt", "a.txt"))
        XCTAssertTrue(matches("{a,{b,c}}.txt", "b.txt"))
        XCTAssertTrue(matches("{a,{b,c}}.txt", "c.txt"))
        XCTAssertFalse(matches("{a,{b,c}}.txt", "d.txt"))
    }

    func testEmptyAlternativeMatchesNothingAtAll() {
        XCTAssertTrue(matches("{,b}.txt", ".txt"))
        XCTAssertTrue(matches("{,b}.txt", "b.txt"))
        XCTAssertFalse(matches("{,b}.txt", "c.txt"))
    }

    func testAlternativeThatWouldStrandTheRestFallsThroughToTheNext() {
        // `ab` must be tried after `a` fails to leave `b.txt` matchable.
        XCTAssertTrue(matches("{a,ab}.txt", "ab.txt"))
    }

    // MARK: - Braces: literal groups

    func testBraceGroupWithoutCommaOrRangeIsLiteralText() {
        XCTAssertTrue(matches("{single}.b", "{single}.b"))
        XCTAssertFalse(matches("{single}.b", "single.b"))
    }

    func testEmptyBraceGroupIsLiteralText() {
        XCTAssertTrue(matches("{}.b", "{}.b"))
    }

    func testUnmatchedOpeningBraceIsLiteralText() {
        XCTAssertTrue(matches("a{b,c", "a{b,c"))
    }

    func testNonIntegerRangeGroupIsLiteralText() {
        XCTAssertTrue(matches("{a..b}.txt", "{a..b}.txt"))
        XCTAssertFalse(matches("{a..b}.txt", "a.txt"))
    }

    // MARK: - Braces: numeric ranges

    func testNumericRangeMatchesEveryIntegerInIt() {
        XCTAssertTrue(matches("{1..3}.txt", "1.txt"))
        XCTAssertTrue(matches("{1..3}.txt", "2.txt"))
        XCTAssertTrue(matches("{1..3}.txt", "3.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "4.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "10.txt"))
    }

    func testNumericRangeMatchesMultiDigitIntegers() {
        XCTAssertTrue(matches("{1..100}.txt", "42.txt"))
        XCTAssertFalse(matches("{1..100}.txt", "101.txt"))
    }

    func testNumericRangeAcceptsNegativeBoundsAndAMatchedMinus() {
        XCTAssertTrue(matches("{-2..2}.txt", "-1.txt"))
        XCTAssertTrue(matches("{-2..2}.txt", "0.txt"))
        XCTAssertTrue(matches("{-2..2}.txt", "-2.txt"))
        XCTAssertFalse(matches("{-2..2}.txt", "-3.txt"))
    }

    func testNumericRangeRefusesANonInteger() {
        XCTAssertFalse(matches("{1..3}.txt", "a.txt"))
        XCTAssertFalse(matches("{1..3}.txt", ".txt"))
    }

    func testNumericRangeBacktracksOntoAShorterRun() {
        XCTAssertTrue(matches("{1..2}0.txt", "10.txt"))
    }

    // MARK: - Escapes

    func testBackslashEscapesTheNextCharacter() {
        XCTAssertTrue(matches("\\*.txt", "*.txt"))
        XCTAssertFalse(matches("\\*.txt", "a.txt"))
        XCTAssertTrue(matches("\\{a\\}.txt", "{a}.txt"))
        XCTAssertTrue(matches("\\?.txt", "?.txt"))
        XCTAssertFalse(matches("\\?.txt", "a.txt"))
    }

    func testEscapedCommaInsideAGroupIsALiteral() {
        XCTAssertTrue(matches("{a\\,b}.txt", "{a,b}.txt"))
    }

    // MARK: - The section-name length cap

    func testSectionNameAtTheLimitIsHonored() {
        let name = String(repeating: "a", count: 1020) + ".txt"
        XCTAssertEqual(name.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: name)
        XCTAssertFalse(glob.exceedsLengthLimit)
        XCTAssertTrue(glob.matches(relativePath: name))
    }

    func testSectionNameBeyondTheLimitNeverMatches() {
        let name = String(repeating: "a", count: 1021) + ".txt"
        XCTAssertGreaterThan(name.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: name)
        XCTAssertTrue(glob.exceedsLengthLimit)
        XCTAssertFalse(glob.matches(relativePath: name))
    }

    // MARK: - The match budget
    //
    // Every case below is pathological in exactly one way, and each asserts two
    // numbers rather than a wall clock: the ceiling is *spent*, and the search
    // entered no more attempts than that ceiling could pay for.
    //
    // The second half is the load-bearing one, and exhaustion alone cannot stand
    // in for it. Every one of these inputs also backtracks through *charged*
    // states, so it drives the budget to zero whether or not the quadratic work
    // in question is charged: restoring the numeric-range regression leaves the
    // exhaustion assertion green while the pair takes 14 s, and the empty-branch
    // one leaves it green at 6.6 s. What tells the two apart is the ratio
    // between work done and ceiling spent — every attempt is charged at least
    // one step, so a correctly charged search cannot enter more attempts than
    // its starting budget, while an uncharged one runs the ceiling many times
    // over. See `EditorConfigGlob.matchAttempts(relativePath:)`. The measured
    // pre-fix numbers stay in each comment as the evidence for why the input is
    // pathological in the first place.

    /// Runs the match against a budget *this suite* owns, answering all three
    /// parts: what the glob said, what was left of the ceiling, and how many
    /// attempts the search entered. The pathological cases assert on the last
    /// two, neither of which a `matches(_:_:)` owning its own budget internally
    /// can report.
    private func matchSpendingBudget(
        _ pattern: String,
        _ path: String
    ) -> (answer: Bool, remaining: Int, attempts: Int) {
        let glob = EditorConfigGlob(pattern: pattern)
        var budget = EditorConfigGlob.maximumMatchSteps
        let answer = glob.matches(relativePath: path, budget: &budget)
        return (answer, budget, glob.matchAttempts(relativePath: path))
    }

    /// The invariant every pathological case below shares: the ceiling is spent,
    /// and the search entered no more attempts than the ceiling could pay for.
    private func assertBoundedByItsCeiling(
        _ result: (answer: Bool, remaining: Int, attempts: Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(result.remaining, 0, "the ceiling was not spent", file: file, line: line)
        XCTAssertLessThanOrEqual(
            result.attempts, EditorConfigGlob.maximumMatchSteps,
            "the search entered \(result.attempts) attempts against a ceiling of "
                + "\(EditorConfigGlob.maximumMatchSteps) — that is work the budget is not charged for",
            file: file, line: line
        )
    }

    func testAPathologicalSectionNameSpendsItsBudgetAndAnswers() {
        // The length cap above does *not* bound the backtracking match — its cost
        // is exponential in the number of wildcards. This 24-character section
        // name against a 42-character path took ~34 s before the step budget
        // existed, on the main thread, inside the Enter and Tab key handlers.
        let pattern = String(repeating: "*a", count: 11) + "*b.c"
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let path = String(repeating: "a", count: 40) + ".x"
        let result = matchSpendingBudget(pattern, path)
        XCTAssertFalse(result.answer)
        assertBoundedByItsCeiling(result)
    }

    func testAnAlternationHeavySectionNameSpendsItsBudgetAndAnswers() {
        // A second pathological shape, and the one the step count alone does not
        // catch: `matchAlternation` splices each branch in front of everything
        // that follows the group, so one "step" copies up to the whole compiled
        // pattern. Charging only the step let this 1_008-character name — well
        // inside the length cap — spend ~0.6 s inside a keystroke. Charging the
        // splice is what the attempt count below reads: uncharged, the same
        // search still drives the ceiling to zero through the wildcards around
        // it, but enters far more attempts than the ceiling could have paid for.
        let pattern = String(repeating: "{a,aa}", count: 18) + String(repeating: "b", count: 900)
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let result = matchSpendingBudget(pattern, String(repeating: "a", count: 26))
        XCTAssertFalse(result.answer)
        assertBoundedByItsCeiling(result)
    }

    func testASectionNameEndingInEmptyAlternationBranchesSpendsItsBudget() {
        // The third pathological shape, and the one a length-derived charge alone
        // misses: an empty branch spliced in front of an empty remainder copies
        // nothing, so `branch.count + rest.count` charged zero and a trailing run
        // of `,`s bought hundreds of free iterations at every backtracking state
        // the budget did allow. Measured at ~0.5 s inside a keystroke before the
        // per-attempt step, and it scales with both the comma count and the path.
        // Those free iterations are exactly "quadratic and uncharged": restore
        // them and this pair takes 6.6 s while *still* spending the ceiling on
        // the wildcards around it — so it is the attempt count, not the
        // exhaustion, that fails here.
        let pattern = String(repeating: "*a", count: 10)
            + "{" + String(repeating: ",", count: 460) + "}"
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let path = String(repeating: "a", count: 60) + "z"
        let result = matchSpendingBudget(pattern, path)
        XCTAssertFalse(result.answer)
        assertBoundedByItsCeiling(result)
    }

    func testANumericRangeAgainstALongDigitRunSpendsItsBudget() {
        // The fourth: `matchNumericRange` tries every candidate length longest
        // first, and a candidate whose value falls outside the bounds never
        // reaches the recursive `match` that charges. Uncharged, the ceiling is
        // multiplied by the path's digit-run length — this pair measured 14 s,
        // and it *still* spends the ceiling on the wildcards around it, so only
        // the attempt count below separates the two.
        let pattern = String(repeating: "*1", count: 10) + "{0..0}"
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let path = String(repeating: "1", count: 200) + "zzz"
        let result = matchSpendingBudget(pattern, path)
        XCTAssertFalse(result.answer)
        assertBoundedByItsCeiling(result)
    }

    func testTheBudgetBoundsAWholeResolutionRatherThanOneSection() {
        // Nothing caps how many sections a `.editorconfig` declares, so a
        // per-section budget multiplies by the section count: fifty copies of the
        // pathological name above cost fifty times the ceiling on one keystroke
        // (measured at ~30 s). One budget threaded through the file is the bound,
        // and the assertion is that bound directly: the *file* — not each of its
        // fifty sections — spends one ceiling and the resolution still answers.
        // A per-section budget passes the exhaustion check just as happily but
        // would leave `budget` at the ceiling here, since each section would have
        // spent a private copy instead.
        let pattern = String(repeating: "{a,aa}", count: 18) + String(repeating: "b", count: 900)
        let text = String(repeating: "[\(pattern)]\nindent_size = 2\n", count: 50)
        let file = EditorConfigFile(text: text)
        XCTAssertEqual(file.sections.count, 50)
        var budget = EditorConfigGlob.maximumMatchSteps
        XCTAssertTrue(file.sections(matching: String(repeating: "a", count: 26), budget: &budget).isEmpty)
        XCTAssertLessThanOrEqual(budget, 0)
    }

    func testAHonestlyLargeConfigStaysFarInsideTheSharedBudget() {
        // The other side of the shared budget: sections must not starve each other
        // in any config a person would write. Two hundred ordinary sections — an
        // order of magnitude past the largest real one — spend a small fraction of
        // the ceiling and every matching section still answers.
        let names = [
            "*", "*.{js,jsx,ts,tsx}", "**/*.md", "src/**/*.swift", "Makefile",
            "{package,bower}.json", "lib/**.js", "[a-z]*.py", "docs/**/*.{md,txt}", "*.min.*",
        ]
        let text = (0..<200).map { "[\(names[$0 % names.count])]\nindent_size = 2\n" }.joined()
        let file = EditorConfigFile(text: text)
        var budget = EditorConfigGlob.maximumMatchSteps
        let matching = file.sections(matching: "src/deep/nested/path/Component.tsx", budget: &budget)
        XCTAssertEqual(matching.count, 40)
        XCTAssertGreaterThan(budget, EditorConfigGlob.maximumMatchSteps / 2)
    }

    func testAnOrdinaryPatternIsNowhereNearTheBudget() {
        // The ceiling must not cost a real section name its answer: a deep path
        // under the commonest shapes still resolves, and resolves as a match.
        let deep = (0..<12).map { "very-long-directory-name-segment-\($0)" }.joined(separator: "/")
        XCTAssertTrue(matches("**/*.{js,jsx,ts,tsx}", deep + "/SomeReallyLongFileName.tsx"))
        XCTAssertTrue(matches("**/*.md", deep + "/README.md"))
    }

    // MARK: - The compile budget

    func testANestedBraceSectionNameSpendsTheCompileBudget() {
        // Compilation is the *other* unbounded cost, and the match budget cannot
        // see it: the compiler scans forward for each group's closing `}`, so a
        // name of nested openers is quadratic — 1_023 of them cost ~500k character
        // steps for one section, before a single path has been matched against it.
        //
        // `exceedsCompileBudget` is the assertion because it is what bounds that
        // scan: the quadratic is still quadratic, it is now *charged*, and the
        // charge is what stops it. Un-charge it — the regression this input was
        // found by — and compilation runs the full 500k steps while the flag
        // stays `false`, which fails here on any machine at any speed.
        let pattern = String(repeating: "{", count: 1023)
        XCTAssertLessThanOrEqual(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: pattern)
        XCTAssertTrue(glob.exceedsCompileBudget)
        // Degrades exactly as an over-long name does: it answers "no" to everything.
        XCTAssertFalse(glob.matches(relativePath: pattern))
        XCTAssertFalse(glob.matches(relativePath: "a.txt"))
    }

    func testANestedCharacterClassSectionNameSpendsTheCompileBudget() {
        // The same shape through the other forward scan: an unclosed `[` is read to
        // the end of the pattern before it degrades to a literal, so a run of them
        // is quadratic too — and, as above, the reading is that the scan is
        // charged rather than that it happened to finish fast enough today.
        let pattern = String(repeating: "[", count: 1024)
        let glob = EditorConfigGlob(pattern: pattern)
        XCTAssertTrue(glob.exceedsCompileBudget)
        XCTAssertFalse(glob.matches(relativePath: "a.txt"))
    }

    func testAWholeFileOfPathologicalSectionNamesChargesEverySection() {
        // The compile budget is per section, so what a whole file costs is
        // (sections × ceiling) — and the 1 MB read cap holds a file of
        // 1_024-character section names to about a thousand of them. Un-budgeted
        // this measured ~0.9 s of main-thread work per resolution, repaid on every
        // cache invalidation.
        //
        // So the assertion is the multiplicand: *every* section degraded through
        // the compile budget, which is what makes the file's total exactly
        // (sections × ceiling) rather than (sections × quadratic). One section
        // escaping the charge is one unbounded scan per resolution, and that is
        // the regression — visible here as a `false` flag, with no clock read.
        let pattern = String(repeating: "{", count: 1023)
        let text = String(repeating: "[\(pattern)]\nindent_size = 2\n", count: 900)
        let file = EditorConfigFile(text: text)
        XCTAssertEqual(file.sections.count, 900)
        XCTAssertTrue(file.sections.allSatisfy { $0.glob.exceedsCompileBudget })
        var budget = EditorConfigGlob.maximumMatchSteps
        XCTAssertTrue(file.sections(matching: "a.txt", budget: &budget).isEmpty)
        // And a file of names that never compiled costs the match budget nothing.
        XCTAssertEqual(budget, EditorConfigGlob.maximumMatchSteps)
    }

    func testAnHonestSectionNameIsNowhereNearTheCompileBudget() {
        // The other side of it: a full-length name carrying many *sibling* groups
        // — none of which scans past its own `}` — must still compile and match.
        // Charging each scan its worst case rather than its real cost would refuse
        // exactly this pattern.
        let pattern = String(repeating: "{a,b}", count: 200) + "*.txt"
        XCTAssertLessThanOrEqual(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: pattern)
        XCTAssertFalse(glob.exceedsCompileBudget)
        XCTAssertTrue(glob.matches(relativePath: String(repeating: "a", count: 200) + "name.txt"))
    }

    // MARK: - Identity

    func testEqualityIsTheSourceSpelling() {
        XCTAssertEqual(EditorConfigGlob(pattern: "*.c"), EditorConfigGlob(pattern: "*.c"))
        XCTAssertNotEqual(EditorConfigGlob(pattern: "*.c"), EditorConfigGlob(pattern: "*.h"))
    }
}
