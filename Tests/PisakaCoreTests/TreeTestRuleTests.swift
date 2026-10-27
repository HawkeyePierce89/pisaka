import XCTest
@testable import PisakaCore

final class TreeTestRuleTests: XCTestCase {

    private func folder(_ path: String) -> Bool {
        TreeTestRule.isTestRow(components: path.split(separator: "/").map(String.init), isFolder: true)
    }

    private func file(_ path: String) -> Bool {
        TreeTestRule.isTestRow(components: path.split(separator: "/").map(String.init), isFolder: false)
    }

    // MARK: - The closed folder-name set

    func testEveryTestFolderNameIsATestRowInAnyCase() {
        XCTAssertEqual(TreeTestRule.testFolderNames, ["test", "tests", "__tests__", "spec", "specs"])
        for name in ["test", "tests", "__tests__", "spec", "specs"] {
            XCTAssertTrue(folder(name), name)
            XCTAssertTrue(folder(name.uppercased()), name.uppercased())
            XCTAssertTrue(folder(name.capitalized), name.capitalized)
        }
        XCTAssertTrue(folder("TeSt"))
        XCTAssertTrue(folder("__Tests__"))
        XCTAssertTrue(folder("sPeCs"))
    }

    func testANearMissIsNotATestFolder() {
        for name in ["testing", "contest", "attest", "tested", "specification", "_tests_", "test-utils"] {
            XCTAssertFalse(folder(name), name)
            XCTAssertFalse(file("\(name)/Foo.swift"), name)
        }
    }

    func testAPlainFolderIsNotATestRow() {
        XCTAssertFalse(folder("Sources"))
        XCTAssertFalse(folder("Sources/PisakaCore"))
    }

    // MARK: - The root

    func testTheRootIsNeverATestRow() {
        XCTAssertFalse(TreeTestRule.isTestRow(components: [], isFolder: true))
        XCTAssertFalse(TreeTestRule.isTestRow(components: [], isFolder: false))
    }

    // MARK: - Inheritance through an ancestor

    func testAFileUnderATestFolderInheritsIt() {
        XCTAssertTrue(file("Tests/PisakaCoreTests/Support/Gate.swift"))
        XCTAssertTrue(file("spec/models/user.rb"))
        XCTAssertTrue(file("__tests__/README.md"))
    }

    func testAFolderUnderATestFolderInheritsIt() {
        XCTAssertTrue(folder("src/test/java"))
        XCTAssertTrue(folder("Tests/PisakaCoreTests/Support"))
        XCTAssertTrue(folder("src/test"))
        XCTAssertFalse(folder("src/main/java"))
    }

    // MARK: - A chain judged by its tail's path

    func testAChainIsATestRowWhereverItsTestSegmentSits() {
        // A chain row `a/b/c` is judged by its tail's root-relative path, so
        // every segment is one of the components the rule walks.
        XCTAssertTrue(folder("test/java/com"))
        XCTAssertTrue(folder("src/test/java"))
        XCTAssertTrue(folder("src/main/specs"))
        XCTAssertFalse(folder("src/main/java"))
    }

    // MARK: - Files judged by their own name

    func testAFileFollowingANamingConventionIsATestRow() {
        XCTAssertTrue(file("src/Button.test.tsx"))
        XCTAssertTrue(file("pkg/server_test.go"))
        XCTAssertTrue(file("FooTests.swift"))
        XCTAssertFalse(file("src/Button.tsx"))
        XCTAssertFalse(file("pkg/server.go"))
    }

    func testARustFileIsATestRowOnlyThroughAFolder() {
        XCTAssertFalse(file("src/lib.rs"))
        XCTAssertFalse(file("src/main.rs"))
        XCTAssertFalse(file("src/foo_test.rs"))
        XCTAssertTrue(file("tests/integration.rs"))
    }

    func testAFileNamedTestIsNotATestFolder() {
        // The last component of a file is its own name, never a folder: a file
        // called `test` is judged by the naming convention alone, which it does
        // not follow.
        XCTAssertFalse(file("test"))
        XCTAssertFalse(file("src/test"))
        XCTAssertFalse(file("Specs"))
        XCTAssertTrue(file("test/test"))
    }
}
