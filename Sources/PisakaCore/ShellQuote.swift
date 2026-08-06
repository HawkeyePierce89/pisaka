import Foundation

/// Pure, testable POSIX-shell single-quoting, shared by the run/test command
/// resolvers (`RunCommand`/`TestCommand`) so a path with spaces or shell
/// metacharacters survives intact when spliced into a command line.
public enum ShellQuote {
    /// Wrap `value` in single quotes for the shell, escaping each embedded
    /// single quote as `'\''` (close, escaped literal quote, reopen). Everything
    /// else — spaces, `$`, backticks, `;` — is literal inside single quotes.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
