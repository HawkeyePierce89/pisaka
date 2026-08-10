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

    /// `base` is normalised (`.`/`..` resolved lexically, no `realpath(3)` and no
    /// `stat(2)` — the layout touches no file system) and re-spelled as a
    /// directory URL, so that two spellings of one root compare equal. Without the
    /// second half, a base that arrived with a trailing slash and one that did not
    /// would be two different `URL`s naming the same directory, and
    /// `LSPInstallLayout` is a value the model compares.
    ///
    /// `URL.standardizedFileURL` is deliberately *not* what does that: it is
    /// documented as lexical and is not — under `/private/{tmp,var,etc}` it strips
    /// the `/private` prefix when the shortened path exists on disk — so it would
    /// re-spell a base the caller handed us into a different one, and only for
    /// some roots. See `normalisedComponents(of:)`.
    public init(base: URL) {
        self.base = Self.directoryURL(Self.normalisedComponents(of: base))
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
    /// of unlikely — *within one run*. The engine's counter restarts at zero every
    /// launch, so the token says nothing across launches and the emptiness of the
    /// tree is established by the engine dropping it before it builds there, not
    /// by this name being unique.
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
        Self.directory(base, contains: url)
    }

    /// Whether `url` *is* the install root, by the same lexical normalisation
    /// `contains(_:)` uses.
    ///
    /// Here rather than at the delete sites so that "inside the root" and "is the
    /// root" can never be answered by two different path rules. They were: the
    /// engine and the gopls model both spelled the second half as
    /// `url.standardizedFileURL.path != base.standardizedFileURL.path`, which
    /// consults the disk for exactly the reason `normalisedComponents(of:)`
    /// records — so one boolean expression asked a lexical question and a
    /// stat-dependent one at once, and only the first was the file's contract.
    public func isBase(_ url: URL) -> Bool {
        Self.normalisedComponents(of: url) == Self.normalisedComponents(of: base)
    }

    /// Whether `url` *is* `directory` or lies underneath it, lexically.
    ///
    /// The same comparison `contains(_:)` is, asked of an arbitrary root rather
    /// than of `base` — the engine asks it of the install root before it deletes
    /// and of one attempt's staging directory before it writes, and one
    /// implementation is what keeps those two answers the same shape. Lexical on
    /// purpose, like everything else here: this file resolves `.`/`..` and touches
    /// no file system, so a symlink inside the tree is not followed (D12 states
    /// that limit).
    ///
    /// **Whole components, not a string prefix**, so `/a/bc` inside `/a/b` is
    /// unrepresentable rather than merely tested against; equal components count
    /// as contained, because the sweep reads the root itself. This is the rule
    /// `CanonicalPath.relativeComponents(of:under:)` applies to *canonical*
    /// components, restated here over lexical ones precisely because this file may
    /// not touch the disk — the two must not be unified.
    ///
    /// The cost is the limit `normalisedComponents(of:)` states: two spellings of
    /// one directory (`/tmp/x` and `/private/tmp/x`) compare as different
    /// directories. Safe for a predicate guarding deletes and writes — it can only
    /// ever refuse — and unreachable from the engine, which derives root and
    /// candidate from one `base`.
    public static func directory(_ directory: URL, contains url: URL) -> Bool {
        let root = normalisedComponents(of: directory)
        let candidate = normalisedComponents(of: url)
        guard candidate.count >= root.count else { return false }
        return candidate.prefix(root.count).elementsEqual(root)
    }

    // MARK: - Mechanism

    /// A path's components, lexically: empties and `.` dropped, `..` resolved
    /// against what precedes it, clamped at the root so `/../x` is `/x`.
    ///
    /// **Stat-free and symlink-blind, which is the whole point.** The obvious
    /// spelling of this — `URL.standardizedFileURL` — is documented as lexical and
    /// is not: for a path under `/private/tmp`, `/private/var` or `/private/etc`
    /// it strips the `/private` prefix *when the shortened path exists on disk*,
    /// and keeps it when it does not. That made this pure-path-math module quietly
    /// decide on disk state, and it had one live consequence: the engine's
    /// `verifyUnpackTarget` asks containment of a staging directory it has just
    /// **created** (so the shortened spelling exists, and it standardised to
    /// `/tmp/…`) against an artifact destination inside it that does **not** exist
    /// yet (so it stayed `/private/tmp/…`). Two spellings of one tree compared as
    /// unrelated and a correct install under a `/private`-spelled root failed with
    /// `unpackFailed`.
    ///
    /// The limit that buys back: `/tmp/x` and `/private/tmp/x` are one directory
    /// on macOS and this file calls them two. Nothing here may resolve that
    /// without a `stat(2)`, and the callers only ever *refuse* on a `false`.
    ///
    /// The contract is an absolute file-URL path — what every construction site
    /// supplies (Application Support in the app, a temporary directory in the
    /// tests) — so the components are read straight off `path` and re-rooted at
    /// `/`; a relative one would be treated as if it hung off the root.
    private static func normalisedComponents(of url: URL) -> [String] {
        var components: [String] = []
        for component in url.path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components
    }

    /// The inverse of `normalisedComponents(of:)`: normalised components back to
    /// an absolute directory URL. No components is the root itself.
    private static func directoryURL(_ components: [String]) -> URL {
        URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    /// Appending a possibly-multi-component, possibly-empty subpath. Empty
    /// answers `root` unchanged rather than the trailing-slash spelling
    /// `appendingPathComponent("")` produces: containment no longer cares (the
    /// component split drops the empty), but the `URL` is compared for equality
    /// by callers and by the tests, and two spellings of one path are two values.
    private static func appending(_ subpath: String, to root: URL) -> URL {
        let components = subpath.split(separator: "/").map(String.init)
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }
}
