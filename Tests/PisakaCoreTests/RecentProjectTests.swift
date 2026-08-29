import XCTest
@testable import PisakaCore

final class RecentProjectTests: XCTestCase {

    func testRowsPreservesOrderAndExcludesNil() {
        let catalog = SessionCatalog(entries: [
            EditorSession(folderPath: "/a", tabs: []),
            EditorSession(folderPath: nil, tabs: []),
            EditorSession(folderPath: "/b", tabs: []),
        ])

        let rows = RecentProject.rows(
            catalog: catalog,
            currentRoot: nil,
            folderExists: { _ in true }
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].path, "/a")
        XCTAssertEqual(rows[1].path, "/b")
    }

    func testEmptyCatalog() {
        let rows = RecentProject.rows(
            catalog: SessionCatalog(entries: []),
            currentRoot: URL(fileURLWithPath: "/a"),
            folderExists: { _ in true }
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testNameDerivationAndVerbatimPath() {
        let catalog = SessionCatalog(entries: [
            EditorSession(folderPath: "/foo/bar", tabs: []),
            EditorSession(folderPath: "/foo/baz/", tabs: []),
            EditorSession(folderPath: "/", tabs: []),
        ])

        let rows = RecentProject.rows(
            catalog: catalog,
            currentRoot: nil,
            folderExists: { _ in true }
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].name, "bar")
        XCTAssertEqual(rows[0].path, "/foo/bar")
        XCTAssertEqual(rows[0].url, URL(fileURLWithPath: "/foo/bar"))

        XCTAssertEqual(rows[1].name, "baz")
        XCTAssertEqual(rows[1].path, "/foo/baz/")

        XCTAssertEqual(rows[2].name, "/")
        XCTAssertEqual(rows[2].path, "/")
    }

    func testExistenceFilter() {
        let catalog = SessionCatalog(entries: [
            EditorSession(folderPath: "/a", tabs: []),
            EditorSession(folderPath: nil, tabs: []),
            EditorSession(folderPath: "/b", tabs: []),
            EditorSession(folderPath: "/c", tabs: []),
        ])

        var calls: [URL] = []
        let rows = RecentProject.rows(
            catalog: catalog,
            currentRoot: nil,
            folderExists: { url in
                calls.append(url)
                return url.path == "/b"
            }
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].path, "/b")
        XCTAssertEqual(calls, [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b"), URL(fileURLWithPath: "/c")])
    }

    func testCurrentProjectMarkedCanonically() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let target = tempDir.appendingPathComponent("target_\(UUID().uuidString)")
        let symlink = tempDir.appendingPathComponent("symlink_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: symlink)
        }

        let catalog = SessionCatalog(entries: [
            EditorSession(folderPath: symlink.path, tabs: []),
            EditorSession(folderPath: symlink.path + "/", tabs: []),
            EditorSession(folderPath: symlink.path + "/./", tabs: []),
        ])

        let root1 = target
        let rows1 = RecentProject.rows(catalog: catalog, currentRoot: root1, folderExists: { _ in true })
        XCTAssertEqual(rows1.count, 1)
        XCTAssertTrue(rows1[0].isCurrent)

        let root4: URL? = nil
        let rows4 = RecentProject.rows(catalog: catalog, currentRoot: root4, folderExists: { _ in true })
        XCTAssertEqual(rows4.count, 1)
        XCTAssertFalse(rows4[0].isCurrent)
    }
}
