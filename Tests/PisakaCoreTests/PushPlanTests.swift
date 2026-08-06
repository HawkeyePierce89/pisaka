import XCTest
@testable import PisakaCore

final class PushPlanTests: XCTestCase {

    private func context(
        unborn: Bool = false,
        detached: Bool = false,
        branch: String? = "master",
        upstream: String? = nil,
        remotes: [String] = [],
        inProgress: InProgressOperation? = nil
    ) -> CommitContext {
        CommitContext(
            isUnbornHEAD: unborn,
            isDetachedHEAD: detached,
            currentBranch: branch,
            upstream: upstream,
            remotes: remotes,
            inProgress: inProgress
        )
    }

    // MARK: - Branch 1: an upstream exists

    func testUpstreamGivesAPlainPush() {
        let plan = PushPlan.plan(context: context(upstream: "origin/master", remotes: ["origin"]))
        XCTAssertEqual(plan, .push(upstream: "origin/master"))
        XCTAssertTrue(plan.isAvailable)
    }

    func testUpstreamWinsEvenWhenItsRemoteIsNotOrigin() {
        let plan = PushPlan.plan(
            context: context(upstream: "fork/master", remotes: ["origin", "fork"])
        )
        XCTAssertEqual(plan, .push(upstream: "fork/master"))
    }

    func testUpstreamWithNoRemotesListedStillPushes() {
        // `git remote` failing (or being read as empty) must not withdraw a push
        // that git is perfectly able to perform through the configured upstream.
        let plan = PushPlan.plan(context: context(upstream: "origin/master", remotes: []))
        XCTAssertEqual(plan, .push(upstream: "origin/master"))
    }

    func testBlankUpstreamIsTreatedAsAbsent() {
        let plan = PushPlan.plan(context: context(upstream: "   ", remotes: ["origin"]))
        XCTAssertEqual(plan, .setUpstream(remote: "origin", branch: "master"))
    }

    // MARK: - Branch 2: no upstream, but a remote exists

    func testNoUpstreamWithOriginCreatesTheUpstream() {
        let plan = PushPlan.plan(context: context(remotes: ["origin"]))
        XCTAssertEqual(plan, .setUpstream(remote: "origin", branch: "master"))
        XCTAssertTrue(plan.isAvailable)
    }

    func testOriginIsPreferredOverOtherRemotes() {
        let plan = PushPlan.plan(context: context(remotes: ["backup", "origin", "upstream"]))
        XCTAssertEqual(plan, .setUpstream(remote: "origin", branch: "master"))
    }

    func testWithoutOriginTheFirstRemoteIsUsed() {
        // `git remote` prints its remotes sorted, so "the first one" is a stable
        // choice rather than an arbitrary one — and the dialog names the target.
        let plan = PushPlan.plan(context: context(remotes: ["backup", "upstream"]))
        XCTAssertEqual(plan, .setUpstream(remote: "backup", branch: "master"))
    }

    func testUnbornHEADCanStillPlanAPush() {
        // The plan describes what happens *after* the commit, so the very first
        // commit on a fresh repository is pushable: HEAD is unborn but the branch
        // name is already known.
        let plan = PushPlan.plan(context: context(unborn: true, branch: "main", remotes: ["origin"]))
        XCTAssertEqual(plan, .setUpstream(remote: "origin", branch: "main"))
    }

    // MARK: - Branch 3: unavailable

    func testDetachedHEADHasNoBranchToPush() {
        let plan = PushPlan.plan(
            context: context(detached: true, branch: nil, remotes: ["origin"])
        )
        XCTAssertEqual(plan, .unavailable(reason: .detachedHEAD))
        XCTAssertFalse(plan.isAvailable)
        XCTAssertEqual(
            PushUnavailableReason.detachedHEAD.message,
            "HEAD is detached — there is no branch to push."
        )
    }

    func testNoRemoteMakesPushUnavailable() {
        let plan = PushPlan.plan(context: context(remotes: []))
        XCTAssertEqual(plan, .unavailable(reason: .noRemote))
        XCTAssertEqual(
            PushUnavailableReason.noRemote.message,
            "This repository has no remote to push to."
        )
    }

    func testDetachedHEADWinsOverAMissingRemote() {
        let plan = PushPlan.plan(context: context(detached: true, branch: nil, remotes: []))
        XCTAssertEqual(plan, .unavailable(reason: .detachedHEAD))
    }

    func testAMissingBranchNameIsTreatedAsDetached() {
        // `symbolic-ref` failing leaves no branch to name in `--set-upstream`;
        // refusing is the honest outcome, not guessing one.
        let plan = PushPlan.plan(context: context(branch: nil, remotes: ["origin"]))
        XCTAssertEqual(plan, .unavailable(reason: .detachedHEAD))
    }

    func testABlankBranchNameIsTreatedAsDetached() {
        let plan = PushPlan.plan(context: context(branch: "  ", remotes: ["origin"]))
        XCTAssertEqual(plan, .unavailable(reason: .detachedHEAD))
    }

    func testBlankRemoteNamesAreIgnored() {
        let plan = PushPlan.plan(context: context(remotes: ["", "  "]))
        XCTAssertEqual(plan, .unavailable(reason: .noRemote))
    }

    /// `.branchChanged` is the one reason `plan(context:)` never produces — it is
    /// the verdict of the re-read `CommitDialogModel.commit` takes immediately
    /// before pushing, which is the only place that compares two readings of the
    /// repository. It carries its text here so the wording sits with the other
    /// push refusals, and it must say that the *commit* survived.
    func testBranchChangedIsReportedByTheModelNotByThePlan() {
        for remotes in [["origin"], []] {
            for detached in [false, true] {
                let plan = PushPlan.plan(
                    context: context(
                        detached: detached,
                        branch: detached ? nil : "main",
                        remotes: remotes
                    )
                )
                XCTAssertNotEqual(plan, .unavailable(reason: .branchChanged))
            }
        }
        XCTAssertEqual(
            PushUnavailableReason.branchChanged.message,
            "The current branch changed while the commit was being created, "
                + "so nothing was pushed. The commit was created — push it from the "
                + "branch that has it."
        )
    }

    // MARK: - Every unavailable reason carries text

    func testEveryUnavailableReasonCarriesText() {
        for reason in [PushUnavailableReason.detachedHEAD, .noRemote, .branchChanged] {
            XCTAssertFalse(
                reason.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(reason) has no message"
            )
        }
    }
}
