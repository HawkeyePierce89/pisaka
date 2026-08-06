import XCTest
@testable import PisakaCore

final class ShellQuoteTests: XCTestCase {
    func testPlainPath() {
        XCTAssertEqual(ShellQuote.quote("/p/app.py"), "'/p/app.py'")
    }

    func testPathWithSpaces() {
        XCTAssertEqual(ShellQuote.quote("/my dir/a b.py"), "'/my dir/a b.py'")
    }

    func testEmbeddedSingleQuote() {
        XCTAssertEqual(ShellQuote.quote("/p/it's.py"), "'/p/it'\\''s.py'")
    }

    func testShellMetacharactersAreLiteral() {
        XCTAssertEqual(ShellQuote.quote("/p/$x`y;z.py"), "'/p/$x`y;z.py'")
    }

    func testEmptyString() {
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }
}
