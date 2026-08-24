import Foundation

/// One compiled element of an EditorConfig section glob.
///
/// The vocabulary is EditorConfig's own, which is deliberately **not**
/// gitignore's: `**` is not bound to whole path components, brace alternation
/// and integer ranges exist, and `!`/trailing-`/` carry no meaning at all. That
/// is why this token set lives beside `GitignoreMatcher` instead of inside it.
enum EditorConfigGlobToken: Equatable {
    /// A literal character — possibly the result of a backslash escape, or of a
    /// brace group that turned out to be literal text (`{single}`).
    case literal(Character)
    /// `*` — any run of characters that does not cross a `/`.
    case star
    /// `**` — any run of characters, separators included. Unlike gitignore's
    /// component-bound `**`, this token may stand for part of a component:
    /// `a**z.c` is a legal EditorConfig pattern.
    case doubleStar
    /// `?` — exactly one character, never a `/`.
    case anyOne
    /// `[abc]`, `[a-z]`, `[!abc]`.
    case characterClass(EditorConfigCharacterClass)
    /// `{a,b}` — one of several alternative token sequences, nested arbitrarily.
    case alternation([[EditorConfigGlobToken]])
    /// `{num1..num2}` — any integer between the two bounds, both inclusive.
    case numericRange(lower: Int, upper: Int)
}

/// The members of one `[…]` class: single characters plus ranges, and whether
/// the class is negated (`[!…]`/`[^…]`, both spellings, as the reference
/// implementations accept both by handing the class to a regex engine).
///
/// The `a-z` bound pair is `GlobCharacterRange`, reused from the gitignore
/// matcher because it is a bare inclusive character range — a value, not a
/// matching rule; nothing about the two dialects' disagreements touches it.
struct EditorConfigCharacterClass: Equatable {
    var negated: Bool
    var singles: Set<Character>
    var ranges: [GlobCharacterRange]

    func contains(_ character: Character) -> Bool {
        let member = singles.contains(character) || ranges.contains { $0.contains(character) }
        return negated ? !member : member
    }
}

/// One EditorConfig section name, compiled once into tokens and asked
/// repeatedly whether it matches a path.
///
/// The path handed to `matches(relativePath:)` is `/`-separated and relative to
/// the directory holding the `.editorconfig` that spelled this section, which is
/// what makes the whole dialect expressible without ever seeing an absolute
/// path.
///
/// Preprocessing follows the spec: a pattern containing no unescaped `/` matches
/// **at any depth** (as if written `**/pattern`, where the `**/` may stand for
/// zero directories, which is why it is a flag here rather than an injected
/// token); any other pattern is anchored to that directory, and a leading `/` is
/// dropped before compiling.
///
/// `?` excludes `/` here. This is a deliberate choice in a place where the
/// reference implementations disagree: the spec says "any single character", and
/// some cores translate `?` to a regex `.` that happily crosses a separator.
/// Pisaka treats `?` like `*`'s single-character sibling, so a one-character
/// wildcard can never silently reach into another directory.
///
/// The spec requires a core to accept section names of up to 1024 characters;
/// that required floor is taken as the cap, so a longer section name compiles to
/// nothing and never matches.
public struct EditorConfigGlob: Equatable {
    /// The longest section name that is honored (the spec's acceptance floor).
    public static let maximumSectionNameLength = 1024

    /// The section name exactly as it was written between `[` and `]`.
    public let pattern: String
    /// The pattern named a `/`, so it is relative to the `.editorconfig`'s own
    /// directory instead of matching at any depth below it.
    public let anchored: Bool
    /// `true` when the section name is longer than the honored cap; such a glob
    /// matches nothing.
    public let exceedsLengthLimit: Bool

    /// The match-ready form.
    let tokens: [EditorConfigGlobToken]

    public init(pattern: String) {
        self.pattern = pattern
        self.exceedsLengthLimit = pattern.count > EditorConfigGlob.maximumSectionNameLength

        var characters = Array(pattern)
        // Anchoring is judged before the leading `/` is dropped, and an escaped
        // `\/` does not anchor anything.
        let anchored = EditorConfigGlob.containsUnescapedSlash(characters)
        if anchored, characters.first == "/" { characters.removeFirst() }
        self.anchored = anchored
        self.tokens = exceedsLengthLimit ? [] : EditorConfigGlobCompiler.compile(characters)
    }

    /// Whether this section applies to `relativePath`, spelled with `/` and
    /// relative to the directory holding the `.editorconfig`.
    public func matches(relativePath: String) -> Bool {
        guard !exceedsLengthLimit else { return false }
        var path = relativePath
        if path.hasPrefix("/") { path.removeFirst() }
        let characters = Array(path)

        if EditorConfigGlob.match(tokens, from: 0, characters, from: 0) { return true }
        guard !anchored else { return false }
        // Unanchored ⇒ "at any depth": the pattern may start at the beginning of
        // any component. An unanchored pattern names no `/`, so trying each
        // component start is exactly what a leading `**/` would express.
        for index in characters.indices where characters[index] == "/" {
            if EditorConfigGlob.match(tokens, from: 0, characters, from: index + 1) { return true }
        }
        return false
    }

    /// `tokens` is derived from `pattern`, so the source is the identity.
    public static func == (lhs: EditorConfigGlob, rhs: EditorConfigGlob) -> Bool {
        lhs.pattern == rhs.pattern
    }

    static func containsUnescapedSlash(_ characters: [Character]) -> Bool {
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == "/" { return true }
            index += 1
        }
        return false
    }

    // MARK: - Matching

    /// Recursive backtracking match of `tokens[tokenIndex...]` against
    /// `characters[characterIndex...]`, both of which must be consumed whole.
    ///
    /// Backtracking rather than the gitignore matcher's dynamic-programming walk
    /// because nested alternation and integer ranges make the state space a tree
    /// rather than a grid; section names are bounded at 1024 characters, so the
    /// worst case is bounded with them.
    static func match(
        _ tokens: [EditorConfigGlobToken],
        from tokenIndex: Int,
        _ characters: [Character],
        from characterIndex: Int
    ) -> Bool {
        var tokenIndex = tokenIndex
        var characterIndex = characterIndex
        while tokenIndex < tokens.count {
            switch tokens[tokenIndex] {
            case .literal(let expected):
                guard characterIndex < characters.count, characters[characterIndex] == expected else { return false }
            case .anyOne:
                guard characterIndex < characters.count, characters[characterIndex] != "/" else { return false }
            case .characterClass(let characterClass):
                guard characterIndex < characters.count,
                      characterClass.contains(characters[characterIndex]) else { return false }
            case .star, .doubleStar:
                let crossesSeparators = tokens[tokenIndex] == .doubleStar
                return matchWildcard(
                    tokens, after: tokenIndex, characters, from: characterIndex,
                    crossesSeparators: crossesSeparators
                )
            case .alternation(let branches):
                return matchAlternation(branches, tokens, after: tokenIndex, characters, from: characterIndex)
            case .numericRange(let lower, let upper):
                return matchNumericRange(
                    lower: lower, upper: upper,
                    tokens, after: tokenIndex, characters, from: characterIndex
                )
            }
            tokenIndex += 1
            characterIndex += 1
        }
        return characterIndex == characters.count
    }

    /// `*`/`**`: try every run length from the shortest up, stopping at a `/`
    /// unless the token is allowed to cross one.
    private static func matchWildcard(
        _ tokens: [EditorConfigGlobToken],
        after tokenIndex: Int,
        _ characters: [Character],
        from characterIndex: Int,
        crossesSeparators: Bool
    ) -> Bool {
        var end = characterIndex
        while true {
            if match(tokens, from: tokenIndex + 1, characters, from: end) { return true }
            guard end < characters.count else { return false }
            if !crossesSeparators, characters[end] == "/" { return false }
            end += 1
        }
    }

    /// `{a,b}`: each branch is spliced in front of what follows the group, so a
    /// branch that matches but leaves the rest unmatchable falls through to the
    /// next one.
    private static func matchAlternation(
        _ branches: [[EditorConfigGlobToken]],
        _ tokens: [EditorConfigGlobToken],
        after tokenIndex: Int,
        _ characters: [Character],
        from characterIndex: Int
    ) -> Bool {
        let rest = Array(tokens[(tokenIndex + 1)...])
        return branches.contains { match($0 + rest, from: 0, characters, from: characterIndex) }
    }

    /// `{num1..num2}`: an optional `-` and a run of digits whose value falls
    /// inside the (inclusive) bounds. Longest run first, then shorter ones, so
    /// `{1..2}0` still matches `10` while a bare `{1..2}` refuses it.
    private static func matchNumericRange(
        lower: Int,
        upper: Int,
        _ tokens: [EditorConfigGlobToken],
        after tokenIndex: Int,
        _ characters: [Character],
        from characterIndex: Int
    ) -> Bool {
        var digitsStart = characterIndex
        if digitsStart < characters.count, characters[digitsStart] == "-" { digitsStart += 1 }
        var end = digitsStart
        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }

        var length = end
        while length > digitsStart {
            if let value = Int(String(characters[characterIndex..<length])),
               value >= lower, value <= upper,
               match(tokens, from: tokenIndex + 1, characters, from: length) {
                return true
            }
            length -= 1
        }
        return false
    }
}

/// The section-name compiler: source characters in, `EditorConfigGlobToken`s
/// out, once per section rather than once per path.
enum EditorConfigGlobCompiler {
    /// Compiles a whole (already de-anchored) section name.
    static func compile(_ characters: [Character]) -> [EditorConfigGlobToken] {
        var index = 0
        return parse(characters, from: &index, insideBraces: false)
    }

    /// Parses a token sequence, stopping at a `,` or `}` when it is the body of
    /// a brace group (where both are structural rather than literal).
    static func parse(
        _ characters: [Character],
        from index: inout Int,
        insideBraces: Bool
    ) -> [EditorConfigGlobToken] {
        var tokens: [EditorConfigGlobToken] = []
        while index < characters.count {
            let character = characters[index]
            if insideBraces, character == "," || character == "}" { break }
            switch character {
            case "\\":
                index += 1
                if index < characters.count {
                    tokens.append(.literal(characters[index]))
                    index += 1
                } else {
                    // A trailing lone backslash is a literal backslash.
                    tokens.append(.literal("\\"))
                }
            case "*":
                var stars = 0
                while index < characters.count, characters[index] == "*" {
                    stars += 1
                    index += 1
                }
                tokens.append(stars >= 2 ? .doubleStar : .star)
            case "?":
                tokens.append(.anyOne)
                index += 1
            case "[":
                if let (characterClass, next) = parseCharacterClass(characters, from: index) {
                    tokens.append(.characterClass(characterClass))
                    index = next
                } else {
                    // An unclosed `[` is an ordinary character.
                    tokens.append(.literal("["))
                    index += 1
                }
            case "{":
                tokens.append(contentsOf: parseBraceGroup(characters, from: &index))
            default:
                tokens.append(.literal(character))
                index += 1
            }
        }
        return tokens
    }

    // MARK: - Braces

    /// Parses the group starting at the `{` under `index`, leaving `index` just
    /// past the group. A group with no matching `}` — and one holding neither a
    /// comma nor a `..` — is literal text, braces included.
    private static func parseBraceGroup(
        _ characters: [Character],
        from index: inout Int
    ) -> [EditorConfigGlobToken] {
        guard let close = matchingBrace(characters, from: index) else {
            index += 1
            return [.literal("{")]
        }
        let body = Array(characters[(index + 1)..<close])
        if containsTopLevelComma(body) {
            var cursor = index + 1
            var branches: [[EditorConfigGlobToken]] = []
            while cursor <= close {
                branches.append(parse(characters, from: &cursor, insideBraces: true))
                guard cursor < close else { break }
                cursor += 1 // step over the `,`
            }
            index = close + 1
            return [.alternation(branches)]
        }
        if let range = numericRange(body) {
            index = close + 1
            return [.numericRange(lower: range.0, upper: range.1)]
        }
        index = close + 1
        return literalTokens(forBraceBody: body)
    }

    /// The index of the `}` closing the `{` at `start`, honoring nesting and
    /// backslash escapes, or `nil` when the group never closes.
    private static func matchingBrace(_ characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index += 1
        }
        return nil
    }

    /// Whether the group body holds a comma of its own, rather than one
    /// belonging to a nested group or escaped into a literal.
    private static func containsTopLevelComma(_ body: [Character]) -> Bool {
        var depth = 0
        var index = 0
        while index < body.count {
            switch body[index] {
            case "\\":
                index += 1
            case "{":
                depth += 1
            case "}":
                depth -= 1
            case "," where depth == 0:
                return true
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// `num1..num2` with both bounds parsed as integers (a leading `-` allowed),
    /// or `nil` when the body is not an integer range — in which case the group
    /// is literal text, as a group holding no comma at all is.
    private static func numericRange(_ body: [Character]) -> (Int, Int)? {
        guard let dots = (0..<max(body.count - 1, 0)).first(where: { body[$0] == "." && body[$0 + 1] == "." }) else {
            return nil
        }
        guard let lower = integer(Array(body[0..<dots])),
              let upper = integer(Array(body[(dots + 2)...])) else { return nil }
        return (lower, upper)
    }

    /// A strict integer: an optional `-`, then ASCII digits and nothing else.
    private static func integer(_ characters: [Character]) -> Int? {
        var digits = characters
        if digits.first == "-" { digits.removeFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(String(characters))
    }

    /// A literal group (`{single}`, `{}`, `{a..b}`) is its own text, braces
    /// included; escapes inside it are still resolved.
    private static func literalTokens(forBraceBody body: [Character]) -> [EditorConfigGlobToken] {
        var tokens: [EditorConfigGlobToken] = [.literal("{")]
        var index = 0
        while index < body.count {
            if body[index] == "\\", index + 1 < body.count { index += 1 }
            tokens.append(.literal(body[index]))
            index += 1
        }
        tokens.append(.literal("}"))
        return tokens
    }

    // MARK: - Character classes

    /// Parses `[…]` starting at the `[` under `start`, returning the class and
    /// the index just past the closing `]`, or `nil` when it never closes.
    private static func parseCharacterClass(
        _ characters: [Character],
        from start: Int
    ) -> (EditorConfigCharacterClass, Int)? {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }
        var singles: Set<Character> = []
        var ranges: [GlobCharacterRange] = []
        // A `]` in the first member position is a literal, not the terminator.
        var isFirst = true
        while index < characters.count {
            let character = characters[index]
            if character == "]", !isFirst {
                return (EditorConfigCharacterClass(negated: negated, singles: singles, ranges: ranges), index + 1)
            }
            isFirst = false

            var member = character
            if character == "\\", index + 1 < characters.count {
                index += 1
                member = characters[index]
            }
            // `a-z`, but a `-` just before the closing `]` is a literal dash.
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                var upper = characters[index + 2]
                var consumed = index + 2
                if upper == "\\", consumed + 1 < characters.count {
                    consumed += 1
                    upper = characters[consumed]
                }
                ranges.append(GlobCharacterRange(lower: member, upper: upper))
                index = consumed + 1
                continue
            }
            singles.insert(member)
            index += 1
        }
        return nil
    }
}
