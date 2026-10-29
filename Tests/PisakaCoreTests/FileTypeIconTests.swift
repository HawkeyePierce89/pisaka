import XCTest
@testable import PisakaCore

/// Pins `FileTypeIcon`, the Core table naming which picture of the vendored
/// file-icon set stands for a file.
///
/// Inventory:
/// - the six phases' order, each case where an earlier phase must beat a later
///   one written out (`testDatabaseRuleBeatsEverything` through
///   `testLanguagePhaseKeepsSyntaxLanguagesOwnOrder`);
/// - case-insensitivity and path tolerance (`testMatchingIsCaseInsensitiveAndReadsTheLastComponent`);
/// - the floor: every name the retired SF Symbol table special-cased still
///   resolves to a named icon (`testTheSpecialCasedNamesOfTheOldTableKeepANamedIcon`);
/// - every sub-table written out literally (`specialNames`, `compoundSuffixes`,
///   `extensions`), so a changed row is a failing row;
/// - every `SyntaxLanguage` case by set equality, and every name and extension
///   the language's internal seams expose, with the one override pinned as a set
///   (`testEverySeamEntryAnswersItsLanguageExceptTheOneOverride`);
/// - reachability: the answers over every sample name in this file equal
///   `Set(FileTypeIcon.allCases)`, so no case ships as a dead asset;
/// - the fallback and the namespaced catalog name.
final class FileTypeIconTests: XCTestCase {
    // MARK: - Sample tables

    /// Phase 2, every exact name plus examples of each stem and prefix row.
    private let specialNames: [String: FileTypeIcon] = [
        // Exact names.
        "package.json": .nodejs,
        ".nvmrc": .nodejs,
        ".node-version": .nodejs,
        "package-lock.json": .npm,
        ".npmrc": .npm,
        ".npmignore": .npm,
        "yarn.lock": .yarn,
        ".yarnrc": .yarn,
        ".yarnrc.yml": .yarn,
        "pnpm-lock.yaml": .pnpm,
        "pnpm-workspace.yaml": .pnpm,
        ".gitattributes": .git,
        ".gitmodules": .git,
        ".gitkeep": .git,
        ".dockerignore": .docker,
        "compose.yml": .docker,
        "compose.yaml": .docker,
        ".prettierignore": .prettier,
        ".eslintignore": .eslint,
        "CODEOWNERS": .codeowners,
        "robots.txt": .robots,
        // Stems: the bare stem and the stem followed by a dot.
        "README": .readme,
        "README.md": .readme,
        "CHANGELOG.md": .changelog,
        "CONTRIBUTING.md": .contributing,
        "LICENSE": .license,
        "LICENSE.md": .license,
        "license.txt": .license,
        "docker-compose.yml": .docker,
        "docker-compose.override.yaml": .docker,
        // Prefixes.
        "tsconfig.json": .tsconfig,
        "tsconfig.app.json": .tsconfig,
        ".prettierrc": .prettier,
        ".prettierrc.json": .prettier,
        "prettier.config.js": .prettier,
        ".eslintrc": .eslint,
        ".eslintrc.cjs": .eslint,
        "eslint.config.mjs": .eslint,
        "vitest.config.ts": .vitest,
        "vitest.workspace.ts": .vitest,
        "jest.config.js": .jest,
    ]

    /// Phase 3, every compound suffix.
    private let compoundSuffixes: [String: FileTypeIcon] = [
        "app.test.ts": .testTS,
        "app.spec.ts": .testTS,
        "App.test.tsx": .testJSX,
        "App.spec.tsx": .testJSX,
        "App.test.jsx": .testJSX,
        "App.spec.jsx": .testJSX,
        "app.test.js": .testJS,
        "app.spec.js": .testJS,
        "index.d.ts": .typescriptDef,
    ]

    /// Phase 4, every extension of the table.
    private let extensions: [String: FileTypeIcon] = [
        "jsx": .react,
        "scss": .sass, "sass": .sass,
        "c": .c, "h": .h,
        "cpp": .cpp, "cc": .cpp, "cxx": .cpp,
        "hpp": .hpp, "hh": .hpp, "hxx": .hpp,
        "java": .java, "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby, "php": .php, "lua": .lua,
        "toml": .toml, "xml": .xml, "svg": .svg,
        "csv": .table, "tsv": .table,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image,
        "ico": .image, "bmp": .image, "tif": .image, "tiff": .image,
        "ttf": .font, "otf": .font, "woff": .font, "woff2": .font,
        "pdf": .pdf,
        "zip": .zip, "gz": .zip, "tgz": .zip, "tar": .zip, "bz2": .zip, "xz": .zip,
        "7z": .zip, "rar": .zip,
        "lock": .lock,
    ]

    /// Phase 5, one sample name per language. The key set is held equal to
    /// `SyntaxLanguage.allCases`.
    private let languageSamples: [SyntaxLanguage: String] = [
        .swift: "main.swift",
        .javascript: "index.js",
        .typescript: "app.ts",
        .tsx: "App.tsx",
        .json: "data.json",
        .markdown: "notes.md",
        .python: "script.py",
        .go: "main.go",
        .rust: "lib.rs",
        .html: "index.html",
        .css: "style.css",
        .yaml: "config.yml",
        .dockerfile: "Dockerfile",
        .dotenv: ".env",
        .gitignore: ".gitignore",
        .sql: "schema.sql",
        .editorconfig: ".editorconfig",
        .shell: "build.sh",
        .make: "Makefile",
    ]

    /// `forLanguage(_:)` written out, so the exhaustive switch is pinned row by
    /// row rather than only for being exhaustive.
    private let languageIcons: [SyntaxLanguage: FileTypeIcon] = [
        .swift: .swift,
        .javascript: .javascript,
        .typescript: .typescript,
        .tsx: .reactTS,
        .json: .json,
        .markdown: .markdown,
        .python: .python,
        .go: .go,
        .rust: .rust,
        .html: .html,
        .css: .css,
        .yaml: .yaml,
        .dockerfile: .docker,
        .dotenv: .tune,
        .gitignore: .git,
        .sql: .database,
        .editorconfig: .editorconfig,
        .shell: .console,
        .make: .makefile,
    ]

    private let databaseNames: [String: FileTypeIcon] = [
        "app.sqlite": .database,
        "app.sqlite3": .database,
        "notes.sqlite": .database,
        "store.db": .database,
        "README.db": .database,
    ]

    private let fallbackNames = ["unknown.xyz", "noextension", "notes.txt", ""]

    // MARK: - Order

    func testDatabaseRuleBeatsEverything() {
        // `README` is a stem; the database rule is asked first.
        XCTAssertEqual(FileTypeIcon.forFile(named: "README.db"), .database)
        XCTAssertEqual(FileTypeIcon.forFile(named: "notes.sqlite"), .database)
    }

    func testSpecialNameBeatsItsExtension() {
        XCTAssertEqual(FileTypeIcon.forFile(named: "package.json"), .nodejs)
        XCTAssertEqual(FileTypeIcon.forFile(named: "LICENSE.md"), .license)
        XCTAssertEqual(FileTypeIcon.forFile(named: "robots.txt"), .robots)
        XCTAssertEqual(FileTypeIcon.forFile(named: "tsconfig.app.json"), .tsconfig)
    }

    func testCompoundSuffixBeatsItsPlainExtension() {
        XCTAssertEqual(FileTypeIcon.forFile(named: "app.test.ts"), .testTS)
        XCTAssertEqual(FileTypeIcon.forFile(named: "app.ts"), .typescript)
        XCTAssertEqual(FileTypeIcon.forFile(named: "App.spec.tsx"), .testJSX)
        XCTAssertEqual(FileTypeIcon.forFile(named: "App.tsx"), .reactTS)
        XCTAssertEqual(FileTypeIcon.forFile(named: "index.d.ts"), .typescriptDef)
    }

    func testTheOneOverrideBeatsTheLanguagePhase() {
        XCTAssertEqual(SyntaxLanguage(forFileName: "Button.jsx"), .javascript)
        XCTAssertEqual(FileTypeIcon.forFile(named: "Button.jsx"), .react)
    }

    func testSpecialNameBeatsTheDotIgnoreFamily() {
        XCTAssertEqual(FileTypeIcon.forFile(named: ".dockerignore"), .docker)
        XCTAssertEqual(FileTypeIcon.forFile(named: ".npmignore"), .npm)
        XCTAssertEqual(FileTypeIcon.forFile(named: ".prettierignore"), .prettier)
        // A member no special name claims reaches the language phase.
        XCTAssertEqual(FileTypeIcon.forFile(named: ".stylelintignore"), .git)
    }

    func testLanguagePhaseKeepsSyntaxLanguagesOwnOrder() {
        XCTAssertEqual(FileTypeIcon.forFile(named: ".env.local"), .tune)
        // The language's extension phase pins `.env.json` to JSON before its
        // `.env.` prefix rule runs; the icon follows the highlighting.
        XCTAssertEqual(FileTypeIcon.forFile(named: ".env.json"), .json)
    }

    // MARK: - Case and paths

    func testMatchingIsCaseInsensitiveAndReadsTheLastComponent() {
        XCTAssertEqual(FileTypeIcon.forFile(named: "MAIN.SWIFT"), .swift)
        XCTAssertEqual(FileTypeIcon.forFile(named: "Readme.MD"), .readme)
        XCTAssertEqual(FileTypeIcon.forFile(named: "PACKAGE.JSON"), .nodejs)
        XCTAssertEqual(FileTypeIcon.forFile(named: "src/components/App.tsx"), .reactTS)
        XCTAssertEqual(FileTypeIcon.forFile(named: "web/package.json"), .nodejs)
        XCTAssertEqual(FileTypeIcon.forFile(named: "/tmp/project/data/app.sqlite"), .database)
    }

    // MARK: - Floor

    func testTheSpecialCasedNamesOfTheOldTableKeepANamedIcon() {
        let floor: [String: FileTypeIcon] = [
            "Package.swift": .swift,
            "LICENSE": .license,
            ".gitignore": .git,
            ".gitattributes": .git,
            "Makefile": .makefile,
            "GNUmakefile": .makefile,
            "Dockerfile": .docker,
            ".editorconfig": .editorconfig,
            ".bashrc": .console,
            ".bash_profile": .console,
            ".bash_logout": .console,
            ".zshrc": .console,
            ".zprofile": .console,
            ".zshenv": .console,
            ".zlogin": .console,
            ".zlogout": .console,
            ".profile": .console,
            ".envrc": .console,
        ]
        for (name, icon) in floor {
            XCTAssertEqual(FileTypeIcon.forFile(named: name), icon, name)
        }
    }

    // MARK: - Tables

    func testEverySpecialNameResolves() {
        for (name, icon) in specialNames {
            XCTAssertEqual(FileTypeIcon.forFile(named: name), icon, name)
        }
    }

    func testEveryCompoundSuffixResolves() {
        for (name, icon) in compoundSuffixes {
            XCTAssertEqual(FileTypeIcon.forFile(named: name), icon, name)
        }
    }

    func testEveryExtensionResolves() {
        for (ext, icon) in extensions {
            XCTAssertEqual(FileTypeIcon.forFile(named: "sample.\(ext)"), icon, ext)
            XCTAssertEqual(FileTypeIcon.forFile(named: "SAMPLE.\(ext.uppercased())"), icon, ext)
        }
    }

    func testTheExtensionTableClaimsNoLanguageExtensionButTheOverride() {
        let claimed = Set(extensions.keys).intersection(SyntaxLanguage.fileExtensions)
        XCTAssertEqual(claimed, ["jsx"])
    }

    func testEveryDatabaseNameResolves() {
        for (name, icon) in databaseNames {
            XCTAssertEqual(FileTypeIcon.forFile(named: name), icon, name)
        }
        for ext in DatabaseFileRule.recognizedExtensions {
            XCTAssertEqual(FileTypeIcon.forFile(named: "sample.\(ext)"), .database, ext)
        }
    }

    // MARK: - Every language

    func testEveryLanguageResolvesThroughItsSample() throws {
        XCTAssertEqual(Set(languageSamples.keys), Set(SyntaxLanguage.allCases))
        for (language, sample) in languageSamples {
            XCTAssertEqual(SyntaxLanguage(forFileName: sample), language, sample)
            XCTAssertEqual(FileTypeIcon.forFile(named: sample), FileTypeIcon.forLanguage(language), sample)
            XCTAssertNotEqual(FileTypeIcon.forLanguage(language), .document, "\(language)")
        }
    }

    func testForLanguageMatchesItsWrittenTable() {
        XCTAssertEqual(Set(languageIcons.keys), Set(SyntaxLanguage.allCases))
        for (language, icon) in languageIcons {
            XCTAssertEqual(FileTypeIcon.forLanguage(language), icon, "\(language)")
        }
    }

    func testEverySeamEntryAnswersItsLanguageExceptTheOneOverride() throws {
        var overrides: Set<String> = []
        for name in SyntaxLanguage.exactFileNames {
            let language = try XCTUnwrap(SyntaxLanguage(forFileName: name), name)
            if FileTypeIcon.forFile(named: name) != FileTypeIcon.forLanguage(language) {
                overrides.insert(name)
            }
        }
        for ext in SyntaxLanguage.fileExtensions {
            let language = try XCTUnwrap(SyntaxLanguage(fileExtension: ext), ext)
            if FileTypeIcon.forFile(named: "sample.\(ext)") != FileTypeIcon.forLanguage(language) {
                overrides.insert(ext)
            }
        }
        XCTAssertEqual(overrides, ["jsx"])
    }

    // MARK: - Reachability

    func testEveryCaseIsReachedBySomeSampleName() {
        var names: [String] = []
        names += specialNames.keys
        names += compoundSuffixes.keys
        names += extensions.keys.map { "sample.\($0)" }
        names += languageSamples.values
        names += databaseNames.keys
        names += fallbackNames
        let answers = Set(names.map(FileTypeIcon.forFile(named:)))
        XCTAssertEqual(answers, Set(FileTypeIcon.allCases))
    }

    // MARK: - Fallback

    func testUnclaimedNamesFallBackToDocument() {
        for name in fallbackNames {
            XCTAssertEqual(FileTypeIcon.forFile(named: name), .document, name)
        }
    }

    // MARK: - Catalog name

    func testCatalogNameIsNamespacedRawValue() {
        XCTAssertEqual(FileTypeIcon.catalogNamespace, "FileIcons")
        for icon in FileTypeIcon.allCases {
            XCTAssertEqual(icon.catalogName, "FileIcons/\(icon.rawValue)")
        }
        XCTAssertEqual(FileTypeIcon.reactTS.catalogName, "FileIcons/react_ts")
        XCTAssertEqual(FileTypeIcon.testJSX.catalogName, "FileIcons/test-jsx")
    }
}
