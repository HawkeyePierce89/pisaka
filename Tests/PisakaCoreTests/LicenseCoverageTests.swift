import XCTest
@testable import PisakaCore

/// The "a license cannot be silently missing" guard.
///
/// `Resources/Licenses/` is copied into the app bundle as a *folder reference*,
/// so nothing in the build relates it to the dependency list: adding a package
/// to `project.yml` produces a green build, a shipping app, and an
/// Acknowledgements screen that quietly omits it. The obligation is legal rather
/// than functional, so no test that exercises the app would ever notice.
///
/// This suite closes that gap statically, in the `VendoredGrammarQueryTests`
/// style — reading the repository's own files through `#filePath` with
/// Foundation only, so it runs in `swift test` without an Xcode build — and
/// asserts the three things that make `licenses.json` the list of record:
///
///  * its id set is **exactly** the set of packages `project.yml` links (minus
///    the local `PisakaCore`) plus the documented transitive `tree-sitter` C
///    runtime, so a new dependency fails here until its license ships, and a
///    removed one fails until its text is dropped;
///  * every remote entry's `revision` equals that identity's `Package.resolved`
///    pin, so a text can never be quietly taken from upstream `HEAD` — the
///    shipped text must be the one that goes with the shipped code;
///  * every entry's `file` exists under `Resources/Licenses`, is non-empty, and
///    is the *only* thing in that directory besides the manifest, so a stale
///    text left behind after a dependency drop is caught too.
///
/// It also pins the two obligations that are specific rather than structural:
/// `libgit2`'s text must contain the `LINKING EXCEPTION` (that section, not the
/// GPLv2 text around it, is what permits linking into a closed-source app), and
/// every identity in `Package.resolved` must be either acknowledged or listed in
/// the manifest's `excluded` array with a reason.
final class LicenseCoverageTests: XCTestCase {
    /// Linked by the app but resolved *transitively* rather than declared in
    /// `project.yml`: `SwiftTreeSitter` depends on the `tree-sitter` C runtime
    /// and links it into the app, so it ships and must be acknowledged even
    /// though no `packages:` entry names it.
    private static let transitiveIdentities: Set<String> = ["tree-sitter"]

    /// The local package (`path: .`), which is this repository's own code.
    private static let localPackage = "PisakaCore"

    // MARK: - Coverage

    func testManifestCoversExactlyTheLinkedDependencies() throws {
        let manifest = try loadManifest()
        let project = try loadProjectDefinition()

        let expected = project.linkedPackages
            .subtracting([Self.localPackage])
            .union(Self.transitiveIdentities)

        XCTAssertEqual(Set(manifest.notices.map(\.id)), expected, """
            Resources/Licenses/licenses.json must list exactly the dependencies the app links. \
            Missing entries are unacknowledged licenses; extra ones acknowledge something that \
            no longer ships. Add or remove the entry *and* its text file under Resources/Licenses.
            """)
    }

    /// A package declared in `packages:` but never listed as a target dependency
    /// would be invisible to the check above — it ships nothing, but it also
    /// means the two lists have drifted apart.
    func testEveryDeclaredPackageIsLinked() throws {
        let project = try loadProjectDefinition()
        XCTAssertEqual(project.declaredPackages, project.linkedPackages, """
            Every package declared in project.yml's `packages:` block must appear in the Pisaka \
            target's `dependencies:` list (and vice versa) — otherwise the license coverage check \
            is measuring a different set than the one that ships.
            """)
        XCTAssertTrue(project.declaredPackages.contains(Self.localPackage),
                      "parsed no PisakaCore package out of project.yml — the parser is out of step")
    }

    /// Every identity SwiftPM resolved is either acknowledged or explicitly
    /// excluded with a reason. "No text ships for this" is indistinguishable
    /// from an oversight unless it is written down.
    func testEveryResolvedIdentityIsAcknowledgedOrExplicitlyExcluded() throws {
        let manifest = try loadManifest()
        let accountedFor = Set(manifest.notices.map { $0.id.lowercased() })
            .union(manifest.excluded.map { $0.id.lowercased() })

        for identity in try resolvedPins().keys.sorted() {
            XCTAssertTrue(accountedFor.contains(identity), """
                \(identity) is pinned in Package.resolved but is neither acknowledged in \
                licenses.json nor listed in its `excluded` array. If it is not linked into the \
                app, say so there with a reason; otherwise ship its license.
                """)
        }

        for exclusion in manifest.excluded {
            XCTAssertFalse(exclusion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "the \(exclusion.id) exclusion carries no reason")
        }
    }

    // MARK: - Provenance

    func testEveryRemoteEntryMatchesItsResolvedPin() throws {
        let pins = try resolvedPins()

        for notice in try loadManifest().notices where notice.origin.hasPrefix("https://") {
            let pin = try XCTUnwrap(pins[notice.id.lowercased()], """
                \(notice.id) has a remote origin but no Package.resolved pin under identity \
                “\(notice.id.lowercased())”.
                """)
            XCTAssertEqual(notice.revision, pin.revision, """
                \(notice.id)'s license text is recorded as coming from \(notice.revision), but the \
                app builds against \(pin.revision). Re-copy the text from the pinned checkout — a \
                text taken from upstream HEAD may not be the license the shipped code is under.
                """)
            if let version = notice.version {
                XCTAssertEqual(version, pin.version, "\(notice.id)'s version disagrees with its pin")
            }
            XCTAssertEqual(notice.origin, pin.location,
                           "\(notice.id)'s origin disagrees with the resolved location")
        }
    }

    func testEveryVendoredEntryNamesARealLicenseSource() throws {
        let vendored = try loadManifest().notices.filter { $0.origin.hasPrefix("Vendor/") }
        XCTAssertEqual(Set(vendored.map(\.id)), ["TreeSitterDotenv", "TreeSitterGitignore"],
                       "the vendored grammars are the only path dependencies the app links")

        for notice in vendored {
            let source = Self.repositoryRoot.appendingPathComponent(notice.origin)
                .appendingPathComponent("LICENSE")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), """
                \(notice.id) is acknowledged as vendored from \(notice.origin), but there is no \
                LICENSE there to have copied — the shipped text has no source in this repository.
                """)
            XCTAssertEqual(try text(atRepositoryPath: "Resources/Licenses/\(notice.file)"),
                           try String(contentsOf: source, encoding: .utf8), """
                           \(notice.file) is no longer byte-identical to \(notice.origin)/LICENSE.
                           """)
        }
    }

    // MARK: - The texts themselves

    func testEveryEntryShipsANonEmptyTextAndNothingElseDoes() throws {
        let manifest = try loadManifest()

        for notice in manifest.notices {
            let contents = try text(atRepositoryPath: "Resources/Licenses/\(notice.file)")
            XCTAssertFalse(contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(notice.file) is empty — it acknowledges nothing")
        }

        let directory = Self.repositoryRoot.appendingPathComponent("Resources/Licenses")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(Set(onDisk), Set(manifest.notices.map(\.file)), """
            Resources/Licenses holds a .txt no manifest entry names (a text left behind after a \
            dependency was dropped), or names one that is not there. The directory ships as a \
            folder reference, so whatever is in it is what the app carries.
            """)
    }

    /// The GPLv2 text alone would forbid what this app does. The exception is
    /// the whole reason libgit2 can be linked here, so a re-copy that grabbed
    /// only `COPYING`'s license body must fail.
    func testLibgit2TextCarriesTheLinkingException() throws {
        let contents = try text(atRepositoryPath: "Resources/Licenses/libgit2.txt")
        XCTAssertTrue(contents.contains("LINKING EXCEPTION"), """
            libgit2.txt must contain the LINKING EXCEPTION section of upstream's COPYING — that \
            section, not the GPLv2 text around it, is what permits linking libgit2 into this app.
            """)
        XCTAssertTrue(contents.contains("GNU GENERAL PUBLIC LICENSE"),
                      "libgit2.txt must also carry the GPLv2 text the exception applies to")
    }

    /// End to end over the real resources: what `LicenseCatalogLoader` will do at
    /// launch, minus the `Bundle`. A manifest that parses in this suite's own
    /// reader but not through `LicenseCatalog` would ship a blank screen.
    func testTheRepositoryManifestResolvesThroughTheCatalog() throws {
        let data = try Data(contentsOf: Self.licensesDirectory.appendingPathComponent("licenses.json"))
        let manifest = try LicenseCatalog.decode(manifest: data)

        var texts: [String: String] = [:]
        for notice in manifest.notices {
            texts[notice.file] = try text(atRepositoryPath: "Resources/Licenses/\(notice.file)")
        }

        let documents = try LicenseCatalog.resolve(manifest: data, texts: texts)
        XCTAssertEqual(documents.map(\.id), manifest.notices.map(\.id))
        XCTAssertTrue(documents.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: - Reading the repository

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let licensesDirectory = repositoryRoot.appendingPathComponent("Resources/Licenses")

    private func text(atRepositoryPath path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func loadManifest() throws -> LicenseManifest {
        let url = Self.licensesDirectory.appendingPathComponent("licenses.json")
        return try LicenseCatalog.decode(manifest: try Data(contentsOf: url))
    }

    private struct Pin {
        let revision: String
        let version: String?
        let location: String
    }

    /// The committed workspace pins, keyed by SwiftPM identity (lowercased).
    /// `DependencyPinTests` owns the *shape* of this file; here it is only the
    /// provenance record for the copied texts.
    private func resolvedPins() throws -> [String: Pin] {
        let url = Self.repositoryRoot.appendingPathComponent(
            "Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let raw = (object as? [String: Any])?["pins"] as? [[String: Any]] ?? []

        var pins: [String: Pin] = [:]
        for entry in raw {
            guard let identity = entry["identity"] as? String else { continue }
            let state = entry["state"] as? [String: Any] ?? [:]
            pins[identity] = Pin(revision: state["revision"] as? String ?? "",
                                 version: state["version"] as? String,
                                 location: entry["location"] as? String ?? "")
        }
        XCTAssertFalse(pins.isEmpty, "read no pins out of Package.resolved")
        return pins
    }

    private struct ProjectDefinition {
        /// The keys of `project.yml`'s top-level `packages:` block.
        let declaredPackages: Set<String>
        /// The `- package:` entries of the app target's `dependencies:` list.
        let linkedPackages: Set<String>
    }

    /// A deliberately tiny, shape-specific reader for the two `project.yml`
    /// lists this suite compares — Core links no YAML parser and must not start.
    /// It is not a YAML implementation: it recognises exactly the two forms the
    /// file uses (a two-space-indented `Name:` key inside `packages:`, and a
    /// `- package: Name` item after a `dependencies:` line), skipping comments.
    /// Both `testEveryDeclaredPackageIsLinked`'s assertions double as a check
    /// that it is still reading something — if the file's shape changes, the
    /// parser returns an empty or partial set and the suite fails rather than
    /// silently comparing nothing.
    private func loadProjectDefinition() throws -> ProjectDefinition {
        let source = try text(atRepositoryPath: "project.yml")

        var declared: Set<String> = []
        var linked: Set<String> = []
        var insidePackagesBlock = false

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // A non-indented key ends whatever block was open.
            if !line.hasPrefix(" ") {
                insidePackagesBlock = (trimmed == "packages:")
                continue
            }

            if insidePackagesBlock,
               line.hasPrefix("  "), !line.hasPrefix("   "),
               trimmed.hasSuffix(":") {
                declared.insert(String(trimmed.dropLast()))
            }

            if trimmed.hasPrefix("- package:") {
                linked.insert(trimmed.dropFirst("- package:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }

        XCTAssertFalse(declared.isEmpty, "parsed no packages out of project.yml")
        XCTAssertFalse(linked.isEmpty, "parsed no target dependencies out of project.yml")
        return ProjectDefinition(declaredPackages: declared, linkedPackages: linked)
    }
}
