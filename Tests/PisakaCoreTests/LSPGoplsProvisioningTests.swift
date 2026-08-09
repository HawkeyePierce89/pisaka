import XCTest
@testable import PisakaCore

/// gopls is where the LSP layer's promises are made to a user who has a Go
/// toolchain and did not ask this app to touch it, so this is where they are
/// pinned: nothing is built without an answer, an answer is given once, a gopls
/// the user already has is used and never removed, a failure is a sentence in a
/// Settings row and nothing else, and a removal stops the server before it
/// deletes the executable.
///
/// **No manifest, on purpose.** The engine here is constructed over an empty
/// `LSPProvisioningManifest`, because gopls is not in one and cannot be (D17):
/// there is no URL to pin and no digest to verify. What the engine contributes
/// is `layout` — the same path math every component uses — and `remove(_:)`,
/// which deletes any component directory whether or not the manifest describes
/// it. A test that had to describe gopls as an `LSPComponent` to exercise this
/// model would be testing a design this one deliberately does not have.
@MainActor
final class LSPGoplsProvisioningTests: XCTestCase {
    private enum Fixture {
        static let goPath = "/usr/local/go/bin/go"
        static let userGoplsPath = "/Users/someone/go/bin/gopls"
        static let versionDirectory = "LanguageServers/gopls/0.23.0"
        static let installedExecutable = "LanguageServers/gopls/0.23.0/bin/gopls"
    }

    // MARK: - The harness

    /// One install root, one settings suite, and a model over both —
    /// rebuildable, which is how "the answer survived a relaunch" and "the
    /// registry is derived from the disk at launch" are staged.
    private final class Harness {
        let root = URL(fileURLWithPath: "/Pisaka-go-tests")
        let tree: StubFileTree
        let layout: LSPInstallLayout
        let discovery: ScriptedGoDiscovery
        let installer: ScriptedGoInstaller
        let defaults: UserDefaults
        private let suiteName: String

        private(set) var engine: LSPInstallEngine
        private(set) var settings: SettingsStore
        private(set) var model: LSPGoplsProvisioningModel

        /// Every push the model made, and — for each — whether the installed
        /// executable still existed when it was made. The second half is what
        /// pins D16's ordering: the removal's push has to arrive while the
        /// binary it names still exists, because the push is what stops the
        /// server running from it.
        private(set) var pushes: [(descriptions: [LSPServerDescription], filesPresent: Bool)] = []

        @MainActor
        init(name: String, discovery: ScriptedGoDiscovery) {
            let root = URL(fileURLWithPath: "/Pisaka-go-tests")
            tree = StubFileTree(root: root, files: [:])
            layout = LSPInstallLayout(base: root.appendingPathComponent(LSPInstallLayout.directoryName))
            self.discovery = discovery
            installer = ScriptedGoInstaller(writingInto: tree)

            suiteName = "LSPGoplsProvisioningTests.\(name)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)

            engine = LSPInstallEngine(
                manifest: LSPProvisioningManifest(components: []),
                layout: layout,
                fileService: tree,
                downloader: ScriptedDownloader(),
                unpacker: ScriptedUnpacker(writingInto: tree),
                architecture: .arm64
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPGoplsProvisioningModel(
                discovery: discovery,
                installer: installer,
                engine: engine,
                fileService: tree,
                settings: settings
            )
            observe()
        }

        /// A relaunch: a second engine, store and model over the same disk and
        /// the same defaults suite.
        @MainActor
        func rebuild() {
            engine = LSPInstallEngine(
                manifest: LSPProvisioningManifest(components: []),
                layout: layout,
                fileService: tree,
                downloader: ScriptedDownloader(),
                unpacker: ScriptedUnpacker(writingInto: tree),
                architecture: .arm64
            )
            settings = SettingsStore(defaults: defaults)
            model = LSPGoplsProvisioningModel(
                discovery: discovery,
                installer: installer,
                engine: engine,
                fileService: tree,
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

        var installedExecutablePath: String {
            root.appendingPathComponent(Fixture.installedExecutable).path
        }

        func deinitSuite() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeHarness(
        _ name: String = #function,
        discovery: ScriptedGoDiscovery
    ) -> Harness {
        let harness = Harness(name: name, discovery: discovery)
        addTeardownBlock { harness.deinitSuite() }
        return harness
    }

    // MARK: - The pin

    func testThePinIsTheOneTheProcedureUpdates() {
        XCTAssertEqual(LSPGopls.componentID, "gopls")
        XCTAssertEqual(LSPGopls.modulePath, "golang.org/x/tools/gopls")
        XCTAssertEqual(LSPGopls.version, "0.23.0")
        // The install root spells a version without the `v`; `go install` spells
        // it with one. Both are derived from a single constant, so a bump cannot
        // move one and leave the other.
        XCTAssertEqual(LSPGopls.moduleVersion, "v0.23.0")
        XCTAssertEqual(LSPGopls.executableSubpath, "bin/gopls")
    }

    // MARK: - No toolchain

    func testWithoutAToolchainNothingIsOfferedBuiltOrRegistered() async {
        let harness = makeHarness(discovery: .missing)
        XCTAssertEqual(harness.model.row.status, .pending, "the row guessed before discovery answered")

        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .noToolchain)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go))

        // Neither the silent half nor the loud one does anything, and the loud
        // one does not even record an answer: there is nothing to answer about.
        await harness.model.prepareForOpening(.go)
        await harness.model.accept()

        XCTAssertEqual(harness.installer.calls, [])
        XCTAssertEqual(harness.model.descriptions, [])
        XCTAssertEqual(harness.pushes.count, 0)
        XCTAssertEqual(harness.model.row.consent, .unasked)
        XCTAssertNil(harness.model.installation)
    }

    /// The negative answer is cached like the positive one — `LSPToolchain`'s
    /// rule, and the reason discovery is a task the model keeps rather than a
    /// call it repeats.
    func testDiscoveryRunsOncePerAppRunIncludingWhenItFindsNothing() async {
        let harness = makeHarness(discovery: .missing)
        await harness.model.discover()
        await harness.model.discover()
        // Including through the silent half, which awaits the same task rather
        // than reading a `report` that may not be there yet.
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.discovery.callCount, 1)
    }

    // MARK: - A gopls the user already has

    func testAGoplsAlreadyOnTheMachineIsUsedSilentlyAndIsNeverRemovable() async {
        let harness = makeHarness(discovery: .found(gopls: Fixture.userGoplsPath))
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .discovered)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go), "a gopls that is already there was offered")
        XCTAssertFalse(harness.model.row.canRemove, "Remove was offered for a binary the app did not put there")
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userGoplsPath))

        // It is registered, and registered as the plain executable entry D18
        // says Core composes — no new launch kind, no arguments.
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.model.descriptions.first?.id, "gopls")
        XCTAssertEqual(harness.model.descriptions.first?.languages, [.go])
        XCTAssertEqual(harness.model.descriptions.first?.launch, .executable(path: Fixture.userGoplsPath))
        XCTAssertEqual(harness.model.descriptions.first?.arguments, [])
        XCTAssertEqual(harness.pushes.count, 1)

        // And nothing is built for it, whatever the consent says.
        harness.settings.setConsent(.accepted, for: LSPGopls.componentID)
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls, [])

        // Refusing on its own, not only in the view.
        await harness.model.remove()
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.pushes.count, 1)
    }

    // MARK: - Accepting

    func testAcceptingBuildsOnceCommitsWithOneRenameAndRegisters() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()

        XCTAssertEqual(harness.model.row.status, .notInstalled)
        let prompt = harness.model.consentPrompt(forOpening: .go)
        XCTAssertEqual(prompt?.displayName, "gopls")
        XCTAssertEqual(prompt?.version, "0.23.0")
        XCTAssertEqual(prompt?.goExecutablePath, Fixture.goPath, "the banner cannot say whose toolchain builds it")
        // …and only for Go. This is the one state where every other condition is
        // satisfied, so it is the only place the language check can be seen: a
        // Mac with a Go toolchain would otherwise offer to build gopls above
        // every Swift and JSON file, spending a one-shot consent on the wrong
        // question.
        for other in SyntaxLanguage.allCases where other != .go {
            XCTAssertNil(harness.model.consentPrompt(forOpening: other), "\(other) was offered gopls")
        }

        await harness.model.accept()

        // One build, asked for the pinned module and version, with the user's
        // own `go` and with `GOBIN` inside the staging tree — nothing global.
        XCTAssertEqual(harness.installer.calls.count, 1)
        XCTAssertEqual(harness.installer.calls.first?.module, "golang.org/x/tools/gopls")
        XCTAssertEqual(harness.installer.calls.first?.version, "v0.23.0")
        XCTAssertEqual(harness.installer.calls.first?.goExecutablePath, Fixture.goPath)
        XCTAssertTrue(
            harness.installer.calls.first?.binDirectory.path.contains("/.staging/") == true,
            "the build wrote straight into the version directory"
        )

        // One rename, onto the version directory, and nothing left staged.
        XCTAssertEqual(harness.tree.moves.count, 1)
        XCTAssertEqual(harness.tree.moves.first?.to, Fixture.versionDirectory)
        XCTAssertTrue(harness.tree.filePaths(under: "LanguageServers/.staging").isEmpty)
        XCTAssertNotNil(harness.tree.files[Fixture.installedExecutable])

        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertTrue(harness.model.row.canRemove)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertNil(harness.model.row.failureMessage)
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: harness.installedExecutablePath)
        )
        XCTAssertEqual(harness.pushes.count, 1, "one install published twice")

        // The answer, and the install, survive a relaunch — the second read is a
        // directory listing, not a note this run left behind.
        harness.rebuild()
        await harness.model.discover()
        XCTAssertEqual(harness.model.row.consent, .accepted)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go))
        XCTAssertEqual(harness.installer.calls.count, 1, "a relaunch rebuilt what was already installed")
    }

    /// D19's preference, staged as the state that makes it visible: both copies
    /// present, and the app's is the one that answers — because it is the one at
    /// the pinned version and the only one Remove may touch.
    func testTheAppsOwnCopyIsPreferredOverOneFoundOnTheMachine() async {
        // The Settings row cannot start this install (a discovered copy already
        // answers), but a previous run's could have — so the state is staged on
        // the disk before the model exists and read the way a relaunch reads it:
        // `discover()` and a directory listing, which is the whole of "the disk
        // is the state" (D12).
        let harness = makeHarness(discovery: .found(gopls: Fixture.userGoplsPath))
        try? harness.tree.write("#!gopls", to: harness.root.appendingPathComponent(Fixture.installedExecutable))
        await harness.model.discover()

        XCTAssertEqual(
            harness.model.installation,
            .appInstalled(version: "0.23.0", path: harness.installedExecutablePath)
        )
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: harness.installedExecutablePath)
        )
    }

    func testAnUpgradeDropsTheVersionItReplaced() async {
        let harness = makeHarness(discovery: .found())
        try? harness.tree.write(
            "#!gopls",
            to: harness.root.appendingPathComponent("LanguageServers/gopls/0.20.0/bin/gopls")
        )
        await harness.model.discover()
        // A stranded version is not the pinned one, so nothing is installed yet.
        XCTAssertEqual(harness.model.row.status, .notInstalled)

        await harness.model.accept()

        XCTAssertNotNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertFalse(
            harness.tree.hasDirectory("LanguageServers/gopls/0.20.0"),
            "the replaced version was left behind"
        )
    }

    func testTwoAcceptsProduceOneBuild() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()

        let gate = Gate()
        harness.installer.hold(on: gate)

        let first = Task { await harness.model.accept() }
        await gate.waitUntilReached()

        // The window itself: the row says what is happening and offers nothing.
        XCTAssertEqual(harness.model.row.status, .installing)
        XCTAssertFalse(harness.model.row.canInstall)
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go))

        let second = Task { await harness.model.install() }
        await Task.yield()
        gate.release()

        await first.value
        await second.value

        XCTAssertEqual(harness.installer.calls.count, 1, "two accepts started two builds")
        XCTAssertEqual(harness.tree.moves.count, 1)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertEqual(harness.pushes.count, 1)
    }

    // MARK: - Declining

    func testDecliningAnswersOnceAndSurvivesARelaunch() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        harness.model.decline()

        XCTAssertEqual(harness.model.row.consent, .declined)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go))
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls, [])
        XCTAssertEqual(harness.pushes.count, 0)

        harness.rebuild()
        await harness.model.discover()
        XCTAssertEqual(harness.model.row.consent, .declined)
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go), "the answer did not survive a relaunch")
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls, [])

        // Turning it around is the Settings row's job, and the row still offers
        // the button that does it.
        XCTAssertTrue(harness.model.row.canInstall)
    }

    /// The silent half of D15 on a *cold* run: the tab open beats the search.
    ///
    /// Discovery is started unawaited at launch and costs a subprocess, while
    /// this runs from the banner's `.task`, so a restored `.go` tab regularly
    /// arrives while the report is still `nil`. Reading it rather than awaiting
    /// it made that return silently — and the trigger never fires again, so
    /// "installs on first use" simply did not happen for the whole app run.
    func testTheFirstGoTabWaitsForDiscoveryRatherThanDecliningSilently() async {
        let harness = makeHarness(discovery: .found())
        harness.settings.setConsent(.accepted, for: LSPGopls.componentID)

        let gate = Gate()
        harness.discovery.hold(on: gate)

        // The launch call, unawaited, exactly as the app composes it.
        let launch = Task { await harness.model.discover() }
        await gate.waitUntilReached()
        XCTAssertEqual(harness.model.row.status, .pending, "the row answered before the search did")

        let opened = Task { await harness.model.prepareForOpening(.go) }
        gate.release()
        await launch.value
        await opened.value

        XCTAssertEqual(harness.discovery.callCount, 1, "the tab open started a second search")
        XCTAssertEqual(harness.installer.calls.count, 1, "the first Go tab of a cold run built nothing")
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
    }

    /// The silent half of D15: accepted once, built on the first Go file of the
    /// next run without asking again.
    func testAnAlreadyAcceptedGoplsIsBuiltWhenAGoFileIsOpened() async {
        let harness = makeHarness(discovery: .found())
        harness.settings.setConsent(.accepted, for: LSPGopls.componentID)
        await harness.model.discover()

        await harness.model.prepareForOpening(.swift)
        await harness.model.prepareForOpening(.typescript)
        XCTAssertEqual(harness.installer.calls, [], "a language that is not Go started a build")

        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls.count, 1)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))

        // And the tab after that changes nothing.
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls.count, 1)
    }

    // MARK: - Failure

    func testAFailedBuildIsARowMessageAndIsNotRetriedAutomatically() async {
        let harness = makeHarness(discovery: .found())
        harness.installer.setOutcome(.fails(ScriptedGoInstaller.Failure.buildFailed))
        await harness.model.discover()

        await harness.model.accept()

        XCTAssertEqual(harness.installer.calls.count, 1)
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertTrue(harness.model.row.canInstall, "a failed install offered no Retry")
        XCTAssertFalse(harness.model.row.failureWasRemoval)
        XCTAssertEqual(harness.model.row.failureMessage?.contains("no required module"), true)
        XCTAssertEqual(harness.model.descriptions, [], "a failed build was registered")
        XCTAssertEqual(harness.pushes.count, 0)

        // Nothing outside `.staging` was touched, and the staging tree is gone.
        XCTAssertFalse(harness.tree.hasDirectory(Fixture.versionDirectory))
        XCTAssertTrue(harness.tree.filePaths(under: "LanguageServers/.staging").isEmpty)
        XCTAssertEqual(harness.tree.moves, [])

        // Consent was recorded, so every later Go tab would qualify — and none of
        // them starts another build this run.
        XCTAssertEqual(harness.model.row.consent, .accepted)
        await harness.model.prepareForOpening(.go)
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls.count, 1, "a failed attempt was retried on a tab switch")

        // Retry from the row is unconditional, and it clears the sentence.
        harness.installer.setOutcome(.builds)
        await harness.model.install()
        XCTAssertEqual(harness.installer.calls.count, 2)
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertNil(harness.model.row.failureMessage)
    }

    /// The one failure a build can hide: `go install` exits 0 and leaves nothing
    /// where `GOBIN` pointed. Committing that would register a server that cannot
    /// start, and every request through it would spend D7's restart budget
    /// finding out.
    func testABuildThatProducesNoExecutableInstallsNothing() async {
        let harness = makeHarness(discovery: .found())
        harness.installer.setOutcome(.buildsNothing)
        await harness.model.discover()

        await harness.model.accept()

        XCTAssertEqual(harness.model.row.status, .notInstalled)
        // The sentence, not merely "a sentence": this is the one surface a
        // failure has (D15), and asserting non-nil cannot tell this failure from
        // a build that never ran or a rename that would not happen.
        XCTAssertEqual(
            harness.model.row.failureMessage,
            LSPGoInstallError.executableMissing(path: "").errorDescription
        )
        XCTAssertEqual(harness.tree.moves, [], "an empty staging tree was committed")
        XCTAssertFalse(harness.tree.hasDirectory(Fixture.versionDirectory))
        XCTAssertEqual(harness.model.descriptions, [])
    }

    /// The other half of D13's atomicity: the build worked and the *rename* did
    /// not. Committing anyway would register an executable that is not there and
    /// spend D7's restart budget per request discovering it.
    func testAFailedRenameInstallsNothingAndLeavesNothingStaged() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        harness.tree.moveFailures.insert(Fixture.versionDirectory)

        await harness.model.accept()

        XCTAssertEqual(harness.installer.calls.count, 1, "the build did not even run")
        XCTAssertEqual(
            harness.model.row.failureMessage?.hasPrefix("Could not install “gopls”."), true,
            "a failed rename was reported as something other than an install failure"
        )
        XCTAssertFalse(harness.model.row.failureWasRemoval)
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertTrue(harness.model.row.canInstall, "a failed rename offered no Retry")
        XCTAssertFalse(harness.model.row.canRemove, "a failed rename left files to reclaim")
        XCTAssertNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertTrue(
            harness.tree.filePaths(under: "LanguageServers/.staging").isEmpty,
            "the staging tree survived the failure it caused"
        )
        XCTAssertEqual(harness.model.descriptions, [], "a rename that did not happen was registered")
        XCTAssertEqual(harness.pushes.count, 0)
    }

    // MARK: - Removal

    func testRemovingWithdrawsTheDescriptionBeforeTheFilesGoAway() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()
        XCTAssertEqual(harness.pushes.count, 1)

        await harness.model.remove()

        // One further push, carrying no gopls — and made while the executable it
        // was running from still existed (D16: stop the server, *then* delete
        // what it was running).
        XCTAssertEqual(harness.pushes.count, 2)
        XCTAssertEqual(harness.pushes.last?.descriptions, [])
        XCTAssertEqual(
            harness.pushes.last?.filesPresent, true,
            "the executable was deleted before the push that stops the server"
        )

        XCTAssertNil(harness.tree.files[Fixture.installedExecutable])
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/gopls"))
        XCTAssertEqual(harness.model.row.status, .notInstalled)
        XCTAssertFalse(harness.model.row.isRemoving)
        XCTAssertNil(harness.model.installation)

        // "Do not build this, and do not ask me" — the only answer that
        // describes what just happened, and it survives a relaunch.
        XCTAssertEqual(harness.model.row.consent, .declined)
        harness.rebuild()
        await harness.model.discover()
        XCTAssertNil(harness.model.consentPrompt(forOpening: .go))
        await harness.model.prepareForOpening(.go)
        XCTAssertEqual(harness.installer.calls.count, 1, "a removed gopls was silently rebuilt")
    }

    /// Removing the app's copy on a machine that also has the user's falls back
    /// to theirs — right, since this app neither put it there nor asked about it,
    /// and the decline it just recorded gates *building*, not using.
    func testRemovingTheAppsCopyFallsBackToTheOneOnTheMachine() async {
        let harness = makeHarness(discovery: .found(gopls: Fixture.userGoplsPath))
        try? harness.tree.write("#!gopls", to: harness.root.appendingPathComponent(Fixture.installedExecutable))
        await harness.model.discover()

        await harness.model.remove()

        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userGoplsPath))
        XCTAssertEqual(harness.model.row.status, .discovered)
        XCTAssertEqual(
            harness.model.descriptions.first?.launch,
            .executable(path: Fixture.userGoplsPath)
        )
        // The withdrawal is still pushed first: the app's binary is deleted, and
        // whatever was running from it has to be stopped before that happens.
        XCTAssertEqual(harness.pushes.map(\.descriptions.isEmpty), [false, true, false])
    }

    /// A version directory the pin moved past is still this app's to reclaim.
    ///
    /// `removeOtherVersions()` only ever runs *inside* a successful install of
    /// the new pin, so a user who bumps to a version their machine cannot build —
    /// offline, module proxy blocked, toolchain too old — or who simply declines
    /// afterwards would otherwise keep tens of megabytes with no button that
    /// admits they are there. `LSPServerRow.hasFilesOnDisk`'s rule, which this
    /// row states in the same words.
    func testAVersionThePinMovedPastIsStillRemovable() async {
        let harness = makeHarness(discovery: .found())
        let stranded = "LanguageServers/gopls/0.20.0/bin/gopls"
        try? harness.tree.write("#!gopls", to: harness.root.appendingPathComponent(stranded))
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
        XCTAssertFalse(harness.tree.hasDirectory("LanguageServers/gopls"))
        XCTAssertFalse(harness.model.row.canRemove)
        XCTAssertNil(harness.model.row.failureMessage)
    }

    /// …and never to a binary the app did not put there. A machine with only the
    /// user's own gopls has nothing under the install root, so Remove is refused
    /// by the model itself and not merely hidden by the view.
    func testRemoveNeverTouchesAGoplsTheAppDidNotInstall() async {
        let harness = makeHarness(discovery: .found(gopls: Fixture.userGoplsPath))
        await harness.model.discover()

        XCTAssertFalse(harness.model.row.hasFilesOnDisk)
        XCTAssertFalse(harness.model.row.canRemove)

        await harness.model.remove()

        XCTAssertEqual(harness.model.installation, .discovered(path: Fixture.userGoplsPath))
        XCTAssertEqual(harness.model.row.consent, .unasked, "a refused removal recorded an answer")
        XCTAssertEqual(harness.tree.removedPaths, [])
        XCTAssertEqual(harness.pushes.count, 1)
    }

    func testAFailedRemovalIsReportedAsARemoval() async {
        let harness = makeHarness(discovery: .found())
        await harness.model.discover()
        await harness.model.accept()

        harness.tree.removeFailures.insert("LanguageServers/gopls")
        await harness.model.remove()

        XCTAssertNotNil(harness.model.row.failureMessage)
        XCTAssertTrue(harness.model.row.failureWasRemoval)
        // The files are still there, so the push that re-registers them is right
        // — a Remove that visibly undoes itself with nothing saying why is the
        // one genuinely confusing outcome this surface can produce.
        XCTAssertEqual(harness.model.row.status, .appInstalled(version: "0.23.0"))
        XCTAssertEqual(harness.model.descriptions.count, 1)
        XCTAssertEqual(harness.model.row.consent, .accepted, "a failed removal recorded a decline")
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
        // and this is the only place that guard can be seen. Without it a build
        // would stage and rename a version directory into the component
        // directory `engine.remove` is concurrently deleting, and would flip
        // consent to `accepted` inside a removal that then records `declined` —
        // leaving the final answer up to the interleaving.
        await harness.model.install()
        XCTAssertEqual(harness.installer.calls.count, 1, "a build started during a removal")
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
        /// `remove()` that deletes before it publishes — is precisely the one
        /// that would never arrive here: an unbounded spin turns a named failure
        /// into a CI job that hangs until the runner kills it and says nothing
        /// about why.
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
