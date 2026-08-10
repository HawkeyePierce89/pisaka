# Fix the three findings from the Rust acceptance review

## Overview

Three closing fixes before 1.0, no feature work. One is a real bug —
`LSPInstallLayout`'s containment predicate stats the disk through
`standardizedFileURL` and therefore answers *false* for a correct install under a
`/private`-spelled root — and it is fixed by making the layout's path math
lexical by its own code, which is what its doc comment has claimed all along. The
second is display-only: tsserver's member items carry a `textEdit` that covers
the typed dot, and since the popup shows the *inserted* text every row under
`greeter.` reads `.greet`. It is fixed by distinguishing the shown string from
the inserted one at the `CodeIntelligenceProviding` seam, under a rule that keeps
the two interchangeable everywhere AppKit inserts the shown string itself. The
third is three stale `#eq?` comments.

Everything not named here must be byte-identical, and in particular **what the
edits insert does not change in any path**.

### Finding 1 — why `standardizedFileURL` has to go

`URL.standardizedFileURL` is documented as lexical and is not: for a path under
`/private/tmp`, `/private/var` or `/private/etc` it strips the `/private` prefix
**when the shortened path exists on disk**. Confirmed on this machine:

```
/private/tmp                    -> /tmp                            (exists → stripped)
/private/tmp/absent-child-xyz   -> /private/tmp/absent-child-xyz   (absent → kept)
/tmp/servers/./node/..          -> /tmp/servers
/../x                           -> /x
```

That is the live failure exactly: `verifyUnpackTarget` asks containment of a
staging directory it has just *created* (so the shortened spelling exists, and it
standardises to `/tmp/…`) against a destination inside it that does not exist yet
(so it stays `/private/tmp/…`) — two spellings of one tree that compare as
unrelated, and the install fails with `unpackFailed` / "is not inside this
install". It is unreachable with the shipped Application Support root and
reachable with any `/private`-spelled one.

The fix is component-wise comparison over lexically-normalised components: split
on `/`, drop empties and `.`, resolve `..` against what precedes it, clamp at the
root, never stat, never follow a symlink. Components rather than string prefixing
so `/a/bc` inside `/a/b` stays unrepresentable rather than merely tested against.
The cost is the documented limit: `/tmp/x` and `/private/tmp/x` compare as
*different* directories. That is safe for a predicate guarding deletes (it can
only ever refuse), and no caller can trip it — the engine derives root and
candidate from one `base`.

This is the same rule `CanonicalPath.relativeComponents(of:under:)` applies to
*canonical* components; it is restated here over lexical ones precisely because
this file may not touch the disk, and the two must not be unified.

### Finding 2 — the rule that makes a display string safe

The popup string is not only shown. AppKit writes it over the typed word as a
preview while the user arrows (`insertCompletion(…, isFinal: false)`), and it
inserts it there itself whenever `CompletionEditPlan.make` rejects the plan as
stale. So the display may differ from the inserted text **only by dropping a head
that re-writes, verbatim, characters already standing in the buffer between the
primary edit's start and the typed word's start.** Under that rule the preview
and the fallback both compose exactly the buffer the plan would have:

- tsserver, `greeter.` with an empty prefix: `textEdit` = `{dot, 1}` →
  `".greet"`. The gap `[dot, typedWord.location)` holds `"."`, and `".greet"`
  starts with `"."`, so the row reads `greet`. Preview → `greeter.greet`; plan →
  `greeter.greet`; fallback → `greeter.greet`. (Today's fallback for this shape
  writes `greeter..greet`, so the fix makes the rejected-plan path correct rather
  than merely prettier.)
- `?.` on an optional receiver — same range `{dot, 1}`, newText `"?.greet"`: the
  head `"?"` is *not* what stands in the buffer, so nothing is dropped and the
  row reads `?.greet`. Showing the rewrite is the honest display.
- sourcekit-lsp members (`completion-member.json`): zero-length `textEdit` at the
  caret, no gap, so display *is* the inserted text, unchanged.

The LSP `label` is never displayed: `greet(name: String)` inserted by the
fallback path would corrupt the buffer.

Because AppKit hands a committed row back **by string**, the display string also
becomes the key the controller finds the item and its prefetched resolve under,
in all three paths (commit, preview, late-resolve follow-up).

## Context

- Files involved:
  - `Sources/PisakaCore/LSPInstallLayout.swift` — `init(base:)` and
    `directory(_:contains:)`; the only two members that normalise a path.
  - `Sources/PisakaCore/CodeIntelligence.swift` — `CompletionItem`, the seam
    value.
  - `Sources/PisakaCore/CompletionEditPlan.swift` — home of the "how an edit
    composes with the typed word" arithmetic
    (`shifted(afterReplacingTypedWord:withLength:)`), and so the home of the new
    display rule.
  - `Sources/PisakaCore/LSPIntelligenceProvider.swift` — `publish(…)` /
    `edits(for:…)`, the one place a dot-covering `textEdit` is turned into a seam
    value.
  - `Sources/Pisaka/CompletionController.swift` — the macOS popup's snapshot, its
    `resolved`/`resolveTasks` tables and `scheduleFollowUp`, all keyed by item
    text today.
  - `Tests/PisakaCoreTests/LSPInstallLayoutTests.swift`,
    `Tests/PisakaCoreTests/CompletionEditPlanTests.swift`,
    `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`.
  - `Tests/PisakaCoreTests/Support/QueryScanner.swift:61`,
    `Tests/PisakaCoreTests/SymbolQueryTests.swift:138,157` — the stale comments.
  - `docs/architecture/core-provisioning.md`, `core-intelligence.md`,
    `core-lsp.md`, `app-editor.md`.
- Related patterns: component-wise containment
  (`CanonicalPath.relativeComponents`); defaulted seam fields added by a phase
  without touching older call sites (`CompletionItem.edits`/`resolveHandle`,
  `CompletionRequest.language`/`member`); pure rule in Core + thin untested glue
  in `Sources/Pisaka`.
- Dependencies: none. No new files, so no new `CLAUDE.md` index line; no
  manifest, pin, license or query change, so the static repository suites are
  untouched.
- Deliberately unchanged: `verifyUnpackTarget` and `mayDelete` (correct consumers
  of the fixed predicate — `mayDelete`'s root comparison keeps working because
  both sides are derived from one `base` and spelled identically), all ranking,
  everything the edits insert, and both iOS surfaces (no LSP provider there, so
  `displayText == text`).

## Development Approach

- **Testing approach**: TDD for both Core rules — the lexical containment
  predicate and the display-spelling rule are the deliverable, and each has a
  test that fails before the fix. Regular (no tests) for `CompletionController`,
  which is untested view-layer glue by convention; its gate is the macOS build
  plus the reasoning written into its doc comment.
- Complete each task fully — code, tests, green `swift test` — before the next.
- Core stays Foundation-only; comment density matches the surrounding files
  (these carry their reasoning, not their mechanics).
- Existing assertions are *extended*, never weakened: `LSPInstallLayoutTests`'
  negative cases and `LSPInstallEngineTests` must pass unchanged.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Make the install layout's path math lexical

**Files:**
- Modify: `Sources/PisakaCore/LSPInstallLayout.swift`
- Modify: `Tests/PisakaCoreTests/LSPInstallLayoutTests.swift`

- [x] write the failing tests first: with root `/private/tmp` (exists on every
      macOS) and an absent child spelled the same way — the shape
      `verifyUnpackTarget` asks, e.g.
      `directory(URL("/private/tmp"), contains: URL("/private/tmp/<absent>/node_modules/typescript"))`
      — assert `true`; assert the mixed-spelling pair `false` in **both**
      directions with a comment naming it as the documented lexical limit; assert
      `LSPInstallLayout(base: URL(fileURLWithPath: "/private/tmp")).base.path` is
      `/private/tmp` (the init no longer strips a prefix either); and assert that
      a root which does **not** exist on disk (`/private/tmp-absent-xyz`) answers
      *identically* for the same shape, which is the "stats nothing" claim stated
      as an assertion rather than as prose
- [x] add the lexical normaliser as private mechanism on `LSPInstallLayout`: a
      path's components with empties and `.` dropped and `..` resolved against
      what precedes it, clamped at the root so `/../x` is `/x` (matching
      `standardizedFileURL`'s *lexical* answer), stat-free and symlink-blind;
      note in its comment that the layout's contract is an absolute file-URL
      base, which every construction site supplies
- [x] rewrite `directory(_:contains:)` over it as a whole-component prefix
      comparison (equal components count as contained — the sweep reads the
      root), and `init(base:)` to re-spell the normalised components as a
      directory URL; both doc comments state why `standardizedFileURL` is *not*
      used (it consults the file system for `/private/{tmp,var,etc}`, so the
      pure-path-math module was quietly deciding on disk state) and state the
      lexical limit for the reader who next sees two spellings compare unequal
- [x] extend the tests with the remaining shapes named in the ticket: trailing
      slash does not change either `contains(_:)` or `LSPInstallLayout` equality;
      `..` at the root does not walk above `/`; `/tmp/servers/./node/..` still
      equals `/tmp/servers`; the existing sibling-with-a-shared-string-prefix and
      `..`-walks-out negatives still fail as before
- [x] run `swift test` — `LSPInstallLayoutTests` green and `LSPInstallEngineTests`
      green **with no edit to that file**

### Task 2: A display string at the completion seam, and the rule that makes it safe

**Files:**
- Modify: `Sources/PisakaCore/CompletionEditPlan.swift`,
  `Sources/PisakaCore/CodeIntelligence.swift`,
  `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/CompletionEditPlanTests.swift`,
  `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [x] write the failing pure-rule tests first, then add the rule to
      `CompletionEditPlan.swift` as a `CompletionEdit` member (that file already
      owns how an edit relates to the typed word): given the typed word's start
      and the buffer the edit was computed against, it answers what a popup row
      should read — `newText` minus a head that re-writes, verbatim in UTF-16,
      the characters standing between `range.location` and the typed word's
      start, and the full `newText` otherwise. Cases: the `{dot,1} → ".greet"`
      head dropped; `"?.greet"` over the same range kept whole; a head that
      differs from the buffer kept whole; no gap (`range.location ==` the typed
      word's start) unchanged; a `newText` that *is* the head kept whole, since
      an empty row is not a row; and the rule applies to the primary edit only
- [x] add `displayText` to `CompletionItem` — an initialiser parameter defaulted
      to `nil` and stored as `displayText ?? text`, so the tree-sitter provider,
      both iOS surfaces and every existing construction site are untouched and
      keep meaning what they meant. Its doc comment carries the safety rule
      verbatim: this string is *also* what AppKit previews and what it inserts
      when the plan is rejected, so it may only differ from `text` by a head that
      re-writes what already stands there, and the LSP `label` is never it
- [x] compute it in `LSPIntelligenceProvider.publish(…)` from the item's own
      primary edit against the request's buffer and the `typedWord` range already
      in hand; leave `edits(for:…)`, the ranking, the dedup key (`inserted`), the
      cap and the resolve bookkeeping exactly as they are, so what is inserted is
      byte-identical
- [x] add the provider-level tests the acceptance names, driving
      `ScriptedLSPTransport`: a dot-covering `textEdit` (`{dot,1} → ".greet"` at
      the member caret) whose item inserts `.greet`, displays `greet` and carries
      an unchanged primary `CompletionEdit`; the `?.` counter-case over the same
      range keeping its full spelling; and the recorded `completion-member.json`
      fixture displaying exactly what it inserts (its ranges are zero-length at
      the caret, so this pins that the common path is untouched)
- [x] run `swift test` — the whole suite green, including every existing
      `LSPIntelligenceProviderTests` assertion about inserted text and edits

### Task 3: The macOS popup keys by what it shows

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`

- [ ] key the snapshot's `texts` and `items` by `displayText` (first-wins on a
      duplicate unchanged), so the rows read as the provider means them to and
      the item is findable under the string AppKit hands back
- [ ] key `resolved` and `resolveTasks` by `displayText` as well
      (`startResolve`), and take `scheduleFollowUp`'s `word` from `displayText` —
      there it is both the resolve key and *what now stands in the buffer* after
      AppKit's own insertion, which is exactly what
      `plan(for:over:replacing:in:)` needs;
      `insert(_:forPartialWordRange:isFinal:in:)` and `preview` already speak in
      the popup's string and so need no change beyond the lookup
- [ ] extend the class doc comment's "the list is strings; the answers are items"
      passage: the string is the item's *display* spelling, it is the key in all
      three tables, and it is safe to preview and to insert verbatim only because
      of the head-dropping rule Core enforces — with the `?.` counter-case named
      so nobody later "simplifies" the rule into showing the label
- [ ] build the macOS app (`xcodegen generate` if needed, then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`)
      and run `swift test` to confirm Core is still green

### Task 4: The three stale `#eq?` comments

**Files:**
- Modify: `Tests/PisakaCoreTests/Support/QueryScanner.swift`,
  `Tests/PisakaCoreTests/SymbolQueryTests.swift`

- [ ] correct the predicate-depth note in `QueryScanner.swift` (the HTML symbols
      query needs a `#match?`, not an `#eq?`) and both doc comments in
      `SymbolQueryTests.swift` (the auxiliary-capture test's `@_attribute`
      rationale and the filter test's "without the predicate" argument), leaving
      the deliberate `#match?`-vs-`#eq?` contrast inside
      `testTheHTMLQueryFiltersAttributesByName`'s body untouched
- [ ] run `swift test` — `SymbolQueryTests` and `VendoredGrammarQueryTests` green
      (the change is comments only, and the suites are the check that nothing
      else moved)

### Task 5: Verify acceptance criteria

- [ ] `swift test` — full suite green, with `LSPInstallEngineTests`,
      `LSPSourceGatingTests` and every existing completion assertion unmodified
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
      — the iOS surfaces are untouched and must still compile against the widened
      seam
- [ ] read the final diff against `master` and confirm the blast radius: no
      change to what any path inserts, none to ranking, none to
      `verifyUnpackTarget`/`mayDelete`, none to `Sources/Pisaka/iOS/`, no new
      file and no manifest/pin/license/query change

### Task 6: Update documentation

- [ ] `docs/architecture/core-provisioning.md` — rewrite the containment passage
      (`LSPInstallLayout` entry, "Lexical like everything else in this file"):
      what the lexical normaliser does, **why `standardizedFileURL` is not used**
      — it consults the file system for `/private/{tmp,var,etc}`, which is how a
      correct install under a `/private`-spelled root failed at
      `verifyUnpackTarget` — the component-wise comparison, and the stated limit
      that two spellings of one directory compare as different, with why that is
      safe for a predicate guarding deletes
- [ ] `docs/architecture/core-intelligence.md` — extend the `CompletionItem`
      passage with `displayText`: defaulted like `edits`/`resolveHandle`,
      display-only, and the head-dropping safety rule with its reason (the shown
      string is previewed and inserted by AppKit itself), plus why the `label` is
      never shown
- [ ] `docs/architecture/core-lsp.md` — record in the `LSPIntelligenceProvider`
      entry that a member `textEdit` covering the typed dot is answered with the
      dot in the inserted text and without it in the display, and that the
      primary edit is unchanged
- [ ] `docs/architecture/app-editor.md` — update the `CompletionController`
      entry: the popup's string is the display spelling and is the key in all
      three tables (snapshot, prefetched resolves, follow-up)
- [ ] no `README.md` or `CLAUDE.md` change is needed (no user-facing behavior
      beyond the corrected popup rows, no new file, no new pattern) — state that
      explicitly rather than leaving it implied

## Post-Completion Checks (manual)

- Live rust-analyzer install with the install root spelled `/private/tmp/…`: it
  now gets past `verifyUnpackTarget` and completes (the acceptance reviewer's
  harness).
- A TypeScript file in a DEBUG build: `greeter.` lists `greet`/`salutation`
  without the leading dot, arrowing through the rows previews correctly,
  committing inserts `greeter.greet`, and an optional receiver's `?.` row still
  reads with its full spelling.
- A Swift file: sourcekit-lsp member rows and their auto-imports behave exactly
  as before.
