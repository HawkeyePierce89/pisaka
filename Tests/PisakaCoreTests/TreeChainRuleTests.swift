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

    /// Joining `a` would stop before its unreadable only child, a chain of one:
    /// the same plain row, so nothing is offered.
    func testASeparatedFolderWhoseOnlyChildIsUnreadableDoesNotOfferShowAsOneRow() throws {
        let tree = tree(["a/b/one.swift", "a/b/two.swift"])
        tree.unreadableDirectories = ["a/b"]
        XCTAssertEqual(
            try rows(tree, separated: [key(tree, "a")]),
            [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: false)]
        )
    }

    /// Joining `a` would append its only child, a link, as the unlisted tail —
    /// a two-segment chain, so the item is offered.
    func testASeparatedFolderWhoseOnlyChildIsALinkOffersShowAsOneRow() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        tree.symlinks = ["a/b"]
        XCTAssertEqual(
            try rows(tree, separated: [key(tree, "a")]),
            [.folder(DirectoryEntry(url: tree.url("a"), isDirectory: true), offersShowAsOneRow: true)]
        )
        XCTAssertFalse(tree.listedPaths.contains("a/b"))
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
        XCTAssertEqual(chain.deleteConfirmationName, "a/b/c")
        XCTAssertEqual(chain.deleteTitle, "Delete \"\(chain.deleteConfirmationName)\"")
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

    // MARK: - Charged listings

    /// The rule over the root's listing, every read going through `memo`.
    private func rows(_ memo: TreeListingMemo, revision: Int, separated: Set<String> = [], tree: StubFileTree) throws -> [TreeRow] {
        TreeChainRule.rows(
            in: try memo.listing(of: tree.root, revision: revision),
            separated: separated,
            isSymbolicLink: { tree.symbolicLinkDestination(at: $0) != nil },
            list: { try memo.listing(of: $0, revision: revision) }
        )
    }

    /// The listings the probe read, the caller's own read of the root excluded.
    private func probeListings(_ tree: StubFileTree) -> [String] {
        Array(tree.listedPaths.dropFirst())
    }

    func testAParentWithNSubfoldersAndOneRunListsNPlusDMinusOneDirectories() throws {
        let others = (1...4).map { "plain\($0)" }
        let run = ["src", "src/main", "src/main/java", "src/main/java/com", "src/main/java/com/acme"]
        let tree = tree(others.flatMap { ["\($0)/one.swift", "\($0)/two.swift"] } + [run.last! + "/one.swift", run.last! + "/two.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let answer = try rows(memo, revision: 0, tree: tree)

        let subfolders = others.count + 1
        XCTAssertEqual(answer.count, subfolders)
        XCTAssertEqual(tree.listedPaths.first, "")
        XCTAssertEqual(probeListings(tree).count, subfolders + run.count - 1)
        XCTAssertEqual(Set(probeListings(tree)), Set(others + run))
    }

    func testTheCapHaltsADeepRunAtThirtyTwoListings() throws {
        let components = (1...40).map { "d\($0)" }
        let tree = tree([components.joined(separator: "/") + "/leaf.swift"])
        _ = try rows(TreeListingMemo { try tree.contentsOfDirectory(at: $0) }, revision: 0, tree: tree)

        let listed = probeListings(tree)
        let expected = (1...32).map { components.prefix($0).joined(separator: "/") }
        XCTAssertEqual(listed.count, 32)
        XCTAssertEqual(Set(listed), Set(expected))
        XCTAssertFalse(tree.listedPaths.contains(components.prefix(33).joined(separator: "/")))
    }

    func testTheMemoServesASecondAskAndARevisionChangeReadsOnceAgain() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift", "README.md"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let expected = ["", "a", "a/b", "a/b/c"]

        // The parent probe, then the tail's own load as its expansion asks it.
        let chain = try XCTUnwrap(try rows(memo, revision: 0, tree: tree).compactMap { row -> TreeChain? in
            if case .chain(let chain) = row { return chain }
            return nil
        }.first)
        let tailLoad = try memo.listing(of: chain.contentsDirectory, revision: 0)
        XCTAssertEqual(tailLoad, chain.tailListing)
        XCTAssertEqual(tree.listedPaths, expected)

        // The same sequence again, same revision: nothing is read.
        _ = try rows(memo, revision: 0, tree: tree)
        _ = try memo.listing(of: chain.contentsDirectory, revision: 0)
        XCTAssertEqual(tree.listedPaths, expected)

        // A new revision reads each directory exactly once again.
        _ = try rows(memo, revision: 1, tree: tree)
        _ = try memo.listing(of: chain.contentsDirectory, revision: 1)
        XCTAssertEqual(tree.listedPaths, expected + expected)
    }

    func testTheMemoIsKeyedByTheTreesSpelling() throws {
        let tree = tree(["a/one.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        _ = try memo.listing(of: tree.url("a"), revision: 0)
        _ = try memo.listing(of: URL(fileURLWithPath: root.path + "/x/../a/"), revision: 0)
        XCTAssertEqual(tree.listedPaths, ["a"])
    }

    func testFailuresAreNotMemoized() throws {
        let tree = tree(["a/one.swift"])
        tree.unreadableDirectories = ["a"]
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }

        XCTAssertThrowsError(try memo.listing(of: tree.url("a"), revision: 0))
        XCTAssertThrowsError(try memo.listing(of: tree.url("a"), revision: 0))
        XCTAssertEqual(tree.listedPaths, ["a", "a"])

        tree.unreadableDirectories = []
        XCTAssertEqual(names(try memo.listing(of: tree.url("a"), revision: 0)), ["one.swift"])
        XCTAssertEqual(names(try memo.listing(of: tree.url("a"), revision: 0)), ["one.swift"])
        XCTAssertEqual(tree.listedPaths, ["a", "a", "a"])
    }

    func testResetForgetsEveryListing() throws {
        let tree = tree(["a/one.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        _ = try memo.listing(of: tree.url("a"), revision: 0)
        memo.reset()
        _ = try memo.listing(of: tree.url("a"), revision: 0)
        XCTAssertEqual(tree.listedPaths, ["a", "a"])
    }

    func testTheModelsLinkQuestionPassesThroughToTheFileService() {
        let tree = tree(["a/one.swift", "b/two.swift"])
        tree.symlinks = ["a"]
        let model = WorkspaceModel(fileService: tree)
        XCTAssertTrue(model.isSymbolicLink(tree.url("a")))
        XCTAssertFalse(model.isSymbolicLink(tree.url("b")))
        XCTAssertTrue(tree.listedPaths.isEmpty)
    }

    // MARK: - Re-evaluation

    func testALoneFolderAddedInTheTailExtendsTheChain() throws {
        let tree = tree([])
        tree.directories = ["a/b/c"]
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let before = try XCTUnwrap(onlyChain(try rows(memo, revision: 0, tree: tree)))
        XCTAssertEqual(names(before.segments), ["a", "b", "c"])

        tree.files = ["a/b/c/d/one.swift": "", "a/b/c/d/two.swift": ""]
        let after = try XCTUnwrap(onlyChain(try rows(memo, revision: 1, tree: tree)))
        XCTAssertEqual(names(after.segments), ["a", "b", "c", "d"])
        XCTAssertEqual(TreeRow.chain(after).id, TreeRow.chain(before).id)
        XCTAssertEqual(after.tailListing, try tree.contentsOfDirectory(at: tree.url("a/b/c/d")))
    }

    func testAFileAddedInAMiddleSegmentShortensTheChain() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let before = try XCTUnwrap(onlyChain(try rows(memo, revision: 0, tree: tree)))
        XCTAssertEqual(names(before.segments), ["a", "b", "c"])

        tree.files["a/b/notes.md"] = ""
        let after = try XCTUnwrap(onlyChain(try rows(memo, revision: 1, tree: tree)))
        XCTAssertEqual(names(after.segments), ["a", "b"])
        XCTAssertEqual(TreeRow.chain(after).id, TreeRow.chain(before).id)
        XCTAssertEqual(Set(names(after.tailListing) ?? []), ["c", "notes.md"])
    }

    func testARenameDraftOfTheOldTailLeadsNowhereAfterAnExtend() throws {
        let tree = tree([])
        tree.directories = ["a/b/c"]
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let anchor = tree.url("a/b")
        let renamed = tree.url("a/b/c")
        let before = try XCTUnwrap(onlyChain(try rows(memo, revision: 0, tree: tree)))
        XCTAssertTrue(TreeRow.chain(before).leads(toDraftAnchor: anchor, renaming: renamed))

        tree.directories = ["a/b/c/d"]
        let after = try XCTUnwrap(onlyChain(try rows(memo, revision: 1, tree: tree)))
        XCTAssertFalse(TreeRow.chain(after).leads(toDraftAnchor: anchor, renaming: renamed))
    }

    /// A shorten moves the old tail's drafts *below* the row rather than off
    /// it: the shortened chain still leads to a rename of `c` (anchored on the
    /// new tail `b`) and to a create in `c`, and so does `c`'s own plain row.
    /// `leads` answers reachability only; whether the row that holds the draft
    /// is expanded is the view's question, which drops a draft below a
    /// collapsed node.
    func testAShortenStillLeadsToTheOldTailsDrafts() throws {
        let tree = tree(["a/b/c/one.swift", "a/b/c/two.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let before = try XCTUnwrap(onlyChain(try rows(memo, revision: 0, tree: tree)))
        XCTAssertTrue(TreeRow.chain(before).leads(toDraftAnchor: tree.url("a/b"), renaming: tree.url("a/b/c")))
        XCTAssertTrue(TreeRow.chain(before).leads(toDraftAnchor: tree.url("a/b/c"), renaming: nil))

        tree.files["a/b/notes.md"] = ""
        let after = try XCTUnwrap(onlyChain(try rows(memo, revision: 1, tree: tree)))
        XCTAssertEqual(names(after.segments), ["a", "b"])
        XCTAssertTrue(TreeRow.chain(after).leads(toDraftAnchor: tree.url("a/b"), renaming: tree.url("a/b/c")))
        XCTAssertTrue(TreeRow.chain(after).leads(toDraftAnchor: tree.url("a/b/c"), renaming: nil))

        let oldTail = try XCTUnwrap(
            TreeChainRule.rows(
                in: try XCTUnwrap(after.tailListing),
                separated: [],
                isSymbolicLink: { tree.symbolicLinkDestination(at: $0) != nil },
                list: { try memo.listing(of: $0, revision: 1) }
            ).first { $0.id == tree.url("a/b/c") }
        )
        XCTAssertEqual(oldTail, plain(tree, "a/b/c", offersShowAsOneRow: false))
        XCTAssertTrue(oldTail.leads(toDraftAnchor: tree.url("a/b/c"), renaming: nil))
    }

    // MARK: - Per-row unfold

    /// The rule over `folder`'s listing, every read through `memo`.
    private func rows(of folder: String, _ memo: TreeListingMemo, separated: Set<String>, tree: StubFileTree) throws -> [TreeRow] {
        TreeChainRule.rows(
            in: try memo.listing(of: tree.url(folder), revision: 0),
            separated: separated,
            isSymbolicLink: { tree.symbolicLinkDestination(at: $0) != nil },
            list: { try memo.listing(of: $0, revision: 0) }
        )
    }

    private func plain(_ tree: StubFileTree, _ path: String, offersShowAsOneRow: Bool) -> TreeRow {
        .folder(DirectoryEntry(url: tree.url(path), isDirectory: true), offersShowAsOneRow: offersShowAsOneRow)
    }

    /// The acceptance walk: separate the head, then the next folder, then join
    /// the head again. Every step is a rule re-run over the memo in one
    /// revision, so after the first probe nothing is listed again.
    func testTheUnfoldSequenceReRunsTheRuleWithNoNewListing() throws {
        let tree = tree(["a/b/c/d/one.swift", "a/b/c/d/two.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let folded = try XCTUnwrap(onlyChain(try rows(of: "", memo, separated: [], tree: tree)))
        XCTAssertEqual(names(folded.segments), ["a", "b", "c", "d"])
        XCTAssertEqual(folded.remainderHead, tree.url("a/b"))
        let listed = tree.listedPaths
        XCTAssertEqual(listed, ["", "a", "a/b", "a/b/c", "a/b/c/d"])

        // {a}: `a` plain, offering to join, over the chain `b/c/d`.
        let headOnly: Set = [key(tree, "a")]
        XCTAssertEqual(try rows(of: "", memo, separated: headOnly, tree: tree), [plain(tree, "a", offersShowAsOneRow: true)])
        let remainder = try XCTUnwrap(onlyChain(try rows(of: "a", memo, separated: headOnly, tree: tree)))
        XCTAssertEqual(names(remainder.segments), ["b", "c", "d"])
        XCTAssertEqual(TreeRow.chain(remainder).id, folded.remainderHead)
        XCTAssertEqual(tree.listedPaths, listed)

        // {a, b}: `b` plain too, over the rest. `a` offers nothing: its one
        // child is separated, so joining it would draw the same plain row.
        let both: Set = [key(tree, "a"), key(tree, "a/b")]
        XCTAssertEqual(try rows(of: "", memo, separated: both, tree: tree), [plain(tree, "a", offersShowAsOneRow: false)])
        XCTAssertEqual(try rows(of: "a", memo, separated: both, tree: tree), [plain(tree, "a/b", offersShowAsOneRow: true)])
        XCTAssertEqual(names(try XCTUnwrap(onlyChain(try rows(of: "a/b", memo, separated: both, tree: tree))).segments), ["c", "d"])
        XCTAssertEqual(tree.listedPaths, listed)

        // {b}: `a` is a plain row again, because the rule is local to each
        // folder and its one child is still separated; `b` still offers to join.
        let innerOnly: Set = [key(tree, "a/b")]
        XCTAssertEqual(try rows(of: "", memo, separated: innerOnly, tree: tree), [plain(tree, "a", offersShowAsOneRow: false)])
        XCTAssertEqual(try rows(of: "a", memo, separated: innerOnly, tree: tree), [plain(tree, "a/b", offersShowAsOneRow: true)])
        XCTAssertEqual(tree.listedPaths, listed)
    }

    /// A revision change empties the memo, and the reload that follows draws a
    /// separated head as a plain row. Its run is still read by that load, so
    /// joining it again lists nothing.
    func testJoiningASeparatedHeadAfterARevisionChangeListsNothingNew() throws {
        let tree = tree(["a/b/c/d/one.swift", "a/b/c/d/two.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let headOnly: Set = [key(tree, "a")]
        _ = try rows(memo, revision: 0, separated: headOnly, tree: tree)
        XCTAssertEqual(
            try rows(memo, revision: 1, separated: headOnly, tree: tree),
            [plain(tree, "a", offersShowAsOneRow: true)]
        )
        let listed = tree.listedPaths
        XCTAssertEqual(Array(listed.suffix(5)), ["", "a", "a/b", "a/b/c", "a/b/c/d"])

        let joined = try XCTUnwrap(onlyChain(try rows(memo, revision: 1, tree: tree)))
        XCTAssertEqual(names(joined.segments), ["a", "b", "c", "d"])
        XCTAssertEqual(tree.listedPaths, listed)
    }

    /// A probe that failed under the load is answered as that failure again by
    /// a re-run through the memo alone — the separation toggle's read — even
    /// once the directory reads: the toggle lists nothing, and the next load
    /// retries it.
    func testARememberedOnlyReRunAnswersAFailedProbeAsTheLoadDidAndListsNothing() throws {
        let tree = tree(["a/b/c/d/one.swift", "a/b/c/d/two.swift"])
        tree.unreadableDirectories = ["a/b/c"]
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        let headOnly: Set = [key(tree, "a")]
        XCTAssertEqual(try rows(memo, revision: 0, separated: headOnly, tree: tree), [plain(tree, "a", offersShowAsOneRow: true)])
        let listed = tree.listedPaths
        XCTAssertEqual(listed, ["", "a", "a/b", "a/b/c"])

        tree.unreadableDirectories = []
        let joined = TreeChainRule.rows(
            in: try memo.rememberedListing(of: tree.root, revision: 0),
            separated: [],
            isSymbolicLink: { tree.symbolicLinkDestination(at: $0) != nil },
            list: { try memo.rememberedListing(of: $0, revision: 0) }
        )
        XCTAssertEqual(names(try XCTUnwrap(onlyChain(joined)).segments), ["a", "b"])
        XCTAssertEqual(tree.listedPaths, listed)

        let reloaded = try XCTUnwrap(onlyChain(try rows(memo, revision: 0, tree: tree)))
        XCTAssertEqual(names(reloaded.segments), ["a", "b", "c", "d"])
        XCTAssertEqual(tree.listedPaths, listed + ["a/b/c", "a/b/c/d"])
    }

    func testTheRememberedListingNeverReads() throws {
        let tree = tree(["a/one.swift"])
        let memo = TreeListingMemo { try tree.contentsOfDirectory(at: $0) }
        XCTAssertThrowsError(try memo.rememberedListing(of: tree.url("a"), revision: 0)) {
            XCTAssertEqual($0 as? TreeListingMemo.NotRemembered, TreeListingMemo.NotRemembered())
        }
        _ = try memo.listing(of: tree.url("a"), revision: 0)
        XCTAssertEqual(names(try memo.rememberedListing(of: URL(fileURLWithPath: root.path + "/x/../a/"), revision: 0)), ["one.swift"])
        XCTAssertThrowsError(try memo.rememberedListing(of: tree.url("a"), revision: 1))
        XCTAssertEqual(names(try memo.listing(of: tree.url("a"), revision: 0)), ["one.swift"])
        XCTAssertEqual(tree.listedPaths, ["a"])
    }

    func testATwoSegmentChainsRemainderIsItsTail() throws {
        let tree = tree(["a/b/one.swift", "a/b/two.swift"])
        let chain = try XCTUnwrap(onlyChain(try rows(tree)))
        XCTAssertEqual(chain.remainderHead, chain.tail.url)
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
