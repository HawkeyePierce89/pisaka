import XCTest
@testable import PisakaCore

final class SearchScopeLineTests: XCTestCase {
    func testWithoutAMaskTheLineNamesTheProjectAndTheExclusion() {
        XCTAssertEqual(
            SearchScopeLine.text(projectName: "pisaka", fileMask: ""),
            "In: pisaka · Exclude: ignored files"
        )
    }

    func testAMaskSitsBetweenTheProjectAndTheExclusion() {
        XCTAssertEqual(
            SearchScopeLine.text(projectName: "pisaka", fileMask: "*.ts, *.tsx"),
            "In: pisaka · Files: *.ts, *.tsx · Exclude: ignored files"
        )
    }

    func testAMaskIsTrimmedOfSurroundingWhitespace() {
        XCTAssertEqual(
            SearchScopeLine.text(projectName: "pisaka", fileMask: "  *.swift \n"),
            "In: pisaka · Files: *.swift · Exclude: ignored files"
        )
    }

    func testAnEmptyOrBlankMaskIsNoMask() {
        let expected = "In: My Project · Exclude: ignored files"
        XCTAssertEqual(SearchScopeLine.text(projectName: "My Project", fileMask: ""), expected)
        XCTAssertEqual(SearchScopeLine.text(projectName: "My Project", fileMask: "   "), expected)
    }
}
