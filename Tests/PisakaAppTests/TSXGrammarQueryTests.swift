#if os(macOS)
import Foundation
import XCTest
import PisakaCore
import SwiftTreeSitter
@testable import Pisaka

/// `.tsx` is parsed with the TSX grammar (`TreeSitterTSX`, shipped by the
/// already-linked `TreeSitterTypeScript` product), and this suite **executes**
/// what ships for it: the grammar, the shipped `Queries/tsx/symbols.scm`, and
/// the three-layer highlights query `SyntaxLanguageConfiguration` composes.
///
/// Every failure here is silent in the product. A query that does not compile
/// leaves `.tsx` files indexing nothing; a merged highlights query that does
/// not compile degrades to the TSX bundle's own TypeScript-only highlights, so
/// JSX tags and ordinary JavaScript syntax render as plain text — and the
/// TypeScript grammar the extension used to resolve to parsed JSX as `ERROR`.
/// None of it is visible to `swift test`, which links no grammar.
final class TSXGrammarQueryTests: XCTestCase {
    /// A component file: an interface, a function component returning a
    /// lowercase element with attributes, and an arrow-function component
    /// rendering the first one as a self-closing element.
    private let sample = """
        import React from "react";

        interface Props { label: string }

        export function Button({ label }: Props) {
          return <button className="primary" onClick={() => {}}>{label}</button>;
        }

        export const App = () => (
          <div id="root">
            <Button label="go" />
          </div>
        );

        """

    func testTheTSXGrammarLoads() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .tsx))
        XCTAssertEqual(configuration.name, "TSX")
    }

    func testTheTSXSymbolsQueryCompiles() {
        XCTAssertNotNil(SymbolQueryCatalog.query(for: .tsx))
    }

    /// Both component shapes are indexed, by set equality over the whole answer.
    func testTheSampleIndexesItsComponents() {
        let symbols = SymbolExtractor.symbols(
            in: sample, language: .tsx, fileURL: URL(fileURLWithPath: "/p/App.tsx")
        )
        let found = Set(symbols.map { Entry(kind: $0.kind, name: $0.name, container: $0.containerName) })
        XCTAssertEqual(found, [
            Entry(kind: .type, name: "Props", container: nil),
            Entry(kind: .property, name: "label", container: "Props"),
            Entry(kind: .function, name: "Button", container: nil),
            Entry(kind: .constant, name: "App", container: nil),
        ])
    }

    /// The JSX half parses: no `ERROR` or missing node anywhere in the tree.
    func testJSXInATSXFileParsesWithoutErrors() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .tsx))
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(sample))
        let root = try XCTUnwrap(tree.rootNode)
        XCTAssertFalse(root.hasError, "the TSX sample must parse without an ERROR or missing node")
    }

    /// The composed highlights query is the one installed — not the TSX bundle's
    /// own fallback — and each of its three layers answers: the JSX layer tags
    /// the lowercase element and its attributes (and, through its `#match?`,
    /// not the capitalised component), the JavaScript layer the string, and the
    /// TypeScript layer the type annotation.
    func testTheMergedHighlightsCaptureTagsAttributesAndBothLanguageLayers() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .tsx))
        let query = try XCTUnwrap(configuration.queries[.highlights])
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(sample))
        let root = try XCTUnwrap(tree.rootNode)

        let content = sample as NSString
        let context = Predicate.Context(string: sample)
        var captured: [String: Set<String>] = [:]
        for match in query.execute(node: root, in: tree) where match.allowed(in: context) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                captured[name, default: []].insert(content.substring(with: capture.range))
            }
        }

        XCTAssertEqual(captured["tag"], ["button", "div"])
        XCTAssertEqual(captured["attribute"], ["className", "onClick", "id", "label"])
        XCTAssertTrue(captured["string"]?.contains("\"react\"") == true, "the JavaScript layer is missing")
        XCTAssertTrue(captured["type"]?.contains("Props") == true, "the TypeScript layer is missing")
    }

    private struct Entry: Hashable {
        let kind: SymbolKind
        let name: String
        let container: String?
    }
}
#endif
