import Foundation

/// The completion's third candidate source: the reserved vocabulary of the
/// language the user is typing in.
///
/// Static per-language lists rather than anything derived from the parse tree.
/// A keyword is spelled the same in every file of a language, it never moves,
/// and it is exactly what a project's *first* file — the one that declares
/// nothing yet and whose buffer holds no words to harvest — has to offer. So the
/// cheapest possible source is also the right one: no index, no read, no parse,
/// just a filter over a sorted array behind the same matcher every other source
/// goes through (`FuzzyMatch`).
///
/// **A keyword is never a definition.** These lists feed completion only;
/// `SymbolIntelligenceProvider`'s go-to-definition path does not consult them,
/// because there is nothing to jump *to* — a keyword has no declaration site in
/// the project. That separation is pinned by a test rather than left to
/// convention, since the two features share a provider.
///
/// The lists are curated, not generated: each holds the tokens a person types
/// while writing the language — declaration and statement keywords, the literal
/// spellings (`true`/`nil`/`None`), the widely-used contextual keywords — and
/// stops there. They are deliberately *not* a standard-library index: `print`,
/// `console` and `String` are declarations, and a project that uses them has
/// them in its buffer or (for its own code) in its symbol index already.
public enum LanguageKeywords {

    /// The keywords of `language`, sorted and duplicate-free, or an empty array
    /// for a language listed in `languagesWithoutKeywords`.
    ///
    /// Sorted because the provider's ranking tie-breaks on name and a stable
    /// input keeps an unranked tie deterministic between runs; duplicate-free
    /// because the provider de-duplicates by name and a repeated entry would
    /// silently do nothing. Both are asserted by `LanguageKeywordsTests` for
    /// every list, so a hand-edited list cannot drift out of either shape.
    public static func keywords(for language: SyntaxLanguage) -> [String] {
        switch language {
        case .swift: return swift
        case .javascript: return javaScript
        case .typescript: return typeScript
        case .python: return python
        case .dockerfile: return dockerfile
        case .go: return go
        // Placeholder: Rust *does* get a list — it is written in the next task,
        // and this line is deliberately not a `languagesWithoutKeywords` entry,
        // which would be a decision rather than a step. `LanguageKeywordsTests`
        // fails on the empty list until it is replaced.
        case .rust: return []
        case .json, .markdown, .html, .css, .yaml, .dotenv, .gitignore: return []
        }
    }

    /// Languages the editor highlights but offers **no** keyword completion for,
    /// each for a stated reason — the absence is a decision, not a gap.
    ///
    /// Recorded as an explicit set for the same reason
    /// `SymbolIndexModel.unindexableLanguages` is: `LanguageKeywordsTests`
    /// asserts by set equality against `SyntaxLanguage.allCases` that every case
    /// either has a non-empty list or is named here, so a language added to the
    /// enum fails `swift test` until someone decides which it is. It can never
    /// silently complete to nothing.
    ///
    /// The reasons, by family:
    ///
    /// - **JSON, YAML, dotenv** — data, not code. Their whole grammar is
    ///   punctuation; the only "keywords" are `true`/`false`/`null` (JSON) and
    ///   YAML's handful of scalar spellings, which are shorter than the popup
    ///   they would open. What the user actually wants completed in a data file
    ///   is the *keys already in the buffer*, which the harvested-word source
    ///   already offers.
    /// - **Markdown** — prose. It has no reserved words at all; its syntax is
    ///   line-leading punctuation.
    /// - **gitignore** — patterns. A path glob has no vocabulary to complete,
    ///   which is also why it is the one language the symbol index skips
    ///   (`SymbolIndexModel.unindexableLanguages`).
    /// - **HTML, CSS** — an open vocabulary that a flat list would answer
    ///   badly. The useful completions here are element names, attribute names
    ///   and property names, and each is only meaningful *in position* (which
    ///   attributes inside which element, which values for which property).
    ///   Several hundred names with no positional filter is noise, not a
    ///   spelling aid; doing it properly is a structural completion of its own
    ///   and belongs to whatever phase takes on typed context.
    public static let languagesWithoutKeywords: Set<SyntaxLanguage> = [
        .json, .markdown, .html, .css, .yaml, .dotenv, .gitignore,
    ]

    // MARK: - The lists

    /// Swift: the reserved words plus the contextual ones that read as keywords
    /// at a declaration site (`async`, `some`, `actor`, the accessor names).
    private static let swift: [String] = [
        "Any", "Self",
        "actor", "any", "as", "associatedtype", "async", "await",
        "borrowing", "break",
        "case", "catch", "class", "consuming", "continue", "convenience",
        "default", "defer", "deinit", "didSet", "do", "dynamic",
        "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "final", "for", "func",
        "get", "guard",
        "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is",
        "lazy", "let",
        "mutating",
        "nil", "nonisolated", "nonmutating",
        "open", "operator", "override",
        "package", "postfix", "precedencegroup", "prefix", "private", "protocol", "public",
        "repeat", "required", "rethrows", "return",
        "self", "set", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias",
        "unowned",
        "var",
        "weak", "where", "while", "willSet",
    ]

    /// JavaScript: the reserved words, the module-syntax contextual ones
    /// (`from`, `of`, `as` is TypeScript-side) and the literal spellings.
    private static let javaScript: [String] = [
        "async", "await",
        "break",
        "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do",
        "else", "export", "extends",
        "false", "finally", "for", "from", "function",
        "get",
        "if", "import", "in", "instanceof",
        "let",
        "new", "null",
        "of",
        "return",
        "set", "static", "super", "switch",
        "this", "throw", "true", "try", "typeof",
        "undefined",
        "var", "void",
        "while", "with",
        "yield",
    ]

    /// TypeScript is JavaScript plus a type-level vocabulary, so it is composed
    /// rather than copied: one list to maintain instead of two that drift, and
    /// the merge is re-sorted so the composition cannot break the sorted
    /// invariant `keywords(for:)` documents.
    private static let typeScript: [String] = (javaScript + typeScriptOnly).sorted()

    /// What TypeScript adds to JavaScript: the modifiers, the type operators and
    /// the primitive type names (which are keywords in type position, not
    /// declarations anything could jump to).
    private static let typeScriptOnly: [String] = [
        "abstract", "any", "as", "asserts",
        "boolean",
        "declare",
        "enum",
        "implements", "infer", "interface", "is",
        "keyof",
        "namespace", "never", "number",
        "object", "override",
        "private", "protected", "public",
        "readonly",
        "satisfies", "string", "symbol",
        "type",
        "unique", "unknown",
    ]

    /// Python: the reserved words (`keyword.kwlist`) plus the soft keywords
    /// `match`/`case`/`type`, which are what a modern file actually types.
    private static let python: [String] = [
        "False", "None", "True",
        "and", "as", "assert", "async", "await",
        "break",
        "case", "class", "continue",
        "def", "del",
        "elif", "else", "except",
        "finally", "for", "from",
        "global",
        "if", "import", "in", "is",
        "lambda",
        "match",
        "nonlocal", "not",
        "or",
        "pass",
        "raise", "return",
        "try", "type",
        "while", "with",
        "yield",
    ]

    /// Dockerfile: the instruction set, uppercase as it is written. `MAINTAINER`
    /// is superseded by `LABEL` but still parsed, and an existing Dockerfile that
    /// uses it should still complete it.
    private static let dockerfile: [String] = [
        "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM",
        "HEALTHCHECK", "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL",
        "STOPSIGNAL", "USER", "VOLUME", "WORKDIR",
    ]

    /// Go: the 25 reserved words **plus the whole universe block** — its 22
    /// predeclared type names, its 4 constants (`true`, `false`, `iota` and the
    /// zero value `nil`) and its 18 built-in functions. 69 entries.
    ///
    /// The universe block is in here under a sharper form of the rule the
    /// TypeScript list already follows (`string`, `number`, `never` are keywords
    /// in type position, not declarations anything could jump to): **an
    /// identifier belongs on a keyword list when no source file can ever declare
    /// it.** Go's predeclared identifiers are declared in *no* file anywhere —
    /// not in the standard library, not in a stub — so no other completion
    /// source can offer them: the symbol index only holds what the project
    /// declares, and the harvested buffer words only hold what the user has
    /// already typed. Leaving them out would make `len`, `error` and `nil`
    /// uncompletable in a Go project forever.
    ///
    /// It does not reopen the "not a standard-library index" line the type's
    /// note draws, either: `fmt.Println` *is* a declaration in a package, so it
    /// stays out along with the rest of the standard library.
    private static let go: [String] = [
        "any", "append",
        "bool", "break", "byte",
        "cap", "case", "chan", "clear", "close", "comparable",
        "complex", "complex128", "complex64", "const", "continue", "copy",
        "default", "defer", "delete",
        "else", "error",
        "fallthrough", "false", "float32", "float64", "for", "func",
        "go", "goto",
        "if", "imag", "import",
        "int", "int16", "int32", "int64", "int8", "interface", "iota",
        "len",
        "make", "map", "max", "min",
        "new", "nil",
        "package", "panic", "print", "println",
        "range", "real", "recover", "return", "rune",
        "select", "string", "struct", "switch",
        "true", "type",
        "uint", "uint16", "uint32", "uint64", "uint8", "uintptr",
        "var",
    ]
}
