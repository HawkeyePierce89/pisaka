import Foundation

/// One painted occurrence: a range in the settled buffer's UTF-16 coordinates
/// and what the editor paints it as.
public struct OccurrenceHighlight: Equatable, Hashable, Sendable {
    /// The three colours an occurrence can take. `.read`/`.write` are the
    /// identifier's (R2) — only a server can name a write — and
    /// `.selectionMatch` is the selected string's other exact matches (R3).
    public enum Kind: Equatable, Hashable, Sendable {
        case read
        case write
        case selectionMatch
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// The editor's occurrence highlight: what is painted now, for which buffer,
/// and the ordering that keeps a late answer from painting over a newer
/// question.
///
/// `FindUsagesModel`'s ordering rule narrowed to one buffer. Every `settle`
/// bumps a monotonic generation token **synchronously**, in the main-actor turn
/// that handles the settled selection, before any hop; every answer publishes
/// only while its captured token is still the latest. An edit (`noteEdit`) and
/// a tab switch (`reset`) bump the same token and clear, so an answer computed
/// against text that has since changed is discarded rather than painted at
/// offsets that no longer mean what they did.
///
/// **One mode per settle** (`OccurrenceHighlightRule.mode`), so the identifier
/// answer and the selection-match answer never paint together. A settle whose
/// mode differs from the published one clears at once, before its own answer
/// arrives; a settle of the same mode on the same buffer keeps the published
/// answer until the new one replaces it, which is what keeps the highlight from
/// flickering while the caret walks within one name (the text is unchanged —
/// any edit already cleared).
///
/// **Where each answer comes from.** The identifier's is the provider's
/// `documentHighlights` — server or textual, decided by the provider chain
/// (D45), and taken whole. The selection match is a pure scan of the immutable
/// snapshot, run off the main actor. A reader throughout: it never touches the
/// buffer, and an exhausted budget or a missing provider is silent — it paints
/// nothing.
@MainActor
public final class OccurrenceHighlightModel: ObservableObject {

    /// The occurrences to paint, ascending by location.
    @Published public private(set) var highlights: [OccurrenceHighlight] = []

    /// The buffer `highlights` belong to, or `nil` when nothing is published.
    /// The app paints only while this is the buffer it is showing.
    @Published public private(set) var fileID: UUID?

    /// Which source answered the identifier question, or `nil` for a
    /// selection match and for no answer.
    @Published public private(set) var provenance: DocumentHighlightAnswer.Provenance?

    /// The scan behind selection-match mode: the selected string and the
    /// snapshot it is searched in, answering the capped match list or `nil` on
    /// an exhausted budget. Runs off the main actor.
    public typealias SelectionScan = @Sendable (_ selected: String, _ text: String) -> [NSRange]?

    /// The code-intelligence seam, read at each settle. Settable because the
    /// app's owner is built before the provider it reads exists.
    public var provider: () -> CodeIntelligenceProviding?
    private let selectionScan: SelectionScan

    /// Monotonically increasing token identifying the latest question. Bumped
    /// by `settle`, `noteEdit` and `reset`.
    private var generation = 0

    /// The mode the published answer (or the one in flight) was asked in.
    private var publishedMode: ModeKind?

    private enum ModeKind {
        case identifier
        case selectionMatch
    }

    /// - Parameters:
    ///   - provider: the code-intelligence seam, read at each settle rather than
    ///     held, because the app swaps a routing provider in once the LSP layer
    ///     is up. `nil` means no identifier answer at all.
    ///   - selectionScan: the selection-match scan; the default is
    ///     `OccurrenceHighlightRule.selectionMatches` with the production budget.
    ///     A test injects one that blocks on a `Gate`.
    public init(
        provider: @escaping () -> CodeIntelligenceProviding? = { nil },
        selectionScan: @escaping SelectionScan = { selected, text in
            OccurrenceHighlightRule.selectionMatches(of: selected, in: text as NSString)
        }
    ) {
        self.provider = provider
        self.selectionScan = selectionScan
    }

    /// The current generation — what the last `settle`, `noteEdit` or `reset`
    /// produced. `internal` for the tests.
    var currentGeneration: Int { generation }

    /// Ask the occurrence question for a settled selection.
    ///
    /// The token is captured here, synchronously; the answer is computed in the
    /// returned task and published only if no newer `settle`, `noteEdit` or
    /// `reset` happened meanwhile. The returned task is for tests and callers
    /// that want to await the outcome; dropping it is fine.
    @discardableResult
    public func settle(
        text: String,
        selection: NSRange,
        language: SyntaxLanguage?,
        fileURL: URL?,
        fileID: UUID
    ) -> Task<Void, Never> {
        generation += 1
        let token = generation
        let mode = OccurrenceHighlightRule.mode(text: text as NSString, selection: selection, language: language)

        switch mode {
        case .none:
            clear()
            return Task {}

        case .identifier(let match):
            prepare(for: .identifier, fileID: fileID)
            let request = DocumentHighlightRequest(
                identifier: match.text,
                fileURL: fileURL,
                offset: match.range.location,
                text: text,
                language: language
            )
            let provider = provider()
            return Task { [weak self] in
                let answer = await provider?.documentHighlights(for: request)
                guard let self, token == self.generation else { return }
                guard let answer else {
                    self.clear()
                    return
                }
                self.publish(
                    answer.highlights.map { highlight in
                        OccurrenceHighlight(
                            range: highlight.range,
                            kind: highlight.kind == .write ? .write : .read
                        )
                    },
                    fileID: fileID,
                    provenance: answer.provenance
                )
            }

        case .selectionMatch(let selected):
            prepare(for: .selectionMatch, fileID: fileID)
            let scan = selectionScan
            return Task { [weak self] in
                let ranges = await Task.detached(priority: .userInitiated) { scan(selected, text) }.value
                guard let self, token == self.generation else { return }
                self.publish(
                    (ranges ?? []).map { OccurrenceHighlight(range: $0, kind: .selectionMatch) },
                    fileID: fileID,
                    provenance: nil
                )
            }
        }
    }

    /// The buffer was edited: every answer in flight is stale and the published
    /// one is at offsets that may have moved, so both go until the next settle.
    public func noteEdit() {
        generation += 1
        clear()
    }

    /// A tab switch or teardown: the same as an edit — nothing published or in
    /// flight survives.
    public func reset() {
        generation += 1
        clear()
    }

    // MARK: - Private

    /// Clear up front when the published answer cannot stand until the new one
    /// lands: another mode's answer, or another buffer's.
    private func prepare(for mode: ModeKind, fileID: UUID) {
        if publishedMode != mode || self.fileID != fileID {
            clear()
        }
        publishedMode = mode
    }

    private func publish(
        _ highlights: [OccurrenceHighlight],
        fileID: UUID,
        provenance: DocumentHighlightAnswer.Provenance?
    ) {
        if highlights.isEmpty {
            clear()
            return
        }
        self.highlights = highlights
        self.fileID = fileID
        self.provenance = provenance
    }

    private func clear() {
        if !highlights.isEmpty { highlights = [] }
        if fileID != nil { fileID = nil }
        if provenance != nil { provenance = nil }
    }
}
