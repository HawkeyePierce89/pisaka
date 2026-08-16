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

    /// The Apple Developer Team the release is signed and notarized under. It
    /// appears in the workflow twice — the identity refusal and the archive's
    /// `DEVELOPMENT_TEAM` — and a release signed under any other team is one no
    /// installed copy's Sparkle update can be verified against by Gatekeeper.
    private static let developerIDTeam = "XJT3LK36GS"

    /// The name of the step that builds the run's keychain and imports the
    /// signing certificate. A constant for the same reason `archiveStepName` is
    /// one: several tests scope themselves to it.
    private static let certificateStepName = "Import the Developer ID certificate"

    /// The name of the `if: always()` step that deletes that keychain again.
    private static let keychainCleanupStepName = "Remove the signing keychain"

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

        assertGuardExits(#""$VERSION" != "$DECLARED""#, in: script, step: "Preflight", because: """
            the tag's version and the MARKETING_VERSION the bundle will report must agree — a \
            mismatch ships an appcast advertising a version the app does not have
            """)
        assertGuardExits(#"-z "$DECLARED""#, in: script, step: "Preflight", because: """
            an unparseable MARKETING_VERSION must be reported as a parse failure rather than \
            compared as an empty string
            """)
        assertGuardExits(#"-z "${SPARKLE_PRIVATE_EDDSA_KEY}""#, in: script, step: "Preflight", because: """
            without the private key nothing can sign the appcast, and Sparkle rejects an unsigned \
            update outright — this must fail in the first seconds, not after a 20-minute archive
            """)
        assertGuardExits(Self.placeholderPublicKey, in: script, step: "Preflight", because: """
            while the committed placeholder SUPublicEDKey is still in Resources/Info.plist, every \
            copy in the wild would verify updates against a key whose private half does not exist
            """)

        // The five signing/notarization secrets, each refused on its own. One
        // combined "signing is not configured" check would be cheaper to write
        // and useless to read: the five come from four different one-time
        // procedures, so the only actionable message is the one that names the
        // missing secret. Each is asserted by mechanism for the reason the whole
        // suite is — a `::warning::` here would archive for twenty minutes and
        // then fail at `codesign`, or worse, at the notary service twenty more
        // minutes later.
        for secret in [
            "DEVELOPER_ID_CERT_P12",
            "DEVELOPER_ID_CERT_PASSWORD",
            "APP_STORE_CONNECT_API_KEY_P8",
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_ISSUER_ID",
        ] {
            assertGuardExits(#"-z "${\#(secret)}""#, in: script, step: "Preflight", because: """
                without \(secret) the release cannot be signed or notarized at all, and the whole \
                point of the preflight is that this costs ten seconds rather than a 20-minute \
                archive followed by a 20-minute notary round trip
                """)

            // The secret has to reach the step, or the `-z` above tests an
            // unset variable that is empty for a reason nobody can fix.
            XCTAssertTrue(script.contains { $0 == "\(secret): ${{ secrets.\(secret) }}" }, """
                release.yml's `Preflight` step must receive \(secret) through its `env:` block. \
                Without the mapping the guard tests an always-empty variable and refuses every \
                release, secret or no secret.
                """)
        }

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
    ///
    /// `step` names the step being asserted about, so the failure says which one:
    /// this is used for the preflight's four refusals *and* for the
    /// unsigned-appcast refusal, which cannot live in the preflight because it
    /// can only be made after `generate_appcast` has run.
    private func assertGuardExits(_ condition: String,
                                  in script: [String],
                                  step: String,
                                  because reason: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let start = script.firstIndex(where: { $0.hasPrefix("if ") && $0.contains(condition) }) else {
            XCTFail("""
                release.yml's `\(step)` step has no `if` testing \(condition). It must, because \
                \(reason).
                """, file: file, line: line)
            return
        }

        // Nesting-aware on both counts. A guarded branch may contain its own
        // `if` — the notarization refusal does, to tell "no log for this
        // submission" from "no submission id at all" — and reading that inner
        // `fi` as the end of the branch would report a guard that does refuse as
        // one that does not. The `exit 1` is required at depth 0 for the mirror
        // reason: an `exit 1` reachable only under a *second* condition is not
        // this guard refusing, and counting it would wave through the one shape
        // this helper exists to catch.
        var refuses = false
        var depth = 0
        for entry in script[(start + 1)...] {
            if entry.hasPrefix("if ") { depth += 1; continue }
            if entry == "fi" {
                if depth == 0 { break }
                depth -= 1
                continue
            }
            if entry == "exit 1", depth == 0 { refuses = true; break }
        }
        XCTAssertTrue(refuses, """
            release.yml's `\(step)` step tests \(condition) but its branch does not `exit 1` — so \
            the run continues and publishes anyway. A `::warning::` here is not a softer guard, it \
            is no guard: \(reason).
            """, file: file, line: line)
    }

    /// The `run:` body of the step named `Preflight`, comment- and blank-stripped.
    ///
    /// Scoped to that one step deliberately: a guard that drifted into a later
    /// step no longer runs before the expensive work, which is the entire reason
    /// the step exists.
    private func preflightScript() throws -> [String] {
        try stepScript(named: "Preflight", because: """
            Everything that can refuse a release cheaply belongs in one step that runs before the \
            archive.
            """)
    }

    /// One step's body, comment- and blank-stripped.
    ///
    /// Every assertion about a command belongs against the step that runs it,
    /// not against the whole file. A workflow-wide `contains` stays green when
    /// the setting it names moves to some other step — the same silent-drift
    /// failure the comment-stripping in this suite exists to catch, one level up.
    ///
    /// The body ends at the first line indented no deeper than the `- name:` that
    /// opened it, which is the only reading that actually scopes the *last* step
    /// of a job: breaking on `- name:` alone runs on through a following `- uses:`
    /// step and into the next job entirely, so an assertion about the last step
    /// could be satisfied by a line belonging to another one.
    private func stepScript(named name: String,
                            in workflow: String = "release.yml",
                            because reason: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> [String] {
        let raw = try text(atRepositoryPath: ".github/workflows/\(workflow)")
            .components(separatedBy: .newlines)
        let start = try XCTUnwrap(raw.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "- name: \(name)"
        }), """
            \(workflow) has no step named `\(name)`. \(reason)
            """, file: file, line: line)

        let indent = raw[start].prefix { $0 == " " || $0 == "\t" }.count

        var body: [String] = []
        for entry in raw[(start + 1)...] {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if entry.prefix(while: { $0 == " " || $0 == "\t" }).count <= indent { break }
            body.append(trimmed)
        }
        return body
    }

    // MARK: - The signing identity

    /// The certificate is imported into a keychain made for this run, under
    /// `$RUNNER_TEMP`, and the decoded `.p12` does not outlive the step.
    ///
    /// Each of these is a separate way to leak or to hang, and none of them fails
    /// the run when it regresses:
    ///
    ///  * a keychain created anywhere but `$RUNNER_TEMP` (the working directory,
    ///    `~/Library/Keychains`) is one the cleanup step's path no longer names,
    ///    so it survives the job;
    ///  * `security import` without `-T /usr/bin/codesign`, or without the
    ///    partition list, leaves the key's ACL asking for interactive
    ///    authorization — on a headless runner that is a hang until the job's
    ///    own timeout, not an error;
    ///  * `security list-keychains -s` replaces the *whole* user search list, so
    ///    passing the new keychain alone silently drops every other keychain for
    ///    the rest of the job. Prepending is the only correct call, and the
    ///    previous list has to be saved for the cleanup step to restore.
    func testTheSigningCertificateIsImportedIntoAThrowawayKeychain() throws {
        let script = try stepScript(named: Self.certificateStepName, because: """
            It is the step that gives this workflow a signing identity at all.
            """)

        XCTAssertTrue(script.contains { $0.contains("security create-keychain") }, """
            release.yml's `\(Self.certificateStepName)` step must create its own keychain with \
            `security create-keychain`. Importing into whatever keychain happens to be first on \
            the search list means importing into the runner's login keychain.
            """)
        XCTAssertTrue(script.contains { $0.contains("KEYCHAIN=\"${RUNNER_TEMP}/") }, """
            The run's keychain must live under $RUNNER_TEMP. Anywhere else and the cleanup step's \
            path no longer names it, so the signing key outlives the job it was imported for.
            """)
        XCTAssertTrue(script.contains { $0.contains("security import") }, """
            release.yml's `\(Self.certificateStepName)` step must import the certificate with \
            `security import`.
            """)
        XCTAssertTrue(script.contains { $0.contains("-T /usr/bin/codesign") }, """
            `security import` must pass `-T /usr/bin/codesign`, or the imported key's ACL does not \
            list the one tool that has to use it and codesign asks for interactive authorization \
            — a hang on a headless runner, not a failure.
            """)
        let partitionList = try XCTUnwrap(script.first(where: {
            $0.contains("security set-key-partition-list")
        }), """
            The imported key needs `security set-key-partition-list -S apple-tool:,apple:`. \
            Without it the first codesign raises the "wants to sign using key in your keychain" \
            dialog and the job hangs until its timeout.
            """)
        // `-s` narrows the update to keys that can *sign*. Without it the query
        // is match-all over every key item in the keychain, and an item with no
        // access control makes the tool exit non-zero — under `set -e` that ends
        // the step on a key this workflow neither imported nor needs, after the
        // preflight passed and with no `::error::` annotation. Nothing in CI can
        // reach this step, so the flag is pinned here or not at all.
        XCTAssertTrue(partitionList.contains(" -s "), """
            `security set-key-partition-list` must pass `-s` so the partition list is applied to \
            the signing key rather than to every key item in the keychain. Got “\(partitionList)”.
            """)
        XCTAssertTrue(script.contains { $0.contains("security unlock-keychain") }, """
            The run's keychain must be unlocked with `security unlock-keychain`. A freshly created \
            keychain is locked, and `codesign` against a locked keychain fails with "User \
            interaction is not allowed" — a message that names neither the keychain nor the lock, \
            and reads like a certificate problem.
            """)

        // The lock settings, asserted including the flag that must *not* be
        // there. `-l` is "lock when the system sleeps"; `-lut` is `-l -u -t`,
        // so the difference between the two spellings is invisible unless the
        // absence is what is asserted.
        let settings = try XCTUnwrap(script.first(where: { $0.contains("security set-keychain-settings") }), """
            release.yml's `\(Self.certificateStepName)` step must set the keychain's lock settings \
            with `security set-keychain-settings`. The default auto-lock interval is five minutes, \
            which is shorter than the archive — the keychain then re-locks mid-build and codesign \
            fails with "User interaction is not allowed".
            """)
        XCTAssertTrue(settings.contains("-ut "), """
            `security set-keychain-settings` must pass `-u -t <seconds>` with a timeout longer than \
            this job. Got “\(settings)”.
            """)
        XCTAssertFalse(settings.contains("-lut") || settings.contains(" -l "), """
            `security set-keychain-settings` must not pass `-l` — it means "lock when the system \
            sleeps", not "lock timeout", and `-lut` is `-l -u -t`. Got “\(settings)”.
            """)

        // The decoded .p12 is removed by the step that wrote it — not by the
        // cleanup step alone, which is a backstop rather than the rule.
        let decode = try XCTUnwrap(script.firstIndex(where: { $0.contains("base64 --decode") }), """
            release.yml's `\(Self.certificateStepName)` step no longer decodes the base64 .p12 \
            secret.
            """)
        let remove = try XCTUnwrap(script.firstIndex(where: {
            $0.hasPrefix("rm -f") && $0.contains("CERTIFICATE")
        }), """
            The decoded .p12 — the private key in the clear — must be removed by the step that \
            wrote it, right after `security import` consumes it.
            """)
        XCTAssertLessThan(decode, remove, """
            The decoded .p12 must be removed *after* it is written, in the same step.
            """)
        // …and is not world-readable while it exists. Same rule and same reason
        // as the .p8's: it is the signing private key, and the step's own stated
        // premise is that this job may not lean on the runner being private.
        // Asserted on the decode line itself because the redirect is what
        // creates the file — a narrowing that is not part of the write is a
        // window, not a fix.
        XCTAssertTrue(script[decode].hasPrefix("(umask 077;"), """
            The decoded .p12 must be written inside a `(umask 077; …)` subshell. Under the \
            runner's default umask it lands world-readable, and the password that protects it is \
            passed to `security import` as an argv on the next line — so both halves of the \
            signing key are exposed together, which is exactly what this step's own comment about \
            not trusting the runner's privacy argues against. Got “\(script[decode])”.
            """)

        // The two certificate secrets refuse in this workflow's own style, by
        // mechanism.
        //
        // These are the two failures with the least legible bare output in the
        // file — `base64: Invalid character in input stream.` for a mis-pasted
        // body, `SecKeychainItemImport: MAC verification failed` for a password
        // that belongs to a different .p12 — and they are fixed by editing
        // *different* secrets, which is exactly the case docs/RELEASING.md warns
        // about when only one of the pair is rotated. Bare, both still stop the
        // run (`set -e`), so nothing here is about fail-closed: it is about the
        // run stopping with a message that names which secret to replace, in a
        // step no PR can exercise.
        //
        // The two refusals do not partition the causes cleanly, and the workflow
        // says so rather than pretending otherwise: `base64 --decode` rejects
        // invalid characters, not a short body, so a paste truncated at a
        // multiple of four bytes decodes into a partial .p12 and arrives at the
        // import refusal. That is why the import message names both halves
        // instead of concluding "the decode succeeded, so it is the password".
        //
        // The decode is guarded with `|| { … }` rather than `if !` because the
        // umask assertion above reads the decode line itself, so the scan for
        // its `exit 1` is spelled out instead of going through
        // `assertGuardExits`.
        XCTAssertTrue(script[decode].hasSuffix("|| {"), """
            The base64 decode of DEVELOPER_ID_CERT_P12 must be guarded. Bare, a mis-pasted secret \
            ends the step with `base64: Invalid character in input stream.` and names neither the \
            secret nor how to regenerate it. Got “\(script[decode])”.
            """)
        let decodeRefuses = script[(decode + 1)...].prefix(while: { $0 != "}" }).contains("exit 1")
        XCTAssertTrue(decodeRefuses, """
            The base64 decode's `|| { … }` branch must `exit 1`. A branch that only annotates lets \
            the run continue to `security import` with an empty or partial .p12, which then fails \
            for a second, unrelated-looking reason.
            """)
        assertGuardExits("security import", in: script, step: Self.certificateStepName, because: """
            a bare `security import` fails a wrong DEVELOPER_ID_CERT_PASSWORD as \
            `SecKeychainItemImport: MAC verification failed`, which names no secret — and the two \
            certificate secrets are a pair, either of which can be the broken half here, so the \
            reader has to be told which two to look at and that the decode having passed rules \
            out neither
            """)

        // The search list is prepended to, not replaced, and the previous value
        // is saved for the cleanup step.
        let setList = try XCTUnwrap(script.first(where: { $0.contains("list-keychains -d user -s") }), """
            release.yml must put the run's keychain on the *user* search list with \
            `security list-keychains -d user -s`, or codesign never sees the identity.
            """)
        XCTAssertTrue(setList.contains("keychains-before"), """
            `security list-keychains -s` overwrites the whole user search list. The call must pass \
            the previously-listed keychains alongside the new one, and must have saved them first \
            so the cleanup step can restore them. Got “\(setList)”.
            """)
    }

    /// The runner's login keychain is never named in this workflow.
    ///
    /// It is the default target of every `security` subcommand that is not told
    /// otherwise, so naming it at all is the single edit that turns this from
    /// "a keychain we made and delete" into "a modification of a keychain that
    /// is not ours" — and the cleanup step would then be *deleting the runner's
    /// login keychain*, which fails in a way nobody reads until it does not.
    func testTheLoginKeychainIsNeverTouched() throws {
        let text = try activeText()
        for spelling in ["login.keychain", "login.keychain-db", "~/Library/Keychains"] {
            XCTAssertFalse(text.contains(spelling), """
                release.yml names “\(spelling)”. The signing certificate belongs in a keychain \
                this workflow creates under $RUNNER_TEMP and deletes again; the login keychain is \
                shared with every other step in the job and is not this workflow's to modify or \
                delete.
                """)
        }
    }

    /// A certificate of the wrong *type* is the failure this refusal exists for,
    /// and it is the one that costs the most.
    ///
    /// An Apple Development certificate, or a Developer ID certificate belonging
    /// to some other team, imports cleanly, is listed by `find-identity`, and
    /// signs the archive without complaint. Nothing local objects. The rejection
    /// arrives from the notary service, after a 20-minute archive and however
    /// long the submission queue is — and it arrives as a JSON status rather than
    /// as anything that names the certificate. An expired certificate is the
    /// cheap case: `find-identity -v` does not list it at all, so the same guard
    /// covers it.
    func testTheImportedIdentityMustBeDeveloperIDForTheTeam() throws {
        let script = try stepScript(named: Self.certificateStepName, because: """
            It is the only place the certificate's type and team can be checked before the archive.
            """)

        XCTAssertTrue(script.contains { $0.contains("security find-identity -v -p codesigning") }, """
            release.yml must list the imported identities with \
            `security find-identity -v -p codesigning`. The `-v` is what restricts the listing to \
            identities that are actually valid for signing, so an expired certificate is caught by \
            its absence.
            """)

        assertGuardExits("Developer ID Application:.*(\(Self.developerIDTeam))",
                         in: script,
                         step: Self.certificateStepName,
                         because: """
            an Apple Development certificate — or a Developer ID certificate for another team — \
            imports cleanly and signs the archive, and is then rejected by the notary service \
            twenty minutes later with a status that names no certificate
            """)
    }

    /// The identity has to exist before the thing that needs it, which is the
    /// whole argument the preflight makes: the archive is the expensive step, and
    /// a signing failure inside it costs the build.
    func testTheCertificateIsImportedBeforeTheArchive() throws {
        let lines = try activeLines()
        let importIndex = try XCTUnwrap(lines.firstIndex(where: {
            $0 == "- name: \(Self.certificateStepName)"
        }), "release.yml has no `\(Self.certificateStepName)` step")
        let archive = try XCTUnwrap(lines.firstIndex(where: { $0.contains("-archivePath") }),
                                    "release.yml no longer archives the app")

        XCTAssertLessThan(importIndex, archive, """
            The certificate must be imported before the archive step. Everything that can refuse \
            the release cheaply belongs before the expensive work — an unusable certificate \
            discovered by `codesign` at the end of a 20-minute build is the exact cost the \
            preflight is arranged to avoid.
            """)
    }

    /// No path out of this job may leave the signing key on the runner.
    ///
    /// `if: always()` is what makes that true for the two paths nobody tests: a
    /// failure in any step above (the archive, the notarization, the publication)
    /// and a cancelled run. Without it the cleanup is skipped in exactly the
    /// situations where something went wrong, which is when the runner's state is
    /// least worth trusting. Being the *last* step is the other half: a cleanup
    /// that sits before the archive deletes the keychain the archive needs.
    func testTheSigningKeychainIsRemovedOnEveryPath() throws {
        let script = try stepScript(named: Self.keychainCleanupStepName, because: """
            No path through this job — success, failure or cancellation — may leave the signing \
            certificate on the runner.
            """)

        XCTAssertTrue(script.contains("if: always()"), """
            release.yml's `\(Self.keychainCleanupStepName)` step must carry `if: always()`. Without \
            it the keychain survives precisely the runs that failed part-way, and a cancelled run \
            never cleans up at all.
            """)
        XCTAssertTrue(script.contains { $0.contains("security delete-keychain") }, """
            release.yml's `\(Self.keychainCleanupStepName)` step must actually delete the keychain \
            with `security delete-keychain`.
            """)
        XCTAssertTrue(script.contains { $0.contains("KEYCHAIN=\"${RUNNER_TEMP}/") }, """
            The cleanup step must name the same $RUNNER_TEMP keychain the import step created. A \
            path that drifted out of step with the import deletes nothing and reports success.
            """)
        XCTAssertTrue(script.contains { $0.contains("list-keychains -d user -s") }, """
            The cleanup step must restore the user search list it prepended to. Leaving the \
            deleted keychain on the list makes every later `security` call in the job warn about \
            a keychain that no longer exists.
            """)

        // Both private keys, by literal path. Each is also removed by the step
        // that wrote it, and neither of those removals survives a cancellation:
        // a `SIGKILL`ed step runs no `trap … EXIT` and no trailing `rm`, which
        // is the one path this `if: always()` step exists for. Asserting only
        // the .p12 would certify the weaker guarantee as the stronger one.
        for key in ["${RUNNER_TEMP}/developer-id.p12", "${RUNNER_TEMP}/notary-key.p8"] {
            XCTAssertTrue(script.contains { $0.hasPrefix("rm -f") && $0.contains(key) }, """
                release.yml's `\(Self.keychainCleanupStepName)` step must `rm -f \(key)`. The step \
                that writes it removes it on every path it reaches the end of, but a cancelled \
                run — the case this `if: always()` step is here for — reaches none of them, and \
                the private key is then what the job leaves behind. \(script)
                """)
        }

        // A cleanup that cannot fail is a cleanup nobody can rely on. The step
        // deliberately runs without `errexit` — one failing command must not
        // abandon the rest of the removal — and the cost of that is a step
        // whose exit status is whatever its *last* command returned: `rm -f`,
        // which succeeds on a file that is not there. So `security
        // delete-keychain` can fail, the certificate can stay on the runner,
        // and the job still reports success about it. The accumulator is what
        // separates "the keys are gone because we removed them" from "the keys
        // are gone because nothing said otherwise".
        XCTAssertTrue(script.contains { $0.hasPrefix("STATUS=") }, """
            release.yml's `\(Self.keychainCleanupStepName)` step must accumulate a status. It runs \
            without `set -e` on purpose, so without one every command's failure is swallowed by \
            the next and the step's exit code is the trailing `rm -f`'s — which succeeds whether \
            or not the keychain was deleted.
            """)
        for command in ["security list-keychains -d user -s", "security delete-keychain", "rm -f"] {
            XCTAssertTrue(script.contains { $0.contains(command) && $0.hasSuffix("|| STATUS=1") }, """
                release.yml's `\(Self.keychainCleanupStepName)` step must record a failure of \
                `\(command)` into the status it exits with. A cleanup command whose failure is \
                neither fatal nor recorded is one whose result the job asserts without checking. \
                \(script)
                """)
        }
        assertGuardExits("STATUS", in: script, step: Self.keychainCleanupStepName, because: """
            a cleanup that failed must fail the job. Recording the failures and then exiting 0 \
            reports a runner scrubbed of the Developer ID certificate and the notary key when it \
            may still hold both
            """)

        // Last step of the file, so nothing that needs the identity runs after
        // the keychain is gone.
        let lines = try activeLines()
        let headers = lines.indices.filter { lines[$0].hasPrefix("- name:") || lines[$0].hasPrefix("- uses:") }
        let last = try XCTUnwrap(headers.last, "release.yml declares no steps at all")
        XCTAssertEqual(lines[last], "- name: \(Self.keychainCleanupStepName)", """
            The keychain cleanup must be the last step of the release job — the last step in the \
            file. It currently is not: “\(lines[last])” comes after it, and anything that runs \
            after the keychain is deleted cannot sign, notarize or verify anything.
            """)
    }

    /// Every refusal in this workflow is a refusal only because the step it sits
    /// in is fatal to the job.
    ///
    /// This is the assumption every `assertGuardExits` in this file rests on and
    /// none of them can see: they prove an `exit 1` is reachable inside a
    /// script, not that the job stops when it runs. `continue-on-error: true` on
    /// a step turns all of them into echoed text — the notarization refusal, the
    /// signature checks, the appcast-signature guard — and the run still
    /// publishes, green. `if:` is the same edit spelled differently: a step
    /// skipped by a condition never runs its guards at all, and an `if: false`
    /// on the staple step ships an app whose ticket lives only on Apple's
    /// servers.
    ///
    /// So: no `continue-on-error:` anywhere, and the one legitimate `if:` is the
    /// cleanup step's `always()`, which widens rather than narrows when the step
    /// runs.
    func testEveryStepFailureStopsTheRelease() throws {
        let lines = try activeLines()

        XCTAssertFalse(lines.contains { $0.hasPrefix("continue-on-error:") }, """
            release.yml carries a `continue-on-error:`. Every refusal in this workflow — the \
            preflight's, the identity check, the signature verification, the non-Accepted \
            notarization status, the appcast signature — is a refusal only because its step's \
            failure ends the job. `continue-on-error: true` demotes all of them to log lines and \
            publishes the release anyway.
            """)

        let conditions = lines.filter { $0.hasPrefix("if:") }
        XCTAssertEqual(conditions, ["if: always()"], """
            The only step condition release.yml may carry is the keychain cleanup's \
            `if: always()`, which makes a step run *more* often. Any other `if:` makes a step run \
            less often, and a skipped step runs none of the guards this suite asserts: `if: false` \
            on the staple step ships an unstapled app with every assertion here still green. Got \
            \(conditions).
            """)
    }

    /// The job's own budget has to be bigger than the wait it contains.
    ///
    /// The notary submission blocks for up to its `--timeout`, on top of an
    /// archive that pays for whole-module optimization across the app and every
    /// linked dependency — and `ci.yml` gives a strictly *smaller* workload (a
    /// Release build rather than an archive) its own budget, read from that file
    /// rather than restated here. If the two do not fit,
    /// a slow-but-healthy notary queue ends the run as a GitHub cancellation:
    /// no `::error::` annotation, none of this workflow's actionable messages,
    /// and — if it lands after `gh release create --draft` — a draft release
    /// occupying the tag that has to be deleted by hand before the tag can be
    /// re-pushed.
    func testTheJobBudgetCoversTheNotaryWait() throws {
        let lines = try activeLines()

        // The budget of the job that *contains* the notarization, found by
        // walking back from the step rather than by taking the file's first
        // `timeout-minutes:` — this workflow has two jobs and they have
        // different budgets.
        let notarize = try XCTUnwrap(lines.firstIndex(where: {
            $0 == "- name: \(Self.notarizeStepName)"
        }), "release.yml has no `\(Self.notarizeStepName)` step")
        let budgetLine = try XCTUnwrap(lines[..<notarize].last(where: { $0.hasPrefix("timeout-minutes:") }), """
            The job that notarizes must declare a `timeout-minutes:`. Without one it runs under \
            GitHub's six-hour default, and a stuck submission holds a runner for the afternoon.
            """)
        let budget = try XCTUnwrap(Int(budgetLine.dropFirst("timeout-minutes:".count)
            .trimmingCharacters(in: .whitespaces)), "could not read a number out of “\(budgetLine)”")

        let script = try stepScript(named: Self.notarizeStepName, because: """
            It is the step whose wait the job budget has to cover.
            """)
        let wait = try XCTUnwrap(script.compactMap { firstMatch(#"--timeout (\d+)m"#, in: $0) }.first, """
            `notarytool submit --wait` must carry a `--timeout <n>m`, in minutes, so this \
            assertion can compare it against the job's budget.
            """)
        let waitMinutes = try XCTUnwrap(Int(wait), "could not read a number out of “\(wait)”")

        // The floor is *read from* `ci.yml`, not written here as a literal.
        // `CLAUDE.md` and `docs/RELEASING.md` both state this relation as "the
        // job budget exceeds the notary `--timeout` by at least ci.yml's build
        // budget", and a hardcoded 45 makes that sentence true only by
        // coincidence: raise CI's budget because the Release build got slower —
        // the one change that means an archive needs *more* headroom, not the
        // same — and this assertion keeps passing at the old number while the
        // documented invariant quietly stops holding. Same cross-file read as
        // `testXcodeGenIsPinnedIdenticallyToCI`.
        let ciFloor = try ciMacBuildBudget()
        XCTAssertGreaterThanOrEqual(budget - waitMinutes, ciFloor, """
            The release job budgets \(budget) minutes and is willing to wait \(waitMinutes) of \
            them for the notary service, leaving \(budget - waitMinutes) for the archive. ci.yml \
            gives \(ciFloor) minutes to a Release *build* of this target, which is strictly less \
            work than an archive of it. A slow-but-healthy notary queue would therefore end this \
            run as a cancellation — no error annotation, no message, and a draft release possibly \
            left occupying the tag. Raise `timeout-minutes:` or lower `--timeout`.
            """)
    }

    /// `ci.yml`'s budget for its macOS Release build, found by walking back from
    /// the build step rather than by taking the file's first `timeout-minutes:`
    /// — that file has three jobs with three different budgets, and the first is
    /// the *test* job's.
    private func ciMacBuildBudget(file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let lines = activeYAMLLines(of: try text(atRepositoryPath: ".github/workflows/ci.yml"))
        let step = try XCTUnwrap(lines.firstIndex(where: {
            $0 == "- name: \(Self.ciMacBuildStepName)"
        }), """
            ci.yml has no `\(Self.ciMacBuildStepName)` step, so the release job's budget has \
            nothing to be measured against. If the step was renamed, update `ciMacBuildStepName`.
            """, file: file, line: line)
        let budgetLine = try XCTUnwrap(lines[..<step].last(where: { $0.hasPrefix("timeout-minutes:") }), """
            ci.yml's macOS build job must declare a `timeout-minutes:` — it is the floor the \
            release job's post-notary headroom is compared against.
            """, file: file, line: line)
        return try XCTUnwrap(Int(budgetLine.dropFirst("timeout-minutes:".count)
            .trimmingCharacters(in: .whitespaces)),
            "could not read a number out of ci.yml's “\(budgetLine)”", file: file, line: line)
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
    ///
    /// Scoped to the archive step rather than to the whole file, for the reason
    /// `stepScript(named:because:)` states: a later step that happened to carry
    /// `-configuration Release` would keep a file-wide `contains` green while the
    /// archive itself silently went back to Xcode's implicit default.
    func testArchiveIsPinnedToTheReleaseConfiguration() throws {
        let script = try stepScript(named: Self.archiveStepName, because: """
            It is the step whose configuration decides whether the shipped app can update at all.
            """)
        XCTAssertTrue(script.contains { $0.contains("-configuration Release") }, """
            release.yml's `\(Self.archiveStepName)` step must pass `-configuration Release` \
            explicitly. See this test's doc comment: a Debug archive ships an app whose updater \
            was compiled out, and nothing else in this workflow can tell the difference.
            """)
    }

    /// The name of the step that produces the archive. A constant because
    /// several tests scope themselves to it, and a renamed step must fail loudly
    /// rather than silently check nothing.
    private static let archiveStepName = "Archive (macOS, Developer ID signed, hardened runtime)"

    /// The name of the step that verifies the archived bundle before anything is
    /// zipped, notarized or published.
    private static let verifyStepName = "Verify the archived app"

    /// The name of the step that re-signs Sparkle's nested helper bundles with
    /// this run's Developer ID identity, between the archive and the
    /// verification. A constant for the same reason `archiveStepName` is one.
    private static let reSignStepName = "Re-sign Sparkle's nested helpers"

    /// The four nested helper bundles `Sparkle.framework` ships, as paths under
    /// the framework.
    ///
    /// They are the four binaries the notary service named when it rejected
    /// `v1.0`: Xcode's archive re-signs the framework *bundle* and does not
    /// recurse into these, so each one reached Apple carrying upstream's ad-hoc
    /// signature — no Developer ID authority and no secure timestamp.
    ///
    /// The list is shared between the two halves of this feature on purpose. The
    /// re-sign step signs exactly these, and the verification step requires
    /// exactly these to be among the Mach-Os it enumerated; a Sparkle version
    /// whose layout moves one of them must fail *both* assertions here rather
    /// than let the two drift apart.
    private static let sparkleNestedHelpers = [
        "Versions/B/XPCServices/Downloader.xpc",
        "Versions/B/XPCServices/Installer.xpc",
        "Versions/B/Autoupdate",
        "Versions/B/Updater.app",
    ]

    /// Whether `line` invokes `codesign` to *apply* a signature, as opposed to
    /// verifying or displaying one.
    ///
    /// Tokenized rather than matched as a substring, because the distinction
    /// this predicate draws is between `-s`/`--sign` and everything else, and
    /// `--strict` contains the letters of neither flag but would defeat a naive
    /// `contains(" -s")` written one space short. The legitimate
    /// `codesign --verify --deep --strict` calls must stay outside this set.
    private static func isSigningInvocation(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.contains(where: { $0 == "codesign" || $0.hasSuffix("/codesign") }) else { return false }
        return tokens.contains { $0 == "-s" || $0 == "--sign" || $0.hasPrefix("--sign=") }
    }

    /// Everything the archive must sign *with*, asserted against the one step
    /// that signs.
    ///
    /// None of these four is verifiable from the outcome of the archive itself —
    /// `xcodebuild` succeeds either way. Each fails somewhere later and worse:
    ///
    ///  * a missing or wrong `CODE_SIGN_IDENTITY` produces a build the notary
    ///    service rejects after the full archive *and* the submission queue,
    ///    with a status that names no certificate;
    ///  * a missing `DEVELOPMENT_TEAM` leaves Xcode to pick among whatever
    ///    identities the run's keychain holds, which is a choice this workflow
    ///    must make rather than discover;
    ///  * `ENABLE_HARDENED_RUNTIME` is a notarization requirement and nothing
    ///    local objects to its absence — `codesign --verify` passes on a bundle
    ///    without it;
    ///  * `--timestamp` is likewise a notarization requirement, and relying on an
    ///    Xcode default for it moves its discovery to the same rejection.
    ///
    /// The ad-hoc `CODE_SIGN_IDENTITY=-` this replaces is asserted *absent*
    /// rather than deleted from the suite: it shipped in R-1 and reverting to it
    /// would leave every other assertion in this file green while publishing a
    /// build no download can open.
    func testTheArchiveIsSignedWithTheDeveloperIDIdentityAndTheHardenedRuntime() throws {
        let script = try stepScript(named: Self.archiveStepName, because: """
            It is the step that signs the app, and everything downstream re-signs *with the same \
            identity* rather than choosing its own — so a wrong choice here is the wrong choice \
            everywhere.
            """)

        XCTAssertTrue(script.contains { $0.contains(#"CODE_SIGN_IDENTITY="Developer ID Application""#) }, """
            release.yml's `\(Self.archiveStepName)` step must pass \
            `CODE_SIGN_IDENTITY="Developer ID Application"`. It is the only certificate type the \
            notary service accepts for software distributed outside the App Store; every other \
            identity signs the archive just as happily and is rejected twenty minutes later.
            """)
        XCTAssertTrue(script.contains { $0.contains("DEVELOPMENT_TEAM=\(Self.developerIDTeam)") }, """
            release.yml's `\(Self.archiveStepName)` step must pass \
            `DEVELOPMENT_TEAM=\(Self.developerIDTeam)`. Without it Xcode chooses among whatever \
            identities the run's keychain happens to hold — and the team is what notarization is \
            scoped to, so the choice belongs in this file rather than in Xcode's search order.
            """)
        XCTAssertTrue(script.contains { $0.contains("ENABLE_HARDENED_RUNTIME=YES") }, """
            release.yml's `\(Self.archiveStepName)` step must pass `ENABLE_HARDENED_RUNTIME=YES`. \
            The notary service refuses any build without it, and nothing local does: \
            `codesign --verify` passes on a bundle signed without the runtime flag.
            """)
        XCTAssertTrue(script.contains { $0.contains("OTHER_CODE_SIGN_FLAGS=--timestamp") }, """
            release.yml's `\(Self.archiveStepName)` step must pass \
            `OTHER_CODE_SIGN_FLAGS=--timestamp`. A secure timestamp is a notarization requirement; \
            leaving it to an Xcode default makes a missing one surface as a notary rejection after \
            the whole archive.
            """)

        // Signing has to be on at all — the committed project value is NO (see
        // `testTheCommittedProjectStaysSigningFree`), so these three overrides
        // are what make this one invocation sign.
        for override in ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES", "CODE_SIGN_STYLE=Manual"] {
            XCTAssertTrue(script.contains { $0.contains(override) }, """
                release.yml's `\(Self.archiveStepName)` step must pass `\(override)`. project.yml \
                commits `CODE_SIGNING_ALLOWED: NO` so ordinary builds need no certificate, which \
                means the release archive signs only because it overrides that here.
                """)
        }

        XCTAssertFalse(try activeText().contains("CODE_SIGN_IDENTITY=-"), """
            release.yml still ad-hoc signs somewhere (`CODE_SIGN_IDENTITY=-`). An ad-hoc signature \
            cannot be notarized, and a downloaded copy of an ad-hoc signed app is one macOS 15 \
            offers no way to open at all — the whole reason this release is signed with a \
            Developer ID certificate.
            """)
    }

    // MARK: - Sparkle's nested helpers

    /// Xcode's archive does not sign what is nested inside the framework it
    /// signs, so this workflow does.
    ///
    /// `Sparkle.framework` ships four helper bundles — two XPC services,
    /// `Autoupdate` and `Updater.app` — with upstream's ad-hoc signatures
    /// (`flags=0x10002(adhoc,runtime)`, no team identifier, no `Timestamp=`).
    /// Archiving re-signs the framework *bundle* around them and leaves them
    /// exactly as shipped, which is what the notary service rejected `v1.0` for,
    /// naming all four with the same two findings: not signed with a valid
    /// Developer ID certificate, and no secure timestamp.
    ///
    /// Every flag asserted here is one of those findings' cure, and none of them
    /// is visible from any local outcome: the helpers verify, the framework
    /// verifies, `--deep --strict` passes on the whole app, and the rejection
    /// arrives twenty minutes and a submission queue later. So each is pinned
    /// against the step that applies it.
    func testSparklesNestedHelpersAreReSignedWithTheReleaseIdentity() throws {
        let script = try stepScript(named: Self.reSignStepName, because: """
            Xcode re-signs the framework bundle and not the bundles nested inside it, so the four \
            helpers reach the notary service ad-hoc signed unless this step replaces their \
            signatures.
            """)

        // The identity is the archive's, named once and used six times. Pinned
        // to the literal so a re-sign under some *other* identity — an ad-hoc
        // `-`, or whatever `find-identity` returns first — cannot pass by
        // virtue of the variable merely existing.
        XCTAssertTrue(script.contains(#"IDENTITY="Developer ID Application""#), """
            release.yml's `\(Self.reSignStepName)` step must sign with the same \
            `Developer ID Application` identity the archive selects. Re-signing under any other \
            identity replaces four ad-hoc signatures the notary service refuses with four \
            signatures it refuses for a different reason.
            """)

        let signings = script.filter(Self.isSigningInvocation)
        XCTAssertEqual(signings.count, 6, """
            release.yml's `\(Self.reSignStepName)` step must carry exactly six `codesign` signing \
            invocations — the four nested helpers, the framework, then the app. It carries \
            \(signings.count): \(signings).
            """)

        for helper in Self.sparkleNestedHelpers {
            XCTAssertTrue(signings.contains { $0.hasSuffix(#""$FRAMEWORK/\#(helper)""#) }, """
                release.yml's `\(Self.reSignStepName)` step must re-sign \(helper). It is one of \
                the four binaries the notary service named when it rejected v1.0, and nothing else \
                in this workflow signs it. Got \(signings).
                """)
        }
        XCTAssertTrue(signings.contains { $0.hasSuffix(#""$FRAMEWORK""#) }, """
            The framework itself must be re-signed after its helpers — modifying nested code \
            invalidates the seal above it, so a framework signed before its helpers seals hashes \
            that no longer match. Got \(signings).
            """)
        XCTAssertTrue(signings.contains { $0.hasSuffix(#""$APP""#) }, """
            The app must be re-signed last, for the same reason: the archive's signature over it \
            seals a framework this step has just replaced. Got \(signings).
            """)

        // Every invocation, not merely one: a flag that reaches five of the six
        // leaves the sixth binary as the one the notary rejects, and the
        // rejection names it rather than the flag.
        for signing in signings {
            for flag in ["--force", #"--sign "$IDENTITY""#, "--options runtime", "--timestamp"] {
                XCTAssertTrue(signing.contains(flag), """
                    Every signing invocation in release.yml's `\(Self.reSignStepName)` step must \
                    pass `\(flag)`. Without `--force` codesign refuses to replace an existing \
                    signature; without the identity it signs ad-hoc; `--options runtime` and \
                    `--timestamp` are the two findings the notary service reported against these \
                    binaries by name. Got “\(signing)”.
                    """)
            }
        }
    }

    /// `Downloader.xpc` is the one helper whose entitlements must survive the
    /// re-sign, and Sparkle's own distribution documentation is where that comes
    /// from (it has said so since 2.6).
    ///
    /// The asymmetry is deliberate and worth stating, because "preserve them
    /// everywhere" reads like the safe default and is not: `Autoupdate` ships a
    /// `com.apple.application-identifier` belonging to Sparkle's own team, and
    /// carrying an App-Store-shaped identifier for a foreign team into a
    /// Developer ID signature is itself a notarization finding. So it is dropped,
    /// following upstream, and only `Downloader.xpc` keeps what it had.
    func testTheDownloaderXPCKeepsItsEntitlementsAcrossTheReSign() throws {
        let script = try stepScript(named: Self.reSignStepName, because: """
            It is the step whose flags decide what each helper's replacement signature carries.
            """)

        let downloader = try XCTUnwrap(script.first(where: {
            Self.isSigningInvocation($0) && $0.contains("Downloader.xpc")
        }), """
            release.yml's `\(Self.reSignStepName)` step no longer signs Downloader.xpc.
            """)
        XCTAssertTrue(downloader.contains("--preserve-metadata=entitlements"), """
            The `Downloader.xpc` re-sign must pass `--preserve-metadata=entitlements`, as Sparkle's \
            distribution documentation has required since 2.6. Got “\(downloader)”.
            """)

        // …and nothing else does. `Autoupdate` carrying its shipped
        // `com.apple.application-identifier` into this team's Developer ID
        // signature is a finding of its own.
        let preserving = script.filter { Self.isSigningInvocation($0) && $0.contains("--preserve-metadata") }
        XCTAssertEqual(preserving.count, 1, """
            Exactly one signing invocation in release.yml's `\(Self.reSignStepName)` step may \
            preserve metadata — `Downloader.xpc`'s. Autoupdate's shipped \
            com.apple.application-identifier belongs to Sparkle's team, and carrying it into this \
            team's Developer ID signature is a notarization finding rather than a courtesy. Got \
            \(preserving).
            """)
    }

    /// Inside-out, asserted by index rather than by presence.
    ///
    /// Code signing seals what is nested inside what is signed, so modifying a
    /// helper invalidates the framework's seal and modifying the framework
    /// invalidates the app's. Signing in any other order therefore produces a
    /// bundle whose outer signatures are stale — which `codesign --verify
    /// --deep --strict` *does* catch, but only after the whole re-sign has run,
    /// and the failure names a hash mismatch rather than an ordering mistake.
    /// All six invocations are present in every wrong order too, so presence
    /// proves nothing here.
    func testTheReSignPassRunsInsideOut() throws {
        let script = try stepScript(named: Self.reSignStepName, because: """
            It is the step whose ordering decides whether the signatures it applies are still valid \
            when it finishes.
            """)

        let framework = try XCTUnwrap(script.firstIndex(where: {
            Self.isSigningInvocation($0) && $0.hasSuffix(#""$FRAMEWORK""#)
        }), "release.yml's `\(Self.reSignStepName)` step no longer re-signs Sparkle.framework")
        let app = try XCTUnwrap(script.firstIndex(where: {
            Self.isSigningInvocation($0) && $0.hasSuffix(#""$APP""#)
        }), "release.yml's `\(Self.reSignStepName)` step no longer re-signs the app")

        for helper in Self.sparkleNestedHelpers {
            let index = try XCTUnwrap(script.firstIndex(where: {
                Self.isSigningInvocation($0) && $0.hasSuffix(#""$FRAMEWORK/\#(helper)""#)
            }), "release.yml's `\(Self.reSignStepName)` step no longer re-signs \(helper)")
            XCTAssertLessThan(index, framework, """
                \(helper) must be re-signed *before* Sparkle.framework. Signing a helper afterwards \
                leaves the framework sealing a code directory hash that no longer exists.
                """)
        }
        XCTAssertLessThan(framework, app, """
            Sparkle.framework must be re-signed before the app. The app's signature seals its \
            embedded frameworks, so re-signing the framework afterwards invalidates the outermost \
            signature — the one Gatekeeper and the notary service both read first.
            """)
    }

    /// `--deep` never signs anything in this workflow.
    ///
    /// Apple documents it as a debugging convenience, not a distribution tool:
    /// it applies one set of flags to everything it happens to find, so the
    /// entitlements `Downloader.xpc` must keep would be dropped, and a helper
    /// added by a future Sparkle would be signed silently instead of stopping
    /// the run at the existence guards. The explicit list is what the
    /// verification step and this suite can hold to account.
    ///
    /// The three `codesign --verify --deep --strict` calls are a different
    /// command entirely and must stay green, which is why this is asserted over
    /// tokenized signing invocations rather than as "the file contains --deep".
    func testNoSigningInvocationUsesDeep() throws {
        let lines = try activeLines()

        let signings = lines.filter(Self.isSigningInvocation)
        XCTAssertFalse(signings.isEmpty, """
            release.yml no longer signs anything with `codesign -s`/`--sign`, so this assertion \
            checks nothing. If the re-sign pass was removed, Sparkle's four nested helpers ship \
            ad-hoc signed and the notary service refuses them.
            """)

        let deep = signings.filter { $0.contains("--deep") }
        XCTAssertTrue(deep.isEmpty, """
            release.yml signs with `--deep`: \(deep). Apple documents `--deep` as unsuited to \
            distribution signing — it applies one set of flags to every nested item it discovers, \
            which drops Downloader.xpc's entitlements and quietly signs any helper a future Sparkle \
            adds instead of stopping at this workflow's existence guards. Sign the explicit list \
            instead. (`codesign --verify --deep --strict` is a different command and is fine.)
            """)

        XCTAssertTrue(lines.contains { $0.contains("codesign --verify --deep --strict") }, """
            release.yml must keep its `codesign --verify --deep --strict` calls. They answer a \
            question the per-binary checks do not — whether every nested item is *validly* signed \
            — and this assertion exists so the `--deep` refusal above cannot be satisfied by \
            deleting them.
            """)
    }

    /// A Sparkle layout change has to stop the run, not slip past it.
    ///
    /// The re-sign list is explicit, which means it is also *stale* the moment a
    /// Sparkle version moves, renames or drops one of these four. Without a
    /// guard that case signs three of four helpers, verifies whatever remains,
    /// and hands the notary service an ad-hoc signed binary — the exact `v1.0`
    /// failure, arriving again from the direction the explicit list was chosen
    /// over `--deep` to make visible.
    ///
    /// Asserted by mechanism, like every other refusal in this file: a
    /// `::warning::` that names the missing path and carries on is not a softer
    /// guard, it is no guard.
    func testAChangedSparkleLayoutStopsTheReSignPass() throws {
        let script = try stepScript(named: Self.reSignStepName, because: """
            It is the step whose explicit path list a Sparkle version bump invalidates.
            """)

        for helper in Self.sparkleNestedHelpers {
            assertGuardExits(#"test -e "$FRAMEWORK/\#(helper)""#,
                             in: script,
                             step: Self.reSignStepName,
                             because: """
                the re-sign list is explicit, so a Sparkle version that moved or renamed \(helper) \
                leaves it signed with upstream's ad-hoc signature and submits it — which is exactly \
                how v1.0 was rejected, and the guard is what notices instead of the notary service
                """)
        }
    }

    /// The archive's signature is *read back off the bundle*, on the app and on
    /// the embedded framework both — and off every Mach-O inside it.
    ///
    /// `codesign --verify --deep --strict` — which this step already ran before
    /// this ticket — answers "is this signature internally valid", and an ad-hoc
    /// signature, an Apple Development identity and a Developer ID one all pass
    /// it. The three facts notarization actually depends on are invisible to it,
    /// so each is matched on its own line of `codesign --display`: the authority,
    /// the team identifier, the hardened-runtime flag and the secure timestamp.
    ///
    /// The timestamp is the one of the four that is *misreported* rather than
    /// absent — `codesign` prints `Signed Time=` for a local timestamp and
    /// `Timestamp=` only for one countersigned by Apple's timestamp authority —
    /// which is why it is matched on the `Timestamp=` spelling anchored at the
    /// start of the line.
    ///
    /// The framework half is the claim "Xcode re-signs the embedded framework
    /// with the same identity", verified rather than believed. It is also the one
    /// piece of nested code whose signature Sparkle re-checks on the user's
    /// machine after an update is unpacked, so a framework signed differently
    /// from its host is a failure that happens after publication, on somebody
    /// else's computer.
    ///
    /// **The call-site count is two no longer, and the assertion was deliberately
    /// updated rather than deleted.** Both bundle checks passed on `v1.0`, and
    /// the notary service rejected it anyway, naming four Mach-Os nested inside
    /// the framework — a bundle-level read says nothing about the binaries below
    /// it. So the third call site is the enumeration loop
    /// (`testTheSignatureCheckRecursesToEveryNestedMachO`), and the count is
    /// pinned at three with each site named individually: a recursion that
    /// replaced the two bundle reads rather than joining them would drop the
    /// resource seal, which is sealed by a bundle's signature and by no Mach-O's.
    func testTheArchivedAppAndItsFrameworkAreCheckedForTheDeveloperIDSignature() throws {
        let script = try stepScript(named: Self.verifyStepName, because: """
            It is the last place the signature can be inspected before the app is notarized and \
            published.
            """)

        XCTAssertTrue(script.contains { $0.contains("codesign --display") }, """
            release.yml's `\(Self.verifyStepName)` step must read the signature back with \
            `codesign --display`. `--verify` alone cannot tell a Developer ID signature from an \
            ad-hoc one — both are valid signatures.
            """)

        // The dump is judged *and* printed, the way the spctl assessment is.
        //
        // The four refusals below each name one missing fact; only the dump says
        // what was there instead. It matters most on the path the `|| true` on
        // the capture exists for: when `codesign --display` itself fails, its
        // error text is what landed in the variable, and the first refusal would
        // otherwise replace it with "is not signed by a Developer ID Application
        // certificate" — a message that names the wrong cause. This step runs
        // after the archive, so there is no cheap second look.
        XCTAssertTrue(script.contains { $0.hasPrefix("printf") && $0.contains("$SIGNATURE") && !$0.contains("grep") }, """
            release.yml's `\(Self.verifyStepName)` step must print the captured `codesign \
            --display` output, not only grep it. Every refusal in this step names a single \
            missing fact; without the dump in the log, a release that fails 25 minutes in carries \
            no evidence of what codesign actually reported — and on the path where `codesign \
            --display` itself failed, the canned message names a cause that is not the real one.
            """)

        assertGuardExits("^Authority=Developer ID Application:", in: script, step: Self.verifyStepName, because: """
            an ad-hoc signature and an Apple Development identity both pass `codesign --verify`, \
            and the difference between them and a Developer ID certificate is the difference \
            between a release that can be notarized and one the notary service rejects after the \
            full archive
            """)
        assertGuardExits("^TeamIdentifier=\(Self.developerIDTeam)", in: script, step: Self.verifyStepName, because: """
            notarization is scoped to a team, so a build signed under another team is one this \
            team's App Store Connect key cannot submit at all
            """)
        assertGuardExits("flags=.*runtime", in: script, step: Self.verifyStepName, because: """
            the hardened runtime is a notarization requirement that nothing local objects to the \
            absence of — the bundle verifies, launches and behaves identically right up to the \
            submission
            """)
        assertGuardExits("^Timestamp=", in: script, step: Self.verifyStepName, because: """
            `OTHER_CODE_SIGN_FLAGS=--timestamp` is passed on the archive's command line precisely \
            so a missing secure timestamp does not first surface as a notary rejection twenty \
            minutes in, and that is only true if the flag having *reached the signature* is read \
            back. It is a single-valued build setting, so anything that displaces it — a \
            `settings.base` entry in project.yml, a different task re-signing the embedded \
            framework — drops the timestamp silently: `codesign --display` then prints \
            `Signed Time=` instead of `Timestamp=`, and the bundle passes `--verify --deep \
            --strict` and all three checks above
            """)

        // Three call sites, each named. Both bundles *and* the enumeration: the
        // two bundle reads carry the resource seal no Mach-O's signature does,
        // and the loop carries the nested binaries no bundle read reaches.
        let checks = script.filter { $0.hasPrefix("verify_developer_id_signature ") }
        XCTAssertEqual(checks.count, 3, """
            release.yml's `\(Self.verifyStepName)` step must apply its signature check at exactly \
            three sites — the app, the embedded Sparkle.framework, and the loop over every \
            enumerated Mach-O. It currently applies it at \(checks.count): \(checks).
            """)
        XCTAssertTrue(checks.contains { $0.hasSuffix(#""$APP""#) }, """
            The signature check must run against the archived app itself ("$APP"). Got \(checks).
            """)
        XCTAssertTrue(checks.contains { $0.contains("Sparkle.framework") }, """
            The signature check must also run against the embedded Sparkle.framework. Xcode signs \
            it as part of the archive with the same identity, which is a claim worth verifying \
            rather than believing — and it is the one nested bundle Sparkle itself re-checks on \
            the user's machine after unpacking an update. Got \(checks).
            """)
        XCTAssertTrue(checks.contains { $0.hasSuffix(#""$BINARY""#) }, """
            The signature check must also run against each enumerated Mach-O ("$BINARY"). The two \
            bundle reads above both passed on v1.0 and the notary service rejected it anyway, \
            naming four binaries nested inside the framework. Got \(checks).
            """)
    }

    /// The four facts are read back off **every Mach-O in the app**, discovered
    /// by enumeration rather than by a second hand-written list.
    ///
    /// A list would be the same mistake at one remove: the re-sign step's
    /// explicit list is deliberate — it is what a Sparkle layout change has to
    /// invalidate loudly — but a *verification* that only looks where the
    /// re-sign looked can never report a binary the re-sign forgot, which is the
    /// whole class of failure `v1.0` belongs to. So the verification enumerates,
    /// and the re-sign's list is checked against what the enumeration found
    /// (`testTheMachOEnumerationRefusesRatherThanCheckingNothing`).
    ///
    /// `-type f` is load-bearing rather than tidy: a framework is a tree of
    /// symlinks, and following them checks the same binary several times under
    /// several names while covering nothing extra.
    func testTheSignatureCheckRecursesToEveryNestedMachO() throws {
        let script = try stepScript(named: Self.verifyStepName, because: """
            It is the only step that can see the archived bundle's insides before the notary \
            service does.
            """)

        let enumeration = try XCTUnwrap(script.first(where: {
            $0.contains("find ") && $0.contains("\"$APP\"") && $0.contains("Mach-O")
        }), """
            release.yml's `\(Self.verifyStepName)` step must enumerate the app's Mach-O binaries \
            with a `find` over "$APP" filtered on `Mach-O`. Without the enumeration the step reads \
            two bundle signatures and nothing below them — exactly the coverage that let v1.0 reach \
            the notary service with four ad-hoc signed helpers inside Sparkle.framework.
            """)
        XCTAssertTrue(enumeration.contains("-type f"), """
            The Mach-O enumeration in release.yml's `\(Self.verifyStepName)` step must pass \
            `-type f`. A framework is a tree of symlinks (Versions/Current and the top-level \
            links), so without it the same binary is verified several times under several names. \
            Got “\(enumeration)”.
            """)
        XCTAssertTrue(enumeration.contains("file "), """
            The Mach-O enumeration must decide what is a Mach-O with `file`, not by path or \
            extension: the binaries that matter here (Autoupdate, the XPC services' executables) \
            have no extension at all. Got “\(enumeration)”.
            """)

        // The enumeration has to be *used*. A `find` whose output nothing reads
        // is a green step that verifies two bundles, which is the state this
        // whole recursion replaces.
        XCTAssertTrue(script.contains { $0.hasPrefix("verify_developer_id_signature ") && $0.contains("$BINARY") }, """
            release.yml's `\(Self.verifyStepName)` step must feed the enumerated Mach-Os to \
            `verify_developer_id_signature`. Enumerating them and not checking them is the same \
            coverage as not enumerating them.
            """)

        // Read in the current shell, not a pipeline subshell. `exit 1` inside
        // the function ends a subshell and nothing else, so a piped `while`
        // would log four refusals and notarize the build anyway.
        XCTAssertTrue(script.contains { $0.hasPrefix("done <<<") }, """
            release.yml's `\(Self.verifyStepName)` step must feed its verification loop from a \
            here-string (`done <<< "$MACH_OS"`). A `while` on the right of a pipe runs in a \
            subshell, where `verify_developer_id_signature`'s `exit 1` ends the subshell and lets \
            the step continue — a refusal that prints its ::error:: and then publishes anyway.
            """)
    }

    /// Two refusals guard the enumeration itself, because an enumeration that
    /// silently matches nothing is indistinguishable from one that passed.
    ///
    /// The first is the empty case: `find` and `file` are two tools whose output
    /// this step parses, and either could stop matching without failing. The loop
    /// then runs zero times and every assertion in this suite stays green while
    /// no binary is checked at all.
    ///
    /// The second is the floor under it — the four Mach-Os the notary service
    /// named when it rejected `v1.0` must be among what was found, by exact path.
    /// It is the counterpart to the re-sign step's explicit list: those two are
    /// the same fact written twice, and this is what refuses when a Sparkle
    /// version bump makes one of them stale. The paths are built from
    /// `sparkleNestedHelpers` here for that reason — the two halves cannot drift
    /// apart without failing this test.
    func testTheMachOEnumerationRefusesRatherThanCheckingNothing() throws {
        let script = try stepScript(named: Self.verifyStepName, because: """
            It is the step whose enumeration decides how much of the app is actually verified.
            """)

        assertGuardExits(#"-z "$MACH_OS""#, in: script, step: Self.verifyStepName, because: """
            an empty enumeration is not a pass: the per-binary loop below it would run zero times, \
            print nothing and leave the step green while checking no binary at all — which is the \
            very failure the recursion was added to catch, arriving through the recursion itself
            """)

        assertGuardExits(#"grep -qxF "$APP/$REQUIRED""#, in: script, step: Self.verifyStepName, because: """
            the four helper Mach-Os the notary service named when it rejected v1.0 must be among \
            what the enumeration found. They are the floor under it and the counterpart to the \
            re-sign step's explicit list: a Sparkle version that moved one of them leaves that list \
            stale, and this is what notices before the submission does
            """)

        // The required set is the re-sign step's list, one level in: the guards
        // there are on the four *bundles*, these are the Mach-Os inside them,
        // which is the level the notary service reports at.
        for helper in Self.sparkleNestedHelpers {
            let required = "Contents/Frameworks/Sparkle.framework/\(helper)"
            XCTAssertTrue(script.contains { $0.contains(required) }, """
                release.yml's `\(Self.verifyStepName)` step must require \(helper)'s Mach-O to be \
                among the binaries it enumerated. The re-sign step signs that bundle; if this step \
                does not insist on seeing it, a Sparkle layout change silently narrows both.
                """)
        }
    }

    /// `codesign --verify --deep --strict` stays, and is not what the recursion
    /// replaces.
    ///
    /// The two answer different questions and `v1.0` is the proof: `--deep
    /// --strict` passed on an app whose four nested helpers carried upstream's
    /// ad-hoc signatures, because an ad-hoc signature is a *valid* signature.
    /// Validity is not identity. Conversely the four facts are read per binary
    /// and say nothing about whether the seals nest correctly — a helper
    /// re-signed after its framework passes all four and fails `--deep --strict`.
    /// Deleting either one because "the other covers it" is the mistake this
    /// assertion exists to fail.
    func testNestedCodeValidityIsStillCheckedAlongsideTheRecursion() throws {
        let script = try stepScript(named: Self.verifyStepName, because: """
            It is the step that inspects the archived bundle before it is submitted.
            """)

        XCTAssertTrue(script.contains { $0.contains("codesign --verify --deep --strict") }, """
            release.yml's `\(Self.verifyStepName)` step must keep `codesign --verify --deep \
            --strict`. The per-binary Developer ID / team / runtime / timestamp checks say the \
            right certificate was used on each Mach-O; they say nothing about whether the \
            signatures nest — a helper re-signed after its framework passes all four and leaves the \
            framework sealing a hash that no longer exists.
            """)
    }

    /// The committed project stays signing-free — which is Decision 1 of this
    /// ticket, and the reason a fresh clone still builds.
    ///
    /// Every signing setting the release needs is passed on the `xcodebuild`
    /// command line, where it applies to that one invocation. Moving any of them
    /// into `project.yml` would look tidier and would break the thing this
    /// repository actually optimizes for: `xcodegen generate` followed by a build
    /// on a machine with no certificate, no team membership and no keychain
    /// entry. `CODE_SIGNING_ALLOWED: NO` is what makes that work, and a
    /// `DEVELOPMENT_TEAM` or `CODE_SIGN_IDENTITY` committed beside it fails
    /// exactly the contributors who cannot fix it.
    func testTheCommittedProjectStaysSigningFree() throws {
        let lines = activeYAMLLines(of: try text(atRepositoryPath: "project.yml"))

        XCTAssertTrue(lines.contains("CODE_SIGNING_ALLOWED: NO"), """
            project.yml must keep `CODE_SIGNING_ALLOWED: NO` in its base settings. The release \
            workflow overrides it (CODE_SIGNING_ALLOWED=YES) for the archive alone, so the \
            committed value is what a clone with no certificate builds under — dropping it makes \
            `xcodegen generate` + build demand a signing identity from everyone.
            """)

        // Matched on the setting *name*, not on a literal `NAME:` prefix. XcodeGen
        // passes build-setting keys through verbatim, so Xcode's conditional
        // spelling — `CODE_SIGN_IDENTITY[sdk=macosx*]: "Developer ID Application"` —
        // is valid YAML that commits the setting, and so is a quoted key. This
        // target is multiplatform (`supportedDestinations: [macOS, iOS]`), which
        // makes a per-SDK signing setting the *likeliest* form of the regression
        // this guard exists to catch: a prefix test would call it absent and land
        // green while every fresh clone started demanding a signing identity.
        for setting in ["DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER"] {
            let committed = lines.filter { line in
                let key = line.drop { $0 == "\"" || $0 == "'" }
                guard key.hasPrefix(setting) else { return false }
                // What may follow the name and still be an assignment of it:
                // `:` plain, `[` conditional, a closing quote, or space before `:`.
                return [":", "[", "\"", "'", " "].contains(String(key.dropFirst(setting.count).prefix(1)))
            }
            XCTAssertTrue(committed.isEmpty, """
                project.yml commits \(committed) — but \(setting) belongs on the release archive's \
                command line only. Committing it makes every local and CI build try to resolve a \
                signing identity that only the release runner has. See release.yml's archive step \
                and docs/RELEASING.md.
                """)
        }
    }

    // MARK: - Notarization and stapling

    /// The name of the step that submits the signed app to the notary service.
    private static let notarizeStepName = "Notarize the archived app"

    /// The name of the step that staples Apple's ticket into the bundle and
    /// asks Gatekeeper whether the result would run.
    private static let stapleStepName = "Staple the notarization ticket"

    /// The submission itself: it has to wait for a verdict, authenticate with
    /// the App Store Connect key trio, and be *read* rather than inferred from
    /// an exit code.
    ///
    /// Each half fails differently and none of them fails loudly:
    ///
    ///  * without `--wait`, `notarytool submit` returns as soon as the upload is
    ///    accepted — not the build. The step goes green in about a minute, the
    ///    staple that follows fails with no ticket to staple, and the *reason*
    ///    (whatever the service would have said minutes later) is never fetched;
    ///  * the key/key-id/issuer trio is the whole authentication, and a missing
    ///    one is an error from a service the run has already spent 20 minutes
    ///    getting to;
    ///  * trusting `$?` alone is the subtle one. The verdict is a JSON field. A
    ///    submission can end `Invalid` and a workflow reading only the exit code
    ///    can carry on to staple, publish, or — worse in the other direction —
    ///    report a network hiccup as a rejected build. So the status is compared
    ///    to `Accepted` explicitly, and anything else fetches the log before it
    ///    refuses: a rejection names the offending binary, and a rejection with
    ///    no log printed costs a whole release run to see.
    func testTheAppIsSubmittedForNotarizationAndTheVerdictIsReadNotInferred() throws {
        let script = try stepScript(named: Self.notarizeStepName, because: """
            A Developer ID signature alone is not enough for a downloaded copy to launch — the \
            notary service's verdict is the other half.
            """)

        // The whole line-continued invocation, so the flags are asserted against
        // the command that actually submits rather than anywhere in the step —
        // `notarytool log` below carries the same key trio.
        let start = try XCTUnwrap(script.firstIndex(where: { $0.contains("notarytool submit") }), """
            release.yml's `\(Self.notarizeStepName)` step must submit the app with \
            `xcrun notarytool submit`.
            """)
        var invocation = [script[start]]
        var index = start
        while script[index].hasSuffix("\\"), index + 1 < script.count {
            index += 1
            invocation.append(script[index])
        }

        XCTAssertTrue(invocation.contains { $0.contains("--wait") }, """
            `notarytool submit` must pass `--wait`. Without it the command returns once the upload \
            is accepted rather than once the *build* is, so this step goes green in a minute, the \
            staple that follows fails with no ticket to staple, and the verdict that explains why \
            is never fetched. Got \(invocation).
            """)
        for flag in [#"--key "$API_KEY""#,
                     #"--key-id "$APP_STORE_CONNECT_KEY_ID""#,
                     #"--issuer "$APP_STORE_CONNECT_ISSUER_ID""#] {
            XCTAssertTrue(invocation.contains { $0.contains(flag) }, """
                `notarytool submit` must pass `\(flag)`. The key, its id and the team's issuer id \
                are the whole authentication to the notary service, and a missing one is an error \
                from a service this run has already spent a 20-minute archive getting to. Got \
                \(invocation).
                """)
        }
        XCTAssertTrue(invocation.contains { $0.contains("--timeout") }, """
            `notarytool submit --wait` must carry a `--timeout`. Without one a stuck submission \
            waits until the job's own budget kills it, which reports as a cancelled release \
            rather than as a notarization that never came back.
            """)

        for secret in ["APP_STORE_CONNECT_API_KEY_P8",
                       "APP_STORE_CONNECT_KEY_ID",
                       "APP_STORE_CONNECT_ISSUER_ID"] {
            XCTAssertTrue(script.contains { $0 == "\(secret): ${{ secrets.\(secret) }}" }, """
                release.yml's `\(Self.notarizeStepName)` step must receive \(secret) through its \
                `env:` block. The preflight refuses a run without it, so a missing mapping *here* \
                is the case where every guard passed and the submission still cannot authenticate.
                """)
        }

        // `set -e` would end the step on a rejected submission *before* the
        // verdict is read, which turns everything below into dead code on
        // exactly the run it exists for. The `|| SUBMIT_EXIT=$?` is what keeps
        // the step alive long enough to explain itself.
        XCTAssertTrue(script.contains { $0.contains("|| SUBMIT_EXIT=$?") }, """
            release.yml's `\(Self.notarizeStepName)` step must capture notarytool's exit code with \
            `|| SUBMIT_EXIT=$?` rather than letting `set -e` fire. Without it a rejected \
            submission ends the step immediately and the status check, the log fetch and the \
            actionable message below are never reached — the run fails with notarytool's own \
            output and nothing else.
            """)

        // Both JSON reads are guarded, for the same reason: `jq` exits non-zero
        // on input that is not valid JSON, and a failing command substitution
        // in an assignment is a `set -e` exit — again before the message.
        for read in ["STATUS=", "SUBMISSION_ID="] {
            let line = try XCTUnwrap(script.first(where: { $0.hasPrefix(read) }), """
                release.yml's `\(Self.notarizeStepName)` step no longer assigns \(read) from \
                notarytool's JSON.
                """)
            XCTAssertTrue(line.contains("||"), """
                `\(read)` must tolerate output that is not valid JSON (a submission killed \
                mid-write, a notarytool that emitted a plain-text error). `jq` exits non-zero on \
                it, and under `set -e` this assignment then ends the step before the ::error:: \
                message and the log fetch — the malformed-output case reports as a bare jq parse \
                error. Got “\(line)”.
                """)
        }

        // The verdict, read explicitly and refused by mechanism.
        assertGuardExits(#""$STATUS" != "Accepted""#, in: script, step: Self.notarizeStepName, because: """
            the notary service's verdict is a field in its JSON, not an exit code — a workflow that \
            reads only `$?` can staple and publish a submission that came back `Invalid`, and can \
            equally report a transport failure as a rejected build
            """)
        XCTAssertTrue(script.contains { $0.contains("notarytool log") }, """
            release.yml's `\(Self.notarizeStepName)` step must fetch `xcrun notarytool log` for the \
            submission when the status is not `Accepted`. The status alone says "Invalid" and \
            nothing else; the log is what names the binary and the reason. A rejection with no log \
            printed costs another full release run just to find out what was wrong.
            """)

        // The log has to be fetched for *this* submission, which means the id
        // has to be read off the JSON rather than hoped for.
        XCTAssertTrue(script.contains { $0.contains("SUBMISSION_ID=") }, """
            release.yml's `\(Self.notarizeStepName)` step must read the submission id out of \
            notarytool's JSON. `notarytool log` takes an id, and without one there is nothing to \
            fetch the failure explanation with.
            """)
    }

    /// The App Store Connect private key is written to disk — `notarytool` takes
    /// a path, not a value — and must not outlive the step that writes it.
    ///
    /// The removal has to be a `trap`, not a line at the end of the script. Every
    /// path out of this step that matters is an *early* one: `set -e` firing on
    /// the `ditto`, the status guard refusing, the submission failing to
    /// authenticate. A trailing `rm` runs on exactly the path where nothing went
    /// wrong, which is the path where it matters least.
    func testTheNotarizationKeyIsRemovedByTheStepThatWritesIt() throws {
        let script = try stepScript(named: Self.notarizeStepName, because: """
            It is the step that writes the App Store Connect private key to the runner's disk.
            """)

        XCTAssertTrue(script.contains { $0.contains(#"API_KEY="${RUNNER_TEMP}/"#) }, """
            The notarization key must be written under $RUNNER_TEMP, like the signing keychain — \
            not into the checkout, where a later step could archive or upload it.
            """)

        let trap = try XCTUnwrap(script.firstIndex(where: {
            $0.hasPrefix("trap ") && $0.contains("rm -f") && $0.contains("API_KEY")
        }), """
            release.yml's `\(Self.notarizeStepName)` step must remove the .p8 with a `trap … EXIT`. \
            A plain `rm` at the end of the script runs only when nothing failed — and every \
            interesting exit from this step is an early one: `set -e` on the ditto, an \
            authentication failure, or the non-Accepted refusal.
            """)
        let write = try XCTUnwrap(script.firstIndex(where: { $0.contains(#"> "$API_KEY""#) }), """
            release.yml's `\(Self.notarizeStepName)` step no longer writes the API key to a file. \
            notarytool takes a path rather than a value, so it has to be written somewhere.
            """)
        XCTAssertLessThan(trap, write, """
            The `trap` must be installed *before* the key is written. Installed afterwards it \
            covers everything except the window in which the key exists and the step has not yet \
            reached the trap — which includes the write itself failing part-way.
            """)
        XCTAssertTrue(script.contains { $0.hasPrefix("(umask 077;") && $0.contains(#"> "$API_KEY""#) }, """
            The .p8 must be written inside a `(umask 077; …)` subshell. It lands under the \
            runner's default umask otherwise — a private key readable by every process on the \
            machine for as long as the notarization takes — and a `chmod` on the following line is \
            not the same fix: the redirect is what creates the file, so narrowing it afterwards \
            leaves a window rather than closing one. Got \(script.filter { $0.contains(#"$API_KEY""#) }).
            """)

        // The trap's signal is asserted, not just its existence: `trap … ERR`
        // reads almost identically and fires on none of the paths that matter
        // here — including the successful one, on which the key would then
        // survive the whole rest of the job.
        XCTAssertTrue(script[trap].hasSuffix(" EXIT"), """
            The .p8's `trap` must be installed on `EXIT`. Any other signal set — `ERR` in \
            particular — leaves the key on disk on the path where the step succeeds, which is \
            every published release. Got “\(script[trap])”.
            """)
    }

    /// The ticket is stapled into the bundle, validated, and the result is put to
    /// Gatekeeper.
    ///
    /// An accepted-but-unstapled app is the failure worth naming: it launches
    /// fine on the runner, passes every `codesign` check, and needs Apple's
    /// service reachable on the *user's* first launch — so it fails offline, on
    /// a captive network, or during a notary outage, and nowhere else.
    /// `stapler validate` is a different statement from `stapler staple`
    /// succeeding: it reads the ticket back out and checks it against the
    /// bundle's own hash. And `spctl --assess` is the only check in this whole
    /// workflow that asks the system policy the actual question — would this run
    /// — rather than asking `codesign` a question that a correctly signed,
    /// un-notarized app also passes.
    func testTheNotarizationTicketIsStapledAndTheResultIsAssessed() throws {
        let script = try stepScript(named: Self.stapleStepName, because: """
            An accepted submission whose ticket is not stapled ships an app whose first launch \
            depends on Apple's service being reachable from the user's machine.
            """)

        XCTAssertTrue(script.contains { $0.contains("stapler staple") }, """
            release.yml's `\(Self.stapleStepName)` step must run `xcrun stapler staple` on the \
            .app. Notarization without stapling is an acceptance that lives only on Apple's \
            servers.
            """)
        // …and explains itself when it fails, like every other refusal here.
        // Bare, `set -e` ends the job on stapler's own output, which for the
        // common case is "The staple and validate action failed! Error 65" and
        // names neither cause nor remedy — in the step reached only after the
        // archive *and* an accepted submission.
        assertGuardExits("xcrun stapler staple", in: script, step: Self.stapleStepName, because: """
            a bare invocation under `set -e` ends the most expensive step in the run with Error 65 \
            and nothing else, while the two realistic causes — a ticket Apple has not finished \
            publishing (wait and re-push the tag) and a bundle that changed after submission (a \
            bug in this workflow) — need opposite responses
            """)
        assertGuardExits("xcrun stapler validate", in: script, step: Self.stapleStepName, because: """
            `stapler staple` succeeding says a ticket was written; `stapler validate` says the \
            ticket in the bundle is the one issued for *this* bundle, which is what catches a \
            staple onto something other than what was submitted
            """)
        XCTAssertTrue(script.contains { $0.contains("codesign --verify --deep --strict") }, """
            release.yml's `\(Self.stapleStepName)` step must re-verify the signature after \
            stapling. Stapling modifies the bundle and is supposed to be signature-neutral; if it \
            ever were not, the failure would surface as a rejected *update* on the user's machine, \
            because Sparkle re-checks the signature of what it unpacks.
            """)
        assertGuardExits("spctl --assess", in: script, step: Self.stapleStepName, because: """
            it is the only check in this workflow that asks the system policy whether a downloaded \
            copy would actually run — the combination of Developer ID signature, hardened runtime \
            and stapled ticket that no individual codesign check can see — and it is the literal \
            goal of signing and notarizing at all
            """)
        // The verdict, not the exit status — the same distinction the notary
        // status is parsed for. `spctl` exits 0 for *any* accepting rule, so the
        // guard above alone is satisfied by `source=Mac App Store`, by
        // `source=Developer ID` (what an accepted but *unstapled* Developer ID
        // app reports), and — the one that matters, because it is a property of
        // the runner rather than of the build — by `source=no usable signature`
        // on a machine whose assessments are disabled, where every path on disk
        // is "accepted" and this gate asserts nothing at all.
        //
        // Asserted through `assertGuardExits` and not as a `contains`: this
        // string appears twice in the step — in the `grep -q` and in the
        // `::error::` text that quotes it — so a `contains` stays green for the
        // one mutation that matters, a refusal downgraded to a `::warning::` or
        // a `grep -q` that no longer reaches `exit 1`. That is the mutation this
        // whole suite exists to catch, and this is the gate it would leave
        // toothless.
        assertGuardExits("source=Notarized Developer ID", in: script, step: Self.stapleStepName, because: """
            release.yml must read the accepting *rule* out of the spctl assessment and refuse \
            anything but `source=Notarized Developer ID`. Exit status alone does not distinguish a \
            stapled Developer ID ticket from an acceptance under some other rule, or from a runner \
            with assessments turned off — on which spctl accepts everything and this workflow's \
            one authoritative gate silently stops being a check
            """)
        XCTAssertTrue(script.contains { $0.contains("spctl --assess") && $0.contains("2>&1") }, """
            The spctl assessment must be captured with `2>&1`. spctl writes it to stderr, so \
            without the redirect the captured output is empty — and the assertion above, which \
            greps that output for the accepting rule, would refuse every release for a reason \
            that has nothing to do with the app.
            """)
    }

    /// The order the release is assembled in, pinned end to end.
    ///
    /// Every neighbouring pair here is a way to publish something broken with
    /// every other assertion in this file green:
    ///
    ///  * notarizing before the archive finishes has nothing to submit;
    ///  * **re-signing after the verification** verifies four signatures that
    ///    are about to be replaced — every fact it read back belongs to a
    ///    signature the run then throws away, so the step reports on a bundle
    ///    that no longer exists by the time it is submitted;
    ///  * **re-signing after the notary submission** is worse than useless: the
    ///    ticket Apple issued is bound to the code directory hash it was given,
    ///    so replacing any signature afterwards invalidates it and the staple
    ///    fails — or, if the staple somehow ran first, ships a bundle whose
    ///    ticket does not describe it;
    ///  * stapling before the verdict staples a ticket that does not exist;
    ///  * **zipping before the staple** is the quiet one — the shipped zip then
    ///    carries an accepted-but-unstapled app, which passes `spctl` on the
    ///    runner (the ticket is fetched online) and needs Apple reachable on
    ///    every user's first launch;
    ///  * generating the appcast before the zip signs an enclosure that is not
    ///    there, and publishing before the appcast attaches a feed that was
    ///    never signed.
    func testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp() throws {
        let lines = try activeLines()

        let sequence = [
            Self.archiveStepName,
            Self.reSignStepName,
            Self.verifyStepName,
            Self.notarizeStepName,
            Self.stapleStepName,
            "Stage the update archive",
            "Generate and sign the appcast",
            "Publish the GitHub Release",
        ]

        var positions: [(String, Int)] = []
        for step in sequence {
            let index = try XCTUnwrap(lines.firstIndex(of: "- name: \(step)"), """
                release.yml has no step named `\(step)`. The release is assembled by these steps in \
                this order: \(sequence).
                """)
            positions.append((step, index))
        }

        for (earlier, later) in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(earlier.1, later.1, """
                release.yml runs `\(later.0)` before `\(earlier.0)`. The release must be assembled \
                in this order: \(sequence.joined(separator: " → ")). See this test's doc comment \
                for what each inversion ships.
                """)
        }
    }

    /// The zip submitted to the notary service and the zip that ships are two
    /// different artefacts, and the shipped one is made from the stapled bundle.
    ///
    /// They look interchangeable and are not. The submitted zip is a snapshot of
    /// the app *before* the ticket exists; reusing it as the release asset would
    /// publish an unstapled app — the exact failure
    /// `testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp` pins the
    /// ordering against, arriving instead by way of a shortcut that saves one
    /// `ditto`.
    func testTheSubmittedZipIsNotTheShippedZip() throws {
        let notarize = try stepScript(named: Self.notarizeStepName, because: """
            It is the step that packs the app for submission.
            """)
        let stage = try stepScript(named: "Stage the update archive", because: """
            It is the step that packs the app for the release.
            """)

        // Both use ditto for the same symlink reason — the notary service
        // unpacks what it is given, and a flattened Sparkle.framework fails
        // there too.
        XCTAssertTrue(notarize.contains { $0.contains("ditto -c -k") }, """
            The zip submitted for notarization must be produced with `ditto -c -k`, like the \
            shipped one: a plain `zip` flattens the embedded Sparkle.framework's symlinks, and the \
            notary service inspects the framework it unpacks.
            """)

        let submitted = notarize.filter { $0.contains("ditto -c -k") }
        XCTAssertFalse(submitted.contains { $0.contains("build/release-assets") }, """
            The notarization step must pack the app into a scratch directory of its own, not into \
            build/release-assets. That directory is what generate_appcast is pointed at — it reads \
            *every* update it finds there — and its contents are what the release attaches, so a \
            pre-staple zip landing in it ships an app whose first launch needs Apple's service \
            reachable. Got \(submitted).
            """)
        XCTAssertTrue(stage.contains { $0.contains("build/release-assets") }, """
            The shipped zip must still be staged in build/release-assets, the directory \
            generate_appcast reads and the release attaches from.
            """)
    }

    /// The signature check `generate_appcast` does not make for us.
    ///
    /// This is the one way a fully green run can still publish a release that
    /// every installed copy rejects, and it is invisible from the exit code.
    /// Sparkle 2.9.5's `generate_appcast/Appcast.swift` compares the app's
    /// `SUPublicEDKey` against the public half of the private key it was given;
    /// on a mismatch it prints a *warning*, leaves `edSignature` nil and — unlike
    /// the neighbouring "no private key" branch — deliberately does not set
    /// `signingError`, which is the only thing the tool rethrows. `FeedXML.swift`
    /// then just omits the `sparkle:edSignature` attribute, and the process exits
    /// 0. The feed is well-formed, advertises a real enclosure, and carries
    /// nothing to verify it against.
    ///
    /// The preflight cannot cover this: it can see that the committed key is no
    /// longer the placeholder, but not that it pairs with a secret it must never
    /// read. So the guard is on the artefact, and the consequence of losing it is
    /// the same one the placeholder refusal exists to prevent — an installed base
    /// that rejects every future update, recoverable only by a manual
    /// re-download by every user.
    func testTheAppcastIsRefusedWhenItCarriesNoEdDSASignature() throws {
        let script = try stepScript(named: "Generate and sign the appcast", because: """
            It is the step that signs the feed, and the only place the missing signature is \
            observable before publication.
            """)

        assertGuardExits("sparkle:edSignature", in: script, step: "Generate and sign the appcast", because: """
            generate_appcast exits 0 when the app's SUPublicEDKey does not match the private key \
            it was handed — it warns, omits the signature and writes the feed anyway. Publishing \
            that feed offers every installed copy an update it must reject, permanently
            """)

        // The guard has to run before the release exists, not after.
        let steps = try activeLines()
        let guardIndex = try XCTUnwrap(steps.firstIndex(where: { $0.contains("sparkle:edSignature") }), """
            release.yml no longer checks the generated appcast for a sparkle:edSignature.
            """)
        let publishIndex = try XCTUnwrap(steps.firstIndex(where: { $0.contains("gh release create") }), """
            release.yml no longer creates the release with `gh release create`.
            """)
        XCTAssertLessThan(guardIndex, publishIndex, """
            The unsigned-appcast guard must run before `gh release create`. Once the release is \
            published, `releases/latest` already points at the broken feed.
            """)
    }

    /// Publication has to be atomic from an installed copy's point of view, and
    /// `gh release create` is not.
    ///
    /// It creates the release first and uploads each asset afterwards, so a
    /// failure on the second upload — a 5xx, a network blip, a cancelled job —
    /// leaves a *published* release carrying the zip and no `appcast.xml`.
    /// `SUFeedURL` resolves through `releases/latest/download/appcast.xml`, which
    /// picks whichever release was published last and resolves the asset by name,
    /// so that state 404s the feed for every installed copy — silently, with the
    /// run already red and nobody's app saying anything. A draft is excluded from
    /// `releases/latest` entirely, so nothing is visible until both assets are
    /// confirmed on it; the promotion is then the one irreversible line.
    func testTheReleaseIsPublishedOnlyOnceBothAssetsAreOnIt() throws {
        let script = try stepScript(named: "Publish the GitHub Release", because: """
            It is the step that makes the release visible to every installed copy.
            """)

        let create = try XCTUnwrap(script.firstIndex(where: { $0.contains("gh release create") }), """
            release.yml no longer creates the release with `gh release create`.
            """)

        // The whole line-continued invocation, so `--draft` is looked for on the
        // command that actually creates the release rather than anywhere in the
        // step.
        var invocation = [script[create]]
        var index = create
        while script[index].hasSuffix("\\"), index + 1 < script.count {
            index += 1
            invocation.append(script[index])
        }
        XCTAssertTrue(invocation.contains { $0.contains("--draft") && !$0.contains("--draft=false") }, """
            `gh release create` must pass `--draft`. It uploads assets *after* creating the \
            release, so without it a failed second upload leaves a published release carrying the \
            zip and no appcast.xml — and releases/latest/download/appcast.xml, which is SUFeedURL, \
            then 404s for every installed copy until someone notices.
            """)

        assertGuardExits(#""$NAMES" != "$EXPECTED""#, in: script, step: "Publish the GitHub Release", because: """
            the draft must be checked for exactly the two assets the feed contract describes before \
            it is promoted — a missing appcast.xml 404s SUFeedURL for every installed copy and a \
            missing zip advertises an enclosure with nothing behind it
            """)

        let guardIndex = try XCTUnwrap(script.firstIndex(where: { $0.contains(#""$NAMES" != "$EXPECTED""#) }), """
            release.yml no longer compares the draft release's asset names against the expected pair.
            """)
        let promote = try XCTUnwrap(script.firstIndex(where: { $0.contains("--draft=false") }), """
            release.yml creates a draft release and never promotes it — the release would never \
            become visible, and `releases/latest` would keep pointing at the previous one.
            """)
        XCTAssertLessThan(guardIndex, promote, """
            The asset-set check must run *before* `gh release edit --draft=false`. Promoting first \
            and checking afterwards is the same non-atomic publication `--draft` exists to avoid: \
            releases/latest already points at the incomplete release by the time the check fails.
            """)
        XCTAssertEqual(promote, script.count - 1, """
            The promotion must be the last thing this step does. Anything after it runs against an \
            already-visible release, so a failure there leaves exactly the half-published state the \
            draft was for.
            """)
    }

    /// The keys Sparkle reads come from the *partial* `Resources/Info.plist`,
    /// merged into Xcode's generated one — a merge that can stop happening
    /// without failing a build. Verifying them one at a time is the point: a
    /// single `grep -E 'CFBundleVersion|…|SUFeedURL'` over the whole dump
    /// succeeds when *any* alternative matches, and `CFBundleVersion` is always
    /// generated, so the Sparkle keys could vanish with the step still green.
    ///
    /// The key set is read out of the `for KEY in …` list itself and compared by
    /// equality, not searched for anywhere in the file. Two of these four keys
    /// are also named in the loop's own `::error::` text — which is an `echo`,
    /// not a comment, so this suite's comment-stripping does not remove it — and
    /// a whole-file `contains(key)` is therefore satisfied by the refusal message
    /// of a loop that no longer checks them. Dropping `SUFeedURL` and
    /// `SUPublicEDKey` from the list left this suite green before the set
    /// comparison replaced it, which is exactly the "a literal mention stands in
    /// for the live setting" failure the type doc says every assertion here must
    /// be immune to. Equality rather than containment additionally catches a key
    /// added to the loop that nothing in this suite knows about.
    func testArchivedAppIsVerifiedForEachRequiredInfoPlistKeySeparately() throws {
        let script = try stepScript(named: Self.verifyStepName, because: """
            It is the step that reads the merged Info.plist back out of the archived bundle.
            """)

        XCTAssertTrue(script.contains { $0.contains("plutil -extract") }, """
            release.yml's `\(Self.verifyStepName)` step must check the archived app's Info.plist \
            key by key with `plutil -extract`, which exits non-zero on an absent key. A `grep -E` \
            alternation cannot fail for an individual key — see this test's doc comment.
            """)

        let loop = try XCTUnwrap(script.first { $0.hasPrefix("for KEY in ") }, """
            release.yml's `\(Self.verifyStepName)` step no longer iterates the required Info.plist \
            keys with a `for KEY in …` list. This suite reads the checked keys out of that list; \
            without it, nothing can tell a key that is verified from a key that is merely \
            mentioned in the step's refusal message.
            """)
        let checked = Set(loop
            .dropFirst("for KEY in ".count)
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ";")) }
            .filter { !$0.isEmpty && $0 != "do" })

        XCTAssertEqual(checked, ["CFBundleVersion", "CFBundleShortVersionString", "SUFeedURL", "SUPublicEDKey"], """
            release.yml must verify exactly these Info.plist keys on the archived app, and this \
            suite must know about every key it verifies. The two Sparkle keys come from the \
            partial Resources/Info.plist that Xcode merges in — without SUFeedURL or SUPublicEDKey \
            the shipped app can never find or verify an update, and nothing else in the build \
            fails. Found: \(checked.sorted()).
            """)

        XCTAssertFalse(script.contains { $0.contains("plutil -p") }, """
            release.yml still dumps the plist with `plutil -p` and greps it. That check passes as \
            long as *one* of the keys it names is present; use per-key `plutil -extract`.
            """)
    }

    /// Presence is not enough for this one key. Every other key in that loop is
    /// verified by existing at all; `CFBundleVersion` is always generated, so it
    /// exists no matter what — what matters is that it holds *this run's* number
    /// rather than the `CURRENT_PROJECT_VERSION: 1` `project.yml` commits. The
    /// override reaching the merged plist is the single assumption the whole
    /// update channel rests on, and it is the kind that breaks silently: a
    /// hardcoded value, an `INFOPLIST_KEY_CFBundleVersion`, or an `.xcconfig`
    /// that wins over the command line would all publish build 1 with every
    /// other check in this file green, and a build numbered 1 published after 12
    /// is one Sparkle never offers to anybody.
    func testArchivedAppsBuildNumberIsCheckedAgainstTheRunNumber() throws {
        let script = try stepScript(named: "Verify the archived app", because: """
            The archived bundle is the last place the build number can be read before it is \
            zipped, signed and published.
            """)

        assertGuardExits("${{ github.run_number }}", in: script, step: "Verify the archived app", because: """
            CFBundleVersion is what Sparkle compares to decide one build is newer than another. \
            Shipping the committed placeholder build number instead of this run's is invisible \
            everywhere else — the key is present, non-empty and structurally fine — and strands \
            every installed copy on a higher build permanently
            """)
    }

    /// The second value-carrying key in that loop, and the one the whole "tag and
    /// version agree" invariant is actually about.
    ///
    /// The preflight already compares the tag against `MARKETING_VERSION`, but it
    /// does so by `sed`-parsing `project.yml` and taking the first match — which
    /// is a *textual* read, not the effective build setting. A per-configuration
    /// or per-destination override under `configs:`/`settings:`, or simply a
    /// second occurrence sorting first, makes the preflight compare the tag
    /// against a value the archive never uses: it passes, and the release ships an
    /// appcast advertising a `sparkle:shortVersionString` the app does not report,
    /// under a zip filename that matches neither. Comparing the *archived* value
    /// against the tag makes the artefact the authority, which is the same
    /// argument the `CFBundleVersion` check above already makes.
    func testArchivedAppsMarketingVersionIsCheckedAgainstTheTag() throws {
        let script = try stepScript(named: "Verify the archived app", because: """
            The archived bundle is the last place the version the app will report can be read \
            before it is zipped, named, advertised and published.
            """)

        assertGuardExits(#""$KEY" = CFBundleShortVersionString"#, in: script, step: "Verify the archived app", because: """
            CFBundleShortVersionString is what the appcast advertises and what the release's zip is \
            named after. The preflight's project.yml parse is textual and can disagree with the \
            effective build setting, and when it does every other check in this workflow stays \
            green while the published feed names a version the app does not have
            """)

        // The comparison has to be against the tag, not against some other
        // string that happens to be in scope: `VERSION` is `${GITHUB_REF_NAME#v}`
        // and is what the zip name and the download prefix are built from too.
        XCTAssertTrue(script.contains { $0.contains(#"VERSION="${GITHUB_REF_NAME#v}""#) }, """
            release.yml's `Verify the archived app` step must derive VERSION from GITHUB_REF_NAME, \
            so the value it compares CFBundleShortVersionString against is the tag itself rather \
            than anything re-read from project.yml — which is the source the check exists to stop \
            trusting.
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

    /// CI's macOS job builds the *shipping* configuration, and that is the only
    /// thing that compiles the updater before a tag exists.
    ///
    /// This is the counterpart to `testArchiveIsPinnedToTheReleaseConfiguration`
    /// and it guards a claim four files now make about themselves (`ci.yml`'s own
    /// comment, `CLAUDE.md`, `README.md`, `docs/RELEASING.md`): the whole Sparkle
    /// surface is behind `#if !DEBUG`, so a Debug-only gate never compiles
    /// `import Sparkle`, `SPUStandardUpdaterController` or the `canCheckForUpdates`
    /// republish at all. Drop the flag — a revert, or a "why is CI slow?" cleanup
    /// aimed at the timeout this raised from 30 to 45 minutes — and `swift test`
    /// stays entirely green while the shipping path goes uncompiled until the
    /// release workflow's archive step, i.e. after the tag is already pushed.
    ///
    /// Scoped to the step, for the reason `stepScript(named:in:because:)` states:
    /// the release workflow *does* pass `-configuration Release`, so a file-wide
    /// or repository-wide `contains` would be satisfied by the wrong workflow
    /// entirely.
    func testCIBuildsTheConfigurationThatShips() throws {
        let script = try stepScript(named: Self.ciMacBuildStepName, in: "ci.yml", because: """
            It is the only place the `#if !DEBUG` updater is compiled before a release tag exists.
            """)
        XCTAssertTrue(script.contains { $0.contains("-configuration Release") }, """
            ci.yml's `\(Self.ciMacBuildStepName)` step must pass `-configuration Release`. See this \
            test's doc comment: Debug compiles none of the Sparkle surface, so dropping the flag \
            moves the first build of the shipping path into the release archive, after the tag is \
            pushed — the exact failure the switch to Release was made to prevent.
            """)
    }

    /// The name of CI's macOS build step. A constant for the same reason
    /// `archiveStepName` is one: a renamed step must fail loudly rather than
    /// silently check nothing.
    private static let ciMacBuildStepName = "Build (macOS, Release — the configuration that ships)"

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

    // MARK: - The documentation the signature replaced

    /// The files that used to carry the Gatekeeper workaround, and must not
    /// carry it again.
    private static let filesThatDocumentedTheWorkaround = [
        ".github/workflows/release.yml",
        "README.md",
        "docs/FEATURES.md",
        "docs/RELEASING.md",
    ]

    /// The literal instructions an ad-hoc-signed download needed. Matched as
    /// strings because that is what a user copies out of a document.
    private static let gatekeeperWorkarounds = [
        "xattr -dr com.apple.quarantine",
        "Open Anyway",
    ]

    /// The acceptance criterion of the signing work, pinned so a revert cannot
    /// quietly restore it.
    ///
    /// A notarized, stapled app opens from a fresh download through the ordinary
    /// "downloaded from the Internet" confirmation — quarantine still applies and
    /// macOS still asks once, but the dialog is confirmable rather than a refusal.
    /// So every instruction that told users to strip the quarantine flag or to
    /// approve the app in System Settings is now wrong — and wrong in a
    /// particularly bad direction. `xattr -dr com.apple.quarantine` is a command
    /// that disables a security check; a project that keeps telling people to run
    /// it teaches the habit for every *other* download too, and the app no longer
    /// has even the excuse of needing it.
    ///
    /// Documentation rots silently: nothing fails when a stale paragraph
    /// survives a rewrite, and a release-notes template is copied into every
    /// future release. So the four files that carried the instruction are
    /// asserted not to carry it any more.
    ///
    /// **This is the one assertion in this suite that reads raw text rather than
    /// `activeText()`**, and deliberately so. Everywhere else, comment-stripping
    /// is what makes an assertion mean "the workflow *does* this" instead of
    /// "some comment mentions it". Here the claim is about prose, and a comment
    /// explaining how to clear quarantine is exactly as much a live instruction
    /// as a `--notes` string is — arguably more so, since the next person editing
    /// the file reads it as current.
    func testTheGatekeeperWorkaroundIsGoneFromEveryDocumentThatCarriedIt() throws {
        for path in Self.filesThatDocumentedTheWorkaround {
            let raw = try text(atRepositoryPath: path)
            for workaround in Self.gatekeeperWorkarounds {
                XCTAssertFalse(raw.contains(workaround), """
                    \(path) still contains “\(workaround)”. Releases are Developer ID signed, \
                    notarized and stapled, so a downloaded copy opens from the ordinary \
                    "downloaded from the Internet" confirmation and this \
                    instruction is both unnecessary and actively harmful — it teaches users to \
                    disable a security check for a problem this app no longer has. Remove it (and \
                    if signing was genuinely reverted, that revert is the bug this test is \
                    reporting). See docs/RELEASING.md.
                    """)
            }
        }
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
