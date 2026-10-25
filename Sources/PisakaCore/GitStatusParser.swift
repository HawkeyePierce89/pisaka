import Foundation

/// Pure parser for `git status --porcelain=v2` output.
///
/// Foundation-only and side-effect-free, so the off-by-one-prone field/path
/// splitting is unit-tested in Core; the `Process` invocation that produces the
/// output lives in `GitCLIService` (the `Pisaka` view target).
///
/// Porcelain v2 grammar (the records we care about):
/// - `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — ordinary change
/// - `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>` —
///   rename/copy (in the default, non `-z`, format the new and old paths are
///   TAB-separated)
/// - `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` — unmerged
///   (merge-conflict) entry: 10 fixed fields before the path
/// - `? <path>` — untracked
/// - `! <path>` — ignored: dropped by `parse`, carried separately by
///   `parseSnapshot` (a directory record's trailing `/` stripped)
/// - `# …` — header lines (skipped)
///
/// The path is taken as the unsplit remainder of the line, so paths containing
/// spaces survive intact.
///
/// Two entry points read the same grammar. `parse` answers the changed-file list
/// alone, and its output does not depend on whether `!` records are present, so
/// every caller that predates the snapshot reads exactly what it always did.
/// `parseSnapshot` answers that same list plus the ignored paths beside it — never
/// mixed into it, because an ignored path is not a local change and the Local
/// Changes panel, the commit dialog and the revert all read the list.
///
/// `hH` — the object name of the file in `HEAD` — is carried as
/// `ChangedFile.headObject` for `1` and `2` records (for a copy, the source's,
/// since that is what the record names). `?` and `u` records leave it `nil`: an
/// untracked file has no `HEAD` side, and an unmerged record names three stage
/// objects rather than one `HEAD` object.
public enum GitStatusParser {
    public static func parse(_ output: String) -> [ChangedFile] {
        parseSnapshot(output).changedFiles
    }

    /// The changed-file list `parse` answers, plus every `! <path>` record as a
    /// repo-relative path in output order. git reports a wholly ignored directory
    /// as one record ending in `/`; the slash is stripped so the list holds plain
    /// paths, and a reader treats each one as a prefix of everything below it.
    public static func parseSnapshot(_ output: String) -> GitStatusSnapshot {
        var changedFiles: [ChangedFile] = []
        var ignoredPaths: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "!" {
                if let path = parseIgnored(line) { ignoredPaths.append(path) }
            } else if let file = parseLine(String(line)) {
                changedFiles.append(file)
            }
        }
        return GitStatusSnapshot(changedFiles: changedFiles, ignoredPaths: ignoredPaths)
    }

    /// `! <path>` — the path remainder, with a directory record's one trailing
    /// `/` removed. A record with no path, or whose path is only the slash, is
    /// dropped rather than producing an empty key that would read as the
    /// repository root.
    private static func parseIgnored(_ line: Substring) -> String? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        var path = parts[1]
        if path.hasSuffix("/") { path = path.dropLast() }
        return path.isEmpty ? nil : String(path)
    }

    private static func parseLine(_ line: String) -> ChangedFile? {
        guard let recordType = line.first else { return nil }
        switch recordType {
        case "1":
            return parseOrdinary(line)
        case "2":
            return parseRename(line)
        case "u":
            return parseUnmerged(line)
        case "?":
            return parseSingle(line, status: .untracked)
        default:
            // `#` header lines are not local changes; `!` ignored entries never
            // reach here (`parseSnapshot` routes them to `parseIgnored`).
            return nil
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — 8 fixed fields before
    /// the path (which may contain spaces, so it is the unsplit remainder).
    private static func parseOrdinary(_ line: String) -> ChangedFile? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { return nil }
        let path = String(parts[8])
        return ChangedFile(path: path, status: status(forXY: parts[1]), headObject: String(parts[6]))
    }

    /// `2 <XY> … <X><score> <newPath>\t<oldPath>` — 9 fixed fields before the
    /// `\t`-joined new/old path pair. The record covers both renames (`R`) and
    /// copies (`C`).
    private static func parseRename(_ line: String) -> ChangedFile? {
        let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard parts.count == 10 else { return nil }
        let paths = parts[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard paths.count == 2 else { return nil }
        // A copy (`C` in the `XY` field) leaves its source — the old path — fully
        // intact: only the new file is the change. Treating it as a rename would
        // make a revert restore/`rm` that untouched source and destroy any local
        // changes to it. So map a copy to a plain addition of the *new* path
        // (revert removes just the copy, never the source); only a true rename
        // carries the `oldPath` a revert restores.
        let headObject = String(parts[6])
        if parts[1].contains("C") {
            return ChangedFile(path: String(paths[0]), status: .added, headObject: headObject)
        }
        return ChangedFile(
            path: String(paths[0]),
            status: .renamed,
            oldPath: String(paths[1]),
            headObject: headObject
        )
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` — an unmerged
    /// (merge-conflict) entry: 10 fixed fields before the path (which may contain
    /// spaces, so it is the unsplit remainder).
    private static func parseUnmerged(_ line: String) -> ChangedFile? {
        let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count == 11 else { return nil }
        let path = String(parts[10])
        return ChangedFile(path: path, status: .conflicted)
    }

    /// `? <path>` — record type then the path remainder.
    private static func parseSingle(_ line: String, status: FileStatus) -> ChangedFile? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return ChangedFile(path: String(parts[1]), status: status)
    }

    /// Map a porcelain-v2 two-character `XY` field to a semantic status. `X` is
    /// the staged (index) state, `Y` the unstaged (worktree) state; either may
    /// hold the change, so the more specific kinds win in precedence order.
    private static func status<S: StringProtocol>(forXY xy: S) -> FileStatus {
        if xy.contains("R") || xy.contains("C") { return .renamed }
        if xy.contains("A") { return .added }
        if xy.contains("D") { return .deleted }
        return .modified
    }
}
