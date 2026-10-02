import XCTest
@testable import PisakaCore

final class MainWindowTitleTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/someone/git/pisaka", isDirectory: true)

    func testAProjectAndAFocusedFileReadProjectDashFile() {
        XCTAssertEqual(
            MainWindowTitle.text(projectRoot: root, focusedFileName: "ContentView.swift"),
            "pisaka — ContentView.swift"
        )
    }

    func testAProjectWithNoFocusedFileReadsTheProjectAlone() {
        XCTAssertEqual(MainWindowTitle.text(projectRoot: root, focusedFileName: nil), "pisaka")
        XCTAssertEqual(MainWindowTitle.text(projectRoot: root, focusedFileName: ""), "pisaka")
    }

    func testNoProjectReadsTheAppsDefault() {
        XCTAssertEqual(MainWindowTitle.text(projectRoot: nil, focusedFileName: nil), "Pisaka")
        XCTAssertEqual(
            MainWindowTitle.text(projectRoot: nil, focusedFileName: "Untitled"), "Pisaka",
            "with no project open the title is the default, whatever is focused"
        )
    }

    func testTheProjectNameIsTheFolderAsSpelledWithOrWithoutATrailingSlash() {
        let spelled = URL(fileURLWithPath: "/tmp/My Project/")
        XCTAssertEqual(MainWindowTitle.text(projectRoot: spelled, focusedFileName: "a.txt"), "My Project — a.txt")
    }
}
