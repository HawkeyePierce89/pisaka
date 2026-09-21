import XCTest
@testable import PisakaCore

final class FileIconTests: XCTestCase {
    /// Build a file entry at a throwaway path with the given file name.
    private func file(_ name: String) -> DirectoryEntry {
        let url = URL(fileURLWithPath: "/tmp/project").appendingPathComponent(name)
        return DirectoryEntry(url: url, isDirectory: false)
    }

    /// Build a directory entry with the given name.
    private func directory(_ name: String) -> DirectoryEntry {
        let url = URL(fileURLWithPath: "/tmp/project").appendingPathComponent(name)
        return DirectoryEntry(url: url, isDirectory: true)
    }

    // MARK: - Known extensions

    func testKnownExtensionsMapToExpectedIcons() {
        let expected: [String: FileIcon] = [
            "Main.swift": FileIcon(symbolName: "swift", color: .orange),
            "app.js": FileIcon(symbolName: "curlybraces", color: .yellow),
            "app.ts": FileIcon(symbolName: "curlybraces", color: .blue),
            "data.json": FileIcon(symbolName: "curlybraces.square", color: .yellow),
            "config.yml": FileIcon(symbolName: "list.bullet.indent", color: .purple),
            "README.md": FileIcon(symbolName: "text.alignleft", color: .blue),
            "script.py": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .green),
            // `go` was already in the extension map before Go became a
            // `SyntaxLanguage`; pinned here so the icon and the language agree.
            "main.go": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .blue),
            // `rs` likewise predates Rust becoming a `SyntaxLanguage`. Asserted
            // rather than added, for the same reason: the two maps are separate
            // and nothing but a test keeps a file that highlights as Rust from
            // showing the generic document icon.
            "main.rs": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .orange),
            "schema.sql": FileIcon(symbolName: "cylinder.split.1x2", color: .blue),
            // The database extensions come from `DatabaseFileRule`, not from a
            // second list in the icon table; `testEveryRecognizedDatabaseExtensionHasTheDatabaseIcon`
            // holds the two together.
            "app.sqlite": FileIcon(symbolName: "cylinder.split.1x2.fill", color: .green),
            "app.db": FileIcon(symbolName: "cylinder.split.1x2.fill", color: .green),
            "run.sh": FileIcon(symbolName: "terminal", color: .green),
            "style.css": FileIcon(symbolName: "paintbrush", color: .blue),
            "logo.png": FileIcon(symbolName: "photo", color: .purple),
            "bundle.zip": FileIcon(symbolName: "doc.zipper", color: .gray),
            "notes.txt": FileIcon(symbolName: "doc.text", color: .gray),
        ]

        for (name, icon) in expected {
            XCTAssertEqual(FileIcon(for: file(name)), icon, "icon for \(name)")
            // Every known mapping is intentionally non-default.
            XCTAssertNotEqual(FileIcon(for: file(name)), FileIcon(symbolName: "doc", color: .gray),
                              "\(name) should not resolve to the fallback icon")
        }
    }

    // MARK: - Case-insensitivity

    func testExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(FileIcon(for: file("FOO.SWIFT")), FileIcon(for: file("foo.swift")))
        XCTAssertEqual(FileIcon(for: file("Data.JSON")), FileIcon(for: file("data.json")))
    }

    // MARK: - Special names

    func testSpecialNamesResolveAndBeatExtensionRule() {
        // Package.swift must NOT be the plain Swift icon.
        let packageIcon = FileIcon(for: file("Package.swift"))
        XCTAssertEqual(packageIcon, FileIcon(symbolName: "shippingbox", color: .orange))
        XCTAssertNotEqual(packageIcon, FileIcon(symbolName: "swift", color: .orange))

        XCTAssertEqual(FileIcon(for: file("LICENSE")), FileIcon(symbolName: "checkmark.seal", color: .yellow))
        XCTAssertEqual(FileIcon(for: file(".gitignore")), FileIcon(symbolName: "arrow.triangle.branch", color: .gray))
        XCTAssertEqual(FileIcon(for: file(".gitattributes")), FileIcon(symbolName: "arrow.triangle.branch", color: .gray))
        XCTAssertEqual(FileIcon(for: file("Makefile")), FileIcon(symbolName: "hammer", color: .gray))
        XCTAssertEqual(FileIcon(for: file("Dockerfile")), FileIcon(symbolName: "shippingbox", color: .blue))
        XCTAssertEqual(FileIcon(for: file(".editorconfig")), FileIcon(symbolName: "slider.horizontal.3", color: .gray))
    }

    func testSpecialNameMatchingIsCaseInsensitive() {
        XCTAssertEqual(FileIcon(for: file("package.swift")), FileIcon(for: file("PACKAGE.SWIFT")))
        XCTAssertEqual(FileIcon(for: file("license")), FileIcon(symbolName: "checkmark.seal", color: .yellow))
        XCTAssertEqual(FileIcon(for: file("makefile")), FileIcon(symbolName: "hammer", color: .gray))
        XCTAssertEqual(FileIcon(for: file(".EditorConfig")), FileIcon(symbolName: "slider.horizontal.3", color: .gray))
        XCTAssertEqual(FileIcon(for: file(".EDITORCONFIG")), FileIcon(symbolName: "slider.horizontal.3", color: .gray))
    }

    // MARK: - Fallback

    func testUnknownExtensionFallsBackToDoc() {
        XCTAssertEqual(FileIcon(for: file("mystery.qwerty")), FileIcon(symbolName: "doc", color: .gray))
    }

    func testNoExtensionFallsBackToDoc() {
        XCTAssertEqual(FileIcon(for: file("README")), FileIcon(symbolName: "doc", color: .gray))
    }

    // MARK: - Directories

    func testDirectoryResolvesToFolderRegardlessOfName() {
        XCTAssertEqual(FileIcon(for: directory("Sources")), FileIcon(symbolName: "folder", color: .accent))
        // A directory named like a Swift file is still a folder.
        XCTAssertEqual(FileIcon(for: directory("something.swift")), FileIcon(symbolName: "folder", color: .accent))
        // A directory named like a special file is still a folder.
        XCTAssertEqual(FileIcon(for: directory("Package.swift")), FileIcon(symbolName: "folder", color: .accent))
    }

    // MARK: - Database extensions

    func testEveryRecognizedDatabaseExtensionHasTheDatabaseIcon() {
        for ext in DatabaseFileRule.recognizedExtensions {
            XCTAssertEqual(
                FileIcon(for: file("data.\(ext)")),
                FileIcon(symbolName: "cylinder.split.1x2.fill", color: .green),
                "recognized database extension .\(ext) must carry the database icon"
            )
        }
    }

    func testDatabaseIconMatchingIsCaseInsensitiveLikeTheRule() {
        XCTAssertEqual(
            FileIcon(for: file("Chinook.SQLITE3")),
            FileIcon(symbolName: "cylinder.split.1x2.fill", color: .green)
        )
    }

    func testTheSQLIconIsNotTheDatabaseIcon() {
        // A `.sql` file is text the editor edits; it must not look like a
        // database the viewer opens.
        XCTAssertEqual(
            FileIcon(for: file("schema.sql")),
            FileIcon(symbolName: "cylinder.split.1x2", color: .blue)
        )
    }

    // MARK: - The shell startup dot-files

    /// The ten names `SyntaxLanguage` claims by exact name. Written out rather
    /// than read from the seam so a name silently *leaving* that table is also
    /// a red test, not just a name joining it.
    private static let shellStartupDotFiles = [
        ".bashrc", ".bash_profile", ".bash_logout",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout",
        ".profile", ".envrc",
    ]

    func testShellStartupDotFilesCarryTheShellIcon() {
        for name in Self.shellStartupDotFiles {
            XCTAssertEqual(
                FileIcon(for: file(name)),
                FileIcon(symbolName: "terminal", color: .green),
                "\(name) highlights as shell and must carry the shell icon"
            )
            XCTAssertEqual(SyntaxLanguage(forFileName: name), .shell, "\(name) must resolve as shell")
        }
    }

    func testShellStartupDotFileMatchingIsCaseInsensitive() {
        XCTAssertEqual(FileIcon(for: file(".ZSHRC")), FileIcon(symbolName: "terminal", color: .green))
        XCTAssertEqual(FileIcon(for: file(".Bash_Profile")), FileIcon(symbolName: "terminal", color: .green))
    }

    // MARK: - The two tables, held together

    /// The rule rather than the instances: every *name* `SyntaxLanguage`
    /// resolves by its exact-name phase must have an icon of its own, because a
    /// dot-file's `pathExtension` is empty and the extension phase can never
    /// answer for it. The exemption is named here so it stays visible.
    func testEveryExactFileNameLanguageHasANonFallbackIcon() {
        // `.env` is the one exact name still on the fallback icon. It is
        // dotenv, not shell, and giving it one is a separate decision from this
        // change; naming it here is what keeps it from being forgotten.
        let exempt: Set<String> = [".env"]
        let fallback = FileIcon(symbolName: "doc", color: .gray)
        for name in SyntaxLanguage.exactFileNames where !exempt.contains(name) {
            XCTAssertNotEqual(
                FileIcon(for: file(name)), fallback,
                "\(name) resolves to a language and must not draw the fallback icon"
            )
        }
        // The exemption must stay an exemption: if `.env` gains an icon, this
        // list is what has to shrink.
        for name in exempt {
            XCTAssertEqual(FileIcon(for: file(name)), fallback, "\(name) is recorded as exempt")
        }
    }

    /// The same rule over the extension phase. Two of shell's five extensions
    /// are a stated, accepted cost from the original plan and stay on the
    /// fallback; the other divergences are older languages, recorded rather
    /// than fixed here.
    func testShellExtensionsCarryTheShellIconExceptTheTwoAcceptedCosts() {
        let fallback = FileIcon(symbolName: "doc", color: .gray)
        // Read from the language table rather than written out, so a sixth
        // shell extension is covered the day it is added.
        let exempt: Set<String> = ["ksh", "command"]
        let shellExtensions = SyntaxLanguage.fileExtensions
            .filter { SyntaxLanguage(fileExtension: $0) == .shell }
        XCTAssertFalse(shellExtensions.isEmpty)
        for ext in shellExtensions where !exempt.contains(ext) {
            XCTAssertEqual(
                FileIcon(for: file("run.\(ext)")),
                FileIcon(symbolName: "terminal", color: .green),
                ".\(ext) must carry the shell icon"
            )
        }
        // `ksh` and `command` highlight as shell and draw the generic document
        // icon. That is the accepted cost recorded in the original plan, not an
        // oversight; asserted so the exemption is visible and so adding an icon
        // for either is a conscious edit here.
        for ext in exempt {
            XCTAssertEqual(SyntaxLanguage(fileExtension: ext), .shell)
            XCTAssertEqual(FileIcon(for: file("run.\(ext)")), fallback, ".\(ext) is a recorded exemption")
        }
    }
}
