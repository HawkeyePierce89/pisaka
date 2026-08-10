import XCTest

/// Static verification that the LSP layer's platform split is where the
/// architecture says it is.
///
/// A repository-file suite in the `VendoredGrammarQueryTests`/`ReleaseMetadataTests`
/// mould: it reads `Sources/` through `#filePath` with Foundation only, so it runs
/// in `swift test` without an Xcode build — which matters here more than usual,
/// because `swift test` compiles `PisakaCore` alone and therefore *cannot* catch
/// either failure this suite exists for.
///
/// **Why the compiler is not enough.** The Core half is checked by the iOS build:
/// a `Process` or an `import AppKit` in `Sources/PisakaCore/LSP*.swift` fails
/// `xcodebuild -destination 'generic/platform=iOS'` — but only after somebody
/// pushes and waits for CI, and only if the offending call happens to be in a
/// platform-unavailable API rather than one iOS also has. The app half is worse:
/// a new `Sources/Pisaka` LSP file that *forgets* its `#if os(macOS)` compiles
/// perfectly well on macOS, and breaks the iOS build with an error naming
/// something several layers down from the actual mistake. Both are cheap to
/// assert here and expensive to diagnose later.
///
/// **Comments are stripped before anything is matched**, and that is not a
/// refinement — it is the only way the check can exist. `LSPWorkspace`'s own
/// documentation opens with "**`Process` is not in this file, and cannot be**",
/// `LSPTransport` explains that the app owns "a `Process` and three pipes", and
/// `LSPIntelligenceProvider` discusses what "AppKit's stock insertion" does. A
/// substring search over raw source would fail on all three, and the obvious fix —
/// rewording the documentation to appease a test — is the wrong direction
/// entirely. String literals are stripped for the same reason.
final class LSPSourceGatingTests: XCTestCase {
    /// The app-side files that must exist and must be macOS-gated. Named
    /// explicitly *as well as* discovered, so a rename does not quietly empty the
    /// sweep and leave a passing suite that checks nothing.
    private static let expectedAppFiles: Set<String> = [
        "LSPArchiveUnpacker.swift",
        "LSPConsentBanner.swift",
        "LSPDownloadService.swift",
        "LSPGoToolchainService.swift",
        "LSPInstalledLicenses.swift",
        "LSPProcessTransport.swift",
        "LSPRustToolchainService.swift",
        "LSPServerSettingsView.swift",
        "LSPToolchain.swift",
        "SourceViewerContent.swift",
        "SourceViewerWindowController.swift",
    ]

    /// File-name prefixes that mark a file as belonging to this layer. `LSP` is
    /// the obvious one; `SourceViewer` is here because the read-only definition
    /// viewer is app-side machinery this layer introduced (an out-of-root jump
    /// has nowhere else to land) and is exactly as dependent on `AppKit` — a
    /// forgotten `#if os(macOS)` there breaks the iOS build the same way, and a
    /// prefix-only sweep would not have noticed.
    private static let appFilePrefixes = ["LSP", "SourceViewer"]

    /// The same, for Core. `CompletionEditPlan` and `RoutingIntelligenceProvider`
    /// carry no `LSP` prefix — they are named for what they decide rather than for
    /// the protocol that made them necessary — but they are the layer's Core
    /// surface just as much as `LSPSession` is, and the Foundation-only rule is
    /// about the whole of it.
    ///
    /// `SHA256` is here for a sharper version of the same reason. It exists only
    /// because provisioning must verify what it downloads and Core cannot link
    /// `CryptoKit`, and the *one* way it could be quietly ruined is somebody
    /// deleting 200 lines of bit-twiddling in favour of `import CryptoKit` — which
    /// would compile on both destinations, pass every digest test, and make the
    /// domain library depend on a platform framework. The import assertion below is
    /// what says no.
    private static let coreFilePrefixes = [
        "LSP",
        "CompletionEditPlan",
        "RoutingIntelligenceProvider",
        "SHA256",
    ]

    /// The Core-side files, named for the same reason the app-side ones are: the
    /// prefix sweep is what *finds* them, and the list is what says the sweep
    /// found what it was supposed to. A rename that empties one of the prefixes
    /// leaves a suite that still passes every "does not contain" assertion below
    /// while checking a shorter and shorter list of files.
    private static let expectedCoreFiles: Set<String> = [
        "CompletionEditPlan.swift",
        "LSPFraming.swift",
        "LSPGoToolchain.swift",
        "LSPGoplsProvisioning.swift",
        "LSPInstallEngine.swift",
        "LSPInstallLayout.swift",
        "LSPIntelligenceProvider.swift",
        "LSPMessage.swift",
        "LSPPositionMap.swift",
        "LSPProtocolTypes.swift",
        "LSPProvisioning.swift",
        "LSPProvisioningManifest.swift",
        "LSPRustProvisioning.swift",
        "LSPRustToolchain.swift",
        "LSPServerDescription.swift",
        "LSPSession.swift",
        "LSPTransport.swift",
        "LSPWorkspace.swift",
        "RoutingIntelligenceProvider.swift",
        "SHA256.swift",
    ]

    /// Identifiers that must not appear in Core's LSP files. `Process` is matched
    /// as a whole token, so `ProcessInfo` and `processIdentifier` — both of which
    /// `LSPWorkspace` legitimately uses — are not false positives; what is being
    /// banned is spawning one.
    private static let forbiddenInCore = ["Process", "AppKit", "UIKit", "SwiftTreeSitter"]

    // MARK: - The app half

    func testEveryAppLSPFileIsGatedToMacOS() throws {
        let files = try appLSPFiles()
        XCTAssertFalse(files.isEmpty, "no Sources/Pisaka files of this layer found — the sweep is broken")

        for url in files {
            let lines = try significantLines(of: url)
            let name = url.lastPathComponent
            XCTAssertEqual(
                lines.first, "#if os(macOS)",
                "\(name) must open with #if os(macOS): it links Process/AppKit and cannot compile for iOS"
            )
            XCTAssertEqual(
                lines.last, "#endif",
                "\(name) must close its #if os(macOS) with #endif"
            )
        }
    }

    /// Set equality, not containment, in the `SymbolQueryTests` mould: containment
    /// alone catches a rename that empties the sweep, but says nothing when the
    /// sweep grows. A new file matching one of the prefixes is a file somebody has
    /// to have looked at — and the list is what the *next* reader consults to know
    /// what this layer put in the app.
    func testTheDiscoveredAppFilesAreExactlyTheExpectedOnes() throws {
        let found = Set(try appLSPFiles().map(\.lastPathComponent))
        XCTAssertEqual(
            found, Self.expectedAppFiles,
            "the app-side file set changed; if a file was added or renamed, update expectedAppFiles"
        )
    }

    // MARK: - The Core half

    func testNoCoreLSPFileReachesForAPlatformFramework() throws {
        let files = try coreLSPFiles()
        XCTAssertFalse(files.isEmpty, "no Sources/PisakaCore files of this layer found — the sweep is broken")

        for url in files {
            let code = Self.strippingCommentsAndStringLiterals(try read(url))
            for identifier in Self.forbiddenInCore {
                XCTAssertFalse(
                    Self.containsToken(identifier, in: code),
                    "\(url.lastPathComponent) uses \(identifier); Core stays Foundation-only "
                    + "(the app owns the process — see LSPProcessTransport)"
                )
            }
        }
    }

    func testEveryCoreLSPFileImportsFoundationAndNothingElse() throws {
        for url in try coreLSPFiles() {
            let code = Self.strippingCommentsAndStringLiterals(try read(url))
            let imports = code
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
                .map { String($0.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(
                Set(imports), ["Foundation"],
                "\(url.lastPathComponent) imports \(imports) — Core's LSP layer is Foundation-only"
            )
        }
    }

    /// Set equality, for the app side's reason and with one of its own: the Core
    /// half's assertions are all *negative* ("does not mention `Process`", "imports
    /// nothing but Foundation"), and a negative assertion over a set that quietly
    /// shrank is indistinguishable from a passing one. Pinning the set is what
    /// makes "the whole layer was checked" a claim the suite can fail on — and,
    /// like the app-side list, it is what the next reader consults to know what
    /// this layer put in Core.
    func testTheDiscoveredCoreFilesAreExactlyTheExpectedOnes() throws {
        let found = Set(try coreLSPFiles().map(\.lastPathComponent))
        XCTAssertEqual(
            found, Self.expectedCoreFiles,
            "the Core-side file set changed; if a file was added or renamed, update expectedCoreFiles"
        )
    }

    func testNoCoreLSPFileCarriesAPlatformConditional() throws {
        // Core compiles identically everywhere (the `CrossPlatformAuditTests`
        // premise). An `#if os(...)` here would mean a protocol that behaves
        // differently on iOS, which is exactly the drift the transport seam exists
        // to prevent.
        for url in try coreLSPFiles() {
            let code = Self.strippingCommentsAndStringLiterals(try read(url))
            XCTAssertFalse(
                code.contains("#if os("),
                "\(url.lastPathComponent) is platform-conditional; the seam is LSPTransport, not #if"
            )
        }
    }

    // MARK: - The scanner, checked against itself

    /// The suite is only worth as much as its scanner: a stripper that returned
    /// the empty string would pass every "does not contain" assertion above and
    /// check nothing at all. So the mechanism is pinned directly — prose and
    /// literals are dropped, code is kept, and `Process` is told apart from
    /// `ProcessInfo`.
    func testTheScannerReadsCodeAndNotProse() {
        let source = """
        // The app owns a `Process` and three pipes.
        /* AppKit is discussed here: /* nested */ still a comment */
        let label = "UIKit"
        let info = ProcessInfo.processInfo.processIdentifier
        let live = Process()
        """
        let code = Self.strippingCommentsAndStringLiterals(source)

        XCTAssertFalse(Self.containsToken("AppKit", in: code), "a block comment survived")
        XCTAssertFalse(Self.containsToken("UIKit", in: code), "a string literal survived")
        XCTAssertTrue(Self.containsToken("Process", in: code), "real code was stripped")
        XCTAssertTrue(code.contains("ProcessInfo"), "real code was stripped")
        XCTAssertEqual(code.components(separatedBy: "\n").count, 5, "the line shape was not preserved")

        // The whole-token rule, stated on its own: these three lines are what
        // `LSPWorkspace` actually contains, and none of them may trip the ban.
        XCTAssertFalse(Self.containsToken("Process", in: "ProcessInfo.processInfo"))
        XCTAssertFalse(Self.containsToken("Process", in: "let processID: Int?"))
        XCTAssertFalse(Self.containsToken("Process", in: "processIdentifier"))
        XCTAssertTrue(Self.containsToken("Process", in: "try Process().run()"))
    }

    // MARK: - Reading the repository

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// This layer's files under `Sources/Pisaka`, at any depth — a future
    /// `Platform/` or `iOS/` file is swept without anyone remembering to add a
    /// directory here.
    private func appLSPFiles() throws -> [URL] {
        try files(
            under: Self.repositoryRoot.appendingPathComponent("Sources/Pisaka"),
            prefixedBy: Self.appFilePrefixes
        )
    }

    private func coreLSPFiles() throws -> [URL] {
        try files(
            under: Self.repositoryRoot.appendingPathComponent("Sources/PisakaCore"),
            prefixedBy: Self.coreFilePrefixes
        )
    }

    private func files(under directory: URL, prefixedBy prefixes: [String]) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { url in
                url.pathExtension == "swift"
                    && prefixes.contains { url.lastPathComponent.hasPrefix($0) }
            }
            .sorted { $0.path < $1.path }
    }

    /// The file's lines with comments stripped and blanks dropped — what the
    /// `#if os(macOS)` wrapper assertion reads, so a file may open with as much
    /// documentation as it likes.
    private func significantLines(of url: URL) throws -> [String] {
        Self.strippingCommentsAndStringLiterals(try read(url))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - The scanner

    /// `identifier` as a whole word: not preceded or followed by an identifier
    /// character. This is what keeps `ProcessInfo` and `processIdentifier` out of
    /// the `Process` ban.
    static func containsToken(_ identifier: String, in code: String) -> Bool {
        let characters = Array(code)
        let needle = Array(identifier)
        guard characters.count >= needle.count else { return false }
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        for start in 0...(characters.count - needle.count) {
            guard Array(characters[start..<(start + needle.count)]) == needle else { continue }
            if start > 0, isIdentifierCharacter(characters[start - 1]) { continue }
            let after = start + needle.count
            if after < characters.count, isIdentifierCharacter(characters[after]) { continue }
            return true
        }
        return false
    }

    /// Swift source with `//` comments, `/* */` comments (nested, as Swift allows)
    /// and string literals removed, newlines preserved so line-oriented assertions
    /// still work.
    ///
    /// Not a parser and does not need to be: it is exact on the constructs this
    /// repository's LSP files actually contain. Where it is approximate it is so
    /// in the *lenient* direction — the contents of a string interpolation are
    /// dropped along with the literal around them — which is the right way round
    /// for a check whose failure message asks a human to reword something.
    static func strippingCommentsAndStringLiterals(_ source: String) -> String {
        enum State {
            case code
            case lineComment
            case blockComment(depth: Int)
            case string
            case multilineString
        }

        let characters = Array(source)
        var result = ""
        var state = State.code
        var index = 0

        func matches(_ text: String, at position: Int) -> Bool {
            let needle = Array(text)
            guard position + needle.count <= characters.count else { return false }
            return Array(characters[position..<(position + needle.count)]) == needle
        }

        while index < characters.count {
            let character = characters[index]
            switch state {
            case .code:
                if matches("//", at: index) {
                    state = .lineComment
                    index += 2
                } else if matches("/*", at: index) {
                    state = .blockComment(depth: 1)
                    index += 2
                } else if matches("\"\"\"", at: index) {
                    state = .multilineString
                    index += 3
                } else if character == "\"" {
                    state = .string
                    index += 1
                } else {
                    result.append(character)
                    index += 1
                }
            case .lineComment:
                if character == "\n" {
                    state = .code
                    result.append(character)
                }
                index += 1
            case .blockComment(let depth):
                if matches("/*", at: index) {
                    state = .blockComment(depth: depth + 1)
                    index += 2
                } else if matches("*/", at: index) {
                    state = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    index += 2
                } else {
                    // Newlines survive so the stripped text keeps its line shape.
                    if character == "\n" { result.append(character) }
                    index += 1
                }
            case .string:
                if character == "\\" {
                    index += 2
                } else if character == "\"" {
                    state = .code
                    index += 1
                } else {
                    if character == "\n" {
                        // An unterminated literal: bail back to code rather than
                        // swallowing the rest of the file.
                        state = .code
                        result.append(character)
                    }
                    index += 1
                }
            case .multilineString:
                if matches("\"\"\"", at: index) {
                    state = .code
                    index += 3
                } else {
                    if character == "\n" { result.append(character) }
                    index += 1
                }
            }
        }
        return result
    }
}
