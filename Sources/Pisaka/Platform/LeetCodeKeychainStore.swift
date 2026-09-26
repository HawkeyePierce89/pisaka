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
/// **That accessibility class is an iOS guarantee.** This store is compiled on
/// both destinations, and without `kSecUseDataProtectionKeychain` a
/// `kSecClassGenericPassword` item on macOS lands in the legacy file-based login
/// keychain, which ignores `kSecAttrAccessible` — so on the Mac the item is
/// protected by the login keychain's own rules instead. The attribute is set
/// unconditionally rather than gated on the platform because it is harmless where
/// it is ignored, but the promise above should be read as the iOS one. Adopting
/// the data-protection keychain on macOS is not a free swap: it wants a signed
/// app with a keychain-access-group entitlement, and this project ships no
/// `.entitlements`.
///
/// `@unchecked Sendable` over an immutable `let`: there is no mutable state, and
/// the Keychain is thread-safe. `LeetCodeModel` reads it synchronously on the
/// main actor, at the first use of the feature rather than at launch (L27). That
/// is safe **only because a read nobody asked for is non-interactive**: account
/// resolution runs from on-appear bodies, which execute inside the window's
/// layout pass, and an authorization panel raised there freezes the app until it
/// is force-quit. So resolution reads `.unattended`, which this file guarantees
/// never waits on a person (see `load(_:)`). An `.attended` read — one that
/// follows an explicit action — may raise the panel, and because it too runs on
/// the main actor the window cannot redraw while the panel stands; the app
/// resumes once it is answered. That brief block is the recorded known limit.
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
    ///
    /// **An `.attended` read is the plain query**, free to raise whatever the
    /// system asks. **An `.unattended` read never waits on a person**, and how
    /// that is guaranteed differs by destination:
    ///
    /// - **macOS** turns the legacy keychain's user interaction off for the one
    ///   query (`copyMatchingWithoutInteraction(_:_:)`). A refused read then
    ///   fails at once — any non-success status, `errSecAuthFailed` and
    ///   `errSecInteractionNotAllowed` alike, is `nil`, as before.
    /// - **iOS** runs the same plain query for both kinds. This item carries no
    ///   access-control flags, so reading it never shows UI; the one case the
    ///   system cannot answer — a read before first unlock — already returns
    ///   `errSecInteractionNotAllowed` without asking, which is `nil` here.
    func load(_ read: LeetCodeCredentialRead) -> LeetCodeCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status: OSStatus
        #if os(macOS)
        switch read {
        case .attended:
            status = SecItemCopyMatching(query as CFDictionary, &item)
        case .unattended:
            status = Self.copyMatchingWithoutInteraction(query, &item)
        }
        #else
        status = SecItemCopyMatching(query as CFDictionary, &item)
        #endif
        guard status == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(LeetCodeCredentials.self, from: data),
              !credentials.session.isEmpty,
              !credentials.csrfToken.isEmpty
        else { return nil }
        return credentials
    }

    #if os(macOS)
    /// `SecItemCopyMatching` with the keychain's user interaction switched off
    /// for exactly this one query, and restored to whatever it was afterwards.
    ///
    /// **Why the legacy switch and not the documented flags.** On macOS this item
    /// lives in the file-based login keychain (see the type's note), and against
    /// it both documented ways of saying "do not ask" were measured failing: a
    /// query carrying `kSecUseAuthenticationUIFail`, and one carrying an
    /// authentication context whose `interactionNotAllowed` is set, each still
    /// raised the authorization panel for a binary the keychain did not
    /// recognise and hung. `SecKeychainSetUserInteractionAllowed(false)` alone
    /// held: the same read returned `errSecAuthFailed` in a few milliseconds with
    /// no panel.
    ///
    /// **The switch is process-wide.** It is held only for the duration of one
    /// synchronous read on the main actor, and nothing else in the macOS process
    /// uses the Keychain (the git PAT store is iOS-only), so no other read can
    /// observe it. The saved value is restored in a `defer`, so every exit
    /// leaves the process as it found it.
    ///
    /// **Its deprecation warning is accepted on purpose**: the API is deprecated
    /// together with the file-based keychain it governs, and that keychain is
    /// exactly where the item lives while the app ships no entitlements.
    private static func copyMatchingWithoutInteraction(
        _ query: [String: Any],
        _ item: inout CFTypeRef?
    ) -> OSStatus {
        var wasAllowed: DarwinBoolean = true
        let saved = SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(saved ? wasAllowed.boolValue : true) }
        return SecItemCopyMatching(query as CFDictionary, &item)
    }
    #endif

    /// Persist `credentials`, replacing any previously stored pair
    /// (delete-then-add, so the ordinary path is a single idempotent branch rather
    /// than an add/update fork whose two halves can disagree about accessibility).
    ///
    /// **The update is the fallback, not a second ordinary path, and it is not
    /// optional.** The delete's failure used to be swallowed by `try?`, which made
    /// the add return `errSecDuplicateItem` and leave the *previous* item in
    /// place. The model's accounting for a failed save is "one sign-in next
    /// launch" (`lastCredentialSaveFailed`), and that is true only if nothing is
    /// stored; with the old item surviving, the next launch reads a **different
    /// account's** session back out of the Keychain and reports it as signed in.
    /// So a duplicate is overwritten in place — with the same accessibility, which
    /// `SecItemUpdate` sets alongside the data precisely so the two halves cannot
    /// disagree — and only a failure of *that* is reported.
    func save(_ credentials: LeetCodeCredentials) throws {
        try? clear()
        let data = try JSONEncoder().encode(credentials)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw LeetCodeKeychainError(status: status) }

        let updated = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )
        guard updated == errSecSuccess else { throw LeetCodeKeychainError(status: updated) }
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
