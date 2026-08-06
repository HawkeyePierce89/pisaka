import Foundation

/// Extraction of the host from a git remote URL, for PAT-by-host selection.
///
/// Pure, testable — the Keychain key the iOS credentials path (Part B) uses to
/// find a Personal Access Token for a remote. Only an **HTTPS** remote yields a
/// host: an scp-style `git@github.com:u/r.git` returns `nil` (it can't be fetched
/// with a PAT on iOS — SSH is exec-based and unavailable there), as does a plain
/// `http://` remote (the PAT is the HTTPS password; supplying it over cleartext
/// `http` would leak it, so the whole feature is HTTPS-only) and anything
/// unparseable.
public enum RemoteHost {
    /// The lowercased host of an HTTPS remote URL, or `nil`.
    ///
    /// `https://user@github.com:443/u/r.git` → `github.com`; the userinfo and
    /// port are stripped, a trailing `.git` on the path is irrelevant. A
    /// non-HTTPS scheme (plain `http://`, scp-style `git@…`, `ssh://`, `file://`,
    /// garbage) → `nil`, so a PAT is never selected for a remote it can't secure.
    public static func host(fromRemoteURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("https://") else { return nil }

        // Strip the scheme, then everything from the first `/` (path) onward.
        guard let schemeRange = trimmed.range(of: "://") else { return nil }
        var authority = String(trimmed[schemeRange.upperBound...])
        if let slash = authority.firstIndex(of: "/") {
            authority = String(authority[authority.startIndex..<slash])
        }

        // Drop userinfo (`user@` or `user:pass@`).
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }

        // Drop the port. Guard IPv6 literals (`[::1]:443`) — only a colon after
        // a closing bracket, or the last colon in a bracket-free authority, is a
        // port separator.
        var hostPart = authority
        if hostPart.hasPrefix("[") {
            if let close = hostPart.firstIndex(of: "]") {
                hostPart = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
            }
        } else if let colon = hostPart.lastIndex(of: ":") {
            hostPart = String(hostPart[hostPart.startIndex..<colon])
        }

        let host = hostPart.lowercased()
        if host.isEmpty { return nil }
        return host
    }
}
