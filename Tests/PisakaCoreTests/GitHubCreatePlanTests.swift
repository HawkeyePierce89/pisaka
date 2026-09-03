import XCTest
@testable import PisakaCore

/// The create sheet's pure half: when Create may run, why it may not, and every
/// sentence the sheet shows above it.
///
/// Three properties carry the suite:
///
/// - **The refusals are `PushUnavailableReason`'s own, verbatim.** Asserted
///   against `PushUnavailableReason.detachedHEAD.message` / `.noRemote.message`
///   rather than against a copied string, so a re-worded commit dialog moves
///   both sentences at once and a second wording cannot appear here unnoticed.
/// - **An empty base disables Create and says nothing.** That is the third way
///   Create is off — a failed `gh repo view` — and it deliberately carries no
///   sentence, because `gh`'s own words are already in the model's message slot.
/// - **Every sentence names what will actually happen**: the base the pull
///   request is opened into, and — the `setUpstream` case — the remote a branch
///   with no upstream will be published to.
final class GitHubCreatePlanTests: XCTestCase {

    private func context(
        branch: String? = "feature",
        upstream: String? = "origin/feature",
        remotes: [String] = ["origin"],
        detached: Bool = false
    ) -> CommitContext {
        CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: detached,
            currentBranch: branch,
            upstream: upstream,
            remotes: remotes,
            inProgress: nil
        )
    }

    // MARK: - The base

    func testTheBaseIsTheAnswerItWasGiven() {
        let plan = GitHubCreatePlan.plan(context: context(), base: "master")

        XCTAssertEqual(plan.base, "master")
        XCTAssertEqual(plan.headBranch, "feature")
        XCTAssertTrue(plan.canCreate)
        XCTAssertNil(plan.refusal)
    }

    func testTheBaseAndTheHeadAreTrimmed() {
        let plan = GitHubCreatePlan.plan(context: context(branch: "  feature\n"), base: " master ")

        XCTAssertEqual(plan.base, "master")
        XCTAssertEqual(plan.headBranch, "feature")
    }

    func testAMissingBaseDisablesCreateWithoutASentence() {
        for base in [nil, "", "   "] as [String?] {
            let plan = GitHubCreatePlan.plan(context: context(), base: base)

            XCTAssertFalse(plan.canCreate, "base: \(String(describing: base))")
            // The `repo view` failure that produced it already put `gh`'s words
            // in the model's one message slot; a second sentence would talk over
            // them.
            XCTAssertNil(plan.refusal)
            XCTAssertNil(plan.baseSentence)
        }
    }

    // MARK: - The two refusals

    func testADetachedHEADRefusesWithThePushPlansOwnSentence() {
        let plan = GitHubCreatePlan.plan(
            context: context(branch: nil, upstream: nil, detached: true),
            base: "master"
        )

        XCTAssertEqual(plan.refusal, .detachedHEAD)
        XCTAssertEqual(plan.refusal?.message, PushUnavailableReason.detachedHEAD.message)
        XCTAssertFalse(plan.canCreate)
        XCTAssertNil(plan.baseSentence)
        XCTAssertNil(plan.publishSentence)
    }

    func testNoRemoteRefusesWithThePushPlansOwnSentence() {
        let plan = GitHubCreatePlan.plan(
            context: context(upstream: nil, remotes: []),
            base: "master"
        )

        XCTAssertEqual(plan.refusal, .noRemote)
        XCTAssertEqual(plan.refusal?.message, PushUnavailableReason.noRemote.message)
        XCTAssertFalse(plan.canCreate)
        XCTAssertNil(plan.baseSentence)
        XCTAssertNil(plan.publishSentence)
    }

    func testAnUnreadableBranchNameIsTheDetachedHEADRefusal() {
        // `PushPlan`'s own rule: no branch name is reported as a detached HEAD
        // ahead of a missing remote, because with no branch there is nothing to
        // push even if a remote were configured.
        let plan = GitHubCreatePlan.plan(
            context: context(branch: "  ", upstream: nil, remotes: []),
            base: "master"
        )

        XCTAssertEqual(plan.refusal, .detachedHEAD)
    }

    // MARK: - The push half

    func testABranchWithAnUpstreamIsPushedPlainly() {
        let plan = GitHubCreatePlan.plan(context: context(), base: "master")

        XCTAssertEqual(plan.push, .push(upstream: "origin/feature"))
        XCTAssertEqual(
            plan.publishSentence,
            "“feature” will be pushed to “origin/feature” before the pull request is created."
        )
    }

    func testABranchWithoutAnUpstreamNamesTheRemoteItWillBePublishedTo() {
        let plan = GitHubCreatePlan.plan(
            context: context(upstream: nil, remotes: ["origin", "fork"]),
            base: "master"
        )

        XCTAssertEqual(plan.push, .setUpstream(remote: "origin", branch: "feature"))
        // Publishing a branch to a remote for the first time is a visible,
        // public act, so the remote is named rather than implied.
        XCTAssertEqual(
            plan.publishSentence,
            "“feature” has no upstream yet — it will be published to “origin” "
                + "before the pull request is created."
        )
    }

    func testTheFirstRemoteIsUsedWhenThereIsNoOrigin() {
        let plan = GitHubCreatePlan.plan(
            context: context(upstream: nil, remotes: ["fork", "upstream"]),
            base: "master"
        )

        XCTAssertEqual(plan.push, .setUpstream(remote: "fork", branch: "feature"))
        XCTAssertEqual(
            plan.publishSentence,
            "“feature” has no upstream yet — it will be published to “fork” "
                + "before the pull request is created."
        )
    }

    // MARK: - The sentences

    func testTheBaseSentenceNamesBothBranches() {
        let plan = GitHubCreatePlan.plan(context: context(), base: "develop")

        XCTAssertEqual(
            plan.baseSentence,
            "The pull request will be opened from “feature” into “develop”."
        )
    }

    // MARK: - The head is not pinned

    func testTheBaseSentenceNamesTheLocalBranchEvenWhenTheUpstreamIsSpelledDifferently() {
        // The head is `gh`'s to resolve — a `--head` argument names a ref in the
        // *base* repository, which for a fork checkout is the wrong repository
        // altogether — so the sentence names the local branch `gh` will read the
        // tracking configuration of, and `create(...)` re-reads that same branch
        // after the push rather than pinning a ref here.
        let plan = GitHubCreatePlan.plan(context: context(upstream: "origin/other-name"), base: "master")

        XCTAssertEqual(plan.headBranch, "feature")
        XCTAssertEqual(
            plan.baseSentence,
            "The pull request will be opened from \u{201C}feature\u{201D} into \u{201C}master\u{201D}."
        )
    }

    func testTheHeadBranchIsTheLocalNameWhateverTheUpstreamIsCalled() {
        for upstream in ["origin/feature", "origin/other-name", "fork/other-name", "gone/other-name", nil] {
            let plan = GitHubCreatePlan.plan(
                context: context(upstream: upstream, remotes: ["origin", "fork"]),
                base: "master"
            )
            XCTAssertEqual(plan.headBranch, "feature", "upstream \(upstream ?? "nil")")
        }
    }

    func testSetUpstreamPublishesUnderTheLocalName() {
        // `git push --set-upstream <remote> <branch>` publishes `branch` under
        // its own name by construction.
        let plan = GitHubCreatePlan.plan(context: context(upstream: nil), base: "master")

        XCTAssertEqual(plan.push, .setUpstream(remote: "origin", branch: "feature"))
    }

    func testTheUncommittedChangesNoteIsStatedOnce() {
        XCTAssertEqual(
            GitHubCreatePlan.uncommittedChangesNote,
            "Uncommitted changes will not be part of the pull request."
        )
    }
}
