import XCTest
@testable import PisakaCore

final class CompletionPopupTests: XCTestCase {

    func testSelectionInitialAndClamping() {
        XCTAssertNil(CompletionPopupSelection(count: 0))
        XCTAssertNil(CompletionPopupSelection(count: -1))

        var sel1 = CompletionPopupSelection(count: 1)!
        XCTAssertEqual(sel1.selectedIndex, 0)
        sel1.moveUp()
        XCTAssertEqual(sel1.selectedIndex, 0)
        sel1.moveDown()
        XCTAssertEqual(sel1.selectedIndex, 0)

        var sel = CompletionPopupSelection(count: 3)!
        XCTAssertEqual(sel.selectedIndex, 0)

        sel.moveUp()
        XCTAssertEqual(sel.selectedIndex, 0)

        sel.moveDown()
        XCTAssertEqual(sel.selectedIndex, 1)

        sel.moveDown()
        XCTAssertEqual(sel.selectedIndex, 2)

        sel.moveDown()
        XCTAssertEqual(sel.selectedIndex, 2)

        sel.select(1)
        XCTAssertEqual(sel.selectedIndex, 1)

        sel.select(5) // out of bounds, ignored
        XCTAssertEqual(sel.selectedIndex, 1)

        sel.select(-1)
        XCTAssertEqual(sel.selectedIndex, 1)
    }

    func testBadgesForEverySymbolKind() {
        let expected: [SymbolKind: String] = [
            .type: "t.square",
            .function: "f.cursive",
            .method: "f.cursive",
            .property: "p.square",
            .constant: "c.square",
            .variable: "v.square",
            .heading: "number",
            .selector: "s.square",
            .key: "k.square",
            .stage: "shippingbox",
            .anchor: "link",
            .target: "target",
        ]
        XCTAssertEqual(Set(expected.keys), Set(SymbolKind.allCases))

        for kind in SymbolKind.allCases {
            let badge = CompletionBadge(source: .symbol(kind))
            XCTAssertEqual(badge.symbolName, expected[kind], "Kind \(kind) needs a valid SF Symbol name")
        }
    }

    func testKeywordVsWord() {
        let itemWord = CompletionItem(text: "foo", kind: nil, isFromCurrentFile: true)
        let itemKeyword = CompletionItem(text: "class", kind: nil, isFromCurrentFile: true)
        let itemSymbol = CompletionItem(text: "MyClass", kind: .type, isFromCurrentFile: true)
        let itemSymbolKw = CompletionItem(text: "func", kind: .function, isFromCurrentFile: true)

        // With language (swift has "class")
        let rowsSwift = CompletionRow.rows(for: [itemWord, itemKeyword, itemSymbol, itemSymbolKw], language: .swift)
        XCTAssertEqual(rowsSwift[0].badge.symbolName, "text.word.spacing")
        XCTAssertEqual(rowsSwift[1].badge.symbolName, "k.circle")
        XCTAssertEqual(rowsSwift[2].badge.symbolName, "t.square")
        XCTAssertEqual(rowsSwift[3].badge.symbolName, "f.cursive")

        // Without language
        let rowsNil = CompletionRow.rows(for: [itemKeyword], language: nil)
        XCTAssertEqual(rowsNil[0].badge.symbolName, "text.word.spacing")

        // Language without keywords
        let rowsJson = CompletionRow.rows(for: [itemKeyword], language: .json)
        XCTAssertEqual(rowsJson[0].badge.symbolName, "text.word.spacing")
    }

    func testRowOrderAndDisplayTextPreserved() {
        let items = [
            CompletionItem(text: "alpha", kind: nil, isFromCurrentFile: true, displayText: "alpha_disp"),
            CompletionItem(text: "beta", kind: nil, isFromCurrentFile: true, displayText: "beta_disp"),
            CompletionItem(
                text: "gamma", kind: nil, isFromCurrentFile: true, displayText: "alpha_disp"
            ), // dup displayText
        ]

        let rows = CompletionRow.rows(for: items, language: nil)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].displayText, "alpha_disp")
        XCTAssertEqual(rows[1].displayText, "beta_disp")

        let emptyRows = CompletionRow.rows(for: [], language: nil)
        XCTAssertTrue(emptyRows.isEmpty)
    }

    /// `detail` is display-only: two items differing only there dedup to the
    /// first, in the same order, inserting the same text, exactly as they would
    /// without it.
    func testDetailTakesNoPartInDedupOrOrderOrInsertedText() {
        let withDetail = [
            CompletionItem(text: "greet()", kind: .method, isFromCurrentFile: false, detail: "Void"),
            CompletionItem(text: "greet()", kind: .method, isFromCurrentFile: false, detail: "String"),
            CompletionItem(text: "salutation", kind: .property, isFromCurrentFile: false, detail: "String"),
        ]
        let without = withDetail.map {
            CompletionItem(text: $0.text, kind: $0.kind, isFromCurrentFile: $0.isFromCurrentFile)
        }

        let rows = CompletionRow.rows(for: withDetail, language: .swift)
        let plain = CompletionRow.rows(for: without, language: .swift)

        XCTAssertEqual(rows.map(\.displayText), plain.map(\.displayText))
        XCTAssertEqual(rows.map(\.displayText), ["greet()", "salutation"])
        XCTAssertEqual(rows.map(\.item.text), plain.map(\.item.text))
        XCTAssertEqual(rows.map(\.badge), plain.map(\.badge))
        XCTAssertEqual(rows.first?.item.detail, "Void")
        XCTAssertNil(plain.first?.item.detail)
    }
}
