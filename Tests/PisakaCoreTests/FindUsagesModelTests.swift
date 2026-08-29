import XCTest
@testable import PisakaCore

@MainActor
final class FindUsagesModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project")

    // MARK: - Stubs

    /// A provider that answers `references` from a canned list and counts the
    /// asks — enough to prove which of the two answers the model took, which is
    /// the whole question this suite is about.
    private final class StubProvider: CodeIntelligenceProviding {
        var referenceRows: [UsageResult] = []
        private(set) var referenceCalls = 0

        func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] { [] }
        func completions(for request: CompletionRequest) async -> [CompletionItem] { [] }

        func references(for request: UsagesRequest) async -> [UsageResult] {
            referenceCalls += 1
            return referenceRows
        }
    }

    private func request(
        _ identifier: String,
        file: String? = "a.swift",
        offset: Int = 0,
        text: String = ""
    ) -> UsagesRequest {
        UsagesRequest(
            identifier: identifier,
            fileURL: file.map { root.appendingPathComponent($0) },
            offset: offset,
            text: text
        )
    }

    private func paths(_ model: FindUsagesModel) -> [String] {
        model.groups.map(\.relativePath)
    }

    // MARK: - The semantic answer

    func testProviderRowsArePublishedWithSemanticProvenance() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "let count = 1"])
        let provider = StubProvider()
        provider.referenceRows = [
            usage(file: "a.swift", location: 4, line: 1, preview: "let count = 1"),
        ]
        let model = FindUsagesModel(fileService: stub, provider: { provider })

        await model.find(request("count", text: "let count = 1"), root: root)

        XCTAssertEqual(model.identifier, "count")
        XCTAssertEqual(model.provenance, .semantic)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertFalse(model.isTruncated)
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.emptyReason)
        // The semantic answer costs no walk at all: nothing was read from disk.
        XCTAssertTrue(stub.readPaths.isEmpty)
    }

    func testSemanticRowsAreGroupedByFileInAnswerOrder() async {
        let provider = StubProvider()
        provider.referenceRows = [
            usage(file: "z/last.swift", location: 0, line: 1, preview: "count"),
            usage(file: "a.swift", location: 10, line: 2, preview: "count"),
            usage(file: "a.swift", location: 0, line: 1, preview: "count"),
        ]
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider }
        )

        await model.find(request("count", file: "a.swift"), root: root)

        // The requesting file leads even though its path sorts first anyway, and
        // its two rows are one group in offset order.
        XCTAssertEqual(paths(model), ["a.swift", "z/last.swift"])
        XCTAssertEqual(model.groups.first?.rows.map(\.range.location), [0, 10])
    }

    // MARK: - The textual answer

    func testEmptyProviderAnswerFallsToTheTextualScan() async {
        let stub = StubFileTree(
            root: root,
            files: [
                "a.swift": "let count = 1\nprint(count)\n",
                "b.swift": "// counter is not count's word\n",
                "c.swift": "nothing here\n",
            ]
        )
        let provider = StubProvider()
        let model = FindUsagesModel(fileService: stub, provider: { provider })

        await model.find(request("count"), root: root)

        XCTAssertEqual(provider.referenceCalls, 1)
        XCTAssertEqual(model.provenance, .textual)
        XCTAssertTrue(model.rows.allSatisfy(\.isTextual))
        // `counter` is not a whole word, `count's` is.
        XCTAssertEqual(paths(model), ["a.swift", "b.swift"])
        XCTAssertEqual(model.rows.map(\.line), [1, 2, 1])
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.emptyReason)
    }

    func testNoProviderAtAllStillAnswersTextually() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.provenance, .textual)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testTextualScanReadsAnOpenBufferInsteadOfTheDiskCopy() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "nothing on disk\n"])
        let model = FindUsagesModel(
            fileService: stub,
            openBuffers: { [self.root.appendingPathComponent("a.swift"): "count in the buffer\n"] }
        )

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.preview.text, "count in the buffer")
        XCTAssertTrue(stub.readPaths.isEmpty)
    }

    func testBinaryAndOversizeFilesAreSkippedByTheScan() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n", "big.bin": "count\n"])
        stub.skippedFiles = ["big.bin"]
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(paths(model), ["a.swift"])
    }

    func testNoUsagesAnywhereReportsTheAnsweredEmptyState() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "nothing\n"])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyReason, .noUsages)
        XCTAssertEqual(model.provenance, .textual)
        XCTAssertFalse(model.isSearching)
    }

    func testAQueryThatIsNotAnIdentifierIsRefusedWithoutAWalk() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "run()\n"])
        let provider = StubProvider()
        let model = FindUsagesModel(fileService: stub, provider: { provider })

        await model.find(request("run()"), root: root)

        XCTAssertEqual(model.identifier, "run()")
        XCTAssertEqual(model.emptyReason, .notAnIdentifier)
        XCTAssertNil(model.provenance)
        XCTAssertEqual(provider.referenceCalls, 0)
        XCTAssertTrue(stub.readPaths.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testWithNoProjectRootTheRequestingBufferIsScannedAlone() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count elsewhere\n"])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count", text: "count and count\n"), root: nil)

        XCTAssertEqual(model.provenance, .textual)
        XCTAssertEqual(model.rows.map(\.range.location), [0, 10])
        XCTAssertEqual(paths(model), ["a.swift"])
        XCTAssertTrue(stub.readPaths.isEmpty)
    }

    func testWithNoProjectRootAndNoFileThereIsNothingToAnswer() async {
        let model = FindUsagesModel(fileService: StubFileTree(root: root, files: [:]))

        await model.find(request("count", file: nil, text: "count\n"), root: nil)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyReason, .noUsages)
    }

    // MARK: - The cap

    func testTheCapClipsTheRowsAndSetsTheTruncationFlag() async {
        let over = Array(repeating: "count", count: UsagesAnswer.cap + 1).joined(separator: " ")
        let stub = StubFileTree(root: root, files: ["a.swift": over])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.rows.count, UsagesAnswer.cap)
        XCTAssertTrue(model.isTruncated)
        XCTAssertFalse(model.isSearching)
    }

    func testAnAnswerUnderTheCapIsNotTruncated() async {
        let under = Array(repeating: "count", count: UsagesAnswer.cap).joined(separator: " ")
        let stub = StubFileTree(root: root, files: ["a.swift": under])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.rows.count, UsagesAnswer.cap)
        XCTAssertFalse(model.isTruncated)
    }

    // MARK: - Generation discipline

    func testNewerQuerySupersedesAnInFlightWalk() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "alpha beta\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = FindUsagesModel(fileService: stub)

        let stale = Task { await model.find(self.request("alpha"), root: self.root) }
        await gate.waitUntilReached()

        // The second question is asked while the first is still blocked in its
        // directory listing; it queues behind it on the model's serial queue and
        // runs the moment the gate opens.
        let fresh = Task { await model.find(self.request("beta"), root: self.root) }
        await waitUntil { model.currentRequestGeneration == 2 }
        gate.release()
        await stale.value
        await fresh.value

        XCTAssertEqual(model.identifier, "beta")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.preview.matchRange, NSRange(location: 6, length: 4))
        XCTAssertFalse(model.isSearching)
    }

    func testFolderSwitchMidWalkAbandonsIt() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = FindUsagesModel(fileService: stub)

        let task = Task { await model.find(self.request("count"), root: self.root) }
        await gate.waitUntilReached()

        model.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        gate.release()
        await task.value

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertFalse(model.isSearching)
    }

    func testPrepareForFolderChangeClearsStaleRowsSynchronously() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)
        await model.find(request("count"), root: root)
        XCTAssertFalse(model.rows.isEmpty)

        model.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
    }

    func testPrepareForFolderChangeForTheSameFolderIsANoOp() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)
        model.prepareForFolderChange(root: root)
        await model.find(request("count"), root: root)

        let generation = model.currentRequestGeneration
        model.prepareForFolderChange(root: root)

        XCTAssertEqual(model.currentRequestGeneration, generation)
        XCTAssertEqual(model.rows.count, 1)
    }

    func testFindRejectsASupersededRequestGeneration() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)

        // The token is captured, then the folder changes before the deferred call
        // ever starts — the shape a `Task`-hopping caller takes.
        let pinned = model.currentRequestGeneration
        model.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))

        await model.find(request("count"), root: root, request: pinned)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
    }

    // MARK: - Post-rename bookkeeping

    func testClearIfNamingClearsResultsAboutTheRenamedIdentifier() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)
        await model.find(request("count"), root: root)

        model.clearIfNaming("count")

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertNil(model.provenance)
    }

    func testClearIfNamingLeavesAnotherIdentifiersResultsAlone() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)
        await model.find(request("count"), root: root)

        model.clearIfNaming("total")

        XCTAssertEqual(model.identifier, "count")
        XCTAssertEqual(model.rows.count, 1)
    }

    func testClearIfNamingStopsAWalkStillLookingForThatName() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = FindUsagesModel(fileService: stub)

        let task = Task { await model.find(self.request("count"), root: self.root) }
        await gate.waitUntilReached()

        model.clearIfNaming("count")
        gate.release()
        await task.value

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyReason, .noQuery)
    }

    // MARK: - Grouping

    func testGroupingKeepsRunsAndNeverMergesTwoFilesSharingAPath() {
        let outside = URL(fileURLWithPath: "/elsewhere/Shared.swift")
        let inside = root.appendingPathComponent("Shared.swift")
        let rows = [
            UsageResult(
                fileURL: inside,
                range: NSRange(location: 0, length: 1),
                line: 1,
                relativePath: "Shared.swift",
                preview: MatchPreview(text: "x", matchRange: NSRange(location: 0, length: 1)),
                isTextual: true
            ),
            UsageResult(
                fileURL: outside,
                range: NSRange(location: 0, length: 1),
                line: 1,
                relativePath: "Shared.swift",
                preview: MatchPreview(text: "x", matchRange: NSRange(location: 0, length: 1)),
                isTextual: true
            ),
        ]

        let groups = UsageFileGroup.grouped(rows)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.fileURL), [inside, outside])
    }

    func testGroupingAnEmptyAnswerProducesNoGroups() {
        XCTAssertTrue(UsageFileGroup.grouped([]).isEmpty)
    }

    // MARK: - Helpers

    private func usage(file: String, location: Int, line: Int, preview: String) -> UsageResult {
        UsageResult(
            fileURL: root.appendingPathComponent(file),
            range: NSRange(location: location, length: 5),
            line: line,
            relativePath: file,
            preview: MatchPreview(text: preview, matchRange: NSRange(location: 0, length: 5)),
            isTextual: false
        )
    }

    /// Poll a main-actor condition until it holds, failing loudly rather than
    /// vacuously when it never does.
    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the expected state", file: file, line: line)
    }
}
