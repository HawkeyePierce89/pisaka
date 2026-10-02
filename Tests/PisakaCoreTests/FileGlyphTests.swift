import XCTest
@testable import PisakaCore

final class FileGlyphTests: XCTestCase {
    /// One sample name per language, with the glyph it must draw. Keyed by the
    /// language so the table is held equal to `SyntaxLanguage.allCases`: a new
    /// language fails here until someone decides whether it is code or text.
    private let samples: [SyntaxLanguage: (name: String, glyph: DesignGlyph)] = [
        .swift: ("main.swift", .fileCode),
        .javascript: ("index.js", .fileCode),
        .typescript: ("app.ts", .fileCode),
        .json: ("package.json", .fileCode),
        .markdown: ("README.md", .fileText),
        .python: ("script.py", .fileCode),
        .go: ("main.go", .fileCode),
        .rust: ("lib.rs", .fileCode),
        .html: ("index.html", .fileCode),
        .css: ("site.css", .fileCode),
        .yaml: ("ci.yml", .fileCode),
        .dockerfile: ("Dockerfile", .fileCode),
        .dotenv: (".env", .fileText),
        .gitignore: (".gitignore", .fileText),
        .sql: ("schema.sql", .fileCode),
        .editorconfig: (".editorconfig", .fileText),
        .shell: ("build.sh", .fileCode),
    ]

    func testEveryLanguageHasAnAnswer() {
        XCTAssertEqual(Set(samples.keys), Set(SyntaxLanguage.allCases))
        for (language, sample) in samples {
            XCTAssertEqual(
                SyntaxLanguage(forFileName: sample.name), language,
                "\(sample.name) no longer resolves to \(language) — pick another sample"
            )
            XCTAssertEqual(FileGlyph.forFile(named: sample.name), sample.glyph, "\(sample.name)")
        }
    }

    func testDatabaseExtensionsDrawTheDatabaseGlyph() {
        for name in ["app.sqlite", "app.sqlite3", "app.db", "APP.DB", "dir/cache.Sqlite"] {
            XCTAssertEqual(FileGlyph.forFile(named: name), .database, name)
        }
        // Only the last extension counts, as DatabaseFileRule states.
        XCTAssertEqual(FileGlyph.forFile(named: "notes.db.txt"), .fileText)
    }

    func testUnknownAndEmptyNamesAreText() {
        for name in ["", "LICENSE", "notes.txt", "photo.png", "archive.tar.gz", "dir/"] {
            XCTAssertEqual(FileGlyph.forFile(named: name), .fileText, "\(name.debugDescription)")
        }
    }

    func testAPathIsReadByItsLastComponent() {
        XCTAssertEqual(FileGlyph.forFile(named: "/Users/me/project/Sources/main.swift"), .fileCode)
        XCTAssertEqual(FileGlyph.forFile(named: "docs/README.md"), .fileText)
    }

    func testFolders() {
        XCTAssertEqual(FileGlyph.forFolder(expanded: true), .folderOpen)
        XCTAssertEqual(FileGlyph.forFolder(expanded: false), .folder)
    }
}
