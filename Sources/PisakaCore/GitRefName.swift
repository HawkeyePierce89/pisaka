import Foundation

/// Validation of a new git branch name, per `git check-ref-format` rules.
///
/// Pure, testable — the branch-switcher's "New Branch…" dialog, separate from
/// `isValidFileName` (a branch name has its own, stricter grammar). This
/// validates a single branch component the way `git branch <name>` /
/// `git checkout -b <name>` require; it is deliberately conservative and does
/// not accept multi-component `foo/bar` slashes (the widget creates one branch,
/// not a hierarchy) — a leading/trailing `/` and a doubled `//` are already
/// rejected, and an interior `/` is allowed only when both sides are non-empty
/// and the component after it does not start with a dot.
public enum GitRefName {
    /// Whether `name` is a valid new branch name.
    ///
    /// Rejects: empty/whitespace-only; a leading `-` (git's own `branch`/`checkout
    /// -b` refuse it, and the macOS CLI runs `git checkout -b <name> …` with no
    /// `--` separator so a dash-led name is mis-parsed as an option); a
    /// leading/trailing slash; `..`; the characters space, `~`, `^`, `:`, `?`, `*`,
    /// `[`, `\`, any ASCII control character (incl. DEL) or NUL, and any line
    /// break — including the non-ASCII NEL/LINE SEPARATOR/PARAGRAPH SEPARATOR
    /// that sit above the control range; a leading dot
    /// or a dot right after a `/`; a `.lock` suffix (on any `/`-separated
    /// component); the sequence `@{`; a lone `@`; a trailing dot; and a doubled `//`.
    public static func isValid(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }

        if name == "@" { return false }
        if name.hasPrefix("-") { return false }
        if name.hasPrefix("/") || name.hasSuffix("/") { return false }
        if name.hasSuffix(".") { return false }
        if name.hasSuffix(".lock") { return false }
        if name.contains("..") { return false }
        if name.contains("//") { return false }
        if name.contains("@{") { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/.") { return false }

        // Any `/`-separated component ending in `.lock` is disallowed too.
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.hasSuffix(".lock") { return false }
        }

        // Scanned over *unicode scalars*, not `Character`s: `\r\n` is a single
        // grapheme cluster carrying two scalars, so a `Character`-level control
        // check would skip it and accept a name with an embedded line break
        // (reachable by pasting into the multiline "New Branch" field).
        //
        // `CharacterSet.newlines` is tested alongside the ASCII control range
        // because three of its scalars — NEL (U+0085), LINE SEPARATOR (U+2028)
        // and PARAGRAPH SEPARATOR (U+2029) — sit *above* it, so the control
        // check alone would accept them. Those dialogs pass no live validator,
        // so this predicate is the only gate a pasted break meets before
        // `git checkout -b`, which happily creates a branch whose name carries
        // an invisible separator. It also keeps the rule aligned with
        // `FileName.componentIssue`, which rejects the same set.
        let forbidden: Set<Unicode.Scalar> = [" ", "~", "^", ":", "?", "*", "[", "\\", "\0"]
        for scalar in name.unicodeScalars {
            if forbidden.contains(scalar) { return false }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if CharacterSet.newlines.contains(scalar) { return false }
        }
        return true
    }
}
