import XCTest
@testable import PisakaCore

/// The merge sheet's pure half: when Merge may run, why it may not, which
/// methods the repository offers, and every sentence the sheet shows.
///
/// Four properties carry the suite:
///
/// - **The enabled rule is asserted exhaustively.** All 168 combinations of the
///   four inputs — draft, `mergeable`, `mergeStateStatus`, checks summary — are
///   walked and compared against the conjunction written out independently in
///   the test, so a rule that grows a fifth term, loses one, or quietly widens
///   its green set fails here rather than in a sheet.
/// - **Checks are judged before the merge state.** The one ordering in the table
///   that changes behaviour: a required check that is still running makes GitHub
///   answer `BLOCKED`, and a plan reading the merge state first would refuse with
///   a sentence about repository rules in exactly the state a wait exists to sit
///   through — and, worse, one that is neither armable nor waitable.
/// - **`isArmable` and `mayResolveByWaiting` are asserted over `allCases`.** They
///   are the wait's whole decision table and the button's label rule; a new
///   refusal that answers neither question deliberately fails the coverage
///   assertion instead of defaulting to "stop".
/// - **Every sentence is asserted through the value that owns it**, never
///   against a copy: the refusals' through `GitHubMergeRefusal.message`, the
///   sheet's through the plan, so a re-wording moves one place.
final class GitHubMergePlanTests: XCTestCase {

    // MARK: - Builders

    private func pullRequest(
        number: Int = 7,
        title: String = "Grow the wire",
        headRefName: String = "feature",
        baseRefName: String = "master",
        isDraft: Bool = false,
        summary: GitHubChecksSummary = .success,
        headRefOid: String = "abc123",
        mergeable: GitHubMergeability = .mergeable,
        mergeStateStatus: GitHubMergeStateStatus = .clean
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            number: number,
            title: title,
            authorLogin: "octocat",
            headRefName: headRefName,
            baseRefName: baseRefName,
            isDraft: isDraft,
            reviewDecision: .approved,
            url: "https://github.com/o/r/pull/\(number)",
            state: "OPEN",
            summary: summary,
            headRefOid: headRefOid,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus
        )
    }

    private func repository(
        merge: Bool = true,
        squash: Bool = true,
        rebase: Bool = true,
        viewerDefault: GitHubMergeMethod = .squash,
        deleteBranchOnMerge: Bool = false
    ) -> GitHubRepository {
        GitHubRepository(
            nameWithOwner: "o/r",
            defaultBranch: "master",
            mergeCommitAllowed: merge,
            squashMergeAllowed: squash,
            rebaseMergeAllowed: rebase,
            viewerDefaultMergeMethod: viewerDefault,
            deleteBranchOnMerge: deleteBranchOnMerge
        )
    }

    private func plan(
        _ request: GitHubPullRequest? = nil,
        repository repo: GitHubRepository? = nil,
        checkedOutBranch: String? = "other"
    ) -> GitHubMergePlan {
        GitHubMergePlan.plan(
            pullRequest: request ?? pullRequest(),
            repository: repo ?? repository(),
            checkedOutBranch: checkedOutBranch
        )
    }

    // MARK: - The enabled rule, exhaustively

    func testTheEnabledRuleIsTheStatedConjunctionOverEveryCombination() {
        let greenStates: Set<GitHubMergeStateStatus> = [.clean, .hasHooks, .unstable]
        let greenSummaries: Set<GitHubChecksSummary> = [.success, .noChecks]
        var enabledCount = 0

        for isDraft in [false, true] {
            for mergeable in GitHubMergeability.allCases {
                for state in GitHubMergeStateStatus.allCases {
                    for summary in GitHubChecksSummary.allCases {
                        let subject = plan(pullRequest(
                            isDraft: isDraft,
                            summary: summary,
                            mergeable: mergeable,
                            mergeStateStatus: state
                        ))
                        let expected = !isDraft
                            && mergeable == .mergeable
                            && greenStates.contains(state)
                            && greenSummaries.contains(summary)
                        let label = "draft \(isDraft), \(mergeable), \(state), \(summary)"

                        XCTAssertEqual(subject.canMerge, expected, label)
                        XCTAssertEqual(subject.refusal == nil, expected, label)
                        if expected { enabledCount += 1 }
                    }
                }
            }
        }

        // 1 draft value × 1 mergeability × 3 green states × 2 green summaries.
        XCTAssertEqual(enabledCount, 6)
    }

    // MARK: - The refusals, one at a time

    func testADraftRefusesWhateverElseIsGreen() {
        let subject = plan(pullRequest(isDraft: true))

        XCTAssertEqual(subject.refusal, .draft)
        XCTAssertEqual(
            subject.refusal?.message,
            "This pull request is a draft. Mark it ready for review on GitHub before merging."
        )
    }

    func testConflictsAreReadFromEitherField() {
        for request in [
            pullRequest(mergeable: .conflicting),
            pullRequest(mergeStateStatus: .dirty),
        ] {
            XCTAssertEqual(plan(request).refusal, .conflicts)
        }
        XCTAssertEqual(
            GitHubMergeRefusal.conflicts.message,
            "This pull request has conflicts with its base branch. Resolve them before merging."
        )
    }

    func testChecksStillRunningRefusesAndSaysSo() {
        let subject = plan(pullRequest(summary: .pending))

        XCTAssertEqual(subject.refusal, .checksRunning)
        XCTAssertEqual(subject.refusal?.message, "Checks are still running.")
    }

    func testFailedChecksRefuse() {
        let subject = plan(pullRequest(summary: .failure))

        XCTAssertEqual(subject.refusal, .checksFailed)
        XCTAssertEqual(subject.refusal?.message, "Some checks did not pass.")
    }

    func testUnknownMergeabilityIsReadFromEitherFieldAndAsksForARefresh() {
        for request in [
            pullRequest(mergeable: .unknown),
            pullRequest(mergeStateStatus: .unknown),
        ] {
            XCTAssertEqual(plan(request).refusal, .mergeabilityUnknown)
        }
        XCTAssertEqual(
            GitHubMergeRefusal.mergeabilityUnknown.message,
            "GitHub has not finished computing mergeability — refresh in a moment."
        )
    }

    func testBehindRefusesWithItsOwnSentence() {
        let subject = plan(pullRequest(mergeStateStatus: .behind))

        XCTAssertEqual(subject.refusal, .behind)
        XCTAssertEqual(
            subject.refusal?.message,
            "The head branch is behind its base branch. Update it on GitHub before merging."
        )
    }

    func testGitHubsOwnRulesRefuseAsBlocked() {
        let subject = plan(pullRequest(mergeStateStatus: .blocked))

        XCTAssertEqual(subject.refusal, .blocked)
        XCTAssertEqual(
            subject.refusal?.message,
            "GitHub’s rules for this repository are blocking the merge — "
                + "a required review or a required check is missing."
        )
    }

    /// The one ordering in the table that changes behaviour.
    ///
    /// A repository with a required check reports `BLOCKED` for the whole time
    /// that check runs. Reading the merge state first would name the repository's
    /// rules — a refusal that is neither armable nor waitable — in precisely the
    /// state the wait exists for.
    func testRunningChecksAreJudgedBeforeAWaitingRequiredCheckMakesGitHubSayBlocked() {
        let subject = plan(pullRequest(summary: .pending, mergeStateStatus: .blocked))

        XCTAssertEqual(subject.refusal, .checksRunning)
        XCTAssertEqual(subject.refusal?.isArmable, true)
    }

    func testEverySentenceIsNonEmptyAndDistinct() {
        let messages = GitHubMergeRefusal.allCases.map(\.message)

        XCTAssertEqual(Set(messages).count, GitHubMergeRefusal.allCases.count)
        for message in messages {
            XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - The wait's two questions

    func testOnlyRunningChecksArmAWait() {
        for refusal in GitHubMergeRefusal.allCases {
            XCTAssertEqual(refusal.isArmable, refusal == .checksRunning, "\(refusal)")
        }
    }

    func testExactlyTheTwoComputingStatesMayResolveByWaiting() {
        let waitable: Set<GitHubMergeRefusal> = [.checksRunning, .mergeabilityUnknown]

        for refusal in GitHubMergeRefusal.allCases {
            XCTAssertEqual(refusal.mayResolveByWaiting, waitable.contains(refusal), "\(refusal)")
        }
    }

    /// Anything a wait may be armed from, it may also keep waiting on. The
    /// converse does not hold, and is the point of having two questions.
    func testArmableImpliesWaitableButNotTheOtherWayAround() {
        for refusal in GitHubMergeRefusal.allCases where refusal.isArmable {
            XCTAssertTrue(refusal.mayResolveByWaiting, "\(refusal)")
        }
        XCTAssertTrue(GitHubMergeRefusal.mergeabilityUnknown.mayResolveByWaiting)
        XCTAssertFalse(GitHubMergeRefusal.mergeabilityUnknown.isArmable)
    }

    // MARK: - The methods

    func testTheAllowedMethodsFollowTheTablesOwnOrder() {
        let subject = plan(repository: repository())

        XCTAssertEqual(subject.allowedMethods, [.merge, .squash, .rebase])
        XCTAssertTrue(subject.showsMethodPicker)
    }

    func testAllowedMethodsAreEachReadFromTheirOwnFlag() {
        XCTAssertEqual(
            plan(repository: repository(merge: false, squash: true, rebase: false)).allowedMethods,
            [.squash]
        )
        XCTAssertEqual(
            plan(repository: repository(merge: true, squash: false, rebase: true)).allowedMethods,
            [.merge, .rebase]
        )
    }

    func testTheDefaultIsTheViewersWhenTheRepositoryStillAllowsIt() {
        let subject = plan(repository: repository(viewerDefault: .rebase))

        XCTAssertEqual(subject.defaultMethod, .rebase)
    }

    func testADisallowedViewerDefaultFallsBackToTheFirstAllowedMethod() {
        let subject = plan(repository: repository(merge: false, squash: true, rebase: true, viewerDefault: .merge))

        XCTAssertEqual(subject.defaultMethod, .squash)
    }

    func testExactlyOneAllowedMethodMeansNoPicker() {
        let subject = plan(repository: repository(merge: false, squash: true, rebase: false, viewerDefault: .merge))

        XCTAssertFalse(subject.showsMethodPicker)
        XCTAssertEqual(subject.defaultMethod, .squash)
        XCTAssertTrue(subject.canMerge)
    }

    /// The way Merge is off *without a sentence* — the create plan's empty base,
    /// read again. GitHub does not permit this repository state; what matters is
    /// that it never enables a button whose command would carry no method flag.
    func testARepositoryAllowingNoMethodDisablesMergeAndSaysNothing() {
        let subject = plan(repository: repository(merge: false, squash: false, rebase: false))

        XCTAssertTrue(subject.allowedMethods.isEmpty)
        XCTAssertNil(subject.defaultMethod)
        XCTAssertFalse(subject.canMerge)
        XCTAssertNil(subject.refusal)
    }

    // MARK: - The sheet's sentences

    func testTheSubjectIsGitHubsOwnDefault() {
        let subject = plan(pullRequest(number: 54, title: "GitHub pull requests part 1"))

        XCTAssertEqual(subject.defaultSubject, "GitHub pull requests part 1 (#54)")
    }

    func testTheMergeSentenceNamesBothRefsEvenWhileMergeIsRefused() {
        let subject = plan(pullRequest(headRefName: "feature", baseRefName: "master", isDraft: true))

        XCTAssertNotNil(subject.refusal)
        XCTAssertEqual(subject.mergeSentence, "“feature” will be merged into “master”.")
    }

    func testTheBranchDeletionLineAppearsOnlyWhenGitHubHasItOn() {
        XCTAssertNil(plan(repository: repository(deleteBranchOnMerge: false)).deleteBranchSentence)
        XCTAssertEqual(
            plan(repository: repository(deleteBranchOnMerge: true)).deleteBranchSentence,
            "This repository deletes head branches on merge — "
                + "GitHub will delete “feature” once the merge lands."
        )
    }

    func testTheTailIsOwedOnlyWhenTheHeadIsTheCheckedOutBranch() {
        let onIt = plan(checkedOutBranch: "feature")
        let elsewhere = plan(checkedOutBranch: "master")

        XCTAssertTrue(onIt.isTailOwed)
        XCTAssertEqual(onIt.tailSentence, "After merging, Pisaka will switch to “master” and pull it.")
        XCTAssertFalse(elsewhere.isTailOwed)
        XCTAssertNil(elsewhere.tailSentence)
    }

    func testADetachedHeadOwesNoTailAndTheBranchIsTrimmed() {
        XCTAssertFalse(plan(checkedOutBranch: nil).isTailOwed)
        XCTAssertFalse(plan(checkedOutBranch: "   ").isTailOwed)
        XCTAssertTrue(plan(checkedOutBranch: " feature\n").isTailOwed)
    }

    /// Refs are case-sensitive in git, so the comparison is too: a tail that
    /// switched away from `Feature` because a row said `feature` would move a
    /// worktree the merge did not touch.
    func testTheTailComparisonIsCaseSensitive() {
        XCTAssertFalse(plan(checkedOutBranch: "Feature").isTailOwed)
    }

    // MARK: - The button, which the sheet only draws

    /// The label rule, over the whole refusal table plus the enabled state: the
    /// button reads *Merge when checks pass* exactly where a wait may be armed,
    /// and *Merge* everywhere else. Asserted here rather than in a view for the
    /// reason the sentences are: a label that disagreed with what the press does
    /// is the one bug this feature cannot afford twice.
    func testTheLabelSaysWhichOfTheTwoThingsThePressWillDo() {
        XCTAssertEqual(plan().buttonTitle, GitHubMergePlan.mergeButtonTitle)
        XCTAssertFalse(plan().armsWait)

        for state in GitHubMergeStateStatus.allCases {
            for summary in GitHubChecksSummary.allCases {
                let subject = plan(pullRequest(summary: summary, mergeStateStatus: state))
                let arms = subject.refusal?.isArmable == true
                XCTAssertEqual(subject.armsWait, arms, "\(state), \(summary)")
                XCTAssertEqual(
                    subject.buttonTitle,
                    arms ? GitHubMergePlan.armButtonTitle : GitHubMergePlan.mergeButtonTitle,
                    "\(state), \(summary)"
                )
            }
        }
    }

    func testTheTwoLabelsAreDistinctAndNamedOnce() {
        XCTAssertEqual(GitHubMergePlan.mergeButtonTitle, "Merge")
        XCTAssertEqual(GitHubMergePlan.armButtonTitle, "Merge when checks pass")
    }

    /// A press only ever does one of two things, so a state that offers neither
    /// disables the button — under that refusal's own sentence, which the sheet
    /// draws beside it.
    func testTheButtonIsOfferedOnlyWhereItMergesOrArms() {
        for state in GitHubMergeStateStatus.allCases {
            for summary in GitHubChecksSummary.allCases {
                let subject = plan(pullRequest(summary: summary, mergeStateStatus: state))
                XCTAssertEqual(subject.buttonIsOffered, subject.canMerge || subject.armsWait, "\(state)")
            }
        }
        XCTAssertFalse(plan(pullRequest(isDraft: true)).buttonIsOffered)
        XCTAssertFalse(plan(pullRequest(mergeable: .conflicting)).buttonIsOffered)
    }

    /// A repository allowing no method arms nothing either: the wait would refuse
    /// it silently half an hour later, which from a button that offered it looks
    /// like a press that did nothing.
    func testARepositoryAllowingNoMethodNeitherMergesNorArms() {
        let subject = plan(
            pullRequest(summary: .pending),
            repository: repository(merge: false, squash: false, rebase: false)
        )

        XCTAssertEqual(subject.refusal, .checksRunning)
        XCTAssertTrue(subject.refusal?.isArmable == true)
        XCTAssertFalse(subject.armsWait)
        XCTAssertFalse(subject.buttonIsOffered)
    }

    /// The button's whole gate, including the two things only the open sheet
    /// knows. A method the repository disallows is the refusal the model makes
    /// anyway, made before the press; an empty subject is a merge commit with no
    /// message, and a rebase — which composes no commit — is never held up by one.
    func testTheButtonsGateCoversTheMethodAndTheSubject() {
        let subject = plan(repository: repository(merge: true, squash: true, rebase: true))

        XCTAssertTrue(subject.buttonIsEnabled(method: .squash, subject: "A change (#7)"))
        XCTAssertFalse(subject.buttonIsEnabled(method: .squash, subject: "   \n "))
        XCTAssertTrue(subject.buttonIsEnabled(method: .rebase, subject: ""))

        let squashOnly = plan(repository: repository(merge: false, squash: true, rebase: false))
        XCTAssertFalse(squashOnly.buttonIsEnabled(method: .merge, subject: "A change (#7)"))
        XCTAssertTrue(squashOnly.buttonIsEnabled(method: .squash, subject: "A change (#7)"))

        let draft = plan(pullRequest(isDraft: true))
        XCTAssertFalse(draft.buttonIsEnabled(method: .squash, subject: "A change (#7)"))
    }

    /// Arming has the same gate: the sheet's button reads *Merge when checks
    /// pass* over a subject field the reader can still empty, and an armed wait
    /// would then send `--subject ""` half an hour later.
    func testAnArmingPressIsGatedByTheSameSubjectRule() {
        let subject = plan(pullRequest(summary: .pending))

        XCTAssertTrue(subject.armsWait)
        XCTAssertFalse(subject.buttonIsEnabled(method: .squash, subject: ""))
        XCTAssertTrue(subject.buttonIsEnabled(method: .squash, subject: "A change (#7)"))
    }
}
