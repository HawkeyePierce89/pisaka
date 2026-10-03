import XCTest
@testable import PisakaCore

final class LocalChangesInlineDiffTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")
    private let stamp = FileStamp(byteCount: 12, modificationDate: Date(timeIntervalSince1970: 1_000))

    private func fingerprint(
        _ file: ChangedFile,
        root: URL? = nil,
        stamp: FileStamp?
    ) -> LocalChangesInlineDiff.Fingerprint {
        LocalChangesInlineDiff.Fingerprint(file: file, root: root ?? self.root, workingStamp: stamp)
    }

    private func needsRebuild(
        _ published: LocalChangesInlineDiff.Fingerprint?,
        _ current: LocalChangesInlineDiff.Fingerprint
    ) -> Bool {
        LocalChangesInlineDiff.needsRebuild(published: published, current: current)
    }

    func testNothingPublishedRebuilds() {
        let file = ChangedFile(path: "a.swift", status: .modified, headObject: "h1")
        XCTAssertTrue(needsRebuild(nil, fingerprint(file, stamp: stamp)))
    }

    func testAnEqualFullyKnownFingerprintSkips() {
        let file = ChangedFile(path: "a.swift", status: .modified, headObject: "h1")
        XCTAssertFalse(needsRebuild(fingerprint(file, stamp: stamp), fingerprint(file, stamp: stamp)))
    }

    func testEachFieldThatDiffersRebuilds() {
        let file = ChangedFile(path: "a.swift", status: .modified, headObject: "h1")
        let published = fingerprint(file, stamp: stamp)
        let otherStamp = FileStamp(byteCount: 13, modificationDate: stamp.modificationDate)
        let variants = [
            fingerprint(ChangedFile(path: "b.swift", status: .modified, headObject: "h1"), stamp: stamp),
            fingerprint(ChangedFile(path: "a.swift", status: .conflicted, headObject: "h1"), stamp: stamp),
            fingerprint(ChangedFile(path: "a.swift", status: .modified, headObject: "h2"), stamp: stamp),
            fingerprint(file, stamp: otherStamp),
            fingerprint(file, root: URL(fileURLWithPath: "/other"), stamp: stamp),
        ]
        for current in variants {
            XCTAssertTrue(needsRebuild(published, current), "\(current)")
        }
        let renamed = ChangedFile(path: "a.swift", status: .renamed, oldPath: "old.swift", headObject: "h1")
        let renamedElsewhere = ChangedFile(path: "a.swift", status: .renamed, oldPath: "older.swift", headObject: "h1")
        XCTAssertTrue(needsRebuild(fingerprint(renamed, stamp: stamp), fingerprint(renamedElsewhere, stamp: stamp)))
    }

    func testAnUnknownStampWithAWorkingSideRebuilds() {
        let file = ChangedFile(path: "a.swift", status: .modified, headObject: "h1")
        XCTAssertTrue(needsRebuild(fingerprint(file, stamp: nil), fingerprint(file, stamp: nil)))
    }

    func testAnUnknownHeadObjectWithAHeadSideRebuilds() {
        let file = ChangedFile(path: "a.swift", status: .modified)
        XCTAssertTrue(needsRebuild(fingerprint(file, stamp: stamp), fingerprint(file, stamp: stamp)))
        let conflicted = ChangedFile(path: "a.swift", status: .conflicted)
        XCTAssertTrue(needsRebuild(fingerprint(conflicted, stamp: stamp), fingerprint(conflicted, stamp: stamp)))
    }

    func testAddedAndUntrackedFilesNeedNoHeadObject() {
        // No HEAD side: only the working stamp has to be known.
        for status in [FileStatus.added, .untracked] {
            let file = ChangedFile(path: "new.swift", status: status)
            XCTAssertFalse(needsRebuild(fingerprint(file, stamp: stamp), fingerprint(file, stamp: stamp)), "\(status)")
            XCTAssertTrue(needsRebuild(fingerprint(file, stamp: nil), fingerprint(file, stamp: nil)), "\(status)")
        }
    }

    func testADeletedFileNeedsNoStamp() {
        // No working side: only the head object has to be known.
        let file = ChangedFile(path: "gone.swift", status: .deleted, headObject: "h1")
        XCTAssertFalse(needsRebuild(fingerprint(file, stamp: nil), fingerprint(file, stamp: nil)))
        let unknown = ChangedFile(path: "gone.swift", status: .deleted)
        XCTAssertTrue(needsRebuild(fingerprint(unknown, stamp: nil), fingerprint(unknown, stamp: nil)))
    }

    func testTheSidesEachStatusReads() {
        for status in FileStatus.allCases {
            let current = fingerprint(ChangedFile(path: "x", status: status), stamp: nil)
            XCTAssertEqual(current.hasWorkingSide, status != .deleted, "\(status)")
            XCTAssertEqual(current.hasHeadSide, ![.added, .untracked].contains(status), "\(status)")
        }
    }
}
