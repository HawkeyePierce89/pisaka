import XCTest
@testable import PisakaCore

final class GitStatusParserTests: XCTestCase {
    func testEmptyOutputIsNoChanges() {
        XCTAssertEqual(GitStatusParser.parse(""), [])
    }

    func testHeaderLinesAreIgnored() {
        let output = """
        # branch.oid abc123
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """
        XCTAssertEqual(GitStatusParser.parse(output), [])
    }

    func testModifiedInWorktree() {
        // `1` ordinary record, XY = ".M" (unmodified index, modified worktree).
        let output = "1 .M N... 100644 100644 100644 abc123 abc123 file.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "file.txt", status: .modified)]
        )
    }

    func testModifiedInIndex() {
        let output = "1 M. N... 100644 100644 100644 abc123 def456 staged.swift"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "staged.swift", status: .modified)]
        )
    }

    func testAdded() {
        let output = "1 A. N... 000000 100644 100644 0000000 def456 newfile.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "newfile.txt", status: .added)]
        )
    }

    func testDeleted() {
        let output = "1 D. N... 100644 000000 000000 ghi789 0000000 gone.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "gone.txt", status: .deleted)]
        )
    }

    func testDeletedInWorktree() {
        let output = "1 .D N... 100644 100644 000000 ghi789 ghi789 vanished.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "vanished.txt", status: .deleted)]
        )
    }

    func testRenamedRecordType2() {
        // `2` rename/copy record: after the hashes, `R100`, then
        // `<newPath>\t<oldPath>` in the default (non `-z`) format.
        let output = "2 R. N... 100644 100644 100644 jkl012 jkl012 R100 new.txt\told.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "new.txt", status: .renamed, oldPath: "old.txt")]
        )
    }

    func testCopiedRecordType2() {
        // `2` record with a copy (`C`) op: the new and old paths are
        // TAB-separated after the `C<score>` field. A copy's source (the old
        // path) is untouched, so it must NOT be modeled as a rename — that would
        // let a revert restore/`rm` the source and lose its local changes. It
        // maps to a plain addition of the copy (the new path), with no `oldPath`.
        let output = "2 C. N... 100644 100644 100644 jkl012 jkl012 C100 copy.txt\tsource.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "copy.txt", status: .added)]
        )
    }

    func testTruncatedOrdinaryRecordIsSkipped() {
        // Fewer than the 8 fixed fields before the path: drop the line, don't crash.
        let output = "1 .M N... 100644"
        XCTAssertEqual(GitStatusParser.parse(output), [])
    }

    func testUntrackedRecordWithNoPathIsSkipped() {
        XCTAssertEqual(GitStatusParser.parse("?"), [])
    }

    func testRenameRecordMissingTabSeparatorIsSkipped() {
        // A `2` record whose path field lacks the `\t` old/new separator is
        // malformed; it is dropped rather than producing a half-formed rename.
        let output = "2 R. N... 100644 100644 100644 a a R100 onlynewpath.txt"
        XCTAssertEqual(GitStatusParser.parse(output), [])
    }

    func testUntracked() {
        let output = "? untracked.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "untracked.txt", status: .untracked)]
        )
    }

    func testIgnoredRecordsAreSkipped() {
        // `!` ignored records are not local changes we surface.
        let output = "! build/output.o"
        XCTAssertEqual(GitStatusParser.parse(output), [])
    }

    func testPathWithSpaces() {
        let output = "1 .M N... 100644 100644 100644 abc abc my file name.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "my file name.txt", status: .modified)]
        )
    }

    func testRenamedPathsWithSpaces() {
        let output = "2 R. N... 100644 100644 100644 a a R090 new name.txt\told name.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "new name.txt", status: .renamed, oldPath: "old name.txt")]
        )
    }

    func testUntrackedPathWithSpaces() {
        let output = "? a new file.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "a new file.txt", status: .untracked)]
        )
    }

    func testUnicodePath() {
        let output = "1 .M N... 100644 100644 100644 abc abc файл.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "файл.txt", status: .modified)]
        )
    }

    func testNestedPath() {
        let output = "1 .M N... 100644 100644 100644 abc abc Sources/PisakaCore/file.swift"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "Sources/PisakaCore/file.swift", status: .modified)]
        )
    }

    func testMixedRecordsWithHeaders() {
        let output = """
        # branch.oid abc123
        # branch.head main
        1 .M N... 100644 100644 100644 a a Sources/app.swift
        1 A. N... 000000 100644 100644 0 b README.md
        2 R. N... 100644 100644 100644 c c R100 docs/new.md\tdocs/old.md
        1 D. N... 100644 000000 000000 d 0 obsolete.txt
        ? scratch.tmp
        ! ignored.log
        """
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [
                ChangedFile(path: "Sources/app.swift", status: .modified),
                ChangedFile(path: "README.md", status: .added),
                ChangedFile(path: "docs/new.md", status: .renamed, oldPath: "docs/old.md"),
                ChangedFile(path: "obsolete.txt", status: .deleted),
                ChangedFile(path: "scratch.tmp", status: .untracked),
            ]
        )
    }

    func testBlankLinesAreIgnored() {
        let output = "\n1 .M N... 100644 100644 100644 a a file.txt\n\n"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "file.txt", status: .modified)]
        )
    }

    func testUnmergedRecordIsConflicted() {
        // `u` unmerged record: XY = "UU" (both modified), then sub, three index
        // modes, the worktree mode, three blob hashes (:1/:2/:3), then the path.
        let output = "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflicted.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "conflicted.txt", status: .conflicted)]
        )
    }

    func testUnmergedRecordPathWithSpaces() {
        let output = "u UU N... 100644 100644 100644 100644 h1 h2 h3 my conflicted file.txt"
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [ChangedFile(path: "my conflicted file.txt", status: .conflicted)]
        )
    }

    func testUnmergedRecordInterleavedWithOtherRecords() {
        let output = """
        # branch.head main
        1 .M N... 100644 100644 100644 a a Sources/app.swift
        u UU N... 100644 100644 100644 100644 h1 h2 h3 merge/target.swift
        ? scratch.tmp
        """
        XCTAssertEqual(
            GitStatusParser.parse(output),
            [
                ChangedFile(path: "Sources/app.swift", status: .modified),
                ChangedFile(path: "merge/target.swift", status: .conflicted),
                ChangedFile(path: "scratch.tmp", status: .untracked),
            ]
        )
    }

    func testTruncatedUnmergedRecordIsSkipped() {
        // Fewer than the 10 fixed fields before the path: drop the line, don't crash.
        let output = "u UU N... 100644 100644"
        XCTAssertEqual(GitStatusParser.parse(output), [])
    }

    func testChangedFileIdentityIsPath() {
        let file = ChangedFile(path: "Sources/x.swift", status: .modified)
        XCTAssertEqual(file.id, "Sources/x.swift")
    }
}
