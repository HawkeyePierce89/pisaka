import XCTest
@testable import PisakaCore

/// `LicenseCatalog` against in-memory fixtures — the decoding contract and every
/// way it refuses.
///
/// The refusals matter more than the happy path: each one stands for a bundle
/// that would show an incomplete Acknowledgements screen while the build stayed
/// green, so they must be errors rather than silently-dropped entries.
/// `LicenseCoverageTests` runs the same code over the repository's real manifest.
final class LicenseNoticeTests: XCTestCase {
    // MARK: - Decoding

    func testDecodesAWellFormedManifest() throws {
        let manifest = try LicenseCatalog.decode(manifest: Self.wellFormed)

        XCTAssertEqual(manifest.notices.count, 3)

        let neon = manifest.notices[0]
        XCTAssertEqual(neon.id, "Neon")
        XCTAssertEqual(neon.name, "Neon")
        XCTAssertEqual(neon.origin, "https://github.com/ChimeHQ/Neon")
        XCTAssertNil(neon.version, "a revision-pinned package has no version to name")
        XCTAssertEqual(neon.revision, "484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165")
        XCTAssertEqual(neon.spdx, "BSD-3-Clause")
        XCTAssertEqual(neon.file, "Neon.txt")

        XCTAssertEqual(manifest.notices[1].version, "1.9.2")
        XCTAssertEqual(manifest.notices[2].origin, "Vendor/TreeSitterGitignore")
    }

    /// The manifest lists dependencies in `project.yml` order, which keeps the
    /// tree-sitter family together; a decoder that reordered them (or a `Set`
    /// slipping in) would scramble the screen.
    func testPreservesManifestOrder() throws {
        let manifest = try LicenseCatalog.decode(manifest: Self.wellFormed)
        XCTAssertEqual(manifest.notices.map(\.id), ["Neon", "libgit2", "TreeSitterGitignore"])
    }

    func testDecodesTheDocumentedExclusions() throws {
        let manifest = try LicenseCatalog.decode(manifest: Self.wellFormed)
        XCTAssertEqual(manifest.excluded, [
            LicenseExclusion(id: "swift-argument-parser",
                             reason: "resolved only for SwiftTerm's Termcast executable target; not linked into the app")
        ])
    }

    /// A manifest with nothing to exclude may omit the key entirely rather than
    /// carry an empty array — otherwise adding the first exclusion would be a
    /// schema change.
    func testTreatsAMissingExcludedKeyAsNoExclusions() throws {
        let json = Data("""
        { "notices": [\(Self.neonEntry)] }
        """.utf8)

        let manifest = try LicenseCatalog.decode(manifest: json)
        XCTAssertTrue(manifest.excluded.isEmpty)
    }

    // MARK: - Refusals

    func testRejectsMalformedJSON() {
        assertThrows(.malformedManifest(reason: "")) {
            _ = try LicenseCatalog.decode(manifest: Data("{ not json".utf8))
        }
    }

    /// A manifest missing a required field is a *malformed* manifest, not a
    /// notice with a blank column: the app links the dependency either way, so
    /// the obligation is unmet until the entry is complete.
    func testRejectsANoticeMissingARequiredField() {
        let json = Data("""
        { "notices": [{ "id": "Neon", "name": "Neon", "file": "Neon.txt" }] }
        """.utf8)

        assertThrows(.malformedManifest(reason: "")) {
            _ = try LicenseCatalog.decode(manifest: json)
        }
    }

    /// The app links plenty of dependencies, so an empty list means a truncated
    /// or wrong file — never "nothing to acknowledge".
    func testRejectsAnEmptyManifest() {
        assertThrows(.emptyManifest) {
            _ = try LicenseCatalog.decode(manifest: Data(#"{ "notices": [] }"#.utf8))
        }
    }

    func testRejectsDuplicateIdentifiers() {
        let json = Data("""
        { "notices": [\(Self.neonEntry), \(Self.neonEntry)] }
        """.utf8)

        assertThrows(.duplicateIdentifier("Neon")) {
            _ = try LicenseCatalog.decode(manifest: json)
        }
    }

    // MARK: - Resolving texts

    func testResolvePairsEachNoticeWithItsTextInManifestOrder() throws {
        let documents = try LicenseCatalog.resolve(manifest: Self.wellFormed, texts: Self.texts)

        XCTAssertEqual(documents.map(\.id), ["Neon", "libgit2", "TreeSitterGitignore"])
        XCTAssertEqual(documents[0].text, "BSD-3-Clause text\n")
        XCTAssertEqual(documents[1].text, "GPLv2 text with a LINKING EXCEPTION\n")
        XCTAssertEqual(documents[2].notice.spdx, "MIT")
    }

    /// Verbatim: no trimming, no reflowing. The copyright lines and the trailing
    /// newline are part of what is being reproduced.
    func testResolveKeepsTheTextExactlyAsSupplied() throws {
        let text = "  Copyright (c) 2020 Someone\n\n  All rights reserved.\n\n"
        let documents = try LicenseCatalog.resolve(manifest: Data("""
        { "notices": [\(Self.neonEntry)] }
        """.utf8), texts: ["Neon.txt": text])

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].text, text)
    }

    func testResolveRejectsAMissingText() {
        assertThrows(.missingText(id: "libgit2", file: "libgit2.txt")) {
            _ = try LicenseCatalog.resolve(
                manifest: Self.wellFormed,
                texts: Self.texts.filter { $0.key != "libgit2.txt" }
            )
        }
    }

    /// Blank is as bad as absent, and whitespace-only is the shape a botched copy
    /// actually takes — it acknowledges nothing while looking present.
    func testResolveRejectsAWhitespaceOnlyText() {
        var texts = Self.texts
        texts["libgit2.txt"] = "\n   \n\t\n"

        assertThrows(.emptyText(id: "libgit2", file: "libgit2.txt")) {
            _ = try LicenseCatalog.resolve(manifest: Self.wellFormed, texts: texts)
        }
    }

    /// `resolve` decodes first, so the manifest-level refusals reach callers that
    /// never call `decode` themselves.
    func testResolveSurfacesManifestErrors() {
        assertThrows(.emptyManifest) {
            _ = try LicenseCatalog.resolve(manifest: Data(#"{ "notices": [] }"#.utf8), texts: [:])
        }
    }

    /// Every case carries a message naming what is wrong, so a broken bundle can
    /// say so instead of showing an empty screen.
    func testEveryErrorDescribesItself() {
        let errors: [LicenseCatalogError] = [
            .malformedManifest(reason: "no notices"),
            .emptyManifest,
            .duplicateIdentifier("Neon"),
            .missingText(id: "Neon", file: "Neon.txt"),
            .emptyText(id: "Neon", file: "Neon.txt"),
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) has no user-facing description")
            XCTAssertFalse(description.contains("PisakaCore.LicenseCatalogError"),
                           "\(error) fell back to the generic NSError description")
        }
    }

    // MARK: - Origin as a link

    /// Both Acknowledgements screens ask `originURL` whether to render the origin
    /// as a tappable link, so the rule is unit-tested here rather than repeated
    /// (and drifting) in two untested view files.
    func testOriginURLOffersRemoteOriginsAndRefusesEverythingElse() throws {
        let documents = try LicenseCatalog.resolve(manifest: Self.wellFormed, texts: Self.texts)

        XCTAssertEqual(documents[0].notice.originURL?.absoluteString,
                       "https://github.com/ChimeHQ/Neon")
        XCTAssertNil(documents[2].notice.originURL,
                     "a Vendor/ path names a directory in this repository, not something to open")

        // Anything that is not https is not a link: an http:// origin is a
        // downgrade worth noticing rather than silently opening, and the other
        // two are what a malformed manifest could otherwise turn into a tap
        // target in a shipped app.
        for origin in ["http://example.com/pkg", "file:///etc/passwd", "javascript:alert(1)", ""] {
            XCTAssertNil(Self.notice(origin: origin).originURL,
                         "“\(origin)” must not be offered as a link")
        }
    }

    private static func notice(origin: String) -> LicenseNotice {
        LicenseNotice(id: "x", name: "x", origin: origin, version: nil,
                      revision: "0", spdx: "MIT", file: "x.txt")
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: LicenseCatalogError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as LicenseCatalogError {
            // `malformedManifest` carries whatever reason JSONDecoder phrased,
            // which is not ours to pin — those cases compare by case alone.
            if case .malformedManifest = expected, case .malformedManifest = error {
                return
            }
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private static let neonEntry = """
    {
      "id": "Neon",
      "name": "Neon",
      "origin": "https://github.com/ChimeHQ/Neon",
      "version": null,
      "revision": "484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165",
      "spdx": "BSD-3-Clause",
      "file": "Neon.txt"
    }
    """

    /// Three entries covering the shapes the real manifest has: a
    /// revision-pinned package with no version, a tagged remote package, and a
    /// vendored one whose origin is a repository path.
    private static let wellFormed = Data("""
    {
      "notices": [
        \(neonEntry),
        {
          "id": "libgit2",
          "name": "libgit2",
          "origin": "https://github.com/ibrahimcetin/libgit2",
          "version": "1.9.2",
          "revision": "52287b0914f300f916b58fec80e13d8dd8f6824f",
          "spdx": "LicenseRef-libgit2-GPL-2.0-only-with-linking-exception AND LGPL-2.1-or-later",
          "file": "libgit2.txt"
        },
        {
          "id": "TreeSitterGitignore",
          "name": "tree-sitter-gitignore (vendored)",
          "origin": "Vendor/TreeSitterGitignore",
          "version": null,
          "revision": "f4685bf11ac466dd278449bcfe5fd014e94aa504",
          "spdx": "MIT",
          "file": "TreeSitterGitignore.txt"
        }
      ],
      "excluded": [
        {
          "id": "swift-argument-parser",
          "reason": "resolved only for SwiftTerm's Termcast executable target; not linked into the app"
        }
      ]
    }
    """.utf8)

    private static let texts = [
        "Neon.txt": "BSD-3-Clause text\n",
        "libgit2.txt": "GPLv2 text with a LINKING EXCEPTION\n",
        "TreeSitterGitignore.txt": "MIT text\n",
    ]
}
