import XCTest
@testable import PisakaCore

final class DependencyFolderRuleTests: XCTestCase {

    private typealias State = DependencyFolderRule.State

    private func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// `isInsideDependencies(components:)` over a listing table keyed by the
    /// root-relative directory path (`""` the root), recording every index asked.
    private func inside(
        _ path: String,
        listings: [String: [String]],
        asked: inout [Int]
    ) -> Bool {
        let parts = components(path)
        var recorded: [Int] = []
        let answer = DependencyFolderRule.isInsideDependencies(components: parts) { index in
            recorded.append(index)
            return listings[parts[..<index].joined(separator: "/")]
        }
        asked = recorded
        return answer
    }

    // MARK: - The table

    func testTheTableIsClosedBySetEquality() {
        let python: Set<String> = ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"]
        XCTAssertEqual(
            Set(DependencyFolderRule.markers.keys),
            ["node_modules", "vendor", ".venv", "venv", "Pods", ".build"]
        )
        XCTAssertEqual(DependencyFolderRule.markers["node_modules"], ["package.json"])
        XCTAssertEqual(DependencyFolderRule.markers["vendor"], ["composer.json", "go.mod", "Gemfile"])
        XCTAssertEqual(DependencyFolderRule.markers[".venv"], python)
        XCTAssertEqual(DependencyFolderRule.markers["venv"], python)
        XCTAssertEqual(DependencyFolderRule.markers["Pods"], ["Podfile"])
        XCTAssertEqual(DependencyFolderRule.markers[".build"], ["Package.swift"])
    }

    func testEveryKeyWithEachOfItsMarkersIsARoot() {
        var checked = 0
        for (name, markers) in DependencyFolderRule.markers {
            for marker in markers {
                XCTAssertTrue(
                    DependencyFolderRule.isDependencyRoot(name: name, siblingNames: ["README.md", name, marker]),
                    "\(name) beside \(marker)"
                )
                checked += 1
            }
        }
        XCTAssertEqual(checked, 16)
    }

    func testATableNameBesideNoMarkerIsNotARoot() {
        for name in DependencyFolderRule.markers.keys {
            XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: name, siblingNames: [name, "README.md"]), name)
            XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: name, siblingNames: []), name)
        }
        XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: "vendor", siblingNames: ["vendor", "package.json"]))
    }

    func testComparisonIsExact() {
        XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: "Node_Modules", siblingNames: ["package.json"]))
        XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: "VENDOR", siblingNames: ["go.mod"]))
        XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: "node_modules", siblingNames: ["Package.json"]))
        XCTAssertFalse(DependencyFolderRule.isDependencyRoot(name: "src", siblingNames: ["package.json"]))
    }

    // MARK: - The root exclusion and inheritance

    func testTheProjectRootIsNeverAsked() {
        var asked: [Int] = []
        let everything = ["": ["package.json", "node_modules"]]
        XCTAssertFalse(inside("", listings: everything, asked: &asked))
        XCTAssertEqual(asked, [])
        XCTAssertFalse(inside("package.json", listings: everything, asked: &asked))
        XCTAssertEqual(asked, [])
        // The entry itself is not an ancestor: the root folder `node_modules` is
        // a root, not inside one.
        XCTAssertFalse(inside("node_modules", listings: everything, asked: &asked))
        XCTAssertEqual(asked, [])
    }

    func testEverythingBelowARootIsInside() {
        var asked: [Int] = []
        XCTAssertTrue(inside("node_modules/x/y/z.js", listings: ["": ["package.json", "node_modules"]], asked: &asked))
        XCTAssertTrue(inside("node_modules/x", listings: ["": ["package.json", "node_modules"]], asked: &asked))
        XCTAssertFalse(inside("node_modules/x/y/z.js", listings: ["": ["node_modules"]], asked: &asked))
    }

    // MARK: - State

    func testANodeBelowARootOrInsideIsInside() {
        let anything: (Int) -> [String] = { _ in ["package.json"] }
        XCTAssertEqual(State.node(segmentNames: ["lodash"], siblingNames: anything, parent: .root), .inside)
        XCTAssertEqual(State.node(segmentNames: ["lodash"], siblingNames: anything, parent: .inside), .inside)
        // A nested `node_modules` beside its package's `package.json` is never a
        // second root.
        XCTAssertEqual(State.node(segmentNames: ["node_modules"], siblingNames: anything, parent: .inside), .inside)
        XCTAssertEqual(State.node(segmentNames: ["node_modules"], siblingNames: anything, parent: .outside), .root)
        XCTAssertEqual(State.node(segmentNames: ["src"], siblingNames: anything, parent: .outside), .outside)
    }

    func testAFileIsNeverARoot() {
        XCTAssertEqual(State.file(inParent: .outside), .outside)
        XCTAssertEqual(State.file(inParent: .root), .inside)
        XCTAssertEqual(State.file(inParent: .inside), .inside)
    }

    func testTheCaptionShowsOnARootAlone() {
        XCTAssertTrue(State.root.showsCaption)
        XCTAssertFalse(State.outside.showsCaption)
        XCTAssertFalse(State.inside.showsCaption)
    }

    // MARK: - The chain rule: any segment

    func testAChainHeadedByARootIsARootRow() {
        let state = State.node(
            segmentNames: ["node_modules", "lodash"],
            siblingNames: { $0 == 0 ? ["package.json", "node_modules"] : ["lodash"] },
            parent: .outside
        )
        XCTAssertEqual(state, .root)
    }

    func testAChainWhoseLaterSegmentIsTheRootIsARootRow() {
        var asked: [Int] = []
        let state = State.node(
            segmentNames: ["tools", "vendor"],
            siblingNames: { index in
                asked.append(index)
                return index == 1 ? ["vendor", "go.mod"] : ["tools"]
            },
            parent: .outside
        )
        XCTAssertEqual(state, .root)
        // Only the table-named segment's siblings are asked for.
        XCTAssertEqual(asked, [1])
    }

    func testAChainUnderARootIsInside() {
        let state = State.node(
            segmentNames: ["a", "b"],
            siblingNames: { _ in ["package.json"] },
            parent: .root
        )
        XCTAssertEqual(state, .inside)
    }

    func testNoSegmentsIsNotARootRow() {
        XCTAssertFalse(DependencyFolderRule.isDependencyRootRow(segmentNames: [], siblingNames: { _ in ["package.json"] }))
    }

    // MARK: - The test-wash suppression

    func testTheTestWashShowsOnlyOutsideDependencies() {
        XCTAssertTrue(State.outside.showsTestWash(isTestRow: true))
        XCTAssertFalse(State.outside.showsTestWash(isTestRow: false))
        XCTAssertFalse(State.root.showsTestWash(isTestRow: true))
        XCTAssertFalse(State.inside.showsTestWash(isTestRow: true))
        XCTAssertFalse(State.inside.showsTestWash(isTestRow: false))
    }

    func testAVendoredPackagesTestFolderWashesNothing() {
        let marker: (Int) -> [String] = { _ in ["package.json", "node_modules"] }
        let modules = State.node(segmentNames: ["node_modules"], siblingNames: marker, parent: .outside)
        let package = State.node(segmentNames: ["x"], siblingNames: marker, parent: modules)
        let test = State.node(segmentNames: ["test"], siblingNames: marker, parent: package)
        XCTAssertEqual(test, .inside)
        let isTestRow = TreeTestRule.isTestRow(components: ["node_modules", "x", "test"], isFolder: true)
        XCTAssertTrue(isTestRow)
        XCTAssertFalse(test.showsTestWash(isTestRow: isTestRow))
    }

    // MARK: - The listing-cost bound

    func testAPathWithNoTableNamedAncestorAsksNoListing() {
        var asked: [Int] = []
        XCTAssertFalse(inside("src/a/b.swift", listings: [:], asked: &asked))
        XCTAssertEqual(asked, [])
    }

    func testARootAncestorIsAskedExactlyOnceForTheRootsEntries() {
        var asked: [Int] = []
        XCTAssertTrue(inside("node_modules/x/y.js", listings: ["": ["package.json", "node_modules"]], asked: &asked))
        XCTAssertEqual(asked, [0])
    }

    func testEveryTableNamedAncestorIsAskedWhenNoneIsARoot() {
        var asked: [Int] = []
        XCTAssertFalse(inside(
            "a/vendor/b/vendor/c.go",
            listings: ["a": ["vendor"], "a/vendor/b": ["vendor"]],
            asked: &asked
        ))
        XCTAssertEqual(asked, [1, 3])
    }

    func testTheWalkStopsAtTheFirstRoot() {
        var asked: [Int] = []
        XCTAssertTrue(inside(
            "vendor/b/vendor/c.go",
            listings: ["": ["vendor", "go.mod"], "vendor/b": ["vendor", "go.mod"]],
            asked: &asked
        ))
        XCTAssertEqual(asked, [0])
    }

    func testANilListingIsNotARoot() {
        var asked: [Int] = []
        XCTAssertFalse(inside("node_modules/x.js", listings: [:], asked: &asked))
        XCTAssertEqual(asked, [0])
    }

    // MARK: - The URL form

    func testTheURLFormMatchesASymlinkedRootSpellingCanonically() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("DependencyFolderRuleTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("node_modules/x/y.js"))
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let canonicalRoot = CanonicalPath.canonical(real).path
        var asked: [String] = []
        let listNames: (URL) -> [String]? = { url in
            asked.append(url.path)
            return url.path == canonicalRoot ? ["package.json", "node_modules"] : nil
        }

        XCTAssertTrue(DependencyFolderRule.isInsideDependencies(
            fileURL: real.appendingPathComponent("node_modules/x/y.js"),
            projectRoot: link,
            listNames: listNames
        ))
        XCTAssertTrue(DependencyFolderRule.isInsideDependencies(
            fileURL: link.appendingPathComponent("node_modules/x/y.js"),
            projectRoot: real,
            listNames: listNames
        ))
        XCTAssertEqual(asked, [canonicalRoot, canonicalRoot])
    }

    func testTheURLFormListsTheDirectoryHoldingEachTableNamedComponent() {
        let root = URL(fileURLWithPath: "/nonexistent-dependency-root")
        let canonicalRoot = CanonicalPath.canonical(root)
        var asked: [String] = []
        XCTAssertFalse(DependencyFolderRule.isInsideDependencies(
            fileURL: root.appendingPathComponent("a/vendor/b/vendor/c.go"),
            projectRoot: root,
            listNames: { asked.append($0.path); return nil }
        ))
        XCTAssertEqual(asked, [
            canonicalRoot.appendingPathComponent("a").path,
            canonicalRoot.appendingPathComponent("a/vendor/b").path,
        ])
    }

    func testOutsideTheRootOrWithNoRootAnswersFalseWithNoListing() {
        var asked = 0
        let listNames: (URL) -> [String]? = { _ in asked += 1; return ["package.json"] }
        let root = URL(fileURLWithPath: "/nonexistent-dependency-root/project")
        XCTAssertFalse(DependencyFolderRule.isInsideDependencies(
            fileURL: URL(fileURLWithPath: "/nonexistent-dependency-root/node_modules/x/y.js"),
            projectRoot: root,
            listNames: listNames
        ))
        XCTAssertFalse(DependencyFolderRule.isInsideDependencies(
            fileURL: root.appendingPathComponent("node_modules/x/y.js"),
            projectRoot: nil,
            listNames: listNames
        ))
        XCTAssertFalse(DependencyFolderRule.isInsideDependencies(
            fileURL: root,
            projectRoot: root,
            listNames: listNames
        ))
        XCTAssertEqual(asked, 0)
    }
}
