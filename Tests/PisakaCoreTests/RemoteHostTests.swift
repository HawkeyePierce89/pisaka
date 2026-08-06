import XCTest
@testable import PisakaCore

final class RemoteHostTests: XCTestCase {
    func testHttpsPlain() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://github.com/u/r.git"),
            "github.com"
        )
    }

    func testHttpsWithoutDotGit() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://github.com/u/r"),
            "github.com"
        )
    }

    func testHttpsWithUser() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://user@github.com/u/r.git"),
            "github.com"
        )
    }

    func testHttpsWithUserAndPassword() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://user:pass@github.com/u/r.git"),
            "github.com"
        )
    }

    func testHttpsWithPort() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://github.com:443/u/r.git"),
            "github.com"
        )
    }

    func testHttpsWithUserAndPort() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://user@github.com:443/u/r.git"),
            "github.com"
        )
    }

    func testPlainHttpReturnsNil() {
        // Plain http would leak the PAT (the HTTPS password) in cleartext, so it
        // yields no host — the feature is HTTPS-only.
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "http://example.com/u/r.git"))
    }

    func testIPv6Literal() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://[::1]:443/u/r.git"),
            "::1"
        )
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://[::1]/u/r"),
            "::1"
        )
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://[2001:db8::1]:8443/team/repo.git"),
            "2001:db8::1"
        )
    }

    func testHostLowercased() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://GitHub.COM/u/r.git"),
            "github.com"
        )
    }

    func testSelfHostedWithPort() {
        XCTAssertEqual(
            RemoteHost.host(fromRemoteURL: "https://git.example.org:8443/team/repo.git"),
            "git.example.org"
        )
    }

    func testScpStyleReturnsNil() {
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "git@github.com:u/r.git"))
    }

    func testSshSchemeReturnsNil() {
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "ssh://git@github.com/u/r.git"))
    }

    func testFileSchemeReturnsNil() {
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "file:///tmp/repo.git"))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "not a url"))
        XCTAssertNil(RemoteHost.host(fromRemoteURL: ""))
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "   "))
        XCTAssertNil(RemoteHost.host(fromRemoteURL: "https://"))
    }
}
