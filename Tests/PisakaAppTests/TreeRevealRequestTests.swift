#if os(macOS)
import XCTest
import PisakaCore
@testable import Pisaka

/// `TreeRevealRequest` matches the tree's rows by standardized path: a listing
/// spells a directory with a trailing slash and the rule's appended components
/// may not, and the two must still agree. A listing is matched by entry name
/// and kind, because it may spell its entries under a resolved parent. Which directories a reveal expands is
/// `TreeRevealRuleTests`' subject; this suite pins the row matching, the
/// target's spelling and the token, and the two chain questions a chain row
/// asks: expanding when any segment is an ancestor, and an inner segment
/// holding nothing but the next one.
final class TreeRevealRequestTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    private func request(for path: String, after previous: TreeRevealRequest? = nil) throws -> TreeRevealRequest {
        try XCTUnwrap(TreeRevealRequest(after: previous, revealing: root.appendingPathComponent(path), root: root))
    }

    func testExpandsEveryAncestorWhateverItsTrailingSlash() throws {
        let reveal = try request(for: "a/b/c/main.swift")
        for path in ["/tmp/project", "/tmp/project/", "/tmp/project/a/", "/tmp/project/a/b", "/tmp/project/a/b/c/"] {
            XCTAssertTrue(reveal.expands(URL(fileURLWithPath: path)), path)
        }
        XCTAssertFalse(reveal.expands(URL(fileURLWithPath: "/tmp/project/a/other")))
        XCTAssertFalse(reveal.expands(URL(fileURLWithPath: "/tmp/project/a/b/c/main.swift")))
    }

    func testTargetsOnlyTheRevealedRowAndTheRowIDMatchesIt() throws {
        let reveal = try request(for: "a/main.swift")
        let row = URL(fileURLWithPath: "/tmp/project/./a/main.swift")
        XCTAssertTrue(reveal.targets(row))
        XCTAssertFalse(reveal.targets(URL(fileURLWithPath: "/tmp/project/a/other.swift")))
        XCTAssertEqual(TreeRevealRequest.rowID(row), TreeRevealRequest.rowID(reveal.target))
    }

    func testTheTargetIsSpelledUnderTheRootAndTheTokenAdvances() throws {
        let first = try request(for: "a/main.swift")
        XCTAssertEqual(first.token, 1)
        XCTAssertEqual(first.target.path, "/tmp/project/a/main.swift")
        let second = try request(for: "a/main.swift", after: first)
        XCTAssertEqual(second.token, 2)
        XCTAssertNotEqual(first, second)
    }

    /// A file reached canonically under a symlinked root is spelled as the
    /// tree spells its row — under the link — or the row would never match.
    func testTheTargetIsSpelledUnderASymlinkedRoot() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let realFile = real.appendingPathComponent("src/a.swift")
        try Data().write(to: realFile)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let reveal = try XCTUnwrap(TreeRevealRequest(after: nil, revealing: realFile, root: link))
        XCTAssertEqual(reveal.target.path, link.appendingPathComponent("src/a.swift").path)
        XCTAssertTrue(reveal.targets(link.appendingPathComponent("src/a.swift")))
    }

    /// Each ancestor needs the next one in its listing, the deepest needs the
    /// target; a listing without it — an excluded `.git`, a deleted file —
    /// makes the request unreachable, and a directory it does not expand never is.
    func testAListingWithoutTheNextStepMakesTheRequestUnreachable() throws {
        let reveal = try request(for: "a/main.swift")
        let rootDir = URL(fileURLWithPath: "/tmp/project/")
        let aDir = URL(fileURLWithPath: "/tmp/project/a/")
        XCTAssertEqual(reveal.step(below: rootDir).map(TreeRevealRequest.rowID), "/tmp/project/a")
        XCTAssertEqual(reveal.step(below: aDir).map(TreeRevealRequest.rowID), "/tmp/project/a/main.swift")
        XCTAssertNil(reveal.step(below: URL(fileURLWithPath: "/tmp/project/b/")))

        let listsA = [DirectoryEntry(url: aDir, isDirectory: true)]
        let listsMain = [DirectoryEntry(url: aDir.appendingPathComponent("main.swift"), isDirectory: false)]
        let listsOther = [DirectoryEntry(url: aDir.appendingPathComponent("other.swift"), isDirectory: false)]
        XCTAssertFalse(reveal.isUnreachable(below: rootDir, listing: listsA))
        XCTAssertTrue(reveal.isUnreachable(below: rootDir, listing: []))
        XCTAssertFalse(reveal.isUnreachable(below: aDir, listing: listsMain))
        XCTAssertTrue(reveal.isUnreachable(below: aDir, listing: listsOther))
        XCTAssertFalse(reveal.isUnreachable(below: URL(fileURLWithPath: "/tmp/project/b/"), listing: []))
    }

    /// A listing entry of the wrong kind cannot carry the request on: an
    /// ancestor replaced by a file, or the target replaced by a directory.
    func testAnEntryOfTheWrongKindMakesTheRequestUnreachable() throws {
        let reveal = try request(for: "a/main.swift")
        let rootDir = URL(fileURLWithPath: "/tmp/project/")
        let aDir = URL(fileURLWithPath: "/tmp/project/a/")
        XCTAssertTrue(reveal.isUnreachable(below: rootDir, listing: [DirectoryEntry(url: aDir, isDirectory: false)]))
        let mainAsDirectory = DirectoryEntry(url: aDir.appendingPathComponent("main.swift"), isDirectory: true)
        XCTAssertTrue(reveal.isUnreachable(below: aDir, listing: [mainAsDirectory]))
    }

    /// The listing may spell its entries under a resolved parent — `/tmp`
    /// lists as `/private/tmp` — so its entries are matched by name.
    func testAListingSpelledUnderAResolvedParentStillReachesTheStep() throws {
        let reveal = try request(for: "a/main.swift")
        let resolvedA = URL(fileURLWithPath: "/private/tmp/project/a/")
        XCTAssertFalse(reveal.isUnreachable(
            below: URL(fileURLWithPath: "/tmp/project/"),
            listing: [DirectoryEntry(url: resolvedA, isDirectory: true)]
        ))
        XCTAssertFalse(reveal.isUnreachable(
            below: URL(fileURLWithPath: "/tmp/project/a"),
            listing: [DirectoryEntry(url: resolvedA.appendingPathComponent("main.swift"), isDirectory: false)]
        ))
    }

    // MARK: - Through a chain row

    /// The `a/b/c` chain's segments as its row spells them for a reveal, with or
    /// without the trailing slash a listing gives a directory.
    private func chainSegments(trailingSlash: Bool) -> [URL] {
        ["a", "a/b", "a/b/c"].map { URL(fileURLWithPath: "/tmp/project/\($0)" + (trailingSlash ? "/" : "")) }
    }

    /// A chain row expands when the request names any one of its segments —
    /// the head, an inner one, the tail — whatever the trailing slash.
    func testAChainExpandsWhenAnyOneSegmentIsAnAncestor() throws {
        let throughTail = try request(for: "a/b/c/main.swift")
        let throughInner = try request(for: "a/b/main.swift")
        let throughHead = try request(for: "a/main.swift")
        for trailingSlash in [false, true] {
            let segments = chainSegments(trailingSlash: trailingSlash)
            XCTAssertTrue(throughTail.expands(anyOf: segments))
            XCTAssertTrue(throughInner.expands(anyOf: segments))
            XCTAssertTrue(throughHead.expands(anyOf: segments))
            XCTAssertTrue(throughTail.expands(anyOf: [segments[2]]), "the tail alone")
            XCTAssertTrue(throughInner.expands(anyOf: [segments[1]]), "an inner segment alone")
        }
        let elsewhere = try request(for: "z/main.swift")
        XCTAssertFalse(elsewhere.expands(anyOf: chainSegments(trailingSlash: true)))
        XCTAssertFalse(elsewhere.expands(anyOf: []))
    }

    /// Below the tail the request needs the next ancestor, or the target in the
    /// deepest one — and a tail listing holding it reaches it.
    func testTheStepBelowTheTailIsTheNextAncestorOrTheTarget() throws {
        let deeper = try request(for: "a/b/c/d/main.swift")
        let segments = chainSegments(trailingSlash: true)
        XCTAssertEqual(deeper.step(below: segments[2]).map(TreeRevealRequest.rowID), "/tmp/project/a/b/c/d")
        let listsD = [DirectoryEntry(url: URL(fileURLWithPath: "/tmp/project/a/b/c/d/"), isDirectory: true)]
        XCTAssertFalse(deeper.isUnreachable(belowChain: segments, listing: listsD))

        let inTail = try request(for: "a/b/c/main.swift")
        XCTAssertEqual(inTail.step(below: segments[2]).map(TreeRevealRequest.rowID), "/tmp/project/a/b/c/main.swift")
        let listsMain = [DirectoryEntry(url: URL(fileURLWithPath: "/tmp/project/a/b/c/main.swift"), isDirectory: false)]
        XCTAssertFalse(inTail.isUnreachable(belowChain: segments, listing: listsMain))
    }

    /// The chain says each inner segment holds only the next one, so a target
    /// sitting in an inner segment — or a request turning off there to another
    /// folder — can never be reached, whatever the tail lists.
    func testATargetInAnInnerSegmentIsUnreachable() throws {
        let segments = chainSegments(trailingSlash: true)
        let inHead = try request(for: "a/main.swift")
        let inInner = try request(for: "a/b/main.swift")
        let offToOther = try request(for: "a/b/other/main.swift")
        let tailListing = [DirectoryEntry(url: URL(fileURLWithPath: "/tmp/project/a/b/c/x.swift"), isDirectory: false)]
        XCTAssertTrue(inHead.isUnreachable(belowChain: segments, listing: tailListing))
        XCTAssertTrue(inInner.isUnreachable(belowChain: segments, listing: tailListing))
        XCTAssertTrue(offToOther.isUnreachable(belowChain: segments, listing: tailListing))
    }

    /// A tail listing without the step — a deleted file, an excluded entry —
    /// makes the request unreachable, and a chain it does not expand never is.
    func testATailListingLackingTheStepIsUnreachable() throws {
        let segments = chainSegments(trailingSlash: false)
        let reveal = try request(for: "a/b/c/main.swift")
        let listsOther = [DirectoryEntry(url: URL(fileURLWithPath: "/tmp/project/a/b/c/other.swift"), isDirectory: false)]
        XCTAssertTrue(reveal.isUnreachable(belowChain: segments, listing: listsOther))
        XCTAssertTrue(reveal.isUnreachable(belowChain: segments, listing: []))

        let elsewhere = try request(for: "z/main.swift")
        XCTAssertFalse(elsewhere.isUnreachable(belowChain: segments, listing: []))
    }

    /// The tail's listing may spell its entries under a resolved parent, as any
    /// listing may; they are matched by name, so the step is still reached.
    func testATailListingSpelledUnderAResolvedParentStillReachesTheStep() throws {
        let reveal = try request(for: "a/b/c/main.swift")
        let resolved = URL(fileURLWithPath: "/private/tmp/project/a/b/c/main.swift")
        XCTAssertFalse(reveal.isUnreachable(
            belowChain: chainSegments(trailingSlash: true),
            listing: [DirectoryEntry(url: resolved, isDirectory: false)]
        ))
    }

    func testNoRequestWithoutARootOrOutsideIt() {
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: URL(fileURLWithPath: "/elsewhere/x.swift"), root: root))
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("x.swift"), root: nil))
    }
}
#endif
