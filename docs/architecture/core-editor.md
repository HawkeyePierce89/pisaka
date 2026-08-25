# PisakaCore — editor engines

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `ColumnSelectionEngine.swift` — pure, testable middle-drag column-selection computation. Visual columns mean the horizontal edges must be resolved by the glyph layout per line, which only the view can do. The engine owns the two decisions that are not layout: `bounds(anchor:head:)` normalizes two drag corners (any of the four corner orders, in the flipped text-view coordinate space) into one rectangle (left/right, top/bottom); `ranges(for:in:)` turns the layout's per-line answers (`ColumnSelectionLine`) into the ordered `selectedRanges`. It clamps each pair into that line's own character range, trims the line terminator (`LineStartIndex.isLineSeparator`, CRLF as one) so it is never swallowed, orders the pair, sorts and de-duplicates, and lets a zero-width rectangle fall out naturally as one zero-length range per line (the multi-caret case). The view passes each line's own character range (taken from the line fragment's glyph range) rather than letting the engine infer the line from an offset: a point right of a short line can resolve to an offset past that line's content, and inferring the line from that offset would attach the range to the *next* line and collide. An empty document line yields a single insertion caret range, while an empty input line list yields no ranges. AppKit requires ordered, non-overlapping ranges, which this engine guarantees.
  - `DuplicateEngine.swift` — pure, testable duplicate-line/selection computation
    for the editor's Cmd+D (Foundation only, no AppKit/Neon — the
    `IndentEngine`/`AutoPairEngine` precedent: the engine operates on an
    `NSString` + UTF-16 offsets and returns a value type describing "what to
    insert and where", while the view layer applies it as one programmatic edit).
    `public struct DuplicateEdit: Equatable` carries `insertionLocation` (a UTF-16
    offset into the *current* document, always a zero-length replacement — a
    duplication never deletes anything), the `text` to splice in, and
    `selectedRange`, the resulting selection expressed in the coordinates of the
    document *after* the insertion. `public enum DuplicateEngine { static func
    duplicate(text: NSString, selectedRange: NSRange) -> DuplicateEdit }`
    implements JetBrains' Cmd+D semantics. **No selection**: the caret's logical
    line is duplicated below it and the caret moves into the copy at the same
    column. **A selection**: the selected span is duplicated *character-wise* — a
    multi-line selection included, deliberately not rounded out to whole lines —
    inserted right after the selection at `NSMaxRange(sel)` and selected itself,
    so repeated presses grow the text (`[ab]` → `ab[ab]` → `abab[ab]`). Line
    boundaries come from `NSString.getLineStart(_:end:contentsEnd:for:)`, which
    follows the same Unicode separator semantics as `LineStartIndex` (LF, CR, the
    CRLF pair as *one* separator, NEL, U+2028, U+2029) and reports the terminator
    length as `end - contentsEnd` — 2 for CRLF, so a terminated line copies its
    own terminator verbatim and the pair is never split. With a terminator present
    the whole line *including* it is inserted at `end` and the new caret is
    `end + (caret - lineStart)`: the column is a UTF-16 offset from the line start
    and the copy has the same length, so overrunning it is impossible — the
    off-by-one-prone boundary, pinned by its own test, is a caret sitting exactly
    at `contentsEnd` of a CRLF line, which lands right before the *copy's* own
    `\r\n`, neither inside the pair nor past it (`"ab\r\ncd\r\n"` with the caret at
    2 → insert `"ab\r\n"` at 4, caret 6). The column is *clamped* to `contentsEnd`,
    so its neighbor state — a caret sitting **inside** the pair, between `\r` and
    `\n`, unreachable through TextKit (which lays CRLF out as one break) but
    expressible programmatically — lands at the copy's line end rather than inside
    the copy's own pair; both are pinned by tests. A line with **no** terminator (the last
    line, or an empty buffer) gets a plain `"\n"` prepended to the copy instead — a
    deliberate simplification, so a CR/CRLF-delimited file's *trailing* insertion
    uses `"\n"` while every terminated line still copies its own separator; an
    empty buffer therefore gains an empty line, as in JetBrains. The selection is
    clamped to the buffer bounds first (an out-of-range or `NSNotFound` range can
    never trap) but is otherwise used as given: the engine never widens a range to
    a composed character sequence, since that would change selection semantics
    (and the text view never hands over a range splitting a surrogate pair).
    Unit-tested in `DuplicateEngineTests`. **Out of scope** (follow-ups): an iOS
    variant via `UIKeyCommand` for an external keyboard over this same engine, and
    an Edit → Duplicate Line menu item.
  - `CommentStyle.swift` — pure, testable mapping from a language to its comment
    syntax (Foundation only). `public enum CommentStyle: Equatable { case
    line(String); case block(open: String, close: String) }`, plus
    `CommentStyle.style(for: SyntaxLanguage) -> CommentStyle?`. It defines
    `public static let languagesWithoutComments: Set<SyntaxLanguage> = [.json,
    .markdown]`, keeping an explicit set for languages with no comment syntax to
    toggle (mirroring `LanguageKeywords`). The tests assert that the set of
    styled languages and the set of no-comment languages are disjoint and
    exhaustively cover `SyntaxLanguage.allCases`, so adding a language requires
    deliberately resolving its comment style. Unit-tested in
    `CommentStyleTests`.
  - `ToggleCommentEngine.swift` — pure, testable toggle-comment computation for
    the editor's Cmd+/ (Foundation only). `public struct CommentToggleEdit: Equatable`
    carries `replacementRange`, `text`, and `selectedRange` (the resulting
    selection in post-edit coordinates). `public enum ToggleCommentEngine { static func
    toggle(text: NSString, selectedRange: NSRange, language: SyntaxLanguage?) ->
    CommentToggleEdit? }`. Returning `nil` is the silent no-op: it means no edit
    and no caret move (for no language, a no-comment language, or a wholly blank
    target). The engine clamps the selection to buffer bounds first, like
    `DuplicateEngine`. Touched lines are computed as the whole-line span from
    the first touched line's start to the last touched line's end (a selection
    ending exactly at a line start does not touch that line). Line separators are
    split via `getLineStart(_:end:contentsEnd:for:)` to preserve terminators
    identically to `DuplicateEngine`.
    A blank caret line is a complete no-op with the caret left where it is. This
    is the deliberate choice against the common alternative of inserting a marker
    on an empty line. Caret placement: if a following line exists, the caret
    lands at that line's start plus the original column (clamped); on the last
    line, it stays on its own line, shifted by the inserted/removed token delta.
    Selection placement becomes the touched lines' post-edit whole-line span
    (from the first touched line's start to the last's contents end).
    Line mode skips blank/whitespace-only lines in both directions. It inserts
    the token after leading indentation with one space after. When removing, it accepts both
    the token alone (`//x`) or with at most one immediately following space
    (`// x`), allowing leading whitespace before the token.
    Block mode normalizes the "first/last touched line" to the first and last
    **non-blank** touched line. Wrap inserts the opener with a trailing space before the first
    non-blank line's first non-whitespace character, and the closer with a leading space at the end
    of the last non-blank line's contents. Unwrap tolerates one space inside
    each delimiter and trailing whitespace after the closer. Delimiters already
    inside the target are left exactly as they are without rebalancing.
    Unit-tested in `ToggleCommentEngineTests`.
  - `TreeRefreshFilter.swift` — pure, Foundation-only decision for the macOS
    project-tree filesystem watcher: `public enum TreeRefreshFilter { static func
    shouldRefresh(changedPaths: [String], root: URL) -> Bool }` answers "is this
    batch of changed paths worth re-reading the tree for". The watcher itself
    (`ProjectWatcher`, FSEvents) is IO-only view-layer code; this off-by-one-prone
    path matching (trailing slashes, same-or-descendant vs. a raw `hasPrefix`) lives
    in Core so it is unit-tested — the `ScopedFileAccess`/`FileIcon`/`LineDiff`
    precedent — and it is **string comparison only, no disk access** (an FSEvents
    callback has no business touching the filesystem). A batch refreshes when at
    least one path is *not* ignored; an empty batch → `false`. Three ignore rules,
    each reusing the existing `ScopedFileAccess.path(_:isWithin:)` for
    same-or-descendant (it already normalizes a trailing slash): (1) *not*
    same-or-descendant of `root` — live, since FSEvents can deliver such paths around
    a stream move/recreate and they are not this project; (2) same-or-descendant of
    the *opened root's top-level* `root/.git` — live, and the rule that makes "a
    `git commit`/`git status` in the embedded terminal doesn't flicker the tree"
    work, because under dir-level events git's writes are reported as the
    directories `root/.git`, `root/.git/objects/xx`, `root/.git/refs/heads`; only the
    root's own `.git` is ignored, a nested `deps/foo/.git` is an ordinary part of the
    visible tree (and `root/.gitignore`/`root/.github` are *not* matched — hence
    `path(_:isWithin:)` rather than `hasPrefix`; the `.git` path itself is built with
    `appendingPathComponent` so a project root of `/` yields `/.git`, not `//.git`);
    (3) a last component of `.DS_Store`
    (via `NSString.lastPathComponent`, which normalizes FSEvents' trailing directory
    slash away) — **dormant** under the watcher's
    dir-level flags, since the `.DS_Store` file's own path is never delivered (the
    containing directory is reported instead), so a Finder write still passes the
    filter and causes one harmless bump (the listing excludes `.DS_Store`, so nothing
    visibly moves); the rule is kept only as defense-in-depth should the stream ever
    switch to `kFSEventStreamCreateFlagFileEvents`. The filter deliberately says
    nothing about *who* produced an event: self-generated writes are excluded at the
    stream level (`kFSEventStreamCreateFlagIgnoreSelf`), not here, so this stays a
    pure path decision. `root` must arrive **canonical** (symlink-resolved): the
    filter is disk-free by design and so cannot resolve it, while FSEvents reports
    realpath-spelled paths no matter how the watched path was spelled — a root
    spelled through a symlink (`~/dev -> /Volumes/Data/dev`) or a firmlink (`/tmp`)
    would fail rule (1) for *every* path and silently disable the whole feature, so
    `ProjectWatcher.start` canonicalizes before calling in. Unit-tested in
    `TreeRefreshFilterTests` (including that contract, both directions).
  - `FileIcon.swift` — pure, testable mapping from a `DirectoryEntry` to an
    icon: a `FileIcon` struct (`symbolName` + semantic `FileIconColor`) with
    `init(for: DirectoryEntry)`. Resolution order: directory → `folder`/`.accent`;
    special-cased file names (e.g. `Package.swift`, `LICENSE`, `.gitignore`,
    `Makefile`, `Dockerfile`); lowercased extension lookup (e.g. `sql` → `cylinder.split.1x2`/`.blue`); fallback →
    `doc`/`.gray`. `FileIconColor` is a semantic enum so the library stays free
    of any SwiftUI/AppKit dependency.
  - `SyntaxLanguage.swift` — pure, testable
    `String`/`CaseIterable`/`Equatable`/`Hashable`/`Sendable`
    enum of supported languages (swift, javascript, typescript, go, rust, json,
    markdown, python, html, css, yaml, dockerfile, dotenv, gitignore, sql) with
    `init?(fileExtension:)` and `init?(forFileName:)`, backed by a lowercased
    extension→language map, mirroring `FileIcon`'s extension-map pattern. The
    last three carry no extension at all (`Dockerfile`, `.env`, `.gitignore`), so
    `init?(forFileName:)` is no longer extension-only: it takes the argument's
    *last path component*, lowercases it, and runs **four phases in a fixed
    order — exact name → extension → prefix → dot-ignore shape**. (The
    `lastPathComponent` normalization is what keeps a caller that hands over a
    path rather than a bare name from getting a *partial* failure: only the
    extension phase reads the last component on its own — `NSString
    .pathExtension` — so without it `backend/app.ts` would resolve while
    `backend/.env` silently would not. Every live call site passes a
    `lastPathComponent` already, but two of them derive it from `ChangedFile
    .path`, a repo-relative *path*, one dropped call away.) (1) *exact name*
    covers `dockerfile` and `.env`;
    (2) *extension* is the ordinary path and the map gained `"dockerfile"` (so
    `web.dockerfile` resolves); (3) *prefix* covers the variant-suffixed forms
    whose trailing component is not a known extension (`dockerfile.` →
    `Dockerfile.dev`, `.env.` → `.env.local`), each prefix ending in the dot that
    separates the variant so `Dockerfileish` and `.environment` are not matched;
    (4) the *dot-ignore shape* is `hasPrefix(".") && hasSuffix("ignore")` — and
    nothing else: the leading dot is already what makes the shortest match the
    bare `.ignore` rather than `ignore` itself (a six-character name ending in
    `ignore` *is* `ignore`, which has no leading dot), so no separate length
    guard is needed and none is written. That last rule is
    deliberately a **shape, not a name list**: `.gitignore`, `.dockerignore`,
    `.npmignore`, `.eslintignore`, `.prettierignore` and `.ignore` are one
    syntactic family (git's pattern grammar) whose membership grows, so an
    enumeration would go stale. The leading dot is load-bearing — this is a
    dot-file convention, not an extension — so `foo.ignore`, `gitignore` and
    `ignore` deliberately do *not* match. The **order** is what keeps the looser
    later phases from shadowing the stricter earlier ones, and is pinned by tests:
    `.env.json` reaches the extension phase and resolves to `.json` rather than
    being claimed by the `.env.` prefix rule, and `.eslintignore.md` resolves to
    `.markdown` rather than to `.gitignore`. `testEveryCaseIsReachableByFileName`
    covers every `allCases` through a file *name* (not an extension), so a future
    case added with no resolution rule fails the suite.
    **Adding a case has three obligations beyond the map**: a grammar in
    `project.yml`/`SyntaxLanguageConfiguration` for highlighting; a
    `Resources/Queries/<raw value>/symbols.scm` for the symbol index — or an
    explicit listing in `SymbolIndexModel.unindexableLanguages` with the reason
    (`.gitignore` sits there: it declares nothing a jump could land on); and a
    keyword list in `LanguageKeywords.keywords(for:)` — or an entry in
    `LanguageKeywords.languagesWithoutKeywords`, again with the reason (the data
    formats and Markdown sit there: they have no reserved words a completion
    could offer). `SymbolQueryTests` and `LanguageKeywordsTests` each compare
    their side against `allCases` by *set equality*, so `swift test` fails until
    each pair is resolved — the point in both cases being that a language can
    never silently index, or complete, to nothing. The
    `Hashable`/`Sendable` conformances are load-bearing for that layer rather
    than decorative: `SymbolQueryCatalog`'s compiled-query cache keys on this
    enum, and it crosses the `@Sendable` extractor seam
    (`docs/architecture/core-intelligence.md`).
  - `MinimapGeometry.swift` — pure, testable scroll/viewport math for the
    VS Code-style *proportional* minimap (CoreGraphics/Foundation only). A
    `public struct MinimapGeometry: Equatable` built from `documentHeight`/
    `viewportHeight`/`minimapHeight`/`contentHeight` (the owner computes
    `contentHeight = lineCount * minimapLineHeight`). Each minimap line has a
    *fixed* height, so unlike a stretch-to-fit minimap the content height may
    exceed the panel: it exposes `documentToMinimap` (`contentHeight /
    documentHeight`, a constant ratio independent of file length, 0 when a height
    is 0), `maxScrollOffset` (`max(0, documentHeight - viewportHeight)`),
    `minimapScrollTop(forScrollOffset:)` (how far the content has *slid* upward —
    0 unless `contentHeight > minimapHeight` and `maxScrollOffset > 0`, else
    `fraction * (contentHeight - minimapHeight)`), `viewportRect(forScrollOffset:)
    -> (y, height)` (panel-space, with the slide already applied:
    `y = clamped*r - minimapScrollTop`, `height = viewportHeight*r`), and
    `scrollOffset(forMinimapCenterY:)` (solves directly for the document offset
    whose viewport rectangle is centered under the cursor for click/drag — a
    single click lands the rectangle under the cursor in one step; a degenerate
    panel-filling rectangle falls back to a proportional map), and
    `scrollOffset(byMinimapDelta:from:)` (the mouse-wheel path: divides a
    minimap-panel-space delta by `documentToMinimap` to reach document points,
    adds it to the current offset, and clamps to `[0, maxScrollOffset]`; a zero
    ratio leaves the offset clamped, i.e. nowhere to scroll). All divisions guard
    against zero. Works in a
    single top-down convention (y grows down, offset 0 = top of doc); the view
    layer converts AppKit's flipped clip-view coordinates at the boundary.
  - `MinimapModel.swift` — pure, testable model + grouping for the minimap
    overview (Foundation only). `MinimapTokenRun` (`column`/`length` in UTF-16 +
    a `SyntaxTokenKind`, color-free) and `MinimapModel` (per-line `runs`,
    `lineCount`, `.empty`). `MinimapModel.build(text:kinds:)` is the pure grouping
    step: given the text and a per-UTF-16-unit `[SyntaxTokenKind]` (filled by the
    view layer's tree-sitter parse), it splits each line into non-whitespace runs
    of a single kind. Empty text ⇒ one empty line (`[[]]`); a `kinds` array
    shorter than the text treats missing positions as `.plain` rather than
    trapping. Line splitting goes through `LineStartIndex` so the minimap counts
    document lines with the *same* separator semantics as the gutter and TextKit.
    The heavy parse stays in `Pisaka`; this dependency-free grouping
    lives in Core so its off-by-one-prone line/column math is unit-tested.
  - `LineStartIndex.swift` — pure, testable line-start indexing shared by the
    minimap (`MinimapModel`) and the line-number gutter (`LineNumberRulerView`),
    so both count document lines with the same Unicode line-break semantics as
    `NSString`/TextKit (LF, CR, the CRLF pair, NEL, U+2028, U+2029 — *not* LF
    alone, which would diverge from the editor for CR/LS/PS-delimited files and
    skew the minimap's wheel-scroll scale and row alignment). `offsets(in:)`
    returns every line's UTF-16 start (plus a trailing entry at `length` for a
    final empty line); `updated(previous:editedRange:changeInLength:newText:)`
    rebuilds the cache *incrementally* from one edit — keeping the unchanged lines
    and shifting the rest. A structure-preserving edit (no line break added or
    removed — the common keystroke) takes a fast path that shifts the cached suffix
    without scanning any line, so typing into even a multi-megabyte single-line
    (minified) file stays cheap; only an edit that adds or removes a line break
    rescans the affected line span. (The per-edit cost is otherwise the inherent
    flat-array suffix shift, not a whole-buffer scan.) On the rescanning path it
    backs the anchor up one line when the edit starts exactly on a line start
    (CRLF, the one two-unit break, can dissolve that start across the boundary),
    and it falls back to a full `offsets(in:)` rebuild for anything it can't apply
    incrementally, so the cache can never drift. Foundation-only (`NSString`), so it stays in Core and is
    fuzz-tested against a full rebuild.
    It also owns the separator set as a **predicate**: `isLineSeparator(_:)` is the
    one answer to "is this character a line break" (LF, CR — the CRLF pair is two of
    them — NEL, U+2028, U+2029), and `IndentEngine`/`AutoPairEngine` defer to it
    rather than carrying copies, so nothing in the editor can split lines
    differently. Distinct from the private `couldStartLine` used by the incremental
    fast path, which is deliberately *over*-inclusive (VT and FF too): there a false
    positive only forfeits a shortcut, while a caller asking what a character **is**
    would get a wrong answer. The one view-layer caller is `HoverController`, which
    needs "the pointer is over a real character" to mean what TextKit's layout means
    (`app-editor.md`).
  - `SyntaxTokenKind.swift` — semantic, color-free token classification
    (`Equatable`: keyword, string, comment, number, type, function, variable,
    constant, `operator`, punctuation, property, parameter, label, plain). Its
    `init(captureName:)` splits a dotted tree-sitter capture name and matches the
    longest known prefix (`keyword.control` → `.keyword`), falling back to
    `.plain`. Color stays out of Core (semantic only, like `FileIconColor`).
    The map carries **five entries that are not a prefix family**: bare `escape` →
    `.string`. tree-sitter-go spells string escapes `@escape` rather than
    `@string.escape`, and without the entry every `\n` in a Go string resolved to
    `.plain` — a hole a highlight query cannot be blamed for and nothing in a
    screenshot makes obvious. The other four are for SQL: `"conditional"` → `.keyword`,
    `"storageclass"` → `.keyword`, `"field"` → `.property`, and `"type.qualifier"`
    → `.keyword` (overriding `.type` prefix so `NOWAIT`/`MAXVALUE` color as keywords).
    `attribute` remains deliberately mapped to `.property` since remapping it
    would incorrectly recolor HTML attributes and Rust `#[derive(…)]`.
    `spell` is mapped to `.plain` following the `.none` precedent to prevent it
    from interfering with its companion `@comment` capture.
  - `IndentEngine.swift` — pure, testable auto-indent computation for the editor
    (Foundation only, no AppKit/Neon), operating on an `NSString` + UTF-16 offsets
    and splitting lines with the same Unicode separators as the rest of the editor
    (via `LineStartIndex`), so it stays in Core and is unit-tested like
    `LineDiff`/`MinimapModel`. Two small public `Equatable` value types —
    `NewlineEdit` (`text` to splice in + `cursorOffset`, the UTF-16 distance from
    the insertion point to the caret, + `consumeAfter`, a count of UTF-16 units
    just past the selection the caller should also delete — the opener case uses it
    to swallow trailing whitespace between the opener and the line's tail so it
    doesn't stack on the inserted unit) and `IndentReplacement` (`range` of the
    current line's leading whitespace + `replacement` indentation) — and three
    static functions. `inferIndentUnit(text:)` returns a single tab if any line
    indents with a tab, else the smallest run of leading spaces observed, falling
    back to four spaces for an empty or unindented file. It is the **fallback
    half** of the unit, not the whole answer: since `.editorconfig` support
    landed, the views ask `IndentUnitRule.unit(config:inferred:)` for the `unit`
    they pass in — a config's `indent_style` decides tabs vs. spaces and its
    `indent_size`/`tab_width` the width, with each half it leaves out falling
    back to this inference, and no applicable config at all returning it
    unchanged (`core-editorconfig.md`). This engine still knows nothing about
    configuration: what that layer decides reaches it only as **parameters** —
    `unit`, and now `terminator` — so every rule below is stated once and read the
    same way with or without an `.editorconfig`.
    `newlineIndentation(text:location:unit:selectionLength:terminator:)` returns a
    `NewlineEdit` for Enter. `terminator` is the separator to splice, defaulting
    to LF so a caller that states nothing behaves byte for byte as before; both
    coordinators pass `end_of_line`'s terminator, because `end_of_line` is
    consumed in full — what `SaveTransform` normalizes an already-written
    terminator to is what a newly typed one is, so the two can never disagree and
    the save never has to come back and fix the line just typed. Its *real* UTF-16
    length is measured everywhere it is counted (CRLF is two units), in the plain
    branch and in the between-brackets split alike, so the caret lands in the same
    logical place under every flavor. The edit itself:
    base = the current line's leading whitespace (inherited verbatim, tabs and
    spaces alike); +one `unit` when the current line, ignoring trailing
    whitespace, ends with an opener (`{`/`(`/`[`) — in which case whitespace just
    past the caret/selection is reported via `consumeAfter` to be deleted rather
    than stacked onto the unit; and a between-brackets split
    (`{|}` → freshly indented middle line for the caret, closer pushed down to
    base) when `location` sits directly between an opener and its matching closer.
    Selection-replacing Enter measures both the adjacent closer and surviving
    whitespace from the *end* of the selection, so selected characters (which the
    replacement deletes) are never miscounted.
    `dedentOnClosing(text:location:closing:)` returns an `IndentReplacement?`
    that rewrites a whitespace-only line's leading whitespace to its opener line's
    indentation when a closing bracket is typed there, scanning backward tracking
    same-kind nesting depth; `nil` when the prefix isn't whitespace-only, `closing`
    isn't a known closer, or no matching opener is found. Bracket matching counts
    *raw* characters — no string/comment awareness — matching the deliberately
    simple, language-agnostic scope.
  - `AutoPairEngine.swift` — pure, testable auto-close decision logic for the
    editor (Foundation only, no AppKit/Neon), operating on an `NSString` + UTF-16
    offsets and splitting lines with the same Unicode separators as the rest of
    the editor (via the `LineStartIndex` set), so it stays in Core and is
    unit-tested like `IndentEngine`. Pairs: `()`, `[]`, `{}`, `""`, `''`,
    `` `` ``. A `public enum AutoPairAction: Equatable` with cases
    `wrap(open:close:)`, `insertPair(close:)`, `typeOver`, `passthrough` is the
    value the view layer turns into a programmatic edit. Two static functions.
    `action(text:selectedRange:typed:)` decides what to do when a single
    character is typed (non-single-character `typed` — paste/IME — →
    `.passthrough`): an opener wraps a non-empty selection, else `.insertPair`
    when the following position *can close*, else `.passthrough`; a closer
    `.passthrough`es a non-empty selection (so the typed closer replaces it),
    else `.typeOver`s an identical closer sitting immediately after the caret,
    else `.passthrough`; a quote wraps a non-empty selection, else `.typeOver`s an
    identical quote after the caret, else `.insertPair` when it *can close*, else
    `.passthrough`. *can-close* (brackets) is: the next position is
    end-of-buffer, a line separator, whitespace, or a closing bracket — so an
    opener directly before a word does not strand a closer. *can-close-quote* is
    *can-close* AND the character immediately before the caret is not
    alphanumeric — so an apostrophe completing a word (`don'`) passes through
    rather than auto-closing into `don''`. `shouldDeletePair(text:location:)`
    returns true when Backspace at `location` (empty selection) sits between an
    auto-inserted empty pair — `(|)`, `"|"`, … — so both characters delete
    together; false for a mismatched/non-empty neighbor pair or a buffer
    boundary. Surrogate-safe single-character reads (a lone surrogate half maps to
    a non-matching `nil`), all index math guards buffer bounds. Bracket/quote
    matching counts *raw* characters — no string/comment awareness (no lexer),
    matching `IndentEngine`'s language-agnostic scope; the quote heuristics above
    stand in for that missing context.
  - `BracketMatchEngine.swift` — pure, testable caret↔bracket pair matching for
    the editor's *pair highlighting* (Foundation only, no AppKit/Neon — the
    `AutoPairEngine`/`IndentEngine` precedent: the engine answers *which two
    characters* to highlight while the view owns the attributes and the colors).
    `public struct BracketPair: Equatable` carries `open`/`close`, both length-1
    UTF-16 ranges with `open` always first regardless of which side the caret sat
    on. `public enum BracketMatchEngine { static func pair(text: NSString,
    selectedRange: NSRange) -> BracketPair? }`: a **non-empty selection** yields
    `nil` (pair highlighting is a caret affordance and a selection already has its
    own highlight; a negative length is degenerate and treated the same), and a
    location outside `0...length` — including `NSNotFound` — yields `nil` without
    trapping. That out-of-range rule is the one deliberate deviation from
    `AutoPairEngine`, which *clamps* a degenerate range because it must still
    decide what a keystroke does; here a caret outside the buffer names nothing to
    highlight. The character *after* the caret is considered first, then the one
    before it (VS Code order), so with brackets on both sides the following one
    wins — and an adjacent bracket that has *no* match doesn't end the search, so
    a caret between an unmatched opener and a matched closer (`)|(`) still
    highlights the closer's pair. An opener scans forward and a closer backward,
    counting the depth of *its own kind* only (`IndentEngine.dedentOnClosing`'s
    rule); no match → `nil`. Quotes are deliberately absent from the tables: a
    quote is its own closer, so "which one closes this one" has no answer without
    a lexer; `<`/`>` are absent for the same kind of reason (comparison operators
    far more often than brackets), both pinned by tests here and in the scanner's
    suite. The character adjacent to the caret is read singly and
    surrogate-safely (a lone surrogate half is never a bracket), but the two
    *outward scans* read in `getCharacters(_:range:)` chunks of the same 4096 units
    `BracketDepthScanner` uses, comparing raw UTF-16 units. That is not symmetry
    for its own sake: the scan stops at the match — a handful of characters away in
    well-formed code — but the common mid-typing state is an *unmatched* adjacent
    bracket (typing `(` right before a word, which `AutoPairEngine` deliberately
    passes through without a closer), and then the scan runs to the buffer end,
    twice, on **every caret move with no debounce**. Per-character
    `NSString.character(at:)` there would be exactly the objc-per-character
    full-buffer walk the scanner's bulk read exists to avoid. Comparing raw units
    preserves the surrogate safety for free (a surrogate half can never equal an
    ASCII bracket). Raw character scan, **no
    string/comment awareness** (no lexer), the same boundary
    `IndentEngine`/`AutoPairEngine` draw: a bracket inside a string literal or a
    comment still matches (known limitation; tree-sitter-aware matching is a
    follow-up). **Divergence from `BracketDepthScanner`** (see that entry for the
    mirror statement): per-kind counting here vs. one shared stack there, so on
    *crossed* input `{[(]}` this engine pairs `[`↔`]` while the scanner marks both
    unmatched — a red bracket can still show a highlighted pair. Deliberate and
    accepted (broken code mid-typing; neither answer is wrong for its own
    question), pinned by `testCrossedBracketsPairPerKindUnlikeDepthScanner` here
    and its mirror in the scanner's suite. Unit-tested in
    `BracketMatchEngineTests`.
  - `BracketDepthScanner.swift` — pure, testable nesting-depth scanning for the
    editor's *rainbow brackets* (Foundation only, color-free — the palette is the
    view's). `public struct BracketToken: Equatable` carries `location` (UTF-16
    offset of the one-unit bracket), `depth` (0 at the outermost) and
    `isUnmatched`; `depth` is *semantic*, not a palette index — the scanner
    reports the honest level (7 stays 7) and the view resolves `depth % N` over
    its own cycling palette (the `FileIconColor`/`SyntaxTokenKind` split). `public
    enum BracketDepthScanner { static func scan(text: NSString) -> [BracketToken] }`
    is one O(n) pass with a **single stack shared by all three kinds** (JetBrains
    rainbow semantics — nesting depth is one number for the whole document, so
    `{[()]}` reads 0,1,2): an opener is pushed and reported with the depth
    *before* the increment; a closer matching the top of the stack pops it and
    takes its opener's depth (so a pair always shares one color); a closer of the
    wrong kind, or one arriving on an empty stack, is reported `isUnmatched` and
    **leaves the stack untouched** (a stray `]` inside `(…)` must not orphan the
    `(`); openers still on the stack at the end are patched to unmatched *in
    place*, so the array stays sorted by `location`. A `depth` reported alongside
    `isUnmatched` is not meaningful and must not be looked up — `isUnmatched` wins
    and the view paints it red — and the two unmatched cases differ: a stray or
    wrong-kind *closer* carries `depth: 0` (it never sat on the stack), while a
    leftover *opener* keeps the depth it was pushed at, because it is patched in
    place rather than rebuilt. **The chunked bulk read is a requirement, not an
    optimization**: the caller runs this on the main actor after a debounce, and
    `NSString.character(at:)` is an objc message send *per character*, which would
    turn a nominally cheap O(n) pass over a megabyte-sized file into visible
    typing jank — so the text is read through `getCharacters(_:range:)` into a
    reusable `[unichar]` buffer of `internal static let chunkSize` (4096) units
    under `withUnsafeMutableBufferPointer`, costing `ceil(n / 4096)` message sends
    with an allocation bounded regardless of file size. Chunking is invisible in
    the result (the stack and the token array carry across chunks, each token's
    `location` is `chunkStart + indexInChunk`) and a test builds input straddling a
    chunk seam to pin exactly that. Same raw scan with **no string/comment
    awareness** as the rest of the editor's engines. **Divergence from
    `BracketMatchEngine`**: the shared stack differs from that engine's per-kind
    counting, so on crossed input `{[(]}` every token here is unmatched while the
    matcher pairs `[`↔`]` — the two agree on all well-formed code and are each
    right for their own question; pinned by
    `testCrossedBracketsAllUnmatchedUnlikeMatchEngine` and its mirror. Unit-tested
    in `BracketDepthScannerTests`. Follow-ups: tree-sitter-aware matching/scanning
    (skipping strings and comments, which would also close the crossed-input
    divergence), an iOS variant over these same two engines, and settings (on/off,
    number of colors).
  - `TextSearch.swift` — pure, testable text search/replace over an `NSString` in
    UTF-16 offsets (Foundation only — the `DuplicateEngine`/`AutoPairEngine`
    split: the view owns selection, scrolling and colors, every decision lives
    here), shared by *both* consumers — the editor's ⌘F find bar and the
    project-wide Find in Files traversal, so the two can never disagree on what
    matches. `SearchQuery` (`Equatable`: `pattern` + the three JetBrains toggles
    `isRegex`/`caseSensitive`/`wholeWord`, flags defaulting to `false`; a value
    type so the view can compare the query it last ran and skip a redundant
    re-scan), `SearchMatch` (`range` + 1-based `lineNumber`), `TextSearchError`
    (`Equatable`/`LocalizedError`: `.emptyPattern`, `.invalidRegex(reason:)` from
    `NSRegularExpression`'s own `localizedDescription` — the human text lives in
    Core like `GitError`/`FileServiceError`, because an invalid regex is an
    ordinary mid-typing state shown inline in the bar, not an alert), and
    `ReplaceEdit` (`range` + resolved `replacement` — a struct, not a tuple, so a
    whole plan is `Equatable` in tests). `enum TextSearchEngine` has six statics.
    `matches(in:query:)` produces ranges by one of two paths — a literal
    `range(of:options:range:)` walk with `.literal` (strict UTF-16, so a found
    length always equals the pattern's) advancing by `max(1, found.length)`, or
    `NSRegularExpression` (compiled by the one `regularExpression(for:)` factory,
    which always sets `.anchorsMatchLines` — see below) — and then runs **one**
    `wholeWord` post-filter over
    whatever either produced. That single filter is the design point: it judges
    the *found match's own* boundaries, so it **composes with regex** (a `\w+`
    match is already whole-word; an `oo` match inside `foo`, or a `[а-я]+` match
    inside a longer Cyrillic word, is filtered out) instead of needing a second,
    regex-specific rule that could drift from the literal one. "Word" is
    `CharacterSet.alphanumerics` plus `_`, a buffer boundary counts as non-word,
    and the two neighbor reads combine surrogate pairs (`AutoPairEngine`'s rule)
    so an astral letter reads as the letter it is rather than as a
    non-alphanumeric surrogate half — which would wave through a match that is not
    on a word boundary. Zero-length matches (`a*`) terminate the walk and keep
    locations strictly increasing on both paths. Line numbers cost one
    `LineStartIndex.offsets(in:)` per call plus a binary search per match
    (O(n + m log n), not O(n·m)), and use the same separators as the gutter and
    the minimap (LF, CR, CRLF as one, NEL, LS, PS); a match sitting exactly on a
    line start belongs to *that* line. `replacement(for:in:query:template:)`
    resolves one template: a literal query inserts it **verbatim** (`$1` there is
    an ordinary dollar sign, so replacing text *with* `$1` needs no escaping),
    while a regex query rebuilds the `NSTextCheckingResult` by re-running the
    pattern inside the match range with
    `[.anchored, .withTransparentBounds, .withoutAnchoringBounds]` and calls
    `replacementString(for:in:offset:template:)`. Those last two options are what
    make the re-run reproduce the *original* whole-buffer run
    (`matches(in:query:)` runs the regex over the full range with no *matching*
    options — the compile options, `.anchorsMatchLines` included, come from the
    shared factory)
    rather than the semantics of a region that happens to end at the match, and
    each fixes an opposite error. Without `.withTransparentBounds` a lookaround
    cannot see past the match — `(h)ello(?= world)` re-run inside `{0, 5}` finds
    nothing — so every such replacement fell back to the raw template and wrote a
    literal `$1` into the buffer, and through Find in Files onto disk, while
    reporting success. Without `.withoutAnchoringBounds` the mirror image: `^`/`$`
    would bind to the *re-run range's* own edges instead of the buffer's **line**
    boundaries, so a mid-line range would re-anchor and substitute rather than
    fall back — an anchored pattern re-matching a range the original run never
    produced. Those line boundaries are the point: `regularExpression(for:)`
    always compiles with **`.anchorsMatchLines`**, the product decision being that
    `^`/`$` in a *search* are line boundaries as they are in VS Code and JetBrains
    (`^import` finds every import line, not only one at the very top of the file).
    The option lives in that single factory, so it applies identically to
    `matches(in:query:)` and to this anchored re-match and the two can never
    disagree about which ranges an anchored pattern produces. What deliberately
    does *not* change: `.dotMatchesLineSeparators` stays off, so `.` still stops at
    a line break. Those anchors are ICU's, whose terminator set is a *superset* of
    `LineStartIndex`'s — see known limit (5) below. It never
    throws: an invalid pattern, an out-of-bounds range, or a range the re-run no
    longer re-matches exactly (a genuinely stale match) falls back to the raw
    `template` — the conservative outcome, since the user sees unsubstituted text
    rather than a silently wrong substitution.
    `replacePlan(matches:in:query:template:)` returns the edits
    **strictly last-to-first** by location, which is the whole ordering contract:
    each edit lies entirely before those already applied, so a caller walks the
    plan against one mutable buffer with *no* offset bookkeeping even for
    length-changing replacements. Overlapping input ranges are dropped with the
    earlier-in-document one winning (two edits over the same characters cannot
    both apply), duplicate zero-length matches at one location are dropped (they
    would otherwise insert the template twice), out-of-buffer ranges are dropped
    so a stale list can never trap, and the regex is compiled once for the plan.
    `index(nearestTo:in:forward:)` is the navigation cursor: forward takes the
    first match starting at or after `location` wrapping to the first, backward
    the last starting strictly before it wrapping to the last, `nil` only for an
    empty array. Deciding on the match's *start* is what lets the caller pass the
    selection's end for "next" and its start for "previous" and so step off the
    current match in both directions — with one qualification that keeps that
    promise true for a **zero-length** match (`a*`, `^`, `\b`, and every
    mid-typing state that reaches one). Selecting such a match leaves the
    selection's end *equal* to its start, so a plain at-or-after test resolves
    back to the match the caret already sits on and Find Next never advances —
    pinned to match 1 of *n* forever while the bar reports the others exist. So a
    zero-length match starting exactly *at* `location` is not a candidate going
    forward, while one of non-zero length still is (a caret placed at the very
    start of a match must still find it rather than skip past it), and nothing
    becomes unreachable: a lone zero-length match at the caret wraps back to
    itself. Find Previous needed no such rule — its predicate is already strict.
    `currentIndex(forCaretAt:in:)` answers the *other* navigation question — which
    match the caret is **on**, i.e. the counter's *n* and the match Replace applies
    to — and exists precisely so the two are never conflated. Reusing the forward
    cursor for it inherits the zero-length exclusion above, which is right for
    "where does Find Next go" and wrong for "where am I": for `^`/`\b`/`a*` it
    names the *following* match, so the counter reads one ahead of the caret and
    `replaceCurrent` edits a match the user is not looking at (with `^`, the first
    line could never be replaced at all, since selecting its match immediately
    resolves the cursor past it). So a match starting exactly at the caret wins
    outright *whatever its length*, falling back to the forward rule only when the
    caret sits on no match's start (mid-match or between matches); locations are
    strictly increasing, so at most one match can start there. For a non-zero-length
    match the two agree, which is why the split shows up only under a zero-length
    one. Unit-tested in `TextSearchTests`, including a walk that steps with
    `index(nearestTo:forward:)` and re-derives the current index from the resulting
    caret, so the selection and the counter can never drift apart by one again.
    **Boundaries** (deliberate, not omissions): no query history, no "replace in
    selection", no incremental/streaming search, and no string/comment awareness —
    the same raw-scan boundary the rest of the editor's engines draw.
  - `EditorViewport.swift` — "where was this tab left?", as a pure value plus the
    per-file store the macOS editor keeps it in. The macOS editor reuses **one**
    `NSTextView` for every tab, so `CodeEditorView.updateNSView`'s wholesale
    `textView.string = text` swap destroys the outgoing tab's position: unless
    something records it first, it exists nowhere and the reader comes back to the
    top of the file with the caret at 0. `public struct EditorViewport: Equatable`
    is that record — `selection: NSRange` (the caret or the selected range, in the
    editor's own UTF-16 coordinates, i.e. `NSTextView.selectedRange()`) and
    `topCharacterOffset: Int` (the UTF-16 offset of the first character visible at
    the top of the viewport). **The scroll anchor is a character offset, not a
    point**, and that is the one design decision in the file: a point is only
    meaningful against the geometry that produced it, and that geometry is not
    stable between two visits to the same tab — the code zoom rescales every line
    (⌘+/⌘-, and `ZoomScaleRule` makes `code` *be* `SettingsStore.fontSize`), the
    font or window width can change, and the text itself can be rewritten by
    another path (a project Replace All, a post-revert `reloadFromDisk`, a merge
    apply). Any of those re-wraps the document, so a remembered `y` names a
    different line, or one past the end; an offset into the *text* survives all of
    them, because the restore asks the live layout where that character is now.
    `clamped(toLength:)` is what makes a record safe to hand back to AppKit after
    the buffer it described has changed (a background tab can be truncated while
    off screen, and an out-of-bounds range is an exception, not a wrong scroll):
    `topCharacterOffset` is clamped into `0...max(0, length - 1)` — **`length`
    itself is deliberately excluded**, so the anchor always names a character that
    really exists (`0` for an empty buffer). The anchor's whole job is to be handed
    to the layout as "which character sits at the top", and at `length` there is no
    character: the glyph range there is empty and its bounding rectangle is
    meaningless, so admitting that value would buy the view layer nothing but a
    special case with three branches, one of which read a pre-layout estimate of
    `extraLineFragmentRect` and scrolled to a fraction of the intended offset. A
    stale anchor past the new end resolves to the *last character's* line instead,
    and `scrollEditor(to:)`'s clamp (`max(0, frame.height - clip.height)`) turns
    that into "the end of the document" for free. The selection clamp is different
    on purpose: `selection.location` is clamped into `0...length` — `length` **is**
    legal for a caret, that being the end of the file — with the length then
    **truncated** to what is left (`length - location`), never intersected. The
    truncation is the same reasoning `applyReveal` already documents: a range
    starting exactly at the buffer end shares no unit with the document, so
    `NSIntersectionRange` answers `{0, 0}` for it and a caret sitting at the end of
    the file would be sent back to the top. A `NSNotFound` or negative location has
    no position at all and collapses to `{0, 0}`. `public struct
    EditorViewportMemory` is the store — `[UUID: EditorViewport]` behind
    `record(_:for:)`, `forget(_:)`, `prune(keeping openFileIDs: Set<UUID>)` and
    `viewport(for:clampedToLength:)`. It is keyed by `OpenFile.id`, the same key
    the coordinator's per-file undo managers use, and pruned by the same open-tabs
    set on the same call, because the two answer the same question about the same
    object and must not disagree about which files still exist. **Absence is half
    the contract**: `viewport(for:clampedToLength:)` answers `nil` for a file with
    no entry, which is the "a tab shown for the first time belongs at the top of
    the file" rule expressed once, in Core, instead of as a scattering of
    view-layer `if`s. Note that the view layer has to *act* on that `nil` rather
    than skip: assigning `textView.string` leaves the caret at the **end** of the
    incoming buffer and the clip view at the outgoing tab's offset, so "no memory"
    is a top-of-file state only because `restoreViewport` sets one (see
    `app-editor.md`). `forget(_:)` exists for the one signal that invalidates a
    record without closing the tab — this file's text was replaced out from under a
    background tab, so the offsets name characters the incoming text never had.
    App-run lifetime only: nothing here is persisted, so a relaunch starts every
    tab at the top (`EditorSession` restores *which* tabs are open, not where they
    were). Unit-tested in `EditorViewportTests` (round trip, `nil` for an
    unrecorded id, `forget`/`prune` — asserted *by value*, since same-valued
    entries cannot catch a store that pairs surviving ids with the wrong
    viewports — that clamping on read leaves the record intact, and the clamp's
    edges: a caret past the new end, a selection straddling it, a caret exactly
    *at* it, `NSNotFound`, a negative location, an anchor past the end, a negative
    anchor, a negative buffer length, a negative selection length, a one-character
    buffer and length 0). **Boundaries**: no points, no line/column,
    no horizontal scroll offset (the editor does not soft-wrap, but a long-line
    x-position has never been remembered and is not part of this), and no
    persistence — the view-layer half is in `app-editor.md`.
