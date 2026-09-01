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
///    editor waits behind.
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
    /// The six `.text` filters are the six places the app treats `openFiles` as
    /// text: `openBuffers` (the index and Find in Files), `bufferTextsByCanonicalPath`
    /// (the rename pass), `textsBeforeBatch` and the Replace All resync loop that
    /// reads it, `openTabSnapshot` (the checkout snapshot) and `openBufferTexts`
    /// (Local History's buffer half). The two `.viewer` tests are the two places the
    /// app must recognize one: the ⌘S funnel's early success and `resyncViewerTab`.
    ///
    /// A count rather than a shape because the failure is silent either way: a
    /// seventh consumer that forgets the filter compiles, runs, and reports a
    /// database as an empty file to whichever subsystem it feeds.
    func testEveryTextShapedConsumerFiltersOnTheTabKind() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "kind == \\.text", in: app),
            6,
            "Six sites read openFiles as text and each must skip viewer tabs. If this number moved, a "
                + "text-shaped consumer was added or removed — say which, here, rather than adjusting the "
                + "number: an unfiltered one hands the empty string to a real path."
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

    func testTheResyncRuleForAViewerTabIsAskedByBothResyncLoops() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "resyncViewerTab\\(", in: app),
            3,
            "One declaration and two call sites: the post-checkout resync and the post-revert one. A database "
                + "can be tracked and therefore reverted, and the loop that misses this rule reads a viewer "
                + "tab as unchanged, asks reloadFromDisk, gets its by-construction false, and force-closes a "
                + "tab whose file is still on disk."
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
