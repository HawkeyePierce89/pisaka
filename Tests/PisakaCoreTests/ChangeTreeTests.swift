import XCTest
@testable import PisakaCore

final class ChangeTreeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")

    // MARK: - Helpers mirroring the node-construction the tree performs.

    private func fileNode(_ file: ChangedFile) -> ChangeNode {
        ChangeNode(
            name: (file.path as NSString).lastPathComponent,
            path: file.path,
            url: root.appendingPathComponent(file.path),
            file: file,
            children: nil
        )
    }

    private func dirNode(_ path: String, _ children: [ChangeNode]) -> ChangeNode {
        ChangeNode(
            name: (path as NSString).lastPathComponent,
            path: path,
            url: root.appendingPathComponent(path),
            file: nil,
            children: children
        )
    }

    // MARK: - Tests

    func testEmptyInputIsEmptyTree() {
        XCTAssertEqual(ChangeTree.build(from: [], root: root), [])
    }

    func testFlatFallbackForRootLevelFiles() {
        // Files with no directory component stay flat at the top level, sorted.
        let b = ChangedFile(path: "b.txt", status: .modified)
        let a = ChangedFile(path: "a.txt", status: .added)
        XCTAssertEqual(
            ChangeTree.build(from: [b, a], root: root),
            [fileNode(a), fileNode(b)]
        )
    }

    func testSingleLevelNesting() {
        let file = ChangedFile(path: "src/a.swift", status: .modified)
        XCTAssertEqual(
            ChangeTree.build(from: [file], root: root),
            [dirNode("src", [fileNode(file)])]
        )
    }

    func testDeepNesting() {
        let file = ChangedFile(path: "a/b/c/file.txt", status: .modified)
        XCTAssertEqual(
            ChangeTree.build(from: [file], root: root),
            [dirNode("a", [dirNode("a/b", [dirNode("a/b/c", [fileNode(file)])])])]
        )
    }

    func testMultipleFilesPerDirectory() {
        let one = ChangedFile(path: "src/one.swift", status: .modified)
        let two = ChangedFile(path: "src/two.swift", status: .added)
        XCTAssertEqual(
            ChangeTree.build(from: [two, one], root: root),
            [dirNode("src", [fileNode(one), fileNode(two)])]
        )
    }

    func testDirectoriesFirstOrdering() {
        // A root-level file and a directory: the directory sorts before the file,
        // matching DirectoryEntry's directories-first convention, regardless of
        // alphabetical order ("zoo" dir still precedes "alpha.txt").
        let rootFile = ChangedFile(path: "alpha.txt", status: .modified)
        let nested = ChangedFile(path: "zoo/inner.txt", status: .added)
        XCTAssertEqual(
            ChangeTree.build(from: [rootFile, nested], root: root),
            [
                dirNode("zoo", [fileNode(nested)]),
                fileNode(rootFile)
            ]
        )
    }

    func testCaseInsensitiveOrdering() {
        let zebra = ChangedFile(path: "Zebra.txt", status: .modified)
        let apple = ChangedFile(path: "apple.txt", status: .modified)
        XCTAssertEqual(
            ChangeTree.build(from: [zebra, apple], root: root),
            [fileNode(apple), fileNode(zebra)]
        )
    }

    func testDirectoriesSortedCaseInsensitively() {
        let inB = ChangedFile(path: "Beta/x.txt", status: .modified)
        let inA = ChangedFile(path: "alpha/y.txt", status: .modified)
        XCTAssertEqual(
            ChangeTree.build(from: [inB, inA], root: root),
            [
                dirNode("alpha", [fileNode(inA)]),
                dirNode("Beta", [fileNode(inB)])
            ]
        )
    }

    func testMixedTreeKeepsDirectoriesBeforeFilesAtEachLevel() {
        let topFile = ChangedFile(path: "README.md", status: .modified)
        let nestedFile = ChangedFile(path: "src/app.swift", status: .modified)
        let nestedDeep = ChangedFile(path: "src/core/util.swift", status: .added)
        XCTAssertEqual(
            ChangeTree.build(from: [topFile, nestedFile, nestedDeep], root: root),
            [
                dirNode("src", [
                    dirNode("src/core", [fileNode(nestedDeep)]),
                    fileNode(nestedFile)
                ]),
                fileNode(topFile)
            ]
        )
    }

    func testNodeIdentityAndDirectoryFlag() {
        let file = ChangedFile(path: "src/a.swift", status: .modified)
        let tree = ChangeTree.build(from: [file], root: root)
        let dir = tree[0]
        XCTAssertEqual(dir.id, "src")
        XCTAssertTrue(dir.isDirectory)
        let leaf = dir.children![0]
        XCTAssertEqual(leaf.id, "src/a.swift")
        XCTAssertFalse(leaf.isDirectory)
        XCTAssertEqual(leaf.file, file)
    }
}
