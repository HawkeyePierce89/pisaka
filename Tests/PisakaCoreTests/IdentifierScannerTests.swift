import XCTest
@testable import PisakaCore

/// Pins the one identifier-boundary rule all of code intelligence shares: the
/// word a ⌘-click resolves, the prefix a keystroke completes, and the words the
/// buffer harvester offers. Boundary cases (`$`, `.`, digit-leading, Unicode,
/// surrogate pairs) are the whole point — they are what a hand-rolled scan in
/// each of the three call sites would have gotten subtly differently.
final class IdentifierScannerTests: XCTestCase {

    private func text(_ string: String) -> NSString { string as NSString }

    // MARK: - identifier(in:at:)

    func testIdentifierExpandsBothWaysFromAnyOffsetInsideIt() {
        let source = text("let workerCount = 3")
        for offset in 4...15 {
            let match = IdentifierScanner.identifier(in: source, at: offset)
            XCTAssertEqual(match?.text, "workerCount", "offset \(offset)")
            XCTAssertEqual(match?.range, NSRange(location: 4, length: 11), "offset \(offset)")
        }
    }

    /// The keyboard path: after typing a name the caret sits just past it, and
    /// ⌃⌘J must still resolve that word.
    func testIdentifierResolvesTheWordEndingAtTheCaret() {
        let source = text("Worker")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 6)?.text, "Worker")
    }

    func testIdentifierIsNilOffAnyName() {
        let source = text("a + b")
        XCTAssertNil(IdentifierScanner.identifier(in: source, at: 2))
        XCTAssertNil(IdentifierScanner.identifier(in: text("   "), at: 1))
        XCTAssertNil(IdentifierScanner.identifier(in: text(""), at: 0))
    }

    func testIdentifierStopsAtDotsAndDollars() {
        let source = text("foo.bar")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 5)?.text, "bar")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 1)?.text, "foo")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("$FOO"), at: 2)?.text, "FOO")
    }

    /// Digits continue a name but cannot start one, so a leading run of them is
    /// trimmed and a pure number is not a name at all.
    func testDigitLeadingRunsAreTrimmedAndPureNumbersAreNotNames() {
        XCTAssertEqual(IdentifierScanner.identifier(in: text("9foo"), at: 0)?.text, "foo")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("9foo"), at: 2)?.text, "foo")
        XCTAssertNil(IdentifierScanner.identifier(in: text("12345"), at: 2))
        XCTAssertEqual(IdentifierScanner.identifier(in: text("x2y"), at: 1)?.text, "x2y")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("_private"), at: 0)?.text, "_private")
    }

    func testUnicodeNamesAreNotSplit() {
        XCTAssertEqual(IdentifierScanner.identifier(in: text("let имя = 1"), at: 5)?.text, "имя")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("número"), at: 3)?.text, "número")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("変数 = 1"), at: 0)?.text, "変数")
    }

    /// A non-BMP scalar occupies two UTF-16 units; neither an offset on its
    /// trailing half nor the surrounding scan may cut it in half.
    func testSurrogatePairsAreScannedWhole() {
        // U+1D400 MATHEMATICAL BOLD CAPITAL A is a letter, so it is a valid name.
        let source = text("var \u{1D400}bc = 1")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 4)?.text, "\u{1D400}bc")
        // Offset 5 is the trailing surrogate half: it resolves to the same name.
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 5)?.text, "\u{1D400}bc")
        XCTAssertEqual(
            IdentifierScanner.identifier(in: source, at: 4)?.range,
            NSRange(location: 4, length: 4)
        )
    }

    func testOffsetsOutsideTheStringAreClamped() {
        let source = text("name")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 999)?.text, "name")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: -5)?.text, "name")
    }

    // MARK: - completionPrefixRange(in:at:)

    func testCompletionPrefixTakesOnlyTheWordLeftOfTheCaret() {
        let source = text("foo.bar")
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: source, at: 7),
            NSRange(location: 4, length: 3)
        )
        // Mid-word: only what is to the left is being completed.
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: source, at: 6),
            NSRange(location: 4, length: 2)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("$FOO"), at: 4),
            NSRange(location: 1, length: 3)
        )
    }

    func testCompletionPrefixIsEmptyAtTheCaretWhenThereIsNothingToComplete() {
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("foo "), at: 4),
            NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text(""), at: 0),
            NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("foo("), at: 4),
            NSRange(location: 4, length: 0)
        )
        // A bare number cannot start a name, so there is no prefix to complete.
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("x = 123"), at: 7),
            NSRange(location: 7, length: 0)
        )
    }

    func testCompletionPrefixTrimsALeadingDigitRun() {
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("9foo"), at: 4),
            NSRange(location: 1, length: 3)
        )
    }

    // MARK: - completionReplaceRange(in:at:)

    func testCompletionReplaceRangeEqualsPrefixRangeWhenThereIsNoSuffix() {
        let source = text("foo.bar")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            IdentifierScanner.completionPrefixRange(in: source, at: 7)
        )
    }

    func testCompletionReplaceRangeExtendsOverTheSuffix() {
        let source = text("CREATE_typo")
        // caret after CREATE (offset 6)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 6),
            NSRange(location: 0, length: 11)
        )
    }

    func testCompletionReplaceRangeAtStartOfWordExtendsOverWholeWord() {
        let source = text("foo")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 0),
            NSRange(location: 0, length: 3)
        )
    }

    func testCompletionReplaceRangeWithEmptyPrefixAndSuffixCoversSuffix() {
        let source = text("worker.foo")
        // caret after the dot (offset 7)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            NSRange(location: 7, length: 3)
        )
    }

    func testCompletionReplaceRangeAtMemberPositionStopsAtDot() {
        let source = text("foo.bar.baz")
        // caret in bar (offset 5)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 5),
            NSRange(location: 4, length: 3)
        )
    }
    
    func testCompletionReplaceRangeWithTrimmedHeadPreservesTheTrimmedStart() {
        let source = text("9foobar")
        // caret at 9foo|bar (offset 4)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 4),
            NSRange(location: 1, length: 6) // "foobar"
        )
    }

    func testCompletionReplaceRangePastDotYieldsEmptyRange() {
        let source = text("worker.")
        // caret after the dot (offset 7)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            NSRange(location: 7, length: 0)
        )
    }

    func testCompletionReplaceRangeClampsOffsetsAndAlignsScalars() {
        let source = text("var \u{1D400}bc = 1")
        // Caret in mid-surrogate (offset 5). The start is at 4, length is 4 ("\u{1D400}bc")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 5),
            NSRange(location: 4, length: 4)
        )
        // Out of range negative clamps to 0
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: -5),
            NSRange(location: 0, length: 3) // "var"
        )
        // End of buffer (clamps to length)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 999),
            NSRange(location: source.length, length: 0)
        )
    }

    // MARK: - memberContext(in:at:)

    /// The two shapes that open a member list: the dot just typed (empty
    /// prefix) and a few characters typed after it.
    func testMemberContextResolvesTheReceiverAndTheTypedPrefix() {
        let justTyped = text("worker.")
        XCTAssertEqual(
            IdentifierScanner.memberContext(in: justTyped, at: 7),
            IdentifierScanner.MemberContext(
                receiver: "worker",
                prefixRange: NSRange(location: 7, length: 0)
            )
        )

        let partial = text("worker.na")
        XCTAssertEqual(
            IdentifierScanner.memberContext(in: partial, at: 9),
            IdentifierScanner.MemberContext(
                receiver: "worker",
                prefixRange: NSRange(location: 7, length: 2)
            )
        )
    }

    /// A chained access takes the *nearest* receiver, not the whole expression:
    /// in `a.b.c|` the members being offered are `b`'s.
    func testMemberContextTakesTheNearestReceiverInAChain() {
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("a.b.c"), at: 5)?.receiver, "b")
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("a.b."), at: 4)?.receiver, "b")
    }

    /// A dot off a closing bracket is still a member position — the expression
    /// yields a value — but its spelling names no type, so there is no receiver.
    func testMemberContextAfterAClosingBracketHasNoReceiver() {
        for source in ["items[0].", "f().", "compute { x }."] {
            let context = IdentifierScanner.memberContext(in: text(source), at: (source as NSString).length)
            XCTAssertNotNil(context, source)
            XCTAssertNil(context?.receiver, source)
        }
    }

    /// Everything a dot can follow that is *not* a member access. `1.` and
    /// `1.5` are the float literals: typing a decimal point must never open a
    /// member list.
    func testMemberContextIsNilWhereTheDotIsNotAMemberAccess() {
        let cases = ["1.", "1.5", "3.14", "foo .", "(.", "..", ".", "foo ,.", "+."]
        for source in cases {
            XCTAssertNil(
                IdentifierScanner.memberContext(in: text(source), at: (source as NSString).length),
                source
            )
        }
        XCTAssertNil(IdentifierScanner.memberContext(in: text(""), at: 0))
    }

    /// Deleting the dot hands the caret back to ordinary identifier completion:
    /// there is no member context left to find.
    func testMemberContextIsNilOnceTheDotIsDeleted() {
        XCTAssertNil(IdentifierScanner.memberContext(in: text("workerna"), at: 8))
        XCTAssertNil(IdentifierScanner.memberContext(in: text("foo"), at: 3))
    }

    /// The reported range is the same one ordinary completion would replace, so
    /// the member and identifier paths can never insert at different places.
    ///
    /// The found-context count is asserted alongside the equality: without it the
    /// loop is a `continue` over offsets that report nothing, and a
    /// `memberContext` regressed to returning `nil` everywhere would pass the one
    /// test whose whole job is the cross-check between the two paths.
    func testMemberContextPrefixRangeMatchesCompletionPrefixRange() {
        // Per source: every offset strictly after its dot(s) is a member position.
        let sources = [
            ("worker.", 1), ("worker.na", 3), ("a.b.c", 4), ("items[0].doR", 4), ("$FOO.bar", 4)
        ]
        for (source, expectedContexts) in sources {
            let string = text(source)
            var found = 0
            for offset in 0...string.length {
                guard let context = IdentifierScanner.memberContext(in: string, at: offset) else { continue }
                found += 1
                XCTAssertEqual(
                    context.prefixRange,
                    IdentifierScanner.completionPrefixRange(in: string, at: offset),
                    "\(source) @ \(offset)"
                )
            }
            XCTAssertEqual(found, expectedContexts, source)
        }
    }

    /// A member prefix that does not *begin* right after the dot is not a member
    /// position at all.
    ///
    /// Two shapes, one rule. When the run after the dot is all digits the trim
    /// leaves nothing, so `completionPrefixRange` reports the empty range **after**
    /// the digits — which the provider reads as "the dot was just typed" (and
    /// answers with every member in the project) and which the editors insert at,
    /// turning `pair.0|` into `pair.0doWork`. When the run merely *starts* with
    /// digits the trim lands partway into it, and completing there rewrites the
    /// middle of a token: `ubuntu20.04lts|` would offer members for the receiver
    /// `ubuntu20` and replace `lts`, yielding `ubuntu20.04doWork`. Swift tuple
    /// access makes the first shape an every-keystroke case, not an exotic one.
    func testMemberContextIsNilWhenTheMemberPrefixDoesNotStartAtTheDot() {
        let sources = [
            "pair.0", "point.12", "ubuntu20.04", "items[0].7",  // trims to nothing
            "ubuntu20.04lts", "v1.0beta", "x.0rc",               // trims partway in
        ]
        for source in sources {
            XCTAssertNil(
                IdentifierScanner.memberContext(in: text(source), at: (source as NSString).length),
                source
            )
        }
        // The empty run is the legitimate bare-dot case and is unaffected, as is a
        // prefix that *contains* digits but still begins with a name character.
        XCTAssertNotNil(IdentifierScanner.memberContext(in: text("pair."), at: 5))
        XCTAssertEqual(
            IdentifierScanner.memberContext(in: text("worker.name0"), at: 12)?.prefixRange,
            NSRange(location: 7, length: 5)
        )
        // A leading `_` starts an identifier, so it is the run's own first
        // character and the position stands.
        XCTAssertEqual(
            IdentifierScanner.memberContext(in: text("worker._x"), at: 9)?.prefixRange,
            NSRange(location: 7, length: 2)
        )
    }

    /// The receiver goes through the same trim rule as every other lookup, and
    /// the scan is surrogate-pair aware on both sides of the dot.
    func testMemberContextAppliesTheSharedBoundaryRule() {
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("9foo.bar"), at: 8)?.receiver, "foo")
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("x2.y"), at: 4)?.receiver, "x2")
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("_private."), at: 9)?.receiver, "_private")
        XCTAssertEqual(IdentifierScanner.memberContext(in: text("имя.по"), at: 6)?.receiver, "имя")
        XCTAssertEqual(
            IdentifierScanner.memberContext(in: text("\u{1D400}bc.d"), at: 6)?.receiver,
            "\u{1D400}bc"
        )
    }

    func testMemberContextClampsOffsetsOutsideTheString() {
        let source = text("worker.na")
        XCTAssertEqual(IdentifierScanner.memberContext(in: source, at: 999)?.receiver, "worker")
        XCTAssertNil(IdentifierScanner.memberContext(in: source, at: -5))
    }

    // MARK: - words(in:limit:)

    func testWordsHarvestsDistinctNamesInFirstOccurrenceOrder() {
        let source = text("let count = count + total // count")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 100), ["let", "count", "total"])
    }

    func testWordsAppliesTheSameBoundaryRule() {
        let source = text("foo.bar $BAZ 9qux 123 _x 変数")
        XCTAssertEqual(
            IdentifierScanner.words(in: source, limit: 100),
            ["foo", "bar", "BAZ", "qux", "_x", "変数"]
        )
    }

    func testWordsCapsDistinctEntriesAndStopsScanning() {
        let source = text("aa bb cc dd ee")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 3), ["aa", "bb", "cc"])
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 0), [])
        XCTAssertEqual(IdentifierScanner.words(in: text(""), limit: 10), [])
    }

    /// The cap counts distinct words, so repetition does not consume it — the
    /// reason a large generated file with few unique tokens still harvests fully.
    func testWordsCapCountsDistinctNamesOnly() {
        let source = text(Array(repeating: "same", count: 500).joined(separator: " ") + " other")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 2), ["same", "other"])
    }

    // MARK: - isIdentifier(_:)

    /// The whole-string form answers the same question the scanning entry points
    /// ask scalar by scalar, which is the point of it existing: what the caret is
    /// completing and what may be inserted are decided by one rule.
    func testIsIdentifierAcceptsWhatTheScannerWouldFindAsOneWholeWord() {
        XCTAssertTrue(IdentifierScanner.isIdentifier("services"))
        XCTAssertTrue(IdentifierScanner.isIdentifier("_private"))
        XCTAssertTrue(IdentifierScanner.isIdentifier("Worker2"))
        XCTAssertTrue(IdentifierScanner.isIdentifier("имя"))
        XCTAssertTrue(IdentifierScanner.isIdentifier("n\u{00FA}mero"))
        XCTAssertTrue(IdentifierScanner.isIdentifier("\u{5909}\u{6570}"))
    }

    /// Everything the run-scanning rule would split, trim or drop entirely.
    func testIsIdentifierRejectsAnythingTheBoundaryRuleWouldNotYieldWhole() {
        XCTAssertFalse(IdentifierScanner.isIdentifier(""))
        XCTAssertFalse(IdentifierScanner.isIdentifier("two words"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("run(_:)"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("foo.bar"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("kebab-case"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("9foo"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("123"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("trailing "))
        XCTAssertFalse(IdentifierScanner.isIdentifier(" leading"))
        XCTAssertFalse(IdentifierScanner.isIdentifier("$FOO"))
    }

    /// Stated as an equivalence rather than by example: for any string, the
    /// whole-string rule agrees with "the scanner finds exactly this word, whole"
    /// — so the two can never drift apart as the classification changes.
    func testIsIdentifierAgreesWithTheScanningEntryPoints() {
        let samples = [
            "services", "_private", "Worker2", "\u{0438}\u{043C}\u{044F}", "", "two words", "run(_:)",
            "foo.bar", "kebab-case", "9foo", "123", "trailing ", " leading", "$FOO", "a",
        ]
        for sample in samples {
            let scanned = IdentifierScanner.words(in: sample as NSString, limit: 2)
            XCTAssertEqual(
                IdentifierScanner.isIdentifier(sample),
                scanned == [sample],
                "whole-string rule disagrees with the scanner for \(sample.debugDescription)"
            )
        }
    }

    // MARK: - The shared classification

    func testClassificationExcludesDigitsFromStartsButNotFromContinuations() {
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("a"))
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("_"))
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("я"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("7"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("$"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("."))

        XCTAssertTrue(IdentifierScanner.isIdentifierContinuation("7"))
        XCTAssertTrue(IdentifierScanner.isIdentifierContinuation("_"))
        XCTAssertFalse(IdentifierScanner.isIdentifierContinuation("-"))
        XCTAssertFalse(IdentifierScanner.isIdentifierContinuation(" "))
    }

    /// The ASCII fast path must be a pure optimization: over the whole ASCII
    /// range both rules have to answer exactly what `CharacterSet.letters` /
    /// `.alphanumerics` do, or the scanner would quietly disagree with itself
    /// about a character source code is full of. Checked exhaustively rather than
    /// by sampling — the range is 128 values, and an off-by-one at a boundary
    /// (`@`/`A`, `Z`/`[`, `` ` ``/`a`, `z`/`{`, `/`/`0`, `9`/`:`) is precisely the
    /// mistake a hand-written range compare makes.
    func testASCIIClassificationMatchesTheUnicodeSetsItShortCircuits() {
        for value in 0..<128 {
            let scalar = UnicodeScalar(UInt8(value))
            XCTAssertEqual(
                IdentifierScanner.isIdentifierStart(scalar),
                scalar == "_" || CharacterSet.letters.contains(scalar),
                "start rule disagrees for U+\(String(value, radix: 16))"
            )
            XCTAssertEqual(
                IdentifierScanner.isIdentifierContinuation(scalar),
                scalar == "_" || CharacterSet.alphanumerics.contains(scalar),
                "continuation rule disagrees for U+\(String(value, radix: 16))"
            )
        }
    }
}
