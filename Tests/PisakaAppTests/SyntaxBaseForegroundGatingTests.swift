#if os(macOS)
import Foundation
import XCTest

/// Every surface that declares itself the **code zone** and shows file content
/// states its own base foreground out of `SyntaxTheme`.
///
/// The rule is the whole zone's, not the editor's, and this suite is keyed on
/// what makes a surface the code zone — the declaration, `ZoomSurfaceProviding`'s
/// `zoomSurfaceKind == .code` or a `ZoomSurfaceMarker(kind: .code)` — rather than
/// on how that surface happens to be highlighted. The earlier key, the
/// `TextViewHighlighter(` attachment, could not see the macOS merge editor at
/// all: its three panes are not highlighted, so they drew file content at the
/// platform default while the iOS resolver beside them drew the table's plain
/// row. One feature, two platforms, two answers, and a green suite.
///
/// The defect the key names is therefore: *a surface that declares itself the
/// code zone and shows file content, but takes its foreground from the platform
/// rather than from the theme's plain row.* The platform's label colour is pure
/// black/white; the palette's plain row is `#1d1d1f`/`#dfe1e5`. A surface that
/// states nothing sits a step off the table beside every surface that does —
/// including, inside one highlighted pane, beside every character a capture did
/// cover.
///
/// Nothing in the compiler can see the omission, the defect being the *absence*
/// of an assignment, so both sets are pinned by **set equality** and the
/// foreground statements are counted by **site rather than by file**: a second
/// pane added inside a file that already passes cannot ride in on its neighbour.
/// A surface with no content of its own to colour — a gutter, the minimap, the
/// completion list, the scroll view behind a pane, a web view carrying its own
/// stylesheet, the commit message field, which is the user's prose and not the
/// file's — is a **named exemption with its reason**, never a silence.
///
/// It reads the repository through `#filePath` with Foundation alone, over
/// comment- and literal-stripped text: these files quote their own assignment in
/// the comment above it, so a raw `contains` would stay green when the line it
/// names is deleted.
final class SyntaxBaseForegroundGatingTests: XCTestCase {

    // MARK: - The code zone, by declaration

    /// Every code-zone surface in `Sources/Pisaka`, as `<file>:<declaring type>`.
    ///
    /// The declaring type rather than the file: `DiffView.swift` holds two of
    /// them, one of which owes a base foreground and one of which does not.
    private static let codeZoneSurfaces: Set<String> = [
        // Shows file content — owes a base foreground.
        "CodeEditorView.swift:EditorTextView",
        "DiffView.swift:DiffTextView",
        "MergeView.swift:MergePaneTextView",
        "SourceViewerContent.swift:SourceViewerTextView",
        "CommitUnifiedDiffView.swift:CommitUnifiedDiffView",
        "ProjectSearchView.swift:ProjectSearchView",
        // Exempt — see `exemptSurfaces` for the reason each one carries.
        "DiffView.swift:DiffGutterView",
        "LineNumberRulerView.swift:LineNumberRulerView",
        "MinimapView.swift:MinimapView",
        "CompletionPanel.swift:CompletionListContentView",
        "ZoomSurface.swift:CodeScrollView",
        "CommitDialogView.swift:CommitDialogView",
        "MarkdownPreviewPane.swift:MarkdownPreviewPane",
        "LeetCodeDescriptionView.swift:LeetCodeDescriptionPane",
    ]

    /// The code-zone surfaces that owe **no** base foreground, each with its
    /// reason. Exempt because there is nothing of the file's for a base
    /// foreground to colour — not because nobody got to them.
    private static let exemptSurfaces: [String: String] = [
        // Draws its own numbers and markers; every glyph it paints it colours.
        "DiffView.swift:DiffGutterView": "a gutter paints its own content",
        "LineNumberRulerView.swift:LineNumberRulerView": "a gutter paints its own content",
        // Draws token runs as filled rectangles; there is no text view at all.
        "MinimapView.swift:MinimapView": "paints token runs, not text",
        // Draws its rows itself, from `CompletionPopup`'s values.
        "CompletionPanel.swift:CompletionListContentView": "paints its own rows",
        // The empty region around a pane: it hosts the text view that states one.
        "ZoomSurface.swift:CodeScrollView": "hosts a pane that states its own",
        // The commit message is the user's prose, not the file's content.
        "CommitDialogView.swift:CommitDialogView": "the message is prose, not file content",
        // A web view carrying its own stylesheet, themed in `MarkdownPreviewTheme`.
        "MarkdownPreviewPane.swift:MarkdownPreviewPane": "a web view with its own stylesheet",
        // A web view carrying its own stylesheet, themed in the statement document.
        "LeetCodeDescriptionView.swift:LeetCodeDescriptionPane": "a web view with its own stylesheet",
    ]

    /// Each surface that owes a base foreground → the file that states it.
    ///
    /// Named rather than derived: an `NSTextView` subclass is configured by the
    /// representable that builds it, so the surface and its statement routinely
    /// live in different types and occasionally in different files.
    private static let statingFile: [String: String] = [
        "CodeEditorView.swift:EditorTextView": "CodeEditorView.swift",
        "DiffView.swift:DiffTextView": "DiffView.swift",
        "MergeView.swift:MergePaneTextView": "MergeView.swift",
        "SourceViewerContent.swift:SourceViewerTextView": "SourceViewerContent.swift",
        "CommitUnifiedDiffView.swift:CommitUnifiedDiffView": "CommitUnifiedDiffView.swift",
        "ProjectSearchView.swift:ProjectSearchView": "ProjectSearchView.swift",
    ]

    /// Every base-foreground statement in `Sources/Pisaka`, by file and **count**.
    ///
    /// The count is the granularity: two panes in one file owe two statements.
    /// The three iOS entries have no code-zone declaration to be keyed on — the
    /// zoom zones are macOS vocabulary — so they are held by the highlighter half
    /// below instead.
    private static let baseForegroundSites: [String: Int] = [
        "CodeEditorView.swift": 1,
        "DiffView.swift": 1,
        "MergeView.swift": 1,
        "SourceViewerContent.swift": 1,
        "CommitUnifiedDiffView.swift": 1,
        "ProjectSearchView.swift": 1,
        "CodeEditorView_iOS.swift": 1,
        "DiffView_iOS.swift": 1,
        "MergeView_iOS.swift": 1,
    ]

    func testEveryCodeZoneSurfaceIsPinned() throws {
        XCTAssertEqual(
            try codeZoneSurfacesInTree(),
            Self.codeZoneSurfaces,
            "a surface started (or stopped) declaring itself the code zone; it owes a base foreground or a named exemption"
        )
    }

    func testEveryExemptionNamesAPinnedSurface() {
        XCTAssertTrue(
            Set(Self.exemptSurfaces.keys).isSubset(of: Self.codeZoneSurfaces),
            "an exemption names a surface that no longer declares the code zone"
        )
        for (surface, reason) in Self.exemptSurfaces {
            XCTAssertFalse(reason.isEmpty, "\(surface) is exempt for no stated reason")
        }
    }

    /// Every code-zone surface is either exempt or names the file stating its
    /// base foreground. Silence is not a third answer.
    func testEveryNonExemptSurfaceStatesABaseForeground() throws {
        XCTAssertEqual(
            Self.codeZoneSurfaces.subtracting(Self.exemptSurfaces.keys),
            Set(Self.statingFile.keys),
            "a code-zone surface is neither exempt nor known to state a base foreground"
        )
        let sites = try baseForegroundSitesInTree()
        for (surface, file) in Self.statingFile {
            XCTAssertGreaterThan(
                sites[file] ?? 0,
                0,
                "\(surface) leaves uncovered text on the platform label colour"
            )
        }
    }

    /// The statements themselves, counted by site so a file that already passes
    /// cannot cover a second pane added inside it.
    func testEveryBaseForegroundSiteIsPinned() throws {
        XCTAssertEqual(
            try baseForegroundSitesInTree(),
            Self.baseForegroundSites,
            "a base-foreground statement was added or removed"
        )
    }

    // MARK: - The highlighter, which is now the iOS half

    /// The views that attach a `TextViewHighlighter` over `SyntaxTheme`.
    ///
    /// Still pinned, for the platform the zone declaration cannot reach: the iOS
    /// layer has no zoom surfaces, so the highlighter attachment is what names a
    /// pane there. On macOS it is a second, weaker reading of the same rule —
    /// weaker because the merge panes, which attach nothing, are outside it.
    private static let attachingFiles: Set<String> = [
        "CodeEditorView.swift",             // the macOS editor
        "DiffView.swift",                   // the macOS side-by-side diff panes
        "SourceViewerContent.swift",        // the macOS out-of-project viewer
        "CodeEditorCoordinator_iOS.swift",  // the iOS editor
        "DiffView_iOS.swift",               // the iOS diff panes
        "MergeView_iOS.swift",              // the iOS three-pane merge editor
    ]

    /// The iOS views that attach a highlighter, and the file that bases each.
    ///
    /// The iOS editor attaches its highlighter from its coordinator and
    /// configures its text view in the representable, so the two halves of that
    /// one view live in two files. It is the only pair that splits, and it is
    /// named here rather than allowed by a weaker rule.
    private static let iOSBasingFiles: Set<String> = [
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

    func testEveryIOSAttachingViewStatesItsBaseForeground() throws {
        let sites = try baseForegroundSitesInTree()
        for file in Self.iOSBasingFiles {
            XCTAssertGreaterThan(
                sites[file] ?? 0,
                0,
                "\(file) attaches the syntax highlighter and leaves uncovered text on the platform label colour"
            )
        }
    }

    /// The one pair that splits across two files is the only one that may.
    func testOnlyTheIOSEditorSplitsAcrossTwoFiles() {
        let iOSAttaching = Self.attachingFiles.filter { $0.hasSuffix("_iOS.swift") }
        XCTAssertEqual(
            Set(iOSAttaching).subtracting(Self.iOSBasingFiles),
            ["CodeEditorCoordinator_iOS.swift"]
        )
        XCTAssertEqual(
            Self.iOSBasingFiles.subtracting(iOSAttaching),
            ["CodeEditorView_iOS.swift"]
        )
    }

    // MARK: - Scanning the tree

    /// The two spellings of "this surface is the code zone".
    private static let codeZoneNeedles = [
        "zoomSurfaceKind: ZoomSurfaceKind = .code",
        "ZoomSurfaceMarker(kind: .code)",
    ]

    /// The two spellings of "this surface's base foreground is the table's plain
    /// row" — an `NSTextView`/`UITextView` property and a SwiftUI modifier.
    private static let baseForegroundNeedles = [
        "textColor = SyntaxTheme.shared.color(for: .plain)",
        ".foregroundStyle(Color(SyntaxTheme.shared.color(for: .plain)))",
    ]

    /// Every code-zone surface in the tree, as `<file>:<declaring type>`.
    ///
    /// The declaring type is the nearest **top-level** type declaration above the
    /// line: top-level so a nested `enum` between the declaration and the marker
    /// cannot be mistaken for the surface's own type.
    private func codeZoneSurfacesInTree() throws -> Set<String> {
        var surfaces: Set<String> = []
        try forEachSourceFile { name, text in
            var current: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let declared = Self.topLevelTypeName(String(line)) { current = declared }
                guard Self.codeZoneNeedles.contains(where: { line.contains($0) }) else { continue }
                surfaces.insert("\(name):\(current ?? "<file scope>")")
            }
        }
        return surfaces
    }

    /// Every base-foreground statement in the tree, counted per file.
    private func baseForegroundSitesInTree() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try forEachSourceFile { name, text in
            let total = Self.baseForegroundNeedles.reduce(0) { $0 + Self.occurrences(of: $1, in: text) }
            if total > 0 { counts[name] = total }
        }
        return counts
    }

    /// The name a top-level type declaration on `line` introduces, if any.
    ///
    /// Top-level means column zero: an indented declaration is nested inside the
    /// surface's own type and must not replace it.
    static func topLevelTypeName(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }
        var words = line.split(separator: " ").map(String.init)
        while let word = words.first,
              ["public", "internal", "fileprivate", "private", "final", "open", "@MainActor"].contains(word) {
            words.removeFirst()
        }
        guard words.count >= 2, ["class", "struct", "enum", "extension"].contains(words[0]) else { return nil }
        let name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    // MARK: - Reading

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// Every Swift file under `Sources/Pisaka`, as its name and its comment- and
    /// literal-stripped text. The one reader the three scans above share.
    private func forEachSourceFile(_ body: (String, String) -> Void) throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil),
            "cannot enumerate \(sources.path)"
        )
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            body(url.lastPathComponent, Self.strippingCommentsAndStringLiterals(text))
        }
    }

    /// The names of the files under `Sources/Pisaka` whose stripped code contains
    /// `needle`.
    private func fileNames(containing needle: String) throws -> Set<String> {
        var names: Set<String> = []
        try forEachSourceFile { name, text in
            if text.contains(needle) { names.insert(name) }
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
