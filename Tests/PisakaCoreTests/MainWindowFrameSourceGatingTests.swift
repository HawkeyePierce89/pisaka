import XCTest

/// Static verification of the main window's frame autosave rules.
///
/// A repository-file suite that reads `Sources/Pisaka/` through `#filePath` with
/// Foundation only and reuses `LSPSourceGatingTests`'s Swift scanner to strip
/// comments and string literals.
///
/// **Why the compiler cannot see this**:
/// 1. The compiler cannot enforce that `setFrameAutosaveName` is only called in exactly
///    one place. A duplicate call elsewhere would quietly steal the name or overwrite the saved frame.
/// 2. The compiler cannot enforce the call order `setFrameUsingName` BEFORE `setFrameAutosaveName`.
///    Calling them in reverse order compiles fine but overwrites the saved frame with the default one
///    on every launch.
/// 3. The compiler cannot ensure `MainWindowFrameAutosave.swift` is gated to macOS. Without `#if os(macOS)`,
///    it would break the iOS build.
/// 4. The compiler cannot guarantee that `PisakaApp.swift` actually attaches the marker to the scene.
/// 5. The compiler cannot enforce that the five auxiliary windows do *not* adopt a name and instead
///    continue to use `.center()`.
final class MainWindowFrameSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

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
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(try read(url))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testExactlyOneAppFileNamesTheFrameAutosaveAPI() throws {
        var foundFiles: Set<String> = []
        for url in try appFiles() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try read(url))
            if LSPSourceGatingTests.containsToken("setFrameAutosaveName", in: code) ||
               LSPSourceGatingTests.containsToken("setFrameUsingName", in: code) {
                foundFiles.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            foundFiles,
            ["MainWindowFrameAutosave.swift"],
            "Exactly one file must name the frame autosave API to prevent accidental multiple adoptions or overwriting."
        )
    }

    func testRestoreComesBeforeAdopt() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let lines = try significantLines(of: url)

        let restoreIndex = lines.firstIndex { LSPSourceGatingTests.containsToken("setFrameUsingName", in: $0) }
        let adoptIndex = lines.firstIndex { LSPSourceGatingTests.containsToken("setFrameAutosaveName", in: $0) }

        let restore = try XCTUnwrap(restoreIndex, "setFrameUsingName not found")
        let adopt = try XCTUnwrap(adoptIndex, "setFrameAutosaveName not found")

        XCTAssertLessThan(
            restore,
            adopt,
            "setFrameUsingName must be called strictly before setFrameAutosaveName to avoid overwriting the saved frame."
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
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try read(url))
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

        for name in auxiliaryWindows {
            // Some might be in subdirectories, let's find the exact path
            let url = try XCTUnwrap(
                (try appFiles()).first { $0.lastPathComponent == name },
                "Could not find \(name) in Sources/Pisaka/"
            )
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try read(url))
            XCTAssertTrue(
                LSPSourceGatingTests.containsToken("center", in: code),
                "\(name) must continue to call center() explicitly, as auxiliary windows do not use a saved frame."
            )
        }
    }
}
