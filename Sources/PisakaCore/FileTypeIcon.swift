import Foundation

/// Which picture of the vendored file-icon set stands for a file, on both
/// platforms.
///
/// Foundation-only and colour-free: each case names one full-colour image the
/// app bundles, and the raw value is that image's name, which is also the
/// upstream file stem. Folders are not answered here — they keep their own
/// glyph on each platform.
///
/// `forFile(named:)` lowercases the last path component and runs six phases;
/// the first that answers wins:
///
/// 1. **Database** — `DatabaseFileRule` is asked first, because a `.db` file is
///    not text at all: `README.db` is a database, not a readme.
/// 2. **Special names** — exact names, then stems (the stem itself or the stem
///    followed by a dot), then prefixes. They run before every extension, so
///    `package.json` is the package manifest rather than JSON, and before the
///    language phase's dot-ignore shape, so `.dockerignore` is Docker's.
/// 3. **Compound suffixes** (`.test.ts`, `.d.ts`), before the plain extension
///    they end in.
/// 4. **Extensions** `SyntaxLanguage` does not claim, plus exactly one override,
///    `jsx`, which highlights as JavaScript but draws the React picture.
/// 5. **Language** — `SyntaxLanguage(forFileName:)` mapped through
///    `forLanguage(_:)`. It is last before the fallback so that the names the
///    language already owns (`Makefile`, `Dockerfile.*`, `.env.*`, the shell
///    start-up dot-files, the dot-ignore family) are asked of it and never
///    restated here, and so that its own order holds: `.env.local` is `tune`
///    while `.env.json` stays `json`, as their highlighting does.
/// 6. **Fallback** — `document`.
///
/// The tables are private data in this one file; `DatabaseFileRule` and
/// `SyntaxLanguage` are asked, never copied.
public enum FileTypeIcon: String, CaseIterable, Sendable {
    case swift
    case javascript
    case typescript
    case reactTS = "react_ts"
    case json
    case markdown
    case python
    case go
    case rust
    case html
    case css
    case yaml
    case docker
    case tune
    case git
    case database
    case editorconfig
    case console
    case makefile
    case react
    case testTS = "test-ts"
    case testJS = "test-js"
    case testJSX = "test-jsx"
    case typescriptDef = "typescript-def"
    case nodejs
    case npm
    case yarn
    case pnpm
    case tsconfig
    case readme
    case changelog
    case contributing
    case license
    case codeowners
    case prettier
    case eslint
    case vitest
    case jest
    case robots
    case lock
    case c
    case h
    case cpp
    case hpp
    case java
    case kotlin
    case ruby
    case php
    case lua
    case toml
    case xml
    case svg
    case table
    case image
    case font
    case pdf
    case zip
    case sass
    case document

    /// The asset-catalog folder the images live in. It provides a namespace,
    /// because the set's `database` would otherwise collide with the design
    /// glyph of the same name.
    public static let catalogNamespace = "FileIcons"

    /// The namespaced name the app loads this image by, `FileIcons/<rawValue>`.
    public var catalogName: String {
        FileTypeIcon.catalogNamespace + "/" + rawValue
    }

    /// The icon for a file called `name` — a bare name or a path; only the last
    /// component is read, case-insensitively. See the type's documentation for
    /// the phase order.
    public static func forFile(named name: String) -> FileTypeIcon {
        let name = (name as NSString).lastPathComponent.lowercased()

        // 1. Database.
        if DatabaseFileRule.isDatabaseFile(named: name) { return .database }

        // 2. Special names: exact, stem, prefix.
        if let icon = exactNames[name] { return icon }
        for (stem, icon) in stems where name == stem || name.hasPrefix(stem + ".") {
            return icon
        }
        for (prefix, suffix, icon) in prefixes where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            return icon
        }

        // 3. Compound suffixes.
        for (suffix, icon) in compoundSuffixes where name.hasSuffix(suffix) {
            return icon
        }

        // 4. Extensions the language does not claim, and the one override.
        if let icon = extensions[(name as NSString).pathExtension] { return icon }

        // 5. Language.
        if let language = SyntaxLanguage(forFileName: name) { return forLanguage(language) }

        // 6. Fallback.
        return .document
    }

    /// The icon for a file that highlights as `language`.
    public static func forLanguage(_ language: SyntaxLanguage) -> FileTypeIcon {
        switch language {
        case .swift: return .swift
        case .javascript: return .javascript
        case .typescript: return .typescript
        case .tsx: return .reactTS
        case .json: return .json
        case .markdown: return .markdown
        case .python: return .python
        case .go: return .go
        case .rust: return .rust
        case .html: return .html
        case .css: return .css
        case .yaml: return .yaml
        case .dockerfile: return .docker
        case .dotenv: return .tune
        case .gitignore: return .git
        case .sql: return .database
        case .editorconfig: return .editorconfig
        case .shell: return .console
        case .make: return .makefile
        }
    }

    /// Phase 2, lowercased whole names.
    private static let exactNames: [String: FileTypeIcon] = [
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
        "codeowners": .codeowners,
        "robots.txt": .robots,
    ]

    /// Phase 2, stems: the name equals the stem or starts with stem + `.`.
    private static let stems: [(String, FileTypeIcon)] = [
        ("readme", .readme),
        ("changelog", .changelog),
        ("contributing", .contributing),
        ("license", .license),
        ("docker-compose", .docker),
    ]

    /// Phase 2, prefixes, each with the suffix the name must also end in (empty
    /// for none). Only `tsconfig` needs one: `tsconfig.json` and its
    /// `tsconfig.*.json` variants are the compiler's configuration, while a
    /// `tsconfig.ts` is ordinary TypeScript.
    private static let prefixes: [(String, String, FileTypeIcon)] = [
        ("tsconfig", ".json", .tsconfig),
        (".prettierrc", "", .prettier),
        ("prettier.config.", "", .prettier),
        (".eslintrc", "", .eslint),
        ("eslint.config.", "", .eslint),
        ("vitest.config.", "", .vitest),
        ("vitest.workspace.", "", .vitest),
        ("jest.config.", "", .jest),
    ]

    /// Phase 3. None of these is a suffix of another, so their order is free.
    private static let compoundSuffixes: [(String, FileTypeIcon)] = [
        (".test.ts", .testTS),
        (".spec.ts", .testTS),
        (".test.tsx", .testJSX),
        (".spec.tsx", .testJSX),
        (".test.jsx", .testJSX),
        (".spec.jsx", .testJSX),
        (".test.js", .testJS),
        (".spec.js", .testJS),
        (".d.ts", .typescriptDef),
    ]

    /// Phase 4, lowercased extensions. Apart from `jsx`, none is one
    /// `SyntaxLanguage` claims; `FileTypeIconTests` holds that through the
    /// language's extension seam, whose every entry must answer its language's
    /// icon except `jsx`.
    private static let extensions: [String: FileTypeIcon] = [
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
}
