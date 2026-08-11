import Foundation
import PisakaCore
import Security

/// Keychain-backed `LeetCodeCredentialStore`: the signed-in LeetCode session
/// between launches.
///
/// The cross-platform sibling of `KeychainCredentialStore` (the iOS-only git PAT
/// store), which is deliberately left alone: the two keep different secrets
/// under different services with different key shapes, and merging them would
/// make one store whose account column means "a remote host" in one half and
/// nothing in the other.
///
/// Thin `Security`-framework IO — every decision worth testing (what counts as a
/// session, when absence means "signed out", what a save failure costs) lives in
/// Core, so this wrapper is untested like the rest of the app layer.
///
/// **The pair is one item, stored as JSON.** `LEETCODE_SESSION` and `csrftoken`
/// are only ever useful together — a request needs both, and half a pair is a
/// login that appears to work and then fails on every call — so storing them as
/// two items would create a state where one exists and the other does not, and
/// every reader would need a rule for it. One item cannot half-exist.
/// `LeetCodeCredentials`' `CodingKeys` are spelled explicitly for exactly this
/// reason: a property rename here would otherwise silently invalidate every
/// stored session.
///
/// **`ThisDeviceOnly`**, matching the git PAT store: the session is a
/// browser-equivalent credential for one machine, so it must never ride along in
/// an encrypted backup or migrate to another device on restore.
/// `AfterFirstUnlock` (rather than `WhenUnlocked`) keeps it readable from a
/// background refresh after the first post-boot unlock.
///
/// `@unchecked Sendable` over an immutable `let`: there is no mutable state, and
/// the Keychain is thread-safe. `LeetCodeModel` reads it on the main actor at
/// launch, but the protocol is not main-actor-bound and nothing here needs it.
final class LeetCodeKeychainStore: LeetCodeCredentialStore, @unchecked Sendable {
    /// The Keychain service every LeetCode session is stored under. Distinct
    /// from the git PAT store's service, so "sign out of LeetCode" cannot reach
    /// a git token and vice versa.
    private let service: String

    /// The account this single item is filed under. A constant rather than a
    /// user name: the item *is* the session, and the user name is something the
    /// session tells us, not something we need in order to find it.
    private let account: String

    init(
        service: String = "ws.karmanov.pisaka.leetcode-session",
        account: String = "leetcode.com"
    ) {
        self.service = service
        self.account = account
    }

    /// A base query matching this store's one item.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored session, or `nil` when none is stored — or when what is stored
    /// no longer decodes, which is deliberately not distinguished. An unreadable
    /// session cannot be used and the recovery for both is the same sign-in, so
    /// the store reports the state the app can act on rather than a diagnosis it
    /// has no screen for.
    func load() -> LeetCodeCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(LeetCodeCredentials.self, from: data),
              !credentials.session.isEmpty,
              !credentials.csrfToken.isEmpty
        else { return nil }
        return credentials
    }

    /// Persist `credentials`, replacing any previously stored pair
    /// (delete-then-add, so the code path is a single idempotent branch rather
    /// than an add/update fork whose two halves can disagree about accessibility).
    func save(_ credentials: LeetCodeCredentials) throws {
        try? clear()
        let data = try JSONEncoder().encode(credentials)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LeetCodeKeychainError(status: status) }
    }

    /// Remove the stored session (a no-op when none is stored). Sign-out calls
    /// this *and* clears the login web view's `leetcode.com` cookies; either
    /// alone leaves the user half signed in.
    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LeetCodeKeychainError(status: status)
        }
    }
}

/// A Keychain `OSStatus` failure with a human-readable message.
///
/// Not a `LeetCodeError`: the model already knows what a failed save costs
/// (`lastCredentialSaveFailed` — one sign-in next launch, never a refused
/// sign-in), and wrapping this in `fileSystem` would attribute a Keychain
/// refusal to the disk.
private struct LeetCodeKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}
