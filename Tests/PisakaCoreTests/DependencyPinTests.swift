import XCTest
@testable import PisakaCore

/// Static verification of the committed workspace `Package.resolved` — the file
/// that actually decides which bytes of every dependency a release build links.
///
/// `project.yml` states each dependency's *requirement*; `Package.resolved`
/// records the *pin* SwiftPM resolved it to, and only the pin is reproducible.
/// The distinction matters for exactly two packages, and for the same structural
/// reason both times: **another package's own manifest asked for something by
/// branch**, so the requirement that reaches this project is a branch and the
/// recorded revision is the whole pin. Every other dependency carries an
/// `exactVersion:`/`revision:` requirement, so its pin cannot move without a
/// visible `project.yml` change.
///
/// The two, each with its own reason, are `branchPinnedDependencies` below:
///
///  * `swifttreesitter` — required `branch: main` because *Neon's own manifest*
///    requires it that way (the pinned Neon revision 484d6fb declares
///    `.package(url: …/SwiftTreeSitter, branch: "main")`, and SwiftPM refuses a
///    package "required using two different revision-based requirements", so a
///    root `revision:` makes `xcodebuild -resolvePackageDependencies` fail
///    outright — see the comment on that entry in `project.yml`).
///  * `swift-cmark` — never declared in `project.yml` at all: it arrives
///    transitively, and *swift-markdown's own manifest* asks for it as
///    `.package(url: …/swift-cmark.git, branch: "release/6.2")`. A frozen release
///    branch rather than a moving `main`, which makes a drift slower but not
///    impossible, and there is no `project.yml` line that would show one.
///
/// For both, the committed revision in this file is the *whole* pin, and nothing
/// in the requirement would flag a drift. A **third** branch pin is not a third
/// instance of the same argument — it is a dependency that stopped being
/// reproducible without anyone saying so, so it fails the suite until it is
/// added here with a reason of its own.
///
/// So this suite reads the resolved file itself, in the
/// `VendoredGrammarQueryTests` style (through `#filePath`, Foundation only), and
/// asserts:
///
///  * the file is still SwiftPM's v2 schema (`version == 2`, `identity`/`kind`/
///    `location` per pin) — the shape `xcodebuild -resolvePackageDependencies`
///    and CI produce, so a rewrite into the legacy v1 shape is caught as the
///    format churn it is rather than reviewed as a pin change;
///  * every pin resolves to a non-empty 40-hex revision, so no dependency is
///    left floating;
///  * the branch-based pins are exactly the documented two — a third one creeping
///    in means another dependency became unpinnable without anyone saying so;
///  * each of those two is pinned to exactly the revision that has been building
///    and testing all along, so an unnoticed jump to a newer branch head fails
///    here.
///
/// A practical note on producing that v2 file, learned while adding the Sparkle
/// pin: which schema `xcodebuild -resolvePackageDependencies` *writes* depends on
/// the local Xcode. CI's (16.4) writes v2; Xcode 26.x rewrites the whole file
/// into the legacy v1 shape (`object.pins`/`repositoryURL`) whenever resolution
/// actually has to change something — a fresh clone or a dropped
/// `DerivedData/…/SourcePackages` then produces a 358-line diff in which the one
/// real pin change is invisible. It leaves an already-correct v2 file alone, so
/// this is only a hazard on the commit that adds or bumps a dependency. When it
/// happens, keep the resolved *values* (they are the real resolution) and
/// re-emit them in the v2 shape rather than committing the churn or hand-typing
/// a revision — the assertions below are what catch getting either half wrong.
final class DependencyPinTests: XCTestCase {
    /// A dependency whose *requirement* is a branch, so its recorded revision is
    /// the whole pin: the revision the project builds against, and the reason
    /// there is no version or revision requirement holding it still instead.
    private struct BranchPin {
        let revision: String
        let reason: String
    }

    /// The packages allowed to be pinned by branch, keyed by SwiftPM identity.
    ///
    /// Both entries exist because *another package's manifest* asked for them by
    /// branch (see the type doc); neither is a choice made in `project.yml`.
    /// Updating a revision here is a deliberate act — change the constant in the
    /// same commit that changes `Package.resolved`. Adding a *third* entry is a
    /// bigger act than that: it says a third dependency has become unpinnable,
    /// which needs its own reason written down rather than a line appended.
    private static let branchPinnedDependencies: [String: BranchPin] = [
        "swifttreesitter": BranchPin(
            revision: "0f40435cdb41673ce4194d731571cf2a2f7c3285",
            reason: """
                required `branch: main` by Neon's own manifest at the pinned Neon revision; this \
                revision is 3 commits past upstream tag 0.10.0 and is what has been building all along
                """
        ),
        "swift-cmark": BranchPin(
            revision: "5d9bdaa4228b381639fff09403e39a04926e2dbe",
            reason: """
                pulled in transitively by swift-markdown, whose manifest requires it as \
                `branch: "release/6.2"`; nothing in project.yml declares it, so this revision is the \
                only record of which cmark the app compiles
                """
        ),
    ]

    func testResolvedFileUsesTheV2Schema() throws {
        let resolved = try loadResolved()
        XCTAssertEqual(resolved.version, 2,
                       "Package.resolved must stay in SwiftPM's v2 schema — the form xcodebuild and CI write")
        XCTAssertFalse(resolved.pins.isEmpty, "Package.resolved records no pins at all")
        for pin in resolved.pins {
            XCTAssertFalse(pin.identity.isEmpty, "a pin has no identity")
            XCTAssertEqual(pin.kind, "remoteSourceControl",
                           "unexpected pin kind for \(pin.identity)")
            XCTAssertFalse(pin.location.isEmpty, "pin \(pin.identity) has no location")
        }
    }

    func testEveryPinRecordsANonEmptyRevision() throws {
        for pin in try loadResolved().pins {
            let revision = pin.revision ?? ""
            XCTAssertFalse(revision.isEmpty, "pin \(pin.identity) records no revision")
            XCTAssertEqual(revision.count, 40,
                           "pin \(pin.identity) revision is not a full commit hash: \(revision)")
            XCTAssertTrue(revision.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                          "pin \(pin.identity) revision is not lowercase hex: \(revision)")
        }
    }

    func testTheDocumentedPairAreTheOnlyBranchPinnedDependencies() throws {
        let branched = try loadResolved().pins
            .filter { $0.branch != nil }
            .map(\.identity)
            .sorted()
        XCTAssertEqual(branched, Self.branchPinnedDependencies.keys.sorted(),
                       """
                       Exactly \(Self.branchPinnedDependencies.keys.sorted().joined(separator: ", ")) may \
                       be pinned by branch, and each only because another package's own manifest requires \
                       it that way. A new branch-based pin means a dependency stopped being reproducible — \
                       pin it in project.yml, or add it to branchPinnedDependencies with its own reason.
                       """)
    }

    func testEveryBranchPinnedDependencyIsPinnedToTheExpectedRevision() throws {
        let pins = try loadResolved().pins
        for (identity, expected) in Self.branchPinnedDependencies {
            let pin = try XCTUnwrap(pins.first { $0.identity == identity },
                                    "no \(identity) pin in Package.resolved")
            XCTAssertEqual(pin.revision, expected.revision,
                           """
                           \(identity) moved off the revision this project builds against — it is \
                           \(expected.reason). A branch requirement means this revision is the only thing \
                           holding it still. If the move is intentional, update this constant too.
                           """)
        }
    }

    /// The pin and the *requirement* must agree.
    ///
    /// Everything above reads `Package.resolved` alone, and everything in
    /// `LicenseCoverageTests` compares the license manifest against that same
    /// file — so the two documents that decide what ships (`project.yml`'s
    /// requirements and the resolved pins) are never compared with each other.
    /// That leaves a green-tests path to shipping the wrong bytes: bump
    /// `SwiftTerm` to `exactVersion: "1.6.0"` in `project.yml` and commit
    /// without the regenerated `Package.resolved` — an easy omission, since the
    /// re-resolve happens as a side effect of a build rather than as an explicit
    /// step. `swift test` stays green (both suites compare against the stale
    /// pin, which still agrees with the stale `licenses.json` entry) and CI
    /// stays green (`xcodebuild` simply resolves 1.6.0 in the runner), while the
    /// shipped app links a version whose license text and recorded revision come
    /// from a different commit — the exact failure
    /// `testEveryRemoteEntryMatchesItsResolvedPin` exists to prevent.
    ///
    /// So assert, per remote package, that the requirement `project.yml` states
    /// is the one `Package.resolved` recorded. `SwiftTreeSitter` is the
    /// documented exception in both directions: its requirement *is* a branch
    /// (Neon's manifest, see the type doc), so the branch name is what must
    /// match and the revision is pinned by
    /// `testSwiftTreeSitterIsPinnedToTheExpectedRevision` instead.
    func testEveryProjectRequirementMatchesItsResolvedPin() throws {
        // Keyed by location, tolerating a duplicate rather than trapping on one:
        // `Dictionary(uniqueKeysWithValues:)` would abort the whole process on two
        // pins sharing a location (the same repository resolved under two
        // identities, or a `.git`-suffix/case variant), and an anomaly in
        // `Package.resolved` is precisely what this suite exists to *report*.
        let entries = try loadResolved().pins
        let pins = Dictionary(entries.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(pins.count, entries.count, """
            Package.resolved records two pins for the same location. Re-resolve: the duplicate is \
            either the same repository resolved under two identities or a URL that differs only by \
            case or a .git suffix, and the checks below would silently validate just one of them.
            """)
        let packages = try loadDeclaredPackages()

        for package in packages {
            guard let url = package.url else { continue }  // a Vendor/ path dependency
            let pin = try XCTUnwrap(pins[url], """
                project.yml declares \(package.name) at \(url), but Package.resolved records no \
                pin for that location. Either the URL moved without a re-resolve, or the \
                dependency was added without committing the regenerated Package.resolved.
                """)

            switch package.requirement {
            case .exactVersion(let version):
                XCTAssertEqual(pin.version, version, """
                    \(package.name) is required as exactVersion \(version) but Package.resolved \
                    pins \(pin.version ?? "no version"). Run `xcodebuild \
                    -resolvePackageDependencies` and commit the regenerated Package.resolved in \
                    the same commit — until then the build resolves one version while every \
                    static check in this repository (including the license provenance checks) \
                    validates the other.
                    """)
                XCTAssertNil(pin.branch,
                             "\(package.name) is required by exact version but pinned to a branch")
            case .revision(let revision):
                XCTAssertEqual(pin.revision, revision, """
                    \(package.name) is required at revision \(revision) but Package.resolved pins \
                    \(pin.revision ?? "nothing"). Re-resolve and commit Package.resolved alongside \
                    the project.yml change.
                    """)
            case .branch(let branch):
                XCTAssertNotNil(Self.branchPinnedDependencies[package.name.lowercased()], """
                    \(package.name) is required by branch in project.yml. Only \
                    \(Self.branchPinnedDependencies.keys.sorted().joined(separator: ", ")) may be, and \
                    each only because another package's own manifest requires it that way.
                    """)
                XCTAssertEqual(pin.branch, branch,
                               "\(package.name) is required on branch \(branch) but pinned to \(pin.branch ?? "no branch")")
            case .none:
                XCTFail("""
                    project.yml declares \(package.name) with a URL but no exactVersion:, \
                    revision: or branch: requirement, so SwiftPM is free to resolve it to \
                    anything. Pin it.
                    """)
            }
        }
    }

    // MARK: - Reading the committed resolved file

    private struct Pin {
        let identity: String
        let kind: String
        let location: String
        let version: String?
        let revision: String?
        let branch: String?
    }

    private struct Resolved {
        let version: Int
        let pins: [Pin]
    }

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func loadResolved(file: StaticString = #filePath, line: UInt = #line) throws -> Resolved {
        let url = Self.repositoryRoot
            .appendingPathComponent("Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Package.resolved is not a JSON object", file: file, line: line
        )
        let version = try XCTUnwrap(object["version"] as? Int,
                                    "Package.resolved has no integer `version`", file: file, line: line)
        let rawPins = object["pins"] as? [[String: Any]] ?? []
        let pins: [Pin] = rawPins.map { raw in
            let state = raw["state"] as? [String: Any] ?? [:]
            return Pin(identity: raw["identity"] as? String ?? "",
                       kind: raw["kind"] as? String ?? "",
                       location: raw["location"] as? String ?? "",
                       version: state["version"] as? String,
                       revision: state["revision"] as? String,
                       branch: state["branch"] as? String)
        }
        return Resolved(version: version, pins: pins)
    }

    // MARK: - Reading the requirements out of project.yml

    private struct DeclaredPackage {
        enum Requirement {
            case exactVersion(String)
            case revision(String)
            case branch(String)
            case none
        }

        let name: String
        /// `nil` for a `path:` (vendored) dependency, which carries no pin.
        let url: String?
        let requirement: Requirement
    }

    /// A deliberately tiny, shape-specific reader for `project.yml`'s `packages:`
    /// block — Core links no YAML parser and must not start (the same reasoning,
    /// and the same shape, as `LicenseCoverageTests.loadProjectDefinition`). It
    /// recognises exactly the two indentation levels the file uses: a two-space
    /// `Name:` key, then its four-space `url:`/`exactVersion:`/`revision:`/
    /// `branch:`/`path:` entries. The emptiness check at the end is what makes a
    /// change in the file's shape fail the suite rather than silently reduce it
    /// to comparing nothing.
    private func loadDeclaredPackages(file: StaticString = #filePath,
                                      line: UInt = #line) throws -> [DeclaredPackage] {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        var packages: [DeclaredPackage] = []
        var insidePackagesBlock = false
        var name: String?
        var url: String?
        var isPath = false
        var requirement = DeclaredPackage.Requirement.none

        func flush() {
            guard let name else { return }
            packages.append(DeclaredPackage(name: name,
                                            url: isPath ? nil : url,
                                            requirement: requirement))
        }

        /// Strips an optional pair of surrounding quotes — versions are written
        /// `exactVersion: "1.5.0"`, revisions bare.
        func value(after key: String, in trimmed: String) -> String {
            var raw = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            return raw
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // A non-indented key ends whatever block was open.
            if !rawLine.hasPrefix(" ") {
                flush()
                name = nil
                insidePackagesBlock = (trimmed == "packages:")
                continue
            }
            guard insidePackagesBlock else { continue }

            if rawLine.hasPrefix("  "), !rawLine.hasPrefix("   "), trimmed.hasSuffix(":") {
                flush()
                name = String(trimmed.dropLast())
                url = nil
                isPath = false
                requirement = .none
                continue
            }

            if trimmed.hasPrefix("url:") {
                url = value(after: "url:", in: trimmed)
            } else if trimmed.hasPrefix("path:") {
                isPath = true
            } else if trimmed.hasPrefix("exactVersion:") {
                requirement = .exactVersion(value(after: "exactVersion:", in: trimmed))
            } else if trimmed.hasPrefix("revision:") {
                requirement = .revision(value(after: "revision:", in: trimmed))
            } else if trimmed.hasPrefix("branch:") {
                requirement = .branch(value(after: "branch:", in: trimmed))
            }
        }
        flush()

        XCTAssertFalse(packages.isEmpty, "parsed no packages out of project.yml",
                       file: file, line: line)
        XCTAssertFalse(packages.allSatisfy { $0.url == nil },
                       "parsed no remote packages out of project.yml — the reader stopped matching its shape",
                       file: file, line: line)
        return packages
    }
}
