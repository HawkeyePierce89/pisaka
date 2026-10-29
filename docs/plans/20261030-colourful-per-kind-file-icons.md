# Colourful per-kind file icons from a vendored icon set, on every surface that draws a file

## Overview

Every file icon in the app becomes a full-colour icon that shows what kind of file it is:
TypeScript, React component, JSON, Dockerfile, Markdown, test file and so on. This applies on
macOS and on iOS. Today macOS draws three grey template glyphs (`file-code` / `file-text` /
`database`, from `FileGlyph.forFile(named:)`) in the tree, tabs, draft and Find in Files, and
tinted SF Symbols (`FileIcon`) in Problems, Usages and the Log; iOS draws tinted SF Symbols
(`FileIcon`). The pictures come from one vendored, MIT-licensed open-source file-icon set. Only
the 59 icons the new Core table names are shipped. They are copied byte for byte from one pinned
commit, pinned by digest, licensed in the bundle, and recorded in a `VENDORED.md` that is not
bundled. This follows the pattern the design glyphs already use.

Naming rule. The set's own display name, "Material Icon Theme", carries no editor brand and may
appear in exactly three places: the manifest entry in `Resources/Licenses/licenses.json` (so the
Acknowledgements screens attribute it honestly, as the design glyphs' entry "Lucide (design
glyphs)" does), the verbatim licence text, and the record `Resources/FileIcons/VENDORED.md`.
Everywhere else (code, comments, docs, commit messages) it is "the vendored file-icon set". The
repository URL, whose slug carries an editor's name, is written only in
`Resources/FileIcons/VENDORED.md`.

Folders do not change. macOS keeps `FileGlyph.forFolder(expanded:)` in `textSecondary`, and iOS
keeps the accent-tinted `folder` symbol.

Decisions taken here so the run needs none:

- Core table: `FileTypeIcon` in `Sources/PisakaCore/FileTypeIcon.swift`, a closed `String` enum.
  Each raw value is an imageset name, which is also the upstream file stem. `catalogName` is the
  namespaced lookup name `FileIcons/<rawValue>`.
- App helper: `FileTypeIconImage` in `Sources/Pisaka/FileTypeIconImage.swift`. It is one SwiftUI
  view compiled for both platforms. No AppKit builder is added, because every macOS file-icon
  site is SwiftUI (the project tree's rows included).
- `FileIcon` and `FileIconColor` are retired completely, together with `FileIconTests`. iOS
  directory rows keep drawing `folder` in `Color.accentColor` through one small iOS view.
- The catalog folder `Sources/Pisaka/Assets.xcassets/FileIcons/` sets `provides-namespace: true`.
  The upstream `database` icon would otherwise collide with the design glyph `database` in the
  non-namespaced `Glyphs/` folder. The namespace also keeps rule forty-six's literal matcher from
  confusing the two families.
- The lookup property is named `catalogName`, not `assetName` / `rawValue`. Rule forty-six flags
  those two tokens for design glyphs; the new loader rule reads `catalogName`.

## Context

- Files involved:
  - Core: `Sources/PisakaCore/FileGlyph.swift` (keeps `forFolder` only),
    `Sources/PisakaCore/FileIcon.swift` (deleted), `Sources/PisakaCore/SyntaxLanguage.swift`
    (comment on the `exactFileNames` / `fileExtensions` seams),
    `Sources/PisakaCore/DatabaseFileRule.swift` (read, not changed), new
    `Sources/PisakaCore/FileTypeIcon.swift`. Doc comments citing `FileIcon` / `FileIconColor` as
    a precedent are spread over about 30 Core and app files;
    `grep -rnw 'FileIcon\|FileIconColor' Sources Tests` lists them.
  - App, macOS: `ProjectTreeView.swift` (`FileRowView`), `ProjectTreeDraftField.swift`,
    `TabStripView.swift` (`TabFileIcon`), `ProjectSearchView.swift` (`groupHeader`),
    `ProblemsPanelView.swift` / `UsagesPanelView.swift` (`fileGroup`), `CommitLogView.swift` (the
    changed-file row), `DesignGlyphImage.swift` (the model), new `FileTypeIconImage.swift`.
  - App, iOS: `iOS/RootView_iOS.swift` (tree rows plus the `swiftUIColor(for:)` mapping),
    `iOS/LocalChangesView_iOS.swift` (file rows, folder rows, `iconColor(for:)`),
    `iOS/CommitLogView_iOS.swift` (`CommitFileRow_iOS`).
  - Assets and records: `Sources/Pisaka/Assets.xcassets/FileIcons/` (new),
    `Resources/FileIcons/VENDORED.md` (new, not bundled), `Resources/Licenses/file-icons.txt`
    (new), `Resources/Licenses/licenses.json`.
  - Tests: new `Tests/PisakaCoreTests/FileTypeIconTests.swift`, new
    `Tests/PisakaCoreTests/FileTypeIconAssetTests.swift`, `FileGlyphTests.swift`,
    `FileIconTests.swift` (deleted), `CrossPlatformAuditTests.swift`,
    `LicenseCoverageTests.swift`, `ChromeThemeSourceGatingTests.swift`, new
    `Tests/PisakaAppTests/FileTypeIconImageTests.swift`,
    `Tests/PisakaAppTests/TreeDiagnosticMarkTests.swift`, and the doc comments of the
    hosted-render suites that describe the old grey file glyph (e.g. `TreeGitStatusColourTests`).
  - Docs: `docs/architecture/core-theme.md`, `app-window.md`, `app-editor.md`,
    `app-git-views.md`, `app-ios.md`, `core-editor.md`, `core-database-viewer.md`, plus every
    other architecture doc citing `FileIcon`; `CLAUDE.md`, `README.md`, `docs/FEATURES.md`.
- Related patterns:
  - The asset pin: `DesignGlyphAssetTests` with `Resources/DesignGlyphs/VENDORED.md`.
  - The run-time load: `DesignGlyphImageTests`.
  - The sole-loader rule: rule forty-six, `testDesignGlyphsAreDrawnOnlyThroughTheHelper`, with its
    self-check `testTheGlyphRuleFlagsEveryLoadSpelling`.
  - The "fourth origin shape" of `LicenseCoverageTests`, an asset-catalog folder checked from both
    ends.
  - Set equality against `SyntaxLanguage.allCases`, as the keyword and symbols-query suites do.
- Dependencies: no package. The icon files and their licence are data, fetched once at
  implementation time from one pinned commit.

### Source of the icon set (all literals; never fetch anything else)

- Repository: GitHub repository id `67831372`. Its tarball for the pinned commit is
  `https://api.github.com/repositories/67831372/tarball/045291ff033062a25441dd297fd51546326866f2`.
  It redirects to the codeload archive.
- Tag `v5.40.0` (annotated tag object `0d17360506c477b4ccb065d8acdbd056331af1fb`) resolves to
  commit `045291ff033062a25441dd297fd51546326866f2`. The record states both.
- Handling: download and extract into a new, empty temporary directory. Treat its contents as
  data only: run nothing from it and run no interpreter inside it.
- Source URL for the record: the tarball's `package.json` field `repository.url`, with the `git+`
  prefix and the `.git` suffix removed. The record is the only place the URL is written.
- Icons are `<top>/icons/<name>.svg`. The licence is `<top>/LICENSE`: sha256
  `cdab3014d4f69b49dde2b85e81792208c72de613aa6aed7f7a9b5c6609b89670`, 1085 bytes, MIT, copyright
  holder "Material Extensions".
- Before copying, check every file against the table below: the first 16 hex digits of its
  sha256 and its byte count. A mismatch means the wrong archive was fetched. Fetch again from the
  literal URL above; the expected bytes are not in question.

### The 59 shipped icons (raw value = imageset name = upstream stem)

| Icon | sha256 prefix | Bytes | `_light` variant upstream |
|---|---|---|---|
| swift | 2cf5377f88aa8cb4 | 502 | — |
| javascript | 00eb9422f4519015 | 291 | — |
| typescript | 1822f88268b452ce | 267 | — |
| react_ts | f5caa02786d9ce96 | 1104 | — |
| json | 649ad4f4d01cec78 | 540 | — |
| markdown | 42f95867350ed1f3 | 161 | — |
| python | 798fcd59653af34e | 773 | — |
| go | eb3b74fcad124042 | 745 | — |
| rust | a58c24641e82c1ba | 526 | — |
| html | 23e04ad5f1ae9cd1 | 232 | — |
| css | afe20f8da21f1f2d | 674 | — |
| yaml | 666b724d61cfa091 | 199 | — |
| docker | 3d032b712bbedea1 | 1501 | — |
| tune | 786079eb0fe64343 | 268 | — |
| git | b0caee7c9cb4e602 | 729 | — |
| database | e0679294defea907 | 332 | — |
| editorconfig | 199762cbea98d785 | 8091 | — |
| console | c5f33efa92ce94d2 | 223 | — |
| makefile | a6d8260757abc492 | 943 | — |
| react | 6a7fb2e8b5e168c0 | 1104 | — |
| test-ts | 7ec0f2314d2937a9 | 615 | — |
| test-js | ce9c34d8ab5b7560 | 615 | — |
| test-jsx | 4fc0daa5e61deaef | 615 | — |
| typescript-def | 3dd13d3bc29103ea | 274 | — |
| nodejs | 365af5c7b70d11c2 | 375 | — |
| npm | 6bd740d3e31675d1 | 132 | — |
| yarn | a9ded67f57faa176 | 918 | — |
| pnpm | a3d8e5760f080d0f | 222 | yes — not taken |
| tsconfig | a7bd2a966578a9ec | 411 | — |
| readme | ed41dbf841368745 | 215 | — |
| changelog | 30377c6875c27b98 | 314 | — |
| contributing | 32e5eb75555da8e5 | 303 | — |
| license | 4b0a147a39eade32 | 225 | — |
| codeowners | a1f09959acd8a60e | 262 | — |
| prettier | b81b3661b6ec0aac | 346 | — |
| eslint | aeb3a553e20f087a | 665 | — |
| vitest | c845017d0b57201a | 318 | — |
| jest | a43bd245edf20ab6 | 519 | — |
| robots | 7540bc749364bd0d | 402 | — |
| lock | f28fe89b018236f9 | 246 | — |
| c | 4adba54251e85851 | 245 | — |
| h | 73fa9417071d70dc | 185 | — |
| cpp | 336346afba3afb62 | 325 | — |
| hpp | a030bcbf24e67aed | 232 | — |
| java | 755c5b6f3fe0fb1e | 208 | — |
| kotlin | 94583b191f9a7898 | 517 | — |
| ruby | a7f0628476482b9f | 491 | — |
| php | 5163a63d5a8d8192 | 880 | — |
| lua | d69816f1ae2002f2 | 576 | — |
| toml | eaeb55ba45f14a50 | 180 | yes — not taken |
| xml | 51bfeb938c24772c | 290 | — |
| svg | 120ceffcaa97658a | 1285 | — |
| table | 1714898c0d538648 | 268 | — |
| image | 838e1953a3a2ebf5 | 346 | — |
| font | 092850724e8e29ff | 165 | — |
| pdf | c14c66a3914b894d | 976 | — |
| zip | dad79a45f756542d | 230 | — |
| sass | e613bd47d598c54c | 1281 | — |
| document | 64f5da56de591d5f | 234 | — |

The SVG content was checked at planning time. None of the 59 uses `<style>`, `<script>`,
`<text>`, `<image>`, `<foreignObject>`, `<filter>`, `<mask>`, `<clipPath>`, opacity or any
`href`. Only `kotlin` uses a `<linearGradient>`. All 59 were drawn through the system SVG renderer
at planning time and every one produced ink; the drawn-ink test in Task 3 is a guard against a
future catalog-compiler or update regression, not an open question.

Three icons draw mostly in very light fills that are weak on the light ground: `editorconfig`
(#eee / #fafafa, no coloured ink at all), `pnpm` (#e0e0e0 half) and `toml` (#cfd8dc letter). They
ship as they are, and the docs record them as follow-ups (R3).

### Resolution order of `FileTypeIcon.forFile(named:)`

Each phase lowercases the last path component first, so matching is case-insensitive. The first
phase that answers wins.

1. **Database.** `DatabaseFileRule.isDatabaseFile(named:)` gives `database`.
2. **Special names**, in three sub-tables checked in this order:
   - **Exact names**:
     - `package.json`, `.nvmrc`, `.node-version` → `nodejs`
     - `package-lock.json`, `.npmrc`, `.npmignore` → `npm`
     - `yarn.lock`, `.yarnrc`, `.yarnrc.yml` → `yarn`
     - `pnpm-lock.yaml`, `pnpm-workspace.yaml` → `pnpm`
     - `.gitattributes`, `.gitmodules`, `.gitkeep` → `git`
     - `.dockerignore`, `compose.yml`, `compose.yaml` → `docker`
     - `.prettierignore` → `prettier`
     - `.eslintignore` → `eslint`
     - `codeowners` → `codeowners`
     - `robots.txt` → `robots`
   - **Stems.** The name equals the stem or starts with stem + `.`:
     - `readme` → `readme`; `changelog` → `changelog`; `contributing` → `contributing`;
       `license` → `license`; `docker-compose` → `docker`
   - **Prefixes**:
     - `tsconfig` (and the name ends in `.json`) → `tsconfig`
     - `.prettierrc`, `prettier.config.` → `prettier`
     - `.eslintrc`, `eslint.config.` → `eslint`
     - `vitest.config.`, `vitest.workspace.` → `vitest`
     - `jest.config.` → `jest`
3. **Compound suffixes**, before plain extensions:
   - `.test.ts`, `.spec.ts` → `test-ts`
   - `.test.tsx`, `.spec.tsx`, `.test.jsx`, `.spec.jsx` → `test-jsx`
   - `.test.js`, `.spec.js` → `test-js`
   - `.d.ts` → `typescript-def`
4. **Extension table**: the extensions `SyntaxLanguage` does not claim, plus exactly one override,
   `jsx` → `react`.
   - `scss`, `sass` → `sass`
   - `c` → `c`; `h` → `h`
   - `cpp`, `cc`, `cxx` → `cpp`; `hpp`, `hh`, `hxx` → `hpp`
   - `java` → `java`; `kt`, `kts` → `kotlin`
   - `rb` → `ruby`; `php` → `php`; `lua` → `lua`
   - `toml` → `toml`; `xml` → `xml`; `svg` → `svg`
   - `csv`, `tsv` → `table`
   - `png`, `jpg`, `jpeg`, `gif`, `webp`, `ico`, `bmp`, `tif`, `tiff` → `image`
   - `ttf`, `otf`, `woff`, `woff2` → `font`
   - `pdf` → `pdf`
   - `zip`, `gz`, `tgz`, `tar`, `bz2`, `xz`, `7z`, `rar` → `zip`
   - `lock` → `lock`
5. **Language.** `SyntaxLanguage(forFileName:)` is mapped through `FileTypeIcon.forLanguage(_:)`,
   an exhaustive `switch`:
   - swift → `swift`; javascript → `javascript`; typescript → `typescript`; tsx → `react_ts`
   - json → `json`; markdown → `markdown`; python → `python`; go → `go`; rust → `rust`
   - html → `html`; css → `css`; yaml → `yaml`; dockerfile → `docker`; dotenv → `tune`
   - gitignore → `git`; sql → `database`; editorconfig → `editorconfig`; shell → `console`;
     make → `makefile`
6. **Fallback**: `document`.

Why phase 5 exists: the names `SyntaxLanguage` already owns are not restated, so the data stays in
one place. Those names are `Makefile`, `GNUmakefile`, `Dockerfile` and `Dockerfile.*`,
`.editorconfig`, `.gitignore` and the dot-ignore family, the ten shell start-up dot-files, `.env`
and `.env.*`. They reach their icon through the language phase. Two consequences, both pinned by
tests:

- `.env.local` gets `tune`, while `.env.json` stays `json`, as its highlighting does.
- `Package.swift` gets `swift` through its extension, because the set has no manifest-specific
  Swift icon.

## Development Approach

- **Testing approach**: TDD. Each task writes its failing tests first, then the code, then runs
  the gates.
- Complete each task fully before moving to the next. Commits are imperative, with no attribution
  footer and no session links.
- Repository conventions apply:
  - Set equality over counts. Where a count is unavoidable, pin it cross-file.
  - Repository-file suites match against stripped text, and every literal-keeping reading states
    its reason in the suite's doc comment.
  - Each suite's doc comment is its inventory.
  - No stop-and-report steps: every decision is above.
  - No editor brand names and no comparisons with other editors in code, comments, docs or
    commits. The set's display name appears only in `Resources/Licenses/licenses.json`,
    `Resources/Licenses/file-icons.txt` and `Resources/FileIcons/VENDORED.md`; the repository URL
    only in `Resources/FileIcons/VENDORED.md`.
- Gate commands. Every `xcodebuild` runs under the pinned Xcode, uses the one permanent
  DerivedData folder, and runs after `xcodegen generate`, because the project is generated and
  gitignored:
  - `swift test`
  - `xcodegen generate`
  - `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`
  - `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
  - `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
  - `swiftlint --strict` (pinned 0.65.1), run from the repository root.
  - Every app-layer result reported names Xcode 26.3.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The Core table `FileTypeIcon`

**Files:**
- Create: `Sources/PisakaCore/FileTypeIcon.swift`
- Create: `Tests/PisakaCoreTests/FileTypeIconTests.swift`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift` (doc comment of the two internal seams only)

The intent: one Foundation-only, colour-free answer to "which icon is this file", for both
platforms.

- It is a closed `public enum FileTypeIcon: String, CaseIterable, Sendable` with the 59 cases of
  the table above. Swift case names are camel-cased where the raw value cannot be an identifier,
  for example `reactTS = "react_ts"`, `testJSX = "test-jsx"`, `typescriptDef = "typescript-def"`.
- `public static let catalogNamespace = "FileIcons"` and `public var catalogName: String`
  (`"FileIcons/" + rawValue`).
- `public static func forFile(named:)` implements the six phases above.
- `public static func forLanguage(_:)` is the exhaustive switch.
- The tables are private data in this one file. `DatabaseFileRule` and `SyntaxLanguage` are
  asked, never restated.

Steps:

- [x] Write `FileTypeIconTests` first, so that it fails to compile or fails. It covers:
  - **Order**:
    - `README.db` → `database` (the database rule beats a stem), `notes.sqlite` → `database`
    - `package.json` → `nodejs`, `LICENSE.md` → `license`, `robots.txt` → `robots` (a special
      name beats its extension)
    - `tsconfig.app.json` → `tsconfig`
    - `app.test.ts` → `testTS` vs `app.ts` → `typescript`; `App.spec.tsx` → `testJSX` vs
      `App.tsx` → `reactTS`; `index.d.ts` → `typescriptDef` (a compound suffix beats its plain
      extension)
    - `Button.jsx` → `react` (the one override beats the language phase)
    - `.dockerignore` → `docker`, `.npmignore` → `npm`, `.prettierignore` → `prettier` (a special
      name beats the dot-ignore family), while `.stylelintignore` → `git`
    - `.env.local` → `tune`, while `.env.json` → `json`
  - **Case and paths**: `MAIN.SWIFT`, `Readme.MD`, `PACKAGE.JSON`, and a path such as
    `src/components/App.tsx` resolve as their lowercased last component.
  - **Floor**: the names today's `FileIcon` special-cases resolve to named icons, written out
    literally in the test:
    - `Package.swift` → `swift`; `LICENSE` → `license`
    - `.gitignore` and `.gitattributes` → `git`
    - `Makefile` and `GNUmakefile` → `makefile`
    - `Dockerfile` → `docker`; `.editorconfig` → `editorconfig`
    - `.bashrc`, `.bash_profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zshenv`, `.zlogin`,
      `.zlogout`, `.profile`, `.envrc` → `console`
  - **Every language**:
    - A sample-name table keyed by `SyntaxLanguage` whose key set equals
      `Set(SyntaxLanguage.allCases)`. Each sample resolves to `forLanguage(case)`, and no case
      maps to `document`.
    - Every name in `SyntaxLanguage.exactFileNames` and every extension in
      `SyntaxLanguage.fileExtensions` resolves to `forLanguage` of its language, except a pinned
      override set equal to exactly `["jsx"]`.
  - **Reachability**: the set of answers over the test's sample names equals
    `Set(FileTypeIcon.allCases)`, so no case is a dead asset.
  - **Fallback**: `unknown.xyz`, `noextension`, `notes.txt` and the empty string → `document`.
  - **Catalog name**: `catalogName` is `FileIcons/<rawValue>` for every case.
- [x] Implement `FileTypeIcon.swift`. Its doc comment states the phase order and why it exists:
  database first, because a `.db` file is not text; the language phase last before the fallback,
  so the names `SyntaxLanguage` owns are never restated.
- [x] Update the `exactFileNames` / `fileExtensions` seam comment in `SyntaxLanguage.swift` to
  name `FileTypeIconTests` as its reader. Do not touch the recognition rules.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Vendor the 59 icons, their record and their licence

**Files:**
- Create: `Sources/Pisaka/Assets.xcassets/FileIcons/Contents.json` and
  `FileIcons/<name>.imageset/{<name>.svg, Contents.json}` × 59
- Create: `Resources/FileIcons/VENDORED.md`
- Create: `Resources/Licenses/file-icons.txt`
- Modify: `Resources/Licenses/licenses.json`
- Create: `Tests/PisakaCoreTests/FileTypeIconAssetTests.swift`
- Modify: `Tests/PisakaCoreTests/LicenseCoverageTests.swift`

The intent: the icons ship exactly as the design glyphs do, with one difference each: they are
SVG, original rendering intent (never template), and in a namespaced folder of their own.

- The folder's `Contents.json` sets `"provides-namespace": true`.
- Each imageset's `Contents.json` names its one SVG (`idiom: universal`) and sets
  `"preserves-vector-representation": true` and `"template-rendering-intent": "original"`.
- `Glyphs/` is not touched.

Steps:

- [x] Write `FileTypeIconAssetTests` first, in the `DesignGlyphAssetTests` mould. It uses
  Foundation and Core's `SHA256` only, and reads through `#filePath`. Its doc comment is its
  inventory. It pins:
  - **Three-way set equality**, in both directions: the imageset names on disk,
    `FileTypeIcon.allCases` raw values, and the rows of the record's icon table.
  - **Bytes**: each SVG's sha256 prefix and byte count equal a pinned table transcribed into the
    suite (the table above), and the record's row states the same two values.
  - **Light-variant column**: it equals the pinned set `{pnpm, toml}`.
  - **Contents files**: each imageset's `Contents.json` names exactly its own SVG and carries the
    two properties above. The folder's `Contents.json` carries `provides-namespace: true`, and the
    folder name equals `FileTypeIcon.catalogNamespace`.
  - **SVG content**: every SVG's root element is `<svg` with a `viewBox`, and the file contains no
    `<style`, `<script`, `<text`, `<image`, `<foreignObject` and no `href`. These are features the
    system's SVG renderer drops silently, so a future update cannot ship an icon that draws
    nothing. This reads literals, so it reads raw bytes; the doc comment says so.
  - **Record header**: the record states tag `v5.40.0` and commit
    `045291ff033062a25441dd297fd51546326866f2`.
- [x] Extend `LicenseCoverageTests`.
  - Its "fourth origin shape" generalizes from the single design-glyph origin to a two-entry table
    of asset-catalog-folder origins: `design-glyphs` → `Glyphs` +
    `Resources/DesignGlyphs/VENDORED.md`, and `file-icons` → `FileIcons` +
    `Resources/FileIcons/VENDORED.md`. Each gets the same two-ended check: every imageset in the
    folder is listed in its record and nothing else is in the folder, and the record's
    `Revision` / `Version` equal the manifest entry's.
  - `expectedCopyrightHolders` gains `"file-icons": "Material Extensions"` (the holder from the
    licence's `Copyright` line), spelled in the suite like every other entry; the key set still
    equals the manifest ids.
  - Update the suite's doc comment.
- [x] Fetch the archive as described in Context. Verify the 59 files and the licence against the
  literals, then copy each SVG byte for byte to `FileIcons/<name>.imageset/<name>.svg`. Write the
  59 `Contents.json` files and the folder's own.
- [x] Copy `LICENSE` verbatim to `Resources/Licenses/file-icons.txt`. Add the manifest entry right
  after `design-glyphs`:
  - `"id": "file-icons"`
  - `"name": "Material Icon Theme (file-type icons)"`
  - `"origin": "Sources/Pisaka/Assets.xcassets/FileIcons"`
  - `"version": "v5.40.0"`
  - `"revision": "045291ff033062a25441dd297fd51546326866f2"`
  - `"spdx": "MIT"`
  - `"file": "file-icons.txt"`
- [x] Write `Resources/FileIcons/VENDORED.md`, modelled on the design glyphs' record.
  - It says it is a record, not a resource: `project.yml` does not bundle the directory.
  - A header table: Source (the URL from `package.json`; the only place in the repository it is
    written), Tag, Commit, Revision (= commit), Version (= tag), Origin, License (MIT, the path of
    the verbatim copy).
  - The icon table: Icon | Prefix | Bytes | Light variant.
  - A sentence on why only 59 of 908 ship (only what the Core table names), and why no `_light`
    variant is taken (one image per kind in both appearances).
  - An "Updating by hand" procedure: fetch by commit, verify, copy, update the enum, both tables
    and the manifest entry, then run `swift test`.
- [x] Confirm by reading that the macOS and iOS acknowledgement screens list every manifest notice
  with no filter, so the new entry appears on both under its display name. No code change is
  expected; if a filter exists, remove it for this entry and test that.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: The drawing helper and the macOS surfaces

**Files:**
- Create: `Sources/Pisaka/FileTypeIconImage.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`, `ProjectTreeDraftField.swift`,
  `TabStripView.swift`, `ProjectSearchView.swift`, `ProblemsPanelView.swift`,
  `UsagesPanelView.swift`, `CommitLogView.swift`
- Modify: `Sources/PisakaCore/FileGlyph.swift`, `Tests/PisakaCoreTests/FileGlyphTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/FileTypeIconImageTests.swift`
- Modify: `Tests/PisakaAppTests/TreeDiagnosticMarkTests.swift`, and the doc comments of the
  hosted-render suites that describe the old grey file glyph (e.g. `TreeGitStatusColourTests`)

The intent: one view draws a file icon at full colour, sharp at every interface scale, in the slot
each site already uses, so no row height or baseline moves.

`FileTypeIconImage(_ icon: FileTypeIcon, side: Double)` behaves as follows:

- It draws `Image(icon.catalogName)` with `.renderingMode(.original)`, `.resizable()` and
  `.scaledToFit()`, in a square frame of `side` points, hidden from accessibility (the row's text
  names the file).
- It never applies a template mode, `foregroundStyle` or a tint.
- On macOS the side is `metrics.pt(side)` from `interfaceMetrics`.
- On iOS it is `side × @ScaledMetric(relativeTo: .body)` with a base of 1, so it follows Dynamic
  Type as the SF Symbol did.
- The file is compiled for both platforms, and the platform split stays inside it.

Slots on macOS:

- Tree rows and the draft: `TreeRowLayout.iconSize` (14). The `.treeDiagnosticDot` modifier stays
  on the icon.
- Both tab orientations through `TabFileIcon`: 13. The untitled-buffer fallback stays spelled once
  there.
- Find in Files headers: `SearchLayout.headerGlyphSlot` (14).
- Problems and Usages file-group headers and the Log's changed-file row: a 14-point frame, as a
  named constant in each surface's own layout type. The 14-point frame sits within the body font's
  line height, so the row height does not move; the layout gate below confirms it.

The Log row's icon loses its status tint. The status letter keeps it, and the docs say so.

`FileGlyph` keeps only `forFolder(expanded:)`. Its doc comment states that file icons are
`FileTypeIcon`'s.

Steps:

- [ ] Write the tests first.
  - **App, `FileTypeIconImageTests`**. It is cheap: no window anywhere in the suite except the two
    `HostedRender`s named below.
    - Every `FileTypeIcon` loads through `NSImage(named: icon.catalogName)` non-nil, and
      `isTemplate == false`.
    - **Drawn ink, every icon**: one 32×32 bitmap context is created once; for each of the 59
      icons it is cleared, the image is drawn into it once, and at least one pixel must be fully
      opaque (alpha 255). The failure message names the icon. This catches an icon the catalog
      compiler drops silently (`kotlin`'s gradient fill is the one at risk); all 59 pass at
      planning time, so this is a guard.
    - `typescript` drawn once into one 48×48 bitmap: its inked pixels are saturated blue (about
      `#0288d1`), not grey and not `textSecondary`.
    - `document` drawn once: its corner pixel is transparent, which proves the root `fill="none"`
      is honoured.
    - One `HostedRender` of `FileTypeIconImage(.typescript, side: 14)` under `ChromeTheme(.dark)`
      and one under `.light`: the drawn ink is the same blue in both, and nothing tints it.
    - **Layout gate for the 14-point slot**: an `HStack` of `FileTypeIconImage(_, side: 14)`
      beside a `Text` in `metrics.scaledFont(.body, weight: .medium)` fits to the same height as
      the `Text` alone, measured through `NSHostingController.sizeThatFits` (no window), at
      interface scale 1.0 and at the interface zone's maximum. This is the property the Problems,
      Usages and Log rows rely on.
  - **App, `TreeDiagnosticMarkTests`**:
    - Move its fixture files from `.swift` to `.go`: the swift icon's orange ink would collide
      with the dot colours the suite samples, while the cyan go icon has no red or yellow ink.
    - Add the missing no-lookup precondition that the warning rows' corners carry no
      `statusYellow`.
    - Together these mean neither dot assertion can be satisfied by an icon's own colour. No
      tolerance is loosened, and the doc comment says why the extension is `.go`.
  - **Core, `ChromeThemeSourceGatingTests`**:
    - A new rule, fifty-three: file-type icons are drawn only through their helper, never as a
      template.
    - It reads every source under `Sources/Pisaka/`, the iOS directory included, with the
      literal-keeping scanner. Its needles are rule forty-six's plus `UIImage(named:`. A load
      names a file-type icon when its argument is the token `catalogName` or a literal starting
      with `FileIcons/`.
    - The loader set equals exactly `{FileTypeIconImage.swift}`.
    - The helper spells `catalogName` in its load(s), spells `.renderingMode(.original)`, and
      spells none of `.template`, `isTemplate`, `foregroundStyle` or `tint`.
    - A self-check is fed every bypass spelling, like `testTheGlyphRuleFlagsEveryLoadSpelling`.
    - Rule forty-six must still pass, with the helper not flagged by it.
    - `FileTypeIconImage.swift` joins `gatedFiles` (sixty-eight). It spells no colour, so every
      colour rule holds for it.
    - The `glyphSizeExemptions` entries for the Problems and Usages `fileGroup` symbols are
      removed, because those symbols are gone.
    - Rule eight's set of gated files constructing `FileIcon(` becomes empty.
    - Update every restated count (rule total, gated-file total and the number-word table) and the
      suite header's inventory.
  - **Core, `FileGlyphTests`**: reduced to the folder answer.
- [ ] Implement the helper and switch the seven macOS sites. Remove `FileGlyph.forFile(named:)`.
  No site other than the helper loads a `FileIcons/` asset.
- [ ] Run `swift test` and the app-layer bundle under Xcode 26.3. The hosted-render layout suites
  touching these rows must stay green: the tree glyph, chain, indent-guide, git-status,
  dependency-caption and sticky suites, tabs, Find in Files and the dock. The rules for making them
  green:
  - No assertion and no tolerance is loosened; a failing layout or colour assertion is fixed in
    the code.
  - Doc comments that describe the old grey file glyph (e.g. `TreeGitStatusColourTests`' "the
    glyph keeps textSecondary") are updated to describe the full-colour icon.
  - A fixture's file extension may change only where an icon's own colour would collide with a
    role the suite samples, and each such change is stated in that suite's doc comment with the
    reason (the `TreeDiagnosticMarkTests` `.go` move above is the first instance).

### Task 4: iOS surfaces, and the retirement of `FileIcon`

**Files:**
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`, `iOS/LocalChangesView_iOS.swift`,
  `iOS/CommitLogView_iOS.swift`
- Delete: `Sources/PisakaCore/FileIcon.swift`, `Tests/PisakaCoreTests/FileIconTests.swift`
- Modify: `Tests/PisakaCoreTests/CrossPlatformAuditTests.swift`,
  `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: every source whose doc comment cites `FileIcon` / `FileIconColor` (about 30 files, found
  with `grep -rnw`)

The intent: iOS draws the same assets through the same helper, and the old Core vocabulary
disappears without leaving references to a type that no longer exists.

- iOS tree file rows, Local Changes file rows and commit Log file rows draw
  `FileTypeIconImage(FileTypeIcon.forFile(named:), side: 18)`. The status tint moves to the
  status letter alone, which already carries it.
- iOS directory rows (the tree and the Local Changes by-folder tree) draw one internal
  `FolderSymbol_iOS` view declared in `RootView_iOS.swift`: `Image(systemName: "folder")` in
  `Color.accentColor`, exactly as today.
- Both colour-mapping helpers (`swiftUIColor(for:)` and `iconColor(for:)`) are deleted.

Steps:

- [ ] Write the tests first:
  - Replace `CrossPlatformAuditTests.testFileIconResolutionIsStable` with a `FileTypeIcon`
    equivalent: the table is platform-independent, a known name answers its icon, and an unknown
    one answers `document`.
  - In `ChromeThemeSourceGatingTests`:
    - Remove `FileIcon.swift` from `colorExemptions`, which leaves three exemptions; update the
      "four" wording and the counts.
    - Delete rule one's `FileIcon(` line exemption (`iconFreeLines` / `constructsFileIcon`) and
      rule eight's third half, keeping its declaration and fallback halves.
    - Rule fifty-three's iOS coverage now sees the iOS sites go through the helper.
- [ ] Switch the three iOS files, add `FolderSymbol_iOS`, and delete `FileIcon.swift` and
  `FileIconTests.swift`.
- [ ] Sweep the comments that cite `FileIcon` or `FileIconColor` as a precedent so that each names
  a surviving one: `SyntaxTokenKind` / `ChromeColorRole` for "a colour-free semantic enum in
  Core", `FileTypeIcon` for "a name-table mapping in Core". The `ChangeTree.swift` comment names
  `FileTypeIcon.forFile(named:)`. `grep -rnw 'FileIcon\|FileIconColor' Sources Tests` must return
  nothing; `TabFileIcon` is a different word.
- [ ] Run `swift test`, the app-layer bundle under Xcode 26.3, and the iOS build. All must pass
  before Task 5.

### Task 5: Documentation and `CLAUDE.md`

**Files:**
- Modify: `docs/architecture/core-theme.md`, `app-window.md`, `app-editor.md`, `app-git-views.md`,
  `app-ios.md`, `core-editor.md`, `core-database-viewer.md`, plus any other architecture doc that
  names `FileIcon` / `FileIconColor`
- Modify: `CLAUDE.md`, `README.md`, `docs/FEATURES.md`

Steps:

- [ ] `core-theme.md`:
  - Entries for `FileTypeIcon.swift` (the phases, the namespace, `catalogName`) and
    `FileTypeIconImage.swift` (its shape and the slots it is drawn in).
  - **The third stated exception**, beside `hairlineWidth` and the terminal: a file-type icon's
    colour is its identity, carried in the asset's own data, so no role can name it. It is drawn
    original and never tinted.
  - Rewrite "The monochrome-icon decision" accordingly: folders and every other glyph stay
    monochrome `textSecondary`, and file icons are full colour.
  - Add rule fifty-three to the canonical rule list and the helper to the gated-file narrative
    (sixty-eight). Drop the `FileIcon` exemption, which leaves three.
  - Follow-ups:
    - `editorconfig`, `pnpm` and `toml` are weak on the light ground. No second image is shipped.
    - The design glyph `database` is no longer drawn by the file surfaces. Whether it still ships
      is a glyph-set question outside this change.
- [ ] `app-window.md` covers the tree rows, the draft, both tab orientations through
  `TabFileIcon`, and the Problems and Usages headers. `app-editor.md` covers the Find in Files
  header. `app-git-views.md` covers the Log row, whose status now lives on the letter only.
  `app-ios.md` covers what iOS draws now: the helper for files and `FolderSymbol_iOS` for
  directories. Remove the `FileIcon` entry from `core-editor.md`, and correct the `FileIcon`
  statements in `core-database-viewer.md` and the other docs.
- [ ] `CLAUDE.md`. It must stay under 60,000 characters (about 57,100 today); write tightly.
  - The core-theme index gains `FileTypeIcon.swift` and `FileTypeIconImage.swift` (app, macOS +
    iOS).
  - The core-editor index loses `FileIcon.swift`.
  - The Resources paragraph names two deliberately unbundled record directories, `DesignGlyphs/`
    and `FileIcons/`.
  - The theme invariant changes to three stated exceptions (the file-type icons added),
    sixty-eight gated files, fifty-three rules, and three exempt files.
  - `FileTypeIconAssetTests` is added to the repository-file suites list.
  - One Conventions sentence beside the design glyphs' bullet: the vendored file-icon set ships as
    original-intent SVG imagesets under `Assets.xcassets/FileIcons/`, named only by
    `FileTypeIcon`, drawn only through `FileTypeIconImage`, licensed and pinned like the glyphs,
    with its record in `Resources/FileIcons/VENDORED.md`.
- [ ] `README.md` and `docs/FEATURES.md` each get one line where the project tree is described:
  per-kind, full-colour file icons.
- [ ] Run `swift test`. `LintConfigurationTests` holds the `CLAUDE.md` bound, and the gating
  suite's cross-file counts must agree.

### Task 6: Verify acceptance criteria

- [ ] Run `swift test`: all green, including `FileTypeIconTests`, `FileTypeIconAssetTests`,
  `LicenseCoverageTests` and `ChromeThemeSourceGatingTests`.
- [ ] Run `xcodegen generate`, then the app-layer bundle under Xcode 26.3 with the pinned
  DerivedData path. Report the result naming Xcode 26.3.
- [ ] Run the macOS Release build and the iOS device build, both unsigned, under Xcode 26.3.
- [ ] Run `swiftlint --strict` from the repository root: clean.
- [ ] Confirm `wc -c CLAUDE.md` is under 60,000.
- [ ] Grep the tree, excluding `.git` and `docs/plans/`, case-insensitively for the editor brand
  name that prefixes the repository slug (read it from the Source row of
  `Resources/FileIcons/VENDORED.md`; this plan does not spell it). It may occur only in
  `Resources/FileIcons/VENDORED.md` and `Resources/Licenses/file-icons.txt`. Also grep every file
  this branch changed for other editor brand names.
- [ ] Grep the tree, excluding `.git` and `docs/plans/`, for the set's display name: it occurs
  only in `Resources/Licenses/licenses.json`, `Resources/Licenses/file-icons.txt` and
  `Resources/FileIcons/VENDORED.md`.
- [ ] Confirm `grep -rnw 'FileIcon\|FileIconColor' Sources Tests docs/architecture CLAUDE.md` is
  empty.

## Post-Completion

Manual verification:

- **Debug build on macOS**, launched by its path typed into the Open panel, never a Release build
  under the user defaults. Open a project with TS, TSX, JSON, Markdown, CSS, YAML, `Dockerfile`,
  `docker-compose.yml`, `.env`, `.gitignore`, `.editorconfig`, `package.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `Cargo.toml`, `app.test.ts` and an unknown extension. Check the tree, both tab
  orientations, a New File draft as the name is typed, Find in Files, Problems, Usages and the
  commit Log's file list:
  - each kind is distinguishable at a glance
  - the unknown extension shows the plain document icon
  - folders are unchanged
  - light and dark appearance show the same icons, and nothing is grey
  - on the light ground, look specifically at `editorconfig` (it draws no coloured ink at all,
    only #eee / #fafafa, so it is nearly invisible), `pnpm` (#e0e0e0 half) and `toml` (#cfd8dc
    letter); their weakness is already recorded as a follow-up in `core-theme.md`, and the check
    confirms how weak
- **iOS**: on a simulator or device, the tree, Local Changes and Log rows draw the same icons, and
  folders keep the accent `folder` symbol.

CI:

- Budget one CI-only iteration on the branch. The `macos-26` runner can fail a hosted-render suite
  that passes on local macOS 27.
- On a `test-macos` failure, read the runner OS line and the uploaded `PisakaAppTests.xcresult`
  before changing anything. Fix the cause; never loosen a tolerance.
