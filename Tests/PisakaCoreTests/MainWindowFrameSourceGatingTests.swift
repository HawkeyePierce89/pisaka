import XCTest

/// Static verification of the main window's frame persistence rules.
///
/// A repository-file suite that reads `Sources/Pisaka/` through `#filePath` with
/// Foundation only and reuses `LSPSourceGatingTests`'s Swift scanner to strip
/// comments and string literals.
///
/// **Why the compiler cannot see this**:
/// 1. The compiler cannot enforce that the frame-persistence API (`setFrame(from:)` /
///    `frameDescriptor`) is named in exactly one file. A second persistence site elsewhere
///    would quietly compete over the saved frame.
/// 2. The compiler cannot enforce that the observers start only AFTER the final restore.
///    Observing first compiles fine but lets the scene's setup-time resize overwrite the
///    saved frame with the default one — the bug this file exists to fix, in a new disguise.
/// 3. The compiler cannot ensure `MainWindowFrameAutosave.swift` is gated to macOS. Without `#if os(macOS)`,
///    it would break the iOS build.
/// 4. The compiler cannot guarantee that `PisakaApp.swift` actually attaches the marker to the scene.
/// 5. The compiler cannot enforce that the five auxiliary windows do *not* persist a frame and instead
///    continue to use `.center()`.
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
            1,
            "There must be exactly one setFrame(from:) restore site in the codebase."
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
            lines.lastIndex(of: "restore(window)"),
            "restore(window) call not found"
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
}
