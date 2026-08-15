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
///  * a Debug archive still embeds `Sparkle.framework`, so every check here
///    passes while the shipped app has its updater compiled out;
///  * `contents: write` at the top level rather than on the one job that
///    publishes would hand the whole workflow — third-party actions included —
///    a write token for no reason.
///
/// So the shape is pinned here, as assertions, in the same spirit as the plist
/// and dependency-pin suites.
///
/// **Every substring assertion runs over `activeText()`, never the raw file.**
/// This workflow is heavily commented and its comments quote its own commands
/// verbatim — `# \`ditto -c -k\` and not \`zip\`` sits three lines above the real
/// `ditto` invocation, and the header prose names `MARKETING_VERSION`,
/// `docs/RELEASING.md` and `Resources/Info.plist`. A `contains` over the raw
/// text therefore cannot tell a live command from a described one: it stays
/// green when the command it names is deleted, which is precisely the class of
/// silent, release-only breakage this suite exists to catch. Comment-stripping
/// is not a nicety here, it is what makes the assertions mean what they say.
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

    /// The name the Sparkle tarball is downloaded to — the file the digest above
    /// must be checked *against*, not merely near.
    private static let sparkleToolsFile = "sparkle-tools.tar.xz"

    /// The committed placeholder public key (see `Resources/Info.plist`). The
    /// workflow's preflight greps for exactly this string and refuses to build
    /// while it is present.
    private static let placeholderPublicKey = "UExBQ0VIT0xERVItUkVQTEFDRS1XSVRILVJFQUwtS1k="

    // MARK: - Trigger, concurrency and permissions

    /// "Only" is the load-bearing word, so the whole `on:` block is compared by
    /// set equality rather than by finding a `tags:` run inside it. A
    /// `workflow_dispatch:` or `branches:` key added *beside* the tag trigger
    /// leaves any run-of-three assertion perfectly satisfied while every ordinary
    /// push publishes a GitHub Release and burns a `github.run_number`.
    func testWorkflowIsTriggeredOnlyByVersionTags() throws {
        let block = try XCTUnwrap(topLevelBlock("on", in: try workflowText()), """
            .github/workflows/release.yml has no top-level `on:` block.
            """)

        XCTAssertEqual(Set(block), ["push:", "tags: ['v*']"], """
            release.yml must trigger on `push:` of `tags: ['v*']` and nothing else. Its `on:` block \
            currently reads \(block). A `branches:` or `workflow_dispatch:` key here would publish \
            a GitHub Release — and burn a github.run_number — on an ordinary push.
            """)
    }

    /// Two release runs must never overlap. `CFBundleVersion` is
    /// `github.run_number` and `releases/latest` is whichever release was
    /// *published* last, so an interleaved pair can leave the feed advertising a
    /// build number lower than the one already installed — an update Sparkle will
    /// never offer, stranding those copies with nothing failing anywhere.
    func testReleaseRunsAreSerializedByAConcurrencyGroup() throws {
        let block = try XCTUnwrap(topLevelBlock("concurrency", in: try workflowText()), """
            release.yml has no top-level `concurrency:` block, so two tag pushes can publish \
            concurrently. See this test's doc comment for why that strands installed copies.
            """)

        XCTAssertTrue(block.contains("group: ${{ github.workflow }}"), """
            The concurrency group must be `${{ github.workflow }}` alone. Grouping by \
            `${{ github.ref }}` (the usual choice) puts every tag in its own group and serializes \
            nothing, because two releases are by definition two different tags. Got \(block).
            """)
        XCTAssertTrue(block.contains("cancel-in-progress: false"), """
            A release run must never be cancelled mid-flight: a half-published release (zip \
            attached, appcast not) is worse than a queued one. Got \(block).
            """)
    }

    /// The token is read-only for the workflow and writable only inside the job
    /// that creates the release.
    func testWritePermissionIsScopedToTheReleaseJobAlone() throws {
        let text = try workflowText()

        let topLevel = try XCTUnwrap(topLevelBlock("permissions", in: text), """
            release.yml has no top-level `permissions:` block. Without one the workflow runs with \
            the repository's default token scope, which may well be write.
            """)
        // Set equality, not "the first entry": a `packages: write` added as a
        // second line is exactly the widening this assertion exists to refuse.
        XCTAssertEqual(Set(topLevel), ["contents: read"], """
            The top-level permissions block must be exactly `contents: read`. Got \(topLevel).
            """)

        let raw = text.components(separatedBy: .newlines)
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

    /// The release must not be reachable from a tag whose `swift test` never ran
    /// — and `swift test` is what asserts the plist keys, the dependency pins and
    /// this file's own shape. Deleting `needs: test` would publish around every
    /// one of those gates with nothing failing.
    func testTheReleaseJobIsGatedOnTheTestJob() throws {
        let lines = try activeLines()

        XCTAssertTrue(lines.contains(consecutively: """
            release:
            needs: test
            """), """
            release.yml's `release:` job must declare `needs: test` as its first key. Without it \
            the archive-and-publish job runs in parallel with the gate, so a tag that cannot pass \
            `swift test` still ships — including the suites that pin Resources/Info.plist's Sparkle \
            keys and this very file.
            """)

        XCTAssertTrue(lines.contains(consecutively: """
            test:
            runs-on: macos-15
            """), "release.yml no longer declares a `test:` job for the release job to depend on")
        XCTAssertTrue(lines.contains("run: swift test"), """
            release.yml's `test:` job must actually run `swift test`. A job named `test` that runs \
            something else satisfies `needs:` and gates nothing.
            """)
    }

    // MARK: - Preflight

    /// Every refusal the release depends on, asserted by its *mechanism*: the
    /// condition must exist inside the preflight step **and its branch must
    /// `exit 1`**.
    ///
    /// Asserting that the file merely mentions `SPARKLE_PRIVATE_EDDSA_KEY` or
    /// `MARKETING_VERSION` proves nothing — the first appears in the appcast
    /// step's `env:` block and the second in the header prose, so a preflight
    /// downgraded from `::error::` + `exit 1` to a `::warning::` keeps every such
    /// assertion green while publishing exactly the release the guard exists to
    /// refuse. The worst case is concrete: a release signed with the real private
    /// key while the shipped `SUPublicEDKey` is still the placeholder, which
    /// every installed copy then rejects every future update from, permanently,
    /// with no remedy short of a manual re-download by every user.
    func testPreflightRefusesEveryUnshippableRelease() throws {
        let script = try preflightScript()

        assertGuardExits(#""$VERSION" != "$DECLARED""#, in: script, because: """
            the tag's version and the MARKETING_VERSION the bundle will report must agree — a \
            mismatch ships an appcast advertising a version the app does not have
            """)
        assertGuardExits(#"-z "$DECLARED""#, in: script, because: """
            an unparseable MARKETING_VERSION must be reported as a parse failure rather than \
            compared as an empty string
            """)
        assertGuardExits(#"-z "${SPARKLE_PRIVATE_EDDSA_KEY}""#, in: script, because: """
            without the private key nothing can sign the appcast, and Sparkle rejects an unsigned \
            update outright — this must fail in the first seconds, not after a 20-minute archive
            """)
        assertGuardExits(Self.placeholderPublicKey, in: script, because: """
            while the committed placeholder SUPublicEDKey is still in Resources/Info.plist, every \
            copy in the wild would verify updates against a key whose private half does not exist
            """)

        // The guard has to read the plist the shipped key actually comes from.
        XCTAssertTrue(script.contains { $0.contains("Resources/Info.plist") }, """
            release.yml's placeholder guard must name Resources/Info.plist — the file the shipped \
            key actually comes from.
            """)
        // A refusal with no next step is a refusal someone will work around.
        XCTAssertTrue(script.contains { $0.contains("docs/RELEASING.md") }, """
            Each preflight refusal must point at docs/RELEASING.md, where the one-time key \
            generation and the tagging rules are written.
            """)
    }

    /// Assert that `condition` appears on an `if` line inside `script` and that
    /// the branch it opens reaches `exit 1` before its `fi`.
    private func assertGuardExits(_ condition: String,
                                  in script: [String],
                                  because reason: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let start = script.firstIndex(where: { $0.hasPrefix("if ") && $0.contains(condition) }) else {
            XCTFail("""
                release.yml's preflight has no `if` testing \(condition). It must, because \(reason).
                """, file: file, line: line)
            return
        }

        var refuses = false
        for entry in script[(start + 1)...] {
            if entry == "fi" { break }
            if entry == "exit 1" { refuses = true; break }
        }
        XCTAssertTrue(refuses, """
            release.yml's preflight tests \(condition) but its branch does not `exit 1` — so the \
            run continues and publishes anyway. A `::warning::` here is not a softer guard, it is \
            no guard: \(reason).
            """, file: file, line: line)
    }

    /// The `run:` body of the step named `Preflight`, comment- and blank-stripped.
    ///
    /// Scoped to that one step deliberately: a guard that drifted into a later
    /// step no longer runs before the expensive work, which is the entire reason
    /// the step exists.
    private func preflightScript() throws -> [String] {
        let raw = try workflowText().components(separatedBy: .newlines)
        let start = try XCTUnwrap(raw.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "- name: Preflight"
        }), """
            release.yml has no step named `Preflight`. Everything that can refuse a release cheaply \
            belongs in one step that runs before the archive.
            """)

        var body: [String] = []
        for entry in raw[(start + 1)...] {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- name:") { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            body.append(trimmed)
        }
        return body
    }

    // MARK: - The artefact

    /// `ditto -c -k`, not `zip`. See the type doc: the failure this prevents
    /// happens on the *user's* machine, long after a green run.
    func testUpdateArchiveIsMadeWithDitto() throws {
        let text = try activeText()

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
        // Any flagged `zip` invocation, not just the `zip -r` the first version
        // of this test named: `zip -y` preserves the symlinks but still stores
        // the archive in a layout ditto is chosen over, so pinning one spelling
        // would wave the other through. Anchored on a word boundary so the
        // `.zip` *filenames* (xcodegen.zip, the release asset) do not match.
        let zipCommands = try activeLines().filter { matches(#"(^|\s)zip\s+-"#, in: $0) }
        XCTAssertTrue(zipCommands.isEmpty, """
            release.yml appears to build an archive with `zip`: \(zipCommands). Use ditto — see \
            above.
            """)
    }

    /// The configuration is what decides whether the shipped app can update at
    /// all: the entire updater is behind `#if !DEBUG` in `SoftwareUpdater.swift`.
    /// Nothing else pins it — `Pisaka.xcodeproj` is generated and gitignored and
    /// `project.yml` declares no `schemes:`, so the scheme is auto-created and
    /// "archive uses Release" would rest on an implicit Xcode default. A Debug
    /// archive still embeds `Sparkle.framework` (the package dependency links
    /// unconditionally), so every other check in this workflow would pass while
    /// the release shipped with "Check for Updates…" permanently disabled.
    func testArchiveIsPinnedToTheReleaseConfiguration() throws {
        XCTAssertTrue(try activeText().contains("-configuration Release"), """
            release.yml's archive step must pass `-configuration Release` explicitly. See this \
            test's doc comment: a Debug archive ships an app whose updater was compiled out, and \
            nothing else in this workflow can tell the difference.
            """)
    }

    /// The keys Sparkle reads come from the *partial* `Resources/Info.plist`,
    /// merged into Xcode's generated one — a merge that can stop happening
    /// without failing a build. Verifying them one at a time is the point: a
    /// single `grep -E 'CFBundleVersion|…|SUFeedURL'` over the whole dump
    /// succeeds when *any* alternative matches, and `CFBundleVersion` is always
    /// generated, so the Sparkle keys could vanish with the step still green.
    func testArchivedAppIsVerifiedForEachRequiredInfoPlistKeySeparately() throws {
        let text = try activeText()

        XCTAssertTrue(text.contains("plutil -extract"), """
            The archived app's Info.plist must be checked key by key with `plutil -extract`, which \
            exits non-zero on an absent key. A `grep -E` alternation cannot fail for an individual \
            key — see this test's doc comment.
            """)
        for key in ["CFBundleVersion", "CFBundleShortVersionString", "SUFeedURL", "SUPublicEDKey"] {
            XCTAssertTrue(text.contains(key), """
                release.yml must verify \(key) is present in the archived app's Info.plist. \
                Without SUFeedURL or SUPublicEDKey the shipped app can never find or verify an \
                update, and nothing in the build fails.
                """)
        }
        XCTAssertFalse(text.contains("plutil -p"), """
            release.yml still dumps the plist with `plutil -p` and greps it. That check passes as \
            long as *one* of the keys it names is present; use per-key `plutil -extract`.
            """)
    }

    func testBuildNumberComesFromTheMonotonicRunNumber() throws {
        XCTAssertTrue(try activeText().contains("CURRENT_PROJECT_VERSION=${{ github.run_number }}"), """
            The archive's build number must be `github.run_number`. CFBundleVersion is what \
            Sparkle compares to decide one build is newer than another, so it has to increase \
            strictly across every release — and it must not be a committed value, or every \
            release would carry a build-number churn commit (docs/RELEASING.md). run_number is \
            GitHub's per-workflow-file counter and never resets.

            The caveat that comes with it — the counter is keyed on this file's *name*, so \
            renaming release.yml restarts it at 1 and a build numbered 1 published after build 12 \
            is one Sparkle will never offer — is documented in this file's header and in \
            docs/RELEASING.md. It is prose about a future edit, so it is deliberately not asserted \
            here: a test that greps for the word "renamed" pins the wording of a comment and \
            nothing about the workflow.
            """)
    }

    // MARK: - Pins

    /// The Sparkle tools are downloaded and then run with the private signing key
    /// on their stdin, so they are pinned exactly like XcodeGen: exact URL, and a
    /// digest checked before anything is extracted.
    func testSparkleReleaseToolsArePinnedByURLAndDigest() throws {
        let text = try activeText()

        XCTAssertTrue(text.contains(Self.sparkleToolsURL), """
            release.yml must download Sparkle's release tools from the pinned 2.9.5 URL \
            (\(Self.sparkleToolsURL)) — the same version the app links, so generate_appcast's \
            signature format and the shipped framework's verifier cannot drift apart.
            """)

        // Narrowed to the file it is checked against: a digest that drifted onto
        // the xcodegen.zip line would otherwise satisfy this.
        let digests = shasumDigests(in: try workflowText(), forFile: Self.sparkleToolsFile)
        XCTAssertEqual(digests, [Self.sparkleToolsDigest], """
            release.yml must verify \(Self.sparkleToolsFile) with `shasum -a 256 -c -` against \
            \(Self.sparkleToolsDigest). The digests it actually checks against that file: \
            \(digests.sorted()). This is the trust boundary for code that then runs with the \
            private signing key on its stdin.
            """)
    }

    /// The tools are fetched and digest-checked *before* the archive, for the
    /// same reason the preflight exists: a moved asset or a changed tarball
    /// layout must not be discovered after a 20-minute build.
    func testSparkleToolsAreInstalledBeforeTheArchive() throws {
        let lines = try activeLines()
        let tools = try XCTUnwrap(lines.firstIndex(where: { $0.contains(Self.sparkleToolsURL) }),
                                  "release.yml no longer downloads the Sparkle tools")
        let archive = try XCTUnwrap(lines.firstIndex(where: { $0.contains("-archivePath") }),
                                    "release.yml no longer archives the app")

        XCTAssertLessThan(tools, archive, """
            The Sparkle tools download and digest check must come before the archive step. \
            Everything that can refuse the release cheaply belongs before the expensive work — a \
            failed digest after a 20-minute build is the exact cost the preflight is arranged to \
            avoid.
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

    // MARK: - The cross-file invariants

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

        let lines = try activeLines()
        let create = try XCTUnwrap(lines.firstIndex(where: { $0.contains("gh release create") }), """
            release.yml no longer creates the release with `gh release create`.
            """)

        // The assets are the trailing positional arguments of the line-continued
        // `gh` invocation; scan the rest of that step for one named exactly as
        // the feed's last path component.
        let attaches = lines[create...].prefix(12).contains { line in
            line.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \\")) == assetName
        }
        XCTAssertTrue(attaches, """
            release.yml must attach the appcast under the literal name “\(assetName)” — the last \
            path component of SUFeedURL in Resources/Info.plist. GitHub's \
            releases/latest/download/<asset> redirect resolves by asset name alone, so any other \
            name leaves every installed copy fetching a 404 forever, with nothing failing here or \
            in the app.
            """)

        XCTAssertTrue(try activeText().contains("-o \(assetName)"), """
            generate_appcast must write the feed to “\(assetName)”, so the file attached to the \
            release already carries the name SUFeedURL resolves against.
            """)
    }

    /// The enclosure URLs the appcast advertises are built from this prefix, and
    /// Sparkle refuses a plain-HTTP download the same way it refuses a
    /// plain-HTTP feed.
    ///
    /// The repository it points at is the *other* half of the same contract: the
    /// feed is fetched from the repository in `SUFeedURL` and the update is then
    /// downloaded from the repository in this prefix. Both are spelled out by
    /// hand in two different files, so a rename or transfer that updates one and
    /// not the other leaves the appcast advertising enclosures on a repository
    /// the feed does not come from — a 404 for every installed copy, and green
    /// on both sides.
    func testTheAppcastDownloadPrefixIsHTTPSOnTheSameRepositoryAsTheFeed() throws {
        let text = try activeText()
        let prefix = try XCTUnwrap(firstMatch(#"--download-url-prefix "([^"]+)""#, in: text), """
            release.yml no longer passes --download-url-prefix to generate_appcast; without it \
            the appcast's enclosure URLs do not resolve to the release's own assets.
            """)
        XCTAssertTrue(prefix.hasPrefix("https://github.com/"), """
            The appcast's download prefix must be HTTPS on github.com — it is where every \
            installed copy fetches the update from. Got “\(prefix)”.
            """)

        let feed = try XCTUnwrap(feedURL(), "Resources/Info.plist has no parseable SUFeedURL")
        let feedRepository = try XCTUnwrap(repositorySlug(of: feed), """
            SUFeedURL “\(feed)” has no <owner>/<repo> path prefix.
            """)
        let prefixRepository = try XCTUnwrap(URL(string: prefix).flatMap(repositorySlug), """
            --download-url-prefix “\(prefix)” has no <owner>/<repo> path prefix.
            """)
        XCTAssertEqual(prefixRepository, feedRepository, """
            The appcast's --download-url-prefix must name the same repository as SUFeedURL in \
            Resources/Info.plist. The feed says “\(feedRepository)”, the workflow says \
            “\(prefixRepository)” — installed copies would fetch the feed from one repository and \
            then 404 on enclosures hosted by another.
            """)
    }

    /// `<owner>/<repo>` — the first two path components of a github.com URL.
    private func repositorySlug(of url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
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

    /// The workflow's active lines — see the type doc for why nothing in this
    /// suite may match against the raw text.
    private func activeLines(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let lines = activeYAMLLines(of: try workflowText())
        XCTAssertFalse(lines.isEmpty, "parsed nothing out of release.yml", file: file, line: line)
        return lines
    }

    /// The active lines rejoined — the only text a `contains` in this suite may
    /// run over.
    private func activeText(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try activeLines(file: file, line: line).joined(separator: "\n")
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

    /// Whether `pattern` matches anywhere in `text`.
    private func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
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
