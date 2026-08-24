# PisakaCore — EditorConfig (resolution core + the indentation rules)

Design documentation for `.editorconfig` support: the five pure/near-pure Core
files that decide *which sections apply to a file*, *what one file's text
means*, *which files in the hierarchy are read at all*, *when a resolved answer
stops being true* and *which whitespace one indentation level is* — plus the
thin app-side wiring on both platforms. Read the relevant entry before modifying
that file, and update it when behavior changes.

## The shape of the feature, in one paragraph

The layer is **read-only and opt-in by the presence of a file**. When a project
has no `.editorconfig`, every behavior below is byte-for-byte what it was
before this layer existed: the content inference (`IndentEngine
.inferIndentUnit(text:)`) picks the indentation unit, and Tab inserts a literal
tab. When a config *does* apply, exactly **three properties are acted on** —
`indent_style`, `indent_size`, `tab_width` — and they change exactly **two
behaviors**: the unit Enter's auto-indent appends, and what the Tab key
inserts. Every other property (`end_of_line`, `charset`,
`trim_trailing_whitespace`, `insert_final_newline`, `max_line_length`, and
anything unknown) is parsed, merged and carried in the property map, but
nothing consumes it yet — part 2 takes the on-save ones. **Nothing is ever
rewritten**: no reformatting on open, on save, or when a config changes; only
newly typed text is affected.

## Decisions

- **The walk stops at the project root** — a deliberate deviation from the
  spec, which walks to the filesystem root. The project root's own
  `.editorconfig` is the last one considered whatever it declares, and a config
  in a parent directory is never read. The reason is uniformity across
  platforms: on iOS the app reads through a security-scoped grant for exactly
  the folder the user picked, so a config above it is not merely unusual to
  honor — it is *unreadable*. Honoring it on macOS alone would make the same
  project indent differently on the two platforms, which is worse than one
  stated limit that is the same everywhere.
- **The glob dialect is its own file, not `GitignoreMatcher`.** The two dialects
  disagree in three load-bearing ways: EditorConfig's `**` is *not* bound to
  whole path components (`a**z.c` is legal and matches inside one component),
  brace alternation `{a,b}` and integer ranges `{1..9}` exist here and nowhere
  in gitignore, and gitignore's `!` negation and trailing-`/` directory
  semantics carry no meaning here at all. Only `GlobCharacterRange` is shared —
  a bare inclusive character range is a value, not a matching rule, and nothing
  about the disagreements touches it.
- **`?` excludes `/`.** The spec says "any single character" and the reference
  implementations disagree, some translating `?` to a regex `.` that crosses
  separators. Pisaka treats `?` as `*`'s single-character sibling, so a
  one-character wildcard can never silently reach into another directory. Stated
  on the type, because a reader who knows another core will expect the other
  answer.
- **Comments are line comments only.** A `#` or `;` starts a comment only as the
  first non-whitespace character of a line; anywhere else it is ordinary text
  belonging to the value, per the current spec's explicit prohibition of inline
  comments — so `foo = a ;)` has the value `a ;)`, not `a`.
- **The spec's required acceptance floors are taken as the cap**: a section name
  longer than 1024 characters, a key longer than 1024, or a value longer than
  4096 is ignored rather than truncated. A core must *accept* up to those
  lengths; refusing beyond them is conforming. It does **not** bound the
  matcher — that is `EditorConfigGlob.maximumMatchSteps`' job, for the reason
  recorded on it.
- **The unit rule is hybrid, and the Tab rule is stricter.** Two questions with
  deliberately different answers, because they carry different risks — see
  `IndentUnitRule` below.
- **Tab fans out over every insertion point.** Native `insertTab` inserts at all
  of `NSTextView.selectedRanges`, and the middle-drag column selection makes
  several zero-width carets a first-class state, so a handler that replaced only
  `selectedRange()` would silently collapse a multi-caret selection to one
  caret. The plan is computed in Core and applied back-to-front in one undo
  group.
- **Invalidation is wholesale, both times**, and a root change clears the cache
  *before* anything can be served — the never-serve-a-previous-project
  guarantee.
- **The layer is a reader**, like the symbol index: it opens files and writes
  none, so it neither raises the disk-writer gate (`autosave.suspend()` +
  `localChanges.beginRevert()`) nor is gated by it. A resolution landing in the
  middle of a revert or a branch switch costs at worst one stale answer, which
  the `noteProjectFilesChanged()` that follows every such rewrite corrects.
  Nothing here may grow a writer bracket.
- **No `.editorconfig` fixture files are committed.** A real one under `Tests/`
  would also apply to this repository, in every editor and every tool that reads
  the format. Sample configs are inline string constants fed to `StubFileTree`
  in-memory trees; "fixture-based" is honored by modelling the case *contents* on
  the official EditorConfig core test suite and naming each test after the case
  it mirrors.

## Core files

  - `EditorConfigGlob.swift` — the section-name dialect, compiled once per
    section and asked repeatedly whether it matches a path (Foundation only,
    pure). `EditorConfigGlobToken` is the vocabulary: `.literal`, `.star` (any
    run not crossing `/`), `.doubleStar` (any run, separators included, and
    *not* component-bound), `.anyOne` (`?`, one character, never `/`),
    `.characterClass`, `.alternation` (`{a,b}`, nested arbitrarily) and
    `.numericRange` (`{num1..num2}`, inclusive, negative bounds and a matched
    leading `-` included). `EditorConfigCharacterClass` carries the `[!…]`/`[^…]`
    negation flag (both spellings, as the reference implementations accept both),
    the single members and the `a-z` ranges (`GlobCharacterRange`, the one thing
    reused from `GitignoreMatcher`). `public struct EditorConfigGlob` takes the
    section name verbatim and exposes `pattern`, `anchored`,
    `exceedsLengthLimit`, `maximumSectionNameLength = 1024` and
    `matches(relativePath:) -> Bool`, where the path is `/`-separated and
    relative to the directory holding the `.editorconfig` — which is what makes
    the whole dialect expressible without ever seeing an absolute path.
    **Preprocessing** follows the spec: a pattern containing no *unescaped* `/`
    matches at any depth (as if written `**/pattern`), any other pattern is
    anchored to that directory and a leading `/` is dropped before compiling.
    "Any depth" is a flag rather than an injected `**/` token because the `**/`
    may stand for zero directories; `matches` tries the whole path first and then
    each component start. A `**/` the pattern actually *spells* stands for zero
    directories too — the reference core translates the whole `/**/` sequence to
    `(\/|\/.*\/)`, so `[src/**/*.ts]` governs `src/index.ts` and `[**/*.md]`
    governs a top-level `README.md`; matching skips the `**` and the `/` after it
    as one alternative, and only where the pattern really spells `/**/` (or opens
    with `**/`, where the config's own directory plays the leading `/`), so
    `a**/z.c` still needs its separator. Equality is by `pattern` alone, since the
    tokens are derived from it. **Matching** is recursive backtracking rather than
    the gitignore matcher's dynamic-programming walk: nested alternation and
    integer ranges make the state space a tree rather than a grid. That tree is
    **not** bounded by the 1024-character cap — the cost is exponential in the
    *number of wildcards*, and a 24-character section name against a 42-character
    path measured ~34 s on the main thread — so `maximumMatchSteps` (200 000)
    bounds it instead: every token step spends one, and an exhausted budget
    answers "does not match", the same degradation an over-long section name
    already gets. The budget is **scoped to one whole resolution**, not to one
    `(section, path)` pair: nothing caps how many sections a `.editorconfig`
    declares or how many configs the outward walk reads, so a per-pair budget
    multiplies by both — fifty copies of one pathological name measured ~30 s on
    a single keystroke. `EditorConfigResolver.resolve` allocates it and threads
    it through `EditorConfigFile.sections(matching:budget:)` into every glob; the
    pair-level `matches(relativePath:)` keeps its own for one-off callers.
    Realistic patterns cost microseconds and are nowhere near it — a
    200-section config spends under 5% of the ceiling — which
    `EditorConfigGlobTests` asserts from both sides. `*`/`**` try every run
    length from the shortest up, stopping at a `/` unless allowed to cross one; an alternation splices
    each branch in front of what follows the group, so a branch that matches but
    leaves the rest unmatchable falls through to the next — and **that splice is
    charged to the budget**, because it copies up to the whole compiled pattern
    per attempt, which a flat one-step-per-attempt count would under-report by
    the pattern's length (a 1 008-character alternation-heavy name spent ~0.6 s
    before it was); a numeric range tries
    the longest digit run first and then shorter ones, so `{1..2}0` matches `10`
    while a bare `{1..2}` refuses it. `EditorConfigGlobCompiler` is the
    source-characters-in, tokens-out half: `\` escapes the next character (a
    trailing lone backslash is a literal backslash), an unclosed `[` is a
    literal, a brace group that never closes — or that holds neither a top-level
    comma nor a `..` integer range (`{single}`, `{}`, `{a..b}` with non-integer
    bounds) — is literal text with its braces, and a `]` in the first member
    position of a class is a literal rather than the terminator. Unit-tested in
    `EditorConfigGlobTests`, construct by construct, mirroring the official core
    suite's glob cases.
  - `EditorConfigFile.swift` — one file's text parsed into its preamble flag and
    its ordered sections, plus the merged property map every consumer reads.
    `EditorConfigPair` is one `key = value` as written: the key trimmed and
    lowercased, the value trimmed and lowercased *only* for the known property
    set (an unknown property's value may be a path or a command, so it is carried
    verbatim). `EditorConfigSection` pairs a compiled `EditorConfigGlob` with its
    pairs **in document order** — an array rather than a dictionary, because the
    merge is defined as "apply in document order", which is also what makes a
    duplicate key inside one section last-wins with no separate rule for it.
    `public struct EditorConfigFile(text:)` **never fails**: a malformed line is
    skipped and the rest of the file is still read, so one typo in a shared
    config cannot silently drop every rule below it. Its rules: a comment is a
    `#`/`;` as the first non-whitespace character of a line and nowhere else;
    `root = true` is honored only in the preamble before the first section and
    compared case-insensitively (one written *under* a section is just another
    property of that section); a section header is the text between the leading
    `[` and the **last** `]` on the line, and a header that never closes is
    skipped; a pair splits at its **first** `=`, so a value may hold as many more
    as it likes; `maximumKeyLength = 1024` and `maximumValueLength = 4096` are
    the caps. `sections(matching:)` returns every matching section in document
    order. `public struct EditorConfigProperties` is the merged map: `values`
    (keys already lowercased), `subscript(key:)`, `isEmpty`, and
    `apply(_ pair:)`, which for the value `unset` (case-insensitive) *removes*
    the property instead of setting it — the spec's way of letting a closer file
    undo an inherited rule. `knownKeys` is the set whose values are
    case-insensitive per the spec, and is what the parser consults before
    lowercasing anything. Unknown properties are carried and never dropped. The
    typed accessors cover only what is consumed today: `indentStyle`
    (`.tab`/`.space`, `nil` when absent or unrecognized), `indentSize` (`.tab`
    for the literal word, `.width(Int)` for a strictly positive integer — `0`,
    negatives and non-numerics are treated as absent rather than as errors),
    `tabWidth` (the explicit property, else a numeric `indent_size`, the default
    the spec states) and `indentWidth` (how wide one level is: a numeric
    `indent_size`; `indent_size = tab` defers to the *explicit* `tab_width`; with
    no `indent_size` at all a stated `tab_width` still describes the width).
    Unit-tested in `EditorConfigFileTests`, edge case by edge case from the
    official suite.
  - `EditorConfigResolver.swift` — the hierarchy walk: `public enum
    EditorConfigResolver` with `fileName = ".editorconfig"` and
    `resolve(fileURL:projectRoot:fileService:) -> EditorConfigProperties`. It
    walks *outward* from the file's own directory through its ancestors, reading
    each `.editorconfig` through the `FileServicing` seam and stopping after the
    first one declaring `root = true` — and **never above the project root**
    (the deviation recorded above). An absent config is the common case and an
    unreadable one (a permission, a lapsed security scope) degrades to the same
    thing: no properties from that directory, and the walk carries on rather than
    failing. The read goes through `readTextIfNotBinary(url:maxBytes:)` with
    `maximumFileBytes` (1 MiB) rather than the uncapped `read(url:)`: the walk
    runs synchronously inside the Enter and Tab key handlers over content a clone
    brought in, so a `.editorconfig` three orders of magnitude past the spec's
    own acceptance floors must not be decoded and line-split on the keystroke —
    and over the cap is a third way of spelling the same "no properties from that
    directory", including its `root = true`. The merge is **outermost-first**: within each file every section
    whose glob matches applies in document order, overwriting property by
    property and never wholesale, so closer files and later sections win.
    **Empty properties** is the answer for a `nil` root, a `nil` url (an untitled
    buffer), a file outside the project (an out-of-project definition window) and
    a project whose configs say nothing about the file — the caller cannot and
    need not tell those apart, because all four mean "fall back to what the
    editor would have done anyway". The directory chain is built from the file's
    **own spelling**, not its canonical path, so a section glob matches the path
    as the user wrote it; containment ("is this file inside the project at
    all?") is still asked canonically through `CanonicalPath`, the repository's
    one rule for that question, and when the two spellings disagree about how
    many components separate the file from the root (a symlinked root) the
    canonical one is used for both, since a chain that does not actually contain
    the file would match nothing. Unit-tested in `EditorConfigResolverTests` over
    `StubFileTree`.
  - `EditorConfigModel.swift` — `@MainActor public final class
    EditorConfigModel`: the editor's one entry point, a per-file cache of
    resolved properties over the resolver plus the two invalidation points the
    app already has a place to call. `properties(for fileURL: URL?)` is
    **synchronous on purpose** — Enter's auto-indent and the Tab key run inside
    the text view's own key handling, which cannot await — and resolves on a
    miss. A resolution is a handful of small reads of files that are almost
    always in the page cache, and the miss happens once per file per
    invalidation; making it async would buy nothing and would force the key
    handlers to guess an answer and correct it later. An **empty answer is
    cached like any other**: a project with no `.editorconfig` at all is the
    common case and may not re-walk the hierarchy on every Enter.
    `noteProjectRoot(_:)` records a (possibly `nil`) root and clears the whole
    cache when it *differs* — including switching to or from `nil` — before
    anything can be served for the new project; the same root again is a no-op,
    so the idle re-assignments a SwiftUI `onChange` (and the iOS editor's
    point-of-use registration) can produce do not throw the cache away. Roots are
    compared canonically **by `path`**, so a trailing slash or a
    `/tmp`-vs-`/private/tmp` re-spelling is not mistaken for a folder switch (two
    urls naming one folder still differ as values when one carries a directory
    hint). `noteProjectFilesChanged()` clears the cache wholesale rather than
    filtering by path: deciding which cached files a given `.editorconfig` edit
    could have affected means re-walking each of their hierarchies, which is the
    very work the filter would be saving — wholesale, the next keystroke in the
    front tab pays for one re-resolution and nothing else does. Unit-tested in
    `EditorConfigModelTests`, including the cache hit asserted against
    `StubFileTree`'s read log.
  - `IndentUnitRule.swift` — which string is one indentation level, what the Tab
    key inserts, and the multi-insertion-point arithmetic; pure and
    Foundation-only, like every other engine here. `TabInsertionPlan` carries
    `replacements` (`IndentReplacement`, reused verbatim from `IndentEngine` —
    a (range, replacement) pair is a (range, replacement) pair whoever produced
    it), sorted by ascending location and non-overlapping, which is what lets the
    view apply them **back-to-front** inside a single undo group, and `carets`,
    zero-length `NSRange`s in the *resulting* text ready for `setSelectedRanges`.
    `unit(config:inferred:)` is the **hybrid** rule: `indent_style = tab` → a
    tab, whatever the content looks like and whatever width is configured (a
    width describes how a tab is *displayed*, never what is inserted);
    `indent_style = space` → spaces as wide as the configuration says, falling
    back to the inferred unit's width when *that* is spaces and to
    `defaultSpaceWidth` (4, matching `IndentEngine.inferIndentUnit`'s own
    fallback) when the inference says tab, since there is no width to carry over
    from a tab, and clamped at `maximumSpaceWidth` (64) because the unit is built
    as a *string on the main thread* for every Enter and every Tab — an untrusted
    `indent_size = 2000000000` would otherwise allocate two gigabytes per
    keystroke; **no `indent_style`** → the inference decides tabs vs. spaces and
    a configured width re-widens a space inference, while a tab inference stays a
    tab (a width alone never converts a file); nothing applicable → `inferred`,
    returned unchanged. `tabInsertion(config:inferred:)` is **stricter on
    purpose**: the effective unit only when the configuration says `indent_style
    = space` outright, and a literal tab in every other case. The asymmetry is
    the point — auto-indent already picks a unit for every file, so letting a
    config refine it changes only which whitespace an already-automatic insertion
    uses; the Tab key is what the *user pressed*, and turning it into spaces on a
    file the content inference merely *guessed* was space-indented would silently
    rewrite what typing does. `tabInsertionPlan(ranges:insertion:)` replaces
    every range — a bare caret or a non-empty selection alike, which is what the
    native Tab does at each insertion point — with `insertion`, placing each
    resulting caret at the end of its own insertion shifted by the net length
    change of every earlier range. The input is normalized rather than trusted:
    ranges are sorted and overlapping ones unioned, so the replacements can be
    applied back-to-front without one edit invalidating the next; touching-but-
    not-overlapping ranges stay separate (a caret at the end of a selection is a
    second insertion point), while anything *starting* where the previous range
    starts is the same insertion point — two identical carets, and equally a
    caret at a selection's start, whose `NSMaxRange` is its own location and so
    would slip a strict `<` overlap test — and an
    empty list answers `.empty`, which the view treats as "let the responder
    chain have the key". `IndentEngine` is **untouched** by all of this: it keeps
    taking `unit` as a parameter and its existing tests pass unmodified.
    Unit-tested in `IndentUnitRuleTests` over the full matrix, including the
    parity check that the plan's edits reproduce, for a single range, exactly
    what one replacement would have produced.

## App wiring (both platforms)

Thin by convention: the views wire keys to the rules and decide nothing.

  - **macOS.** `PisakaApp` owns one `EditorConfigModel` as a plain stored
    reference over the same stateless `FileService()` every other disk reader
    uses — the `symbolIndexController` precedent, and for its exact reason: it
    publishes nothing, so observing it would put `ContentView` (and with it the
    project tree, the tab list and `CodeEditorView.updateNSView`) on an update
    path for a value this scene's `body` never shows. It is threaded through
    `ContentView` into `CodeEditorView` as a plain, undefaulted property beside
    `symbolIndex` (undefaulted because any default worth writing would be a
    second live disk reader built for a view nobody constructs), and the
    coordinator holds it **weakly**, like `symbolIndex` — a deallocated one means
    empty properties, which is exactly the "no configuration applies" answer.
    Invalidation hangs off `noteProjectRoot(_:)` in `openFolder(url:)`,
    synchronously, before anything can ask a question — plus **three**
    `noteProjectFilesChanged()` sites, which together are what makes a live
    `.editorconfig` edit take effect without reopening the project. The watcher
    callback (`projectWatcher.start(root:onChange:)`, beside the tree bump and
    the index refresh) covers only *other* processes' writes:
    `kFSEventStreamCreateFlagIgnoreSelf` drops every event this app causes, so on
    its own it would miss both of the paths that matter most. So
    `notifyIndexOfProjectFileChanges()` invalidates too — ahead of its root guard,
    since unlike the index this cache needs no root to be told anything — covering
    the app's own worktree rewrites (branch switch, revert, merge apply,
    project-wide Replace All, a tree rename or delete), exactly as the iOS peer in
    `RootView_iOS` does; and `noteEditorConfigWrites(_:)` covers the *save* paths
    that funnel deliberately does not (`save(id:)` and the autosave's `onSaved`,
    which was widened to report the urls it wrote), because editing a
    `.editorconfig` in Pisaka itself is the likeliest way anyone changes one and is
    a self-write the watcher never sees. That last one is narrow on purpose — it
    fires only when a written url *is* a `.editorconfig` — since an ordinary save
    is the app's most frequent write and clearing on each would put a resolution
    walk on the next keystroke after every autosave burst.
  - **The macOS Tab handler.** `doCommandBy` intercepts
    `#selector(NSResponder.insertTab(_:))` and returns **`false` whenever the
    rule answers a tab**, so AppKit's own `insertTab` runs and the key behaves
    byte-for-byte as it did before this layer existed — at every insertion point,
    with the stock undo grouping and the stock field-editor semantics. Only when
    the rule answers spaces does it act: all of `textView.selectedRanges` go
    through `tabInsertionPlan`, and the replacements are applied back-to-front
    inside one `shouldChangeText(inRanges:replacementStrings:)` /
    `textStorage.beginEditing()` … `endEditing()` / `didChangeText()` bracket
    (one undoable step, one change notification), followed by
    `setSelectedRanges` with the plan's carets. A `shouldChangeText` *refusal*
    returns `false`, not `true`: a refused edit is not a handled key, and eating
    it would leave Tab doing nothing at all. The spaces are written as an
    `NSAttributedString` carrying `textView.typingAttributes`, because the raw
    storage path (which the multi-range fan-out needs) would otherwise inherit
    whatever the adjacent text has — and in a buffer with no adjacent text, no
    font at all; every *other* programmatic edit here goes through
    `insertText(_:replacementRange:)`, which applies them for free. The handler
    also asks the **cheap question first** — `indentStyle == .space`, before
    touching the buffer — because `textView.string` bridges a mutable
    `NSTextStorage` and copies the whole buffer, and `inferIndentUnit` then walks
    every line of that copy: paying both on every Tab press to compute a value the
    stricter rule discards is precisely the main-thread cost `textDidChange` is
    careful to avoid. The iOS coordinator asks it in the same order. The existing
    `isApplyingProgrammaticEdit` guard covers the *whole* bracket, not just the
    storage mutation, because the single-range case reaches the single-range
    delegate callback where the auto-pair interceptor lives. `insertBacktab` is
    untouched. Enter's handler is unchanged except for where its `unit` comes
    from: `IndentUnitRule.unit(config:inferred:)` instead of the bare inference,
    asked through one private helper so Enter and Tab can never disagree about
    the unit — they differ only in *whether* it is used.
  - **iOS.** `PisakaApp_iOS` builds the model over the *scoped*
    `SecurityScopedFileService`, so its reads run under the opened folder's
    security-scope grant, and hands it to `RootView_iOS` (a plain `let` — it
    publishes nothing) and on to `CodeEditorView_iOS`, which also starts
    receiving `projectRoot` as the macOS editor already does. The root is
    registered **at the point of use**, on every editor update, and not only from
    `RootView_iOS`'s `.onChange(of: model.projectRoot)`: that observer runs in a
    *later* SwiftUI update cycle — the hazard the root view already fences
    against for the branch widget and the symbol index — so registering only
    there would leave a window in which the editor already shows the new
    project's file while the model still holds the previous root, and one Enter
    pressed inside it would be indented by the folder the user just left. The
    call is idempotent for an unchanged root, so doing it every update costs a
    comparison and throws no cache away. `notifyIndexOfProjectFileChanges()`
    drops the cache alongside the index refresh, covering the worktree rewrites
    the app performs itself (a branch switch, a revert, a merge apply), and
    `noteEditorConfigWrite(_:)` — the peer of the macOS `noteEditorConfigWrites(_:)`,
    narrow for the same reason — covers the one *save* iOS has, the close
    confirmation's **Save** button, since that funnel deliberately does not and
    editing a `.editorconfig` in Pisaka itself is the likeliest way anyone changes
    one. iOS has **no file-system watcher**, so an out-of-band edit to a
    `.editorconfig` (Files.app, another app's share extension) is not picked up
    until one of those boundaries — a stated limit, exactly as it is for the
    symbol index.
  - **The iOS Tab handler.** `shouldChangeTextIn` intercepts a `"\t"`
    replacement, applies the rule's spaces through the existing `applyEdit` and
    suppresses the default; when the rule answers a tab it lets `UITextView`
    insert its own, untouched. `UITextView` has a single `selectedRange`, so no
    fan-out is needed — but the one range still goes through `tabInsertionPlan`,
    so the arithmetic that decides what replaces the selection and where the
    caret lands is asked once, in Core, rather than restated per platform.

## Test inventory

Every acceptance case has a named test, all in `Tests/PisakaCoreTests/` and all
over in-memory trees (no committed `.editorconfig`):

  - `EditorConfigGlobTests` — each construct separately: `*` vs. `/`, `**`
    across directories and inside a component, `?`, classes and negated classes,
    literal brace groups, nested braces, numeric ranges (negatives included, a
    non-integer refused), escapes, the 1024-character boundary accepted at the
    limit and ignored beyond it, and the "no slash ⇒ any depth" vs. "slash ⇒
    anchored" split. Plus the budget from all four sides, each asserted on a wall
    clock because a bound on work is the only honest way to state one: the
    wildcard-heavy pathological name, the alternation-heavy one (the shape a flat
    step count under-reports), fifty copies of it in one file (the per-pair-vs-
    per-resolution scope), and a 200-section but honest config spending under half
    the ceiling while every matching section still answers.
  - `EditorConfigFileTests` — whole-line `#` and `;` comments (leading
    whitespace included), a `;`/`#` kept verbatim inside a value (the spec's own
    `foo = a ;)`), whitespace around keys and values, a value containing `=`, the
    key and value length caps at and beyond the floor, a header with no closing
    bracket, a `root = true` after the first section ignored, key and known-value
    case-insensitivity, and every accessor including the `indent_size = tab` →
    `tab_width` coupling and the rejection of `0`/negative/non-numeric sizes.
  - `EditorConfigResolverTests` — nested configs overriding per property,
    `root = true` stopping the walk, a config above the project root never read,
    later-section-wins inside one file, `unset` clearing an inherited property,
    unknown properties surviving the merge, a file outside the root and a `nil`
    root both resolving to empty, and an unreadable — or oversize — `.editorconfig`
    degrading to "no properties from that file" (its `root = true` included)
    rather than failing the walk.
  - `EditorConfigModelTests` — a cached answer served without a second read
    (asserted against `StubFileTree`'s read log), an edited config picked up
    after `noteProjectFilesChanged()`, a root switch clearing the previous
    project's entries, a `nil` root answering empty, and repeated queries for
    different files under one root.
  - `IndentUnitRuleTests` — the full unit/Tab matrix (both styles, width from
    `indent_size`, width from `tab_width`, `indent_size = tab` with and without
    `tab_width`, each half-specified case against both a tab-inferred and a
    space-inferred file, empty properties returning the inference and a literal
    tab respectively), and the plan cases (one caret, one non-empty range,
    several carets on consecutive lines — the column-selection shape — several
    non-empty ranges, and the resulting caret offsets checked against a text the
    test applies the plan to, including the single-range parity check that stands
    in for eyeballing the view).
