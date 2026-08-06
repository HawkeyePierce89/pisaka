import XCTest
@testable import PisakaCore

/// Covers the pure "is this FSEvents batch worth re-reading the project tree"
/// decision. The watcher itself (`Sources/Pisaka/ProjectWatcher.swift`, macOS-only)
/// is thin view-layer IO and untested by project convention — every decision it
/// makes about a batch lives here.
final class TreeRefreshFilterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/dev/project")

    private func shouldRefresh(_ paths: [String]) -> Bool {
        TreeRefreshFilter.shouldRefresh(changedPaths: paths, root: root)
    }

    // MARK: - The `.git` rule (live under the watcher's dir-level flags)

    func testBatchOfOnlyGitInternalsIsIgnored() {
        XCTAssertFalse(shouldRefresh([
            "/Users/dev/project/.git",
            "/Users/dev/project/.git/objects/ab",
            "/Users/dev/project/.git/refs/heads",
        ]))
    }

    func testMixedBatchWithOneRealPathRefreshes() {
        XCTAssertTrue(shouldRefresh([
            "/Users/dev/project/.git/objects",
            "/Users/dev/project/src",
        ]))
    }

    /// Only the *opened root's* top-level `.git` is service noise; a nested
    /// repository checked out inside the project is part of the visible tree.
    func testNestedForeignGitDirectoryRefreshes() {
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/deps/foo/.git"]))
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/deps/foo/.git/objects"]))
    }

    /// The match must be same-or-descendant, not a raw string prefix: `.gitignore`
    /// and `.github` are ordinary, visible entries that share `.git`'s prefix.
    func testGitPrefixedSiblingsAreNotTreatedAsGitInternals() {
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/.gitignore"]))
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/.github"]))
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/.github/workflows"]))
    }

    func testGitDirectoryWithTrailingSlashIsIgnored() {
        // FSEvents reports directories with a trailing slash.
        XCTAssertFalse(shouldRefresh([
            "/Users/dev/project/.git/",
            "/Users/dev/project/.git/refs/heads/",
        ]))
    }

    // MARK: - The `.DS_Store` rule (dormant under the current flags)

    // NOTE: These cases assert *file-level-event* behavior. The watcher creates
    // its stream without `kFSEventStreamCreateFlagFileEvents`, so a `.DS_Store`
    // path never actually arrives — a Finder write to `root/.DS_Store` is reported
    // as the containing directory `root`, which passes the filter and produces one
    // harmless bump (the listing excludes `.DS_Store`, so nothing visibly moves).
    // They guard a dormant defense-in-depth branch kept for a possible future
    // switch to file-level events, not a production path — see the doc comment on
    // `TreeRefreshFilter`.

    func testDSStoreOnlyBatchIsIgnored() {
        XCTAssertFalse(shouldRefresh(["/Users/dev/project/.DS_Store"]))
    }

    func testNestedDSStoreOnlyBatchIsIgnored() {
        XCTAssertFalse(shouldRefresh(["/Users/dev/project/src/nested/.DS_Store"]))
    }

    func testDSStoreWithTrailingSlashIsIgnored() {
        XCTAssertFalse(shouldRefresh(["/Users/dev/project/src/.DS_Store/"]))
    }

    func testDSStoreMixedWithARealPathRefreshes() {
        XCTAssertTrue(shouldRefresh([
            "/Users/dev/project/.DS_Store",
            "/Users/dev/project/src/main.swift",
        ]))
    }

    // MARK: - The root itself and the outside-the-root rule

    func testPathEqualToRootRefreshes() {
        XCTAssertTrue(shouldRefresh(["/Users/dev/project"]))
    }

    func testRootWithTrailingSlashRefreshes() {
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/"]))
    }

    func testPathOutsideRootIsIgnored() {
        XCTAssertFalse(shouldRefresh(["/Users/dev/other/src"]))
        XCTAssertFalse(shouldRefresh(["/tmp"]))
    }

    /// A sibling directory sharing the root's name prefix is outside the project —
    /// the containment check must normalize rather than `hasPrefix` the raw string.
    func testSiblingSharingRootNamePrefixIsIgnored() {
        XCTAssertFalse(shouldRefresh(["/Users/dev/project-backup/src"]))
    }

    func testInsideTheRootWithTrailingSlashRefreshes() {
        XCTAssertTrue(shouldRefresh(["/Users/dev/project/src/"]))
    }

    /// The filesystem root is the one root whose `.git` path must not be assembled
    /// by naive concatenation (`"/" + "/.git"` → `//.git`, which would stop matching
    /// git's own writes).
    func testFilesystemRootStillIgnoresItsGitDirectory() {
        let fsRoot = URL(fileURLWithPath: "/", isDirectory: true)
        XCTAssertFalse(
            TreeRefreshFilter.shouldRefresh(changedPaths: ["/.git/objects"], root: fsRoot)
        )
        XCTAssertTrue(
            TreeRefreshFilter.shouldRefresh(changedPaths: ["/src"], root: fsRoot)
        )
    }

    // MARK: - Canonical-root contract

    /// The filter is disk-free string comparison, so it cannot resolve symlinks:
    /// FSEvents reports realpath-spelled paths, and a root spelled through a symlink
    /// matches none of them. `ProjectWatcher.start` canonicalizes the root before it
    /// gets here precisely because of this — pinned so the requirement stays visible
    /// rather than implicit (without it, auto-refresh silently never fires for a
    /// project opened through a symlink).
    func testNonCanonicalRootMatchesNoResolvedPath() {
        XCTAssertFalse(
            TreeRefreshFilter.shouldRefresh(
                changedPaths: ["/Volumes/Data/dev/project/src"],
                root: URL(fileURLWithPath: "/Users/dev/link-to-project")
            )
        )
    }

    /// The counterpart: with the canonical root the watcher actually passes, the very
    /// same resolved paths are accepted (and its `.git` still filtered).
    func testCanonicalRootMatchesResolvedPaths() {
        let resolvedRoot = URL(fileURLWithPath: "/Volumes/Data/dev/project")
        XCTAssertTrue(
            TreeRefreshFilter.shouldRefresh(
                changedPaths: ["/Volumes/Data/dev/project/src"],
                root: resolvedRoot
            )
        )
        XCTAssertFalse(
            TreeRefreshFilter.shouldRefresh(
                changedPaths: ["/Volumes/Data/dev/project/.git/refs/heads"],
                root: resolvedRoot
            )
        )
    }

    // MARK: - Degenerate input

    func testEmptyBatchDoesNotRefresh() {
        XCTAssertFalse(shouldRefresh([]))
    }

    func testBatchOfOnlyIgnoredKindsDoesNotRefresh() {
        XCTAssertFalse(shouldRefresh([
            "/Users/dev/project/.git/objects",
            "/Users/dev/project/.DS_Store",
            "/Users/dev/other/elsewhere",
        ]))
    }

    func testEmptyPathStringIsIgnored() {
        XCTAssertFalse(shouldRefresh([""]))
    }
}
