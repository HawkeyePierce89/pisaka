with open('Tests/PisakaCoreTests/ToggleCommentEngineTests.swift', 'r') as f:
    content = f.read()

old_test = '''    func testBlockWrapUnwrapRoundTrip() {
        let original = "  a\\n  b"
        let edit1 = ToggleCommentEngine.toggle(text: original as NSString, selectedRange: NSRange(location: 0, length: 7), language: .css)!
        let edit2 = ToggleCommentEngine.toggle(text: edit1.text as NSString, selectedRange: edit1.selectedRange, language: .css)!
        XCTAssertEqual(edit2.text, original)
    }'''

new_test = '''    func testBlockWrapUnwrapRoundTrip() {
        let original = "  a\\n  b"
        let edit1 = ToggleCommentEngine.toggle(text: original as NSString, selectedRange: NSRange(location: 0, length: 7), language: .css)!
        let edit2 = ToggleCommentEngine.toggle(text: edit1.text as NSString, selectedRange: edit1.selectedRange, language: .css)!
        XCTAssertEqual(edit2.text, original)
        XCTAssertEqual(edit2.selectedRange, NSRange(location: 0, length: 7))
    }'''

content = content.replace(old_test, new_test)

with open('Tests/PisakaCoreTests/ToggleCommentEngineTests.swift', 'w') as f:
    f.write(content)
