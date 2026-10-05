# The design's glyphs draw whole: re-vendor the PDFs at their native 24-unit box, and pin that the drawing fits

## Overview

Thirteen of the twenty-four shipped design glyphs are visibly clipped, on the right or at the
bottom. The cause is in the vendored PDFs, not in the drawing code. The previous export wrote
each glyph's media box as the drawn extent rounded down to an integer, while the geometry kept
its fractional size (`folder` is a 12×12 box holding geometry 12.84 wide), and the renderer
clips to the box. A corrected export puts every glyph in a 24×24 box at the icon set's native
coordinates. This change does five things:

- ships that export;
- removes `DesignGlyph.nativeSize`, which no longer means anything, so every drawing site
  states its own size;
- makes the record, the pins and the licence manifest agree with the new bytes;
- adds a Core-gate check that decodes every shipped PDF and fails if any path coordinate lies
  outside its 24×24 box;
- fixes the Problems toggle as a side effect. Its old `file-warning.pdf` was the design tool's
  "icon not found" placeholder (a question mark in a circle); the new file is the real
  document-with-exclamation-mark drawing.

## Context

- Corrected export (outside the repository): `~/Documents/pisaka-design-export/icons/`. It
  holds 32 PDFs, a `LICENSE.txt` byte-identical to `Resources/Licenses/design-glyphs.txt`, and
  a `MANIFEST.txt` whose sha256 is
  `85aea20cfbbe52b9c6c445bb3964d0a06db9db7543e1f901ea7350b0999e3a26`. All 32 PDFs were checked
  during planning against their manifest prefixes and match.
- Previous export, moved aside and kept only for the one-time negative check:
  `~/Documents/pisaka-design-export-2026-10-02/icons/`. Never vendor anything from it.
- Files involved:
  - `Sources/PisakaCore/DesignGlyph.swift`
  - `Sources/Pisaka/DesignGlyphImage.swift`
  - `Sources/Pisaka/ProjectSearchView.swift` (`groupHeader(for:)`, `SearchLayout`)
  - `Sources/Pisaka/Assets.xcassets/Glyphs/<name>.imageset/<name>.pdf` (24 files)
  - `Resources/DesignGlyphs/VENDORED.md`
  - `Resources/Licenses/licenses.json` (the `design-glyphs` entry)
  - `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`
  - `Tests/PisakaCoreTests/DesignGlyphTests.swift`
  - `Tests/PisakaCoreTests/Support/DesignGlyphRecord.swift` (doc comment only)
  - `Tests/PisakaAppTests/DesignGlyphImageTests.swift`
  - `Tests/PisakaAppTests/ProjectSearchLayoutTests.swift` (comment only)
  - `docs/architecture/core-theme.md`
  - `docs/architecture/core-services.md` (the `BottomPanel.glyph` paragraph that lists the six
    toggle glyphs)
  - `docs/architecture/app-editor.md` (the Find in Files group-header description)
- Facts about the new PDFs, measured during planning. Where these differ from the ticket's
  notes, the measurement wins:
  - Each shipped PDF has exactly one `/MediaBox [0 0 24 24]` and exactly one content stream.
  - Each stream is `/Filter /FlateDecode` with zlib framing: a two-byte header starting
    `0x78`, raw deflate data, then a big-endian Adler-32 trailer.
  - Each decoded stream opens with the flip `1 0 0 -1 0 24 cm` and has **no** translation
    `cm`. The previous export had a second `1 0 0 1 tx ty cm`, so the check must apply
    translations when present and must not require one.
  - Operators used across all 24 new and old files: `q Q cm gs RG rg re m l c y h f`, plus
    name operands like `/G3` and `/G4`.
  - `re` draws the export frame's invisible ground, `0 0 24 24 re` under an alpha-0 graphics
    state. `y` is a curve operator.
  - Strokes are already outlined into fills: there is no `S`, so path coordinates are the
    ink's own outline.
  - New export, coordinate bounds after the flip: x and y all within roughly 0.98…23.09.
  - Previous export: fifteen of the twenty-four shipped PDFs have geometry outside their box.
    They are `file-warning`, `git-compare`, `list-checks`, `search`, `git-pull-request-arrow`,
    `folder`, `folder-open`, `file-code`, `file-text`, `database`, `user-round`, `refresh-cw`,
    `case-sensitive`, `whole-word` and `regex`. This set includes the thirteen the ticket
    names as visibly clipped.
  - Find in Files group header, decided at planning: the glyph is drawn at 14 in a 14 slot.
    Padding stays 16 and the gap stays 6, so the path now starts at 36 and no longer lines up
    with the 34-point match indent. Comments and docs that claim it lines up must stop
    claiming it.
- Related patterns: `DesignGlyphAssetTests` reads repository files through `#filePath` with
  Foundation and Core's own `SHA256` only. `DesignGlyphRecord` is the shared reader of the
  record's glyph table, used by both that suite and `LicenseCoverageTests`. Repository-reading
  suites follow the conventions in CLAUDE.md (set equality over counts; a rule must not be
  weaker than its comment).
- Dependencies: none new. Inflating uses Foundation's `NSData.decompressed(using: .zlib)`,
  which takes raw deflate, so the two-byte header and the four-byte trailer are stripped first.

## Development Approach

- **Testing approach**: Regular. The tasks are ordered so `swift test` is green at the end of
  each one:
  1. `nativeSize` goes first, while the old bytes are still in place.
  2. The bytes and the record change together.
  3. The geometry check lands last, against bytes that already satisfy it.
- Complete each task fully before moving to the next.
- No PDF is edited by hand. The record, the test pins and the licence manifest entry change
  together, by the record's own update procedure.
- No brand or product names in code, comments, docs or commits. Say "the design's glyphs",
  "the icon set" and "the design tool". The icon set's name appears only where
  `licenses.json` and the licence text already carry it.
- Every `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`,
  never a folder inside the repository.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Remove `nativeSize`; every site states its glyph's size

The "drawn size the export states" is going away: under the new export every glyph sits in the
same 24-unit box, and the design draws one glyph at several sizes. So size stops being a
property of the glyph and becomes the surface's statement, everywhere.

Exactly one site relies on the default today: the Find in Files result-group header. The
design draws that glyph at 14. Every other site already states the size the design gives its
surface, and keeps it.

**Files:**
- Modify: `Sources/PisakaCore/DesignGlyph.swift`
- Modify: `Sources/Pisaka/DesignGlyphImage.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Tests/PisakaCoreTests/DesignGlyphTests.swift`
- Modify: `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/DesignGlyphRecord.swift`
- Modify: `Tests/PisakaAppTests/DesignGlyphImageTests.swift`
- Modify: `Tests/PisakaAppTests/ProjectSearchLayoutTests.swift`

- [x] `DesignGlyph.nativeSize` is deleted. The enum's doc comment no longer says the suite pins
  a native size.
- [x] `DesignGlyphImage.init` takes `size: Double` with no default, and the
  `size ?? glyph.nativeSize` fallback is gone. The `size` property's doc comment says the size
  is always the drawing surface's, in points at interface scale 1.0.
- [x] The Find in Files group header passes `size: 14`. `SearchLayout.headerGlyphSlot` becomes
  14, and its doc comment says the design draws the file glyph there at 14. `headerPadding`
  stays 16 and the HStack gap stays 6. `headerPadding`'s comment stops claiming the path
  starts at the match indent: it now says the path starts at 36, two points past the 34-point
  match indent.
- [x] No other `DesignGlyphImage(` call site changes its size. Re-read every call site once to
  confirm each one already passes `size:` explicitly.
- [x] `DesignGlyphTests.testNativeSizesAreTheExportedOnes` is deleted.
- [x] In `DesignGlyphAssetTests`, the `nativeSize` assertion is removed from the record
  cross-check, and the test is renamed for what it still checks: the record's glyph set equals
  the cases, and the record's prefixes equal `pinnedPrefixes`. The suite's doc-comment
  inventory drops the `nativeSize` bullet. `DesignGlyphRecord`'s doc comment stops naming
  `nativeSize`.
- [x] `DesignGlyphImageTests.testTheSwiftUIHalfOccupiesItsSlotAtTheInterfaceScale` passes an
  explicit size (for example 12), since the initializer now requires one.
- [x] `ProjectSearchLayoutTests`' comment saying a header path "starts at the same 34" is
  corrected to 36. Its assertions need no change: the glyph is still inside its slot at the
  content padding.
- [x] Run `swift test`; it must pass. Run `swiftlint --strict`; it must be clean. Run the
  app-layer bundle; it must pass:
  ```
  xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
  ```

### Task 2: Vendor the corrected export; the record, the pins and the licence entry follow the bytes

Replace the twenty-four shipped PDFs byte for byte from
`~/Documents/pisaka-design-export/icons/`, following `Resources/DesignGlyphs/VENDORED.md`'s own
"Updating by hand" procedure. Then make the record say what the asset now is and why.

**Files:**
- Modify: `Sources/Pisaka/Assets.xcassets/Glyphs/<name>.imageset/<name>.pdf` (all 24)
- Modify: `Resources/DesignGlyphs/VENDORED.md`
- Modify: `Resources/Licenses/licenses.json`
- Modify: `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`

- [ ] Each shipped PDF is copied over its imageset's PDF from the new export, after checking its
  `shasum -a 256` prefix against the new `MANIFEST.txt`. No `Contents.json` changes: each keeps
  its template intent, its preserved vector representation and its one filename. The eight
  unshipped icons stay out.
- [ ] `Resources/Licenses/design-glyphs.txt` is unchanged; confirm with `cmp` against the
  export's `LICENSE.txt`. The `design-glyphs` entry's `revision` in `licenses.json` becomes
  `85aea20cfbbe52b9c6c445bb3964d0a06db9db7543e1f901ea7350b0999e3a26`. Its `version` stays
  `null`.
- [ ] `VENDORED.md` header table: the Revision row holds the new digest, and the Source row says
  the export is dated 2026-10-05.
- [ ] `VENDORED.md` glyph table: every Size cell is `24`, the MIT-notice column is unchanged,
  and the Prefix column is transcribed from the new manifest:

  | Glyph | Prefix |
  |---|---|
  | `package` | `4e19fc2e5b0fbd39` |
  | `git-branch` | `1738e285c5e53723` |
  | `chevron-down` | `8b7df9eda0367c90` |
  | `chevron-right` | `02cd1542fb22ad90` |
  | `git-pull-request` | `37a0975caf14903b` |
  | `check` | `496d1749c8eaf0e0` |
  | `terminal` | `992c48725d6efb5d` |
  | `file-warning` | `18a5d9157e3c9fa2` |
  | `git-compare` | `2dbb6bb38742483c` |
  | `list-checks` | `3456e4aed7e36adb` |
  | `search` | `fca0d98489622650` |
  | `git-pull-request-arrow` | `d9250c717269a4c4` |
  | `folder` | `8751dad31dc2126f` |
  | `folder-open` | `b732124cc847a62f` |
  | `file-code` | `4f1e3ceacbac6a29` |
  | `file-text` | `d759e0792fcfd2ba` |
  | `database` | `94e48ce90170f619` |
  | `x` | `9ffad35485eeffa0` |
  | `user-round` | `5eac37ea03006449` |
  | `undo-2` | `3086adea25b52419` |
  | `refresh-cw` | `b1dba6c8271f47ff` |
  | `case-sensitive` | `7e7229ec9d8a3b64` |
  | `whole-word` | `c8f3633e9f9b8492` |
  | `regex` | `0f392dda96cecce3` |

- [ ] `VENDORED.md` prose, in its own words. It states:
  - Why the box is 24 for every glyph: it is the icon set's native viewBox (two units of
    padding each side, stroke width 2). A vector is drawn at whatever size each surface states,
    so the design's 10-, 12-, 13-, 14- and 16-point instances are all the same asset, and the
    Size column is the box, not a drawn size. The paragraph that equated the size with
    `DesignGlyph.nativeSize` is replaced.
  - What the previous export's defect was: it exported the bare icon node, so each media box
    was the drawn extent rounded down to an integer while the geometry kept its fractional
    size. The renderer clips to the box, so right and bottom edges were cut off; for example,
    `folder` was a 12×12 box holding geometry 12.84 wide.
  - The one drawing that changed on purpose: the previous `file-warning.pdf` was the design
    tool's "icon not found" placeholder, because the icon set renamed that glyph while the
    design file kept the old name. The new file is the real drawing; the asset name, the enum
    case and every use are unchanged.
- [ ] `VENDORED.md` "Updating by hand" procedure:
  - Gains a first rule: **export a 24×24 frame wrapping each icon, never the bare icon node**,
    with the reason (the bare node reproduces the rounded-down, clipping box).
  - Names `DesignGlyphAssetTests`' geometry check (Task 3) as the step that proves an export
    before it is vendored. The way to run it against a candidate export before copying, as a
    throwaway local edit, is stated in Task 3's doc comment.
  - Step 3's "a changed size also changes `DesignGlyph.nativeSize`" is replaced by "the size
    column is 24 for every glyph".
- [ ] In `DesignGlyphAssetTests`, `pinnedPrefixes` is replaced with the table above, and the
  suite's doc-comment inventory is updated to match. The record cross-check from Task 1
  additionally asserts that every record row's size is exactly 24, with a failure message
  naming the glyph. Set equality with the enum and the record-versus-pins prefix cross-check
  stay as they are.
- [ ] Run `swift test`; it must pass, including `DesignGlyphAssetTests` and
  `LicenseCoverageTests`. Run `swiftlint --strict`; it must be clean. Run the app-layer bundle
  (same command as Task 1); it must pass. Where a bitmap suite pinned a glyph's drawn extent
  rather than its slot, the pinned number moves to the new drawing; slot and column pins do
  not move.

### Task 3: The gate sees the defect class: every path coordinate lies inside the 24×24 box

Add a check to `DesignGlyphAssetTests` that would have failed on 2026-10-02. It decodes each
shipped PDF's content stream and bounds the drawn geometry, not just the box. A check that
reads only the media box or the manifest sizes does not meet this requirement. It uses
Foundation only and reads the PDFs through `#filePath` like the suite's other checks.

The reader is a private nested helper inside the suite (not a new Support file). It works on
`Data`, so the same code serves both the shipped files and in-memory fixtures.

**Files:**
- Modify: `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`

- [ ] **Media box.** Exactly one `/MediaBox` per file, equal to `[0 0 24 24]`.
- [ ] **Streams.** Every content stream is located through its dictionary's `/Length`; the
  slice is taken after the `stream` keyword and its end-of-line. Each must be `/FlateDecode`.
  - Its first two bytes must be a valid zlib header: CMF `0x78`, with
    `(CMF·256 + FLG) % 31 == 0`.
  - The bytes between the header and the four-byte trailer are inflated with
    `NSData.decompressed(using: .zlib)`.
  - The inflated bytes' Adler-32 must equal the big-endian trailer, which proves the decode.
  - A file with no content stream fails.
- [ ] **Interpreter.** The decoded text is tokenized on PDF whitespace. Numbers go on an
  operand stack; tokens starting with `/` are name operands. Operators are interpreted against
  a full affine CTM, with `q` pushing it and `Q` popping it, so the export's flip and any
  translation the previous export used are applied without being special-cased. An unbalanced
  `Q` fails. Each operator is handled as follows:
  - `cm` concatenates its six operands onto the CTM.
  - `m` and `l` bound one point each.
  - `c` bounds three points.
  - `v` and `y` bound two points each.
  - `re` bounds its four corners.
  - `h`, `f`, `gs`, `rg` and `RG` are accepted and draw nothing new.
  - **Any other operator fails** with a message naming it. That includes `S`, where stroked
    geometry would need half a line width, and any text or image operator, which could draw
    outside without a path coordinate. A future export that changes shape fails loudly instead
    of passing unexamined.
- [ ] **Bounding.** Each bounded point is transformed by the current CTM and must satisfy
  0 ≤ x ≤ 24 and 0 ≤ y ≤ 24, with no tolerance. Each shipped file must bound at least one
  point, so the check cannot pass vacuously. The failure message names the glyph, the
  coordinate and the box, and points at `VENDORED.md`'s "export a 24×24 frame" rule.
- [ ] **Fixture tests.** Fixtures are built in memory with Foundation's
  `NSData.compressed(using: .zlib)`, wrapped in a `0x78 0x9C` header and an Adler-32 trailer,
  inside a minimal PDF-shaped `Data` carrying `/MediaBox`, `/Filter /FlateDecode`, `/Length`
  and `stream … endstream`. Cases:
  - an in-box drawing passes;
  - a point at 24.5 fails;
  - a translation inside `q … Q` that pushes a point out fails, while a point after the `Q` is
    judged untranslated;
  - a `[0 0 12 12]` media box fails;
  - an unknown operator fails.

  The reader returns its findings (box, out-of-box points, unknown operators), and the fixture
  tests assert on those findings rather than on `XCTFail` side effects.
- [ ] **Doc comment.** The suite's doc-comment inventory gains the new bullet. It states what
  the check bounds and why, and that the exports outline strokes to fills. It also says how to
  run the check against a candidate export folder before vendoring, as a throwaway local edit
  pointing the reader at that folder.
- [ ] **One-time hand check, not committed.** Point the reader at
  `~/Documents/pisaka-design-export-2026-10-02/icons/<name>.pdf` for the twenty-four shipped
  names, with a temporary test method or a temporary path edit. Confirm it reports geometry out
  of the box for all fifteen previous-export files listed in Context, including the thirteen
  the ticket names. Then revert the temporary edit; nothing from that folder is copied or
  committed. Record the result in the task's progress note.
- [ ] Run `swift test`; it must pass, with the geometry check green on all twenty-four shipped
  PDFs. Run `swiftlint --strict`; it must be clean.

### Task 4: Documentation

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/core-services.md`
- Modify: `docs/architecture/app-editor.md`

- [ ] `core-theme.md`, `DesignGlyph.swift` entry:
  - The enum is a name table only.
  - Every asset is a 24-unit box at the icon set's native coordinates, and its drawn size is
    always the surface's.
  - `nativeSize` is gone, and why.
  - `DesignGlyphTests` pins names only.
  - What `DesignGlyphAssetTests` pins: set equality with the imagesets; each PDF's manifest
    prefix; template intent and preserved vector data; the record's size column at 24 for
    every row; every shipped PDF's media box at 24×24 with every path coordinate inside it;
    asset symbols off.
- [ ] `core-theme.md`, "The design's glyphs — one helper, one name table" section: the name
  table carries no size. `DesignGlyphImage`'s `size:` is required and no longer defaults to
  `nativeSize`. The section says in one sentence what the previous export's clipping defect
  was and that the geometry check now pins it.
- [ ] `core-services.md`, the `BottomPanel.glyph` paragraph listing the six toggle glyphs, notes
  that the Problems toggle now draws the real `file-warning` drawing; it previously drew the
  design tool's placeholder.
- [ ] `app-editor.md`, the Find in Files group-header description: the file glyph is at 14 in a
  14 slot, gap 6, so the path starts at 36. It no longer claims the path lines up with the
  34-point match indent.
- [ ] `CLAUDE.md`'s glyph bullet is re-read. It still holds (bytes pinned to the export's
  manifest by `DesignGlyphAssetTests`; licence and provenance unchanged), so it is left
  untouched.
- [ ] Run `swift test`; it must pass, because `LintConfigurationTests` and the doc-reading
  suites read these files. Run `swiftlint --strict`; it must be clean.

### Task 5: Verify acceptance criteria

- [ ] Run `swift test`. It must be green, including `DesignGlyphAssetTests`,
  `DesignGlyphTests`, `LicenseCoverageTests`, `ChromeThemeSourceGatingTests` and
  `LintConfigurationTests`.
- [ ] Run the app-layer bundle; it must be green. Its glyph-measuring suites are
  `BottomBarLayoutTests`, `TreeRowGlyphLayoutTests`, `TabColumnLayoutTests`,
  `DockTabRowLayoutTests`, `ChromePopoverLayoutTests`, `LocalChangesLayoutTests`,
  `ProjectSearchLayoutTests` and `DesignGlyphImageTests`.
  ```
  xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
  ```
- [ ] Run `swiftlint --strict` from the repository root; it must be clean.
- [ ] Run `grep -rn nativeSize Sources Tests docs Resources CLAUDE.md`; it must return nothing.
- [ ] Confirm that no brand or product name was introduced in any changed file.

## Post-Completion

Manual verification, in a Debug build only, never a Release build under the user's defaults:

- At interface scale 1.0 and 2.0, check every glyph in the bottom bar, the project tree, the
  tab list, the Local Changes toolbar, the search-bar toggles and the two popovers. All four
  edges must be intact:
  - `folder` and `folder-open` have no flattened right side;
  - `file-code` and `file-text` have their bottom stroke;
  - the lower circles of `git-pull-request-arrow` and `git-compare` are closed;
  - the magnifier's handle is whole.
- The Problems toggle shows a document with an exclamation mark.
- A bar widget's `package`, `git-branch` and `git-pull-request` at 12 read as the design's
  12-point instance, with geometry about 10 wide inside the 12 slot.
- The Find in Files group header shows the file glyph at 14, with the path starting just past
  the match lines' indent.
