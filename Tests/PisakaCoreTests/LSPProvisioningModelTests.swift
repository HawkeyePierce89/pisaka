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
                    "fallbackPath": .string(
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

    /// The silent half installs *once* per app run. A failed attempt leaves the
    /// server `absent`, so without the failure gate every switch back to a `.ts`
    /// tab would start the same download again — and clear, on the way past, the
    /// row that is the only place the failure is reported.
    func testAFailedInstallIsNotRetriedByOpeningTheLanguageAgain() async {
        let harness = makeHarness()
        harness.downloader.fail(Fixture.tsServer)
        await harness.model.accept(.typescript)

        let message = harness.model.row(for: .typescript)?.failureMessage
        XCTAssertNotNil(message)
        let downloads = harness.downloader.requestedURLs.count

        // Every way a tab open reaches this: the same language, and the other one
        // the same server serves.
        await harness.model.prepareForOpening(.typescript)
        await harness.model.prepareForOpening(.javascript)

        XCTAssertEqual(
            harness.downloader.requestedURLs.count,
            downloads,
            "a tab open re-attempted an install that already failed this app run"
        )
        XCTAssertEqual(
            harness.model.row(for: .typescript)?.failureMessage,
            message,
            "a tab open wiped the failure the Settings row exists to show"
        )

        // The explicit Retry is unconditional, and so is the next launch.
        harness.downloader.serve(Fixture.tsServer)
        await harness.model.install(.typescript)
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
    }

    /// The gate is per app run, not per disk: the failure lives in the model, so a
    /// relaunch offers the accepted server its next attempt.
    func testARelaunchRetriesAnInstallThatFailedInThePreviousRun() async {
        let harness = makeHarness()
        harness.downloader.fail(Fixture.tsServer)
        await harness.model.accept(.typescript)
        XCTAssertNotNil(harness.model.row(for: .typescript)?.failureMessage)

        harness.downloader.serve(Fixture.tsServer)
        harness.rebuild()
        await harness.model.refresh()
        await harness.model.prepareForOpening(.typescript)

        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
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

    /// The one Remove that can go wrong after the point of no return: the push
    /// that stopped the process has already happened, so a deletion that fails
    /// leaves the files there and the very next push puts the server straight
    /// back. That is a Remove visibly undoing itself, and it must say why.
    func testAFailedRemovalSaysSoInsteadOfSilentlyReinstatingTheServer() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        harness.tree.removeFailures = ["LanguageServers/typescript-language-server"]

        await harness.model.remove(.typescript)

        let row = harness.model.row(for: .typescript)
        XCTAssertEqual(
            row?.failureMessage,
            LSPInstallError.removeFailed(
                component: "typescript-language-server",
                reason: StubFileTree.StubError.denied.localizedDescription
            ).localizedDescription
        )
        // The files are still there, so the model reports what is true rather
        // than what was asked for — and the server is servable again, which is
        // exactly why the message has to exist.
        XCTAssertEqual(row?.state, .installed(version: "5.3.0"))
        XCTAssertEqual(row?.canRemove, true, "a failed removal left no way to try again")
        XCTAssertTrue(harness.model.registry.servesLanguage(.typescript))
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/typescript-language-server/5.3.0"))

        // The runtime is untouched: the server that needs it is still installed.
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))

        // And no decline was recorded: this server is installed, registered and
        // answering requests, which is the one state "declined" may not describe.
        // Recording it here would also have the row read "Installed · 5.3.0"
        // under a consent that says the user refused it.
        XCTAssertEqual(row?.consent, .accepted)

        // Retrying once the volume cooperates finishes the job, clears the
        // message, and *then* records the answer.
        harness.tree.removeFailures = []
        await harness.model.remove(.typescript)
        XCTAssertNil(harness.model.row(for: .typescript)?.failureMessage)
        XCTAssertEqual(harness.state(of: .typescript), .absent)
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .declined)
    }

    /// The two components of a server are installed in order and committed
    /// separately, so a download that dies on the small one leaves the ~52 MB
    /// runtime behind under a row that reads "not installed". The runtime is kept
    /// on purpose — the retry then costs 4 MB rather than 56 — but it has to stay
    /// reclaimable, or the only way out of an install that will never succeed
    /// (offline machine, blocked registry) is the Finder.
    func testAnInstallThatDiedAfterTheRuntimeLandedCanStillReclaimIt() async {
        let harness = makeHarness()
        harness.downloader.fail(Fixture.tsServer)

        await harness.model.accept(.typescript)

        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))
        let row = harness.model.row(for: .typescript)
        XCTAssertEqual(row?.state, .absent)
        XCTAssertEqual(row?.canInstall, true)
        XCTAssertEqual(row?.canRemove, true, "the runtime a failed install stranded could not be reclaimed")

        // The row nobody asked about does not offer to clean up after the one
        // that failed, even though they share the runtime.
        XCTAssertEqual(harness.model.row(for: .python)?.canRemove, false)

        await harness.model.remove(.typescript)

        XCTAssertFalse(
            harness.tree.hasDirectory("LanguageServers/node"),
            "Remove left the stranded runtime on disk"
        )
        XCTAssertEqual(harness.model.row(for: .typescript)?.canRemove, false)
        // Nothing was ever registered, so there is nothing to push either way.
        XCTAssertEqual(harness.pushes.count, 0)
    }

    /// A runtime still in use is not "stranded", so the row a removal left behind
    /// does not offer to delete it out from under the server that needs it.
    func testTheRowOfARemovedServerOffersNothingWhileTheOtherStillUsesTheRuntime() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.accept(.python)

        await harness.model.remove(.typescript)

        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))
        XCTAssertEqual(
            harness.model.row(for: .typescript)?.canRemove,
            false,
            "a removed server offered to delete the runtime the other one is running on"
        )
        XCTAssertEqual(harness.model.row(for: .python)?.canRemove, true)
    }

    /// D16's ordering is "push, then delete" — the push is what stops the process,
    /// and it is awaited, so the model sits inside it for as long as the shutdown
    /// takes. A second Remove arriving in that window must not run: its own
    /// `publishRegistry()` finds the registry already published and returns
    /// *without suspending*, so it would walk straight into the deletion and pull
    /// the executable out from under the session the first call is still stopping
    /// — precisely the orphan the ordering exists to prevent.
    func testASecondRemoveDuringTheShutdownPushDoesNothing() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        let gate = PushGate()
        harness.model.onRegistryChange = { _ in await gate.hold() }

        let first = Task { await harness.model.remove(.typescript) }
        await gate.waitUntilHeld()

        // The window itself: the row says what is happening and offers no button.
        let midway = harness.model.row(for: .typescript)
        XCTAssertEqual(midway?.isRemoving, true)
        XCTAssertEqual(midway?.canRemove, false)

        await harness.model.remove(.typescript)
        XCTAssertTrue(
            harness.tree.hasDirectory("LanguageServers/typescript-language-server/5.3.0"),
            "a second Remove deleted the files while the first was still stopping the server"
        )
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))

        // Nor does an Install arriving in the same window: the row offers no
        // button, and `install(_:)` refuses on its own for the same reason.
        let downloads = harness.downloader.requestedURLs.count
        XCTAssertEqual(midway?.canInstall, false)
        await harness.model.install(.typescript)
        XCTAssertEqual(harness.downloader.requestedURLs.count, downloads)

        gate.release()
        await first.value

        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/typescript-language-server"))
        XCTAssertEqual(harness.model.row(for: .typescript)?.isRemoving, false)
        XCTAssertEqual(harness.state(of: .typescript), .absent)
    }

    /// A rendezvous the *push* runs into, so a test can act while the model is
    /// suspended inside `onRegistryChange` — where a real removal spends up to
    /// `LSPSession.Budgets.shutdown` stopping a process. The support `Gate`
    /// blocks its thread, which on the main actor would deadlock the test rather
    /// than interleave with it.
    @MainActor
    private final class PushGate {
        private var resume: (() -> Void)?
        private var held = false

        func hold() async {
            held = true
            await withCheckedContinuation { continuation in
                resume = { continuation.resume() }
            }
        }

        func release() {
            resume?()
            resume = nil
        }

        func waitUntilHeld() async {
            while !held { await Task.yield() }
        }
    }

    /// A runtime that could not be deleted is reported too, even though the
    /// server it belonged to is gone: the disk is the state, and 52 MB that
    /// silently stayed behind is the one thing "delete the directory to
    /// de-provision" would not explain.
    ///
    /// The decline is recorded all the same, and that is the half a message alone
    /// would get wrong. Consent describes the *server*, whose own deletion
    /// succeeded — the row reads `.absent`, the registry no longer serves the
    /// language — so leaving it `accepted` because a shared directory would not go
    /// away has the next launch silently re-download the server the user just
    /// removed, under a row offering "Retry" for a removal.
    func testAFailedRuntimeRemovalIsReportedButStillDeclinesTheServerItRemoved() async {
        let harness = makeHarness()
        await harness.model.accept(.python)
        harness.tree.removeFailures = ["LanguageServers/node"]

        await harness.model.remove(.python)

        XCTAssertEqual(harness.state(of: .python), .absent)
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))
        XCTAssertEqual(
            harness.model.row(for: .python)?.failureMessage,
            LSPInstallError.removeFailed(
                component: "node",
                reason: StubFileTree.StubError.denied.localizedDescription
            ).localizedDescription
        )

        XCTAssertEqual(harness.model.row(for: .python)?.consent, .declined)
        XCTAssertFalse(harness.model.registry.servesLanguage(.python))

        // Which is what makes the removal survive the relaunch: `prepareForOpening`
        // reads consent off the store, so an `accepted` left behind here would fetch
        // pyright again the first time a `.py` tab opened — the runtime it needs
        // being exactly the directory that would not go away.
        harness.rebuild()
        await harness.model.refresh()
        await harness.model.prepareForOpening(.python)
        XCTAssertEqual(harness.state(of: .python), .absent, "the removed server re-downloaded itself")
        XCTAssertNil(harness.model.consentPrompt(forOpening: .python))
    }

    /// …and the runtime it could not delete stays reclaimable, which the decline
    /// must not take away with it.
    ///
    /// This is the one state where the two halves of `remove(_:)` disagree: the
    /// server component is gone (so the row reads `.absent` and consent is
    /// `declined`), while ~110 MB of unpacked Node is still on disk and needed by
    /// nothing. Deriving `hasFilesOnDisk`'s runtime branch from `accepted` made
    /// that state terminal — no Remove on any row, under a message saying the
    /// removal failed — so the rule is "answered about", not "accepted".
    func testTheRuntimeAFailedRemovalStrandedStaysReclaimable() async {
        let harness = makeHarness()
        await harness.model.accept(.python)
        harness.tree.removeFailures = ["LanguageServers/node"]

        await harness.model.remove(.python)

        let row = harness.model.row(for: .python)
        XCTAssertEqual(row?.state, .absent)
        XCTAssertEqual(row?.consent, .declined)
        XCTAssertEqual(row?.canRemove, true, "a declined row could not reclaim the runtime it stranded")
        // Still not offered under the row nobody has answered for, which is what
        // the gate is actually for.
        XCTAssertEqual(harness.model.row(for: .typescript)?.canRemove, false)

        // It survives the relaunch, because both halves of the answer are read
        // off the disk rather than off an in-memory note of what went wrong.
        harness.rebuild()
        await harness.model.refresh()
        XCTAssertEqual(harness.model.row(for: .python)?.canRemove, true)

        harness.tree.removeFailures = []
        await harness.model.remove(.python)

        XCTAssertFalse(
            harness.tree.hasDirectory("LanguageServers/node"),
            "the second Remove left the stranded runtime on disk"
        )
        XCTAssertNil(harness.model.row(for: .python)?.failureMessage)
        XCTAssertEqual(harness.model.row(for: .python)?.canRemove, false)
    }

    /// The install button on that row says "Install", not "Retry".
    ///
    /// Same row, same visible message — but the message is about a directory this
    /// button would not touch, and the action it performs is a fresh ~52 MB
    /// download of the server the user just removed. "Retry" beside a sentence
    /// beginning "Could not remove" reads as retrying the removal.
    func testTheInstallButtonDoesNotOfferToRetryAFailedRemoval() async {
        let harness = makeHarness()
        await harness.model.accept(.python)
        harness.tree.removeFailures = ["LanguageServers/node"]

        await harness.model.remove(.python)

        let removed = harness.model.row(for: .python)
        XCTAssertNotNil(removed?.failureMessage)
        XCTAssertEqual(removed?.canInstall, true)
        XCTAssertEqual(removed?.failureWasRemoval, true)

        // A failed *install* is the case the "Retry" label exists for, and it is
        // unchanged.
        harness.downloader.fail(Fixture.tsServer)
        await harness.model.accept(.typescript)
        let failedInstall = harness.model.row(for: .typescript)
        XCTAssertNotNil(failedInstall?.failureMessage)
        XCTAssertEqual(failedInstall?.failureWasRemoval, false)
    }

    /// Removing one server while the other's install is in flight must leave the
    /// shared runtime alone — the accepted download would otherwise land on a
    /// server whose `node` had been deleted underneath it, servable by nothing
    /// and reported installed by the row.
    func testRemovingOneServerKeepsTheRuntimeAnInFlightInstallIsWaitingOn() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)

        // Python's install is held at its own artifact: `node` is already there,
        // so what is in flight is the thing that would make the runtime needed.
        let gate = Gate()
        harness.downloader.hold(Fixture.pyright, on: gate)
        let install = Task { await harness.model.install(.python) }
        await gate.waitUntilReached()
        XCTAssertEqual(harness.state(of: .python), .installing)

        await harness.model.remove(.typescript)

        XCTAssertTrue(
            harness.tree.hasDirectory("LanguageServers/node/24.19.0"),
            "the runtime an accepted install is waiting on was deleted"
        )
        XCTAssertNil(harness.model.row(for: .typescript)?.failureMessage)

        gate.release()
        await install.value
        XCTAssertEqual(harness.state(of: .python), .installed(version: "1.1.411"))
        XCTAssertTrue(harness.model.registry.servesLanguage(.python))
    }

    /// And removing the server whose *own* install is in flight must do nothing at
    /// all — the case the row's `canRemove` hides but the model has to refuse on
    /// its own, exactly as it refuses a second Remove.
    ///
    /// The stranded runtime is what makes this reachable: it is the one state that
    /// puts Install and Remove on the same row at the same time (server component
    /// absent, `node` on disk and reclaimable), so a Remove clicked off a row
    /// snapshot taken a frame before Retry claimed the attempt arrives here with an
    /// install running. Everything it would then do is wrong.
    /// `engine.remove(serverComponentID)` no-ops — the attempt has committed
    /// nothing yet, it is all still staging — so the removal walks straight on to
    /// the shared runtime, which `runtimeIsNeeded(byAnythingOtherThan:)` reports as
    /// needed by nothing because it only ever asks about the *other* servers. The
    /// install then commits its artifact onto a deleted `node`: a server the row
    /// reads as absent, servable by nothing, with the 4 MB download spent.
    func testARemoveArrivingWhileTheSameServerInstallsDoesNothing() async {
        let harness = makeHarness()
        // The stranded runtime: `node` lands, the server's own artifact does not.
        harness.downloader.fail(Fixture.tsServer)
        await harness.model.accept(.typescript)
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))

        let stranded = harness.model.row(for: .typescript)
        XCTAssertEqual(stranded?.canInstall, true)
        XCTAssertEqual(stranded?.canRemove, true, "the state this test needs is not the one it staged")

        // Retry, held on the artifact that failed last time.
        harness.downloader.serve(Fixture.tsServer)
        let gate = Gate()
        harness.downloader.hold(Fixture.tsServer, on: gate)
        let install = Task { await harness.model.install(.typescript) }
        await gate.waitUntilReached()
        XCTAssertEqual(harness.state(of: .typescript), .installing)

        let removedBefore = harness.tree.removedPaths
        await harness.model.remove(.typescript)

        XCTAssertEqual(
            harness.tree.removedPaths,
            removedBefore,
            "a Remove ran against an install in flight and deleted its runtime"
        )
        XCTAssertTrue(harness.tree.hasDirectory("LanguageServers/node/24.19.0"))
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .accepted)
        XCTAssertNil(harness.model.row(for: .typescript)?.failureMessage)
        XCTAssertEqual(harness.state(of: .typescript), .installing)

        gate.release()
        await install.value

        // The retry the user actually asked for finishes, whole and servable.
        XCTAssertEqual(harness.state(of: .typescript), .installed(version: "5.3.0"))
        XCTAssertTrue(harness.model.registry.servesLanguage(.typescript))
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .accepted)
    }

    /// The value-type half of the same window: a row that is being removed offers
    /// no Install either.
    ///
    /// `state` cannot say this on its own. A removal that starts from the stranded
    /// state finds the server component `.absent` and keeps reading `.absent`
    /// throughout, so without `isRemoving` in the rule the row would offer Install
    /// beside its own "Removing…" and a spinner.
    func testARowBeingRemovedOffersNeitherButton() {
        let row = LSPServerRow(
            server: .typescript,
            displayName: "TypeScript",
            languages: LSPDownloadableServer.typescript.languages,
            consent: .declined,
            state: .absent,
            pendingDownloadByteCount: 0,
            failureMessage: nil,
            hasFilesOnDisk: true,
            isRemoving: true
        )

        XCTAssertFalse(row.canInstall)
        XCTAssertFalse(row.canRemove)
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

    // MARK: - What an install may not change

    /// The registry an install publishes differs from the previous one by exactly
    /// one entry, appended: everything already in it — sourcekit-lsp above all —
    /// is the same value in the same place.
    ///
    /// Stated as an assertion over *every* language rather than over the two
    /// downloadable ones, because the failure this guards against is a manifest
    /// record that claims a language it should not: a `typescript` component that
    /// listed `.swift` would take sourcekit-lsp's place in nothing (first
    /// registration wins) but would take every other language's, silently, for
    /// whoever installs it.
    private func assertInstallingAppendsExactlyOneEntry(
        _ server: LSPDownloadableServer,
        _ harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let before = harness.model.registry
        await harness.model.accept(server)
        let after = harness.model.registry

        XCTAssertEqual(after.descriptions.count, before.descriptions.count + 1, file: file, line: line)
        XCTAssertEqual(
            Array(after.descriptions.dropLast()),
            before.descriptions,
            "an install rewrote the entries that were already registered",
            file: file,
            line: line
        )
        XCTAssertEqual(after.descriptions.first, .sourcekitLSP, file: file, line: line)
        XCTAssertEqual(
            after.servedLanguages,
            before.servedLanguages.union(server.languages),
            file: file,
            line: line
        )
        for language in SyntaxLanguage.allCases where !server.languages.contains(language) {
            XCTAssertEqual(
                after.description(for: language),
                before.description(for: language),
                "\(language) changed hands when \(server.id) was installed",
                file: file,
                line: line
            )
        }
    }

    func testInstallingPyrightLeavesTypeScriptAndSwiftExactlyAsTheyWere() async {
        let harness = makeHarness()
        await assertInstallingAppendsExactlyOneEntry(.python, harness)

        let registry = harness.model.registry
        XCTAssertEqual(registry.description(for: .swift), .sourcekitLSP)
        XCTAssertFalse(registry.servesLanguage(.typescript))
        XCTAssertFalse(registry.servesLanguage(.javascript))
        XCTAssertEqual(registry.servedLanguages, [.swift, .python])
        XCTAssertEqual(harness.state(of: .typescript), .absent)
        // The TypeScript row is offerable exactly as it was: an install of the
        // other server is not an answer to a question about this one.
        XCTAssertEqual(harness.model.row(for: .typescript)?.consent, .unasked)
        XCTAssertNotNil(harness.model.consentPrompt(forOpening: .typescript))
    }

    func testInstallingTheTypeScriptServerLeavesPythonAndSwiftExactlyAsTheyWere() async {
        let harness = makeHarness()
        await assertInstallingAppendsExactlyOneEntry(.typescript, harness)

        let registry = harness.model.registry
        XCTAssertEqual(registry.description(for: .swift), .sourcekitLSP)
        XCTAssertFalse(registry.servesLanguage(.python))
        XCTAssertEqual(registry.servedLanguages, [.swift, .typescript, .javascript])
        XCTAssertEqual(harness.state(of: .python), .absent)
        XCTAssertEqual(harness.model.row(for: .python)?.consent, .unasked)
        XCTAssertNotNil(harness.model.consentPrompt(forOpening: .python))
    }

    /// Both installed, and the base is still untouched: whatever else this layer
    /// publishes, `.swift` resolves to the entry 2a shipped, found through `xcrun`
    /// and named by nothing in the manifest.
    func testNoManifestEntryEverClaimsTheSwiftPath() async {
        let harness = makeHarness()
        await harness.model.accept(.typescript)
        await harness.model.accept(.python)

        XCTAssertEqual(harness.model.registry.description(for: .swift), .sourcekitLSP)
        for description in harness.model.registry.descriptions.dropFirst() {
            XCTAssertFalse(description.languages.contains(.swift), description.id)
            if case .toolchainTool = description.launch {
                XCTFail("a provisioned server was described as a toolchain tool: \(description.id)")
            }
        }
        for server in LSPDownloadableServer.allCases {
            XCTAssertFalse(server.languages.contains(.swift), server.id)
        }
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
