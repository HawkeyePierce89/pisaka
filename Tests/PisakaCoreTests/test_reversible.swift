import XCTest
@testable import PisakaCore

final class ExtraTests: XCTestCase {
    func testIndentedReversibility() {
        let text = "  a"
        let nsText = text as NSString
        let edit1 = ToggleCommentEngine.toggle(text: nsText, selectedRange: NSRange(location: 0, length: 0), language: .swift)!
        XCTAssertEqual(edit1.text, "  // a")
        let range = NSRange(location: 0, length: 0)
        let edit2 = ToggleCommentEngine.toggle(text: edit1.text as NSString, selectedRange: range, language: .swift)!
        XCTAssertEqual(edit2.text, "  a")
    }
}
