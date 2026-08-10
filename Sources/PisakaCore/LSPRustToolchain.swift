import Foundation

/// rust-analyzer's identity, and the one thing it deliberately does not carry:
/// its version (D21/D24).
///
/// Unlike `LSPGopls`, this server **is** a pinned `LSPComponent` — a URL, a
/// SHA-256 and a byte count in `LSPProvisioningManifest` — so everything
/// version-shaped already has one home, and restating it here would be a second
/// spelling of a pin the by-hand update procedure moves. What is left is the
/// handful of facts a manifest record has no field for: the id the consent, the
/// install root and `engine.remove(_:)` all key on, the name the surfaces print,
/// and where the source lives for the licence sentence the Settings row shows.
///
/// The version, the licence expression and the executable's position inside the
/// version directory are read *through* `component(in:)` from whichever manifest
/// the engine was built over — which is what lets the tests drive this model with
/// a fixture pin and still prove the model reads the data rather than a constant.
public enum LSPRustAnalyzer {
    /// The component id, shared by the manifest record, `LSPInstallLayout`'s path
    /// math, `LSPInstallEngine.remove(_:)` and the `SettingsStore` consent
    /// dictionary — one identity, one spelling.
    public static let componentID = "rust-analyzer"

    /// What the Settings row and the consent prompt call it. rust-analyzer has no
    /// friendlier name, and inventing one ("Rust Language Server") would make it
    /// harder, not easier, to search for what was installed.
    public static let displayName = "rust-analyzer"

    /// Where the source lives, for the row's one licence sentence.
    ///
    /// A bare `.gz` ships no licence file, so there is nothing inside the
    /// installed tree for `LSPInstalledLicenses` to print and nothing for
    /// `licenses.json` to cover — this app bundles none of its bytes (D24). A
    /// sentence naming the origin and the `Apache-2.0 OR MIT` expression the
    /// manifest records is the honest substitute, and it is written down here
    /// rather than left as an omission in a view.
    public static let origin = "https://github.com/rust-lang/rust-analyzer"

    /// The pinned record in `manifest`, or `nil` for a manifest that does not
    /// describe it.
    ///
    /// `nil` is a real answer rather than a precondition: this layer's uniform
    /// response to data it cannot act on is *absence* — nothing is offered,
    /// nothing is installed, and Rust goes on being answered by the tree-sitter
    /// index — which is exactly what a missing component has to mean.
    public static func component(in manifest: LSPProvisioningManifest) -> LSPComponent? {
        manifest.component(componentID)
    }
}

/// What the app found on *this* Mac (D23).
///
/// The app does the searching — the inherited `PATH`, `~/.cargo/bin`, Homebrew's
/// prefixes, the login shell's `$PATH` — because every one of those is
/// machine-specific knowledge of exactly the kind D9 keeps out of Core, and
/// running `cargo --version` to confirm the find is something Core may not do at
/// all. What crosses the seam is this value, and Core's rules are written over it
/// alone.
///
/// A rust-analyzer path without a `cargo` path is unrepresentable on purpose, and
/// that is D23 rather than tidiness: rust-analyzer shells out to `cargo` to build
/// the project model, so without a toolchain it starts, answers almost nothing,
/// and burns D7's restart budget per request while every surface in the app
/// claims it is installed — the failure the gopls `searchPath` lesson recorded,
/// and one `RoutingIntelligenceProvider` cannot see, since an empty answer and a
/// file that declares nothing are the same value at that seam.
public enum LSPRustToolchainReport: Equatable, Sendable {
    /// No usable `cargo` on this machine. Nothing is ever prompted, installed or
    /// registered — Rust answers from the tree-sitter index, exactly as it does
    /// for a user who declined.
    case missing

    /// A `cargo` at a path, the `PATH` it and the server must run under, and a
    /// rust-analyzer the *user* already has at another path, if there is one.
    /// `rustAnalyzerPath` says nothing about the app's own copy, which is read
    /// off the install root instead.
    ///
    /// `searchPath` is the second half of "a toolchain was found", for
    /// `LSPGoToolchainReport.found`'s reason applied to a second server: a
    /// Finder-launched app inherits `launchd`'s `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains neither `~/.cargo/bin`
    /// nor Homebrew's prefixes nor any version-manager shim directory, so a
    /// rust-analyzer started under it would resolve no `cargo` at all. That is
    /// the *normal* launch and not an edge case, so the app reports the `PATH`
    /// that found the `cargo` alongside it and Core hands it to the server as the
    /// launch environment without ever learning what is in it (D9).
    case found(cargoPath: String, searchPath: String, rustAnalyzerPath: String?)

    public var cargoPath: String? {
        if case let .found(cargoPath, _, _) = self { return cargoPath }
        return nil
    }

    /// The `PATH` both the toolchain and the server it drives must run under.
    public var searchPath: String? {
        if case let .found(_, searchPath, _) = self { return searchPath }
        return nil
    }

    public var discoveredRustAnalyzerPath: String? {
        if case let .found(_, _, rustAnalyzerPath) = self { return rustAnalyzerPath }
        return nil
    }

    public var hasToolchain: Bool { cargoPath != nil }
}

/// Which rust-analyzer is being used, and therefore what may be done to it (D24).
///
/// The two cases are not two spellings of "installed": one is a binary rustup put
/// in `~/.cargo/bin` and the other is a directory this app owns and verified
/// against a pinned digest, and Remove may only ever touch the second. Keeping
/// them apart in the type is what makes that a rule rather than a check a view
/// has to remember.
public enum LSPRustAnalyzerInstallation: Equatable, Sendable {
    /// Found on this Mac, at a path the app neither chose nor may delete.
    case discovered(path: String)
    /// Downloaded, verified and installed by this app, under its own install
    /// root, at the version it pinned.
    case appInstalled(version: String, path: String)

    public var executablePath: String {
        switch self {
        case let .discovered(path): return path
        case let .appInstalled(_, path): return path
        }
    }

}

/// What the consent banner needs in order to ask about rust-analyzer, and nothing
/// else.
///
/// `LSPGoConsentPrompt`'s shape with the field that makes Rust the hybrid it is:
/// **a byte count**. Accepting gopls runs the user's own toolchain and downloads
/// nothing this app can size, so its prompt has none; accepting this fetches a
/// pinned artifact whose size the manifest knows exactly, and D15's rule is that
/// nobody is asked to download something unsized.
///
/// The count is `pendingDownloadByteCount`, which is what is still missing rather
/// than the component's gross total — the same number the Settings row shows, and
/// zero for a component already on disk.
public struct LSPRustConsentPrompt: Equatable, Sendable {
    public let displayName: String
    public let version: String
    public let downloadByteCount: Int

    public init(displayName: String, version: String, downloadByteCount: Int) {
        self.displayName = displayName
        self.version = version
        self.downloadByteCount = downloadByteCount
    }
}

/// rust-analyzer as the Settings tab sees it — D24's seven states, with every
/// button's availability a property here rather than a condition in a view.
///
/// **Why this row and not `LSPServerRow`.** Rust reuses 2b's *engine* but not its
/// row (D21), because its honest state set is the Go row's: it has a toolchain
/// gate and a discovered-copy state that no 2b server has, and a 2b row offering
/// Install beside the sentence "no Rust toolchain" would be a lie. What it takes
/// from 2b instead is the one field the Go row has no use for — the download
/// size.
public struct LSPRustServerRow: Equatable, Sendable {
    /// The row's whole answer to "what is going on". Six cases here plus
    /// `failureMessage` are D24's seven states.
    public enum Status: Equatable, Sendable {
        /// Discovery has not answered yet. `LSPToolchain.Resolution.pending`'s
        /// case, for its reason: the search may shell out to a login shell, so it
        /// cannot run inside the turn that draws the row, and a row that guessed
        /// "no Rust toolchain" for that first moment would tell the user
        /// something false and then quietly correct itself.
        case pending
        /// No usable `cargo` on this machine — the state where nothing is offered
        /// at all, for a discovered rust-analyzer just as much as for a
        /// downloadable one (D23).
        case noToolchain
        /// A toolchain, nothing installed, and a size to show for what Install
        /// would fetch.
        case notInstalled
        case installing
        /// A rust-analyzer the user already has. Used, never removable from here.
        case discovered
        /// This app's own copy, at the version it pinned.
        case appInstalled(version: String)
    }

    public let status: Status
    public let consent: LSPServerConsent
    /// The last attempt's failure, or `nil`. The *whole* failure surface, D15's
    /// rule verbatim: a download that did not work is a sentence in this row and
    /// a button that says Retry, and nothing anywhere else — no alert, no beep,
    /// and no change to what the editor does, since Rust was answering from
    /// tree-sitter before the attempt and still is.
    public let failureMessage: String?
    /// Whether `failureMessage` describes a failed *removal* rather than a failed
    /// install — it is what the button beside the sentence is labelled off.
    public let failureWasRemoval: Bool
    /// The version this app would install, for the row's own copy in every state
    /// — including the ones where nothing is installed yet. Empty when the
    /// manifest describes no such component, which is the same "nothing to
    /// offer" every other surface reports for that case.
    public let version: String
    /// The SPDX expression the manifest records, for the row's licence sentence.
    /// The substitute for an Acknowledgements entry that cannot exist: the
    /// archive is one binary and ships no licence text to print (D24).
    public let licenseSPDX: String
    /// Bytes still to fetch to make it usable — 0 once it is installed.
    public let pendingDownloadByteCount: Int
    /// Whether Remove would reclaim anything: any version directory this app
    /// installed, **including one a pin bump has left stranded** — servable by
    /// nothing, still occupying real disk. `LSPGoServerRow.hasFilesOnDisk`'s
    /// field, for its reason: the only other thing that deletes a stranded
    /// directory is the cleanup inside a *successful* install of the new pin, so
    /// a user who then declines — or whose download fails, offline or behind a
    /// proxy — would keep tens of megabytes with no button in the app that admits
    /// they are there.
    public let hasFilesOnDisk: Bool
    public let isRemoving: Bool

    /// Install (or Retry) needs a toolchain to drive the server, nothing
    /// installed to be made redundant, and nothing in flight.
    ///
    /// A *discovered* rust-analyzer is deliberately not installable over: it
    /// already answers, so the only thing a 13 MB download would buy is a second
    /// copy of the same program plus a Remove button, and D24's preference rule
    /// would then silently switch which binary is running.
    ///
    /// A manifest that describes no such component reads as `.notInstalled` — the
    /// honest status, since nothing is — but there is nothing to install, so the
    /// empty `version` is required here too. Otherwise this is the one surface
    /// that would offer the action while `consentPrompt` and `install()`, which
    /// both guard on the component, silently do nothing: a live button beside a
    /// "Zero KB download" that answers no click.
    public var canInstall: Bool { status == .notInstalled && !version.isEmpty && !isRemoving }

    /// Remove applies to files under this app's own install root and to nothing
    /// else — never to a binary in `~/.cargo/bin` that the app did not put there,
    /// which `hasFilesOnDisk` cannot see and `engine.remove` would not touch
    /// anyway.
    ///
    /// Keyed on the files rather than on `status`, for `hasFilesOnDisk`'s reason:
    /// a version directory the pin moved past reads as `.notInstalled` (or, on a
    /// machine that also has the user's own copy, `.discovered`) while still
    /// being this app's to reclaim. Nothing in flight, for `LSPServerRow`'s two
    /// reasons — removing mid-install would delete a directory the commit is
    /// about to rename onto, and removing mid-removal would delete one the first
    /// removal is still stopping a process on top of.
    public var canRemove: Bool { hasFilesOnDisk && status != .installing && !isRemoving }

    public init(
        status: Status,
        consent: LSPServerConsent,
        failureMessage: String? = nil,
        failureWasRemoval: Bool = false,
        version: String = "",
        licenseSPDX: String = "",
        pendingDownloadByteCount: Int = 0,
        hasFilesOnDisk: Bool = false,
        isRemoving: Bool = false
    ) {
        self.status = status
        self.consent = consent
        self.failureMessage = failureMessage
        self.failureWasRemoval = failureWasRemoval
        self.version = version
        self.licenseSPDX = licenseSPDX
        self.pendingDownloadByteCount = pendingDownloadByteCount
        self.hasFilesOnDisk = hasFilesOnDisk
        self.isRemoving = isRemoving
    }
}
