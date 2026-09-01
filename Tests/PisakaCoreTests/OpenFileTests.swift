import XCTest
@testable import PisakaCore

/// The open-file model's two kinds and the dirty rule each carries.
final class OpenFileTests: XCTestCase {
    private let databaseURL = URL(fileURLWithPath: "/tmp/project/app.sqlite")

    // MARK: - Text tabs

    func testOrdinaryInitializerMakesATextTab() {
        let file = OpenFile(url: URL(fileURLWithPath: "/tmp/project/a.swift"), text: "x", savedText: "x")
        XCTAssertEqual(file.kind, .text)
        XCTAssertFalse(file.isDirty)
    }

    func testATextTabIsDirtyWhenTextDivergesFromSavedText() {
        var file = OpenFile(url: URL(fileURLWithPath: "/tmp/project/a.swift"), text: "x", savedText: "x")
        file.text = "xy"
        XCTAssertTrue(file.isDirty)
    }

    func testUntitledTabHasNoURLAndAPlaceholderName() {
        let file = OpenFile()
        XCTAssertNil(file.url)
        XCTAssertEqual(file.displayName, "Untitled")
        XCTAssertEqual(file.kind, .text)
    }

    // MARK: - Viewer tabs

    func testViewerInitializerCarriesNoText() {
        let file = OpenFile(viewerFor: databaseURL)
        XCTAssertEqual(file.kind, .viewer)
        XCTAssertEqual(file.url, databaseURL)
        XCTAssertEqual(file.text, "")
        XCTAssertEqual(file.savedText, "")
        XCTAssertEqual(file.displayName, "app.sqlite")
    }

    func testViewerTabIsNeverDirtyEvenAfterTextIsAssigned() {
        var file = OpenFile(viewerFor: databaseURL)
        XCTAssertFalse(file.isDirty)
        file.text = "someone assigned this"
        XCTAssertFalse(file.isDirty, "a viewer tab is never dirty, whatever its text field holds")
        file.savedText = "and this"
        XCTAssertFalse(file.isDirty)
    }

    func testViewerInitializerHonorsAGivenIdentity() {
        let id = UUID()
        let file = OpenFile(id: id, viewerFor: databaseURL)
        XCTAssertEqual(file.id, id)
    }

    func testKindIsPartOfEquality() {
        let id = UUID()
        let viewer = OpenFile(id: id, viewerFor: databaseURL)
        let text = OpenFile(id: id, url: databaseURL)
        XCTAssertNotEqual(viewer, text)
    }
}
