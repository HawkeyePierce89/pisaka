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
    /// `github.com` is on the list for rust-analyzer alone, and it is the project's
    /// own releases path rather than a mirror. GitHub answers a release asset with
    /// a redirect to `objects.githubusercontent.com`, which `URLSession` follows and
    /// nothing here pins — deliberately: what makes an unpinned redirect target safe
    /// is the SHA-256 the bytes are checked against, exactly as it is for the two
    /// hosts that do not redirect.
    func testEveryArtifactIsFetchedOverHTTPSFromAnOfficialHost() {
        let allowedHosts: Set<String> = ["nodejs.org", "registry.npmjs.org", "github.com"]
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

    /// A host is not an owner, and `github.com` is the one host on that list where
    /// the difference is the whole check.
    ///
    /// `nodejs.org` and `registry.npmjs.org` are single-project hosts: naming them
    /// *is* naming the project. GitHub serves every repository there is, so a pin
    /// repointed at `github.com/<anybody>/rust-analyzer/releases/...` passes the
    /// host check while pointing at a fork — which is precisely what "a pin was not
    /// pointed at somebody's mirror" was meant to catch. The digest still bounds
    /// what a wrong URL can do; the two checks are independent on purpose, and this
    /// is the half that says *whose* bytes were meant.
    func testGitHubArtifactsComeFromTheProjectsOwnRepository() {
        let owners = ["github.com": "/rust-lang/rust-analyzer/releases/download/"]
        for artifact in allArtifacts {
            guard let prefix = owners[artifact.url.host ?? ""] else { continue }
            XCTAssertTrue(
                artifact.url.path.hasPrefix(prefix),
                "\(artifact.url) is on \(artifact.url.host ?? "-") but not under \(prefix)"
            )
        }
    }

    /// A `.gzip` artifact's file name is a *name*, not a path.
    ///
    /// It is the only field in this manifest that is concatenated onto a directory
    /// rather than computed by `LSPInstallLayout`, so `"../../x"` would have the
    /// unpacker write an executable outside the install root — D12's containment
    /// promise broken by data rather than by code. `LSPInstallEngine` refuses it at
    /// runtime; this is the same rule stated where the data is, so a by-hand pin
    /// edit fails `swift test` rather than at install time on a user's Mac.
    func testEveryGzipArtifactNamesALoneFile() {
        for artifact in allArtifacts {
            guard case let .gzip(fileName) = artifact.format else { continue }
            XCTAssertFalse(fileName.isEmpty, "\(artifact.url) unpacks to a file with no name")
            XCTAssertFalse(
                fileName.contains("/"), "“\(fileName)” is a path, not a file name"
            )
            XCTAssertFalse(
                fileName == "." || fileName == "..", "“\(fileName)” is a directory, not a file"
            )
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

    /// The two components that ship native code — `node` and `rust-analyzer` —
    /// must pin exactly one artifact per architecture; every npm tarball is
    /// architecture-independent and must claim none. An npm artifact that
    /// accidentally carried `.arm64` would leave Intel Macs unable to install a
    /// server for no reason anyone would find quickly; a native one that carried
    /// `nil` would hand every Mac both slices and install the wrong one over the
    /// right one.
    ///
    /// The native set is written out by hand rather than derived from "declares an
    /// architecture", which would make this assertion true of whatever the manifest
    /// happened to say.
    func testTheNativeComponentsCoverBothArchitecturesAndTheNPMArtifactsCoverNone() {
        let native: Set<String> = ["node", "rust-analyzer"]
        XCTAssertTrue(
            native.isSubset(of: Set(manifest.components.map(\.id))),
            "a component named here is no longer in the manifest"
        )

        for component in manifest.components {
            guard native.contains(component.id) else {
                for artifact in component.artifacts {
                    XCTAssertNil(
                        artifact.architecture,
                        "\(artifact.url.lastPathComponent) is an npm tarball and is architecture-independent"
                    )
                    XCTAssertTrue(LSPHostArchitecture.allCases.allSatisfy(artifact.applies(to:)))
                }
                continue
            }

            XCTAssertEqual(
                Set(component.artifacts.compactMap(\.architecture)), Set(LSPHostArchitecture.allCases),
                "\(component.id) must pin one artifact per architecture"
            )
            XCTAssertEqual(component.artifacts.count, LSPHostArchitecture.allCases.count)
            for architecture in LSPHostArchitecture.allCases {
                XCTAssertEqual(
                    component.artifacts(for: architecture).count, 1,
                    "\(component.id) fetches more than one artifact on \(architecture.rawValue)"
                )
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

    /// A `.gzip` artifact names its file twice — once in the format's payload
    /// (what the unpacker creates, and what the engine's pre-commit gate then asks
    /// about) and once inside the component's `executableSubpath` (what the
    /// registry launches). Nothing at runtime compares the two: a mismatch
    /// downloads, verifies, unpacks, passes the executable gate on the file it did
    /// write, commits, and produces a server that dies with `ENOENT` on every
    /// start. Both spellings are pinned data, so the check belongs here.
    func testEveryGzipArtifactUnpacksToTheExecutableItsComponentNames() {
        for component in manifest.components {
            for artifact in component.artifacts {
                guard case let .gzip(fileName) = artifact.format else { continue }
                XCTAssertFalse(fileName.isEmpty, "\(component.id): a gzip artifact must name its file")
                XCTAssertFalse(fileName.contains("/"), "\(component.id): “\(fileName)” is a path, not a file name")
                let unpacked = artifact.destinationSubpath.isEmpty
                    ? fileName
                    : artifact.destinationSubpath + "/" + fileName
                XCTAssertEqual(
                    component.executableSubpath, unpacked,
                    "\(component.id) launches a path its gzip artifact does not unpack into"
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
        let known: Set<String> = ["MIT", "Apache-2.0", "ISC", "BSD-3-Clause"]

        // The one component whose installed tree contains no license text at all,
        // pinned by id so a second one cannot appear by accident. A bare `.gz`
        // holds one executable and nothing beside it (D24), so there is nothing
        // for `LSPInstalledLicenses` to read; every other component here must
        // ship its notices from inside its own tree.
        let shipsNoLicenseText: Set<String> = ["rust-analyzer"]

        // The one *artifact* inside a component that ships no license text of its
        // own — `@vscode/l10n` 0.0.18 publishes none, declaring MIT in its
        // `package.json` alone — so the "nothing lands unacknowledged" rule below
        // cannot be satisfied for it by any path that exists in the tarball.
        //
        // Pinned by destination, as a decision: the alternative is dropping the
        // package from `licenseFileSubpaths` silently, which is indistinguishable
        // from the mistyped subpath this suite exists to catch, and which would
        // let a *second* unacknowledged package in behind it. The obligation is
        // met by the declared id in the component's SPDX expression; if upstream
        // ever ships a file, it belongs in `licenseFileSubpaths` and off this
        // list, and the assertion below is what says so.
        let landsWithoutALicenseText: Set<String> = ["node_modules/@vscode/l10n"]

        for component in manifest.components {
            // `licenseSPDX` is an *expression*, so the operands are validated
            // rather than the whole string: a set of whole strings would reject
            // the honest `MIT AND Apache-2.0` and quietly reward labelling
            // pyright's two-licensed tree with whichever single id was already
            // listed here. Both operators appear — `AND` when the tree really is
            // under two licenses at once (pyright), `OR` when upstream offers a
            // choice (rust-analyzer) — and the ids have to be recognisable either
            // way.
            let operands = component.licenseSPDX
                .components(separatedBy: " AND ")
                .flatMap { $0.components(separatedBy: " OR ") }
            XCTAssertFalse(component.licenseSPDX.isEmpty, "\(component.id): no SPDX expression")
            for operand in operands {
                XCTAssertTrue(known.contains(operand), "\(component.id): unrecognised SPDX id “\(operand)”")
            }

            guard !shipsNoLicenseText.contains(component.id) else {
                XCTAssertTrue(
                    component.licenseFileSubpaths.isEmpty,
                    "\(component.id) now ships a license text — say so here rather than leaving it unread"
                )
                continue
            }
            XCTAssertFalse(component.licenseFileSubpaths.isEmpty, "\(component.id) ships no license text")

            func isUnder(_ subpath: String, _ destination: String) -> Bool {
                destination.isEmpty || subpath == destination || subpath.hasPrefix(destination + "/")
            }

            // Nothing lands unacknowledged…
            for architecture in LSPHostArchitecture.allCases {
                for artifact in component.artifacts(for: architecture) {
                    guard !landsWithoutALicenseText.contains(artifact.destinationSubpath) else {
                        XCTAssertFalse(
                            component.licenseFileSubpaths.contains { isUnder($0, artifact.destinationSubpath) },
                            """
                            \(component.id): “\(artifact.destinationSubpath)” now acknowledges a license text — \
                            take it off the exception list rather than leaving both statements standing
                            """
                        )
                        continue
                    }
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

    // MARK: - rust-analyzer

    /// The first component that is a standalone program rather than a Node
    /// argument, and so the first that exercises every field the other three leave
    /// at its default: a second archive format, no leading components to strip, a
    /// destination subdirectory, no requirements, and a version that is a date.
    ///
    /// Pinned by value rather than by shape. Each of these is one character wide in
    /// the source, none of them has a compiler or a runtime check behind it, and a
    /// wrong one produces an install that succeeds and a server that never starts.
    func testTheRustAnalyzerComponentIsOneGzippedBinaryPerArchitecture() throws {
        let component = try XCTUnwrap(manifest.component("rust-analyzer"))

        XCTAssertEqual(component.version, "2026-08-03", "the version is upstream's release date, not a semver")
        XCTAssertEqual(component.executableSubpath, "bin/rust-analyzer")
        XCTAssertEqual(component.requires, [], "nothing runs rust-analyzer but the kernel")
        XCTAssertEqual(
            manifest.installationOrder(for: "rust-analyzer").map(\.id), ["rust-analyzer"],
            "requiring nothing, it installs alone — no runtime is fetched on its behalf"
        )

        let expected: [LSPHostArchitecture: (String, String, Int, Int)] = [
            .arm64: (
                "rust-analyzer-aarch64-apple-darwin.gz",
                "bba6cd8209643cd781f3ee5474fa232d3ee1b77a57f2e77982806e3c80a65207",
                13_873_448,
                37_914_480
            ),
            .x64: (
                "rust-analyzer-x86_64-apple-darwin.gz",
                "8966f9429085c243817b9d13afa76e98920668c07a9b432901daaf047397c6cb",
                14_576_027,
                39_382_228
            ),
        ]

        for architecture in LSPHostArchitecture.allCases {
            let slice = component.artifacts(for: architecture)
            XCTAssertEqual(slice.count, 1, "\(architecture.rawValue) must fetch exactly one file")
            let artifact = try XCTUnwrap(slice.first)
            let (fileName, sha256, byteCount, unpackedByteCount) = try XCTUnwrap(expected[architecture])

            XCTAssertEqual(artifact.url.lastPathComponent, fileName)
            XCTAssertEqual(
                artifact.url.deletingLastPathComponent().lastPathComponent, component.version,
                "the asset must come from the release the version pins"
            )
            XCTAssertEqual(artifact.sha256, sha256)
            XCTAssertEqual(artifact.byteCount, byteCount)
            // Measured, not estimated — one file, so `gunzip` + `ls -l` answers it
            // exactly and there is no block-size rounding to hide a pasted value.
            XCTAssertEqual(artifact.unpackedByteCount, unpackedByteCount)
            XCTAssertEqual(artifact.format, .gzip(fileName: "rust-analyzer"))
            XCTAssertEqual(artifact.stripComponents, 0)
            XCTAssertEqual(artifact.destinationSubpath, "bin")
            XCTAssertEqual(
                component.downloadByteCount(for: architecture), byteCount,
                "the size the prompt shows is one slice, never the sum of both"
            )
        }

        XCTAssertNotEqual(
            component.downloadByteCount(for: .arm64), component.downloadByteCount(for: .x64),
            "the two slices are the same size — one architecture's pin was pasted over the other"
        )
        XCTAssertEqual(
            layout.executable(of: component)?.path,
            "/tmp/pisaka-servers/rust-analyzer/2026-08-03/bin/rust-analyzer",
            "the binary the unpacker writes and the path the registry launches are the same file"
        )
    }

    /// The empty `licenseFileSubpaths` is a decision (D24), so it is asserted as
    /// one: a `.gz` of a single binary carries no notice, `LSPInstalledLicenses`
    /// therefore has nothing to print, and the substitute is the Settings row's
    /// sentence naming the origin and the dual license. Left implicit, it would be
    /// indistinguishable from a subpath somebody forgot — which is the failure this
    /// layer's license checks exist to catch everywhere else.
    func testRustAnalyzerShipsNoLicenseTextAndSaysWhichLicensesItIsUnder() throws {
        let component = try XCTUnwrap(manifest.component("rust-analyzer"))
        XCTAssertEqual(component.licenseSPDX, "Apache-2.0 OR MIT", "upstream offers a choice; the heading says so")
        XCTAssertTrue(component.licenseFileSubpaths.isEmpty)
        XCTAssertTrue(
            layout.licenseFiles(of: component).isEmpty,
            "the Acknowledgements surface must be handed nothing to read rather than a path that is not there"
        )
    }

    /// Rust reuses the manifest and the engine, not `LSPProvisioningModel` (D21):
    /// its row has a toolchain gate and a discovered-copy state that no 2b row can
    /// express. So the downloadable-server enum stays exactly what it was, and this
    /// is the assertion that adding a component did not quietly widen it.
    func testTheDownloadableServerSetIsUnchangedByTheRustComponent() {
        XCTAssertEqual(Set(LSPDownloadableServer.allCases.map(\.rawValue)), ["typescript", "python", "yaml"])
        XCTAssertFalse(
            LSPDownloadableServer.allCases.map(\.serverComponentID).contains("rust-analyzer"),
            "rust-analyzer is not a 2b server; its lifecycle lives in the Rust model"
        )
        XCTAssertNotNil(
            manifest.component("rust-analyzer"),
            "…and yet the component is pinned here, which is the whole of what Rust reuses"
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
        XCTAssertEqual(
            seen, [.typescript, .javascript, .python, .yaml],
            "the served language set changed"
        )
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
        XCTAssertNil(
            description.configuration,
            "the TypeScript server takes no settings from this layer; its handshake is what it was"
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
        XCTAssertNil(
            description.configuration,
            "pyright takes no settings from this layer; its handshake is what it was"
        )
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

    // MARK: - yaml-language-server

    /// The first component whose **whole runtime closure** is pinned, and the
    /// reason that is not a slippery slope: `server.js` `require`s its
    /// dependencies at run time rather than shipping a bundle, so a package
    /// missing from this list is a server that dies on start — the same failure a
    /// wrong `executableSubpath` produces, and the same reason it is pinned data.
    ///
    /// The closure is asserted by value: twenty packages, each at the version and
    /// the compressed size resolved by the procedure in `core-provisioning.md`,
    /// each landing flat at `node_modules/<package>`. Flat is load-bearing —
    /// nothing here resolves versions, so a closure with a conflict could not be
    /// laid out this way at all, and the fact that it has none is what makes
    /// Node's ordinary upward walk from `server.js` find every one of them.
    ///
    /// Nothing but this test can see a dropped member: the manifest still
    /// compiles, every remaining digest still verifies, the install still
    /// succeeds, and the server exits on its first `require`.
    func testTheYAMLComponentPinsItsWholeRuntimeClosure() throws {
        let component = try XCTUnwrap(manifest.component("yaml-language-server"))

        XCTAssertEqual(component.version, "1.24.0")
        XCTAssertEqual(component.requires, ["node"], "it is a Node program and pins no second runtime")
        XCTAssertEqual(
            manifest.installationOrder(for: "yaml-language-server").map(\.id),
            ["node", "yaml-language-server"],
            "the runtime installs first (D13)"
        )
        XCTAssertEqual(
            component.executableSubpath,
            "node_modules/yaml-language-server/out/server/src/server.js",
            "the entry point is the server module, not the package's `bin` shim"
        )

        let expected: [(String, String, Int)] = [
            ("yaml-language-server", "yaml-language-server-1.24.0.tgz", 646_765),
            ("ajv", "ajv-8.20.0.tgz", 217_611),
            ("ajv-draft-04", "ajv-draft-04-1.0.0.tgz", 8_735),
            ("ajv-i18n", "ajv-i18n-4.2.0.tgz", 25_980),
            ("@vscode/l10n", "l10n-0.0.18.tgz", 4_548),
            ("fast-deep-equal", "fast-deep-equal-3.1.3.tgz", 3_656),
            ("fast-uri", "fast-uri-3.1.5.tgz", 32_112),
            ("json-schema-traverse", "json-schema-traverse-1.0.0.tgz", 6_074),
            ("jsonc-parser", "jsonc-parser-3.3.1.tgz", 27_354),
            ("picomatch", "picomatch-4.0.5.tgz", 24_079),
            ("prettier", "prettier-3.9.6.tgz", 2_800_155),
            ("request-light", "request-light-0.5.8.tgz", 10_534),
            ("require-from-string", "require-from-string-2.0.2.tgz", 1_816),
            ("vscode-jsonrpc", "vscode-jsonrpc-8.2.0.tgz", 35_427),
            ("vscode-languageserver", "vscode-languageserver-9.0.1.tgz", 32_720),
            ("vscode-languageserver-protocol", "vscode-languageserver-protocol-3.17.5.tgz", 59_008),
            ("vscode-languageserver-textdocument", "vscode-languageserver-textdocument-1.0.13.tgz", 8_425),
            ("vscode-languageserver-types", "vscode-languageserver-types-3.17.5.tgz", 71_382),
            ("vscode-uri", "vscode-uri-3.1.0.tgz", 59_768),
            ("yaml", "yaml-2.8.3.tgz", 111_837),
        ]

        XCTAssertEqual(component.artifacts.count, expected.count, "the closure gained or lost a package")
        for (index, (package, fileName, byteCount)) in expected.enumerated() {
            guard index < component.artifacts.count else { break }
            let artifact = component.artifacts[index]
            XCTAssertEqual(artifact.url.lastPathComponent, fileName, "\(package) is pinned at another version")
            XCTAssertEqual(artifact.byteCount, byteCount, "\(package)'s download size is not what was measured")
            XCTAssertEqual(
                artifact.destinationSubpath, "node_modules/\(package)",
                "\(package) must land flat, where Node's upward walk from server.js looks"
            )
            XCTAssertEqual(artifact.format, .tarGzip)
            XCTAssertEqual(artifact.stripComponents, 1, "an npm tarball wraps its contents in `package/`")
            XCTAssertNil(artifact.architecture, "an npm tarball is architecture-independent")
        }

        // The figure the consent prompt puts in front of someone, per
        // architecture — identical on both, since nothing here is native.
        for architecture in LSPHostArchitecture.allCases {
            XCTAssertEqual(component.downloadByteCount(for: architecture), 4_187_986)
        }
    }

    /// The registry entry, in the shape the other two have — plus the one field
    /// no other server uses.
    ///
    /// `configuration` is the whole of why this server works at all. The pinned
    /// 1.24.0 bundle pulls `workspace/configuration` on `initialized`
    /// unconditionally, for `yaml`, `http`, `[yaml]`, `editor` and `files`; this
    /// value is what the `yaml` section is answered with, and `schemaStore.enable`
    /// is what makes a compose file complete from schemastore rather than from
    /// whatever the buffer happens to contain. Stated rather than left to
    /// upstream's default — which is `true` today, so the behaviour would work by
    /// luck and break silently on a pin bump.
    func testTheYAMLEntryRunsNodeOnTheServerAndCarriesItsSchemaStoreSetting() throws {
        let description = try XCTUnwrap(LSPDownloadableServer.yaml.serverDescription(manifest: manifest, layout: layout))
        let base = "/tmp/pisaka-servers"

        XCTAssertEqual(description.id, "yaml-language-server")
        XCTAssertEqual(description.languages, [.yaml])
        XCTAssertEqual(description.launch, .executable(path: "\(base)/node/24.19.0/bin/node"))
        XCTAssertEqual(description.arguments, [
            "\(base)/yaml-language-server/1.24.0/node_modules/yaml-language-server/out/server/src/server.js",
            "--stdio",
        ])
        XCTAssertNil(
            description.initializationOptions,
            "this server takes its settings on the configuration channels, not in `initialize`"
        )
        XCTAssertEqual(
            description.configuration,
            .object([
                "yaml": .object([
                    "schemaStore": .object(["enable": .bool(true)]),
                    "completion": .bool(true),
                    "hover": .bool(true),
                ])
            ]),
            "the section key must be `yaml` — it is what the server pulls, and an unnamed section is answered null"
        )
        XCTAssertNil(LSPDownloadableServer.yaml.tsserverSubpath, "there is no TypeScript in this server's story")
    }

    /// Three SPDX ids, pinned by hand for the reason pyright's two are: the
    /// heading `LSPInstalledLicenses` prints sits over the very texts below it, and
    /// a single "MIT" compiles, passes every other assertion here and captions
    /// `yaml`'s ISC and `fast-uri`'s BSD-3-Clause with the wrong license.
    ///
    /// The second half is the `@vscode/l10n` exception, asserted as a decision
    /// rather than left as an absence: the package publishes no license file at
    /// 0.0.18, so there is nothing inside the installed tree for the
    /// Acknowledgements surface to read, and the only honest record of that is a
    /// statement. The moment upstream ships one, both this and the exception in
    /// `testEveryComponentDeclaresALicenseItActuallyShips` fail.
    func testTheYAMLComponentNamesEveryLicenseItsClosureIsUnder() throws {
        let component = try XCTUnwrap(manifest.component("yaml-language-server"))
        XCTAssertEqual(component.licenseSPDX, "MIT AND ISC AND BSD-3-Clause")

        // Every notice found by the `tar tzf | grep` step, in upstream's own
        // spelling — three different casings appear across the closure and a path
        // this layer cannot read is dropped silently at display time.
        for subpath in [
            "node_modules/yaml/LICENSE",                                   // ISC
            "node_modules/fast-uri/LICENSE",                               // BSD-3-Clause
            "node_modules/prettier/THIRD-PARTY-NOTICES.md",                // a second notice
            "node_modules/vscode-jsonrpc/thirdpartynotices.txt",           // …and five more like it
            "node_modules/vscode-languageserver/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-protocol/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-textdocument/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-types/thirdpartynotices.txt",
            "node_modules/jsonc-parser/LICENSE.md",                        // .md
            "node_modules/require-from-string/license",                    // lowercase
            "node_modules/vscode-uri/LICENSE.md",
        ] {
            XCTAssertTrue(component.licenseFileSubpaths.contains(subpath), "“\(subpath)” is no longer acknowledged")
        }

        // One acknowledged text per package the component installs, except the
        // one that ships none.
        let packagesWithNoNotice = Set(
            component.artifacts
                .map(\.destinationSubpath)
                .filter { destination in
                    !component.licenseFileSubpaths.contains { $0.hasPrefix(destination + "/") }
                }
        )
        XCTAssertEqual(
            packagesWithNoNotice, ["node_modules/@vscode/l10n"],
            """
            @vscode/l10n 0.0.18 publishes no license file and is the stated exception; \
            anything else here ships one and it must be listed
            """
        )
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
