import XCTest
@testable import PisakaCore

final class GitBlobTextTests: XCTestCase {

    // MARK: - The three cases

    func testNilDataIsAbsent() {
        XCTAssertEqual(GitBlobText.classify(nil), .absent)
    }

    func testOrdinaryTextIsText() {
        let data = Data("hello\nworld\n".utf8)
        XCTAssertEqual(GitBlobText.classify(data), .text("hello\nworld\n"))
    }

    func testEmptyDataIsEmptyText() {
        XCTAssertEqual(GitBlobText.classify(Data()), .text(""))
    }

    func testNULInHeadIsBinary() {
        var bytes = Array("abc".utf8)
        bytes.append(0)
        bytes.append(contentsOf: Array("def".utf8))
        XCTAssertEqual(GitBlobText.classify(Data(bytes)), .binary)
    }

    func testInvalidUTF8WithoutNULIsBinary() {
        // 0xFF is never a valid UTF-8 byte, and there is no NUL anywhere — so the
        // decode, not the NUL probe, is what must reject this.
        let data = Data([0x61, 0x62, 0xFF, 0x63])
        XCTAssertFalse(data.contains(0))
        XCTAssertEqual(GitBlobText.classify(data), .binary)
    }

    // MARK: - The probe window matches FileService

    func testNULBeyondProbeWindowIsText() {
        // The same boundary `FileService.readTextIfNotBinary` draws: only the first
        // `binaryProbeBytes` bytes are probed (git's own `buffer_is_binary`
        // window), so a NUL past it leaves the blob text.
        var bytes = [UInt8](repeating: 0x61, count: FileService.binaryProbeBytes)
        bytes.append(0)
        let classified = GitBlobText.classify(Data(bytes))
        guard case let .text(text) = classified else {
            return XCTFail("expected .text, got \(classified)")
        }
        XCTAssertEqual(text.unicodeScalars.count, FileService.binaryProbeBytes + 1)
        XCTAssertEqual(text.unicodeScalars.last, "\u{0}")
    }

    func testNULAtTheLastProbedByteIsBinary() {
        // Off-by-one guard on the other side of the same boundary.
        var bytes = [UInt8](repeating: 0x61, count: FileService.binaryProbeBytes - 1)
        bytes.append(0)
        XCTAssertEqual(GitBlobText.classify(Data(bytes)), .binary)
    }

    // MARK: - The separation of meanings

    func testAbsentAndBinaryAreDistinctAndNeitherExpressesTheOther() {
        // The whole reason `headBlob` returns `Data?` rather than `String?`:
        // "the path is absent from HEAD" is decided by git's exit code, while
        // "the bytes are not text" is decided here — an undecodable blob must
        // never collapse into absence (which would classify a file binary in HEAD
        // and text in the worktree as wholly *added*, with selectable units
        // against a falsely empty old side).
        XCTAssertNotEqual(GitBlobText.classify(nil), GitBlobText.classify(Data([0x00])))
        XCTAssertEqual(GitBlobText.classify(Data([0x00])), .binary)
        // An empty blob is text, not absence: a file that exists at HEAD and is
        // empty there is a real, ordinary case.
        XCTAssertNotEqual(GitBlobText.classify(Data()), .absent)
    }
}
