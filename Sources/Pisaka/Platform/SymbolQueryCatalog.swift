#if os(macOS) || os(iOS)
import Foundation
import SwiftTreeSitter
import PisakaCore

/// Loads and caches the compiled `symbols.scm` query for each language — the
/// symbol index's counterpart to `SyntaxLanguageConfiguration`, which does the
/// same job for the bundled *highlight* queries.
///
/// Lives in the non-gated `Platform/` layer because both destinations index:
/// `Resources/Queries` is a folder reference, so the directory lands as
/// `Queries/<language>/symbols.scm` inside the built bundle on macOS
/// (`Contents/Resources/Queries/…`) and iOS (`Queries/…` at the `.app` root)
/// alike, and `Bundle` resolves it the same way from either.
///
/// Structurally a copy of `SyntaxLanguageConfiguration` on purpose, for the same
/// three reasons:
/// - **Cached**, because compiling a query is the expensive part (`ts_query_new`
///   parses the whole `.scm` and builds the pattern automata) and the index asks
///   for a language's query once per *file*.
/// - **Not `@MainActor`**, because `SymbolExtractor` runs on `SymbolIndexModel`'s
///   private serial queue. The cache is therefore lock-guarded; the lock is held
///   only across the dictionary read/write, never across a compile, so the
///   non-recursive `NSLock` cannot deadlock (a racing compile may happen twice —
///   both results are valid and the last write wins).
/// - **`nil` on any failure**, so a packaging or compilation problem degrades
///   that language to "no symbols" rather than crashing the editor.
///
/// That last degradation is quieter than the highlighting one it mirrors: a file
/// nothing highlights is visibly plain text, whereas a file nothing indexes looks
/// exactly like a file that declares nothing. `swift test` cannot close the gap —
/// checking that a query *compiles* needs SwiftTreeSitter, which `PisakaCore`
/// deliberately does not link, so `SymbolQueryTests` can only verify the queries
/// statically. The runtime half is this type's `assertionFailure`: in a DEBUG
/// build a missing or uncompilable query traps with the language named, on the
/// first file of that type, instead of silently indexing nothing forever.
enum SymbolQueryCatalog {
    /// The bundle subdirectory the `Resources/Queries` folder reference produces.
    private static let directory = "Queries"

    /// The query file inside each language's directory. Spelled once, exactly as
    /// it appears on disk (no `withExtension:` split — `scm` is part of the name
    /// the folder reference copies).
    private static let queryFileName = "symbols.scm"

    /// Guards `cache` and `unavailable`. See the type's note on why the lock is
    /// never held across a compile.
    private static let cacheLock = NSLock()
    private static var cache: [SyntaxLanguage: Query] = [:]

    /// Languages whose query could not be loaded, remembered so the failure costs
    /// one bundle lookup rather than one per file. Without it a project full of
    /// `.py` files would re-read and re-compile a broken query thousands of times
    /// — and, in DEBUG, trip the assertion on every one of them.
    private static var unavailable: Set<SyntaxLanguage> = []

    /// The compiled symbols query for `language`, or `nil` when the language ships
    /// none (gitignore) or its query cannot be loaded or compiled.
    static func query(for language: SyntaxLanguage) -> Query? {
        let cached = cacheLock.withLock { () -> (query: Query?, known: Bool) in
            if let query = cache[language] { return (query, true) }
            return (nil, unavailable.contains(language))
        }
        if cached.known { return cached.query }

        guard let query = makeQuery(for: language) else {
            cacheLock.withLock { _ = unavailable.insert(language) }
            return nil
        }
        cacheLock.withLock { cache[language] = query }
        return query
    }

    /// Reads and compiles `language`'s query against its grammar.
    ///
    /// Each failure is reported separately in DEBUG because they mean different
    /// things: a missing file is a packaging mistake (the folder reference, or a
    /// query that was never authored), while a compile error is a query that no
    /// longer matches its grammar — the failure mode a grammar bump produces, and
    /// the one `SymbolQueryTests` can only approximate by pinning node names.
    private static func makeQuery(for language: SyntaxLanguage) -> Query? {
        // A language Core declares unindexable ships no query *by design*, so it
        // must not assert. `SymbolIndexModel` already skips these files, but the
        // check is repeated here because this type is also reachable directly.
        guard SymbolIndexModel.isIndexable(language) else { return nil }

        guard
            let url = Bundle.main.url(
                forResource: queryFileName,
                withExtension: nil,
                subdirectory: directory + "/" + language.rawValue
            ),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure(
                "\(directory)/\(language.rawValue)/\(queryFileName) is missing from the app bundle, "
                + "so \(language.rawValue) files will index no symbols."
            )
            return nil
        }

        guard let configuration = SyntaxLanguageConfiguration.configuration(for: language) else {
            // The grammar itself failed to load, which already degrades the file
            // to plain text; the highlighting path owns that failure, so this one
            // stays silent rather than asserting twice for one cause.
            return nil
        }

        do {
            return try Query(language: configuration.language, data: data)
        } catch {
            assertionFailure(
                "\(directory)/\(language.rawValue)/\(queryFileName) does not compile against the "
                + "\(language.rawValue) grammar (\(error)), so those files will index no symbols."
            )
            return nil
        }
    }
}

#endif
