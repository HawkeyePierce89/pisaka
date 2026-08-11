import Foundation

/// Where the LeetCode integration keeps the two things it caches, as pure path
/// math over a base directory the app supplies.
///
/// **No file system access, on purpose** — the `LSPInstallLayout` discipline,
/// restated for a second cache root: nothing here stats, reads, creates or
/// deletes, so the catalog's tests can reason about paths against a
/// `StubFileTree` while the app points the same math at
/// `~/Library/Application Support/Pisaka/LeetCode` (or the iOS container's
/// equivalent) without a second implementation. A method that answers a `URL` is
/// not claiming anything is there.
///
/// The shape it describes:
///
/// ```text
/// <base>/
///   catalog.json                 ← the ~4000-row problem list, refetched daily
///   Statements/
///     two-sum.html               ← LeetCode's own statement fragment, verbatim
/// ```
///
/// Two properties carry the design.
///
/// **Everything is derived from one base**, so "delete that directory" is a
/// complete de-provisioning of the integration's cache — the same promise the
/// language-server install root makes, for the same reason: the disk *is* the
/// state, and there is no database to fall out of step with it.
///
/// **A slug is not a path component until it has been checked.** `statementFile`
/// answers an `Optional` because the string it is handed comes off the network
/// and out of a file name the user could have typed; `../../../Library/…` must
/// not become a write. The check is `LeetCodeProblemInput.normalizedSlug(_:)` —
/// the *same* rule that decides whether a slug typed into "Open Problem…" is a
/// slug at all — so the app cannot cache a statement under a name it would later
/// refuse to look up, and there is exactly one definition of the character set to
/// audit.
public struct LeetCodeCacheLayout: Equatable, Sendable {
    /// The cache root — `…/Application Support/Pisaka/LeetCode` in the app, a
    /// temporary directory in the tests.
    public let base: URL

    /// `base` is normalised lexically (`.`/`..` resolved, no `realpath(3)` and no
    /// `stat(2)`) and re-spelled as a directory URL, so two spellings of one root
    /// compare equal — this is a value the models hold and compare.
    ///
    /// `URL.standardizedFileURL` is deliberately not what does that: it consults
    /// the disk under `/private/{tmp,var,etc}`, which is precisely the bug
    /// `LSPInstallLayout.normalisedComponents(of:)` records at length. The lexical
    /// rule lives there; this initialiser reaches it through the one public door
    /// it exposes (`directory(_:contains:)`) for containment, and restates the
    /// four-line normalisation for the base itself rather than making that rule
    /// public just to be borrowed once.
    public init(base: URL) {
        var components: [String] = []
        for component in base.path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        self.base = URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: true
        )
    }

    /// The directory name the app appends to its Application Support directory.
    /// Here rather than in the app so the one place that spells it is the one
    /// place the "delete this to forget everything" instruction points at.
    public static let directoryName = "LeetCode"

    /// The cached problem list. One file, because the whole catalog arrives in
    /// one response (`GET /api/problems/all/`) and is only ever replaced whole.
    public static let catalogFileName = "catalog.json"

    public static let statementsDirectoryName = "Statements"

    /// Where `catalog.json` lives.
    public var catalogFile: URL {
        base.appendingPathComponent(Self.catalogFileName, isDirectory: false)
    }

    /// The directory holding one HTML fragment per problem.
    public var statementsDirectory: URL {
        base.appendingPathComponent(Self.statementsDirectoryName, isDirectory: true)
    }

    /// The cached statement for `slug`, or `nil` when `slug` is not one.
    ///
    /// The `nil` is a refusal, not an absence: a caller that gets it must treat
    /// the statement as uncacheable rather than fall back to some other path.
    /// Every real LeetCode slug passes (they are lowercase ASCII with interior
    /// hyphens); what does not pass is a traversal (`../secrets`), an absolute
    /// path, a name with a separator in it, or the empty string.
    public func statementFile(forSlug slug: String) -> URL? {
        guard let component = Self.sanitizedSlugComponent(slug) else { return nil }
        return statementsDirectory.appendingPathComponent("\(component).html", isDirectory: false)
    }

    /// The single file-name component a slug may become, or `nil`.
    ///
    /// Exposed so the model can tell "no cached statement" from "this slug can
    /// never have one" without re-deriving the rule.
    public static func sanitizedSlugComponent(_ slug: String) -> String? {
        LeetCodeProblemInput.normalizedSlug(slug)
    }

    /// Whether `url` is inside the cache root — the assertion that this layer
    /// only ever writes its own files.
    ///
    /// Lexical, like everything else here, and asked through `LSPInstallLayout`'s
    /// implementation so that "inside my root" is one comparison in this codebase
    /// rather than two that could drift apart. Its stated limit applies unchanged:
    /// `/tmp/x` and `/private/tmp/x` are one directory on macOS and this call
    /// reads them as two, which is safe for a predicate that can only refuse.
    public func contains(_ url: URL) -> Bool {
        LSPInstallLayout.directory(base, contains: url)
    }
}
