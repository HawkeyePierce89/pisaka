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
    public static let standard = LSPProvisioningManifest(components: [.node, .typescriptLanguageServer, .pyright])
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

/// How an artifact is packed. One case today, and a case rather than a `Bool`
/// because the unpack seam takes the format as an argument and a second one
/// (a `.zip` for a server that ships no tarball) must be a compile error at every
/// call site rather than a silently wrong `false`.
public enum LSPArchiveFormat: String, Equatable, Sendable {
    case tarGzip
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
    /// Every artifact here is 1: a Node tarball wraps everything in
    /// `node-v…-darwin-arm64/`, an npm tarball in `package/`.
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

    /// SPDX identifier for everything this component ships. One id per component
    /// because each one's artifacts happen to agree; a component whose artifacts
    /// disagreed would have to be split, which is the honest outcome anyway.
    public let licenseSPDXID: String

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
        licenseSPDXID: String,
        licenseFileSubpaths: [String],
        artifacts: [LSPArtifact],
        requires: [String] = [],
        executableSubpath: String? = nil
    ) {
        self.id = id
        self.version = version
        self.licenseSPDXID = licenseSPDXID
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
        licenseSPDXID: "MIT",
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
        licenseSPDXID: "Apache-2.0",
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
        licenseSPDXID: "MIT",
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
        }
    }

    /// Never contains `.swift`: sourcekit-lsp is found through `xcrun` and is not
    /// something this layer provisions, replaces or can interfere with.
    public var languages: Set<SyntaxLanguage> {
        switch self {
        case .typescript: return [.typescript, .javascript]
        case .python: return [.python]
        }
    }

    public var serverComponentID: String {
        switch self {
        case .typescript: return "typescript-language-server"
        case .python: return "pyright"
        }
    }

    /// Every server here is a Node program, but the runtime is named per server
    /// rather than assumed: the day one of them ships a standalone binary, the
    /// change is this property answering `nil` and not a rewrite of the engine.
    public var runtimeComponentID: String {
        switch self {
        case .typescript, .python: return "node"
        }
    }

    /// Arguments after the entry point. Both servers speak LSP over stdio only
    /// when told to; the default for both is a socket.
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
        case .python: return nil
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
            initializationOptions: options
        )
    }
}
