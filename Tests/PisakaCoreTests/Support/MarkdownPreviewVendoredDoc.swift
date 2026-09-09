import Foundation

/// The reader for `Resources/MarkdownPreview/VENDORED.md`, shared by the two
/// suites that check the preview's bundled assets against it —
/// `MarkdownPreviewAssetPinTests` (the bytes) and `LicenseCoverageTests` (the
/// notice's version and revision).
///
/// It exists because that document is the *record* for two files nothing in the
/// build relates to anything: the bundles are copied into the app as a folder
/// reference, so a stale version line, a wrong commit or a re-downloaded file
/// produce a green build and a shipping app whose acknowledgements name a
/// release it does not carry. One reader, two suites, so the document cannot
/// satisfy one of them and drift from the other.
///
/// The shape it reads is deliberately the one a person writes: a `## <name>`
/// heading per asset, and under it a two-column table whose left cell is a field
/// name (`Version`, `Commit`, `File`, `Bytes`, `SHA-256`) and whose right cell is
/// that field's value, backticks trimmed. Any other section — the prose, the
/// scope list, the update procedure — is skipped, so the document stays readable
/// rather than becoming a data file with headings.
enum MarkdownPreviewVendoredDoc {

    /// One `## <name>` section's fields, keyed by the left-hand cell.
    struct Section {
        let name: String
        let fields: [String: String]

        /// A field, or `nil` where the section does not state it. `nil` rather
        /// than `""`: a missing row and an empty one are the same mistake, and
        /// both must fail the caller's `XCTUnwrap` rather than compare equal to
        /// something.
        func value(_ field: String) -> String? {
            guard let value = fields[field], !value.isEmpty else { return nil }
            return value
        }
    }

    /// Every `## ` section of the document that carries at least one table row,
    /// keyed by its heading text.
    ///
    /// Keyed by heading because the two asset sections are named exactly as their
    /// `licenses.json` ids (`highlight.js`, `mermaid`) — one name for the
    /// document, the manifest and the pin table, so no third mapping exists to
    /// get wrong.
    static func sections(in document: String) -> [String: Section] {
        var sections: [String: Section] = [:]
        var name: String?
        var fields: [String: String] = [:]

        func flush() {
            if let name, !fields.isEmpty {
                sections[name] = Section(name: name, fields: fields)
            }
            fields = [:]
        }

        for line in document.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## ") {
                flush()
                name = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // A `# ` heading closes whatever section was open without opening
            // one: the document's title is not an asset.
            if trimmed.hasPrefix("# ") {
                flush()
                name = nil
                continue
            }

            guard trimmed.hasPrefix("|") else { continue }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // `| a | b |` splits to ["", "a", "b", ""] — exactly two fields
            // between the outer pipes, so a three-column table (the size table
            // at the top of the document) is skipped rather than half-read.
            guard cells.count == 4 else { continue }

            let key = unquoted(cells[1])
            let value = unquoted(cells[2])
            guard !key.isEmpty, !value.isEmpty, key != "---", value != "---" else { continue }
            fields[key] = value
        }
        flush()

        return sections
    }

    /// A cell's value with the backticks a Markdown table wraps a literal in
    /// removed, so `` `11.11.1` `` and `11.11.1` are the same value.
    private static func unquoted(_ cell: String) -> String {
        cell.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            .trimmingCharacters(in: .whitespaces)
    }
}
