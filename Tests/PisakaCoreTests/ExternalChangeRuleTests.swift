import Foundation
@testable import PisakaCore
import XCTest

final class ExternalChangeRuleTests: XCTestCase {
    private let stampA = FileStamp(byteCount: 5, modificationDate: Date(timeIntervalSince1970: 100))
    private let stampB = FileStamp(byteCount: 5, modificationDate: Date(timeIntervalSince1970: 200))

    /// The verdict, plus how many times the read was evaluated.
    private func judge(
        recorded: FileStamp?,
        current: FileStamp?,
        disk: ExternalDiskRead,
        savedText: String,
        text: String,
        holdingConflict: Bool = false
    ) -> (verdict: ExternalChangeVerdict, reads: Int) {
        var reads = 0
        let verdict = ExternalChangeRule.verdict(
            recorded: recorded,
            current: current,
            read: {
                reads += 1
                return disk
            },
            savedText: savedText,
            text: text,
            holdingConflict: holdingConflict
        )
        return (verdict, reads)
    }

    // MARK: - unchanged

    func testEqualStampsAreUnchangedWithoutReading() {
        // The disk would say otherwise; an equal stamp means it is never asked.
        let result = judge(recorded: stampA, current: stampA, disk: .text("other"), savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .unchanged)
        XCTAssertEqual(result.reads, 0)
    }

    func testEqualStampsNeverReadWhateverTheDiskOrBuffer() {
        for disk in [ExternalDiskRead.text("x"), .missing, .unreadable] {
            for text in ["base", "edit"] {
                let result = judge(recorded: stampA, current: stampA, disk: disk, savedText: "base", text: text)
                XCTAssertEqual(result.verdict, .unchanged, "\(disk) / \(text)")
                XCTAssertEqual(result.reads, 0, "\(disk) / \(text)")
            }
        }
    }

    // MARK: - unknown stamps

    func testUnknownCurrentStampReadsAndCompares() {
        let same = judge(recorded: stampA, current: nil, disk: .text("base"), savedText: "base", text: "base")
        XCTAssertEqual(same.verdict, .stampOnly)
        XCTAssertEqual(same.reads, 1)
        let changed = judge(recorded: stampA, current: nil, disk: .text("new"), savedText: "base", text: "base")
        XCTAssertEqual(changed.verdict, .reload)
    }

    func testBothStampsUnknownStillReads() {
        // nil == nil must not read as "unchanged": unknown is not a match.
        let result = judge(recorded: nil, current: nil, disk: .text("new"), savedText: "base", text: "base")
        XCTAssertEqual(result.verdict, .reload)
        XCTAssertEqual(result.reads, 1)
    }

    func testNoRecordedStampWithACurrentOneReads() {
        let result = judge(recorded: nil, current: stampA, disk: .text("new"), savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .conflict(diskText: "new"))
        XCTAssertEqual(result.reads, 1)
    }

    // MARK: - stampOnly

    func testTouchIdenticalCheckoutAndSameBytesCopyAreStampOnly() {
        // All three move the stamp and leave the bytes: only the date moves for a
        // touch, and a checkout or copy may move both size-equal fields.
        let touched = FileStamp(byteCount: 5, modificationDate: Date(timeIntervalSince1970: 101))
        let checkout = FileStamp(byteCount: 5, modificationDate: Date(timeIntervalSince1970: 300))
        let copy = FileStamp(byteCount: 5, modificationDate: nil)
        for current in [touched, checkout, copy] {
            let result = judge(recorded: stampA, current: current, disk: .text("hello"), savedText: "hello", text: "hello")
            XCTAssertEqual(result.verdict, .stampOnly, "\(current)")
            XCTAssertEqual(result.reads, 1)
        }
    }

    func testIdenticalContentUnderEditsIsStampOnly() {
        // The edits are the user's; the disk still holds their baseline.
        let result = judge(recorded: stampA, current: stampB, disk: .text("base"), savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .stampOnly)
    }

    // MARK: - reload

    func testCleanTabWithDifferentContentReloads() {
        let result = judge(recorded: stampA, current: stampB, disk: .text("new"), savedText: "base", text: "base")
        XCTAssertEqual(result.verdict, .reload)
    }

    func testCleanButStaleBufferReloads() {
        // Edited back to savedText: clean, so the different disk side reloads it.
        let result = judge(recorded: stampA, current: stampB, disk: .text("disk"), savedText: "base", text: "base")
        XCTAssertEqual(result.verdict, .reload)
    }

    // MARK: - holdingConflict

    func testAHeldCleanButStaleBufferIsAConflictNotAReload() {
        // The bar's Overwrite: the buffer is the user's side, clean or not.
        let result = judge(
            recorded: stampA, current: stampB, disk: .text("disk"), savedText: "base", text: "base",
            holdingConflict: true
        )
        XCTAssertEqual(result.verdict, .conflict(diskText: "disk"))
    }

    func testAHeldCleanBufferOverAnUnreadableFileIsAConflictNotLeftAlone() {
        let result = judge(
            recorded: stampA, current: stampB, disk: .unreadable, savedText: "base", text: "base",
            holdingConflict: true
        )
        XCTAssertEqual(result.verdict, .conflict(diskText: nil))
    }

    func testHoldingChangesNothingWhenTheDiskIsBackAtTheBaselineOrEqualsTheBuffer() {
        let back = judge(
            recorded: stampA, current: stampB, disk: .text("base"), savedText: "base", text: "base",
            holdingConflict: true
        )
        XCTAssertEqual(back.verdict, .stampOnly)
        let same = judge(
            recorded: stampA, current: stampB, disk: .text("edit"), savedText: "base", text: "edit",
            holdingConflict: true
        )
        XCTAssertEqual(same.verdict, .adoptBaseline)
    }

    // MARK: - adoptBaseline

    func testBufferAlreadyEqualToDiskAdoptsTheBaseline() {
        let result = judge(recorded: stampA, current: stampB, disk: .text("edit"), savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .adoptBaseline)
    }

    // MARK: - conflict

    func testDirtyTabWithDifferentContentIsAConflictCarryingTheDiskText() {
        let result = judge(recorded: stampA, current: stampB, disk: .text("disk"), savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .conflict(diskText: "disk"))
    }

    func testUnreadableIsAConflictWhenDirty() {
        let result = judge(recorded: stampA, current: stampB, disk: .unreadable, savedText: "base", text: "edit")
        XCTAssertEqual(result.verdict, .conflict(diskText: nil))
    }

    // MARK: - leaveAlone

    func testUnreadableIsLeftAloneWhenClean() {
        let result = judge(recorded: stampA, current: stampB, disk: .unreadable, savedText: "base", text: "base")
        XCTAssertEqual(result.verdict, .leaveAlone)
    }

    // MARK: - missing

    func testMissingNeverYieldsAConflict() {
        for (recorded, current) in [(stampA, stampB), (stampA, nil), (nil, nil)] as [(FileStamp?, FileStamp?)] {
            for text in ["base", "edit", ""] {
                let result = judge(recorded: recorded, current: current, disk: .missing, savedText: "base", text: text)
                XCTAssertEqual(result.verdict, .missing, "\(String(describing: current)) / \(text)")
            }
        }
    }
}
