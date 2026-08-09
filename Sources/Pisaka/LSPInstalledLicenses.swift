#if os(macOS)
import Foundation
import PisakaCore

/// The license texts of whatever is *installed*, read from the installed tree.
///
/// **Why these are not in `Resources/Licenses/`.** Everything in that directory
/// ships inside the app and is pinned by `LicenseCoverageTests`; Node,
/// `typescript-language-server`, `typescript`, `pyright` and `fsevents` ship
/// inside nothing — they arrive later, only if the user asks for them, and they
/// are gone again the moment the user removes them. Checking their texts into
/// the bundle would acknowledge software the app may never have on disk, and
/// would go stale against a pin bump the moment one file was updated and the
/// other forgotten. Reading the verbatim `LICENSE` out of the tree that was
/// actually installed (`LSPComponent.licenseFileSubpaths`, resolved by
/// `LSPInstallLayout`) makes the notice and the code it covers the same bytes,
/// so they cannot disagree.
///
/// One document per *component*, not per file, matching the repository's
/// existing package-granular convention: a component that carries a second
/// package (`typescript` beside its server, `fsevents` beside pyright) has that
/// package's verbatim text appended below a line marking where the first one
/// ends — the same shape `Resources/Licenses/tree-sitter.txt` and `libgit2.txt`
/// already use for the third-party trees they compile in.
///
/// Reads the disk on every call and caches nothing, unlike `LicenseCatalogLoader`
/// — the bundled texts cannot change at run time and these can, twice per
/// install and once per removal. The callers read them into `@State` keyed on the
/// provisioning rows, so a body evaluation costs nothing.
enum LSPInstalledLicenses {
    /// The installed components' notices, in manifest order. Empty when nothing
    /// is installed, which is what makes the Acknowledgements section disappear.
    ///
    /// "Installed" is `isInstalled(_:)` — the *pinned* version on disk — rather
    /// than `state(of:) != .absent`: a stranded tree from an older pin is real
    /// disk that `LSPServerSettingsView` can remove, but the app is not running
    /// it, and acknowledging software one is not shipping or executing would be
    /// noise in the one screen that must be exact.
    @MainActor
    static func documents(engine: LSPInstallEngine) -> [LicenseDocument] {
        engine.manifest.components.compactMap { component in
            guard engine.isInstalled(component.id) else { return nil }
            return document(
                for: component,
                layout: engine.layout,
                architecture: engine.architecture
            )
        }
    }

    /// One component's notice, or `nil` when not one of its license files could
    /// be read.
    ///
    /// A missing or unreadable text is skipped rather than substituted: the
    /// point of this screen is the verbatim text, and "we could not find it" is
    /// better said by its absence from a list than by a placeholder that reads
    /// like a license. It cannot happen for an install this app performed — the
    /// files come out of the same verified tarball as the code — so the only way
    /// here is a hand-edited install root.
    @MainActor
    private static func document(
        for component: LSPComponent,
        layout: LSPInstallLayout,
        architecture: LSPHostArchitecture
    ) -> LicenseDocument? {
        var sections: [String] = []
        for subpath in component.licenseFileSubpaths {
            let url = layout.file(subpath, of: component)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            sections.append(sections.isEmpty ? text : separator(before: subpath) + text)
        }

        guard
            !sections.isEmpty,
            // The artifact for the slice this app is *running as* — the x64 Node
            // tarball on a Rosetta-translated build — so the digest below names
            // the bytes that were actually verified and installed.
            let primary = component.artifacts(for: architecture).first
        else { return nil }

        return LicenseDocument(
            notice: LicenseNotice(
                id: component.id,
                name: component.id,
                origin: primary.url.absoluteString,
                version: component.version,
                // The manifest pins by digest rather than by commit, and the
                // digest is what makes this text verifiable for the same reason
                // a revision does for a checked-in one: it names the exact
                // archive these bytes came out of. Spelled with its algorithm,
                // because the header renders the field as "Revision" and a bare
                // 64 hex characters there would read as a git object id.
                revision: "sha256:\(primary.sha256)",
                spdx: component.licenseSPDXID,
                file: component.licenseFileSubpaths.first ?? ""
            ),
            text: sections.joined(separator: "\n")
        )
    }

    /// The line between one package's verbatim text and the next's, naming what
    /// follows. Worded like the appended notices in `Resources/Licenses/`, so a
    /// reader who has seen one recognizes the other.
    private static func separator(before subpath: String) -> String {
        """


        ----------------------------------------------------------------------

        Everything above this line is the verbatim license of the package named \
        at the top of this entry. The section below is the verbatim license of \
        “\(packageName(in: subpath))”, which is installed alongside it and \
        distributed with it as part of the same component.


        """
    }

    /// The npm package a license subpath belongs to —
    /// `node_modules/typescript/LICENSE.txt` → `typescript`. A subpath with no
    /// `node_modules` segment (Node's own `LICENSE`) answers the subpath itself,
    /// which never reaches the separator because such components carry one file.
    private static func packageName(in subpath: String) -> String {
        let components = subpath.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(of: "node_modules"),
              components.indices.contains(index + 1)
        else { return subpath }
        return components[index + 1]
    }
}

#endif
