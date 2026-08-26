import Foundation

/// A source language the editor can syntax-highlight.
///
/// Pure, UI-free semantic type (no Neon/SwiftTreeSitter/AppKit), mirroring the
/// extension-map pattern in `FileIcon`. The view layer maps each case to a
/// concrete tree-sitter grammar (`SyntaxLanguageConfiguration`).
///
/// Resolution is by *file name*, not by extension alone: `Dockerfile`, `.env`
/// and `.gitignore` carry no extension at all, so `init(forFileName:)` runs four
/// phases in this order — exact name → extension → prefix → dot-ignore shape.
/// Every phase is case-insensitive (the whole name is lowercased first) and
/// matches the *last path component*, so a caller that hands over a path rather
/// than a bare name still resolves. Only the extension phase was path-tolerant
/// on its own (`NSString.pathExtension` reads the last component); the other
/// three match the whole string, so without that normalization
/// `"backend/app.ts"` would resolve while `"backend/.env"` silently would not —
/// a partial, per-language failure rather than an honest one.
///
/// The order is what keeps the later, looser rules from shadowing the earlier,
/// stricter ones: `.env.json` reaches the extension phase and resolves to
/// `.json` rather than being claimed by the `.env.` prefix rule, and
/// `.eslintignore.md` resolves to `.markdown` rather than to `.gitignore`.
///
/// The gitignore rule is deliberately a *shape*, not a name list: a lowercased
/// name that starts with `.` and ends with `ignore`. All of `.gitignore`,
/// `.dockerignore`, `.npmignore`, `.eslintignore`, `.prettierignore` and a bare
/// `.ignore` are one syntactic family (git's pattern grammar), and new members
/// of it appear regularly, so enumerating them would go stale. The leading dot
/// is load-bearing — this is a dot-file convention, not an extension — so
/// `foo.ignore`, `gitignore` and `ignore` deliberately do *not* match.
public enum SyntaxLanguage: String, CaseIterable, Equatable, Hashable, Sendable {
    case swift
    case javascript
    case typescript
    case json
    case markdown
    case python
    case go
    case rust
    case html
    case css
    case yaml
    case dockerfile
    case dotenv
    case gitignore
    case sql
    case editorconfig

    /// Resolve a language from a bare file extension (no leading dot — pass the
    /// extension itself, e.g. `"swift"`, as `pathExtension` yields). Matching is
    /// case-insensitive. Returns `nil` for an empty or unknown extension.
    public init?(fileExtension: String) {
        guard let language = SyntaxLanguage.extensionMap[fileExtension.lowercased()] else {
            return nil
        }
        self = language
    }

    /// Resolve a language from a file name, in four phases: exact name →
    /// extension → prefix → dot-ignore shape (see the type's documentation for
    /// why that order matters). A path is accepted too — only its last component
    /// is matched. Returns `nil` when no phase claims the name.
    public init?(forFileName fileName: String) {
        let name = (fileName as NSString).lastPathComponent.lowercased()

        // 1. Exact name — the extensionless names (`Dockerfile`, `.env`).
        if let language = SyntaxLanguage.exactFileNameMap[name] {
            self = language
            return
        }

        // 2. Extension — the ordinary case, and the phase that pins `.env.json`
        //    to `.json` before the `.env.` prefix rule can claim it.
        if let language = SyntaxLanguage(fileExtension: (name as NSString).pathExtension) {
            self = language
            return
        }

        // 3. Prefix — the variant-suffixed forms (`Dockerfile.dev`, `.env.local`)
        //    whose trailing component is not a known extension.
        if name.hasPrefix("dockerfile.") {
            self = .dockerfile
            return
        }
        if name.hasPrefix(".env.") {
            self = .dotenv
            return
        }

        // 4. Dot-ignore shape — a dot-file whose name ends in "ignore". The
        //    leading dot is the whole rule: it is also what makes the shortest
        //    match the bare `.ignore` rather than `ignore` itself (a name that
        //    ends in "ignore" and is only six characters long *is* "ignore",
        //    which has no leading dot), so no separate length check is needed.
        if name.hasPrefix(".") && name.hasSuffix(SyntaxLanguage.ignoreSuffix) {
            self = .gitignore
            return
        }

        return nil
    }

    /// Lowercased file extension → language.
    private static let extensionMap: [String: SyntaxLanguage] = [
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
        "dockerfile": .dockerfile,
        "sql": .sql,
    ]

    /// Lowercased whole file name → language, for the extensionless names.
    private static let exactFileNameMap: [String: SyntaxLanguage] = [
        "dockerfile": .dockerfile,
        ".env": .dotenv,
        EditorConfigResolver.fileName: .editorconfig,
    ]

    /// The trailing token of the dot-ignore shape rule.
    private static let ignoreSuffix = "ignore"
}
