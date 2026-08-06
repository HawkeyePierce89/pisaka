import Foundation

/// A username/password pair for an HTTPS git transaction — a Personal Access
/// Token supplied as the password (`GIT_CREDENTIAL_USERPASS_PLAINTEXT`).
///
/// Pure value type. The iOS libgit2 credentials callback (Task 9) turns this into
/// a `git_credential_userpass_plaintext_new` call; the username is a host-derived
/// placeholder and the token is the secret.
public struct GitCredential: Equatable {
    /// The username presented to the server — a host-specific placeholder (the PAT
    /// is the real secret): `"x-access-token"` for GitHub, `"git"` elsewhere.
    public let username: String
    /// The Personal Access Token, sent as the HTTPS password.
    public let token: String

    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }
}

/// The outcome of resolving credentials for a remote before an HTTPS fetch.
///
/// Distinguishes the three cases the fetch/branch-create flow must handle: usable
/// credentials, an HTTPS remote with no stored token (direct the user to add one),
/// and a non-HTTPS remote (a PAT cannot fetch an scp-style `git@…`/`ssh://` remote
/// on iOS — SSH is exec-based and unavailable there).
public enum CredentialResolution: Equatable {
    /// A stored token was found for the remote's host.
    case credential(GitCredential)
    /// The remote is HTTPS but no token is stored for `host` — surface
    /// `GitError.credentialsRequired(host:)` and direct the user to Settings.
    case missingToken(host: String)
    /// The remote URL is not HTTPS, so a PAT cannot authenticate it — surface a
    /// clear "HTTPS origin required" message.
    case nonHTTPSRemote
}

/// A store of Personal Access Tokens keyed by remote host.
///
/// The pure/testable seam over the iOS Keychain wrapper (`KeychainCredentialStore`,
/// Task 9). Every method is defaulted in the extension below so a partial in-memory
/// stub compiles by implementing only what it needs (the `GitServicing`
/// default-extension precedent) — and, importantly, an unimplemented lookup returns
/// `nil`, i.e. an *absent token is the explicit default signal*.
public protocol CredentialStore {
    /// The stored token for `host`, or `nil` when none is stored (or it is
    /// unreadable — treated as absent, so the flow falls back to
    /// `credentialsRequired`).
    func token(forHost host: String) -> String?
    /// Persist `token` for `host` (overwriting any existing one).
    func save(token: String, forHost host: String) throws
    /// Remove the stored token for `host` (a no-op when none is stored).
    func delete(forHost host: String) throws
}

public extension CredentialStore {
    func token(forHost host: String) -> String? { nil }
    func save(token: String, forHost host: String) throws {}
    func delete(forHost host: String) throws {}
}

/// Pure credential-by-host selection for the iOS HTTPS fetch.
///
/// Foundation-only, testable ahead of the Keychain/libgit2 IO. Resolves a remote
/// URL to either usable credentials, a `missingToken` signal (HTTPS host with no
/// stored PAT), or `nonHTTPSRemote` (a PAT cannot fetch a non-HTTPS remote on iOS).
/// The host is extracted with `RemoteHost.host(fromRemoteURL:)` so the same rule
/// that produced the Keychain key produces the lookup.
public enum GitCredentials {
    /// The HTTPS username for `host` — a placeholder, since the PAT (the password)
    /// is the real secret. GitHub authenticates a PAT with `"x-access-token"`; other
    /// hosts accept any non-empty username, for which `"git"` is used.
    public static func username(forHost host: String) -> String {
        let lower = host.lowercased()
        if lower == "github.com" || lower.hasSuffix(".github.com") {
            return "x-access-token"
        }
        return "git"
    }

    /// Resolve credentials for `remoteURL` from `store`.
    ///
    /// - A non-HTTPS remote (no host) → `.nonHTTPSRemote`.
    /// - An HTTPS remote whose host has no stored (or empty) token → `.missingToken`.
    /// - Otherwise → `.credential` with the host-derived username and the stored token.
    public static func resolve(remoteURL: String, store: CredentialStore) -> CredentialResolution {
        guard let host = RemoteHost.host(fromRemoteURL: remoteURL) else {
            return .nonHTTPSRemote
        }
        guard let token = store.token(forHost: host), !token.isEmpty else {
            return .missingToken(host: host)
        }
        return .credential(GitCredential(username: username(forHost: host), token: token))
    }
}
