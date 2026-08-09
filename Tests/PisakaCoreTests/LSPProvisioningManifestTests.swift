import XCTest
@testable import PisakaCore

/// The manifest is data, so it is checked the way `DependencyPinTests` checks the
/// other pinned data in this repository: by asserting the *shape* every record
/// must have rather than by restating the records.
///
/// There is no compiler and no runtime check between a mistyped SHA-256 and a
/// user whose download silently refuses to install — and, worse, no check at all
/// between an `http://` URL and an unverified binary being executed. Both are one
/// character wide in the source and neither shows up in any build. That is what
/// this suite is for.
final class LSPProvisioningManifestTests: XCTestCase {
    private let manifest = LSPProvisioningManifest.standard
    private let layout = LSPInstallLayout(base: URL(fileURLWithPath: "/tmp/pisaka-servers"))

    private var allArtifacts: [LSPArtifact] { manifest.components.flatMap(\.artifacts) }

    // MARK: - Where the bytes come from

    /// HTTPS, an absolute URL, and one of two hosts. The host allow-list is the
    /// substantive half: a checksum proves the bytes were not tampered with in
    /// flight, but it proves nothing about whether a pin was pointed at somebody's
    /// mirror in the first place, and "official sources only" is a claim that has
    /// to be enforced somewhere.
    func testEveryArtifactIsFetchedOverHTTPSFromAnOfficialHost() {
        let allowedHosts: Set<String> = ["nodejs.org", "registry.npmjs.org"]
        for artifact in allArtifacts {
            XCTAssertEqual(artifact.url.scheme, "https", "\(artifact.url) is not HTTPS")
            XCTAssertNotNil(artifact.url.host, "\(artifact.url) has no host — not an absolute URL")
            XCTAssertTrue(
                allowedHosts.contains(artifact.url.host ?? ""),
                "\(artifact.url.host ?? "-") is not an official source; sources are \(allowedHosts.sorted())"
            )
            XCTAssertFalse(artifact.url.lastPathComponent.isEmpty, "\(artifact.url) names no file")
        }
    }

    func testNoArtifactIsListedTwice() {
        let urls = allArtifacts.map(\.url)
        XCTAssertEqual(Set(urls).count, urls.count, "the same URL is pinned twice")
    }

    // MARK: - The checksums

    /// 64 lowercase hexadecimal characters. Lowercase specifically: the engine
    /// compares against `SHA256.hexadecimalDigest(of:)`, which emits lowercase, so
    /// an uppercase pin is a checksum that can never match — an install that fails
    /// forever for a reason no message would explain.
    func testEveryChecksumIsSixtyFourLowercaseHexCharacters() {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for artifact in allArtifacts {
            XCTAssertEqual(
                artifact.sha256.count, 64,
                "\(artifact.url.lastPathComponent): a SHA-256 is 64 characters, this one is \(artifact.sha256.count)"
            )
            XCTAssertTrue(
                artifact.sha256.unicodeScalars.allSatisfy(hex.contains),
                "\(artifact.url.lastPathComponent): \(artifact.sha256) is not lowercase hexadecimal"
            )
        }
    }

    func testNoTwoArtifactsShareAChecksum() {
        let digests = allArtifacts.map(\.sha256)
        XCTAssertEqual(Set(digests).count, digests.count, "two artifacts carry the same digest — one was copy-pasted")
    }

    // MARK: - The sizes

    func testEverySizeIsPositiveAndUnpackedExceedsCompressed() {
        for artifact in allArtifacts {
            XCTAssertGreaterThan(artifact.byteCount, 0, "\(artifact.url.lastPathComponent) has no download size")
            XCTAssertGreaterThan(
                artifact.unpackedByteCount, artifact.byteCount,
                "\(artifact.url.lastPathComponent) unpacks smaller than it downloads — the two are swapped"
            )
        }
    }

    /// The number the consent prompt shows is per architecture, and it must not
    /// be the sum of both Node slices.
    func testTheDownloadSizeOfNodeIsOneSliceNotBoth() throws {
        let node = try XCTUnwrap(manifest.component("node"))
        for architecture in LSPHostArchitecture.allCases {
            XCTAssertEqual(node.artifacts(for: architecture).count, 1)
            XCTAssertEqual(node.downloadByteCount(for: architecture), node.artifacts(for: architecture)[0].byteCount)
        }
        XCTAssertNotEqual(
            node.downloadByteCount(for: .arm64), node.downloadByteCount(for: .x64),
            "the two slices are the same size — one architecture's pin was pasted over the other"
        )
    }

    // MARK: - Architecture coverage

    /// Node ships per-architecture and must cover both; every npm tarball is
    /// architecture-independent and must claim none. An npm artifact that
    /// accidentally carried `.arm64` would leave Intel Macs unable to install a
    /// server for no reason anyone would find quickly.
    func testNodeCoversBothArchitecturesAndTheNPMArtifactsCoverNone() throws {
        let node = try XCTUnwrap(manifest.component("node"))
        XCTAssertEqual(
            Set(node.artifacts.compactMap(\.architecture)), Set(LSPHostArchitecture.allCases),
            "node must pin one artifact per architecture"
        )
        XCTAssertEqual(node.artifacts.count, LSPHostArchitecture.allCases.count)

        for component in manifest.components where component.id != "node" {
            for artifact in component.artifacts {
                XCTAssertNil(
                    artifact.architecture,
                    "\(artifact.url.lastPathComponent) is an npm tarball and is architecture-independent"
                )
                XCTAssertTrue(LSPHostArchitecture.allCases.allSatisfy(artifact.applies(to:)))
            }
        }
    }

    func testEveryComponentHasSomethingToInstallOnEveryArchitecture() {
        for component in manifest.components {
            for architecture in LSPHostArchitecture.allCases {
                XCTAssertFalse(
                    component.artifacts(for: architecture).isEmpty,
                    "\(component.id) installs nothing on \(architecture.rawValue)"
                )
            }
        }
    }

    // MARK: - Identity and placement

    func testComponentIDsAreUniqueAndUsableAsDirectoryNames() {
        let ids = manifest.components.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two components share an id")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertFalse(id.contains("/"), "\(id) is a path, not a directory name")
            XCTAssertNotEqual(id, ".", "\(id) is not a directory name")
            XCTAssertNotEqual(id, "..", "\(id) is not a directory name")
            XCTAssertNotEqual(
                id, LSPInstallLayout.stagingDirectoryName,
                "a component may not be named after the staging directory"
            )
        }
        for component in manifest.components {
            XCTAssertFalse(component.version.isEmpty)
            XCTAssertFalse(component.version.contains("/"), "\(component.id)'s version is not a directory name")
        }
    }

    /// Within one component, two artifacts that are both fetched on the same
    /// architecture must unpack to different places — otherwise the second
    /// silently overwrites the first, and the missing half only shows up when the
    /// server fails to start. Node's two artifacts *do* share a destination (the
    /// version directory itself) and are correct precisely because only one of
    /// them is ever fetched, so the check is per architecture rather than global.
    func testArtifactDestinationsAreUniquePerComponentAndArchitecture() {
        for component in manifest.components {
            for architecture in LSPHostArchitecture.allCases {
                let destinations = component.artifacts(for: architecture).map(\.destinationSubpath)
                XCTAssertEqual(
                    Set(destinations).count, destinations.count,
                    "\(component.id) unpacks two \(architecture.rawValue) artifacts into the same place"
                )
            }
        }
    }

    /// The strip depth deserves its own pin, because it is the one field in this
    /// record that **no test can otherwise reach**: `ScriptedUnpacker` records the
    /// depth it was handed and writes a canned tree regardless, since a fake with
    /// no real archive has nothing to strip. A wrong depth therefore passes the
    /// whole suite and produces a server whose entry point is not where the
    /// registry says it is — an install that succeeds and a process that dies on
    /// start, for every user. Every artifact here is 1 (a Node tarball wraps
    /// everything in `node-v…-darwin-arm64/`, an npm tarball in `package/`), so a
    /// different value is a deliberate change that has to be made here too.
    func testEveryDestinationAndStripDepthIsSane() {
        for component in manifest.components {
            for artifact in component.artifacts {
                switch artifact.format {
                case .tarGzip:
                    XCTAssertEqual(
                        artifact.stripComponents, 1,
                        "\(artifact.url.lastPathComponent): every tarball here wraps its contents in one directory"
                    )
                case .gzip:
                    // A bare `.gz` holds one file and no layout, so there is
                    // nothing to strip and the unpacker ignores the value. Pinned
                    // at 0 rather than left unspecified: the field would otherwise
                    // read as a fact about the archive that is not true of it.
                    XCTAssertEqual(
                        artifact.stripComponents, 0,
                        "\(artifact.url.lastPathComponent): a gzip artifact has no leading components to strip"
                    )
                }
                XCTAssertFalse(artifact.destinationSubpath.hasPrefix("/"), "destinations are relative")
                XCTAssertFalse(
                    artifact.destinationSubpath.split(separator: "/").contains(".."),
                    "\(artifact.url.lastPathComponent) escapes its component directory"
                )
                XCTAssertTrue(
                    layout.contains(layout.destination(of: artifact, unpackingInto: layout.versionDirectory(for: component))),
                    "\(artifact.url.lastPathComponent) lands outside the install root"
                )
            }
        }
    }

    // MARK: - Requirements

    func testEveryRequirementResolvesAndNothingRequiresItself() {
        for component in manifest.components {
            for requirement in component.requires {
                XCTAssertNotNil(manifest.component(requirement), "\(component.id) requires unknown \(requirement)")
                XCTAssertNotEqual(requirement, component.id, "\(component.id) requires itself")
            }
        }
    }

    /// Requirements first, each component once — what the engine installs in.
    func testInstallationOrderPutsTheRuntimeFirst() {
        for server in LSPDownloadableServer.allCases {
            let order = manifest.installationOrder(for: server.serverComponentID).map(\.id)
            XCTAssertEqual(order, ["node", server.serverComponentID], "\(server.rawValue) installs out of order")
        }
        XCTAssertEqual(manifest.installationOrder(for: "node").map(\.id), ["node"])
        XCTAssertEqual(manifest.installationOrder(for: "nonexistent"), [])
    }

    /// A hand-edited cycle must terminate rather than hang the installer. Built
    /// here rather than in `.standard`, which has none.
    func testInstallationOrderTerminatesOnACycle() {
        let artifact = LSPArtifact(
            url: URL(string: "https://nodejs.org/dist/x.tar.gz")!,
            sha256: String(repeating: "0", count: 64),
            byteCount: 1,
            unpackedByteCount: 2
        )
        let cyclic = LSPProvisioningManifest(components: [
            LSPComponent(id: "a", version: "1", licenseSPDX: "MIT", licenseFileSubpaths: [], artifacts: [artifact], requires: ["b"]),
            LSPComponent(id: "b", version: "1", licenseSPDX: "MIT", licenseFileSubpaths: [], artifacts: [artifact], requires: ["a"]),
        ])
        XCTAssertEqual(cyclic.installationOrder(for: "a").map(\.id), ["b", "a"])
    }

    // MARK: - Licenses

    /// Every component ships a license text from inside its own installed tree,
    /// under a recognised SPDX id. The Acknowledgements section reads exactly
    /// these paths, so a component with none would install code the app then
    /// displays no notice for.
    ///
    /// The rule is **at least one notice per artifact**, deliberately not exactly
    /// one: a package's own LICENSE is not automatically the whole obligation.
    /// `typescript` ships a separate `ThirdPartyNoticeText.txt` for the material
    /// incorporated into `tsserver.js`, and pyright ships the Apache-2.0 typeshed
    /// stub library under its own MIT tree — the same shape as the `deps/xdiff`
    /// and `lib/src/unicode` notices appended to the bundled texts in
    /// `Resources/Licenses/`, and the reason `LicenseCoverageTests` says the
    /// package-granular comparison is a floor rather than the whole check.
    func testEveryComponentDeclaresALicenseItActuallyShips() {
        let known: Set<String> = ["MIT", "Apache-2.0"]
        for component in manifest.components {
            // `licenseSPDX` is an *expression*, so the operands are validated
            // rather than the whole string: a set of whole strings would reject
            // the honest `MIT AND Apache-2.0` and quietly reward labelling
            // pyright's two-licensed tree with whichever single id was already
            // listed here.
            let operands = component.licenseSPDX.components(separatedBy: " AND ")
            XCTAssertFalse(component.licenseSPDX.isEmpty, "\(component.id): no SPDX expression")
            for operand in operands {
                XCTAssertTrue(known.contains(operand), "\(component.id): unrecognised SPDX id “\(operand)”")
            }
            XCTAssertFalse(component.licenseFileSubpaths.isEmpty, "\(component.id) ships no license text")

            func isUnder(_ subpath: String, _ destination: String) -> Bool {
                destination.isEmpty || subpath == destination || subpath.hasPrefix(destination + "/")
            }

            // Nothing lands unacknowledged…
            for architecture in LSPHostArchitecture.allCases {
                for artifact in component.artifacts(for: architecture) {
                    XCTAssertTrue(
                        component.licenseFileSubpaths.contains { isUnder($0, artifact.destinationSubpath) },
                        "\(component.id): nothing acknowledges what lands at “\(artifact.destinationSubpath)”"
                    )
                }
            }

            // …and nothing is acknowledged that no artifact installs, which is
            // what a mistyped subpath looks like. It has no static check of its
            // own — a wrong path is skipped silently at display time — so this is
            // the closest one available without the tarballs.
            let destinations = LSPHostArchitecture.allCases
                .flatMap { component.artifacts(for: $0) }
                .map(\.destinationSubpath)
            for subpath in component.licenseFileSubpaths {
                XCTAssertTrue(
                    destinations.contains { isUnder(subpath, $0) },
                    "\(component.id): “\(subpath)” is not inside anything this component installs"
                )
            }

            for url in layout.licenseFiles(of: component) {
                XCTAssertTrue(layout.contains(url), "\(component.id)'s license text is outside the install root")
            }
        }
    }

    /// pyright's expression names both licenses its tree is under, pinned by hand
    /// because nothing else can see it: the Apache-2.0 half is typeshed's
    /// `dist/typeshed-fallback/LICENSE`, a different project's file shipped inside
    /// pyright's MIT package, and `LSPInstalledLicenses` renders this string as
    /// the heading over that very text. A single "MIT" compiles, passes every
    /// other assertion here, and mislabels the notice on screen — so the value is
    /// written down rather than derived, the way the digests above are.
    ///
    /// The other two stay single-id on the stated rule: `node`'s OpenSSL/ICU/zlib
    /// sections and `typescript`'s `ThirdPartyNoticeText.txt` are notices *inside*
    /// those packages' own files, printed verbatim below the heading.
    func testPyrightIsLabelledWithBothLicensesItsTreeIsUnder() throws {
        XCTAssertEqual(try XCTUnwrap(manifest.component("pyright")).licenseSPDX, "MIT AND Apache-2.0")
        XCTAssertEqual(try XCTUnwrap(manifest.component("node")).licenseSPDX, "MIT")
        XCTAssertEqual(
            try XCTUnwrap(manifest.component("typescript-language-server")).licenseSPDX,
            "Apache-2.0"
        )
    }

    // MARK: - The servers

    func testEveryServerResolvesInsideTheManifest() throws {
        for server in LSPDownloadableServer.allCases {
            let component = try XCTUnwrap(
                manifest.component(server.serverComponentID),
                "\(server.rawValue)'s server component is not in the manifest"
            )
            XCTAssertNotNil(manifest.component(server.runtimeComponentID), "\(server.rawValue)'s runtime is missing")
            XCTAssertTrue(
                component.requires.contains(server.runtimeComponentID),
                "\(component.id) does not require the runtime \(server.rawValue) says it runs on"
            )
            XCTAssertNotNil(component.executableSubpath, "\(component.id) declares no entry point")
            XCTAssertFalse(server.displayName.isEmpty)
            XCTAssertEqual(server.serverID, component.id)
        }
    }

    /// The one rule this whole phase must not break: nothing downloadable claims
    /// Swift, and no two servers claim the same language (`LSPServerRegistry` is
    /// first-registration-wins, so an overlap would silently disable one of them).
    func testTheServedLanguagesAreDisjointAndNeverSwift() {
        var seen: Set<SyntaxLanguage> = []
        for server in LSPDownloadableServer.allCases {
            XCTAssertFalse(server.languages.isEmpty, "\(server.rawValue) serves nothing")
            XCTAssertFalse(server.languages.contains(.swift), "\(server.rawValue) claims Swift; sourcekit-lsp owns it")
            XCTAssertTrue(seen.isDisjoint(with: server.languages), "\(server.rawValue) overlaps another server")
            seen.formUnion(server.languages)
        }
        XCTAssertEqual(seen, [.typescript, .javascript, .python], "the served language set changed")
    }

    // MARK: - The registry entries

    func testTheTypeScriptEntryRunsNodeOnTheServerEntryPointAndNamesTSServer() throws {
        let description = try XCTUnwrap(LSPDownloadableServer.typescript.serverDescription(manifest: manifest, layout: layout))
        let base = "/tmp/pisaka-servers"

        XCTAssertEqual(description.id, "typescript-language-server")
        XCTAssertEqual(description.languages, [.typescript, .javascript])
        XCTAssertEqual(description.launch, .executable(path: "\(base)/node/24.19.0/bin/node"))
        XCTAssertEqual(description.arguments, [
            "\(base)/typescript-language-server/5.3.0/node_modules/typescript-language-server/lib/cli.mjs",
            "--stdio",
        ])
        XCTAssertEqual(
            description.initializationOptions,
            .object(["tsserver": .object([
                "fallbackPath": .string("\(base)/typescript-language-server/5.3.0/node_modules/typescript/lib/tsserver.js")
            ])]),
            """
            D11: the pinned tsserver is named outright rather than left to Node's upward walk, \
            and under `fallbackPath` rather than `path` — `path` would override a project's own \
            node_modules/typescript, which the server prefers and which D11 says still wins.
            """
        )
    }

    func testThePythonEntryRunsNodeOnPyrightAndConfiguresNothing() throws {
        let description = try XCTUnwrap(LSPDownloadableServer.python.serverDescription(manifest: manifest, layout: layout))
        let base = "/tmp/pisaka-servers"

        XCTAssertEqual(description.id, "pyright")
        XCTAssertEqual(description.languages, [.python])
        XCTAssertEqual(description.launch, .executable(path: "\(base)/node/24.19.0/bin/node"))
        XCTAssertEqual(description.arguments, [
            "\(base)/pyright/1.1.411/node_modules/pyright/dist/pyright-langserver.js",
            "--stdio",
        ])
        XCTAssertNil(description.initializationOptions)
    }

    /// Every entry point and executable a description names has to be inside the
    /// component the engine actually installs — a description pointing at a path
    /// nothing unpacks into is a server that fails to start with `ENOENT`.
    func testEveryEntryPointLandsUnderOneOfItsComponentsArtifacts() throws {
        for server in LSPDownloadableServer.allCases {
            let component = try XCTUnwrap(manifest.component(server.serverComponentID))
            let entry = try XCTUnwrap(component.executableSubpath)
            let destinations = component.artifacts.map(\.destinationSubpath)
            XCTAssertTrue(
                destinations.contains { !$0.isEmpty && entry.hasPrefix($0 + "/") },
                "\(component.id)'s entry point \(entry) is not inside anything it unpacks"
            )
            if let tsserver = server.tsserverSubpath {
                XCTAssertTrue(
                    destinations.contains { !$0.isEmpty && tsserver.hasPrefix($0 + "/") },
                    "\(component.id)'s tsserver path is not inside anything it unpacks"
                )
            }
            for subpath in component.licenseFileSubpaths where !destinations.contains("") {
                XCTAssertTrue(
                    destinations.contains { !$0.isEmpty && subpath.hasPrefix($0 + "/") },
                    "\(component.id)'s license text \(subpath) is not inside anything it unpacks"
                )
            }
        }
        let node = try XCTUnwrap(manifest.component("node"))
        XCTAssertEqual(node.executableSubpath, "bin/node")
        XCTAssertEqual(node.artifacts.map(\.destinationSubpath), ["", ""], "node unpacks into its version directory")
    }

    /// A manifest that does not describe a server answers `nil` rather than
    /// trapping — the language then falls back to tree-sitter, which is what every
    /// other failure in this layer does.
    func testAServerMissingFromTheManifestHasNoRegistryEntry() {
        let empty = LSPProvisioningManifest(components: [])
        for server in LSPDownloadableServer.allCases {
            XCTAssertNil(server.serverDescription(manifest: empty, layout: layout))
        }

        let runtimeless = LSPProvisioningManifest(components: [.typescriptLanguageServer])
        XCTAssertNil(LSPDownloadableServer.typescript.serverDescription(manifest: runtimeless, layout: layout))
    }
}
