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
    }

    func testSpecialNameMatchingIsCaseInsensitive() {
        XCTAssertEqual(FileIcon(for: file("package.swift")), FileIcon(for: file("PACKAGE.SWIFT")))
        XCTAssertEqual(FileIcon(for: file("license")), FileIcon(symbolName: "checkmark.seal", color: .yellow))
        XCTAssertEqual(FileIcon(for: file("makefile")), FileIcon(symbolName: "hammer", color: .gray))
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
}
