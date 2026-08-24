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

    func testAPathologicalSectionNameAnswersQuicklyInsteadOfHanging() {
        // The length cap above does *not* bound the backtracking match — its cost
        // is exponential in the number of wildcards. This 24-character section
        // name against a 42-character path took ~34 s before the step budget
        // existed, on the main thread, inside the Enter and Tab key handlers. The
        // budget is what makes the bound real; a wall clock is the only honest
        // way to assert it.
        let pattern = String(repeating: "*a", count: 11) + "*b.c"
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let path = String(repeating: "a", count: 40) + ".x"
        let started = Date()
        XCTAssertFalse(matches(pattern, path))
        XCTAssertLessThan(-started.timeIntervalSinceNow, 1.0)
    }

    func testAnAlternationHeavySectionNameAnswersQuicklyInsteadOfHanging() {
        // A second pathological shape, and the one the step count alone does not
        // catch: `matchAlternation` splices each branch in front of everything
        // that follows the group, so one "step" copies up to the whole compiled
        // pattern. Charging only the step let this 1_008-character name — well
        // inside the length cap — spend ~0.6 s inside a keystroke.
        let pattern = String(repeating: "{a,aa}", count: 18) + String(repeating: "b", count: 900)
        XCTAssertLessThan(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let started = Date()
        XCTAssertFalse(matches(pattern, String(repeating: "a", count: 26)))
        XCTAssertLessThan(-started.timeIntervalSinceNow, 1.0)
    }

    func testTheBudgetBoundsAWholeResolutionRatherThanOneSection() {
        // Nothing caps how many sections a `.editorconfig` declares, so a
        // per-section budget multiplies by the section count: fifty copies of the
        // pathological name above cost fifty times the ceiling on one keystroke
        // (measured at ~30 s). One budget threaded through the file is the bound.
        let pattern = String(repeating: "{a,aa}", count: 18) + String(repeating: "b", count: 900)
        let text = String(repeating: "[\(pattern)]\nindent_size = 2\n", count: 50)
        let file = EditorConfigFile(text: text)
        XCTAssertEqual(file.sections.count, 50)
        var budget = EditorConfigGlob.maximumMatchSteps
        let started = Date()
        XCTAssertTrue(file.sections(matching: String(repeating: "a", count: 26), budget: &budget).isEmpty)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 1.0)
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

    func testANestedBraceSectionNameCompilesInsteadOfStalling() {
        // Compilation is the *other* unbounded cost, and the match budget cannot
        // see it: the compiler scans forward for each group's closing `}`, so a
        // name of nested openers is quadratic — 1_023 of them cost ~500k character
        // steps for one section, before a single path has been matched against it.
        let pattern = String(repeating: "{", count: 1023)
        XCTAssertLessThanOrEqual(pattern.count, EditorConfigGlob.maximumSectionNameLength)
        let started = Date()
        let glob = EditorConfigGlob(pattern: pattern)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 0.1)
        // Degrades exactly as an over-long name does: it answers "no" to everything.
        XCTAssertTrue(glob.exceedsCompileBudget)
        XCTAssertFalse(glob.matches(relativePath: pattern))
        XCTAssertFalse(glob.matches(relativePath: "a.txt"))
    }

    func testANestedCharacterClassSectionNameCompilesInsteadOfStalling() {
        // The same shape through the other forward scan: an unclosed `[` is read to
        // the end of the pattern before it degrades to a literal, so a run of them
        // is quadratic too.
        let pattern = String(repeating: "[", count: 1024)
        let started = Date()
        let glob = EditorConfigGlob(pattern: pattern)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 0.1)
        XCTAssertTrue(glob.exceedsCompileBudget)
        XCTAssertFalse(glob.matches(relativePath: "a.txt"))
    }

    func testAWholeFileOfPathologicalSectionNamesParsesInsideAKeystroke() {
        // The budget is per section, so what a whole file costs is (sections ×
        // ceiling) — and the 1 MB read cap holds a file of 1_024-character section
        // names to about a thousand of them. Un-budgeted this measured ~0.9 s of
        // main-thread work per resolution, repaid on every cache invalidation.
        let pattern = String(repeating: "{", count: 1023)
        let text = String(repeating: "[\(pattern)]\nindent_size = 2\n", count: 900)
        let started = Date()
        let file = EditorConfigFile(text: text)
        XCTAssertEqual(file.sections.count, 900)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 1.0)
        var budget = EditorConfigGlob.maximumMatchSteps
        XCTAssertTrue(file.sections(matching: "a.txt", budget: &budget).isEmpty)
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
