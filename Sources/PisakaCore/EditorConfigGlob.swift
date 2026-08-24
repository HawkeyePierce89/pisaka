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

    /// The most match steps **one whole resolution** may take before further
    /// answers degrade to "does not match".
    ///
    /// The length cap above does **not** bound the backtracking match: its cost
    /// is exponential in the *number of wildcards*, not linear in the pattern's
    /// length, and a 24-character section name like `*a*a*a*a*a*a*a*a*a*a*b.c`
    /// against a 42-character path takes tens of seconds. `properties(for:)` is
    /// synchronous and is asked from inside the Enter and Tab key handlers, and
    /// a `.editorconfig` is untrusted content from a cloned repository — so the
    /// bound has to be a real budget rather than a claim about lengths. Bailing
    /// out to "no match" is the same degradation an over-long section name
    /// already gets, and the ceiling is far above what any honest pattern costs.
    ///
    /// **Scoped to the resolution, not to the pair.** Nothing caps how many
    /// sections a `.editorconfig` may declare, nor how many configs the outward
    /// walk reads, so a per-pair budget multiplies by both: fifty copies of one
    /// pathological section name cost fifty times the ceiling on a single
    /// keystroke. `EditorConfigResolver.resolve` therefore allocates one budget
    /// and threads it through every file and every section; the pair-level entry
    /// point below keeps its own budget only for callers asking a single
    /// question (tests, and any future one-off).
    static let maximumMatchSteps = 200_000

    /// The most compile steps **one section name** may take before it degrades
    /// to "does not match".
    ///
    /// The length cap bounds compilation no better than it bounds matching, and
    /// for the same reason: cost is not linear in the pattern's length. The
    /// compiler scans *forward* to find each group's closing `}` and each
    /// class's closing `]`, so a name built of nested openers — `{{{{…` or
    /// `[[[[…` — costs O(n²): at the 1024-character cap that is ~500k character
    /// steps for one section, and the 1 MB read cap admits a thousand such
    /// sections in a single file (~0.9 s of main-thread work, measured). The
    /// model caches *resolved properties*, not parsed files, and the watcher
    /// drops that cache on any project write, so the cost is paid again on the
    /// next keystroke rather than once per session.
    ///
    /// Scoped per **section**, unlike `maximumMatchSteps`'s per-resolution
    /// budget: compilation happens in `init`, which the file parser calls for
    /// each section with no budget to thread through, and the quadratic lives
    /// *inside* one section — so bounding each one bounds a whole file at
    /// (sections × this), which the read cap already holds to ~1000. The ceiling
    /// is eight times the length cap: far above the ~4n an honest pattern
    /// spends, far below the n² a crafted one wants.
    static let maximumCompileSteps = 8 * maximumSectionNameLength

    /// The section name exactly as it was written between `[` and `]`.
    public let pattern: String
    /// The pattern named a `/`, so it is relative to the `.editorconfig`'s own
    /// directory instead of matching at any depth below it.
    public let anchored: Bool
    /// `true` when the section name is longer than the honored cap; such a glob
    /// matches nothing.
    public let exceedsLengthLimit: Bool

    /// `true` when compiling the section name ran out of `maximumCompileSteps`;
    /// such a glob matches nothing, exactly as an over-long one does.
    let exceedsCompileBudget: Bool

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
        // The budget is spent, not merely watched: a step is charged before it is
        // taken, so a name that finishes on the last one lands at exactly zero and
        // only an *over*-spend (below zero) degrades the section.
        var budget = EditorConfigGlob.maximumCompileSteps
        self.tokens = exceedsLengthLimit ? [] : EditorConfigGlobCompiler.compile(characters, budget: &budget)
        self.exceedsCompileBudget = budget < 0
    }

    /// Whether this section applies to `relativePath`, spelled with `/` and
    /// relative to the directory holding the `.editorconfig`.
    public func matches(relativePath: String) -> Bool {
        var budget = EditorConfigGlob.maximumMatchSteps
        return matches(relativePath: relativePath, budget: &budget)
    }

    /// The same question against a budget the *caller* owns, so one resolution —
    /// every section of every `.editorconfig` on the walk — is bounded as a
    /// whole rather than once per pair (see `maximumMatchSteps`).
    func matches(relativePath: String, budget: inout Int) -> Bool {
        guard !exceedsLengthLimit, !exceedsCompileBudget else { return false }
        var path = relativePath
        if path.hasPrefix("/") { path.removeFirst() }
        let characters = Array(path)

        // One budget for the whole question, so a pattern cannot buy itself more
        // work by having many component starts to try.
        if EditorConfigGlob.match(tokens, from: 0, characters, from: 0, budget: &budget) { return true }
        guard !anchored else { return false }
        // Unanchored ⇒ "at any depth": the pattern may start at the beginning of
        // any component. An unanchored pattern names no `/`, so trying each
        // component start is exactly what a leading `**/` would express.
        for index in characters.indices where characters[index] == "/" {
            if EditorConfigGlob.match(tokens, from: 0, characters, from: index + 1, budget: &budget) {
                return true
            }
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
    /// rather than a grid. That tree is *not* bounded by the section-name length
    /// cap, so `budget` bounds it instead: every token step spends one, and an
    /// exhausted budget answers "does not match" (see `maximumMatchSteps`).
    static func match(
        _ tokens: [EditorConfigGlobToken],
        from tokenIndex: Int,
        _ characters: [Character],
        from characterIndex: Int,
        budget: inout Int
    ) -> Bool {
        var tokenIndex = tokenIndex
        var characterIndex = characterIndex
        while tokenIndex < tokens.count {
            guard budget > 0 else { return false }
            budget -= 1
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
                // `/**/` may stand for *zero* directories, which the reference
                // core spells by translating that whole sequence to `(\/|\/.*\/)`.
                // The wildcard below always consumes the trailing `/`, so without
                // this the two commonest section names in the wild — `[**/*.md]`
                // and `[src/**/*.ts]` — would silently refuse `README.md` and
                // `src/index.ts`. Skipping both the `**` and the `/` after it is
                // exactly the "zero directories" branch; it applies only where the
                // pattern really spells `/**/` (or opens with `**/`, where the
                // directory holding the `.editorconfig` plays the leading `/`).
                if crossesSeparators,
                   tokenIndex + 1 < tokens.count, tokens[tokenIndex + 1] == .literal("/"),
                   tokenIndex == 0 || tokens[tokenIndex - 1] == .literal("/"),
                   match(tokens, from: tokenIndex + 2, characters, from: characterIndex, budget: &budget) {
                    return true
                }
                return matchWildcard(
                    tokens, after: tokenIndex, characters, from: characterIndex,
                    crossesSeparators: crossesSeparators, budget: &budget
                )
            case .alternation(let branches):
                return matchAlternation(
                    branches, tokens, after: tokenIndex, characters, from: characterIndex, budget: &budget
                )
            case .numericRange(let lower, let upper):
                return matchNumericRange(
                    lower: lower, upper: upper,
                    tokens, after: tokenIndex, characters, from: characterIndex, budget: &budget
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
        crossesSeparators: Bool,
        budget: inout Int
    ) -> Bool {
        var end = characterIndex
        while true {
            if match(tokens, from: tokenIndex + 1, characters, from: end, budget: &budget) { return true }
            guard end < characters.count, budget > 0 else { return false }
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
        from characterIndex: Int,
        budget: inout Int
    ) -> Bool {
        let rest = Array(tokens[(tokenIndex + 1)...])
        for branch in branches {
            // The splice is the one place where a "step" is not constant-cost:
            // building `branch + rest` copies up to the whole compiled pattern —
            // with ARC traffic for the nested payloads — on *every* attempt, so a
            // budget that charged one step per attempt would under-count the real
            // work by the pattern's length. Charging the copy is what keeps the
            // ceiling a ceiling: `{a,aa}`×18 followed by 900 literals otherwise
            // spends 0.6 s inside a keystroke while staying well under the
            // length cap.
            budget -= branch.count + rest.count
            guard budget > 0 else { return false }
            if match(branch + rest, from: 0, characters, from: characterIndex, budget: &budget) { return true }
            guard budget > 0 else { return false }
        }
        return false
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
        from characterIndex: Int,
        budget: inout Int
    ) -> Bool {
        var digitsStart = characterIndex
        if digitsStart < characters.count, characters[digitsStart] == "-" { digitsStart += 1 }
        var end = digitsStart
        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }

        var length = end
        while length > digitsStart {
            if let value = Int(String(characters[characterIndex..<length])),
               value >= lower, value <= upper,
               match(tokens, from: tokenIndex + 1, characters, from: length, budget: &budget) {
                return true
            }
            guard budget > 0 else { return false }
            length -= 1
        }
        return false
    }
}

/// The section-name compiler: source characters in, `EditorConfigGlobToken`s
/// out, once per section rather than once per path.
enum EditorConfigGlobCompiler {
    /// Spends `steps` of the compile budget, answering `false` once it is gone.
    ///
    /// Every forward scan the compiler makes is charged for what it actually
    /// costs — the alternative, charging the *worst case* before each scan,
    /// would refuse an honest pattern carrying many sibling groups, none of
    /// which scans past its own `}` (see `maximumCompileSteps`).
    private static func spend(_ budget: inout Int, _ steps: Int = 1) -> Bool {
        budget -= steps
        return budget >= 0
    }

    /// Compiles a whole (already de-anchored) section name.
    ///
    /// A budget over-spend abandons the parse where it stands; the caller reads
    /// the exhaustion off `budget` and makes the whole section match nothing, so
    /// the half-built token list it gets back here is never consulted.
    static func compile(_ characters: [Character], budget: inout Int) -> [EditorConfigGlobToken] {
        var index = 0
        return parse(characters, from: &index, insideBraces: false, budget: &budget)
    }

    /// Parses a token sequence, stopping at a `,` or `}` when it is the body of
    /// a brace group (where both are structural rather than literal).
    static func parse(
        _ characters: [Character],
        from index: inout Int,
        insideBraces: Bool,
        budget: inout Int
    ) -> [EditorConfigGlobToken] {
        var tokens: [EditorConfigGlobToken] = []
        while index < characters.count {
            guard spend(&budget) else { return tokens }
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
                if let (characterClass, next) = parseCharacterClass(characters, from: index, budget: &budget) {
                    tokens.append(.characterClass(characterClass))
                    index = next
                } else {
                    // An unclosed `[` is an ordinary character.
                    tokens.append(.literal("["))
                    index += 1
                }
            case "{":
                tokens.append(contentsOf: parseBraceGroup(characters, from: &index, budget: &budget))
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
        from index: inout Int,
        budget: inout Int
    ) -> [EditorConfigGlobToken] {
        guard let close = matchingBrace(characters, from: index, budget: &budget) else {
            index += 1
            return [.literal("{")]
        }
        let body = Array(characters[(index + 1)..<close])
        // One charge covers the body copy above and the three single-pass reads
        // of it below (`containsTopLevelComma`, `numericRange`, `literalTokens`),
        // none of which can exceed the body's own length; that they are not
        // charged individually understates the cost by a small constant factor,
        // which the ceiling absorbs. Without this, nesting alone — every level
        // copying and re-reading the level below — is quadratic.
        guard spend(&budget, body.count) else {
            index = characters.count
            return []
        }
        if containsTopLevelComma(body) {
            var cursor = index + 1
            var branches: [[EditorConfigGlobToken]] = []
            while cursor <= close {
                branches.append(parse(characters, from: &cursor, insideBraces: true, budget: &budget))
                // An exhausted budget stops the walk here rather than stepping the
                // cursor over every remaining character for branches that will each
                // return empty: the answer is already "matches nothing".
                guard cursor < close, budget >= 0 else { break }
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
    private static func matchingBrace(_ characters: [Character], from start: Int, budget: inout Int) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            guard spend(&budget) else { return nil }
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
        from start: Int,
        budget: inout Int
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
            guard spend(&budget) else { return nil }
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
