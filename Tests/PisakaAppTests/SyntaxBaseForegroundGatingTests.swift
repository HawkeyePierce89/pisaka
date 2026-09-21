#if os(macOS)
import Foundation
import XCTest

/// Every view that attaches the syntax highlighter also states its own base
/// foreground.
///
/// Neon paints only what a capture covers. Everything else — a file with no
/// grammar at all, the whitespace between tokens, a node the query does not name
/// — keeps whatever colour the text view was left on, and a text view left alone
/// is on the platform's label colour. That colour follows the *system*
/// appearance and ignores the app's Theme preference, so a pane that never sets
/// one paints uncovered text a different colour than the editor beside it does,
/// while every highlighted character in both agrees.
///
/// Nothing in the compiler can see the omission: the defect is the *absence* of
/// an assignment, which is why this suite searches for the highlighter
/// attachment — the thing that is present — and asserts the assignment beside
/// it, rather than searching for `textColor`. Both sets are pinned by **set
/// equality**, so a seventh pane added later is a red test rather than a silent
/// disagreement nobody notices until two windows are open side by side.
///
/// It reads the repository through `#filePath` with Foundation alone, over
/// comment- and literal-stripped text: these files quote their own assignment in
/// the comment above it, so a raw `contains` would stay green when the line it
/// names is deleted.
final class SyntaxBaseForegroundGatingTests: XCTestCase {

    /// The views that attach a `TextViewHighlighter` over `SyntaxTheme`.
    private static let attachingFiles: Set<String> = [
        "CodeEditorView.swift",             // the macOS editor
        "DiffView.swift",                   // the macOS side-by-side diff panes
        "SourceViewerContent.swift",        // the macOS out-of-project viewer
        "CodeEditorCoordinator_iOS.swift",  // the iOS editor
        "DiffView_iOS.swift",               // the iOS diff panes
        "MergeView_iOS.swift",              // the iOS three-pane merge editor
    ]

    /// The files that read the base foreground out of the one table.
    ///
    /// The same six views, with one file substituted: the iOS editor attaches its
    /// highlighter from its coordinator and configures its text view in the
    /// representable, so the two halves of that one view live in two files. It is
    /// the only pair that splits, and it is named here rather than allowed by a
    /// weaker rule.
    private static let basingFiles: Set<String> = [
        "CodeEditorView.swift",
        "DiffView.swift",
        "SourceViewerContent.swift",
        "CodeEditorView_iOS.swift",
        "DiffView_iOS.swift",
        "MergeView_iOS.swift",
    ]

    func testEveryHighlighterAttachmentIsPinned() throws {
        XCTAssertEqual(
            try fileNames(containing: "TextViewHighlighter("),
            Self.attachingFiles,
            "a view started (or stopped) attaching the syntax highlighter; it owes a base foreground too"
        )
    }

    func testEveryAttachingViewStatesItsBaseForeground() throws {
        XCTAssertEqual(
            try fileNames(containing: "textColor = SyntaxTheme.shared.color(for: .plain)"),
            Self.basingFiles,
            "a view attaching the syntax highlighter leaves uncovered text on the platform label colour"
        )
    }

    /// The one pair that splits across two files is the only one that may.
    func testOnlyTheIOSEditorSplitsAcrossTwoFiles() {
        let split = Self.attachingFiles.subtracting(Self.basingFiles)
        XCTAssertEqual(split, ["CodeEditorCoordinator_iOS.swift"])
        XCTAssertEqual(
            Self.basingFiles.subtracting(Self.attachingFiles),
            ["CodeEditorView_iOS.swift"]
        )
    }

    // MARK: - Reading

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// The names of the files under `Sources/Pisaka` whose stripped code contains
    /// `needle`.
    private func fileNames(containing needle: String) throws -> Set<String> {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "cannot enumerate \(sources.path)"
        )
        var names: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.strippingCommentsAndStringLiterals(text).contains(needle) {
                names.insert(url.lastPathComponent)
            }
        }
        return names
    }

    /// Swift text with its comments and string literals removed.
    ///
    /// Written here rather than borrowed: the repository's other scanners live in
    /// the Core test bundle, which this one cannot import.
    static func strippingCommentsAndStringLiterals(_ source: String) -> String {
        var output = ""
        let characters = Array(source)
        var index = 0
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if depth > 0 {
                if character == "*", next == "/" { depth -= 1; index += 2; continue }
                if character == "/", next == "*" { depth += 1; index += 2; continue }
                if character == "\n" { output.append(character) }
                index += 1
                continue
            }
            if character == "/", next == "*" { depth = 1; index += 2; continue }
            if character == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "\"" {
                index = Self.endOfStringLiteral(in: characters, startingAt: index)
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// The index just past the string literal that starts at `start`.
    private static func endOfStringLiteral(in characters: [Character], startingAt start: Int) -> Int {
        let isMultiline = start + 2 < characters.count
            && characters[start + 1] == "\""
            && characters[start + 2] == "\""
        var index = start + (isMultiline ? 3 : 1)
        while index < characters.count {
            if characters[index] == "\\" { index += 2; continue }
            if characters[index] == "\"" {
                guard isMultiline else { return index + 1 }
                if index + 2 < characters.count,
                   characters[index + 1] == "\"",
                   characters[index + 2] == "\"" {
                    return index + 3
                }
            }
            if !isMultiline, characters[index] == "\n" { return index }
            index += 1
        }
        return index
    }
}

#endif
