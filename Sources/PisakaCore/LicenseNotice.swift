import Foundation

/// One shipped third-party dependency, as recorded in
/// `Resources/Licenses/licenses.json`.
///
/// The manifest — not the Xcode project — is the list of record for what the app
/// must acknowledge: the license texts are copied into the bundle as a folder
/// reference, so nothing in the build knows or checks which dependencies they
/// correspond to. `LicenseCoverageTests` closes that gap statically (the id set
/// must equal what `project.yml` links, each `revision` must equal the
/// `Package.resolved` pin), and this type is what both that test and the
/// Acknowledgements screens read.
public struct LicenseNotice: Codable, Equatable, Identifiable, Sendable {
    /// The dependency's key as `project.yml` spells it (`Neon`, `libgit2`,
    /// `tree-sitter-swift`, …). Doubles as the `Identifiable` id, so it must be
    /// unique across the manifest — `LicenseCatalog` enforces that.
    public let id: String
    /// The display name, which may differ from `id` where the id is a package
    /// key and the name is the upstream project (`tree-sitter-dotenv (vendored)`).
    public let name: String
    /// The upstream URL for a remote package, or the `Vendor/<name>` path for a
    /// vendored one.
    public let origin: String
    /// The upstream release, or `nil` where there is none to name: Neon and
    /// SwiftTreeSitter are revision-pinned past their newest tags, and the
    /// vendored gitignore grammar has no upstream release at all. Optional
    /// rather than an empty string so the UI can omit the row instead of
    /// rendering a blank one.
    public let version: String?
    /// The exact commit the shipped text was copied from — for a remote package
    /// the `Package.resolved` pin, for a vendored one the SHA its `VENDORED.md`
    /// records. This is what makes the text verifiable rather than merely
    /// plausible.
    public let revision: String
    /// The SPDX license *expression* (`MIT`, `BSD-3-Clause`,
    /// `MIT AND Unicode-DFS-2016`).
    ///
    /// A license the SPDX License List does not carry is written as a
    /// `LicenseRef-…` operand rather than invented as a list id — libgit2's
    /// GPLv2-plus-linking-exception has no listed identifier, and `WITH` only
    /// accepts identifiers from SPDX's *exception* list, so spelling it
    /// `GPL-2.0-only WITH linking-exception` would put an expression through the
    /// Acknowledgements screens that no SPDX parser accepts. `LicenseCoverageTests`
    /// enforces that shape over the real manifest.
    public let spdx: String
    /// The text file's name inside `Resources/Licenses/`, resolved against the
    /// bundle by the app layer.
    public let file: String

    public init(
        id: String,
        name: String,
        origin: String,
        version: String?,
        revision: String,
        spdx: String,
        file: String
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.version = version
        self.revision = revision
        self.spdx = spdx
        self.file = file
    }

    /// `origin` as something to open, or `nil` when it is not.
    ///
    /// The decision lives here rather than in the two Acknowledgements screens
    /// because it is one rule, not a per-platform rendering choice: a remote
    /// package's origin is the `https://` URL `Package.resolved` records, and a
    /// vendored one names a `Vendor/<name>` path in this repository, which is not
    /// a link. `https` specifically — an `http://` origin is a downgrade worth
    /// noticing rather than quietly making tappable, and `URL(string:)` alone
    /// would happily accept `file://` or a `javascript:` scheme out of a manifest
    /// this type cannot assume is well-formed.
    public var originURL: URL? {
        guard origin.hasPrefix("https://"), let url = URL(string: origin) else { return nil }
        return url
    }
}

/// A dependency that appears in `Package.resolved` but is deliberately *not*
/// acknowledged, with the reason why.
///
/// Recorded in the manifest rather than left out of it: "no license text ships
/// for this" is indistinguishable from an oversight unless the exclusion is
/// written down. Today the only entry is `swift-argument-parser`, resolved
/// solely for SwiftTerm's `Termcast` executable target and never linked into the
/// app.
public struct LicenseExclusion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// The decoded `licenses.json`: what ships, and what deliberately does not.
public struct LicenseManifest: Codable, Equatable, Sendable {
    public let notices: [LicenseNotice]
    public let excluded: [LicenseExclusion]

    public init(notices: [LicenseNotice], excluded: [LicenseExclusion] = []) {
        self.notices = notices
        self.excluded = excluded
    }

    /// `excluded` is optional in the file — a manifest with nothing to exclude
    /// may simply omit the key rather than carry an empty array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notices = try container.decode([LicenseNotice].self, forKey: .notices)
        excluded = try container.decodeIfPresent([LicenseExclusion].self, forKey: .excluded) ?? []
    }
}

/// A notice paired with the verbatim license text it points at — what the
/// Acknowledgements screens render.
public struct LicenseDocument: Equatable, Identifiable, Sendable {
    public let notice: LicenseNotice
    /// The text exactly as it ships: never truncated, never reflowed. Copyright
    /// lines are part of the obligation.
    public let text: String

    public var id: String { notice.id }

    public init(notice: LicenseNotice, text: String) {
        self.notice = notice
        self.text = text
    }
}

/// Why a license catalog could not be built.
///
/// Every case describes a *shipping* defect rather than a user mistake: the
/// manifest and the texts are repository resources, so any of these means the
/// bundle would silently acknowledge less than it must. `LicenseCoverageTests`
/// catches them in `swift test`; the app layer surfaces the description so a
/// broken bundle says so instead of showing an empty screen.
public enum LicenseCatalogError: Error, Equatable {
    /// The manifest is not the JSON shape `LicenseManifest` describes.
    case malformedManifest(reason: String)
    /// The manifest decoded but lists no dependencies. The app links plenty, so
    /// an empty list is a truncated or wrong file, not an app with no
    /// dependencies.
    case emptyManifest
    /// Two notices share an id, so one of them would be unreachable in a
    /// keyed/`Identifiable` context.
    case duplicateIdentifier(String)
    /// A notice names a text file the caller did not supply — the license did
    /// not make it into the bundle.
    case missingText(id: String, file: String)
    /// The text file exists but is blank (or only whitespace), which
    /// acknowledges nothing.
    case emptyText(id: String, file: String)
}

extension LicenseCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedManifest(let reason):
            return "The bundled license manifest could not be read: \(reason)"
        case .emptyManifest:
            return "The bundled license manifest lists no dependencies."
        case .duplicateIdentifier(let id):
            return "The bundled license manifest lists “\(id)” more than once."
        case .missingText(let id, let file):
            return "The license text for “\(id)” (\(file)) is missing from the app bundle."
        case .emptyText(let id, let file):
            return "The license text for “\(id)” (\(file)) is empty."
        }
    }
}

/// Decodes `licenses.json` and pairs each notice with its license text.
///
/// Deliberately knows nothing about `Bundle` (or any file system): Core stays
/// Foundation-only and testable, and the caller — `LicenseCatalogLoader` in the
/// app's `Platform/` layer — supplies the manifest bytes and a `file name →
/// text` dictionary it read from wherever the resources actually live. That also
/// makes every failure mode above reachable from an in-memory fixture instead of
/// requiring a deliberately-broken bundle.
public enum LicenseCatalog {
    /// Decodes the manifest, rejecting the two structural defects that would
    /// otherwise pass silently: an empty list, and duplicate ids.
    public static func decode(manifest: Data) throws -> LicenseManifest {
        let decoded: LicenseManifest
        do {
            decoded = try JSONDecoder().decode(LicenseManifest.self, from: manifest)
        } catch {
            throw LicenseCatalogError.malformedManifest(reason: error.localizedDescription)
        }

        guard !decoded.notices.isEmpty else { throw LicenseCatalogError.emptyManifest }

        var seen: Set<String> = []
        for notice in decoded.notices {
            guard seen.insert(notice.id).inserted else {
                throw LicenseCatalogError.duplicateIdentifier(notice.id)
            }
        }

        return decoded
    }

    /// Decodes the manifest and attaches each notice's text, keyed by
    /// `LicenseNotice.file`.
    ///
    /// Manifest order is preserved: `licenses.json` lists dependencies in
    /// `project.yml` order, which groups the tree-sitter family together and is
    /// more useful to read than an alphabetical sort the UI could impose anyway.
    public static func resolve(
        manifest: Data,
        texts: [String: String]
    ) throws -> [LicenseDocument] {
        try decode(manifest: manifest).notices.map { notice in
            guard let text = texts[notice.file] else {
                throw LicenseCatalogError.missingText(id: notice.id, file: notice.file)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LicenseCatalogError.emptyText(id: notice.id, file: notice.file)
            }
            return LicenseDocument(notice: notice, text: text)
        }
    }
}
