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
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
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
            6,
            "There are six gated worktree operations. If this changed, a write path was added or removed — "
                + "and the capture count below must move with it."
        )
        XCTAssertEqual(
            gates,
            6,
            "Every gated operation raises both halves of the writer bracket; the two counts must agree."
        )
        XCTAssertEqual(
            captures,
            suspends,
            "Each gated operation must await captureBeforeOperation as the first await inside its bracket. "
                + "An operation that rewrites the worktree without one destroys text no other copy of exists."
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

    func testTheProjectSweepRunsOnFolderOpen() throws {
        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "pruneProject", in: app),
            1,
            "Retention's whole-project sweep runs exactly once, from openFolder — which the launch-time session "
                + "restore also goes through, so a relaunch prunes as a user-driven open does."
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
