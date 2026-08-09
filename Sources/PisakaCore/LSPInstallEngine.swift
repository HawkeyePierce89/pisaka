import Foundation

/// Fetching the bytes of one artifact (D14).
///
/// **The seam carries bytes, not files.** Core never opens a socket and never
/// writes an archive to disk: it asks for a `URL` and is handed the response
/// body, which it hashes and passes straight to the unpacker. That is what keeps
/// the whole install sequence — the part with all the decisions in it —
/// exercisable by `swift test` with no network, no `tar` and no temporary
/// directory, and it is why `LSPInstallEngineTests` can stage a corrupted
/// download as a one-line stub rather than as a fixture file.
///
/// The stated cost is resident memory: a Node tarball is ~53 MB and is held whole
/// while it is verified and unpacked. A streaming seam would trade that for a
/// file the engine would have to create, verify, unpack *and* clean up on every
/// failure path — four more things to get wrong for a peak that a machine running
/// an IDE already has.
///
/// The peak is bounded by what the *server* sends, not by the manifest: nothing
/// caps a response, so an endpoint that streamed indefinitely would grow the
/// app's memory until the session's resource timeout cut it off. That is
/// deliberate rather than overlooked — capping it needs the byte count at the
/// seam and a chunked read, and it would buy nothing against the threat that
/// matters, since a body of the wrong size still fails the digest and installs
/// nothing. Both are recorded as known limits in
/// `docs/architecture/core-provisioning.md`.
public protocol LSPArtifactDownloading: Sendable {
    /// The bytes at `url`, or a thrown error for anything that went wrong —
    /// transport, TLS, a non-200 status. The engine does not distinguish them:
    /// every one of them is `LSPInstallError.downloadFailed`.
    func data(from url: URL) async throws -> Data
}

/// Expanding one verified archive into a directory (D14).
///
/// `stripComponents` is the archive's own wrapper directory
/// (`node-v24.19.0-darwin-arm64/`, npm's `package/`), removed as the entries are
/// written rather than by unpacking and then moving — which is what lets an
/// artifact land at its final relative position in one step.
public protocol LSPArchiveUnpacking: Sendable {
    func unpack(
        _ archive: Data,
        format: LSPArchiveFormat,
        into destination: URL,
        stripComponents: Int
    ) async throws
}

/// Why an install did not happen.
///
/// Typed in `GitError`'s mould — a small closed set with human-readable
/// `errorDescription`s, so the one surface that shows a failure (the Settings
/// row's Retry) can say something true without the engine knowing anything about
/// a view. Every one of these is *silent* everywhere else: a language whose
/// server failed to install answers from tree-sitter exactly as one that was
/// never offered, and nothing alerts.
public enum LSPInstallError: Error, Equatable, LocalizedError {
    /// The bytes that arrived are not the bytes the manifest pinned. Terminal for
    /// the attempt: there is no retry loop here, because a mirror or an
    /// intercepting proxy serving something else will serve it again, and the one
    /// thing this layer must never do is install code it could not verify.
    case checksumMismatch(component: String, url: URL)
    case downloadFailed(component: String, reason: String)
    case unpackFailed(component: String, reason: String)
    /// The component ships nothing for the slice this app is running as.
    case unsupportedArchitecture(component: String, architecture: LSPHostArchitecture)
    /// A directory could not be created or renamed while installing.
    case fileSystemFailed(component: String, reason: String)
    /// An installed component's directory could not be deleted. Distinct from
    /// `fileSystemFailed` only so the sentence the Settings row shows describes
    /// what the user actually asked for — a removal that reports "could not
    /// install" reads as a different failure than the one that happened.
    case removeFailed(component: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .checksumMismatch(component, _):
            return "The download for “\(component)” did not match its checksum and was discarded."
        case let .downloadFailed(component, reason):
            return "Could not download “\(component)”. \(reason)"
        case let .unpackFailed(component, reason):
            return "Could not unpack “\(component)”. \(reason)"
        case let .unsupportedArchitecture(component, architecture):
            return "“\(component)” is not available for this Mac (\(architecture.rawValue))."
        case let .fileSystemFailed(component, reason):
            return "Could not install “\(component)”. \(reason)"
        case let .removeFailed(component, reason):
            return "Could not remove “\(component)”. \(reason)"
        }
    }
}

/// What the file system says about one component (D12).
public enum LSPInstallState: Equatable, Sendable {
    case absent
    /// An attempt is in flight *right now* — the engine's in-flight table, not
    /// anything on disk. Nothing persists this: a crash mid-install leaves
    /// `absent` plus a staging tree the next launch sweeps.
    case installing
    /// A version directory exists. The version is what is *on disk*, which is
    /// normally the manifest's pin and is the previous one for the moment between
    /// a new app version's first launch and the user accepting the update — see
    /// `isInstalled(_:)` for the difference that matters.
    case installed(version: String)
}

/// Download, verify, unpack and install the components the manifest describes.
///
/// The whole of D12–D14 lives here, and the shape is deliberately small:
///
/// * **State is the file system** (D12). There is no database, no receipt file
///   and no cache to get out of step with the disk — `state(of:)` is a directory
///   listing plus the in-flight table, so a user who deletes
///   `~/Library/Application Support/Pisaka/LanguageServers` has de-provisioned,
///   completely, with nothing left believing otherwise.
/// * **Atomicity is one rename** (D13). Everything an attempt produces is built
///   inside its own staging directory; the version directory comes into existence
///   in a single `move`, and the previous version is deleted only after that move
///   has succeeded. Every failure path therefore leaves either the previous
///   install exactly as it was or nothing at all — never a half-written tree that
///   `state(of:)` would report as installed.
/// * **The bytes come through seams** (D14), so this file — the one with the
///   ordering rules in it — is Foundation-only and fully unit-tested.
///
/// **`@MainActor`, like every other model here.** The in-flight table is read
/// synchronously by the Settings surface and the consent banner in the same turn
/// they are drawn, and coalescing two installs of one component is only sound if
/// the claim is made without a hop between the check and the store. The
/// expensive parts — the download, the digest, the unpack — all happen inside
/// `await`s on `nonisolated` seams, so nothing here holds the main actor while
/// 53 MB moves.
///
/// **A reader of the project, a writer only of its own directory.** Nothing here
/// touches the user's files, so this takes no `autosave.suspend()` /
/// `localChanges.beginRevert()` gate and is not gated by one — the rule the
/// symbol index and the rest of the LSP layer already follow. Every path it
/// deletes is asserted to be inside `layout.base` first.
@MainActor
public final class LSPInstallEngine {
    /// The pinned data this engine may act on. Public because the provisioning
    /// model turns installed components into registry entries, and both must be
    /// reading the same manifest for the paths to agree.
    public let manifest: LSPProvisioningManifest
    public let layout: LSPInstallLayout
    /// The slice this app is running as — see `LSPHostArchitecture`.
    public let architecture: LSPHostArchitecture

    private let fileService: FileServicing
    private let downloader: LSPArtifactDownloading
    private let unpacker: LSPArchiveUnpacking

    /// An attempt in flight, with an id so the task that finishes clears its own
    /// slot and never a newer one's — `LSPWorkspace`'s flush discipline, for the
    /// same reason.
    private struct PendingInstall {
        let id: Int
        let task: Task<Result<Void, Error>, Never>
    }

    private var installs: [String: PendingInstall] = [:]
    private var installCounter = 0
    /// Distinguishes one attempt's staging tree from the next's, so a retry can
    /// never adopt the half-written directory a previous attempt left behind (see
    /// `LSPInstallLayout.stagingDirectory`).
    private var stagingCounter = 0

    public init(
        manifest: LSPProvisioningManifest = .standard,
        layout: LSPInstallLayout,
        fileService: FileServicing,
        downloader: LSPArtifactDownloading,
        unpacker: LSPArchiveUnpacking,
        architecture: LSPHostArchitecture
    ) {
        self.manifest = manifest
        self.layout = layout
        self.fileService = fileService
        self.downloader = downloader
        self.unpacker = unpacker
        self.architecture = architecture
    }

    // MARK: - State

    /// What the disk (plus the in-flight table) says about `componentID`.
    ///
    /// A component the manifest does not describe is `absent`: this answers what
    /// is installed, not what could be.
    public func state(of componentID: String) -> LSPInstallState {
        if installs[componentID] != nil { return .installing }
        let versions = installedVersions(of: componentID)
        guard let stranded = versions.last else { return .absent }
        // The pinned version wins when it is there, so the common answer is the
        // one the registry entries are built from. Any *other* version is still
        // reported as installed — it is a real tree taking up real disk, left by
        // an app version whose pin has since moved — but it is not servable, and
        // `isInstalled(_:)` is the question that tells the two apart.
        if let pinned = manifest.component(componentID)?.version, versions.contains(pinned) {
            return .installed(version: pinned)
        }
        // `last` of a *lexicographic* sort, deliberately not "the newest": the
        // versions here are dotted strings, so `1.1.9` sorts after `1.1.10`, and
        // nothing in this layer knows a version scheme to compare them properly.
        // It costs nothing to be wrong, because this branch only ever names a
        // tree for the Settings row to offer removing — a successful install
        // leaves exactly one version behind (`removeOtherVersions`), so more than
        // one is already the rare case, and no path serves what it reports.
        return .installed(version: stranded)
    }

    public func state(of component: LSPComponent) -> LSPInstallState {
        state(of: component.id)
    }

    /// Whether the **pinned** version is on disk — the only thing that makes a
    /// server servable, since every path `LSPDownloadableServer.serverDescription`
    /// composes names that version.
    public func isInstalled(_ componentID: String) -> Bool {
        guard let component = manifest.component(componentID) else { return false }
        return installedVersions(of: componentID).contains(component.version)
    }

    /// Whether everything `server` needs — its own component *and* its runtime —
    /// is installed at the pinned version.
    public func isInstalled(_ server: LSPDownloadableServer) -> Bool {
        let order = manifest.installationOrder(for: server.serverComponentID)
        guard !order.isEmpty else { return false }
        return order.allSatisfy { isInstalled($0.id) }
    }

    /// The bytes still to fetch to make `componentID` usable — what the consent
    /// prompt and the Settings row show (D15 — "sized"). Already-installed
    /// requirements cost nothing, which is the whole point of `node` being one
    /// shared component: accepting Python after TypeScript is 4 MB, not 56.
    public func pendingDownloadByteCount(for componentID: String) -> Int {
        manifest.installationOrder(for: componentID)
            .filter { !isInstalled($0.id) }
            .reduce(0) { $0 + $1.downloadByteCount(for: architecture) }
    }

    public func pendingDownloadByteCount(for server: LSPDownloadableServer) -> Int {
        pendingDownloadByteCount(for: server.serverComponentID)
    }

    /// Every version directory that exists for `componentID`, sorted, so `last`
    /// is a deterministic choice rather than whatever order the volume enumerated.
    ///
    /// A listing that throws — the component has never been installed, so its
    /// directory does not exist — is "nothing installed", which is exactly what a
    /// missing directory means.
    private func installedVersions(of componentID: String) -> [String] {
        guard let entries = try? fileService.contentsOfDirectory(
            at: layout.componentDirectory(componentID)
        ) else { return [] }
        return entries.filter(\.isDirectory).map(\.name).sorted()
    }

    // MARK: - Installing

    /// Install `server` and everything it needs.
    public func install(_ server: LSPDownloadableServer) async throws {
        try await install(server.serverComponentID)
    }

    /// Install `componentID`, its requirements first.
    ///
    /// The ordering is the manifest's (`installationOrder(for:)`) rather than this
    /// engine's, because it is a property of the data. A requirement that fails
    /// aborts the whole thing by throwing before the component that needs it is
    /// attempted — half a server is worse than none, since the registry entry it
    /// would produce names a `node` that is not there and every request through it
    /// would spend D7's restart budget discovering that.
    ///
    /// A component the manifest does not describe installs nothing and succeeds:
    /// this layer's uniform answer to malformed data is *absence*, and the caller
    /// reads that from `state(of:)` a moment later exactly as it reads a failure.
    public func install(_ componentID: String) async throws {
        for component in manifest.installationOrder(for: componentID) {
            try await install(component)
        }
    }

    /// One component, coalesced.
    ///
    /// Two accepts landing at once (the consent banner and the Settings row, or
    /// TypeScript and Python both wanting `node`) must produce one download, and
    /// both callers must see the same outcome. The claim is made *synchronously*
    /// between the check and the store — there is no suspension point between them
    /// — which is what makes "one download" true rather than likely.
    private func install(_ component: LSPComponent) async throws {
        if isInstalled(component.id) { return }
        if let pending = installs[component.id] { return try await pending.task.value.get() }

        installCounter += 1
        let id = installCounter
        let task = Task { @MainActor [self] () -> Result<Void, Error> in
            let outcome: Result<Void, Error>
            do {
                try await perform(component)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // Released from inside the task body, while it is still running, and
            // only if it is still ours — `LSPWorkspace.flush`'s rule: a waiter that
            // wakes to find a *finished* task still occupying the slot would await
            // it without suspending, and a newer claim must not be erased by an
            // older attempt finishing late.
            if installs[component.id]?.id == id { installs[component.id] = nil }
            return outcome
        }
        installs[component.id] = PendingInstall(id: id, task: task)
        return try await task.value.get()
    }

    /// D13, in order: stage, download, **verify**, unpack, one `move`, then — and
    /// only then — delete what it replaced.
    ///
    /// Every failure between the first line and the `move` is caught here, drops
    /// the staging tree and rethrows: nothing outside `.staging` has been touched
    /// yet, so "the previous install is exactly as it was" needs no rollback to be
    /// true. That is the whole reason the sequence is shaped this way.
    private func perform(_ component: LSPComponent) async throws {
        let artifacts = component.artifacts(for: architecture)
        guard !artifacts.isEmpty else {
            throw LSPInstallError.unsupportedArchitecture(
                component: component.id,
                architecture: architecture
            )
        }

        stagingCounter += 1
        let staging = layout.stagingDirectory(for: component, token: stagingCounter)

        do {
            try ensureDirectory(staging, of: component)

            for artifact in artifacts {
                let archive: Data
                do {
                    archive = try await downloader.data(from: artifact.url)
                } catch {
                    throw LSPInstallError.downloadFailed(
                        component: component.id,
                        reason: error.localizedDescription
                    )
                }

                // Before the unpack, always: the alternative is writing code of
                // unknown provenance into a directory and deleting it afterwards,
                // which is a very different promise.
                guard await LSPInstallEngine.digest(of: archive) == artifact.sha256 else {
                    throw LSPInstallError.checksumMismatch(
                        component: component.id,
                        url: artifact.url
                    )
                }

                let destination = layout.destination(of: artifact, unpackingInto: staging)
                try ensureDirectory(destination, of: component)
                do {
                    try await unpacker.unpack(
                        archive,
                        format: artifact.format,
                        into: destination,
                        stripComponents: artifact.stripComponents
                    )
                } catch {
                    throw LSPInstallError.unpackFailed(
                        component: component.id,
                        reason: error.localizedDescription
                    )
                }
            }

            try commit(staging, of: component)
        } catch {
            discard(staging)
            throw error
        }
    }

    /// The single rename that makes the version directory exist, and the cleanup
    /// that may only happen after it.
    ///
    /// The old version is removed *afterwards*, best-effort: by this point the new
    /// one is installed and servable, and failing the install because a stale
    /// directory could not be deleted would turn a successful upgrade into a
    /// reported failure over some wasted disk. What is left behind is visible to
    /// `installedVersions(of:)` and removed by the next successful upgrade or by
    /// `remove(_:)`.
    private func commit(_ staging: URL, of component: LSPComponent) throws {
        let version = layout.versionDirectory(for: component)
        do {
            // The component directory is the `move`'s destination *parent* and may
            // not exist yet (a first install); the rename needs it there.
            try fileService.ensureDirectory(at: layout.componentDirectory(component.id))
            try fileService.move(from: staging, to: version)
        } catch {
            throw LSPInstallError.fileSystemFailed(
                component: component.id,
                reason: error.localizedDescription
            )
        }
        removeOtherVersions(of: component)
    }

    /// The artifact's digest, computed off the main actor.
    ///
    /// `nonisolated static` and `async` on purpose: this engine is `@MainActor`,
    /// and a plain call to `SHA256.hexadecimalDigest(of:)` from `perform(_:)` would
    /// hash all 53 MB of the Node tarball *on the main thread* — a fifth of a
    /// second of frozen editor on Apple silicon, more on an Intel Mac, once per
    /// artifact. A `nonisolated async` function does not inherit its caller's
    /// executor, so the loop lands on the cooperative pool and only the comparison
    /// comes back — which is what makes this class's "nothing here holds the main
    /// actor while 53 MB moves" true of the digest as well as the download and the
    /// unpack.
    private nonisolated static func digest(of archive: Data) async -> String {
        SHA256.hexadecimalDigest(of: archive)
    }

    private func removeOtherVersions(of component: LSPComponent) {
        for version in installedVersions(of: component.id) where version != component.version {
            let directory = layout.versionDirectory(componentID: component.id, version: version)
            guard mayDelete(directory) else { continue }
            try? fileService.removeItem(at: directory)
        }
    }

    /// Whether this engine may delete `url`.
    ///
    /// `layout.contains(_:)` answers "inside the install root", and deliberately
    /// counts the root itself — it is a containment predicate, and the sweep reads
    /// that directory. Nothing here may ever *delete* it: every path below is
    /// built from a component id or read out of a listing, and one that resolves
    /// back to the root (a hand-edited manifest with `..` in an id, a `.staging`
    /// entry that walks out through a symlink) would take every provisioned server
    /// with it in a single `removeItem`. So the delete sites ask this instead.
    private func mayDelete(_ url: URL) -> Bool {
        layout.contains(url) && url.standardizedFileURL.path != layout.base.standardizedFileURL.path
    }

    private func ensureDirectory(_ url: URL, of component: LSPComponent) throws {
        do {
            try fileService.ensureDirectory(at: url)
        } catch {
            throw LSPInstallError.fileSystemFailed(
                component: component.id,
                reason: error.localizedDescription
            )
        }
    }

    /// Drop an attempt's staging tree. Best-effort by design: this runs on a path
    /// that is *already* failing, and the sweep at the next launch is what makes
    /// leftovers a disk-space question rather than a correctness one.
    private func discard(_ staging: URL) {
        guard mayDelete(staging) else { return }
        try? fileService.removeItem(at: staging)
    }

    // MARK: - Removing

    /// Delete every version of `componentID`.
    ///
    /// Removing a component that is not installed succeeds, doing nothing: the
    /// postcondition is "this is not on disk", which already holds.
    ///
    /// Deliberately does **not** stop a running server — the workspace owns that,
    /// and the provisioning model calls this after pushing a registry without the
    /// server in it, which is what terminates the process (D16). Deleting the
    /// executable out from under a live process would leave exactly the orphan the
    /// release check greps for.
    public func remove(_ componentID: String) throws {
        let directory = layout.componentDirectory(componentID)
        guard mayDelete(directory), !installedVersions(of: componentID).isEmpty else { return }
        do {
            try fileService.removeItem(at: directory)
        } catch {
            throw LSPInstallError.removeFailed(
                component: componentID,
                reason: error.localizedDescription
            )
        }
    }

    /// Delete everything under `.staging` (D13).
    ///
    /// Called once at launch, before anything is installed, so there is by
    /// definition no attempt in flight for it to destroy: what it finds is what a
    /// crash, a force-quit or a power loss left behind, and every one of those
    /// trees is unreachable garbage — the version directories are the only thing
    /// anything reads. Never throws: a missing staging root is the normal case,
    /// and a launch must not fail over a directory nobody will look in.
    public func sweepStaging() {
        guard let entries = try? fileService.contentsOfDirectory(at: layout.stagingRoot) else {
            return
        }
        for entry in entries where mayDelete(entry.url) {
            try? fileService.removeItem(at: entry.url)
        }
    }
}
