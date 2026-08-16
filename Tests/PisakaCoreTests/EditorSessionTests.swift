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

    // MARK: - SessionCatalog

    private func session(_ folderPath: String?, _ marker: String) -> EditorSession {
        EditorSession(folderPath: folderPath, tabs: [.file(path: marker)])
    }

    func testCatalogStartsEmpty() {
        let catalog = SessionCatalog()
        XCTAssertTrue(catalog.entries.isEmpty)
        XCTAssertNil(catalog.lastOpened)
        XCTAssertNil(catalog.session(forFolder: URL(fileURLWithPath: "/p/root")))
        XCTAssertNil(catalog.session(forFolder: nil))
    }

    func testCatalogHeadIsTheLastOpenedPointer() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/one", "/p/one/a.swift"))
        catalog.store(session("/p/two", "/p/two/b.swift"))
        XCTAssertEqual(catalog.lastOpened, session("/p/two", "/p/two/b.swift"))
        XCTAssertEqual(catalog.entries.first?.folderPath, "/p/two")
    }

    func testCatalogKeysByCanonicalPath() {
        // /tmp vs /private/tmp: the two spellings of one real directory must land
        // on one entry, not accumulate one session per spelling.
        var catalog = SessionCatalog()
        catalog.store(session("/tmp", "/tmp/a.swift"))
        catalog.store(session("/private/tmp", "/tmp/b.swift"))
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(
            catalog.session(forFolder: URL(fileURLWithPath: "/tmp")),
            session("/private/tmp", "/tmp/b.swift")
        )
    }

    func testCatalogKeyIgnoresTrailingSlashesAndDotComponents() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/root", "/p/root/a.swift"))
        for spelling in ["/p/root/", "/p/root/.", "/p/root/sub/..", "/p/./root"] {
            XCTAssertEqual(
                catalog.session(forFolder: URL(fileURLWithPath: spelling)),
                session("/p/root", "/p/root/a.swift"),
                "spelling \(spelling) should match the stored /p/root entry"
            )
        }
        // …and storing under one of them replaces rather than adds.
        catalog.store(session("/p/root/", "/p/root/b.swift"))
        XCTAssertEqual(catalog.entries.count, 1)
    }

    func testCatalogNilFolderIsItsOwnKey() {
        var catalog = SessionCatalog()
        catalog.store(session(nil, "/p/scratch.swift"))
        catalog.store(session("/p/root", "/p/root/a.swift"))
        XCTAssertEqual(catalog.entries.count, 2)
        XCTAssertEqual(catalog.session(forFolder: nil), session(nil, "/p/scratch.swift"))
        // A real folder never matches the no-folder entry, in either direction.
        XCTAssertEqual(
            catalog.session(forFolder: URL(fileURLWithPath: "/p/root")),
            session("/p/root", "/p/root/a.swift")
        )
        XCTAssertNil(catalog.session(forFolder: URL(fileURLWithPath: "/p/other")))
    }

    func testCatalogStorePromotesAnExistingEntryToTheHead() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/one", "/p/one/a.swift"))
        catalog.store(session("/p/two", "/p/two/b.swift"))
        catalog.store(session("/p/three", "/p/three/c.swift"))
        catalog.store(session("/p/one", "/p/one/a.swift"))
        XCTAssertEqual(
            catalog.entries.map(\.folderPath),
            ["/p/one", "/p/three", "/p/two"]
        )
    }

    func testCatalogStoreReplacesRatherThanDuplicates() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/root", "/p/root/a.swift"))
        catalog.store(session("/p/root", "/p/root/b.swift"))
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(
            catalog.session(forFolder: URL(fileURLWithPath: "/p/root")),
            session("/p/root", "/p/root/b.swift")
        )
    }

    func testCatalogStoreAdoptsTheLatestSpelling() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/root", "/p/root/a.swift"))
        catalog.store(session("/p/root/", "/p/root/b.swift"))
        XCTAssertEqual(catalog.entries.map(\.folderPath), ["/p/root/"])
    }

    func testCatalogCapEvictsTheLeastRecentlyUsedTail() {
        var catalog = SessionCatalog()
        for index in 0..<SessionCatalog.maxStoredProjects {
            catalog.store(session("/p/\(index)", "/p/\(index)/a.swift"))
        }
        XCTAssertEqual(catalog.entries.count, SessionCatalog.maxStoredProjects)
        catalog.store(session("/p/new", "/p/new/a.swift"))
        XCTAssertEqual(catalog.entries.count, SessionCatalog.maxStoredProjects)
        XCTAssertEqual(catalog.entries.first?.folderPath, "/p/new")
        // /p/0 was the oldest and is the one that went.
        XCTAssertNil(catalog.session(forFolder: URL(fileURLWithPath: "/p/0")))
        XCTAssertNotNil(catalog.session(forFolder: URL(fileURLWithPath: "/p/1")))
    }

    func testCatalogCapNeverEvictsTheHeadJustStored() {
        var catalog = SessionCatalog()
        catalog.store(session("/p/one", "/p/one/a.swift"), limit: 1)
        catalog.store(session("/p/two", "/p/two/b.swift"), limit: 1)
        XCTAssertEqual(catalog.entries.map(\.folderPath), ["/p/two"])
        // A degenerate limit must still leave the entry that was just stored.
        catalog.store(session("/p/three", "/p/three/c.swift"), limit: 0)
        XCTAssertEqual(catalog.entries.map(\.folderPath), ["/p/three"])
    }

    func testCatalogHugeUntitledTextEvictsNothing() {
        // Retention is by entry count, never by byte size: one project's
        // pathologically large scratch buffer must not cost another its session.
        var catalog = SessionCatalog()
        catalog.store(session("/p/small", "/p/small/a.swift"))
        catalog.store(
            EditorSession(
                folderPath: "/p/huge",
                tabs: [.untitled(text: String(repeating: "x", count: 2_000_000))]
            )
        )
        catalog.store(session("/p/other", "/p/other/a.swift"))
        XCTAssertEqual(catalog.entries.count, 3)
        XCTAssertEqual(
            catalog.session(forFolder: URL(fileURLWithPath: "/p/small")),
            session("/p/small", "/p/small/a.swift")
        )
        XCTAssertEqual(
            catalog.session(forFolder: URL(fileURLWithPath: "/p/huge"))?.tabs.first?.text?.count,
            2_000_000
        )
    }

    func testCatalogMigratingSeedsAOneEntryCatalog() {
        let legacy = EditorSession(
            folderPath: "/p/root",
            tabs: [.file(path: "/p/root/a.swift")],
            selectedIndex: 0
        )
        let catalog = SessionCatalog.migrating(legacy)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.lastOpened, legacy)
        XCTAssertEqual(catalog.session(forFolder: URL(fileURLWithPath: "/p/root")), legacy)
    }

    func testCatalogMigratingAFolderlessSessionKeysItUnderNil() {
        let legacy = EditorSession(tabs: [.untitled(text: "scratch")])
        let catalog = SessionCatalog.migrating(legacy)
        XCTAssertEqual(catalog.lastOpened, legacy)
        XCTAssertEqual(catalog.session(forFolder: nil), legacy)
        XCTAssertNil(catalog.session(forFolder: URL(fileURLWithPath: "/p/root")))
    }

    func testCatalogRoundTripsThroughAPropertyListPreservingOrder() throws {
        var catalog = SessionCatalog()
        catalog.store(session(nil, "/p/scratch.swift"))
        catalog.store(session("/p/one", "/p/one/a.swift"))
        catalog.store(
            EditorSession(
                folderPath: "/p/two",
                tabs: [.file(path: "/p/two/b.swift"), .untitled(text: "scratch")],
                selectedIndex: 1
            )
        )
        let data = try PropertyListEncoder().encode(catalog)
        let decoded = try PropertyListDecoder().decode(SessionCatalog.self, from: data)
        XCTAssertEqual(decoded, catalog)
        XCTAssertEqual(decoded.entries.map(\.folderPath), ["/p/two", "/p/one", nil])
        XCTAssertEqual(decoded.lastOpened?.folderPath, "/p/two")
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

    /// Write `session` under the pre-catalog single-blob key, which is what a
    /// `UserDefaults` domain written by the version before this change holds.
    private func writeLegacyBlob(_ session: EditorSession, into defaults: UserDefaults) throws {
        let data = try PropertyListEncoder().encode(session)
        defaults.set(data, forKey: SessionStore.Keys.lastSession)
    }

    func testStoreMissingKeyLoadsNil() {
        let store = SessionStore(defaults: makeDefaults())
        XCTAssertNil(store.loadLastOpened())
        XCTAssertNil(store.session(forFolder: URL(fileURLWithPath: "/p/root")))
        XCTAssertNil(store.session(forFolder: nil))
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
        let reopened = SessionStore(defaults: defaults)
        XCTAssertEqual(reopened.loadLastOpened(), session)
        XCTAssertEqual(reopened.session(forFolder: URL(fileURLWithPath: "/p/root")), session)
    }

    func testStoreRoundTripsAnEmptySession() {
        let defaults = makeDefaults()
        // "Everything closed" is a real answer and must not read back as
        // "nothing stored" — that would resurrect the session before last.
        SessionStore(defaults: defaults).save(EditorSession())
        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(store.loadLastOpened(), EditorSession())
        XCTAssertTrue(store.loadLastOpened()?.isEmpty == true)
        // The no-folder workspace is a key like any other.
        XCTAssertEqual(store.session(forFolder: nil), EditorSession())
    }

    func testStoreKeepsBothProjectsAndMakesTheLatestTheHead() {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        let one = EditorSession(folderPath: "/p/one", tabs: [.file(path: "/p/one/a.swift")])
        let two = EditorSession(folderPath: "/p/two", tabs: [.file(path: "/p/two/b.swift")])
        store.save(one)
        store.save(two)

        // The old store replaced; the keyed one keeps both and points at the last.
        XCTAssertEqual(store.loadLastOpened(), two)
        XCTAssertEqual(store.session(forFolder: URL(fileURLWithPath: "/p/one")), one)
        XCTAssertEqual(store.session(forFolder: URL(fileURLWithPath: "/p/two")), two)
    }

    func testStoreSaveUnderADifferentSpellingOverwritesTheSameEntry() throws {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        store.save(EditorSession(folderPath: "/tmp", tabs: [.file(path: "/tmp/a.swift")]))
        store.save(EditorSession(folderPath: "/private/tmp/", tabs: [.file(path: "/tmp/b.swift")]))

        // One project, one entry — spellings must not accumulate sessions.
        let data = try XCTUnwrap(defaults.data(forKey: SessionStore.Keys.projectSessions))
        let catalog = try PropertyListDecoder().decode(SessionCatalog.self, from: data)
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.folderPath, "/private/tmp/")
        XCTAssertEqual(
            store.session(forFolder: URL(fileURLWithPath: "/tmp")),
            EditorSession(folderPath: "/private/tmp/", tabs: [.file(path: "/tmp/b.swift")])
        )
    }

    func testStoreSaveOfOneProjectLeavesAnotherProjectsSessionIntact() {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        let one = EditorSession(folderPath: "/p/one", tabs: [.untitled(text: "one's scratch")])
        store.save(one)
        store.save(EditorSession(folderPath: "/p/two"))
        store.save(EditorSession(folderPath: "/p/two", tabs: [.file(path: "/p/two/b.swift")]))
        XCTAssertEqual(store.session(forFolder: URL(fileURLWithPath: "/p/one")), one)
    }

    func testStoreCapsTheStoredProjects() {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        for index in 0...SessionCatalog.maxStoredProjects {
            store.save(EditorSession(folderPath: "/p/\(index)"))
        }
        // The first one saved is the least recently opened and is the one gone.
        XCTAssertNil(store.session(forFolder: URL(fileURLWithPath: "/p/0")))
        XCTAssertNotNil(store.session(forFolder: URL(fileURLWithPath: "/p/1")))
        XCTAssertEqual(store.loadLastOpened()?.folderPath, "/p/\(SessionCatalog.maxStoredProjects)")
    }

    func testStoreClearRemovesEverySession() throws {
        let defaults = makeDefaults()
        let store = SessionStore(defaults: defaults)
        try writeLegacyBlob(EditorSession(folderPath: "/p/legacy"), into: defaults)
        store.save(EditorSession(folderPath: "/p/one"))
        store.save(EditorSession(folderPath: "/p/two"))
        XCTAssertNotNil(store.loadLastOpened())

        store.clear()

        // Both keys go: leaving the legacy blob would migrate it straight back in.
        XCTAssertNil(store.loadLastOpened())
        XCTAssertNil(store.session(forFolder: URL(fileURLWithPath: "/p/one")))
        XCTAssertNil(defaults.object(forKey: SessionStore.Keys.lastSession))
    }

    func testStoreCorruptBlobLoadsNil() {
        let defaults = makeDefaults()
        defaults.set(Data("not a property list".utf8), forKey: SessionStore.Keys.projectSessions)
        XCTAssertNil(SessionStore(defaults: defaults).loadLastOpened())
    }

    func testStoreTruncatedBlobLoadsNil() throws {
        let defaults = makeDefaults()
        var catalog = SessionCatalog()
        catalog.store(EditorSession(folderPath: "/p/root", tabs: [.file(path: "/p/a.swift")]))
        let data = try PropertyListEncoder().encode(catalog)
        defaults.set(data.prefix(data.count / 2), forKey: SessionStore.Keys.projectSessions)
        XCTAssertNil(SessionStore(defaults: defaults).loadLastOpened())
    }

    func testStoreValueOfTheWrongTypeLoadsNil() {
        let defaults = makeDefaults()
        defaults.set("a string, not a blob", forKey: SessionStore.Keys.projectSessions)
        let store = SessionStore(defaults: defaults)
        XCTAssertNil(store.loadLastOpened())
        XCTAssertNil(store.session(forFolder: URL(fileURLWithPath: "/p/root")))
    }

    func testStoreCorruptCatalogDoesNotResurrectTheLegacyBlob() throws {
        let defaults = makeDefaults()
        try writeLegacyBlob(EditorSession(folderPath: "/p/legacy"), into: defaults)
        defaults.set(Data("not a property list".utf8), forKey: SessionStore.Keys.projectSessions)
        // Garbage under the new key means something wrote it; a blank slate beats
        // silently restoring a session from before the upgrade.
        XCTAssertNil(SessionStore(defaults: defaults).loadLastOpened())
    }

    // MARK: - SessionStore migration

    func testStoreMigratesALegacyBlobWithAFolder() throws {
        let defaults = makeDefaults()
        let legacy = EditorSession(
            folderPath: "/p/root",
            tabs: [.file(path: "/p/root/a.swift"), .untitled(text: "scratch")],
            selectedIndex: 1
        )
        try writeLegacyBlob(legacy, into: defaults)

        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(store.loadLastOpened(), legacy)
        XCTAssertEqual(store.session(forFolder: URL(fileURLWithPath: "/p/root")), legacy)
        XCTAssertNil(store.session(forFolder: nil))
    }

    func testStoreMigratesALegacyBlobWithoutAFolder() throws {
        let defaults = makeDefaults()
        let legacy = EditorSession(tabs: [.untitled(text: "scratch")], selectedIndex: 0)
        try writeLegacyBlob(legacy, into: defaults)

        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(store.loadLastOpened(), legacy)
        XCTAssertEqual(store.session(forFolder: nil), legacy)
        XCTAssertNil(store.session(forFolder: URL(fileURLWithPath: "/p/root")))
    }

    func testStoreMigrationLeavesTheLegacyKeyInPlaceAndNeverWritesItAgain() throws {
        let defaults = makeDefaults()
        let legacy = EditorSession(folderPath: "/p/root")
        try writeLegacyBlob(legacy, into: defaults)
        let legacyData = defaults.data(forKey: SessionStore.Keys.lastSession)

        let store = SessionStore(defaults: defaults)
        store.save(EditorSession(folderPath: "/p/other"))

        // Kept, byte for byte: deleting buys nothing, and a downgrade can still
        // restore from it.
        XCTAssertEqual(defaults.data(forKey: SessionStore.Keys.lastSession), legacyData)
    }

    func testStoreIgnoresTheLegacyBlobOnceTheCatalogExists() throws {
        let defaults = makeDefaults()
        try writeLegacyBlob(EditorSession(folderPath: "/p/legacy"), into: defaults)
        let store = SessionStore(defaults: defaults)
        store.save(EditorSession(folderPath: "/p/new"))

        XCTAssertEqual(store.loadLastOpened()?.folderPath, "/p/new")
        // The migrated entry is still there — but it came in through the catalog,
        // and a later save must not re-read the legacy key.
        store.save(EditorSession(folderPath: "/p/newer"))
        XCTAssertEqual(store.loadLastOpened()?.folderPath, "/p/newer")
        XCTAssertEqual(
            store.session(forFolder: URL(fileURLWithPath: "/p/legacy"))?.folderPath,
            "/p/legacy"
        )
    }

    func testStoreMigrationSurvivesAnUndecodableLegacyBlob() {
        let defaults = makeDefaults()
        defaults.set(Data("not a property list".utf8), forKey: SessionStore.Keys.lastSession)
        XCTAssertNil(SessionStore(defaults: defaults).loadLastOpened())
    }

    func testStoreLoadsACatalogCarryingUnknownKeys() throws {
        // Forward compatibility: a catalog written by a future version carries
        // keys this build has no property for — at the catalog, entry, session and
        // tab levels — and must still load with everything this build understands.
        let plist: [String: Any] = [
            "futureCatalogField": "head-of-mru",
            "entries": [
                [
                    "folderPath": "/p/root",
                    "futureEntryField": true,
                    "session": [
                        "folderPath": "/p/root",
                        "futureSessionField": 42,
                        "tabs": [
                            ["path": "/p/a.swift", "futureTabField": true],
                            ["text": "scratch"],
                        ],
                        "selectedIndex": 1,
                    ],
                ]
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let defaults = makeDefaults()
        defaults.set(data, forKey: SessionStore.Keys.projectSessions)

        let expected = EditorSession(
            folderPath: "/p/root",
            tabs: [.file(path: "/p/a.swift"), .untitled(text: "scratch")],
            selectedIndex: 1
        )
        let store = SessionStore(defaults: defaults)
        XCTAssertEqual(store.loadLastOpened(), expected)
        XCTAssertEqual(store.session(forFolder: URL(fileURLWithPath: "/p/root")), expected)
    }

    func testStoreMigratesALegacyBlobCarryingUnknownKeys() throws {
        // The same permissiveness on the migration path: the legacy blob is
        // decoded by the very same session decoder before it seeds the catalog.
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
            SessionStore(defaults: defaults).loadLastOpened(),
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

        let loaded = SessionStore(defaults: defaults).loadLastOpened()
        XCTAssertEqual(loaded?.tabs, [
            .file(path: "/p/a.swift"),
            SessionTab(),
            .file(path: "/p/b.swift"),
        ])
        XCTAssertEqual(loaded?.selectedIndex, 2)
    }
}
