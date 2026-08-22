import Foundation

/// One offerable language: everything the integration needs to write a solution
/// file in it, in one row.
///
/// The four facts travel together on purpose. LeetCode names a language by its
/// own slug (`python3`, `golang`), the editor names it by `SyntaxLanguage`, the
/// file needs an extension, and the header comment needs that language's
/// line-comment token. Keeping them in one value makes "every offerable language
/// has all four" structural rather than four dictionaries that can disagree —
/// the failure mode being a picker entry that produces a `.txt` file or a header
/// comment that is a syntax error.
public struct LeetCodeLanguage: Equatable, Hashable, Sendable {
    /// How the editor knows this language (highlighting, the symbol index).
    public let language: SyntaxLanguage
    /// LeetCode's own slug — the key into `codeSnippets` and, in LC-2, the
    /// `lang` a submission is made under.
    public let langSlug: String
    /// The extension the solution file gets, without the dot.
    public let fileExtension: String
    /// This language's line-comment token, for the seeded header.
    public let lineCommentPrefix: String
    /// What the picker shows, spelled the way LeetCode spells it.
    public let displayName: String

    public init(
        language: SyntaxLanguage,
        langSlug: String,
        fileExtension: String,
        lineCommentPrefix: String,
        displayName: String
    ) {
        self.language = language
        self.langSlug = langSlug
        self.fileExtension = fileExtension
        self.lineCommentPrefix = lineCommentPrefix
        self.displayName = displayName
    }
}

/// How a problem becomes a file: its name, and what is in it when it is created.
///
/// The name is the *association*. This integration deliberately keeps no
/// side-car database mapping files to problems — the description panel now, and
/// LC-2's Run/Submit later, both answer "which problem is this tab?" by reading
/// the file name back. That makes the naming rule load-bearing in both
/// directions, so ``name(number:slug:language:)`` and
/// ``problemNumber(fromFileName:)``/``slug(fromFileName:)`` are written as one
/// unit and tested as a round trip: a name this type writes must always parse
/// back to the number and slug it was written from.
///
/// The consequence the user sees is that renaming a solution file detaches it
/// from its problem. That is accepted (the alternative is invisible state that
/// goes stale), and it is why the number is zero-padded to four digits: the
/// files sort in problem order in the tree, so there is no reason to rename
/// them.
public enum LeetCodeSolutionFile {

    // MARK: - Languages

    /// The languages the picker offers, in the order it shows them.
    ///
    /// A deliberate subset of both LeetCode's ~20 languages and the editor's
    /// `SyntaxLanguage` cases: a language belongs here only if the editor can
    /// highlight it *and* LeetCode accepts submissions in it. Swift leads
    /// because this is a Swift editor; the rest follow rough popularity.
    ///
    /// Note the two slugs that are not the obvious ones — LeetCode says
    /// `python3` (plain `python` is Python 2, still listed and still accepted,
    /// and seeding a Python 2 snippet in 2026 would be a bug) and `golang` — and
    /// that both directions of the mapping go through this one list.
    public static let offerableLanguages: [LeetCodeLanguage] = [
        LeetCodeLanguage(
            language: .swift,
            langSlug: "swift",
            fileExtension: "swift",
            lineCommentPrefix: "//",
            displayName: "Swift"
        ),
        LeetCodeLanguage(
            language: .python,
            langSlug: "python3",
            fileExtension: "py",
            lineCommentPrefix: "#",
            displayName: "Python3"
        ),
        LeetCodeLanguage(
            language: .go,
            langSlug: "golang",
            fileExtension: "go",
            lineCommentPrefix: "//",
            displayName: "Go"
        ),
        LeetCodeLanguage(
            language: .rust,
            langSlug: "rust",
            fileExtension: "rs",
            lineCommentPrefix: "//",
            displayName: "Rust"
        ),
        LeetCodeLanguage(
            language: .typescript,
            langSlug: "typescript",
            fileExtension: "ts",
            lineCommentPrefix: "//",
            displayName: "TypeScript"
        ),
        LeetCodeLanguage(
            language: .javascript,
            langSlug: "javascript",
            fileExtension: "js",
            lineCommentPrefix: "//",
            displayName: "JavaScript"
        ),
    ]

    /// The language LeetCode calls `langSlug`, or `nil` when it is one this app
    /// does not offer (LeetCode has C#, Kotlin, Erlang and a dozen more).
    ///
    /// Matching is case-insensitive because the slug arrives from the wire and
    /// from `SettingsStore`, where an older build or a hand-edited defaults
    /// entry could have stored any spelling; the *stored* form is always
    /// lowercase.
    public static func language(forLangSlug langSlug: String) -> LeetCodeLanguage? {
        let needle = langSlug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return offerableLanguages.first { $0.langSlug == needle }
    }

    /// The offerable row for an editor language, or `nil` when that language is
    /// not offered (`.json`, `.markdown`, …).
    public static func language(for language: SyntaxLanguage) -> LeetCodeLanguage? {
        offerableLanguages.first { $0.language == language }
    }

    /// The language a solution file's **extension** says it is written in, or
    /// `nil` when the extension names none.
    ///
    /// This is the reverse of the one thing ``name(number:slug:language:)``
    /// encodes that the number and the slug do not, and it exists because the
    /// judge has to name a `lang` in its payload: the file on screen is all the
    /// judge has, and the extension is where its language is written down. Going
    /// through ``offerableLanguages`` — rather than through `SyntaxLanguage`,
    /// which knows `.rb` and `.cpp` this app does not offer — is what keeps the
    /// two directions from ever disagreeing: a file this app *wrote* always maps
    /// back to the language it was written in, and a file it did not write maps
    /// to something LeetCode will accept or to nothing at all.
    ///
    /// `nil` is the honest answer for `0001-two-sum.md`, and the judge turns it
    /// into a stated refusal rather than guessing a language and submitting
    /// prose to the judge.
    ///
    /// Matched case-insensitively (a `.PY` on a case-insensitive volume is the
    /// same file), and a leading dot is tolerated: callers pass
    /// `URL.pathExtension`, which carries none, but a hand-written `".py"` must
    /// not silently answer `nil`.
    public static func language(forFileExtension fileExtension: String) -> LeetCodeLanguage? {
        var needle = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if needle.hasPrefix(".") { needle.removeFirst() }
        guard !needle.isEmpty else { return nil }
        return offerableLanguages.first { $0.fileExtension == needle }
    }

    /// The picker's fallback, used when nothing has been persisted yet and when
    /// a persisted slug no longer names an offerable language.
    public static var defaultLanguage: LeetCodeLanguage { offerableLanguages[0] }

    // MARK: - Names

    /// How many digits the number is padded to, and the reason the files sort in
    /// problem order. Problems past 9999 simply widen the field rather than
    /// being truncated or rejected.
    public static let numberPadding = 4

    /// `0001-two-sum.swift` — the name a newly opened problem gets.
    ///
    /// The number comes first so the folder sorts by problem, the slug follows
    /// so the name is readable, and the extension is the language's, so the
    /// editor highlights the file and the symbol index reads it with no extra
    /// wiring. Nothing here depends on the *title*: titles contain spaces,
    /// colons and question marks, and one of them would eventually be a name the
    /// file system refuses.
    public static func name(number: Int, slug: String, language: LeetCodeLanguage) -> String {
        "\(paddedNumber(number))-\(slug).\(language.fileExtension)"
    }

    /// The number a solution file's name starts with, or `nil` when the name is
    /// not one of ours.
    ///
    /// Accepts a path (only the last component is read) and any extension,
    /// including none: the file may have been created by an older build, or by a
    /// language this build no longer offers, and the description panel should
    /// still recognise it.
    ///
    /// The shape is permissive enough that an unrelated file can match it
    /// (`2024-notes.md` reads as problem 2024, slug `notes`). That is deliberate
    /// and safe: nothing is written on the strength of a parse, and the second
    /// half of the association — the file must sit inside the configured
    /// LeetCode folder — is checked by `LeetCodeModel`, which is also the layer
    /// that discovers there is no such problem and shows nothing.
    public static func problemNumber(fromFileName fileName: String) -> Int? {
        parts(fromFileName: fileName)?.number
    }

    /// The slug a solution file's name carries, or `nil` when the name is not
    /// one of ours. See ``problemNumber(fromFileName:)``.
    public static func slug(fromFileName fileName: String) -> String? {
        parts(fromFileName: fileName)?.slug
    }

    /// Both halves of a solution file's name, or `nil` when it is not one.
    ///
    /// The single reverse rule: last path component → drop the extension →
    /// split at the first hyphen → digits before it, a valid slug after it. The
    /// slug is validated by `LeetCodeProblemInput.normalizedSlug(_:)`, the same
    /// rule the input field uses, so the app cannot write a name it would then
    /// fail to recognise.
    ///
    /// The extension is dropped rather than checked, because a solved problem
    /// may have been rewritten in another language, and the number is what the
    /// panel needs either way.
    public static func parts(fromFileName fileName: String) -> (number: Int, slug: String)? {
        let component = (fileName as NSString).lastPathComponent
        let stem = (component as NSString).deletingPathExtension
        guard let hyphen = stem.firstIndex(of: "-") else { return nil }

        let digits = stem[stem.startIndex..<hyphen]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }

        let remainder = String(stem[stem.index(after: hyphen)...])
        guard let slug = LeetCodeProblemInput.normalizedSlug(remainder) else { return nil }
        return (number, slug)
    }

    /// The number as it appears in a file name: zero-padded to
    /// ``numberPadding`` digits, wider numbers passing through unchanged.
    private static func paddedNumber(_ number: Int) -> String {
        let digits = String(number)
        guard digits.count < numberPadding else { return digits }
        return String(repeating: "0", count: numberPadding - digits.count) + digits
    }

    // MARK: - Contents

    /// The one header comment line a seeded file carries.
    ///
    /// Number, title and the problem's URL, in that language's line-comment
    /// syntax. It exists for the human reading the file outside the app — the
    /// integration itself never parses it back (the *name* is the association),
    /// which is why it can be edited or deleted with no consequence.
    ///
    /// One line, not a banner: this is a file the user is about to type in, and
    /// six lines of ceremony above the cursor is what people delete first.
    ///
    /// **One line is a guarantee, not a description.** The title is LeetCode's,
    /// interpolated into a *line* comment, so an interior line separator in it
    /// would end the comment and leave the remainder as bare, uncommented text on
    /// line 2 of the file — which the never-overwrite rule then preserves forever.
    /// Trimming the ends is not enough for that; every separator inside is
    /// collapsed to a space.
    public static func header(
        number: Int,
        title: String,
        slug: String,
        language: LeetCodeLanguage
    ) -> String {
        let url = LeetCodeAPI.problemURL(slug: slug).absoluteString
        // Empty pieces are dropped rather than joined, so a CRLF — two separators
        // with nothing between them — costs one space, not two.
        let cleanTitle = title
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let subject = cleanTitle.isEmpty ? slug : cleanTitle
        return "\(language.lineCommentPrefix) \(number). \(subject) — \(url)"
    }

    /// The bytes a newly created solution file is written with: the header, a
    /// blank line, then LeetCode's own snippet verbatim, newline-terminated.
    ///
    /// "Verbatim" is the point — the snippet is the signature the judge expects,
    /// so nothing here reindents, trims or rewrites it. The only adjustment is
    /// the trailing newline, and only when the snippet does not already end in
    /// one (LeetCode's do not), so re-seeding never produces a file that differs
    /// from itself by a blank line.
    ///
    /// A `nil` header means the language has no comment syntax to put one in;
    /// the file is then the snippet alone. An empty snippet (LeetCode offers the
    /// problem in no language this app knows) yields the header alone rather
    /// than a stray blank line.
    public static func contents(header: String?, snippet: String) -> String {
        let body = snippet.hasSuffix("\n") || snippet.isEmpty ? snippet : snippet + "\n"
        guard let header, !header.isEmpty else { return body }
        guard !body.isEmpty else { return header + "\n" }
        return header + "\n\n" + body
    }
}
