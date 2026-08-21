import Foundation

/// Everything the app needs to know to *start* one language server, and nothing
/// about how to talk to it (D9).
///
/// The whole point of the type is that adding a server is a data change. Phase 2b
/// adds TypeScript and Python by appending two of these to `LSPServerRegistry`;
/// no client code moves, because nothing above this file knows the word
/// "sourcekit". `LSPWorkspaceTests` pins that promise by serving a second,
/// entirely fictional server through configuration alone.
///
/// The launch method is a *description*, not a resolution: Core cannot spawn a
/// process, and `xcrun` is not a thing a Foundation-only library may run. Turning
/// `.toolchainTool(name:)` into an executable path is the app's job
/// (`LSPToolchain`, task 8), which keeps this value type comparable, encodable and
/// testable without an Xcode installation anywhere in sight.
public struct LSPServerDescription: Equatable, Hashable, Sendable, Identifiable {
    /// How the executable is found.
    public enum Launch: Equatable, Hashable, Sendable {
        /// A tool inside the active Xcode/Swift toolchain, resolved with
        /// `xcrun --find <name>` (honouring `DEVELOPER_DIR`). This is
        /// sourcekit-lsp: it ships with Xcode, its path moves with the selected
        /// toolchain, and hard-coding one would break the moment someone runs
        /// `xcode-select`.
        case toolchainTool(name: String)
        /// An absolute path to an executable — what 2b's `typescript-language-server`
        /// will use once the app grows a way to point at one.
        case executable(path: String)
    }

    /// Stable identifier, and half of the `(server, root)` key `LSPWorkspace`
    /// counts failures against. Never shown to anyone.
    public let id: String

    /// The languages this server answers for. A `Set` because a real server often
    /// serves several (`typescript-language-server` covers JS and TS), and because
    /// the registry's language→server map is built from it.
    public let languages: Set<SyntaxLanguage>

    public let launch: Launch

    /// Arguments after the executable. sourcekit-lsp needs none; a node-based
    /// server needs `--stdio`.
    public let arguments: [String]

    /// Passed through verbatim as `initialize`'s `initializationOptions`. Opaque
    /// on purpose: it is *this server's* configuration, and Core has no business
    /// having an opinion about its shape.
    public let initializationOptions: JSONValue?

    /// The server's own settings, keyed by the configuration *section* it asks
    /// for — `{"yaml": {…}}` for a server that pulls the `yaml` section.
    ///
    /// Opaque for the same reason as `initializationOptions`: it is *that
    /// server's* configuration, and Core has no opinion about its shape. The two
    /// are not interchangeable, though — `initializationOptions` travels once,
    /// inside `initialize`, while this value answers the two channels a server
    /// may take settings on afterwards (`LSPSession.start`, which sends
    /// `workspace/didChangeConfiguration` and answers `workspace/configuration`
    /// out of it, section by section).
    ///
    /// `nil` for every server that needs none, which is all of them but the YAML
    /// one — and `nil` is not merely a default here but the statement that the
    /// handshake is byte-for-byte what it was: no notification is sent and every
    /// pulled section is still answered `null`.
    public let configuration: JSONValue?

    /// Environment variables laid **over** the app's own for this server's
    /// process, empty for almost every server.
    ///
    /// An overlay and never a replacement: a language server resolves its
    /// toolchain, its caches and its build system out of the environment it
    /// inherits, so `LSPProcessTransport` merges these on top of
    /// `ProcessInfo.processInfo.environment` rather than assigning them
    /// (`GitCLIService.run`'s reasoning, one level down). Empty for sourcekit-lsp
    /// (`xcrun`/`DEVELOPER_DIR` already answer), for
    /// `typescript-language-server` and for pyright (launched as an absolute-path
    /// `node` plus an absolute-path script, resolving nothing off `PATH`).
    ///
    /// It exists for gopls, which is the one server so far that looks a *second*
    /// executable up on `PATH` — see `LSPGoToolchainReport.found`'s `searchPath`.
    /// Carried on the description rather than resolved at launch because the
    /// value is machine-specific knowledge D9 keeps out of Core: the app finds it
    /// and puts it here, and Core only passes it along.
    public let environment: [String: String]

    public init(
        id: String,
        languages: Set<SyntaxLanguage>,
        launch: Launch,
        arguments: [String] = [],
        initializationOptions: JSONValue? = nil,
        configuration: JSONValue? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.languages = languages
        self.launch = launch
        self.arguments = arguments
        self.initializationOptions = initializationOptions
        self.configuration = configuration
        self.environment = environment
    }

    /// The one server phase 2a ships.
    ///
    /// No `initializationOptions`: sourcekit-lsp discovers the build system from
    /// the root it is initialized with (a `Package.swift`, a `compile_commands.json`,
    /// an `.xcodeproj` via the build server protocol), and every option worth
    /// setting has a working default. A project it cannot make sense of answers
    /// nothing, which is exactly the case the routing provider falls back for.
    public static let sourcekitLSP = LSPServerDescription(
        id: "sourcekit-lsp",
        languages: [.swift],
        launch: .toolchainTool(name: "sourcekit-lsp")
    )
}

/// Which server answers for which language (D9).
///
/// A struct rather than a global: the app builds the real one, and a test builds
/// a registry of fakes without touching it. The language→description map is
/// resolved once at construction, so the lookup on the request path is a single
/// dictionary hit.
///
/// **First registration wins** when two descriptions claim the same language.
/// Arbitrary but stated, and it makes the composition order meaningful: a caller
/// that wants to override a stock server puts theirs first rather than having to
/// remove ours.
public struct LSPServerRegistry: Equatable, Sendable {
    public let descriptions: [LSPServerDescription]
    private let byLanguage: [SyntaxLanguage: LSPServerDescription]

    public init(_ descriptions: [LSPServerDescription]) {
        self.descriptions = descriptions
        var map: [SyntaxLanguage: LSPServerDescription] = [:]
        for description in descriptions {
            for language in description.languages where map[language] == nil {
                map[language] = description
            }
        }
        byLanguage = map
    }

    /// The registry the app runs with: one server, one language.
    public static let standard = LSPServerRegistry([.sourcekitLSP])

    /// No servers at all — what a platform with no language server (iOS) and a
    /// good many tests want. Every lookup answers `nil`, so routing degrades to
    /// tree-sitter for everything without a special case anywhere.
    public static let empty = LSPServerRegistry([])

    public func description(for language: SyntaxLanguage) -> LSPServerDescription? {
        byLanguage[language]
    }

    public func servesLanguage(_ language: SyntaxLanguage) -> Bool {
        byLanguage[language] != nil
    }

    public var servedLanguages: Set<SyntaxLanguage> { Set(byLanguage.keys) }
}

extension SyntaxLanguage {
    /// The `languageId` LSP names this language by, sent with every `didOpen`.
    ///
    /// A server keys its parser off this string, so it is the *protocol's*
    /// spelling and not our raw value — which is why it is a `switch` rather than
    /// `rawValue`: a language added to the enum must be spelled here deliberately,
    /// and the compiler is what enforces that.
    ///
    /// Most cases are the spec's own identifiers. Two are not in that list and are
    /// spelled the way editors have settled on: `.dotenv` (no server speaks it;
    /// present only so the mapping is total) and `.gitignore` → `"ignore"`, the id
    /// VS Code uses for the whole gitignore family.
    public var lspLanguageID: String {
        switch self {
        case .swift: return "swift"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .json: return "json"
        case .markdown: return "markdown"
        case .python: return "python"
        case .go: return "go"
        case .rust: return "rust"
        case .html: return "html"
        case .css: return "css"
        case .yaml: return "yaml"
        case .dockerfile: return "dockerfile"
        case .dotenv: return "dotenv"
        case .gitignore: return "ignore"
        case .sql: return "sql"
        }
    }

    /// The `languageId` for one *document*, which for the JS/TS family is not
    /// decided by the language alone.
    ///
    /// `SyntaxLanguage` deliberately collapses `.tsx` into `.typescript` and
    /// `.jsx` into `.javascript` — one grammar, one keyword list, one symbols
    /// query — but LSP names those `typescriptreact`/`javascriptreact`, and
    /// `typescript-language-server` passes the id straight through to tsserver as
    /// a script kind (`mode2ScriptKind`, verified in the pinned 5.3.0 bundle). It
    /// corrects a bad id only when the id is not a mode it knows, so
    /// `"typescript"` on a `.tsx` file is *not* corrected: tsserver opens it as
    /// `ScriptKind.TS`, whose language variant parses no JSX. Every completion and
    /// definition inside the JSX half of the file then comes back wrong — and
    /// comes back **answered**, which is the one failure
    /// `RoutingIntelligenceProvider` cannot fall back from, since a wrong answer
    /// is indistinguishable from a right one at that seam.
    ///
    /// `.jsx` is harmless either way (tsserver's `ScriptKind.JS` already parses
    /// JSX), and is spelled here for the same reason the rest of this mapping is
    /// a `switch`: the protocol's spelling, stated deliberately.
    public func lspLanguageID(forFileNamed fileName: String) -> String {
        switch (self, (fileName as NSString).pathExtension.lowercased()) {
        case (.typescript, "tsx"): return "typescriptreact"
        case (.javascript, "jsx"): return "javascriptreact"
        default: return lspLanguageID
        }
    }
}
