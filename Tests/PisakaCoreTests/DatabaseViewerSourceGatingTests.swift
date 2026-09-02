import XCTest

/// Static verification of the database viewer's cross-layer wiring rules.
///
/// A repository-file suite in the `LocalHistorySourceGatingTests` shape: it reads
/// `Sources/` through `#filePath` with Foundation only and strips comments and
/// string literals with `LSPSourceGatingTests`'s Swift scanner before matching.
/// Load-bearing, not tidy — every file this suite reads states its own rules in
/// prose, and several of them quote the very tokens matched below, so a raw
/// `contains` would stay green on a comment describing a call site that has been
/// deleted.
///
/// **Why the compiler cannot see any of this:**
///
/// 1. A viewer tab is a perfectly ordinary `OpenFile` to the type system. Every
///    text-shaped consumer in `PisakaApp` compiles unchanged against one and then
///    *lies*: `openBuffers` offers the empty string for a real path, so the symbol
///    index and Find in Files report the database as an empty file; the rename
///    pass and Replace All vouch for bytes nobody read; the checkout resync reads
///    a `reloadFromDisk` that answers `false` by construction as a failed read and
///    force-closes a tab whose file is sitting right there. Nothing crashes and no
///    assertion elsewhere fires, so the *count* of tab-kind filters is pinned
///    against the sites that need them, and a new text-shaped consumer fails here
///    until it skips viewer tabs too.
/// 2. The compiler cannot enforce decision 3 — that the tab kind is off unless the
///    macOS app turns it on. `viewerTabsEnabled` defaults to `false` precisely so
///    the four iOS open sites keep today's honest read failure instead of showing
///    a database as an empty text file, and a single extra argument at the iOS
///    `WorkspaceModel(…)` would compile and silently undo that.
/// 3. The compiler cannot keep SQLite out of Core. `PisakaCore` must stay
///    Foundation-only and portable; an `import SQLite3` under `Sources/PisakaCore/`
///    builds fine on both destinations and is exactly the dependency the seam
///    exists to prevent.
/// 4. The compiler cannot ensure the app-side files are macOS-gated; without
///    `#if os(macOS)` they would break the iOS build, which has no viewer surface.
/// 5. The compiler cannot enforce that the viewer stays a **reader**. Naming
///    `autosave.suspend()` / `localChanges.beginRevert()` anywhere inside the
///    feature would compile perfectly and turn a background query into a gate the
///    editor waits behind. Part 2a makes the distinction finer rather than
///    weaker: the viewer now *consults* that gate before it writes a cell, which
///    is the opposite direction, and the way it stays a reader is that the
///    question arrives as an injected closure — no file under the viewer names
///    `localChanges` at all, and the scene is the one place the closure is tied
///    to the flag.
/// 6. The compiler cannot see that the write entry points ask the question. Both
///    `updateCell` and `setCellToNull` compile perfectly without ever calling
///    `isWriteBlocked`, and a cell edit landing in a database git is rewriting is
///    a silent failure by construction — the write succeeds, and the file it
///    wrote into is replaced a moment later.
final class DatabaseViewerSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    // MARK: - Reading

    private func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    /// The text of a call's argument list, from just past its opening paren to
    /// just before the paren that closes it.
    ///
    /// Counted rather than found: the first `)` after the call is whichever
    /// nested call happens to close first, so a scan for it makes the assertion
    /// depend on the *order* the two arguments are written in — a harmless
    /// re-ordering would truncate the extract and fail a rule it never touched.
    static func balancedArgumentList(in code: String, from start: String.Index) -> String? {
        var depth = 1
        var index = start
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[start..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// Every file whose name says it belongs to the feature, on both sides of the
    /// Core/app boundary. Matched by name rather than by a hand-kept list so a file
    /// added later falls under these rules the moment it exists.
    private func databaseFiles() throws -> [URL] {
        let core = try swiftFiles(under: "Sources/PisakaCore")
        let app = try swiftFiles(under: "Sources/Pisaka")
        return (core + app).filter { $0.lastPathComponent.hasPrefix("Database") }
    }

    private func code(of url: URL) throws -> String {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try String(contentsOf: url, encoding: .utf8)
        )
    }

    private func code(ofFileNamed name: String, under relativeDirectory: String) throws -> String {
        try code(of: Self.repositoryRoot.appendingPathComponent(relativeDirectory + "/" + name))
    }

    private func occurrences(of pattern: String, in code: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    // MARK: - The connection's flags

    /// The whole feature rests on the tab's own connection being read-only for
    /// its life — that is why a viewer tab holds no unflushed state and why
    /// termination's best-effort `closeAll()` is correct. Changing that one flag
    /// compiles and passes every other test, while a tab nobody edited starts
    /// taking write locks and checkpointing a WAL database.
    func testTheTabsConnectionIsOpenedReadOnlyAndTheWriteConnectionReadWrite() throws {
        let service = try code(ofFileNamed: "DatabaseConnectionService.swift", under: "Sources/Pisaka/Platform")

        XCTAssertEqual(
            try occurrences(of: "SQLITE_OPEN_READONLY", in: service),
            1,
            "Exactly one open is read-only: the tab's own, held for the life of the tab."
        )
        XCTAssertEqual(
            try occurrences(of: "SQLITE_OPEN_READWRITE", in: service),
            1,
            "And exactly one is read-write: the short-lived connection one committed edit runs on."
        )
        XCTAssertEqual(
            try occurrences(of: "SQLITE_OPEN_CREATE", in: service),
            0,
            "Neither open may create a file. A viewer tab opens a database the workspace already probed "
                + "into existence; a path that no longer names one must fail rather than answer an empty "
                + "database nobody asked for."
        )
    }

    /// And nothing else in the app opens one at all.
    func testNoOtherFileOpensASQLiteConnection() throws {
        for url in try swiftFiles(under: "Sources") {
            guard url.lastPathComponent != "DatabaseConnectionService.swift" else { continue }
            XCTAssertEqual(
                try occurrences(of: "sqlite3_open", in: try code(of: url)),
                0,
                "\(url.lastPathComponent) must not open a database of its own."
            )
        }
    }

    // MARK: - The SQLite import

    func testTheSystemSQLiteModuleIsImportedInExactlyOneFile() throws {
        var importing: Set<String> = []
        for url in try swiftFiles(under: "Sources") {
            let code = try self.code(of: url)
            guard try occurrences(of: "(?m)^\\s*import SQLite3\\b", in: code) > 0 else { continue }
            importing.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            importing,
            ["DatabaseConnectionService.swift"],
            "The C API lives behind the seam in exactly one file. A second importer is a second answer to what "
                + "a statement, a bind and a step mean — and the first step towards SQL being composed outside "
                + "Core, which is the whole reason DatabaseServicing exists."
        )
    }

    func testCoreNeverImportsSQLite() throws {
        for url in try swiftFiles(under: "Sources/PisakaCore") {
            let code = try self.code(of: url)
            XCTAssertEqual(
                try occurrences(of: "(?m)^\\s*import SQLite3\\b", in: code),
                0,
                "\(url.lastPathComponent) must not import SQLite3: PisakaCore is Foundation-only so the domain "
                    + "logic stays portable and `swift test` stays dependency-free."
            )
        }
    }

    // MARK: - Platform gating

    func testEveryAppSideDatabaseFileIsMacOSGated() throws {
        let appFiles = try databaseFiles().filter { !$0.path.contains("/Sources/PisakaCore/") }
        XCTAssertFalse(
            appFiles.isEmpty,
            "The app half of the viewer must exist; if it moved, this suite is looking in the wrong place."
        )
        for url in appFiles {
            let firstLine = try code(of: url)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            XCTAssertEqual(
                firstLine,
                "#if os(macOS)",
                "\(url.lastPathComponent) must open with #if os(macOS): the viewer is macOS-only in part 1, and "
                    + "an ungated file would break the iOS build (which links no SQLite surface at all)."
            )
        }
    }

    // MARK: - Decision 3: the switch is the macOS app's alone

    func testOnlyTheMacOSAppTurnsViewerTabsOn() throws {
        var naming: Set<String> = []
        for url in try swiftFiles(under: "Sources/Pisaka") {
            let code = try self.code(of: url)
            guard LSPSourceGatingTests.containsToken("viewerTabsEnabled", in: code) else { continue }
            naming.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            naming,
            ["PisakaApp.swift"],
            "Exactly one app file may turn the tab kind on. The routing lives in Core's open(url:), which iOS "
                + "reaches through the same four call sites — and iOS has no viewer surface, so a viewer tab "
                + "there would render a database as an empty text file. Off by default is what keeps iOS "
                + "failing honestly at the read instead."
        )
    }

    func testTheIOSAppConstructsItsWorkspaceWithoutTheSwitch() throws {
        let ios = try code(ofFileNamed: "PisakaApp_iOS.swift", under: "Sources/Pisaka/iOS")
        XCTAssertEqual(
            try occurrences(of: "WorkspaceModel\\(", in: ios),
            1,
            "The iOS app builds exactly one workspace; a second construction site is a second place decision 3 "
                + "could be undone."
        )
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("viewerTabsEnabled", in: ios),
            "The iOS workspace must take the default. Passing the switch here would compile and would show a "
                + "database as an empty, editable, saveable text file."
        )
    }

    // MARK: - The text-shaped consumers

    /// The count of tab-kind filters in `PisakaApp.swift`, pinned against the sites
    /// that need them.
    ///
    /// The seven `.text` filters are the seven places the app treats `openFiles` as
    /// text: `openBuffers` (the index and Find in Files), `bufferTextsByCanonicalPath`
    /// (the rename pass), `textsBeforeBatch` and the Replace All resync loop that
    /// reads it, `openTabSnapshot` (the checkout snapshot), `openBufferTexts`
    /// (Local History's buffer half) and `syncOpenBuffersForDiagnostics` (the
    /// push channel's whole-set flush, which hands `file.text` to the document
    /// sync). The two `.viewer` tests are the two places the app must recognize
    /// one: the ⌘S funnel's early success and `resyncViewerTab`.
    ///
    /// The eighth and ninth are the two *commands* that act on the selected tab
    /// as text: `isFindableTabSelected` and `localHistoryTargetURL`.
    ///
    /// A count rather than a shape because the failure is silent either way: a
    /// seventh consumer that forgets the filter compiles, runs, and reports a
    /// database as an empty file to whichever subsystem it feeds.
    func testEveryTextShapedConsumerFiltersOnTheTabKind() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "kind == \\.text", in: app),
            9,
            "Nine sites read openFiles as text and each must skip viewer tabs. If this number moved, a "
                + "text-shaped consumer was added or removed — say which, here, rather than adjusting the "
                + "number: an unfiltered one hands the empty string to a real path. The eighth is "
                + "isFindableTabSelected: the find bar renders inside the text editor zone alone, so the "
                + "four in-editor find commands grey out on a viewer tab rather than arming a bar the next "
                + "text tab would come up already showing. The ninth is localHistoryTargetURL: a Restore on "
                + "a viewer tab would file a revision claiming the database held the empty string and then "
                + "restore nothing."
        )
        XCTAssertEqual(
            try occurrences(of: "kind == \\.viewer|kind != \\.viewer", in: app),
            2,
            "Two sites answer *for* a viewer tab: save(id:) returns success without writing, and "
                + "resyncViewerTab settles both post-operation resyncs. A third would be a second opinion on "
                + "what a viewer tab is."
        )
    }

    func testTheSaveFunnelReturnsBeforeItsWriterGateAndTransform() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        guard let start = app.range(of: "private func save(id: UUID, abandoningBuffer")?.upperBound,
              let gate = app.range(of: "revertInFlight()", range: start..<app.endIndex)?.lowerBound,
              let viewer = app.range(of: "kind != .viewer", range: start..<app.endIndex)?.lowerBound
        else {
            XCTFail("save(id:) must exist, refuse while the writer gate is up, and return early for a viewer tab")
            return
        }
        XCTAssertLessThan(
            viewer,
            gate,
            "The viewer early return comes first. A save that writes nothing cannot race git, and reporting "
                + "failure instead would beep at the close prompt and fail the run/test pre-run save — while "
                + "falling through to prepareForSave would ask the transform about a buffer that does not exist "
                + "and the recreate probe would put an empty file where a deleted database was."
        )
    }

    func testTheResyncRuleForAViewerTabIsAskedByEveryResyncSite() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "resyncViewerTab\\(", in: app),
            4,
            "One declaration and three call sites: the post-checkout resync, the post-revert one and the "
                + "merge apply. A database can be tracked, and therefore reverted and conflicted, and a site "
                + "that misses this rule reads a viewer tab as unchanged, asks reloadFromDisk, gets its "
                + "by-construction false, and force-closes a tab whose file is still on disk."
        )
    }

    /// The merge apply is the site the rule reached last, and the only one whose
    /// snapshot is a single tuple rather than a loop's dictionary — which is
    /// exactly why it read as clean-and-unchanged for a tab holding no text at all.
    func testTheMergeApplyAsksTheViewerRuleBeforeItsTextSnapshotGuard() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        guard let start = app.range(of: "private func applyMerge(")?.upperBound,
              let viewer = app.range(of: "resyncViewerTab(", range: start..<app.endIndex)?.lowerBound,
              let guardSite = app.range(of: "guard let before = preApply", range: start..<app.endIndex)?
                  .lowerBound
        else {
            XCTFail("applyMerge must exist, ask the viewer rule, and then read its preApply snapshot")
            return
        }
        XCTAssertLessThan(
            viewer,
            guardSite,
            "The viewer rule comes first. preApply records a viewer tab's empty text and false dirtiness, "
                + "which the guard reads as clean and provably unchanged, so a database tab resolved through "
                + "the merge editor would be force-closed over a file still on disk."
        )
    }

    // MARK: - Never dirty is the reason, not a second filter

    func testAutosaveAndTheSaveTransformAreGatedOnDirtinessAlone() throws {
        let autosave = try code(ofFileNamed: "AutosaveController.swift", under: "Sources/Pisaka")
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("kind", in: autosave),
            "Autosave must not learn about tab kinds. Every scan it makes is gated on isDirty, which a viewer "
                + "tab answers false to by construction — the invariant is the reason, and a second filter "
                + "here would be a second thing to keep true."
        )
        XCTAssertEqual(
            try occurrences(of: "\\$0\\.isDirty && \\$0\\.url != nil", in: autosave),
            2,
            "The two dirty-and-titled scans (the ids about to be written, and the failed-write probe) are what "
                + "make the invariant load-bearing; a scan that dropped isDirty would start writing viewer tabs."
        )

        let transform = try code(ofFileNamed: "SaveTransformController.swift", under: "Sources/Pisaka")
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("kind", in: transform),
            "The on-save transform is only ever handed ids that a dirty scan or the ⌘S funnel produced, and "
                + "the funnel now returns before it for a viewer tab; it needs no tab-kind knowledge of its own."
        )
    }

    func testLocalHistoryNeverSeesAViewerTabsBuffer() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        guard let start = app.range(of: "private func openBufferTexts()")?.upperBound,
              let end = app.range(of: "return texts", range: start..<app.endIndex)?.lowerBound
        else {
            XCTFail("openBufferTexts() must exist — it is Local History's buffer half")
            return
        }
        XCTAssertTrue(
            app[start..<end].contains("kind == .text"),
            "The always-added half of every pre-operation capture must skip viewer tabs, or a revert or a "
                + "checkout files a revision holding the empty string under a database's path — a snapshot "
                + "that claims to be the file and is not, which is worse than no snapshot at all."
        )
        XCTAssertEqual(
            try occurrences(of: "captureSaves\\b", in: app),
            3,
            "The save capture stays at the three save sites and needs no viewer filter: it is reached only "
                + "from paths already gated on isDirty or on the ⌘S funnel's early return."
        )

        guard let target = app.range(of: "private var localHistoryTargetURL: URL?")?.upperBound,
              let targetEnd = app.range(of: "\n    }", range: target..<app.endIndex)?.lowerBound
        else {
            XCTFail("localHistoryTargetURL must exist — it is what File ▸ Local History… acts on")
            return
        }
        XCTAssertTrue(
            app[target..<targetEnd].contains("kind == .text"),
            "The menu target must be a text tab. A viewer tab answers the empty string to text(for:), so a "
                + "Restore reaching it captures a revision claiming the database held the empty string and "
                + "then restores nothing — the buffer half's skip, undone by the one command that opens a buffer of its own."
        )
    }

    // MARK: - The viewer consults the gate it never raises

    func testTheWriteEntryPointsConsultTheGateBeforeSendingAnything() throws {
        let model = try code(ofFileNamed: "DatabaseViewerModel.swift", under: "Sources/PisakaCore")
        guard let start = model.range(of: "public func updateCell(")?.upperBound,
              let gate = model.range(of: "isWriteBlocked()", range: start..<model.endIndex)?.lowerBound,
              let send = model.range(of: "performWrite(", range: start..<model.endIndex)?.lowerBound
        else {
            XCTFail("updateCell must exist, ask isWriteBlocked() and then send the transaction")
            return
        }
        XCTAssertLessThan(
            gate,
            send,
            "The gate question comes before the write. A cell edit that lands while a revert, a checkout or a "
                + "commit is rewriting the worktree writes into a file git is about to replace: the edit "
                + "reports success and then disappears, with nothing anywhere saying so."
        )

        // The one other entry point routes through the first rather than
        // repeating the refusal — a second copy is a second thing to keep true.
        XCTAssertEqual(
            try occurrences(of: "isWriteBlocked\\(\\)", in: model),
            1,
            "The gate is asked in exactly one place. setCellToNull is updateCell with an entry of .null, so a "
                + "second ask would be a second answer to the same question."
        )
    }

    func testNoViewerFileNamesTheGateItself() throws {
        for url in try databaseFiles() {
            let code = try self.code(of: url)
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("localChanges", in: code),
                "\(url.lastPathComponent) must not name the gate's own model. The viewer is handed the "
                    + "question as a closure precisely so the feature holds no opinion about who is writing "
                    + "the worktree or how that is discovered — and so Core, which cannot see LocalChangesModel "
                    + "at all, asks the same question the app does."
            )
        }
    }

    func testTheSceneWiresTheGateQuestionAndTheWriteHook() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        guard let start = app.range(of: "databaseViewers.start(")?.upperBound,
              let wiring = Self.balancedArgumentList(in: app, from: start)
        else {
            XCTFail("the scene must wire the viewer's gate question and write hook exactly once")
            return
        }
        XCTAssertTrue(
            wiring.contains("localChanges.isReverting"),
            "The gate question must be the same flag ⌘S and the tree file operations refuse on. Wiring it to "
                + "anything else would give the viewer a second, quieter opinion about when the worktree is "
                + "being rewritten."
        )
        XCTAssertTrue(
            wiring.contains("refreshLocalChanges()"),
            "A committed edit modifies a tracked file, so it owes the panel the same generation-pinned refresh "
                + "a save gives it — reusing that function rather than composing a second refresh is what keeps "
                + "the pinning in one place."
        )
        XCTAssertEqual(
            try occurrences(of: "databaseViewers\\.start\\(", in: app),
            1,
            "Wired once, in the scene's start-once block. A second site is a second pair of answers, and the "
                + "later one silently wins."
        )
    }

    /// The read path must stay innocent of both: a listing, a page load and a
    /// sort are reads, and a read that consulted the writer gate would go blank
    /// (or refuse) every time somebody committed.
    func testTheReadPathNamesNeitherTheGateNorTheHook() throws {
        let model = try code(ofFileNamed: "DatabaseViewerModel.swift", under: "Sources/PisakaCore")
        for entryPoint in ["public func load()", "public func select(", "public func goToPage("] {
            guard let start = model.range(of: entryPoint)?.upperBound else {
                XCTFail("\(entryPoint) must exist — it is one of the viewer's read entry points")
                continue
            }
            // To the next declaration at type scope, which is where this one ends.
            let end = model.range(of: "\n    public func ", range: start..<model.endIndex)?.lowerBound
                ?? model.endIndex
            let body = String(model[start..<end])
            XCTAssertFalse(
                body.contains("isWriteBlocked") || body.contains("didWrite"),
                "\(entryPoint) is a read and must consult neither. The viewer goes on answering questions "
                    + "about a database while git rewrites the worktree; only a write waits for that to finish."
            )
        }
    }

    // MARK: - The viewer is a reader

    func testNoDatabaseFileTakesTheWriterGate() throws {
        for url in try databaseFiles() {
            let code = try self.code(of: url)
            XCTAssertFalse(
                code.contains("autosave.suspend") || LSPSourceGatingTests.containsToken("beginRevert", in: code),
                "\(url.lastPathComponent) must not raise the writer gate: the viewer reads a file the worktree "
                    + "writers never touch as text, so it is neither a gated writer nor a gate of its own — "
                    + "the symbol index's and the terminal's rule, for their reason."
            )
        }
    }
}
