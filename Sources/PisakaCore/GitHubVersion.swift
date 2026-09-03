import Foundation

/// A `gh` version, and the one comparison this layer makes (G4).
///
/// Three integers and nothing else. `gh` publishes prereleases
/// (`2.50.0-rc.1`) and its `--version` line carries a build date, neither of
/// which participates in "is this new enough", so both are read and dropped
/// rather than modelled: a release candidate for 2.50.0 either has the flag this
/// app needs or it does not, and ordering it *below* 2.50.0 the way semver does
/// would refuse a binary that works.
public struct GitHubVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The oldest `gh` this feature accepts.
    ///
    /// **2.50.0, and the reason is one flag**: `gh pr checks --json` — without
    /// which the per-row checks list has no machine-readable answer at all —
    /// landed in cli/cli#9079, merged 2024-05-16, and the first tag containing
    /// that commit is `v2.50.0` (2024-05-29). Everything else in scope
    /// (`pr list --json`, `repo view --json`, `pr create`, `pr checkout`) is
    /// older than that, so this one flag is the bound. Raise it only against a
    /// commit-to-tag check of the same shape, and record the new reason here.
    public static let minimum = GitHubVersion(major: 2, minor: 50, patch: 0)

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitHubVersion, rhs: GitHubVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// The version named by `gh --version`'s output, or `nil` for output that
    /// does not name one.
    ///
    /// `gh --version` prints two lines — `gh version 2.99.0 (2026-09-01)` and a
    /// release URL — and only the first is read. The line is found by its first
    /// two whitespace-separated words rather than by a substring search, so the
    /// release URL on line 2 (which also contains a version) can never be the
    /// answer, and so a `gh` replaced on the `PATH` by something else entirely
    /// reports `nil` instead of a number nobody should trust.
    ///
    /// `nil` is a real answer, not a precondition failure: it becomes
    /// `GitHubAvailability.notInstalled`, because a binary that will not say what
    /// it is cannot be vouched for.
    public static func parse(_ output: String) -> GitHubVersion? {
        for line in output.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 3, words[0] == "gh", words[1] == "version" else { continue }
            if let version = parseNumber(String(words[2])) { return version }
        }
        return nil
    }

    /// `2.99.0`, `v2.99.0`, `2.50.0-rc.1`, `2.50.0+build` and `2.50` — the
    /// spellings a version token has actually taken — reduced to three integers.
    ///
    /// A missing patch reads as `0` (`2.50` ≡ `2.50.0`); a fourth component, a
    /// prerelease suffix and build metadata are all dropped, for the reason on
    /// the type. Anything whose first two components are not integers is `nil`.
    public static func parseNumber(_ token: String) -> GitHubVersion? {
        var text = token.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex..<cut])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return GitHubVersion(major: major, minor: minor, patch: patch)
    }
}
