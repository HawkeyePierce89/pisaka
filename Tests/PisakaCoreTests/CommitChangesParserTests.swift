import XCTest
@testable import PisakaCore

final class CommitChangesParserTests: XCTestCase {
    func testEmptyOutputYieldsNoChanges() {
        XCTAssertEqual(CommitChangesParser.parse(""), [])
        XCTAssertEqual(CommitChangesParser.parse("\n\n"), [])
    }

    func testModifiedAddedDeleted() {
        let output = """
        M\tSources/A.swift
        A\tSources/B.swift
        D\tSources/C.swift
        """
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "Sources/A.swift", status: .modified),
            ChangedFile(path: "Sources/B.swift", status: .added),
            ChangedFile(path: "Sources/C.swift", status: .deleted)
        ])
    }

    func testTypeChangeMapsToModified() {
        XCTAssertEqual(
            CommitChangesParser.parse("T\tlink"),
            [ChangedFile(path: "link", status: .modified)]
        )
    }

    func testRenameCarriesOldPath() {
        let output = "R100\told/name.swift\tnew/name.swift"
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        ])
    }

    func testCopyReportedAsAddedOfNewPathOnly() {
        // A copy leaves the source untouched, so only the new path is reported, as
        // a plain addition with no oldPath (mirroring GitStatusParser).
        let output = "C75\tsrc/orig.swift\tsrc/copy.swift"
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "src/copy.swift", status: .added)
        ])
    }

    func testPathsWithSpacesSurvive() {
        let output = "M\tdir with spaces/file name.swift"
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "dir with spaces/file name.swift", status: .modified)
        ])
    }

    func testCRLFLineEndingsStripped() {
        let output = "M\tA.swift\r\nA\tB.swift\r\n"
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "A.swift", status: .modified),
            ChangedFile(path: "B.swift", status: .added)
        ])
    }

    func testMalformedRecordsSkipped() {
        // A status code with no path, an unknown code, and a rename missing its new
        // path are all dropped; the well-formed record survives.
        let output = """
        M
        Z\tweird.swift
        R100\tonly-old.swift
        A\tgood.swift
        """
        XCTAssertEqual(CommitChangesParser.parse(output), [
            ChangedFile(path: "good.swift", status: .added)
        ])
    }
}
