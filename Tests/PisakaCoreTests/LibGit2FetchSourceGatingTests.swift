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
/// 1. It matches comment- and literal-stripped source, through the scanner five
///    other suites share, so the prose above the assignment — which names the
///    field and the constant — cannot keep this suite green on its own.
/// 2. It asserts **position**: the assignment must sit after the file's single
///    `git_fetch_options_init(` and before its single `git_remote_fetch(`, so it
///    is pinned to the options that fetch uses rather than to some other
///    `git_fetch_options` value a later edit might introduce. Those two counts
///    are also the loud-vacuity guard — a file that lost either call satisfies
///    the ordering rule trivially, so the ordering assertion is only meaningful
///    once both are known to occur exactly once.
/// 3. It forbids the two permissive constants anywhere in the stripped file, so
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

    /// The UTF-16 offsets at which `needle` occurs in `code`, matched literally.
    ///
    /// UTF-16, so these are comparable with the regular expression's own match
    /// locations without a second index space in the middle.
    private func offsets(of needle: String, in code: String) -> [Int] {
        let text = code as NSString
        var found: [Int] = []
        var searchStart = 0
        while searchStart < text.length {
            let remaining = NSRange(location: searchStart, length: text.length - searchStart)
            let range = text.range(of: needle, options: [.literal], range: remaining)
            guard range.location != NSNotFound else { break }
            found.append(range.location)
            searchStart = range.location + max(range.length, 1)
        }
        return found
    }

    /// The UTF-16 offsets at which `pattern` matches `code`.
    private func matchOffsets(of pattern: String, in code: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: code, range: NSRange(code.startIndex..., in: code))
        return matches.map(\.range.location)
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
            offsets(of: "git_fetch_options_init(", in: code).count, 1,
            "expected exactly one git_fetch_options_init( in \(Self.relativePath)"
        )
        XCTAssertEqual(
            offsets(of: "git_remote_fetch(", in: code).count, 1,
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
        let assignments = try matchOffsets(
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
        guard let assignment = assignments.first,
              let initialization = offsets(of: "git_fetch_options_init(", in: code).first,
              let fetchCall = offsets(of: "git_remote_fetch(", in: code).first else { return }
        XCTAssertTrue(
            initialization < assignment,
            "the redirect policy must be set after git_fetch_options_init, which would otherwise overwrite it"
        )
        XCTAssertTrue(
            assignment < fetchCall,
            "the redirect policy must be set before git_remote_fetch, on the options that fetch is handed"
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
                offsets(of: constant, in: code).isEmpty,
                "\(constant) must not appear in \(Self.relativePath) — off-site redirects carry the PAT to another host"
            )
        }
    }
}
