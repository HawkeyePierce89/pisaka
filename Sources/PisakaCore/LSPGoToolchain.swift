import Foundation

/// The gopls pin, and the one shape its installed tree may have (D17/D20).
///
/// Deliberately **not** an `LSPComponent` and deliberately not in
/// `LSPProvisioningManifest`: there are no official prebuilt gopls binaries, so
/// there is no URL to pin, no SHA-256 to verify and nothing to unpack. What is
/// pinned instead is a module path and a version — the two arguments of one
/// `go install` — and integrity is Go's own checksum database, which is that
/// ecosystem's equivalent of 2b's pinned digests and which this app therefore
/// does not reimplement.
///
/// `executableSubpath` is a constant rather than something the install reports
/// back, and that is load-bearing. The registry entry's path has to be derivable
/// from a directory listing after a relaunch — the disk is the state (D12) — so
/// "where the binary is inside the version directory" cannot be a fact only the
/// installing run remembered. `go install` puts the built program at
/// `$GOBIN/<program name>`, and the program name for this module is `gopls`, so
/// the shape is known before the build runs and the build's answer is *checked*
/// against it rather than trusted.
public enum LSPGopls {
    /// The component id, shared with `LSPInstallLayout`'s path math and
    /// `LSPInstallEngine.remove(_:)` — both string-keyed, neither needing an
    /// `LSPComponent` to describe this one.
    public static let componentID = "gopls"

    /// What the Settings row and the consent prompt call it. gopls has no
    /// friendlier name, and inventing one ("Go Language Server") would make it
    /// harder, not easier, to search for what was installed.
    public static let displayName = "gopls"

    public static let modulePath = "golang.org/x/tools/gopls"

    /// The version directory's name, unprefixed, like every other component's.
    public static let version = "0.23.0"

    /// The same version as `go install` spells it — Go module versions carry the
    /// `v`, install roots do not.
    public static var moduleVersion: String { "v\(version)" }

    public static let executableName = "gopls"

    /// Where the binary sits inside its version directory, and inside the
    /// staging tree before the rename.
    public static let executableSubpath = "bin/gopls"

    /// The directory `GOBIN` is pointed at, relative to whichever root the
    /// install is building into.
    public static let binSubpath = "bin"

    /// gopls's licence, named in the Settings row.
    ///
    /// It ships no licence file into `GOBIN` — `go install` writes one binary and
    /// nothing else — so there is nothing for `LSPInstalledLicenses` to read out
    /// of the installed tree and nothing for `licenses.json` to cover, this app
    /// bundling no gopls bytes at all. A sentence naming the origin and the
    /// licence is the honest substitute, and it is written down here rather than
    /// left as an omission in a view.
    public static let licenseSPDX = "BSD-3-Clause"

    /// Where the source lives, for the same sentence.
    public static let origin = "https://github.com/golang/tools"
}

/// What the app found on *this* Mac (D18).
///
/// The app does the searching — `$GOBIN`, `$GOPATH/bin`, `~/go/bin`, the login
/// `PATH`, `/usr/local/go/bin`, Homebrew — because every one of those is
/// machine-specific knowledge of exactly the kind D9 keeps out of Core. What
/// crosses the seam is this value, and Core's rules are written over it alone.
///
/// A gopls path without a `go` path is unrepresentable on purpose: gopls found
/// with no toolchain to have built it would still start, but nothing in this
/// design can offer, update or explain it, and "no Go toolchain" is the one
/// sentence the Settings row can say truthfully in that case.
public enum LSPGoToolchainReport: Equatable, Sendable {
    /// No `go` on this machine. Nothing is ever prompted, installed or
    /// registered — the language answers from the tree-sitter index, exactly as
    /// it does for a user who declined.
    case missing
    /// `go` at a path, and a gopls the *user* installed at another, if there is
    /// one. `goplsPath` says nothing about the app's own copy, which is read off
    /// the install root instead.
    case found(goPath: String, goplsPath: String?)

    public var goPath: String? {
        if case let .found(goPath, _) = self { return goPath }
        return nil
    }

    public var discoveredGoplsPath: String? {
        if case let .found(_, goplsPath) = self { return goplsPath }
        return nil
    }

    public var hasToolchain: Bool { goPath != nil }
}

/// Which gopls is being used, and therefore what may be done to it (D19).
///
/// The two cases are not two spellings of "installed": one is a binary somebody
/// else put in `~/go/bin` and the other is a directory this app owns, and Remove
/// may only ever touch the second. Keeping them apart in the type is what makes
/// that a rule rather than a check a view has to remember.
public enum LSPGoplsInstallation: Equatable, Sendable {
    /// Found on this Mac, at a path the app neither chose nor may delete.
    case discovered(path: String)
    /// Built by this app's `go install` and living under its own install root.
    case appInstalled(version: String, path: String)

    public var executablePath: String {
        switch self {
        case let .discovered(path): return path
        case let .appInstalled(_, path): return path
        }
    }

    public var isAppInstalled: Bool {
        if case .appInstalled = self { return true }
        return false
    }
}

/// What the consent banner needs in order to ask about gopls, and nothing else —
/// `LSPConsentPrompt`'s shape, with the fields that differ because the answer
/// buys something different.
///
/// There is no byte count, because nothing is downloaded by this app: accepting
/// runs the user's own `go`, which fetches the module through Go's own tooling
/// and builds it. The `go` path is carried so the banner can say *whose*
/// toolchain is about to do the work, which is the whole of the difference
/// between this prompt and 2b's.
public struct LSPGoConsentPrompt: Equatable, Sendable {
    public let displayName: String
    public let version: String
    public let goExecutablePath: String

    public init(displayName: String, version: String, goExecutablePath: String) {
        self.displayName = displayName
        self.version = version
        self.goExecutablePath = goExecutablePath
    }
}

/// gopls as the Settings tab sees it — D19's five states plus the one the
/// lifecycle actually starts in, with every button's availability a property
/// here rather than a condition in a view.
public struct LSPGoServerRow: Equatable, Sendable {
    /// The row's whole answer to "what is going on".
    public enum Status: Equatable, Sendable {
        /// Discovery has not answered yet. `LSPToolchain.Resolution.pending`'s
        /// case, for its reason: the search shells out to `go`, so it cannot be
        /// run inside the turn that draws the row, and a row that guessed
        /// "no Go toolchain" for that first moment would tell the user something
        /// false and then quietly correct itself.
        case pending
        /// No `go` on this machine — the state where nothing is offered at all.
        case noToolchain
        case notInstalled
        case installing
        /// A gopls the user installed. Usable, never removable from here.
        case discovered
        /// This app's own copy, at the version it pinned.
        case appInstalled(version: String)
    }

    public let status: Status
    public let consent: LSPServerConsent
    /// The last attempt's failure, or `nil`. The *whole* failure surface, D15's
    /// rule verbatim: a build that did not work is a sentence in this row and a
    /// button that says Retry, and nothing anywhere else — no alert, no beep,
    /// and no change to what the editor does, since Go was answering from
    /// tree-sitter before the attempt and still is.
    public let failureMessage: String?
    /// Whether `failureMessage` describes a failed *removal* rather than a
    /// failed install — `LSPServerRow`'s field, for its reason: it is what the
    /// button beside the sentence is labelled off.
    public let failureWasRemoval: Bool
    /// The version this app would install, for the row's own copy in every state
    /// — including the ones where nothing is installed yet.
    public let version: String
    public let isRemoving: Bool

    /// Install (or Retry) needs a toolchain to build with, nothing installed to
    /// be made redundant, and nothing in flight.
    ///
    /// A *discovered* gopls is deliberately not installable over: it already
    /// answers, so the only thing an install would buy is a second copy of the
    /// same program plus a Remove button, and D19's preference rule would then
    /// silently switch which binary is running.
    public var canInstall: Bool { status == .notInstalled && !isRemoving }

    /// Remove applies to this app's own copy and to nothing else — never to a
    /// binary in `~/go/bin` that the app did not put there.
    public var canRemove: Bool {
        guard case .appInstalled = status else { return false }
        return !isRemoving
    }

    public init(
        status: Status,
        consent: LSPServerConsent,
        failureMessage: String? = nil,
        failureWasRemoval: Bool = false,
        version: String = LSPGopls.version,
        isRemoving: Bool = false
    ) {
        self.status = status
        self.consent = consent
        self.failureMessage = failureMessage
        self.failureWasRemoval = failureWasRemoval
        self.version = version
        self.isRemoving = isRemoving
    }
}
