import XCTest

/// Static verification that the iOS libgit2 fetch refuses off-site redirects.
///
/// **This is a text pin, not an integration test, and it is not a proof that
/// libgit2 honours the value.** It asserts that one assignment exists, exactly
/// once, on the options `git_remote_fetch` is actually handed. What it cannot
/// see is a network: `LibGit2Service` compiles only under `#if os(iOS)`, so
/// `swift test` (Core alone, host-compiled) never builds it, the app-layer
/// bundle is macOS, and CI has no simulator. A real test of this rule would need
/// an HTTP server that answers the smart-HTTP probe with a `Location` naming a
/// *second* host, that second host answering 401 so the credentials callback
/// fires, and both of them reachable from a simulator this pipeline does not
/// have — at which point the assertion would be "no `Authorization` header ever
/// reached host two". Until that exists, the mechanism below is what stands in
/// for it.
///
/// **Why the compiler cannot see the rule:**
///
/// `git_fetch_options_init` leaves `follow_redirects` zero, and zero does not
/// mean "refuse" — it means *unspecified*, which sends libgit2 to the
/// `http.followRedirects` configuration, whose own default permits an off-site
/// redirect on the initial request. So the insecure state is the state the
/// struct arrives in: deleting the assignment does not break a build, does not
/// fail a Core test, and does not change a single visible behaviour on a
/// well-behaved host. It only means that a remote answering `302` to another
/// host gets the stored Personal Access Token presented to it.
///
/// The pin is therefore written as a *mechanism* rather than as a `contains`
/// that a comment could satisfy:
///
/// 1. It matches comment- and literal-stripped source, through the scanner every
///    other source-gating suite shares, so the prose above the assignment —
///    which names the field and the constant — cannot keep this suite green on
///    its own.
/// 2. It asserts **position**: the assignment must sit after the file's single
///    `git_fetch_options_init(` and before its single `git_remote_fetch(`, so it
///    is pinned to the options that fetch uses rather than to some other
///    `git_fetch_options` value a later edit might introduce. Those two counts
///    are also the loud-vacuity guard — a file that lost either call satisfies
///    the ordering rule trivially, so the ordering assertion is only meaningful
///    once both are known to occur exactly once.
/// 3. It asserts **identity**, which position alone cannot: the value the policy
///    is assigned *to* must be the value `git_remote_fetch` is handed. libgit2
///    accepts `NULL` fetch options and falls back to its own defaults, so
///    `git_remote_fetch(remote, nil, nil, nil)` restores the exact vulnerable
///    behaviour while leaving a correctly-ordered, correctly-spelled assignment
///    sitting above it — mutating a value nothing reads, which is not even an
///    unused-variable warning. So the receiver of the assignment is read out of
///    the source, and required to be both what `git_fetch_options_init` was
///    handed and what the fetch call carries.
/// 4. It forbids the two permissive constants anywhere in the stripped file, so
///    "hardening" this into `GIT_REMOTE_REDIRECT_INITIAL` — which is precisely
///    the default the assignment exists to overrule — fails here instead of
///    passing quietly.
final class LibGit2FetchSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let relativePath = "Sources/Pisaka/iOS/LibGit2Service.swift"

    /// The service's source with comments and string literals removed.
    private func strippedSource() throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(Self.relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        return LSPSourceGatingTests.strippingCommentsAndStringLiterals(source)
    }

    /// The UTF-16 offsets at which `pattern` matches `code`.
    ///
    /// One search, regular-expression shaped, spelled the way
    /// `LocalHistorySourceGatingTests` already spells it; a landmark that is a
    /// plain string goes through ``literal(_:)`` rather than getting a second,
    /// differently-shaped search of its own. UTF-16 offsets, so every landmark
    /// here is comparable without a second index space in the middle.
    private func offsets(of pattern: String, in code: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: code, range: NSRange(code.startIndex..., in: code))
        return matches.map(\.range.location)
    }

    /// `text` as a pattern that matches itself and nothing else.
    private func literal(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text)
    }

    // MARK: - The loud-vacuity guard

    /// The file is readable, non-empty, and contains exactly one options
    /// initialization and exactly one fetch call.
    ///
    /// Both halves matter. A path that stopped resolving, or a scanner that
    /// swallowed the file, would make every `contains`-shaped assertion below
    /// pass by matching nothing; and the ordering rule is only a rule while
    /// there is exactly one of each landmark to order against.
    func testTheServiceIsReadableAndHasOneFetchCallToPinAgainst() throws {
        let code = try strippedSource()
        XCTAssertFalse(
            code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(Self.relativePath) read as empty — the pin below would be vacuous"
        )
        XCTAssertEqual(
            try offsets(of: literal("git_fetch_options_init("), in: code).count, 1,
            "expected exactly one git_fetch_options_init( in \(Self.relativePath)"
        )
        XCTAssertEqual(
            try offsets(of: literal("git_remote_fetch("), in: code).count, 1,
            "expected exactly one git_remote_fetch( in \(Self.relativePath)"
        )
    }

    // MARK: - The rule

    /// `follow_redirects` is set to `GIT_REMOTE_REDIRECT_NONE` exactly once, on
    /// the options the fetch is handed.
    ///
    /// Whitespace-insensitive, because how the assignment is spelled is not the
    /// rule; that it is made, once, between the initialization and the call is.
    func testFetchRefusesOffSiteRedirects() throws {
        let code = try strippedSource()
        let assignments = try offsets(
            of: #"follow_redirects\s*=\s*GIT_REMOTE_REDIRECT_NONE"#,
            in: code
        )
        XCTAssertEqual(
            assignments.count, 1,
            """
            expected exactly one `follow_redirects = GIT_REMOTE_REDIRECT_NONE` in \
            \(Self.relativePath): git_fetch_options_init leaves the field zero, which \
            libgit2 reads as unspecified and resolves through http.followRedirects, \
            whose default allows an initial off-site redirect — and a stored Personal \
            Access Token would be presented to whatever host it named
            """
        )
        // `XCTUnwrap`, never `guard … else { return }`: a landmark that disappeared
        // would otherwise make the two ordering assertions below vanish silently,
        // leaving a green test that asserted nothing about order. The vacuity guard
        // above is a *different* test method, so it cannot speak for this one.
        let assignment = try XCTUnwrap(
            assignments.first,
            "no redirect-policy assignment to order — the rule below was not evaluated"
        )
        let initialization = try XCTUnwrap(
            try offsets(of: literal("git_fetch_options_init("), in: code).first,
            "no git_fetch_options_init( to order against — the rule below was not evaluated"
        )
        let fetchCall = try XCTUnwrap(
            try offsets(of: literal("git_remote_fetch("), in: code).first,
            "no git_remote_fetch( to order against — the rule below was not evaluated"
        )
        XCTAssertTrue(
            initialization < assignment,
            "the redirect policy must be set after git_fetch_options_init, which would otherwise overwrite it"
        )
        XCTAssertTrue(
            assignment < fetchCall,
            "the redirect policy must be set before git_remote_fetch, on the options that fetch is handed"
        )
    }

    /// The options carrying the policy are the options `git_remote_fetch` is handed.
    ///
    /// Position is not identity. libgit2 accepts `NULL` fetch options and falls
    /// back to its own defaults — which is the vulnerable state — so
    /// `git_remote_fetch(remotePointer, nil, nil, nil)` would leave the ordering
    /// rule above satisfied by an assignment to a value nobody reads. The
    /// receiver is therefore read out of the assignment itself and required to be
    /// both what `git_fetch_options_init` was handed and what the fetch call
    /// carries, so the three references are pinned to one variable rather than to
    /// three independently plausible spellings.
    func testTheFetchIsHandedTheOptionsCarryingThePolicy() throws {
        let code = try strippedSource()
        let receiverPattern = #"([A-Za-z_][A-Za-z0-9_]*)\.follow_redirects\s*=\s*GIT_REMOTE_REDIRECT_NONE"#
        let regex = try NSRegularExpression(pattern: receiverPattern)
        let text = code as NSString
        let matches = regex.matches(in: code, range: NSRange(location: 0, length: text.length))
        let match = try XCTUnwrap(
            matches.first,
            """
            no `<options>.follow_redirects = GIT_REMOTE_REDIRECT_NONE` in \(Self.relativePath) \
            — the identity rule below was not evaluated
            """
        )
        let receiver = text.substring(with: match.range(at: 1))

        XCTAssertEqual(
            try offsets(of: #"git_fetch_options_init\(\s*&"# + literal(receiver) + #"\b"#, in: code).count, 1,
            "git_fetch_options_init must initialize &\(receiver), the value the redirect policy is set on"
        )
        XCTAssertEqual(
            try offsets(of: #"git_remote_fetch\([^)]*&"# + literal(receiver) + #"\b"#, in: code).count, 1,
            """
            git_remote_fetch must be handed &\(receiver) in \(Self.relativePath): libgit2 accepts NULL \
            fetch options and falls back to its own defaults, so passing nil there restores the \
            off-site redirect the assignment above exists to refuse — while leaving that assignment \
            correctly spelled and correctly positioned
            """
        )
    }

    /// Neither permissive constant appears in the file.
    ///
    /// `GIT_REMOTE_REDIRECT_INITIAL` is the configuration default this
    /// assignment exists to overrule, so naming it here would be the
    /// regression wearing the fix's clothes; `GIT_REMOTE_REDIRECT_ALL` is
    /// strictly worse. Read on the stripped source: prose that *discusses*
    /// either constant is not a policy, and the entry in `app-ios.md` is where
    /// that discussion belongs.
    func testNoPermissiveRedirectPolicyIsNamed() throws {
        let code = try strippedSource()
        for constant in ["GIT_REMOTE_REDIRECT_INITIAL", "GIT_REMOTE_REDIRECT_ALL"] {
            XCTAssertTrue(
                try offsets(of: literal(constant), in: code).isEmpty,
                "\(constant) must not appear in \(Self.relativePath) — off-site redirects carry the PAT to another host"
            )
        }
    }
}
