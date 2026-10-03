import XCTest
@testable import PisakaCore

final class ChangedFileGroupsTests: XCTestCase {
    private func file(_ path: String, _ status: FileStatus = .modified, oldPath: String? = nil) -> ChangedFile {
        ChangedFile(path: path, status: status, oldPath: oldPath)
    }

    private func shape(_ groups: [ChangedFileGroup]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.label, $0.files.map(\.path)) })
    }

    func testEmptyInputGivesNoGroups() {
        XCTAssertEqual(ChangedFileGroups.group([], rootName: "pisaka"), [])
    }

    func testRootFilesGoUnderTheProjectNameAndComeFirst() {
        let groups = ChangedFileGroups.group(
            [file("b/x.swift"), file("README.md"), file("a/y.swift")],
            rootName: "pisaka"
        )
        XCTAssertEqual(groups.map(\.label), ["pisaka", "a", "b"])
        XCTAssertEqual(groups.map(\.path), ["", "a", "b"])
        XCTAssertEqual(groups.first?.files.map(\.path), ["README.md"])
    }

    func testNestedPathsAreOneLevelPerDistinctParentDirectory() {
        let groups = ChangedFileGroups.group(
            [
                file("Sources/PisakaCore/Deep/Z.swift"),
                file("Sources/PisakaCore/A.swift"),
                file("Sources/Pisaka/View.swift"),
                file("Sources/PisakaCore/B.swift"),
            ],
            rootName: "root"
        )
        // No intermediate `Sources` row: only directories that hold a file.
        XCTAssertEqual(
            groups.map(\.label),
            ["Sources/Pisaka", "Sources/PisakaCore", "Sources/PisakaCore/Deep"]
        )
        XCTAssertEqual(
            shape(groups)["Sources/PisakaCore"],
            ["Sources/PisakaCore/A.swift", "Sources/PisakaCore/B.swift"]
        )
    }

    func testFilesSortByNameNotByStatusOrInputOrder() {
        let groups = ChangedFileGroups.group(
            [file("d/zeta.swift", .added), file("d/Alpha.swift", .deleted), file("d/beta.swift")],
            rootName: "root"
        )
        XCTAssertEqual(groups.single?.files.map(\.path), ["d/Alpha.swift", "d/beta.swift", "d/zeta.swift"])
    }

    func testNumbersCompareNumerically() {
        let groups = ChangedFileGroups.group(
            [file("v10/a"), file("v2/a"), file("x/file10"), file("x/file2")],
            rootName: "root"
        )
        XCTAssertEqual(groups.map(\.label), ["v2", "v10", "x"])
        XCTAssertEqual(groups.last?.files.map(\.path), ["x/file2", "x/file10"])
    }

    func testARenameIsGroupedByItsNewPath() {
        let renamed = file("new/place/Moved.swift", .renamed, oldPath: "old/Moved.swift")
        let groups = ChangedFileGroups.group([renamed], rootName: "root")
        XCTAssertEqual(groups.map(\.label), ["new/place"])
        XCTAssertEqual(groups.single?.files, [renamed])
    }

    func testOrderingIsStableAcrossInputPermutations() {
        let files = [
            file("src/b.swift"), file("src/B.swift"), file("src/a.swift"),
            file("lib/x"), file("top.txt"), file("Lib/y"),
        ]
        let expected = ChangedFileGroups.group(files, rootName: "root")
        XCTAssertEqual(expected.map(\.label), ["root", "Lib", "lib", "src"])
        // Names equal but for case are ordered by the exact path, so the result
        // does not depend on which arrived first.
        XCTAssertEqual(expected.last?.files.map(\.path), ["src/a.swift", "src/B.swift", "src/b.swift"])
        for permutation in [files.reversed(), files.shuffledDeterministically()] {
            XCTAssertEqual(ChangedFileGroups.group(Array(permutation), rootName: "root"), expected)
        }
    }

    // MARK: - Project folder below the repository root

    func testNestedProjectGroupsProjectRelativeAndOutsideFilesAfter() {
        // Project `repo/app`: files in `app/`, `app/Sources/`, `lib/` and at the
        // repository root.
        let files = [
            file("lib/util.swift"), file("README.md"),
            file("app/Sources/View.swift"), file("app/main.swift"),
        ]
        let groups = ChangedFileGroups.group(
            files, rootName: "app", projectPrefix: "app", repositoryName: "repo"
        )
        XCTAssertEqual(groups.map(\.label), ["app", "Sources", "repo", "repo/lib"])
        // Identity stays the repository-relative directory.
        XCTAssertEqual(groups.map(\.path), ["app", "app/Sources", "", "lib"])
        // Git paths are untouched.
        XCTAssertEqual(shape(groups)["Sources"], ["app/Sources/View.swift"])
        XCTAssertEqual(shape(groups)["repo"], ["README.md"])
    }

    func testOutsideGroupsSortAfterEveryProjectGroup() {
        let groups = ChangedFileGroups.group(
            [file("aaa/x"), file("app/zzz/y"), file("app2/z")],
            rootName: "app", projectPrefix: "app", repositoryName: "repo"
        )
        // `app2` shares a string prefix with `app` but is outside it.
        XCTAssertEqual(groups.map(\.label), ["zzz", "repo/aaa", "repo/app2"])
    }

    func testEmptyPrefixIsTheRepositoryRootCase() {
        let files = [file("b/x.swift"), file("README.md"), file("a/y.swift")]
        XCTAssertEqual(
            ChangedFileGroups.group(files, rootName: "pisaka", projectPrefix: ""),
            ChangedFileGroups.group(files, rootName: "pisaka")
        )
    }

    func testDisplayPathIsProjectRelativeInsideAndRepositoryRelativeOutside() {
        XCTAssertEqual(ChangedFileGroups.displayPath("app/Sources/V.swift", projectPrefix: "app"), "Sources/V.swift")
        XCTAssertEqual(ChangedFileGroups.displayPath("app/main.swift", projectPrefix: "app"), "main.swift")
        XCTAssertEqual(ChangedFileGroups.displayPath("lib/util.swift", projectPrefix: "app"), "lib/util.swift")
        XCTAssertEqual(ChangedFileGroups.displayPath("app2/z", projectPrefix: "app"), "app2/z")
        XCTAssertEqual(ChangedFileGroups.displayPath("a/b.swift", projectPrefix: ""), "a/b.swift")
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }

    /// A fixed reordering (odd indices, then even), so the test needs no seed.
    func shuffledDeterministically() -> [Element] {
        enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            + enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    }
}
