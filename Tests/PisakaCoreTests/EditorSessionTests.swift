import XCTest
@testable import PisakaCore

final class EditorSessionTests: XCTestCase {
    // MARK: - Helpers

    private func titled(_ path: String, text: String = "x") -> OpenFile {
        OpenFile(url: URL(fileURLWithPath: path), text: text, savedText: text)
    }

    private func untitled(_ text: String) -> OpenFile {
        OpenFile(url: nil, text: text, savedText: "")
    }

    // MARK: - snapshot

    func testSnapshotKeepsTabOrder() {
        let files = [titled("/p/a.swift"), untitled("scratch"), titled("/p/b.swift")]
        let session = EditorSession.snapshot(openFiles: files, selectedID: nil, projectRoot: nil)
        XCTAssertEqual(session.tabs, [
            .file(path: "/p/a.swift"),
            .untitled(text: "scratch"),
            .file(path: "/p/b.swift"),
        ])
    }

    func testEmptyUntitledBufferIsDropped() {
        let files = [titled("/p/a.swift"), untitled(""), titled("/p/b.swift")]
        let session = EditorSession.snapshot(openFiles: files, selectedID: nil, projectRoot: nil)
        XCTAssertEqual(session.tabs, [.file(path: "/p/a.swift"), .file(path: "/p/b.swift")])
    }

    func testWhitespaceOnlyUntitledBufferIsStored() {
        // Deliberately no trimming: whitespace is something the user typed.
        let session = EditorSession.snapshot(
            openFiles: [untitled("   \n")],
            selectedID: nil,
            projectRoot: nil
        )
        XCTAssertEqual(session.tabs, [.untitled(text: "   \n")])
    }

    func testEmptyTitledFileIsStored() {
        // An empty *file* still names something on disk; only an empty Untitled
        // scratch buffer is dropped.
        let session = EditorSession.snapshot(
            openFiles: [titled("/p/empty.swift", text: "")],
            selectedID: nil,
            projectRoot: nil
        )
        XCTAssertEqual(session.tabs, [.file(path: "/p/empty.swift")])
    }

    func testSelectionIndexIsOverStoredRecords() {
        let a = titled("/p/a.swift")
        let dropped = untitled("")
        let b = titled("/p/b.swift")
        let session = EditorSession.snapshot(
            openFiles: [a, dropped, b],
            selectedID: b.id,
            projectRoot: nil
        )
        // b is at index 2 in the live model but index 1 among the stored records.
        XCTAssertEqual(session.selectedIndex, 1)
        XCTAssertEqual(session.tabs.count, 2)
    }

    func testSelectionOfDroppedRecordIsNil() {
        let a = titled("/p/a.swift")
        let dropped = untitled("")
        let session = EditorSession.snapshot(
            openFiles: [a, dropped],
            selectedID: dropped.id,
            projectRoot: nil
        )
        XCTAssertNil(session.selectedIndex)
        XCTAssertEqual(session.tabs, [.file(path: "/p/a.swift")])
    }

    func testNoSelectionYieldsNilIndex() {
        let session = EditorSession.snapshot(
            openFiles: [titled("/p/a.swift")],
            selectedID: nil,
            projectRoot: nil
        )
        XCTAssertNil(session.selectedIndex)
    }

    func testUnknownSelectionIDYieldsNilIndex() {
        let session = EditorSession.snapshot(
            openFiles: [titled("/p/a.swift")],
            selectedID: UUID(),
            projectRoot: nil
        )
        XCTAssertNil(session.selectedIndex)
    }

    func testFolderPathIsRecorded() {
        let session = EditorSession.snapshot(
            openFiles: [],
            selectedID: nil,
            projectRoot: URL(fileURLWithPath: "/p/root")
        )
        XCTAssertEqual(session.folderPath, "/p/root")
    }

    func testNoFolderYieldsNilFolderPath() {
        let session = EditorSession.snapshot(
            openFiles: [titled("/p/a.swift")],
            selectedID: nil,
            projectRoot: nil
        )
        XCTAssertNil(session.folderPath)
    }

    func testEmptyModelYieldsEmptySession() {
        let session = EditorSession.snapshot(openFiles: [], selectedID: nil, projectRoot: nil)
        XCTAssertEqual(session, EditorSession())
        XCTAssertTrue(session.isEmpty)
    }

    func testSessionWithOnlyAFolderIsNotEmpty() {
        let session = EditorSession.snapshot(
            openFiles: [],
            selectedID: nil,
            projectRoot: URL(fileURLWithPath: "/p/root")
        )
        XCTAssertFalse(session.isEmpty)
    }

    func testPathsAreStoredVerbatimRatherThanResolved() throws {
        // A real symlink, so `resolvingSymlinksInPath()` would genuinely change the
        // spelling — the snapshot must still store the path as the tab spells it.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditorSessionTests-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let target = real.appendingPathComponent("file.swift")
        try "let x = 1".write(to: target, atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let viaLink = link.appendingPathComponent("file.swift")
        XCTAssertNotEqual(viaLink.resolvingSymlinksInPath().path, viaLink.path)

        let file = OpenFile(url: viaLink, text: "let x = 1", savedText: "let x = 1")
        let session = EditorSession.snapshot(
            openFiles: [file],
            selectedID: file.id,
            projectRoot: nil
        )
        XCTAssertEqual(session.tabs, [.file(path: viaLink.path)])
    }

    // MARK: - SessionTab shape

    func testFactoriesProduceTheExpectedFields() {
        XCTAssertEqual(SessionTab.file(path: "/p/a.swift"), SessionTab(path: "/p/a.swift", text: nil))
        XCTAssertEqual(SessionTab.untitled(text: "hi"), SessionTab(path: nil, text: "hi"))
    }

    func testRecordWithNeitherFieldIsAValidDecode() throws {
        // The future-version tab: an unknown kind whose fields this build skips.
        // It must decode (the batch survives); skipping it is restore's decision.
        let json = Data("{}".utf8)
        let tab = try JSONDecoder().decode(SessionTab.self, from: json)
        XCTAssertNil(tab.path)
        XCTAssertNil(tab.text)
    }

    func testUnknownKeysAreIgnoredWhenDecoding() throws {
        let json = Data(#"{"path":"/p/a.swift","futureField":42}"#.utf8)
        let tab = try JSONDecoder().decode(SessionTab.self, from: json)
        XCTAssertEqual(tab, .file(path: "/p/a.swift"))
    }

    func testSessionRoundTripsThroughAPropertyList() throws {
        let session = EditorSession(
            folderPath: "/p/root",
            tabs: [.file(path: "/p/a.swift"), .untitled(text: "scratch")],
            selectedIndex: 1
        )
        let data = try PropertyListEncoder().encode(session)
        let decoded = try PropertyListDecoder().decode(EditorSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: - SessionStore

    /// A fresh, isolated `UserDefaults` suite per test so stores never read or
    /// write the shared standard domain (the `SettingsStoreTests` precedent).
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "EditorSessionTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testStoreMissingKeyLoadsNil() {
        let store = SessionStore(defaults: makeDefaults())
        XCTAssertNil(store.load())
    }

    func testStoreRoundTripsAcrossTwoInstances() {
        let defaults = makeDefaults()
        let session = EditorSession(
            folderPath: "/p/root",
            tabs: [.file(path: "/p/a.swift"), .untitled(text: "scratch")],
            selectedIndex: 1
        )
        SessionStore(defaults: defaults).save(session)
        // A second store over the same suite is what a relaunch looks like.
        XCTAssertEqual(SessionStore(defaults: defaults).load(), session)
    }

    func testStoreRoundTripsAnEmptySession() {
        let defaults = makeDefaults()
        // "Everything closed" is a real answer and must not read back as
        // "nothing stored" — that would resurrect the session before last.
        SessionStore(defaults: defaults).save(EditorSession())
        let loaded = SessionStore(defaults: defaults).load()
        XCTAssertEqual(loaded, EditorSession())
        XCTAssertTrue(loaded?.isEmpty == true)
    }

    func testStoreSaveReplacesThePreviousSession() {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        store.save(EditorSession(folderPath: "/p/one", tabs: [.file(path: "/p/a.swift")]))
        store.save(EditorSession(folderPath: "/p/two"))
        XCTAssertEqual(store.load(), EditorSession(folderPath: "/p/two"))
    }

    func testStoreClearRemovesTheSession() {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        store.save(EditorSession(folderPath: "/p/root"))
        XCTAssertNotNil(store.load())
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreCorruptBlobLoadsNil() {
        let defaults = makeDefaults()
        defaults.set(Data("not a property list".utf8), forKey: SessionStore.Keys.lastSession)
        XCTAssertNil(SessionStore(defaults: defaults).load())
    }

    func testStoreTruncatedBlobLoadsNil() {
        let defaults = makeDefaults()
        let data = try! PropertyListEncoder().encode(
            EditorSession(folderPath: "/p/root", tabs: [.file(path: "/p/a.swift")])
        )
        defaults.set(data.prefix(data.count / 2), forKey: SessionStore.Keys.lastSession)
        XCTAssertNil(SessionStore(defaults: defaults).load())
    }

    func testStoreValueOfTheWrongTypeLoadsNil() {
        let defaults = makeDefaults()
        defaults.set("a string, not a blob", forKey: SessionStore.Keys.lastSession)
        XCTAssertNil(SessionStore(defaults: defaults).load())
    }

    func testStoreLoadsABlobCarryingUnknownKeys() throws {
        // Forward compatibility: a session written by a future version carries
        // keys this build has no property for — at the session level and inside a
        // tab record — and must still load with everything this build understands.
        let plist: [String: Any] = [
            "folderPath": "/p/root",
            "futureSessionField": 42,
            "tabs": [
                ["path": "/p/a.swift", "futureTabField": true],
                ["text": "scratch"],
            ],
            "selectedIndex": 1,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let defaults = makeDefaults()
        defaults.set(data, forKey: SessionStore.Keys.lastSession)

        XCTAssertEqual(
            SessionStore(defaults: defaults).load(),
            EditorSession(
                folderPath: "/p/root",
                tabs: [.file(path: "/p/a.swift"), .untitled(text: "scratch")],
                selectedIndex: 1
            )
        )
    }

    func testStoreLoadsABlobWhoseTabNamesNeitherPathNorText() throws {
        // The future-version tab, seen through the store: one record this build
        // cannot make sense of must not cost the user the whole session. It
        // decodes as an empty record here; restore is what skips it.
        let plist: [String: Any] = [
            "tabs": [
                ["path": "/p/a.swift"],
                ["futureKind": "terminal"],
                ["path": "/p/b.swift"],
            ],
            "selectedIndex": 2,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let defaults = makeDefaults()
        defaults.set(data, forKey: SessionStore.Keys.lastSession)

        let loaded = SessionStore(defaults: defaults).load()
        XCTAssertEqual(loaded?.tabs, [
            .file(path: "/p/a.swift"),
            SessionTab(),
            .file(path: "/p/b.swift"),
        ])
        XCTAssertEqual(loaded?.selectedIndex, 2)
    }
}
