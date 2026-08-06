import XCTest
@testable import PisakaCore

/// Tests for the pure search engine backing the editor's find bar and the
/// project-wide "Find in Files" traversal. Everything here is Foundation-only
/// (`NSString` + UTF-16 offsets), like `DuplicateEngine`/`AutoPairEngine`.
final class TextSearchTests: XCTestCase {

    // MARK: - Literal search

    func testLiteralSearchIsCaseInsensitiveByDefault() throws {
        let text = "Foo foo FOO" as NSString
        let matches = try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "foo"))
        XCTAssertEqual(matches.map(\.range.location), [0, 4, 8])
        XCTAssertEqual(matches.map(\.range.length), [3, 3, 3])
    }

    func testLiteralSearchCaseSensitive() throws {
        let text = "Foo foo FOO" as NSString
        let matches = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "foo", caseSensitive: true)
        )
        XCTAssertEqual(matches.map(\.range.location), [4])
    }

    func testLiteralSearchFindsOverlappingCandidatesByAdvancingOneMatch() throws {
        // "aaaa" with pattern "aa": non-overlapping walk (advance by the match
        // length) yields 2 matches, not 3.
        let text = "aaaa" as NSString
        let matches = try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "aa"))
        XCTAssertEqual(matches.map(\.range.location), [0, 2])
    }

    func testLiteralSearchWithNoMatchReturnsEmpty() throws {
        let text = "hello" as NSString
        XCTAssertTrue(try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "zz")).isEmpty)
    }

    func testEmptyTextYieldsNoMatches() throws {
        let text = "" as NSString
        XCTAssertTrue(try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "a")).isEmpty)
    }

    // MARK: - Errors

    func testEmptyPatternThrows() {
        let text = "anything" as NSString
        XCTAssertThrowsError(try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: ""))) { error in
            XCTAssertEqual(error as? TextSearchError, .emptyPattern)
        }
    }

    func testWhitespaceOnlyPatternThrows() {
        let text = "a   b" as NSString
        XCTAssertThrowsError(try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "   "))) { error in
            XCTAssertEqual(error as? TextSearchError, .emptyPattern)
        }
        XCTAssertThrowsError(
            try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: " \t ", isRegex: true))
        ) { error in
            XCTAssertEqual(error as? TextSearchError, .emptyPattern)
        }
    }

    func testInvalidRegexThrowsWithAReason() {
        let text = "anything" as NSString
        XCTAssertThrowsError(
            try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "[", isRegex: true))
        ) { error in
            guard case .invalidRegex(let reason)? = error as? TextSearchError else {
                return XCTFail("expected .invalidRegex, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse((error as? TextSearchError)?.errorDescription?.isEmpty ?? true)
        }
    }

    func testEmptyPatternHasHumanReadableDescription() {
        XCTAssertFalse(TextSearchError.emptyPattern.errorDescription?.isEmpty ?? true)
    }

    func testInvalidRegexWithBlankReasonStillDescribesItself() {
        XCTAssertFalse(TextSearchError.invalidRegex(reason: "  ").errorDescription?.isEmpty ?? true)
    }

    /// An invalid pattern is only invalid when it is *used* as a regex — the same
    /// characters are an ordinary literal otherwise.
    func testInvalidRegexPatternIsFineAsALiteral() throws {
        let text = "a [ b" as NSString
        let matches = try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "["))
        XCTAssertEqual(matches.map(\.range.location), [2])
    }

    // MARK: - Regex search

    func testRegexSearchIsCaseInsensitiveByDefaultAndHonorsTheFlag() throws {
        let text = "Foo foo" as NSString
        let insensitive = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "f.o", isRegex: true)
        )
        XCTAssertEqual(insensitive.map(\.range.location), [0, 4])

        let sensitive = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "f.o", isRegex: true, caseSensitive: true)
        )
        XCTAssertEqual(sensitive.map(\.range.location), [4])
    }

    func testRegexSearchWithCaptureGroupsReportsTheWholeMatch() throws {
        let text = "a=1 bb=22" as NSString
        let matches = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: #"(\w+)=(\d+)"#, isRegex: true)
        )
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 4, length: 5)])
    }

    /// A pattern that can match nothing must neither loop forever nor report the
    /// same location twice: the walk terminates and locations strictly increase.
    func testZeroLengthRegexMatchesTerminateAndStrictlyIncrease() throws {
        let text = "bab" as NSString
        let matches = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "a*", isRegex: true)
        )
        XCTAssertFalse(matches.isEmpty)
        let locations = matches.map(\.range.location)
        XCTAssertEqual(locations, locations.sorted())
        XCTAssertEqual(Set(locations).count, locations.count)
        XCTAssertTrue(matches.contains { $0.range.length == 0 })
    }

    // MARK: - Whole word

    private func wholeWordLocations(_ haystack: String, _ needle: String) throws -> [Int] {
        try TextSearchEngine.matches(
            in: haystack as NSString,
            query: SearchQuery(pattern: needle, wholeWord: true)
        ).map(\.range.location)
    }

    func testWholeWordAtBufferBoundaries() throws {
        XCTAssertEqual(try wholeWordLocations("foo", "foo"), [0])
        XCTAssertEqual(try wholeWordLocations("foo bar", "foo"), [0])
        XCTAssertEqual(try wholeWordLocations("bar foo", "foo"), [4])
    }

    func testWholeWordRejectsAlphanumericAndUnderscoreNeighbors() throws {
        XCTAssertEqual(try wholeWordLocations("foobar", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("barfoo", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("_foo", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("foo_", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("foo1", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("1foo", "foo"), [])
    }

    func testWholeWordAcceptsPunctuationAndWhitespaceNeighbors() throws {
        XCTAssertEqual(try wholeWordLocations("(foo).", "foo"), [1])
        XCTAssertEqual(try wholeWordLocations("a\tfoo\n", "foo"), [2])
        XCTAssertEqual(try wholeWordLocations("-foo-", "foo"), [1])
    }

    func testWholeWordTreatsCyrillicAsWordCharacters() throws {
        // "оо" inside a longer Cyrillic word is not a whole word…
        XCTAssertEqual(try wholeWordLocations("фоо", "оо"), [])
        // …but standing alone it is.
        XCTAssertEqual(try wholeWordLocations("ф оо!", "оо"), [2])
    }

    /// Neighbors are read as *scalars*, combining a surrogate pair: an astral
    /// letter (U+1D400 MATHEMATICAL BOLD CAPITAL A, category Lu) is a word
    /// character, while a lone low-surrogate read would look non-word and wrongly
    /// keep the match.
    func testWholeWordCombinesSurrogatePairsForAstralLetters() throws {
        XCTAssertEqual(try wholeWordLocations("\u{1D400}foo", "foo"), [])
        XCTAssertEqual(try wholeWordLocations("foo\u{1D400}", "foo"), [])
    }

    /// An emoji is a symbol, not a letter, so it is a legitimate word boundary —
    /// and it too must be read as one scalar rather than two surrogate halves.
    func testWholeWordAcceptsAnEmojiNeighbor() throws {
        XCTAssertEqual(try wholeWordLocations("😀foo😀", "foo"), [2])
    }

    /// The `wholeWord` post-filter judges the *produced match's* own boundaries,
    /// so it applies unchanged to regex matches — it is one rule for both paths.
    func testWholeWordComposesWithRegex() throws {
        func locations(_ haystack: String, _ pattern: String) throws -> [Int] {
            try TextSearchEngine.matches(
                in: haystack as NSString,
                query: SearchQuery(pattern: pattern, isRegex: true, wholeWord: true)
            ).map(\.range.location)
        }

        // `\w+` matches maximally, so every match already sits on word boundaries.
        XCTAssertEqual(try locations("foo_bar baz", #"\w+"#), [0, 8])
        // A regex that can match mid-word is filtered by the same rule.
        XCTAssertEqual(try locations("foo", "oo"), [])
        XCTAssertEqual(try locations("фоо ноо", #"[а-я]+о"#), [0, 4])
        XCTAssertEqual(try locations("фоо ноо", "оо"), [])
        // Edges adjacent to `_` and to a digit are filtered.
        XCTAssertEqual(try locations("a_bc", "bc"), [])
        XCTAssertEqual(try locations("1bc", "bc"), [])
        XCTAssertEqual(try locations("bc9", "bc"), [])
    }

    // MARK: - Line numbers

    func testLineNumbersAreOneBasedForEveryStandardSeparator() throws {
        // LF, CRLF, CR and U+2028 each end exactly one line.
        let text = "a\nb\r\nc\rd\u{2028}e" as NSString
        let matches = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "[a-e]", isRegex: true)
        )
        XCTAssertEqual(matches.map(\.lineNumber), [1, 2, 3, 4, 5])
    }

    func testMatchAtALineStartBelongsToThatLine() throws {
        let text = "aa\nbb" as NSString
        let matches = try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "bb"))
        XCTAssertEqual(matches.map(\.range.location), [3])
        XCTAssertEqual(matches.map(\.lineNumber), [2])
    }

    func testMatchOnTheTrailingEmptyLine() throws {
        // A zero-length regex match at the very end of a newline-terminated buffer
        // lands on the trailing empty line, which `LineStartIndex` counts.
        let text = "a\n" as NSString
        let matches = try TextSearchEngine.matches(
            in: text,
            query: SearchQuery(pattern: "z*", isRegex: true)
        )
        XCTAssertEqual(matches.last?.range.location, 2)
        XCTAssertEqual(matches.last?.lineNumber, 2)
    }

    func testCRLFPairIsOneSeparator() throws {
        let text = "x\r\ny" as NSString
        let matches = try TextSearchEngine.matches(in: text, query: SearchQuery(pattern: "y"))
        XCTAssertEqual(matches.map(\.lineNumber), [2])
    }

    // MARK: - Replacement text

    func testLiteralReplacementIsTheTemplateVerbatim() throws {
        let text = "foo bar" as NSString
        let query = SearchQuery(pattern: "foo")
        let match = try XCTUnwrap(TextSearchEngine.matches(in: text, query: query).first)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: match, in: text, query: query, template: "baz"),
            "baz"
        )
    }

    /// A literal search never interprets `$1` — the template is inserted as typed,
    /// so searching for text and replacing with a literal dollar reference works.
    func testLiteralReplacementDoesNotInterpretGroupReferences() throws {
        let text = "foo" as NSString
        let query = SearchQuery(pattern: "foo")
        let match = try XCTUnwrap(TextSearchEngine.matches(in: text, query: query).first)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: match, in: text, query: query, template: "$1 $0 \\1"),
            "$1 $0 \\1"
        )
    }

    func testRegexReplacementSubstitutesCaptureGroups() throws {
        let text = "a=1 bb=22" as NSString
        let query = SearchQuery(pattern: #"(\w+)=(\d+)"#, isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(
            matches.map { TextSearchEngine.replacement(for: $0, in: text, query: query, template: "$2=$1") },
            ["1=a", "22=bb"]
        )
    }

    func testRegexReplacementSubstitutesTheWholeMatch() throws {
        let text = "a=1 bb=22" as NSString
        let query = SearchQuery(pattern: #"(\w+)=(\d+)"#, isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(
            matches.map { TextSearchEngine.replacement(for: $0, in: text, query: query, template: "[$0]") },
            ["[a=1]", "[bb=22]"]
        )
    }

    /// The rebuild is best-effort and never throws: a range the pattern does not
    /// re-match (a stale match, or a pattern needing context outside the range)
    /// yields the template unsubstituted rather than a crash or a partial edit.
    func testRegexReplacementFallsBackToTheRawTemplateForANonMatchingRange() {
        let text = "abc def" as NSString
        let query = SearchQuery(pattern: #"(\d+)"#, isRegex: true)
        let stale = SearchMatch(range: NSRange(location: 0, length: 3), lineNumber: 1)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: stale, in: text, query: query, template: "<$1>"),
            "<$1>"
        )
    }

    func testRegexReplacementFallsBackForAnInvalidPattern() {
        let text = "abc" as NSString
        let query = SearchQuery(pattern: "[", isRegex: true)
        let match = SearchMatch(range: NSRange(location: 0, length: 1), lineNumber: 1)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: match, in: text, query: query, template: "$1"),
            "$1"
        )
    }

    func testRegexReplacementFallsBackForAnOutOfBoundsRange() {
        let text = "abc" as NSString
        let query = SearchQuery(pattern: #"\w"#, isRegex: true)
        let match = SearchMatch(range: NSRange(location: 2, length: 9), lineNumber: 1)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: match, in: text, query: query, template: "x"),
            "x"
        )
    }

    /// A trailing lookahead sits *outside* the match's own range, so the anchored
    /// re-run only finds it because the options carry `.withTransparentBounds`.
    /// Without them the substitution fell back to the raw template and wrote a
    /// literal `<$1>` into the buffer (and, through Find in Files, onto disk).
    func testRegexReplacementSubstitutesThroughATrailingLookahead() throws {
        let text = "hello world" as NSString
        let query = SearchQuery(pattern: "(h)ello(?= world)", isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: 5)])
        XCTAssertEqual(
            TextSearchEngine.replacement(for: matches[0], in: text, query: query, template: "<$1>"),
            "<h>"
        )
    }

    func testRegexReplacementSubstitutesThroughALeadingLookbehind() throws {
        let text = "foobar" as NSString
        let query = SearchQuery(pattern: "(?<=foo)(b)ar", isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: matches[0], in: text, query: query, template: "<$1>"),
            "<b>"
        )
    }

    /// The mirror of the lookaround case: `.withoutAnchoringBounds` keeps `^`/`$`
    /// bound to the *buffer's line boundaries*, so the re-run agrees with the
    /// whole-buffer run that produced the match rather than re-anchoring at the
    /// match range's own edges.
    ///
    /// `"xab\nab"` is chosen so the two spellings disagree: the only `^(a)b` match
    /// is the one at the start of line 2, while the mid-line `ab` at `{1, 2}` is
    /// not a match at all — and would only re-match if the range's own start were
    /// treated as a line start.
    func testRegexReplacementKeepsAnchorsBoundToLineStartsNotTheMatchRange() throws {
        let text = "xab\nab" as NSString
        let query = SearchQuery(pattern: "^(a)b", isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 4, length: 2)])
        XCTAssertEqual(
            TextSearchEngine.replacement(for: matches[0], in: text, query: query, template: "<$1>"),
            "<a>"
        )

        // The mid-line "ab" is not a match, so a stale range naming it must not
        // re-match through a region-local `^`.
        let stale = SearchMatch(range: NSRange(location: 1, length: 2), lineNumber: 1)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: stale, in: text, query: query, template: "<$1>"),
            "<$1>"
        )
    }

    /// `^` is a *line* start, the VS Code/JetBrains editor-find semantics.
    func testRegexCaretMatchesAtEveryLineStart() throws {
        let text = "ab\ncd" as NSString
        let query = SearchQuery(pattern: #"^\w"#, isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(
            matches.map(\.range),
            [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)]
        )
        XCTAssertEqual(matches.map(\.lineNumber), [1, 2])
    }

    /// `$` is a *line* end, the mirror of the `^` rule.
    func testRegexDollarMatchesAtEveryLineEnd() throws {
        let text = "ab\nab" as NSString
        let query = SearchQuery(pattern: "b$", isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(
            matches.map(\.range),
            [NSRange(location: 1, length: 1), NSRange(location: 4, length: 1)]
        )
    }

    /// A match on a later line substitutes its groups like any other: the anchored
    /// re-run sees the same line boundaries the whole-buffer run did.
    func testRegexReplacementSubstitutesGroupsForAMatchOnALaterLine() throws {
        let text = "x1\ny2" as NSString
        let query = SearchQuery(pattern: #"^(\w)(\d)$"#, isRegex: true)
        let matches = try TextSearchEngine.matches(in: text, query: query)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(
            TextSearchEngine.replacement(for: matches[1], in: text, query: query, template: "<$2$1>"),
            "<2y>"
        )
    }

    /// Line anchors are on; `.dotMatchesLineSeparators` deliberately is **not**,
    /// so `.` still stops at a line break.
    func testRegexDotDoesNotCrossALineBreak() throws {
        let text = "a\nb" as NSString
        let query = SearchQuery(pattern: "a.b", isRegex: true)
        XCTAssertTrue(try TextSearchEngine.matches(in: text, query: query).isEmpty)
    }

    /// The anchors must agree with the separators the gutter and the minimap
    /// count by (`LineStartIndex`), not only with LF: a CR- or CRLF-delimited
    /// file would otherwise report `^` hits where no line starts. CRLF is the one
    /// two-unit break, so it is also the off-by-one candidate — `^` belongs after
    /// the `\n`, not between the pair.
    func testRegexCaretMatchesAtLineStartsForEverySeparator() throws {
        for (name, separator) in [
            ("CR", "\r"), ("CRLF", "\r\n"), ("NEL", "\u{0085}"),
            ("LS", "\u{2028}"), ("PS", "\u{2029}"),
        ] {
            let text = "ab\(separator)cd" as NSString
            let query = SearchQuery(pattern: #"^\w"#, isRegex: true)
            let matches = try TextSearchEngine.matches(in: text, query: query)
            let secondLineStart = 2 + (separator as NSString).length
            XCTAssertEqual(
                matches.map(\.range),
                [NSRange(location: 0, length: 1), NSRange(location: secondLineStart, length: 1)],
                "\(name) line starts"
            )
            // The engine's own line numbering must agree with where it anchored.
            XCTAssertEqual(matches.map(\.lineNumber), [1, 2], "\(name) line numbers")

            // And the anchored re-run the replacement path uses reproduces it, so
            // a second-line match substitutes rather than falling back.
            XCTAssertEqual(
                TextSearchEngine.replacement(
                    for: matches[1], in: text, query: SearchQuery(pattern: #"^(\w)"#, isRegex: true),
                    template: "<$1>"
                ),
                "<c>",
                "\(name) replacement"
            )
        }
    }

    /// The documented divergence: ICU anchors after a *superset* of
    /// `LineStartIndex`'s separators, adding VT (U+000B) and FF (U+000C). Pinned
    /// so it stays a known limit rather than drifting silently — see
    /// `TextSearchEngine.regularExpression(for:)`.
    func testRegexAnchorsFollowICUTerminatorsIncludingFormFeed() throws {
        let text = "a\u{000B}b\u{000C}c\nd" as NSString
        let matches = try TextSearchEngine.matches(
            in: text, query: SearchQuery(pattern: "^.", isRegex: true)
        )
        // ICU anchors after the VT and the FF as well as after the LF.
        XCTAssertEqual(matches.map(\.range.location), [0, 2, 4, 6])
        // The editor's own line model sees only two lines, so the VT/FF hits
        // report the line number of the text they sit inside.
        XCTAssertEqual(LineStartIndex.offsets(in: text), [0, 6])
        XCTAssertEqual(matches.map(\.lineNumber), [1, 1, 1, 2])
    }

    /// A whole plan built from a lookahead query substitutes every match, rather
    /// than splattering the unresolved template across the buffer.
    func testReplacePlanSubstitutesThroughALookahead() throws {
        let query = SearchQuery(pattern: #"(\w+)(?=;)"#, isRegex: true)
        let edits = try plan("one; two; three", query, template: "[$1]")
        XCTAssertEqual(edits.map(\.replacement), ["[two]", "[one]"])
        XCTAssertEqual(applying(edits, to: "one; two; three"), "[one]; [two]; three")
    }

    // MARK: - Replacement plan

    private func plan(
        _ haystack: String,
        _ query: SearchQuery,
        template: String
    ) throws -> [ReplaceEdit] {
        let text = haystack as NSString
        let matches = try TextSearchEngine.matches(in: text, query: query)
        return TextSearchEngine.replacePlan(matches: matches, in: text, query: query, template: template)
    }

    /// Applying the plan in order to one mutable buffer: each edit sits entirely
    /// before the ones already applied, so no earlier offset is ever invalidated.
    private func applying(_ plan: [ReplaceEdit], to haystack: String) -> String {
        let mutable = NSMutableString(string: haystack)
        for edit in plan {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    func testReplacePlanIsOrderedStrictlyLastToFirst() throws {
        let edits = try plan("foo bar foo baz foo", SearchQuery(pattern: "foo"), template: "x")
        XCTAssertEqual(edits.map(\.range.location), [16, 8, 0])
        XCTAssertEqual(edits.map(\.replacement), ["x", "x", "x"])
    }

    func testReplacePlanDropsOverlapsKeepingTheEarlierMatch() {
        let text = "abcdefg" as NSString
        let overlapping = [
            SearchMatch(range: NSRange(location: 0, length: 3), lineNumber: 1),
            SearchMatch(range: NSRange(location: 2, length: 3), lineNumber: 1),
            SearchMatch(range: NSRange(location: 5, length: 2), lineNumber: 1),
        ]
        let edits = TextSearchEngine.replacePlan(
            matches: overlapping,
            in: text,
            query: SearchQuery(pattern: "abc"),
            template: "X"
        )
        XCTAssertEqual(
            edits,
            [
                ReplaceEdit(range: NSRange(location: 5, length: 2), replacement: "X"),
                ReplaceEdit(range: NSRange(location: 0, length: 3), replacement: "X"),
            ]
        )
    }

    func testReplacePlanDropsRangesOutsideTheBuffer() {
        let text = "abc" as NSString
        let edits = TextSearchEngine.replacePlan(
            matches: [
                SearchMatch(range: NSRange(location: 0, length: 1), lineNumber: 1),
                SearchMatch(range: NSRange(location: 2, length: 9), lineNumber: 1),
            ],
            in: text,
            query: SearchQuery(pattern: "a"),
            template: "Z"
        )
        XCTAssertEqual(edits, [ReplaceEdit(range: NSRange(location: 0, length: 1), replacement: "Z")])
    }

    func testApplyingThePlanReplacesWithALongerString() throws {
        let source = "foo bar foo"
        let edits = try plan(source, SearchQuery(pattern: "foo"), template: "quuux")
        XCTAssertEqual(applying(edits, to: source), "quuux bar quuux")
    }

    func testApplyingThePlanReplacesWithAShorterString() throws {
        let source = "foo bar foo"
        let edits = try plan(source, SearchQuery(pattern: "foo"), template: "f")
        XCTAssertEqual(applying(edits, to: source), "f bar f")
    }

    func testApplyingThePlanReplacesWithAnEmptyString() throws {
        let source = "foo bar foo"
        let edits = try plan(source, SearchQuery(pattern: "foo"), template: "")
        XCTAssertEqual(applying(edits, to: source), " bar ")
    }

    func testApplyingARegexPlanSubstitutesEachMatchesOwnGroups() throws {
        let source = "a=1\nbb=22\n"
        let edits = try plan(
            source,
            SearchQuery(pattern: #"(\w+)=(\d+)"#, isRegex: true),
            template: "$2 -> $1"
        )
        XCTAssertEqual(applying(edits, to: source), "1 -> a\n22 -> bb\n")
    }

    func testApplyingAPlanOverZeroLengthMatchesInsertsWithoutDeleting() throws {
        let source = "ab"
        let edits = try plan(source, SearchQuery(pattern: "x*", isRegex: true), template: "-")
        XCTAssertEqual(applying(edits, to: source), "-a-b-")
    }

    func testReplacePlanOverNoMatchesIsEmpty() {
        XCTAssertTrue(
            TextSearchEngine.replacePlan(
                matches: [],
                in: "abc" as NSString,
                query: SearchQuery(pattern: "z"),
                template: "x"
            ).isEmpty
        )
    }

    // MARK: - Navigation cursor

    private var cursorMatches: [SearchMatch] {
        [
            SearchMatch(range: NSRange(location: 4, length: 3), lineNumber: 1),
            SearchMatch(range: NSRange(location: 10, length: 3), lineNumber: 2),
            SearchMatch(range: NSRange(location: 20, length: 3), lineNumber: 3),
        ]
    }

    func testNearestIndexOnEmptyMatchesIsNil() {
        XCTAssertNil(TextSearchEngine.index(nearestTo: 0, in: [], forward: true))
        XCTAssertNil(TextSearchEngine.index(nearestTo: 0, in: [], forward: false))
    }

    func testNearestIndexForwardTakesTheFirstMatchAtOrAfterTheCaret() {
        let matches = cursorMatches
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: matches, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 4, in: matches, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 5, in: matches, forward: true), 1)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 20, in: matches, forward: true), 2)
    }

    func testNearestIndexForwardWrapsPastTheLastMatch() {
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 21, in: cursorMatches, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 9_999, in: cursorMatches, forward: true), 0)
    }

    func testNearestIndexBackwardTakesTheLastMatchBeforeTheCaret() {
        let matches = cursorMatches
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 21, in: matches, forward: false), 2)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 20, in: matches, forward: false), 1)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 10, in: matches, forward: false), 0)
    }

    func testNearestIndexBackwardWrapsBeforeTheFirstMatch() {
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 4, in: cursorMatches, forward: false), 2)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: cursorMatches, forward: false), 2)
    }

    func testNearestIndexOverASingleMatchAlwaysResolvesToIt() {
        let one = [SearchMatch(range: NSRange(location: 3, length: 1), lineNumber: 1)]
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: one, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 99, in: one, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: one, forward: false), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 99, in: one, forward: false), 0)
    }

    /// A caret sitting *at the start* of a non-empty match must still find that
    /// match going forward — the zero-length rule below must not cost this.
    func testNearestIndexForwardTakesANonEmptyMatchStartingAtTheCaret() {
        let matches = [
            SearchMatch(range: NSRange(location: 5, length: 3), lineNumber: 1),
            SearchMatch(range: NSRange(location: 10, length: 3), lineNumber: 2),
        ]
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 5, in: matches, forward: true), 0)
    }

    /// Find Next must advance across zero-length matches (`a*`, `^`, `\b`) rather
    /// than resolving back to the one the caret already sits on: selecting a
    /// zero-length match leaves the selection's end equal to its start, so an
    /// at-or-after test would pin the bar to match 1 of n forever.
    func testNearestIndexForwardStepsOffAZeroLengthMatchAtTheCaret() {
        let matches = (0...3).map {
            SearchMatch(range: NSRange(location: $0, length: 0), lineNumber: 1)
        }

        // Walking with the caret left at each selected zero-length match visits
        // every one of them in turn, then wraps.
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: matches, forward: true), 1)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 1, in: matches, forward: true), 2)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 2, in: matches, forward: true), 3)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 3, in: matches, forward: true), 0)
    }

    /// The wraparound still reaches a lone zero-length match, so nothing becomes
    /// unreachable in exchange for the stepping rule above.
    func testNearestIndexForwardOverALoneZeroLengthMatchResolvesToIt() {
        let one = [SearchMatch(range: NSRange(location: 4, length: 0), lineNumber: 1)]
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 4, in: one, forward: true), 0)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: one, forward: true), 0)
    }

    /// Find Previous was never stuck (its predicate is already strict) and must
    /// stay that way.
    func testNearestIndexBackwardStepsOffAZeroLengthMatchAtTheCaret() {
        let matches = (0...3).map {
            SearchMatch(range: NSRange(location: $0, length: 0), lineNumber: 1)
        }
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 3, in: matches, forward: false), 2)
        XCTAssertEqual(TextSearchEngine.index(nearestTo: 0, in: matches, forward: false), 3)
    }

    // MARK: - Current-match cursor

    func testCurrentIndexOnEmptyMatchesIsNil() {
        XCTAssertNil(TextSearchEngine.currentIndex(forCaretAt: 0, in: []))
    }

    /// Off a match start it is the forward rule: the match at or after the caret,
    /// wrapping past the last one.
    func testCurrentIndexOffAMatchStartFallsBackToTheForwardRule() {
        let matches = cursorMatches
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 0, in: matches), 0)
        // Mid-match: the caret is inside match 0, which it has already passed the
        // start of, so the next one is named — the pre-existing behaviour.
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 5, in: matches), 1)
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 14, in: matches), 2)
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 9_999, in: matches), 0)
    }

    /// Selecting a match puts the caret at its start, so that match is the current
    /// one — the same answer the forward rule already gave for a non-empty match.
    func testCurrentIndexTakesANonEmptyMatchStartingAtTheCaret() {
        let matches = cursorMatches
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 4, in: matches), 0)
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 10, in: matches), 1)
        XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: 20, in: matches), 2)
    }

    /// The point of the separate resolver: a **zero-length** match at the caret is
    /// the current one, where `index(nearestTo:forward:)` deliberately skips it to
    /// let Find Next advance. Conflating the two made the counter read one ahead
    /// of the caret and Replace edit the following match — with `^`, the first
    /// line could never be replaced at all.
    func testCurrentIndexTakesAZeroLengthMatchAtTheCaret() {
        let matches = (0...3).map {
            SearchMatch(range: NSRange(location: $0, length: 0), lineNumber: 1)
        }
        for caret in 0...3 {
            XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: caret, in: matches), caret)
            // The navigation cursor still steps off it, so ⌘G keeps advancing.
            XCTAssertNotEqual(
                TextSearchEngine.index(nearestTo: caret, in: matches, forward: true),
                caret
            )
        }
    }

    /// Walking with Find Next and re-deriving "current" from the resulting caret
    /// must land on the match that was just selected, for zero-length matches too
    /// — otherwise the selection and the current index drift apart by one on every
    /// step.
    func testCurrentIndexAgreesWithWhatFindNextSelected() {
        for matches in [cursorMatches, (0...3).map({
            SearchMatch(range: NSRange(location: $0 * 2, length: 0), lineNumber: 1)
        })] {
            var caret = 0
            for _ in 0..<(matches.count + 1) {
                guard let next = TextSearchEngine.index(
                    nearestTo: caret,
                    in: matches,
                    forward: true
                ) else { return XCTFail("expected a match") }
                // Selecting it leaves the caret at the match's start.
                caret = matches[next].range.location
                XCTAssertEqual(TextSearchEngine.currentIndex(forCaretAt: caret, in: matches), next)
                // A non-empty match is selected whole, so "next" starts from its end.
                caret = NSMaxRange(matches[next].range)
            }
        }
    }

    // MARK: - Query value semantics

    func testSearchQueryDefaultsAllFlagsToFalse() {
        let query = SearchQuery(pattern: "x")
        XCTAssertFalse(query.isRegex)
        XCTAssertFalse(query.caseSensitive)
        XCTAssertFalse(query.wholeWord)
        XCTAssertEqual(query, SearchQuery(pattern: "x", isRegex: false, caseSensitive: false, wholeWord: false))
        XCTAssertNotEqual(query, SearchQuery(pattern: "x", isRegex: true))
    }
}
