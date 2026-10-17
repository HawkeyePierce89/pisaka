#if os(macOS)
import Foundation
import PisakaCore
import SwiftTreeSitter
import XCTest
@testable import Pisaka

/// Toggle Comment's JSX context (R6) over the real TSX grammar:
/// `CommentContextTreeWalk` collects the chain at a line's first non-whitespace
/// offset, and `CommentStyle.context(ancestors:)` reads it. The Core suite pins
/// the rule over synthetic chains; this pins that the pinned grammar's node
/// kinds and nesting are the ones the rule was written against.
///
/// What it pins:
/// - a `<div>` child line, a jsx text line, a child's closing tag line and a
///   child `{…}` line are JSX children;
/// - the root element of a `return (…)` and plain TS are code;
/// - an attribute line and a lone `/>` line inside a multi-line tag are code;
/// - a child line of a `<>…</>` fragment is JSX children;
/// - the whole toggle through the resolver writes `{/* */}` on a child line,
///   and a second ⌘/ — or ⌥⌘/ over the wrapped text — gives the source back
///   byte for byte, because the wrapped line is itself a child `{…}` line;
/// - the javascript grammar answers the same, and a non-ASCII character
///   earlier in the buffer does not shift the UTF-16-to-byte offset.
@MainActor
final class CommentContextTreeWalkTests: XCTestCase {
    private let source = """
    const answer: number = 42;

    export function View({ items }: { items: string[] }) {
      return (
        <div>
          <span>first</span>
          plain words
          {items.map((item) => item)}
          <img
            className="x"
          />
          <p>
            nested
          </p>
        </div>
      );
    }

    export function Fragment() {
      return (
        <>
          <em>child</em>
        </>
      );
    }
    """

    private func context(
        ofLineContaining needle: String, in source: String? = nil, language: SyntaxLanguage = .tsx
    ) throws -> CommentContext {
        let source = source ?? self.source
        let text = source as NSString
        let tree = try XCTUnwrap(SyntaxTreeSnapshot.parse(text: source, language: language))
        let found = text.range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, needle)
        let line = text.lineRange(for: NSRange(location: found.location, length: 0))
        var offset = line.location
        while offset < NSMaxRange(line), text.character(at: offset) == 0x20 { offset += 1 }
        let chain = CommentContextTreeWalk.ancestors(in: tree, at: offset, textLength: text.length)
        return CommentStyle.context(ancestors: chain)
    }

    func testChildLinesAreJSXChildren() throws {
        XCTAssertEqual(try context(ofLineContaining: "<span>first"), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "plain words"), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "<p>"), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "</p>"), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "{items.map"), .jsxChildren)
    }

    func testRootAndPlainCodeAreCode() throws {
        XCTAssertEqual(try context(ofLineContaining: "<div>"), .code)
        XCTAssertEqual(try context(ofLineContaining: "const answer"), .code)
        XCTAssertEqual(try context(ofLineContaining: "return ("), .code)
    }

    func testLinesInsideAMultiLineTagAreCode() throws {
        XCTAssertEqual(try context(ofLineContaining: "className=\"x\""), .code)
        XCTAssertEqual(try context(ofLineContaining: "/>"), .code)
    }

    func testAFragmentChildLineIsJSXChildren() throws {
        XCTAssertEqual(try context(ofLineContaining: "<em>child"), .jsxChildren)
    }

    func testTheJavaScriptGrammarAnswersTheSame() throws {
        let source = """
        function View() {
          return (
            <div>
              <span>first</span>
              {items}
            </div>
          );
        }
        """
        XCTAssertEqual(try context(ofLineContaining: "<span>first", in: source, language: .javascript), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "{items}", in: source, language: .javascript), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "<div>", in: source, language: .javascript), .code)
    }

    func testANonASCIIPrefixDoesNotShiftTheOffset() throws {
        let source = """
        const greeting = "привет, 🌍";
        function View() {
          return (
            <div>
              <span>first</span>
            </div>
          );
        }
        """
        XCTAssertEqual(try context(ofLineContaining: "<span>first", in: source), .jsxChildren)
        XCTAssertEqual(try context(ofLineContaining: "<div>", in: source), .code)
    }

    private func applying(_ plan: RangeEditPlan, to source: String) -> String {
        let result = NSMutableString(string: source)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func lineToggle(_ source: String, caretAt needle: String) throws -> String {
        let text = source as NSString
        let caret = text.range(of: needle).location
        XCTAssertNotEqual(caret, NSNotFound, needle)
        let resolver = CommentContextTreeWalk.resolver(
            snapshot: SyntaxTreeSnapshot(), text: text, language: .tsx, fileID: nil
        )
        let plan = try XCTUnwrap(ToggleCommentEngine.toggle(
            text: text, selectedRanges: [NSRange(location: caret, length: 0)], language: .tsx, context: resolver
        ))
        return applying(plan, to: source)
    }

    func testTheToggleThroughTheResolverWritesBracesAndUndoesThem() throws {
        let wrapped = try lineToggle(source, caretAt: "<span>first")
        XCTAssertTrue(wrapped.contains("\n      {/* <span>first</span> */}\n"), wrapped)
        XCTAssertEqual(try lineToggle(wrapped, caretAt: "{/* <span>first"), source)
    }

    func testTheBlockToggleUnwrapsAWrappedChild() throws {
        let child = "<span>first</span>"
        let text = source as NSString
        let resolver = CommentContextTreeWalk.resolver(
            snapshot: SyntaxTreeSnapshot(), text: text, language: .tsx, fileID: nil
        )
        let first = try XCTUnwrap(BlockCommentEngine.toggle(
            text: text, selectedRanges: [text.range(of: child)], language: .tsx, context: resolver
        ))
        let wrapped = applying(first, to: source)
        XCTAssertTrue(wrapped.contains("\n      {/* \(child) */}\n"), wrapped)
        let wrappedText = wrapped as NSString
        let again = try XCTUnwrap(BlockCommentEngine.toggle(
            text: wrappedText, selectedRanges: first.selections, language: .tsx,
            context: CommentContextTreeWalk.resolver(
                snapshot: SyntaxTreeSnapshot(), text: wrappedText, language: .tsx, fileID: nil
            )
        ))
        XCTAssertEqual(applying(again, to: wrapped), source)
    }
}
#endif
