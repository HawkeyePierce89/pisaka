import XCTest
@testable import PisakaCore

/// The seam's value types. Small, but the two behaviours here are load-bearing:
/// the schema suite asserts requests byte for byte, and the throttle path reads
/// one response header whose spelling it does not control.
final class LeetCodeTransportTests: XCTestCase {
    private let url = URL(string: "https://leetcode.com/graphql")!

    func testRequestDefaultsToAGETWithNoHeadersAndNoBody() {
        let request = LeetCodeHTTPRequest(url: url)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.headers, [:])
        XCTAssertNil(request.body)
    }

    func testRequestsAreEquatableByEveryComponent() {
        let base = LeetCodeHTTPRequest(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        XCTAssertEqual(base, base)
        var otherBody = base
        otherBody.body = Data("{ }".utf8)
        XCTAssertNotEqual(base, otherBody)
        var otherHeaders = base
        otherHeaders.headers["Referer"] = "https://leetcode.com/"
        XCTAssertNotEqual(base, otherHeaders)
    }

    func testResponseSuccessRange() {
        XCTAssertTrue(LeetCodeHTTPResponse(statusCode: 200).isSuccess)
        XCTAssertTrue(LeetCodeHTTPResponse(statusCode: 204).isSuccess)
        XCTAssertFalse(LeetCodeHTTPResponse(statusCode: 199).isSuccess)
        XCTAssertFalse(LeetCodeHTTPResponse(statusCode: 302).isSuccess)
        XCTAssertFalse(LeetCodeHTTPResponse(statusCode: 429).isSuccess)
    }

    func testResponseHeaderLookupIsCaseInsensitive() {
        // Field names are case-insensitive on the wire and stacks normalise them
        // differently; the throttle path must not depend on which spelling arrived.
        let response = LeetCodeHTTPResponse(statusCode: 429, headers: ["retry-after": "30"])
        XCTAssertEqual(response.headerValue(forName: "Retry-After"), "30")
        XCTAssertEqual(response.headerValue(forName: "retry-after"), "30")
        XCTAssertNil(response.headerValue(forName: "Content-Type"))
    }

    func testResponseDefaultsToNoHeadersAndAnEmptyBody() {
        let response = LeetCodeHTTPResponse(statusCode: 200)
        XCTAssertEqual(response.headers, [:])
        XCTAssertTrue(response.body.isEmpty)
    }

    /// A transport is one `async throws` call and nothing else — a stub proves the
    /// protocol is usable without a `URLSession`, which is the whole point.
    func testAStubTransportSatisfiesTheProtocol() async throws {
        struct EchoTransport: LeetCodeTransport {
            func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse {
                LeetCodeHTTPResponse(statusCode: 200, body: request.body ?? Data())
            }
        }
        let response = try await EchoTransport().send(
            LeetCodeHTTPRequest(method: "POST", url: url, body: Data("hello".utf8))
        )
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello")
    }
}
