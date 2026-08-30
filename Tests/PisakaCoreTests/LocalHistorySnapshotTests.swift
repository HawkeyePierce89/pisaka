import XCTest
@testable import PisakaCore

/// The event tag is on-disk vocabulary, not a display detail: it is one of the
/// three fields `LocalHistoryLayout` encodes into a snapshot's file name, so a
/// tag that changes orphans every snapshot already written under the old one.
/// These tests pin the tag set and the round-trip so that consequence is a
/// deliberate edit rather than a rename nobody noticed.
final class LocalHistorySnapshotTests: XCTestCase {

    // MARK: - Events

    func testEveryEventRoundTripsThroughItsTag() {
        for event in LocalHistoryEvent.allCases {
            XCTAssertEqual(LocalHistoryEvent(tag: event.tag), event, "tag \(event.tag) did not round-trip")
        }
    }

    func testTheTagSetIsExactlyTheDocumentedVocabulary() {
        XCTAssertEqual(
            Set(LocalHistoryEvent.allCases.map(\.tag)),
            ["save", "replace", "revert", "merge", "branch", "commit", "restore", "rename"]
        )
    }

    /// `-` is the file name's field separator and the stamp is ASCII digits, so a
    /// tag carrying either would make its own names unparseable.
    func testNoTagCanCollideWithTheNameGrammar() {
        for event in LocalHistoryEvent.allCases {
            XCTAssertFalse(event.tag.contains("-"), "\(event.tag) contains the field separator")
            XCTAssertFalse(event.tag.contains("."), "\(event.tag) contains the extension separator")
            XCTAssertFalse(event.tag.isEmpty)
            XCTAssertEqual(event.tag, event.tag.lowercased())
        }
    }

    func testAnUnknownTagIsNotAnEvent() {
        XCTAssertNil(LocalHistoryEvent(tag: "rebase"))
        XCTAssertNil(LocalHistoryEvent(tag: "Save"))
        XCTAssertNil(LocalHistoryEvent(tag: ""))
    }

    /// The window renders these; two events sharing a title would make two kinds
    /// of revision indistinguishable in the list.
    func testEveryEventHasItsOwnNonEmptyTitle() {
        let titles = LocalHistoryEvent.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, LocalHistoryEvent.allCases.count)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertEqual(LocalHistoryEvent.save.title, "Save")
        XCTAssertEqual(LocalHistoryEvent.replace.title, "Before Replace All")
        XCTAssertEqual(LocalHistoryEvent.revert.title, "Before Revert")
        XCTAssertEqual(LocalHistoryEvent.merge.title, "Before Merge Apply")
        XCTAssertEqual(LocalHistoryEvent.branch.title, "Before Branch Change")
        XCTAssertEqual(LocalHistoryEvent.commit.title, "Before Commit")
        XCTAssertEqual(LocalHistoryEvent.restore.title, "Before Restore")
        XCTAssertEqual(LocalHistoryEvent.rename.title, "Before Rename")
    }

    /// Only `save` records something that happened; every other event records
    /// what a file looked like *before* something else ran.
    func testEveryPreOperationEventSaysBefore() {
        for event in LocalHistoryEvent.allCases where event != .save {
            XCTAssertTrue(event.title.hasPrefix("Before "), "\(event.tag) titled \(event.title)")
        }
    }

    // MARK: - Ordering

    func testSortingIsNewestFirst() {
        let old = snapshot(milliseconds: 1_000, event: .save)
        let middle = snapshot(milliseconds: 2_000, event: .commit)
        let new = snapshot(milliseconds: 3_000, event: .branch)

        XCTAssertEqual(
            LocalHistorySnapshot.sortedNewestFirst([middle, old, new]).map(\.timestamp),
            [new, middle, old].map(\.timestamp)
        )
    }

    /// Two captures of one file can share a millisecond (a pre-operation capture
    /// stores several files in one pass). Without a total order the listing would
    /// reshuffle between two reads of an unchanged directory and the window's
    /// selection would jump.
    func testAnExactTimestampTieBreaksOnTheFileNameDescending() {
        let first = LocalHistorySnapshot(
            fileName: "a.snapshot",
            timestamp: Date(timeIntervalSince1970: 5),
            event: .save,
            contentHash: "0000000000000000"
        )
        let second = LocalHistorySnapshot(
            fileName: "b.snapshot",
            timestamp: Date(timeIntervalSince1970: 5),
            event: .save,
            contentHash: "1111111111111111"
        )

        XCTAssertEqual(LocalHistorySnapshot.sortedNewestFirst([first, second]).map(\.fileName), ["b.snapshot", "a.snapshot"])
        XCTAssertEqual(LocalHistorySnapshot.sortedNewestFirst([second, first]).map(\.fileName), ["b.snapshot", "a.snapshot"])
    }

    func testSortingEmptyAndSingleInputsIsANoOp() {
        XCTAssertEqual(LocalHistorySnapshot.sortedNewestFirst([]), [])
        let only = snapshot(milliseconds: 42, event: .restore)
        XCTAssertEqual(LocalHistorySnapshot.sortedNewestFirst([only]), [only])
    }

    /// Equality is over every field, because the store compares a parsed listing
    /// against what it just wrote.
    func testEqualityCoversEveryField() {
        let base = snapshot(milliseconds: 7, event: .save)
        XCTAssertEqual(base, snapshot(milliseconds: 7, event: .save))
        XCTAssertNotEqual(base, snapshot(milliseconds: 8, event: .save))
        XCTAssertNotEqual(base, snapshot(milliseconds: 7, event: .merge))
        XCTAssertNotEqual(
            base,
            LocalHistorySnapshot(
                fileName: base.fileName,
                timestamp: base.timestamp,
                event: base.event,
                contentHash: "ffffffffffffffff"
            )
        )
    }

    // MARK: - Helpers

    private func snapshot(milliseconds: Int, event: LocalHistoryEvent) -> LocalHistorySnapshot {
        let timestamp = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let hash = "0123456789abcdef"
        return LocalHistorySnapshot(
            fileName: LocalHistoryLayout.snapshotFileName(timestamp: timestamp, event: event, contentHash: hash),
            timestamp: timestamp,
            event: event,
            contentHash: hash
        )
    }
}
