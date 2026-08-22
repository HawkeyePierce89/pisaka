import XCTest
@testable import PisakaCore

/// The install engine is the one place in this phase that can leave a machine in
/// a state nobody asked for — a half-unpacked server the registry reports as
/// installed, a working install destroyed by a failed upgrade, two downloads of a
/// 53 MB runtime because two languages wanted it at once. D13's staging discipline
/// exists for exactly those, and every one of them is asserted here rather than
/// argued for in a comment.
///
/// The manifest under test is a **fixture**, not `.standard`: the real pins are
/// checksums of real tarballs, and a suite that had to produce bytes hashing to
/// them would need the network the whole design exists to avoid. So the fixture's
/// checksums are the digests of the fake seams' canned bytes — the comparison is
/// what is under test here, and `SHA256Tests` is what pins the digest itself.
@MainActor
final class LSPInstallEngineTests: XCTestCase {
    // MARK: - The fixture manifest

    private enum Fixture {
        static let runtimeARM = URL(string: "https://example.invalid/runtime-1.0.0-arm64.tar.gz")!
        static let runtimeIntel = URL(string: "https://example.invalid/runtime-1.0.0-x64.tar.gz")!
        static let serverArchive = URL(string: "https://example.invalid/server-2.0.0.tgz")!
        static let helperArchive = URL(string: "https://example.invalid/helper-1.0.0.tgz")!
        static let bumpedServerArchive = URL(string: "https://example.invalid/server-3.0.0.tgz")!
        static let intelOnlyArchive = URL(string: "https://example.invalid/intel-only-1.0.0.tgz")!
        static let binaryArchive = URL(string: "https://example.invalid/tool-1.0.0-arm64.gz")!
        static let bumpedBinaryArchive = URL(string: "https://example.invalid/tool-2.0.0-arm64.gz")!

        static func artifact(
            _ url: URL,
            byteCount: Int,
            destinationSubpath: String = "",
            architecture: LSPHostArchitecture? = nil
        ) -> LSPArtifact {
            LSPArtifact(
                url: url,
                sha256: ScriptedArchive.checksum(for: url),
                byteCount: byteCount,
                unpackedByteCount: byteCount * 4,
                stripComponents: 1,
                destinationSubpath: destinationSubpath,
                architecture: architecture
            )
        }

        static let runtime = LSPComponent(
            id: "runtime",
            version: "1.0.0",
            licenseSPDX: "MIT",
            licenseFileSubpaths: ["LICENSE"],
            artifacts: [
                artifact(runtimeARM, byteCount: 1000, architecture: .arm64),
                artifact(runtimeIntel, byteCount: 1100, architecture: .x64)
            ],
            executableSubpath: "bin/runtime"
        )

        /// Two artifacts under one component, the `typescript-language-server`
        /// shape (D11): a server and the library it drives, installed and removed
        /// together.
        static let server = LSPComponent(
            id: "server",
            version: "2.0.0",
            licenseSPDX: "Apache-2.0",
            licenseFileSubpaths: ["node_modules/server/LICENSE"],
            artifacts: [
                artifact(serverArchive, byteCount: 200, destinationSubpath: "node_modules/server"),
                artifact(helperArchive, byteCount: 30, destinationSubpath: "node_modules/helper")
            ],
            requires: ["runtime"],
            executableSubpath: "node_modules/server/main.js"
        )

        /// The same component as a later app version pins it.
        static let bumpedServer = LSPComponent(
            id: "server",
            version: "3.0.0",
            licenseSPDX: "Apache-2.0",
            licenseFileSubpaths: ["node_modules/server/LICENSE"],
            artifacts: [
                artifact(bumpedServerArchive, byteCount: 210, destinationSubpath: "node_modules/server"),
                artifact(helperArchive, byteCount: 30, destinationSubpath: "node_modules/helper")
            ],
            requires: ["runtime"],
            executableSubpath: "node_modules/server/main.js"
        )

        static let intelOnly = LSPComponent(
            id: "intel-only",
            version: "1.0.0",
            licenseSPDX: "MIT",
            licenseFileSubpaths: [],
            artifacts: [artifact(intelOnlyArchive, byteCount: 10, architecture: .x64)]
        )

        /// A bare `.gz` of one executable — rust-analyzer's shape (D22), and the
        /// only artifact here that is not a tarball: no wrapper directory to
        /// strip, one file whose name the *manifest* supplies, and a mode the
        /// unpacker sets rather than the archive carrying.
        static func binaryArtifact(_ url: URL, byteCount: Int) -> LSPArtifact {
            LSPArtifact(
                url: url,
                sha256: ScriptedArchive.checksum(for: url),
                byteCount: byteCount,
                unpackedByteCount: byteCount * 4,
                format: .gzip(fileName: "tool"),
                stripComponents: 0,
                destinationSubpath: "bin",
                architecture: .arm64
            )
        }

        static let binary = LSPComponent(
            id: "binary",
            version: "1.0.0",
            licenseSPDX: "Apache-2.0 OR MIT",
            licenseFileSubpaths: [],
            artifacts: [binaryArtifact(binaryArchive, byteCount: 500)],
            executableSubpath: "bin/tool"
        )

        static let bumpedBinary = LSPComponent(
            id: "binary",
            version: "2.0.0",
            licenseSPDX: "Apache-2.0 OR MIT",
            licenseFileSubpaths: [],
            artifacts: [binaryArtifact(bumpedBinaryArchive, byteCount: 520)],
            executableSubpath: "bin/tool"
        )

        /// The by-hand pin edit that would escape the install root: the one field
        /// in this manifest that is concatenated onto a directory rather than
        /// computed by `LSPInstallLayout`.
        static let escapingBinary = LSPComponent(
            id: "escaping",
            version: "1.0.0",
            licenseSPDX: "Apache-2.0 OR MIT",
            licenseFileSubpaths: [],
            artifacts: [
                LSPArtifact(
                    url: escapingArchive,
                    sha256: ScriptedArchive.checksum(for: escapingArchive),
                    byteCount: 500,
                    unpackedByteCount: 2_000,
                    format: .gzip(fileName: "../../../tool"),
                    stripComponents: 0,
                    destinationSubpath: "bin",
                    architecture: .arm64
                )
            ],
            executableSubpath: "bin/tool"
        )

        static let escapingArchive = URL(string: "https://example.invalid/escaping-1.0.0.gz")!

        /// The *other* field the by-hand pin edit composes a path out of, and the
        /// one that escapes for **both** formats: an ordinary tarball whose
        /// `destinationSubpath` walks up out of the staging tree.
        static let escapingDestination = LSPComponent(
            id: "escaping-destination",
            version: "1.0.0",
            licenseSPDX: "MIT",
            licenseFileSubpaths: [],
            artifacts: [
                artifact(
                    escapingDestinationArchive,
                    byteCount: 40,
                    destinationSubpath: "../../../escape"
                )
            ]
        )

        static let escapingDestinationArchive =
            URL(string: "https://example.invalid/escaping-destination-1.0.0.tgz")!

        static let manifest = LSPProvisioningManifest(
            components: [runtime, server, intelOnly, binary, escapingBinary, escapingDestination]
        )
        static let bumpedManifest = LSPProvisioningManifest(
            components: [runtime, bumpedServer, bumpedBinary]
        )
    }

    // MARK: - The harness

    /// One install root, one file tree, one pair of seams — and an engine that can
    /// be rebuilt over all three, which is how "the app shipped a new manifest" is
    /// staged.
    private final class Harness {
        let root = URL(fileURLWithPath: "/Pisaka-tests")
        let tree: StubFileTree
        let downloader = ScriptedDownloader()
        let unpacker: ScriptedUnpacker
        let layout: LSPInstallLayout
        var engine: LSPInstallEngine

        @MainActor
        init(manifest: LSPProvisioningManifest = Fixture.manifest, architecture: LSPHostArchitecture = .arm64) {
            let root = URL(fileURLWithPath: "/Pisaka-tests")
            tree = StubFileTree(root: root, files: [:])
            unpacker = ScriptedUnpacker(writingInto: tree)
            layout = LSPInstallLayout(base: root.appendingPathComponent(LSPInstallLayout.directoryName))
            engine = LSPInstallEngine(
                manifest: manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: architecture
            )

            downloader.serve(Fixture.runtimeARM)
            downloader.serve(Fixture.runtimeIntel)
            downloader.serve(Fixture.serverArchive)
            downloader.serve(Fixture.helperArchive)
            downloader.serve(Fixture.bumpedServerArchive)
            downloader.serve(Fixture.intelOnlyArchive)
            downloader.serve(Fixture.binaryArchive)
            downloader.serve(Fixture.bumpedBinaryArchive)
            downloader.serve(Fixture.escapingArchive)
            downloader.serve(Fixture.escapingDestinationArchive)

            unpacker.stub(Fixture.runtimeARM, tree: ["bin/runtime": "#!runtime arm64", "LICENSE": "MIT"])
            unpacker.stub(Fixture.runtimeIntel, tree: ["bin/runtime": "#!runtime x64", "LICENSE": "MIT"])
            unpacker.stub(Fixture.serverArchive, tree: ["main.js": "server 2.0.0", "LICENSE": "Apache"])
            unpacker.stub(Fixture.helperArchive, tree: ["index.js": "helper 1.0.0"])
            unpacker.stub(Fixture.bumpedServerArchive, tree: ["main.js": "server 3.0.0", "LICENSE": "Apache"])
        }

        /// A second engine over the same disk and the same seams — a relaunch,
        /// optionally with a manifest whose pins have moved.
        @MainActor
        func rebuild(manifest: LSPProvisioningManifest) {
            engine = LSPInstallEngine(
                manifest: manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: engine.architecture
            )
        }

        /// A URL inside the install root as the stub tree spells it.
        func path(_ url: URL) -> String {
            String(url.path.dropFirst(root.path.count + 1))
        }

        func installedFiles(_ componentID: String, version: String) -> [String] {
            tree.filePaths(under: path(layout.versionDirectory(componentID: componentID, version: version)))
        }

        var stagingEntries: [String] {
            tree.filePaths(under: path(layout.stagingRoot))
        }
    }

    private func expectFailure(
        installing componentID: String,
        on engine: LSPInstallEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> LSPInstallError? {
        do {
            try await engine.install(componentID)
            XCTFail("the install succeeded; a failure was staged", file: file, line: line)
            return nil
        } catch let error as LSPInstallError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - The happy path, in the order D13 states

    func testTheSequenceVerifiesBeforeUnpackingAndFinishesWithOneMove() async throws {
        let harness = Harness()
        try await harness.engine.install("server")

        // Requirements first, and each artifact in manifest order.
        XCTAssertEqual(
            harness.downloader.requestedURLs,
            [Fixture.runtimeARM, Fixture.serverArchive, Fixture.helperArchive]
        )

        // What was unpacked is what was verified — the *bytes*, not just the URL.
        XCTAssertEqual(
            harness.unpacker.calls.map(\.archive),
            [Fixture.runtimeARM, Fixture.serverArchive, Fixture.helperArchive].map(ScriptedArchive.bytes)
        )
        XCTAssertEqual(harness.unpacker.calls.map(\.stripComponents), [1, 1, 1])
        XCTAssertEqual(harness.unpacker.calls.map(\.format), [.tarGzip, .tarGzip, .tarGzip])

        // Everything was unpacked into staging; the version directory came into
        // existence in one rename afterwards.
        for call in harness.unpacker.calls {
            XCTAssertTrue(
                call.destination.path.hasPrefix(harness.layout.stagingRoot.path + "/"),
                "\(call.destination.path) was unpacked outside .staging"
            )
        }
        XCTAssertEqual(harness.stagingEntries, [], "staging survived a successful install")

        XCTAssertEqual(
            harness.installedFiles("runtime", version: "1.0.0"),
            ["LanguageServers/runtime/1.0.0/LICENSE", "LanguageServers/runtime/1.0.0/bin/runtime"]
        )
        XCTAssertEqual(
            harness.installedFiles("server", version: "2.0.0"),
            [
                "LanguageServers/server/2.0.0/node_modules/helper/index.js",
                "LanguageServers/server/2.0.0/node_modules/server/LICENSE",
                "LanguageServers/server/2.0.0/node_modules/server/main.js"
            ]
        )

        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
        XCTAssertTrue(harness.engine.isInstalled("server"))
    }

    /// The executable each component advertises really is where the layout says —
    /// the property the registry entries are built on.
    func testTheInstalledTreeHoldsWhatTheRegistryWillNameLater() async throws {
        let harness = Harness()
        try await harness.engine.install("server")

        let runtimeExecutable = harness.layout.executable(of: Fixture.runtime)!
        let serverEntry = harness.layout.file("node_modules/server/main.js", of: Fixture.server)
        XCTAssertEqual(harness.tree.files[harness.path(runtimeExecutable)], "#!runtime arm64")
        XCTAssertEqual(harness.tree.files[harness.path(serverEntry)], "server 2.0.0")
        XCTAssertEqual(
            harness.tree.files[harness.path(harness.layout.licenseFiles(of: Fixture.runtime)[0])],
            "MIT"
        )
    }

    func testAReinstallOfSomethingAlreadyInstalledDownloadsNothing() async throws {
        let harness = Harness()
        try await harness.engine.install("server")
        let downloadsAfterFirst = harness.downloader.requestedURLs.count

        try await harness.engine.install("server")
        try await harness.engine.install("runtime")

        XCTAssertEqual(harness.downloader.requestedURLs.count, downloadsAfterFirst)
        XCTAssertEqual(harness.unpacker.calls.count, 3)
    }

    func testTheArchitectureDecidesWhichArtifactsAreFetched() async throws {
        let intel = Harness(architecture: .x64)
        try await intel.engine.install("runtime")

        XCTAssertEqual(intel.downloader.requestedURLs, [Fixture.runtimeIntel])
        XCTAssertEqual(intel.tree.files[intel.path(intel.layout.executable(of: Fixture.runtime)!)], "#!runtime x64")
    }

    func testAComponentWithNothingForThisSliceFailsWithoutDownloadingAnything() async {
        let harness = Harness()
        let error = await expectFailure(installing: "intel-only", on: harness.engine)

        XCTAssertEqual(error, .unsupportedArchitecture(component: "intel-only", architecture: .arm64))
        XCTAssertEqual(harness.downloader.requestedURLs, [])
        XCTAssertEqual(harness.engine.state(of: "intel-only"), .absent)
    }

    /// A component the manifest does not describe installs nothing and does not
    /// fail — this layer's uniform answer to malformed data is absence.
    func testAnUnknownComponentInstallsNothing() async throws {
        let harness = Harness()
        try await harness.engine.install("no-such-component")

        XCTAssertEqual(harness.downloader.requestedURLs, [])
        XCTAssertEqual(harness.engine.state(of: "no-such-component"), .absent)
        XCTAssertFalse(harness.engine.isInstalled("no-such-component"))
    }

    // MARK: - Checksums

    func testAChecksumMismatchLeavesNothingBehindAndIsNotRetried() async {
        let harness = Harness()
        harness.downloader.serve(Fixture.serverArchive, bytes: Data("something else entirely".utf8))

        let error = await expectFailure(installing: "server", on: harness.engine)
        XCTAssertEqual(error, .checksumMismatch(component: "server", url: Fixture.serverArchive))

        // Rejected *before* the unpack: the bytes never reached the file system.
        XCTAssertEqual(harness.unpacker.calls.map(\.archive), [ScriptedArchive.bytes(for: Fixture.runtimeARM)])
        XCTAssertEqual(harness.stagingEntries, [])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/server/2.0.0"))
        XCTAssertEqual(harness.engine.state(of: "server"), .absent)

        // One attempt, one fetch: a mirror serving the wrong bytes will serve them
        // again, so there is no retry loop here.
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.serverArchive), 1)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.helperArchive), 0)
    }

    // MARK: - Every failure path, from nothing and from an install

    /// Where an attempt can go wrong, and how each one is staged. The point of
    /// sweeping all four is that D13's promise is about the *sequence*, not about
    /// any one step: whichever one fails, the disk is left as it was found.
    private enum Injection: CaseIterable {
        case download
        case checksum
        case unpack
        case move

        var expectedComponent: String { "server" }
    }

    private func stage(_ injection: Injection, on harness: Harness, archive: URL, versionPath: String) {
        switch injection {
        case .download:
            harness.downloader.fail(archive)
        case .checksum:
            harness.downloader.serve(archive, bytes: Data("not the pinned bytes".utf8))
        case .unpack:
            harness.unpacker.fail(archive)
        case .move:
            harness.tree.moveFailures.insert(versionPath)
        }
    }

    func testEveryFailurePathLeavesNothingWhenNothingWasInstalled() async {
        for injection in Injection.allCases {
            let harness = Harness()
            stage(
                injection,
                on: harness,
                archive: Fixture.serverArchive,
                versionPath: "LanguageServers/server/2.0.0"
            )

            let error = await expectFailure(installing: "server", on: harness.engine)
            XCTAssertNotNil(error, "\(injection)")

            XCTAssertEqual(harness.engine.state(of: "server"), .absent, "\(injection)")
            XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/server/2.0.0"), "\(injection)")
            XCTAssertEqual(harness.stagingEntries, [], "\(injection): staging survived a failure")
            XCTAssertTrue(
                harness.tree.directories.filter { $0.hasPrefix("LanguageServers/.staging/") }.isEmpty,
                "\(injection): a staging directory survived a failure"
            )
            // The requirement installed before the failure is untouched: it is a
            // complete, verified component in its own right.
            XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"), "\(injection)")
        }
    }

    func testEveryFailurePathLeavesAPreviousInstallByteForByte() async throws {
        for injection in Injection.allCases {
            let harness = Harness()
            try await harness.engine.install("server")
            let installed = harness.tree.files
            let downloadsBefore = harness.downloader.requestedURLs.count

            // The app ships a new version whose pin has moved, and the upgrade
            // fails at `injection`.
            harness.rebuild(manifest: Fixture.bumpedManifest)
            stage(
                injection,
                on: harness,
                archive: Fixture.bumpedServerArchive,
                versionPath: "LanguageServers/server/3.0.0"
            )

            let error = await expectFailure(installing: "server", on: harness.engine)
            XCTAssertNotNil(error, "\(injection)")

            XCTAssertEqual(harness.tree.files, installed, "\(injection): the previous install was disturbed")
            XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"), "\(injection)")
            XCTAssertEqual(harness.stagingEntries, [], "\(injection)")
            XCTAssertGreaterThan(harness.downloader.requestedURLs.count, downloadsBefore, "\(injection)")

            // And the old tree is still *usable*, which is the claim that matters:
            // every path the previous manifest's registry entry names is there.
            let previous = LSPInstallLayout(base: harness.layout.base)
            XCTAssertEqual(
                harness.tree.files[harness.path(previous.file("node_modules/server/main.js", of: Fixture.server))],
                "server 2.0.0",
                "\(injection)"
            )
        }
    }

    // MARK: - Version bumps

    func testAVersionBumpInstallsBesideAndThenRemovesTheOldVersion() async throws {
        let harness = Harness()
        try await harness.engine.install("server")

        harness.rebuild(manifest: Fixture.bumpedManifest)
        // Before the upgrade the old tree is reported as installed — it is really
        // there — but it is not the pinned version, so nothing may be served from
        // it.
        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertFalse(harness.engine.isInstalled("server"))

        try await harness.engine.install("server")

        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "3.0.0"))
        XCTAssertTrue(harness.engine.isInstalled("server"))
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/server/2.0.0"), "the old version was left behind")
        XCTAssertEqual(
            harness.tree.files[harness.path(harness.layout.file("node_modules/server/main.js", of: Fixture.bumpedServer))],
            "server 3.0.0"
        )
        // The old version's deletion happens after the rename, so it is a delete
        // of one directory and not of the component's.
        XCTAssertTrue(harness.tree.removedPaths.contains("LanguageServers/server/2.0.0"))
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/server/3.0.0"))

        // The shared runtime is untouched and was not fetched twice.
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
    }

    // MARK: - Coalescing

    func testTwoInstallsOfOneComponentPerformOneDownloadAndBothSeeTheResult() async throws {
        let harness = Harness()
        let gate = Gate()
        harness.downloader.hold(Fixture.runtimeARM, on: gate)

        let first = Task { try await harness.engine.install("runtime") }
        await gate.waitUntilReached()

        // The in-flight table, not the disk: nothing has been written yet.
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installing)
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/runtime/1.0.0"))

        // The second caller reports what it saw on the way in. Without that, a
        // second call that happened to arrive *after* the first finished would
        // take the already-installed fast path, download nothing, and pass this
        // test while exercising no coalescing at all.
        let second = Task { () -> Bool in
            let overlapped = harness.engine.state(of: "runtime") == .installing
            try await harness.engine.install("runtime")
            return overlapped
        }
        // Let the second call reach the coalescing point before the first is
        // allowed to finish.
        await Task.yield()

        gate.release()
        try await first.value
        let overlapped = try await second.value
        XCTAssertTrue(overlapped, "the second install did not overlap the first")

        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)
        XCTAssertEqual(harness.unpacker.calls.count, 1)
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
    }

    /// A coalesced failure is a failure for *both* callers — the second one must
    /// not read "somebody else is installing it" as success.
    func testACoalescedFailureIsRaisedToBothCallers() async {
        let harness = Harness()
        let gate = Gate()
        harness.downloader.fail(Fixture.runtimeARM)
        harness.downloader.hold(Fixture.runtimeARM, on: gate)

        let first = Task { try await harness.engine.install("runtime") }
        await gate.waitUntilReached()
        let second = Task { try await harness.engine.install("runtime") }
        await Task.yield()
        gate.release()

        var failures = 0
        for task in [first, second] {
            do {
                try await task.value
            } catch let error as LSPInstallError {
                failures += 1
                XCTAssertEqual(error, .downloadFailed(
                    component: "runtime",
                    reason: ScriptedDownloader.Failure.offline.localizedDescription
                ))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)
        XCTAssertEqual(harness.engine.state(of: "runtime"), .absent)
    }

    // MARK: - Requirements

    func testARuntimeFailureAbortsTheServerInstall() async {
        let harness = Harness()
        harness.downloader.fail(Fixture.runtimeARM)

        let error = await expectFailure(installing: "server", on: harness.engine)
        XCTAssertEqual(error, .downloadFailed(
            component: "runtime",
            reason: ScriptedDownloader.Failure.offline.localizedDescription
        ))

        // The server's own artifacts were never fetched: half a server is worse
        // than none, since its registry entry would name a runtime that is absent.
        XCTAssertEqual(harness.downloader.requestedURLs, [Fixture.runtimeARM])
        XCTAssertEqual(harness.engine.state(of: "server"), .absent)
        XCTAssertEqual(harness.engine.state(of: "runtime"), .absent)
        XCTAssertFalse(harness.engine.isInstalled(.typescript))
    }

    func testAnAlreadyInstalledRuntimeIsNotFetchedForASecondServer() async throws {
        let harness = Harness()
        try await harness.engine.install("runtime")
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)

        try await harness.engine.install("server")
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)
        XCTAssertTrue(harness.engine.isInstalled("server"))
    }

    // MARK: - Sizes

    func testThePendingDownloadSizeCountsOnlyWhatIsMissing() async throws {
        let harness = Harness()
        XCTAssertEqual(harness.engine.pendingDownloadByteCount(for: "server"), 1000 + 200 + 30)

        try await harness.engine.install("runtime")
        XCTAssertEqual(harness.engine.pendingDownloadByteCount(for: "server"), 200 + 30)

        try await harness.engine.install("server")
        XCTAssertEqual(harness.engine.pendingDownloadByteCount(for: "server"), 0)
    }

    // MARK: - Removal

    func testRemovingDropsEveryVersionAndIsANoOpWhenNothingIsInstalled() async throws {
        let harness = Harness()
        try harness.engine.remove("server")
        XCTAssertEqual(harness.tree.removedPaths, [], "removing an absent component touched the disk")

        try await harness.engine.install("server")
        try harness.engine.remove("server")

        XCTAssertEqual(harness.engine.state(of: "server"), .absent)
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/server"))
        // The shared runtime is *not* removed with it: deciding that nothing else
        // needs it is the model's job, not the engine's.
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
    }

    func testARemovedServerCanBeInstalledAgain() async throws {
        let harness = Harness()
        try await harness.engine.install("server")
        try harness.engine.remove("server")
        try await harness.engine.install("server")

        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.serverArchive), 2)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.runtimeARM), 1)
    }

    // MARK: - Sweeping

    func testSweepingRemovesLeftoverStagingAndNothingElse() async throws {
        let harness = Harness()
        try await harness.engine.install("server")

        // What a crash mid-install leaves: a half-written tree under `.staging`
        // that nothing reads and nothing would ever finish.
        harness.tree.files["LanguageServers/.staging/server-2.0.0-9/node_modules/server/main.js"] = "half"
        try harness.tree.ensureDirectory(
            at: harness.layout.stagingDirectory(componentID: "runtime", version: "1.0.0", token: 4)
        )

        harness.engine.sweepStaging()

        XCTAssertEqual(harness.stagingEntries, [])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/.staging/server-2.0.0-9"))
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/.staging/runtime-1.0.0-4"))
        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
        XCTAssertEqual(
            harness.installedFiles("server", version: "2.0.0").count, 3,
            "the sweep reached outside .staging"
        )
    }

    /// The sweep is best-effort, so the install may not lean on it having worked.
    ///
    /// This is the across-launches case the staging *token* cannot cover: the
    /// counter restarts at zero every run, so the first attempt of a run
    /// recomputes the exact path a crashed attempt of the previous run left
    /// occupied — and `ensureDirectory` succeeds on a directory that is already
    /// there. Staged as the sweep failing (`removeFailures`) and then being
    /// removed, which is what a permissions blip or a file the volume would not
    /// release looks like from here: the leftover survives the sweep, the install
    /// runs anyway, and none of the previous attempt's files may reach the version
    /// directory the single `move` commits.
    func testAnInstallDoesNotAdoptALeftoverStagingTreeTheSweepCouldNotRemove() async throws {
        let harness = Harness()

        // What a force-quit mid-unpack left behind, at the very path this run's
        // first attempt will compute (`runtime` installs first, token 1).
        let leftover = "LanguageServers/.staging/runtime-1.0.0-1"
        harness.tree.files["\(leftover)/bin/runtime"] = "#!truncated"
        harness.tree.files["\(leftover)/bin/orphan"] = "from the attempt that died"

        harness.tree.removeFailures.insert(leftover)
        harness.engine.sweepStaging()
        XCTAssertTrue(harness.tree.hasDirectory(leftover), "the sweep was supposed to fail here")

        harness.tree.removeFailures.remove(leftover)
        try await harness.engine.install("runtime")

        XCTAssertEqual(
            harness.installedFiles("runtime", version: "1.0.0"),
            ["LanguageServers/runtime/1.0.0/LICENSE", "LanguageServers/runtime/1.0.0/bin/runtime"],
            "a file from the previous attempt was committed by the rename"
        )
        XCTAssertEqual(
            harness.tree.files["LanguageServers/runtime/1.0.0/bin/runtime"], "#!runtime arm64",
            "the truncated file survived instead of being replaced"
        )
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// The sweep against a listing spelled through a symlink — the shape the
    /// re-derivation in `sweepStaging` exists for, and the only one in which a
    /// correct leftover reads as outside the install root.
    ///
    /// `FileManager.contentsOfDirectory(at:)` resolves the parent's symlinks in
    /// the URLs it returns, while `layout.base` is whatever the caller spelled
    /// and this file's path math is lexical and may not stat — so an install root
    /// under `/tmp` lists its own staging tree as `/private/tmp/…`, which
    /// `mayDelete` refuses. Taking the entry's *name* and re-rooting it is what
    /// keeps both sides derived from one `base`; without it the sweep silently
    /// deletes nothing, and a predicate that only ever refuses leaves no trace.
    func testSweepingRemovesLeftoversEvenWhenTheListingSpellsThemThroughASymlink() async throws {
        let harness = Harness()
        try await harness.engine.install("server")
        harness.tree.files["LanguageServers/.staging/server-2.0.0-9/node_modules/server/main.js"] = "half"
        // The same tree, re-spelled the way the real file manager hands it back.
        harness.tree.listingSpelling = { URL(fileURLWithPath: "/private" + $0.path) }

        harness.engine.sweepStaging()

        XCTAssertEqual(harness.tree.removedPaths, ["LanguageServers/.staging/server-2.0.0-9"])
        XCTAssertEqual(harness.stagingEntries, [])
        XCTAssertEqual(
            harness.installedFiles("server", version: "2.0.0").count, 3,
            "the sweep reached outside .staging"
        )
    }

    /// A launch on a machine that has provisioned servers and crashed on none of
    /// them. Both shapes have to be no-ops over an installed tree rather than an
    /// error or a deletion: the staging root absent (nothing was ever installed on
    /// this volume, so the listing throws) and the staging root present but empty
    /// (what every successful install leaves behind, since the tree it built was
    /// renamed out of it).
    func testSweepingAnEmptyOrAbsentStagingRootLeavesEveryInstallAlone() async throws {
        let absent = Harness()
        XCTAssertFalse(absent.tree.hasDirectory("LanguageServers/.staging"))
        absent.engine.sweepStaging()
        XCTAssertEqual(absent.tree.removedPaths, [])

        let harness = Harness()
        try await harness.engine.install("server")
        let installed = harness.tree.filePaths(under: "LanguageServers")
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/.staging"))
        XCTAssertEqual(harness.stagingEntries, [], "the install left its staging tree behind")

        harness.engine.sweepStaging()

        XCTAssertEqual(harness.tree.removedPaths, [])
        XCTAssertEqual(harness.tree.filePaths(under: "LanguageServers"), installed)
        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
    }

    // MARK: - Containment

    /// Every deletion this engine makes is asserted to be inside `layout.base`
    /// first, and the assertions are not decoration: the ids they guard come from
    /// a manifest, and a manifest is data that can be hand-edited. A component id
    /// that walks out of the install root must delete *nothing* — not the user's
    /// files, and not the install root itself.
    func testNothingOutsideTheInstallRootIsEverDeleted() async throws {
        let harness = Harness()
        try await harness.engine.install("server")
        harness.tree.files["Documents/notes.txt"] = "the user's"
        let before = harness.tree.filePaths(under: "")

        for escaping in ["../..", "../../Documents", "..", "../LanguageServers"] {
            try harness.engine.remove(escaping)
        }

        XCTAssertEqual(harness.tree.removedPaths, [], "a deletion escaped the install root")
        XCTAssertEqual(harness.tree.filePaths(under: ""), before)
        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
    }

    /// The same guard on the sweep, which is the one place the engine deletes
    /// something it did not compute the path of: the entries come from a listing,
    /// and an entry that resolves outside the root is skipped rather than removed.
    func testTheSweepSkipsAnythingThatResolvesOutsideTheInstallRoot() async throws {
        let harness = Harness()
        try await harness.engine.install("server")
        harness.tree.files["Documents/notes.txt"] = "the user's"

        // A `.staging` entry whose name walks back out of the root — what a
        // symlink or a hand-made directory would produce in a listing.
        harness.tree.files["LanguageServers/.staging/../../Documents/planted.txt"] = "planted"
        harness.tree.files["LanguageServers/.staging/real-1.0.0-1/payload"] = "leftover"

        harness.engine.sweepStaging()

        XCTAssertEqual(harness.tree.removedPaths, ["LanguageServers/.staging/real-1.0.0-1"])
        XCTAssertEqual(harness.tree.files["Documents/notes.txt"], "the user's")
        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
    }

    // MARK: - The gzip format and the executable gate (D22)

    func testAGzipArtifactInstallsAsOneExecutableFileInOneRename() async throws {
        let harness = Harness()
        try await harness.engine.install("binary")

        // The format travels to the seam whole — the file's name is *in* it,
        // because a bare `.gz` carries no name of its own — and the strip depth
        // the manifest states for it is 0, which the unpacker ignores.
        XCTAssertEqual(harness.unpacker.calls.map(\.format), [.gzip(fileName: "tool")])
        XCTAssertEqual(harness.unpacker.calls.map(\.stripComponents), [0])
        XCTAssertTrue(
            harness.unpacker.calls[0].destination.path.hasPrefix(harness.layout.stagingRoot.path + "/")
        )

        XCTAssertEqual(harness.installedFiles("binary", version: "1.0.0"), ["LanguageServers/binary/1.0.0/bin/tool"])
        XCTAssertEqual(harness.tree.moves.count, 1, "the version directory took more than one rename")
        XCTAssertEqual(harness.engine.state(of: "binary"), .installed(version: "1.0.0"))
        XCTAssertTrue(harness.engine.isInstalled("binary"))
        XCTAssertEqual(harness.stagingEntries, [])

        // What the whole format exists to promise: the installed file can be run.
        let executable = try XCTUnwrap(harness.layout.executable(of: Fixture.binary))
        XCTAssertTrue(harness.tree.isExecutableFile(at: executable))
    }

    /// The gate itself: an unpack that reports success and produces a file nobody
    /// can run must install *nothing*.
    ///
    /// Everything before the rename is the same as a successful install — the
    /// bytes verified, the staging tree written — so this is the one failure D13's
    /// sequence could not see on its own, and the reason it is checked before
    /// `commit` rather than after.
    func testAGzipUnpackThatForgetsTheModeCommitsNothing() async {
        let harness = Harness()
        harness.unpacker.forgetExecutableMode(Fixture.binaryArchive)

        let error = await expectFailure(installing: "binary", on: harness.engine)
        guard case let .unpackFailed(component, reason) = error else {
            return XCTFail("expected an unpack failure, got \(String(describing: error))")
        }
        XCTAssertEqual(component, "binary")
        XCTAssertTrue(reason.contains("tool"), "the message does not name the file: \(reason)")
        XCTAssertTrue(reason.contains("executable"), "the message does not say why: \(reason)")

        // Not renamed, not partially installed, and nothing left under staging.
        XCTAssertEqual(harness.tree.moves, [])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/binary/1.0.0"))
        XCTAssertEqual(harness.engine.state(of: "binary"), .absent)
        XCTAssertFalse(harness.engine.isInstalled("binary"))
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// And the same failure over a working install leaves it exactly as it was —
    /// D13's promise, now covering the gate as well as the four steps before it.
    func testAGzipUpgradeThatForgetsTheModeLeavesThePreviousInstallByteForByte() async throws {
        let harness = Harness()
        try await harness.engine.install("binary")
        let installed = harness.tree.files

        harness.rebuild(manifest: Fixture.bumpedManifest)
        harness.unpacker.forgetExecutableMode(Fixture.bumpedBinaryArchive)

        let error = await expectFailure(installing: "binary", on: harness.engine)
        XCTAssertNotNil(error)

        XCTAssertEqual(harness.tree.files, installed, "the previous install was disturbed")
        XCTAssertEqual(harness.engine.state(of: "binary"), .installed(version: "1.0.0"))
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/binary/2.0.0"))
        XCTAssertEqual(harness.stagingEntries, [])
        // Still runnable: the gate rejected the new tree, not the old one.
        XCTAssertTrue(harness.tree.isExecutableFile(at: harness.tree.url("LanguageServers/binary/1.0.0/bin/tool")))
    }

    /// D12's containment rule applied to the `.gzip` case's file name — one of the
    /// two manifest fields a path is composed out of, and the one the containment
    /// test cannot see, because the unpacker appends it after this layer has handed
    /// the destination over.
    ///
    /// The unpacker writes `destination.appendingPathComponent(fileName)` and
    /// creates it `0o755`, so a `fileName` that walks upwards would put an
    /// executable outside the install root — and the mode gate would then confirm
    /// it and let `commit` proceed. Refused **before** the unpack rather than
    /// after, because after is a file that already exists: nothing here can
    /// un-write it, and the whole promise is that the install root is the only
    /// thing this app touches.
    func testAGzipArtifactThatNamesAPathOutsideItsDestinationIsRefusedBeforeTheUnpack() async {
        let harness = Harness()

        let error = await expectFailure(installing: "escaping", on: harness.engine)
        guard case let .unpackFailed(component, reason) = error else {
            return XCTFail("expected an unpack failure, got \(String(describing: error))")
        }
        XCTAssertEqual(component, "escaping")
        XCTAssertTrue(reason.contains("../../../tool"), "the message does not name it: \(reason)")

        XCTAssertEqual(
            harness.unpacker.calls.count, 0,
            "the unpacker was handed a destination it should never have been asked to write"
        )
        XCTAssertEqual(harness.tree.moves, [])
        XCTAssertEqual(harness.engine.state(of: "escaping"), .absent)
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// The other manifest field, and the one that escapes for **every** format:
    /// `destinationSubpath` is split and appended onto the staging directory, so
    /// `"../../../escape"` names a directory outside the install root that
    /// `ensureDirectory` would create and `tar` would then unpack into — no `.gzip`
    /// required.
    ///
    /// Refused before the directory exists, not merely before the unpack: creating
    /// it is already a write outside the one tree this app promises to touch, and
    /// `discard(staging)` cannot reach it afterwards because it is not under
    /// staging.
    func testAnArtifactWhoseDestinationEscapesTheStagingTreeIsRefusedBeforeAnythingIsCreated() async {
        let harness = Harness()

        let error = await expectFailure(installing: "escaping-destination", on: harness.engine)
        guard case let .unpackFailed(component, reason) = error else {
            return XCTFail("expected an unpack failure, got \(String(describing: error))")
        }
        XCTAssertEqual(component, "escaping-destination")
        XCTAssertTrue(reason.contains("../../../escape"), "the message does not name it: \(reason)")

        XCTAssertFalse(
            harness.tree.hasDirectory("escape"),
            "a directory was created outside the install root"
        )
        XCTAssertEqual(
            harness.unpacker.calls.count, 0,
            "the unpacker was handed a destination it should never have been asked to write"
        )
        XCTAssertEqual(harness.tree.moves, [])
        XCTAssertEqual(harness.engine.state(of: "escaping-destination"), .absent)
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// And a destination that stays inside the install root but walks *out of the
    /// attempt's staging directory* is refused for the same reason: it would write
    /// into an installed version directory, where `discard` will not clean it up
    /// and D13's "the previous install is exactly as it was" quietly stops being
    /// true.
    func testAnArtifactWhoseDestinationLeavesStagingForAnInstalledTreeIsRefused() async throws {
        let harness = Harness()
        try await harness.engine.install("binary")
        let installed = harness.tree.files
        let unpacksSoFar = harness.unpacker.calls.count

        let manifest = LSPProvisioningManifest(
            components: [
                LSPComponent(
                    id: "sideways",
                    version: "1.0.0",
                    licenseSPDX: "MIT",
                    licenseFileSubpaths: [],
                    artifacts: [
                        Fixture.artifact(
                            Fixture.escapingDestinationArchive,
                            byteCount: 40,
                            destinationSubpath: "../../binary/1.0.0/bin"
                        )
                    ]
                )
            ]
        )
        harness.rebuild(manifest: manifest)

        let error = await expectFailure(installing: "sideways", on: harness.engine)
        guard case .unpackFailed = error else {
            return XCTFail("expected an unpack failure, got \(String(describing: error))")
        }

        XCTAssertEqual(harness.tree.files, installed, "the previous install was disturbed")
        XCTAssertEqual(
            harness.unpacker.calls.count, unpacksSoFar,
            "the unpacker was handed a destination inside an installed tree"
        )
        XCTAssertEqual(harness.engine.state(of: "binary"), .installed(version: "1.0.0"))
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// The gate does not replace the digest, it follows it: a `.gzip` artifact
    /// whose bytes are not the pinned bytes is still rejected before anything is
    /// unpacked at all.
    func testAGzipDownloadThatFailsItsChecksumNeverReachesTheUnpacker() async {
        let harness = Harness()
        harness.downloader.serve(Fixture.binaryArchive, bytes: Data("not the pinned bytes".utf8))

        let error = await expectFailure(installing: "binary", on: harness.engine)
        XCTAssertEqual(error, .checksumMismatch(component: "binary", url: Fixture.binaryArchive))

        XCTAssertEqual(harness.unpacker.calls, [])
        XCTAssertEqual(harness.tree.moves, [])
        XCTAssertEqual(harness.engine.state(of: "binary"), .absent)
        XCTAssertEqual(harness.stagingEntries, [])
    }

    /// The gate is `.gzip`'s alone. A tarball's entry point is a script run as an
    /// argument to a runtime, so executability is not what makes it work — and a
    /// gate applied to every format would fail every install this layer already
    /// performs.
    func testTarballComponentsInstallUnchangedAndAreNotAskedToBeExecutable() async throws {
        let harness = Harness()
        try await harness.engine.install("server")

        XCTAssertEqual(harness.engine.state(of: "server"), .installed(version: "2.0.0"))
        XCTAssertEqual(harness.engine.state(of: "runtime"), .installed(version: "1.0.0"))
        XCTAssertTrue(harness.unpacker.calls.allSatisfy { $0.format == .tarGzip })

        // Nothing the tar path wrote is executable in this tree, and it installed
        // anyway — which is the assertion, not an accident of the stub.
        let entry = harness.layout.file("node_modules/server/main.js", of: Fixture.server)
        XCTAssertFalse(harness.tree.isExecutableFile(at: entry))
        XCTAssertTrue(harness.engine.isInstalled("server"))
    }

    // MARK: - The error messages

    /// Every failure this engine can report reaches a Settings row through
    /// `localizedDescription`, so each case has to say something — a raw enum
    /// falls back to "operation couldn't be completed (error N)".
    func testEveryFailureCarriesAUserFacingMessage() {
        let errors: [LSPInstallError] = [
            .checksumMismatch(component: "node", url: Fixture.runtimeARM),
            .downloadFailed(component: "node", reason: "The Internet connection appears to be offline."),
            .unpackFailed(component: "pyright", reason: "The archive could not be read."),
            .unsupportedArchitecture(component: "node", architecture: .arm64),
            .fileSystemFailed(component: "node", reason: "Permission denied.")
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(
                message.contains("PisakaCore"),
                "\(error) fell back to the generic NSError description"
            )
        }
    }
}
