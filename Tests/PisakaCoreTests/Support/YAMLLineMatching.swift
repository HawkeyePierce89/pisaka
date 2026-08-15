import Foundation

/// Line matching shared by the suites that read this repository's YAML
/// (`ReleaseMetadataTests` over `project.yml`, `ReleaseWorkflowTests` over
/// `.github/workflows/*.yml`).
///
/// Both need the same two things, and both got them wrong in the same way
/// before this was shared: whole-line equality over *consecutive* lines, so a
/// setting that is merely quoted in a comment cannot satisfy an assertion about
/// the setting being live.
extension Array where Element == String {
    /// Whether `needle`'s lines appear here as a *consecutive* run, each trimmed
    /// line matched whole.
    ///
    /// Whole-line equality is the point: `contains` on the joined text would be
    /// satisfied by a commented-out or merely-quoted setting, which is exactly
    /// the failure these suites exist to catch. Feed this comment-stripped
    /// lines (`activeLines(of:)`) and both halves hold.
    func contains(consecutively needle: String) -> Bool {
        let wanted = needle.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !wanted.isEmpty, count >= wanted.count else { return false }

        return indices.dropLast(wanted.count - 1).contains { start in
            Array(self[start ..< start + wanted.count]) == wanted
        }
    }
}

/// A YAML file's *active* lines: neither blank nor a whole-line comment,
/// trimmed, in file order.
///
/// The workflow and `project.yml` are both heavily commented and their comments
/// quote their own settings verbatim — `# \`ditto -c -k\` and not \`zip\`` sits
/// three lines above the real `ditto` invocation — so a raw `contains` cannot
/// tell a live setting from a described one. Every substring assertion in these
/// suites must run over this, not the raw text.
///
/// Only *whole-line* comments are dropped. A trailing `# v4.3.1` after a pinned
/// action SHA stays, which is wanted: those annotate live lines rather than
/// standing in for them.
func activeYAMLLines(of text: String) -> [String] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// The active lines of a top-level (zero-indent) block: everything indented
/// under `key`, up to the next zero-indent key.
///
/// Returns `nil` when the key is absent at the top level, which callers report
/// as its own failure — "the block is missing" and "the block says the wrong
/// thing" are different bugs.
func topLevelBlock(_ key: String, in text: String) -> [String]? {
    let raw = text.components(separatedBy: .newlines)
    guard let start = raw.firstIndex(where: { $0 == "\(key):" }) else { return nil }

    var entries: [String] = []
    for line in raw[(start + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        // A zero-indent line ends the block.
        if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
        entries.append(trimmed)
    }
    return entries
}
