import Foundation

/// The reader for the glyph table of `Resources/DesignGlyphs/VENDORED.md`,
/// shared by the two suites that check the design glyphs against it —
/// `LicenseCoverageTests` (every imageset is acknowledged) and
/// `DesignGlyphAssetTests` (every `nativeSize` is the recorded size).
///
/// One reader, two suites, so the record cannot satisfy one of them and drift
/// from the other. The record's two-column `## design-glyphs` section is read by
/// `MarkdownPreviewVendoredDoc` instead, which skips this four-column table.
enum DesignGlyphRecord {

    /// One row of the `| Glyph | Prefix | Size | MIT notice |` table.
    struct Row: Equatable {
        let name: String
        let prefix: String
        let size: Double
        let mitNotice: Bool
    }

    /// Every row whose first cell is a backticked glyph name and whose size cell
    /// parses as a number. The header and the separator fail both, so they are
    /// skipped rather than special-cased.
    static func rows(in record: String) -> [Row] {
        record.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // `| a | b | c | d |` splits to six cells with the outer two empty.
            guard cells.count == 6, cells[1].hasPrefix("`"),
                  let size = Double(cells[3]) else { return nil }
            return Row(name: unquoted(cells[1]),
                       prefix: unquoted(cells[2]),
                       size: size,
                       mitNotice: cells[4] == "yes")
        }
    }

    private static func unquoted(_ cell: String) -> String {
        cell.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }
}
