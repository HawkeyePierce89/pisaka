import Foundation

/// One `.gitignore` line in parsed form.
///
/// The four things a line can say — "re-include" (`!`), "anchored to this
/// `.gitignore`'s own directory" (a `/` anywhere but the trailing position),
/// "directories only" (a trailing `/`), and the per-component globs themselves —
/// are decided once at parse time, so matching a path is a walk over already
/// compiled tokens rather than a re-reading of the source text.
///
/// The grammar follows gitignore(5) and git's own `dir.c`/`wildmatch.c`:
/// * a blank line, or one whose first character is `#`, is not a pattern
///   (`\#`/`\!` escape those two leading characters);
/// * trailing **spaces** are stripped unless escaped with a backslash (git strips
///   spaces only — a trailing tab stays part of the name);
/// * `*` matches any run of characters *within one path component*, `?` exactly
///   one, `[a-z]`/`[!a-z]`/`[^a-z]` a character class, and a backslash escapes
///   the next character;
/// * `**` as a whole component matches zero or more components — except as the
///   *last* component, where it matches one or more (git's `abc/**` matches what
///   is inside `abc`, not `abc` itself);
/// * an unanchored pattern matches at any depth, i.e. exactly as if it were
///   written `**/pattern`, which is how it is compiled.
///
/// There is deliberately no "leading period" rule: unlike shell globbing, `*`
/// matches a dotfile, as git's `wildmatch` does.
public struct GitignorePattern {
    /// A `!` line: a match re-*includes* the path instead of excluding it.
    public let negated: Bool
    /// The pattern is relative to the directory holding the `.gitignore`, rather
    /// than matching at any depth below it.
    public let anchored: Bool
    /// A trailing `/`: the pattern matches directories only.
    public let directoryOnly: Bool
    /// The per-component source globs, with `!`, a leading `/` and the trailing
    /// `/` already removed (`!build/foo/` → `["build", "foo"]`).
    public let components: [String]

    /// The match-ready form: `components` compiled to tokens, with the trailing
    /// `**` and unanchored expansions already applied.
    let compiled: [PatternComponent]

    /// Parses one `.gitignore` line, or `nil` when the line is not a pattern
    /// (blank, whitespace-only, a comment, or nothing but the `!`/`/` markers).
    public init?(line rawLine: String) {
        var chars = Array(GitignorePattern.trimmingTrailingSpaces(rawLine))
        guard let first = chars.first, first != "#" else { return nil }

        var negated = false
        if first == "!" {
            negated = true
            chars.removeFirst()
        }
        guard !chars.isEmpty else { return nil }

        var directoryOnly = false
        if chars.last == "/" {
            directoryOnly = true
            chars.removeLast()
        }
        guard !chars.isEmpty else { return nil }

        // Anchoring is judged *before* the leading `/` is dropped, so `/build` is
        // anchored (git's `PATTERN_FLAG_NODIR` test) while `build` is not.
        let anchored = chars.contains("/")
        let components = String(chars)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return nil }

        var compiled: [PatternComponent] = components.map {
            $0 == "**" ? .doubleStar : .glob(Glob.compile($0))
        }
        // A trailing `**` matches *one* or more components: `abc/**` covers what
        // is inside `abc` but not `abc` itself. One `*` component in front of it
        // spells that without a second `**` rule in the matcher.
        if compiled.last == .doubleStar {
            compiled.insert(.glob([.star]), at: compiled.count - 1)
        }
        if !anchored {
            compiled.insert(.doubleStar, at: 0)
        }

        self.negated = negated
        self.anchored = anchored
        self.directoryOnly = directoryOnly
        self.components = components
        self.compiled = compiled
    }

    /// Whether this pattern matches the path spelled by `pathComponents`
    /// (relative to the directory holding the `.gitignore`).
    public func matches(pathComponents: [String], isDirectory: Bool) -> Bool {
        guard !pathComponents.isEmpty else { return false }
        if directoryOnly && !isDirectory { return false }
        return GitignorePattern.match(compiled, against: pathComponents)
    }

    // MARK: - Matching

    /// Component-wise match with `**` support, as a dynamic-programming walk
    /// rather than recursive backtracking: `O(pattern × path)` regardless of how
    /// many `**`s a pattern piles up.
    static func match(_ pattern: [PatternComponent], against path: [String]) -> Bool {
        let m = pattern.count
        let n = path.count
        guard m > 0 else { return n == 0 }

        // `previous[j]` = the first `i` pattern components match the first `j`
        // path components.
        var previous = [Bool](repeating: false, count: n + 1)
        previous[0] = true
        for i in 1...m {
            var current = [Bool](repeating: false, count: n + 1)
            switch pattern[i - 1] {
            case .doubleStar:
                current[0] = previous[0]
                if n > 0 {
                    for j in 1...n { current[j] = previous[j] || current[j - 1] }
                }
            case .glob(let tokens):
                if n > 0 {
                    for j in 1...n {
                        current[j] = previous[j - 1] && Glob.matches(tokens: tokens, name: path[j - 1])
                    }
                }
            }
            previous = current
        }
        return previous[n]
    }

    // MARK: - Line trimming

    /// git's `trim_trailing_spaces` verbatim: drop the trailing run of **spaces**
    /// unless a backslash escapes one of them (a backslash always consumes the
    /// next character, so `foo\ ` keeps its space while `foo   ` does not).
    static func trimmingTrailingSpaces(_ line: String) -> String {
        let chars = Array(line)
        var lastSpace: Int?
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case " ":
                if lastSpace == nil { lastSpace = i }
            case "\\":
                i += 1
                guard i < chars.count else { return String(chars) }
                lastSpace = nil
            default:
                lastSpace = nil
            }
            i += 1
        }
        guard let lastSpace else { return String(chars) }
        return String(chars[0..<lastSpace])
    }
}

extension GitignorePattern: Equatable {
    /// `compiled` is derived from the other fields, so comparing the parsed form
    /// is enough (and keeps the internal token types out of the public surface).
    public static func == (lhs: GitignorePattern, rhs: GitignorePattern) -> Bool {
        lhs.negated == rhs.negated
            && lhs.anchored == rhs.anchored
            && lhs.directoryOnly == rhs.directoryOnly
            && lhs.components == rhs.components
    }
}

/// One compiled component of a `GitignorePattern`.
enum PatternComponent: Equatable {
    /// `**` — zero or more whole path components.
    case doubleStar
    /// Exactly one path component, matched by these glob tokens.
    case glob([GlobToken])
}

/// One compiled element of a single-component glob.
enum GlobToken: Equatable {
    /// `*` — any run of characters (a component never contains a separator, so
    /// this is where "`*` does not cross a `/`" comes from).
    case star
    /// `?` — exactly one character.
    case anyOne
    /// A literal character (possibly the result of a backslash escape).
    case literal(Character)
    /// `[…]` — a character class.
    case set(GlobCharacterSet)
}

/// The members of one `[…]` class: single characters plus ranges, and whether the
/// class is negated (`[!…]`/`[^…]`).
struct GlobCharacterSet: Equatable {
    var negated: Bool
    var singles: Set<Character>
    var ranges: [GlobCharacterRange]

    func contains(_ character: Character) -> Bool {
        let member = singles.contains(character) || ranges.contains { $0.contains(character) }
        return negated ? !member : member
    }
}

/// An `a-z` range inside a character class (a struct rather than a
/// `ClosedRange` so an inverted `z-a` can be kept without trapping).
struct GlobCharacterRange: Equatable {
    var lower: Character
    var upper: Character

    func contains(_ character: Character) -> Bool {
        lower <= character && character <= upper
    }
}

/// Single-component glob matching (`*`, `?`, `[…]`, backslash escapes) — the
/// piece a `.gitignore` pattern applies per path component, exposed on its own
/// because the "Find in Files" file mask (`*.ts,*.tsx`) is exactly this rule
/// applied to a file name.
///
/// Matching is a dynamic-programming walk, so a pattern with many stars
/// (`a*a*a*a*b`) stays `O(name × pattern)` instead of going exponential the way
/// naive backtracking does.
public enum Glob {
    /// Whether `name` — one path component, or any single string — matches
    /// `pattern`. Case-sensitive, like git on a case-sensitive volume.
    public static func matches(name: String, pattern: String) -> Bool {
        matches(tokens: compile(pattern), name: name)
    }

    static func matches(tokens: [GlobToken], name: String) -> Bool {
        let characters = Array(name)
        let m = tokens.count
        let n = characters.count
        guard m > 0 else { return n == 0 }

        var previous = [Bool](repeating: false, count: n + 1)
        previous[0] = true
        for i in 1...m {
            var current = [Bool](repeating: false, count: n + 1)
            let token = tokens[i - 1]
            if token == .star {
                current[0] = previous[0]
                if n > 0 {
                    for j in 1...n { current[j] = previous[j] || current[j - 1] }
                }
            } else if n > 0 {
                for j in 1...n {
                    current[j] = previous[j - 1] && token.matches(characters[j - 1])
                }
            }
            previous = current
        }
        return previous[n]
    }

    /// Compiles one component's glob source into tokens. Consecutive `*`s
    /// collapse into one (inside a component `**` means no more than `*` does),
    /// an unterminated `[` is a literal bracket, and a trailing lone backslash is
    /// a literal backslash.
    static func compile(_ pattern: String) -> [GlobToken] {
        let characters = Array(pattern)
        var tokens: [GlobToken] = []
        var i = 0
        while i < characters.count {
            switch characters[i] {
            case "*":
                if tokens.last != .star { tokens.append(.star) }
                i += 1
            case "?":
                tokens.append(.anyOne)
                i += 1
            case "\\":
                if i + 1 < characters.count {
                    tokens.append(.literal(characters[i + 1]))
                    i += 2
                } else {
                    tokens.append(.literal("\\"))
                    i += 1
                }
            case "[":
                if let (set, next) = parseCharacterSet(characters, from: i) {
                    tokens.append(.set(set))
                    i = next
                } else {
                    tokens.append(.literal("["))
                    i += 1
                }
            default:
                tokens.append(.literal(characters[i]))
                i += 1
            }
        }
        return tokens
    }

    /// Parses `[…]` starting at `start` (which must be the `[`), returning the
    /// set and the index just past the closing `]`, or `nil` when the class is
    /// unterminated.
    private static func parseCharacterSet(
        _ characters: [Character],
        from start: Int
    ) -> (GlobCharacterSet, Int)? {
        var i = start + 1
        var negated = false
        if i < characters.count, characters[i] == "!" || characters[i] == "^" {
            negated = true
            i += 1
        }
        var singles: Set<Character> = []
        var ranges: [GlobCharacterRange] = []
        // A `]` in the first member position is a literal, not the terminator.
        var isFirst = true
        while i < characters.count {
            let character = characters[i]
            if character == "]" && !isFirst {
                return (GlobCharacterSet(negated: negated, singles: singles, ranges: ranges), i + 1)
            }
            isFirst = false

            var member = character
            if character == "\\", i + 1 < characters.count {
                i += 1
                member = characters[i]
            }
            // `a-z`, but a `-` just before the closing `]` is a literal dash.
            if i + 2 < characters.count, characters[i + 1] == "-", characters[i + 2] != "]" {
                var upper = characters[i + 2]
                var consumed = i + 2
                if upper == "\\", consumed + 1 < characters.count {
                    consumed += 1
                    upper = characters[consumed]
                }
                ranges.append(GlobCharacterRange(lower: member, upper: upper))
                i = consumed + 1
                continue
            }
            singles.insert(member)
            i += 1
        }
        return nil
    }
}

extension GlobToken {
    func matches(_ character: Character) -> Bool {
        switch self {
        case .star:
            return true
        case .anyOne:
            return true
        case .literal(let literal):
            return literal == character
        case .set(let set):
            return set.contains(character)
        }
    }
}

/// The patterns of **one** `.gitignore` file, in file order.
///
/// Scope: this type answers "what does *this* file say about this path", with
/// git's last-match-wins rule inside the file. Composing several files down a
/// directory tree — and refusing to resurrect a file under an excluded directory
/// — is `GitignoreStack`'s job, and `.git` itself is excluded by the caller
/// (the traversal), not here. Global excludes (`core.excludesFile`,
/// `.git/info/exclude`) are deliberately out of scope.
public struct GitignoreRules: Equatable {
    /// What a matching pattern says about a path.
    public enum Decision: Equatable {
        /// The path is excluded (an ordinary pattern matched).
        case ignored
        /// The path is explicitly re-included (a `!` pattern matched).
        case included
    }

    /// The parsed patterns, in file order (later entries win).
    public let patterns: [GitignorePattern]

    /// Parses a whole `.gitignore` file. Lines split on any Unicode line break,
    /// so CRLF contents parse without a stray carriage return ending up in a
    /// pattern.
    public init(fileContents: String) {
        patterns = fileContents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { GitignorePattern(line: String($0)) }
    }

    public init(patterns: [GitignorePattern]) {
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// This file's verdict on `relativePath` (relative to the directory holding
    /// the `.gitignore`), or `nil` when no pattern here matches it.
    ///
    /// Last match wins, so the patterns are walked in reverse and the first hit
    /// decides. Only the path *itself* is judged — an ancestor directory being
    /// excluded is the traversal's (and `GitignoreStack`'s) concern.
    public func decision(relativePath: String, isDirectory: Bool) -> Decision? {
        let components = GitignoreRules.pathComponents(relativePath)
        guard !components.isEmpty else { return nil }
        for pattern in patterns.reversed()
        where pattern.matches(pathComponents: components, isDirectory: isDirectory) {
            return pattern.negated ? .included : .ignored
        }
        return nil
    }

    /// Splits a relative path into components, dropping empties so a leading,
    /// trailing or doubled separator cannot introduce a nameless component.
    static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

/// The `.gitignore` files in effect for one point of a directory walk: the
/// project root's own file plus every nested one on the way down.
///
/// This is the layered counterpart of `GitignoreRules`, which answers only for
/// *one* file. Three rules, all of them git's:
///
/// * **deeper overrides outer** — a nested `.gitignore` is consulted first, and
///   the first level with an opinion decides, so `sub/.gitignore` holding
///   `!important.log` re-includes a file the root's `*.log` excluded;
/// * **last match wins inside one file** — delegated to `GitignoreRules`;
/// * **an excluded directory is never re-opened from inside** — gitignore(5):
///   "It is not possible to re-include a file if a parent directory of that file
///   is excluded". Every ancestor directory is judged before the path itself, and
///   an excluded one is final. (git gets this for free by not descending at all,
///   which is also why it never even reads a nested `.gitignore` down there.)
///
/// Scope is inherited from `GitignoreRules`: tree `.gitignore` files only — no
/// `core.excludesFile`, no `.git/info/exclude`, and `.git` itself is skipped by
/// the traversal rather than by any rule here. Matching is case-sensitive, as
/// git is with `core.ignorecase=false`.
public struct GitignoreStack: Equatable {
    /// One `.gitignore` file and the root-relative directory that holds it.
    public struct Level: Equatable {
        /// The holding directory's components, relative to the project root —
        /// empty for the root's own `.gitignore`.
        public let directory: [String]
        /// That file's patterns.
        public let rules: GitignoreRules

        public init(directory: [String], rules: GitignoreRules) {
            self.directory = directory
            self.rules = rules
        }
    }

    /// The levels in discovery order: outermost first, deepest last.
    public private(set) var levels: [Level]

    /// An empty stack, which excludes nothing.
    public init() {
        levels = []
    }

    public init(levels: [Level]) {
        self.levels = levels
    }

    /// This stack plus one more `.gitignore`, found in `relativeDirectory`
    /// (relative to the project root; `""` for the root's own file).
    ///
    /// Levels must be appended **outermost first**, which is the order a
    /// top-down traversal discovers them in — `decision` reads them back to
    /// front to give the deepest file the first word. A file with no patterns
    /// (empty, or nothing but blanks and comments) is dropped rather than
    /// stored: it can never have an opinion, so keeping it would only lengthen
    /// every lookup.
    public func appending(rules: GitignoreRules, relativeDirectory: String) -> GitignoreStack {
        guard !rules.isEmpty else { return self }
        let level = Level(
            directory: GitignoreRules.pathComponents(relativeDirectory),
            rules: rules
        )
        return GitignoreStack(levels: levels + [level])
    }

    /// Whether `relativePath` (relative to the project root) is excluded.
    ///
    /// Ancestors are judged first and an excluded directory short-circuits, so a
    /// negation below one cannot resurrect anything; only then is the path
    /// itself judged. A path with no components (`""`, `"/"`) is never excluded.
    public func isExcluded(relativePath: String, isDirectory: Bool) -> Bool {
        let components = GitignoreRules.pathComponents(relativePath)
        guard !components.isEmpty else { return false }

        for depth in 1..<components.count
        where decision(for: Array(components[0..<depth]), isDirectory: true) == .ignored {
            return true
        }
        return decision(for: components, isDirectory: isDirectory) == .ignored
    }

    /// The verdict of the deepest level that has one, or `nil` when no level's
    /// patterns match `components` at all.
    ///
    /// A level applies only to paths *strictly under* its own directory, so its
    /// components are matched as a whole-component prefix and the remainder is
    /// what its patterns are asked about (which is what makes an anchored
    /// pattern in a nested file relative to *that* directory).
    func decision(for components: [String], isDirectory: Bool) -> GitignoreRules.Decision? {
        for level in levels.reversed() {
            guard components.count > level.directory.count,
                  Array(components.prefix(level.directory.count)) == level.directory
            else { continue }
            let relative = components.dropFirst(level.directory.count).joined(separator: "/")
            if let decision = level.rules.decision(relativePath: relative, isDirectory: isDirectory) {
                return decision
            }
        }
        return nil
    }
}
