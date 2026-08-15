import XCTest
@testable import PisakaCore

/// Static verification of `.github/workflows/release.yml` — the tag-triggered
/// workflow that archives, signs and publishes the macOS build.
///
/// Written in the `ReleaseMetadataTests`/`DependencyPinTests` style: the
/// repository's own files are read through `#filePath` with Foundation only, so
/// the check runs in `swift test` without an Xcode build and without the Core
/// target gaining a dependency.
///
/// A release workflow is the worst possible place for an unasserted invariant.
/// It runs on a `v*` tag and nowhere else, so a mistake in it is *not* caught by
/// CI, by a pull request, or by any local build; the first time anyone finds out
/// is on the tag push that was supposed to ship. Worse, several of its mistakes
/// do not fail the run at all — they produce a green release that is silently
/// broken for the people who install it:
///
///  * a plain `zip` instead of `ditto -c -k` flattens `Sparkle.framework`'s
///    symlinks, so the *update* fails its signature check on the user's machine
///    while the workflow reports success;
///  * a build number that is not monotonic publishes a release Sparkle will
///    never offer, because `CFBundleVersion` is how it orders builds;
///  * an asset attached under any name other than the one `SUFeedURL` ends in
///    leaves `releases/latest/download/appcast.xml` resolving to nothing, so
///    every installed copy quietly stops finding updates;
///  * `contents: write` at the top level rather than on the one job that
///    publishes would hand the whole workflow — third-party actions included —
///    a write token for no reason.
///
/// So the shape is pinned here, as assertions, in the same spirit as the plist
/// and dependency-pin suites.
///
/// **What this suite deliberately cannot assert**: that the workflow *works*. It
/// has no runner, no network, no Xcode and no secret. The end-to-end proof is
/// the manual pass recorded in `docs/RELEASING.md` — the first tag push, and the
/// install-N/publish-N+1 update pass.
final class ReleaseWorkflowTests: XCTestCase {
    // MARK: - Pinned constants
    //
    // Values that appear in the workflow and must not drift silently. Changing
    // one here is the deliberate act; changing one only in the YAML fails this
    // suite.

    /// The Sparkle release tarball the workflow's `generate_appcast` comes from
    /// — the same version the app links (`project.yml`).
    private static let sparkleToolsURL =
        "https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz"

    /// Its SHA-256. The workflow downloads an archive and then *executes* what is
    /// inside it with the private signing key on its stdin, so the digest is the
    /// whole trust boundary for that step.
    private static let sparkleToolsDigest =
        "015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"

    /// The committed placeholder public key (see `Resources/Info.plist`). The
    /// workflow's preflight greps for exactly this string and refuses to build
    /// while it is present.
    ///
    /// Note what is deliberately *not* asserted: that this equals the value
    /// currently in the plist. When the real key is finally swapped in, the plist
    /// changes and the guard does not — it keeps looking for the placeholder,
    /// where it is permanently satisfied and harmless. Tying the two together
    /// would force the guard to be rewritten to grep for the *real* key, which
    /// would then refuse every release forever.
    private static let placeholderPublicKey = "UExBQ0VIT0xERVItUkVQTEFDRS1XSVRILVJFQUwtS1k="

    // MARK: - Trigger and permissions

    func testWorkflowIsTriggeredOnlyByVersionTags() throws {
        let lines = try workflowLines()

        XCTAssertTrue(lines.contains(consecutively: """
            on:
            push:
            tags: ['v*']
            """), """
            .github/workflows/release.yml must trigger on `push:` of `tags: ['v*']` and nothing \
            else. A `branches:` or `workflow_dispatch` trigger here would publish a GitHub \
            Release — and burn a github.run_number — on an ordinary push.
            """)
    }

    /// The token is read-only for the workflow and writable only inside the job
    /// that creates the release.
    func testWritePermissionIsScopedToTheReleaseJobAlone() throws {
        let raw = try workflowText().components(separatedBy: .newlines)

        let topLevel = try XCTUnwrap(raw.firstIndex(of: "permissions:"), """
            .github/workflows/release.yml has no top-level `permissions:` block. Without one the \
            workflow runs with the repository's default token scope, which may well be write.
            """)
        let firstEntry = try XCTUnwrap(raw[(topLevel + 1)...].first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }))
        XCTAssertEqual(firstEntry.trimmingCharacters(in: .whitespaces), "contents: read",
                       "the top-level permissions block must be `contents: read`")

        let writes = raw.indices.filter { raw[$0].trimmingCharacters(in: .whitespaces) == "contents: write" }
        XCTAssertEqual(writes.count, 1, """
            Exactly one `contents: write` belongs in release.yml — on the release job. Found \
            \(writes.count).
            """)
        let write = try XCTUnwrap(writes.first)

        // The job it belongs to is the nearest preceding job header: a
        // two-space-indented bare `<name>:` line under `jobs:`.
        let owningJob = raw[..<write].last(where: Self.isJobHeader)
        XCTAssertEqual(owningJob?.trimmingCharacters(in: .whitespaces), "release:", """
            `contents: write` must sit on the `release:` job, the only one that creates a release \
            or uploads an asset. It is currently under “\(owningJob ?? "no job at all")”.
            """)
    }

    /// A two-space-indented bare `<name>:` line — a job header under `jobs:`.
    private static func isJobHeader(_ line: String) -> Bool {
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return false }
        let body = line.dropFirst(2)
        guard body.hasSuffix(":") else { return false }
        let name = body.dropLast()
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Preflight

    /// Both refusals the release depends on, asserted by their mechanism rather
    /// than by their wording — a preflight that stopped comparing the two
    /// versions, or stopped looking at the plist, is the failure worth catching.
    func testPreflightRefusesAVersionMismatchAndThePlaceholderKey() throws {
        let text = try workflowText()

        XCTAssertTrue(text.contains("MARKETING_VERSION"), """
            release.yml's preflight must read MARKETING_VERSION out of project.yml and compare it \
            with the tag. Without that a `v1.1` tag happily ships a bundle that reports 1.0, and \
            the appcast advertises a version the app does not have.
            """)
        XCTAssertTrue(text.contains("$VERSION") && text.contains("$DECLARED"), """
            release.yml's preflight no longer compares the tag's version with the declared one.
            """)

        XCTAssertTrue(text.contains(Self.placeholderPublicKey), """
            release.yml's preflight must grep Resources/Info.plist for the committed placeholder \
            SUPublicEDKey (\(Self.placeholderPublicKey)) and refuse to build while it is there. \
            Without that guard a release can ship signed by a key whose public half no installed \
            copy carries: every update it offers would be rejected, and the only way out would be \
            a manual re-download by every user.
            """)
        XCTAssertTrue(text.contains("Resources/Info.plist"), """
            release.yml's placeholder guard must name Resources/Info.plist — the file the shipped \
            key actually comes from.
            """)

        XCTAssertTrue(text.contains("SPARKLE_PRIVATE_EDDSA_KEY"), """
            release.yml must fail early when the SPARKLE_PRIVATE_EDDSA_KEY secret is empty rather \
            than after the archive: an unsigned appcast is not a degraded release, it is one \
            Sparkle refuses outright.
            """)
        XCTAssertTrue(text.contains("docs/RELEASING.md"), """
            Each preflight refusal points at docs/RELEASING.md, where the one-time key generation \
            and the tagging rules are written. A refusal with no next step is a refusal someone \
            will work around.
            """)
    }

    // MARK: - The artefact

    /// `ditto -c -k`, not `zip`. See the type doc: the failure this prevents
    /// happens on the *user's* machine, long after a green run.
    func testUpdateArchiveIsMadeWithDitto() throws {
        let text = try workflowText()

        XCTAssertTrue(text.contains("ditto -c -k"), """
            The update zip must be produced with `ditto -c -k --sequesterRsrc --keepParent`. A \
            plain `zip` stores the embedded Sparkle.framework's symlinks (Versions/Current and \
            the top-level links) as duplicated regular files, so the unpacked framework fails its \
            own signature check and Sparkle rejects the update — with nothing at all failing here.
            """)
        XCTAssertTrue(text.contains("--sequesterRsrc") && text.contains("--keepParent"), """
            `ditto -c -k` needs --sequesterRsrc --keepParent: the first keeps extended attributes \
            and resource forks out of the file bodies, the second archives the .app as a \
            directory rather than its contents.
            """)
        XCTAssertFalse(text.contains("zip -r"), """
            release.yml appears to build an archive with `zip -r`. Use ditto — see above.
            """)
    }

    func testBuildNumberComesFromTheMonotonicRunNumber() throws {
        let text = try workflowText()

        XCTAssertTrue(text.contains("CURRENT_PROJECT_VERSION=${{ github.run_number }}"), """
            The archive's build number must be `github.run_number`. CFBundleVersion is what \
            Sparkle compares to decide one build is newer than another, so it has to increase \
            strictly across every release — and it must not be a committed value, or every \
            release would carry a build-number churn commit (docs/RELEASING.md). run_number is \
            GitHub's per-workflow-file counter and never resets.
            """)
        XCTAssertTrue(text.contains("renamed"), """
            The run_number caveat must stay documented in this file: the counter is keyed on the \
            workflow file's *name*, so renaming release.yml restarts it at 1 — and a build \
            numbered 1 published after build 12 is one Sparkle will never offer. Whoever renames \
            the file has to add an offset, and that comment is the only place saying so.
            """)
    }

    // MARK: - Pins

    /// The Sparkle tools are downloaded and then run with the private signing key
    /// on their stdin, so they are pinned exactly like XcodeGen: exact URL, and a
    /// digest checked before anything is extracted.
    func testSparkleReleaseToolsArePinnedByURLAndDigest() throws {
        let text = try workflowText()

        XCTAssertTrue(text.contains(Self.sparkleToolsURL), """
            release.yml must download Sparkle's release tools from the pinned 2.9.5 URL \
            (\(Self.sparkleToolsURL)) — the same version the app links, so generate_appcast's \
            signature format and the shipped framework's verifier cannot drift apart.
            """)

        let digests = shasumDigests(in: text)
        XCTAssertTrue(digests.contains(Self.sparkleToolsDigest), """
            release.yml must verify the Sparkle tarball with `shasum -a 256 -c -` against \
            \(Self.sparkleToolsDigest) before extracting it. The digests it actually checks: \
            \(digests.sorted()). This is the trust boundary for code that then runs with the \
            private signing key on its stdin.
            """)
    }

    /// Both workflows install XcodeGen, and nothing makes them stay in step — CI
    /// can build green with one version while the release ships a project
    /// generated by another, and the difference surfaces as a release-only build
    /// failure or, worse, a release-only project difference nobody ever tested.
    func testXcodeGenIsPinnedIdenticallyToCI() throws {
        let release = try workflowText()
        let ci = try text(atRepositoryPath: ".github/workflows/ci.yml")

        let releaseURLs = xcodeGenURLs(in: release)
        let ciURLs = xcodeGenURLs(in: ci)
        XCTAssertFalse(releaseURLs.isEmpty, "release.yml does not install XcodeGen by URL")
        XCTAssertFalse(ciURLs.isEmpty, "ci.yml does not install XcodeGen by URL")
        XCTAssertEqual(releaseURLs, ciURLs, """
            release.yml and ci.yml must install the same XcodeGen build. CI's: \(ciURLs.sorted()); \
            the release workflow's: \(releaseURLs.sorted()).
            """)

        let releaseDigests = shasumDigests(in: release, forFile: "xcodegen.zip")
        let ciDigests = shasumDigests(in: ci, forFile: "xcodegen.zip")
        XCTAssertFalse(ciDigests.isEmpty, "ci.yml no longer verifies xcodegen.zip's digest")
        XCTAssertEqual(releaseDigests, ciDigests, """
            The XcodeGen digest checked in release.yml must equal the one ci.yml checks. \
            CI's: \(ciDigests.sorted()); the release workflow's: \(releaseDigests.sorted()).
            """)
    }

    // MARK: - The cross-file invariant

    /// The half of the feed contract that lives in the workflow.
    ///
    /// `SUFeedURL` is `…/releases/latest/download/appcast.xml`, and GitHub
    /// resolves that redirect purely by *asset name*. Attach the file as
    /// `Pisaka-appcast.xml`, `appcast-v1.0.xml` or anything else and the redirect
    /// 404s: every installed copy silently stops finding updates, with nothing
    /// failing on either side. `ReleaseMetadataTests` asserts the plist half;
    /// this asserts the workflow half against it.
    func testTheReleaseAttachesTheAssetNameTheFeedURLResolvesAgainst() throws {
        let feed = try XCTUnwrap(feedURL(), "Resources/Info.plist has no parseable SUFeedURL")
        let assetName = feed.lastPathComponent
        XCTAssertFalse(assetName.isEmpty, "SUFeedURL has no last path component")

        let text = try workflowText()
        let lines = text.components(separatedBy: .newlines)
        let create = try XCTUnwrap(lines.firstIndex(where: { $0.contains("gh release create") }), """
            release.yml no longer creates the release with `gh release create`.
            """)

        // The assets are the trailing positional arguments of the line-continued
        // `gh` invocation; scan the rest of that step for one named exactly as
        // the feed's last path component.
        let attaches = lines[create...].prefix(12).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \\"))
                == assetName
        }
        XCTAssertTrue(attaches, """
            release.yml must attach the appcast under the literal name “\(assetName)” — the last \
            path component of SUFeedURL in Resources/Info.plist. GitHub's \
            releases/latest/download/<asset> redirect resolves by asset name alone, so any other \
            name leaves every installed copy fetching a 404 forever, with nothing failing here or \
            in the app.
            """)

        XCTAssertTrue(text.contains("-o \(assetName)"), """
            generate_appcast must write the feed to “\(assetName)”, so the file attached to the \
            release already carries the name SUFeedURL resolves against.
            """)
    }

    /// The enclosure URLs the appcast advertises are built from this prefix, and
    /// Sparkle refuses a plain-HTTP download the same way it refuses a
    /// plain-HTTP feed.
    func testTheAppcastDownloadPrefixIsHTTPSOnGitHub() throws {
        let text = try workflowText()
        let prefix = try XCTUnwrap(firstMatch(#"--download-url-prefix "([^"]+)""#, in: text), """
            release.yml no longer passes --download-url-prefix to generate_appcast; without it \
            the appcast's enclosure URLs do not resolve to the release's own assets.
            """)
        XCTAssertTrue(prefix.hasPrefix("https://github.com/"), """
            The appcast's download prefix must be HTTPS on github.com — it is where every \
            installed copy fetches the update from. Got “\(prefix)”.
            """)
    }

    // MARK: - Reading the repository

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func text(atRepositoryPath path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func workflowText() throws -> String {
        try text(atRepositoryPath: ".github/workflows/release.yml")
    }

    /// The workflow's *active* lines: neither blank nor a comment, trimmed, in
    /// file order — the same treatment `ReleaseMetadataTests` gives `project.yml`,
    /// and for the same reason: this file is heavily commented and its comments
    /// quote its own settings verbatim, so a raw `contains` cannot tell a live
    /// trigger from a described one.
    private func workflowLines(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let lines = try workflowText()
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertFalse(lines.isEmpty, "parsed nothing out of release.yml", file: file, line: line)
        return lines
    }

    private func feedURL() throws -> URL? {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = object as? [String: Any],
              let raw = plist["SUFeedURL"] as? String else { return nil }
        return URL(string: raw)
    }

    // MARK: - Tiny parsers

    /// Every digest actually piped into `shasum -a 256 -c -`, optionally narrowed
    /// to the file it is checked against.
    ///
    /// Requiring the pipe on the same line, and not just a 64-hex string
    /// somewhere, is the point: a digest sitting in a comment — or in an `echo`
    /// whose `| shasum` someone deleted — is not a verified download, and would
    /// otherwise satisfy these assertions.
    private func shasumDigests(in text: String, forFile file: String? = nil) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9a-f]{64})\s+(\S+)"#) else { return [] }

        var digests: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.contains("shasum -a 256 -c -") else { continue }
            let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let digest = Range(match.range(at: 1), in: trimmed),
                  let name = Range(match.range(at: 2), in: trimmed) else { continue }
            let checkedFile = String(trimmed[name])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let file, checkedFile != file { continue }
            digests.insert(String(trimmed[digest]))
        }
        return digests
    }

    private func xcodeGenURLs(in text: String) -> Set<String> {
        var urls: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            if let url = firstMatch(#"(https://github\.com/yonaskolb/XcodeGen/releases/download/\S+)"#,
                                    in: trimmed) {
                urls.insert(url)
            }
        }
        return urls
    }

    /// The first capture group of `pattern` in `text`, or `nil`.
    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

private extension Array where Element == String {
    /// Whether `needle`'s lines appear here as a *consecutive* run, each trimmed
    /// line matched whole — the same helper `ReleaseMetadataTests` keeps, for the
    /// same reason: whole-line equality rules out a commented-out or
    /// merely-quoted setting.
    func contains(consecutively needle: String) -> Bool {
        let wanted = needle.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty, count >= wanted.count else { return false }

        return indices.dropLast(wanted.count - 1).contains { start in
            Array(self[start ..< start + wanted.count]) == wanted
        }
    }
}
