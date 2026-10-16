#if os(macOS)
import XCTest
import PisakaCore
@testable import Pisaka

/// `TreeRevealRequest` matches the tree's rows by standardized path: a listing
/// spells a directory with a trailing slash and the rule's appended components
/// may not, and the two must still agree. Which directories a reveal expands is
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

    func testNoRequestWithoutARootOrOutsideIt() {
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: URL(fileURLWithPath: "/elsewhere/x.swift"), root: root))
        XCTAssertNil(TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("x.swift"), root: nil))
    }
}
#endif
