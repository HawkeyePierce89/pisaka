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
/// It also pins the obligations that are specific rather than structural: every
/// `spdx` must be an expression SPDX would actually parse, over ids pinned by
/// hand (`testEverySPDXExpressionIsWellFormed` — nothing in the build reads that
/// field, so an invented identifier renders like a real one); `libgit2`'s text
/// must contain the `LINKING EXCEPTION` (that section, not the
/// GPLv2 text around it, is what permits linking into a closed-source app);
/// every identity in `Package.resolved` must be either acknowledged or listed in
/// the manifest's `excluded` array with a reason; and the two texts that carry a
/// *sub*-dependency notice must keep carrying it.
///
/// That last one marks the known granularity limit of everything above: the id
/// set is compared package by package, and a package that vendors third-party C
/// into its own target ships licenses no package-level comparison can see. See
/// `testTextsCarryTheirBundledSubDependencyNotices`.
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

    // MARK: - The expressions

    /// Every SPDX License List id this manifest's expressions use. A pinned set
    /// rather than a syntax rule, for the same reason the vendored-query suite
    /// pins its capture names: nothing offline can tell a real list id from a
    /// plausible-looking invention, so a new one fails here until someone has
    /// checked it against spdx.org/licenses.
    private static let usedSPDXLicenseIDs: Set<String> = [
        "BSD-3-Clause",
        "LGPL-2.1-or-later",
        "MIT",
        "Unicode-DFS-2016",
        "Zlib",
    ]

    /// SPDX *exception* ids (the right operand of `WITH`) this manifest uses —
    /// empty, and deliberately so. The one dependency whose licence carries an
    /// exception, libgit2, has no listed identifier for it, and `WITH` accepts
    /// nothing else; it is therefore spelled as a `LicenseRef-` operand instead.
    private static let usedSPDXExceptionIDs: Set<String> = []

    /// `spdx` is documented as an SPDX expression, is shown under every
    /// dependency's name on both Acknowledgements screens, and is the app's only
    /// machine-readable statement of what it is obliged to. Nothing in the build
    /// parses it, so an invented identifier ships and renders exactly like a real
    /// one — the easy mistake being to write a custom exception as though it were
    /// on SPDX's exception list (`GPL-2.0-only WITH linking-exception`), which no
    /// SPDX parser accepts.
    ///
    /// Known limit: the grammar checked here is the flat one the manifest uses —
    /// operands separated by `AND`/`OR`/`WITH`. A parenthesised expression fails
    /// the operand charset below and needs this check extended rather than the
    /// parentheses dropped.
    func testEverySPDXExpressionIsWellFormed() throws {
        for notice in try loadManifest().notices {
            let tokens = notice.spdx.split(separator: " ").map(String.init)
            guard !tokens.isEmpty, tokens.count.isMultiple(of: 2) == false else {
                XCTFail("""
                    \(notice.id)'s spdx expression “\(notice.spdx)” is not operand [operator \
                    operand]… — an SPDX expression is a licence, or licences joined by AND/OR/WITH.
                    """)
                continue
            }

            for (index, token) in tokens.enumerated() {
                guard index.isMultiple(of: 2) else {
                    XCTAssertTrue(["AND", "OR", "WITH"].contains(token), """
                        \(notice.id)'s spdx expression “\(notice.spdx)” has “\(token)” where an \
                        operator belongs. SPDX operators are the uppercase AND/OR/WITH, and no \
                        licence id may contain a space.
                        """)
                    continue
                }

                XCTAssertTrue(Self.isSPDXIDString(token), """
                    “\(token)” in \(notice.id)'s spdx expression is not an SPDX idstring \
                    (letters, digits, `.`, `-`, a trailing `+`).
                    """)

                if index > 0, tokens[index - 1] == "WITH" {
                    XCTAssertTrue(Self.usedSPDXExceptionIDs.contains(token), """
                        \(notice.id) says “WITH \(token)”, but WITH takes only ids from SPDX's \
                        *exception* list — a licence's own custom exception is not one. Write the \
                        whole licence as a `LicenseRef-…` operand instead, or add \(token) here \
                        once it is confirmed to be on spdx.org/licenses/exceptions-index.html.
                        """)
                } else if token.hasPrefix("LicenseRef-") {
                    XCTAssertFalse(token == "LicenseRef-", "\(notice.id)'s LicenseRef- carries no name")
                } else {
                    XCTAssertTrue(Self.usedSPDXLicenseIDs.contains(token), """
                        “\(token)” in \(notice.id)'s spdx expression is not one of the SPDX ids \
                        this manifest is known to use. If it is on spdx.org/licenses, add it to \
                        usedSPDXLicenseIDs; if it is not on the list, spell it `LicenseRef-\(token)`.
                        """)
                }
            }
        }
    }

    /// SPDX's `idstring`: letters, digits, `.` and `-`, plus the `+`
    /// "or-later" suffix a licence id may end with.
    private static func isSPDXIDString(_ token: String) -> Bool {
        let body = token.hasSuffix("+") ? String(token.dropLast()) : token
        return !body.isEmpty
            && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    // MARK: - Provenance

    /// The two provenance tests below select on `origin`: one takes the
    /// `https://` entries, the other the `Vendor/` ones. An entry spelled any
    /// other way (`http://`, `git@…`, a bare URL) would be picked up by neither
    /// and so would ship with its `revision` checked against nothing. Partition
    /// first, so a third shape has to be dealt with rather than skipped.
    func testEveryEntryHasARemoteOrVendoredOrigin() throws {
        for notice in try loadManifest().notices {
            XCTAssertTrue(notice.origin.hasPrefix("https://") || notice.origin.hasPrefix("Vendor/"), """
                \(notice.id)'s origin “\(notice.origin)” is neither an https:// URL nor a \
                Vendor/ path, so neither provenance test covers it and its revision is \
                unverified. Spell a remote origin exactly as Package.resolved's location.
                """)
        }
    }

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
            // Unconditional, including the nil case: a notice that drops its
            // `version` also drops the Version row from the Acknowledgements
            // header, which a `if let` guard would wave through. nil is correct
            // only where the pin itself is revision- or branch-based.
            XCTAssertEqual(notice.version, pin.version, """
                \(notice.id)'s version disagrees with its Package.resolved pin \
                (\(notice.version ?? "nil") vs \(pin.version ?? "nil")). A revision- or \
                branch-pinned package has no version to name, so both must be nil together.
                """)
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

    /// A vendored entry has no `Package.resolved` pin to check its `revision`
    /// against, so the equivalent record is the upstream SHA in its own
    /// `VENDORED.md`. Without this, updating a vendored grammar leaves the
    /// manifest — and the Acknowledgements screen — naming the *old* commit,
    /// with a green suite: exactly the "verifiable rather than merely plausible"
    /// property `LicenseNotice.revision` is documented to carry.
    func testEveryVendoredEntryRecordsTheSHAItsVendoredDocDoes() throws {
        for notice in try loadManifest().notices where notice.origin.hasPrefix("Vendor/") {
            let doc = try text(atRepositoryPath: "\(notice.origin)/VENDORED.md")
            let recorded = try XCTUnwrap(Self.upstreamCommit(inVendoredDoc: doc), """
                \(notice.origin)/VENDORED.md has no `| Commit | \\`<40-hex>\\` |` row for the \
                upstream table's SHA — the manifest's revision has nothing to be checked against.
                """)
            XCTAssertEqual(notice.revision, recorded, """
                \(notice.id) is acknowledged at \(notice.revision), but \(notice.origin)/VENDORED.md \
                records the vendored tree as \(recorded). Update licenses.json (and re-copy the \
                LICENSE) whenever the vendored grammar moves.
                """)
        }
    }

    /// The `| Commit | `<sha>` |` row of a `VENDORED.md` upstream table.
    private static func upstreamCommit(inVendoredDoc doc: String) -> String? {
        for line in doc.components(separatedBy: .newlines) {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[1] == "Commit" else { continue }
            let sha = fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard sha.count == 40,
                  sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { continue }
            return sha
        }
        return nil
    }

    // MARK: - The texts themselves

    func testEveryEntryShipsANonEmptyTextAndNothingElseDoes() throws {
        let manifest = try loadManifest()

        for notice in manifest.notices {
            let contents = try text(atRepositoryPath: "Resources/Licenses/\(notice.file)")
            XCTAssertFalse(contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(notice.file) is empty — it acknowledges nothing")
        }

        // The *whole* directory listing, not just its `.txt`s: the folder
        // reference copies everything, so a stray `.md` or an editor backup would
        // ship inside the bundle with nothing to notice it. Filtering to `.txt`
        // first would wave all of those through.
        //
        // `.DS_Store` is the one exception, and for both reasons at once: it is
        // gitignored so it never reaches a checkout, and Xcode's resource copy
        // excludes it by default (`builtin-copy -exclude .DS_Store …`) so it would
        // not ship even if it did. Asserting on it would only red-fail the suite
        // for whoever opened `Resources/Licenses` in Finder.
        let directory = Self.repositoryRoot.appendingPathComponent("Resources/Licenses")
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != ".DS_Store" }
        XCTAssertEqual(Set(onDisk), Set(manifest.notices.map(\.file)).union([Self.manifestFileName]), """
            Resources/Licenses must hold exactly licenses.json plus the text every manifest entry \
            names — nothing more. Anything else is either a text left behind after a dependency \
            was dropped, an entry naming a file that is not there, or a stray file that would \
            ship: the directory is a folder reference, so whatever is in it is what the app \
            carries.
            """)
    }

    /// The copyright holder each text must name, by manifest id.
    ///
    /// Everything else in this suite checks a text's *existence* and its
    /// entry's *metadata* — the file is present, non-empty, named by the
    /// manifest, and its `revision` matches `Package.resolved`. None of that
    /// reads the text, so copying the wrong `LICENSE` into a slot passes every
    /// one of those assertions: the file is non-empty, present, named, and the
    /// pin it is compared against belongs to the entry, not to the bytes. With
    /// sixteen near-identical MIT files added in one pass, a single misfiled
    /// copy is an easy slip and the only visible difference is a name and a
    /// year — which is precisely the part that carries the attribution
    /// obligation. So pin that line.
    ///
    /// Four grammar texts (`tree-sitter-go/-html/-javascript/-json`) are
    /// genuinely byte-identical upstream — same holder, same year — so no
    /// content check can tell those four apart from one another. That is
    /// harmless: they carry the same grant from the same holder. Every other
    /// pair is distinguishable, and this table distinguishes them.
    private static let expectedCopyrightHolders: [String: String] = [
        "libgit2": "libgit2 is Copyright (C) the libgit2 contributors",
        "Neon": "Copyright (c) 2022, Chime",
        "Rearrange": "Copyright (c) 2019, Chime Systems Inc.",
        "Sparkle": "Copyright (c) 2006-2013 Andy Matuschak.",
        "SwiftTerm": "Copyright (c) 2019-2022 Miguel de Icaza",
        "SwiftTreeSitter": "Copyright (c) 2021, Chime",
        "tree-sitter": "Copyright (c) 2018-2024 Max Brunsfeld",
        "tree-sitter-css": "Copyright (c) 2018 Max Brunsfeld",
        "tree-sitter-dockerfile": "Copyright (c) 2021 Camden Cheek",
        "tree-sitter-go": "Copyright (c) 2014 Max Brunsfeld",
        "tree-sitter-html": "Copyright (c) 2014 Max Brunsfeld",
        "tree-sitter-javascript": "Copyright (c) 2014 Max Brunsfeld",
        "tree-sitter-json": "Copyright (c) 2014 Max Brunsfeld",
        "tree-sitter-markdown": "Copyright (c) 2021 Matthias Deiml",
        "tree-sitter-python": "Copyright (c) 2016 Max Brunsfeld",
        "tree-sitter-rust": "Copyright (c) 2017 Maxim Sokolov",
        "tree-sitter-swift": "Copyright (c) 2021 alex-pinkus",
        "tree-sitter-typescript": "Copyright (c) 2017 Max Brunsfeld",
        "tree-sitter-yaml": "Copyright (c) 2024 tree-sitter-grammars contributors",
        "TreeSitterDotenv": "Copyright (c) 2024 Henrik Hautakoski",
        "TreeSitterGitignore": "Copyright (c) 2022 shunsambongi",
    ]

    /// Every shipped text actually names the dependency it is filed under.
    ///
    /// The table is asserted by *set equality* against the manifest's ids for
    /// the same reason the privacy-manifest and grammar-query checks are: a new
    /// dependency must not be able to arrive with an unverified text just
    /// because nobody remembered to extend the table.
    func testEveryTextNamesItsOwnCopyrightHolder() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(Set(Self.expectedCopyrightHolders.keys), Set(manifest.notices.map(\.id)), """
            expectedCopyrightHolders must cover exactly the manifest's entries. A dependency added \
            without a line here ships a license text that nothing reads; a line left behind names \
            a dependency that no longer ships.
            """)

        for notice in manifest.notices {
            guard let expected = Self.expectedCopyrightHolders[notice.id] else { continue }
            let contents = try text(atRepositoryPath: "Resources/Licenses/\(notice.file)")
            XCTAssertTrue(contents.contains(expected), """
                \(notice.file) does not name \(notice.id)'s copyright holder (looked for \
                “\(expected)”). Either the wrong LICENSE was copied into this slot — the app would \
                then ship the wrong attribution for \(notice.id) — or upstream re-licensed and both \
                this text and the table need updating from the checkout at the pinned revision.
                """)
        }
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

    /// The coverage check above is *package*-granular: it compares manifest ids
    /// against the packages `project.yml` links. Two of those packages compile
    /// third-party source trees of their own into the app, under licenses their
    /// own top-level `LICENSE`/`COPYING` does not carry — so a package's own
    /// license file is not automatically the whole obligation, and nothing in
    /// the id-set comparison can see the difference.
    ///
    /// Both gaps are closed by *appending* the missing notice to the shipped
    /// text (the way libgit2's own COPYING already aggregates zlib, PCRE,
    /// ntlmclient and llhttp) rather than by adding a manifest entry: a
    /// sub-dependency has no SwiftPM identity, so it has no `Package.resolved`
    /// pin for the provenance tests to check and no `- package:` line for the
    /// coverage test to match. This test is what makes the appendices survive a
    /// re-copy: bumping either pin and pasting upstream's file over ours drops
    /// them silently, and only an assertion notices.
    func testTextsCarryTheirBundledSubDependencyNotices() throws {
        // libgit2's Package.swift compiles deps/xdiff (LibXDiff, LGPL-2.1-or-later),
        // which upstream's COPYING enumerates for every *other* bundled dep but
        // not for this one. The LGPL *text* it needs is already in the file:
        // upstream's COPYING carries it for deps/winhttp, which this app never
        // compiles (winhttp is not in the target's `sources:`) — so what the
        // appendix adds is the missing xdiff attribution, not the license body.
        let libgit2 = try text(atRepositoryPath: "Resources/Licenses/libgit2.txt")
        XCTAssertTrue(libgit2.contains("LibXDiff by Davide Libenzi"), """
            libgit2.txt must carry the LibXDiff (deps/xdiff/) notice appended below upstream's \
            COPYING — that directory is in the package's `sources:` and so compiles into the app, \
            but upstream's COPYING never names it. Re-add the appendix after re-copying COPYING.
            """)

        // tree-sitter compiles lib/src/unicode/ (ICU-derived headers); upstream
        // ships their notice as lib/src/unicode/LICENSE and then `exclude:`s
        // that file from the SwiftPM target, so it never reaches the bundle.
        let treeSitter = try text(atRepositoryPath: "Resources/Licenses/tree-sitter.txt")
        XCTAssertTrue(treeSitter.contains("COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)"), """
            tree-sitter.txt must carry the ICU/Unicode notice for lib/src/unicode/ appended below \
            upstream's MIT LICENSE. The package's `sources: ["src"]` compiles those headers into \
            the app while its `exclude:` drops the notice, so nothing else ships it.
            """)

        // Sparkle is the third case, and the one where upstream already did the
        // aggregating: its own LICENSE carries an `EXTERNAL LICENSES` section
        // for the third-party sources it compiles in (bsdiff/Colin Percival,
        // sais-lite/Yuta Mori, the portable C ed25519 implementation from
        // orlp/ed25519 by Orson Peters, and SUSignatureVerifier.m/Mark Hamlin
        // — four entries, not three). So unlike the two above,
        // the verbatim copy *is* the whole obligation and `Sparkle.txt` has no
        // appendix. What must be pinned is that the copy stays whole: a re-copy
        // that grabbed only the MIT grant at the top of the file — the part that
        // looks like a complete licence — would drop four attributions and every
        // other check in this suite would still pass, since the text would be
        // present, non-empty, and would still name Andy Matuschak.
        let sparkle = try text(atRepositoryPath: "Resources/Licenses/Sparkle.txt")
        XCTAssertTrue(sparkle.contains("EXTERNAL LICENSES"), """
            Sparkle.txt must carry upstream's EXTERNAL LICENSES section — the bsdiff, sais-lite, \
            ed25519 and SUSignatureVerifier notices for the third-party sources Sparkle compiles \
            into the framework. It is part of upstream's own LICENSE, so copy that file whole \
            rather than the MIT grant at the top of it.
            """)
        // All four entries, so that a re-copy which lost any one of them fails
        // here: asserting three of four would wave through exactly the kind of
        // partial copy this test exists to catch.
        for holder in ["Copyright 2003-2005 Colin Percival",
                       "Copyright (c) 2008-2010 Yuta Mori",
                       "Copyright (c) 2015 Orson Peters",
                       "Copyright (c) 2011 Mark Hamlin"] {
            XCTAssertTrue(sparkle.contains(holder), """
                Sparkle.txt no longer names “\(holder)” — one of the EXTERNAL LICENSES entries was \
                lost. Re-copy upstream's LICENSE at the pinned tag in full.
                """)
        }

        // Checked and found clean, recorded here because "nothing was found" is
        // otherwise indistinguishable from "nobody looked": tree-sitter-rust
        // 0.24.2 compiles `src/parser.c` + `src/scanner.c`, both upstream's own
        // code under upstream's own MIT, and the only other tree under `src/` is
        // `src/tree_sitter/{alloc,array,parser}.h` — tree-sitter's own MIT
        // headers, already covered by the `tree-sitter` entry above. So its text
        // is upstream's LICENSE verbatim with no appendix, and there is
        // deliberately no assertion for it here.
    }

    /// End to end over the real resources: what `LicenseCatalogLoader` will do at
    /// launch, minus the `Bundle`. A manifest that parses in this suite's own
    /// reader but not through `LicenseCatalog` would ship a blank screen.
    ///
    /// The texts are gathered the way the loader gathers them — by *enumerating
    /// the directory*, not by looking up the names the manifest gives. Building
    /// the dictionary from the manifest would make `missingText` unreachable and
    /// the whole check true by construction; enumerating means a notice naming a
    /// file that is not on disk fails here exactly as it would at launch.
    func testTheRepositoryManifestResolvesThroughTheCatalog() throws {
        let data = try Data(contentsOf: Self.licensesDirectory.appendingPathComponent(Self.manifestFileName))

        var texts: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.licensesDirectory.path)
        where name.hasSuffix(".txt") {
            texts[name] = try text(atRepositoryPath: "Resources/Licenses/\(name)")
        }

        let documents = try LicenseCatalog.resolve(manifest: data, texts: texts)
        let manifest = try LicenseCatalog.decode(manifest: data)
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

    /// The manifest's file name inside `Resources/Licenses/`.
    private static let manifestFileName = "licenses.json"

    private func text(atRepositoryPath path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func loadManifest() throws -> LicenseManifest {
        let url = Self.licensesDirectory.appendingPathComponent(Self.manifestFileName)
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

    /// The app target whose `dependencies:` decide what is linked into the
    /// shipped binary — and so what has to be acknowledged.
    private static let appTargetName = "Pisaka"

    /// A deliberately tiny, shape-specific reader for the two `project.yml`
    /// lists this suite compares — Core links no YAML parser and must not start.
    /// It is not a YAML implementation: it recognises exactly the two forms the
    /// file uses (a two-space-indented `Name:` key inside `packages:`, and a
    /// `- package: Name` item under the app target's own `dependencies:` key),
    /// skipping comments.
    ///
    /// The `- package:` scan is scoped to that one target rather than matched
    /// file-wide, because `linkedPackages` means "what the shipped app links".
    /// A second target with dependencies of its own — a UI-test bundle, say —
    /// would otherwise grow the set silently, and `testManifestCoversExactlyThe…`
    /// would start demanding a license text for something the app never links.
    ///
    /// Both `testEveryDeclaredPackageIsLinked`'s assertions double as a check
    /// that it is still reading something — if the file's shape changes, the
    /// parser returns an empty or partial set and the suite fails rather than
    /// silently comparing nothing.
    private func loadProjectDefinition() throws -> ProjectDefinition {
        let source = try text(atRepositoryPath: "project.yml")

        var declared: Set<String> = []
        var linked: Set<String> = []
        var topLevelBlock = ""
        var currentTarget: String?
        var insideDependencies = false

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // A non-indented key ends whatever block was open.
            if !line.hasPrefix(" ") {
                topLevelBlock = trimmed
                currentTarget = nil
                insideDependencies = false
                continue
            }

            // A two-space-indented `Name:` key is a package declaration under
            // `packages:` and a target name under `targets:`.
            if line.hasPrefix("  "), !line.hasPrefix("   "), trimmed.hasSuffix(":") {
                let name = String(trimmed.dropLast())
                if topLevelBlock == "packages:" { declared.insert(name) }
                if topLevelBlock == "targets:" { currentTarget = name }
                insideDependencies = false
                continue
            }

            guard topLevelBlock == "targets:", currentTarget == Self.appTargetName else { continue }

            // A four-space-indented key is a sibling of `dependencies:`, so it
            // opens the list or closes it; the items themselves sit deeper.
            if line.hasPrefix("    "), !line.hasPrefix("     ") {
                insideDependencies = (trimmed == "dependencies:")
                continue
            }

            if insideDependencies, trimmed.hasPrefix("- package:") {
                linked.insert(trimmed.dropFirst("- package:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }

        XCTAssertFalse(declared.isEmpty, "parsed no packages out of project.yml")
        XCTAssertFalse(linked.isEmpty, """
            parsed no dependencies for the \(Self.appTargetName) target out of project.yml — \
            either the target was renamed (update `appTargetName`) or the file's shape changed
            """)
        return ProjectDefinition(declaredPackages: declared, linkedPackages: linked)
    }
}
