import XCTest
@testable import PisakaCore

final class BranchRefTests: XCTestCase {
    func testGroupingSplitsLocalAndRemote() {
        let refs = BranchRef.build(
            fromRefnames: [
                "refs/heads/main",
                "refs/heads/feature",
                "refs/remotes/origin/master",
                "refs/remotes/origin/dev",
            ],
            current: "main"
        )
        let locals = BranchRef.locals(refs)
        let remotes = BranchRef.remotes(refs)
        XCTAssertEqual(locals.map(\.shortName), ["feature", "main"])
        XCTAssertEqual(remotes.map(\.shortName), ["origin/dev", "origin/master"])
    }

    func testLocalsSortBeforeRemotesInBuild() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/remotes/origin/zzz", "refs/heads/aaa"],
            current: nil
        )
        XCTAssertFalse(refs[0].isRemote)
        XCTAssertTrue(refs[1].isRemote)
    }

    func testMarksCurrentByShortName() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/heads/main", "refs/heads/dev"],
            current: "dev"
        )
        XCTAssertEqual(refs.filter(\.isCurrent).map(\.shortName), ["dev"])
    }

    func testDetachedHeadMarksNoneCurrent() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/heads/main", "refs/heads/dev"],
            current: nil
        )
        XCTAssertTrue(refs.allSatisfy { !$0.isCurrent })
    }

    func testRemoteBranchNeverMarkedCurrent() {
        // Even if a remote's short name matches `current`, only a local is marked.
        let refs = BranchRef.build(
            fromRefnames: ["refs/remotes/origin/main"],
            current: "origin/main"
        )
        XCTAssertTrue(refs.allSatisfy { !$0.isCurrent })
    }

    func testDropsTags() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/heads/main", "refs/tags/v1.0", "refs/tags/release"],
            current: "main"
        )
        XCTAssertEqual(refs.map(\.shortName), ["main"])
    }

    func testDropsRemoteHeadSymref() {
        let refs = BranchRef.build(
            fromRefnames: [
                "refs/remotes/origin/HEAD",
                "refs/remotes/origin/master",
            ],
            current: nil
        )
        XCTAssertEqual(refs.map(\.shortName), ["origin/master"])
    }

    func testRemoteNameAndShortName() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/remotes/upstream/release/1.0"],
            current: nil
        )
        XCTAssertEqual(refs.count, 1)
        let r = refs[0]
        XCTAssertTrue(r.isRemote)
        XCTAssertEqual(r.remoteName, "upstream")
        XCTAssertEqual(r.shortName, "upstream/release/1.0")
        XCTAssertEqual(r.name, "refs/remotes/upstream/release/1.0")
    }

    func testLocalFields() {
        let refs = BranchRef.build(fromRefnames: ["refs/heads/main"], current: "main")
        let r = refs[0]
        XCTAssertFalse(r.isRemote)
        XCTAssertNil(r.remoteName)
        XCTAssertEqual(r.shortName, "main")
        XCTAssertEqual(r.name, "refs/heads/main")
        XCTAssertTrue(r.isCurrent)
    }

    func testFilterCaseInsensitiveSubstring() {
        let refs = BranchRef.build(
            fromRefnames: [
                "refs/heads/main",
                "refs/heads/feature-login",
                "refs/remotes/origin/Feature-Logout",
            ],
            current: nil
        )
        let filtered = BranchRef.filtered(refs, query: "feat")
        XCTAssertEqual(
            Set(filtered.map(\.shortName)),
            ["feature-login", "origin/Feature-Logout"]
        )
    }

    func testBlankFilterPassesEverything() {
        let refs = BranchRef.build(
            fromRefnames: ["refs/heads/main", "refs/heads/dev"],
            current: nil
        )
        XCTAssertEqual(BranchRef.filtered(refs, query: "   ").count, 2)
        XCTAssertEqual(BranchRef.filtered(refs, query: "").count, 2)
    }

    func testEmptyInput() {
        XCTAssertTrue(BranchRef.build(fromRefnames: [], current: nil).isEmpty)
    }

    func testDropsMalformedRefnames() {
        // An empty local short name, a remote with no branch component, and empty
        // remote/branch components are all skipped rather than yielding garbage
        // BranchRefs; a well-formed ref alongside them survives.
        let refs = BranchRef.build(
            fromRefnames: [
                "refs/heads/",            // empty local short name
                "refs/remotes/origin",    // no "/" after the remote name
                "refs/remotes//x",        // empty remote component
                "refs/remotes/origin/",   // empty branch component
                "refs/heads/main",        // valid
            ],
            current: nil
        )
        XCTAssertEqual(refs.map(\.shortName), ["main"])
    }
}
