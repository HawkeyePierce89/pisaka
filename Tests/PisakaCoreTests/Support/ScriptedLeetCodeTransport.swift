import Foundation
@testable import PisakaCore

/// A `LeetCodeTransport` that answers from a script instead of from LeetCode.
///
/// The `ScriptedLSPTransport` principle applied to HTTP: everything interesting
/// about this area — when a catalog is refetched, what a throttle does to an
/// open, which of two overlapping operations publishes — is *sequencing and
/// failure handling*, and none of it needs a network. What it needs is a
/// transport that can answer a recorded body once and a different one the next
/// time, fail on demand, and be held mid-flight while a test changes the world.
///
/// Answers are keyed by **route**, not by the whole request, because the request
/// carries a session cookie and a GraphQL document the test has no business
/// restating — those are `LeetCodeAPITests`' subject, asserted there byte for
/// byte. Here a test says "the catalog request answers this file" and then
/// asserts *how many times* it was asked.
///
/// Two behaviours are worth knowing before writing a test against it:
///
/// - A route's script is a queue, and **the last step is sticky**: stub one
///   answer and every call gets it, stub three and the third answers forever
///   after. That is what lets "a warm cache makes no request" and "the miss path
///   refreshes exactly once" both be assertions about `count(for:)` rather than
///   about how many stubs were consumed.
/// - An **unstubbed route throws** rather than answering an empty 200. A test
///   that forgot to script something must fail as a failure, not as a parse
///   error three layers away.
final class ScriptedLeetCodeTransport: LeetCodeTransport, @unchecked Sendable {

    /// What a request is *for*, as coarsely as the tests need to distinguish.
    enum Route: Hashable {
        /// A POST to the GraphQL endpoint, identified by its operation name
        /// (`globalData`, `questionData`) — which is exactly how LeetCode's own
        /// logging and rate limiting identify it.
        case graphQL(operation: String)
        /// The legacy REST catalog.
        case problemList
        /// Anything else, by path — so a request nobody expected is nameable in
        /// the failure message rather than silently matching something.
        case other(path: String)
    }

    enum Failure: Error, LocalizedError {
        /// The transport could not reach LeetCode at all — the shape the real one
        /// reports as `LeetCodeError.network`.
        case offline
        /// Nothing was scripted for this route.
        case notStubbed(Route)

        var errorDescription: String? {
            switch self {
            case .offline:
                return "The Internet connection appears to be offline."
            case .notStubbed(let route):
                return "No scripted response for \(route)."
            }
        }
    }

    private struct Step {
        let answer: Result<LeetCodeHTTPResponse, Error>
        let delay: TimeInterval
    }

    private let lock = NSLock()
    private var steps: [Route: [Step]] = [:]
    private var gates: [Route: Gate] = [:]
    private var sentStorage: [LeetCodeHTTPRequest] = []

    // MARK: - Scripting

    /// Answer `route` with `response`, replacing any script it had.
    func serve(_ route: Route, with response: LeetCodeHTTPResponse, delay: TimeInterval = 0) {
        script(route, [Step(answer: .success(response), delay: delay)])
    }

    /// Answer `route` with a 200 carrying `json`.
    func serve(
        _ route: Route,
        json: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) {
        serve(
            route,
            with: LeetCodeHTTPResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(json.utf8)
            ),
            delay: delay
        )
    }

    /// Answer `route` with a 200 carrying the bytes of a recorded fixture.
    func serve(
        _ route: Route,
        body: Data,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        delay: TimeInterval = 0
    ) {
        serve(
            route,
            with: LeetCodeHTTPResponse(statusCode: statusCode, headers: headers, body: body),
            delay: delay
        )
    }

    /// Answer `route` with each element in turn, the last one sticking.
    func serve(_ route: Route, sequence responses: [LeetCodeHTTPResponse]) {
        script(route, responses.map { Step(answer: .success($0), delay: 0) })
    }

    /// Fail every request for `route`.
    func fail(_ route: Route, with error: Error = Failure.offline) {
        script(route, [Step(answer: .failure(error), delay: 0)])
    }

    /// Fail the first request for `route` and answer the rest with `response` —
    /// the "it worked on the retry" shape.
    func fail(
        _ route: Route,
        once error: Error = Failure.offline,
        thenServe response: LeetCodeHTTPResponse
    ) {
        script(
            route,
            [
                Step(answer: .failure(error), delay: 0),
                Step(answer: .success(response), delay: 0)
            ]
        )
    }

    /// Hold every request for `route` until the gate is released — the window a
    /// test starts a second, coalescing operation in.
    ///
    /// Blocking is sound because `send(_:)` is `nonisolated async`: the model
    /// `await`s it from the main actor, so the body runs on the cooperative pool
    /// and the main actor stays free. That is `Gate`'s whole premise.
    func hold(_ route: Route, on gate: Gate) {
        lock.lock()
        gates[route] = gate
        lock.unlock()
    }

    private func script(_ route: Route, _ newSteps: [Step]) {
        lock.lock()
        steps[route] = newSteps
        lock.unlock()
    }

    // MARK: - What was asked

    /// Every request, in call order.
    var sent: [LeetCodeHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    /// The requests that went to `route`, in call order.
    func requests(for route: Route) -> [LeetCodeHTTPRequest] {
        sent.filter { Self.route(of: $0) == route }
    }

    /// How many times `route` was requested — the assertion most of these tests
    /// actually make.
    func count(for route: Route) -> Int {
        requests(for: route).count
    }

    // MARK: - Routing

    /// Which route a request belongs to.
    ///
    /// The GraphQL operation name is read back out of the body the way LeetCode
    /// reads it, rather than being carried alongside: that keeps the fake honest
    /// about the bytes `LeetCodeAPI` actually composed.
    static func route(of request: LeetCodeHTTPRequest) -> Route {
        if request.url == LeetCodeAPI.problemListURL { return .problemList }
        if request.url == LeetCodeAPI.graphQLURL {
            let operation = request.body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap { ($0 as? [String: Any])?["operationName"] as? String }
            return .graphQL(operation: operation ?? "")
        }
        return .other(path: request.url.path)
    }

    // MARK: - LeetCodeTransport

    func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse {
        let route = Self.route(of: request)

        lock.lock()
        sentStorage.append(request)
        let gate = gates[route]
        var queue = steps[route] ?? []
        let step = queue.first
        // The last step sticks; earlier ones are consumed.
        if queue.count > 1 {
            queue.removeFirst()
            steps[route] = queue
        }
        lock.unlock()

        gate?.wait()

        guard let step else { throw Failure.notStubbed(route) }
        if step.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
        }
        return try step.answer.get()
    }
}
