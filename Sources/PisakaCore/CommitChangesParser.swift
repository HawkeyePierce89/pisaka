import Foundation

/// Pure parser for `git diff-tree --name-status` output (a commit's changed files
/// against its first parent), producing the same `[ChangedFile]` the Local Changes
/// view uses.
///
/// Mirrors `GitStatusParser`'s shape — a side-effect-free `static func parse(_:)`
/// over raw git output, unit-tested in Core, while the `Process` invocation that
/// produces the output lives in `GitCLIService`.
///
/// ## Output format
///
/// The service runs `git diff-tree --no-commit-id --name-status -r -M -m
/// --first-parent --root <hash>`, one record per line:
///
/// - `M\t<path>` — modified (also `T`, a type change, mapped to `.modified`).
/// - `A\t<path>` — added.
/// - `D\t<path>` — deleted.
/// - `R<score>\t<oldPath>\t<newPath>` — renamed (`oldPath` carried through).
/// - `C<score>\t<oldPath>\t<newPath>` — copied. The source is untouched, so only
///   the new path is reported, as `.added` with no `oldPath` (matching
///   `GitStatusParser`'s copy handling).
///
/// Fields are TAB-separated, so paths containing spaces survive intact. A trailing
/// CR (CRLF line endings) is stripped; blank lines and records with too few fields
/// are skipped. Empty output yields `[]`.
public enum CommitChangesParser {
    public static func parse(_ output: String) -> [ChangedFile] {
        // Split on any newline. `Character.isNewline` treats a CRLF pair as the one
        // grapheme cluster it is, so it splits cleanly without leaving a trailing
        // CR on the line — unlike `split(separator: "\n")`, which would miss the
        // `\r\n` grapheme entirely.
        output
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> ChangedFile? {
        guard !line.isEmpty else { return nil }

        let fields = line.components(separatedBy: "\t")
        guard let code = fields.first?.first else { return nil }

        switch code {
        case "M", "T":
            guard fields.count >= 2 else { return nil }
            return ChangedFile(path: fields[1], status: .modified)
        case "A":
            guard fields.count >= 2 else { return nil }
            return ChangedFile(path: fields[1], status: .added)
        case "D":
            guard fields.count >= 2 else { return nil }
            return ChangedFile(path: fields[1], status: .deleted)
        case "R":
            guard fields.count >= 3 else { return nil }
            return ChangedFile(path: fields[2], status: .renamed, oldPath: fields[1])
        case "C":
            // A copy leaves the source untouched, so report only the new path as a
            // plain addition (no `oldPath`) — same as `GitStatusParser`.
            guard fields.count >= 3 else { return nil }
            return ChangedFile(path: fields[2], status: .added)
        default:
            return nil
        }
    }
}
