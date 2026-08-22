import XCTest
@testable import PisakaCore

final class MergeDocumentTests: XCTestCase {
    // A document with stable | conflict | stable, used by most tests.
    private func sampleDocument(trailingNewline: Bool = true) -> MergeDocument {
        let regions: [MergeRegion] = [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b"], ours: ["X"], theirs: ["Y"])),
            .stable(["c"])
        ]
        return MergeDocument(regions: regions, trailingNewline: trailingNewline)
    }

    // MARK: - Construction / counts

    func testNewDocumentStartsAllConflictsUnresolved() {
        let doc = sampleDocument()
        XCTAssertEqual(doc.conflictCount, 1)
        XCTAssertEqual(doc.unresolvedCount, 1)
        XCTAssertFalse(doc.isFullyResolved)
        XCTAssertEqual(doc.resolution(at: 0), .unresolved)
    }

    func testNoConflictsIsFullyResolved() {
        let doc = MergeDocument(regions: [.stable(["a", "b"])])
        XCTAssertEqual(doc.conflictCount, 0)
        XCTAssertEqual(doc.unresolvedCount, 0)
        XCTAssertTrue(doc.isFullyResolved)
        XCTAssertEqual(doc.resolvedText, "a\nb\n")
    }

    // MARK: - resolvedText per Resolution

    func testResolvedTextUnresolvedEmitsConflictMarkers() {
        let doc = sampleDocument()
        XCTAssertEqual(
            doc.resolvedText,
            "a\n<<<<<<< ours\nX\n=======\nY\n>>>>>>> theirs\nc\n"
        )
    }

    func testResolvedTextOurs() {
        var doc = sampleDocument()
        doc.setResolution(.ours, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nX\nc\n")
        XCTAssertTrue(doc.isFullyResolved)
        XCTAssertEqual(doc.unresolvedCount, 0)
    }

    func testResolvedTextTheirs() {
        var doc = sampleDocument()
        doc.setResolution(.theirs, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nY\nc\n")
    }

    func testResolvedTextBothOursFirst() {
        var doc = sampleDocument()
        doc.setResolution(.bothOursFirst, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nX\nY\nc\n")
    }

    func testResolvedTextBothTheirsFirst() {
        var doc = sampleDocument()
        doc.setResolution(.bothTheirsFirst, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nY\nX\nc\n")
    }

    func testResolvedTextCustom() {
        var doc = sampleDocument()
        doc.setResolution(.custom("M1\nM2"), at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nM1\nM2\nc\n")
    }

    func testResolvedTextCustomEmptyDeletesTheSpan() {
        var doc = sampleDocument()
        doc.setResolution(.custom(""), at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nc\n")
    }

    // MARK: - Trailing newline

    func testResolvedTextNoTrailingNewline() {
        var doc = sampleDocument(trailingNewline: false)
        doc.setResolution(.ours, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nX\nc")
    }

    func testEmptyDocumentResolvedTextIsEmpty() {
        let doc = MergeDocument(regions: [], trailingNewline: true)
        XCTAssertEqual(doc.resolvedText, "")
    }

    // MARK: - Multiple conflicts resolved independently

    func testMultipleConflictsResolvedIndependently() {
        let regions: [MergeRegion] = [
            .stable(["top"]),
            .conflict(ConflictHunk(base: ["b1"], ours: ["O1"], theirs: ["T1"])),
            .stable(["mid"]),
            .conflict(ConflictHunk(base: ["b2"], ours: ["O2"], theirs: ["T2"])),
            .stable(["end"])
        ]
        var doc = MergeDocument(regions: regions)
        XCTAssertEqual(doc.conflictCount, 2)
        XCTAssertEqual(doc.unresolvedCount, 2)

        doc.setResolution(.ours, at: 0)
        XCTAssertEqual(doc.unresolvedCount, 1)
        XCTAssertFalse(doc.isFullyResolved)

        doc.setResolution(.theirs, at: 1)
        XCTAssertEqual(doc.unresolvedCount, 0)
        XCTAssertTrue(doc.isFullyResolved)
        XCTAssertEqual(doc.resolvedText, "top\nO1\nmid\nT2\nend\n")
    }

    // MARK: - Add/add and modify/delete (empty spans)

    func testAddAddConflictBothSidesContribute() {
        // Empty base; both sides added different content.
        let doc0 = MergeDocument(regions: [
            .conflict(ConflictHunk(base: [], ours: ["O"], theirs: ["T"]))
        ])
        var doc = doc0
        doc.setResolution(.bothOursFirst, at: 0)
        XCTAssertEqual(doc.resolvedText, "O\nT\n")
    }

    func testModifyDeleteOneEmptySide() {
        // theirs deleted the span (empty), ours modified it.
        var doc = MergeDocument(regions: [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b"], ours: ["B"], theirs: [])),
            .stable(["c"])
        ])
        doc.setResolution(.theirs, at: 0) // accept the deletion
        XCTAssertEqual(doc.resolvedText, "a\nc\n")
        doc.setResolution(.ours, at: 0)
        XCTAssertEqual(doc.resolvedText, "a\nB\nc\n")
    }

    // MARK: - Setter bounds

    func testSetResolutionOutOfRangeIsIgnored() {
        var doc = sampleDocument()
        doc.setResolution(.ours, at: 5)
        XCTAssertEqual(doc.resolution(at: 0), .unresolved)
        XCTAssertEqual(doc.unresolvedCount, 1)
    }
}
