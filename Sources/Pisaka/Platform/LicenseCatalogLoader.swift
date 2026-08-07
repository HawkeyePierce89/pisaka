import Foundation
import PisakaCore

/// Reads the bundled license resources and hands their bytes to Core's
/// `LicenseCatalog`.
///
/// Lives in the non-gated `Platform/` layer because both Acknowledgements screens
/// need it and nothing here is platform-specific: `Resources/Licenses` is a folder
/// reference, so the directory lands as `Licenses/` inside the built bundle on
/// both destinations (`Contents/Resources/Licenses/` on macOS, `Licenses/` at the
/// `.app` root on iOS) and `Bundle` resolves it the same way from either.
///
/// Thin glue by design — every decision (what a well-formed manifest is, which
/// defects are fatal, what order the notices come in) stays in `LicenseCatalog`,
/// which deliberately knows nothing about `Bundle`. This type only turns resource
/// URLs into the `Data`/`[file: text]` pair Core asks for, and caches the result
/// once: the texts total a few hundred kilobytes (libgit2's GPLv2-plus-exception
/// alone is 64 KB) and never change at run time, so re-reading them on every
/// selection change in the list would be pure waste.
enum LicenseCatalogLoader {
    /// The bundle subdirectory the folder reference produces.
    private static let directory = "Licenses"
    /// The manifest's file name (no `withExtension:` split — the name is spelled
    /// once, exactly as it appears in `Resources/Licenses/`).
    private static let manifestName = "licenses.json"

    /// The resolved notices in manifest order, or `[]` when the bundle is broken.
    /// Callers that need to explain the emptiness read `failureDescription`.
    static var documents: [LicenseDocument] {
        (try? cached.get()) ?? []
    }

    /// A single user-facing sentence describing why no notices could be loaded, or
    /// `nil` on success. Surfacing it — rather than showing an empty list — is the
    /// whole reason `LicenseCatalogError` is a `LocalizedError`: a bundle that
    /// silently acknowledges nothing is a compliance failure, so it has to say so.
    static var failureDescription: String? {
        guard case .failure(let error) = cached else { return nil }
        // Both error types this can see (`LicenseCatalogError`, `LoaderError`)
        // conform to `LocalizedError`, and Foundation's bridging already routes
        // `localizedDescription` through `errorDescription` for those — no cast.
        return error.localizedDescription
    }

    /// The one-shot cache. A `static let` is lazily initialized exactly once and
    /// its initialization is thread-safe, which is all the synchronization this
    /// needs — the value is immutable afterwards.
    private static let cached = Result { try load() }

    private static func load() throws -> [LicenseDocument] {
        let bundle = Bundle.main
        guard
            let manifestURL = bundle.url(
                forResource: manifestName,
                withExtension: nil,
                subdirectory: directory
            )
        else {
            throw LoaderError.missingManifest
        }

        let manifest = try Data(contentsOf: manifestURL)

        // Read every text in the directory rather than the ones the manifest
        // names: the folder reference copies whatever is on disk, so this keeps
        // the loader out of the business of deciding what *should* be there.
        // `LicenseCatalog.resolve` is what pairs them up and names the id and file
        // of anything the manifest expects and this dictionary lacks.
        var texts: [String: String] = [:]
        for url in bundle.urls(forResourcesWithExtension: "txt", subdirectory: directory) ?? [] {
            // A text that cannot be decoded as UTF-8 is left out on purpose, so it
            // surfaces as Core's `missingText` (which names the id and the file)
            // instead of as an encoding error with no dependency attached.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            texts[url.lastPathComponent] = text
        }

        return try LicenseCatalog.resolve(manifest: manifest, texts: texts)
    }

    /// The one failure this layer can detect that Core cannot: the manifest never
    /// made it into the bundle, so there are no bytes to decode. Everything past
    /// that point is a `LicenseCatalogError`.
    enum LoaderError: Error, LocalizedError {
        case missingManifest

        var errorDescription: String? {
            "The bundled license manifest (\(directory)/\(manifestName)) is missing from the app bundle."
        }
    }
}
