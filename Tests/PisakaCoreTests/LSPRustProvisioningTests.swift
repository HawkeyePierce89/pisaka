import XCTest
@testable import PisakaCore

/// rust-analyzer is the one server this app both *discovers* and *downloads*, so
/// this is where the hybrid's promises are pinned: without a `cargo` nothing is
/// offered, asked or registered at all; a rust-analyzer the user already has is
/// used silently and never removed; the app's own copy wins when both exist; a
/// failure is a sentence in a Settings row and nothing else; and a removal stops
/// the server before it deletes the executable.
///
/// **A fixture manifest, not `.standard`** — `LSPInstallEngineTests`' reason: the
/// shipped pin is the checksum of a real 13 MB release asset, and a suite that had
/// to produce bytes hashing to it would need the network this whole design exists
/// to avoid. The fixture's digest is the digest of the scripted seams' canned
/// bytes, and its *version* is deliberately not the shipped one, so a model that
/// hard-coded `2026-08-03` anywhere would fail here rather than pass by
/// coincidence. What the shipped record actually says is pinned by
/// `LSPProvisioningManifestTests` and, for the two facts this model composes paths
/// out of, by `testTheShippedPinIsTheOneThisModelDrives` below.
@MainActor
final class LSPRustProvisioningTests: XCTestCase {
    // MARK: - The fixture

    private enum Fixture {
        static let userRustAnalyzerPath = "/Users/someone/.cargo/bin/rust-analyzer"

        static let version = "2026-01-02"
        static let archive = URL(string: "https://example.invalid/rust-analyzer-\(version).gz")!

        static let versionDirectory = "LanguageServers/rust-analyzer/\(version)"
        static let installedExecutable = "LanguageServers/rust-analyzer/\(version)/bin/rust-analyzer"

        /// The version an app update moves the pin *to*, and the archive it names
        /// — the upgrade case, where a version directory is already on disk while
        /// the row reports the new pin as not installed.
        static let nextVersion = "2026-02-03"
        static let nextArchive = URL(string: "https://example.invalid/rust-analyzer-\(nextVersion).gz")!

        /// The shipped component's shape exactly — a bare `.gz` of one binary,
        /// nothing to strip, the name in the format's payload, no licence file to
        /// read and nothing required (D22/D24).
        static func component(
            version: String = Fixture.version,
            archive: URL = Fixture.archive
        ) -> LSPComponent {
            LSPComponent(
                id: LSPRustAnalyzer.componentID,
                version: version,
                licenseSPDX: "Apache-2.0 OR MIT",
                licenseFileSubpaths: [],
                artifacts: [
                    LSPArtifact(
                        url: archive,
                        sha256: ScriptedArchive.checksum(for: archive),
                        byteCount: 13_000_000,
                        unpackedByteCount: 37_000_000,
                        format: .gzip(fileName: "rust-analyzer"),
                        stripComponents: 0,
                        destinationSubpath: "bin",
                        architecture: .arm64
                    )
                ],
                executableSubpath: "bin/rust-analyzer"
            )
        }

        static let manifest = LSPProvisioningManifest(components: [component()])

        /// The same manifest one pin bump later.
        static let bumpedManifest = LSPProvisioningManifest(
            components: [component(version: nextVersion, archive: nextArchive)]
        )

        /// A manifest that describes no rust-analyzer at all — not a state the
        /// shipped pin can be in, and the one the model answers "nothing to
        /// offer" for at every surface rather than trapping on.
        static let emptyManifest = LSPProvisioningManifest(components: [])
    }

    // MARK: - The harness

    /// One install root, one settings suite, and a model over both — rebuildable,
    /// which is how "the answer survived a relaunch" and "the registry is derived
    /// from the disk at launch" are staged.
    private final class Harness {
        let root = URL(fileURLWithPath: "/Pisaka-rust-tests")
        let tree: StubFileTree
        let layout: LSPInstallLayout
        let discovery: ScriptedRustDiscovery
        let downloader: ScriptedDownloader
        let unpacker: ScriptedUnpacker
        let defaults: UserDefaults
        private let suiteName: String

        private(set) var engine: LSPInstallEngine
        private(set) var settings: SettingsStore
        private(set) var model: LSPRustProvisioningModel

        /// Every push the model made, and — for each — whether the installed
        /// executable still existed when it was made. The second half is what
        /// pins D16's ordering: the removal's push has to arrive while the binary
        /// it names still exists, because the push is what stops the server
        /// running from it.
        private(set) var pushes: [(descriptions: [LSPServerDescription], filesPresent: Bool)] = []

        @MainActor
        init(
            name: String,
            discovery: ScriptedRustDiscovery,
            manifest: LSPProvisioningManifest = Fixture.manifest
        ) {
            let root = URL(fileURLWithPath: "/Pisaka-rust-tests")
            tree = StubFileTree(root: root, files: [:])
            layout = LSPInstallLayout(base: root.appendingPathComponent(LSPInstallLayout.directoryName))
            self.discovery = discovery
            downloader = ScriptedDownloader()
            unpacker = ScriptedUnpacker(writingInto: tree)
            downloader.serve(Fixture.archive)
            downloader.serve(Fixture.nextArchive)

            suiteName = "LSPRustProvisioningTests.\(name)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)

            engine = LSPInstallEngine(
                manifest: manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: .arm64
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPRustProvisioningModel(
                discovery: discovery,
                engine: engine,
                settings: settings
            )
            observe()
        }

        /// A relaunch: a second engine, store and model over the same disk and the
        /// same defaults suite.
        ///
        /// The manifest is a parameter because an app *update* is a relaunch over
        /// a moved pin, which is the only way the upgrade states — a version
        /// directory on disk that the row reports as not installed — can be
        /// staged at all.
        @MainActor
        func rebuild(manifest: LSPProvisioningManifest = Fixture.manifest) {
            engine = LSPInstallEngine(
                manifest: manifest,
                layout: layout,
                fileService: tree,
                downloader: downloader,
                unpacker: unpacker,
                architecture: .arm64
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPRustProvisioningModel(
                discovery: discovery,
                engine: engine,
                settings: settings
            )
            pushes = []
            observe()
        }

        @MainActor
        private func observe() {
            model.onDescriptionsChange = { [weak self] descriptions in
                guard let self else { return }
                pushes.append((descriptions, tree.files[Fixture.installedExecutable] != nil))
            }
        }

        /// Stage an app-installed copy the way a previous run would have left one
        /// — the disk is the state (D12), so this is the whole of it.
        @MainActor
        func stageAppInstalledCopy() {
            try? tree.write(
                "#!rust-analyzer",
                to: root.appendingPathComponent(Fixture.installedExecutable)
            )
        }

        var installedExecutablePath: String {
            root.appendingPathComponent(Fixture.installedExecutable).path
        }

        func deinitSuite() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeHarness(
        _ name: String = #function,
        discovery: ScriptedRustDiscovery,
        manifest: LSPProvisioningManifest = Fixture.manifest
    ) -> Harness {
        let harness = Harness(name: name, discovery: discovery, manifest: manifest)
        addTeardownBlock { harness.deinitSuite() }
        return harness
    }

    // MARK: - The pin

    /// The fixture proves the model reads a manifest; this proves the manifest it
    /// reads in the app says what the model's path math assumes. Two facts, and
    /// only two: the component exists under the id every other surface keys on,
    /// and it declares an executable — without which `installation` could never
    /// answer `.appInstalled` and the row would read "not installed" forever.
    func testTheShippedPinIsTheOneThisModelDrives() {
        let component = LSPRustAnalyzer.component(in: .standard)
        XCTAssertEqual(component?.id, "rust-analyzer")
        XCTAssertEqual(component?.executableSubpath, "bin/rust-analyzer")
        XCTAssertEqual(LSPRustAnalyzer.componentID, "rust-analyzer")
        XCTAssertEqual(LSPRustAnalyzer.displayName, "rust-analyzer")
    }

    // MARK: - No toolchain

    func testWithoutAToolchainNothingIsOfferedDownloadedOrRegistered() async {
        let harness = makeHarness(discovery: .missing)
        XCTAssertEqual(harness.model.row.status, .pending, "the row guessed before discovery answered")

        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .noToolchain)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))

        // Neither the silent half nor the loud one does anything, and the loud one
        // does not even record an answer: there is nothing to answer about (D23).
        await harness.model.prepareForOpening(.rust)
        await harness.model.accept()

        XCTAssertEqual(harness.downloader.requestedURLs, [])
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertEqual(harness.pushes.count, 0)
        XCTAssertEqual(harness.model.row.consent, .unasked)
    }

    /// The sharper half of D23: a toolchain is required even for a rust-analyzer
    /// that is *already there*, because the server shells out to `cargo` and
    /// without one it answers almost nothing while every request spends D7's
    /// restart budget finding out.
    ///
    /// A *discovered* rust-analyzer with no `cargo` is unrepresentable —
    /// `LSPRustToolchainReport.missing` carries no path, which is the rule stated
    /// in the type rather than checked in the model. What can still happen is the
    /// case staged here: a machine this app installed a copy on, whose toolchain
    /// has since gone. The row says so and nothing is registered.
    func testAToolchainThatWentAwayWithdrawsTheServerTheAppInstalled() async {
        let harness = makeHarness(discovery: .missing)
        harness.stageAppInstalledCopy()
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)

        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .noToolchain)
        XCTAssertEqual(
            harness.model.installation,
            .appInstalled(version: Fixture.version, path: harness.installedExecutablePath),
            "the files are still there — the row is about the toolchain, not about them"
        )
        XCTAssertEqual(harness.model.descriptions, [], "a server with no cargo to drive was registered")
        XCTAssertEqual(harness.pushes.count, 0)
        // The files are still this app's to reclaim, which is the one action that
        // still makes sense in this state.
        XCTAssertTrue(harness.model.row.hasFilesOnDisk)
        XCTAssertTrue(harness.model.row.canRemove)
    }

    /// The negative answer is cached like the positive one — `LSPToolchain`'s
    /// rule, and the reason discovery is a task the model keeps rather than a call
    /// it repeats.
    func testDiscoveryRunsOncePerAppRunIncludingWhenItFindsNothing() async {
        let harness = makeHarness(discovery: .missing)
        await harness.model.discover()
        await harness.model.discover()
        // Including through the silent half, which awaits the same task rather
        // than reading a `report` that may not be there yet.
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.discovery.callCount, 1)
    }

    /// The other half of "a toolchain is required": rust-analyzer resolves `cargo`
    /// on its own `PATH`, so a registration without the `PATH` the `cargo` is on
    /// registers a server that starts and answers nothing — and an answer of
    /// nothing is what the routing provider cannot distinguish from a file that
    /// declares nothing, so it would fall back silently for good while every
    /// surface in the app said rust-analyzer was installed.
    func testRustAnalyzerIsNotRegisteredWithoutThePathItsToolchainIsOn() async {
        let harness = makeHarness(
            discovery: .found(searchPath: "", rustAnalyzer: Fixture.userRustAnalyzerPath)
        )
        await harness.model.discover()

        // The row is unchanged — a toolchain *was* found, and this is not a state
        // the user can be told about or do anything about.
        XCTAssertEqual(harness.model.row.status, .discovered)
        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userRustAnalyzerPath))
        // …but nothing that cannot work is handed to the workspace.
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertEqual(harness.pushes.count, 0)
    }

    // MARK: - A rust-analyzer the user already has

    func testARustAnalyzerAlreadyOnTheMachineIsUsedSilentlyAndIsNeverRemovable() async {
        let harness = makeHarness(discovery: .found(rustAnalyzer: Fixture.userRustAnalyzerPath))
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .discovered)
        XCTAssertNil(
            harness.model.consentPrompt(forOpening: .rust),
            "a rust-analyzer that is already there was offered as a download"
        )
        XCTAssertFalse(
            harness.model.row.canRemove,
            "Remove was offered for a binary the app did not put there"
        )
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userRustAnalyzerPath))

        // It is registered, and registered as the plain executable entry D9 says
        // Core composes — no new launch kind, no arguments.
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.model.descriptions.first?.id, "rust-analyzer")
        XCTAssertEqual(harness.model.descriptions.first?.languages, [.rust])
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: Fixture.userRustAnalyzerPath)
        )
        XCTAssertEqual(harness.model.descriptions.first?.arguments, [])
        XCTAssertEqual(
            harness.model.descriptions.first?.environment,
            ["PATH": ScriptedRustDiscovery.searchPath],
            "rust-analyzer was registered without the PATH its `cargo` is on"
        )
        XCTAssertEqual(harness.pushes.count, 1)

        // And nothing is downloaded for it, whatever the consent says.
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.downloader.requestedURLs, [])

        // Refusing on its own, not only in the view.
        await harness.model.remove()
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.pushes.count, 1)
        XCTAssertEqual(harness.tree.removedPaths, [])
        // Read off the store rather than the row: a refused removal publishes
        // nothing, so the row is deliberately the one from `discover()`.
        XCTAssertEqual(
            harness.settings.consent(for: LSPRustAnalyzer.componentID), .accepted,
            "a refused removal recorded a decline"
        )
    }

    /// D24's preference, staged as the state that makes it visible: both copies
    /// present, and the app's is the one that answers — because it is the one at
    /// the pinned version and the only one Remove may touch.
    func testTheAppsOwnCopyIsPreferredOverOneFoundOnTheMachine() async {
        let harness = makeHarness(discovery: .found(rustAnalyzer: Fixture.userRustAnalyzerPath))
        harness.stageAppInstalledCopy()
        await harness.model.discover()

        XCTAssertEqual(
            harness.model.installation,
            .appInstalled(version: Fixture.version, path: harness.installedExecutablePath)
        )
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: harness.installedExecutablePath)
        )
        XCTAssertTrue(harness.model.row.canRemove)
    }

    // MARK: - Accepting

    func testAcceptingDownloadsOnceCommitsWithOneRenameAndRegisters() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertEqual(harness.model.row.licenseSPDX, "Apache-2.0 OR MIT")

        // The prompt is sized, which is the whole of what makes it 2b's prompt
        // rather than gopls's — nobody is asked to download something unsized
        // (D15), and the figure is the engine's own arithmetic rather than a
        // second copy of it.
        let prompt = harness.model.consentPrompt(forOpening: .rust)
        XCTAssertEqual(prompt?.displayName, "rust-analyzer")
        XCTAssertEqual(prompt?.version, Fixture.version)
        XCTAssertEqual(
            prompt?.downloadByteCount,
            harness.engine.pendingDownloadByteCount(for: LSPRustAnalyzer.componentID)
        )
        XCTAssertEqual(prompt?.downloadByteCount, 13_000_000)

        // …and only for Rust. This is the one state where every other condition is
        // satisfied, so it is the only place the language check can be seen: a Mac
        // with a Rust toolchain would otherwise offer to download rust-analyzer
        // above every Swift and JSON file, spending a one-shot consent on the
        // wrong question.
        for other in SyntaxLanguage.allCases where other != .rust {
            XCTAssertNil(harness.model.consentPrompt(forOpening: other), "\(other) was offered rust-analyzer")
        }

        await harness.model.accept()

        // One download of the pinned artifact, and one rename onto the version
        // directory with nothing left staged.
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.archive), 1)
        XCTAssertEqual(harness.tree.moves.count, 1)
        XCTAssertEqual(harness.tree.moves.first?.to, Fixture.versionDirectory)
        XCTAssertTrue(harness.tree.filePaths(under: "LanguageServers/.staging").isEmpty)
        XCTAssertNotNil(harness.tree.files[Fixture.installedExecutable])

        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertTrue(harness.model.row.canRemove)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertNil(harness.model.row.failureMessage)
        XCTAssertEqual(
            harness.model.row.pendingDownloadByteCount, 0,
            "an installed component still reported bytes to fetch"
        )
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: harness.installedExecutablePath)
        )
        XCTAssertEqual(
            harness.model.descriptions.first?.environment,
            ["PATH": ScriptedRustDiscovery.searchPath],
            "the copy the app just downloaded was registered without the PATH its `cargo` is on"
        )
        XCTAssertEqual(harness.pushes.count, 1, "one install published twice")

        // The answer, and the install, survive a relaunch — the second read is a
        // directory listing, not a note this run left behind.
        harness.rebuild()
        await harness.model.discover()
        XCTAssertEqual(harness.model.row.consent, .accepted)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "a relaunch re-downloaded what was already installed"
        )
    }

    func testTwoAcceptsProduceOneDownload() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()

        let gate = Gate()
        harness.downloader.hold(Fixture.archive, on: gate)

        let first = Task { await harness.model.accept() }
        await gate.waitUntilReached()

        // The window itself: the row says what is happening and offers nothing.
        XCTAssertEqual(harness.model.row.status, .installing)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))

        let second = Task { await harness.model.install() }
        await Task.yield()
        gate.release()

        await first.value
        await second.value

        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "two accepts started two downloads"
        )
        XCTAssertEqual(harness.tree.moves.count, 1)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertEqual(harness.pushes.count, 1)
    }

    // MARK: - Not yet asked

    /// The layer's first promise, and the one the rest of this suite kept
    /// stepping over: **nothing is downloaded before the question is answered.**
    ///
    /// Every other `prepareForOpening` case here reaches its answer through some
    /// other guard — no toolchain, declined, already installed — so a
    /// `prepareForOpening` that treated "not yet asked" as good enough would have
    /// passed all of them while shipping a silent 13 MB fetch on the first `.rs`
    /// tab of a machine that has never seen the banner. This is the case with the
    /// toolchain *found* and the consent *unasked*, where the only thing standing
    /// between the tab open and the network is that one comparison.
    func testARustFileOpenedBeforeTheQuestionIsAnsweredDownloadsNothing() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        XCTAssertEqual(harness.model.row.consent, .unasked)

        await harness.model.prepareForOpening(.rust)

        XCTAssertEqual(harness.downloader.requestedURLs, [], "an unanswered question started a download")
        XCTAssertEqual(harness.model.row.consent, .unasked, "opening a file answered the question")
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertEqual(harness.pushes.count, 0)

        // What it does instead: the banner has something to ask, and the size it
        // asks about is the slice this architecture would fetch.
        let prompt = harness.model.consentPrompt(forOpening: .rust)
        XCTAssertEqual(prompt?.version, Fixture.version)
        XCTAssertEqual(prompt?.downloadByteCount, 13_000_000)
    }

    /// A manifest that describes no rust-analyzer — the state every surface of
    /// this model has its own `component` guard for, asserted as one answer
    /// rather than as five separate absences.
    ///
    /// Not a state the shipped pin can be in, which is exactly why it is worth a
    /// test: nothing in `swift test` compiles against `LSPProvisioningManifest`
    /// being non-empty, so the guards are load-bearing for a by-hand manifest
    /// edit and for nothing else.
    func testAManifestThatDescribesNoRustAnalyzerOffersNothing() async {
        let harness = makeHarness(discovery: .found(), manifest: Fixture.emptyManifest)
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .notInstalled, "nothing is installed, and that is true")
        XCTAssertEqual(harness.model.row.version, "")
        XCTAssertEqual(harness.model.row.licenseSPDX, "")
        XCTAssertEqual(harness.model.row.pendingDownloadByteCount, 0)
        XCTAssertFalse(
            harness.model.row.canInstall,
            "the row offered Install for a component the manifest does not describe"
        )
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))

        // And the two entry points agree with the row rather than with each other:
        // neither downloads, neither records an answer, and neither registers.
        await harness.model.install()
        await harness.model.prepareForOpening(.rust)

        XCTAssertEqual(harness.downloader.requestedURLs, [])
        XCTAssertEqual(harness.model.row.consent, .unasked, "consent was recorded for nothing")
        XCTAssertNil(harness.model.installation)
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertEqual(harness.pushes.count, 0)
    }

    // MARK: - Declining

    func testDecliningAnswersOnceAndSurvivesARelaunch() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        harness.model.decline()

        XCTAssertEqual(harness.model.row.consent, .declined)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.downloader.requestedURLs, [])
        XCTAssertEqual(harness.pushes.count, 0)

        harness.rebuild()
        await harness.model.discover()
        XCTAssertEqual(harness.model.row.consent, .declined)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust), "the answer did not survive a relaunch")
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.downloader.requestedURLs, [])

        // Turning it around is the Settings row's job, and the row still offers
        // the button that does it.
        XCTAssertTrue(harness.model.row.canInstall)
    }

    /// The silent half of D15 on a *cold* run: the tab open beats the search.
    ///
    /// Discovery is started unawaited at launch and costs a subprocess, while this
    /// runs from the banner's `.task`, so a restored `.rs` tab regularly arrives
    /// while the report is still `nil`. Reading it rather than awaiting it would
    /// make that return silently — and the trigger never fires again, so "installs
    /// on first use" simply would not happen for the whole app run.
    func testTheFirstRustTabWaitsForDiscoveryRatherThanDecliningSilently() async {
        let harness = makeHarness(discovery: .found())
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)

        let gate = Gate()
        harness.discovery.hold(on: gate)

        // The launch call, unawaited, exactly as the app composes it.
        let launch = Task { await harness.model.discover() }
        await gate.waitUntilReached()
        XCTAssertEqual(harness.model.row.status, .pending, "the row answered before the search did")

        let opened = Task { await harness.model.prepareForOpening(.rust) }
        gate.release()
        await launch.value
        await opened.value

        XCTAssertEqual(harness.discovery.callCount, 1, "the tab open started a second search")
        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "the first Rust tab of a cold run downloaded nothing"
        )
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
    }

    /// The silent half of D15: accepted once, installed on the first Rust file of
    /// the next run without asking again.
    func testAnAlreadyAcceptedRustAnalyzerIsInstalledWhenARustFileIsOpened() async {
        let harness = makeHarness(discovery: .found())
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)
        await harness.model.discover()

        await harness.model.prepareForOpening(.swift)
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(
            harness.downloader.requestedURLs, [],
            "a language that is not Rust started a download"
        )

        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.archive), 1)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))

        // And the tab after that changes nothing.
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.archive), 1)
    }

    // MARK: - Failure

    func testAFailedInstallIsARowMessageAndIsNotRetriedAutomatically() async {
        let harness = makeHarness(discovery: .found())
        harness.downloader.fail(Fixture.archive)
        await harness.model.discover()

        await harness.model.accept()

        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.archive), 1)
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertTrue(harness.model.row.canInstall, "a failed install offered no Retry")
        XCTAssertFalse(harness.model.row.failureWasRemoval)
        XCTAssertEqual(
            harness.model.row.failureMessage?.hasPrefix("Could not download “rust-analyzer”."), true,
            "a failed download was reported as something else"
        )
        XCTAssertEqual(harness.model.descriptions, [], "a failed install was registered")
        XCTAssertEqual(harness.pushes.count, 0)

        // Nothing outside `.staging` was touched, and the staging tree is gone.
        XCTAssertFalse(harness.tree.hasDirectory(Fixture.versionDirectory))
        XCTAssertTrue(harness.tree.filePaths(under: "LanguageServers/.staging").isEmpty)
        XCTAssertEqual(harness.tree.moves, [])

        // Consent was recorded, so every later Rust tab would qualify — and none
        // of them starts another download this run.
        XCTAssertEqual(harness.model.row.consent, .accepted)
        await harness.model.prepareForOpening(.rust)
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "a failed attempt was retried on a tab switch"
        )

        // Retry from the row is unconditional, and it clears the sentence.
        harness.downloader.serve(Fixture.archive)
        await harness.model.install()
        XCTAssertEqual(harness.downloader.requestCount(for: Fixture.archive), 2)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertNil(harness.model.row.failureMessage)
    }

    /// The failure the `.gzip` format introduced (D22), seen from up here: an
    /// unpack that "succeeded" and produced something nobody can run installs
    /// nothing, and the row says so rather than reporting a server that cannot
    /// start.
    func testAnUnpackThatProducesANonExecutableInstallsNothing() async {
        let harness = makeHarness(discovery: .found())
        harness.unpacker.forgetExecutableMode(Fixture.archive)
        await harness.model.discover()

        await harness.model.accept()

        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertEqual(
            harness.model.row.failureMessage?.hasPrefix("Could not unpack “rust-analyzer”."), true
        )
        XCTAssertEqual(harness.tree.moves, [], "an unrunnable binary was committed")
        XCTAssertFalse(harness.tree.hasDirectory(Fixture.versionDirectory))
        XCTAssertEqual(harness.model.descriptions, [])
    }

    // MARK: - Removal

    func testRemovingWithdrawsTheDescriptionBeforeTheFilesGoAway() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()
        XCTAssertEqual(harness.pushes.count, 1)

        await harness.model.remove()

        // One further push, carrying no rust-analyzer — and made while the
        // executable it was running from still existed (D16: stop the server,
        // *then* delete what it was running).
        XCTAssertEqual(harness.pushes.count, 2)
        XCTAssertEqual(harness.pushes.last?.descriptions, [])
        XCTAssertEqual(
            harness.pushes.last?.filesPresent, true,
            "the executable was deleted before the push that stops the server"
        )

        XCTAssertNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/rust-analyzer"))
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertFalse(harness.model.row.isRemoving)
        XCTAssertNil(harness.model.installation)

        // "Do not download this, and do not ask me" — the only answer that
        // describes what just happened, and it survives a relaunch.
        XCTAssertEqual(harness.model.row.consent, .declined)
        harness.rebuild()
        await harness.model.discover()
        XCTAssertNil(harness.model.consentPrompt(forOpening: .rust))
        await harness.model.prepareForOpening(.rust)
        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "a removed rust-analyzer was silently re-downloaded"
        )
    }

    /// Removing the app's copy on a machine that also has the user's falls back to
    /// theirs — right, since this app neither put it there nor asked about it, and
    /// the decline it just recorded gates *downloading*, not using.
    func testRemovingTheAppsCopyFallsBackToTheOneOnTheMachine() async {
        let harness = makeHarness(discovery: .found(rustAnalyzer: Fixture.userRustAnalyzerPath))
        harness.stageAppInstalledCopy()
        await harness.model.discover()

        await harness.model.remove()

        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userRustAnalyzerPath))
        XCTAssertEqual(harness.model.row.status, .discovered)
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: Fixture.userRustAnalyzerPath)
        )
        // The withdrawal is still pushed first: the app's binary is deleted, and
        // whatever was running from it has to be stopped before that happens.
        XCTAssertEqual(harness.pushes.map(\.descriptions.isEmpty), [false, true, false])
    }

    /// A version directory the pin moved past is still this app's to reclaim —
    /// `LSPRustServerRow.hasFilesOnDisk`'s rule, which this row states in the same
    /// words the Go row does.
    func testAVersionThePinMovedPastIsStillRemovable() async {
        let harness = makeHarness(discovery: .found())
        let stranded = "LanguageServers/rust-analyzer/2025-01-01/bin/rust-analyzer"
        try? harness.tree.write("#!rust-analyzer", to: harness.root.appendingPathComponent(stranded))
        await harness.model.discover()

        // Nothing is *servable*: the pinned version is not installed, so the row
        // offers Install — and Remove, for the files that are nonetheless there.
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertNil(harness.model.installation)
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertTrue(harness.model.row.canInstall)
        XCTAssertTrue(harness.model.row.canRemove, "a stranded version directory had no way out")

        await harness.model.remove()

        XCTAssertNil(harness.tree.files[stranded])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/rust-analyzer"))
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.row.failureMessage)
    }

    /// A Remove arriving while an install is still in flight, from the other side
    /// of the same window `testASecondRemovalDuringTheShutdownPushDoesNothing`
    /// covers — and it is the guard, not `canRemove`, that has to refuse: the row
    /// is a value read a frame ago, and the download suspends for as long as the
    /// network takes.
    ///
    /// What it prevents is not a tidiness problem: `engine.remove` deletes the
    /// component directory the in-flight install is about to rename its staging
    /// tree onto, and the two writes race over consent as well — the install
    /// records `accepted`, the removal `declined`, and which one survives is the
    /// interleaving's business rather than the user's.
    func testARemovalDuringAnInstallDoesNothing() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()

        let gate = Gate()
        harness.downloader.hold(Fixture.archive, on: gate)
        let install = Task { await harness.model.accept() }
        await gate.waitUntilReached()

        XCTAssertEqual(harness.model.row.status, .installing)
        await harness.model.remove()

        XCTAssertEqual(harness.tree.removedPaths, [], "a Remove ran inside an install")
        XCTAssertFalse(harness.model.row.isRemoving)
        XCTAssertEqual(harness.model.row.consent, .accepted, "a refused Remove still recorded a decline")

        gate.release()
        await install.value

        // The install the Remove did not disturb finished normally.
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertNotNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertNil(harness.model.row.failureMessage)
    }

    /// The upgrade window, and the only state in which `canRemove`'s
    /// `status != .installing` clause decides anything on its own: a version
    /// directory is on disk — so `hasFilesOnDisk` says yes — while the *new* pin
    /// is downloading. Removing there would delete the component directory the
    /// commit is about to rename onto.
    func testAnUpgradeOffersNoRemoveWhileTheNewPinIsDownloading() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))

        // An app update: the same disk, one pin later.
        harness.rebuild(manifest: Fixture.bumpedManifest)
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .notInstalled, "the moved pin read as installed")
        XCTAssertTrue(harness.model.row.hasFilesOnDisk)
        XCTAssertTrue(harness.model.row.canRemove, "the superseded directory had no way out")

        let gate = Gate()
        harness.downloader.hold(Fixture.nextArchive, on: gate)
        let upgrade = Task { await harness.model.install() }
        await gate.waitUntilReached()

        XCTAssertEqual(harness.model.row.status, .installing)
        XCTAssertTrue(
            harness.model.row.hasFilesOnDisk,
            "the old version is still on disk — which is why the clause below is the one that decides"
        )
        XCTAssertFalse(harness.model.row.canRemove, "Remove was offered mid-upgrade")

        gate.release()
        await upgrade.value
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.nextVersion))
    }

    func testAFailedRemovalIsReportedAsARemoval() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()

        harness.tree.removeFailures.insert("LanguageServers/rust-analyzer")
        await harness.model.remove()

        XCTAssertNotNil(harness.model.row.failureMessage)
        XCTAssertTrue(harness.model.row.failureWasRemoval)
        // The files are still there, so the push that re-registers them is right —
        // a Remove that visibly undoes itself with nothing saying why is the one
        // genuinely confusing outcome this surface can produce.
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.model.row.consent, .accepted, "a failed removal recorded a decline")
    }

    /// A failed *removal* is not the failure that suppresses the automatic
    /// install, and the difference is the whole reason `Failure` carries
    /// `wasRemoval` rather than being a string.
    ///
    /// The state staged here is the one where it matters: consent is still
    /// `accepted` (only a *successful* removal declines), the pinned version is
    /// not installed, and a superseded directory is what the failed removal left
    /// behind. "Some failure happened" would sit on that for the rest of the app
    /// run with a sentence about a removal, while the thing the user asked for —
    /// a working rust-analyzer — is one install away.
    func testAFailedRemovalDoesNotSuppressTheInstallOnFirstUse() async {
        let harness = makeHarness(discovery: .found())
        let stranded = "LanguageServers/rust-analyzer/2025-01-01/bin/rust-analyzer"
        try? harness.tree.write("#!rust-analyzer", to: harness.root.appendingPathComponent(stranded))
        harness.settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)
        await harness.model.discover()

        harness.tree.removeFailures.insert("LanguageServers/rust-analyzer")
        await harness.model.remove()

        XCTAssertTrue(harness.model.row.failureWasRemoval)
        XCTAssertEqual(harness.model.row.consent, .accepted)
        XCTAssertNil(harness.model.installation, "the pinned version was never installed")

        await harness.model.prepareForOpening(.rust)

        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "a failed removal blocked the install the accepted consent still asks for"
        )
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: Fixture.version))
        XCTAssertNil(harness.model.row.failureMessage, "the removal's sentence outlived the install")
        // The other half of the distinction — a failed *install* still suppresses
        // the automatic retry — is `testAFailedInstallIsARowMessageAndIsNotRetriedAutomatically`.
    }

    /// A second Remove arriving while the first is still inside the push — the
    /// window `canRemove` hides and the model has to refuse on its own, because
    /// the push is exactly how long the server takes to stop.
    func testASecondRemovalDuringTheShutdownPushDoesNothing() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()

        let gate = PushGate()
        harness.model.onDescriptionsChange = { _ in await gate.hold() }

        let first = Task { await harness.model.remove() }
        await gate.waitUntilHeld()

        XCTAssertTrue(harness.model.row.isRemoving)
        XCTAssertFalse(harness.model.row.canRemove)

        await harness.model.remove()
        XCTAssertNotNil(
            harness.tree.files[Fixture.installedExecutable],
            "a second Remove deleted the executable while the first was still stopping the server"
        )

        // An *install* arriving in the same window is refused by the model too,
        // and this is the only place that guard can be seen. Without it a download
        // would stage and rename a version directory into the component directory
        // `engine.remove` is concurrently deleting, and would flip consent to
        // `accepted` inside a removal that then records `declined` — leaving the
        // final answer up to the interleaving.
        await harness.model.install()
        XCTAssertEqual(
            harness.downloader.requestCount(for: Fixture.archive), 1,
            "a download started during a removal"
        )
        XCTAssertEqual(harness.model.row.consent, .accepted)

        gate.release()
        await first.value
        XCTAssertNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertFalse(harness.model.row.isRemoving)
    }

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

        /// Bounded, because the regression this gate exists to catch — a
        /// `remove()` that deletes before it publishes — is precisely the one that
        /// would never arrive here: an unbounded spin turns a named failure into a
        /// CI job that hangs until the runner kills it and says nothing about why.
        func waitUntilHeld(
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            for _ in 0..<100_000 {
                if held { return }
                await Task.yield()
            }
            XCTFail("the removal never reached its push", file: file, line: line)
        }
    }
}
