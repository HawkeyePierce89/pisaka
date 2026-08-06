import XCTest
@testable import PisakaCore

final class CanonicalPathTests: XCTestCase {

    // MARK: - canonical(_:)

    func testCanonicalStandardizesCurrentDirectoryComponent() {
        let url = URL(fileURLWithPath: "/a/./b")
        XCTAssertEqual(CanonicalPath.canonical(url).path, "/a/b")
    }

    func testCanonicalStandardizesParentDirectoryComponent() {
        let url = URL(fileURLWithPath: "/a/b/../c")
        XCTAssertEqual(CanonicalPath.canonical(url).path, "/a/c")
    }

    func testCanonicalIsIdempotent() {
        let url = URL(fileURLWithPath: "/a/b/../c/./d.txt")
        let once = CanonicalPath.canonical(url)
        XCTAssertEqual(CanonicalPath.canonical(once), once)
    }

    func testCanonicalResolvesSymlink() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("a.txt")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // The same file reached through the symlink canonicalizes to the same url.
        XCTAssertEqual(
            CanonicalPath.canonical(link.appendingPathComponent("a.txt")),
            CanonicalPath.canonical(file)
        )
    }

    // MARK: - relativeComponents(of:under:)

    func testRelativeComponentsOfNestedPathYieldsSuffix() {
        let components = URL(fileURLWithPath: "/p/root/src/a.swift").pathComponents
        let ancestor = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertEqual(
            CanonicalPath.relativeComponents(of: components, under: ancestor),
            ["src", "a.swift"]
        )
    }

    func testRelativeComponentsOfDirectChildYieldsSingleComponent() {
        let components = URL(fileURLWithPath: "/p/root/a.swift").pathComponents
        let ancestor = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertEqual(
            CanonicalPath.relativeComponents(of: components, under: ancestor),
            ["a.swift"]
        )
    }

    func testRelativeComponentsOfEqualPathsIsNilStrictlyUnder() {
        let components = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertNil(CanonicalPath.relativeComponents(of: components, under: components))
    }

    func testRelativeComponentsOfNonPrefixIsNil() {
        let components = URL(fileURLWithPath: "/p/other/a.swift").pathComponents
        let ancestor = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertNil(CanonicalPath.relativeComponents(of: components, under: ancestor))
    }

    func testRelativeComponentsRejectsSharedNamePrefixThatIsNotAComponentPrefix() {
        // "/p/rootx" starts with the string "/p/root" but is not under it.
        let components = URL(fileURLWithPath: "/p/rootx/a.swift").pathComponents
        let ancestor = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertNil(CanonicalPath.relativeComponents(of: components, under: ancestor))
    }

    func testRelativeComponentsOfShorterPathIsNil() {
        let components = URL(fileURLWithPath: "/p").pathComponents
        let ancestor = URL(fileURLWithPath: "/p/root").pathComponents
        XCTAssertNil(CanonicalPath.relativeComponents(of: components, under: ancestor))
    }

    func testRelativeComponentsUnderRootDirectory() {
        let components = URL(fileURLWithPath: "/a/b").pathComponents
        let ancestor = URL(fileURLWithPath: "/").pathComponents
        XCTAssertEqual(
            CanonicalPath.relativeComponents(of: components, under: ancestor),
            ["a", "b"]
        )
    }

    /// Empty-array boundaries: an empty ancestor is a prefix of everything (the
    /// whole path is "below" it), while two empty arrays are equal and so not
    /// *strictly* under one another.
    func testRelativeComponentsWithEmptyArrays() {
        XCTAssertEqual(CanonicalPath.relativeComponents(of: ["a", "b"], under: []), ["a", "b"])
        XCTAssertNil(CanonicalPath.relativeComponents(of: [], under: []))
        XCTAssertNil(CanonicalPath.relativeComponents(of: [], under: ["a"]))
    }

    // MARK: - the `/private` caveat: symmetric application is what makes it safe

    /// `canonical(_:)` uses `resolvingSymlinksInPath()`, which *strips* a
    /// `/private` prefix (`/private/tmp` → `/tmp`) rather than producing a true
    /// realpath. That is harmless precisely because both sides of every
    /// comparison go through the same transform: a temp-dir root and a file
    /// inside it still match through `relativeComponents`, whichever way each
    /// side happened to be spelled.
    func testCanonicalPrefixStrippingIsHarmlessBecauseItIsAppliedSymmetrically() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("src/a.swift")
        try Data().write(to: file)

        // One side spelled with the `/private` prefix, the other without — after
        // the same transform they agree.
        let privateRoot = URL(fileURLWithPath: "/private" + root.path)
        for rootSpelling in [root, privateRoot] {
            for fileSpelling in [file, URL(fileURLWithPath: "/private" + file.path)] {
                XCTAssertEqual(
                    CanonicalPath.relativeComponents(
                        of: CanonicalPath.canonical(fileSpelling).pathComponents,
                        under: CanonicalPath.canonical(rootSpelling).pathComponents
                    ),
                    ["src", "a.swift"],
                    "root \(rootSpelling.path) / file \(fileSpelling.path)"
                )
            }
        }
    }

    /// The same symmetry through a symlinked root: a root opened *through* a
    /// symlink and a file spelled canonically still match.
    func testCanonicalMatchesAcrossSymlinkedRootSpelling() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real")
        try fm.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        let file = real.appendingPathComponent("src/a.swift")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(
            CanonicalPath.relativeComponents(
                of: CanonicalPath.canonical(file).pathComponents,
                under: CanonicalPath.canonical(link).pathComponents
            ),
            ["src", "a.swift"]
        )
        XCTAssertEqual(
            CanonicalPath.relativeComponents(
                of: CanonicalPath.canonical(link.appendingPathComponent("src/a.swift")).pathComponents,
                under: CanonicalPath.canonical(real).pathComponents
            ),
            ["src", "a.swift"]
        )
    }
}
