import XCTest
@testable import PisakaCore

/// Tests for the pure `.gitignore` pattern matcher backing the project-wide
/// "Find in Files" traversal. Foundation-only, one test per gitignore(5) grammar
/// rule, plus the single-component `Glob` the file mask reuses.
final class GitignoreMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func decision(
        _ contents: String,
        _ path: String,
        isDirectory: Bool = false
    ) -> GitignoreRules.Decision? {
        GitignoreRules(fileContents: contents).decision(relativePath: path, isDirectory: isDirectory)
    }

    // MARK: - Line parsing: blanks and comments

    func testBlankLinesAndCommentsAreDropped() {
        let rules = GitignoreRules(fileContents: "\n# a comment\n\nbuild\n\n*.log\n")
        XCTAssertEqual(rules.patterns.count, 2)
        XCTAssertEqual(rules.patterns.map(\.components), [["build"], ["*.log"]])
    }

    func testCommentLineIsNotAPattern() {
        XCTAssertNil(decision("#build\n", "build"))
    }

    func testEscapedHashIsALiteralPattern() {
        XCTAssertEqual(decision("\\#build\n", "#build"), .ignored)
        XCTAssertNil(decision("\\#build\n", "build"))
    }

    func testEscapedBangIsALiteralNotANegation() {
        // "\!important" names a file literally called "!important" and does not
        // re-include anything.
        XCTAssertEqual(GitignoreRules(fileContents: "\\!important\n").patterns.first?.negated, false)
        XCTAssertEqual(decision("\\!important\n", "!important"), .ignored)
        XCTAssertNil(decision("\\!important\n", "important"))
    }

    // MARK: - Trailing whitespace

    func testTrailingSpacesAreStrippedUnlessEscaped() {
        XCTAssertEqual(decision("build   \n", "build", isDirectory: true), .ignored)
        // The escaped space is part of the name.
        XCTAssertEqual(decision("build\\ \n", "build "), .ignored)
        XCTAssertNil(decision("build\\ \n", "build"))
    }

    func testWhitespaceOnlyLineIsDropped() {
        XCTAssertTrue(GitignoreRules(fileContents: "   \n\n").patterns.isEmpty)
    }

    // MARK: - Negation

    func testNegationReIncludesAPreviouslyExcludedFile() {
        let contents = """
            *.log
            !keep.log
            """
        XCTAssertEqual(decision(contents, "debug.log"), .ignored)
        XCTAssertEqual(decision(contents, "keep.log"), .included)
    }

    func testLastMatchWinsWithinOneFile() {
        // Exclusion after a negation wins again — order decides, not polarity.
        let contents = """
            !keep.log
            *.log
            """
        XCTAssertEqual(decision(contents, "keep.log"), .ignored)
    }

    func testNoMatchingPatternYieldsNilDecision() {
        XCTAssertNil(decision("*.log\n", "main.swift"))
    }

    // MARK: - Anchoring

    func testPatternWithoutSlashMatchesAtAnyDepth() {
        let contents = "build\n"
        XCTAssertEqual(decision(contents, "build"), .ignored)
        XCTAssertEqual(decision(contents, "a/build"), .ignored)
        XCTAssertEqual(decision(contents, "a/b/build"), .ignored)
    }

    func testPatternWithAnInteriorSlashIsAnchoredToTheRules_Directory() {
        let contents = "build/foo\n"
        XCTAssertEqual(decision(contents, "build/foo"), .ignored)
        XCTAssertNil(decision(contents, "a/build/foo"))
    }

    func testLeadingSlashAnchorsWithoutBecomingAPathComponent() {
        let contents = "/build\n"
        XCTAssertEqual(decision(contents, "build"), .ignored)
        XCTAssertNil(decision(contents, "a/build"))
    }

    func testTrailingSlashDoesNotAnchor() {
        // The trailing "/" is the directory marker, not an interior separator, so
        // "build/" still matches at any depth.
        let contents = "build/\n"
        XCTAssertEqual(decision(contents, "a/b/build", isDirectory: true), .ignored)
    }

    // MARK: - Directory-only patterns

    func testTrailingSlashMatchesDirectoriesOnly() {
        let contents = "build/\n"
        XCTAssertEqual(decision(contents, "build", isDirectory: true), .ignored)
        XCTAssertNil(decision(contents, "build", isDirectory: false))
    }

    func testPatternWithoutTrailingSlashMatchesBothKinds() {
        let contents = "build\n"
        XCTAssertEqual(decision(contents, "build", isDirectory: true), .ignored)
        XCTAssertEqual(decision(contents, "build", isDirectory: false), .ignored)
    }

    // MARK: - Wildcards

    func testStarDoesNotCrossASlash() {
        XCTAssertNil(decision("a*c\n", "a/b/c"))
        XCTAssertEqual(decision("a*c\n", "abc"), .ignored)
    }

    func testStarMatchesWithinOneComponentAtAnyDepth() {
        let contents = "*.log\n"
        XCTAssertEqual(decision(contents, "debug.log"), .ignored)
        XCTAssertEqual(decision(contents, "a/b/debug.log"), .ignored)
        XCTAssertNil(decision(contents, "debug.txt"))
    }

    func testStarMatchesADotFile() {
        // gitignore has no "leading period" rule (unlike shell globbing).
        XCTAssertEqual(decision("*\n", ".env"), .ignored)
    }

    func testLeadingDoubleStarMatchesAtAnyDepth() {
        let contents = "**/foo\n"
        XCTAssertEqual(decision(contents, "foo"), .ignored)
        XCTAssertEqual(decision(contents, "a/foo"), .ignored)
        XCTAssertEqual(decision(contents, "a/b/foo"), .ignored)
        XCTAssertNil(decision(contents, "foo/bar"))
    }

    func testTrailingDoubleStarMatchesEverythingInsideButNotTheDirectoryItself() {
        let contents = "abc/**\n"
        XCTAssertNil(decision(contents, "abc", isDirectory: true))
        XCTAssertEqual(decision(contents, "abc/x"), .ignored)
        XCTAssertEqual(decision(contents, "abc/x/y"), .ignored)
        XCTAssertNil(decision(contents, "other/x"))
    }

    func testMiddleDoubleStarMatchesZeroOrMoreDirectories() {
        let contents = "a/**/b\n"
        XCTAssertEqual(decision(contents, "a/b"), .ignored)
        XCTAssertEqual(decision(contents, "a/x/b"), .ignored)
        XCTAssertEqual(decision(contents, "a/x/y/b"), .ignored)
        XCTAssertNil(decision(contents, "a/x/y"))
    }

    func testQuestionMarkMatchesExactlyOneCharacter() {
        let contents = "file?.txt\n"
        XCTAssertEqual(decision(contents, "file1.txt"), .ignored)
        XCTAssertNil(decision(contents, "file.txt"))
        XCTAssertNil(decision(contents, "file12.txt"))
        // ? does not cross a separator either.
        XCTAssertNil(decision("a?c\n", "a/c"))
    }

    func testCharacterClassRangeAndNegatedRange() {
        XCTAssertEqual(decision("file[0-9].txt\n", "file7.txt"), .ignored)
        XCTAssertNil(decision("file[0-9].txt\n", "filea.txt"))
        XCTAssertEqual(decision("file[!0-9].txt\n", "filea.txt"), .ignored)
        XCTAssertNil(decision("file[!0-9].txt\n", "file7.txt"))
        // "^" is accepted as the negation marker too.
        XCTAssertEqual(decision("file[^0-9].txt\n", "filea.txt"), .ignored)
        XCTAssertEqual(decision("[a-z]*\n", "readme"), .ignored)
        XCTAssertNil(decision("[a-z]*\n", "README"))
    }

    func testEscapedWildcardIsALiteral() {
        XCTAssertEqual(decision("a\\*b\n", "a*b"), .ignored)
        XCTAssertNil(decision("a\\*b\n", "axb"))
    }

    // MARK: - File format

    func testCRLFContentsParseWithoutStrayCarriageReturns() {
        let contents = "build\r\n# comment\r\n*.log\r\n"
        XCTAssertEqual(decision(contents, "build"), .ignored)
        XCTAssertEqual(decision(contents, "x.log"), .ignored)
        XCTAssertEqual(GitignoreRules(fileContents: contents).patterns.count, 2)
    }

    func testEmptyRelativePathHasNoDecision() {
        XCTAssertNil(decision("*\n", ""))
        XCTAssertNil(decision("*\n", "/"))
    }

    // MARK: - Performance

    func testPathologicalGlobCompletesQuickly() {
        // A naive backtracking matcher goes exponential here; the DP walk is
        // O(name × pattern).
        let name = String(repeating: "a", count: 200)
        let started = Date()
        XCTAssertFalse(Glob.matches(name: name, pattern: "a*a*a*a*a*a*b"))
        XCTAssertNil(decision("a*a*a*a*a*a*b\n", name))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MARK: - Glob (single component, reused by the file mask)

    func testGlobBasics() {
        XCTAssertTrue(Glob.matches(name: "main.ts", pattern: "*.ts"))
        XCTAssertFalse(Glob.matches(name: "main.tsx", pattern: "*.ts"))
        XCTAssertTrue(Glob.matches(name: "main.tsx", pattern: "*.ts?"))
        XCTAssertTrue(Glob.matches(name: "anything", pattern: "*"))
        XCTAssertTrue(Glob.matches(name: "", pattern: "*"))
        XCTAssertFalse(Glob.matches(name: "", pattern: "?"))
        XCTAssertTrue(Glob.matches(name: "exact", pattern: "exact"))
        XCTAssertFalse(Glob.matches(name: "exact", pattern: "exac"))
    }

    func testGlobUnterminatedClassIsALiteralBracket() {
        XCTAssertTrue(Glob.matches(name: "[abc", pattern: "[abc"))
    }

    func testGlobClassWithLiteralClosingBracketFirst() {
        XCTAssertTrue(Glob.matches(name: "]", pattern: "[]]"))
        XCTAssertFalse(Glob.matches(name: "a", pattern: "[]]"))
    }

    // MARK: - Parsed form

    func testParsedFormRecordsFlags() {
        let negated = GitignorePattern(line: "!build/foo/")
        XCTAssertEqual(negated?.negated, true)
        XCTAssertEqual(negated?.anchored, true)
        XCTAssertEqual(negated?.directoryOnly, true)
        XCTAssertEqual(negated?.components, ["build", "foo"])

        let plain = GitignorePattern(line: "*.log")
        XCTAssertEqual(plain?.negated, false)
        XCTAssertEqual(plain?.anchored, false)
        XCTAssertEqual(plain?.directoryOnly, false)
        XCTAssertEqual(plain?.components, ["*.log"])

        XCTAssertNil(GitignorePattern(line: "# comment"))
        XCTAssertNil(GitignorePattern(line: "   "))
        XCTAssertNil(GitignorePattern(line: "!"))
        XCTAssertNil(GitignorePattern(line: "/"))
    }

    // MARK: - Stack: nesting

    /// Builds a stack from `(relativeDirectory, contents)` pairs, outermost
    /// first — the order a traversal discovers them in.
    private func stack(_ levels: [(String, String)]) -> GitignoreStack {
        levels.reduce(GitignoreStack()) { stack, level in
            stack.appending(rules: GitignoreRules(fileContents: level.1), relativeDirectory: level.0)
        }
    }

    func testNestedGitignoreOverridesTheRootOne() {
        // Verified against git: with root "*.log" and "sub/.gitignore"
        // "!important.log", `git status -uall` lists sub/important.log as
        // untracked (not ignored) while sub/other.log stays ignored.
        let stack = stack([("", "*.log\n"), ("sub", "!important.log\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: "sub/important.log", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "sub/other.log", isDirectory: false))
        // The outer rule still governs everything outside the nested directory.
        XCTAssertTrue(stack.isExcluded(relativePath: "important.log", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "other/important.log", isDirectory: false))
    }

    func testNestedNegationReIncludesAFileExcludedByTheRoot() {
        let stack = stack([("", "build\n"), ("sub", "!build\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: "sub/build", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "build", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "other/build", isDirectory: false))
    }

    func testDeeperLevelWinsOverTheOuterOneInBothDirections() {
        // Exclusion nested under a negation is just as authoritative as the
        // reverse — depth decides, not polarity.
        let excludingInner = stack([("", "!keep.log\n*.log\n"), ("sub", "!keep.log\n")])
        XCTAssertFalse(excludingInner.isExcluded(relativePath: "sub/keep.log", isDirectory: false))
        XCTAssertTrue(excludingInner.isExcluded(relativePath: "keep.log", isDirectory: false))

        let includingInner = stack([("", "!*.log\n"), ("sub", "*.log\n")])
        XCTAssertTrue(includingInner.isExcluded(relativePath: "sub/a.log", isDirectory: false))
        XCTAssertFalse(includingInner.isExcluded(relativePath: "a.log", isDirectory: false))
    }

    func testUnmatchedDeeperLevelFallsThroughToTheOuterOne() {
        let stack = stack([("", "*.log\n"), ("sub", "*.tmp\n")])
        XCTAssertTrue(stack.isExcluded(relativePath: "sub/a.log", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "sub/a.tmp", isDirectory: false))
        XCTAssertFalse(stack.isExcluded(relativePath: "a.tmp", isDirectory: false))
    }

    // MARK: - Stack: excluded parents

    func testNegationUnderAnExcludedDirectoryDoesNotResurrectTheFile() {
        // git: "It is not possible to re-include a file if a parent directory of
        // that file is excluded." Verified — with root "logs/" and
        // "logs/.gitignore" "!keep.txt", `git status -uall` does not list
        // logs/keep.txt (git never even descends to read the nested file).
        let nested = stack([("", "logs/\n"), ("logs", "!keep.txt\n")])
        XCTAssertTrue(nested.isExcluded(relativePath: "logs/keep.txt", isDirectory: false))
        // Same rule when the negation sits in the *same* file as the exclusion.
        let sameFile = stack([("", "logs/\n!logs/keep.txt\n")])
        XCTAssertTrue(sameFile.isExcluded(relativePath: "logs/keep.txt", isDirectory: false))
        // ...and at any depth below the excluded directory.
        XCTAssertTrue(nested.isExcluded(relativePath: "logs/a/b/keep.txt", isDirectory: false))
        XCTAssertTrue(nested.isExcluded(relativePath: "logs/a", isDirectory: true))
    }

    func testExcludingOnlyTheContentsStillAllowsANegation() {
        // The counterpart: "foo/*" excludes the *entries*, not the directory, so
        // "!foo/bar" survives (git agrees — see the oracle table).
        let stack = stack([("", "foo/*\n!foo/bar\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: "foo/bar", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "foo/other", isDirectory: false))
        XCTAssertFalse(stack.isExcluded(relativePath: "foo", isDirectory: true))
    }

    func testTheExcludedDirectoryItselfIsExcluded() {
        let stack = stack([("", "logs/\n")])
        XCTAssertTrue(stack.isExcluded(relativePath: "logs", isDirectory: true))
        XCTAssertFalse(stack.isExcluded(relativePath: "logs", isDirectory: false))
    }

    // MARK: - Stack: anchoring

    func testAnchoredPatternInANestedFileIsRelativeToThatDirectory() {
        // Verified: "sub/.gitignore" holding "/foo" ignores sub/foo while
        // sub/deep/foo stays untracked.
        let stack = stack([("sub", "/foo\n")])
        XCTAssertTrue(stack.isExcluded(relativePath: "sub/foo", isDirectory: false))
        XCTAssertFalse(stack.isExcluded(relativePath: "sub/deep/foo", isDirectory: false))
        XCTAssertFalse(stack.isExcluded(relativePath: "foo", isDirectory: false))
    }

    func testAnchoredRootPatternDoesNotMatchAtDepthWhileUnanchoredDoes() {
        let anchored = stack([("", "build/foo\n")])
        XCTAssertTrue(anchored.isExcluded(relativePath: "build/foo", isDirectory: false))
        XCTAssertFalse(anchored.isExcluded(relativePath: "a/build/foo", isDirectory: false))

        let unanchored = stack([("", "foo\n")])
        XCTAssertTrue(unanchored.isExcluded(relativePath: "foo", isDirectory: false))
        XCTAssertTrue(unanchored.isExcluded(relativePath: "a/b/foo", isDirectory: false))
    }

    // MARK: - Stack: scope and degenerate input

    func testDotGitIsNotTheMatchersBusiness() {
        // The traversal excludes ".git" itself; no rule here does, so the matcher
        // reports it as any other unmatched path.
        let stack = stack([("", "*.log\nbuild/\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: ".git", isDirectory: true))
        XCTAssertFalse(stack.isExcluded(relativePath: ".git/config", isDirectory: false))
        XCTAssertFalse(stack.isExcluded(relativePath: ".gitignore", isDirectory: false))
    }

    func testEmptyStackExcludesNothing() {
        let empty = GitignoreStack()
        XCTAssertFalse(empty.isExcluded(relativePath: "anything", isDirectory: false))
        XCTAssertFalse(empty.isExcluded(relativePath: "a/b/c", isDirectory: true))
    }

    func testEmptyRulesAreNotAppended() {
        let stack = GitignoreStack()
            .appending(rules: GitignoreRules(fileContents: "\n# only comments\n"), relativeDirectory: "sub")
        XCTAssertTrue(stack.levels.isEmpty)
    }

    func testEmptyRelativePathIsNotExcluded() {
        let stack = stack([("", "*\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: "", isDirectory: true))
        XCTAssertFalse(stack.isExcluded(relativePath: "/", isDirectory: true))
    }

    func testLevelsRecordTheirDirectoryComponents() {
        let stack = stack([("", "*.log\n"), ("a/b", "*.tmp\n")])
        XCTAssertEqual(stack.levels.map(\.directory), [[], ["a", "b"]])
    }

    // MARK: - Oracle: cross-checked against `git check-ignore`

    /// Every row below is a verdict **captured from git itself**, not one
    /// reasoned out by hand.
    ///
    /// How it was captured (git 2.55.0, macOS):
    ///
    /// ```sh
    /// git init -q repo && cd repo
    /// git config core.ignorecase false   # macOS `git init` sets this true on APFS,
    ///                                    # which would make `[a-z]*` match `README`
    /// # then, per row: write the pattern text into .gitignore and ask git
    /// printf '<contents>\n' > .gitignore
    /// git check-ignore --no-index -q -- '<path>'   # exit 0 = ignored, 1 = not
    /// ```
    ///
    /// The repository holds nothing but that one `.gitignore`; `--no-index` is
    /// what lets a path be judged without the file existing, and a **trailing
    /// `/` on the path is how `check-ignore` is told the path is a directory**
    /// (without it, `build/` does not match the path `build`).
    private static let oracle: [(contents: String, path: String, ignored: Bool)] = [
        ("build", "build", true),
        ("build", "a/build", true),
        ("build", "a/b/build", true),
        ("build/foo", "build/foo", true),
        ("build/foo", "a/build/foo", false),
        ("/build", "build", true),
        ("/build", "a/build", false),
        ("build/", "build/", true),
        ("build/", "build", false),
        ("build/", "a/b/build/", true),
        ("*.log", "debug.log", true),
        ("*.log", "a/b/debug.log", true),
        ("*.log", "debug.txt", false),
        ("a*c", "a/b/c", false),
        ("a*c", "abc", true),
        ("**/foo", "foo", true),
        ("**/foo", "a/b/foo", true),
        ("abc/**", "abc/x", true),
        ("abc/**", "abc/x/y", true),
        ("a/**/b", "a/b", true),
        ("a/**/b", "a/x/y/b", true),
        ("a/**/b", "a/x/y", false),
        ("file?.txt", "file1.txt", true),
        ("file?.txt", "file12.txt", false),
        ("file[0-9].txt", "file7.txt", true),
        ("file[!0-9].txt", "filea.txt", true),
        ("file[!0-9].txt", "file7.txt", false),
        ("*", ".env", true),
        ("a\\*b", "a*b", true),
        ("a\\*b", "axb", false),
        ("\\#build", "#build", true),
        ("#build", "build", false),
        ("\\!important", "!important", true),
        ("doc/frotz/", "doc/frotz/", true),
        ("doc/frotz/", "a/doc/frotz/", false),
        ("[a-z]*", "readme", true),
        ("[a-z]*", "README", false),
        ("*.log\n!keep.log", "debug.log", true),
        ("*.log\n!keep.log", "keep.log", false),
        ("!keep.log\n*.log", "keep.log", true),
        ("logs/\n!logs/keep.log", "logs/keep.log", true),
        ("foo/*\n!foo/bar", "foo/bar", false),
        ("**", "a/b", true),
    ]

    func testMatcherAgreesWithGitCheckIgnoreOracle() {
        for row in GitignoreMatcherTests.oracle {
            let stack = GitignoreStack()
                .appending(rules: GitignoreRules(fileContents: row.contents), relativeDirectory: "")
            let excluded = stack.isExcluded(
                relativePath: row.path,
                isDirectory: row.path.hasSuffix("/")
            )
            XCTAssertEqual(
                excluded,
                row.ignored,
                "pattern \(row.contents.debugDescription) vs path \(row.path.debugDescription)"
            )
        }
    }

    /// The one row deliberately **left out** of the oracle table, recorded here
    /// so the divergence is visible rather than silently omitted.
    ///
    /// `git check-ignore --no-index -- 'abc/'` reports `abc/**` as matching the
    /// directory `abc` itself — a consequence of `check-ignore` wildmatching the
    /// pathname *with* its trailing slash, so the `**` matches the empty
    /// remainder. git's actual *traversal* does not treat `abc` as excluded, and
    /// the difference is observable:
    ///
    /// ```sh
    /// printf 'abc/**\n!abc/keep.txt\n' > .gitignore
    /// mkdir abc && touch abc/keep.txt abc/other.txt
    /// git status --porcelain -uall     # => "?? abc/keep.txt"
    /// ```
    ///
    /// The negation survives, which it could not if `abc` were an excluded
    /// parent. This matcher feeds a traversal, so it follows the traversal
    /// semantics (documented on `GitignorePattern`: a trailing `**` matches one
    /// or more components) — and that is exactly what keeps the negation alive.
    func testTrailingDoubleStarLeavesTheDirectoryItselfIncluded() {
        let stack = stack([("", "abc/**\n!abc/keep.txt\n")])
        XCTAssertFalse(stack.isExcluded(relativePath: "abc", isDirectory: true))
        XCTAssertFalse(stack.isExcluded(relativePath: "abc/keep.txt", isDirectory: false))
        XCTAssertTrue(stack.isExcluded(relativePath: "abc/other.txt", isDirectory: false))
    }
}
