#if os(iOS)
import Foundation
import Security
import PisakaCore

/// Keychain-backed `CredentialStore` for the iOS HTTPS git fetch: stores a
/// Personal Access Token per remote host (the Keychain *account*) under a fixed
/// service, so `LibGit2Service.fetch`'s credentials callback can supply it and the
/// Settings screen can enter/list/delete it. Thin `Security`-framework IO — the
/// by-host *selection* logic lives in Core (`GitCredentials`/`RemoteHost`), so this
/// wrapper is untested like the rest of the view layer.
///
/// Every operation is a synchronous `SecItem*` call; the Keychain is thread-safe,
/// so the store is read from `LibGit2Service`'s serial git queue (inside the fetch
/// credentials callback) while the Settings UI mutates it on the main actor —
/// hence `@unchecked Sendable`.
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// The Keychain service under which every PAT is stored; the remote host is the
    /// per-item account, so a token is keyed exactly by the host
    /// `RemoteHost.host(fromRemoteURL:)` (and thus `GitCredentials.resolve`) derives.
    private let service: String

    init(service: String = "ws.karmanov.pisaka.git-pat") {
        self.service = service
    }

    /// A base query matching this store's item for `host` (the account).
    private func baseQuery(forHost host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    /// The stored token for `host`, or `nil` when none is stored (or it is empty /
    /// unreadable — treated as absent, so the fetch falls back to
    /// `credentialsRequired`).
    func token(forHost host: String) -> String? {
        var query = baseQuery(forHost: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Persist `token` for `host`, overwriting any existing one (delete-then-add,
    /// so the code path is a single idempotent branch).
    func save(token: String, forHost host: String) throws {
        try? delete(forHost: host)
        guard let data = token.data(using: .utf8) else { return }
        var attributes = baseQuery(forHost: host)
        attributes[kSecValueData as String] = data
        // `ThisDeviceOnly`: the PAT is a secret used only for local HTTPS fetches, so
        // it must never be included in an encrypted device backup or migrated to
        // another device on restore. `AfterFirstUnlock` keeps it readable from the
        // fetch credentials callback after the first post-boot unlock.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Remove the stored token for `host` (a no-op when none is stored).
    func delete(forHost host: String) throws {
        let status = SecItemDelete(baseQuery(forHost: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// The hosts that currently have a stored token, sorted — for the Settings list.
    func storedHosts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return [] }
        return entries
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted()
    }
}

/// A Keychain `OSStatus` failure with a human-readable message (so a save/delete
/// error surfaces something better than a raw code in the Settings screen).
private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}
#endif
