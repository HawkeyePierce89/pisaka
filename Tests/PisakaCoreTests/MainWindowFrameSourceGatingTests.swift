import XCTest

/// Static verification of the main window's frame persistence rules.
///
/// A repository-file suite that reads `Sources/Pisaka/` through `#filePath` with
/// Foundation only and reuses `LSPSourceGatingTests`'s Swift scanner to strip
/// comments and string literals.
///
/// **Why the compiler cannot see this**:
/// 1. The compiler cannot enforce that the frame-persistence API (`setFrame(from:)` /
///    `frameDescriptor`, and the first-launch `setFrame(_:display:)`) is named in exactly one
///    file. A second persistence site elsewhere would quietly compete over the saved frame.
/// 2. The compiler cannot enforce that the observers start only AFTER the final restore.
///    Observing first compiles fine but lets the scene's setup-time resize overwrite the
///    saved frame with the default one — the bug this file exists to fix, in a new disguise.
/// 3. The compiler cannot ensure `MainWindowFrameAutosave.swift` is gated to macOS. Without `#if os(macOS)`,
///    it would break the iOS build.
/// 4. The compiler cannot guarantee that `PisakaApp.swift` actually attaches the marker to the scene.
/// 5. The compiler cannot enforce that the five auxiliary windows do *not* persist a frame and instead
///    continue to use `.center()`.
/// 6. The compiler cannot enforce that Core's `MainWindowInitialFrameRule` is reached **only on the
///    missing-key path**: asked only past a guard that no saved descriptor exists, named in exactly
///    one app file, and applied by `restore` only in the `else` of the guard that reads the stored
///    descriptor — so the stored descriptor is tried first and always wins. Applying the rule
///    unconditionally compiles fine and resizes every returning user's window on every launch.
///    Both guards read one `savedDescriptor()`, which reads the key and refuses a value Core's
///    `isRestorable` rejects — so a malformed descriptor counts as missing on both paths alike,
///    rather than suppressing the fallback while `setFrame(from:)` silently does nothing.
///
/// Every rule reads comment- and literal-stripped text; none of them has a literal as its subject.
final class MainWindowFrameSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func appFiles() throws -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka")
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

    private func significantLines(of url: URL) throws -> [String] {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testExactlyOneAppFileNamesTheFramePersistenceAPI() throws {
        var foundFiles: Set<String> = []
        var setFrameCount = 0
        var descriptorCount = 0

        // Two sites, one each: the descriptor restore `setFrame(from:)` and the
        // first-launch `setFrame(_:display:)` — both in the one file.
        let setFrameRegex = try NSRegularExpression(pattern: "\\bsetFrame\\b")
        let descriptorRegex = try NSRegularExpression(pattern: "\\bframeDescriptor\\b")

        for url in try appFiles() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
            let codeRange = NSRange(code.startIndex..., in: code)

            let setFrameMatches = setFrameRegex.numberOfMatches(in: code, range: codeRange)
            let descriptorMatches = descriptorRegex.numberOfMatches(in: code, range: codeRange)

            if setFrameMatches > 0 || descriptorMatches > 0 {
                foundFiles.insert(url.lastPathComponent)
                setFrameCount += setFrameMatches
                descriptorCount += descriptorMatches
            }
        }
        XCTAssertEqual(
            foundFiles,
            ["MainWindowFrameAutosave.swift"],
            "Exactly one file must name the frame persistence API to prevent competing persistence sites."
        )
        XCTAssertEqual(
            setFrameCount,
            2,
            "There must be exactly two setFrame sites: the setFrame(from:) restore and the first-launch frame."
        )
        XCTAssertEqual(
            descriptorCount,
            1,
            "There must be exactly one frameDescriptor save site in the codebase."
        )
    }

    func testObserversStartOnlyAfterTheFinalRestore() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let lines = try significantLines(of: url)

        let lastRestoreCall = try XCTUnwrap(
            lines.lastIndex { $0.hasPrefix("restore(window") },
            "restore(window, …) call not found"
        )
        let firstObserveCall = try XCTUnwrap(
            lines.firstIndex(of: "observe(window)"),
            "observe(window) call not found"
        )

        XCTAssertLessThan(
            lastRestoreCall,
            firstObserveCall,
            "Every restore(window) call must precede observe(window): observing before the final "
                + "re-apply lets the scene's setup-time resize overwrite the saved frame with the default one."
        )
    }

    func testTheGlueIsMacOSGated() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let lines = try significantLines(of: url)
        XCTAssertEqual(
            lines.first,
            "#if os(macOS)",
            "MainWindowFrameAutosave.swift must open with #if os(macOS) to avoid breaking the iOS build."
        )
    }

    func testTheSceneInstallsTheMarker() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/PisakaApp.swift")
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("MainWindowFrameAutosave", in: code),
            "PisakaApp.swift must install the MainWindowFrameAutosave marker."
        )
    }

    func testAuxiliaryWindowsStillCenterThemselves() throws {
        let auxiliaryWindows = [
            "DiffWindowController.swift",
            "MergeWindowController.swift",
            "ProjectSearchWindowController.swift",
            "SourceViewerWindowController.swift",
            "LeetCodeBrowserWindowController.swift",
        ]

        let files = try appFiles()
        for name in auxiliaryWindows {
            // Some might be in subdirectories, let's find the exact path
            let url = try XCTUnwrap(
                files.first { $0.lastPathComponent == name },
                "Could not find \(name) in Sources/Pisaka/"
            )
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
            XCTAssertTrue(
                LSPSourceGatingTests.containsToken("center", in: code),
                "\(name) must continue to call center() explicitly, as auxiliary windows do not use a saved frame."
            )
        }
    }

    // MARK: - The first-launch frame is the missing-key path only

    /// The lines of the `static func <name>(` body in `MainWindowFrameAutosave.swift`,
    /// from its declaration up to the next `static func` or the end of the type.
    private func functionBody(named name: String) throws -> [String] {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let lines = try significantLines(of: url)
        let start = try XCTUnwrap(
            lines.firstIndex { $0.contains("static func \(name)(") },
            "\(name) not found in MainWindowFrameAutosave.swift — rename it and update this suite deliberately"
        )
        let end = lines[(start + 1)...].firstIndex { $0.contains("static func ") } ?? lines.endIndex
        return Array(lines[start..<end])
    }

    func testTheInitialFrameRuleIsNamedInExactlyOneAppFile() throws {
        var found: Set<String> = []
        for url in try appFiles() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
            if LSPSourceGatingTests.containsToken("MainWindowInitialFrameRule", in: code) {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(found, ["MainWindowFrameAutosave.swift"])
    }

    func testTheInitialFrameRuleIsAskedOnlyPastTheMissingKeyGuard() throws {
        let body = try functionBody(named: "firstLaunchFrame")
        let guardLine = try XCTUnwrap(
            body.firstIndex { $0 == "guard savedDescriptor() == nil else { return nil }" },
            "firstLaunchFrame must open by refusing when the saved key is present"
        )
        let ruleCall = try XCTUnwrap(
            body.firstIndex { $0.contains("MainWindowInitialFrameRule.frame(") },
            "firstLaunchFrame no longer asks MainWindowInitialFrameRule"
        )
        XCTAssertLessThan(guardLine, ruleCall, "the rule must be asked only after the missing-key guard")
        XCTAssertEqual(
            body.filter { $0.contains("MainWindowInitialFrameRule") }.count, 1,
            "the rule is asked at exactly one site"
        )
    }

    func testTheStoredDescriptorIsAppliedFirstAndAlwaysWins() throws {
        let body = try functionBody(named: "restore")
        let descriptorGuard = try XCTUnwrap(
            body.firstIndex { $0 == "guard let descriptor = savedDescriptor() else {" },
            "restore must open by reading the stored descriptor"
        )
        let initialApply = try XCTUnwrap(
            body.firstIndex { $0.contains("setFrame(initialFrame") },
            "restore no longer applies the first-launch frame"
        )
        let guardReturn = try XCTUnwrap(
            body[initialApply...].firstIndex(of: "return"),
            "the first-launch apply must sit inside the descriptor guard's else, ending in return"
        )
        let descriptorApply = try XCTUnwrap(
            body.firstIndex(of: "window.setFrame(from: descriptor)"),
            "restore no longer applies the stored descriptor"
        )
        XCTAssertLessThan(descriptorGuard, initialApply)
        XCTAssertLessThan(initialApply, guardReturn)
        XCTAssertLessThan(guardReturn, descriptorApply)
        // Nothing sits between the guard and the first-launch apply: the else
        // branch is that one statement, so the frame cannot be applied on the
        // saved-key path by a statement slipped in front of it.
        XCTAssertEqual(initialApply, descriptorGuard + 1)
    }

    func testTheSavedDescriptorIsReadOnceAndRefusedWhenCoreRejectsIt() throws {
        let body = try functionBody(named: "savedDescriptor")
        let read = try XCTUnwrap(
            body.firstIndex { $0 == "guard let descriptor = UserDefaults.standard.string(forKey: defaultsKey)," },
            "savedDescriptor must open by reading the saved key"
        )
        XCTAssertEqual(
            body[read + 1], "MainWindowInitialFrameRule.isRestorable(descriptor) else { return nil }",
            "the same guard must refuse a descriptor Core does not consider restorable"
        )
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let reads = try significantLines(of: url).filter { $0.contains("UserDefaults.standard.string(forKey:") }
        XCTAssertEqual(reads.count, 1, "the saved key is read only through savedDescriptor()")
    }

    func testBothRestoresApplyTheOneComputedAnswer() throws {
        let body = try functionBody(named: "adopt")
        let computed = body.filter { $0.contains("firstLaunchFrame(") }
        XCTAssertEqual(computed.count, 1, "the first-launch frame is computed once, at adoption")
        let restores = body.filter { $0.hasPrefix("restore(window") }
        XCTAssertEqual(
            restores, ["restore(window, initialFrame: initialFrame)", "restore(window, initialFrame: initialFrame)"],
            "both restore calls must apply the one precomputed answer"
        )
    }
}
