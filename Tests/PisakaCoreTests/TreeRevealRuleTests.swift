import XCTest
@testable import PisakaCore

final class TreeRevealRuleTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Users/tester/dev/proj")

    private func paths(_ urls: [URL]?) -> [String]? {
        urls?.map(\.path)
    }

    func testThreeLevelsDeepAnswersEveryDirectoryFromTheRootDownInOrder() {
        let file = root.appendingPathComponent("a/b/c/d.swift")
        XCTAssertEqual(
            paths(TreeRevealRule.ancestors(of: file, root: root)),
            [
                "/Users/tester/dev/proj", "/Users/tester/dev/proj/a",
                "/Users/tester/dev/proj/a/b", "/Users/tester/dev/proj/a/b/c",
            ]
        )
    }

    func testFileDirectlyUnderTheRootAnswersOnlyTheRoot() {
        let file = root.appendingPathComponent("main.swift")
        XCTAssertEqual(paths(TreeRevealRule.ancestors(of: file, root: root)), [root.path])
    }

    func testFileOutsideTheRootAnswersNil() {
        XCTAssertNil(TreeRevealRule.ancestors(of: URL(fileURLWithPath: "/etc/hosts"), root: root))
        // A sibling sharing the root's name as a string prefix is still outside.
        XCTAssertNil(TreeRevealRule.ancestors(
            of: URL(fileURLWithPath: "/Users/tester/dev/projx/a.swift"), root: root
        ))
    }

    func testTheRootItselfAnswersNil() {
        XCTAssertNil(TreeRevealRule.ancestors(of: root, root: root))
    }

    /// The root opened through a symlink, the file spelled canonically: the
    /// canonical probe decides containment, but every answer keeps the root's
    /// own (symlinked) spelling, because that is how the tree spells its rows.
    func testSymlinkedRootAnswersInTheRootsOwnSpelling() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let realFile = real.appendingPathComponent("src/sub/a.swift")
        try Data().write(to: realFile)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            paths(TreeRevealRule.ancestors(of: realFile, root: link)),
            [
                link.path, link.appendingPathComponent("src").path,
                link.appendingPathComponent("src/sub").path,
            ]
        )
    }

    /// The root and the file differing only by the `/private` firmlink prefix,
    /// either way round: still inside, answered in the root's spelling.
    func testPrivateFirmlinkDifferenceStillAnswersInTheRootsSpelling() throws {
        let fm = FileManager.default
        let plainRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: plainRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: plainRoot) }
        try Data().write(to: plainRoot.appendingPathComponent("src/a.swift"))
        let privateRoot = URL(fileURLWithPath: "/private" + plainRoot.path)

        for (rootSpelling, fileRoot) in [(plainRoot, privateRoot), (privateRoot, plainRoot)] {
            let file = fileRoot.appendingPathComponent("src/a.swift")
            XCTAssertEqual(
                paths(TreeRevealRule.ancestors(of: file, root: rootSpelling)),
                [rootSpelling.path, rootSpelling.appendingPathComponent("src").path],
                "root \(rootSpelling.path) / file \(file.path)"
            )
        }
    }
}
