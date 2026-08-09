import Foundation

/// Where every provisioned file goes (D12/D13), as pure path math.
///
/// **No file system access, on purpose.** Every method here is a `URL`
/// computation over a base directory, so the engine's tests can reason about
/// paths against a `StubFileTree` and the app can point the same math at
/// `~/Library/Application Support/Pisaka/LanguageServers` without a second
/// implementation. Nothing in this file stats, reads, creates or deletes; a
/// method that answers a `URL` is not making a claim that anything is there.
///
/// The shape it describes:
///
/// ```text
/// <base>/
///   .staging/
///     node-24.19.0-7/                      ← download + verify + unpack land here
///   node/
///     24.19.0/bin/node
///   typescript-language-server/
///     5.3.0/node_modules/typescript-language-server/lib/cli.mjs
///     5.3.0/node_modules/typescript/lib/tsserver.js
///   pyright/
///     1.1.411/node_modules/pyright/dist/pyright-langserver.js
/// ```
///
/// Two properties of that shape carry the design. **Version in the path** is what
/// makes an upgrade a fresh directory beside the old one rather than an in-place
/// mutation, so a failed upgrade cannot damage a working install (D13) — and it
/// is why `state(of:)` can be a directory listing rather than a database (D12).
/// **Staging under the same base** is what makes the final `move` a rename within
/// one volume, which is the atomic step the whole install sequence is built
/// around; a staging directory in `/tmp` would be a cross-device copy and would
/// have no atomicity to offer.
///
/// The staging directory name begins with a dot so it sorts and reads as
/// bookkeeping rather than as a component named `staging`, and so a component id
/// can never collide with it (`LSPProvisioningManifestTests` pins that).
public struct LSPInstallLayout: Equatable, Sendable {
    /// The install root — `…/Application Support/Pisaka/LanguageServers` in the
    /// app, a temporary directory in the tests.
    public let base: URL

    /// `base` is standardised (`.`/`..` resolved lexically, no `realpath(3)` — the
    /// layout touches no file system) and re-spelled as a directory URL, so that
    /// two spellings of one root compare equal. Without the second half, a base
    /// that arrived with a trailing slash and one that did not would be two
    /// different `URL`s naming the same directory, and `LSPInstallLayout` is a
    /// value the model compares.
    public init(base: URL) {
        self.base = URL(fileURLWithPath: base.standardizedFileURL.path, isDirectory: true)
    }

    /// The directory name the app appends to its Application Support directory.
    /// Here rather than in the app so the one place that spells it is the one
    /// place the de-provisioning instructions in `README.md` point at.
    public static let directoryName = "LanguageServers"

    public static let stagingDirectoryName = ".staging"

    // MARK: - Installed trees

    public var stagingRoot: URL {
        base.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    /// All versions of one component. Normally holds exactly one child; holds two
    /// for the instant between a successful upgrade's `move` and the old
    /// version's deletion.
    public func componentDirectory(_ componentID: String) -> URL {
        base.appendingPathComponent(componentID, isDirectory: true)
    }

    /// The directory whose *existence* means "this version is installed".
    public func versionDirectory(componentID: String, version: String) -> URL {
        componentDirectory(componentID).appendingPathComponent(version, isDirectory: true)
    }

    public func versionDirectory(for component: LSPComponent) -> URL {
        versionDirectory(componentID: component.id, version: component.version)
    }

    /// A path inside an installed component — an entry point, an executable, a
    /// license text. `subpath` empty answers the version directory itself.
    public func file(_ subpath: String, of component: LSPComponent) -> URL {
        Self.appending(subpath, to: versionDirectory(for: component))
    }

    /// The executable this component provides, if it provides one (`node`).
    public func executable(of component: LSPComponent) -> URL? {
        component.executableSubpath.map { file($0, of: component) }
    }

    /// The verbatim license texts inside the installed tree, in manifest order —
    /// what the Acknowledgements surface reads once the component is on disk.
    public func licenseFiles(of component: LSPComponent) -> [URL] {
        component.licenseFileSubpaths.map { file($0, of: component) }
    }

    // MARK: - Staging

    /// The scratch tree one install attempt owns (D13).
    ///
    /// `token` distinguishes attempts: two installs of the same component and
    /// version are coalesced by the engine, but a *retry* after a failed attempt
    /// whose sweep has not run yet must not adopt the half-written tree the
    /// previous one left. A fresh token per attempt makes that impossible instead
    /// of unlikely.
    public func stagingDirectory(componentID: String, version: String, token: Int) -> URL {
        stagingRoot.appendingPathComponent("\(componentID)-\(version)-\(token)", isDirectory: true)
    }

    public func stagingDirectory(for component: LSPComponent, token: Int) -> URL {
        stagingDirectory(componentID: component.id, version: component.version, token: token)
    }

    /// Where one artifact's stripped contents go, under whichever root the
    /// attempt is building into — a staging directory while installing, and the
    /// same relative position inside the version directory once it is moved.
    /// That correspondence is the reason `move` alone finishes the job.
    public func destination(of artifact: LSPArtifact, unpackingInto root: URL) -> URL {
        Self.appending(artifact.destinationSubpath, to: root)
    }

    // MARK: - Containment

    /// Whether `url` is inside the install root. The engine deletes directories;
    /// this is the assertion that it only ever deletes its own.
    public func contains(_ url: URL) -> Bool {
        let root = base.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - Mechanism

    /// Appending a possibly-multi-component, possibly-empty subpath. Empty
    /// answers `root` unchanged — `appendingPathComponent("")` would leave a
    /// trailing slash and break the string comparison `contains(_:)` and the
    /// tests do.
    private static func appending(_ subpath: String, to root: URL) -> URL {
        let components = subpath.split(separator: "/").map(String.init)
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }
}
