import XCTest
@testable import PisakaCore

final class GitFileModeTests: XCTestCase {
    // MARK: - Parsing `git ls-tree`

    func testParseTakesTheLeadingModeField() {
        XCTAssertEqual(
            GitFileMode.parse(lsTreeOutput: "100644 blob 0123abc\tsrc/a.swift\n"),
            "100644"
        )
    }

    func testParseReadsAnExecutableAndASymlinkMode() {
        XCTAssertEqual(
            GitFileMode.parse(lsTreeOutput: "100755 blob 0123abc\tscripts/run.sh\n"),
            "100755"
        )
        XCTAssertEqual(
            GitFileMode.parse(lsTreeOutput: "120000 blob 0123abc\tlink\n"),
            "120000"
        )
    }

    /// A path that is not in the tree makes `ls-tree` print nothing, and the
    /// caller must fall back to the working file rather than invent a mode.
    func testParseOfEmptyOrNonNumericOutputIsNil() {
        XCTAssertNil(GitFileMode.parse(lsTreeOutput: ""))
        XCTAssertNil(GitFileMode.parse(lsTreeOutput: "\n"))
        XCTAssertNil(GitFileMode.parse(lsTreeOutput: " 100644 blob 0123abc\ta"))
        XCTAssertNil(GitFileMode.parse(lsTreeOutput: "fatal: not a tree object"))
    }

    // MARK: - The working file's own mode

    func testWorktreeModeFromStatFacts() {
        XCTAssertEqual(GitFileMode.worktree(isSymlink: false, isExecutable: false), "100644")
        XCTAssertEqual(GitFileMode.worktree(isSymlink: false, isExecutable: true), "100755")
        XCTAssertEqual(GitFileMode.worktree(isSymlink: true, isExecutable: false), "120000")
        // A symlink's own permission bits are irrelevant — and on macOS `lstat`
        // reports them set — so the link wins.
        XCTAssertEqual(GitFileMode.worktree(isSymlink: true, isExecutable: true), "120000")
    }

    // MARK: - Reconciliation

    /// The whole reason the recorded mode is read at all: committing three lines
    /// of an executable script must not drop its exec bit, even when the working
    /// file's own permissions say otherwise (a checkout that lost them,
    /// `core.fileMode=false`).
    func testRecordedModeWinsWhenTheTypeIsUnchanged() {
        XCTAssertEqual(GitFileMode.reconciled(head: "100755", worktree: "100644"), "100755")
        XCTAssertEqual(GitFileMode.reconciled(head: "100644", worktree: "100755"), "100644")
        XCTAssertEqual(GitFileMode.reconciled(head: "120000", worktree: "120000"), "120000")
    }

    /// A typechange (git's `T`, which `GitStatusParser` maps to `.modified`)
    /// reaches the dialog as an ordinary selectable modification. Staging the
    /// assembled text under the recorded `120000` would record a **symlink whose
    /// target is the file's entire text** — silently, since git validates neither.
    func testALinkAtHEADReplacedByAFileTakesTheWorkingFilesType() {
        XCTAssertEqual(GitFileMode.reconciled(head: "120000", worktree: "100644"), "100644")
        XCTAssertEqual(GitFileMode.reconciled(head: "120000", worktree: "100755"), "100755")
    }

    /// The mirror image, and the one the naive "a typechange takes the working
    /// file's mode" rule gets wrong: a regular file at `HEAD` replaced by a
    /// **symlink** in the worktree. Both sides still classify as text (`HEAD`'s is
    /// the file's contents, the worktree's is the link's target string), so a
    /// partial selection is offered and assembled — and taking the worktree's
    /// `120000` would record a symlink whose target is that assembled mixture,
    /// reaching the very corruption the reconciliation exists to prevent from the
    /// other direction. A blob this app assembled line by line is never a link
    /// target, so a typechange to a link records a regular file.
    func testAFileAtHEADReplacedByALinkNeverRecordsALink() {
        XCTAssertEqual(GitFileMode.reconciled(head: "100644", worktree: "120000"), "100644")
        // The exec bit is not inherited across a typechange either: the working
        // file is a link, so "is it executable" has no answer to carry over.
        XCTAssertEqual(GitFileMode.reconciled(head: "100755", worktree: "120000"), "100644")
    }

    /// Two links whose *targets* differ is not a typechange, so the recorded mode
    /// still wins and the entry stays a link — a partial selection there assembles
    /// a target string, which is honestly a link's content.
    func testLinkToLinkIsNotATypechange() {
        XCTAssertEqual(GitFileMode.reconciled(head: "120000", worktree: "120000"), "120000")
    }
}
