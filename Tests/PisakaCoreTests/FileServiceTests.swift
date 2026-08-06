import XCTest
@testable import PisakaCore

final class FileServiceTests: XCTestCase {
    func testWriteThenReadRoundTrip() throws {
        let service = FileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = "line one\nline two\n"
        try service.write(original, to: url)
        let readBack = try service.read(url: url)

        XCTAssertEqual(readBack, original)
    }

    func testReadMissingFileThrows() {
        let service = FileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")

        XCTAssertThrowsError(try service.read(url: url))
    }

    func testRoundTripPreservesMultibyteUnicode() throws {
        let service = FileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let original = "héllo 日本語 🚀\n"
        try service.write(original, to: url)

        XCTAssertEqual(try service.read(url: url), original)
    }

    func testRoundTripPreservesEmptyString() throws {
        let service = FileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try service.write("", to: url)

        XCTAssertEqual(try service.read(url: url), "")
    }

    func testWriteOverwritesExistingContents() throws {
        let service = FileService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try service.write("first", to: url)
        try service.write("second", to: url)

        XCTAssertEqual(try service.read(url: url), "second")
    }

    func testContentsOfDirectorySortsFoldersFirstThenAlphabetical() throws {
        let service = FileService()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try fm.createDirectory(at: dir.appendingPathComponent("Zebra"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try service.write("", to: dir.appendingPathComponent("Beta.txt"))
        try service.write("", to: dir.appendingPathComponent("apple.txt"))

        let entries = try service.contentsOfDirectory(at: dir)

        XCTAssertEqual(entries.map(\.name), ["alpha", "Zebra", "apple.txt", "Beta.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false, false])
    }

    func testContentsOfDirectoryShowsDotfilesButHidesServiceEntries() throws {
        let service = FileService()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try service.write("", to: dir.appendingPathComponent("visible.txt"))
        try service.write("", to: dir.appendingPathComponent(".gitignore"))
        try service.write("", to: dir.appendingPathComponent(".DS_Store"))
        try fm.createDirectory(at: dir.appendingPathComponent(".github"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)

        let entries = try service.contentsOfDirectory(at: dir)

        // Dotfiles are visible (VS Code-style); only the exact service names in
        // `excludedEntryNames` (`.git`, `.DS_Store`) are hidden — a visible dot
        // *directory* (`.github`) and a visible dot *file* (`.gitignore`) both
        // survive. Order is directories-first, then `localizedCaseInsensitiveCompare`:
        // `.github` precedes `src` because the first differing letters are `g < s`,
        // and `.gitignore` precedes `visible.txt` because `g < v`. The expectation
        // does *not* rest on a leading dot sorting before letters — punctuation
        // weight in that comparator is locale-dependent.
        XCTAssertEqual(entries.map(\.name), [".github", "src", ".gitignore", "visible.txt"])
        XCTAssertEqual(entries.map(\.isDirectory), [true, true, false, false])
    }

    /// The exclusion rule the listing and the tree's create/rename validation
    /// share: exact names only, so no dotfile is caught by prefix.
    func testIsExcludedEntryNameMatchesServiceNamesExactly() {
        XCTAssertTrue(FileService.isExcludedEntryName(".git"))
        XCTAssertTrue(FileService.isExcludedEntryName(".DS_Store"))
        XCTAssertFalse(FileService.isExcludedEntryName(".gitignore"))
        XCTAssertFalse(FileService.isExcludedEntryName(".github"))
        XCTAssertFalse(FileService.isExcludedEntryName("git"))
        XCTAssertFalse(FileService.isExcludedEntryName(""))
    }

    /// Create-time validation is *stricter* than the listing: the same service
    /// names, compared case-insensitively, because a case-insensitive volume
    /// (the APFS default) resolves `.GIT` onto an existing `.git`.
    func testIsReservedCreateNameMatchesServiceNamesCaseInsensitively() {
        XCTAssertTrue(FileService.isReservedCreateName(".git"))
        XCTAssertTrue(FileService.isReservedCreateName(".GIT"))
        XCTAssertTrue(FileService.isReservedCreateName(".Git"))
        XCTAssertTrue(FileService.isReservedCreateName(".DS_Store"))
        XCTAssertTrue(FileService.isReservedCreateName(".ds_store"))
        XCTAssertFalse(FileService.isReservedCreateName(".gitignore"))
        XCTAssertFalse(FileService.isReservedCreateName(".github"))
        XCTAssertFalse(FileService.isReservedCreateName("git"))
        XCTAssertFalse(FileService.isReservedCreateName(""))
    }

    /// The two predicates over the one `excludedEntryNames` set stay apart: the
    /// *listing* rule remains exact-match, so a user's `.GIT` folder is still
    /// shown (git and Finder write the exact names).
    func testExcludedEntryNameStaysExactWhileCreateNameIsCaseInsensitive() {
        XCTAssertFalse(FileService.isExcludedEntryName(".GIT"))
        XCTAssertFalse(FileService.isExcludedEntryName(".Ds_Store"))
        XCTAssertTrue(FileService.isReservedCreateName(".GIT"))
        XCTAssertTrue(FileService.isReservedCreateName(".Ds_Store"))
    }

    /// The seam the app's `projectTestEvidence()` relies on since the explicit
    /// `.mocharc*` probing was removed: a dot-prefixed runner config in the
    /// project root reaches `TestCommand` through the ordinary listing.
    func testDotfileRunnerConfigReachesTestCommandThroughListing() throws {
        let service = FileService()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try service.write("", to: dir.appendingPathComponent(".mocharc.yml"))

        let names = Set(try service.contentsOfDirectory(at: dir).map(\.name))
        let evidence = ProjectTestEvidence(rootEntryNames: names, manifests: [:])

        XCTAssertEqual(
            TestCommand.command(
                forFileName: "a.test.js",
                absolutePath: "/p/a.test.js",
                evidence: evidence
            ),
            .command("npx mocha '/p/a.test.js'")
        )
    }

    func testContentsOfDirectoryReturnsEmptyForEmptyDirectory() throws {
        let service = FileService()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // An existing-but-empty directory lists as [] (distinct from a missing
        // directory, which throws) — the tree renders this as an empty folder.
        XCTAssertEqual(try service.contentsOfDirectory(at: dir), [])
    }

    func testContentsOfDirectoryThrowsForMissingDirectory() {
        let service = FileService()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try service.contentsOfDirectory(at: dir))
    }

    // MARK: - createFile

    func testCreateFileCreatesEmptyFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("new.txt")

        try service.createFile(at: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try service.read(url: url), "")
    }

    func testCreateFileThrowsOnExistingPath() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("exists.txt")
        try service.write("hi", to: url)

        XCTAssertThrowsError(try service.createFile(at: url)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
        // The existing content is untouched.
        XCTAssertEqual(try service.read(url: url), "hi")
    }

    func testCreateFileThrowsWhenDirectoryOccupiesPath() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("name")
        try service.createDirectory(at: url)

        // A directory already at the target path is also a collision (never clobber).
        XCTAssertThrowsError(try service.createFile(at: url)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
    }

    func testCreateFileThrowsOnMissingParent() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing").appendingPathComponent("new.txt")

        XCTAssertThrowsError(try service.createFile(at: url))
    }

    // MARK: - createDirectory

    func testCreateDirectoryCreatesDirectory() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("subdir")

        try service.createDirectory(at: url)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateDirectoryThrowsOnExistingPath() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("subdir")
        try service.createDirectory(at: url)

        XCTAssertThrowsError(try service.createDirectory(at: url)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
    }

    func testCreateDirectoryThrowsWhenFileOccupiesPath() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("name")
        try service.write("hi", to: url)

        // A file already at the target path is also a collision (never clobber).
        XCTAssertThrowsError(try service.createDirectory(at: url)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
        XCTAssertEqual(try service.read(url: url), "hi")
    }

    func testCreateDirectoryThrowsOnMissingParent() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing").appendingPathComponent("subdir")

        XCTAssertThrowsError(try service.createDirectory(at: url))
    }

    // MARK: - ensureDirectory

    func testEnsureDirectoryCreatesWholeChain() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")

        try service.ensureDirectory(at: c)

        for url in [a, b, c] {
            var isDir: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                "\(url.lastPathComponent) should exist"
            )
            XCTAssertTrue(isDir.boolValue, "\(url.lastPathComponent) should be a directory")
        }
    }

    func testEnsureDirectoryReusesExistingIntermediate() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try service.createDirectory(at: a)
        // A marker inside the pre-existing directory: reuse must not disturb it.
        let marker = a.appendingPathComponent("keep.txt")
        try service.write("keep", to: marker)
        let c = a.appendingPathComponent("b").appendingPathComponent("c")

        try service.ensureDirectory(at: c)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(try service.read(url: marker), "keep")
    }

    func testEnsureDirectoryOnExistingChainIsNoOp() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = dir.appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
        try service.ensureDirectory(at: c)
        let marker = c.appendingPathComponent("keep.txt")
        try service.write("keep", to: marker)

        // Idempotent: an existing directory is reused, never re-created.
        try service.ensureDirectory(at: c)

        XCTAssertEqual(try service.read(url: marker), "keep")
    }

    func testEnsureDirectoryThrowsWhenFileOccupiesIntermediate() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try service.write("content", to: a)
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")

        XCTAssertThrowsError(try service.ensureDirectory(at: c)) { error in
            XCTAssertEqual(error as? FileServiceError, .notADirectory(name: "a"))
        }
        // The check runs before any write, so nothing deeper was created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.path))
        XCTAssertEqual(try service.read(url: a), "content")
    }

    func testEnsureDirectoryThrowsWhenFileOccupiesFinalComponent() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try service.createDirectory(at: a)
        let b = a.appendingPathComponent("b")
        try service.write("content", to: b)

        XCTAssertThrowsError(try service.ensureDirectory(at: b)) { error in
            XCTAssertEqual(error as? FileServiceError, .notADirectory(name: "b"))
        }
        XCTAssertEqual(try service.read(url: b), "content")
    }

    func testEnsureDirectoryReusesSymlinkToDirectoryOnThePath() throws {
        // Documented, deliberate `mkdir -p` behavior: the existence/type probe
        // dereferences the link, so the chain continues *inside* its target.
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try service.createDirectory(at: target)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try service.ensureDirectory(at: link.appendingPathComponent("a").appendingPathComponent("b"))

        // The chain landed in the link's target, not beside the link.
        var isDir: ObjCBool = false
        let inTarget = target.appendingPathComponent("a").appendingPathComponent("b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inTarget.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        // The link itself was reused, never replaced by a real directory.
        XCTAssertEqual(service.symbolicLinkDestination(at: link), target.path)
    }

    func testEnsureDirectoryThrowsWhenSymlinkToFileOccupiesThePath() throws {
        // The probe dereferences the link, so a link to a *file* is the same
        // "not a folder" refusal as the file itself — named by the link.
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file.txt")
        try service.write("content", to: file)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let deeper = link.appendingPathComponent("a")
        XCTAssertThrowsError(try service.ensureDirectory(at: deeper)) { error in
            XCTAssertEqual(error as? FileServiceError, .notADirectory(name: "link"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deeper.path))
        XCTAssertEqual(try service.read(url: file), "content")
    }

    func testEnsureDirectoryDoesNotRollBackAPartiallyCreatedChain() throws {
        // `mkdir -p` semantics: a prefix created before a later step fails is
        // left on disk. The app's create flow depends on this (it refreshes the
        // tree on failure so those folders are visible).
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        // NAME_MAX is 255 on APFS/HFS+, so the deepest component fails to be
        // created *after* its parents already succeeded.
        let tooLong = String(repeating: "x", count: 512)
        let deepest = a.appendingPathComponent("b").appendingPathComponent(tooLong)

        XCTAssertThrowsError(try service.ensureDirectory(at: deepest))

        for url in [a, a.appendingPathComponent("b")] {
            var isDir: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                "\(url.lastPathComponent) should survive the later failure"
            )
            XCTAssertTrue(isDir.boolValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deepest.path))
    }

    func testEnsureDirectoryToleratesADirectoryCreatedConcurrently() throws {
        // The probe and the create are two syscalls: another writer (a build or
        // a `git` run in the embedded terminal) can create the same directory in
        // between, and `ensureDirectory`'s postcondition — "a directory exists
        // here" — is then already satisfied, so the create's `EEXIST` must not
        // fail the operation.
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try service.createDirectory(at: a)

        XCTAssertNoThrow(
            try service.reconcileDirectoryCreateFailure(at: a, error: CocoaError(.fileWriteFileExists))
        )
    }

    func testEnsureDirectoryReportsANonDirectoryThatAppearedDuringCreate() throws {
        // The same race, but the racer created a *file* at the path: report the
        // same `.notADirectory` the up-front probe would have raised, not the
        // raw `FileManager` error.
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try service.write("content", to: a)

        XCTAssertThrowsError(
            try service.reconcileDirectoryCreateFailure(at: a, error: CocoaError(.fileWriteFileExists))
        ) { error in
            XCTAssertEqual(error as? FileServiceError, .notADirectory(name: "a"))
        }
    }

    func testEnsureDirectoryRethrowsWhenThePathIsStillAbsentAfterAFailedCreate() throws {
        // No race — a genuine failure (missing/unwritable parent). The original
        // `FileManager` error must survive so the alert explains the real cause.
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing")

        XCTAssertThrowsError(
            try service.reconcileDirectoryCreateFailure(at: missing, error: CocoaError(.fileNoSuchFile))
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
    }

    func testEnsureDirectoryThrowsWhenADanglingSymlinkOccupiesTheFinalComponent() throws {
        // End-to-end cover of the reconcile path's rethrow: the probe
        // dereferences the dead link and sees nothing, `mkdir` then fails with
        // `EEXIST` on the link itself, and the re-probe still finds nothing — so
        // the create must fail rather than silently "succeed".
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: dir.appendingPathComponent("gone")
        )

        XCTAssertThrowsError(try service.ensureDirectory(at: link))
        // Still a symlink — never replaced by a real directory.
        XCTAssertEqual(
            service.symbolicLinkDestination(at: link),
            dir.appendingPathComponent("gone").path
        )
    }

    func testEnsureDirectoryDefaultsToUnsupportedOnAStubService() {
        // The protocol-extension default is what keeps the read/write-only test
        // stubs compiling; it must *throw*, never silently no-op, or a create
        // would appear to succeed while writing nothing.
        struct ReadWriteOnlyService: FileServicing {
            func read(url: URL) throws -> String { "" }
            func write(_ text: String, to url: URL) throws {}
            func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        }

        XCTAssertThrowsError(
            try ReadWriteOnlyService().ensureDirectory(at: URL(fileURLWithPath: "/tmp/x"))
        ) { error in
            XCTAssertEqual(error as? FileServiceError, .unsupported)
        }
    }

    // MARK: - move

    func testMoveRenamesItem() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("old.txt")
        let destination = dir.appendingPathComponent("new.txt")
        try service.write("content", to: source)

        try service.move(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try service.read(url: destination), "content")
    }

    func testMoveThrowsOnCollision() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("old.txt")
        let destination = dir.appendingPathComponent("new.txt")
        try service.write("source", to: source)
        try service.write("destination", to: destination)

        XCTAssertThrowsError(try service.move(from: source, to: destination)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
        // Neither file is clobbered.
        XCTAssertEqual(try service.read(url: source), "source")
        XCTAssertEqual(try service.read(url: destination), "destination")
    }

    func testMoveRenamesDirectoryTreePreservingContents() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("old")
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try service.write("a", to: source.appendingPathComponent("a.txt"))
        try service.write("b", to: nested.appendingPathComponent("b.txt"))
        let destination = dir.appendingPathComponent("new")

        try service.move(from: source, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try service.read(url: destination.appendingPathComponent("a.txt")), "a")
        XCTAssertEqual(
            try service.read(url: destination.appendingPathComponent("nested/b.txt")),
            "b"
        )
    }

    func testMoveThrowsWhenDestinationDirectoryExists() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("file.txt")
        try service.write("content", to: source)
        let destination = dir.appendingPathComponent("dir")
        try service.createDirectory(at: destination)

        XCTAssertThrowsError(try service.move(from: source, to: destination)) { error in
            XCTAssertEqual(error as? FileServiceError, .alreadyExists)
        }
        XCTAssertEqual(try service.read(url: source), "content")
    }

    func testMoveAllowsCaseOnlyRename() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("file.txt")
        let destination = dir.appendingPathComponent("File.txt")
        try service.write("content", to: source)

        // A case-only rename is not a collision with itself, even on a
        // case-insensitive volume where the destination path "already exists".
        try service.move(from: source, to: destination)

        XCTAssertEqual(try service.read(url: destination), "content")
        let names = try service.contentsOfDirectory(at: dir).map(\.name)
        XCTAssertEqual(names, ["File.txt"])
    }

    // MARK: - removeItem

    func testRemoveItemDeletesFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doomed.txt")
        try service.write("bye", to: url)

        try service.removeItem(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveItemDeletesDirectoryTree() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        let nested = tree.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try service.write("a", to: tree.appendingPathComponent("a.txt"))
        try service.write("b", to: nested.appendingPathComponent("b.txt"))

        try service.removeItem(at: tree)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
    }

    func testRemoveItemThrowsForMissingPath() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing.txt")

        // The view layer surfaces this as a non-fatal alert.
        XCTAssertThrowsError(try service.removeItem(at: url))
    }

    // MARK: - FileServiceError messages

    func testErrorDescriptionsAreHumanReadable() {
        // `NSAlert(error:)` shows `localizedDescription`, which for a raw enum
        // would be the unhelpful "couldn't be completed (… error 0.)" fallback;
        // the `LocalizedError` conformance must surface real text instead.
        XCTAssertEqual(
            FileServiceError.alreadyExists.errorDescription,
            "An item with that name already exists."
        )
        XCTAssertEqual(
            FileServiceError.unsupported.errorDescription,
            "This operation is not supported."
        )
        XCTAssertFalse(FileServiceError.alreadyExists.localizedDescription.contains("error 0"))
    }

    func testNotADirectoryDescriptionNamesTheOffendingComponent() {
        let description = FileServiceError.notADirectory(name: "centrifugo").errorDescription
        XCTAssertEqual(description, "\"centrifugo\" already exists and is not a folder.")
        XCTAssertFalse(description?.isEmpty ?? true)
        XCTAssertFalse(
            FileServiceError.notADirectory(name: "centrifugo")
                .localizedDescription.contains("error 0")
        )
    }

    // MARK: - Byte count and binary/oversize reads (project search)

    func testFileByteCountReportsOnDiskSize() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.txt")
        // Multibyte on purpose: the count is bytes, not characters.
        try service.write("héllo", to: url)

        XCTAssertEqual(service.fileByteCount(at: url), 6)
    }

    func testFileByteCountIsNilForMissingFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(service.fileByteCount(at: dir.appendingPathComponent("nope.txt")))
    }

    func testReadTextIfNotBinaryReturnsTextForOrdinaryFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.swift")
        try service.write("let x = 1\n", to: url)

        XCTAssertEqual(try service.readTextIfNotBinary(url: url, maxBytes: 1_000), "let x = 1\n")
    }

    func testReadTextIfNotBinarySkipsBinaryFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.bin")
        // A NUL byte inside the probed head is the binary signal.
        try Data([0x50, 0x4B, 0x00, 0x03, 0x41]).write(to: url)

        XCTAssertNil(try service.readTextIfNotBinary(url: url, maxBytes: 1_000))
    }

    func testReadTextIfNotBinarySkipsOversizeFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.txt")
        try service.write(String(repeating: "a", count: 100), to: url)

        XCTAssertNil(try service.readTextIfNotBinary(url: url, maxBytes: 99))
        // Exactly at the cap is still readable — the bound is inclusive.
        XCTAssertEqual(try service.readTextIfNotBinary(url: url, maxBytes: 100)?.count, 100)
    }

    func testReadTextIfNotBinarySkipsNonUTF8File() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("latin1.txt")
        // Valid Latin-1, invalid UTF-8, and no NUL — so only the decode rejects it.
        try Data([0x68, 0xE9, 0x6C, 0x6C, 0x6F]).write(to: url)

        XCTAssertNil(try service.readTextIfNotBinary(url: url, maxBytes: 1_000))
    }

    func testReadTextIfNotBinaryThrowsForMissingFile() throws {
        let service = FileService()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "Could not be read" must stay distinguishable from "skip this file".
        XCTAssertThrowsError(
            try service.readTextIfNotBinary(url: dir.appendingPathComponent("nope.txt"), maxBytes: 1_000)
        )
    }

    /// The protocol-extension default must implement the *same* contract, so a
    /// stub that only knows how to `read` still skips binaries and oversize files.
    func testDefaultReadTextIfNotBinaryAppliesTheSameRules() throws {
        struct TextOnlyStub: FileServicing {
            var contents: String
            func read(url: URL) throws -> String { contents }
            func write(_ text: String, to url: URL) throws {}
            func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        }
        let url = URL(fileURLWithPath: "/stub/a.txt")

        XCTAssertEqual(
            try TextOnlyStub(contents: "hello").readTextIfNotBinary(url: url, maxBytes: 10),
            "hello"
        )
        XCTAssertNil(try TextOnlyStub(contents: "hello").readTextIfNotBinary(url: url, maxBytes: 4))
        XCTAssertNil(try TextOnlyStub(contents: "a\0b").readTextIfNotBinary(url: url, maxBytes: 10))
        XCTAssertNil(TextOnlyStub(contents: "hello").fileByteCount(at: url))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
