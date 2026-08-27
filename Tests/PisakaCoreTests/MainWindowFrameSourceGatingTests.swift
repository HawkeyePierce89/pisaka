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

    func testExactlyOneAppFileNamesTheFrameAutosaveAPI() throws {
        var foundFiles: Set<String> = []
        var autosaveNameCount = 0
        var usingNameCount = 0

        let autosaveRegex = try NSRegularExpression(pattern: "\\bsetFrameAutosaveName\\b")
        let usingRegex = try NSRegularExpression(pattern: "\\bsetFrameUsingName\\b")

        for url in try appFiles() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
            let codeRange = NSRange(code.startIndex..., in: code)

            let autosaveMatches = autosaveRegex.numberOfMatches(in: code, range: codeRange)
            let usingMatches = usingRegex.numberOfMatches(in: code, range: codeRange)

            if autosaveMatches > 0 || usingMatches > 0 {
                foundFiles.insert(url.lastPathComponent)
                autosaveNameCount += autosaveMatches
                usingNameCount += usingMatches
            }
        }
        XCTAssertEqual(
            foundFiles,
            ["MainWindowFrameAutosave.swift"],
            "Exactly one file must name the frame autosave API to prevent accidental multiple adoptions or overwriting."
        )
        XCTAssertEqual(
            autosaveNameCount,
            3,
            "There must be exactly three calls to setFrameAutosaveName in the codebase (one to adopt, two to clear)."
        )
        XCTAssertEqual(usingNameCount, 1, "There must be exactly one call to setFrameUsingName in the codebase.")
    }

    func testRestoreComesBeforeAdopt() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/MainWindowFrameAutosave.swift")
        let lines = try significantLines(of: url)

        let restoreIndex = lines.firstIndex { LSPSourceGatingTests.containsToken("setFrameUsingName", in: $0) }
        let adoptIndex = lines.firstIndex {
            LSPSourceGatingTests.containsToken("setFrameAutosaveName", in: $0) &&
            LSPSourceGatingTests.containsToken("mainWindowFrameAutosaveName", in: $0)
        }

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
