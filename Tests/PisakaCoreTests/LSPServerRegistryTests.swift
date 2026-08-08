import XCTest
@testable import PisakaCore

/// The registry is the whole of D9's promise that "adding a server is one entry",
/// so what is pinned here is the *data*: which language reaches which description,
/// what the shipped Swift entry says, and that the language→server map is total
/// and unambiguous.
final class LSPServerRegistryTests: XCTestCase {

    // MARK: - The shipped entry

    func testTheStandardRegistryShipsSourcekitLSPForSwiftAndNothingElse() {
        let registry = LSPServerRegistry.standard

        XCTAssertEqual(registry.descriptions.map(\.id), ["sourcekit-lsp"])
        XCTAssertEqual(registry.servedLanguages, [.swift])
        XCTAssertEqual(registry.description(for: .swift)?.id, "sourcekit-lsp")

        // Every other language the editor knows keeps today's tree-sitter answers,
        // and does so by there being nothing here to ask.
        for language in SyntaxLanguage.allCases where language != .swift {
            XCTAssertNil(registry.description(for: language), "\(language) must not be served in 2a")
            XCTAssertFalse(registry.servesLanguage(language))
        }
    }

    func testSourcekitLSPIsFoundThroughTheToolchainWithNoArgumentsOrOptions() {
        let description = LSPServerDescription.sourcekitLSP

        // Resolved with `xcrun --find` by the app, never a hard-coded path: the
        // binary moves with `xcode-select`.
        XCTAssertEqual(description.launch, .toolchainTool(name: "sourcekit-lsp"))
        XCTAssertEqual(description.arguments, [])
        XCTAssertNil(description.initializationOptions)
        XCTAssertEqual(description.languages, [.swift])
    }

    func testTheEmptyRegistryServesNothing() {
        let registry = LSPServerRegistry.empty

        XCTAssertTrue(registry.servedLanguages.isEmpty)
        for language in SyntaxLanguage.allCases {
            XCTAssertNil(registry.description(for: language))
        }
    }

    // MARK: - Composition

    func testOneDescriptionCanServeSeveralLanguages() {
        let node = LSPServerDescription(
            id: "typescript-language-server",
            languages: [.typescript, .javascript],
            launch: .executable(path: "/usr/local/bin/typescript-language-server"),
            arguments: ["--stdio"]
        )
        let registry = LSPServerRegistry([node])

        XCTAssertEqual(registry.description(for: .typescript)?.id, node.id)
        XCTAssertEqual(registry.description(for: .javascript)?.id, node.id)
        XCTAssertEqual(registry.servedLanguages, [.typescript, .javascript])
    }

    func testTheFirstDescriptionToClaimALanguageWins() {
        let first = LSPServerDescription(
            id: "first",
            languages: [.python],
            launch: .executable(path: "/bin/first")
        )
        let second = LSPServerDescription(
            id: "second",
            languages: [.python, .yaml],
            launch: .executable(path: "/bin/second")
        )
        let registry = LSPServerRegistry([first, second])

        // Stated rather than incidental: composition order is how a caller
        // overrides a stock server without having to remove it.
        XCTAssertEqual(registry.description(for: .python)?.id, "first")
        // The loser still serves the language nobody contested.
        XCTAssertEqual(registry.description(for: .yaml)?.id, "second")
    }

    func testAddingAServerIsOneEntry() {
        // D9's claim, asserted as a value change: the standard registry plus one
        // description serves one more language, and nothing else moves.
        let extra = LSPServerDescription(
            id: "pyright",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/pyright-langserver"),
            arguments: ["--stdio"],
            initializationOptions: .object(["python": .object(["analysis": .object([:])])])
        )
        let registry = LSPServerRegistry(LSPServerRegistry.standard.descriptions + [extra])

        XCTAssertEqual(registry.servedLanguages, [.swift, .python])
        XCTAssertEqual(registry.description(for: .swift)?.id, "sourcekit-lsp")
        XCTAssertEqual(registry.description(for: .python)?.arguments, ["--stdio"])
        XCTAssertEqual(
            registry.description(for: .python)?.initializationOptions?["python"]?["analysis"],
            .object([:])
        )
    }

    // MARK: - Language identifiers

    func testEveryLanguageHasADistinctNonEmptyLSPIdentifier() {
        // The `languageId` a `didOpen` carries is what a server keys its parser
        // off. The mapping is a `switch`, so it is total by construction; what a
        // test can add is that no case is spelled as the empty string and that two
        // languages never claim one identifier.
        let identifiers = SyntaxLanguage.allCases.map(\.lspLanguageID)

        for (language, identifier) in zip(SyntaxLanguage.allCases, identifiers) {
            XCTAssertFalse(identifier.isEmpty, "\(language) has no LSP identifier")
        }
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "two languages share an identifier")
    }

    func testTheIdentifiersThatAreNotTheRawValueAreSpelledTheWayServersExpect() {
        XCTAssertEqual(SyntaxLanguage.swift.lspLanguageID, "swift")
        XCTAssertEqual(SyntaxLanguage.typescript.lspLanguageID, "typescript")
        XCTAssertEqual(SyntaxLanguage.markdown.lspLanguageID, "markdown")
        // The whole gitignore family is `ignore` to every editor that names it.
        XCTAssertEqual(SyntaxLanguage.gitignore.lspLanguageID, "ignore")
    }
}
