import XCTest
@testable import PisakaCore

/// The layout is the only thing that knows what the store looks like, and three
/// separate things depend on its answers agreeing: the store engine (which
/// writes, lists and prunes), the browser model (which reads a revision back out
/// of a name it was handed) and the de-provisioning instruction in the docs
/// (which tells a user to delete one directory). The name grammar is the load
/// bearing part — a listing reads *no* content, so a name that no longer parses
/// is a revision that has silently ceased to exist.
final class LocalHistoryLayoutTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Pisaka/LocalHistory")
    private var layout: LocalHistoryLayout { LocalHistoryLayout(base: base) }
    private let root = URL(fileURLWithPath: "/Users/someone/git/pisaka")

    // MARK: - The base

    func testTheBaseIsNormalisedLexicallyAndTwoSpellingsCompareEqual() {
        let noisy = URL(fileURLWithPath: "/Users/someone/git/../Library/./Application Support/Pisaka/LocalHistory")
        XCTAssertEqual(LocalHistoryLayout(base: noisy), layout)
        XCTAssertEqual(LocalHistoryLayout(base: noisy).base.path, base.path)
    }

    func testTheDirectoryNameIsTheOnePlaceItIsSpelled() {
        XCTAssertEqual(LocalHistoryLayout.directoryName, "LocalHistory")
        XCTAssertEqual(base.lastPathComponent, LocalHistoryLayout.directoryName)
    }

    // MARK: - Directories

    func testAProjectDirectoryIsTheRootsNameAndItsDigest() {
        let directory = layout.projectDirectory(forRoot: root)
        XCTAssertEqual(directory.deletingLastPathComponent().path, base.path)

        let name = directory.lastPathComponent
        XCTAssertTrue(name.hasPrefix("pisaka-"), name)
        let digest = String(name.dropFirst("pisaka-".count))
        XCTAssertEqual(digest.count, LocalHistoryLayout.projectHashLength)
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
        XCTAssertEqual(digest, digest.lowercased())
    }

    func testTheSameInputsGiveTheSameDirectoryEveryTime() {
        XCTAssertEqual(layout.projectDirectory(forRoot: root), layout.projectDirectory(forRoot: root))
        XCTAssertEqual(
            layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift"),
            layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift")
        )
    }

    func testTwoRootsGetTwoAreasEvenWhenTheyShareAName() {
        let other = URL(fileURLWithPath: "/Users/someone/work/pisaka")
        XCTAssertNotEqual(layout.projectDirectory(forRoot: root), layout.projectDirectory(forRoot: other))
        XCTAssertNotEqual(
            layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift"),
            layout.fileDirectory(forRoot: other, relativePath: "Sources/a.swift")
        )
    }

    func testTwoRelativePathsGetTwoDirectoriesInsideOneProjectArea() {
        let first = layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift")
        let second = layout.fileDirectory(forRoot: root, relativePath: "Sources/b.swift")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent(), layout.projectDirectory(forRoot: root))
        XCTAssertEqual(second.deletingLastPathComponent(), layout.projectDirectory(forRoot: root))
    }

    /// Two files whose names differ only in case are two files on a case-sensitive
    /// volume, and the digest keeps them apart on any volume.
    func testCaseIsPartOfAFilesIdentity() {
        XCTAssertNotEqual(
            layout.fileDirectory(forRoot: root, relativePath: "Sources/A.swift"),
            layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift")
        )
    }

    func testAFileDirectoryIsAFlatFixedWidthDigest() {
        let name = layout.fileDirectory(forRoot: root, relativePath: "a/very/deeply/nested/path/to/file.swift").lastPathComponent
        XCTAssertEqual(name.count, LocalHistoryLayout.fileHashLength)
        XCTAssertTrue(name.allSatisfy(\.isHexDigit))
        XCTAssertFalse(name.contains("/"))
    }

    /// The same normalisation the roots get, so one file cannot grow two
    /// histories because two callers spelled its relative path differently.
    func testARelativePathIsNormalisedLexically() {
        let plain = layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift")
        XCTAssertEqual(layout.fileDirectory(forRoot: root, relativePath: "./Sources/a.swift"), plain)
        XCTAssertEqual(layout.fileDirectory(forRoot: root, relativePath: "Sources/./a.swift"), plain)
        XCTAssertEqual(layout.fileDirectory(forRoot: root, relativePath: "Sources//a.swift"), plain)
        XCTAssertEqual(layout.fileDirectory(forRoot: root, relativePath: "Tests/../Sources/a.swift"), plain)
    }

    func testARootWithATrailingSlashOrNoiseIsTheSameRoot() {
        XCTAssertEqual(
            layout.projectDirectory(forRoot: URL(fileURLWithPath: "/Users/someone/git/pisaka/")),
            layout.projectDirectory(forRoot: root)
        )
        XCTAssertEqual(
            layout.projectDirectory(forRoot: URL(fileURLWithPath: "/Users/someone/git/other/../pisaka")),
            layout.projectDirectory(forRoot: root)
        )
    }

    /// A file name is bounded; a project directory's name is not allowed to be.
    func testALongOrSeparatorBearingRootNameStillMakesOneLegalComponent() {
        let long = URL(fileURLWithPath: "/Users/someone/" + String(repeating: "x", count: 400))
        let name = layout.projectDirectory(forRoot: long).lastPathComponent
        XCTAssertLessThanOrEqual(name.utf8.count, 64 + 1 + LocalHistoryLayout.projectHashLength)
        XCTAssertFalse(name.contains("/"))

        let colon = URL(fileURLWithPath: "/Users/someone/a:b")
        XCTAssertTrue(layout.projectDirectory(forRoot: colon).lastPathComponent.hasPrefix("a_b-"))
    }

    /// The bound is measured in the unit the file system measures it in. Sixty-four
    /// emoji are 64 `Character`s and 256 bytes: truncating by character would name
    /// a directory `ensureDirectory` cannot create, and a project whose directory
    /// cannot be created has no history at all — silently, since every failure in
    /// this feature is.
    func testTheReadableProjectNameIsTruncatedByBytesRatherThanByCharacters() {
        for name in [String(repeating: "🌍", count: 80), String(repeating: "👩‍👩‍👧‍👦", count: 40)] {
            let component = layout
                .projectDirectory(forRoot: URL(fileURLWithPath: "/Users/someone/" + name))
                .lastPathComponent
            XCTAssertLessThanOrEqual(
                component.utf8.count,
                64 + 1 + LocalHistoryLayout.projectHashLength,
                component
            )
            // Still a *readable* hint: whole characters, never a name cut
            // mid-scalar.
            XCTAssertTrue(component.hasPrefix("🌍") || component.hasPrefix("👩‍👩‍👧‍👦"), component)
            XCTAssertEqual(
                component.split(separator: "-").last?.count,
                LocalHistoryLayout.projectHashLength,
                "the digest after the hint is what identifies the project: \(component)"
            )
        }
    }

    func testTheFilesystemRootStillNamesADirectory() {
        let name = layout.projectDirectory(forRoot: URL(fileURLWithPath: "/")).lastPathComponent
        XCTAssertTrue(name.hasPrefix("project-"), name)
        XCTAssertEqual(name.count, "project-".count + LocalHistoryLayout.projectHashLength)
    }

    // MARK: - Containment

    func testContainsAcceptsEverythingTheLayoutProduces() {
        let project = layout.projectDirectory(forRoot: root)
        let file = layout.fileDirectory(forRoot: root, relativePath: "Sources/a.swift")
        let snapshot = file.appendingPathComponent(
            LocalHistoryLayout.snapshotFileName(
                timestamp: Date(timeIntervalSince1970: 1_772_345_678.901),
                event: .save,
                contentHash: LocalHistoryLayout.contentHash(of: "hello")
            ),
            isDirectory: false
        )

        XCTAssertTrue(layout.contains(layout.base))
        XCTAssertTrue(layout.contains(project))
        XCTAssertTrue(layout.contains(file))
        XCTAssertTrue(layout.contains(snapshot))
    }

    func testContainsRefusesAnythingOutsideTheStore() {
        XCTAssertFalse(layout.contains(root))
        XCTAssertFalse(layout.contains(base.deletingLastPathComponent()))
        XCTAssertFalse(layout.contains(URL(fileURLWithPath: base.path + "Extra/x.snapshot")))
    }

    // MARK: - The content hash

    func testTheContentHashIsSixteenLowercaseHexCharactersOfTheUTF8Digest() {
        let hash = LocalHistoryLayout.contentHash(of: "let x = 1\n")
        XCTAssertEqual(hash.count, LocalHistoryLayout.contentHashLength)
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertEqual(hash, String(SHA256.hexadecimalDigest(of: Data("let x = 1\n".utf8)).prefix(16)))
    }

    func testOneChangedByteChangesTheHashAndIdenticalTextDoesNot() {
        XCTAssertEqual(LocalHistoryLayout.contentHash(of: "abc"), LocalHistoryLayout.contentHash(of: "abc"))
        XCTAssertNotEqual(LocalHistoryLayout.contentHash(of: "abc"), LocalHistoryLayout.contentHash(of: "abd"))
        XCTAssertNotEqual(LocalHistoryLayout.contentHash(of: ""), LocalHistoryLayout.contentHash(of: "\n"))
    }

    // MARK: - Snapshot names

    func testANameRoundTripsForEveryEvent() {
        let timestamp = Date(timeIntervalSince1970: 1_772_345_678.901)
        let hash = LocalHistoryLayout.contentHash(of: "content")

        for event in LocalHistoryEvent.allCases {
            let name = LocalHistoryLayout.snapshotFileName(timestamp: timestamp, event: event, contentHash: hash)
            let parsed = LocalHistoryLayout.snapshot(fromFileName: name)
            XCTAssertEqual(parsed?.fileName, name)
            XCTAssertEqual(parsed?.event, event)
            XCTAssertEqual(parsed?.contentHash, hash)
            XCTAssertEqual(parsed?.timestamp.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 0.0005)
        }
    }

    func testANameIsTheDocumentedShape() {
        let name = LocalHistoryLayout.snapshotFileName(
            timestamp: Date(timeIntervalSince1970: 1_772_345_678.901),
            event: .save,
            contentHash: "0123456789abcdef"
        )
        XCTAssertEqual(name, "0000001772345678901-save-0123456789abcdef.snapshot")
        XCTAssertEqual(name.split(separator: ".").first?.split(separator: "-").first?.count, LocalHistoryLayout.timestampDigits)
    }

    /// Nineteen zero-padded digits is what makes a directory listing sortable
    /// without parsing, which is what retention and dedup rely on.
    func testLexicalNameOrderIsChronologicalOrderAcrossEveryBoundary() {
        // A millisecond, a second and a day boundary, plus the decimal carries a
        // narrower field would break on (999 → 1000, 9999 → 10000).
        let seconds: [Double] = [
            0,
            0.001,
            0.999,
            1,
            1.001,
            9.999,
            10,
            1_772_345_678.901,
            1_772_345_678.902,
            1_772_345_679,
            1_772_345_699.999,
            1_772_345_700,
            1_772_388_000,
            1_772_474_400,
        ]
        let names = seconds.map { second in
            LocalHistoryLayout.snapshotFileName(
                timestamp: Date(timeIntervalSince1970: second),
                event: .save,
                contentHash: "0123456789abcdef"
            )
        }

        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(Set(names).count, names.count)

        let parsed = names.compactMap(LocalHistoryLayout.snapshot(fromFileName:))
        XCTAssertEqual(parsed.count, names.count)
        XCTAssertEqual(
            LocalHistorySnapshot.sortedNewestFirst(parsed).map(\.fileName),
            names.reversed().map { $0 }
        )
    }

    /// Unreachable — a snapshot is stamped when it is taken — but the clamp keeps
    /// the "every name is 19 digits" invariant total rather than nearly total.
    func testAPre1970TimestampClampsRatherThanEmittingAMinusSign() {
        let name = LocalHistoryLayout.snapshotFileName(
            timestamp: Date(timeIntervalSince1970: -5),
            event: .save,
            contentHash: "0123456789abcdef"
        )
        XCTAssertEqual(name, "0000000000000000000-save-0123456789abcdef.snapshot")
        XCTAssertEqual(LocalHistoryLayout.snapshot(fromFileName: name)?.timestamp, Date(timeIntervalSince1970: 0))
    }

    // MARK: - Malformed names

    func testAMalformedNameParsesToNilRatherThanAPartialSnapshot() {
        let malformed = [
            "",
            "0000001772345678901-save-0123456789abcdef",           // no extension
            "0000001772345678901-save-0123456789abcdef.snap",      // wrong extension
            "0000001772345678901-save-0123456789abcdef.snapshot.bak",
            "0000001772345678901-save.snapshot",                   // two fields
            "0000001772345678901-save-0123456789abcdef-2.snapshot", // four fields
            "0123456789abcdef.snapshot",                           // one field
            "000000177234567890a-save-0123456789abcdef.snapshot",  // non-numeric millis
            "177234567890-save-0123456789abcdef.snapshot",         // too few digits
            "00000001772345678901-save-0123456789abcdef.snapshot",  // too many digits
            "                   -save-0123456789abcdef.snapshot",  // right width, not digits
            "0000001772345678901-rebase-0123456789abcdef.snapshot", // unknown tag
            "0000001772345678901-Save-0123456789abcdef.snapshot",   // tags are lowercase
            "0000001772345678901--0123456789abcdef.snapshot",       // empty tag
            "0000001772345678901-save-0123456789abcde.snapshot",    // hash too short
            "0000001772345678901-save-0123456789abcdef0.snapshot",  // hash too long
            "0000001772345678901-save-0123456789ABCDEF.snapshot",   // hash not lowercase
            "0000001772345678901-save-0123456789abcdeg.snapshot",   // hash not hex
            "nested/0000001772345678901-save-0123456789abcdef.snapshot",
            ".snapshot",
            ".DS_Store",
        ]

        for name in malformed {
            XCTAssertNil(LocalHistoryLayout.snapshot(fromFileName: name), "parsed \(name)")
        }
    }

    /// An arabic-numeral look-alike is not an ASCII digit; `Int64` would happily
    /// take some of them, so the width check alone is not the gate.
    func testANonASCIIDigitIsNotADigit() {
        let name = "000000177234567890١-save-0123456789abcdef.snapshot"
        XCTAssertNil(LocalHistoryLayout.snapshot(fromFileName: name))
    }
}
