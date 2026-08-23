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

    /// The wire integer for this severity — the "both ways" half of the table.
    public var lspValue: Int { rawValue }

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
/// already documents as bounded and invisible, since no line number from here is
/// ever printed next to the gutter's own numbering without going through
/// `LineStartIndex`.
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
            line: lineIndex(containing: bufferRange.location, lineStarts: lineStarts),
            severity: DiagnosticSeverity(lspValue: lsp.severity?.rawValue),
            message: lsp.message,
            source: lsp.source,
            fileURL: url
        )
    }

    /// Binary search for the line whose start is the greatest one `<= offset`;
    /// an empty table (which `LSPPositionMap.lineStarts` never produces) reads
    /// as one line starting at zero.
    private static func lineIndex(containing offset: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}

// MARK: - Ordering

public extension Diagnostic {
    /// The panel's stable order, decided here rather than in the view because
    /// two surfaces (the Problems list and hover's merged messages) must agree
    /// on it.
    ///
    /// The key is a **total** order — no two diagnostics compare equal unless
    /// they are equal — so a sort is stable regardless of the sort algorithm's
    /// own stability: grouped by file path, then top-to-bottom through the
    /// buffer, then most severe first within one position (the error sitting on
    /// a token outranks the hint sharing its start).
    struct OrderingKey: Equatable, Comparable {
        public let filePath: String
        public let startOffset: Int
        public let severity: DiagnosticSeverity

        public init(path: String, startOffset: Int, severity: DiagnosticSeverity) {
            self.filePath = path
            self.startOffset = startOffset
            self.severity = severity
        }

        init(_ diagnostic: Diagnostic) {
            self.init(
                path: diagnostic.fileURL.standardizedFileURL.path,
                startOffset: diagnostic.range.location,
                severity: diagnostic.severity
            )
        }

        public static func < (lhs: OrderingKey, rhs: OrderingKey) -> Bool {
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.startOffset != rhs.startOffset { return lhs.startOffset < rhs.startOffset }
            return lhs.severity > rhs.severity
        }
    }

    /// Where this diagnostic sorts, per the rules on `OrderingKey`.
    var orderingKey: OrderingKey { OrderingKey(self) }
}
