import Foundation

/// The diagnostics currently on screen, keyed by document URL — the store both
/// consumers read: the editor overlay asks "what covers this buffer", the ruler
/// asks "what marks this line", and the Problems panel asks "what lists, in
/// what order".
///
/// A **value type**, so it can live inside an `ObservableObject` model (the
/// `DiagnosticsModel`, Task 4's file) and be handed around by copy like
/// `SymbolIndex`. Every mutation is wholesale or per-document; nothing here
/// ranks, filters by language, or touches a server. Provenance is kept per
/// entry — *which* server reported a document's set — because two of the
/// clearing rules are keyed by that provenance (D33). The push's wire version
/// is deliberately not stored: the acceptance gate reads it off the model's own
/// sync records, so keeping a second copy here would be state nobody reads.
///
/// The server key mirrors `LSPWorkspace.ServerKey`'s `(serverID, root)` pair as
/// its own public value rather than exposing the workspace's internal one:
/// clearing is keyed by the pair (D33), and Core's LSP layer must stay
/// importable without dragging the whole workspace type into every signature.
///
/// Foundation-only and purely in-memory; the disk is nobody's state here.
public struct DiagnosticStore: Equatable, Sendable {
    /// Which server's answers these are: one language server, one project root.
    /// The canonical root path makes the same folder reached through a symlink
    /// one key, matching how the workspace keys its sessions.
    public struct ServerKey: Hashable, Sendable {
        public let serverID: String
        public let root: String

        public init(serverID: String, root: String) {
            self.serverID = serverID
            self.root = root
        }
    }

    /// One document's set plus the provenance that produced it.
    public struct Entry: Equatable, Sendable {
        /// Ordered however the last push arrived; the queries impose order.
        public var diagnostics: [Diagnostic]
        public let serverKey: ServerKey

        public init(diagnostics: [Diagnostic], serverKey: ServerKey) {
            self.diagnostics = diagnostics
            self.serverKey = serverKey
        }
    }

    /// The header's two numbers. Information and hint are deliberately absent:
    /// the header answers "how much is broken", not "how much was said" —
    /// counted here, once, so no view restates the rule.
    public struct Counts: Equatable, Sendable {
        public let errors: Int
        public let warnings: Int

        public init(errors: Int, warnings: Int) {
            self.errors = errors
            self.warnings = warnings
        }
    }

    /// One row of the Problems panel: a single diagnostic flattened to what the
    /// list renders — severity icon, message, and the one-based line; `source`
    /// is deliberately not carried, because nothing on screen shows it.
    ///
    /// `Hashable` so the SwiftUI list can key rows by **content** rather than by
    /// offset: an insertion above an earlier row must not shift every
    /// subsequent row's identity (a stateful row view would otherwise carry its
    /// hover highlight onto a different message). Content-keyed identity is
    /// only sound when the content is unique, which is why
    /// ``rows(relativeTo:)`` — not this type — collapses byte-identical rows:
    /// a `ForEach` keyed on `\.self` with two equal elements is undefined
    /// behavior, not a merge.
    public struct Row: Equatable, Hashable, Sendable {
        public let severity: DiagnosticSeverity
        public let message: String
        /// The span in the buffer, for open-and-reveal.
        public let range: NSRange
        /// The zero-based line it starts on, as stored.
        public let line: Int

        init(_ diagnostic: Diagnostic) {
            severity = diagnostic.severity
            message = diagnostic.message
            range = diagnostic.range
            line = diagnostic.line
        }
    }

    /// One file's rows, with the display path the panel shows.
    public struct FileRows: Equatable, Sendable {
        public let url: URL
        /// Path components relative to the project root when the file lives
        /// inside it; absolute components otherwise. Components, not a joined
        /// string, so the view picks its separator — `DisplayPath`'s rule.
        public let pathComponents: [String]
        /// Ordered by ``Diagnostic/orderingKey`` within the file.
        public let rows: [Row]
    }

    /// Keyed by `url.standardizedFileURL`, so `/a/b.swift` spelled with a
    /// trailing dot-path or differently-cased drive still matches itself; the
    /// canonical probe stays out on purpose — same-file identity across symlink
    /// spellings is decided once by `CanonicalPath` at the model boundary, not
    /// re-derived under every key here.
    private var entries: [URL: Entry] = [:]

    public init() {}

    // MARK: - Mutations

    /// Wholesale replacement — LSP semantics: a push for a URI replaces
    /// everything previously known for it, including the empty push ("all
    /// clear"), which must land as an empty entry rather than a missing one so
    /// provenance survives for the next comparison.
    ///
    /// The wire version a push may carry is deliberately not part of the entry:
    /// the model's acceptance gate reads versions off its own sync records, so
    /// storing one here would be write-only state.
    public mutating func replace(
        url: URL,
        serverKey: ServerKey,
        diagnostics: [Diagnostic]
    ) {
        entries[url.standardizedFileURL] = Entry(
            diagnostics: diagnostics,
            serverKey: serverKey
        )
    }

    /// Forget one document — `didClose`, a tab close, a buffer replaced.
    public mutating func clear(url: URL) {
        entries.removeValue(forKey: url.standardizedFileURL)
    }

    /// Forget every document one server answered for — D33's teardown clears:
    /// a death, a shutdown, an un-registration, the fourth-failure
    /// unavailability.
    public mutating func clear(serverKey: ServerKey) {
        entries = entries.filter { $0.value.serverKey != serverKey }
    }

    /// Forget everything — the folder changed; no answer survives the move.
    public mutating func clearAll() {
        entries.removeAll()
    }

    /// Install the array `DiagnosticShift.updated(...)` produced for a document,
    /// keeping its provenance intact. No entry for `url` means nothing to shift
    /// and nothing invented: shifting is defined only over a set a server
    /// produced, and minting an entry would fabricate provenance the acceptance
    /// gate would then trust. An empty shifted array still installs — after a
    /// keystroke dropped the one error there was, "no known problems" is true
    /// until the next push says otherwise.
    public mutating func apply(shift: [Diagnostic], to url: URL) {
        guard var entry = entries[url.standardizedFileURL] else { return }
        entry.diagnostics = shift
        entries[url.standardizedFileURL] = entry
    }

    // MARK: - Queries

    /// The full entry behind a document, when one is held.
    public func entry(for url: URL) -> Entry? {
        entries[url.standardizedFileURL]
    }

    /// Every diagnostic whose range contains `offset`, ordered by
    /// ``Diagnostic/orderingKey`` — hover's lookup (D34).
    ///
    /// Containment follows the half-open convention `[start, end)` — hovering
    /// just past a squiggle's last character is not hovering it — with the one
    /// exception the convention would make unhittable: a zero-length diagnostic
    /// contains exactly its own offset, so pointing at it still finds it.
    public func diagnostics(at offset: Int, in url: URL) -> [Diagnostic] {
        guard let entry = entries[url.standardizedFileURL] else { return [] }
        return entry
            .diagnostics
            .filter { diagnostic in
                let start = diagnostic.range.location
                let end = start + diagnostic.range.length
                if diagnostic.range.length == 0 { return offset == start }
                return start <= offset && offset < end
            }
            .sorted { $0.orderingKey < $1.orderingKey }
    }

    /// Worst severity per line, at exactly `lineCount` entries — the ruler
    /// indexes the result by line, so the `BlameShift` invariant
    /// (`result.count == what the caller indexes by`) is applied here rather
    /// than hoped for downstream.
    ///
    /// The plan named this query `(url:lineCount:)`; it grew one parameter for
    /// a reason worth stating: marking **every line a multi-line diagnostic
    /// spans** needs the line geometry (where does the span's end land?), which
    /// the store deliberately does not keep — it stores offsets and one start
    /// line per diagnostic, no text and no tables. The caller already holds the
    /// ruler's line-start array at the call site, so passing it costs nothing.
    ///
    /// Inconsistent geometry degrades honestly: an empty or unanchored table,
    /// or a negative count, yields all-`nil` at exactly `lineCount` — a blank
    /// marker column, never a crash indexing past the array. A diagnostic whose
    /// stored `line` falls outside the requested window is skipped rather than
    /// clamped onto line 0, where it would be a lie.
    public func worstSeverityPerLine(
        url: URL,
        lineCount: Int,
        lineStarts: [Int]
    ) -> [DiagnosticSeverity?] {
        guard lineCount > 0, lineStarts.first == 0 else {
            return Array(repeating: nil, count: max(0, lineCount))
        }
        var result = [DiagnosticSeverity?](repeating: nil, count: lineCount)
        guard let entry = entries[url.standardizedFileURL] else { return result }
        for diagnostic in entry.diagnostics {
            guard diagnostic.line < lineCount else { continue }
            // The last line the span touches: for a zero-length range its own
            // line; otherwise the line containing the last covered character
            // (`end - 1`, exclusive end), then clamped into the window. The
            // arithmetic is overflow-checked like every offset sum in this
            // layer: a garbage span skips rather than traps.
            let (end, endOverflowed) = diagnostic.range.location
                .addingReportingOverflow(diagnostic.range.length)
            guard !endOverflowed else { continue }
            let lastCovered = diagnostic.range.length > 0 ? end - 1 : diagnostic.range.location
            let lastLine = min(LSPPositionMap.lineIndex(containing: lastCovered, lineStarts: lineStarts), lineCount - 1)
            for line in diagnostic.line...max(diagnostic.line, lastLine) {
                // Worst severity wins; `.error` is Comparable's greatest case.
                result[line] = max(result[line] ?? diagnostic.severity, diagnostic.severity)
            }
        }
        return result
    }

    /// The panel's rows: one `FileRows` per diagnosed document, files ordered
    /// by path, rows within a file by ``Diagnostic/orderingKey`` — the stable
    /// reading order decided once on the value type.
    ///
    /// Byte-identical rows are collapsed here, deliberately: two diagnostics
    /// that flatten to the same severity, message, span and line render — and
    /// activate — identically, and the view keys its `ForEach` on exactly these
    /// fields (`Row`'s note), where duplicate ids are undefined behavior rather
    /// than a merge. The collapse is a *rendering* rule, not a store one: the
    /// entry keeps every diagnostic, so the overlay, the gutter, hover and
    /// ``counts`` all still see both.
    ///
    /// The relative path reuses `CanonicalPath`'s primitives through the same
    /// two-probe order `DisplayPath.relativeComponents(of:under:)` documents
    /// (lexical first, canonical fallback), minus the home fallback: a file
    /// outside the root shows its absolute components, because the panel has no
    /// `~` story of its own and inventing one would disagree with the
    /// breadcrumb's spelling of the same file.
    public func rows(relativeTo root: URL) -> [FileRows] {
        entries
            .filter { !$0.value.diagnostics.isEmpty }
            .map { url, entry -> FileRows in
                var seen = Set<Row>()
                let rows = entry.diagnostics
                    .sorted { $0.orderingKey < $1.orderingKey }
                    .map(Row.init)
                    .filter { seen.insert($0).inserted }
                return FileRows(
                    url: url,
                    pathComponents: Self.pathComponents(of: url, relativeTo: root),
                    rows: rows
                )
            }
            .sorted { lhs, rhs in
                if lhs.pathComponents != rhs.pathComponents {
                    return lhs.pathComponents.lexicographicallyPrecedes(rhs.pathComponents)
                }
                return lhs.url.absoluteString < rhs.url.absoluteString
            }
    }

    /// Errors and warnings across every document — the header's numbers.
    public var counts: Counts {
        var errors = 0
        var warnings = 0
        for entry in entries.values {
            for diagnostic in entry.diagnostics {
                switch diagnostic.severity {
                case .error: errors += 1
                case .warning: warnings += 1
                case .information, .hint: break
                }
            }
        }
        return Counts(errors: errors, warnings: warnings)
    }

    // MARK: - Path helpers

    /// Display components for a url against the panel's root: strictly-below
    /// components when the file lives inside it (lexical probe first, canonical
    /// fallback — `DisplayPath.relativeComponents`' order, for its documented
    /// reason), absolute standardized components otherwise.
    private static func pathComponents(of url: URL, relativeTo root: URL) -> [String] {
        if let suffix = CanonicalPath.relativeComponents(
            of: url.standardizedFileURL.pathComponents,
            under: root.standardizedFileURL.pathComponents
        ) {
            return suffix
        }
        if let suffix = CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(url).pathComponents,
            under: CanonicalPath.canonical(root).pathComponents
        ) {
            return suffix
        }
        return Array(url.standardizedFileURL.pathComponents.drop { $0 == "/" })
    }
}
