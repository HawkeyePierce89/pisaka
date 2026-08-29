import XCTest
@testable import PisakaCore

/// The policy is the only thing standing between an aggressive autosave and an
/// unbounded pile of bytes in Application Support, and the only thing that
/// promises the pile is never *empty* when it matters. Both halves are pinned
/// here: the skip rule with its precedence (so a cheap refusal is never paid for
/// with a digest, and a file from outside the project never lands in this
/// project's history) and the retention rule with its one unconditional
/// survivor.
final class LocalHistoryPolicyTests: XCTestCase {
    private let policy = LocalHistoryPolicy()
    private let now = Date(timeIntervalSince1970: 1_772_345_678)

    // MARK: - The ceilings

    func testTheContentCeilingIsFindInFilesOwnCeiling() {
        XCTAssertEqual(LocalHistoryPolicy.defaultMaxContentBytes, ProjectSearchModel.defaultMaxFileBytes)
        XCTAssertEqual(LocalHistoryPolicy.defaultMaxContentBytes, 1 << 20)
    }

    func testTheStatedDefaultsAreTheDocumentedNumbers() {
        XCTAssertEqual(LocalHistoryPolicy.defaultMaxAge, 14 * 24 * 60 * 60)
        XCTAssertEqual(LocalHistoryPolicy.defaultRevisionsPerFile, 30)
        XCTAssertEqual(LocalHistoryPolicy.defaultMaxPreOperationFiles, 200)

        XCTAssertEqual(policy.maxContentBytes, LocalHistoryPolicy.defaultMaxContentBytes)
        XCTAssertEqual(policy.maxAge, LocalHistoryPolicy.defaultMaxAge)
        XCTAssertEqual(policy.revisionsPerFile, LocalHistoryPolicy.defaultRevisionsPerFile)
        XCTAssertEqual(policy.maxPreOperationFiles, LocalHistoryPolicy.defaultMaxPreOperationFiles)
    }

    // MARK: - Capture: the happy answer

    func testACaptureAnswersTheHashTheFileNameWillCarry() {
        let decision = policy.capture(of: "let x = 1\n", relativePath: "Sources/A.swift", latestHash: nil)
        XCTAssertEqual(decision, .capture(hash: LocalHistoryLayout.contentHash(of: "let x = 1\n")))
        XCTAssertEqual(decision.hash?.count, LocalHistoryLayout.contentHashLength)
    }

    func testEmptyContentIsCapturedRatherThanTreatedAsAbsent() {
        // Emptying a file is exactly the edit a safety net is for.
        XCTAssertNotNil(policy.capture(of: "", relativePath: "A.swift", latestHash: nil).hash)
    }

    func testANestedPathIsInsideTheProject() {
        XCTAssertNotNil(policy.capture(of: "x", relativePath: "a/b/c/D.swift", latestHash: nil).hash)
        XCTAssertNotNil(policy.capture(of: "x", relativePath: "./a/../b/C.swift", latestHash: nil).hash)
    }

    // MARK: - Capture: each skip in isolation

    func testNoRelativePathIsUntitled() {
        XCTAssertEqual(policy.capture(of: "x", relativePath: nil, latestHash: nil), .skip(.untitled))
        XCTAssertEqual(policy.capture(of: "x", relativePath: "", latestHash: nil), .skip(.untitled))
    }

    func testAnAbsoluteOrEscapingPathIsOutsideTheProject() {
        for path in ["/etc/hosts", "../elsewhere/A.swift", "a/../../B.swift", "..", "."] {
            XCTAssertEqual(
                policy.capture(of: "x", relativePath: path, latestHash: nil),
                .skip(.outsideProject),
                path
            )
        }
    }

    func testExactlyTheCeilingIsCapturedAndOneByteMoreIsNot() {
        let atCeiling = String(repeating: "a", count: policy.maxContentBytes)
        XCTAssertNotNil(policy.capture(of: atCeiling, relativePath: "A.txt", latestHash: nil).hash)

        let overCeiling = atCeiling + "a"
        XCTAssertEqual(
            policy.capture(of: overCeiling, relativePath: "A.txt", latestHash: nil),
            .skip(.tooLarge(bytes: policy.maxContentBytes + 1))
        )
    }

    func testTheCeilingCountsUTF8BytesNotCharacters() {
        // Half as many characters as the ceiling, but two bytes each: over.
        let small = LocalHistoryPolicy(maxContentBytes: 10)
        let fiveTwoByteCharacters = String(repeating: "é", count: 5)
        XCTAssertEqual(fiveTwoByteCharacters.count, 5)
        XCTAssertNotNil(small.capture(of: fiveTwoByteCharacters, relativePath: "A.txt", latestHash: nil).hash)

        let sixTwoByteCharacters = String(repeating: "é", count: 6)
        XCTAssertEqual(sixTwoByteCharacters.count, 6)
        XCTAssertEqual(
            small.capture(of: sixTwoByteCharacters, relativePath: "A.txt", latestHash: nil),
            .skip(.tooLarge(bytes: 12))
        )
    }

    func testIdenticalContentSkipsAndOneChangedByteDoesNot() {
        let text = "let x = 1\n"
        let hash = LocalHistoryLayout.contentHash(of: text)
        XCTAssertEqual(policy.capture(of: text, relativePath: "A.swift", latestHash: hash), .skip(.unchanged))

        let changed = "let x = 2\n"
        XCTAssertEqual(
            policy.capture(of: changed, relativePath: "A.swift", latestHash: hash),
            .capture(hash: LocalHistoryLayout.contentHash(of: changed))
        )
        // A trailing newline is a change like any other.
        XCTAssertNotNil(policy.capture(of: "let x = 1", relativePath: "A.swift", latestHash: hash).hash)
    }

    func testAnotherFilesHashDoesNotSuppressThisFile() {
        let hash = LocalHistoryLayout.contentHash(of: "something else entirely")
        XCTAssertNotNil(policy.capture(of: "let x = 1\n", relativePath: "A.swift", latestHash: hash).hash)
    }

    // MARK: - Capture: precedence between the skips

    func testPathRefusalsOutrankSizeAndSameness() {
        let oversized = String(repeating: "a", count: policy.maxContentBytes + 1)
        XCTAssertEqual(policy.capture(of: oversized, relativePath: nil, latestHash: nil), .skip(.untitled))
        XCTAssertEqual(
            policy.capture(of: oversized, relativePath: "/tmp/A.txt", latestHash: nil),
            .skip(.outsideProject)
        )

        let text = "let x = 1\n"
        let hash = LocalHistoryLayout.contentHash(of: text)
        XCTAssertEqual(policy.capture(of: text, relativePath: nil, latestHash: hash), .skip(.untitled))
        XCTAssertEqual(policy.capture(of: text, relativePath: "../A.swift", latestHash: hash), .skip(.outsideProject))
    }

    func testSizeOutranksSameness() {
        let oversized = String(repeating: "a", count: policy.maxContentBytes + 1)
        XCTAssertEqual(
            policy.capture(of: oversized, relativePath: "A.txt", latestHash: LocalHistoryLayout.contentHash(of: oversized)),
            .skip(.tooLarge(bytes: policy.maxContentBytes + 1))
        )
    }

    func testUntitledOutranksOutsideTheProject() {
        XCTAssertEqual(policy.capture(of: "x", relativePath: nil, latestHash: nil), .skip(.untitled))
    }

    // MARK: - Retention

    func testEmptyAndSingleRevisionInputsAreNoOps() {
        let empty = policy.prune([], now: now)
        XCTAssertTrue(empty.keep.isEmpty)
        XCTAssertTrue(empty.delete.isEmpty)

        let one = snapshot(secondsAgo: 0)
        let single = policy.prune([one], now: now)
        XCTAssertEqual(single.keep, [one])
        XCTAssertTrue(single.delete.isEmpty)
    }

    func testAgeDropsEverythingOlderThanTheBoundExceptTheNewest() {
        let day: TimeInterval = 24 * 60 * 60
        let fresh = snapshot(secondsAgo: day)
        let atTheBound = snapshot(secondsAgo: policy.maxAge)
        let justPast = snapshot(secondsAgo: policy.maxAge + 1)
        let ancient = snapshot(secondsAgo: 90 * day)

        let result = policy.prune([ancient, justPast, atTheBound, fresh], now: now)
        XCTAssertEqual(result.keep, [fresh, atTheBound])
        XCTAssertEqual(result.delete, [justPast, ancient])
    }

    func testTheNewestSurvivesEvenWhenItIsItselfExpired() {
        let day: TimeInterval = 24 * 60 * 60
        let newest = snapshot(secondsAgo: 30 * day)
        let older = snapshot(secondsAgo: 60 * day)

        let result = policy.prune([older, newest], now: now)
        XCTAssertEqual(result.keep, [newest])
        XCTAssertEqual(result.delete, [older])
    }

    func testTheCountCapKeepsExactlyTheNewestThirty() {
        for total in [31, 100] {
            let all = (0..<total).map { snapshot(secondsAgo: TimeInterval($0) * 60) }
            let result = policy.prune(all.shuffled(), now: now)
            XCTAssertEqual(result.keep.count, policy.revisionsPerFile, "total \(total)")
            XCTAssertEqual(result.delete.count, total - policy.revisionsPerFile, "total \(total)")
            XCTAssertEqual(result.keep, Array(all.prefix(policy.revisionsPerFile)), "total \(total)")
            XCTAssertEqual(result.delete, Array(all.dropFirst(policy.revisionsPerFile)), "total \(total)")
        }
    }

    func testExactlyTheCountCapIsANoOp() {
        let all = (0..<policy.revisionsPerFile).map { snapshot(secondsAgo: TimeInterval($0) * 60) }
        let result = policy.prune(all, now: now)
        XCTAssertEqual(result.keep, all)
        XCTAssertTrue(result.delete.isEmpty)
    }

    func testAgeIsAppliedBeforeTheCountCap() {
        // Twenty fresh revisions and twenty expired ones: the cap alone would keep
        // thirty, but age has already condemned the older twenty.
        let day: TimeInterval = 24 * 60 * 60
        let fresh = (0..<20).map { snapshot(secondsAgo: TimeInterval($0) * 60) }
        let expired = (0..<20).map { snapshot(secondsAgo: policy.maxAge + TimeInterval($0 + 1) * day) }

        let result = policy.prune(fresh + expired, now: now)
        XCTAssertEqual(result.keep, fresh)
        XCTAssertEqual(result.delete, expired)
    }

    func testALabelledSnapshotIsPrunedOnTheSameTermsAsASave() {
        let labelled = LocalHistoryEvent.allCases.filter { $0 != .save }
        let all = (0..<31).map { index -> LocalHistorySnapshot in
            let event = index.isMultiple(of: 2) ? labelled[index % labelled.count] : LocalHistoryEvent.save
            return snapshot(secondsAgo: TimeInterval(index) * 60, event: event)
        }

        let result = policy.prune(all, now: now)
        XCTAssertEqual(result.keep, Array(all.prefix(30)))
        XCTAssertEqual(result.delete, [all[30]])
        XCTAssertNotEqual(result.delete.first?.event, .save)
    }

    func testARevisionStampedInTheFutureIsNotExpired() {
        // Clock skew, or a snapshot written by a machine one second ahead.
        let ahead = snapshot(secondsAgo: -60)
        let result = policy.prune([ahead], now: now)
        XCTAssertEqual(result.keep, [ahead])
        XCTAssertTrue(result.delete.isEmpty)
    }

    func testASmallPolicyIsWhatTheStoresTestsWillHold() {
        let small = LocalHistoryPolicy(maxAge: 60, revisionsPerFile: 2)
        let all = (0..<4).map { snapshot(secondsAgo: TimeInterval($0)) }
        let result = small.prune(all, now: now)
        XCTAssertEqual(result.keep, Array(all.prefix(2)))
        XCTAssertEqual(result.delete, Array(all.dropFirst(2)))
    }

    // MARK: - Support

    /// A snapshot built the way the layout builds one, so `prune`'s ordering is
    /// exercised against real names rather than hand-spelled ones.
    private func snapshot(secondsAgo: TimeInterval, event: LocalHistoryEvent = .save) -> LocalHistorySnapshot {
        let timestamp = now.addingTimeInterval(-secondsAgo)
        let hash = LocalHistoryLayout.contentHash(of: "\(timestamp.timeIntervalSince1970)-\(event.tag)")
        let name = LocalHistoryLayout.snapshotFileName(timestamp: timestamp, event: event, contentHash: hash)
        guard let parsed = LocalHistoryLayout.snapshot(fromFileName: name) else {
            XCTFail("the layout could not parse the name it just produced: \(name)")
            return LocalHistorySnapshot(fileName: name, timestamp: timestamp, event: event, contentHash: hash)
        }
        return parsed
    }
}
