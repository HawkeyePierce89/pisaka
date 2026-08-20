import XCTest
@testable import PisakaCore

/// The project tree's drag-and-drop rule.
///
/// Two halves, asserted separately: the disk-free `structuralDecision` (identity,
/// ancestry, the drop-onto-current-parent no-op — the drag *hover* question) and
/// the full `decision`, which adds the collision and existence facts that need a
/// listing (the *drop* question).
///
/// The canonical cases use real temporary directories and real symlinks rather
/// than the in-memory tree: `StubFileTree` compares root-relative strings and
/// resolves nothing, so a symlink or a `/private` spelling it cannot represent is
/// exactly what the canonical rules exist for.
final class MoveDropRuleTests: XCTestCase {

    // MARK: - Temp-directory helper

    /// A fresh temporary directory, removed when the test ends.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Destination shape

    func testDestinationKeepsTheSourceNameAndTheTargetSpelling() {
        let source = URL(fileURLWithPath: "/project/src/a.swift")
        let folder = URL(fileURLWithPath: "/project/lib")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: source, into: folder),
            .move(destination: URL(fileURLWithPath: "/project/lib/a.swift"))
        )
    }

    func testDestinationOfAFolderKeepsItsName() {
        let source = URL(fileURLWithPath: "/project/src/models")
        let folder = URL(fileURLWithPath: "/project/lib")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: source, into: folder),
            .move(destination: URL(fileURLWithPath: "/project/lib/models"))
        )
    }

    func testDestinationIsSpelledFromTheTargetNotItsCanonicalForm() throws {
        // The project's path rule: store what the user spelled, compare
        // canonically. A `/private`-spelled target must yield a
        // `/private`-spelled destination, not the resolved one.
        let dir = try makeTempDirectory()
        let source = dir.appendingPathComponent("src/a.swift")
        let privateFolder = URL(fileURLWithPath: "/private" + dir.path)
            .appendingPathComponent("lib")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: source, into: privateFolder),
            .move(destination: privateFolder.appendingPathComponent("a.swift"))
        )
    }

    // MARK: - The no-op

    func testDropOntoTheCurrentParentIsTheSilentNoOp() {
        let source = URL(fileURLWithPath: "/project/src/a.swift")
        let folder = URL(fileURLWithPath: "/project/src")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: source, into: folder),
            .refuse(.unchangedLocation)
        )
        XCTAssertTrue(MoveDropRefusal.unchangedLocation.isSilent)
    }

    func testEveryRefusalExceptTheNoOpIsReported() {
        let reported: [MoveDropRefusal] = [
            .ontoItself,
            .intoOwnDescendant,
            .nameTaken(name: "a.swift", folder: "lib"),
            .sourceMissing(name: "a.swift"),
            .targetMissing(name: "lib"),
        ]
        for refusal in reported {
            XCTAssertFalse(refusal.isSilent, "\(refusal)")
            // Every reported refusal has to carry text: it reaches the user
            // through `NSAlert(error:)`, whose fallback wording is useless.
            XCTAssertNotNil(refusal.errorDescription, "\(refusal)")
        }
    }

    func testCollisionMessageNamesBothTheEntryAndTheFolder() {
        let text = MoveDropRefusal.nameTaken(name: "a.swift", folder: "lib").errorDescription
        XCTAssertEqual(text, "\"a.swift\" already exists in \"lib\".")
    }

    // MARK: - Self and descendants

    func testDropOntoItselfIsRefused() {
        let folder = URL(fileURLWithPath: "/project/src")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: folder, into: folder),
            .refuse(.ontoItself)
        )
    }

    func testDropIntoAnImmediateChildIsRefused() {
        XCTAssertEqual(
            MoveDropRule.structuralDecision(
                source: URL(fileURLWithPath: "/project/src"),
                into: URL(fileURLWithPath: "/project/src/models")
            ),
            .refuse(.intoOwnDescendant)
        )
    }

    func testDropIntoADeepDescendantIsRefused() {
        XCTAssertEqual(
            MoveDropRule.structuralDecision(
                source: URL(fileURLWithPath: "/project/src"),
                into: URL(fileURLWithPath: "/project/src/models/nested/deeper")
            ),
            .refuse(.intoOwnDescendant)
        )
    }

    func testASiblingWithASharedNamePrefixIsNotADescendant() {
        // Whole-component matching: `/project/srcx` is not inside `/project/src`,
        // which a raw string prefix check would get wrong.
        XCTAssertEqual(
            MoveDropRule.structuralDecision(
                source: URL(fileURLWithPath: "/project/src"),
                into: URL(fileURLWithPath: "/project/srcx")
            ),
            .move(destination: URL(fileURLWithPath: "/project/srcx/src"))
        )
    }

    // MARK: - Canonical spellings

    func testTheSameFolderSpelledThroughPrivateIsRefusedAsItself() throws {
        let dir = try makeTempDirectory()
        let folder = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let privateSpelling = URL(fileURLWithPath: "/private" + folder.path)

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: folder, into: privateSpelling),
            .refuse(.ontoItself)
        )
        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: privateSpelling, into: folder),
            .refuse(.ontoItself)
        )
    }

    func testNavigationComponentsAndTrailingSlashesStillCompareEqual() {
        let folder = URL(fileURLWithPath: "/project/src")
        let awkward = URL(fileURLWithPath: "/project/./lib/../src/")

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: folder, into: awkward),
            .refuse(.ontoItself)
        )
    }

    func testASymlinkOntoItsOwnReferentIsRefusedAsItself() throws {
        // The conservative symlink rule: the row *is* a link to the destination,
        // so canonically the two are the same folder and the drag is refused
        // rather than carried out under a reading the user may not share.
        let dir = try makeTempDirectory()
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: link, into: real),
            .refuse(.ontoItself)
        )
        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: real, into: link),
            .refuse(.ontoItself)
        )
    }

    func testTheCurrentParentReachedThroughASymlinkIsStillTheNoOp() throws {
        let dir = try makeTempDirectory()
        let parent = dir.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let child = parent.appendingPathComponent("child.txt")
        try "x".write(to: child, atomically: true, encoding: .utf8)
        let parentLink = dir.appendingPathComponent("plink")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parent)

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: child, into: parentLink),
            .refuse(.unchangedLocation)
        )
    }

    func testADescendantReachedThroughASymlinkIsStillRefused() throws {
        let dir = try makeTempDirectory()
        let top = dir.appendingPathComponent("top")
        let sub = top.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let topLink = dir.appendingPathComponent("tlink")
        try FileManager.default.createSymbolicLink(at: topLink, withDestinationURL: top)

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: top, into: topLink.appendingPathComponent("sub")),
            .refuse(.intoOwnDescendant)
        )
    }

    func testASymlinkEntryMayMoveBesideItsReferent() throws {
        // The counterpart of the conservative rule: the link *entry* lives in the
        // directory that holds it, so dropping it into the referent's parent is a
        // genuine move, not the no-op.
        let dir = try makeTempDirectory()
        let here = dir.appendingPathComponent("here")
        let there = dir.appendingPathComponent("there")
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        let target = there.appendingPathComponent("real.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let link = here.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(
            MoveDropRule.structuralDecision(source: link, into: there),
            .move(destination: there.appendingPathComponent("link.txt"))
        )
    }

    // MARK: - The disk half

    private func makeTree(_ files: [String: String]) -> StubFileTree {
        StubFileTree(root: URL(fileURLWithPath: "/project"), files: files)
    }

    func testAFileDroppedIntoAnUnrelatedFolderMoves() {
        let tree = makeTree(["src/a.swift": "", "lib/b.swift": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .move(destination: tree.url("lib/a.swift"))
        )
    }

    func testTheSameNameUnderTheSourcesOwnParentIsNotACollision() {
        // The collision question is about the *destination's* listing only: the
        // source's own directory of course holds the name, and a check that
        // scanned anywhere else would refuse every drag.
        let tree = makeTree(["src/a.swift": "", "src/other.swift": "", "lib/b.swift": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .move(destination: tree.url("lib/a.swift"))
        )
    }

    func testAnExistingNameInTheDestinationIsRefused() {
        let tree = makeTree(["src/a.swift": "", "lib/a.swift": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .refuse(.nameTaken(name: "a.swift", folder: "lib"))
        )
    }

    func testAFolderCollidingWithAFileOfTheSameNameIsRefused() {
        let tree = makeTree(["src/models/m.swift": "", "lib/models": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/models"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .refuse(.nameTaken(name: "models", folder: "lib"))
        )
    }

    func testAVanishedSourceIsRefused() {
        let tree = makeTree(["src/a.swift": "", "lib/b.swift": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/gone.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .refuse(.sourceMissing(name: "gone.swift"))
        )
    }

    func testAnUnlistableSourceParentIsRefusedAsAVanishedSource() {
        let tree = makeTree(["src/a.swift": "", "lib/b.swift": ""])
        tree.unreadableDirectories.insert("src")

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .refuse(.sourceMissing(name: "a.swift"))
        )
    }

    func testAnUnlistableDestinationIsRefused() {
        let tree = makeTree(["src/a.swift": "", "lib/b.swift": ""])
        tree.unreadableDirectories.insert("lib")

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("lib"),
                fileService: tree
            ),
            .refuse(.targetMissing(name: "lib"))
        )
    }

    func testTheStructuralRulesRunBeforeAnyListing() {
        // A refusal the paths alone can reach must not depend on the disk — the
        // hover half answers the same way with no file service at all.
        let tree = makeTree(["src/a.swift": ""])

        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src/a.swift"),
                into: tree.url("src"),
                fileService: tree
            ),
            .refuse(.unchangedLocation)
        )
        XCTAssertEqual(
            MoveDropRule.decision(
                source: tree.url("src"),
                into: tree.url("src/nested"),
                fileService: tree
            ),
            .refuse(.intoOwnDescendant)
        )
    }

    func testTheFullDecisionAgreesWithTheStructuralOneWhenTheDiskIsClear() {
        let tree = makeTree(["src/a.swift": "", "lib/b.swift": ""])
        let source = tree.url("src/a.swift")
        let folder = tree.url("lib")

        XCTAssertEqual(
            MoveDropRule.decision(source: source, into: folder, fileService: tree),
            MoveDropRule.structuralDecision(source: source, into: folder)
        )
    }
}
