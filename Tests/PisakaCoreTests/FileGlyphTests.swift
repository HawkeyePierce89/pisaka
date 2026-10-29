import XCTest
@testable import PisakaCore

/// `FileGlyph`'s one answer, the folder's; a file's icon is `FileTypeIcon`'s
/// (`FileTypeIconTests`).
final class FileGlyphTests: XCTestCase {
    func testFolders() {
        XCTAssertEqual(FileGlyph.forFolder(expanded: true), .folderOpen)
        XCTAssertEqual(FileGlyph.forFolder(expanded: false), .folder)
    }
}
