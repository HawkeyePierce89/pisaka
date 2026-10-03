import Foundation

/// Which design glyph stands for a file or a folder on the macOS chrome — the
/// project tree, both tab orientations and the tree's inline draft.
///
/// Three answers for a file, deliberately coarse: a database, a text document,
/// or code. The design draws no per-language icon, so the question is only
/// *what kind of thing is this file*, and it is answered from the two rules that
/// already own it — `DatabaseFileRule` for a database, `SyntaxLanguage` for
/// everything else — rather than from a third extension table.
///
/// `FileIcon` is untouched and still answers the iOS layer (an SF Symbol and a
/// tint); this type is the macOS chrome's name table, and like `DesignGlyph` it
/// is Foundation-only and colour-free — the caller draws it in a role.
public enum FileGlyph {
    /// The glyph for a file called `name` (a bare name or a path; only the last
    /// component's extension and name are read).
    ///
    /// - `database` when `DatabaseFileRule` recognises the name — asked first,
    ///   because a `.sql` *script* is code while a `.db` file is not text at all;
    /// - `file-text` for a name no `SyntaxLanguage` claims, and for the four
    ///   languages that are prose or configuration rather than code: Markdown,
    ///   `.gitignore`, `.env` and `.editorconfig`;
    /// - `file-code` for every other language.
    public static func forFile(named name: String) -> DesignGlyph {
        if DatabaseFileRule.isDatabaseFile(named: name) { return .database }
        let lastComponent = (name as NSString).lastPathComponent
        guard let language = SyntaxLanguage(forFileName: lastComponent) else { return .fileText }
        switch language {
        case .markdown, .gitignore, .dotenv, .editorconfig:
            return .fileText
        case .swift, .javascript, .typescript, .json, .python, .go, .rust, .html, .css,
             .yaml, .dockerfile, .sql, .shell:
            return .fileCode
        }
    }

    /// The glyph for a folder: open while its row is expanded, closed otherwise.
    public static func forFolder(expanded: Bool) -> DesignGlyph {
        expanded ? .folderOpen : .folder
    }
}
