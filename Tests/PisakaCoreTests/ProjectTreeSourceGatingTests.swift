import XCTest

/// Static verification that every `onChange` in the project tree's view file
/// uses the two-argument form.
///
/// A repository-file suite in the `DrawDirtyRectSourceGatingTests` mould: it
/// reads `Sources/Pisaka/ProjectTreeView.swift` through `RepositorySources`,
/// so **comments and string literals are stripped before anything is
/// matched**. The file's comments quote the old form on purpose — the reveal,
/// `shape` and `separated` handlers each explain why they are not the
/// one-argument `onChange` — and a reference to "the tree's
/// `onChange(of: projectRoot)`" sits in a comment too, so a raw reading would
/// count sites that are not code.
///
/// What is checked, and why:
///
/// - **Every `onChange` closure names exactly two parameters.** The
///   one-argument form's action reads the *previous* update's captured
///   values: a reveal handler read a `reveal` still `nil` for an on-screen
///   row, and a reshaped chain listed its old tail (`TreeChainReshapeTests`).
///   Not every site reads a captured value, but the file keeps one form so a
///   new handler copies the safe one. For each `onChange` followed by `(`
///   (whitespace allowed, so a call wrapped over several lines is found), the
///   argument list is taken by parenthesis balancing and must be followed by
///   `{`; the closure's text up to its first whole-word `in` must be a
///   parameter list of exactly two comma-separated names. A closure with no
///   `in` before any other code — the zero-argument form — fails too.
/// - **At least one site is found**, so the check cannot pass vacuously
///   against a renamed file or a scanner that stopped matching.
/// - **The scanner catches each wrong form.** `testTheScannerJudgesEachForm`
///   pins the one-argument, zero-argument and two-argument forms, wrapped and
///   unwrapped, against literal snippets.
///
/// **The horizon.** Only this file is read: the tree is where the
/// one-argument form bit twice. A trailing closure is the only shape judged;
/// an action passed as a labelled argument (`onChange(of: x, perform: f)`)
/// has no `{` after the argument list and fails as a missing closure, which is
/// the conservative answer.
final class ProjectTreeSourceGatingTests: XCTestCase {

    private static let treePath = "Sources/Pisaka/ProjectTreeView.swift"

    func testEveryOnChangeInTheTreeTakesTwoArguments() throws {
        let code = try RepositorySources.stripped(at: Self.treePath)
        let sites = Self.onChangeSites(in: code)
        XCTAssertFalse(sites.isEmpty, "found no onChange in \(Self.treePath) — the scanner or the path drifted")
        for site in sites {
            XCTAssertEqual(
                site.parameterCount, 2,
                "\(Self.treePath):\(site.line) — onChange closure is not the two-argument form "
                    + "({ _, newValue in … } / { _, _ in … }); the one-argument form reads the previous update's values"
            )
        }
    }

    func testTheScannerJudgesEachForm() {
        let cases: [(snippet: String, count: Int?)] = [
            (".onChange(of: value) { _, newValue in use(newValue) }", 2),
            (".onChange(of: value) { _, _ in reload() }", 2),
            (".onChange(of: value, initial: true) { (old, new) in use(new) }", 2),
            (".onChange(\n    of: frame(in: .named(space)).minY, initial: true\n) { _, minY in scroll(minY) }", 2),
            (".onChange(of: value) { newValue in use(newValue) }", 1),
            (".onChange (of: value) { _ in reload() }", 1),
            (".onChange(of: value) { reload() }", nil),
            (".onChange(of: value) { items.map { x in x } }", nil),
            (".onChange(of: value, perform: reload)", nil),
        ]
        for (snippet, count) in cases {
            let sites = Self.onChangeSites(in: snippet)
            XCTAssertEqual(sites.count, 1, "the onChange in `\(snippet)` was not found")
            XCTAssertEqual(sites.first?.parameterCount, count, "`\(snippet)` was judged wrongly")
        }
        XCTAssertTrue(Self.onChangeSites(in: "func onChanged(of x: Int) {}\nlet onChangeCount = 1").isEmpty)
    }

    // MARK: - Scanner

    /// One `onChange` call: the 1-based line it starts on, and how many
    /// parameters its trailing closure names (`nil` when there is no trailing
    /// closure or no parameter list).
    struct Site {
        let line: Int
        let parameterCount: Int?
    }

    static func onChangeSites(in code: String) -> [Site] {
        let characters = Array(code)
        let keyword = Array("onChange")
        var sites: [Site] = []
        var index = 0
        while index + keyword.count <= characters.count {
            guard characters[index..<(index + keyword.count)].elementsEqual(keyword),
                  index == 0 || !isIdentifier(characters[index - 1])
            else {
                index += 1
                continue
            }
            var cursor = skipWhitespace(characters, from: index + keyword.count)
            guard cursor < characters.count, characters[cursor] == "(" else {
                index += keyword.count
                continue
            }
            let line = characters[..<index].filter { $0 == "\n" }.count + 1
            guard let close = matching(characters, openAt: cursor, open: "(", close: ")") else {
                sites.append(Site(line: line, parameterCount: nil))
                break
            }
            cursor = skipWhitespace(characters, from: close + 1)
            let count = cursor < characters.count && characters[cursor] == "{"
                ? parameterCount(characters, closureOpenAt: cursor)
                : nil
            sites.append(Site(line: line, parameterCount: count))
            index = close + 1
        }
        return sites
    }

    /// The names before the closure's first whole-word `in`, when everything
    /// before it is a parameter list (names, commas, whitespace, one pair of
    /// parentheses); `nil` otherwise.
    private static func parameterCount(_ characters: [Character], closureOpenAt open: Int) -> Int? {
        let end = matching(characters, openAt: open, open: "{", close: "}") ?? characters.count
        var cursor = open + 1
        var header = ""
        while cursor < end {
            let character = characters[cursor]
            if character == "i", cursor + 1 < end, characters[cursor + 1] == "n",
               !isIdentifier(characters[cursor - 1]),
               cursor + 2 >= characters.count || !isIdentifier(characters[cursor + 2]) {
                var list = header.trimmingCharacters(in: .whitespacesAndNewlines)
                if list.hasPrefix("("), list.hasSuffix(")") { list = String(list.dropFirst().dropLast()) }
                let names = list.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard names.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isIdentifier) }) else { return nil }
                return names.count
            }
            guard isIdentifier(character) || character == "," || character == "(" || character == ")"
                    || character.isWhitespace
            else { return nil }
            header.append(character)
            cursor += 1
        }
        return nil
    }

    private static func matching(_ characters: [Character], openAt open: Int, open opener: Character,
                                 close closer: Character) -> Int? {
        var depth = 0
        for position in open..<characters.count {
            if characters[position] == opener {
                depth += 1
            } else if characters[position] == closer {
                depth -= 1
                if depth == 0 { return position }
            }
        }
        return nil
    }

    private static func skipWhitespace(_ characters: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}
