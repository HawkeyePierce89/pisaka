import Foundation

/// The set of constraints applied to the commit history query (`git log`).
///
/// Carries the four *server-side* filter dimensions that change which commits the
/// service fetches — ref selection, author, date range, and path — and builds the
/// corresponding `git log` arguments via the pure `gitArguments()` seam. The
/// *client-side* message search is intentionally **not** a field here: it filters
/// the already-loaded commits without re-querying git, so the model holds the
/// query separately and applies it via the pure `LogFilter.search(_:query:)`
/// helper (a filter change re-fetches; a search change does not).
///
/// Foundation-only and pure, so the argument building and search predicate are
/// unit-tested in Core; the `Process` invocation that consumes the arguments lives
/// in `GitCLIService`.
public struct LogFilter: Equatable {
    /// Which refs the history spans.
    public enum RefSelection: Equatable {
        /// Every ref (`--all`) — the "All" selection and the default.
        case all
        /// A single named ref (a branch/tag), passed to `git log` as a positional
        /// revision so only its ancestry is walked.
        case ref(String)
    }

    /// The ref scope of the query. Defaults to `.all` (`--all`).
    public var refSelection: RefSelection

    /// An author filter (`--author=<value>`), or `nil`/blank for no author
    /// constraint. git treats the value as a pattern matched against the author
    /// name/email.
    public var author: String?

    /// Lower bound on the commit (author) date (`--since=<iso>`), or `nil`.
    public var since: Date?

    /// Upper bound on the commit (author) date (`--until=<iso>`), or `nil`.
    public var until: Date?

    /// A pathspec limiting the history to commits touching `path` (`-- <path>`),
    /// or `nil`/blank for the whole tree.
    public var path: String?

    public init(
        refSelection: RefSelection = .all,
        author: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        path: String? = nil
    ) {
        self.refSelection = refSelection
        self.author = author
        self.since = since
        self.until = until
        self.path = path
    }

    /// The `git log` revision/option arguments this filter contributes, in
    /// addition to the fixed formatting/ordering flags the service always passes.
    ///
    /// Ordering follows git's grammar: the option filters first, then a named
    /// ref's positional revision behind `--end-of-options`, then the pathspec last
    /// behind a `--` separator (so a path that looks like a revision or option is
    /// never misparsed). The `.all` scope spans every ref via `--all` (itself an
    /// option, so it leads); a named ref is a positional revision.
    ///
    /// A named ref is emitted *last among the options* and prefixed with
    /// `--end-of-options`: a ref name may legitimately begin with `--` (git's
    /// `check-ref-format` accepts, e.g., a tag named `--max-count=0`), and passed
    /// bare it would be parsed as an option that silently overrides the command.
    /// `--end-of-options` forces git to treat the following argument as a revision,
    /// and because everything after it must be positional, the option filters
    /// (`--author`/`--since`/`--until`) are placed before it.
    ///
    /// Blank author/path values (after trimming whitespace) contribute nothing, so
    /// an empty text field in the filter bar does not constrain the query. A blank
    /// `.ref` name would make `git log` fall back to HEAD silently, so it degrades
    /// to `--all`. Dates are formatted as strict UTC ISO-8601, which git accepts
    /// for `--since`/`--until`.
    public func gitArguments() -> [String] {
        var arguments: [String] = []
        // A named ref is a *positional revision*, so it must follow every option
        // (and `--end-of-options`); buffer it here and append it after the options.
        var namedRef: String?

        switch refSelection {
        case .all:
            arguments.append("--all")
        case .ref(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank ref name would make `git log` fall back to HEAD silently;
            // treat it as "all" so the query is never accidentally narrowed.
            if trimmed.isEmpty {
                arguments.append("--all")
            } else {
                namedRef = trimmed
            }
        }

        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            arguments.append("--author=\(author)")
        }

        if let since {
            arguments.append("--since=\(Self.iso(since))")
        }
        if let until {
            arguments.append("--until=\(Self.iso(until))")
        }

        // After all options: the positional revision, protected against being
        // parsed as an option by `--end-of-options`.
        if let namedRef {
            arguments.append(contentsOf: ["--end-of-options", namedRef])
        }

        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            arguments.append(contentsOf: ["--", path])
        }

        return arguments
    }

    /// Whether this filter can yield a *non-contiguous* slice of history — one in
    /// which a shown commit names a parent that the filter excluded — which the
    /// branch graph cannot represent (it would open lanes seeking parents that
    /// never appear below, drawing dangling/unrelated lines down the gutter).
    ///
    /// Ref selection (`.all`/`.ref`) walks a connected ancestry, and a `path`
    /// pathspec triggers git's *parent rewriting* (because the service passes
    /// `--parents`): the shown parent pointers are rewritten to the nearest
    /// included ancestor, so the slice stays contiguous. The commit-limiting
    /// options `--author`/`--since`/`--until` do **not** rewrite parents — they
    /// simply omit non-matching commits — so any of them can leave a shown commit
    /// pointing at an omitted parent. The view suppresses the graph when this is
    /// true, exactly as it already does for the client-side message search.
    public var mayProduceNonContiguousHistory: Bool {
        let hasAuthor = !(author?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        return hasAuthor || since != nil || until != nil
    }

    /// The ref this filter should *display* as selected, given the set of refs the
    /// repository actually knows (`references`), or `nil` for "all refs".
    ///
    /// `.all` resolves to `nil` (the view maps `nil` onto its own "All" sentinel
    /// tag). A `.ref(name)` resolves to `name` only when it is present in
    /// `references`; an unknown/dangling ref (one the current repo no longer has —
    /// e.g. a stale selection left over from a previous folder) degrades to `nil`
    /// ("all"), mirroring `gitArguments()`'s refusal to silently narrow the query.
    ///
    /// Pure resolution shared by the filter bar's branch picker: the picker reads
    /// its current value straight from `filter` through this helper (rather than a
    /// mirrored `@State`), so a model-published filter change never looks like a
    /// user selection and cannot drive a refetch loop.
    public func resolvedRef(amongKnown references: [String]) -> String? {
        switch refSelection {
        case .all:
            return nil
        case .ref(let name):
            return references.contains(name) ? name : nil
        }
    }

    /// Strict ISO-8601 in UTC (e.g. `1970-01-01T00:00:00Z`), so the formatting is
    /// locale/timezone-independent and the arguments are deterministic.
    private static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Client-side message search

    /// Filter `commits` to those matching `query` by subject, case-insensitively.
    ///
    /// A blank `query` (empty or whitespace-only) returns the list unchanged. The
    /// match is a case-insensitive substring of the commit subject — the "filter by
    /// message" box — and runs entirely over the already-loaded commits, so typing in
    /// the search field never re-queries git.
    public static func search(_ commits: [Commit], query: String) -> [Commit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return commits }
        return commits.filter {
            $0.subject.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}
