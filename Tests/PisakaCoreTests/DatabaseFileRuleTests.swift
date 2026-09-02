import XCTest
@testable import PisakaCore

/// The recognition rule that decides what opens in the database viewer.
///
/// The rule is one static answer over one set, so what is worth pinning is the
/// *shape* of the match: last extension only, case-insensitive, and never a
/// name that merely contains a recognized component.
final class DatabaseFileRuleTests: XCTestCase {
    // MARK: - Recognized

    func testRecognizedExtensionsAreTheStatedSet() {
        XCTAssertEqual(DatabaseFileRule.recognizedExtensions, ["sqlite", "sqlite3", "db"])
    }

    func testEachRecognizedExtensionIsRecognizedInBothCases() {
        for ext in DatabaseFileRule.recognizedExtensions {
            XCTAssertTrue(
                DatabaseFileRule.isDatabaseFile(named: "app.\(ext)"),
                "lowercase .\(ext) should be recognized"
            )
            XCTAssertTrue(
                DatabaseFileRule.isDatabaseFile(named: "app.\(ext.uppercased())"),
                "uppercase .\(ext) should be recognized"
            )
        }
    }

    func testMixedCaseIsRecognized() {
        XCTAssertTrue(DatabaseFileRule.isDatabaseFile(named: "Chinook.SqLiTe"))
        XCTAssertTrue(DatabaseFileRule.isDatabaseFile(named: "Chinook.Db"))
    }

    func testRecognizedExtensionOnADotfileBody() {
        // `.hidden.db` has a last extension of `db`; the leading dot only hides
        // the file, it does not change what it is.
        XCTAssertTrue(DatabaseFileRule.isDatabaseFile(named: ".hidden.db"))
    }

    // MARK: - Not recognized

    func testUnrecognizedExtension() {
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "schema.sql"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "notes.txt"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "Main.swift"))
    }

    func testOnlyTheLastExtensionCounts() {
        // The middle component reads `db`, but the file is a text file and the
        // editor must keep editing it.
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "a.db.txt"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "dump.sqlite.gz"))
    }

    func testNoExtension() {
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "Makefile"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "db"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: ""))
    }

    func testDotfileWithNoOtherComponentIsNotRecognized() {
        // `.sqlite` is a dotfile with no extension at all, not a database named
        // by its extension.
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: ".sqlite"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: ".db"))
    }

    func testTrailingDotIsNotAnExtension() {
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "app."))
    }

    func testAPathIsAnsweredByItsLastComponent() {
        XCTAssertTrue(DatabaseFileRule.isDatabaseFile(named: "/tmp/project/app.sqlite"))
        XCTAssertFalse(DatabaseFileRule.isDatabaseFile(named: "/tmp/app.db/notes.txt"))
    }
}
