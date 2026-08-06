import XCTest
@testable import PisakaCore

final class DiffWindowTitleTests: XCTestCase {
    func testLocalChangesTitle() {
        XCTAssertEqual(
            DiffWindowTitle.localChanges(path: "Sources/PisakaCore/BottomPanel.swift"),
            "Sources/PisakaCore/BottomPanel.swift — Local Changes"
        )
    }

    func testCommitTitleTruncatesFullHash() {
        let title = DiffWindowTitle.commit(
            path: "README.md",
            hash: "9d6521a1234567890abcdef",
            subject: "add plan"
        )
        XCTAssertEqual(title, "README.md — 9d6521a add plan")
    }

    func testCommitTitleWithAlreadyShortHash() {
        let title = DiffWindowTitle.commit(
            path: "a/b.swift",
            hash: "abc12",
            subject: "fix"
        )
        XCTAssertEqual(title, "a/b.swift — abc12 fix")
    }

    func testCommitTitleHashTruncatedToSevenChars() {
        let title = DiffWindowTitle.commit(path: "f.txt", hash: "0123456789", subject: "s")
        // Short hash is the first seven characters.
        XCTAssertEqual(title, "f.txt — 0123456 s")
    }

    func testCommitTitleHashExactlyShortLengthIsKeptWhole() {
        // Boundary: a hash of exactly `shortHashLength` characters is kept whole
        // (prefix returns the entire string), pinning the off-by-one truncation.
        let title = DiffWindowTitle.commit(path: "f.txt", hash: "0123456", subject: "s")
        XCTAssertEqual(title, "f.txt — 0123456 s")
    }
}
