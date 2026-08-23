import Foundation

/// How serious a diagnostic is, in the editor's own vocabulary — not the wire's.
///
/// The wire value is `LSPDiagnosticSeverity` (an open set); this is the closed
/// set the gutter, the squiggle and the panel switch over. The conversion is
/// deliberately total: **an absent or unknown severity becomes `.error`**, which
/// is what the spec's "if the client doesn't know, it decides" means for an
/// editor that must not hide a failure — an unrecognised number is more plausibly
/// a server naming a problem it considers serious than one it considers trivia,
/// so the benefit of the doubt goes to red.
///
/// `Comparable` orders by *seriousness*, with `.error` the **greatest** element,
/// so `max` across the diagnostics touching one line answers exactly the question
/// the gutter asks ("what should this line's marker show"). The order is
/// therefore the reverse of the raw wire values, which is why `<` is written out
/// rather than derived from `rawValue`.
public enum DiagnosticSeverity: Int, Sendable, Hashable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
    /// The LSP integer → severity. Absent (`nil`) and unrecognised values both
    /// land on `.error`, per the rule above; a recognised value maps directly.
    public init(lspValue: Int?) {
        guard let lspValue, let known = DiagnosticSeverity(rawValue: lspValue) else {
            self = .error
            return
        }
        self = known
    }

    /// The severity's spoken form — the word hover prefixes a diagnostic's
    /// message with (D34), lowercase because that is how servers and compilers
    /// name severities in the output a developer already reads.
    public var label: String {
        switch self {
        case .error: return "error"
        case .warning: return "warning"
        case .information: return "information"
        case .hint: return "hint"
        }
    }

    /// Higher is more serious; the input to both `<` and `OrderingKey`.
    private var seriousnessRank: Int {
        switch self {
        case .error: return 3
        case .warning: return 2
        case .information: return 1
        case .hint: return 0
        }
    }

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.seriousnessRank < rhs.seriousnessRank
    }
}

/// Ordered by seriousness, `.error` greatest — see `<` above.
extension DiagnosticSeverity: Comparable {}

/// One diagnostic anchored to the editor's coordinate system: a UTF-16 buffer
/// range plus the line it starts on, with the message and metadata to display.
///
/// This is the post-`LSPPositionMap` shape — everything downstream (the overlay
/// manager, the ruler, the store, the panel) works in buffer offsets and never
/// sees an LSP position again. `line` counts lines the way the mapping table did
/// (`LSPPositionMap.lineStarts(in:)`, LSP's separators), which differs from the
/// editor's count only in a file delimited by NEL/LS/PS — the divergence D1
/// already documents as bounded. Geometry consumers (the gutter's marker column,
/// the squiggles) go through the editor's own table; the one place the number is
/// *printed* raw is the Problems panel's `:N` suffix, where it can differ from
/// the gutter's on that same row — stated as a known limit in `core-lsp.md`
/// rather than laundered through a second table here.
public struct Diagnostic: Equatable, Hashable, Sendable {
    /// The span in the buffer, UTF-16 offsets, already clamped by the mapping.
    public var range: NSRange
    /// The zero-based line `range.location` starts on, per the mapping table.
    public var line: Int
    public var severity: DiagnosticSeverity
    public var message: String
    public var source: String?
    public var fileURL: URL

    public init(
        range: NSRange,
        line: Int,
        severity: DiagnosticSeverity,
        message: String,
        source: String?,
        fileURL: URL
    ) {
        self.range = range
        self.line = line
        self.severity = severity
        self.message = message
        self.source = source
        self.fileURL = fileURL
    }
}

// MARK: - Mapping

public extension Diagnostic {
    /// Map one wire diagnostic onto the buffer it describes.
    ///
    /// Positions go through `LSPPositionMap` against the text the *server was
    /// told* (D31) — the same text every other answer of that session is mapped
    /// against — using the caller's precomputed line-start table, so a whole
    /// push of N diagnostics scans the buffer once, not N times.
    ///
    /// An out-of-range position clamps rather than rejects: a line past the end
    /// lands at the end of the buffer, a character past its line at that line's
    /// content end, which is what makes a push computed against slightly stale
    /// text still point somewhere honest instead of vanishing. The one outcome
    /// that *cannot* be placed — a range whose mapped bounds fall outside the
    /// buffer, unreachable through today's clamping rules but kept as a gate so
    /// a future change to those rules cannot hand TextKit an `NSRange` it traps
    /// on — returns `nil` and drops the entry.
    static func make(
        from lsp: LSPDiagnostic,
        in content: NSString,
        lineStarts: [Int],
        url: URL
    ) -> Diagnostic? {
        let bufferRange = LSPPositionMap.range(for: lsp.range, in: content, lineStarts: lineStarts)
        guard bufferRange.location >= 0,
              bufferRange.location <= content.length,
              bufferRange.location + bufferRange.length <= content.length else {
            return nil
        }
        return Diagnostic(
            range: bufferRange,
            line: LSPPositionMap.lineIndex(containing: bufferRange.location, lineStarts: lineStarts),
            severity: DiagnosticSeverity(lspValue: lsp.severity?.rawValue),
            message: lsp.message,
            source: lsp.source,
            fileURL: url
        )
    }
}

// MARK: - Ordering

public extension Diagnostic {
    /// The panel's stable order, decided here rather than in the view because
    /// two surfaces (the Problems list and hover's merged messages) must agree
    /// on it.
    ///
    /// The key is a **total** order — no two distinct diagnostics compare equal
    /// — so a sort is stable regardless of the sort algorithm's own stability:
    /// grouped by file path, then top-to-bottom through the buffer, then most
    /// severe first at one start — severity outranks every remaining field, so
    /// the worst complaint at a position is always the one read first — then
    /// shorter span, message and source lexicographically among equals, which
    /// is what keeps two same-position same-severity complaints from tying.
    /// Every field
    /// a diagnostic can differ in but `line` participates (`line` is derived
    /// from the start offset by the mapping, never an independent fact), so two
    /// keys compare equal only when the diagnostics do.
    struct OrderingKey: Equatable, Comparable {
        public let filePath: String
        public let startOffset: Int
        public let endOffset: Int
        public let severity: DiagnosticSeverity
        public let message: String
        public let source: String?

        public init(
            path: String,
            startOffset: Int,
            endOffset: Int,
            severity: DiagnosticSeverity,
            message: String,
            source: String?
        ) {
            self.filePath = path
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.severity = severity
            self.message = message
            self.source = source
        }

        init(_ diagnostic: Diagnostic) {
            self.init(
                path: diagnostic.fileURL.standardizedFileURL.path,
                startOffset: diagnostic.range.location,
                endOffset: diagnostic.range.location + diagnostic.range.length,
                severity: diagnostic.severity,
                message: diagnostic.message,
                source: diagnostic.source
            )
        }

        public static func < (lhs: OrderingKey, rhs: OrderingKey) -> Bool {
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.endOffset != rhs.endOffset { return lhs.endOffset < rhs.endOffset }
            if lhs.message != rhs.message { return lhs.message < rhs.message }
            // Spelled out rather than through `Optional`'s own Comparable
            // conformance: absent sorts before any present value, including the
            // empty string, so a missing source stays distinct from a blank one.
            switch (lhs.source, rhs.source) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let lhsSource?, let rhsSource?): return lhsSource < rhsSource
            }
        }
    }

    /// Where this diagnostic sorts, per the rules on `OrderingKey`.
    var orderingKey: OrderingKey { OrderingKey(self) }
}

// MARK: - Hover (D34)

public extension Diagnostic {
    /// The hover popover's content for a pointer resting on `diagnostics`
    /// (D34): each message as a severity-labelled prose segment in
    /// ``orderingKey`` order, above `typeAnswer`'s segments when there is one
    /// and alone when there is not.
    ///
    /// The labels are what make a bare message readable — "value of type X has
    /// no member" without its "error:" reads as documentation rather than as a
    /// complaint — and the order is the panel's, decided here for the same
    /// reason the key exists: two surfaces must agree on it without consulting
    /// each other.
    ///
    /// **The cap machinery is not applied twice.** Building goes through the
    /// `HoverContent` checking initializer, which is where D26's two length caps
    /// already run on every hover answer; cutting to a *line count* stays the
    /// renderer's call at presentation (`truncated(toLineCount:)`), exactly as
    /// for a plain type answer. Nothing here truncates again — the merged value
    /// travels the one path a server's answer always took.
    ///
    /// `nil` only when there is nothing to draw at all: an empty set with no
    /// type answer — or messages that normalize to nothing — is "no popover",
    /// never an empty one (D25). An empty set with a type answer falls through
    /// to that answer **unchanged** — segments and truncation mark alike;
    /// there are no diagnostics, so there is nothing to merge above it.
    static func hoverContent(
        for diagnostics: [Diagnostic],
        merging typeAnswer: HoverContent?
    ) -> HoverContent? {
        guard !diagnostics.isEmpty else { return typeAnswer }
        let ordered = diagnostics.sorted { $0.orderingKey < $1.orderingKey }
        let labelled = ordered.map { diagnostic in
            HoverSegment.prose("\(diagnostic.severity.label): \(diagnostic.message)")
        }
        return HoverContent(
            segments: labelled + (typeAnswer?.segments ?? []),
            isTruncated: typeAnswer?.isTruncated ?? false
        )
    }
}
