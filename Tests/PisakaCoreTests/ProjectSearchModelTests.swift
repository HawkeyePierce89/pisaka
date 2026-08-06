import XCTest
@testable import PisakaCore

@MainActor
final class ProjectSearchModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project")

    // MARK: - Stubs

    /// A blocking rendezvous the off-main traversal runs into, so a test can hold
    /// a search suspended while it changes the model's state on the main actor.
    private final class Gate {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reachedFlag = false

        /// Whether the gated code has been entered (readable from any thread).
        var reached: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachedFlag
        }

        func wait() {
            lock.lock()
            reachedFlag = true
            lock.unlock()
            semaphore.wait()
        }

        func release() { semaphore.signal() }
    }

    /// An in-memory tree: `files` maps root-relative paths to contents, and the
    /// directory listing is derived from those keys. Deliberately *does not*
    /// filter `.git`/`.DS_Store` — that is the traversal's job, and the test for
    /// it would be vacuous if the stub hid them first.
    private final class StubFiles: FileServicing {
        /// Mutable so a test can re-point the whole tree at a second folder, which
        /// is how the folder-switch tests give the *new* project real files to
        /// find (the model holds one service, so the two projects take turns).
        var root: URL
        var files: [String: String]
        /// Root-relative paths reported as symbolic links.
        var symlinks: Set<String> = []
        /// Root-relative directory paths whose listing throws (`""` for the root).
        var unreadableDirectories: Set<String> = []
        /// Root-relative paths whose `write` throws.
        var failingWrites: Set<String> = []
        /// Held on the *first* directory listing, if set.
        var gate: Gate?
        /// Held on the *first* file read, if set.
        var readGate: Gate?

        private let lock = NSLock()
        private var readPathsStorage: [String] = []
        private var writtenPathsStorage: [String] = []

        /// The root-relative paths whose contents were read, in call order.
        var readPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return readPathsStorage
        }

        /// The root-relative paths written to, in call order (a failed write is
        /// not recorded — nothing reached the file).
        var writtenPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return writtenPathsStorage
        }

        init(root: URL, files: [String: String]) {
            self.root = root
            self.files = files
        }

        private enum StubError: Error, LocalizedError {
            case missing
            case denied

            var errorDescription: String? {
                switch self {
                case .missing: return "No such file."
                case .denied: return "Permission denied."
                }
            }
        }

        func read(url: URL) throws -> String {
            if let readGate {
                self.readGate = nil
                readGate.wait()
            }
            let path = relative(url)
            guard let contents = files[path] else { throw StubError.missing }
            lock.lock()
            readPathsStorage.append(path)
            lock.unlock()
            return contents
        }

        func write(_ text: String, to url: URL) throws {
            let path = relative(url)
            guard !failingWrites.contains(path) else { throw StubError.denied }
            files[path] = text
            lock.lock()
            writtenPathsStorage.append(path)
            lock.unlock()
        }

        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
            if let gate {
                self.gate = nil
                gate.wait()
            }
            let prefix = relative(url).isEmpty ? [] : relative(url).split(separator: "/").map(String.init)
            guard !unreadableDirectories.contains(relative(url)) else { throw StubError.missing }

            var names: [String: Bool] = [:]
            for path in files.keys {
                let components = path.split(separator: "/").map(String.init)
                guard components.count > prefix.count,
                      Array(components.prefix(prefix.count)) == prefix
                else { continue }
                let name = components[prefix.count]
                let isDirectory = components.count > prefix.count + 1
                names[name] = (names[name] ?? false) || isDirectory
            }
            return names
                .map { DirectoryEntry(url: url.appendingPathComponent($0.key), isDirectory: $0.value) }
                .sorted { lhs, rhs in
                    lhs.isDirectory != rhs.isDirectory
                        ? lhs.isDirectory
                        : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }

        func symbolicLinkDestination(at url: URL) -> String? {
            symlinks.contains(relative(url)) ? "elsewhere" : nil
        }

        private func relative(_ url: URL) -> String {
            let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(base) else { return "" }
            return String(url.path.dropFirst(base.count))
        }
    }

    // MARK: - Traversal

    func testTraversalSkipsGitDirectoryAndHonorsNestedGitignore() async {
        let stub = StubFiles(root: root, files: [
            ".gitignore": "build/\n*.log\n",
            "a.swift": "needle here",
            "app.log": "needle in a log",
            "build/generated.swift": "needle generated",
            ".git/COMMIT_EDITMSG": "needle committed",
            "sub/.gitignore": "!keep.log\n",
            "sub/keep.log": "needle kept",
            "sub/drop.log": "needle dropped",
            "sub/b.swift": "needle nested"
        ])
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["a.swift", "sub/b.swift", "sub/keep.log"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.truncated)
    }

    func testTraversalDoesNotDescendIntoSymlinkedDirectory() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle",
            "link/looped.swift": "needle"
        ])
        stub.symlinks = ["link"]
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["a.swift"])
    }

    func testTraversalSkipsSymlinkedFiles() async {
        let stub = StubFiles(root: root, files: [
            "real.swift": "needle",
            "link.swift": "needle"
        ])
        // A symlink to a *file* dereferences to `isDirectory == false`, so it is
        // indistinguishable from an ordinary entry in the listing: without the
        // explicit probe it would be searched (duplicating its target's matches)
        // and, on Replace All, overwritten with a regular file.
        stub.symlinks = ["link.swift"]
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["real.swift"])
    }

    func testUnreadableDirectoryIsSkippedRatherThanFailingTheSearch() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle",
            "secret/b.swift": "needle"
        ])
        stub.unreadableDirectories = ["secret"]
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["a.swift"])
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - File mask

    func testFileMaskFiltersFilesByGlob() async {
        let stub = StubFiles(root: root, files: [
            "a.ts": "needle",
            "b.tsx": "needle",
            "c.js": "needle",
            "d.ts.map": "needle"
        ])
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "*.ts,*.tsx")

        XCTAssertEqual(paths(model), ["a.ts", "b.tsx"])
        XCTAssertEqual(model.fileMask, "*.ts,*.tsx")
    }

    func testMaskPatternsSplitOnCommasAndWhitespace() {
        XCTAssertEqual(ProjectSearchModel.maskPatterns("*.ts, *.tsx"), ["*.ts", "*.tsx"])
        XCTAssertEqual(ProjectSearchModel.maskPatterns("  "), [])
        XCTAssertEqual(ProjectSearchModel.maskPatterns(""), [])
        // No patterns means every file, not no file.
        XCTAssertTrue(ProjectSearchModel.matchesMask(name: "anything.bin", patterns: []))
        XCTAssertTrue(ProjectSearchModel.matchesMask(name: "a.ts", patterns: ["*.ts"]))
        XCTAssertFalse(ProjectSearchModel.matchesMask(name: "a.js", patterns: ["*.ts"]))
    }

    // MARK: - Skipped files

    func testBinaryAndOversizeFilesAreSkipped() async {
        let stub = StubFiles(root: root, files: [
            "text.swift": "needle",
            "image.png": "PNG\0needle",
            "huge.swift": String(repeating: "needle ", count: 10)
        ])
        // 20 bytes: "needle" fits, the 70-byte file does not.
        let model = ProjectSearchModel(fileService: stub, maxFileBytes: 20)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["text.swift"])
    }

    // MARK: - Open buffers

    func testDirtyOpenBufferIsSearchedInsteadOfDiskContents() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "saved text with no hits",
            "b.swift": "needle on disk"
        ])
        let dirty = root.appendingPathComponent("a.swift")
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { [dirty: "unsaved needle in the buffer"] }
        )

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["a.swift", "b.swift"])
        XCTAssertEqual(model.results.first?.previews.first?.text, "unsaved needle in the buffer")
        // The buffered file's contents were never read from disk (only its
        // `.gitignore`-less directory listing touched the service).
        XCTAssertFalse(stub.readPaths.contains("a.swift"))
        XCTAssertTrue(stub.readPaths.contains("b.swift"))
    }

    func testOpenBuffersAreSnapshotOncePerSearchNotPerFile() async {
        var files: [String: String] = [:]
        for index in 0..<80 { files["f\(index).swift"] = "needle \(index)" }
        let stub = StubFiles(root: root, files: files)
        let counter = CallCounter()
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: {
                counter.bump()
                return [:]
            }
        )

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(model.results.count, 80)
        // 80 files span three chunks, so a per-file (or even per-chunk) lookup
        // would show here. The workspace is read *once* for the whole walk: the
        // closure runs on the main actor and matching a candidate against the
        // tabs costs a symlink resolution per tab, so asking per file would put
        // `files × tabs` of them on the main thread.
        XCTAssertEqual(counter.count, 1)
    }

    func testOpenBufferMatchesATabSpelledThroughADifferentPath() async {
        let stub = StubFiles(root: root, files: ["a.swift": "saved text with no hits"])
        // The same file named with a `..` hop — one of the spellings
        // `WorkspaceModel.fileID(forURL:)` canonicalizes away when it matches
        // tabs, so the snapshot's keying has to agree with it or a dirty buffer
        // would be missed and the stale on-disk text searched instead.
        let spelled = root.appendingPathComponent("sub/../a.swift")
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { [spelled: "unsaved needle"] }
        )

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertEqual(paths(model), ["a.swift"])
        XCTAssertEqual(model.results.first?.previews.first?.text, "unsaved needle")
        XCTAssertFalse(stub.readPaths.contains("a.swift"))
    }

    // MARK: - Results shape

    func testResultsCarryLineNumbersAndPreviewRanges() async {
        let stub = StubFiles(root: root, files: [
            "src/a.swift": "first line\nlet needle = 1\nthird\n"
        ])
        let model = ProjectSearchModel(fileService: stub)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        guard let result = model.results.first else { return XCTFail("no result") }
        XCTAssertEqual(result.relativePath, "src/a.swift")
        XCTAssertEqual(result.fileURL, root.appendingPathComponent("src/a.swift"))
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.matches.first?.lineNumber, 2)
        // The preview is the whole logical line, separator stripped, with the
        // match located inside it.
        XCTAssertEqual(result.previews.first?.text, "let needle = 1")
        XCTAssertEqual(result.previews.first?.matchRange, NSRange(location: 4, length: 6))
    }

    func testPreviewClipsAVeryLongLineAroundTheMatch() {
        let padding = String(repeating: "x", count: 5_000)
        let text = (padding + "needle" + padding) as NSString
        let match = SearchMatch(range: NSRange(location: 5_000, length: 6), lineNumber: 1)

        let preview = ProjectSearchModel.preview(for: match, in: text)

        XCTAssertEqual(preview.text.utf16.count, ProjectSearchModel.previewWindow)
        XCTAssertEqual(preview.matchRange, NSRange(location: ProjectSearchModel.previewLead, length: 6))
        XCTAssertEqual((preview.text as NSString).substring(with: preview.matchRange), "needle")
    }

    // MARK: - Truncation

    func testMatchCapTruncatesResults() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle needle needle",
            "b.swift": "needle needle needle"
        ])
        let model = ProjectSearchModel(fileService: stub, maxMatches: 4)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertTrue(model.truncated)
        XCTAssertEqual(model.results.map(\.matchCount).reduce(0, +), 4)
        XCTAssertFalse(model.isSearching)
        // The cap is the one place a file's `matches` and `previews` are clipped
        // independently, and the view indexes one by the other — a desync would be
        // an out-of-range crash in a result row, not a wrong answer.
        for result in model.results {
            XCTAssertEqual(result.matches.count, result.previews.count)
        }
    }

    func testChunkStopsMaterializingMatchesAtItsBudget() {
        let stub = StubFiles(root: root, files: [:])
        let files = [
            root.appendingPathComponent("a.swift"),
            root.appendingPathComponent("b.swift")
        ]
        // Both files stand in as open buffers, so the chunk never reaches the
        // (empty) stub for their contents.
        let buffers = ProjectSearchModel.bufferIndex(
            Dictionary(uniqueKeysWithValues: files.map { ($0, "needle needle needle") })
        )

        let found = ProjectSearchModel.searchChunk(
            files: files,
            buffers: buffers,
            root: root,
            query: SearchQuery(pattern: "needle"),
            fileService: stub,
            maxBytes: ProjectSearchModel.defaultMaxFileBytes,
            matchBudget: 4
        )

        // The budget is what bounds the *work*: without it both files' matches
        // and their ~300-unit previews are built in full before the caller clips
        // a single one, so a chunk of megabyte-scale files allocates hundreds of
        // megabytes it immediately discards.
        XCTAssertEqual(found.map(\.matches.count), [3, 1])
        XCTAssertEqual(found.map(\.previews.count), [3, 1])
        // A budget already spent stops the chunk rather than searching on.
        XCTAssertTrue(
            ProjectSearchModel.searchChunk(
                files: files,
                buffers: buffers,
                root: root,
                query: SearchQuery(pattern: "needle"),
                fileService: stub,
                maxBytes: ProjectSearchModel.defaultMaxFileBytes,
                matchBudget: 0
            ).isEmpty
        )
    }

    func testCapReachedExactlyOnAFileBoundaryStillReportsTruncation() async {
        // `a` fills the cap exactly, so the overflow that raises `truncated` is
        // `b`'s first match — the one the chunk's `remaining + 1` budget exists
        // to keep producing.
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle needle",
            "b.swift": "needle needle"
        ])
        let model = ProjectSearchModel(fileService: stub, maxMatches: 2)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertTrue(model.truncated)
        XCTAssertEqual(paths(model), ["a.swift"])
        XCTAssertEqual(model.results.map(\.matchCount).reduce(0, +), 2)
    }

    func testResultsUnderTheCapAreNotTruncated() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle needle"])
        let model = ProjectSearchModel(fileService: stub, maxMatches: 4)

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        XCTAssertFalse(model.truncated)
        XCTAssertEqual(model.results.first?.matchCount, 2)
    }

    // MARK: - Query validation

    func testBlankPatternClearsResultsWithoutAnError() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")
        XCTAssertFalse(model.results.isEmpty)

        await model.search(root: root, query: SearchQuery(pattern: "   "), mask: "")

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isSearching)
    }

    func testInvalidRegexReportsItsReasonAndClearsResults() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        await model.search(root: root, query: SearchQuery(pattern: "([", isRegex: true), mask: "")

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.errorMessage?.isEmpty ?? true)
    }

    // MARK: - Generations

    func testPrepareForSearchClearsStaleResultsSynchronously() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")
        XCTAssertFalse(model.results.isEmpty)

        let generation = model.prepareForSearch(root: URL(fileURLWithPath: "/other"))

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.truncated)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(generation, model.currentRequestGeneration)
        // A repeat call for the same folder is a no-op.
        XCTAssertEqual(model.prepareForSearch(root: URL(fileURLWithPath: "/other")), generation)
    }

    /// `query`/`fileMask` describe *what produced the rows*, so they must be
    /// cleared together with them. Left behind next to an empty `results`, they
    /// say the new project was searched for that query and matched nothing — which
    /// is how a Find in Files window open across a folder switch came to report
    /// "No results" for a project it never walked, with Replace All still armed
    /// from the previous folder's rows.
    func testPrepareForSearchClearsTheQueryThatProducedTheStaleResults() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle", wholeWord: true), mask: "*.swift")
        XCTAssertEqual(model.query, SearchQuery(pattern: "needle", wholeWord: true))
        XCTAssertEqual(model.fileMask, "*.swift")

        model.prepareForSearch(root: URL(fileURLWithPath: "/other"))

        XCTAssertEqual(model.query, SearchQuery(pattern: ""))
        XCTAssertEqual(model.fileMask, "")
    }

    func testFolderChangeSupersedesAnInFlightSearch() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let gate = Gate()
        stub.gate = gate
        let model = ProjectSearchModel(fileService: stub)

        let task = Task { await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "") }
        await waitUntil { gate.reached }

        // The folder switched while the traversal was still blocked off-main.
        model.prepareForSearch(root: URL(fileURLWithPath: "/other"))
        gate.release()
        await task.value

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testNewerSearchSupersedesAnInFlightOne() async {
        let stub = StubFiles(root: root, files: ["a.swift": "alpha beta"])
        let gate = Gate()
        stub.gate = gate
        let model = ProjectSearchModel(fileService: stub)

        let stale = Task { await model.search(root: root, query: SearchQuery(pattern: "alpha"), mask: "") }
        await waitUntil { gate.reached }

        // The second search bumps the generation, so the first must discard its
        // results rather than publishing them over the newer ones.
        let fresh = Task { await model.search(root: root, query: SearchQuery(pattern: "beta"), mask: "") }
        gate.release()
        await stale.value
        await fresh.value

        XCTAssertEqual(model.query.pattern, "beta")
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.results.first?.previews.first?.matchRange, NSRange(location: 6, length: 4))
        XCTAssertFalse(model.isSearching)
    }

    func testSearchRejectsASupersededRequestGeneration() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        let stale = model.currentRequestGeneration
        model.prepareForSearch(root: URL(fileURLWithPath: "/other"))

        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "", request: stale)

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(stub.readPaths.isEmpty)
    }

    // MARK: - Replace all

    func testReplaceAllWritesClosedFilesAndSumsTheCounts() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle one needle",
            "b.swift": "no hits here",
            "sub/c.swift": "needle deep"
        ])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 2, matchesReplaced: 3))
        XCTAssertEqual(stub.files["a.swift"], "pin one pin")
        XCTAssertEqual(stub.files["sub/c.swift"], "pin deep")
        // A file with no match was never in the results, so it is never written.
        XCTAssertEqual(stub.files["b.swift"], "no hits here")
        XCTAssertEqual(stub.writtenPaths.sorted(), ["a.swift", "sub/c.swift"])
    }

    func testReplaceAllWithNoResultsIsAZeroSummary() async {
        let stub = StubFiles(root: root, files: ["a.swift": "nothing"])
        let model = ProjectSearchModel(fileService: stub)

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary())
        XCTAssertTrue(stub.writtenPaths.isEmpty)
    }

    func testReplaceAllSubstitutesRegexGroups() async {
        let stub = StubFiles(root: root, files: ["a.swift": "foo=1\nbar=22\n"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(
            root: root,
            query: SearchQuery(pattern: "(\\w+)=(\\d+)", isRegex: true),
            mask: ""
        )

        let summary = await model.replaceAll(template: "$2=$1")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 2))
        XCTAssertEqual(stub.files["a.swift"], "1=foo\n22=bar\n")
    }

    func testReplaceAllRoutesAnOpenBufferThroughTheApplyClosureWithoutWritingToDisk() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "saved needle",
            "b.swift": "disk needle"
        ])
        let dirty = root.appendingPathComponent("a.swift")
        let applied = AppliedBuffers()
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { [dirty: "unsaved needle here"] },
            applyBufferText: { url, text in
                applied.record(url: url, text: text)
                return true
            }
        )
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 2, matchesReplaced: 2))
        // The edit went to the buffer — verbatim, keeping the unsaved text — and
        // the file on disk was left exactly as it was, so the tab stays dirty.
        XCTAssertEqual(applied.entries.map(\.text), ["unsaved pin here"])
        XCTAssertEqual(applied.entries.map(\.url), [dirty])
        XCTAssertEqual(stub.files["a.swift"], "saved needle")
        XCTAssertEqual(stub.writtenPaths, ["b.swift"])
        XCTAssertEqual(stub.files["b.swift"], "disk pin")
    }

    func testReplaceAllReportsAnOpenBufferItCouldNotUpdate() async {
        let stub = StubFiles(root: root, files: ["a.swift": "saved needle"])
        let dirty = root.appendingPathComponent("a.swift")
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { [dirty: "unsaved needle"] },
            applyBufferText: { _, _ in false }
        )
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary.filesChanged, 0)
        XCTAssertEqual(summary.matchesReplaced, 0)
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertTrue(summary.errors[0].contains("a.swift"))
        XCTAssertTrue(stub.writtenPaths.isEmpty)
    }

    func testReplaceAllSkipsAFileThatChangedSinceTheSearch() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle here",
            "b.swift": "needle there"
        ])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // Someone edited the file out of band: the captured match no longer sits
        // where it did, so the replacement must not be applied blind.
        stub.files["a.swift"] = "the needle moved along the line"

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1, filesSkipped: 1))
        XCTAssertEqual(stub.files["a.swift"], "the needle moved along the line")
        XCTAssertEqual(stub.files["b.swift"], "pin there")
        XCTAssertEqual(stub.writtenPaths, ["b.swift"])
    }

    func testReplaceAllReportsAFileThatVanishedSinceTheSearch() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle here",
            "b.swift": "needle there"
        ])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        stub.files["a.swift"] = nil

        let summary = await model.replaceAll(template: "pin")

        // A read that *fails* is an error the user should see, unlike a file that
        // merely moved on (skipped) — and it does not stop the batch either.
        XCTAssertEqual(summary.filesChanged, 1)
        XCTAssertEqual(summary.filesSkipped, 0)
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertTrue(summary.errors[0].contains("a.swift"))
        XCTAssertEqual(stub.files["b.swift"], "pin there")
    }

    func testReplaceAllContinuesAfterAPerFileWriteFailure() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle here",
            "b.swift": "needle there"
        ])
        stub.failingWrites = ["a.swift"]
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        // The failure is reported and the batch carries on to the next file.
        XCTAssertEqual(summary.filesChanged, 1)
        XCTAssertEqual(summary.matchesReplaced, 1)
        XCTAssertEqual(summary.filesSkipped, 0)
        XCTAssertEqual(summary.errors.count, 1)
        XCTAssertTrue(summary.errors[0].contains("a.swift"))
        XCTAssertTrue(summary.errors[0].contains("Permission denied."))
        XCTAssertEqual(stub.files["a.swift"], "needle here")
        XCTAssertEqual(stub.files["b.swift"], "pin there")
    }

    func testReplaceAllStopsWhenTheProjectChangesMidBatch() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle",
            "b.swift": "needle"
        ])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let gate = Gate()
        stub.readGate = gate
        let task = Task { await model.replaceAll(template: "pin") }
        await waitUntil { gate.reached }

        model.prepareForSearch(root: URL(fileURLWithPath: "/other"))
        gate.release()
        let summary = await task.value

        // The file already in flight is written (nothing rolls it back) and is
        // *counted*, so the caller still refreshes for it; the batch then stops
        // with `abandoned` set rather than walking on into a project the user
        // left. A zeroed summary here would read as "nothing matched" for a batch
        // that had already rewritten a file.
        XCTAssertEqual(
            summary,
            ReplaceSummary(filesChanged: 1, matchesReplaced: 1, abandoned: true)
        )
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(stub.files["a.swift"], "pin")
        XCTAssertEqual(stub.files["b.swift"], "needle")
        XCTAssertEqual(stub.writtenPaths, ["a.swift"])
    }

    /// `abandoned` alone makes a summary non-empty, so the view reports "stopped
    /// early" rather than the flatly false "no file still matched".
    func testAbandonedSummaryIsNotReportedAsEmpty() {
        XCTAssertFalse(ReplaceSummary(abandoned: true).isEmpty)
        XCTAssertTrue(ReplaceSummary().isEmpty)
    }

    func testReplaceAllRejectsAPinnedGenerationSupersededBeforeItStarted() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // What the view captures synchronously, at the moment the Replace All is
        // confirmed and *before* it hops onto a `Task`.
        let origin = model.currentRootGeneration

        // The folder switches — and the new project is searched successfully — in
        // exactly that gap, so the deferred batch starts against a project the
        // user has already left.
        let other = URL(fileURLWithPath: "/other")
        model.prepareForSearch(root: other)
        stub.root = other
        stub.files = ["x.swift": "needle"]
        await model.search(root: other, query: SearchQuery(pattern: "needle"), mask: "")
        XCTAssertEqual(paths(model), ["x.swift"])

        let summary = await model.replaceAll(template: "pin", originGeneration: origin)

        // Nothing ran: the counts are zero but `abandoned` is set, so the view
        // says "the batch stopped because the folder changed" rather than the
        // flatly misleading "no file matched".
        XCTAssertEqual(summary, ReplaceSummary(abandoned: true))
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(stub.files["x.swift"], "needle")
        XCTAssertTrue(stub.writtenPaths.isEmpty)
    }

    func testReplaceAllWithAMatchingPinnedGenerationRuns() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle here"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(
            template: "pin",
            originGeneration: model.currentRootGeneration
        )

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "pin here")
    }

    func testReplaceAllWithoutAPinnedGenerationIsNeverRejected() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle here"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // Switch away and back, so the project token has moved on from anything a
        // caller might have captured. An *unpinned* call carries no claim about
        // which project it was issued for, so it is judged only by the results it
        // holds — the path every direct call (and every other test) takes.
        model.prepareForSearch(root: URL(fileURLWithPath: "/other"))
        model.prepareForSearch(root: root)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "pin here")
    }

    /// The pin is the **project** token, not the request token — the distinction
    /// the whole fix rests on. A new query for the same folder bumps the request
    /// generation, and a batch guarded by *that* would abandon itself the moment
    /// the user typed in the still-live query field, after files had already been
    /// rewritten. Here the folder never changes, so the batch must run.
    func testReplaceAllPinIsTheProjectTokenNotTheRequestToken() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle here"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // What the view captured when the batch was confirmed.
        let origin = model.currentRootGeneration
        let requestBefore = model.currentRequestGeneration

        // A second search of the *same* folder lands in the gap: it moves the
        // request token on while leaving the project token where it was.
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")
        XCTAssertNotEqual(model.currentRequestGeneration, requestBefore)
        XCTAssertEqual(model.currentRootGeneration, origin)

        let summary = await model.replaceAll(template: "pin", originGeneration: origin)

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "pin here")
    }

    /// `resultsQuery` must track the *latest* search, not merely be captured once:
    /// the rows on screen belong to the newest query, so a batch judged by an
    /// older one fails the staleness check for every file and reports
    /// "everything skipped" about a perfectly current list.
    func testReplaceAllUsesTheLatestSearchesQueryNotAnEarlierOne() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle one needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")
        await model.search(root: root, query: SearchQuery(pattern: "one"), mask: "")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "needle pin needle")
    }

    func testReplaceAllUsesTheQueryThatProducedTheResultsNotTheLiveOne() async {
        let stub = StubFiles(root: root, files: ["a.swift": "needle one needle"])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // `query` is a settable public `@Published`, so a caller *may* bind a live
        // field to it (this app's own window deliberately does not). The batch is
        // judged by the query that produced the rows regardless: matching the
        // captured ranges against a pattern nothing was searched with would skip
        // every file and report "nothing matched" for a list that is in fact
        // perfectly current.
        model.query = SearchQuery(pattern: "zzz")

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 2))
        XCTAssertEqual(stub.files["a.swift"], "pin one pin")
    }

    func testReplaceAllContinuesWhenANewQueryForTheSameProjectArrivesMidBatch() async {
        let stub = StubFiles(root: root, files: [
            "a.swift": "needle",
            "b.swift": "needle"
        ])
        let model = ProjectSearchModel(fileService: stub)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        let gate = Gate()
        stub.readGate = gate
        let task = Task { await model.replaceAll(template: "pin") }
        await waitUntil { gate.reached }

        // A new *query* for the same project bumps the search generation. Unlike a
        // folder switch, it must not abandon the batch: the snapshot is already in
        // hand and every file is re-verified before its write, so stopping would
        // leave files rewritten on disk while the caller was told nothing happened.
        let before = model.currentRequestGeneration
        let search = Task { await model.search(root: self.root, query: SearchQuery(pattern: "pin"), mask: "") }
        var spins = 0
        while model.currentRequestGeneration == before && spins < 2_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            spins += 1
        }
        XCTAssertNotEqual(model.currentRequestGeneration, before)

        gate.release()
        let summary = await task.value
        _ = await search.value

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 2, matchesReplaced: 2))
        XCTAssertEqual(stub.files["a.swift"], "pin")
        XCTAssertEqual(stub.files["b.swift"], "pin")
    }

    func testReplaceAllSkipsAnOpenBufferEditedWhileTheReplacementWasComputed() async {
        let stub = StubFiles(root: root, files: ["a.swift": "saved needle"])
        let dirty = root.appendingPathComponent("a.swift")
        let buffer = MutableBuffer(text: "unsaved needle")
        let applied = AppliedBuffers()
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { [dirty: buffer.read()] },
            applyBufferText: { url, text in
                applied.record(url: url, text: text)
                return true
            }
        )
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // The editor stays live while the batch runs: the buffer changes right
        // after `replaceAll` sampled it, i.e. while the replacement is being
        // computed off the main actor.
        buffer.editOnNextRead = "unsaved needle plus a fresh edit"

        let summary = await model.replaceAll(template: "pin")

        // The stale replacement is skipped and counted, never applied — applying
        // it would silently drop the edit the user just made.
        XCTAssertEqual(summary, ReplaceSummary(filesSkipped: 1))
        XCTAssertTrue(applied.entries.isEmpty)
        XCTAssertEqual(stub.files["a.swift"], "saved needle")
        XCTAssertTrue(stub.writtenPaths.isEmpty)
    }

    func testReplaceAllHandsTheResultToATabOpenedWhileTheWriteWasInFlight() async {
        let stub = StubFiles(root: root, files: ["a.swift": "disk needle"])
        let target = root.appendingPathComponent("a.swift")
        let tab = LateOpenedTab()
        let applied = AppliedBuffers()
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { tab.read().map { [target: $0] } ?? [:] },
            applyBufferText: { url, text in
                applied.record(url: url, text: text)
                return true
            }
        )
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // The buffer-vs-disk branch is chosen before the file's off-main hop, so a
        // tab opened *during* the read-modify-write reads the pre-replacement text
        // and is clean — nothing else would ever correct it, and a later save would
        // put the stale text back over the batch's result.
        tab.openOnNextRead = "disk needle"

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "disk pin")
        // Reconciled exactly where the buffer branch would have left it: changed in
        // the tab, for the user to save.
        XCTAssertEqual(applied.entries.map(\.url), [target])
        XCTAssertEqual(applied.entries.map(\.text), ["disk pin"])
    }

    func testReplaceAllLeavesATabThatOpenedAndMovedOnDuringTheWriteAlone() async {
        let stub = StubFiles(root: root, files: ["a.swift": "disk needle"])
        let target = root.appendingPathComponent("a.swift")
        let tab = LateOpenedTab()
        let applied = AppliedBuffers()
        let model = ProjectSearchModel(
            fileService: stub,
            openBuffers: { tab.read().map { [target: $0] } ?? [:] },
            applyBufferText: { url, text in
                applied.record(url: url, text: text)
                return true
            }
        )
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")

        // Opened *and* typed into inside the same window: the tab no longer holds
        // what was on disk, so handing it the replacement would drop that edit.
        tab.openOnNextRead = "disk needle plus a fresh edit"

        let summary = await model.replaceAll(template: "pin")

        XCTAssertEqual(summary, ReplaceSummary(filesChanged: 1, matchesReplaced: 1))
        XCTAssertEqual(stub.files["a.swift"], "disk pin")
        XCTAssertTrue(applied.entries.isEmpty)
    }

    func testReplacedTextAcceptsAMatchAddedAfterEveryCapturedOne() {
        // The cap can clip a file's match list mid-way, so a hit appearing *after*
        // every captured one cannot invalidate any of them: the leading matches
        // still sit where the results say, and only they are replaced.
        let outcome = ProjectSearchModel.replacedText(
            in: "needle and needle",
            captured: [SearchMatch(range: NSRange(location: 0, length: 6), lineNumber: 1)],
            query: SearchQuery(pattern: "needle"),
            template: "pin"
        )

        XCTAssertEqual(outcome?.text, "pin and needle")
        XCTAssertEqual(outcome?.count, 1)
    }

    func testReplacedTextRejectsAMatchAddedBeforeTheCapturedOnes() {
        // A hit inserted *before* the captured ones shifts every captured range,
        // so nothing in the list can be trusted and the whole file is skipped.
        let outcome = ProjectSearchModel.replacedText(
            in: "needle and needle",
            captured: [SearchMatch(range: NSRange(location: 11, length: 6), lineNumber: 1)],
            query: SearchQuery(pattern: "needle"),
            template: "pin"
        )

        XCTAssertNil(outcome)
    }

    // MARK: - Helpers

    /// An open editor tab that can change *between* two reads, so a test can model
    /// the user typing while a batch is suspended off the main actor: the read that
    /// follows `editOnNextRead` being set still returns the old text, and every read
    /// after it returns the new one.
    private final class MutableBuffer {
        private var text: String
        var editOnNextRead: String?

        init(text: String) {
            self.text = text
        }

        func read() -> String {
            let current = text
            if let next = editOnNextRead {
                text = next
                editOnNextRead = nil
            }
            return current
        }
    }

    /// A tab that *appears* between two reads, so a test can model the user opening
    /// a file while a batch is suspended off the main actor: the read that follows
    /// `openOnNextRead` being set still finds no tab, and every read after it finds
    /// one (the `MutableBuffer` shape, for presence rather than content).
    private final class LateOpenedTab {
        private var text: String?
        var openOnNextRead: String?

        func read() -> String? {
            let current = text
            if let next = openOnNextRead {
                text = next
                openOnNextRead = nil
            }
            return current
        }
    }

    /// Counts how often the open-buffer snapshot closure was asked for the tabs.
    private final class CallCounter {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    /// Records what the buffer-apply closure was handed, so a test can assert
    /// the edit reached the open tab rather than the disk.
    private final class AppliedBuffers {
        private(set) var entries: [(url: URL, text: String)] = []

        func record(url: URL, text: String) {
            entries.append((url: url, text: text))
        }
    }

    private func paths(_ model: ProjectSearchModel) -> [String] {
        model.results.map(\.relativePath)
    }

    /// Poll `condition` (set from another thread) without blocking the main
    /// actor, so a gated off-main call can be observed from an async test.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the gated call", file: file, line: line)
    }
}
