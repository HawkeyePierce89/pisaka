# PisakaCore — EditorConfig (resolution core, the indentation rules, the on-save transforms)

Design documentation for `.editorconfig` support: the six pure/near-pure Core
files that decide *which sections apply to a file*, *what one file's text
means*, *which files in the hierarchy are read at all*, *when a resolved answer
stops being true*, *which whitespace one indentation level is* and *what a save
rewrites* — plus the thin app-side wiring on both platforms. Read the relevant
entry before modifying that file, and update it when behavior changes.

## The shape of the feature, in one paragraph

The layer is **opt-in by the presence of a file** and **adds no write of its
own**. When a project has no `.editorconfig`, every behavior below is
byte-for-byte what it was before this layer existed: the content inference
(`IndentEngine.inferIndentUnit(text:)`) picks the indentation unit, Tab inserts
a literal tab, Enter splices an LF, and a save writes the buffer exactly as it
stands. When a config *does* apply, exactly **six properties are acted on**, in
two groups. The three *indentation* ones — `indent_style`, `indent_size`,
`tab_width` — change what **newly typed** text is: the unit Enter's auto-indent
appends, and what the Tab key inserts. The three *on-save* ones —
`end_of_line`, `trim_trailing_whitespace`, `insert_final_newline` — change what
a **save** writes, and are the single deliberate exception to part 1's founding
principle that existing content is never reformatted (`SaveTransform` below).
`end_of_line` is consumed on both sides of that line: it decides what
already-written terminators become on a save *and* what Enter splices, so the
two can never disagree. Every other property (`charset`, `max_line_length`, and
anything unknown) is parsed, merged and carried in the property map, and nothing
consumes it. **A save is the only trigger**: nothing is rewritten on open, on
close, on a tab switch or when a config changes, indentation already in a file is
never rewritten, and there is no whole-project normalization command.

`.editorconfig` is now a first-class language in Pisaka. The file syntax itself is highlighted and its symbol indexing offers section headers for navigation, while the keywords list offers its property names and values for completion. This language-level functionality is fully separated from the file's behavioral side: file resolution, indentation rules, and the on-save transforms described below remain entirely unchanged by it. See `SyntaxLanguage.swift` in `core-editor.md` and the symbols/keywords entries in `core-intelligence.md` for the language mechanics.

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
- **A save is the one exception, and it is written down as one.** Part 1's
  principle is not quietly relaxed: exactly three properties, on exactly one
  trigger, and only when the project's own `.editorconfig` asks for them. Open,
  close, tab switch and a configuration change still rewrite nothing; no
  indentation already in a file is ever rewritten; and the other worktree writers
  (project-wide Replace All, every git operation) keep writing exactly the bytes
  they write today. Why a save is admissible where the others are not: it is the
  one moment the file's bytes are being decided anyway, so a transform there
  produces the diff the configuration asked for and no unrequested one — whereas
  the same rewrite on open or on a tab switch would dirty a file nobody edited.
- **The three transforms compose against the *original* offsets.**
  `SaveTransform` emits one ascending, non-overlapping edit list rather than
  piping three passes into one another, so no intermediate buffer exists and the
  position remap is arithmetic over that single list instead of three remaps
  stacked. Only the final-terminator decision has to read through the earlier
  steps, because a last line that trimming empties is already terminated by the
  line above it and must not gain a second terminator.
- **The caret's line is spared from trimming.** Autosave here is aggressive
  (idle, tab switch, focus loss, termination), so trimming the line the caret is
  on would delete the indentation someone had just typed and was about to type
  into, mid-thought — a save nobody asked for eating a keystroke they did. Every
  line holding a protected position (the caret, and each endpoint of every
  selected range) keeps its trailing whitespace, and the first save after the
  caret leaves trims it. The exemption is **trimming's alone**: a terminator is
  normalized and a final newline appended under the caret exactly as anywhere
  else, because neither can delete what was just typed. A buffer with no
  protected positions — one no editor is showing — is trimmed in full.
- **NEL, LS and PS are left exactly as they are.** `end_of_line`'s vocabulary
  names LF, CR and CRLF; the editor's own separator set (`LineStartIndex`) is a
  strict superset of it. Folding a separator the property never named into one it
  did would be this engine inventing a rule the configuration did not state, so
  the three unnamed ones survive every combination. This is the feature's one
  stated limit. It is a rule about the separators a file *already* has, not
  licence to add one: `insert_final_newline` appends LF where the file's own last
  terminator is one of the unnamed three, because appending an unnamed one would
  leave the file with no final newline by every reckoning outside this editor's
  splitter while making the property unsatisfiable ever after.
- **The transform rides the live editor whenever there is one.** A buffer on
  screen is rewritten *through* the text view, in one `shouldChangeText` /
  `beginEditing`…`endEditing` / `didChangeText` bracket applied back-to-front, so
  the whole save is a single undoable step and every observer sees an ordinary
  edit; replacing the string behind the editor's back would drop that tab's undo
  stack and its remembered scroll position on the most ordinary action there is.
  A background tab has no view to ride and pays exactly that cost, which is
  stated on the controller rather than left to be discovered.
- **The layer is a reader**, like the symbol index: it opens files and **adds no
  write of its own**, so it neither raises the disk-writer gate
  (`autosave.suspend()` + `localChanges.beginRevert()`) nor is gated by it. The
  on-save transform does not change that: it writes nothing itself, it changes
  *what the write the user already asked for puts on disk*, and it runs inside
  that save's own gating — `PisakaApp.save(id:)` asks it **after** the writer-gate
  refusal, so a save the gate refuses transforms nothing at all. A resolution
  landing in the middle of a revert or a branch switch costs at worst one stale
  answer, which the `noteProjectFilesChanged()` that follows every such rewrite
  corrects. Nothing here may grow a writer bracket.
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
    Because it is shared, some config has to be the one that runs out of it, and
    **which one is not left to fall out of the merge loop**: matching runs
    *innermost-first* and the merge replays the results *outermost-first*. The
    two orders are opposite on purpose. Merging outermost-first is what "a closer
    file wins" means and is not negotiable; draining in that same order would put
    exhaustion on the **closest** file — the one whose answer outranks every
    other — so a quadratic (or merely large) root `.editorconfig` could silently
    starve the `src/foo/.editorconfig` beside the edited file and the walk would
    degrade in exactly the wrong direction, with no diagnostic.
    **Compilation carries a second budget**, `maximumCompileSteps` (8 × the
    length cap), because the length cap bounds it no better than it bounds
    matching: the compiler scans *forward* for each group's closing `}` and each
    class's closing `]`, so a section name of nested openers (`{{{{…`, `[[[[…`)
    is quadratic — ~500 000 character steps for one 1024-character name, and the
    1 MB read cap admits a thousand of them in one file (~0.9 s of main-thread
    work per resolution, and the model caches *resolved properties* rather than
    parsed files, so a watcher callback makes the next keystroke pay it again).
    An over-spend sets `exceedsCompileBudget` and the section matches nothing,
    the same degradation the other two limits give. Per **section** rather than
    per resolution — compilation happens in `init`, which the file parser calls
    with no budget to thread, and the quadratic lives inside one section, so
    bounding each bounds a file at (sections × ceiling) — and every scan is
    charged what it *actually* costs rather than its worst case, since charging
    the worst case would refuse an honest full-length name carrying many sibling
    groups, none of which scans past its own `}`.
    Realistic patterns cost microseconds and are nowhere near it — a
    200-section config spends under 5% of the ceiling — which
    `EditorConfigGlobTests` asserts from both sides. `*`/`**` try every run
    length from the shortest up, stopping at a `/` unless allowed to cross one; an alternation splices
    each branch in front of what follows the group, so a branch that matches but
    leaves the rest unmatchable falls through to the next — and **that splice is
    charged to the budget**, because it copies up to the whole compiled pattern
    per attempt, which a flat one-step-per-attempt count would under-report by
    the pattern's length (a 1 008-character alternation-heavy name spent ~0.6 s
    before it was) — *plus a flat step per attempt on top of the copy*, since an
    empty branch in front of an empty remainder copies nothing and would
    otherwise be free (`{,,,}` closing a pattern was ~0.5 s of uncharged work);
    a numeric range tries
    the longest digit run first and then shorter ones, so `{1..2}0` matches `10`
    while a bare `{1..2}` refuses it — **and each candidate is charged for the
    digits it copies and parses**, because a candidate falling outside the bounds
    never reaches the recursive step that would charge for it, which multiplied
    the whole ceiling by the path's digit-run length (13 s at 200 digits).
    The rule the three share: *every* loop that can iterate without recursing
    charges, or the ceiling is not a ceiling. `EditorConfigGlobCompiler` is the
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
    skipped *and* ends the section above it — the pairs below land nowhere rather
    than in the previous section, so a typo'd `[*.py` cannot hand Python's rules
    to whatever glob happened to be open (and a `root` below it is not a preamble
    declaration either, because the preamble ends at the first `[` line whether
    or not it parsed); a leading **UTF-8 BOM is stripped** before anything else,
    since U+FEFF is not in `CharacterSet.whitespaces` and would otherwise make
    the first line — usually `root = true` or `[*]` — parse as neither a header
    nor a pair; a pair splits at its **first** `=`, so a value may hold as many
    more as it likes; `maximumKeyLength = 1024` and `maximumValueLength = 4096`
    are the caps. `sections(matching:)` returns every matching section in document
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
    **The three on-save accessors sit beside them**, with the same "absent rather
    than an error" posture: `endOfLine` answers the closed `EndOfLine` enum
    (`lf`/`cr`/`crlf`, each carrying as `terminator` the string it names) and
    `nil` for an absent *or* unrecognized value, so one typo in a shared config
    normalizes nothing instead of normalizing wrongly; `trimTrailingWhitespace`
    and `insertFinalNewline` answer `Bool?` — exactly the literals `true` and
    `false`, everything else `nil`. All three keys are in `knownKeys`, so the
    parser has already lowercased their values and the accessors fold no case
    themselves (which also means a property map built directly from strings reads
    exactly as spelled), and `unset` restores the absent answer for each by
    removing the key before any accessor sees it. The enum's vocabulary being
    *closed* is what makes the NEL/LS/PS limit expressible at all: there is no
    `EndOfLine` case for a separator the format does not name, so no code path can
    normalize to one. Unit-tested in `EditorConfigFileTests`, edge case by edge
    case from the official suite.
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
    hint) — behind a lexical `standardizedFileURL.path` fast path, because the
    iOS editor re-states the root from `updateUIView`, i.e. on every keystroke,
    and `CanonicalPath.canonical` is a `readlink` per path component run twice
    per call; only a genuinely different spelling reaches the filesystem. `noteProjectFilesChanged()` clears the cache wholesale rather than
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
    rewrite what typing does. Both take `inferred` as an **autoclosure**,
    evaluated only when the answer depends on it: producing it means
    `IndentEngine.inferIndentUnit(text:)` over a copy of the whole buffer, on the
    main thread, inside a key handler, and a configuration stating both halves
    (`indent_style = tab`, or `space` with an `indent_size`) — the shape this
    feature exists for — needs no inference at all. Tab is where it matters
    most: a key that cost nothing before this layer must not start scanning the
    file to compute a value it discards. `tabInsertionPlan(ranges:insertion:)` replaces
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
  - `SaveTransform.swift` — **what a save rewrites**: the one engine behind the
    exception recorded above, pure and Foundation-only on `NSString` UTF-16
    offsets like every other editor engine here.
    `plan(text:config:protectedPositions:)` answers a `SaveTransformPlan`
    carrying `replacements` (`IndentReplacement` again — a (range, replacement)
    pair is a (range, replacement) pair whichever rule produced it — ascending and
    non-overlapping against the **original** text, so a view applies them
    back-to-front in one bracket) and `text`, the bytes that must reach the disk,
    the buffer and the saved baseline alike. **An empty plan is the answer for
    everything this feature must not touch**: no `.editorconfig`, a configuration
    stating none of the three, or a buffer that already satisfies all of them —
    and `text` is then the input string byte for byte, so a caller may write it
    unconditionally. That case is also the *cheap* one on purpose: the three
    accessors are read first and an all-absent answer returns before the text is
    split at all, because this runs on every ⌘S and every autosave tick of every
    project, almost none of which have a config.
    **The composition, in its stated order.** (1) `end_of_line`: every LF, CR or
    CRLF terminator differing from the target becomes the target — the CRLF pair
    is one terminator, never two edits, which is exactly what
    `TerminatedLineRange` hands over; NEL, LS and PS are left alone (the stated
    limit); absent or unrecognized normalizes nothing. (2)
    `trim_trailing_whitespace = true`: the trailing run of spaces and tabs before
    each terminator and at end of file is deleted, except on a spared line — and
    *only* spaces and tabs, so a separator the property does not name is content
    as far as trimming is concerned. (3) `insert_final_newline = true`: a file not
    ending in a terminator gains exactly one — the configured `end_of_line` when
    set, otherwise **the file's own last terminator when that is one of the three
    `end_of_line` names** (which is what keeps a CRLF file stating no
    `end_of_line` from gaining a lone LF), otherwise LF; `false`
    or absent does nothing, an existing final terminator is never doubled and
    never removed, an empty buffer stays empty (there is no line to terminate),
    and a last line that trimming empties gains nothing either, because the line
    above already terminates the text — **measured against the trim the
    configuration asks for, not the one this caret position allowed**. Reading the
    spared answer instead would make the appended terminator depend on where the
    caret happened to be at an autosave tick: a whitespace-only last line under the
    caret would be terminated, the next save (caret moved away) would trim the
    whitespace it just terminated, and the file would keep a blank line nobody
    typed — a fixed point *different* from the one the same buffer reaches with the
    caret anywhere else. Sparing defers a trim; it never changes what the file
    should end up being. The order is what step 3 *reads*, not the
    order edits are applied in: per line the trim (inside the content) precedes
    the terminator edit (immediately after it), so appending in line order already
    yields the ascending, non-overlapping list the contract promises.
    **The spared lines** come from `protectedPositions`, UTF-16 offsets the caller
    passes — the caret and both endpoints of every selected range when the buffer
    is open in an editor, nothing at all when it is not. A position sits on the
    line whose *enclosing* range (content and terminator together) contains it, so
    a caret parked at the end of a line's content — the case the rule exists for —
    spares that line rather than the next, and a caret at column zero spares only
    its own line. **The end of the text is two different places**, and the last
    terminator is what tells them apart: in an unterminated file the last line
    *is* where that caret sits, so it is spared; in a file ending in a terminator
    the caret is on the empty line *after* the last line `TerminatedLines` emits
    (it emits no phantom final line), so nothing is spared at all. Sparing the
    preceding line there would protect a run on a line the caret has already
    left — and, worse, one the deferral below could never make good on, since the
    caret never moves off a position it is already past: the buffer would owe that
    trim on every autosave tick for as long as the caret rested there. The lookup
    is a binary search over those enclosing ranges, which tile the text with no
    gaps; the one offset they do not cover — the end — is answered ahead of the
    search, because its two answers come from the terminator rather than from any
    range comparison.
    **Sparing is a deferral, and the deferral is reported.** A plan that left a
    run standing on a spared line says so through `deferredTrim`, and that flag
    is the only thing that can distinguish "already conforming" from "owes a
    trim": both answer an empty plan. Without it the rule's own promise — *the
    next save after the caret leaves trims it* — is false for the commonest flow
    there is: type, pause, let the idle autosave write, never touch the file
    again. The tab is clean after that write and moving the caret does not dirty
    it, so `saveAllDirty()` never looks at it a second time and the run stays on
    disk for good. Deliberately *not* "there were protected positions": a caret on
    a line with nothing to trim owes nothing, and re-offering every such buffer
    would put a whole-file scan per open tab on the main thread on every tick.
    **A buffer being abandoned is trimmed in full**, because it passes no
    protected positions at all: the close prompt's Save, the quit flush and the
    folder-switch flush all write a file that has no next save to defer to. That
    holds on **every** branch of those paths, including the one that changes
    method: the close prompt's Save on an *untitled* buffer answers `.needsSaveAs`
    and continues into `saveAs`, so `abandoningBuffer` is threaded through it into
    `prepareForSaveAs(id:destination:protectingCaret:)` — the tab closes on the
    next statement, and the owed set is pruned to open files, so a deferral made
    there would have nowhere to come true. It holds on the branch that changes
    *path*, too: when the live view refuses the rewrite (an IME composition in
    flight, a declined `shouldChangeText`), an abandoning save does not re-arm the
    owed set the way an ordinary one does — there is no later save to settle it —
    but rewrites through `WorkspaceModel.replaceText(_:for:)` instead, the same
    path a background tab takes, so the transformed bytes still reach disk. The
    undo stack and viewport that costs belong to a buffer about to be destroyed,
    which is the same reasoning by which abandonment settles an owed trim whether
    or not a view still holds it. Both quit observers pass it too, for
    the same reason stated one level up in `app-shell.md`. The
    commit dialog's flush keeps protecting — editing continues after it, so the
    caret still has a line to protect, and the owed set means the trim is not
    lost.
    **`rewrites(under:)`** is the same three-property question the plan's own
    early-out asks, exposed because a caller has to ask it *before* it can call
    `plan` at all: the macOS funnel's next step is reading `NSTextView.string`,
    which materializes a copy of the whole buffer, and paying that on every ⌘S
    and every autosave tick of every project without an `.editorconfig` is
    precisely the cost this feature promised not to add. Safe as a pre-filter
    because `protectedPositions` can only *remove* edits.
    **The remap arithmetic lives here and nowhere else**, so the caret, each
    selection endpoint and the scroll anchor all move by the same three rules:
    an offset at or before an edit's start is unchanged by it (at the start counts
    as *before* — the only insertion this engine emits is at end of file, and
    treating the caret as after it would push the reader onto a newly created
    empty line for no reason); an offset at or after an edit's end shifts by that
    edit's net length; and an offset **inside** an edit is defined explicitly
    rather than left to chance — it keeps its distance from the edit's start, up
    to the replacement's own length, so a trimmed run collapses to where it began
    and an offset between a CR and its LF lands at the end of what replaced the
    pair. `NSNotFound` and negatives are returned untouched: they name no
    position, and inventing one would turn "no selection" into a caret somewhere.
    `remappedRange` maps a range through its two ends, the only definition that
    stays correct when an edit falls *inside* the selection. There is deliberately
    no whole-`EditorViewport` convenience: the editor's column selection is
    *several* ranges, which one viewport cannot carry, so the view remaps each
    selected range through `remappedRange` and the scroll anchor through
    `remappedOffset` — which is precisely what it restores after applying the plan.
    Which offsets a selection *contributes* is this engine's decision too:
    `protectedPositions(forSelectedRanges:)` takes the whole `selectedRanges`
    array — a bare caret gives its location, a selection gives both endpoints,
    every range of a column selection counts — leaving the view layer with nothing
    but the unwrap of AppKit's `[NSValue]`.
    **Idempotence** falls out of the three rules and is asserted rather than
    assumed: the plan for an already-transformed text is empty, so a second save
    of an untouched buffer writes the same bytes and moves nothing.
    Unit-tested in `SaveTransformTests` (the acceptance list) and, end to end over
    `WorkspaceModel`, in `SaveTransformIntegrationTests`.
  - `TerminatedLines.swift` — **the single line splitter**, documented in full in
    `core-diff-merge.md`; what part 2 added is the level below it.
    `TerminatedLineRange` is one line as a pair of ranges (`content`,
    `terminator`, plus `enclosing` for the two together, with the CRLF pair kept
    as one range of length two and an empty terminator located at the end of the
    content for an unterminated final line), and `ranges(_:)` is the traversal
    that produces them. `split(_:)` became a **projection** of it — the offsets
    are computed once and the substrings only read from them — because the save
    transform *edits* text and would otherwise have to re-derive offsets by
    measuring the substrings it was handed, which is a second definition of what a
    line is by another name. The file's whole doc comment rests on there being one
    traversal that decides where a line ends; making `ranges(_:)` the primitive
    keeps that invariant **structural** rather than coincidental, exactly as
    `LineDiff.splitLines` being `split(text).map(\.content)` does one level up.
    `TerminatedLinesTests` fuzzes the projection against `split(_:)` for the same
    reason the older fuzz test exists: as a lock against a second implementation
    coming back.

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
    the app's own worktree rewrites (a revert's in-process `unlinkat`, merge
    apply, project-wide Replace All, a tree rename or delete). A **branch switch
    is not among them on macOS**: `git` runs there as a subprocess, so
    `IgnoreSelf` does not drop its events and the watcher is what covers it —
    which is why `finishBranchOperation` calls nothing. The iOS peer in
    `RootView_iOS` makes the same call for the same reasons *and* has to cover
    the branch switch, since libgit2 runs in-process; and `noteEditorConfigWrites(_:)` covers the *save* paths
    that funnel deliberately does not (`save(id:)` and the autosave's `onSaved`,
    which was widened to report the urls it wrote), because editing a
    `.editorconfig` in Pisaka itself is the likeliest way anyone changes one and is
    a self-write the watcher never sees. That last one is narrow on purpose — it
    fires only when a written url *is* a `.editorconfig` — since an ordinary save
    is the app's most frequent write and clearing on each would put a resolution
    walk on the next keystroke after every autosave burst. Both platforms ask
    `EditorConfigResolver.isFileName(_:)`, which **folds case**, because the
    resolver's own lookup does not compare at all: it appends the name to a
    directory and lets the filesystem answer, and default APFS answers with a
    `.EditorConfig` a Windows-authored repository carries. An exact comparison
    would read such a file and never notice a write to it — the stale cache these
    helpers exist to prevent — so the rule lives in Core beside the name rather
    than being restated per platform.
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
    **asks the rule rather than restating it**: whether Tab inserts spaces at all
    is `IndentUnitRule.tabInsertion`'s decision, and the handler reads only its
    answer. Pre-checking `indentStyle == .space` in the view would put half of
    that decision in the view layer and buy nothing, because the rule's
    `inferred:` **autoclosure** already makes the answer free in every case but
    one: `textView.string` bridges a mutable `NSTextStorage` and copies the whole
    buffer, and `inferIndentUnit` then walks every line of that copy — the
    main-thread cost `textDidChange` is careful to avoid — and neither the
    no-configuration case nor a fully-stated `indent_style = space` +
    `indent_size` ever evaluates it. Only spaces of an unstated width read the
    buffer, to carry the file's own width over. The iOS coordinator asks it the
    same way. `scrollRangeToVisible` is called
    explicitly on the first caret afterwards: it is the one thing
    `insertText(_:replacementRange:)` does for every other programmatic edit here
    that neither `setSelectedRanges` nor `didChangeText()` does, and without it
    Tab under `indent_style = space` would type into a scrolled-away caret while
    a literal tab — the same key, one property apart — jumps back to it. The
    first caret is what `selectedRange()` reports for a multi-range selection,
    and so what the native key scrolls to. The existing
    `isApplyingProgrammaticEdit` guard covers the *whole* bracket, not just the
    storage mutation, because the single-range case reaches the single-range
    delegate callback where the auto-pair interceptor lives. `insertBacktab` is
    untouched. Enter's handler is unchanged except for the two values it reads
    from the configuration: its `unit` comes from
    `IndentUnitRule.unit(config:inferred:)` instead of the bare inference, asked
    through one private helper so Enter and Tab can never disagree about the unit
    — they differ only in *whether* it is used — and its `terminator:` comes from
    `endOfLine?.terminator ?? "\n"` through a second one-line helper, so a
    project stating `end_of_line = crlf` types the terminator its saves normalize
    to, and a project stating nothing splices an LF byte for byte as before.
    `IndentEngine.newlineIndentation` takes that terminator as a defaulted
    parameter and measures its real UTF-16 length for the returned cursor offset
    and the between-brackets split, so a two-unit terminator puts the caret
    exactly where a one-unit one does. The iOS Return handler asks the same two
    questions the same way.
  - **The save funnel (macOS).** `SaveTransformController` is the one place every
    macOS save passes through before it writes, shaped like
    `EditorSearchController` for the same reasons: owned by `PisakaApp` for the
    app's whole lifetime, `attach(textView:editor:)`ed from `CodeEditorView
    .makeNSView`, holding the text view and the editor seam **weakly** (a torn-down
    editor is the ordinary state of a background tab, not a degraded one), with
    `start(model:editorConfig:onBufferReplaced:)` binding the two models once so
    each call site stays a single line. **The three-property question is asked
    before anything is read** (`SaveTransform.rewrites(under:)`), and that order is
    load-bearing rather than tidy: the next step reads `NSTextView.string`, which
    materializes a fresh copy of the whole buffer, so asking second would put two
    full-buffer traversals on the main thread at every ⌘S and every autosave tick
    of every project that states none of the three — the case this feature promised
    to cost nothing. **It also carries the one piece of state the feature needs**:
    `owedTrims`, the buffers whose last save left a run standing on a spared line.
    `prepareForAutosave(ids:abandoningBuffers:)` re-offers exactly that set
    alongside the dirty ids, which is what makes sparing a deferral rather than a
    silent exemption — after the spared write the tab is clean and moving the caret
    does not dirty it, so nothing else would ever offer that buffer a second save.
    `prepareForSave(ids:)` deliberately does **not** union: ⌘S names one file and
    must rewrite that file alone, since transforming a second tab would dirty a
    buffer the keystroke is not going to write. The set is maintained on every
    save — inserted on `plan.deferredTrim`, removed otherwise, **and re-inserted
    when the view refuses the rewrite** (`apply` answering `false`: a composition
    in progress, a declined `shouldChangeText`), because a save that changed
    nothing still owes everything it was going to change — with the one exception
    of a save that is *abandoning* the buffer, which has no later save to owe it
    to and therefore settles the refusal through the model on the spot — so a
    buffer drops
    out the moment it is trimmed, its configuration stops asking, or it is saved
    with no caret to protect, and it is intersected with the open tabs so a closed
    file leaves nothing behind. **An owed trim is settled through the editor, or
    not yet.** The buffer that owes one is, overwhelmingly, the tab the user just
    left — the tab-switch autosave spares the caret's line while that file is
    still displayed, and `saveAllDirty()` republishes `$openFiles`, so the idle
    tick two seconds later re-offers it with the *new* tab on screen. Settling it
    then would take the through-the-model path below and cost that tab its undo
    stack and its remembered scroll position, for a whitespace trim nobody asked
    for; that cost is stated for a background tab an autosave happens to catch,
    and paying it on every tab switch is a different thing. So the re-offer is
    filtered to buffers a live view still holds: an owed buffer waits for a save
    that can reach it through its view (the user comes back and types) and stays
    owed meanwhile. **Abandonment settles it regardless** — the quit flush, the
    folder switch's second (post-refusal) flush and the close prompt are about to
    destroy every undo stack and every viewport there is, so nothing is left for
    waiting to protect and the trim would otherwise never happen at all. **The one
    place an owed trim is dropped rather than settled is closing a tab that is
    already clean**: the spared write left it clean, so `WorkspaceModel.close`
    takes the no-prompt branch and there is no save at all to settle it on — and
    inventing one would be this feature writing a file outside a save, which is the
    line it does not cross. The intersection with the open tabs then forgets the
    id, and the run stands on disk until that file is edited and saved again. Said
    in `docs/FEATURES.md` too, where the promise is made. **It decides nothing the engine decides**: properties come
    from the same `EditorConfigModel` Enter and Tab ask, the plan comes from
    `SaveTransform`, and this class owns only the AppKit half — which buffer is on
    screen, the undo-coalescing bracket, the selection and the scroll anchor.
    `SaveTransformEditor` is that AppKit half stated as a tiny protocol the
    `CodeEditorView.Coordinator` conforms to, rather than a bag of closures,
    because every member is a question the coordinator already answers for its own
    paths. `displayedFileID` is **read, never cached**: the tab-switch autosave
    fires from `WorkspaceModel.$selectedID` *before* `updateNSView` swaps the
    buffer, so at that moment it still names the outgoing file — which is exactly
    the buffer being saved and the one the transform must reach through the view.
    **Two application paths, and the model picks between them.** A buffer the
    editor still holds *and whose text the view still agrees with* is rewritten
    through the text view, in `insertConfiguredTab`'s bracket — `shouldChangeText`
    / `beginEditing`…`endEditing` / `didChangeText`, edits applied back-to-front,
    wrapped in a `breakUndoCoalescing()` on **each** side (a save is not typing:
    `NSTextView` would otherwise register the rewrite into whichever typing action
    is open, so an autosave inserting the final newline right after the user typed
    at end of file would ride along in the typing action and the ⌘Z meant to
    restore the pre-save buffer would take the typed run with it — the break
    before is what starts the save's own action, the break after is what stops the
    next keystroke joining it, and single-edit plans are exactly the ones that
    need both, since a multi-range plan breaks coalescing incidentally),
    replacements carrying `typingAttributes` explicitly (the raw storage path
    would otherwise inherit whatever the adjacent text has, and in a buffer with no
    adjacent text, no font at all) — **or, when applying them one by one
    would cost more than replacing the span they cover, as the single replacement
    covering it** (`SaveTransformPlan.applicableReplacements(originalLength:)`,
    the engine's own arithmetic rather than the view layer's: every
    `replaceCharacters` shifts
    everything after it, so one edit per line makes a whole-file `end_of_line`
    normalization quadratic — a multi-second main-thread freeze on the first save
    of a large CRLF buffer, the same shape `applied(_:to:)` refuses in Core; both
    costs are measured and the smaller wins, so a two-line trim at opposite ends of
    a big file stays two edits and `endEditing` coalesces the edited ranges into
    one either way. The collapsed span's end is the run's **summed net length**,
    never `remappedOffset` — that answers where a *position* lands and counts an
    offset at an edit's start as before it, which is right for a caret facing the
    final newline the engine may insert at end of file and wrong for a span that
    has to contain that insertion: reading it there dropped the inserted
    terminator, saving a file without the final newline its configuration asked
    for and leaving the buffer clean so nothing came back for it) — so the whole
    save is one undoable step (a
    single ⌘Z restores the pre-save buffer), one change notification, and every
    observer (Neon, the gutter, the minimap, the brackets, the symbol index and,
    through `reindexSymbols`, the LSP push sync) sees an ordinary edit. The
    selection and the anchor are put back from the engine's remap, and
    `scrollRangeToVisible` is deliberately **not** called: every other programmatic
    edit here is something the user just asked for, so jumping to the caret is
    right; a save is not, and an autosave is not even a keystroke — the page stays
    where the reader left it, which (because the transform can delete characters
    *above* the viewport) means putting the remapped anchor back at the top rather
    than doing nothing. A **marked range** refuses the whole path: this mutates
    `textStorage` directly, which is exactly the bookkeeping a composition depends
    on, so mid-composition the save writes the untransformed bytes and the next
    save — a keystroke later — transforms them. A buffer the editor no longer
    holds goes through `WorkspaceModel.replaceText(_:for:)` instead, which bumps
    that tab's text-replacement revision and therefore **drops its undo stack and
    remembered viewport** when it is next displayed, exactly as every other
    off-screen rewrite does (Replace All, a revert, a merge apply). Known and
    bounded, and said in the doc comment rather than left to be discovered: it
    costs undo history for a tab nobody is looking at, on a save the project's own
    configuration asked to rewrite. That path additionally reports the rewrite
    through `onBufferReplaced`, bound to `PisakaApp.reindexReloadedBuffer(id:url:)`
    — the resync every other off-screen rewrite already funnels through. It is not
    optional bookkeeping: no change notification fires, and a buffer-sourced index
    entry is *skipped* by every disk refresh (`SymbolIndexModel`), so without it
    the pre-transform declarations, their pre-transform offsets and the document's
    stale diagnostics would stand until that tab happened to be displayed again.
    Save As passes no url on purpose: an untitled buffer has never been indexed
    under any path, and `saveAs`'s own `notifyIndexOfProjectFileChanges()` picks
    the written file up from disk. **A shown buffer whose view has not caught up
    takes the off-screen path too**, and that comparison is not defensive: a
    model-side rewrite (Replace All, a revert, a merge apply, a reload) lands in
    the model first and reaches the view on SwiftUI's next update pass, while
    every one of those writers replays a deferred autosave *synchronously* from
    its own `defer { autosave.resume() }` — inside that very window. Reading the
    view there would transform text the model had already replaced and push it
    back through `didChangeText`, silently undoing the rewrite in that tab and
    then writing the undone result to disk. The model is authoritative whenever
    the two differ, exactly as `updateNSView`'s content-replaced branch decides
    it.
    **The two guards.** `beginSaveTransformRewrite()` raises
    `isApplyingProgrammaticEdit` *and* `isSwappingBuffer` before the edit is even
    proposed (`shouldChangeText` re-enters the delegate's own interceptors);
    `resetIncrementalReadersForSaveTransform()` then drops the blame column and
    clears this document's diagnostics, and is deliberately a *second* call made
    only once the edit is known to be permitted — a refused `shouldChangeText`
    changes no text, and discarding both readers for a rewrite that never
    happened would leave the gutter and the underlines empty with no edit to
    re-publish them. The reason they are dropped at all is that `endEditing`
    coalesces the several small replacements into **one** edited range — for a
    whole-file terminator normalization, the whole buffer — which is the
    buffer-swap case in everything but name, so it takes the buffer-swap treatment
    rather than letting the incremental blame and diagnostic shifters run across a
    file-wide replacement. Neither reader stays empty: the push sync that
    `textDidChange` schedules re-publishes the diagnostics, and blame reloads on
    the update pass the save's own `diskRevision` bump guarantees.
    `invalidateDiagnosticPaint()` is deliberately *not* called, unlike on a real
    swap: no `textView.string` assignment happened, so the temporary attributes are
    still painted and forgetting the cache would leave stale underlines behind.
    **The call sites, and only these.** `PisakaApp.save(id:)` — after the
    writer-gate refusal and before the write, so ⌘S, the close prompt's Save and
    the `runFile`/`testFile` pre-run saves all inherit it without a second site,
    and a refused save transforms nothing; `saveAs(id:)`, once the panel has been
    answered, because only then is there a path to resolve against and it is the
    *destination's* configuration that applies; and `AutosaveController`, on the
    regular triggers and on both flush paths, wired as an **injected closure** so
    that controller keeps holding no policy. The two callers choose their id sets
    differently on purpose: ⌘S passes the one file it names, dirty or not, because
    that keystroke writes it either way, while autosave passes only the dirty
    titled buffers `saveAllDirty()` will actually write — transforming a clean
    background tab would make it dirty and put a file nobody edited into the next
    commit. Nothing else calls it: not open, not close, not a tab switch on its
    own, not an `.editorconfig` change, and not the worktree writers.
    **A save is no longer this class's only caller**, though it is still its only
    *transform*: there are now **two** non-save callers, and they share one body.
    `applyRestore(_:to:)` is Local History's restore (`core-local-history.md`) and
    `applyRename(_:to:)` is the buffer half of the seventh gated worktree operation
    (`core-lsp.md`'s `RenameEditPlan` entry); both route through one private
    `applyExternalRewrite(_:to:in:current:)`, because the *choice* between the
    live-text-view path (one undoable step) and `WorkspaceModel.replaceText` (undo
    stack lost) is the decision, and two spellings of it is how the off-screen half
    would stop telling its readers. Both live here rather than in the history window
    or the rename command because copying that AppKit bracket into a second file is
    how the copies would drift.
    `applyRename` **decides nothing**: the plan is `RenameFilePlan.applied(to:)`'s,
    already ascending, non-overlapping and expressed against the text this buffer is
    being asked to hold, and whether the buffer is still that text was settled by
    `RenameEditPlan.apply` — which verified every file before producing any plan, in
    the same main-actor turn, with no `await` between for anything to change in. Its
    one guard is the no-op guard `applyRestore` also makes (a buffer that already
    holds the result is left alone, so a clean tab is not dirtied for no change),
    and it is *not* a staleness check: a second one here would need the plan's
    *input* text, which a `SaveTransformPlan` does not carry. It builds a single whole-buffer `SaveTransformPlan` by hand (`init` is
    public) and runs it through the very same private bracket, so a restored
    revision is one undoable step with one change notification, exactly as a save
    transform is — and it gets the position remap for free, which for a
    whole-buffer replacement clamps the caret, every selection endpoint and the
    scroll anchor into the new text instead of leaving an offset past its end. It
    is **not a save**: it computes no plan from an `.editorconfig`, reads no
    properties, writes no disk and leaves the tab dirty for the ordinary save
    funnel to settle. Two consequences follow from that. `owedTrims` is
    deliberately left alone — what a save owes is recomputed by the next save from
    the buffer as it then stands, and this is not one. And the through-the-model
    fallback is the *usual* path here rather than the exception, because restoring
    a file with no open tab opens one first and SwiftUI has not yet built its
    editor when this runs; it costs that fresh tab an undo stack it never had, and
    reports through `onBufferReplaced` like every other off-screen rewrite (a
    restore always has a url, since the store is keyed by one). A restore whose
    text the buffer already holds does nothing: `LocalHistoryBrowserModel
    .restore(currentText:)` refuses that case before it becomes a plan, and it is
    re-checked here because this method is reachable with any text and rewriting a
    buffer with itself would dirty a clean tab for no change — compared as
    `NSString` for `prepare`'s reason, since canonical equivalence would call a
    decomposed and a precomposed spelling equal and skip a restore that does change
    bytes.
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
    call is idempotent for an unchanged root, so doing it every update throws no
    cache away — and costs a *string* comparison, not a canonicalization, which
    is what `EditorConfigModel.isSameRoot`'s lexical fast path is there for: this
    is the per-keystroke caller. `notifyIndexOfProjectFileChanges()`
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
    caret lands is asked once, in Core, rather than restated per platform. The
    Return handler passes `newlineTerminator()` beside the unit it already
    resolves, the macOS peer's one-liner over `endOfLine`; the dedent and
    auto-pair behavior around it is untouched.
  - **The iOS save.** iOS has exactly **one** save — the close confirmation's
    **Save** button — so it has no controller: `RootView_iOS.applySaveTransform
    (to:)` is the whole app half, and it is the same three-step chain (resolve
    through the `EditorConfigModel` this screen already holds, ask
    `SaveTransform`, rewrite) called immediately before `model.save(for:)`, so
    what reaches the disk is what the configuration asked for. It rewrites through
    `WorkspaceModel.replaceText(_:for:)` unconditionally rather than through the
    text view, and that costs nothing here: the tab is closed on the very next
    line, so there is no undo stack or remembered viewport left to drop.
    **No protected positions are passed**, and that is a decision rather than an
    omission: the macOS funnel spares the caret's line because its autosave is
    aggressive enough to trim indentation out from under someone mid-thought,
    while iOS has no autosave at all and this buffer is being *closed* — there is
    no caret left to protect, so the file is trimmed in full. An empty plan
    returns having touched nothing, exactly as on macOS.

## Test inventory

Every acceptance case has a named test, all in `Tests/PisakaCoreTests/` and all
over in-memory trees (no committed `.editorconfig`):

  - `EditorConfigGlobTests` — each construct separately: `*` vs. `/`, `**`
    across directories and inside a component, `?`, classes and negated classes,
    literal brace groups, nested braces, numeric ranges (negatives included, a
    non-integer refused), escapes, the 1024-character boundary accepted at the
    limit and ignored beyond it, and the "no slash ⇒ any depth" vs. "slash ⇒
    anchored" split. Plus the budget from six sides, each asserted on a wall
    clock because a bound on work is the only honest way to state one: the
    wildcard-heavy pathological name, the alternation-heavy one (the shape a flat
    step count under-reports), a name ending in empty alternation branches and a
    numeric range against a long digit run (the two shapes a *length*-derived
    charge under-reports), fifty copies of one of them in a single file (the
    per-pair-vs-per-resolution scope), and a 200-section but honest config
    spending under half the ceiling while every matching section still answers.
  - `SaveTransformTests` — the acceptance list, engine-level: trimming with
    spaces, tabs and mixed runs (a whitespace-only line, the unterminated last
    line, a buffer trimmed on every line); the spared line from six sides (a
    caret at end of content, at column zero, at end of an unterminated file, at
    end of a *terminated* file — which spares nothing — both endpoints of a
    selection, and the same buffer trimmed once the caret has moved away), that
    sparing is trimming's alone, and that no protected positions trims in full;
    the final newline in each terminator flavor, taken from the file's own when no
    `end_of_line` states one and LF when the file's own is one of the unnamed
    three, never doubled, never removed, absent under `false`
    and unset, an empty buffer untouched, and the two last-line interactions with
    trimming; each of the three `end_of_line` targets against pure-LF, pure-CRLF,
    pure-CR and mixed files, the CRLF pair as one terminator, an unrecognized
    value normalizing nothing, and NEL/LS/PS surviving every combination; the
    three composing in the stated order; the remap across shrinking and growing
    edits with offsets before, inside and after each site and at end of file,
    ranges through their two ends, the selection-and-anchor pair the funnel really
    remaps, an absent selection not invented a position, an empty plan mapping
    every position to itself, and a composed case whose every offset is an
    astral-plane surrogate pair (the one input class that tells UTF-16 arithmetic
    apart from `Character` arithmetic); what a caret, a selection and a column
    selection each contribute as protected positions, and that `NSNotFound`, a
    negative and an offset past the end spare no line they should not; the
    idempotence check (the plan for the transformed text is empty); and the
    no-configuration pins — an empty map, a map of only part 1's indentation
    properties, the three set to `false`/unrecognized, and an empty buffer — each
    producing an empty plan and a byte-identical text.
  - `SaveTransformIntegrationTests` — the same chain end to end over
    `WorkspaceModel` + `EditorConfigModel` + `StubFileTree` with a real
    `.editorconfig` tree, since the view layers themselves are untested by
    convention: a transformed save leaves the tab **clean** with the buffer, the
    saved baseline and the written bytes identical; the second save writes nothing
    new; the remapped selection and anchor are the engine's; the caret's line
    survives one save and is trimmed by the next after the caret moves; a buffer
    with no protected positions (the iOS shape) is trimmed in full; an autosave
    tick transforms and writes every dirty titled buffer; the iOS save writes what
    the configuration asked and, without one, the buffer byte for byte; a
    Return-spliced terminator survives the next save untouched; a file outside the
    configured section is not transformed; ⌘S transforms a **clean, unedited**
    buffer (the counterpart of the autosave case, which must not touch one); Save
    As resolves the **destination's** configuration against a leaf that does not
    exist on disk yet, writes the buffer byte for byte into a folder no
    configuration covers, and refuses a destination another tab already owns
    *before* anything is rewritten; and — the regression that matters most — a
    project with no `.editorconfig` writes byte-identical bytes and moves exactly
    the revision tokens it moved before this feature existed.
  - `EditorConfigFileTests` — whole-line `#` and `;` comments (leading
    whitespace included), a `;`/`#` kept verbatim inside a value (the spec's own
    `foo = a ;)`), whitespace around keys and values, a value containing `=`, the
    key and value length caps at and beyond the floor, a header with no closing
    bracket, a `root = true` after the first section ignored, key and known-value
    case-insensitivity, and every accessor including the `indent_size = tab` →
    `tab_width` coupling and the rejection of `0`/negative/non-numeric sizes —
    plus the three on-save ones: each `end_of_line` value with the terminator it
    names, both booleans against their two literals, all three `nil` for an absent
    or unrecognized value, all three read case-insensitively through the parser,
    `unset` restoring the absent answer for each, and an empty map stating none of
    them.
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
