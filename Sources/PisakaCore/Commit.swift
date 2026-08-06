import Foundation

/// A single commit in the Log view's history list.
///
/// A deliberately small value type carrying only what the list, graph, and
/// detail panes need: the full `hash` (identity), `parents` (parent hashes, in
/// the order `git log --parents` reports them — first parent first; empty for a
/// root commit; 2+ for a merge), the `author` name, the raw ISO-8601 `date`
/// string (kept as text so Core stays free of locale/formatting concerns — the
/// view layer formats for display), the single-line `subject`, and the decoded
/// `refs` (branch/tag/HEAD names attached to this commit).
///
/// Identity is the full `hash`, so a commit keeps a stable identity across
/// refreshes/filters.
public struct Commit: Identifiable, Equatable {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let date: String
    public let subject: String
    public let refs: [String]

    public init(
        hash: String,
        parents: [String],
        author: String,
        date: String,
        subject: String,
        refs: [String]
    ) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    /// Stable identity from the full commit hash.
    public var id: String { hash }
}

/// Pure parser for the `git log` output the service produces.
///
/// Foundation-only and side-effect-free, so the field/record splitting and the
/// `%D` ref-decoration decoding are unit-tested in Core; the `Process`
/// invocation that produces the output lives in `GitCLIService`.
///
/// ## Output format
///
/// The service must run `git log` with this exact pretty format (see
/// ``Commit/prettyFormat``):
///
///     %H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e
///
/// Fields within a record are separated by NUL (`%x00`), and records are
/// terminated by an ASCII Record Separator (`%x1e`, `\u{1e}`). Neither byte can
/// appear inside a hash, author name, ISO date, single-line subject, or ref
/// list, so a subject or ref containing spaces (or the commas/arrows git uses
/// inside `%D`) survives splitting intact — a plain newline-terminated format
/// would be ambiguous if a subject ever embedded the separator.
///
/// The six fields, in order:
/// 1. `%H` — full commit hash.
/// 2. `%P` — parent hashes, space-separated (empty for a root commit).
/// 3. `%an` — author name.
/// 4. `%aI` — author date, strict ISO-8601.
/// 5. `%s` — subject (first line of the message).
/// 6. `%D` — ref names, e.g. `HEAD -> main, origin/main, tag: v1.0`.
public extension Commit {
    /// The exact `--pretty=format:` argument the service passes to `git log`.
    static let prettyFormat = "%H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e"

    /// Parse the raw `git log` output produced by ``prettyFormat`` into commits,
    /// preserving git's ordering. Malformed records (wrong field count) are
    /// skipped; empty/whitespace-only output yields `[]`.
    static func parse(_ output: String) -> [Commit] {
        output
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { parseRecord(String($0)) }
    }

    private static func parseRecord(_ record: String) -> Commit? {
        // Records are joined by the RS terminator; `git log` puts a newline
        // between records, which lands at the front of the next record — trim
        // leading/trailing whitespace so the hash field starts clean.
        let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fields = trimmed.components(separatedBy: "\u{0}")
        guard fields.count == 6 else { return nil }

        let parents = fields[1]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        return Commit(
            hash: fields[0],
            parents: parents,
            author: fields[2],
            date: fields[3],
            subject: fields[4],
            refs: parseRefs(fields[5])
        )
    }

    /// Decode the `%D` ref decoration field into bare ref names.
    ///
    /// git formats it like `HEAD -> main, origin/main, tag: v1.0`: refs are
    /// comma-space separated, the checked-out branch is prefixed `HEAD -> `, and
    /// tags are prefixed `tag: `. We strip those prefixes to bare names and drop
    /// a standalone detached-`HEAD` entry. An empty field yields `[]`.
    private static func parseRefs(_ field: String) -> [String] {
        field
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { raw in
                var ref = raw.trimmingCharacters(in: .whitespaces)
                if let arrow = ref.range(of: "HEAD -> ") {
                    ref = String(ref[arrow.upperBound...])
                }
                if ref.hasPrefix("tag: ") {
                    ref = String(ref.dropFirst("tag: ".count))
                }
                // A detached HEAD decorates as a lone "HEAD" with no arrow.
                guard !ref.isEmpty, ref != "HEAD" else { return nil }
                return ref
            }
    }
}
