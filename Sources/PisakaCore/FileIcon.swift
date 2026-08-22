import Foundation

/// A semantic color token for a file-type icon.
///
/// Kept as an enum (not a concrete UI color) so `PisakaCore` stays free of any
/// SwiftUI/AppKit dependency. The view layer maps each case to a real color.
public enum FileIconColor: Equatable {
    case orange, yellow, blue, green, purple, red, pink, gray, accent
}

/// The icon to show for a directory entry: an SF Symbol name and a tint.
///
/// Pure, testable mapping logic. Resolution order in `init(for:)`:
/// 1. directories → `folder`/`.accent`
/// 2. special-cased file names (matched case-insensitively)
/// 3. file extension lookup (lowercased)
/// 4. fallback → `doc`/`.gray`
public struct FileIcon: Equatable {
    public let symbolName: String
    public let color: FileIconColor

    public init(symbolName: String, color: FileIconColor) {
        self.symbolName = symbolName
        self.color = color
    }

    /// Resolve the icon for a directory entry.
    public init(for entry: DirectoryEntry) {
        if entry.isDirectory {
            self = FileIcon(symbolName: "folder", color: .accent)
            return
        }
        if let special = FileIcon.specialNameMap[entry.name.lowercased()] {
            self = special
            return
        }
        let ext = entry.url.pathExtension.lowercased()
        if let byExtension = FileIcon.extensionMap[ext] {
            self = byExtension
            return
        }
        self = FileIcon(symbolName: "doc", color: .gray)
    }

    /// File names that get a fixed icon regardless of extension. Keys are
    /// lowercased so matching is case-insensitive.
    private static let specialNameMap: [String: FileIcon] = [
        "package.swift": FileIcon(symbolName: "shippingbox", color: .orange),
        "license": FileIcon(symbolName: "checkmark.seal", color: .yellow),
        ".gitignore": FileIcon(symbolName: "arrow.triangle.branch", color: .gray),
        ".gitattributes": FileIcon(symbolName: "arrow.triangle.branch", color: .gray),
        "makefile": FileIcon(symbolName: "hammer", color: .gray),
        "dockerfile": FileIcon(symbolName: "shippingbox", color: .blue)
    ]

    /// Lowercased file extension → icon.
    private static let extensionMap: [String: FileIcon] = [
        // Source code
        "swift": FileIcon(symbolName: "swift", color: .orange),
        "js": FileIcon(symbolName: "curlybraces", color: .yellow),
        "mjs": FileIcon(symbolName: "curlybraces", color: .yellow),
        "ts": FileIcon(symbolName: "curlybraces", color: .blue),
        "tsx": FileIcon(symbolName: "curlybraces", color: .blue),
        "jsx": FileIcon(symbolName: "curlybraces", color: .yellow),
        "py": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .green),
        "rb": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .red),
        "go": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .blue),
        "rs": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .orange),
        "c": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .blue),
        "h": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .purple),
        "cpp": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .blue),
        "java": FileIcon(symbolName: "cup.and.saucer", color: .red),
        "kt": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .purple),
        "sh": FileIcon(symbolName: "terminal", color: .green),
        "bash": FileIcon(symbolName: "terminal", color: .green),
        "zsh": FileIcon(symbolName: "terminal", color: .green),

        // Markup / styles
        "html": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .orange),
        "css": FileIcon(symbolName: "paintbrush", color: .blue),
        "scss": FileIcon(symbolName: "paintbrush", color: .pink),

        // Data / config
        "json": FileIcon(symbolName: "curlybraces.square", color: .yellow),
        "yml": FileIcon(symbolName: "list.bullet.indent", color: .purple),
        "yaml": FileIcon(symbolName: "list.bullet.indent", color: .purple),
        "toml": FileIcon(symbolName: "list.bullet.indent", color: .gray),
        "xml": FileIcon(symbolName: "chevron.left.forwardslash.chevron.right", color: .green),
        "sql": FileIcon(symbolName: "cylinder.split.1x2", color: .blue),

        // Docs / text
        "md": FileIcon(symbolName: "text.alignleft", color: .blue),
        "markdown": FileIcon(symbolName: "text.alignleft", color: .blue),
        "txt": FileIcon(symbolName: "doc.text", color: .gray),
        "pdf": FileIcon(symbolName: "doc.richtext", color: .red),

        // Images
        "png": FileIcon(symbolName: "photo", color: .purple),
        "jpg": FileIcon(symbolName: "photo", color: .purple),
        "jpeg": FileIcon(symbolName: "photo", color: .purple),
        "gif": FileIcon(symbolName: "photo", color: .purple),
        "svg": FileIcon(symbolName: "photo", color: .green),

        // Archives
        "zip": FileIcon(symbolName: "doc.zipper", color: .gray),
        "gz": FileIcon(symbolName: "doc.zipper", color: .gray),
        "tar": FileIcon(symbolName: "doc.zipper", color: .gray)
    ]
}
