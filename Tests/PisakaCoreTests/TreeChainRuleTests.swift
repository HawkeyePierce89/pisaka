import XCTest
@testable import PisakaCore

final class TreeChainRuleTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/Users/tester/dev/proj")

    // MARK: - Helpers

    private func tree(_ paths: [String]) -> StubFileTree {
        StubFileTree(root: root, files: Dictionary(uniqueKeysWithValues: paths.map { ($0, "") }))
    }

    /// The rule over the root's own listing, through the stub alone.
    private func rows(_ tree: StubFileTree, separated: Set<String> = []) throws -> [TreeRow] {
        let rootListing = try tree.contentsOfDirectory(at: tree.root)
        return TreeChainRule.rows(
            in: rootListing,
            separated: separated,
            isSymbolicLink: { tree.symbolicLinkDestination(at: $0) != nil },
            list: { try tree.contentsOfDirectory(at: $0) }
        )
    }

    private func onlyChain(_ rows: [TreeRow], file: StaticString = #filePath, line: UInt = #line) -> TreeChain? {
        guard rows.count == 1, case .chain(let chain) = rows[0] else {
            XCTFail("expected exactly one chain row, got \(rows)", file: file, line: line)
            return nil
        }
        return chain
    }

    private func names(_ entries: [DirectoryEntry]?) -> [String]? {
        entries?.map(\.name)
    }

    private func key(_ tree: StubFileTree, _ path: String) -> String {
        TreeChainRule.key(for: tree.url(path))
    }

    // MARK: - The walk

    func testAQualifyingRunBecomesOneChain() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b", "c"])
        XCTAssertEqual(names(chain.tailListing), ["one.swift", "two.swift"])
    }

    func testTheWalkStopsAtAFolderWithNoEntries() throws {
        let tree = tree([])
        tree.directories = ["a/b/c"]
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b", "c"])
        XCTAssertEqual(names(chain.tailListing), [])
    }

    func testTheWalkStopsAtAFolderWithTwoEntries() throws {
        let tree = tree(["a/b/x/one.swift", "a/b/y/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertEqual(names(chain.tailListing), ["x", "y"])
    }

    func testTheWalkStopsAtAFolderWhoseSingleEntryIsAFile() throws {
        let tree = tree(["a/b/only.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertEqual(names(chain.tailListing), ["only.swift"])
    }

    func testAChainOfOneIsAPlainRow() throws {
        let tree = tree(["a/one.swift", "a/two.swift"])
        XCTAssertEqual(try rows(tree), [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)])
    }

    func testFilesStayFileRowsBesideAChain() throws {
        let tree = tree(["a/b/one.swift", "README.md"])
        let answer = try rows(tree)
        XCTAssertEqual(answer.count, 2)
        guard case .chain(let chain) = answer[0] else { return XCTFail("expected a chain first, got \(answer)") }
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertEqual(answer[1], .file(DirectoryEntry(url: tree.url("README.md"), isDirectory: false)))
    }

    /// The root holds one folder only — it would qualify if it were an entry,
    /// and it is not one: the rule answers that folder's chain, never the root.
    func testTheRootIsNeverASegment() throws {
        let tree = tree(["a/b/one.swift", "a/b/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(chain.segments.map(\.url), [tree.url("a"), tree.url("a/b")])
        XCTAssertFalse(chain.segments.contains { $0.url.standardizedFileURL == root.standardizedFileURL })
    }

    func testAHeadThatIsASymbolicLinkIsAPlainRowAndIsNeverListed() throws {
        let tree = tree(["a/b/one.swift", "a/b/two.swift"])
        tree.symlinks = ["a"]
        XCTAssertEqual(try rows(tree), [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)])
        XCTAssertFalse(tree.listedPaths.contains("a"))
    }

    func testALinkContinuationBecomesTheUnlistedTail() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        tree.symlinks = ["a/b"]
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertNil(chain.tailListing)
        XCTAssertFalse(tree.listedPaths.contains("a/b"))
    }

    func testARunDeeperThanTheCapEndsAtExactlyThirtyTwoSegments() throws {
        let components = (1...40).map { "d\($0)" }
        let tree = tree([components.joined(separator: "/") + "/leaf.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(TreeChainRule.maximumSegments, 32)
        XCTAssertEqual(names(chain.segments), Array(components.prefix(32)))
        // The 32nd segment is listed; the rest of the run is its child.
        XCTAssertEqual(names(chain.tailListing), ["d33"])
    }

    // MARK: - Separation

    func testASeparatedHeadIsAPlainRowOfferingShowAsOneRow() throws {
        let tree = tree(["a/b/one.swift", "a/b/two.swift"])
        XCTAssertEqual(
            try rows(tree, separated: [key(tree, "a")]),
            [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: true)]
        )
    }

    func testASeparatedFolderThatWouldNotQualifyDoesNotOfferShowAsOneRow() throws {
        let tree = tree(["a/one.swift", "a/two.swift"])
        XCTAssertEqual(
            try rows(tree, separated: [key(tree, "a")]),
            [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)]
        )
    }

    func testASeparatedContinuationEndsTheChainBeforeIt() throws {
        let tree = tree(["a/b/c/d/one.swift", "a/b/c/d/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree, separated: [key(tree, "a/b/c")])))
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertEqual(names(chain.tailListing), ["c"])
    }

    // MARK: - Silent probe failures

    func testAnUnreadableHeadDegradesToAPlainRow() throws {
        let tree = tree(["a/b/one.swift"])
        tree.unreadableDirectories = ["a"]
        XCTAssertEqual(try rows(tree), [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)])
    }

    func testAnUnreadableContinuationEndsTheChainBeforeIt() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        tree.unreadableDirectories = ["a/b/c"]
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(names(chain.segments), ["a", "b"])
        XCTAssertEqual(names(chain.tailListing), ["c"])
    }

    func testAnUnreadableFirstContinuationLeavesThePlainHead() throws {
        let tree = tree(["a/b/one.swift"])
        tree.unreadableDirectories = ["a/b"]
        XCTAssertEqual(try rows(tree), [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)])
    }

    // MARK: - Addressing, as data

    func testEveryAddressAndTitleOfAChain() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        let head = tree.url("a")
        let tail = tree.url("a/b/c")

        XCTAssertEqual(TreeRow.chain(chain).id, head)
        XCTAssertEqual(chain.identity, head)
        XCTAssertEqual(chain.contentsDirectory, tail)
        XCTAssertEqual(chain.createTarget, tail)
        XCTAssertEqual(chain.renameTarget, DirectoryEntry(url: tail, isDirectory: true))
        XCTAssertEqual(chain.deleteTarget, head)
        XCTAssertEqual(chain.dragSource, head)
        XCTAssertEqual(chain.dropDestination, tail)
        XCTAssertEqual(chain.diagnosticMarkURL, head)
        XCTAssertEqual(chain.spokenGitStateURL, head)
        XCTAssertEqual(chain.gitStatusURLs, [head, tree.url("a/b"), tail])
        XCTAssertEqual(names(chain.leadingSegments), ["a", "b"])

        XCTAssertEqual(chain.label, "a/b/c")
        XCTAssertEqual(chain.renameTitle, "Rename \"c\"")
        XCTAssertEqual(chain.deleteTitle, "Delete \"a/b/c\"")
        XCTAssertEqual(TreeChain.showAsSeparateFoldersTitle, "Show as Separate Folders")
        XCTAssertEqual(TreeChain.showAsOneRowTitle, "Show as One Row")
        XCTAssertEqual(chain.renameSiblings, ["c"])

        let revealHead = URL(fileURLWithPath: "/tmp/proj/a", isDirectory: true)
        XCTAssertEqual(
            chain.revealURLs(underHeadRevealURL: revealHead).map(\.path),
            ["/tmp/proj/a", "/tmp/proj/a/b", "/tmp/proj/a/b/c"]
        )
    }

    func testTheKeyIsTheStandardizedSpelling() {
        XCTAssertEqual(TreeChainRule.key(for: URL(fileURLWithPath: "/p/a/./b/")), "/p/a/b")
        XCTAssertEqual(TreeChainRule.key(for: URL(fileURLWithPath: "/p/a/x/../b")), "/p/a/b")
    }

    // MARK: - Draft leads

    func testAPlainEntryLeadsToADraftBelowItOrRenamingIt() {
        let folder = TreeRow.folder(DirectoryEntry(url: root.appendingPathComponent("src"), isDirectory: true), offersShowAsOneRow: false)
        let file = TreeRow.file(DirectoryEntry(url: root.appendingPathComponent("src.txt"), isDirectory: false))
        let deep = root.appendingPathComponent("src/x")

        XCTAssertTrue(folder.leads(toDraftAnchor: deep, renaming: nil))
        XCTAssertTrue(folder.leads(toDraftAnchor: root.appendingPathComponent("src"), renaming: nil))
        XCTAssertTrue(folder.leads(toDraftAnchor: root, renaming: root.appendingPathComponent("src")))
        XCTAssertTrue(file.leads(toDraftAnchor: root, renaming: root.appendingPathComponent("src.txt")))
        // A file never holds a draft further down, and a sibling name-prefix is
        // not containment.
        XCTAssertFalse(file.leads(toDraftAnchor: root.appendingPathComponent("src.txt/x"), renaming: nil))
        XCTAssertFalse(folder.leads(toDraftAnchor: root.appendingPathComponent("srcx/y"), renaming: nil))
    }

    func testAChainLeadsOnlyToItsTailAndBelow() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        let row = TreeRow.chain(try XCTUnwrap(onlyChain(try rows(tree))))

        // At the tail, under it, and a rename of the tail.
        XCTAssertTrue(row.leads(toDraftAnchor: tree.url("a/b/c"), renaming: nil))
        XCTAssertTrue(row.leads(toDraftAnchor: tree.url("a/b/c/sub"), renaming: nil))
        XCTAssertTrue(row.leads(toDraftAnchor: tree.url("a/b"), renaming: tree.url("a/b/c")))
        // An inner segment is no longer drawn: neither a create in it nor a
        // rename of it leads anywhere — the head's own rename included.
        XCTAssertFalse(row.leads(toDraftAnchor: tree.url("a"), renaming: nil))
        XCTAssertFalse(row.leads(toDraftAnchor: tree.url("a/b"), renaming: nil))
        XCTAssertFalse(row.leads(toDraftAnchor: tree.url("a"), renaming: tree.url("a/b")))
        XCTAssertFalse(row.leads(toDraftAnchor: root, renaming: tree.url("a")))
    }

    // MARK: - The real listing

    /// The listing's own exclusions apply before the rule sees anything, so a
    /// folder holding `.git` and one subfolder holds one folder.
    func testAFolderHoldingDotGitAndOneSubfolderQualifies() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("p/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("p/q"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("p/q/one.swift"))
        try Data().write(to: dir.appendingPathComponent("p/q/two.swift"))

        let service = FileService()
        let answer = TreeChainRule.rows(
            in: try service.contentsOfDirectory(at: dir),
            separated: [],
            isSymbolicLink: { service.symbolicLinkDestination(at: $0) != nil },
            list: { try service.contentsOfDirectory(at: $0) }
        )
        let chain = try XCTUnwrap(onlyChain(answer))
        XCTAssertEqual(names(chain.segments), ["p", "q"])
        XCTAssertEqual(names(chain.tailListing), ["one.swift", "two.swift"])
    }
}
