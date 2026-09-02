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
/// 7. The compiler cannot see that the console composes no SQL. Part 2b's whole
///    premise is that the *reader's* text travels verbatim to the seam — the one
///    stated exception to "Core writes every byte of SQL" — and the way that
///    stays an exception rather than a second composer is that no console file
///    names `DatabaseQuery` and `DatabaseQuery` names no console member. A
///    console file that started appending `LIMIT` to the reader's text would
///    compile, run, and quietly rewrite the question that was asked.
/// 8. The compiler cannot see who owns the reader's text. `ContentView` swaps the
///    viewer surface out whole for a text tab and `DatabaseViewerHost` keys it on
///    the tab, so a console input holding its own `@State` compiles perfectly and
///    loses a half-written query to a glance at a source file — silently, and
///    leaving the pane's deliberate re-presentation of a pending confirmation
///    standing over an empty box.
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

    /// The text of one declaration's body: from its own line to whichever
    /// declaration at type scope comes next.
    ///
    /// Needed wherever the rule is about *where* a call happens rather than
    /// whether it appears at all — the whole-file answer to "does this name the
    /// gate?" is yes for every file that has one write in it.
    static func declarationBody(after declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration)?.upperBound else { return nil }
        let end = ["\n    public func ", "\n    private func ", "\n    public var ", "\n    private var "]
            .compactMap { code.range(of: $0, range: start..<code.endIndex)?.lowerBound }
            .min() ?? code.endIndex
        return String(code[start..<end])
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
    ///
    /// **Part 2b moves neither number**, which is the point of pinning them here:
    /// the console lives entirely inside a tab that already exists, and the two
    /// things it needed from the scene — the gate question and the write hook —
    /// were wired for the cell edit. A console that had required a tenth filter
    /// would have meant a new way for the app to read a viewer tab as text.
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
        //
        // Still one *here*, though the tab now has two writers: the console asks
        // the same question in `DatabaseConsoleModel.confirm()` and is pinned by
        // its own test below. Two places rather than one because the two writes
        // are asked at different moments — a cell edit is sent the instant it is
        // committed, while a console batch waits out however long the reader
        // spends reading a confirmation — so the answer that matters is read
        // separately in each. What must never grow is the count *within* either
        // file.
        XCTAssertEqual(
            try occurrences(of: "isWriteBlocked\\(\\)", in: model),
            1,
            "The gate is asked in exactly one place in this file. setCellToNull is updateCell with an entry of "
                + ".null, so a second ask would be a second answer to the same question."
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
    ///
    /// The console's half is the same rule at a subtler site. `run(_:)` cannot
    /// know whether it is a read until `classifyConsole(_:)` has answered, so the
    /// tempting shape is to ask the gate up front and refuse the whole run —
    /// which would mean a `SELECT` typed during a checkout answering a refusal
    /// instead of rows. Classification and the read it may lead to are reads;
    /// only `confirm()` is a write, and only `confirm()` asks.
    func testTheReadPathNamesNeitherTheGateNorTheHook() throws {
        let viewer = try code(ofFileNamed: "DatabaseViewerModel.swift", under: "Sources/PisakaCore")
        let console = try code(ofFileNamed: "DatabaseConsoleModel.swift", under: "Sources/PisakaCore")
        let readPaths: [(String, String, String)] = [
            ("DatabaseViewerModel", "public func load()", viewer),
            ("DatabaseViewerModel", "public func select(", viewer),
            ("DatabaseViewerModel", "public func goToPage(", viewer),
            ("DatabaseConsoleModel", "public func run(", console),
            ("DatabaseConsoleModel", "private func performRead(", console),
        ]
        for (file, entryPoint, code) in readPaths {
            guard let body = Self.declarationBody(after: entryPoint, in: code) else {
                XCTFail("\(file).\(entryPoint) must exist — it is one of the viewer's read entry points")
                continue
            }
            XCTAssertFalse(
                body.contains("isWriteBlocked") || body.contains("didWrite"),
                "\(file).\(entryPoint) is a read and must consult neither. The viewer goes on answering "
                    + "questions about a database while git rewrites the worktree; only a write waits for "
                    + "that to finish."
            )
        }
    }

    // MARK: - The console, the tab's second writer

    /// The `updateCell` rule, restated for the writer that arrived second.
    ///
    /// The console's shape makes the failure quieter than the cell edit's: the
    /// reader is asked a question and then has to read it, so the window between
    /// deciding to write and writing is as long as a person takes — which is
    /// exactly long enough for a checkout to start. Asking before the prompt
    /// would compile, read plausibly, and answer about a moment that has passed.
    func testTheConsoleAsksTheGateOnceAndBeforeAnythingIsSent() throws {
        let model = try code(ofFileNamed: "DatabaseConsoleModel.swift", under: "Sources/PisakaCore")
        guard let start = model.range(of: "public func confirm()")?.upperBound,
              let gate = model.range(of: "isWriteBlocked()", range: start..<model.endIndex)?.lowerBound,
              let send = model.range(of: "performConsoleWrite(", range: start..<model.endIndex)?.lowerBound
        else {
            XCTFail("confirm() must exist, ask isWriteBlocked() and then send the transaction")
            return
        }
        XCTAssertLessThan(
            gate,
            send,
            "The gate question comes before the write, and inside confirm() rather than before the prompt. A "
                + "batch that commits while a revert, a checkout or a merge apply is rewriting the worktree "
                + "writes into a file git is about to replace: it reports its affected-row count and then "
                + "disappears, with nothing anywhere saying so."
        )
        XCTAssertEqual(
            try occurrences(of: "isWriteBlocked\\(\\)", in: model),
            1,
            "Asked in exactly one place in this file too. run(_:) must not ask it: classification and the read "
                + "it may lead to are reads, and refusing a SELECT because somebody is committing would make "
                + "the console go dark for a reason that has nothing to do with the question typed into it."
        )
    }

    /// The reader's text is the console's one input and it travels verbatim; the
    /// row cap travels beside it as a number the app half enforces by stepping.
    /// Two call sites for the same text would be two chances for one of them to
    /// start "helping".
    func testTheReadersTextReachesTheSeamThroughOneCallSiteEach() throws {
        let model = try code(ofFileNamed: "DatabaseConsoleModel.swift", under: "Sources/PisakaCore")
        for member in ["classifyConsole", "runConsoleRead", "performConsoleWrite"] {
            XCTAssertEqual(
                try occurrences(of: "\\b\(member)\\(", in: model),
                1,
                "\(member) is called exactly once. Each of the three is a different promise about the "
                    + "reader's text — nothing runs, everything runs read-only, everything runs in one "
                    + "transaction — and a second call site is a second place that promise is made."
            )
        }
    }

    /// The console is the **one stated exception** to "Core writes every byte of
    /// SQL": the text is the reader's own and is never composed, quoted, wrapped
    /// or appended to. Both halves of that are pinned, because either one alone
    /// leaves the door open — a console file reaching for `DatabaseQuery` would
    /// start composing, and a `DatabaseQuery` member built for the console would
    /// make the exception into a second composer.
    func testTheConsoleComposesNoSQL() throws {
        for url in try databaseFiles() where url.lastPathComponent.hasPrefix("DatabaseConsole") {
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("DatabaseQuery", in: try code(of: url)),
                "\(url.lastPathComponent) must not name DatabaseQuery. The console runs the reader's text and "
                    + "nothing else: the cap is a number the app half steps to, not a LIMIT appended to a "
                    + "statement whose meaning the console cannot see."
            )
        }

        let query = try code(ofFileNamed: "DatabaseQuery.swift", under: "Sources/PisakaCore")
        for member in ["Console", "classifyConsole", "runConsoleRead", "performConsoleWrite"] {
            XCTAssertEqual(
                try occurrences(of: "\\b\(member)", in: query),
                0,
                "DatabaseQuery must name no console member (\(member)). It stays the composer for the grid's "
                    + "own statements alone; a console helper here would be the exception growing into the "
                    + "rule it is an exception to."
            )
        }
    }

    /// The three rules above this section apply to the console's files by virtue
    /// of their names — and a rule that applies by prefix is a rule that stops
    /// applying the moment somebody renames a file. So the membership is asserted
    /// rather than assumed: these are the files part 2b added, and each is
    /// covered by the macOS gating, the no-`localChanges` rule and the reader
    /// rule because it is in this set.
    func testTheConsolesFilesAreCoveredByTheFeatureWideRules() throws {
        let found = Set(try databaseFiles().map(\.lastPathComponent))
        for file in ["DatabaseConsolePlan.swift", "DatabaseConsoleModel.swift", "DatabaseConsoleView.swift"] {
            XCTAssertTrue(
                found.contains(file),
                "\(file) must be discovered by databaseFiles(). If it was renamed away from the Database "
                    + "prefix, three rules stopped applying to it silently — restore the prefix or add it to "
                    + "the set by hand."
            )
        }
    }

    /// The console needed nothing from the scene, which is why the tab-kind
    /// filter counts above did not move: it lives inside a tab that already
    /// exists, and the gate question and the write hook it uses are the ones
    /// `DatabaseViewerTabs` was already handed for the cell edit. A console type
    /// named in `PisakaApp.swift` would mean a second wiring path for the same
    /// two closures — and the later one would silently win.
    func testTheSceneKnowsNothingAboutTheConsole() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "DatabaseConsole", in: app),
            0,
            "The scene must not name the console. It reaches the tab through DatabaseViewerTabs, which "
                + "forwards the one gate question and the one write hook the scene already wires."
        )
    }

    // MARK: - Nothing is armed while a write is in flight

    /// The surface disables on the **tab-wide** flag, never on the grid's own
    /// half of it.
    ///
    /// `isWriteInFlight` is `isWriting || console.isWriting`; a site spelling
    /// `model.isWriting` instead would stay live for the whole of a console
    /// batch — a page turn landing mid-transaction, a sort re-query against a
    /// table the batch is dropping, an editor opened over rows it is rewriting —
    /// and every other gate in this suite would stay green, because the flag it
    /// asked still exists and still answers. So the three controls are pinned by
    /// the term they disable on, and the half-flag is pinned by absence.
    func testTheGridsControlsDisableOnTheTabWideWriteFlag() throws {
        let view = try code(ofFileNamed: "DatabaseViewerView.swift", under: "Sources/Pisaka")
        for pattern in [
            #"\.disabled\(!model\.page\.hasPrevious \|\| model\.isWriteInFlight\)"#,
            #"\.disabled\(!model\.page\.hasNext \|\| model\.isWriteInFlight\)"#,
            #"\.disabled\(model\.isWriteInFlight\)"#,
            #"isGridIdle: Bool \{ !model\.isWriteInFlight && !model\.isLoadingRows \}"#,
        ] {
            XCTAssertEqual(
                try occurrences(of: pattern, in: view),
                1,
                "DatabaseViewerView must keep the paging buttons, the sort headers and the cell editor "
                    + "disabled while either writer is in flight — the term is model.isWriteInFlight, and "
                    + "\(pattern) is the site that says so."
            )
        }
        XCTAssertEqual(
            try occurrences(of: #"model\.isWriting"#, in: view),
            0,
            "The surface must never ask the grid's half of the flag: isWriteInFlight is the one question "
                + "that covers the console's confirmed mutation too."
        )
    }

    /// Run is the console's half of the same rule, and it needs **both** terms:
    /// the console's own `isRunning` covers a classification, a read or a
    /// mutation of its own, while `isWriteInFlight` — handed down by the owner,
    /// never re-derived here — covers the grid's cell edit, which the console
    /// cannot see.
    func testRunIsDisabledWhileEitherWriterIsInFlight() throws {
        let console = try code(ofFileNamed: "DatabaseConsoleView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: #"isRunDisabled: Bool \{ console\.isRunning \|\| isWriteInFlight \}"#, in: console),
            1,
            "Run must be disabled by the console's own spinner and by the tab's write flag together."
        )
        XCTAssertEqual(
            try occurrences(of: #"\.disabled\(isRunDisabled\)"#, in: console),
            1,
            "…and the Run control must be the thing that reads it."
        )
    }

    /// The reader's text belongs to the console, not to the pane drawing it.
    ///
    /// `ContentView` swaps the viewer surface out whole for a text tab and
    /// `DatabaseViewerHost` keys it on the tab, so the pane is destroyed by any
    /// tab switch while the console behind it lives as long as the tab. An input
    /// owning its own text would therefore lose a half-written query to a glance
    /// at a source file, silently — and would leave the pane's deliberate
    /// re-presentation of a pending confirmation standing over an empty box.
    func testTheReadersTextIsHeldByTheConsoleAndNotByThePane() throws {
        let console = try code(ofFileNamed: "DatabaseConsoleView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: #"@State private var text"#, in: console),
            0,
            "The input must not own the reader's text: this view does not live as long as the typing does."
        )
        XCTAssertGreaterThan(
            try occurrences(of: #"console\.text"#, in: console),
            0,
            "…it reads and writes the console's own property instead."
        )
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
