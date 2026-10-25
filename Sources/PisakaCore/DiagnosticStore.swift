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
    ///
    /// The set is one of two kinds, and the kind is a type rather than a flag:
    /// a **mapped** set was mapped onto a buffer the workspace holds and carries
    /// UTF-16 offsets; a **positional** set describes a document no buffer holds
    /// and carries the server's positions only. Editor-facing readers go through
    /// ``mapped``, which is `nil` for a positional entry, so a positional set can
    /// never reach a squiggle, the gutter, hover, the edit shift or problem
    /// navigation.
    public struct Entry: Equatable, Sendable {
        public var payload: Payload
        public let serverKey: ServerKey

        public init(payload: Payload, serverKey: ServerKey) {
            self.payload = payload
            self.serverKey = serverKey
        }

        /// The buffer-mapped set, or `nil` for a positional entry — the only
        /// accessor an editor-facing reader uses.
        public var mapped: [Diagnostic]? {
            guard case .mapped(let diagnostics) = payload else { return nil }
            return diagnostics
        }

        /// The server-positioned set, or `nil` for a mapped entry.
        public var positional: [PositionalDiagnostic]? {
            guard case .positional(let diagnostics) = payload else { return nil }
            return diagnostics
        }

        /// Every severity the set holds, whichever kind it is — what the counts
        /// read, so the header's numbers span closed files too.
        var severities: [DiagnosticSeverity] {
            switch payload {
            case .mapped(let diagnostics): return diagnostics.map(\.severity)
            case .positional(let diagnostics): return diagnostics.map(\.severity)
            }
        }
    }

    /// The two kinds of set an ``Entry`` can hold. Each is ordered however the
    /// last push arrived; the queries impose order.
    public enum Payload: Equatable, Sendable {
        case mapped([Diagnostic])
        case positional([PositionalDiagnostic])
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

    /// Where activating a panel ``Row`` lands, in the coordinates its kind
    /// carries: buffer offsets for a mapped diagnostic, the server's range for
    /// a positional one. ``Row/rangeToReveal(in:)`` turns either into a buffer
    /// range against the text the file opened with.
    public enum RevealTarget: Equatable, Hashable, Sendable {
        case offsets(NSRange)
        case position(LSPRange)
    }

    /// One row of the Problems panel: a single diagnostic flattened to what the
    /// list renders — severity icon, message, and the one-based line — plus the
    /// target activation reveals; `source` is deliberately not carried, because
    /// nothing on screen shows it.
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
        public let target: RevealTarget
        /// The zero-based line it starts on: the stored line for a mapped
        /// diagnostic, the server's start line for a positional one.
        public let line: Int

        /// The one-based line the panel shows beside the message — what the
        /// user reads in the gutter. Total: a positional row's `line` is a
        /// number a *server* sent, decoded straight off the wire, so `line + 1`
        /// with an `Int.max` in it would trap the app on one malformed report.
        /// A negative line reads as the first, as `LSPPositionMap` clamps it.
        public var displayLine: Int {
            line < 0 ? 1 : line == .max ? line : line + 1
        }

        init(_ diagnostic: Diagnostic) {
            severity = diagnostic.severity
            message = diagnostic.message
            target = .offsets(diagnostic.range)
            line = diagnostic.line
        }

        init(_ diagnostic: PositionalDiagnostic) {
            severity = diagnostic.severity
            message = diagnostic.message
            target = .position(diagnostic.range)
            line = diagnostic.range.start.line
        }

        /// The buffer range to reveal for this row in `text` — the buffer the
        /// file holds once activation has opened it. Total: it never traps and
        /// never refuses.
        ///
        /// A positional target is mapped through
        /// `LSPPositionMap.range(for:in:)` with its clamping, so a line past the
        /// end lands at the end of the text and a character past its line at
        /// that line's end. A mapped target was mapped against the buffer it
        /// describes; it is clamped into `text`'s length only so a buffer that
        /// changed underneath the row cannot hand TextKit a range it traps on,
        /// which leaves an in-range range unchanged.
        public func rangeToReveal(in text: NSString) -> NSRange {
            switch target {
            case .position(let range):
                return LSPPositionMap.range(for: range, in: text)
            case .offsets(let range):
                let location = min(max(0, range.location), text.length)
                let length = min(max(0, range.length), text.length - location)
                return NSRange(location: location, length: length)
            }
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

        /// The panel's file order: by path components, ties (the same
        /// components reached by two spellings) by absolute URL — total, so the
        /// full build and an incremental merge agree on every list.
        static func precedes(_ lhs: FileRows, _ rhs: FileRows) -> Bool {
            if lhs.pathComponents != rhs.pathComponents {
                return lhs.pathComponents.lexicographicallyPrecedes(rhs.pathComponents)
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
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
            payload: .mapped(diagnostics),
            serverKey: serverKey
        )
    }

    /// Wholesale replacement with a positional set — the report for a document
    /// no buffer holds. The same LSP semantics as the mapped replacement: it
    /// replaces whatever was known for the URI, whichever kind that was, and an
    /// empty report installs an empty entry so provenance survives.
    public mutating func replace(
        url: URL,
        serverKey: ServerKey,
        positional diagnostics: [PositionalDiagnostic]
    ) {
        entries[url.standardizedFileURL] = Entry(
            payload: .positional(diagnostics),
            serverKey: serverKey
        )
    }

    /// Forget one document's **mapped** set — a buffer replaced wholesale.
    ///
    /// A positional entry is left alone: it never described a buffer, so a
    /// buffer's replacement cannot have made it stale. That is what lets a file
    /// being opened keep showing its positional record in the panel and the tree
    /// until the first mapped report replaces it.
    public mutating func clearMapped(url: URL) {
        let key = url.standardizedFileURL
        guard entries[key]?.mapped != nil else { return }
        entries.removeValue(forKey: key)
    }

    /// Forget every document one server answered for — D33's teardown clears:
    /// a death, a shutdown, an un-registration, the fourth-failure
    /// unavailability.
    public mutating func clear(serverKey: ServerKey) {
        entries = entries.filter { $0.value.serverKey != serverKey }
    }

    /// Forget every document at or under `url`, both kinds — the app removed
    /// or moved that file or folder away, so whatever was known about the old
    /// path describes a file that no longer exists there.
    ///
    /// Compared by whole standardized path component, lexically, like every
    /// key here: a sibling whose name merely starts with the removed one's
    /// survives.
    public mutating func clear(under url: URL) {
        let removed = url.standardizedFileURL.pathComponents
        entries = entries.filter { key, _ in
            let components = key.pathComponents
            return components != removed
                && CanonicalPath.relativeComponents(of: components, under: removed) == nil
        }
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
    ///
    /// Installs only onto a **mapped** entry: a shift is computed from buffer
    /// offsets, and a positional entry has none to shift.
    public mutating func apply(shift: [Diagnostic], to url: URL) {
        let key = url.standardizedFileURL
        guard var entry = entries[key], entry.mapped != nil else { return }
        entry.payload = .mapped(shift)
        entries[key] = entry
    }

    // MARK: - Queries

    /// The full entry behind a document, when one is held.
    public func entry(for url: URL) -> Entry? {
        entries[url.standardizedFileURL]
    }

    /// Every entry, keyed by its standardized URL — what `TreeDiagnostics`
    /// walks to build the tree's lookup.
    var entriesByURL: [URL: Entry] { entries }

    /// Every diagnostic whose range contains `offset`, ordered by
    /// ``Diagnostic/orderingKey`` — hover's lookup (D34).
    ///
    /// Containment follows the half-open convention `[start, end)` — hovering
    /// just past a squiggle's last character is not hovering it — with the one
    /// exception the convention would make unhittable: a zero-length diagnostic
    /// contains exactly its own offset, so pointing at it still finds it.
    public func diagnostics(at offset: Int, in url: URL) -> [Diagnostic] {
        guard let mapped = entries[url.standardizedFileURL]?.mapped else { return [] }
        let hits = mapped
            .filter { diagnostic in
                let start = diagnostic.range.location
                let end = start + diagnostic.range.length
                if diagnostic.range.length == 0 { return offset == start }
                return start <= offset && offset < end
            }
        return Diagnostic.sortedByOrderingKey(hits)
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
    /// **Both ends of the marked band come from the caller's table**, never from
    /// the stored ``Diagnostic/line``. That number counts lines the way the
    /// *mapping* table did (LSP's separators, D1) and is only ever printed — the
    /// panel's `:N` suffix. Reading it as geometry here would mix two
    /// numberings: in a file delimited by NEL/LS/PS the editor counts lines the
    /// LSP table does not, so a one-line diagnostic would paint a band as tall
    /// as every exotic separator above it. The contract stated on `Diagnostic`
    /// ("geometry consumers go through the editor's own table") is therefore
    /// applied here rather than assumed.
    ///
    /// Inconsistent geometry degrades honestly: an empty or unanchored table,
    /// or a negative count, yields all-`nil` at exactly `lineCount` — a blank
    /// marker column, never a crash indexing past the array. A diagnostic that
    /// starts outside the requested window is skipped rather than clamped onto
    /// line 0, where it would be a lie — **outside on either side**: the mapping
    /// never mints a negative offset, but `Diagnostic` is a public value type
    /// with a public memberwise init, so the guard screens the lower bound too
    /// rather than trusting a caller this method never met.
    public func worstSeverityPerLine(
        url: URL,
        lineCount: Int,
        lineStarts: [Int]
    ) -> [DiagnosticSeverity?] {
        guard lineCount > 0, lineStarts.first == 0 else {
            return Array(repeating: nil, count: max(0, lineCount))
        }
        var result = [DiagnosticSeverity?](repeating: nil, count: lineCount)
        guard let mapped = entries[url.standardizedFileURL]?.mapped else { return result }
        for diagnostic in mapped {
            guard diagnostic.range.location >= 0 else { continue }
            // The last line the span touches: for a zero-length range its own
            // line; otherwise the line containing the last covered character
            // (`end - 1`, exclusive end), then clamped into the window. The
            // arithmetic is overflow-checked like every offset sum in this
            // layer: a garbage span skips rather than traps.
            let (end, endOverflowed) = diagnostic.range.location
                .addingReportingOverflow(diagnostic.range.length)
            guard !endOverflowed else { continue }
            // The first line, from the same table as the last — see the note
            // above on why the stored `line` is not read here.
            let firstLine = LSPPositionMap.lineIndex(containing: diagnostic.range.location, lineStarts: lineStarts)
            guard firstLine < lineCount else { continue }
            let lastCovered = diagnostic.range.length > 0 ? end - 1 : diagnostic.range.location
            let lastLine = min(LSPPositionMap.lineIndex(containing: lastCovered, lineStarts: lineStarts), lineCount - 1)
            for line in firstLine...max(firstLine, lastLine) {
                // Worst severity wins; `.error` is Comparable's greatest case.
                result[line] = max(result[line] ?? diagnostic.severity, diagnostic.severity)
            }
        }
        return result
    }

    /// The panel's rows: one `FileRows` per document with a non-empty set of
    /// either kind — a closed file's positional set lists beside an open
    /// file's mapped one — files ordered by path, rows within a file by
    /// ``Diagnostic/orderingKey``, the one key both kinds share, so the stable
    /// reading order is decided once on the value types.
    ///
    /// Byte-identical rows are collapsed here, deliberately: two diagnostics
    /// that flatten to the same severity, message, target and line render —
    /// and activate — identically, and the view keys its `ForEach` on exactly
    /// these fields (`Row`'s note), where duplicate ids are undefined behavior
    /// rather than a merge. The collapse is a *rendering* rule, not a store
    /// one: the entry keeps every diagnostic, so the overlay, the gutter, hover
    /// and ``counts`` all still see both.
    ///
    /// The relative path reuses `CanonicalPath`'s primitives through the same
    /// two-probe order `DisplayPath.relativeComponents(of:under:)` documents
    /// (lexical first, canonical fallback), minus the home fallback: a file
    /// outside the root shows its absolute components, because the panel has no
    /// `~` story of its own and inventing one would disagree with the
    /// breadcrumb's spelling of the same file.
    public func rows(relativeTo root: URL) -> [FileRows] {
        entries.keys
            .compactMap { fileRows(for: $0, relativeTo: root) }
            .sorted(by: FileRows.precedes)
    }

    /// One document's group of ``rows(relativeTo:)`` — `nil` when it holds no
    /// entry or an empty set. The per-file half of the full build, so a caller
    /// that keeps the groups can rebuild exactly the documents a mutation
    /// touched (`DiagnosticsModel`'s panel cache) and reach the same answer.
    func fileRows(for url: URL, relativeTo root: URL) -> FileRows? {
        let key = url.standardizedFileURL
        guard let entry = entries[key] else { return nil }
        let ordered: [Row]
        switch entry.payload {
        case .mapped(let diagnostics):
            ordered = Diagnostic.sortedByOrderingKey(diagnostics).map(Row.init)
        case .positional(let diagnostics):
            ordered = PositionalDiagnostic.sortedByOrderingKey(diagnostics).map(Row.init)
        }
        guard !ordered.isEmpty else { return nil }
        var seen = Set<Row>()
        return FileRows(
            url: key,
            pathComponents: Self.pathComponents(of: key, relativeTo: root),
            rows: ordered.filter { seen.insert($0).inserted }
        )
    }

    /// Errors and warnings across every document, both kinds — the header's
    /// numbers.
    public var counts: Counts {
        var errors = 0
        var warnings = 0
        for entry in entries.values {
            for severity in entry.severities {
                switch severity {
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
