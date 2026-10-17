import XCTest

/// Static verification of the command lines the macOS `GitCLIService` hands to
/// `git`.
///
/// A repository-file suite: it reads `Sources/Pisaka/GitCLIService.swift`
/// through `#filePath` with Foundation only. That file is compiled **only by the
/// app target** — `swift test` never builds it — so an argument dropped from
/// one of its arrays compiles, ships green, and is discovered by the person
/// whose repository it misbehaved in. Every subject here is a **string
/// literal** (`"--no-optional-locks"`, `"--"`, `"-M"`), so the suite reads
/// `GitHubSourceGatingTests.strippingComments(_:)` — comments removed, literals
/// kept — for that stated reason: the usual
/// `LSPSourceGatingTests.strippingCommentsAndStringLiterals` would delete the
/// very text every rule checks. Comments are still stripped because the file's
/// doc comments quote these flags while explaining them.
///
/// The rules, each invisible to the compiler:
///
/// - **One funnel, one prefix** (`testEveryCommandCarriesTheGlobalOptions`):
///   `Process()` is constructed once in the file and `process.arguments` is
///   assigned once, from `["git"] + Self.globalOptions + arguments`, and
///   `globalOptions` holds `"--no-optional-locks"` and
///   `"log.showSignature=false"`. So no command — read or write, today's or a
///   future one — launches without them.
/// - **Every `--pretty` site re-encodes** (`testEveryPrettySiteForcesUTF8`):
///   the array literals spelling `"--pretty` are, by set equality, the ones
///   spelling `"--encoding=UTF-8"`, neither set empty; and neither
///   `--show-signature` nor `log.showSignature=true` is spelled anywhere,
///   because signature text corrupts `Commit.parse`'s hash field
///   (`CommitParserTests`).
/// - **The prompt-suppressing commands** (`testTheNetworkCommandsSuppressTheTerminalPrompt`):
///   the set of functions whose bodies spell `GIT_TERMINAL_PROMPT` is exactly
///   `{fetch, push, pull, commit}` — the commands that reach a remote or run
///   hooks that may. A set, not a count, so it is the one place that number
///   lives (`GitHubSourceGatingTests` defers here).
/// - **Every checkout is terminated** (`testEveryCheckoutEndsItsRevisionsWithATerminator`):
///   the array literals spelling `"checkout"` are exactly the three expected
///   spellings — the two branch checkouts ending in `"--"`, plus the path
///   restore's `HEAD -- path` — and every `"checkout"` literal in the file
///   sits inside one of them.
/// - **Blame ignores whitespace and follows in-file moves, not copies**
///   (`testBlameIgnoresWhitespaceAndFollowsMovesWithinTheFile`): the one
///   `"blame"` array spells `"-w"` and `"-M"` and no `"-C"` in any form.
final class GitCLIArgumentSourceGatingTests: XCTestCase {
    private static let serviceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>
        .appendingPathComponent("Sources/Pisaka/GitCLIService.swift")

    /// The service with comments stripped and literals kept.
    private func service() throws -> String {
        GitHubSourceGatingTests.strippingComments(try String(contentsOf: Self.serviceURL, encoding: .utf8))
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The innermost bracketed literals of `code` — `[` … `]` pairs with no
    /// bracket of their own outside a string — whose contents spell at least
    /// one string literal, each with its whitespace collapsed to single spaces.
    /// Brackets inside a string literal are text, not structure.
    private func arrayLiterals(in code: String) -> [String] {
        var literals: [String] = []
        var openings: [(index: String.Index, nested: Bool)] = []
        var inString = false
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            if inString {
                if character == "\\" {
                    index = code.index(after: index)
                } else if character == "\"" || character == "\n" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                if !openings.isEmpty { openings[openings.count - 1].nested = true }
                openings.append((index, false))
            } else if character == "]", let opening = openings.popLast(), !opening.nested {
                let body = code[code.index(after: opening.index)..<index]
                if body.contains("\"") {
                    literals.append(body.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                }
            }
            if index < code.endIndex { index = code.index(after: index) }
        }
        return literals
    }

    /// The body (braces included) of every `func` in `code`, keyed by name.
    /// Overloads share a name, so their bodies are concatenated.
    private func functionBodies(in code: String) throws -> [String: String] {
        let declaration = try NSRegularExpression(pattern: "\\bfunc (\\w+)")
        var bodies: [String: String] = [:]
        for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let name = Range(match.range(at: 1), in: code),
                  let open = code[name.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0
            var inString = false
            var index = open
            while index < code.endIndex {
                let character = code[index]
                if inString {
                    if character == "\\" {
                        index = code.index(after: index)
                    } else if character == "\"" || character == "\n" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if index < code.endIndex { index = code.index(after: index) }
            }
            let end = index < code.endIndex ? code.index(after: index) : code.endIndex
            bodies[String(code[name]), default: ""] += code[open..<end]
        }
        return bodies
    }

    func testTheReadersSeeWhatTheyClaimTo() throws {
        XCTAssertEqual(
            arrayLiterals(in: "f([\"a\", x, \"[b]\"]) + [[\"c\"], [\"d\"]] + y[i]"),
            ["\"a\", x, \"[b]\"", "\"c\"", "\"d\""]
        )
        let bodies = try functionBodies(in: "func a() { if x { \"}\" } }\nfunc b() { y }")
        XCTAssertEqual(bodies["a"], "{ if x { \"}\" } }")
        XCTAssertEqual(bodies["b"], "{ y }")
    }

    func testEveryCommandCarriesTheGlobalOptions() throws {
        let code = try service()
        XCTAssertEqual(
            occurrences(of: "Process()", in: code), 1,
            "GitCLIService constructs one Process, in runBlocking — a second launch path would skip the prefix"
        )
        XCTAssertEqual(
            occurrences(of: "process.arguments", in: code), 1,
            "process.arguments is assigned once, in the funnel"
        )
        XCTAssertEqual(
            occurrences(of: "process.arguments = [\"git\"] + Self.globalOptions + arguments", in: code), 1,
            "the funnel prefixes every command with globalOptions"
        )
        let definition = try XCTUnwrap(
            code.range(of: "private static let globalOptions = ["),
            "globalOptions is gone — re-point this rule rather than losing it"
        )
        let literal = try XCTUnwrap(code[definition.upperBound...].split(separator: "]").first)
        for option in ["\"--no-optional-locks\"", "\"log.showSignature=false\""] {
            XCTAssertTrue(literal.contains(option), "globalOptions must carry \(option)")
        }
    }

    func testEveryPrettySiteForcesUTF8() throws {
        let code = try service()
        let arrays = arrayLiterals(in: code)
        let pretty = Set(arrays.filter { $0.contains("\"--pretty") })
        let encoded = Set(arrays.filter { $0.contains("\"--encoding=UTF-8\"") })
        XCTAssertFalse(pretty.isEmpty, "no --pretty site found — re-point this rule rather than losing it")
        XCTAssertEqual(pretty, encoded, "every --pretty array, and only those, passes --encoding=UTF-8")
        for banned in ["--show-signature", "log.showSignature=true"] {
            XCTAssertEqual(
                occurrences(of: banned, in: code), 0,
                "\(banned) prints signature text into the --pretty records Commit.parse reads"
            )
        }
    }

    func testTheNetworkCommandsSuppressTheTerminalPrompt() throws {
        let bodies = try functionBodies(in: try service())
        let prompting = Set(bodies.filter { $0.value.contains("GIT_TERMINAL_PROMPT") }.keys)
        XCTAssertEqual(
            prompting, ["fetch", "push", "pull", "commit"],
            "exactly the commands that reach a remote or run hooks pass GIT_TERMINAL_PROMPT=0 — a credential "
                + "prompt on /dev/tty would wedge the shared serial queue"
        )
    }

    func testEveryCheckoutEndsItsRevisionsWithATerminator() throws {
        let code = try service()
        let checkouts = arrayLiterals(in: code).filter { $0.contains("\"checkout\"") }
        XCTAssertEqual(
            Set(checkouts),
            [
                "\"checkout\", branch, \"--\"",
                "\"checkout\", \"-b\", name, startPoint, \"--\"",
                "\"checkout\", \"HEAD\", \"--\", path",
            ],
            "a branch checkout without \"--\" lets a same-named path win: a stale name restores that path over "
                + "its unstaged edits, and a tracking-only name is refused as ambiguous"
        )
        XCTAssertEqual(
            occurrences(of: "\"checkout\"", in: code), checkouts.count,
            "every \"checkout\" literal sits inside one of the terminated arrays"
        )
        XCTAssertTrue(checkouts.allSatisfy { $0.contains("\"--\"") })
    }

    func testBlameIgnoresWhitespaceAndFollowsMovesWithinTheFile() throws {
        let blames = arrayLiterals(in: try service()).filter { $0.contains("\"blame\"") }
        XCTAssertEqual(blames.count, 1, "one blame command line — re-point this rule if that changes")
        let blame = try XCTUnwrap(blames.first)
        XCTAssertTrue(blame.contains("\"-w\""), "blame ignores whitespace-only changes")
        XCTAssertTrue(blame.contains("\"-M\""), "blame follows lines moved within the file")
        XCTAssertFalse(
            blame.contains("\"-C"),
            "no -C: it is expensive and would attribute lines to commits in other files"
        )
    }
}
