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
/// - a `<div>` child line, a jsx text line and a child's closing tag line are
///   JSX children;
/// - a `{…}` line, the root element of a `return (…)` and plain TS are code;
/// - an attribute line and a lone `/>` line inside a multi-line tag are code;
/// - a child line of a `<>…</>` fragment is JSX children;
/// - the whole toggle through the resolver writes `{/* */}` on a child line.
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

    private func context(ofLineContaining needle: String) throws -> CommentContext {
        let text = source as NSString
        let tree = try XCTUnwrap(SyntaxTreeSnapshot.parse(text: source, language: .tsx))
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
    }

    func testExpressionRootAndPlainCodeAreCode() throws {
        XCTAssertEqual(try context(ofLineContaining: "{items.map"), .code)
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

    func testTheToggleThroughTheResolverWritesBraces() throws {
        let text = source as NSString
        let caret = text.range(of: "<span>first").location
        let resolver = CommentContextTreeWalk.resolver(
            snapshot: SyntaxTreeSnapshot(), text: text, language: .tsx, fileID: nil
        )
        let plan = try XCTUnwrap(ToggleCommentEngine.toggle(
            text: text, selectedRanges: [NSRange(location: caret, length: 0)], language: .tsx, context: resolver
        ))
        let result = NSMutableString(string: source)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertTrue((result as String).contains("\n      {/* <span>first</span> */}\n"), result as String)
    }
}
#endif
