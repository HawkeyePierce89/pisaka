import XCTest
@testable import PisakaCore

/// The model is where consent, the install engine and 2a's registry meet, so it
/// is where the rules that are *promises to the user* live: nothing downloads
/// without an answer, an answer is given once, a failure is a sentence in a
/// Settings row and nothing else, and a removal stops the process before it
/// deletes the executable.
///
/// **The manifest under test is a fixture with the real component ids.** The
/// pins in `.standard` are checksums of real tarballs, and a suite able to
/// produce bytes hashing to them would need the network this whole design exists
/// to avoid (`LSPInstallEngineTests` says the same). But the ids, versions and
/// entry-point subpaths are exactly the real ones, because
/// `LSPDownloadableServer` names components by id: this fixture is what lets
/// `.typescript` resolve, install and become a registry entry with no network in
/// sight, and it is the only reason the registry assertions below are about the
/// shipped enum rather than about a stand-in.
@MainActor
final class LSPProvisioningModelTests: XCTestCase {
    // MARK: - The fixture manifest

    private enum Fixture {
        static let nodeARM = URL(string: "https://example.invalid/node-arm64.tar.gz")!
        static let nodeIntel = URL(string: "https://example.invalid/node-x64.tar.gz")!
        static let tsServer = URL(string: "https://example.invalid/typescript-language-server.tgz")!
        static let typescript = URL(string: "https://example.invalid/typescript.tgz")!
        static let pyright = URL(string: "https://example.invalid/pyright.tgz")!
        static let fsevents = URL(string: "https://example.invalid/fsevents.tgz")!

        static let nodeBytes = 52_234_372
        static let tsServerBytes = 501_633
        static let typescriptBytes = 4_377_468
        static let pyrightBytes = 4_139_958
        static let fseventsBytes = 22_808

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
                destinationSubpath: destinationSubpath,
                architecture: architecture
            )
        }

        static let node = LSPComponent(
            id: "node",
            version: "24.19.0",
            licenseSPDXID: "MIT",
            licenseFileSubpaths: ["LICENSE"],
            artifacts: [
                artifact(nodeARM, byteCount: nodeBytes, architecture: .arm64),
                artifact(nodeIntel, byteCount: nodeBytes, architecture: .x64),
            ],
            executableSubpath: "bin/node"
        )

        static let typescriptLanguageServer = LSPComponent(
            id: "typescript-language-server",
            version: "5.3.0",
            licenseSPDXID: "Apache-2.0",
            licenseFileSubpaths: ["node_modules/typescript-language-server/LICENSE"],
            artifacts: [
                artifact(
                    tsServer,
                    byteCount: tsServerBytes,
                    destinationSubpath: "node_modules/typescript-language-server"
                ),
                artifact(
                    typescript,
                    byteCount: typescriptBytes,
                    destinationSubpath: "node_modules/typescript"
                ),
            ],
            requires: ["node"],
            executableSubpath: "node_modules/typescript-language-server/lib/cli.mjs"
        )

        static let pyrightComponent = LSPComponent(
            id: "pyright",
            version: "1.1.411",
            licenseSPDXID: "MIT",
            licenseFileSubpaths: ["node_modules/pyright/LICENSE.txt"],
            artifacts: [
                artifact(pyright, byteCount: pyrightBytes, destinationSubpath: "node_modules/pyright"),
                artifact(fsevents, byteCount: fseventsBytes, destinationSubpath: "node_modules/fsevents"),
            ],
            requires: ["node"],
            executableSubpath: "node_modules/pyright/dist/pyright-langserver.js"
        )

        static let manifest = LSPProvisioningManifest(
            components: [node, typescriptLanguageServer, pyrightComponent]
        )

        /// Every artifact of the real manifest is represented, so an install that
        /// stops early is visible as a missing request rather than as a shorter
        /// list nobody counted.
        static let allURLs = [nodeARM, nodeIntel, tsServer, typescript, pyright, fsevents]
    }

    // MARK: - The harness

    /// One install root, one settings suite, and a model over both — rebuildable,
    /// which is how "the answer survived a relaunch" and "the registry is derived
    /// from the disk at launch" are staged.
    private final class Harness {
        let root = URL(fileURLWithPath: "/Pisaka-tests")
        let tree: StubFileTree
        let downloader = ScriptedDownloader()
        let unpacker: ScriptedUnpacker
        let layout: LSPInstallLayout
        let defaults: UserDefaults
        private let suiteName: String

        private(set) var engine: LSPInstallEngine
        private(set) var settings: SettingsStore
        private(set) var model: LSPProvisioningModel

        /// Every registry the model pushed, and — for each — whether the
        /// TypeScript server's files were still on disk when it was pushed. The
        /// second half is what pins D16's ordering: the removal's push has to
        /// arrive while the executable it names still exists, because the push is
        /// what stops the process running from it.
        private(set) var pushes: [(registry: LSPServerRegistry, typescriptFilesPresent: Bool)] = []

        @MainActor
        init(name: String, architecture: LSPHostArchitecture = .arm64) {
            let root = URL(fileURLWithPath: "/Pisaka-tests")
            tree = StubFileTree(root: root, files: [:])
            unpacker = ScriptedUnpacker(writingInto: tree)
            layout = LSPInstallLayout(base: root.appendingPathComponent(LSPInstallLayout.directoryName))

            suiteName = "LSPProvisioningModelTests.\(name)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)

            engine = LSPInstallEngine(
                manifest: Fixture.manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: architecture
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPProvisioningModel(engine: engine, settings: settings)

            for url in Fixture.allURLs { downloader.serve(url) }
            unpacker.stub(Fixture.nodeARM, tree: ["bin/node": "#!node arm64", "LICENSE": "MIT"])
            unpacker.stub(Fixture.nodeIntel, tree: ["bin/node": "#!node x64", "LICENSE": "MIT"])
            unpacker.stub(Fixture.tsServer, tree: ["lib/cli.mjs": "tsserver-lsp", "LICENSE": "Apache"])
            unpacker.stub(Fixture.typescript, tree: ["lib/tsserver.js": "tsserver"])
            unpacker.stub(Fixture.pyright, tree: ["dist/pyright-langserver.js": "pyright", "LICENSE.txt": "MIT"])
            unpacker.stub(Fixture.fsevents, tree: ["fsevents.node": "native"])

            observe()
        }

        /// A relaunch: a second engine, store and model over the same disk and the
        /// same defaults suite.
        @MainActor
        func rebuild() {
            engine = LSPInstallEngine(
                manifest: Fixture.manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: engine.architecture
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPProvisioningModel(engine: engine, settings: settings)
            // A relaunch records its own pushes: what the previous run published
            // is not something the new process saw.
            pushes = []
            observe()
        }

        @MainActor
        private func observe() {
            model.onRegistryChange = { [weak self] registry in
                guard let self else { return }
                pushes.append((registry, tree.hasDirectory("LanguageServers/typescript-language-server/5.3.0")))
            }
        }

        var pushedRegistries: [LSPServerRegistry] { pushes.map(\.registry) }

        @MainActor
        func state(of server: LSPDownloadableServer) -> LSPInstallState? {
            model.row(for: server)?.state
        }

        func deinitSuite() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeHarness(
        _ name: String = #function,
        architecture: LSPHostArchitecture = .arm64
    ) -> Harness {
        let harness = Harness(name: name, architecture: architecture)
        addTeardownBlock { harness.deinitSuite() }
        return harness
    }

    // MARK: - The prompt rule

    func testTheLanguageMapIsTheEnumsOwnAndNeverCoversSwift() {
        XCTAssertEqual(LSPDownloadableServer.serving(.typescript), .typescript)
        XCTAssertEqual(LSPDownloadableServer.serving(.javascript), .typescript)
        XCTAssertEqual(LSPDownloadableServer.serving(.python), .python)
        XCTAssertNil(LSPDownloadableServer.serving(.swift))
        XCTAssertNil(LSPDownloadableServer.serving(.json))
        XCTAssertNil(LSPDownloadableServer.serving(.markdown))
    }

    func testThePromptOffersADownloadableLanguageWithItsPendingSize() {
        let harness = makeHarness()

        let prompt = harness.model.consentPrompt(forOpening: .typescript)
        XCTAssertEqual(prompt?.server, .typescript)
        XCTAssertEqual(prompt?.displayName, "TypeScript / JavaScript")
        XCTAssertEqual(
            prompt?.downloadByteCount,
            Fixture.nodeBytes + Fixture.tsServerBytes + Fixture.typescriptBytes
        )
        // The same server, offered for the other language it serves.
        XCTAssertEqual(harness.model.consentPrompt(forOpening: .javascript)?.server, .typescript)

        // Nothing has been asked, so nothing has been fetched.
        XCTAssertEqual(harness.downloader.requestedURLs, [])
    }

    func testALanguageWithNoDownloadableServerNeverPrompts() {
        let harness = makeHarness()
        for language in [SyntaxLanguage.swift, .json, .yaml, .gitignore] {
            XCTAssertNil(harness.model.consentPrompt(forOpening: language), "\(language)")
        }
    }

    func testTheSecondServerIsOfferedAtWhatIsStillMissing() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        // `node` is already there, so Python costs its own two artifacts.
        XCTAssertEqual(
            harness.model.consentPrompt(forOpening: .python)?.downloadByteCount,
            Fixture.pyrightBytes + Fixture.fseventsBytes
        )
    }

    func testDecliningAnswersOnceAndSurvivesARelaunch() async {
        let harness = makeHarness()
        harness.model.decline(.typescript)

        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript))
        XCTAssertNil(harness.model.consentPrompt(forOpening: .javascript))
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .declined)

        harness.rebuild()
        await harness.model.refresh()
        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript), "the answer did not survive a relaunch")
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .declined)
        XCTAssertEqual(harness.model.row(for: .typescript)?.state, .absent)
    }

    func testAcceptingAnswersOnceAndSurvivesARelaunch() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript))

        harness.rebuild()
        await harness.model.refresh()
        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript))
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .accepted)
    }

    // MARK: - Declining

    func testDecliningDownloadsNothingAndPublishesNothing() async {
        let harness = makeHarness()
        harness.model.decline(.typescript)
        await harness.model.prepareForOpening(.typescript)
        await harness.model.prepareForOpening(.javascript)

        XCTAssertEqual(harness.downloader.requestedURLs, [], "a declined server downloaded something")
        XCTAssertEqual(harness.pushes.count, 0, "a declined server changed the registry")
        XCTAssertEqual(harness.model.registry, .standard)
        XCTAssertEqual(harness.state(of: .typescript), .absent)
    }

    // MARK: - Accepting

    func testAcceptingInstallsTheRuntimeAndTheServerAndPublishesAUsableRegistry() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        // Runtime first, then the server's own two artifacts.
        XCTAssertEqual(
            harness.downloader.requestedURLs,
            [Fixture.nodeARM, Fixture.tsServer, Fixture.typescript]
        )
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertEqual(harness.model.row(for: .typescript)?.pendingDownloadByteCount, 0)
        XCTAssertNil(harness.model.row(for: .typescript)?.failureMessage)

        XCTAssertEqual(harness.pushes.count, 1)
        let registry = harness.model.registry
        XCTAssertEqual(harness.pushedRegistries.last, registry)

        // Both of this server's languages, and Swift untouched.
        XCTAssertTrue(registry.servesLanguage(.typescript))
        XCTAssertTrue(registry.servesLanguage(.javascript))
        XCTAssertEqual(registry.description(for: .swift), .sourcekitLSP)
        XCTAssertEqual(registry.descriptions.first, .sourcekitLSP, "sourcekit-lsp lost its place")
        XCTAssertNil(registry.description(for: .python))

        // The entry names the installed Node, the installed entry point, and — D11
        // — the `typescript` beside it.
        let description = registry.description(for: .typescript)
        XCTAssertEqual(description?.id, "typescript-language-server")
        XCTAssertEqual(
            description?.launch,
            .executable(path: "/Pisaka-tests/LanguageServers/node/24.19.0/bin/node")
        )
        XCTAssertEqual(
            description?.arguments,
            [
                "/Pisaka-tests/LanguageServers/typescript-language-server/5.3.0"
                    + "/node_modules/typescript-language-server/lib/cli.mjs",
                "--stdio",
            ]
        )
        XCTAssertEqual(
            description?.initializationOptions,
            .object([
                "tsserver": .object([
                    "path": .string(
                        "/Pisaka-tests/LanguageServers/typescript-language-server/5.3.0"
                            + "/node_modules/typescript/lib/tsserver.js"
                    )
                ])
            ])
        )

        // And every path that entry names is really there.
        XCTAssertEqual(harness.tree.files["LanguageServers/node/24.19.0/bin/node"], "#!node arm64")
        XCTAssertEqual(
            harness.tree.files[
                "LanguageServers/typescript-language-server/5.3.0"
                    + "/node_modules/typescript-language-server/lib/cli.mjs"
            ],
            "tsserver-lsp"
        )
        XCTAssertEqual(
            harness.tree.files[
                "LanguageServers/typescript-language-server/5.3.0/node_modules/typescript/lib/tsserver.js"
            ],
            "tsserver"
        )
    }

    func testTheSecondServerReusesTheRuntimeAndBothStayRegistered() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.accept(.python)

        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.nodeARM), 1)
        XCTAssertEqual(harness.state(of: .python), .installed(version: "1.1.411"))

        let registry = harness.model.registry
        XCTAssertEqual(registry.descriptions.first, .sourcekitLSP)
        XCTAssertEqual(registry.descriptions.count, 3)
        XCTAssertTrue(registry.servesLanguage(.typescript))
        XCTAssertTrue(registry.servesLanguage(.python))
        XCTAssertEqual(
            registry.description(for: .python)?.launch,
            .executable(path: "/Pisaka-tests/LanguageServers/node/24.19.0/bin/node")
        )
        // pyright takes no `initializationOptions` — there is no second copy of
        // anything for it to be pointed at.
        XCTAssertNil(registry.description(for: .python)?.initializationOptions)
    }

    /// D15's silent half: consent already given, files missing, nothing asked.
    func testAnAcceptedButAbsentServerInstallsOnFirstUseWithoutAsking() async {
        let harness = makeHarness()
        harness.settings.setConsent(.accepted, for: LSPDownloadableServer.python.id)
        await harness.model.refresh()

        XCTAssertNil(harness.model.consentPrompt(forOpening: .python))
        await harness.model.prepareForOpening(.python)

        XCTAssertEqual(harness.state(of: .python), .installed(version: "1.1.411"))
        XCTAssertTrue(harness.model.registry.servesLanguage(.python))

        // Opening a second Python file installs nothing a second time.
        let downloads = harness.downloader.requestedURLs.count
        await harness.model.prepareForOpening(.python)
        XCTAssertEqual(harness.downloader.requestedURLs.count, downloads)
    }

    func testOpeningAnUnaskedLanguageInstallsNothing() async {
        let harness = makeHarness()
        await harness.model.prepareForOpening(.typescript)

        XCTAssertEqual(harness.downloader.requestedURLs, [], "an unasked server installed itself")
        XCTAssertNotNil(harness.model.consentPrompt(forOpening: .typescript))
    }

    // MARK: - Failure

    func testAFailedInstallLeavesConsentAcceptedTheRowRetryableAndTheRegistryUnchanged() async {
        let harness = makeHarness()
        harness.downloader.fail(Fixture.tsServer)

        await harness.model.accept(.typescript)

        let row = harness.model.row(for: .typescript)
        XCTAssertEqual(row?.consent, .accepted)
        XCTAssertEqual(row?.state, .absent)
        XCTAssertEqual(row?.canInstall, true, "a failed install left no way to retry")
        XCTAssertNotNil(row?.failureMessage)
        XCTAssertEqual(
            row?.failureMessage,
            LSPInstallError.downloadFailed(
                component: "typescript-language-server",
                reason: ScriptedDownloader.Failure.offline.localizedDescription
            ).localizedDescription
        )

        // Nothing was published, and nothing prompts: the language answers from
        // tree-sitter exactly as it did before, silently.
        XCTAssertEqual(harness.pushes.count, 0)
        XCTAssertEqual(harness.model.registry, .standard)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript))
    }

    func testRetryingAfterAFailureInstallsAndClearsTheMessage() async {
        let harness = makeHarness()
        harness.downloader.fail(Fixture.tsServer)
        await harness.model.accept(.typescript)
        XCTAssertNotNil(harness.model.row(for: .typescript)?.failureMessage)

        harness.downloader.serve(Fixture.tsServer)
        await harness.model.install(.typescript)

        XCTAssertNil(harness.model.row(for: .typescript)?.failureMessage)
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertTrue(harness.model.registry.servesLanguage(.typescript))
        // The runtime that succeeded on the first attempt was not fetched twice.
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.nodeARM), 1)
    }

    /// A mirror serving something other than what the manifest pinned is the one
    /// failure that must never be papered over: it fails, and the language stays
    /// on tree-sitter.
    func testAChecksumMismatchIsJustAnotherSilentFailure() async {
        let harness = makeHarness()
        harness.downloader.serve(Fixture.nodeARM, bytes: Data("not node".utf8))

        await harness.model.accept(.typescript)

        XCTAssertEqual(harness.state(of: .typescript), .absent)
        XCTAssertEqual(harness.model.registry, .standard)
        XCTAssertEqual(
            harness.model.row(for: .typescript)?.failureMessage,
            LSPInstallError.checksumMismatch(component: "node", url: Fixture.nodeARM).localizedDescription
        )
    }

    // MARK: - Installing…

    func testARowReadsInstallingWhileAnAttemptIsInFlight() async throws {
        let harness = makeHarness()
        let gate = Gate()
        harness.downloader.hold(Fixture.nodeARM, on: gate)

        let install = Task { await harness.model.accept(.typescript) }
        await gate.waitUntilReached()

        let row = harness.model.row(for: .typescript)
        XCTAssertEqual(row?.state, .installing)
        XCTAssertEqual(row?.canInstall, false, "an in-flight install offered an Install button")
        XCTAssertEqual(row?.canRemove, false, "an in-flight install offered a Remove button")
        // The second server is installing too: it is waiting for the very same
        // runtime download.
        harness.settings.setConsent(.accepted, for: LSPDownloadableServer.python.id)
        let python = Task { await harness.model.prepareForOpening(.python) }
        await Task.yield()
        XCTAssertEqual(harness.state(of: .python), .installing)

        gate.release()
        await install.value
        await python.value

        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertEqual(harness.state(of: .python), .installed(version: "1.1.411"))
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.nodeARM), 1)
    }

    func testTwoAcceptsForOneServerProduceOneAttempt() async {
        let harness = makeHarness()
        let gate = Gate()
        harness.downloader.hold(Fixture.nodeARM, on: gate)

        let first = Task { await harness.model.accept(.typescript) }
        await gate.waitUntilReached()
        let second = Task { await harness.model.install(.typescript) }
        await Task.yield()
        gate.release()

        await first.value
        await second.value

        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.nodeARM), 1)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.tsServer), 1)
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertEqual(harness.pushes.count, 1, "one install published two registries")
    }

    // MARK: - Removal

    func testRemovingPublishesWithoutTheServerBeforeItsFilesGoAway() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        XCTAssertEqual(harness.pushes.count, 1)

        await harness.model.remove(.typescript)

        // One further push, carrying a registry without the server — and made
        // while the executable it was running from still existed (D16: stop the
        // process, *then* delete what it was running).
        XCTAssertEqual(harness.pushes.count, 2)
        XCTAssertFalse(harness.pushes[1].registry.servesLanguage(.typescript))
        XCTAssertFalse(harness.pushes[1].registry.servesLanguage(.javascript))
        XCTAssertTrue(
            harness.pushes[1].typescriptFilesPresent,
            "the files were deleted before the session was told to stop"
        )

        XCTAssertEqual(harness.model.registry, .standard)
        XCTAssertEqual(harness.state(of: .typescript), .absent)
        XCTAssertEqual(harness.model.row(for: .typescript)?.canRemove, false)
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/typescript-language-server"))
    }

    func testRemovingTheLastServerDropsTheRuntimeAndRemovingTheFirstDoesNot() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.accept(.python)

        await harness.model.remove(.typescript)
        XCTAssertTrue(
            harness.tree.hasDirectory("LanguageServers/node/24.19.0"),
            "the runtime went away while a server still needed it"
        )
        XCTAssertEqual(harness.state(of: .python), .installed(version: "1.1.411"))
        XCTAssertTrue(harness.model.registry.servesLanguage(.python))

        await harness.model.remove(.python)
        XCTAssertFalse(
            harness.tree.hasDirectory("LanguageServers/node"),
            "the runtime outlived the last server that needed it"
        )
        XCTAssertEqual(harness.model.registry, .standard)
    }

    /// A removal is an answer too: the next `.ts` file must neither re-download
    /// the server nor ask about it again.
    func testARemovedServerNeitherReinstallsNorPrompts() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.remove(.typescript)

        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .declined)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .typescript))

        let downloads = harness.downloader.requestedURLs.count
        await harness.model.prepareForOpening(.typescript)
        XCTAssertEqual(harness.downloader.requestedURLs.count, downloads)
        XCTAssertEqual(harness.state(of: .typescript), .absent)

        // And it is turned around from the Settings surface, which is the one
        // place that can.
        await harness.model.install(.typescript)
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .accepted)
    }

    func testRemovingSomethingThatIsNotInstalledChangesNothing() async {
        let harness = makeHarness()
        await harness.model.remove(.python)

        XCTAssertEqual(harness.pushes.count, 0)
        XCTAssertEqual(harness.model.registry, .standard)
        XCTAssertEqual(harness.tree.removedPaths, [])
    }

    // MARK: - Launch

    func testRefreshDerivesTheWholeRegistryFromTheDiskAtLaunch() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.accept(.python)

        harness.rebuild()
        // Before the refresh the model knows only its base — nothing is persisted
        // about what was registered last time, on purpose.
        XCTAssertEqual(harness.model.registry, .standard)

        await harness.model.refresh()

        XCTAssertEqual(harness.pushes.count, 1, "the launch refresh pushed more than once")
        XCTAssertTrue(harness.model.registry.servesLanguage(.typescript))
        XCTAssertTrue(harness.model.registry.servesLanguage(.python))
        XCTAssertEqual(harness.model.registry.descriptions.first, .sourcekitLSP)
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertEqual(harness.model.row(for: .python)?.consent, .accepted)
        // A relaunch that finds everything in place downloads nothing.
        await harness.model.prepareForOpening(.typescript)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.nodeARM), 1)
    }

    func testARefreshThatChangesNothingPublishesNothing() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        XCTAssertEqual(harness.pushes.count, 1)

        await harness.model.refresh()
        await harness.model.refresh()

        XCTAssertEqual(harness.pushes.count, 1, "an unchanged registry was pushed again")
    }

    func testAStrandedVersionIsNotServableButIsRemovable() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        // What a pin bump leaves behind: the tree of a version this app no longer
        // names. Nothing may be served from it — every path the registry entry
        // composes carries the pinned version — but it is real disk and the
        // Settings row has to be able to reclaim it.
        try? harness.tree.removeItem(
            at: harness.layout.versionDirectory(componentID: "typescript-language-server", version: "5.3.0")
        )
        try? harness.tree.write(
            "stale",
            to: harness.layout
                .versionDirectory(componentID: "typescript-language-server", version: "4.0.0")
                .appendingPathComponent("node_modules/typescript-language-server/lib/cli.mjs")
        )
        await harness.model.refresh()

        let row = harness.model.row(for: .typescript)
        XCTAssertEqual(row?.state, .absent)
        XCTAssertEqual(row?.canRemove, true, "a stranded version could not be reclaimed")
        XCTAssertFalse(harness.model.registry.servesLanguage(.typescript))
    }

    // MARK: - Rows

    func testTheRowsAreOnePerServerInAFixedOrder() {
        let harness = makeHarness()
        XCTAssertEqual(harness.model.rows.map(\.server), LSPDownloadableServer.allCases)
        // The row's identity is the *server's* (the key consent is stored under),
        // not its component's — the two spellings exist and the persisted one is
        // this.
        XCTAssertEqual(harness.model.rows.map(\.id), ["typescript", "python"])
        XCTAssertEqual(
            harness.model.rows.map(\.server.serverComponentID),
            ["typescript-language-server", "pyright"]
        )
        XCTAssertEqual(harness.model.rows.map(\.displayName), ["TypeScript / JavaScript", "Python"])
        XCTAssertEqual(harness.model.rows.map(\.languages), [[.typescript, .javascript], [.python]])
        XCTAssertEqual(harness.model.rows.map(\.state), [.absent, .absent])
        XCTAssertEqual(harness.model.rows.map(\.isInstalled), [false, false])
        XCTAssertEqual(harness.model.rows.map(\.canInstall), [true, true])
        XCTAssertEqual(harness.model.rows.map(\.canRemove), [false, false])
    }
}
