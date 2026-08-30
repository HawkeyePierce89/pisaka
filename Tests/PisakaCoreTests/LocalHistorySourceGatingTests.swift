import XCTest

/// Static verification of Local History's app-layer wiring rules.
///
/// A repository-file suite that reads `Sources/` through `#filePath` with
/// Foundation only and reuses `LSPSourceGatingTests`'s Swift scanner to strip
/// comments and string literals — load-bearing here, not tidy: every file this
/// suite reads *quotes its own rules in prose*, so a raw `contains` would stay
/// green on a comment describing a call site that has been deleted.
///
/// **Why the compiler cannot see any of this:**
///
/// 1. Local History is a safety net, and a safety net's failure mode is silence.
///    A write path wired without a capture compiles, runs, and loses exactly the
///    text it was added to protect — there is no crash, no wrong pixel and no
///    failing assertion anywhere, only a revision that is missing on the day
///    somebody looks. So the *count* of capture sites is pinned against the count
///    of write paths, and adding a seventh gated operation or a fourth save site
///    fails here until it captures too.
/// 2. The compiler cannot see that `AutosaveController` reports **every** branch
///    that writes. The quit branch silently skipped `onSaved` for the whole life
///    of that class, which was correct while the only listener was a UI refresh
///    and became a lost edit the moment Local History listened; nothing but a
///    count keeps the next branch honest.
/// 3. The compiler cannot enforce that Local History stays a **reader**. Naming
///    `autosave.suspend()` / `localChanges.beginRevert()` anywhere inside the
///    feature would compile perfectly and quietly turn a background snapshot into
///    a gate the editor waits behind.
/// 4. The compiler cannot ensure the app-side files are macOS-gated; without
///    `#if os(macOS)` they would break the iOS build, which has no window to
///    browse history in and no caller for the capture model.
final class LocalHistorySourceGatingTests: XCTestCase {

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
    /// Core/app boundary. Matching by name rather than by a hand-kept list is what
    /// makes the window and the view Task 7 adds fall under these rules the moment
    /// they exist, instead of when somebody remembers to add them.
    private func localHistoryFiles() throws -> [URL] {
        let core = try swiftFiles(under: "Sources/PisakaCore")
        let app = try swiftFiles(under: "Sources/Pisaka")
        return (core + app).filter { $0.lastPathComponent.hasPrefix("LocalHistory") }
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
        try offsets(of: pattern, in: code).count
    }

    /// Where each match starts, so a rule can be about *order* rather than about
    /// totals — the difference between "seven brackets and seven captures" and
    /// "seven brackets each of which captures".
    private func offsets(of pattern: String, in code: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
            .map { $0.range.location }
    }

    // MARK: - Platform gating

    func testEveryAppSideLocalHistoryFileIsMacOSGated() throws {
        let appFiles = try localHistoryFiles().filter {
            !$0.path.contains("/Sources/PisakaCore/")
        }
        XCTAssertFalse(
            appFiles.isEmpty,
            "The app half of Local History must exist; if it moved, this suite is looking in the wrong place."
        )
        for url in appFiles {
            let firstLine = try code(of: url)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            XCTAssertEqual(
                firstLine,
                "#if os(macOS)",
                "\(url.lastPathComponent) must open with #if os(macOS): Local History is macOS-only end to end, "
                    + "and an ungated file would break the iOS build."
            )
        }
    }

    func testTheSupportDirectoryIsTheOnlyPlaceTheStoreBaseIsSpelled() throws {
        var namingFiles: Set<String> = []
        for url in try swiftFiles(under: "Sources/Pisaka") {
            let code = try self.code(of: url)
            guard LSPSourceGatingTests.containsToken("LocalHistoryLayout", in: code),
                  LSPSourceGatingTests.containsToken("directoryName", in: code) else { continue }
            namingFiles.insert(url.lastPathComponent)
        }
        XCTAssertEqual(
            namingFiles,
            ["LocalHistorySupportDirectory.swift"],
            "Exactly one app file may build the Local History store base, so 'delete that directory to forget "
                + "every revision' has one spelling."
        )
    }

    // MARK: - The capture sites

    func testEveryGatedOperationCapturesBeforeItRuns() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")

        let suspends = try occurrences(of: "autosave\\.suspend\\(\\)", in: app)
        let gates = try occurrences(of: "localChanges\\.beginRevert\\(\\)", in: app)
        // `await captureBeforeOperation(` — the *call sites*. The app's own
        // one-line wrapper spells the model's method as
        // `await localHistory.captureBeforeOperation(`, so neither it nor its
        // declaration is counted here and the number stays "one per bracket".
        let captures = try occurrences(of: "await captureBeforeOperation\\(", in: app)

        XCTAssertEqual(
            suspends,
            7,
            "There are seven gated worktree operations. If this changed, a write path was added or removed — "
                + "and the capture count below must move with it."
        )
        XCTAssertEqual(
            gates,
            7,
            "Every gated operation raises both halves of the writer bracket; the two counts must agree."
        )
        XCTAssertEqual(
            captures,
            suspends,
            "Each gated operation must await captureBeforeOperation as the first await inside its bracket. "
                + "An operation that rewrites the worktree without one destroys text no other copy of exists."
        )

        // Totals alone would stay green on the one arrangement this rule exists
        // to refuse: two captures inside one bracket and none inside another. So
        // the two sets are checked to *alternate* — every `autosave.suspend()` is
        // followed by a capture before the next one begins.
        let bracketed = try (offsets(of: "autosave\\.suspend\\(\\)", in: app).map { (offset: $0, isCapture: false) }
            + offsets(of: "await captureBeforeOperation\\(", in: app).map { (offset: $0, isCapture: true) })
            .sorted { $0.offset < $1.offset }
            .map(\.isCapture)
        XCTAssertEqual(
            bracketed,
            Array(repeating: [false, true], count: suspends).flatMap { $0 },
            "The two must alternate, gate then capture: an operation holding two captures while another holds "
                + "none rewrites the worktree with nothing snapshotted, and the counts above cannot see it."
        )
    }

    func testTheSaveCaptureIsNamedAtExactlyTheThreeSaveSites() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "captureSaves\\b", in: app),
            3,
            "The three save sites are save(id:), saveAs(id:) and the AutosaveController onSaved binding. "
                + "A fourth write path that does not capture loses that save silently."
        )
        XCTAssertEqual(
            try occurrences(of: "captureSavesSynchronously", in: app),
            1,
            "The synchronous capture belongs to the quit path alone: it is the one place this feature does disk "
                + "work on the main thread, and it is deliberate because a Task hop at termination may never run."
        )
    }

    func testTheStoreSweepRunsOnFolderOpen() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "pruneStore", in: app),
            1,
            "Retention's sweep runs exactly once, from openFolder — which the launch-time session restore also "
                + "goes through, so a relaunch prunes as a user-driven open does."
        )
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("pruneProject", in: app),
            "The sweep takes no root: a sweep keyed to the project being opened never reclaims the history of a "
                + "project that is not opened again, which is both unbounded growth and the retention promise "
                + "broken."
        )
    }

    // MARK: - The autosave report

    func testEveryAutosaveWritePathReportsItsSaves() throws {
        let controller = try code(ofFileNamed: "AutosaveController.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "onSaved\\?\\(", in: controller),
            3,
            "The three write paths are performAutosave, the reporting branch of flushNow and the quit branch of "
                + "flushNow. The quit branch reported nothing until Local History needed it; a branch that writes "
                + "bytes and tells nobody is how a write path loses its safety net."
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("isTerminating", in: controller),
            "The report carries which path it came from, so the caller can skip the session-only follow-up work "
                + "without a second, forgettable hook."
        )
    }

    func testTheQuitBranchStillSkipsTheMissingFileProbe() throws {
        let controller = try code(ofFileNamed: "AutosaveController.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "missingDirtyPaths\\(in:", in: controller),
            2,
            "The probe stays at the two mid-session sites only. Running it at quit would cost one stat per dirty "
                + "buffer to answer a question — bump the tree — that has no meaning once the run loop is ending."
        )
    }

    // MARK: - Restore goes through the one rewrite funnel

    func testTheRestoreIsRoutedThroughTheSaveTransformController() throws {
        let controller = try code(ofFileNamed: "SaveTransformController.swift", under: "Sources/Pisaka")
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("applyRestore", in: controller),
            "The restore's entry point lives beside the save transform's, because both go through the same "
                + "through-the-view bracket; a restore that grew its own copy of that AppKit code is how the two "
                + "would drift."
        )

        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "applyRestore\\(", in: app),
            1,
            "There is exactly one restore call site. A second one would be a second answer to what a restore "
                + "does to the buffer, the undo stack and the dirty flag."
        )
    }

    func testNoLocalHistoryFileRewritesABufferItself() throws {
        for url in try localHistoryFiles() {
            let code = try self.code(of: url)
            for forbidden in ["beginSaveTransformRewrite", "replaceCharacters", "replaceText", "shouldChangeText"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(forbidden, in: code),
                    "\(url.lastPathComponent) must not rewrite a buffer itself (it names \(forbidden)): a restore "
                        + "goes through SaveTransformController.applyRestore, which is the one path that makes it "
                        + "a single undoable step with a single change notification."
                )
            }
        }
    }

    func testTheRestoreSnapshotsTheBufferItIsAboutToDisplace() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "captureBuffers\\(", in: app),
            1,
            "The restore is the one caller of the general buffer capture, and it must stay one: a restore that "
                + "replaced a buffer without snapshotting it first would be the single operation in this feature "
                + "that destroys text the feature itself cannot get back."
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("LocalHistoryRestore", in: app),
            "The restore travels as a plan value, so the app cannot hold the text it is about to write without "
                + "also holding the text it is about to displace."
        )
    }

    func testTheRestoreReAsksThePlansSamenessQuestionBeforeCapturing() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "displaced as NSString\\)\\.isEqual\\(to: plan\\.text\\)", in: app),
            1,
            "The published plan answers the sameness question against the text the window resolved, refreshed "
                + "when it becomes key — and a buffer can move without either happening. A plan gone stale that "
                + "way re-creates the armed button whose click does nothing, and adds a side effect to it: "
                + "applyRestore bails at its own guard, but the capture in front of it has already filed a "
                + ".restore revision of bytes nothing displaced. So the question is re-asked here, against the "
                + "buffer actually in hand, before the capture — and by bytes, like every other sameness test in "
                + "this feature."
        )
    }

    func testTheRestoreAsksItsRefusalsBeforeOpeningAnything() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        let asks = try offsets(of: "localHistoryRestoreRefused\\(displacing:", in: app)
        let opens = try offsets(of: "model\\.open\\(url: plan\\.fileURL\\)", in: app)
        XCTAssertEqual(
            asks.count,
            2,
            "Both refusals are one question asked at two moments: once against the text the restore can already "
                + "see it would displace, once against the buffer the open produced. Collapsing them back to one "
                + "is what re-introduces the side effect below."
        )
        XCTAssertEqual(opens.count, 1, "The restore opens the file it is restoring exactly once.")
        guard asks.count == 2, let open = opens.first else { return }
        XCTAssertLessThan(
            asks[0],
            open,
            "The question must be put before WorkspaceModel.open — which selects a tab, and adds one for a file "
                + "no tab holds. Asking only afterwards turns a click that does nothing into a click that pulls "
                + "the editor onto another file and beeps."
        )
        XCTAssertGreaterThan(
            asks[1],
            open,
            "It is re-asked after the open, because the open is what the capture and the replacement act on and "
                + "the file can move between the two reads; the pre-open ask exists to keep a refusal from "
                + "costing a tab, not to decide it."
        )

        let preflights = try offsets(of: "localHistoryTextToDisplace\\(", in: app)
        XCTAssertEqual(
            preflights.count,
            2,
            "The pre-open ask is fed by one seam — its declaration and its single call site. A file with no tab "
                + "has no buffer to judge, so without it the whole no-tab case reaches the open before it can be "
                + "refused, which is the side effect above wearing a narrower hat."
        )
        guard let preflight = preflights.min() else { return }
        XCTAssertLessThan(
            preflight,
            open,
            "The seam is asked before the open, not after it."
        )
    }

    func testThePreOpenAskReadsDiskWithoutTheWindowsCeiling() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        guard let start = app.range(of: "private func localHistoryTextToDisplace(")?.lowerBound,
              let end = app.range(
                  of: "private func localHistoryRestoreRefused(",
                  range: start..<app.endIndex
              )?.lowerBound
        else {
            XCTFail("localHistoryTextToDisplace must exist and sit beside the refusal it feeds")
            return
        }
        let body = String(app[start..<end])
        XCTAssertTrue(
            body.contains("fileService.read(url:"),
            "The no-tab half reads the file the plain way, exactly as WorkspaceModel.open is about to."
        )
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("readTextIfNotBinary", in: body),
            "It must not use the window's capped read: that ceiling is LocalHistoryPolicy.maxContentBytes to "
                + "the byte, so a capped preflight answers the empty string for exactly the file the policy is "
                + "about to refuse as tooLarge — waving through the one case it most needs to catch."
        )
    }

    func testTheRestoreRefusesWhatThePolicyWillNotCapture() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "policy\\.capture\\(", in: app),
            1,
            "The restore asks the very policy the store will apply whether the text it is about to displace can "
                + "be stored, and stops when it cannot. Without that question a file which had history when it "
                + "was small and has since grown past maxContentBytes is replaced with nothing captured — the "
                + "one place this feature destroys exactly what it exists to keep."
        )
    }

    // MARK: - The window

    func testBothOpenSitesExist() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "showLocalHistory\\(for:", in: app),
            2,
            "The two open sites are the File menu item and the project tree's row callback, and both must reach "
                + "the same handler: there is one window and one browser model behind it, so a second open path "
                + "is a second way to leave the two disagreeing about which file is shown."
        )
        let tree = try code(ofFileNamed: "ProjectTreeView.swift", under: "Sources/Pisaka")
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("onShowLocalHistory", in: tree),
            "The project tree's file rows offer Local History; the callback is threaded from ContentView like "
                + "every other row action."
        )
        let content = try code(ofFileNamed: "ContentView.swift", under: "Sources/Pisaka")
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("onShowLocalHistory", in: content),
            "ContentView threads the tree's callbacks; a row action it does not carry cannot reach the app."
        )
    }

    func testTheWindowDeclaresNoZoomSurfaceOfItsOwn() throws {
        for url in try localHistoryFiles() {
            let code = try self.code(of: url)
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("ZoomSurfaceMarker", in: code)
                    || LSPSourceGatingTests.containsToken("ZoomSurface", in: code),
                "\(url.lastPathComponent) must declare no zoom surface: the only thing in this window drawn at "
                    + "the code font is the DiffView it hosts, which declares its own — and the revisions list "
                    + "around it is chrome, so it belongs to the interface zone."
            )
        }
    }

    func testTheHistoryWindowIsClosedAtTermination() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("localHistoryWindows", in: app)
                && app.contains("localHistoryWindows.closeAll()"),
            "The window is torn down on willTerminateNotification beside the diff/merge/search/browser ones; "
                + "a retained window that outlives termination is the one failure mode that shape has."
        )
    }

    // MARK: - Local History is a reader

    func testLocalHistoryNeverTakesTheWriterGate() throws {
        for url in try localHistoryFiles() {
            let code = try self.code(of: url)
            XCTAssertFalse(
                code.contains("autosave.suspend") || LSPSourceGatingTests.containsToken("beginRevert", in: code),
                "\(url.lastPathComponent) must not raise the writer gate: Local History reads the user's files "
                    + "and writes only its own store, so it is neither a gated writer nor a gate of its own — "
                    + "the symbol index's rule, for the symbol index's reason."
            )
        }
    }
}
