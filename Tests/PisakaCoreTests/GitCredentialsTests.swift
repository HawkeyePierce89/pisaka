import XCTest
@testable import PisakaCore

final class GitCredentialsTests: XCTestCase {
    /// A minimal in-memory `CredentialStore` for the pure resolution tests.
    private struct MemoryStore: CredentialStore {
        var tokens: [String: String] = [:]
        func token(forHost host: String) -> String? { tokens[host] }
    }

    /// A store relying entirely on the protocol-extension defaults (no token
    /// stored) — confirms "absent token is the explicit default signal".
    private struct EmptyDefaultStore: CredentialStore {}

    // MARK: - username(forHost:)

    func testUsernameForGitHub() {
        XCTAssertEqual(GitCredentials.username(forHost: "github.com"), "x-access-token")
    }

    func testUsernameForGitHubSubdomainEnterprise() {
        XCTAssertEqual(
            GitCredentials.username(forHost: "api.github.com"),
            "x-access-token"
        )
    }

    func testUsernameForGitHubIsCaseInsensitive() {
        XCTAssertEqual(GitCredentials.username(forHost: "GitHub.com"), "x-access-token")
    }

    func testUsernameForOtherHost() {
        XCTAssertEqual(GitCredentials.username(forHost: "gitlab.com"), "git")
        XCTAssertEqual(GitCredentials.username(forHost: "git.example.org"), "git")
    }

    // MARK: - resolve

    func testResolveWithStoredTokenGitHub() {
        let store = MemoryStore(tokens: ["github.com": "ghp_secret"])
        let result = GitCredentials.resolve(
            remoteURL: "https://github.com/u/r.git",
            store: store
        )
        XCTAssertEqual(
            result,
            .credential(GitCredential(username: "x-access-token", token: "ghp_secret"))
        )
    }

    func testResolveWithStoredTokenOtherHost() {
        let store = MemoryStore(tokens: ["gitlab.com": "glpat_secret"])
        let result = GitCredentials.resolve(
            remoteURL: "https://gitlab.com/u/r.git",
            store: store
        )
        XCTAssertEqual(
            result,
            .credential(GitCredential(username: "git", token: "glpat_secret"))
        )
    }

    func testResolveUsesHostFromURLWithUserAndPort() {
        // The host is stripped of userinfo/port before the store lookup.
        let store = MemoryStore(tokens: ["github.com": "tok"])
        let result = GitCredentials.resolve(
            remoteURL: "https://user@github.com:443/u/r.git",
            store: store
        )
        XCTAssertEqual(
            result,
            .credential(GitCredential(username: "x-access-token", token: "tok"))
        )
    }

    func testResolveMissingTokenWhenNoneStored() {
        let store = MemoryStore(tokens: [:])
        let result = GitCredentials.resolve(
            remoteURL: "https://github.com/u/r.git",
            store: store
        )
        XCTAssertEqual(result, .missingToken(host: "github.com"))
    }

    func testResolveMissingTokenWithDefaultStore() {
        let result = GitCredentials.resolve(
            remoteURL: "https://github.com/u/r.git",
            store: EmptyDefaultStore()
        )
        XCTAssertEqual(result, .missingToken(host: "github.com"))
    }

    func testResolveMissingTokenWhenStoredEmpty() {
        // An empty stored token is treated as absent.
        let store = MemoryStore(tokens: ["github.com": ""])
        let result = GitCredentials.resolve(
            remoteURL: "https://github.com/u/r.git",
            store: store
        )
        XCTAssertEqual(result, .missingToken(host: "github.com"))
    }

    func testResolveNonHTTPSRemoteScpStyle() {
        let store = MemoryStore(tokens: ["github.com": "tok"])
        let result = GitCredentials.resolve(
            remoteURL: "git@github.com:u/r.git",
            store: store
        )
        XCTAssertEqual(result, .nonHTTPSRemote)
    }

    func testResolveNonHTTPSRemoteSSHScheme() {
        let result = GitCredentials.resolve(
            remoteURL: "ssh://git@github.com/u/r.git",
            store: MemoryStore(tokens: ["github.com": "tok"])
        )
        XCTAssertEqual(result, .nonHTTPSRemote)
    }

    func testResolveNonHTTPSRemoteGarbage() {
        let result = GitCredentials.resolve(
            remoteURL: "not a url",
            store: MemoryStore()
        )
        XCTAssertEqual(result, .nonHTTPSRemote)
    }

    // MARK: - CredentialStore defaults

    func testDefaultStoreSaveAndDeleteAreNoOps() throws {
        // The default save/delete implementations do nothing and do not throw,
        // so a lookup-only stub compiles and behaves.
        let store = EmptyDefaultStore()
        XCTAssertNil(store.token(forHost: "github.com"))
        XCTAssertNoThrow(try store.save(token: "x", forHost: "github.com"))
        XCTAssertNoThrow(try store.delete(forHost: "github.com"))
    }
}
