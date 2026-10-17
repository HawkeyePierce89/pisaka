#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// `EditorTextView`'s word granularity — what a double-click selects — read off
/// the real override on the editor's TextKit 1 stack (`EditorLayoutHarness`),
/// no window.
///
/// The rule itself is Core's `WordSelectionRule`, pinned there case by case;
/// this suite pins the app half alone: that `.selectByWord` reaches the rule
/// with the language the view's `syntaxLanguage` reports at that moment, and
/// that everything the rule leaves to the platform — a punctuation click, the
/// triple-click's paragraph — is exactly what a stock `NSTextView` over the
/// same text answers.
@MainActor
final class WordSelectionGranularityTests: XCTestCase {
    private let text = "const s = z.object({ a: c$d, b: res.status })\nnext line\n"

    func testDoubleClickSelectsOneIdentifierBetweenPeriods() {
        let editor = makeEditor(language: .typescript)
        XCTAssertEqual(word(at: "z", in: editor), "z")
        XCTAssertEqual(word(at: "object", in: editor, inset: 3), "object")
        XCTAssertEqual(word(at: "res", in: editor, inset: 1), "res")
        XCTAssertEqual(word(at: "status", in: editor, inset: 2), "status")
    }

    func testDollarIsAWordCharacterInTypeScriptOnly() {
        let editor = makeEditor(language: .typescript)
        XCTAssertEqual(word(at: "c$d", in: editor, inset: 1), "c$d")
        XCTAssertEqual(word(at: "c$d", in: editor, inset: 0), "c$d")

        editor.syntaxLanguage = { .swift }
        XCTAssertEqual(word(at: "c$d", in: editor, inset: 0), "c", "the language is read per gesture")
    }

    func testDragSnapsEachEndToItsIdentifier() {
        let editor = makeEditor(language: .typescript)
        let ns = text as NSString
        let start = ns.range(of: "res").location + 1
        let end = ns.range(of: "status").location + 3
        let range = editor.selectionRange(
            forProposedRange: NSRange(location: start, length: end - start),
            granularity: .selectByWord
        )
        XCTAssertEqual(ns.substring(with: range), "res.status")
    }

    func testPunctuationClickIsThePlatformsAnswer() {
        let editor = makeEditor(language: .typescript)
        let stock = makeStock()
        for needle in ["(", "{", ".", " = "] {
            let proposed = NSRange(location: (text as NSString).range(of: needle).location, length: 0)
            XCTAssertEqual(
                editor.selectionRange(forProposedRange: proposed, granularity: .selectByWord),
                stock.selectionRange(forProposedRange: proposed, granularity: .selectByWord),
                "click on \(needle.debugDescription)"
            )
        }
    }

    func testOtherGranularitiesAreUntouched() {
        let editor = makeEditor(language: .typescript)
        let stock = makeStock()
        let proposed = NSRange(location: (text as NSString).range(of: "object").location + 2, length: 0)
        for granularity in [NSSelectionGranularity.selectByParagraph, .selectByCharacter] {
            XCTAssertEqual(
                editor.selectionRange(forProposedRange: proposed, granularity: granularity),
                stock.selectionRange(forProposedRange: proposed, granularity: granularity),
                "granularity \(granularity.rawValue)"
            )
        }
    }

    // MARK: - Helpers

    private func makeEditor(language: SyntaxLanguage?) -> EditorTextView {
        let editor = EditorTextView(usingTextLayoutManager: false)
        let harness = EditorLayoutHarness(textView: editor)
        editor.string = text
        harness.layOut()
        editor.syntaxLanguage = { language }
        retained.append(harness)
        return editor
    }

    private func makeStock() -> NSTextView {
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        retained.append(harness)
        return harness.textView
    }

    /// The word a click `inset` characters into the first `needle` selects.
    private func word(at needle: String, in editor: EditorTextView, inset: Int = 0) -> String {
        let ns = text as NSString
        let proposed = NSRange(location: ns.range(of: needle).location + inset, length: 0)
        return ns.substring(with: editor.selectionRange(forProposedRange: proposed, granularity: .selectByWord))
    }

    /// The harnesses own the scroll views the text views live in.
    private var retained: [EditorLayoutHarness] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }
}
#endif
