import Foundation

/// The pinned, static description of everything the app is allowed to download.
///
/// **This file is data, and that is the whole design.** Provisioning a tenth
/// language server must be one manifest record and nothing else: no new download
/// code, no new unpack rule, no new path math. That is only true if a "component"
/// is fully described by a version and a list of verified artifacts — which is
/// what `LSPComponent` is — and if the servers themselves are described by which
/// components they need and where their entry point sits inside them, which is
/// what `LSPDownloadableServer` is.
///
/// **Nothing here is discovered at runtime.** There is no registry query, no
/// `dist-tags`, no "latest": every URL, byte count and SHA-256 below was resolved
/// by hand and is changed only by shipping a new version of the app. That is the
/// point — the checksum is the only thing standing between the manifest and
/// whatever the network hands over (`SHA256`), so a checksum the app fetched from
/// the same place as the bytes would verify nothing at all. It also means
/// `swift test` needs no network: the data under test is right here.
///
/// The by-hand update procedure (where the checksums come from, and how the
/// unpacked sizes are measured) lives in `docs/architecture/core-provisioning.md`.
public struct LSPProvisioningManifest: Equatable, Sendable {
    public let components: [LSPComponent]

    public init(components: [LSPComponent]) {
        self.components = components
        byID = Dictionary(components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private let byID: [String: LSPComponent]

    public func component(_ id: String) -> LSPComponent? { byID[id] }

    /// `id` and everything it requires, requirements first, each id once.
    ///
    /// The engine installs in exactly this order (D13's runtime-before-server
    /// rule), and the ordering lives here rather than in the engine because it is
    /// a property of the *data*: the manifest is what knows that
    /// `typescript-language-server` cannot run without `node`.
    ///
    /// Depth-first, with a visited set, so a cycle in a hand-edited manifest
    /// terminates instead of hanging — the manifest tests assert there is none,
    /// but a data file that can hang the installer is not a thing to leave open.
    public func installationOrder(for id: String) -> [LSPComponent] {
        var ordered: [LSPComponent] = []
        var visited: Set<String> = []

        func visit(_ id: String) {
            guard !visited.contains(id), let component = byID[id] else { return }
            visited.insert(id)
            for requirement in component.requires { visit(requirement) }
            ordered.append(component)
        }

        visit(id)
        return ordered
    }

    /// The manifest the app ships. See the table in
    /// `docs/architecture/core-provisioning.md` for provenance.
    ///
    /// `rustAnalyzer` is in here without a matching `LSPDownloadableServer` case,
    /// and that is D21 rather than an oversight: what Rust reuses from this layer is
    /// the pinned component and the engine that installs it, not
    /// `LSPProvisioningModel`, whose row cannot say "no Rust toolchain".
    public static let standard = LSPProvisioningManifest(
        components: [.node, .typescriptLanguageServer, .pyright, .rustAnalyzer, .yamlLanguageServer]
    )
}

// MARK: - Architecture

/// The two Mac architectures a shipped app can be running as.
///
/// Taken from the running slice, not from the hardware: a Rosetta-translated app
/// reports `x64` and provisions the x64 Node, which is correct — the child process
/// it spawns inherits the translation. Recorded as a known limit rather than
/// worked around, because the alternative (asking the kernel what the machine
/// really is and running a native child under a translated parent) buys nothing
/// for a stdio server.
public enum LSPHostArchitecture: String, CaseIterable, Sendable {
    case arm64
    case x64
}

// MARK: - Artifacts

/// How an artifact is packed — and, for `gzip`, what the single file inside it is
/// called.
///
/// A case rather than a `Bool` because the unpack seam takes the format as an
/// argument and a new one must be a compile error at every call site rather than
/// a silently wrong `false`. The second case is what that bought: rust-analyzer
/// publishes its macOS builds as a bare `.gz` of one binary, not as a tarball, so
/// the unpacker's switch grew a branch and nothing else had to move.
///
/// **The name lives in the payload (D22).** A tarball carries its members' names;
/// a bare `.gz` carries nothing but bytes, so the file it decompresses into has to
/// be named by whoever pinned it. Naming it here rather than in a parallel
/// `LSPArtifact.unpackedFileName` is what keeps the manifest from being able to
/// express "a gzip with no name" or "a tarball with one" — two states that have no
/// meaning and would each need a guard somewhere.
///
/// It also carries an implication the other case does not: **a `gzip` artifact is
/// an executable**. That is the only reason this format exists here, and
/// `LSPInstallEngine` verifies it before it commits — the unpacker sets the bit at
/// creation, the engine refuses to install a file that somehow lacks it.
///
/// No raw value: `stripComponents` is meaningless for `gzip` (the manifest tests
/// pin it to `0`), and nothing ever needed the format as a string.
public enum LSPArchiveFormat: Equatable, Sendable {
    case tarGzip
    case gzip(fileName: String)
}

/// One downloadable file, and everything needed to verify and place it.
///
/// The byte counts are *sizes shown to the user*, not checks. `byteCount` is what
/// the consent prompt and the Settings row put in front of someone before anything
/// is fetched (D15 — "sized"); nothing compares a response against it, because a
/// length check is strictly weaker than the SHA-256 that already gates the unpack
/// and adding one would suggest a second guarantee that is not there. The single
/// thing standing between the manifest and whatever the network hands over is the
/// digest.
public struct LSPArtifact: Equatable, Sendable {
    public let url: URL

    /// The expected digest, 64 lowercase hexadecimal characters — the form
    /// `nodejs.org`'s `SHASUMS256.txt` and `shasum -a 256` both print, so the pin
    /// can be pasted rather than transcribed.
    public let sha256: String

    /// Compressed size, as served. Shown to the user; never trusted as a limit.
    public let byteCount: Int

    /// Approximate size on disk after unpacking. Rounded on purpose — it is
    /// measured by unpacking once and reading `du -sk`.
    ///
    /// **Nothing reads this at runtime**, and that is the honest description of
    /// it: no surface shows a disk figure and no path checks for free space
    /// before an unpack (a full volume surfaces as `unpackFailed`, which discards
    /// the staging tree and leaves the previous install alone, so the outcome is
    /// already correct). It is here as the recorded result of the manifest's
    /// by-hand update procedure — the number someone bumping a pin has to measure
    /// anyway to know what they are shipping — and `LSPProvisioningManifestTests`
    /// is what keeps it from drifting into nonsense.
    public let unpackedByteCount: Int

    public let format: LSPArchiveFormat

    /// Leading path components the archive's own layout adds and we do not want.
    /// Every *tarball* here is 1: a Node tarball wraps everything in
    /// `node-v…-darwin-arm64/`, an npm tarball in `package/`. A `.gzip` artifact
    /// has no layout to strip and pins this at 0 — the unpacker ignores it there,
    /// and `LSPProvisioningManifestTests` is what keeps the data saying so.
    public let stripComponents: Int

    /// Where the stripped contents land, relative to the component's version
    /// directory. Empty means the version directory itself (Node), which is what
    /// puts the binary at `<version>/bin/node`.
    public let destinationSubpath: String

    /// `nil` when the artifact is architecture-independent — every npm tarball
    /// here, since neither server ships native code we use (`fsevents` builds
    /// nothing at install time; it is present so Node's optional-dependency
    /// resolution finds it rather than warning).
    public let architecture: LSPHostArchitecture?

    public init(
        url: URL,
        sha256: String,
        byteCount: Int,
        unpackedByteCount: Int,
        format: LSPArchiveFormat = .tarGzip,
        stripComponents: Int = 1,
        destinationSubpath: String = "",
        architecture: LSPHostArchitecture? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.unpackedByteCount = unpackedByteCount
        self.format = format
        self.stripComponents = stripComponents
        self.destinationSubpath = destinationSubpath
        self.architecture = architecture
    }

    /// Whether this artifact is one of the files to fetch when running as
    /// `architecture`. An artifact with no architecture applies to all of them.
    public func applies(to architecture: LSPHostArchitecture) -> Bool {
        self.architecture == nil || self.architecture == architecture
    }
}

// MARK: - Components

/// A versioned directory of verified artifacts (D12).
///
/// The unit of installation, of removal, and of sharing: `node` is one component
/// that two servers require, so accepting Python after TypeScript downloads
/// 4 MB and not 56. "Installed" is the existence of the version directory and
/// nothing else — there is no database, no receipt file and no state to get out
/// of sync with the disk.
public struct LSPComponent: Equatable, Sendable, Identifiable {
    public let id: String
    public let version: String

    /// SPDX *expression* for everything this component ships — one id, or ids
    /// joined by ` AND `, the way `licenses.json` already spells `tree-sitter` as
    /// `MIT AND Unicode-DFS-2016`.
    ///
    /// An expression rather than a bare id because a component is its whole
    /// installed tree, and a tree is not always under one license: `pyright`'s own
    /// code is MIT and the typeshed stub library it ships beside it is Apache-2.0,
    /// from a different project. Labelling that entry "MIT" would caption
    /// Apache-2.0 text with the wrong license on the one screen whose purpose is
    /// exactness.
    ///
    /// What it deliberately does *not* enumerate is the third-party notices
    /// carried **inside** a package's own license file — Node's OpenSSL/ICU/zlib
    /// sections, `typescript`'s `ThirdPartyNoticeText.txt`, the MIT header
    /// `typescript-language-server`'s Apache-2.0 LICENSE opens with for its
    /// vscode-derived parts. Those travel with the verbatim text
    /// `LSPInstalledLicenses` prints, which is the authority; this field is the
    /// heading over it, and a heading naming thirty ids informs nobody. The line
    /// is "a separate project's license file" — which is exactly what
    /// `licenseFileSubpaths` lists a second entry for.
    public let licenseSPDX: String

    /// Verbatim license texts inside the installed tree, relative to the version
    /// directory. Read at display time by the Acknowledgements surface — the
    /// obligation travels with the bytes, so it is satisfied from the bytes
    /// rather than from a copy checked in beside them.
    public let licenseFileSubpaths: [String]

    public let artifacts: [LSPArtifact]

    /// Component ids that must be installed first. Only ever `node` today.
    public let requires: [String]

    /// The executable this component provides, relative to the version directory,
    /// or `nil` for a component that is only ever `node`'s argument.
    public let executableSubpath: String?

    public init(
        id: String,
        version: String,
        licenseSPDX: String,
        licenseFileSubpaths: [String],
        artifacts: [LSPArtifact],
        requires: [String] = [],
        executableSubpath: String? = nil
    ) {
        self.id = id
        self.version = version
        self.licenseSPDX = licenseSPDX
        self.licenseFileSubpaths = licenseFileSubpaths
        self.artifacts = artifacts
        self.requires = requires
        self.executableSubpath = executableSubpath
    }

    /// The artifacts to fetch when running as `architecture`.
    public func artifacts(for architecture: LSPHostArchitecture) -> [LSPArtifact] {
        artifacts.filter { $0.applies(to: architecture) }
    }

    /// Total compressed bytes for `architecture` — the number the consent prompt
    /// and the Settings row show.
    public func downloadByteCount(for architecture: LSPHostArchitecture) -> Int {
        artifacts(for: architecture).reduce(0) { $0 + $1.byteCount }
    }
}

// MARK: - The pins

extension LSPComponent {
    /// The shared Node runtime. Both servers are Node programs; pinning one
    /// runtime rather than letting each server find "a node" is what makes the
    /// install hermetic — nothing here consults `$PATH`, and a user's Homebrew
    /// Node being upgraded out from under us cannot break a language server.
    public static let node = LSPComponent(
        id: "node",
        version: "24.19.0",
        licenseSPDX: "MIT",
        licenseFileSubpaths: ["LICENSE"],
        artifacts: [
            LSPArtifact(
                url: URL(string: "https://nodejs.org/dist/v24.19.0/node-v24.19.0-darwin-arm64.tar.gz")!,
                sha256: "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
                byteCount: 52_234_372,
                unpackedByteCount: 110_000_000,
                architecture: .arm64
            ),
            LSPArtifact(
                url: URL(string: "https://nodejs.org/dist/v24.19.0/node-v24.19.0-darwin-x64.tar.gz")!,
                sha256: "d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316",
                byteCount: 53_439_583,
                unpackedByteCount: 112_000_000,
                architecture: .x64
            ),
        ],
        executableSubpath: "bin/node"
    )

    /// `typescript-language-server`, plus the `typescript` it drives (D11).
    ///
    /// Two artifacts of *one* component rather than two components, because the
    /// pair is only ever installed and removed together and the server's own
    /// resolution expects to find `typescript` beside it: both land under this
    /// component's `node_modules/`, so Node's upward walk from `cli.mjs` finds it
    /// even before `initializationOptions` names it outright.
    ///
    /// `typescript` is pinned at 5.9.3 rather than the current major: 7.0 is the
    /// native rewrite and no longer ships the `lib/tsserver.js` this server drives.
    public static let typescriptLanguageServer = LSPComponent(
        id: "typescript-language-server",
        version: "5.3.0",
        licenseSPDX: "Apache-2.0",
        // `ThirdPartyNoticeText.txt` is not decoration: TypeScript's own
        // `LICENSE.txt` is Apache-2.0 for Microsoft's code, and that file is the
        // separate notice for the third-party material incorporated into the
        // `tsserver.js` this component installs and runs. Same obligation, and
        // the same reason, as the `deps/xdiff` and `lib/src/unicode` notices
        // appended to the bundled texts in `Resources/Licenses/`.
        licenseFileSubpaths: [
            "node_modules/typescript-language-server/LICENSE",
            "node_modules/typescript/LICENSE.txt",
            "node_modules/typescript/ThirdPartyNoticeText.txt",
        ],
        artifacts: [
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/typescript-language-server/-/typescript-language-server-5.3.0.tgz")!,
                sha256: "398cacc17fff2108652e7b4050e3182008d17063246b3fea7dcf5fae2ce1560e",
                byteCount: 501_633,
                unpackedByteCount: 2_600_000,
                destinationSubpath: "node_modules/typescript-language-server"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/typescript/-/typescript-5.9.3.tgz")!,
                sha256: "10e108c9cf7d5f2879053dff18515fb405abf2ccef63eaaf017d9c571687a1d3",
                byteCount: 4_377_468,
                unpackedByteCount: 23_000_000,
                destinationSubpath: "node_modules/typescript"
            ),
        ],
        requires: ["node"],
        executableSubpath: "node_modules/typescript-language-server/lib/cli.mjs"
    )

    /// `pyright`, plus its one (optional) dependency.
    ///
    /// `fsevents` is macOS-only, optional, and pure prebuilt native code that
    /// pyright's watcher reaches for; installing it costs 22 KB and avoids the
    /// resolution warning its absence produces. There is no other transitive
    /// closure — which is why this whole layer needs no `npm`, no lockfile and no
    /// dependency solver.
    public static let pyright = LSPComponent(
        id: "pyright",
        version: "1.1.411",
        // Two ids, because the tree really is under two: the Apache-2.0 below is
        // typeshed's, not a notice inside pyright's own MIT file, and the
        // Acknowledgements heading has to say so or it captions Apache-2.0 text
        // "MIT". Same shape as `tree-sitter`'s `MIT AND Unicode-DFS-2016` in
        // `licenses.json`.
        licenseSPDX: "MIT AND Apache-2.0",
        // pyright's own `LICENSE.txt` is MIT and covers its code. It also ships
        // `dist/typeshed-fallback/` — the typeshed stub library it reads to
        // answer anything about the standard library — which is Apache-2.0 under
        // its own `LICENSE`, a different license from a different project. The
        // repository's package-granular rule is that a package's own LICENSE is
        // not automatically the whole obligation; this is that case.
        licenseFileSubpaths: [
            "node_modules/pyright/LICENSE.txt",
            "node_modules/pyright/dist/typeshed-fallback/LICENSE",
            "node_modules/fsevents/LICENSE",
        ],
        artifacts: [
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/pyright/-/pyright-1.1.411.tgz")!,
                sha256: "bd5c488fc20fa237a944279bf32cae2f986cf10d5d5d9e8705819859daeb2f4a",
                byteCount: 4_139_958,
                unpackedByteCount: 21_000_000,
                destinationSubpath: "node_modules/pyright"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/fsevents/-/fsevents-2.3.3.tgz")!,
                sha256: "c77e7a5d5ff31dd7acea7c44d4a0455e0528cdacbd24a8cb6c82b66d239b587e",
                byteCount: 22_808,
                unpackedByteCount: 90_000,
                destinationSubpath: "node_modules/fsevents"
            ),
        ],
        requires: ["node"],
        executableSubpath: "node_modules/pyright/dist/pyright-langserver.js"
    )

    /// rust-analyzer — the one component here that is a **standalone binary**, and
    /// the reason `LSPArchiveFormat` has a second case (D22).
    ///
    /// Everything else in this manifest is a Node program, or Node itself, arriving
    /// in a tarball that carries its own directory layout and a mode per member.
    /// Upstream publishes rust-analyzer as a bare `.gz` of one Mach-O executable:
    /// there is no wrapping directory to strip (`stripComponents: 0`), no member
    /// name to read out of the archive (so the name travels in the format's
    /// payload), and no mode either — which is what the engine's pre-commit
    /// executable check exists for.
    ///
    /// **`licenseFileSubpaths` is empty as a decision, not as an omission** (D24).
    /// The archive holds one binary and nothing beside it, so there is no verbatim
    /// text inside the installed tree for `LSPInstalledLicenses` to print, and the
    /// substitute is one sentence in the Settings row naming the origin and the
    /// dual license below. `licenses.json` covers nothing of it either: this app
    /// bundles none of its bytes — they arrive over the network at the user's
    /// request or not at all.
    ///
    /// `requires: []`, because nothing runs it but the kernel — the first component
    /// here that is not a `node` argument. And it is the one whose **version is a
    /// date**: that is what upstream ships, and a date sorts correctly
    /// lexicographically, which is the single property `LSPInstallEngine.state(of:)`
    /// asks of a version string.
    public static let rustAnalyzer = LSPComponent(
        id: "rust-analyzer",
        version: "2026-08-03",
        licenseSPDX: "Apache-2.0 OR MIT",
        licenseFileSubpaths: [],
        artifacts: [
            LSPArtifact(
                url: URL(string: "https://github.com/rust-lang/rust-analyzer/releases/download/2026-08-03/rust-analyzer-aarch64-apple-darwin.gz")!,
                sha256: "bba6cd8209643cd781f3ee5474fa232d3ee1b77a57f2e77982806e3c80a65207",
                byteCount: 13_873_448,
                unpackedByteCount: 37_914_480,
                format: .gzip(fileName: "rust-analyzer"),
                stripComponents: 0,
                destinationSubpath: "bin",
                architecture: .arm64
            ),
            LSPArtifact(
                url: URL(string: "https://github.com/rust-lang/rust-analyzer/releases/download/2026-08-03/rust-analyzer-x86_64-apple-darwin.gz")!,
                sha256: "8966f9429085c243817b9d13afa76e98920668c07a9b432901daaf047397c6cb",
                byteCount: 14_576_027,
                unpackedByteCount: 39_382_228,
                format: .gzip(fileName: "rust-analyzer"),
                stripComponents: 0,
                destinationSubpath: "bin",
                architecture: .x64
            ),
        ],
        executableSubpath: "bin/rust-analyzer"
    )

    /// `yaml-language-server`, and the whole of the runtime closure it `require`s
    /// (D11's rule, applied to a package that needs it twenty times over).
    ///
    /// The other two Node components pin one or two tarballs because their
    /// published bundles are self-contained. This one is not: `server.js` is a
    /// thin entry point that `require`s its dependencies at run time, so every
    /// package in the resolved closure is a pin here or the server dies on start.
    /// Twenty tarballs, ~4.19 MB compressed, ~24.8 MB on disk — resolved once, by
    /// hand, and flat: no version in the closure conflicts with another, so the
    /// same `node_modules/<package>` layout the other components use resolves
    /// correctly under Node's ordinary upward walk from `server.js`. **There is
    /// still no npm here, and no solver** — the closure is data, resolved by the
    /// procedure in `core-provisioning.md` and changed only by shipping a new app.
    ///
    /// `prettier` is in the list although Pisaka never asks this server to format
    /// anything: `yamlFormatter.js` sits in the language service's own module
    /// graph and `require`s `prettier/standalone` unconditionally, so leaving it
    /// out is a server that fails to load rather than a server without formatting.
    /// It is also, at 2.8 MB, two thirds of the download.
    ///
    /// **This component's schemas are not pinned, and cannot be.** The server
    /// fetches JSON schemas over the network while it runs — that is what
    /// makes a compose file complete `services` rather than whatever the buffer
    /// happens to contain — so it is the one stated exception to "what may be
    /// downloaded is pinned data". The exception is declared where consent is
    /// given — the consent banner and the Settings row say so before anything is
    /// fetched — and recorded in `core-provisioning.md` beside the invariant it
    /// qualifies, rather than only in this comment.
    public static let yamlLanguageServer = LSPComponent(
        id: "yaml-language-server",
        version: "1.24.0",
        // Three ids, because the closure really is under three: MIT for
        // eighteen of the twenty packages, ISC for `yaml` and BSD-3-Clause for
        // `fast-uri`, each a separate project's own license file shipped inside
        // this tree. Same rule as pyright's `MIT AND Apache-2.0` — the heading
        // has to name every license the texts below it are under.
        licenseSPDX: "MIT AND ISC AND BSD-3-Clause",
        // Every license and third-party notice the closure ships, found by the
        // `tar tzf | grep -iE 'licen|notice|third.?party'` step in
        // `core-provisioning.md` and listed with upstream's own spelling —
        // `License.txt`, `LICENSE.md` and a lowercase `license` all appear, and a
        // path this layer cannot read is dropped silently at display time.
        //
        // `prettier` and five of the six `vscode-*` packages ship a second notice
        // beside their license for material incorporated into their bundles; all
        // of them are listed. The one package with **no entry at all** is
        // `node_modules/@vscode/l10n`, and that is a stated exception rather than
        // an omission: 0.0.18 publishes no license file, declaring MIT in its
        // `package.json` alone. `LSPProvisioningManifestTests` pins it by
        // destination so a second unacknowledged package cannot appear quietly.
        licenseFileSubpaths: [
            "node_modules/yaml-language-server/LICENSE",
            "node_modules/ajv/LICENSE",
            "node_modules/ajv-draft-04/LICENSE",
            "node_modules/ajv-i18n/LICENSE",
            "node_modules/fast-deep-equal/LICENSE",
            "node_modules/fast-uri/LICENSE",
            "node_modules/json-schema-traverse/LICENSE",
            "node_modules/jsonc-parser/LICENSE.md",
            "node_modules/picomatch/LICENSE",
            "node_modules/prettier/LICENSE",
            "node_modules/prettier/THIRD-PARTY-NOTICES.md",
            "node_modules/request-light/LICENSE.md",
            "node_modules/require-from-string/license",
            "node_modules/vscode-jsonrpc/License.txt",
            "node_modules/vscode-jsonrpc/thirdpartynotices.txt",
            "node_modules/vscode-languageserver/License.txt",
            "node_modules/vscode-languageserver/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-protocol/License.txt",
            "node_modules/vscode-languageserver-protocol/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-textdocument/License.txt",
            "node_modules/vscode-languageserver-textdocument/thirdpartynotices.txt",
            "node_modules/vscode-languageserver-types/License.txt",
            "node_modules/vscode-languageserver-types/thirdpartynotices.txt",
            "node_modules/vscode-uri/LICENSE.md",
            "node_modules/yaml/LICENSE",
        ],
        artifacts: [
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/yaml-language-server/-/yaml-language-server-1.24.0.tgz")!,
                sha256: "11a321032012131f2ccdf7952dc347ce05291c66931a5de2f449b2dfc81f24b2",
                byteCount: 646_765,
                unpackedByteCount: 7_600_000,
                destinationSubpath: "node_modules/yaml-language-server"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/ajv/-/ajv-8.20.0.tgz")!,
                sha256: "b2f0b3a893bbb8cc5efb6814f08b1499e19e31d5dd73683f5893382f48f6e7b3",
                byteCount: 217_611,
                unpackedByteCount: 2_400_000,
                destinationSubpath: "node_modules/ajv"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/ajv-draft-04/-/ajv-draft-04-1.0.0.tgz")!,
                sha256: "b2328acf9b3a5b1b3a098789770c2dd34ed86b5913c904c056091ec10319c2e7",
                byteCount: 8_735,
                unpackedByteCount: 120_000,
                destinationSubpath: "node_modules/ajv-draft-04"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/ajv-i18n/-/ajv-i18n-4.2.0.tgz")!,
                sha256: "b84c90f14594a447bf59badc6a9b01e75049400186adec9c85b52e1709867239",
                byteCount: 25_980,
                unpackedByteCount: 530_000,
                destinationSubpath: "node_modules/ajv-i18n"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/@vscode/l10n/-/l10n-0.0.18.tgz")!,
                sha256: "f1c2dc897488595f6bb42121869f525c6c6a5f7c8dca550754199c3251ed7c5c",
                byteCount: 4_548,
                unpackedByteCount: 33_000,
                destinationSubpath: "node_modules/@vscode/l10n"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/fast-deep-equal/-/fast-deep-equal-3.1.3.tgz")!,
                sha256: "b019a0980f27638dc3f85836b0e478f188e00d7a6e5852c0819fa86f56e47b8f",
                byteCount: 3_656,
                unpackedByteCount: 45_000,
                destinationSubpath: "node_modules/fast-deep-equal"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/fast-uri/-/fast-uri-3.1.5.tgz")!,
                sha256: "82a71e7e3716dc8c392cac0762bce80614cf539ef22000415e26eaf5c453ce2f",
                byteCount: 32_112,
                unpackedByteCount: 260_000,
                destinationSubpath: "node_modules/fast-uri"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/json-schema-traverse/-/json-schema-traverse-1.0.0.tgz")!,
                sha256: "023222622df29fc274bde5d3590e47aa1d4a8e3c1d6e2aba029948ed79799b21",
                byteCount: 6_074,
                unpackedByteCount: 57_000,
                destinationSubpath: "node_modules/json-schema-traverse"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/jsonc-parser/-/jsonc-parser-3.3.1.tgz")!,
                sha256: "4a0315b8671e7463bae7af7c142cdf19e9aa7ba39eb36dc2df383b8648e3cbc9",
                byteCount: 27_354,
                unpackedByteCount: 260_000,
                destinationSubpath: "node_modules/jsonc-parser"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/picomatch/-/picomatch-4.0.5.tgz")!,
                sha256: "e89c478225a42b3793bb4a39fd576de142c9829c26a5bd71782249e48b112f51",
                byteCount: 24_079,
                unpackedByteCount: 120_000,
                destinationSubpath: "node_modules/picomatch"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/prettier/-/prettier-3.9.6.tgz")!,
                sha256: "997da95cf2ae81053cafc79ef122a6e8dc12e3f2c619d57eb1f2e19525fb212f",
                byteCount: 2_800_155,
                unpackedByteCount: 10_100_000,
                destinationSubpath: "node_modules/prettier"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/request-light/-/request-light-0.5.8.tgz")!,
                sha256: "4b6d4b48fa05056435b300a4a5f904bacbe0e6ddfa28bb44b729eb64f24375b9",
                byteCount: 10_534,
                unpackedByteCount: 49_000,
                destinationSubpath: "node_modules/request-light"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/require-from-string/-/require-from-string-2.0.2.tgz")!,
                sha256: "cb694a4965908f7775a0c757f00cf4e624d193cd71d77988fbcca0f597b88d82",
                byteCount: 1_816,
                unpackedByteCount: 16_000,
                destinationSubpath: "node_modules/require-from-string"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-jsonrpc/-/vscode-jsonrpc-8.2.0.tgz")!,
                sha256: "3da44531c398f1545074cb728e359a822f35b9f8ac7171c847f42f0728b9c7cb",
                byteCount: 35_427,
                unpackedByteCount: 340_000,
                destinationSubpath: "node_modules/vscode-jsonrpc"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-languageserver/-/vscode-languageserver-9.0.1.tgz")!,
                sha256: "6cd7f463ae7872e588a4dd5ed5149475fe32e53517509a81e715eb0540602412",
                byteCount: 32_720,
                unpackedByteCount: 370_000,
                destinationSubpath: "node_modules/vscode-languageserver"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-languageserver-protocol/-/vscode-languageserver-protocol-3.17.5.tgz")!,
                sha256: "7473eb2d2163f3f8bea09644f9d803789a195e596b65d3946c4157e583e3ccc8",
                byteCount: 59_008,
                unpackedByteCount: 512_000,
                destinationSubpath: "node_modules/vscode-languageserver-protocol"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-languageserver-textdocument/-/vscode-languageserver-textdocument-1.0.13.tgz")!,
                sha256: "46c8c250fa7667a9503cffb506512b99557784dfefbd8e318944856ca11ffbb9",
                byteCount: 8_425,
                unpackedByteCount: 70_000,
                destinationSubpath: "node_modules/vscode-languageserver-textdocument"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-languageserver-types/-/vscode-languageserver-types-3.17.5.tgz")!,
                sha256: "d673f9e7f8bbe51351be51c58f32d4dcfa97a670ebb86bc633368394c609cac0",
                byteCount: 71_382,
                unpackedByteCount: 400_000,
                destinationSubpath: "node_modules/vscode-languageserver-types"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/vscode-uri/-/vscode-uri-3.1.0.tgz")!,
                sha256: "c6ec752d7a4858237389b23fb4d5ac05c2f1f606071cd212a9b54730e43cfc54",
                byteCount: 59_768,
                unpackedByteCount: 246_000,
                destinationSubpath: "node_modules/vscode-uri"
            ),
            LSPArtifact(
                url: URL(string: "https://registry.npmjs.org/yaml/-/yaml-2.8.3.tgz")!,
                sha256: "9539805d7447def2bed5c5b4acacc283362c5e80abc5d93472b2f35f0cbf85ad",
                byteCount: 111_837,
                unpackedByteCount: 1_300_000,
                destinationSubpath: "node_modules/yaml"
            ),
        ],
        requires: ["node"],
        executableSubpath: "node_modules/yaml-language-server/out/server/src/server.js"
    )
}

// MARK: - Servers

/// A language server the app can provision for itself.
///
/// The bridge between the manifest (what may be downloaded) and 2a's
/// `LSPServerRegistry` (what may be started). Deliberately a closed enum rather
/// than another data record: every case here is a *served language set*, and the
/// one rule this layer must never break — the Swift path is untouched — is a
/// statement about that set, checked by set equality in the tests. A tenth server
/// is one case plus one component, and the compiler asks for both.
public enum LSPDownloadableServer: String, CaseIterable, Equatable, Sendable, Identifiable {
    case typescript
    case python
    case yaml

    public var id: String { rawValue }

    /// The id the started server is keyed by in `LSPServerRegistry` and in
    /// `LSPWorkspace`'s `(server, root)` bookkeeping. The component id, because
    /// they name the same thing and two spellings of one identity is one more
    /// thing to get out of step.
    public var serverID: String { serverComponentID }

    /// Shown in the consent banner and the Settings row.
    public var displayName: String {
        switch self {
        case .typescript: return "TypeScript / JavaScript"
        case .python: return "Python"
        case .yaml: return "YAML"
        }
    }

    /// Never contains `.swift`: sourcekit-lsp is found through `xcrun` and is not
    /// something this layer provisions, replaces or can interfere with.
    public var languages: Set<SyntaxLanguage> {
        switch self {
        case .typescript: return [.typescript, .javascript]
        case .python: return [.python]
        case .yaml: return [.yaml]
        }
    }

    public var serverComponentID: String {
        switch self {
        case .typescript: return "typescript-language-server"
        case .python: return "pyright"
        case .yaml: return "yaml-language-server"
        }
    }

    /// Every server here is a Node program, but the runtime is named per server
    /// rather than assumed: the day one of them ships a standalone binary, the
    /// change is this property answering `nil` and not a rewrite of the engine.
    public var runtimeComponentID: String {
        switch self {
        case .typescript, .python, .yaml: return "node"
        }
    }

    /// Arguments after the entry point. Every server here speaks LSP over stdio
    /// only when told to; the default for all of them is a socket.
    public var arguments: [String] { ["--stdio"] }

    /// D11: the `typescript` copy this server should drive *when the project has
    /// none of its own*, relative to the server component's version directory.
    /// `nil` for a server with nothing to point at.
    ///
    /// It becomes `initializationOptions.tsserver.fallbackPath`, and the choice of
    /// key is the whole of D11's "a project with its own `node_modules/typescript`
    /// still wins". `typescript-language-server` resolves in a fixed order —
    /// `tsserver.path`, then the workspace's `node_modules/typescript/lib`, then
    /// `tsserver.fallbackPath`, then whatever `require.resolve('typescript')`
    /// finds from its own install — so naming the pinned copy under `path` would
    /// override the workspace copy for every project, and a repository pinned to
    /// TypeScript 4.x would be analysed by 5.9.3 with no way to say otherwise.
    /// Under `fallbackPath` the pinned copy is what a project without one gets,
    /// which is what it is for.
    public var tsserverSubpath: String? {
        switch self {
        case .typescript: return "node_modules/typescript/lib/tsserver.js"
        case .python, .yaml: return nil
        }
    }

    /// The settings this server takes on its **configuration** channels, keyed by
    /// the section it asks for — `LSPServerDescription.configuration`, carried
    /// onto the description below and delivered by `LSPSession`.
    ///
    /// `nil` for every server but the YAML one, which is the statement that their
    /// handshakes are byte-for-byte what they were.
    ///
    /// The YAML server pulls `workspace/configuration` for `yaml`, `http`,
    /// `[yaml]`, `editor` and `files` on `initialized`, **unconditionally** —
    /// whatever the client advertised — and its `onDidChangeConfiguration` handler
    /// ignores the pushed payload and re-pulls. That is a fact about the pinned
    /// 1.24.0 bundle rather than a hope about the protocol, which is what pinning
    /// is for. So the value below is what the answer to that pull is built from,
    /// and only the `yaml` section is named: the other four are answered `null`,
    /// exactly as they would be with no configuration at all.
    ///
    /// `schemaStore.enable` is stated rather than left to upstream's default —
    /// which happens to be `true`, so schemas would load by luck. It is the
    /// setting that makes a `docker-compose.yml` complete `services` at all, and a
    /// default that flips in a later pin would take completion with it silently.
    public var configuration: JSONValue? {
        switch self {
        case .typescript, .python: return nil
        case .yaml:
            return .object([
                "yaml": .object([
                    "schemaStore": .object(["enable": .bool(true)]),
                    "completion": .bool(true),
                    "hover": .bool(true),
                ])
            ])
        }
    }

    /// The one sentence about traffic this layer does **not** pin, or `nil` for a
    /// server whose network use ends when its download does.
    ///
    /// Data on the server rather than copy in a view, for the same reason
    /// `displayName` is: the download banner and the Settings row say the same
    /// thing about the same server because there is one thing to say, written
    /// once. A view that composed its own sentence would be a second place for
    /// this fact to be wrong, and the fact is a promise about the user's network.
    ///
    /// **The stated exception to "what may be downloaded is pinned data."** The
    /// YAML server resolves a document's schema over the network while it runs —
    /// that is what knows `services` belongs in a `docker-compose.yml`, and no
    /// pinned byte in this manifest could contain it — so consenting to this
    /// server consents to that traffic too. It is therefore said where consent is
    /// given, not only in the docs: `LSPConsentPrompt` and `LSPServerRow` both
    /// carry it (`LSPProvisioning.swift`).
    ///
    /// **The sentence names more than schemastore.org, because the traffic does.**
    /// Only the *catalog* comes from that one host; each schema then comes from
    /// whichever host its catalog entry names (most of the catalog's entries point
    /// at `raw.githubusercontent.com`, and the compose schema is one of them). And
    /// a YAML file may name its own schema URL in a header comment
    /// (`# yaml-language-server: $schema=…`, `modelineUtil.js` in the pinned
    /// bundle), so *opening a file from an untrusted repository* is enough to
    /// direct one of these requests at a host that file chose. A user who
    /// consented on the strength of one domain name would have been told something
    /// narrower than the truth, and consent here is asked once and never again.
    ///
    /// It is *not* a second install: nothing lands under the install root, so
    /// Remove and a deleted `LanguageServers` directory still de-provision
    /// completely (D12).
    public var runtimeNetworkNote: String? {
        switch self {
        case .typescript, .python: return nil
        case .yaml:
            return """
                This server also fetches JSON schemas while it runs: a catalog from \
                schemastore.org, then each schema from the host that catalog names — or \
                the one a file's own "# yaml-language-server: $schema=" line names. That \
                is what completes a docker-compose.yml against its real schema, and none \
                of it is part of the pinned download.
                """
        }
    }

    /// The registry entry this server becomes once installed — the whole reason
    /// the manifest exists.
    ///
    /// `nil` when the manifest does not describe the server (a hand-edited
    /// manifest, and nothing else: the manifest tests assert `.standard` resolves
    /// both). Answering `nil` rather than trapping keeps a malformed manifest a
    /// *missing server* — the language falls back to tree-sitter, silently, which
    /// is what every other failure in this layer does.
    ///
    /// Note what this does **not** do: check that anything is on disk. It is pure
    /// path math over the manifest, so it is testable without a file system; the
    /// model only calls it for components the engine reports installed.
    public func serverDescription(
        manifest: LSPProvisioningManifest,
        layout: LSPInstallLayout
    ) -> LSPServerDescription? {
        guard
            let server = manifest.component(serverComponentID),
            let runtime = manifest.component(runtimeComponentID),
            let runtimeExecutable = runtime.executableSubpath,
            let entrySubpath = server.executableSubpath
        else { return nil }

        let node = layout.file(runtimeExecutable, of: runtime)
        let entry = layout.file(entrySubpath, of: server)

        var options: JSONValue?
        if let tsserverSubpath {
            options = .object([
                "tsserver": .object(["fallbackPath": .string(layout.file(tsserverSubpath, of: server).path)])
            ])
        }

        return LSPServerDescription(
            id: serverID,
            languages: languages,
            launch: .executable(path: node.path),
            arguments: [entry.path] + arguments,
            initializationOptions: options,
            configuration: configuration
        )
    }
}
