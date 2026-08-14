import Foundation

/// What the user typed into "Open Problem…", once it has been understood.
///
/// The entry points on both platforms are one text field, and people put three
/// different things in it: the number they see on the site (`1`), the slug
/// (`two-sum`), or the URL they copied out of a browser tab. Parsing is pure and
/// lives here because the two entry points (macOS sheet, iOS section) are
/// untested view code and must not each invent their own idea of what is
/// acceptable — and because the field is *live-validated*, so the same function
/// that decides whether the Open button is enabled is the one that decides what
/// gets fetched.
///
/// A number is not resolved to a slug here: that needs the catalog
/// (`LeetCodeCatalog`), which may have to go to the network. This layer answers
/// only "which of the two identifiers is this", and answers `nil` for anything
/// it cannot place — an empty field, a sentence, a URL for some other site —
/// rather than guessing, because a guess becomes a request for a problem that
/// does not exist and an error the user cannot act on.
public enum LeetCodeProblemInput: Equatable, Hashable, Sendable {
    /// The user-visible problem number (`questionFrontendId`), always positive.
    case number(Int)
    /// A URL slug, already normalized to LeetCode's lowercase spelling.
    case slug(String)

    /// Parse whatever the user typed, or `nil` when it names no problem.
    ///
    /// Order matters and is the whole rule:
    ///
    /// 1. **A LeetCode URL** — recognised first, because a URL contains both a
    ///    slug and (in `/problems/1/`-style links) digits, and reading it as
    ///    anything else would take the wrong half of it.
    /// 2. Anything else containing `/` is rejected outright: it had a path shape
    ///    and did not name a LeetCode problem, so falling through to the slug
    ///    rule could only produce a wrong answer.
    /// 3. **All digits** → a number, and *only* a number: `0` and a 30-digit
    ///    paste are rejected here rather than falling through, because a digit
    ///    string satisfies the slug shape too and "problem `0`" would then be
    ///    fetched as the slug `0`, producing "no such problem" instead of the
    ///    honest "that is not a problem number". No LeetCode slug is all
    ///    digits, so nothing is lost. Leading zeros are fine (`0001` is how the
    ///    file names are written, so it is what people paste back in); zero and
    ///    negatives are not, since there is no problem 0.
    /// 4. **A slug**, normalized by ``normalizedSlug(_:)``.
    ///
    /// Surrounding whitespace is trimmed everywhere — a pasted URL usually
    /// arrives with a trailing newline.
    public static func parse(_ text: String) -> LeetCodeProblemInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let slug = slugFromURL(trimmed) { return .slug(slug) }
        // Had a path shape but named no problem — do not fall through.
        if trimmed.contains("/") { return nil }

        // All digits is a number attempt and nothing else — see rule 3.
        if isAllDigits(trimmed) {
            return number(from: trimmed).map(LeetCodeProblemInput.number)
        }
        if let slug = normalizedSlug(trimmed) { return .slug(slug) }
        return nil
    }

    /// Whether this text is reaching for a problem *number* — rule 3's own test,
    /// asked on its own.
    ///
    /// ``parse(_:)`` answers `nil` both to "these are not digits" and to "these
    /// are digits that name no problem" (`0`, or more digits than an `Int` holds),
    /// and a caller that must tell those apart would otherwise restate the digit
    /// rule beside this type — which is how the browser's filter came to search
    /// titles for `0`. Exported so it stays one rule with one spelling.
    public static func isNumberAttempt(_ text: String) -> Bool {
        isAllDigits(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The canonical answer to "is this a slug, and how is it spelled".
    ///
    /// Written down once and reused by `LeetCodeSolutionFile`'s reverse
    /// file-name parse, so the app cannot accept a slug in the input field that
    /// it would then refuse to recognise in the file name it wrote itself.
    ///
    /// LeetCode slugs are lowercase ASCII letters, digits and interior hyphens
    /// (`two-sum`, `3sum-closest`, `n-queens-ii`). Input is lowercased before
    /// checking — a user pasting `Two-Sum` means the same problem — but nothing
    /// else is repaired: spaces are not turned into hyphens, because a title is
    /// not reliably a slug (`3Sum` is `3sum`, `Add Two Numbers` is
    /// `add-two-numbers`) and a silently wrong slug reads as "no such problem".
    public static func normalizedSlug(_ text: String) -> String? {
        let slug = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty, !slug.hasPrefix("-"), !slug.hasSuffix("-") else { return nil }
        var sawAlphanumeric = false
        for character in slug {
            switch character {
            case "a"..."z", "0"..."9":
                sawAlphanumeric = true
            case "-":
                continue
            default:
                return nil
            }
        }
        return sawAlphanumeric ? slug : nil
    }

    // MARK: - Pieces

    /// All-ASCII-digits → a positive problem number, or `nil`.
    ///
    /// `Int(_:)` alone would accept `"+1"`, `"-1"` and a leading Unicode minus;
    /// the digit check runs first so only a plain number gets through, and
    /// `Int(_:)` still guards the overflow case (a 30-digit paste is `nil`, not
    /// a crash).
    private static func number(from text: String) -> Int? {
        guard isAllDigits(text) else { return nil }
        guard let value = Int(text), value > 0 else { return nil }
        return value
    }

    /// Whether every character is an ASCII digit (and there is at least one).
    private static func isAllDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The slug named by a LeetCode URL, or `nil` when this is not one.
    ///
    /// Deliberately string surgery rather than `URLComponents`: the common paste
    /// is a full `https://` URL, but people also type `leetcode.com/problems/…`
    /// with no scheme, which `URL(string:)` reads as a *path* whose host is nil.
    /// Stripping the scheme by hand and matching on path components treats both
    /// spellings identically, and leaves the host check explicit.
    ///
    /// Everything from the first `?` or `#` is dropped first (LeetCode's own
    /// "Copy Link" appends `?envType=…`), and the whole string is lowercased,
    /// which is also the slug's normalization.
    ///
    /// The slug is taken from the component *after* `problems` wherever that
    /// appears, so `/problems/two-sum/description/` and a contest URL
    /// (`/contest/weekly-contest-1/problems/two-sum/`) both resolve.
    private static func slugFromURL(_ text: String) -> String? {
        var body = Substring(text)
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            body = body[..<cut]
        }
        var lowered = Substring(body.lowercased())
        for scheme in ["https://", "http://"] where lowered.hasPrefix(scheme) {
            lowered = lowered.dropFirst(scheme.count)
        }

        let components = lowered.split(separator: "/", omittingEmptySubsequences: true)
        guard let host = components.first, isLeetCodeHost(String(host)) else { return nil }
        guard let marker = components.firstIndex(of: "problems"),
              marker + 1 < components.count else { return nil }
        return normalizedSlug(String(components[marker + 1]))
    }

    /// Whether a URL's authority component belongs to LeetCode.
    ///
    /// `leetcode.com` and any subdomain of it (`www.`), plus the China site,
    /// whose slugs are the same strings — the *detail* request still goes to
    /// `leetcode.com`, so accepting a `.cn` link costs nothing and refusing one
    /// would look arbitrary. A port is tolerated and ignored.
    private static func isLeetCodeHost(_ authority: String) -> Bool {
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        for domain in ["leetcode.com", "leetcode.cn"] where host == domain
            || host.hasSuffix("." + domain) {
            return true
        }
        return false
    }
}
