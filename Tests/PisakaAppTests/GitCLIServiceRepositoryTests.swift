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

    // MARK: - Helpers

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
