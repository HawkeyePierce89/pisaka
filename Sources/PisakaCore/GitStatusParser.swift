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
/// - `! <path>` — ignored (skipped)
/// - `# …` — header lines (skipped)
///
/// The path is taken as the unsplit remainder of the line, so paths containing
/// spaces survive intact.
public enum GitStatusParser {
    public static func parse(_ output: String) -> [ChangedFile] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
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
            // `!` ignored entries and `#` header lines are not local changes.
            return nil
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — 8 fixed fields before
    /// the path (which may contain spaces, so it is the unsplit remainder).
    private static func parseOrdinary(_ line: String) -> ChangedFile? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count == 9 else { return nil }
        let path = String(parts[8])
        return ChangedFile(path: path, status: status(forXY: parts[1]))
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
        if parts[1].contains("C") {
            return ChangedFile(path: String(paths[0]), status: .added)
        }
        return ChangedFile(
            path: String(paths[0]),
            status: .renamed,
            oldPath: String(paths[1])
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

    /// `? <path>` / `! <path>` — record type then the path remainder.
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
