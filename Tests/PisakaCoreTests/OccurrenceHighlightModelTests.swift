import XCTest
@testable import PisakaCore

/// `OccurrenceHighlightModel`'s ordering: which answer is published, which is
/// discarded, and which clears. Races are staged with `Gate` — the answer is
/// provably parked inside the provider or the scan while the test changes
/// state — never with a timed wait.
@MainActor
final class OccurrenceHighlightModelTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/project/a.ts")
    private let fileID = UUID()
    private let text = "let started = 1; started += started"

    // MARK: - Stubs

    /// A provider answering `documentHighlights` from a canned answer, optionally
    /// parked on a per-identifier `Gate` until the test releases it.
    private final class StubProvider: CodeIntelligenceProviding {
        var answers: [String: DocumentHighlightAnswer] = [:]
        var gates: [String: Gate] = [:]
        private(set) var requests: [DocumentHighlightRequest] = []

        func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] { [] }
        func completions(for request: CompletionRequest) async -> [CompletionItem] { [] }

        func documentHighlights(for request: DocumentHighlightRequest) async -> DocumentHighlightAnswer? {
            requests.append(request)
            if let gate = gates[request.identifier] {
                await Task.detached { gate.wait() }.value
            }
            return answers[request.identifier]
        }
    }

    private func range(of needle: String, occurrence: Int = 0) -> NSRange {
        let ns = text as NSString
        var searchFrom = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(of: needle, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            searchFrom = NSMaxRange(found)
        }
        return found
    }

    private func textual(_ ranges: [NSRange]) -> DocumentHighlightAnswer {
        DocumentHighlightAnswer(provenance: .textual, highlights: ranges.map { .init(range: $0, kind: .read) })
    }

    private func caret(at location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: - Identifier mode

    func testCaretOnIdentifierPublishesProviderAnswer() async {
        let provider = StubProvider()
        let ranges = [range(of: "started"), range(of: "started", occurrence: 1), range(of: "started", occurrence: 2)]
        provider.answers["started"] = textual(ranges)
        let model = OccurrenceHighlightModel(provider: { provider })

        await model.settle(
            text: text, selection: caret(at: range(of: "started", occurrence: 1).location + 2),
            language: .typescript, fileURL: fileURL, fileID: fileID
        ).value

        XCTAssertEqual(model.highlights.map(\.range), ranges)
        XCTAssertTrue(model.highlights.allSatisfy { $0.kind == .read })
        XCTAssertEqual(model.fileID, fileID)
        XCTAssertEqual(model.provenance, .textual)
        // The request names the identifier's first character, whatever the caret.
        XCTAssertEqual(provider.requests.first?.offset, range(of: "started", occurrence: 1).location)
        XCTAssertEqual(provider.requests.first?.fileURL, fileURL)
    }

    func testServerWriteKindSurvivesIntoPublishedState() async {
        let provider = StubProvider()
        provider.answers["started"] = DocumentHighlightAnswer(provenance: .server, highlights: [
            .init(range: range(of: "started"), kind: .write),
            .init(range: range(of: "started", occurrence: 1), kind: .write),
            .init(range: range(of: "started", occurrence: 2), kind: .read),
        ])
        let model = OccurrenceHighlightModel(provider: { provider })

        await model.settle(
            text: text, selection: caret(at: range(of: "started").location),
            language: .typescript, fileURL: fileURL, fileID: fileID
        ).value

        XCTAssertEqual(model.highlights.map(\.kind), [.write, .write, .read])
        XCTAssertEqual(model.provenance, .server)
    }

    func testNoProviderOrNoAnswerPublishesNothing() async {
        let noProvider = OccurrenceHighlightModel()
        await noProvider.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertTrue(noProvider.highlights.isEmpty)
        XCTAssertNil(noProvider.fileID)

        let silent = StubProvider()
        let model = OccurrenceHighlightModel(provider: { silent })
        await model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertTrue(model.highlights.isEmpty)
        XCTAssertNil(model.provenance)
    }

    // MARK: - Ordering

    func testSlowFirstRequestOvertakenBySecondNeverPublishes() async {
        let source = "alpha beta alpha beta"
        let ns = source as NSString
        let provider = StubProvider()
        let alphaGate = Gate()
        provider.gates["alpha"] = alphaGate
        provider.answers["alpha"] = textual([ns.range(of: "alpha")])
        provider.answers["beta"] = textual([ns.range(of: "beta")])
        let model = OccurrenceHighlightModel(provider: { provider })

        let first = model.settle(
            text: source, selection: caret(at: 1), language: .typescript, fileURL: fileURL, fileID: fileID
        )
        await alphaGate.waitUntilReached()
        await model.settle(
            text: source, selection: caret(at: 7), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertEqual(model.highlights.map(\.range), [ns.range(of: "beta")])

        alphaGate.release()
        await first.value
        XCTAssertEqual(model.highlights.map(\.range), [ns.range(of: "beta")])
    }

    func testEditDuringFlightDiscardsResult() async {
        let provider = StubProvider()
        let gate = Gate()
        provider.gates["started"] = gate
        provider.answers["started"] = textual([range(of: "started")])
        let model = OccurrenceHighlightModel(provider: { provider })

        let flight = model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        )
        await gate.waitUntilReached()
        let before = model.currentGeneration
        model.noteEdit()
        XCTAssertGreaterThan(model.currentGeneration, before)

        gate.release()
        await flight.value
        XCTAssertTrue(model.highlights.isEmpty)
        XCTAssertNil(model.fileID)
    }

    func testEditAndResetClearPublishedAnswer() async {
        let provider = StubProvider()
        provider.answers["started"] = textual([range(of: "started")])
        let model = OccurrenceHighlightModel(provider: { provider })

        await model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertFalse(model.highlights.isEmpty)
        model.noteEdit()
        XCTAssertTrue(model.highlights.isEmpty)

        await model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertFalse(model.highlights.isEmpty)
        model.reset()
        XCTAssertTrue(model.highlights.isEmpty)
        XCTAssertNil(model.fileID)
        XCTAssertNil(model.provenance)
    }

    func testSelectionScanOvertakenByEditNeverPublishes() async {
        let gate = Gate()
        let model = OccurrenceHighlightModel(selectionScan: { selected, text in
            gate.wait()
            return OccurrenceHighlightRule.selectionMatches(of: selected, in: text as NSString)
        })

        let flight = model.settle(
            text: "a + b; a + b", selection: NSRange(location: 0, length: 5),
            language: .typescript, fileURL: fileURL, fileID: fileID
        )
        await gate.waitUntilReached()
        model.noteEdit()
        gate.release()
        await flight.value
        XCTAssertTrue(model.highlights.isEmpty)
    }

    // MARK: - Modes

    func testSelectionMatchPublishesEveryExactMatch() async {
        let source = "a + b; a + b; a+b"
        let model = OccurrenceHighlightModel()

        await model.settle(
            text: source, selection: NSRange(location: 0, length: 5),
            language: .typescript, fileURL: fileURL, fileID: fileID
        ).value

        XCTAssertEqual(model.highlights, [
            OccurrenceHighlight(range: NSRange(location: 0, length: 5), kind: .selectionMatch),
            OccurrenceHighlight(range: NSRange(location: 7, length: 5), kind: .selectionMatch),
        ])
        XCTAssertNil(model.provenance)
        XCTAssertEqual(model.fileID, fileID)
    }

    func testSelectionMatchPastCapPublishesNothing() async {
        // `ab` alone is an identifier — the identifier's question — so the
        // selection is `ab `, which occurs once more than the cap.
        let cap = OccurrenceHighlightRule.selectionMatchCap
        let model = OccurrenceHighlightModel()

        let atCap = String(repeating: "ab ", count: cap)
        await model.settle(
            text: atCap, selection: NSRange(location: 0, length: 3),
            language: nil, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertEqual(model.highlights.count, cap)

        let source = String(repeating: "ab ", count: cap + 1)
        await model.settle(
            text: source, selection: NSRange(location: 0, length: 3),
            language: nil, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertTrue(model.highlights.isEmpty)
    }

    func testModeSwitchClearsTheOtherModesAnswerAtOnce() async {
        let source = "foo + bar; foo + bar"
        let provider = StubProvider()
        let gate = Gate()
        provider.gates["foo"] = gate
        provider.answers["foo"] = textual([NSRange(location: 0, length: 3), NSRange(location: 11, length: 3)])
        let model = OccurrenceHighlightModel(provider: { provider })

        // Selection-match answer published first.
        await model.settle(
            text: source, selection: NSRange(location: 0, length: 9),
            language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertEqual(model.highlights.map(\.kind), [.selectionMatch, .selectionMatch])

        // A caret on `foo` switches to identifier mode: the selection matches go
        // before the identifier answer arrives, not when it lands.
        let flight = model.settle(
            text: source, selection: caret(at: 1), language: .typescript, fileURL: fileURL, fileID: fileID
        )
        XCTAssertTrue(model.highlights.isEmpty)
        await gate.waitUntilReached()
        gate.release()
        await flight.value
        XCTAssertEqual(model.highlights.map(\.kind), [.read, .read])

        // And back: a selection match clears the identifier answer at once.
        let back = model.settle(
            text: source, selection: NSRange(location: 0, length: 9),
            language: .typescript, fileURL: fileURL, fileID: fileID
        )
        XCTAssertTrue(model.highlights.isEmpty)
        await back.value
        XCTAssertEqual(model.highlights.map(\.kind), [.selectionMatch, .selectionMatch])

        // A selection that asks for nothing (one unit) clears too.
        await model.settle(
            text: source, selection: NSRange(location: 3, length: 1),
            language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertTrue(model.highlights.isEmpty)
    }

    func testSameModeKeepsAnswerUntilReplacedButAnotherBufferClears() async {
        let provider = StubProvider()
        let gate = Gate()
        provider.answers["started"] = textual([range(of: "started")])
        let model = OccurrenceHighlightModel(provider: { provider })

        await model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertEqual(model.highlights.count, 1)

        provider.gates["started"] = gate
        let same = model.settle(
            text: text, selection: caret(at: 6), language: .typescript, fileURL: fileURL, fileID: fileID
        )
        XCTAssertEqual(model.highlights.count, 1)
        await gate.waitUntilReached()
        gate.release()
        await same.value

        provider.gates["started"] = nil
        let other = model.settle(
            text: text, selection: caret(at: 5), language: .typescript, fileURL: fileURL, fileID: UUID()
        )
        XCTAssertTrue(model.highlights.isEmpty)
        await other.value
        XCTAssertNotEqual(model.fileID, fileID)
    }

    func testAnotherIdentifierClearsPreviousAnswerBeforeItsOwnLands() async {
        let source = "alpha = beta; alpha + beta"
        let alpha = NSRange(location: 0, length: 5)
        let beta = NSRange(location: 8, length: 4)
        let provider = StubProvider()
        let gate = Gate()
        provider.answers["alpha"] = textual([alpha])
        provider.answers["beta"] = textual([beta])
        let model = OccurrenceHighlightModel(provider: { provider })

        await model.settle(
            text: source, selection: caret(at: 2), language: .typescript, fileURL: fileURL, fileID: fileID
        ).value
        XCTAssertEqual(model.highlights.map(\.range), [alpha])

        provider.gates["beta"] = gate
        let other = model.settle(
            text: source, selection: caret(at: 10), language: .typescript, fileURL: fileURL, fileID: fileID
        )
        XCTAssertTrue(model.highlights.isEmpty)
        await gate.waitUntilReached()
        XCTAssertTrue(model.highlights.isEmpty)
        gate.release()
        await other.value
        XCTAssertEqual(model.highlights.map(\.range), [beta])
    }
}
