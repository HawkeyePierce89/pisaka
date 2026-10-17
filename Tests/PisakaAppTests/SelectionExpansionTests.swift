#if os(macOS)
import AppKit
import PisakaCore
import SwiftTreeSitter
import XCTest
@testable import Pisaka

/// Expand / Shrink Selection's app half (R6): the coordinator's
/// `SelectionExpansionController` climbs the real TypeScript tree through
/// `SelectionExpansionTreeWalk`, hands the chain to `SelectionExpansionRule`,
/// and keeps the `SelectionExpansionHistory` that Shrink walks back along.
///
/// What it pins:
/// - from a caret in an argument, Expand steps through the word, the argument
///   contents, the argument list, the call and the statement, and Shrink
///   returns along exactly that path, then has nothing left;
/// - inside a string literal the word is the first step;
/// - a selection change Expand did not make, and an edit, both clear the
///   history;
/// - plain text, which has no grammar, climbs the bracket fallback.
///
/// The fixture is read through `#filePath`. The tree is parsed up front through
/// the coordinator's own snapshot, so each Expand below is served from its
/// cache synchronously — the causal order, not a wait.
@MainActor
final class SelectionExpansionTests: XCTestCase {

    func testExpandClimbsWordArgumentsCallStatementAndShrinkReturns() async throws {
        let editor = try await makeEditor(try fixture("expand.ts"), language: .typescript)
        let text = editor.text
        let caret = text.range(of: "alpha, beta)").location + 2
        editor.select(NSRange(location: caret, length: 0))

        var steps: [String] = []
        for _ in 0..<5 {
            XCTAssertTrue(editor.coordinator.selectionExpansion.expand())
            steps.append(text.substring(with: editor.selection))
        }
        XCTAssertEqual(steps, [
            "alpha",
            "alpha, beta",
            "(alpha, beta)",
            "report(alpha, beta)",
            "report(alpha, beta);",
        ])

        var back: [String] = []
        for _ in 0..<4 {
            XCTAssertTrue(editor.coordinator.selectionExpansion.shrink())
            back.append(text.substring(with: editor.selection))
        }
        XCTAssertEqual(back, ["report(alpha, beta)", "(alpha, beta)", "alpha, beta", "alpha"])
        XCTAssertTrue(editor.coordinator.selectionExpansion.shrink())
        XCTAssertEqual(editor.selection, NSRange(location: caret, length: 0))
        XCTAssertFalse(editor.coordinator.selectionExpansion.shrink(), "nothing left to shrink back to")
    }

    func testInsideAStringTheWordIsTheFirstStep() async throws {
        let editor = try await makeEditor(try fixture("expand.ts"), language: .typescript)
        let caret = editor.text.range(of: "hello world").location + 2
        editor.select(NSRange(location: caret, length: 0))
        XCTAssertTrue(editor.coordinator.selectionExpansion.expand())
        XCTAssertEqual(editor.text.substring(with: editor.selection), "hello")
        XCTAssertTrue(editor.coordinator.selectionExpansion.expand())
        XCTAssertEqual(editor.text.substring(with: editor.selection), "hello world")
    }

    func testAManualSelectionChangeClearsTheHistory() async throws {
        let editor = try await makeEditor(try fixture("expand.ts"), language: .typescript)
        let caret = editor.text.range(of: "alpha, beta)").location + 2
        editor.select(NSRange(location: caret, length: 0))
        XCTAssertTrue(editor.coordinator.selectionExpansion.expand())
        XCTAssertTrue(editor.coordinator.selectionExpansion.expand())

        editor.select(NSRange(location: caret + 1, length: 0))
        XCTAssertFalse(editor.coordinator.selectionExpansion.shrink(), "a click elsewhere forgets the path")
    }

    func testAnEditClearsTheHistory() async throws {
        let editor = try await makeEditor(try fixture("expand.ts"), language: .typescript)
        let caret = editor.text.range(of: "alpha, beta)").location + 2
        editor.select(NSRange(location: caret, length: 0))
        XCTAssertTrue(editor.coordinator.selectionExpansion.expand())

        // An edit before the selection, with no selection made afterwards.
        editor.harness.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// x\n")
        XCTAssertFalse(editor.coordinator.selectionExpansion.shrink(), "an edit forgets the path")
    }

    func testPlainTextClimbsTheBracketFallback() async throws {
        let editor = try await makeEditor("call(one, [two]) tail", language: nil)
        let caret = editor.text.range(of: "one").location + 1
        editor.select(NSRange(location: caret, length: 0))

        var steps: [String] = []
        while editor.coordinator.selectionExpansion.expand() {
            steps.append(editor.text.substring(with: editor.selection))
        }
        XCTAssertEqual(steps, ["one", "one, [two]", "(one, [two])", "call(one, [two]) tail"])
    }

    // MARK: - Harness

    @MainActor
    private final class Editor {
        let harness: EditorLayoutHarness
        let coordinator: CodeEditorView.Coordinator

        init(text: String, language: SyntaxLanguage?) {
            harness = EditorLayoutHarness()
            harness.textView.string = text
            coordinator = CodeEditorView.Coordinator(text: .constant(text))
            coordinator.textView = harness.textView
            coordinator.fileID = UUID()
            coordinator.language = language
            // The delegate `makeNSView` assigns, through which the menu
            // commands reach `selectionExpansion`.
            harness.textView.delegate = coordinator
        }

        var text: NSString { harness.textView.string as NSString }
        var selection: NSRange { harness.textView.selectedRange() }

        func select(_ range: NSRange) {
            harness.textView.setSelectedRange(range)
        }
    }

    private func makeEditor(_ text: String, language: SyntaxLanguage?) async throws -> Editor {
        let editor = Editor(text: text, language: language)
        addTeardownBlock { @MainActor in
            editor.harness.textView.delegate = nil
        }
        if let language, let fileID = editor.coordinator.fileID {
            let tree = await editor.coordinator.treeSnapshot.tree(text: text, language: language, fileID: fileID)
            XCTAssertNotNil(tree, "the grammar did not load")
        }
        return editor
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

#endif
