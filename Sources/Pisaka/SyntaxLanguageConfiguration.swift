#if os(macOS) || os(iOS)
import Foundation
import SwiftTreeSitter
import PisakaCore

// Grammar packages (Pisaka target only — never PisakaCore or tests). Each
// exposes a C `tree_sitter_<name>()` entry point plus a bundled
// `queries/highlights.scm`, loaded by `LanguageConfiguration` from the SPM
// resource bundle (`TreeSitter<Name>_TreeSitter<Name>.bundle`).
import TreeSitterSwift
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterPython
import TreeSitterHTML
import TreeSitterCSS
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterYAML
import TreeSitterDockerfile
import TreeSitterDotenv
// Vendored locally (`Vendor/TreeSitterGitignore`) — upstream ships neither a
// Swift binding nor highlight queries; see that package's `VENDORED.md`. It is
// packaged exactly like the remote grammars, so its resource bundle follows the
// same `TreeSitter<Name>_TreeSitter<Name>` convention.
import TreeSitterGitignore

/// Maps a semantic `SyntaxLanguage` (PisakaCore) to a concrete tree-sitter
/// `LanguageConfiguration` (grammar parser + bundled highlight queries).
///
/// This is the view-layer bridge that keeps the grammar/Neon wiring out of
/// `PisakaCore`. Configurations are loaded lazily and cached, since loading
/// compiles the bundled `.scm` queries — work we don't want to repeat on every
/// tab switch.
///
/// `configuration(for:)` returns `nil` when a grammar bundle or its queries
/// can't be loaded, so a packaging failure degrades to plain text rather than
/// crashing the editor.
///
/// This type is **not** `@MainActor`-isolated: Neon resolves injected
/// sub-languages by invoking the configuration's `languageProvider` on its
/// background processor queue (see `BackgroundProcessor`), so
/// `configuration(forInjectionName:)` — and the `configuration(for:)` it calls —
/// can run off the main actor. The cache mutations are therefore guarded by a
/// lock so overlapping highlighters can't corrupt the dictionaries from
/// different threads. Building a `LanguageConfiguration` (loading the grammar +
/// compiling queries) off the main thread is safe — Neon itself constructs its
/// parsers on background queues.
enum SyntaxLanguageConfiguration {
    /// Guards `cache` and `injectionCache`. Held only across the dictionary
    /// read/write, never across a configuration build or a reentrant call, so
    /// the non-recursive `NSLock` can't deadlock (a racing build may happen
    /// twice; both results are valid and the last write wins).
    private static let cacheLock = NSLock()
    private static var cache: [SyntaxLanguage: LanguageConfiguration] = [:]

    /// The loaded configuration for `language`, or `nil` if its grammar/queries
    /// fail to load. Results are cached after the first successful load.
    static func configuration(for language: SyntaxLanguage) -> LanguageConfiguration? {
        if let cached = cacheLock.withLock({ cache[language] }) {
            return cached
        }
        guard let configuration = try? makeConfiguration(for: language) else {
            return nil
        }
        cacheLock.withLock { cache[language] = configuration }
        return configuration
    }

    /// Builds a fresh configuration for `language`. The `name:` passed to
    /// `LanguageConfiguration` must match the grammar's SPM resource bundle,
    /// which follows the `TreeSitter<name>_TreeSitter<name>` convention.
    private static func makeConfiguration(for language: SyntaxLanguage) throws -> LanguageConfiguration {
        switch language {
        case .swift:
            return try LanguageConfiguration(tree_sitter_swift(), name: "Swift")
        case .javascript:
            return try LanguageConfiguration(tree_sitter_javascript(), name: "JavaScript")
        case .typescript:
            return try makeTypeScriptConfiguration()
        case .json:
            return try LanguageConfiguration(tree_sitter_json(), name: "JSON")
        case .markdown:
            return try LanguageConfiguration(tree_sitter_markdown(), name: "Markdown")
        case .python:
            return try LanguageConfiguration(tree_sitter_python(), name: "Python")
        case .html:
            return try LanguageConfiguration(tree_sitter_html(), name: "HTML")
        case .css:
            return try LanguageConfiguration(tree_sitter_css(), name: "CSS")
        case .yaml:
            return try LanguageConfiguration(tree_sitter_yaml(), name: "YAML")
        case .dockerfile:
            return try LanguageConfiguration(tree_sitter_dockerfile(), name: "Dockerfile")
        case .dotenv:
            return try LanguageConfiguration(tree_sitter_dotenv(), name: "Dotenv")
        case .gitignore:
            return try LanguageConfiguration(tree_sitter_gitignore(), name: "Gitignore")
        }
    }

    /// Builds the TypeScript configuration with the JavaScript highlight queries
    /// composed in as a base layer.
    ///
    /// The TypeScript grammar's bundled `highlights.scm` carries only
    /// TypeScript-specific captures (types, parameter/member modifiers, TS-only
    /// keywords). Comments, strings, numbers, functions, operators, and the
    /// common keywords live in the JavaScript grammar's highlights, which the
    /// TypeScript grammar is a superset of. Without composing them, ordinary
    /// JavaScript syntax in a `.ts`/`.tsx` file renders as plain text.
    ///
    /// JavaScript patterns are placed first so the TypeScript-specific ones that
    /// follow take precedence on overlapping nodes. If either bundle's queries
    /// can't be read or the merged query fails to compile, this degrades to the
    /// TypeScript-only configuration rather than failing.
    private static func makeTypeScriptConfiguration() throws -> LanguageConfiguration {
        let language = Language(tree_sitter_typescript())
        let base = try LanguageConfiguration(language, name: "TypeScript")

        guard
            let jsHighlights = highlightsQueryData(
                bundleNamed: "TreeSitterJavaScript_TreeSitterJavaScript"
            ),
            let tsHighlights = highlightsQueryData(
                bundleNamed: "TreeSitterTypeScript_TreeSitterTypeScript"
            )
        else {
            return base
        }

        var merged = jsHighlights
        merged.append(Data("\n".utf8))
        merged.append(tsHighlights)

        guard let mergedQuery = try? Query(language: language, data: merged) else {
            return base
        }

        var queries = base.queries
        queries[.highlights] = mergedQuery
        return LanguageConfiguration(language, name: "TypeScript", queries: queries)
    }

    /// Resolves a configuration for a sub-language referenced by a tree-sitter
    /// injection (e.g. Markdown's `(#set! injection.language "markdown_inline")`,
    /// fenced code blocks, embedded HTML/YAML). Returns `nil` for languages we
    /// don't support, leaving that injected content as plain text.
    static func configuration(forInjectionName name: String) -> LanguageConfiguration? {
        let normalized = name.lowercased()

        if normalized == "markdown_inline" || normalized == "markdown.inline" {
            return markdownInlineConfiguration()
        }

        // Fenced code / embedded blocks reference languages by name or extension
        // (e.g. "swift", "js", "py"); resolve through the same map the editor uses.
        if let language = SyntaxLanguage(rawValue: normalized)
            ?? SyntaxLanguage(fileExtension: normalized) {
            return configuration(for: language)
        }

        return nil
    }

    /// The Markdown inline grammar (emphasis, strong, links, code spans), cached
    /// after first load. Its SPM bundle doesn't follow the `TreeSitter\(name)_…`
    /// convention (it ships inside the block grammar's package), so the bundle
    /// name is supplied explicitly.
    private static func markdownInlineConfiguration() -> LanguageConfiguration? {
        if let cached = cacheLock.withLock({ injectionCache["markdown_inline"] }) {
            return cached
        }
        guard let configuration = try? LanguageConfiguration(
            tree_sitter_markdown_inline(),
            name: "markdown_inline",
            bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
        ) else {
            return nil
        }
        cacheLock.withLock { injectionCache["markdown_inline"] = configuration }
        return configuration
    }

    private static var injectionCache: [String: LanguageConfiguration] = [:]

    /// Reads the `highlights.scm` data from a grammar's SPM resource bundle.
    ///
    /// Mirrors SwiftTreeSitter's own bundle-path resolution (the `queries`
    /// directory location differs between SwiftPM and Xcode builds).
    private static func highlightsQueryData(bundleNamed bundleName: String) -> Data? {
        guard let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle") else {
            return nil
        }

        let shortQueries = bundleURL.appendingPathComponent("queries", isDirectory: true)
        let queriesDir = FileManager.default.fileExists(atPath: shortQueries.path)
            ? shortQueries
            : bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true)

        let highlights = queriesDir.appendingPathComponent("highlights.scm")
        return try? Data(contentsOf: highlights)
    }
}

#endif
