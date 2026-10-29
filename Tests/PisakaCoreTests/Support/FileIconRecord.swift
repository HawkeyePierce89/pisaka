import Foundation

/// The reader for the icon table of `Resources/FileIcons/VENDORED.md`, shared
/// by the two suites that check the vendored file-icon set against it —
/// `LicenseCoverageTests` (every imageset is acknowledged) and
/// `FileTypeIconAssetTests` (the record lists exactly the cases, with the pinned
/// prefixes, byte counts and light-variant column).
///
/// One reader, two suites, so the record cannot satisfy one of them and drift
/// from the other. The record's two-column `## file-icons` section is read by
/// `MarkdownPreviewVendoredDoc` instead, which skips this four-column table.
enum FileIconRecord {

    /// One row of the `| Icon | Prefix | Bytes | Light variant |` table.
    struct Row: Equatable {
        let name: String
        let prefix: String
        let bytes: Int
        let lightVariant: Bool
    }

    /// Every row whose first cell is a backticked icon name and whose bytes cell
    /// parses as an integer. The header and the separator fail both, so they are
    /// skipped rather than special-cased.
    static func rows(in record: String) -> [Row] {
        record.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // `| a | b | c | d |` splits to six cells with the outer two empty.
            guard cells.count == 6, cells[1].hasPrefix("`"),
                  let bytes = Int(cells[3]) else { return nil }
            return Row(name: unquoted(cells[1]),
                       prefix: unquoted(cells[2]),
                       bytes: bytes,
                       lightVariant: cells[4] == "yes")
        }
    }

    private static func unquoted(_ cell: String) -> String {
        cell.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}
