import XCTest
@testable import PisakaCore

/// D44's record and the settings page's derivation over it: the ring's bound,
/// the sentence, and which rows carry a status.
@MainActor
final class LSPServerFailureRecordTests: XCTestCase {

    // MARK: - Ring

    func testTheRingKeepsTheNewestBytesAtExactlyItsBound() {
        var record = LSPServerFailureRecord(serverID: "sourcekit-lsp", root: "/tmp/p")
        let capacity = LSPServerFailureRecord.capacity
        let first = Data(repeating: UInt8(ascii: "a"), count: capacity - 10)
        let second = Data(repeating: UInt8(ascii: "b"), count: 25)

        record.append(first, sequence: 1)
        XCTAssertEqual(record.tail.count, capacity - 10, "under the bound nothing is dropped")

        record.append(second, sequence: 2)
        XCTAssertEqual(record.tail.count, capacity)
        XCTAssertEqual(record.tail.suffix(25), second, "the newest bytes survive whole")
        XCTAssertEqual(record.tail.prefix(capacity - 25), first.suffix(capacity - 25))
    }

    func testAChunkLargerThanTheRingKeepsOnlyItsOwnNewestBytes() {
        var record = LSPServerFailureRecord(serverID: "gopls", root: "/tmp/p")
        record.append(Data("old".utf8), sequence: 1)
        var big = Data(repeating: UInt8(ascii: "x"), count: LSPServerFailureRecord.capacity)
        big.append(Data("END".utf8))

        record.append(big, sequence: 2)

        XCTAssertEqual(record.tail.count, LSPServerFailureRecord.capacity)
        XCTAssertTrue(record.text.hasSuffix("END"))
        XCTAssertFalse(record.text.contains("old"))
    }

    func testInvalidUTF8IsDecodedLossilyRatherThanToNothing() {
        var record = LSPServerFailureRecord(serverID: "gopls", root: "/tmp/p")
        record.append(Data([0xE2, 0x82]) + Data("panic".utf8), sequence: 1)
        XCTAssertTrue(record.text.hasSuffix("panic"))
        XCTAssertTrue(record.text.contains("\u{FFFD}"))
    }

    // MARK: - Sentence

    func testTheStatusSentenceNamesTheCountTheRetirementAndTheExit() {
        var record = LSPServerFailureRecord(serverID: "sourcekit-lsp", root: "/tmp/p")
        XCTAssertFalse(record.hasFailed)

        record.noteFailure(count: 1, retired: false, sequence: 1)
        XCTAssertEqual(record.statusSentence, "Restarted after 1 failure")

        record.noteExit(code: 1, sequence: 2)
        record.noteFailure(count: 4, retired: true, sequence: 3)
        XCTAssertEqual(record.statusSentence, "Stopped after 4 failures · exit code 1")

        record.noteExit(code: -9, sequence: 4)
        XCTAssertEqual(record.statusSentence, "Stopped after 4 failures · signal 9")
    }

    // MARK: - Rows

    private func failed(
        _ serverID: String,
        root: String = "/tmp/p",
        count: Int = 1,
        sequence: Int
    ) -> LSPServerFailureRecord {
        var record = LSPServerFailureRecord(serverID: serverID, root: root)
        record.noteFailure(count: count, retired: count > 3, sequence: sequence)
        return record
    }

    func testSeveralRootsForOneServerResolveToTheNewestRecord() {
        let model = LSPServerFailureModel()
        model.receive([
            failed("gopls", root: "/a", count: 4, sequence: 9),
            failed("gopls", root: "/b", count: 1, sequence: 3),
        ])
        XCTAssertEqual(model.status(forServerID: "gopls")?.root, "/a")
        XCTAssertNil(model.status(forServerID: "rust-analyzer"))
    }

    func testAServerWithoutARowGetsAStatusOnlyRowOnlyWhileARecordExists() {
        let model = LSPServerFailureModel()
        let rowIDs: Set<String> = ["gopls", "rust-analyzer", "typescript-language-server"]
        XCTAssertTrue(model.statusOnlyRows(excludingServerIDs: rowIDs).isEmpty)

        model.receive([failed("sourcekit-lsp", sequence: 1), failed("gopls", sequence: 2)])
        XCTAssertEqual(
            model.statusOnlyRows(excludingServerIDs: rowIDs).map(\.serverID),
            ["sourcekit-lsp"],
            "a server with a row of its own carries its status there, not twice"
        )

        model.receive([failed("gopls", sequence: 2)])
        XCTAssertTrue(model.statusOnlyRows(excludingServerIDs: rowIDs).isEmpty)
    }

    func testARecordThatIsNotAboutAFailureIsNotShown() {
        let model = LSPServerFailureModel()
        var chatty = LSPServerFailureRecord(serverID: "sourcekit-lsp", root: "/tmp/p")
        chatty.append(Data("indexing…".utf8), sequence: 1)
        model.receive([chatty])
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertTrue(model.statusOnlyRows(excludingServerIDs: []).isEmpty)
    }
}
