import XCTest
@testable import PisakaCore

/// A stand-in for the app layer's tree-sitter extractor: every line spelled
/// `sym <name>` declares one symbol, and every call is recorded.
///
/// Counting calls is the point — most of what this suite asserts is *work not
/// done* (a stamp-unchanged file not re-parsed, an unindexable language never
/// reaching the extractor at all), which no amount of inspecting the resulting
/// index can show.
private final class RecordingExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var callsStorage: [String] = []
    private var gateStorage: Gate?

    /// The file names handed to the extractor, in call order.
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    /// Held on the *next* extraction, so a test can stage a folder switch
    /// landing mid-parse.
    func gateNextCall(_ gate: Gate) {
        lock.lock()
        gateStorage = gate
        lock.unlock()
    }

    /// The closure `SymbolIndexModel` is constructed with — synchronous, exactly
    /// as the seam demands.
    var extract: @Sendable (String, SyntaxLanguage, URL) -> [Symbol] {
        { [self] text, _, url in symbols(in: text, fileURL: url) }
    }

    private func symbols(in text: String, fileURL: URL) -> [Symbol] {
        lock.lock()
        callsStorage.append(fileURL.lastPathComponent)
        let gate = gateStorage
        gateStorage = nil
        lock.unlock()
        gate?.wait()

        var found: [Symbol] = []
        var offset = 0
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("sym ") {
                let name = String(line.dropFirst(4))
                if !name.isEmpty {
                    found.append(
                        Symbol(
                            name: name,
                            kind: .function,
                            range: NSRange(location: offset + 4, length: (name as NSString).length),
                            fileURL: fileURL,
                            line: number + 1
                        )
                    )
                }
            }
            offset += (line as NSString).length + 1
        }
        return found
    }
}

/// A *mutable* stand-in for the workspace's open tabs, so a test can close one
/// while a walk is in flight — which the constant closures elsewhere in this
/// suite cannot express.
private final class OpenBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: String]

    init(_ storage: [URL: String]) { self.storage = storage }

    /// The closure `SymbolIndexModel` is constructed with.
    var snapshot: [URL: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func close(_ url: URL) {
        lock.lock()
        storage[url] = nil
        lock.unlock()
    }
}

@MainActor
final class SymbolIndexModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project")
    private let otherRoot = URL(fileURLWithPath: "/other")

    private func names(_ model: SymbolIndexModel, _ name: String) -> [String] {
        model.index.symbols(named: name).map(\.name)
    }

    // MARK: - What gets indexed

    func testRebuildIndexesEveryIndexableFile() async {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "sym alpha\n",
            "sub/b.py": "sym beta\n",
            "notes.txt": "sym gamma\n"
        ])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)

        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "b.py"])
        XCTAssertEqual(names(model, "alpha"), ["alpha"])
        XCTAssertEqual(names(model, "beta"), ["beta"])
        // An unknown extension resolves to no language at all, so it is dropped
        // before it is even read.
        XCTAssertTrue(names(model, "gamma").isEmpty)
        XCTAssertFalse(stub.readPaths.contains("notes.txt"))
        XCTAssertEqual(model.index.indexedFileCount, 2)
        XCTAssertFalse(model.isIndexing)
    }

    func testUnindexableLanguagesNeverReachTheExtractor() async {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "sym alpha\n",
            ".gitignore": "sym ignored\n"
        ])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)

        // The traversal reads `.gitignore` for its rules, but the *index* never
        // parses it: it ships no `symbols.scm`, so it can declare nothing.
        XCTAssertEqual(extractor.calls, ["a.swift"])
        XCTAssertTrue(names(model, "ignored").isEmpty)
    }

    func testUnindexableLanguagesAreExactlyTheOnesShippingNoQuery() {
        XCTAssertEqual(SymbolIndexModel.unindexableLanguages, [.gitignore])
        for language in SyntaxLanguage.allCases where language != .gitignore {
            XCTAssertTrue(SymbolIndexModel.isIndexable(language), "\(language) should be indexable")
        }
        XCTAssertFalse(SymbolIndexModel.isIndexable(.gitignore))
        XCTAssertEqual(SymbolIndexModel.indexableLanguage(forFileName: "a.swift"), .swift)
        XCTAssertNil(SymbolIndexModel.indexableLanguage(forFileName: ".gitignore"))
        XCTAssertNil(SymbolIndexModel.indexableLanguage(forFileName: "a.unknownext"))
    }

    func testBinaryOrOversizeFileIsIndexedAsEmptyRatherThanReReadForever() async {
        let stub = StubFileTree(root: root, files: ["big.swift": "sym huge\n"])
        stub.skippedFiles = ["big.swift"]
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)
        await model.refresh(root: root)

        XCTAssertTrue(extractor.calls.isEmpty)
        // Indexed (so its unchanged stamp is recorded) but empty.
        XCTAssertEqual(model.index.indexedFileCount, 1)
        XCTAssertTrue(model.index.symbols(inFile: stub.url("big.swift")).isEmpty)
    }

    func testTheModelNeverWritesToDisk() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)

        await model.rebuild(root: root)
        await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)
        await model.refresh(root: root)

        XCTAssertTrue(stub.writtenPaths.isEmpty)
    }

    // MARK: - Incremental availability

    func testSymbolsAreAnswerableBeforeTheWalkFinishes() async {
        var files: [String: String] = [:]
        for number in 0..<40 {
            files[String(format: "f%02d.swift", number)] = "sym s\(number)\n"
        }
        let stub = StubFileTree(root: root, files: files)
        let gate = Gate()
        // The first file of the *second* chunk: reaching it proves the first
        // chunk has already been published.
        stub.readGate = (path: "f32.swift", gate: gate)
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)

        let walk = Task { await model.rebuild(root: root) }
        await gate.waitUntilReached()

        XCTAssertEqual(model.index.indexedFileCount, SymbolIndexModel.chunkSize)
        XCTAssertEqual(names(model, "s0"), ["s0"])
        XCTAssertTrue(names(model, "s39").isEmpty)
        XCTAssertTrue(model.isIndexing)

        gate.release()
        await walk.value

        XCTAssertEqual(model.index.indexedFileCount, 40)
        XCTAssertEqual(names(model, "s39"), ["s39"])
        XCTAssertFalse(model.isIndexing)
    }

    // MARK: - Generation

    func testPrepareForFolderChangeClearsTheIndexSynchronously() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)
        XCTAssertFalse(model.index.isEmpty)

        let before = model.currentRequestGeneration
        let generation = model.prepareForFolderChange(root: otherRoot)

        // Cleared in the same turn as the call, with no `Task` hop in between:
        // a stale symbol must never be jumpable to while the new project loads.
        XCTAssertTrue(model.index.isEmpty)
        XCTAssertGreaterThan(generation, before)
        XCTAssertEqual(model.currentRequestGeneration, generation)
    }

    func testPrepareForTheSameFolderIsANoOp() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)
        let generation = model.currentRequestGeneration

        XCTAssertEqual(model.prepareForFolderChange(root: root), generation)
        XCTAssertFalse(model.index.isEmpty)
    }

    func testRebuildRejectsASupersededRequestGeneration() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)

        let stale = model.prepareForFolderChange(root: root)
        _ = model.prepareForFolderChange(root: otherRoot)

        // Two rapid folder opens: the deferred rebuild for the first must not
        // run at all, since `Task`s are not guaranteed to start in creation
        // order.
        await model.rebuild(root: root, request: stale)

        XCTAssertTrue(model.index.isEmpty)
        XCTAssertTrue(stub.readPaths.isEmpty)
    }

    func testSupersededRebuildPublishesNothing() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)

        let walk = Task { await model.rebuild(root: root) }
        await gate.waitUntilReached()
        _ = model.prepareForFolderChange(root: otherRoot)
        gate.release()
        await walk.value

        XCTAssertTrue(model.index.isEmpty)
    }

    func testTwoRapidFolderChangesSettleOnTheNewerOne() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let gate = Gate()
        stub.listingGate = gate
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)

        let first = Task { await model.rebuild(root: root) }
        await gate.waitUntilReached()

        // The second project takes the stub over while the first walk is held.
        stub.root = otherRoot
        stub.files = ["b.swift": "sym beta\n"]
        let generation = model.prepareForFolderChange(root: otherRoot)
        gate.release()
        await first.value
        await model.rebuild(root: otherRoot, request: generation)

        XCTAssertEqual(names(model, "beta"), ["beta"])
        XCTAssertTrue(names(model, "alpha").isEmpty)
    }

    // MARK: - Stamp-gated refresh

    func testRefreshOnlyReExtractsFilesWhoseStampChanged() async {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "sym alpha\n",
            "b.swift": "sym beta\n"
        ])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)
        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "b.swift"])

        await model.refresh(root: root)
        // Nothing changed on disk, so nothing is re-read and nothing is
        // re-parsed — the property that keeps an `npm i` cheap.
        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "b.swift"])

        stub.files["b.swift"] = "sym betaTwo\n"
        await model.refresh(root: root)

        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "b.swift", "b.swift"])
        XCTAssertEqual(names(model, "betaTwo"), ["betaTwo"])
        XCTAssertTrue(names(model, "beta").isEmpty)
        XCTAssertEqual(names(model, "alpha"), ["alpha"])
    }

    func testRefreshReExtractsASameSizeEditOnItsModificationDate() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        // A stamp the byte count alone cannot tell apart from the next one — the
        // typo fix, the `let`→`var`, the equal-length rename. Only the date moves.
        let first = Date(timeIntervalSince1970: 1_000)
        stub.stampOverrides["a.swift"] = FileStamp(byteCount: 10, modificationDate: first)
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)
        XCTAssertEqual(extractor.calls, ["a.swift"])

        stub.files["a.swift"] = "sym omega\n"
        stub.stampOverrides["a.swift"] = FileStamp(
            byteCount: 10,
            modificationDate: first.addingTimeInterval(60)
        )
        await model.refresh(root: root)

        XCTAssertEqual(extractor.calls, ["a.swift", "a.swift"])
        XCTAssertEqual(names(model, "omega"), ["omega"])
        XCTAssertTrue(names(model, "alpha").isEmpty)
    }

    func testAnUnreadableFileIsSkippedAndRetriedOnTheNextRefresh() async {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "sym alpha\n",
            "b.swift": "sym beta\n"
        ])
        stub.unreadableFiles = ["b.swift"]
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)

        // A throwing read produces no outcome at all, so no stamp is recorded for
        // it — the half that matters, since a stamp would make every later refresh
        // conclude the file was up to date and never look at it again.
        XCTAssertEqual(extractor.calls, ["a.swift"])
        XCTAssertTrue(names(model, "beta").isEmpty)

        stub.unreadableFiles = []
        await model.refresh(root: root)

        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "b.swift"])
        XCTAssertEqual(names(model, "beta"), ["beta"])
    }

    func testRefreshReExtractsEverythingWhenStampsAreUnavailable() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        stub.stampsAreUnavailable = true
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.rebuild(root: root)
        await model.refresh(root: root)

        // "Unknown" means "re-read it": a service that reports no stamps degrades
        // to correct-but-slower, never to stale.
        XCTAssertEqual(extractor.calls, ["a.swift", "a.swift"])
    }

    func testRefreshDropsAFileTheWalkNoLongerSees() async {
        let stub = StubFileTree(root: root, files: [
            "a.swift": "sym alpha\n",
            "b.swift": "sym beta\n"
        ])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)

        stub.files["b.swift"] = nil
        await model.refresh(root: root)

        XCTAssertTrue(names(model, "beta").isEmpty)
        XCTAssertEqual(names(model, "alpha"), ["alpha"])
        XCTAssertEqual(model.index.indexedFileCount, 1)
    }

    func testARefreshForTheFolderTheUserJustLeftIsDiscarded() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)

        // The folder switch, exactly as the app performs it: registered
        // synchronously, then walked.
        stub.root = otherRoot
        stub.files = ["b.swift": "sym beta\n"]
        let request = model.prepareForFolderChange(root: otherRoot)
        await model.rebuild(root: otherRoot, request: request)

        // The watcher callback for the *previous* root, enqueued before the switch
        // and delivered after it (`DispatchQueue.main.async`). Treating it as a
        // folder change would clear the index the switch just filled and refill it
        // from a folder that is no longer open.
        await model.refresh(root: root)

        XCTAssertEqual(names(model, "beta"), ["beta"])
        XCTAssertTrue(names(model, "alpha").isEmpty)
        XCTAssertEqual(model.index.indexedFileCount, 1)
    }

    // MARK: - Buffers

    func testOpenBuffersAreIndexedInsteadOfDiskContents() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let url = stub.url("a.swift")
        let model = SymbolIndexModel(
            fileService: stub,
            openBuffers: { [url: "sym typed\n"] },
            extractSymbols: RecordingExtractor().extract
        )

        await model.rebuild(root: root)

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "saved").isEmpty)
        XCTAssertFalse(stub.readPaths.contains("a.swift"))
    }

    func testAnOpenBufferOutsideTheWalkedRootIsStillIndexed() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        // A tab the traversal cannot produce: it names a file under the folder the
        // user just left (or one this project's `.gitignore` excludes). The walk
        // is the only thing that runs on a folder switch, and it clears the
        // buffer marks first — so if it skipped this tab, the file the user is
        // looking at would answer nothing until they switched away and back.
        let outside = URL(fileURLWithPath: "/elsewhere/tool.swift")
        let notes = URL(fileURLWithPath: "/elsewhere/notes.txt")
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(
            fileService: stub,
            openBuffers: { [outside: "sym typed\n", notes: "sym ignored\n"] },
            extractSymbols: extractor.extract
        )

        await model.rebuild(root: root)

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertEqual(names(model, "alpha"), ["alpha"])
        // The language gate still applies, and the buffer is never read from disk.
        XCTAssertTrue(names(model, "ignored").isEmpty)
        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "tool.swift"])
        // Its text comes from the buffer, never from disk — which is what makes a
        // candidate the traversal never produced safe to add.
        XCTAssertEqual(stub.readPaths, ["a.swift"])

        // And it is buffer-owned like any other tab: a later refresh neither
        // re-parses it nor drops it for being outside the walk.
        await model.refresh(root: root)
        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertEqual(extractor.calls.sorted(), ["a.swift", "tool.swift"])
    }

    func testAWalkTimeBufferSnapshotDoesNotClobberANewerReindex() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let url = stub.url("a.swift")
        let extractor = RecordingExtractor()
        // The walk reads the workspace once, before it starts. The sibling test
        // `testBufferEntrySurvivesAChunkThatReadDiskBeforeTheEdit` stages this
        // window for a chunk that read *disk*; this one stages it for a chunk that
        // took the walk-time *buffer* snapshot, which is text the user has since
        // typed past. It carries a buffer's authority but not its freshness, so
        // the `apply` guard has to tell the two apart.
        let model = SymbolIndexModel(
            fileService: stub,
            openBuffers: { [url: "sym stale\n"] },
            extractSymbols: extractor.extract
        )

        let gate = Gate()
        stub.listingGate = gate
        let walk = Task { await model.rebuild(root: root) }
        await gate.waitUntilReached()

        let reindex = Task {
            await model.reindexBuffer(url: url, text: "sym typed\n", language: .swift)
        }
        // Let the re-index reach its own off-main hop, so it is queued behind the
        // held traversal and ahead of the chunk that follows it.
        await Task.yield()
        gate.release()
        await reindex.value
        await walk.value

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "stale").isEmpty)
    }

    func testReindexBufferPublishesTheBuffersSymbols() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)

        await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "saved").isEmpty)
    }

    func testReindexBufferSkipsAnUnindexableLanguage() async {
        let stub = StubFileTree(root: root, files: [:])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)

        await model.reindexBuffer(url: stub.url(".gitignore"), text: "sym ignored\n", language: .gitignore)

        XCTAssertTrue(extractor.calls.isEmpty)
        XCTAssertTrue(model.index.isEmpty)
    }

    func testReindexBufferSupersededMidFlightPublishesNothing() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)
        await model.rebuild(root: root)

        let gate = Gate()
        extractor.gateNextCall(gate)
        let reindex = Task {
            await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)
        }
        await gate.waitUntilReached()
        _ = model.prepareForFolderChange(root: otherRoot)
        gate.release()
        await reindex.value

        // The parse finished for a project the user has already left, so its
        // result is discarded rather than published into the new one's index.
        XCTAssertTrue(model.index.isEmpty)
    }

    func testARefreshDoesNotClobberABufferSourcedEntry() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)
        await model.rebuild(root: root)
        await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)

        // The file changes on disk (a `git checkout` of it, say) while the tab
        // still holds the user's text.
        stub.files["a.swift"] = "sym savedTwo\n"
        await model.refresh(root: root)

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "savedTwo").isEmpty)
        // Not merely "the result was dropped": the file is not read or parsed at
        // all. Dropping it downstream would leave the file the user is typing in
        // being re-read and re-parsed on every FSEvents burst for nothing.
        XCTAssertEqual(extractor.calls, ["a.swift", "a.swift"])
        XCTAssertEqual(stub.readPaths, ["a.swift"])
    }

    func testARefreshDoesNotResurrectTheWalkTimeBufferSnapshot() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let extractor = RecordingExtractor()
        let url = stub.url("a.swift")
        // The workspace snapshot a walk reads *once*, before it starts — the tab's
        // text as of that moment. Every other buffer test here leaves it empty,
        // which is the one arrangement the app never wires.
        let model = SymbolIndexModel(
            fileService: stub,
            openBuffers: { [url: "sym stale\n"] },
            extractSymbols: extractor.extract
        )
        await model.rebuild(root: root)
        XCTAssertEqual(names(model, "stale"), ["stale"])

        // The user keeps typing; the debounced re-index publishes ahead of the
        // snapshot, which nothing updates.
        await model.reindexBuffer(url: url, text: "sym typed\n", language: .swift)

        await model.refresh(root: root)

        // The refresh must not republish the file from text that is now two edits
        // old — and must not re-parse it to do so.
        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "stale").isEmpty)
        XCTAssertEqual(extractor.calls, ["a.swift", "a.swift"])
    }

    func testReindexBufferCancelledMidFlightPublishesNothing() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)
        await model.rebuild(root: root)

        let url = stub.url("a.swift")
        let gate = Gate()
        extractor.gateNextCall(gate)
        let reindex = Task {
            await model.reindexBuffer(url: url, text: "sym typed\n", language: .swift)
        }
        await gate.waitUntilReached()
        // Exactly what a tab close does: cancel the in-flight re-index, then hand
        // the entry back to disk. Without the cancellation re-check the parse
        // would resume afterwards and re-mark the file buffer-sourced, pinning the
        // index to text no editor holds any more.
        reindex.cancel()
        model.forgetBuffer(url: url)
        gate.release()
        await reindex.value

        XCTAssertTrue(names(model, "typed").isEmpty)
        XCTAssertEqual(names(model, "saved"), ["saved"])

        // And the entry is disk-owned again rather than skipped forever: the file
        // changing on disk now reaches the index.
        stub.files["a.swift"] = "sym savedTwo\n"
        await model.refresh(root: root)
        XCTAssertEqual(names(model, "savedTwo"), ["savedTwo"])
    }

    func testABufferSourcedFileTheWalkNeverSeesIsNotRemoved() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)

        // A tab on a file the traversal does not produce — outside the opened
        // folder, or excluded by the project's `.gitignore`.
        let outside = URL(fileURLWithPath: "/elsewhere/tool.swift")
        await model.reindexBuffer(url: outside, text: "sym typed\n", language: .swift)

        await model.refresh(root: root)

        // Removing it would break completion in the very file being typed in.
        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertEqual(names(model, "alpha"), ["alpha"])
    }

    func testABufferReindexSurvivesARefreshThatStartsMidParse() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let extractor = RecordingExtractor()
        let model = SymbolIndexModel(fileService: stub, extractSymbols: extractor.extract)
        await model.rebuild(root: root)

        let gate = Gate()
        extractor.gateNextCall(gate)
        let reindex = Task {
            await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)
        }
        await gate.waitUntilReached()

        // An FSEvents refresh (a save, a build, an `npm i`) starts while the
        // buffer parse is still running. It advances the *walk* generation, which
        // must not be read as "the user left the project" — the parse holds the
        // only copy of what was just typed, and nothing retries it.
        let refresh = Task { await model.refresh(root: root) }
        while !model.isIndexing { await Task.yield() }
        gate.release()
        await reindex.value
        await refresh.value

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "alpha").isEmpty)
    }

    func testBufferEntrySurvivesAChunkThatReadDiskBeforeTheEdit() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)

        // Stage the exact window the buffer-over-disk rule exists for: the file
        // changed on disk, so the refresh *will* read it, and the tab is
        // re-indexed after the walk took its buffer snapshot but before the
        // chunk's result is applied.
        stub.files["a.swift"] = "sym savedTwo\n"
        let gate = Gate()
        stub.listingGate = gate
        let refresh = Task { await model.refresh(root: root) }
        await gate.waitUntilReached()

        let reindex = Task {
            await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)
        }
        // Let the re-index reach its own off-main hop, so it is queued behind the
        // held traversal and ahead of the chunk that follows it.
        await Task.yield()
        gate.release()
        await reindex.value
        await refresh.value

        XCTAssertEqual(names(model, "typed"), ["typed"])
        XCTAssertTrue(names(model, "savedTwo").isEmpty)
    }

    func testATabClosedMidWalkDoesNotLeaveTheFileBufferOwned() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let url = stub.url("a.swift")
        let buffers = OpenBuffers([url: "sym typed\n"])
        let model = SymbolIndexModel(
            fileService: stub,
            openBuffers: { buffers.snapshot },
            extractSymbols: RecordingExtractor().extract
        )

        let gate = Gate()
        stub.listingGate = gate
        let walk = Task { await model.rebuild(root: root) }
        await gate.waitUntilReached()

        // The tab closes after the walk read the workspace, so its chunk is still
        // carrying an outcome extracted from a buffer that no longer exists — the
        // walk's version of the window `reindexBuffer`'s cancellation check covers.
        buffers.close(url)
        model.forgetBuffer(url: url)
        gate.release()
        await walk.value

        // The symbols survive: they are still the best text anyone has for the
        // file.
        XCTAssertEqual(names(model, "typed"), ["typed"])

        // What must *not* survive is the ownership. If the outcome had marked the
        // file buffer-sourced, every later refresh would skip it and the entry
        // would stay frozen for the rest of the session.
        stub.files["a.swift"] = "sym savedTwo\n"
        await model.refresh(root: root)
        XCTAssertEqual(names(model, "savedTwo"), ["savedTwo"])
        XCTAssertTrue(names(model, "typed").isEmpty)
    }

    func testForgetBufferLetsTheNextRefreshTakeTheDiskVersion() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym saved\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        await model.rebuild(root: root)
        await model.reindexBuffer(url: stub.url("a.swift"), text: "sym typed\n", language: .swift)

        model.forgetBuffer(url: stub.url("a.swift"))
        // The stamp went with the mark, so the file is re-extracted even though
        // disk has not changed since the rebuild.
        await model.refresh(root: root)

        XCTAssertEqual(names(model, "saved"), ["saved"])
        XCTAssertTrue(names(model, "typed").isEmpty)
    }

    // MARK: - Provider

    func testProviderAnswersFromTheModelsLatestSnapshot() async {
        let stub = StubFileTree(root: root, files: ["a.swift": "sym alpha\n"])
        let model = SymbolIndexModel(fileService: stub, extractSymbols: RecordingExtractor().extract)
        let provider = model.provider

        let beforeWalk = await provider.definitions(
            for: DefinitionRequest(identifier: "alpha", fileURL: nil, offset: 0)
        )
        XCTAssertTrue(beforeWalk.isEmpty)

        await model.rebuild(root: root)

        let candidates = await provider.definitions(
            for: DefinitionRequest(identifier: "alpha", fileURL: nil, offset: 0)
        )
        XCTAssertEqual(candidates.map(\.relativePath), ["a.swift"])
        XCTAssertEqual(candidates.first?.symbol.line, 1)
    }
}
