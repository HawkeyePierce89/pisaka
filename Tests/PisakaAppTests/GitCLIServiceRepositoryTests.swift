#if os(macOS)
import Foundation
import XCTest
import PisakaCore
@testable import Pisaka

/// R4, R1, R2 and R5 against the real `git`, in throwaway repositories.
///
/// `GitCLIArgumentSourceGatingTests` pins the command lines `GitCLIService`
/// spells — the trailing `--` on both branch checkouts and the
/// `--no-optional-locks` global option, `--encoding=UTF-8` and blame's `-w -M`
/// — but whether those arguments do what
/// their doc comments claim is a fact about git itself, and this bundle is the
/// only place a real git runs:
///
/// - the ticket's scenario, a local branch sharing its name with a tracked
///   directory, still switches (a regression guard: git already preferred the
///   branch before the terminator);
/// - a stale name with no branch behind it that matches a path fails with
///   `GitError.checkoutFailed` and leaves that path's unstaged edit alone —
///   without `--`, git restores the path from the index and exits 0;
/// - a name that exists only as `origin/<name>` and is also a path switches —
///   without `--`, git refuses it as ambiguous — and `createAndCheckout` from
///   that remote start point, whose name is also a path, creates the branch;
/// - `changedFiles` leaves `.git/index` byte-for-byte untouched when the stat
///   cache is stale, and a plain `git status` run by the helper afterwards does
///   rewrite it, so the assertion cannot pass vacuously;
/// - a message stored in ISO-8859-1, in a repository whose
///   `i18n.logOutputEncoding` is also ISO-8859-1, reads back as Unicode through
///   both `--pretty` sites — without the flag git emits the Latin-1 bytes;
/// - a re-indented line and a line moved within the file both stay attributed
///   to the commit that wrote them — without `-w -M` both go to the later one.
/// - the gutter's base (`headText`) resolves a file in a subdirectory relative
///   to its own directory — the `./` prefix; without it git reads the path from
///   the repository root and finds nothing — comes back with a checkout's CRLF
///   endings under `eol=crlf` — without `--filters`, the stored LF bytes — and is
///   `nil` for a binary blob, an untracked file and a file outside any repository;
/// - that base's read is bounded at `GutterChangeModel.maxSideBytes` *after* the
///   filters: exactly the cap reads back, one byte over is `nil`, and a blob under
///   the cap that the checkout's CRLF conversion grows past it is `nil` too;
/// - the status snapshot's `--ignored=matching` reports what git ignores from
///   each source it consults — a `.gitignore`d directory as one slash-stripped
///   path, `.git/info/exclude`, and a `core.excludesFile` (set in the
///   repository's config, standing in for the global one) — while none of it
///   reaches the changed files, and a force-added tracked file inside an
///   ignored directory still reports its edit while its sibling stays ignored;
/// - that status command, run outside any repository, throws
///   `GitError.notARepository` from both `statusSnapshot` and `changedFiles`.
///
/// The repositories come from `ThrowawayRepository`, whose own git runs with
/// the machine's configuration masked; the service under test inherits the
/// process environment, as it does in the app.
final class GitCLIServiceRepositoryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitCLIServiceRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
    }

    // MARK: - R4

    func testALocalBranchNamedLikeATrackedDirectoryChecksOut() async throws {
        let repo = try makeRepository("repo")
        try commitFile("docs/f", contents: "a\n", in: repo)
        try git(["branch", "docs"], in: repo)

        try await GitCLIService().checkout(branch: "docs", root: repo)

        XCTAssertEqual(try currentBranch(in: repo), "docs")
    }

    func testAStaleNameMatchingAPathFailsAndKeepsTheUnstagedEdit() async throws {
        let repo = try makeRepository("repo")
        try commitFile("docs/f", contents: "a\n", in: repo)
        let file = repo.appendingPathComponent("docs/f")
        try Data("edit\n".utf8).write(to: file)

        do {
            try await GitCLIService().checkout(branch: "docs", root: repo)
            XCTFail("checkout of a name with no branch behind it must fail")
        } catch GitError.checkoutFailed {
            // Expected: with `--`, git reads `docs` as a revision only.
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "edit\n")
        XCTAssertEqual(try currentBranch(in: repo), "main")
    }

    func testANameOnlyOnTheRemoteThatIsAlsoAPathChecksOut() async throws {
        let origin = try makeRepository("origin")
        try commitFile("docs/f", contents: "a\n", in: origin)
        try git(["branch", "docs"], in: origin)
        try git(["clone", "-q", origin.path, "clone"], in: scratch)
        let clone = scratch.appendingPathComponent("clone", isDirectory: true)

        try await GitCLIService().checkout(branch: "docs", root: clone)

        XCTAssertEqual(try currentBranch(in: clone), "docs")
    }

    func testCreateAndCheckoutFromARemoteStartPointThatIsAlsoAPath() async throws {
        let origin = try makeRepository("origin")
        try commitFile("docs/f", contents: "a\n", in: origin)
        try git(["branch", "docs"], in: origin)
        try git(["clone", "-q", origin.path, "clone"], in: scratch)
        let clone = scratch.appendingPathComponent("clone", isDirectory: true)

        try await GitCLIService().createAndCheckout(name: "feature", startPoint: "origin/docs", root: clone)

        XCTAssertEqual(try currentBranch(in: clone), "feature")
    }

    // MARK: - R1

    func testChangedFilesDoesNotRewriteTheIndex() async throws {
        let repo = try makeRepository("repo")
        try commitFile("a.txt", contents: "a\n", in: repo)
        // A backdated mtime no longer matches the index's stat data, so any
        // `status` that may take the optional lock refreshes and writes it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
            ofItemAtPath: repo.appendingPathComponent("a.txt").path
        )
        let index = repo.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)

        let changed = try await GitCLIService().changedFiles(root: repo)

        XCTAssertEqual(changed, [])
        XCTAssertEqual(try Data(contentsOf: index), before, "changedFiles wrote .git/index")

        // Control: the same stale stat cache, read by a git that may lock.
        try git(["status", "--porcelain"], in: repo)
        XCTAssertNotEqual(
            try Data(contentsOf: index), before,
            "plain git status did not refresh the index, so the assertion above proves nothing"
        )
    }

    // MARK: - R2

    func testALegacyEncodedMessageReadsBackAsUnicode() async throws {
        let repo = try makeRepository("repo")
        try git(["config", "i18n.commitEncoding", "ISO-8859-1"], in: repo)
        try git(["config", "i18n.logOutputEncoding", "ISO-8859-1"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try git(["add", "--", "a.txt"], in: repo)
        let message = scratch.appendingPathComponent("message")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: message)  // "café\n" in ISO-8859-1
        try git(["commit", "-q", "-F", message.path], in: repo)

        let service = GitCLIService()
        let commits = try await service.commits(filter: LogFilter(), limit: 1, root: repo)
        let headMessage = try await service.headMessage(root: repo)

        XCTAssertEqual(commits.first?.subject, "café")
        XCTAssertEqual(headMessage?.trimmingCharacters(in: .whitespacesAndNewlines), "café")
    }

    // MARK: - R5

    func testBlameKeepsReindentedAndMovedLinesWithTheirAuthor() async throws {
        let repo = try makeRepository("repo")
        // Each line is long enough for `-M`'s default score of 20 characters.
        try commitFile(
            "f.swift",
            contents: "let alphaBetaGammaDelta = 1\nlet epsilonZetaEtaTheta = 2\nlet iotaKappaLambdaMu = 3\n",
            in: repo
        )
        let original = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        // Move the last line to the top and re-indent the middle one.
        try commitFile(
            "f.swift",
            contents: "let iotaKappaLambdaMu = 3\nlet alphaBetaGammaDelta = 1\n    let epsilonZetaEtaTheta = 2\n",
            in: repo
        )

        let lines = try await GitCLIService().blame(fileURL: repo.appendingPathComponent("f.swift"))

        XCTAssertEqual(lines.map { $0?.hash }, [original, original, original])
    }

    // MARK: - Gutter base

    func testHeadTextResolvesAFileInASubdirectory() async throws {
        let repo = try makeRepository("repo")
        try commitFile("src/deep/file.txt", contents: "deep\n", in: repo)
        try commitFile("file.txt", contents: "root\n", in: repo)

        let text = try await GitCLIService().headText(fileURL: repo.appendingPathComponent("src/deep/file.txt"))

        XCTAssertEqual(text, "deep\n")
    }

    func testHeadTextAppliesTheCheckoutsLineEndingConversion() async throws {
        let repo = try makeRepository("repo")
        try commitFile(".gitattributes", contents: "*.txt eol=crlf\n", in: repo)
        try commitFile("file.txt", contents: "one\ntwo\n", in: repo)
        XCTAssertEqual(try git(["cat-file", "blob", "HEAD:file.txt"], in: repo), "one\ntwo\n")

        let text = try await GitCLIService().headText(fileURL: repo.appendingPathComponent("file.txt"))

        XCTAssertEqual(text, "one\r\ntwo\r\n")
    }

    func testHeadTextIsNilForABinaryBlobAnUntrackedFileAndAFileOutsideARepository() async throws {
        let repo = try makeRepository("repo")
        try commitFile("binary.bin", contents: "a\u{0}b", in: repo)
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))
        let outside = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: outside.appendingPathComponent("file.txt"))
        let service = GitCLIService()

        let binary = try await service.headText(fileURL: repo.appendingPathComponent("binary.bin"))
        let untracked = try await service.headText(fileURL: repo.appendingPathComponent("untracked.txt"))
        let unrepositoried = try await service.headText(fileURL: outside.appendingPathComponent("file.txt"))

        XCTAssertNil(binary)
        XCTAssertNil(untracked)
        XCTAssertNil(unrepositoried)
    }

    func testHeadTextIsBoundedAtTheGutterCapAfterTheFilters() async throws {
        let cap = GutterChangeModel.maxSideBytes
        let repo = try makeRepository("repo")
        try commitFile(".gitattributes", contents: "grown.txt eol=crlf\n", in: repo)
        try commitFile("atCap.txt", contents: String(repeating: "a", count: cap), in: repo)
        try commitFile("overCap.txt", contents: String(repeating: "a", count: cap + 1), in: repo)
        // Under the cap as stored, half again as long once LF becomes CRLF.
        try commitFile("grown.txt", contents: String(repeating: "a\n", count: cap / 2 - 1), in: repo)
        let service = GitCLIService()

        let atCap = try await service.headText(fileURL: repo.appendingPathComponent("atCap.txt"))
        let overCap = try await service.headText(fileURL: repo.appendingPathComponent("overCap.txt"))
        let grown = try await service.headText(fileURL: repo.appendingPathComponent("grown.txt"))

        XCTAssertEqual(atCap?.utf8.count, cap)
        XCTAssertNil(overCap)
        XCTAssertNil(grown)
    }

    // MARK: - Status snapshot

    func testAnIgnoredDirectoryIsOneSlashStrippedPathAndNoChangedFile() async throws {
        let repo = try makeRepository("repo")
        try commitFile(".gitignore", contents: "pisaka-build-out/\n", in: repo)
        try write("pisaka-build-out/a.o", in: repo)
        try write("pisaka-build-out/nested/b.o", in: repo)
        try write("fresh.txt", in: repo)

        let snapshot = try await GitCLIService().statusSnapshot(root: repo)

        XCTAssertTrue(snapshot.ignoredPaths.contains("pisaka-build-out"), "\(snapshot.ignoredPaths)")
        XCTAssertFalse(snapshot.ignoredPaths.contains { $0.hasPrefix("pisaka-build-out/") })
        XCTAssertFalse(snapshot.changedFiles.contains { $0.path.hasPrefix("pisaka-build-out") })
        XCTAssertTrue(snapshot.changedFiles.contains { $0.path == "fresh.txt" && $0.status == .untracked })
        let changedFiles = try await GitCLIService().changedFiles(root: repo)
        XCTAssertEqual(changedFiles, snapshot.changedFiles, "changedFiles is the snapshot's list")
    }

    func testAFileIgnoredThroughTheInfoExcludeIsReported() async throws {
        let repo = try makeRepository("repo")
        try commitFile("kept.txt", contents: "a\n", in: repo)
        try Data("pisaka-info-excluded.txt\n".utf8)
            .write(to: repo.appendingPathComponent(".git/info/exclude"))
        try write("pisaka-info-excluded.txt", in: repo)

        let snapshot = try await GitCLIService().statusSnapshot(root: repo)

        XCTAssertTrue(snapshot.ignoredPaths.contains("pisaka-info-excluded.txt"), "\(snapshot.ignoredPaths)")
        XCTAssertFalse(snapshot.changedFiles.contains { $0.path == "pisaka-info-excluded.txt" })
    }

    func testAFileIgnoredThroughTheExcludesFileIsReported() async throws {
        let repo = try makeRepository("repo")
        try commitFile("kept.txt", contents: "a\n", in: repo)
        let excludes = scratch.appendingPathComponent("excludes")
        try Data("pisaka-globally-excluded.txt\n".utf8).write(to: excludes)
        try git(["config", "core.excludesFile", excludes.path], in: repo)
        try write("pisaka-globally-excluded.txt", in: repo)

        let snapshot = try await GitCLIService().statusSnapshot(root: repo)

        XCTAssertTrue(snapshot.ignoredPaths.contains("pisaka-globally-excluded.txt"), "\(snapshot.ignoredPaths)")
        XCTAssertFalse(snapshot.changedFiles.contains { $0.path == "pisaka-globally-excluded.txt" })
    }

    func testAForceAddedFileInsideAnIgnoredDirectoryReportsItsEdit() async throws {
        let repo = try makeRepository("repo")
        try commitFile(".gitignore", contents: "pisaka-vendor/\n", in: repo)
        try write("pisaka-vendor/kept.txt", in: repo)
        try git(["add", "-f", "--", "pisaka-vendor/kept.txt"], in: repo)
        try git(["commit", "-q", "-m", "force-add"], in: repo)
        try write("pisaka-vendor/kept.txt", contents: "edited\n", in: repo)
        try write("pisaka-vendor/sibling.txt", in: repo)

        let service = GitCLIService()
        let snapshot = try await service.statusSnapshot(root: repo)

        XCTAssertTrue(snapshot.changedFiles.contains { $0.path == "pisaka-vendor/kept.txt" && $0.status == .modified })
        XCTAssertFalse(snapshot.changedFiles.contains { $0.path == "pisaka-vendor/sibling.txt" })
        XCTAssertFalse(snapshot.ignoredPaths.contains("pisaka-vendor/kept.txt"))
        let repositoryRoot = try await service.repositoryRoot(for: repo)
        let lookup = TreeGitStatus(snapshot: snapshot, repositoryRoot: repositoryRoot, openedFolder: repo)
        XCTAssertEqual(lookup.state(for: repo.appendingPathComponent("pisaka-vendor/kept.txt")), .modified)
        XCTAssertEqual(lookup.state(for: repo.appendingPathComponent("pisaka-vendor/sibling.txt")), .ignored)
    }

    func testTheStatusCommandOutsideAnyRepositoryThrowsNotARepository() async throws {
        let outside = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let service = GitCLIService()

        do {
            _ = try await service.statusSnapshot(root: outside)
            XCTFail("statusSnapshot answered for a folder outside any repository")
        } catch GitError.notARepository {}
        do {
            _ = try await service.changedFiles(root: outside)
            XCTFail("changedFiles answered for a folder outside any repository")
        } catch GitError.notARepository {}
    }

    // MARK: - Helpers

    /// Writes an untracked file at `path` inside `repo`, creating its folders.
    private func write(_ path: String, contents: String = "x\n", in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private var repository: ThrowawayRepository { ThrowawayRepository(scratch: scratch) }

    private func makeRepository(_ name: String) throws -> URL {
        try repository.makeRepository(name)
    }

    private func commitFile(_ path: String, contents: String, in repo: URL) throws {
        try repository.commitFile(path, contents: contents, in: repo)
    }

    private func currentBranch(in repo: URL) throws -> String {
        try repository.currentBranch(in: repo)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        try repository.git(arguments, in: directory)
    }
}

#endif
