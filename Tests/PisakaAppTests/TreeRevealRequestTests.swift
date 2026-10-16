#if os(macOS)
import XCTest
import PisakaCore
@testable import Pisaka

/// `TreeRevealRequest` matches the tree's rows by standardized path: a listing
/// spells a directory with a trailing slash and the rule's appended components
/// may not, and the two must still agree. A listing is matched by entry name
/// and kind, because it may spell its entries under a resolved parent. Which directories a reveal expands is
/// `TreeRevealRuleTests`' subject; this suite pins the row matching, the
/// target's spelling and the token.
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

    func testNoRequestWithoutARootOrOutsideIt() {
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: URL(fileURLWithPath: "/elsewhere/x.swift"), root: root))
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("x.swift"), root: nil))
    }
}
#endif
