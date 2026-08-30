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
        /// The last request as the model actually assembled it — which is not the
        /// one the caller handed `find`, since the buffers are added on the way.
        private(set) var lastRequest: UsagesRequest?

        /// Run on the main actor *while `find` is suspended on this answer* — the
        /// causal rendezvous the semantic checkpoint needs, with no timing in it:
        /// the model is provably parked on this `await` when the hook runs, which
        /// is the one window in which a newer question can supersede a semantic
        /// answer that has already been computed.
        var whileAnswering: (@MainActor () -> Void)?

        func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] { [] }
        func completions(for request: CompletionRequest) async -> [CompletionItem] { [] }

        func references(for request: UsagesRequest) async -> [UsageResult] {
            referenceCalls += 1
            lastRequest = request
            if let whileAnswering { await MainActor.run { whileAnswering() } }
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

    /// A tab may hold a file the project walk never yields — one the
    /// `.gitignore` excludes, say. Answering "No usages" for the name the caret
    /// is sitting on is the one wrong answer the user can see is wrong, so the
    /// requesting file is scanned whether or not the walk visited it.
    func testTheRequestingFileIsScannedEvenWhenTheWalkSkipsIt() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "nothing here\n"])
        let hidden = root.appendingPathComponent("ignored/gen.swift")
        let model = FindUsagesModel(
            fileService: stub,
            openBuffers: { [hidden: "let count = 1\n"] }
        )

        await model.find(
            request("count", file: "ignored/gen.swift", offset: 4, text: "let count = 1\n"),
            root: root
        )

        XCTAssertEqual(model.provenance, .textual)
        XCTAssertEqual(paths(model), ["ignored/gen.swift"])
        XCTAssertNil(model.emptyReason)
    }

    /// The same rule for a tab opened from outside the folder entirely: its rows
    /// display as a bare file name (`ProjectFileWalk.relativePath`) and lead the
    /// answer, because that is where the question was asked from.
    func testTheRequestingFileIsScannedWhenItLivesOutsideTheRoot() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let outside = URL(fileURLWithPath: "/elsewhere/x.swift")
        let model = FindUsagesModel(
            fileService: stub,
            openBuffers: { [outside: "count\n"] }
        )

        await model.find(
            UsagesRequest(identifier: "count", fileURL: outside, offset: 0, text: "count\n"),
            root: root
        )

        XCTAssertEqual(paths(model), ["x.swift", "a.swift"])
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

    /// Exactly at the cap, which is the boundary worth pinning: `make` truncates
    /// on `> cap`, so an answer of precisely `cap` rows is complete.
    func testAnAnswerExactlyAtTheCapIsNotTruncated() async {
        let under = Array(repeating: "count", count: UsagesAnswer.cap).joined(separator: " ")
        let stub = StubFileTree(root: root, files: ["a.swift": under])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.rows.count, UsagesAnswer.cap)
        XCTAssertFalse(model.isTruncated)
    }

    /// **The walk abandons the project once it is past the cap, and reports it.**
    ///
    /// The truncation flag is the walk's own answer to "was there more to read?"
    /// rather than a count comparison, because the two can disagree: the loop
    /// stops on the *raw* count while the answer measures the *deduplicated* one,
    /// and the requesting file is deliberately collected twice whenever the walk
    /// spells it differently (a symlinked root is the ordinary case), so those
    /// rows collapse afterwards. `UsagesAnswerTests` pins the below-the-cap half
    /// of that contract, which needs no project to state; this pins that the walk
    /// both stops and says so.
    func testAWalkAbandonedWithFilesLeftUnreadIsTruncatedAndReadsNoFurther() async {
        let over = Array(repeating: "count", count: UsagesAnswer.cap + 1).joined(separator: " ")
        // More files than one chunk holds, so the walk provably has some left when
        // the first chunk alone puts it past the cap.
        var files = ["a.swift": over]
        for index in 0..<(FindUsagesModel.chunkSize * 2) {
            files["z\(index).swift"] = "nothing to find here"
        }
        let stub = StubFileTree(root: root, files: files)
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)

        XCTAssertEqual(model.rows.count, UsagesAnswer.cap)
        XCTAssertTrue(model.isTruncated, "files left unread is truncation")
        XCTAssertLessThan(
            stub.readPaths.count,
            files.count,
            "the point of stopping is that the rest of the project is not read"
        )
    }

    // MARK: - The open buffers

    /// **The semantic answer is told about the documents the server holds.**
    ///
    /// A server's ranges in a dirty *background* tab are that document's — the
    /// push channel gave it that text — so the provider needs those texts to map
    /// them, and only this model can hand them over.
    func testTheServerDocumentsTravelWithTheSemanticQuestion() async {
        let provider = StubProvider()
        let other = root.appendingPathComponent("other.swift")
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider },
            serverTexts: { [other: "let count = 2"] }
        )

        await model.find(request("count"), root: root)

        XCTAssertEqual(provider.lastRequest?.openTexts, [other: "let count = 2"])
    }

    /// **The semantic half reads what the server was told, not what the tab now
    /// holds.**
    ///
    /// The document-sync debounce means a background tab typed in a moment ago is
    /// a buffer no server has seen. Mapping the server's `(line, character)`
    /// answers onto *that* text is how a row acquires a plausible line number and
    /// the wrong offsets — the one way this layer can produce a row that is wrong
    /// rather than absent. The two seams therefore differ, and the semantic
    /// question takes the server's.
    func testTheSemanticQuestionIgnoresBuffersTheServerHasNotSeen() async {
        let provider = StubProvider()
        let other = root.appendingPathComponent("other.swift")
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider },
            openBuffers: { [other: "typed since the last push"] },
            serverTexts: { [other: "what the server was told"] }
        )

        await model.find(request("count"), root: root)

        XCTAssertEqual(provider.lastRequest?.openTexts, [other: "what the server was told"])
    }

    /// A caller with no language server offers nothing: the seam is empty, and an
    /// empty map is not filled in from the live buffers behind its back.
    func testWithNoServerDocumentsTheSemanticQuestionCarriesNone() async {
        let provider = StubProvider()
        let other = root.appendingPathComponent("other.swift")
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider },
            openBuffers: { [other: "let count = 2"] }
        )

        await model.find(request("count"), root: root)

        XCTAssertEqual(provider.lastRequest?.openTexts, [:])
    }

    /// A caller that filled `openTexts` itself keeps its own snapshot: the model
    /// supplies the server's documents, it does not overrule a request that
    /// already carries them.
    func testARequestThatAlreadyCarriesBuffersIsNotOverwritten() async {
        let provider = StubProvider()
        let stated = root.appendingPathComponent("stated.swift")
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider },
            serverTexts: { [self.root.appendingPathComponent("other.swift"): "ignored"] }
        )
        let carried = UsagesRequest(
            identifier: "count",
            fileURL: root.appendingPathComponent("a.swift"),
            offset: 0,
            text: "",
            openTexts: [stated: "let count = 3"]
        )

        await model.find(carried, root: root)

        XCTAssertEqual(provider.lastRequest?.openTexts, [stated: "let count = 3"])
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

    /// **The checkpoint after the provider's `await`.** The answer is computed,
    /// and by the time it comes back the user has left the folder — so it must be
    /// dropped rather than published into a window that no longer shows those
    /// files.
    func testASupersededQuestionDropsAComputedSemanticAnswer() async {
        let provider = StubProvider()
        provider.referenceRows = [
            usage(file: "a.swift", location: 0, line: 1, preview: "count"),
        ]
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider }
        )
        provider.whileAnswering = { [weak model] in
            model?.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        }

        await model.find(request("count"), root: root)

        XCTAssertEqual(provider.referenceCalls, 1)
        XCTAssertTrue(model.rows.isEmpty, "A superseded semantic answer must not be published.")
        XCTAssertNil(model.provenance)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
    }

    /// The same checkpoint, superseded by a *newer question* rather than by a
    /// folder switch: the rows are for the name nobody is asking about any more.
    func testANewerQuestionDropsAComputedSemanticAnswer() async {
        let provider = StubProvider()
        provider.referenceRows = [
            usage(file: "a.swift", location: 0, line: 1, preview: "count"),
        ]
        let model = FindUsagesModel(
            fileService: StubFileTree(root: root, files: [:]),
            provider: { provider }
        )
        provider.whileAnswering = { [weak model] in model?.clearIfNaming("count") }

        await model.find(request("count"), root: root)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.provenance)
    }

    /// **The checkpoint after each chunk.** Two chunks' worth of files with the
    /// folder switched while the second one is being read: the first chunk's rows
    /// are cleared by the switch, and the second chunk must not put them back.
    func testAFolderSwitchBetweenChunksAbandonsTheRestOfTheWalk() async {
        var files: [String: String] = [:]
        for index in 0..<(FindUsagesModel.chunkSize * 2) {
            files[String(format: "f%02d.swift", index)] = "count\n"
        }
        let stub = StubFileTree(root: root, files: files)
        let gate = Gate()
        // A file in the *second* chunk (the listing is name-ordered), so the first
        // chunk has already been scanned and published when the switch lands.
        stub.readGate = (path: "f40.swift", gate: gate)
        let model = FindUsagesModel(fileService: stub)

        let task = Task { await model.find(self.request("count", file: nil), root: self.root) }
        await gate.waitUntilReached()

        model.prepareForFolderChange(root: URL(fileURLWithPath: "/other"))
        gate.release()
        await task.value

        XCTAssertTrue(
            model.rows.isEmpty,
            "A chunk finishing after the folder changed must not publish the previous project's rows."
        )
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertFalse(model.isSearching)
    }

    /// `isSearching` is the panel's progress indicator and its "Searching…" empty
    /// state; asserting only that it ends `false` would keep passing if it were
    /// never set at all.
    func testIsSearchingIsTrueWhileTheWalkIsRunning() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = FindUsagesModel(fileService: stub)

        let task = Task { await model.find(self.request("count"), root: self.root) }
        await gate.waitUntilReached()

        XCTAssertTrue(model.isSearching)

        gate.release()
        await task.value

        XCTAssertFalse(model.isSearching)
    }

    /// **A walk that reads no file at all still ends in an answer.** An empty or
    /// wholly excluded project publishes from no chunk, and without a terminal
    /// publish the panel would fall back to "nothing has been asked yet" for a
    /// question that was just asked and just answered.
    func testAProjectWithNoFilesStillEndsInATextualAnswer() async {
        let model = FindUsagesModel(fileService: StubFileTree(root: root, files: [:]))

        await model.find(request("count", file: nil), root: root)

        XCTAssertEqual(model.provenance, .textual)
        XCTAssertEqual(model.emptyReason, .noUsages)
        XCTAssertEqual(model.identifier, "count")
        XCTAssertFalse(model.isSearching)
    }

    /// Two presses in one main-actor turn reserve two tokens, so the *later*
    /// question wins whichever task the runtime happens to start first — which a
    /// caller that merely read the current generation would not get.
    func testTwoReservedTokensSettleOnTheLaterQuestion() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "alpha beta\n"])
        let model = FindUsagesModel(fileService: stub)

        let first = model.prepareForQuery(for: "alpha")
        let second = model.prepareForQuery(for: "beta")

        // Deliberately run in reservation-*reverse* order: the later question is
        // answered first, and the earlier one must still be refused.
        await model.find(request("beta"), root: root, request: second)
        await model.find(request("alpha"), root: root, request: first)

        XCTAssertEqual(model.identifier, "beta")
        XCTAssertEqual(model.rows.count, 1)
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

    /// Closing the folder is a switch like any other: the rows belong to a project
    /// that is no longer open, and leaving them clickable would open files from a
    /// window that shows none.
    func testClosingTheFolderClearsTheRows() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)
        await model.find(request("count"), root: root)
        XCTAssertFalse(model.rows.isEmpty)

        model.prepareForFolderChange(root: nil)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertNil(model.provenance)
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

    /// The window a reserved token opens: a ⌃⌘U pressed while the rename's round
    /// trip is in flight holds a token, but nothing about that question has
    /// reached `identifier` yet. Comparing the displayed subject alone would read
    /// the rename as being about some other name and let the queued walk publish
    /// the spelling the rename just removed.
    func testClearIfNamingInvalidatesAQuestionReservedButNotYetStarted() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count\n"])
        let model = FindUsagesModel(fileService: stub)

        // Reserved in the main-actor turn that handled the press; `find` has not
        // run, so the model still displays nothing at all.
        let reserved = model.prepareForQuery(for: "count")
        XCTAssertEqual(model.identifier, "")

        model.clearIfNaming("count")
        await model.find(request("count"), root: root, request: reserved)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertFalse(model.isSearching)
    }

    /// The other half of decision 7 in that same window: a reserved question about
    /// a name the rename did not touch is still the question the user asked, so
    /// the rename must not take its token away.
    func testClearIfNamingLeavesAQuestionReservedForAnotherNameRunnable() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count total\n"])
        let model = FindUsagesModel(fileService: stub)

        let reserved = model.prepareForQuery(for: "total")
        model.clearIfNaming("count")
        await model.find(request("total"), root: root, request: reserved)

        XCTAssertEqual(model.identifier, "total")
        XCTAssertEqual(model.rows.count, 1)
    }

    /// The same half, with rows for the old name still on screen — the case where
    /// the clear *does* fire. Clearing what is displayed and stranding the newer
    /// reserved question are two different acts, and only the first is decision
    /// 7's: the reservation already superseded any walk the bump would have
    /// stranded, so bumping past it would reject the one question that is current.
    func testClearIfNamingKeepsAnotherNamesReservationWhileClearingTheOldRows() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count total\n"])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("count"), root: root)
        XCTAssertEqual(model.identifier, "count")

        let reserved = model.prepareForQuery(for: "total")
        model.clearIfNaming("count")

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.emptyReason, .noQuery)

        await model.find(request("total"), root: root, request: reserved)

        XCTAssertEqual(model.identifier, "total")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.provenance, .textual)
    }

    /// A reservation is spent once `find` redeems it: the rows on screen are then
    /// the ones `identifier` names, and a later rename of some *other* name must
    /// not invalidate them through a token nobody is still holding.
    func testARedeemedReservationNoLongerInvalidatesByItsOwnName() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count total\n"])
        let model = FindUsagesModel(fileService: stub)

        let reserved = model.prepareForQuery(for: "count")
        await model.find(request("count"), root: root, request: reserved)
        let afterAnswer = model.currentRequestGeneration

        model.clearIfNaming("total")

        XCTAssertEqual(model.currentRequestGeneration, afterAnswer)
        XCTAssertEqual(model.identifier, "count")
        XCTAssertEqual(model.rows.count, 1)
    }

    /// The interleaving where invalidating a reservation is the *only* thing that
    /// happens: a walk for one name is already running, a ⌃⌘U for a second name
    /// reserves a token inside the rename's round trip, and the rename then
    /// removes that second name. The bump strands the running walk's chunk **and**
    /// the reserved question, so neither of the two tasks reaches a publish — and
    /// with the displayed subject naming neither of them, nothing would put the
    /// loading flag back down. The panel would print "Searching…" over an
    /// abandoned walk's partial rows with nothing left to finish it.
    func testClearIfNamingEndsTheLoadingStateItStrandsForAnotherName() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count total\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = FindUsagesModel(fileService: stub)

        // The older walk, still inside the listing when the rename lands.
        let running = Task { await model.find(self.request("total"), root: self.root) }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isSearching)

        // ⌃⌘U on `count` while the rename's round trip is in flight: reserved in
        // the main-actor turn that handled the press, not yet started.
        let reserved = model.prepareForQuery(for: "count")

        model.clearIfNaming("count")
        gate.release()
        await running.value
        await model.find(request("count"), root: root, request: reserved)

        XCTAssertFalse(
            model.isSearching,
            "Stranding both the running walk and the question that would have replaced it must "
                + "not leave the panel loading forever."
        )
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.identifier, "")
        XCTAssertEqual(model.emptyReason, .noQuery)
        XCTAssertNil(model.provenance)
    }

    /// The same bump with **no** walk running: there is no loading state to end,
    /// and a settled answer about a name the rename did not touch still survives
    /// it (decision 7's other half).
    func testClearIfNamingKeepsASettledAnswerWhenItInvalidatesAReservation() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "count total\n"])
        let model = FindUsagesModel(fileService: stub)

        await model.find(request("total"), root: root)
        XCTAssertEqual(model.rows.count, 1)

        model.prepareForQuery(for: "count")
        model.clearIfNaming("count")

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.identifier, "total")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.provenance, .textual)
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
