import XCTest
@testable import PisakaCore

/// Tests for the `.editorconfig` file format parser and the merged property map.
///
/// The cases mirror the official EditorConfig core test suite's parser and
/// property files — their *contents*, not their files: an actual
/// `.editorconfig` committed under `Tests/` would apply to this repository in
/// every editor and every tool that reads the format, so each sample config is
/// spelled inline and each test is named after the case it mirrors.
final class EditorConfigFileTests: XCTestCase {

    // MARK: - Helpers

    /// The pairs of the single section of a one-section file.
    private func pairs(_ text: String) -> [EditorConfigPair] {
        let file = EditorConfigFile(text: text)
        return file.sections.first?.pairs ?? []
    }

    /// The value of `key` in the single section of a one-section file.
    private func value(_ key: String, _ text: String) -> String? {
        EditorConfigFile(text: text).sections.first?.value(for: key)
    }

    /// A properties map built by applying every pair of every section, in order.
    private func properties(_ text: String) -> EditorConfigProperties {
        var properties = EditorConfigProperties()
        for section in EditorConfigFile(text: text).sections {
            for pair in section.pairs { properties.apply(pair) }
        }
        return properties
    }

    // MARK: - Preamble and sections

    func testRootTrueInThePreambleIsHonored() {
        XCTAssertTrue(EditorConfigFile(text: "root = true\n[*]\nindent_size = 2\n").isRoot)
    }

    func testRootIsComparedCaseInsensitively() {
        XCTAssertTrue(EditorConfigFile(text: "Root = TRUE\n").isRoot)
    }

    func testRootFalseAndAnAbsentRootBothLeaveTheWalkOpen() {
        XCTAssertFalse(EditorConfigFile(text: "root = false\n").isRoot)
        XCTAssertFalse(EditorConfigFile(text: "[*]\nindent_size = 2\n").isRoot)
    }

    func testRootAfterTheFirstSectionIsIgnoredAsADeclaration() {
        let file = EditorConfigFile(text: "[*]\nroot = true\n")
        XCTAssertFalse(file.isRoot)
        // It is still an ordinary property of that section.
        XCTAssertEqual(file.sections.first?.value(for: "root"), "true")
    }

    func testSectionsKeepDocumentOrderWithTheirOwnPairs() {
        let file = EditorConfigFile(text: """
        [*]
        indent_style = space
        [*.c]
        indent_size = 4
        """)
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections.map { $0.glob.pattern }, ["*", "*.c"])
        XCTAssertEqual(file.sections.first?.value(for: "indent_style"), "space")
        XCTAssertEqual(file.sections.last?.value(for: "indent_size"), "4")
    }

    func testSectionNameIsTheTextUpToTheLastClosingBracket() {
        let file = EditorConfigFile(text: "[[*.c]]\nindent_size = 2\n")
        XCTAssertEqual(file.sections.first?.glob.pattern, "[*.c]")
    }

    func testHeaderWithNoClosingBracketIsSkipped() {
        let file = EditorConfigFile(text: "[*.c\nindent_size = 2\n[*.h]\nindent_size = 4\n")
        XCTAssertEqual(file.sections.map { $0.glob.pattern }, ["*.h"])
        XCTAssertEqual(file.sections.first?.value(for: "indent_size"), "4")
    }

    /// A typo'd header must not hand its pairs to whatever section was open above
    /// it: `indent_size = 8` below a broken `[*.py` is not a rule for `*.c`.
    func testHeaderWithNoClosingBracketEndsThePrecedingSection() {
        let file = EditorConfigFile(text: "[*.c]\nindent_size = 2\n[*.py\nindent_size = 8\n")
        XCTAssertEqual(file.sections.map { $0.glob.pattern }, ["*.c"])
        XCTAssertEqual(file.sections.first?.pairs.count, 1)
        XCTAssertEqual(file.sections.first?.value(for: "indent_size"), "2")
    }

    /// The preamble ends at the first `[` line whether or not it parsed, so a
    /// `root` below a broken header is not a preamble declaration.
    func testRootBelowAnUnclosedHeaderIsNotHonored() {
        XCTAssertFalse(EditorConfigFile(text: "[*.c\nroot = true\n").isRoot)
    }

    // MARK: - Byte-order mark

    func testLeadingByteOrderMarkDoesNotHideTheFirstSection() {
        let file = EditorConfigFile(text: "\u{FEFF}[*]\nindent_style = space\n")
        XCTAssertEqual(file.sections.map { $0.glob.pattern }, ["*"])
        XCTAssertEqual(file.sections.first?.value(for: "indent_style"), "space")
    }

    func testLeadingByteOrderMarkDoesNotHideRoot() {
        XCTAssertTrue(EditorConfigFile(text: "\u{FEFF}root = true\n[*]\nindent_size = 2\n").isRoot)
    }

    func testSectionsMatchingReturnsEveryMatchInDocumentOrder() {
        let file = EditorConfigFile(text: """
        [*]
        indent_style = space
        [*.py]
        indent_size = 4
        [*.c]
        indent_size = 2
        """)
        XCTAssertEqual(file.sections(matching: "a.c").map { $0.glob.pattern }, ["*", "*.c"])
    }

    // MARK: - Comments

    func testWholeLineCommentsAreSkippedWithBothMarkersAndLeadingWhitespace() {
        let text = """
        # a hash comment
        ; a semicolon comment
            # an indented hash comment
            ; an indented semicolon comment
        [*]
        indent_size = 2
        """
        XCTAssertEqual(pairs(text), [EditorConfigPair(key: "indent_size", value: "2")])
    }

    func testSemicolonInsideAValueIsKeptVerbatim() {
        // The spec's own example of what an inline comment is *not*.
        XCTAssertEqual(value("foo", "[*]\nfoo = a ;)\n"), "a ;)")
    }

    func testHashInsideAValueIsKeptVerbatimWithNoPrecedingSpace() {
        XCTAssertEqual(value("foo", "[*]\nfoo = bar#baz\n"), "bar#baz")
        XCTAssertEqual(value("foo", "[*]\nfoo = bar # baz\n"), "bar # baz")
    }

    func testCommentMarkerInsideASectionNameIsPartOfTheName() {
        XCTAssertEqual(EditorConfigFile(text: "[a#b.c]\nindent_size = 2\n").sections.first?.glob.pattern, "a#b.c")
    }

    // MARK: - Keys and values

    func testWhitespaceAroundKeysAndValuesIsTrimmed() {
        XCTAssertEqual(pairs("[*]\n   indent_size   =   4   \n"),
                       [EditorConfigPair(key: "indent_size", value: "4")])
    }

    func testKeysAreLowercased() {
        XCTAssertEqual(value("indent_style", "[*]\nIndent_Style = space\n"), "space")
    }

    func testKnownValuesAreLowercasedAndUnknownOnesAreVerbatim() {
        XCTAssertEqual(value("indent_style", "[*]\nindent_style = SPACE\n"), "space")
        XCTAssertEqual(value("my_property", "[*]\nmy_property = KeepMyCase\n"), "KeepMyCase")
    }

    func testValueMayContainEqualsSigns() {
        XCTAssertEqual(value("foo", "[*]\nfoo = a=b=c\n"), "a=b=c")
    }

    func testEmptyValueIsKept() {
        XCTAssertEqual(value("foo", "[*]\nfoo =\n"), "")
    }

    func testLineWithNoEqualsSignIsSkippedWithoutLosingTheRest() {
        XCTAssertEqual(pairs("[*]\nnot a pair\nindent_size = 2\n"),
                       [EditorConfigPair(key: "indent_size", value: "2")])
    }

    func testEmptyKeyIsSkipped() {
        XCTAssertEqual(pairs("[*]\n = 2\nindent_size = 2\n"),
                       [EditorConfigPair(key: "indent_size", value: "2")])
    }

    func testDuplicateKeyInOneSectionIsLastWins() {
        XCTAssertEqual(value("indent_size", "[*]\nindent_size = 2\nindent_size = 4\n"), "4")
    }

    func testKeyAtTheLengthCapIsAcceptedAndBeyondItIgnored() {
        let atCap = String(repeating: "k", count: EditorConfigFile.maximumKeyLength)
        let beyondCap = String(repeating: "k", count: EditorConfigFile.maximumKeyLength + 1)
        XCTAssertEqual(value(atCap, "[*]\n\(atCap) = v\n"), "v")
        XCTAssertNil(value(beyondCap, "[*]\n\(beyondCap) = v\n"))
    }

    func testValueAtTheLengthCapIsAcceptedAndBeyondItIgnored() {
        let atCap = String(repeating: "v", count: EditorConfigFile.maximumValueLength)
        let beyondCap = String(repeating: "v", count: EditorConfigFile.maximumValueLength + 1)
        XCTAssertEqual(value("foo", "[*]\nfoo = \(atCap)\n"), atCap)
        XCTAssertNil(value("foo", "[*]\nfoo = \(beyondCap)\n"))
    }

    func testPairsBeforeTheFirstSectionAreNotProperties() {
        XCTAssertTrue(EditorConfigFile(text: "indent_size = 2\n").sections.isEmpty)
    }

    func testCarriageReturnLineEndingsParseTheSameAsNewlines() {
        XCTAssertEqual(value("indent_size", "[*]\r\nindent_size = 2\r\n"), "2")
    }

    // MARK: - The property map

    func testUnknownPropertiesAreCarriedAndReadableCaseInsensitively() {
        let properties = properties("[*]\nMy_Property = Value\n")
        XCTAssertEqual(properties["my_property"], "Value")
        XCTAssertEqual(properties["My_Property"], "Value")
        XCTAssertNil(properties["absent"])
    }

    func testEmptyPropertiesAreEmpty() {
        XCTAssertTrue(EditorConfigProperties().isEmpty)
        XCTAssertNil(EditorConfigProperties().indentStyle)
        XCTAssertNil(EditorConfigProperties().indentSize)
        XCTAssertNil(EditorConfigProperties().tabWidth)
        XCTAssertNil(EditorConfigProperties().indentWidth)
    }

    func testApplyingUnsetRemovesTheProperty() {
        var properties = EditorConfigProperties(["indent_size": "2"])
        properties.apply(EditorConfigPair(key: "indent_size", value: "UNSET"))
        XCTAssertNil(properties["indent_size"])
        XCTAssertTrue(properties.isEmpty)
    }

    func testLaterPairOverwritesEarlierOne() {
        XCTAssertEqual(properties("[*]\nindent_size = 2\n[*.c]\nindent_size = 8\n").indentWidth, 8)
    }

    // MARK: - indent_style

    func testIndentStyleReadsBothWordsAndRejectsAnythingElse() {
        XCTAssertEqual(EditorConfigProperties(["indent_style": "tab"]).indentStyle, .tab)
        XCTAssertEqual(EditorConfigProperties(["indent_style": "space"]).indentStyle, .space)
        XCTAssertNil(EditorConfigProperties(["indent_style": "spaces"]).indentStyle)
        XCTAssertNil(EditorConfigProperties().indentStyle)
    }

    func testIndentStyleIsCaseInsensitiveThroughTheParser() {
        XCTAssertEqual(properties("[*]\nindent_style = Tab\n").indentStyle, .tab)
    }

    // MARK: - indent_size

    func testIndentSizeReadsAPositiveIntegerAndTheWordTab() {
        XCTAssertEqual(EditorConfigProperties(["indent_size": "4"]).indentSize, .width(4))
        XCTAssertEqual(EditorConfigProperties(["indent_size": "tab"]).indentSize, .tab)
    }

    func testIndentSizeRejectsZeroNegativeAndNonNumericValues() {
        XCTAssertNil(EditorConfigProperties(["indent_size": "0"]).indentSize)
        XCTAssertNil(EditorConfigProperties(["indent_size": "-2"]).indentSize)
        XCTAssertNil(EditorConfigProperties(["indent_size": "2.5"]).indentSize)
        XCTAssertNil(EditorConfigProperties(["indent_size": "two"]).indentSize)
        XCTAssertNil(EditorConfigProperties(["indent_size": ""]).indentSize)
    }

    // MARK: - tab_width

    func testTabWidthPrefersItsOwnValue() {
        XCTAssertEqual(EditorConfigProperties(["tab_width": "8", "indent_size": "2"]).tabWidth, 8)
    }

    func testTabWidthDefaultsToANumericIndentSize() {
        XCTAssertEqual(EditorConfigProperties(["indent_size": "2"]).tabWidth, 2)
    }

    func testTabWidthIsNilWhenIndentSizeIsTheWordTab() {
        XCTAssertNil(EditorConfigProperties(["indent_size": "tab"]).tabWidth)
    }

    func testTabWidthRejectsZeroAndNonNumericValues() {
        XCTAssertNil(EditorConfigProperties(["tab_width": "0"]).tabWidth)
        XCTAssertNil(EditorConfigProperties(["tab_width": "wide"]).tabWidth)
    }

    // MARK: - indentWidth (the coupling)

    func testIndentWidthIsTheNumericIndentSize() {
        XCTAssertEqual(EditorConfigProperties(["indent_size": "2", "tab_width": "8"]).indentWidth, 2)
    }

    func testIndentSizeTabDefersToTheExplicitTabWidth() {
        XCTAssertEqual(EditorConfigProperties(["indent_size": "tab", "tab_width": "8"]).indentWidth, 8)
    }

    func testIndentSizeTabWithNoTabWidthHasNoWidth() {
        XCTAssertNil(EditorConfigProperties(["indent_size": "tab"]).indentWidth)
    }

    func testTabWidthAloneDescribesTheWidth() {
        XCTAssertEqual(EditorConfigProperties(["tab_width": "3"]).indentWidth, 3)
    }

    func testAnUnusableIndentSizeLeavesNoWidth() {
        XCTAssertNil(EditorConfigProperties(["indent_size": "0"]).indentWidth)
    }

    // MARK: - end_of_line

    func testEndOfLineReadsEveryNamedValueWithItsTerminator() {
        XCTAssertEqual(EditorConfigProperties(["end_of_line": "lf"]).endOfLine, .lf)
        XCTAssertEqual(EditorConfigProperties(["end_of_line": "cr"]).endOfLine, .cr)
        XCTAssertEqual(EditorConfigProperties(["end_of_line": "crlf"]).endOfLine, .crlf)
        XCTAssertEqual(EditorConfigProperties.EndOfLine.lf.terminator, "\n")
        XCTAssertEqual(EditorConfigProperties.EndOfLine.cr.terminator, "\r")
        XCTAssertEqual(EditorConfigProperties.EndOfLine.crlf.terminator, "\r\n")
    }

    /// An unrecognized value is absent, not an error — the posture the existing
    /// accessors take for a bad `indent_size`. NEL/LS/PS are not in the
    /// property's vocabulary, so naming one leaves the file unnormalized rather
    /// than normalized to something the config never asked for.
    func testEndOfLineIsNilWhenAbsentOrUnrecognized() {
        XCTAssertNil(EditorConfigProperties().endOfLine)
        XCTAssertNil(EditorConfigProperties(["end_of_line": "lfcr"]).endOfLine)
        XCTAssertNil(EditorConfigProperties(["end_of_line": "nel"]).endOfLine)
        XCTAssertNil(EditorConfigProperties(["end_of_line": ""]).endOfLine)
    }

    func testEndOfLineIsCaseInsensitiveThroughTheParser() {
        XCTAssertEqual(properties("[*]\nend_of_line = CRLF\n").endOfLine, .crlf)
    }

    // MARK: - trim_trailing_whitespace and insert_final_newline

    func testTheTwoBooleansReadExactlyTheirTwoLiterals() {
        XCTAssertEqual(EditorConfigProperties(["trim_trailing_whitespace": "true"]).trimTrailingWhitespace, true)
        XCTAssertEqual(EditorConfigProperties(["trim_trailing_whitespace": "false"]).trimTrailingWhitespace, false)
        XCTAssertEqual(EditorConfigProperties(["insert_final_newline": "true"]).insertFinalNewline, true)
        XCTAssertEqual(EditorConfigProperties(["insert_final_newline": "false"]).insertFinalNewline, false)
    }

    func testTheTwoBooleansAreNilWhenAbsentOrUnrecognized() {
        XCTAssertNil(EditorConfigProperties().trimTrailingWhitespace)
        XCTAssertNil(EditorConfigProperties().insertFinalNewline)
        XCTAssertNil(EditorConfigProperties(["trim_trailing_whitespace": "yes"]).trimTrailingWhitespace)
        XCTAssertNil(EditorConfigProperties(["trim_trailing_whitespace": "1"]).trimTrailingWhitespace)
        XCTAssertNil(EditorConfigProperties(["insert_final_newline": "on"]).insertFinalNewline)
        XCTAssertNil(EditorConfigProperties(["insert_final_newline": ""]).insertFinalNewline)
    }

    func testTheTwoBooleansAreCaseInsensitiveThroughTheParser() {
        let properties = properties("[*]\ntrim_trailing_whitespace = True\ninsert_final_newline = FALSE\n")
        XCTAssertEqual(properties.trimTrailingWhitespace, true)
        XCTAssertEqual(properties.insertFinalNewline, false)
    }

    /// `unset` in a closer file undoes an inherited rule, which for these three
    /// must read as "the project states nothing" rather than as `false`.
    func testUnsetRestoresTheAbsentAnswerForAllThree() {
        let properties = properties("""
        [*]
        end_of_line = lf
        trim_trailing_whitespace = true
        insert_final_newline = true
        [*.md]
        end_of_line = unset
        trim_trailing_whitespace = unset
        insert_final_newline = unset
        """)
        XCTAssertNil(properties.endOfLine)
        XCTAssertNil(properties.trimTrailingWhitespace)
        XCTAssertNil(properties.insertFinalNewline)
    }

    func testAnEmptyMapStatesNoneOfTheThreeOnSaveProperties() {
        XCTAssertNil(EditorConfigProperties().endOfLine)
        XCTAssertNil(EditorConfigProperties().trimTrailingWhitespace)
        XCTAssertNil(EditorConfigProperties().insertFinalNewline)
    }
}
