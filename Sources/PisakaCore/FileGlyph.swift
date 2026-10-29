import Foundation

/// Which design glyph stands for a folder on the macOS chrome — the project
/// tree and the tree's inline draft.
///
/// File icons are not this type's: a file is drawn by its kind, through
/// `FileTypeIcon` and the vendored file-icon set, in the icon's own colours.
/// A folder keeps the design's monochrome glyph, and like `DesignGlyph` this
/// type is Foundation-only and colour-free — the caller draws it in a role.
public enum FileGlyph {
    /// The glyph for a folder: open while its row is expanded, closed otherwise.
    public static func forFolder(expanded: Bool) -> DesignGlyph {
        expanded ? .folderOpen : .folder
    }
}
