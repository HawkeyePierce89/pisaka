import XCTest
@testable import PisakaCore

/// Static verification of the committed workspace `Package.resolved` — the file
/// that actually decides which bytes of every dependency a release build links.
///
/// `project.yml` states each dependency's *requirement*; `Package.resolved`
/// records the *pin* SwiftPM resolved it to, and only the pin is reproducible.
/// The distinction matters for exactly one package. Every other dependency
/// carries an `exactVersion:`/`revision:` requirement, so its pin cannot move
/// without a visible `project.yml` change; `SwiftTreeSitter` is required as
/// `branch: main` because *Neon's own manifest* requires it that way (the pinned
/// Neon revision 484d6fb declares `.package(url: …/SwiftTreeSitter,
/// branch: "main")`, and SwiftPM refuses a package "required using two different
/// revision-based requirements", so a root `revision:` makes
/// `xcodebuild -resolvePackageDependencies` fail outright — see the comment on
/// that entry in `project.yml`). For that one package the committed revision in
/// this file is the *whole* pin, and nothing in the requirement would flag a
/// drift to a newer `main`.
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
///  * `swifttreesitter` is the *only* branch-based pin — a second one creeping
///    in means another dependency became unpinnable without anyone saying so;
///  * `swifttreesitter`'s revision is exactly the one that has been building and
///    testing all along, so an unnoticed jump to a newer `main` fails here.
final class DependencyPinTests: XCTestCase {
    /// The SwiftTreeSitter revision the project builds against: 3 commits past
    /// upstream tag `0.10.0`. Updating it is a deliberate act — change this
    /// constant in the same commit that changes `Package.resolved`.
    private static let swiftTreeSitterRevision = "0f40435cdb41673ce4194d731571cf2a2f7c3285"

    /// The one package allowed to be pinned by branch, and why (see the type doc).
    private static let branchPinnedIdentity = "swifttreesitter"

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

    func testSwiftTreeSitterIsTheOnlyBranchPinnedDependency() throws {
        let branched = try loadResolved().pins
            .filter { $0.branch != nil }
            .map(\.identity)
            .sorted()
        XCTAssertEqual(branched, [Self.branchPinnedIdentity],
                       """
                       Only \(Self.branchPinnedIdentity) may be pinned by branch, and only because Neon's \
                       own manifest requires it that way. A new branch-based pin means a dependency \
                       stopped being reproducible — pin it in project.yml or document it here.
                       """)
    }

    func testSwiftTreeSitterIsPinnedToTheExpectedRevision() throws {
        let pin = try XCTUnwrap(
            try loadResolved().pins.first { $0.identity == Self.branchPinnedIdentity },
            "no \(Self.branchPinnedIdentity) pin in Package.resolved"
        )
        XCTAssertEqual(pin.revision, Self.swiftTreeSitterRevision,
                       """
                       SwiftTreeSitter moved off the revision this project builds against. It is required \
                       as `branch: main` (Neon's manifest, not our choice), so this revision is the only \
                       thing holding it still. If the move is intentional, update this constant too.
                       """)
    }

    // MARK: - Reading the committed resolved file

    private struct Pin {
        let identity: String
        let kind: String
        let location: String
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
                       revision: state["revision"] as? String,
                       branch: state["branch"] as? String)
        }
        return Resolved(version: version, pins: pins)
    }
}
