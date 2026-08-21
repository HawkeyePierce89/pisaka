import XCTest
@testable import PisakaCore

final class FileNameTests: XCTestCase {
    func testRejectsEmpty() {
        XCTAssertFalse(isValidFileName(""))
    }

    func testRejectsWhitespaceOnly() {
        XCTAssertFalse(isValidFileName("   "))
        XCTAssertFalse(isValidFileName("\t"))
        XCTAssertFalse(isValidFileName("\n"))
        XCTAssertFalse(isValidFileName(" \t \n "))
    }

    func testRejectsPathSeparator() {
        XCTAssertFalse(isValidFileName("foo/bar"))
        XCTAssertFalse(isValidFileName("/foo"))
        XCTAssertFalse(isValidFileName("foo/"))
        XCTAssertFalse(isValidFileName("a/b/c.txt"))
    }

    func testRejectsNulByte() {
        XCTAssertFalse(isValidFileName("foo\0bar"))
    }

    func testAcceptsOrdinaryNames() {
        XCTAssertTrue(isValidFileName("file.txt"))
        XCTAssertTrue(isValidFileName("README"))
        XCTAssertTrue(isValidFileName("My Document.md"))
        XCTAssertTrue(isValidFileName("Package.swift"))
    }

    func testAcceptsDotfiles() {
        XCTAssertTrue(isValidFileName(".gitignore"))
        XCTAssertTrue(isValidFileName(".env"))
    }

    func testRejectsDirectoryNavigationNames() {
        // "." and ".." reference existing directories, not a new single entry.
        XCTAssertFalse(isValidFileName("."))
        XCTAssertFalse(isValidFileName(".."))
        XCTAssertFalse(isValidFileName("  .  "))
        XCTAssertFalse(isValidFileName(" .. "))
    }

    func testAcceptsNamesWithSurroundingWhitespace() {
        // The documented contract allows surrounding whitespace in an otherwise
        // non-blank name; callers trim as they see fit.
        XCTAssertTrue(isValidFileName(" foo "))
        XCTAssertTrue(isValidFileName("foo.txt "))
    }

    func testAcceptsMultiDotNames() {
        // Only the exact "." / ".." are navigation names; these are ordinary.
        XCTAssertTrue(isValidFileName("..."))
        XCTAssertTrue(isValidFileName("a.b.c"))
        XCTAssertTrue(isValidFileName(".hidden.txt"))
    }

    // MARK: - parseRelativeEntryPath

    func testParsesNestedPath() {
        XCTAssertEqual(parseRelativeEntryPath("a/b/c.json"), ["a", "b", "c.json"])
        XCTAssertEqual(parseRelativeEntryPath("centrifugo/config.json"), ["centrifugo", "config.json"])
    }

    func testParsesSingleNameWithoutSlash() {
        // Backwards compatible with the old single-name dialogs.
        XCTAssertEqual(parseRelativeEntryPath("file.txt"), ["file.txt"])
        XCTAssertEqual(parseRelativeEntryPath(".gitignore"), [".gitignore"])
    }

    func testToleratesExactlyOneTrailingSlash() {
        XCTAssertEqual(parseRelativeEntryPath("a/b/"), ["a", "b"])
        XCTAssertEqual(parseRelativeEntryPath("a/"), ["a"])
        // The whole input is trimmed first, so a padded trailing slash is still
        // just a trailing slash.
        XCTAssertEqual(parseRelativeEntryPath("a/   "), ["a"])
    }

    func testRejectsLeadingSlash() {
        // A leading slash makes it absolute, not relative to the directory.
        XCTAssertNil(parseRelativeEntryPath("/a/b"))
        XCTAssertNil(parseRelativeEntryPath("/"))
    }

    func testRejectsEmptyInteriorComponent() {
        XCTAssertNil(parseRelativeEntryPath("a//b"))
    }

    func testRejectsTwoTrailingSlashes() {
        XCTAssertNil(parseRelativeEntryPath("a//"))
        XCTAssertNil(parseRelativeEntryPath("a/b//"))
    }

    func testRejectsWhitespaceOnlyComponent() {
        // The seam between per-component trimming and the empty-component rule.
        XCTAssertNil(parseRelativeEntryPath("a/ /b"))
        XCTAssertNil(parseRelativeEntryPath("a/\t/b"))
        XCTAssertNil(parseRelativeEntryPath("a/ /"))
    }

    func testRejectsNavigationComponents() {
        XCTAssertNil(parseRelativeEntryPath("a/../b"))
        XCTAssertNil(parseRelativeEntryPath("a/./b"))
        XCTAssertNil(parseRelativeEntryPath(".."))
        XCTAssertNil(parseRelativeEntryPath("."))
        XCTAssertNil(parseRelativeEntryPath("a/.."))
    }

    func testRejectsReservedComponents() {
        XCTAssertNil(parseRelativeEntryPath("x/.git/y"))
        XCTAssertNil(parseRelativeEntryPath("x/.DS_Store"))
        XCTAssertNil(parseRelativeEntryPath(".git"))
    }

    func testRejectsReservedComponentsCaseInsensitively() {
        // A case-insensitive volume resolves these onto the real service entry.
        XCTAssertNil(parseRelativeEntryPath("x/.GIT/y"))
        XCTAssertNil(parseRelativeEntryPath("x/.Ds_Store"))
        XCTAssertNil(parseRelativeEntryPath(".Git/y"))
    }

    func testTrimsEachComponent() {
        XCTAssertEqual(parseRelativeEntryPath(" a / b.txt "), ["a", "b.txt"])
        XCTAssertEqual(parseRelativeEntryPath("  file.txt  "), ["file.txt"])
    }

    func testRejectsEmptyAndBlankInput() {
        XCTAssertNil(parseRelativeEntryPath(""))
        XCTAssertNil(parseRelativeEntryPath("   "))
        XCTAssertNil(parseRelativeEntryPath("\t\n"))
    }

    func testRejectsNulInComponent() {
        XCTAssertNil(parseRelativeEntryPath("a/b\0c"))
        XCTAssertNil(parseRelativeEntryPath("a\0b"))
    }

    func testRejectsSeparatorHiddenInsideAGraphemeCluster() {
        // A combining mark fuses with the preceding "/" into one grapheme
        // cluster, so a Character-level scan sees no separator — yet the name
        // still produces a real "/" in the on-disk path, landing the entry in a
        // directory the user never named. Both predicates must scan scalars.
        let hidden = "a/\u{0338}b"
        XCTAssertEqual(hidden.count, 3, "precondition: the slash is inside a cluster")
        XCTAssertFalse(isValidFileName(hidden))
        // It parses as a path, not as one component: the separator is real.
        XCTAssertEqual(parseRelativeEntryPath(hidden), ["a", "\u{0338}b"])
        // The split is scalar-exact, so both separators are seen; a lone
        // combining mark is an odd but legal entry name, not an empty component.
        XCTAssertEqual(parseRelativeEntryPath("a/\u{0338}/b"), ["a", "\u{0338}", "b"])
    }

    func testAcceptsNonReservedDotfileComponents() {
        // Only the two service names are reserved; ordinary dotfiles pass.
        XCTAssertEqual(parseRelativeEntryPath(".github/workflows/ci.yml"),
                       [".github", "workflows", "ci.yml"])
        XCTAssertEqual(parseRelativeEntryPath("a/.gitignore"), ["a", ".gitignore"])
    }

    // MARK: - EntryPathIssue messages

    func testEveryIssueCaseCarriesANonEmptyMessage() {
        let all: [EntryPathIssue] = [
            .emptyInput,
            .emptyComponent,
            .navigationComponent(".."),
            .separatorInName,
            .lineBreak,
            .nulCharacter,
            .reservedComponent(".git")
        ]
        for issue in all {
            XCTAssertFalse(issue.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(issue) must carry a user-facing reason")
        }
    }

    func testReservedComponentMessageNamesTheOffendingComponent() {
        XCTAssertTrue(EntryPathIssue.reservedComponent(".git").message.contains(".git"))
        XCTAssertTrue(EntryPathIssue.reservedComponent(".DS_Store").message.contains(".DS_Store"))
    }

    func testNavigationComponentMessageNamesTheOffendingComponent() {
        // Quoted, so "." and ".." stay distinguishable in the message.
        XCTAssertTrue(EntryPathIssue.navigationComponent(".").message.contains("\".\""))
        XCTAssertTrue(EntryPathIssue.navigationComponent("..").message.contains("\"..\""))
        XCTAssertFalse(EntryPathIssue.navigationComponent(".").message.contains("\"..\""))
    }

    func testSeparatorInNameMessageSaysSingleNameNotPath() {
        let message = EntryPathIssue.separatorInName.message
        XCTAssertTrue(message.contains("single name"))
        XCTAssertTrue(message.contains("path"))
    }

    // MARK: - validateRelativeEntryPath

    func testValidatePathAcceptsOrdinaryPaths() {
        XCTAssertNil(validateRelativeEntryPath("file.txt"))
        XCTAssertNil(validateRelativeEntryPath("a/b/c.json"))
        XCTAssertNil(validateRelativeEntryPath("a/b/"))
        XCTAssertNil(validateRelativeEntryPath(".github/workflows/ci.yml"))
    }

    func testValidatePathReportsEmptyInput() {
        XCTAssertEqual(validateRelativeEntryPath(""), .emptyInput)
        XCTAssertEqual(validateRelativeEntryPath("   "), .emptyInput)
        XCTAssertEqual(validateRelativeEntryPath("\t\n"), .emptyInput)
    }

    func testValidatePathReportsEmptyComponent() {
        XCTAssertEqual(validateRelativeEntryPath("/a/b"), .emptyComponent)
        XCTAssertEqual(validateRelativeEntryPath("a//b"), .emptyComponent)
        XCTAssertEqual(validateRelativeEntryPath("a//"), .emptyComponent)
        XCTAssertEqual(validateRelativeEntryPath("a/ /b"), .emptyComponent)
        XCTAssertEqual(validateRelativeEntryPath("/"), .emptyComponent)
    }

    func testValidatePathReportsNavigationComponent() {
        XCTAssertEqual(validateRelativeEntryPath("a/../b"), .navigationComponent(".."))
        XCTAssertEqual(validateRelativeEntryPath("a/./b"), .navigationComponent("."))
        XCTAssertEqual(validateRelativeEntryPath(".."), .navigationComponent(".."))
    }

    func testValidatePathReportsReservedComponentInAnyCasing() {
        XCTAssertEqual(validateRelativeEntryPath("x/.git/y"), .reservedComponent(".git"))
        // The offending component is reported as the user spelled it.
        XCTAssertEqual(validateRelativeEntryPath("x/.GIT/y"), .reservedComponent(".GIT"))
        XCTAssertEqual(validateRelativeEntryPath("x/.DS_Store"), .reservedComponent(".DS_Store"))
    }

    func testValidatePathReportsNulCharacter() {
        XCTAssertEqual(validateRelativeEntryPath("a\0b"), .nulCharacter)
        XCTAssertEqual(validateRelativeEntryPath("a/b\0c"), .nulCharacter)
    }

    func testValidatePathReportsLineBreakInsideAComponent() {
        // Only reachable by paste — the dialog's Enter never inserts a newline.
        XCTAssertEqual(validateRelativeEntryPath("a\nb"), .lineBreak)
        XCTAssertEqual(validateRelativeEntryPath("a/b\rc"), .lineBreak)
        XCTAssertEqual(validateRelativeEntryPath("a\u{2028}b"), .lineBreak)
        // A *surrounding* line break is trimmed away, so it is not an issue.
        XCTAssertNil(validateRelativeEntryPath("a\n"))
        XCTAssertNil(validateRelativeEntryPath("\na/b\n"))
    }

    func testValidatePathDetectsEveryLineBreakScalar() {
        // The rule is `CharacterSet.newlines`, not just LF — a pasted CRLF is the
        // commonest shape and is one grapheme carrying two scalars.
        for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(
                validateRelativeEntryPath("a\(separator)b"), .lineBreak,
                "expected .lineBreak for U+\(separator.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+"))"
            )
        }
    }

    func testValidatePathTrimsALineBreakAtAComponentBoundary() {
        // Components are trimmed *after* the split, so a break falling exactly on
        // a separator is surrounding whitespace for both neighbours rather than an
        // interior one: `a/\nb` names `a/b`, it does not report `.lineBreak`.
        XCTAssertNil(validateRelativeEntryPath("a/\nb"))
        XCTAssertEqual(parseRelativeEntryPath("a/\nb"), ["a", "b"])
    }

    func testValidatePathReportsTheFirstOffendingComponent() {
        // Two violations in one input: the earlier component's issue wins.
        XCTAssertEqual(validateRelativeEntryPath("../.git"), .navigationComponent(".."))
        XCTAssertEqual(validateRelativeEntryPath(".git/.."), .reservedComponent(".git"))
        XCTAssertEqual(validateRelativeEntryPath("a//b\nc"), .emptyComponent)
    }

    func testValidateNameReportsSeparatorBeforeAnyOtherComponentIssue() {
        // A `/` is judged up front, before the shared component rule, so it wins
        // over a line break or a navigation name appearing in the same input.
        XCTAssertEqual(validateSingleEntryName("a/b\nc"), .separatorInName)
        XCTAssertEqual(validateSingleEntryName("../x"), .separatorInName)
    }

    func testValidateNameDetectsEveryLineBreakScalar() {
        for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(validateSingleEntryName("a\(separator)b"), .lineBreak)
        }
    }

    // MARK: - validateSingleEntryName

    func testValidateNameAcceptsOrdinaryNames() {
        XCTAssertNil(validateSingleEntryName("file.txt"))
        XCTAssertNil(validateSingleEntryName(".gitignore"))
        XCTAssertNil(validateSingleEntryName("My Document.md"))
        XCTAssertNil(validateSingleEntryName(" foo "))
        XCTAssertNil(validateSingleEntryName("..."))
    }

    func testValidateNameReportsSeparatorInName() {
        // Rename takes one name, not a path — a "/" is never a valid separator
        // here, not even the trailing one `parseRelativeEntryPath` tolerates.
        XCTAssertEqual(validateSingleEntryName("a/b"), .separatorInName)
        XCTAssertEqual(validateSingleEntryName("/foo"), .separatorInName)
        XCTAssertEqual(validateSingleEntryName("foo/"), .separatorInName)
        XCTAssertEqual(validateSingleEntryName("/"), .separatorInName)
        // The separator hidden inside a grapheme cluster is a real separator.
        XCTAssertEqual(validateSingleEntryName("a/\u{0338}b"), .separatorInName)
    }

    func testValidateNameReportsNavigationComponent() {
        XCTAssertEqual(validateSingleEntryName("."), .navigationComponent("."))
        XCTAssertEqual(validateSingleEntryName(".."), .navigationComponent(".."))
        XCTAssertEqual(validateSingleEntryName("  .  "), .navigationComponent("."))
        XCTAssertEqual(validateSingleEntryName(" .. "), .navigationComponent(".."))
    }

    func testValidateNameReportsReservedNames() {
        XCTAssertEqual(validateSingleEntryName(".git"), .reservedComponent(".git"))
        XCTAssertEqual(validateSingleEntryName(".DS_Store"), .reservedComponent(".DS_Store"))
    }

    func testValidateNameUsesExactMatchReservedSemantics() {
        // Rename's post-OK guard is `FileService.isExcludedEntryName` (exact
        // match): a user's own `.Git` folder is an ordinary entry the tree shows,
        // so the dialog must not block a name that guard would accept.
        XCTAssertTrue(FileService.isExcludedEntryName(".git"))
        XCTAssertFalse(FileService.isExcludedEntryName(".Git"))
        XCTAssertNil(validateSingleEntryName(".Git"))
        XCTAssertNil(validateSingleEntryName(".GIT"))
        XCTAssertNil(validateSingleEntryName(".Ds_Store"))
    }

    func testValidateNameReportsEmptyInput() {
        XCTAssertEqual(validateSingleEntryName(""), .emptyInput)
        XCTAssertEqual(validateSingleEntryName(" "), .emptyInput)
        XCTAssertEqual(validateSingleEntryName("\t\n"), .emptyInput)
    }

    func testValidateNameReportsNulCharacter() {
        XCTAssertEqual(validateSingleEntryName("a\0b"), .nulCharacter)
    }

    func testValidateNameReportsLineBreak() {
        // Only reachable by paste — the dialog's Enter never inserts a newline.
        XCTAssertEqual(validateSingleEntryName("a\nb"), .lineBreak)
        XCTAssertEqual(validateSingleEntryName("a\rb"), .lineBreak)
        XCTAssertEqual(validateSingleEntryName("a\u{2028}b"), .lineBreak)
        // A *surrounding* line break is trimmed away, so it is not an issue.
        XCTAssertNil(validateSingleEntryName("a\n"))
        XCTAssertNil(validateSingleEntryName("\nfoo.txt\n"))
    }

    // MARK: - isValidFileName/validateSingleEntryName parity

    func testNamePredicateAndValidatorAgreeExceptOnReservedNames() {
        let inputs = [
            // valid
            "file.txt", "README", "My Document.md", "Package.swift", ".gitignore",
            ".env", " foo ", "foo.txt ", "...", "a.b.c", ".hidden.txt",
            ".Git", ".GIT", ".Ds_Store", "a\n", "\nfoo.txt\n",
            // empty input
            "", "   ", "\t", "\n", " \t \n ",
            // separator
            "foo/bar", "/foo", "foo/", "a/b/c.txt", "/", "a/\u{0338}b",
            // navigation
            ".", "..", "  .  ", " .. ",
            // NUL
            "foo\0bar", "a\0b",
            // line break
            "a\nb", "a\rb", "a\u{2028}b"
        ]
        for input in inputs {
            let issue = validateSingleEntryName(input)
            // `isValidFileName` deliberately does not judge reserved names — the
            // rename call site checks those separately.
            if case .reservedComponent = issue { continue }
            XCTAssertEqual(isValidFileName(input), issue == nil,
                           "predicate/validator disagree on \(String(reflecting: input)): "
                               + "isValidFileName=\(isValidFileName(input)), issue=\(String(describing: issue))")
        }
    }

    func testNamePredicateDoesNotJudgeReservedNames() {
        XCTAssertTrue(isValidFileName(".git"))
        XCTAssertTrue(isValidFileName(".DS_Store"))
        XCTAssertEqual(validateSingleEntryName(".git"), .reservedComponent(".git"))
    }

    func testNamePredicateRejectsLineBreaks() {
        // Deliberate tightening: a pasted `a\nb` used to be accepted and created
        // an entry with a newline in its name.
        XCTAssertFalse(isValidFileName("a\nb"))
        XCTAssertFalse(isValidFileName("a\rb"))
    }

    // MARK: - parser/validator parity

    func testParserAndValidatorAgreeOnEveryInput() {
        let inputs = [
            // valid
            "file.txt", ".gitignore", "a/b/c.json", "centrifugo/config.json",
            "a/b/", "a/", "a/   ", " a / b.txt ", "  file.txt  ",
            ".github/workflows/ci.yml", "a/.gitignore", "...", "a.b.c", ".hidden.txt",
            "a/\u{0338}b", "a/\u{0338}/b", "a\n", "\na/b\n",
            // empty input
            "", "   ", "\t\n",
            // empty component
            "/a/b", "/", "a//b", "a//", "a/b//", "a/ /b", "a/\t/b", "a/ /",
            // navigation component
            "a/../b", "a/./b", "..", ".", "a/..", "  .  ", " .. ",
            // reserved component
            "x/.git/y", "x/.DS_Store", ".git", "x/.GIT/y", "x/.Ds_Store", ".Git/y",
            // NUL
            "a/b\0c", "a\0b",
            // line break inside a component
            "a\nb", "a/b\rc", "a\u{2028}b"
        ]
        for input in inputs {
            let parsed = parseRelativeEntryPath(input)
            let issue = validateRelativeEntryPath(input)
            XCTAssertEqual(parsed != nil, issue == nil,
                           "parser/validator disagree on \(String(reflecting: input)): "
                               + "parsed=\(String(describing: parsed)), issue=\(String(describing: issue))")
        }
    }
}
