import XCTest
@testable import PisakaCore

final class SyntaxLanguageTests: XCTestCase {
    // MARK: - Known extensions

    func testKnownExtensionsMapToExpectedLanguage() {
        let expected: [String: SyntaxLanguage] = [
            "swift": .swift,
            "js": .javascript,
            "jsx": .javascript,
            "mjs": .javascript,
            "cjs": .javascript,
            "ts": .typescript,
            "tsx": .typescript,
            "json": .json,
            "md": .markdown,
            "markdown": .markdown,
            "py": .python,
            "go": .go,
            "rs": .rust,
            "html": .html,
            "htm": .html,
            "css": .css,
            "yml": .yaml,
            "yaml": .yaml,
            "dockerfile": .dockerfile
        ]

        for (ext, language) in expected {
            XCTAssertEqual(SyntaxLanguage(fileExtension: ext), language, "extension \(ext)")
        }
    }

    // MARK: - Case insensitivity

    func testExtensionLookupIsCaseInsensitive() {
        XCTAssertEqual(SyntaxLanguage(fileExtension: "SWIFT"), .swift)
        XCTAssertEqual(SyntaxLanguage(fileExtension: "Swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(fileExtension: "JSON"), .json)
        XCTAssertEqual(SyntaxLanguage(fileExtension: "yAmL"), .yaml)
    }

    // MARK: - Unknown / missing extension

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(SyntaxLanguage(fileExtension: ""))
        XCTAssertNil(SyntaxLanguage(fileExtension: "xyz"))
    }

    // MARK: - From file name

    func testInitFromFileNameDerivesExtension() {
        XCTAssertEqual(SyntaxLanguage(forFileName: "Main.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(forFileName: "app.ts"), .typescript)
        XCTAssertEqual(SyntaxLanguage(forFileName: "README.md"), .markdown)
        XCTAssertEqual(SyntaxLanguage(forFileName: "INDEX.HTML"), .html)
        XCTAssertEqual(SyntaxLanguage(forFileName: "deeply.nested.name.json"), .json)
    }

    func testInitFromFileNameWithNoExtensionReturnsNil() {
        XCTAssertNil(SyntaxLanguage(forFileName: "Makefile"))
        XCTAssertNil(SyntaxLanguage(forFileName: "LICENSE"))
        XCTAssertNil(SyntaxLanguage(forFileName: "README"))
        XCTAssertNil(SyntaxLanguage(forFileName: ""))
    }

    func testInitFromFileNameWithUnknownExtensionReturnsNil() {
        XCTAssertNil(SyntaxLanguage(forFileName: "archive.zip"))
        XCTAssertNil(SyntaxLanguage(forFileName: "notes.rst"))
    }

    // MARK: - Dockerfile

    func testDockerfileNamesResolve() {
        XCTAssertEqual(SyntaxLanguage(forFileName: "Dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "DOCKERFILE"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "Dockerfile.dev"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "Dockerfile.prod"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "web.dockerfile"), .dockerfile)
    }

    func testDockerfileLookalikesDoNotResolve() {
        XCTAssertNil(SyntaxLanguage(forFileName: "Dockerfileish"))
        XCTAssertNil(SyntaxLanguage(forFileName: "docker"))
        XCTAssertNil(SyntaxLanguage(forFileName: "mydockerfile"))
    }

    // MARK: - dotenv

    func testDotenvNamesResolve() {
        XCTAssertEqual(SyntaxLanguage(forFileName: ".env"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".ENV"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".env.local"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".env.production"), .dotenv)
    }

    func testDotenvLookalikesDoNotResolve() {
        XCTAssertNil(SyntaxLanguage(forFileName: "env"))
        XCTAssertNil(SyntaxLanguage(forFileName: "myenv.txt"))
        XCTAssertNil(SyntaxLanguage(forFileName: "envfile"))
        XCTAssertNil(SyntaxLanguage(forFileName: ".environment"))
    }

    // MARK: - gitignore (dot-ignore shape)

    func testDotIgnoreShapeResolves() {
        // One syntactic family, one rule: a dot-file whose name ends in "ignore".
        XCTAssertEqual(SyntaxLanguage(forFileName: ".gitignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".dockerignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".npmignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".eslintignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".prettierignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".ignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".GITIGNORE"), .gitignore)
    }

    func testDotIgnoreShapeRejectsNonDotFiles() {
        // The dot is the convention that makes this a family; without it the name
        // is an ordinary file that merely ends in "ignore".
        XCTAssertNil(SyntaxLanguage(forFileName: "foo.ignore"))
        XCTAssertNil(SyntaxLanguage(forFileName: "gitignore"))
        XCTAssertNil(SyntaxLanguage(forFileName: "ignore"))
        XCTAssertNil(SyntaxLanguage(forFileName: "."))
        XCTAssertNil(SyntaxLanguage(forFileName: ".ignored"))
    }

    // MARK: - Go

    func testGoNamesResolve() {
        // Go is an ordinary extension language: it resolves in phase 2 and no
        // later, looser phase may claim or re-claim it.
        XCTAssertEqual(SyntaxLanguage(forFileName: "main.go"), .go)
        XCTAssertEqual(SyntaxLanguage(forFileName: "MAIN.GO"), .go)
        XCTAssertEqual(SyntaxLanguage(forFileName: "handler_test.go"), .go)
        XCTAssertEqual(SyntaxLanguage(forFileName: "cmd/server/main.go"), .go)
    }

    func testGoLookalikesDoNotResolveToGo() {
        // A bare `go` is the toolchain's name, not a source file: there is no
        // exact-name rule for it, and with no extension it reaches no phase.
        XCTAssertNil(SyntaxLanguage(forFileName: "go"))
        XCTAssertNil(SyntaxLanguage(forFileName: "go.work"))
        // `.goignore` is a dot-file ending in "ignore" with no `go` extension, so
        // the shape rule claims it — the extension phase must not.
        XCTAssertEqual(SyntaxLanguage(forFileName: ".goignore"), .gitignore)
    }

    // MARK: - Rust

    func testRustNamesResolve() {
        // Rust is an ordinary extension language, like Go: it resolves in phase 2
        // and no later, looser phase may claim or re-claim it. Rust's tests live
        // beside the code in the same file, so there is no separate test-file
        // spelling to pin here — `main.rs` and `lib.rs` are the same rule.
        XCTAssertEqual(SyntaxLanguage(forFileName: "main.rs"), .rust)
        XCTAssertEqual(SyntaxLanguage(forFileName: "MAIN.RS"), .rust)
        XCTAssertEqual(SyntaxLanguage(forFileName: "lib.rs"), .rust)
        XCTAssertEqual(SyntaxLanguage(forFileName: "src/bin/server.rs"), .rust)
    }

    func testRustLookalikesDoNotResolveToRust() {
        // No prefix or dot-ignore rule may claim a Rust-shaped name, and no
        // Rust rule may claim a neighbour's: `Cargo.toml` is the manifest (TOML
        // is not a language here at all), `rustfmt.toml` likewise, and a bare
        // `rs` has no extension so it reaches no phase.
        XCTAssertNil(SyntaxLanguage(forFileName: "rs"))
        XCTAssertNil(SyntaxLanguage(forFileName: "Cargo.toml"))
        XCTAssertNil(SyntaxLanguage(forFileName: "rustfmt.toml"))
        XCTAssertNil(SyntaxLanguage(forFileName: "main.rs.orig"))
        // `.rsignore` is a dot-file ending in "ignore" with no `rs` extension,
        // so the shape rule claims it — the extension phase must not.
        XCTAssertEqual(SyntaxLanguage(forFileName: ".rsignore"), .gitignore)
    }

    // MARK: - SQL

    func testSqlNamesResolve() {
        XCTAssertEqual(SyntaxLanguage(forFileName: "foo.sql"), .sql)
        XCTAssertEqual(SyntaxLanguage(forFileName: "FOO.SQL"), .sql)
        XCTAssertEqual(SyntaxLanguage(forFileName: "path/to/schema.sql"), .sql)
    }
    // MARK: - Rule precedence

    func testExtensionWinsOverDotIgnoreShapeAndPrefix() {
        // Order is exact name → extension → prefix → dot-ignore shape, so an
        // explicit extension always wins. These are the inputs that actually
        // distinguish the phases: each would resolve to a *different* language if
        // the extension phase ran after the prefix or the shape rule.
        XCTAssertEqual(SyntaxLanguage(forFileName: ".env.json"), .json)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".env.yaml"), .yaml)
        XCTAssertEqual(SyntaxLanguage(forFileName: ".eslintignore.md"), .markdown)
    }

    // Phases 1 (exact name) and 2 (extension) have no distinguishing input: every
    // key of the exact-name map is extensionless, so the extension phase declines
    // for all of them and swapping the two would change nothing. There is
    // therefore no ordering test for that pair — `testDockerfileNamesResolve` /
    // `testDotenvNamesResolve` already pin that those names resolve at all.

    // MARK: - Path tolerance

    func testPathsResolveByTheirLastComponent() {
        // Only the extension phase reads the last component on its own
        // (`NSString.pathExtension`); the other three match the whole string. A
        // caller passing a repo-relative path — `ChangedFile.path` is one, and the
        // diff call sites are a single `lastPathComponent` away from handing it
        // over — must not get highlighting for `.ts` but plain text for `.env`.
        XCTAssertEqual(SyntaxLanguage(forFileName: "backend/src/app.ts"), .typescript)
        XCTAssertEqual(SyntaxLanguage(forFileName: "backend/Dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "backend/Dockerfile.dev"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(forFileName: "backend/.env"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(forFileName: "backend/.env.local"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(forFileName: "packages/web/.gitignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage(forFileName: "/abs/path/.dockerignore"), .gitignore)
        // A directory-shaped path resolves on the component before the trailing
        // slash, and a lookalike stays unmatched however it is spelled.
        XCTAssertEqual(SyntaxLanguage(forFileName: "a/b/Dockerfile/"), .dockerfile)
        XCTAssertNil(SyntaxLanguage(forFileName: "backend/foo.ignore"))
        XCTAssertNil(SyntaxLanguage(forFileName: "backend/env"))
    }

    // MARK: - Raw-value stability

    func testRawValuesAreStable() {
        // Raw values are consumed by `configuration(forInjectionName:)` for fenced
        // code blocks, so renaming one is a behavior change, not a refactor.
        // Go's raw value is also the fence info string Markdown code blocks use
        // (```go), so injection resolution reaches it through the raw value alone.
        XCTAssertEqual(SyntaxLanguage(rawValue: "go"), .go)
        XCTAssertEqual(SyntaxLanguage.go.rawValue, "go")
        // Rust's raw value is likewise the fence info string (```rust), and it
        // is *not* the extension — `configuration(forInjectionName:)` tries the
        // raw value first and the extension second, so both spellings resolve.
        XCTAssertEqual(SyntaxLanguage(rawValue: "rust"), .rust)
        XCTAssertEqual(SyntaxLanguage.rust.rawValue, "rust")
        XCTAssertEqual(SyntaxLanguage(fileExtension: "rs"), .rust)
        XCTAssertEqual(SyntaxLanguage(rawValue: "dockerfile"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage(rawValue: "dotenv"), .dotenv)
        XCTAssertEqual(SyntaxLanguage(rawValue: "gitignore"), .gitignore)
        XCTAssertEqual(SyntaxLanguage.dockerfile.rawValue, "dockerfile")
        XCTAssertEqual(SyntaxLanguage.dotenv.rawValue, "dotenv")
        XCTAssertEqual(SyntaxLanguage.gitignore.rawValue, "gitignore")
    }

    // MARK: - Enum hygiene

    func testEveryCaseIsReachableByFileName() {
        // Every declared language must be resolvable from at least one file *name*
        // (not extension alone — `Dockerfile`, `.env` and `.gitignore` carry no
        // extension). This guards against adding a `case` with no resolution rule,
        // which would leave it unreachable / always plain text.
        let knownFileNames = [
            "Main.swift", "app.js", "app.jsx", "app.mjs", "app.cjs",
            "app.ts", "app.tsx", "data.json", "README.md", "README.markdown",
            "main.py", "main.go", "main.rs", "index.html", "index.htm", "style.css",
            "config.yml", "config.yaml",
            "Dockerfile", ".env", ".gitignore", "schema.sql"
        ]
        let reachable = Set(knownFileNames.compactMap(SyntaxLanguage.init(forFileName:)))
        XCTAssertEqual(reachable, Set(SyntaxLanguage.allCases),
                       "every SyntaxLanguage case must be reachable from some file name")
    }
}
