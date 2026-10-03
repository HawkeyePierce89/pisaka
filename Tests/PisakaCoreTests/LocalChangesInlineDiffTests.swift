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

    // MARK: - Content: binary and oversized sides are refused

    /// An in-memory working copy that counts its reads.
    private final class Files: FileServicing {
        var text: String?
        var symlinkTarget: String?
        private(set) var reads = 0
        func read(url: URL) throws -> String {
            reads += 1
            guard let text else { throw CocoaError(.fileReadNoSuchFile) }
            return text
        }
        func write(_ text: String, to url: URL) throws {}
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? { symlinkTarget }
        func isExecutableFile(at url: URL) -> Bool { false }
    }

    private let cap = LocalChangesInlineDiff.maxSideBytes
    private let modified = ChangedFile(path: "a.swift", status: .modified)

    private func working(_ files: Files, file: ChangedFile? = nil, stamp: FileStamp? = nil) -> LocalChangesInlineDiff.Side {
        LocalChangesInlineDiff.workingSide(
            for: file ?? modified,
            url: root.appendingPathComponent("a.swift"),
            stamp: stamp,
            fileService: files
        )
    }

    @MainActor
    func testTheCapIsTheCommitDialogsSelectableFileCap() {
        XCTAssertEqual(LocalChangesInlineDiff.maxSideBytes, 1 << 20)
        XCTAssertEqual(LocalChangesInlineDiff.maxSideBytes, CommitDialogModel.maxSelectableFileBytes)
    }

    func testABinaryHeadSideIsBinary() {
        let head = LocalChangesInlineDiff.headSide(Data([0x61, 0x00, 0x62]))
        XCTAssertEqual(head, .binary)
        XCTAssertEqual(LocalChangesInlineDiff.content(head: head, working: .text("a\n")), .binary)
    }

    func testANonUTF8HeadSideIsBinary() {
        XCTAssertEqual(LocalChangesInlineDiff.headSide(Data([0xFF, 0xFE, 0x41])), .binary)
    }

    func testABinaryWorkingSideIsBinary() {
        let files = Files()
        files.text = "a\u{0}b"
        let side = working(files)
        XCTAssertEqual(side, .binary)
        XCTAssertTrue(side.isRefusal)
        XCTAssertEqual(LocalChangesInlineDiff.content(head: .text("a\n"), working: side), .binary)
    }

    func testAnOverCapWorkingStampIsTooLargeWithNoRead() {
        let files = Files()
        files.text = "small"
        let side = working(files, stamp: FileStamp(byteCount: cap + 1, modificationDate: nil))
        XCTAssertEqual(side, .tooLarge)
        XCTAssertEqual(files.reads, 0)
        XCTAssertEqual(LocalChangesInlineDiff.content(head: .text("a\n"), working: side), .tooLarge)
    }

    func testAnOverCapHeadSideIsTooLarge() {
        let head = LocalChangesInlineDiff.headSide(Data(repeating: 0x61, count: cap + 1))
        XCTAssertEqual(head, .tooLarge)
        XCTAssertEqual(LocalChangesInlineDiff.content(head: head, working: .text("a\n")), .tooLarge)
    }

    func testExactlyAtTheCapIsText() {
        let atCap = String(repeating: "a", count: cap)
        XCTAssertEqual(LocalChangesInlineDiff.headSide(Data(atCap.utf8)), .text(atCap))
        let files = Files()
        files.text = atCap
        XCTAssertEqual(working(files, stamp: FileStamp(byteCount: cap, modificationDate: nil)), .text(atCap))
        XCTAssertEqual(files.reads, 1)
    }

    func testTextOnBothSidesIsRows() {
        let files = Files()
        files.text = "new\n"
        let content = LocalChangesInlineDiff.content(
            head: LocalChangesInlineDiff.headSide(Data("old\n".utf8)),
            working: working(files)
        )
        XCTAssertEqual(content, .rows(LineDiff.rows(old: "old\n", new: "new\n")))
    }

    func testOneSidedFilesDiffAgainstAnEmptySide() {
        XCTAssertEqual(LocalChangesInlineDiff.headSide(nil), .absent)
        XCTAssertEqual(
            LocalChangesInlineDiff.content(head: .absent, working: .text("a\n")),
            .rows(LineDiff.rows(old: "", new: "a\n"))
        )
        let files = Files()
        files.text = "ignored"
        let deleted = ChangedFile(path: "a.swift", status: .deleted)
        XCTAssertEqual(working(files, file: deleted), .absent)
        XCTAssertEqual(files.reads, 0)
        XCTAssertEqual(
            LocalChangesInlineDiff.content(head: .text("x\n"), working: .absent),
            .rows(LineDiff.rows(old: "x\n", new: ""))
        )
    }

    func testASymlinkIsItsTargetStringAndAFailedReadIsAbsent() {
        let files = Files()
        files.symlinkTarget = "/elsewhere"
        XCTAssertEqual(working(files), .text("/elsewhere"))
        XCTAssertEqual(files.reads, 0)
        XCTAssertEqual(working(Files()), .absent)
    }
}
