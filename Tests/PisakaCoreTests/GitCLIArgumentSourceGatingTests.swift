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
///   spelling `"--encoding=UTF-8"`, neither set empty, and every `"--pretty`
///   literal sits inside one of them (an array the reader skips cannot escape
///   the rule); and neither
///   `--show-signature` nor `log.showSignature=true` is spelled anywhere,
///   because signature text corrupts `Commit.parse`'s hash field
///   (`CommitParserTests`).
/// - **The prompt-suppressing commands** (`testTheCommandsThatMayPromptSuppressTheTerminalPrompt`):
///   the set of functions whose bodies spell `"GIT_TERMINAL_PROMPT": "0"` is exactly
///   `{fetch, push, pull, commit, headText, checkout, createAndCheckout, restoreFromHead}` — the
///   commands that reach a remote, or run hooks or filters that may
///   (`headText`'s `--filters` and every checkout run smudge filters, and an
///   LFS smudge may fetch; `restoreFromHead` is the revert's path restore, named
///   apart from `checkout` because the reader joins same-named bodies, so one
///   overload carrying the variable would cover for the other). A set, not a count, so it is
///   the one place that number lives (`GitHubSourceGatingTests` defers here).
/// - **Every checkout is terminated** (`testEveryCheckoutEndsItsRevisionsWithATerminator`):
///   the array literals spelling `"checkout"` are exactly the three expected
///   spellings — the two branch checkouts ending in `"--"`, plus the path
///   restore's `HEAD -- path` — and every `"checkout"` literal in the file
///   sits inside one of them.
/// - **Blame ignores whitespace and follows in-file moves, not copies**
///   (`testBlameIgnoresWhitespaceAndFollowsMovesWithinTheFile`): the one
///   `"blame"` array spells `"-w"` and `"-M"` and no `"-C"` in any form.
/// - **One status command reports what git ignores**
///   (`testTheOneStatusCommandReportsIgnoredPaths`): exactly one array literal
///   spells `"--ignored=matching"`, that literal also spells `"status"`, and no
///   other text in the file spells `--ignored` in any form. The status run is
///   spelled once so `changedFiles` and the tree's snapshot cannot drift apart,
///   and the one mode named is `matching` — `traditional` would list every file
///   inside an ignored directory, and `no` would leave the tree nothing to dim.
/// - **The project watcher refreshes Local Changes, ungated**
///   (`testTheProjectWatcherRefreshesLocalChangesUngated`): the one
///   `projectWatcher.start(` call in `Sources/Pisaka/PisakaApp.swift` hands a
///   callback whose body calls the model's `refreshForDiskChange(` — the entry
///   point that neither supersedes a running revert nor clears its error — and
///   names neither `autosave.suspend()` nor `beginRevert()`. It lives here because it leans on
///   the first rule: that refresh cannot feed the watcher only because every
///   `git` it runs carries `--no-optional-locks`. Its subject is a call, not a
///   literal, so it reads that file through
///   `LSPSourceGatingTests.strippingCommentsAndStringLiterals` — the callback's
///   own comment names the call it asks for.
final class GitCLIArgumentSourceGatingTests: XCTestCase {
    private static let serviceURL = RepositorySources.url("Sources/Pisaka/GitCLIService.swift")

    private static let appURL = serviceURL
        .deletingLastPathComponent()
        .appendingPathComponent("PisakaApp.swift")

    /// The service with comments stripped and literals kept.
    private func service() throws -> String {
        GitHubSourceGatingTests.strippingComments(try RepositorySources.raw(Self.serviceURL))
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
        let elements = literal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(
            elements, ["\"--no-optional-locks\"", "\"-c\"", "\"log.showSignature=false\""],
            "globalOptions is exactly these three tokens in this order — without its -c, git would read "
                + "log.showSignature=false as the subcommand"
        )
    }

    func testEveryPrettySiteForcesUTF8() throws {
        let code = try service()
        let arrays = arrayLiterals(in: code)
        let pretty = Set(arrays.filter { $0.contains("\"--pretty") })
        let encoded = Set(arrays.filter { $0.contains("\"--encoding=UTF-8\"") })
        XCTAssertFalse(pretty.isEmpty, "no --pretty site found — re-point this rule rather than losing it")
        XCTAssertEqual(pretty, encoded, "every --pretty array, and only those, passes --encoding=UTF-8")
        XCTAssertEqual(
            occurrences(of: "\"--pretty", in: code), pretty.count,
            "every --pretty literal sits inside an array this rule reads"
        )
        for banned in ["--show-signature", "log.showSignature=true"] {
            XCTAssertEqual(
                occurrences(of: banned, in: code), 0,
                "\(banned) prints signature text into the --pretty records Commit.parse reads"
            )
        }
    }

    func testTheCommandsThatMayPromptSuppressTheTerminalPrompt() throws {
        let bodies = try functionBodies(in: try service())
        let prompting = Set(bodies.filter { $0.value.contains("\"GIT_TERMINAL_PROMPT\": \"0\"") }.keys)
        XCTAssertEqual(
            prompting,
            ["fetch", "push", "pull", "commit", "headText", "checkout", "createAndCheckout", "restoreFromHead"],
            "exactly the commands that reach a remote, or run hooks or filters that may, pass "
                + "GIT_TERMINAL_PROMPT=0 — a credential prompt on /dev/tty would wedge the shared serial queue"
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

    func testTheOneStatusCommandReportsIgnoredPaths() throws {
        let code = try service()
        let ignoring = arrayLiterals(in: code).filter { $0.contains("\"--ignored=matching\"") }
        XCTAssertEqual(ignoring.count, 1, "one status command line carries --ignored=matching")
        XCTAssertTrue(
            ignoring.first?.contains("\"status\"") ?? false,
            "the --ignored=matching array is the status command, so the snapshot and changedFiles share one run"
        )
        XCTAssertEqual(
            occurrences(of: "--ignored", in: code), 1,
            "no other literal spells --ignored in any form — a second mode or a second status run would "
                + "let the tree's ignored set and the changed-file list come from different answers"
        )
    }

    /// The first `{ … }` block at or after `index`, braces balanced.
    private static func braced(after index: String.Index, in text: String) -> String? {
        guard let open = text[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        for current in text[open...].indices {
            if text[current] == "{" { depth += 1 }
            if text[current] == "}" { depth -= 1 }
            if depth == 0 { return String(text[open...current]) }
        }
        return nil
    }

    func testTheProjectWatcherRefreshesLocalChangesUngated() throws {
        let app = try RepositorySources.stripped(Self.appURL)
        XCTAssertEqual(
            occurrences(of: "projectWatcher.start(", in: app), 1,
            "one watcher subscription — re-point this rule if that changes"
        )
        let start = try XCTUnwrap(app.range(of: "projectWatcher.start("))
        let callback = try XCTUnwrap(Self.braced(after: start.upperBound, in: app), "the watcher's callback is gone")
        XCTAssertEqual(
            occurrences(of: "localChanges.refreshForDiskChange(", in: callback), 1,
            "an edit made outside the app reaches Local Changes only through the watcher's refresh, "
                + "and through the entry point that leaves a revert's error standing"
        )
        for gate in ["autosave.suspend()", "beginRevert()"] {
            XCTAssertFalse(callback.contains(gate), "the watcher's refresh is a reader and raises no writer gate")
        }
    }
}
