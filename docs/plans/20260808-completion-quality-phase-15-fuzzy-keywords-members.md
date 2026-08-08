# Completion quality, phase 1.5: fuzzy matching, keywords, member completion

## Overview

Three upgrades to the phase-1 autocompletion, all inside the existing
`CodeIntelligenceProviding` seam and the existing tree-sitter symbol index:

1. **Fuzzy/camelCase matching** — a candidate no longer has to literally start
   with the typed text; `arrBuf`, `aBu` and `buf` all surface `ArrayBuffer`,
   with match quality as the top ranking key.
2. **Language keywords** — a static per-language list becomes a third candidate
   source, ranked between declared symbols and bare buffer words, never a
   go-to-definition result.
3. **Member completion after a dot** — a typed `.` after an identifier or a
   closing bracket opens the list with an empty member prefix; the candidate set
   is members only (method/property/constant carrying a container), with the
   receiver's own type first when the receiver spells a known type name.

Every decision lands in `PisakaCore`. The two editor layers change only where a
trigger or an insertion guard blocks the new shapes (a zero-length prefix, a
non-prefix match).

## Context

**Core files involved**

- Create: `Sources/PisakaCore/FuzzyMatch.swift` — subsequence matching + the
  match-quality value the ranking sorts on.
- Create: `Sources/PisakaCore/LanguageKeywords.swift` — the per-language static
  keyword lists.
- Modify: `Sources/PisakaCore/SymbolIndex.swift` — word-boundary initial bucket,
  fuzzy lookup, member lookups.
- Modify: `Sources/PisakaCore/IdentifierScanner.swift` — member-position
  detection and receiver extraction.
- Modify: `Sources/PisakaCore/CodeIntelligence.swift` — `CompletionRequest`
  grows `language` and `member`.
- Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift` — all ranking.

**App files involved**

- Modify: `Sources/Pisaka/CompletionController.swift`,
  `Sources/Pisaka/CodeEditorView.swift` (macOS trigger + language plumbing).
- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift` (same, plus the
  insertion guard).

**Tests**:
`Tests/PisakaCoreTests/{FuzzyMatchTests,LanguageKeywordsTests,SymbolIndexTests,IdentifierScannerTests,SymbolIntelligenceProviderTests}.swift`.

**Docs**: `docs/architecture/core-intelligence.md`, `CLAUDE.md` (index lines
only), `README.md` (completion section + known limits).

### Key design decisions (fixed by this plan)

**How fuzzy lookup gets its candidate set — a widened bucket, not a project
scan.** `SymbolIndex.prefixBucket` (lowercased *first* character → entries)
becomes `initialBucket`, keyed by every **word-boundary initial** of a name:
the first character, each camelCase hump (`ArrayBuffer` → `a`, `b`), and each
character after `_`, `-` or a digit/letter transition, deduplicated per name and
capped at 8 keys per name so a pathological identifier cannot blow the index up.
A fuzzy query looks in exactly one bucket — the one for its first typed
character — and filters it by subsequence, so the per-keystroke cost keeps the
shape it has today, ~2–3× the entries scanned and ~2–3× the bucket memory.
The consequence, which becomes a documented limit: **the first typed character
must land on a word boundary of the candidate.** `buf` → `ArrayBuffer` (hump),
`rray` → nothing. This is also what makes the boundary-first ranking rule cheap.

**Member lookup adds no index structure.** A dot-triggered request does one
ordered pass over the index's per-file storage, filtered to member kinds that
carry a container, stopping at the pre-cap — plus one `nameBucket` hit to ask
whether the receiver is a known type name and one unbounded pass for that
container's own members (small). This runs at most once per typed `.`, behind
the existing 150 ms debounce, off the main actor. Ordinary per-keystroke
completion never takes this path.

**Ranking key order** (member mode adds one key on top, nothing is reordered):

```
[member mode only] receiver's own container first
match quality: case-sensitive prefix < case-insensitive prefix < fuzzy
                (within fuzzy: fewer off-boundary hits, then tighter span,
                 then earlier first hit)
current file first
source: symbol (0) < keyword (1) < bare buffer word (2)
shorter name
lexicographic, then kind
```

For a literal prefix the quality key collapses to exactly today's two-valued
case rank and the fuzzy sub-keys are constant, so today's order is preserved
bit-for-bit and the existing ranking tests pass unchanged.

**Keywords carry `isFromCurrentFile: true`** — a keyword belongs to the language
of the file being typed in, so it is as local as a harvested word, and the source
key is then what decides between them. Where the current-file rule and the
source rule genuinely conflict (a keyword vs. a symbol declared in *another*
file), the current-file rule wins, exactly as it does today between a word and a
project symbol; the keyword tests isolate the source rule by putting everything
in one file, the way `testSymbolsOutrankBareBufferWords` already does.

**No new `SymbolKind` case for keywords** — `SymbolQueryTests` pins `SymbolKind`
by set equality against the shipped queries' captures. A keyword is a
`CompletionItem` with `kind == nil`; its source rank lives inside the provider's
private `Ranked`, so the public seam does not grow a field nobody renders.

**Member mode's buffer-word fallback requires a non-empty member prefix.**
Buffer words are offered in member mode only when the user has typed at least
one character after the dot and no member matched it. A typed `.` with an
empty prefix and no matching member shows **nothing at all** — so a dot inside
a data-file string, a JSON value or a comment cannot open a list of unrelated
buffer words. This is the stricter reading of the ticket's "buffer words only
as a fallback when no member matches", chosen because an empty prefix matches
*every* word in the buffer and the popup would be pure noise exactly where the
dot is least likely to be a member access.

## Development Approach

- **Testing approach**: Regular (code first, then tests), matching the
  repository's existing suites.
- All logic in `PisakaCore`, Foundation-only; app layers stay thin glue
  (macOS under `#if os(macOS)`, iOS in `Sources/Pisaka/iOS/`).
- UTF-16 offsets throughout; match the surrounding comment density — these files
  carry their reasoning inline, and the new rules must too.
- Completion stays a **reader**: no `autosave.suspend()`, no
  `localChanges.beginRevert()`, no writer gate.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**

## Implementation Steps

### Task 1: The fuzzy matcher

**Files:**
- Create: `Sources/PisakaCore/FuzzyMatch.swift`
- Create: `Tests/PisakaCoreTests/FuzzyMatchTests.swift`

- [x] Add `FuzzyMatch.wordBoundaryInitials(of:)`: the deduplicated, lowercased
      set of characters that begin a "word" in a name — index 0, a camel hump
      (lower→upper, and the last upper of an upper run followed by a lower, so
      `URLSession` yields `s`), and the character after `_`, `-` or a
      digit/letter transition. Cap at 8 keys.
- [x] Add `FuzzyMatch.Quality`: `Comparable`, carrying `tier`
      (0 case-sensitive prefix, 1 case-insensitive prefix, 2 fuzzy),
      `offBoundary` (matched characters that did not land on a word boundary),
      `span` (last matched index − first), `start` (first matched index).
      For a literal prefix match the three fuzzy sub-keys are constant, which is
      what keeps today's ordering intact.
- [x] Add `FuzzyMatch.quality(of candidate: String, matching query: String)
      -> Quality?`: `nil` when the query is not a case-insensitive subsequence
      of the candidate; a greedy left-to-right walk that prefers the next
      *boundary* occurrence of each query character and falls back to the next
      occurrence. Deterministic and documented; empty query yields `nil`.
      The first matched character is additionally required to land on a word
      boundary — stated in the matcher rather than left to `SymbolIndex`'s
      bucket, so keywords and buffer words (which are not looked up through a
      bucket) obey the same rule. A `matches(_:query:)` convenience wraps the
      non-ranking filter call sites.
- [x] Write tests: `aBu`/`arrBuf`/`buf` all match `ArrayBuffer`; `rray` does
      not (first character off a boundary); a boundary-hitting match orders
      before a scattered one; a tighter/earlier match orders before a looser
      one; exact-case prefix < case-insensitive prefix < fuzzy; `snake_case`
      and `URLSession` boundary sets; non-ASCII names are not split.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Fuzzy and member lookups in `SymbolIndex`

**Files:**
- Modify: `Sources/PisakaCore/SymbolIndex.swift`
- Modify: `Tests/PisakaCoreTests/SymbolIndexTests.swift`

- [x] Replace `prefixBucket` with `initialBucket`, filed under
      `FuzzyMatch.wordBoundaryInitials(of:)` instead of the single first
      character; update `replace(fileKey:symbols:)` and `purge(fileKey:)` so a
      re-index still leaves no residue (the purge stays one sweep per distinct
      bucket, not one per symbol).
- [x] Replace `symbols(withPrefix:limit:)` with
      `symbols(matching query: String, limit: Int)`: one bucket lookup for the
      query's first character, filtered by `FuzzyMatch.quality(...) != nil`,
      returned in the documented stable order and capped after ordering. Empty
      query still yields nothing. Keep the existing prefix assertions in the
      tests — this is a superset, not a replacement of behavior.
- [x] Add `members(matching query: String, limit: Int) -> [Symbol]`: an ordered
      pass over the per-file storage (files by key, symbols in extraction
      order), keeping `.method`/`.property`/`.constant` symbols that carry a
      non-empty `containerName` and match `query` fuzzily (an **empty query
      matches every member**, which is the typed-dot case), stopping at `limit`.
- [x] Add `members(inContainer name: String) -> [Symbol]` — the same filter
      restricted to one container name, case-sensitive, uncapped.
- [x] Add `declaresType(named:) -> Bool` over `nameBucket` — the receiver
      heuristic's one question.
- [x] Document in the type's header that it still **ranks nothing**: these
      methods filter and order, they do not score.
- [x] Write/extend tests: bucket purge leaves no residue after a hump-keyed
      re-index; `symbols(matching:)` finds `ArrayBuffer` for `aBu` and still
      finds it for `arr`; cap applies after ordering; `members(matching:"")`
      returns every container-carrying member and excludes free functions,
      types and container-less symbols; `members(inContainer:)` is
      case-sensitive; `declaresType(named:)` is false for a same-named function.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Language keywords

**Files:**
- Create: `Sources/PisakaCore/LanguageKeywords.swift`
- Create: `Tests/PisakaCoreTests/LanguageKeywordsTests.swift`

- [x] Add `LanguageKeywords.keywords(for language: SyntaxLanguage) -> [String]`
      with lists for `.swift`, `.javascript`, `.typescript`, `.python` and
      `.dockerfile` (the instruction set, uppercase as written), and an empty
      list for the data languages. Document *why* the data languages get none
      (a token list there is noise, not a spelling aid), in the same voice as
      `SymbolIndexModel.unindexableLanguages`.
- [x] Add an explicit `LanguageKeywords.languagesWithoutKeywords` set so the
      absence is a stated decision rather than a gap, mirroring how
      `unindexableLanguages` records its reasons.
- [x] Write tests: **set equality** over `SyntaxLanguage.allCases` — every case
      is either in `languagesWithoutKeywords` or has a non-empty list, so a new
      language fails the suite until someone decides; each list is sorted,
      duplicate-free and made of insertable tokens (every entry survives
      `IdentifierScanner.completionPrefixRange` unchanged, so a keyword can
      actually be typed and completed); spot-check `guard` in Swift, `async` in
      TypeScript, `elif` in Python, `FROM`/`HEALTHCHECK` in Dockerfile.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: Member-position detection

**Files:**
- Modify: `Sources/PisakaCore/IdentifierScanner.swift`
- Modify: `Tests/PisakaCoreTests/IdentifierScannerTests.swift`

- [x] Add `IdentifierScanner.MemberContext` — `receiver: String?` (the
      identifier immediately left of the dot, `nil` when the dot follows a
      closing bracket) plus the `prefixRange` the completion replaces (the
      member prefix already typed after the dot, possibly empty).
- [x] Add `IdentifierScanner.memberContext(in text: NSString, at offset: Int)
      -> MemberContext?`, extending the file's one boundary rule rather than
      inventing a second: walk back over identifier continuation scalars (the
      member prefix), require a `.` immediately before, and require the scalar
      before the dot to be an identifier continuation **or** one of `)`, `]`,
      `}`. A dot after whitespace, `(`, `,`, another `.`, or a bare number
      (`1.`, so a float literal never triggers) yields `nil`. Surrogate-pair
      aware and offset-clamped like the rest of the file.
- [x] Document that string/comment context is deliberately not detected, so a
      dot inside a string does trigger — matching identifier completion's
      existing behavior.
- [x] Write tests: `worker.|`, `worker.na|`, `a.b.c|` (receiver `b`),
      `items[0].|` and `f().|` (receiver `nil`), `1.|`, `foo .|`, `(.|`,
      `..|` and start-of-file all `nil`; `foo|` after the dot is deleted yields
      `nil` (the ordinary-completion path returns); the reported `prefixRange`
      equals `completionPrefixRange` at the same offset.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: Fuzzy + keyword ranking in the provider

**Files:**
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`
- Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`

- [x] Grow `CompletionRequest` with `language: SyntaxLanguage?` and
      `member: IdentifierScanner.MemberContext?`, both defaulted to `nil` in the
      initializer so every existing call site and test compiles unchanged.
      Document on the seam that the protocol's shape is untouched, so a phase-2
      LSP provider implements the same contract.
- [x] Rewrite `Ranked` to carry `FuzzyMatch.Quality` as its first key and a
      three-valued `sourceRank` (symbol 0, keyword 1, word 2), leaving the
      current-file, length, lexicographic and kind keys and their order alone.
      Rewrite the `isOrderedBefore` comparator to match, and rewrite the
      method's doc comment so the documented ranking is the implemented one.
- [x] Feed the index through `symbols(matching:limit:)`; keep the "also ask the
      current file for its own symbols" mitigation and re-state its reasoning
      for the widened match set; filter buffer words by
      `FuzzyMatch.quality(...) != nil` instead of `hasPrefix`.
- [x] Add keywords as a third source: `LanguageKeywords.keywords(for:)` when
      `request.language != nil`, filtered by the same matcher, emitted as
      `CompletionItem(text:kind: nil, isFromCurrentFile: true)`. Existing
      name-based de-duplication then collapses a keyword and an identical buffer
      word to one entry, best rank first.
- [x] Write tests: `aBu` surfaces `ArrayBuffer`; boundary-hitting fuzzy beats
      scattered fuzzy; an exact-case prefix match still beats everything,
      including a shorter fuzzy match; `gua` in a Swift request offers `guard`;
      keywords rank below same-file symbols and above same-file buffer words;
      `guard` as both keyword and buffer word appears once; a `nil` language
      yields no keywords; go-to-definition for a keyword spelling returns
      nothing (**the pinned "definitions never contain keywords" test**).
- [x] Confirm every pre-existing completion and definition test still passes
      **unedited** — with **one deliberate exception**, recorded here rather
      than worked around: `testAnEmptyIndexStillOffersBufferWords` asserted the
      full buffer-word list by equality (`["worker", "workshop"]`) for the query
      `wor`, and `wonder` is a genuine subsequence match (w·o…r) that the
      widened matcher now offers. The assertion was updated to
      `["worker", "workshop", "wonder"]` — which additionally pins that the
      fuzzy match ranks strictly *behind* both literal prefixes. No other
      completion or definition test was touched; the plan's expectation that
      literal-prefix ordering survives bit-for-bit held everywhere else.
- [x] Run `swift test` — must pass before Task 6.

### Task 6: Member completion in the provider

**Files:**
- Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`

- [x] Branch `completions(for:in:...)` on `request.member`: allow an empty
      prefix in that branch only (an empty prefix with no member context still
      yields nothing), and take candidates from
      `SymbolIndex.members(matching:limit:)` — no keywords at all.
- [x] Apply the receiver heuristic: when `member.receiver` is non-nil and
      `index.declaresType(named:)` is true, collect
      `members(inContainer: receiver)` first and give them a container rank
      above every other container's; that rank sorts above match quality, and
      every existing tie-break still applies underneath.
- [x] Fall back to harvested buffer words **only when the member prefix is
      non-empty and no member candidate matched it**. With an empty member
      prefix (the bare typed dot) there is no fallback at all — the request
      returns an empty result rather than every word in the buffer. Document
      that rule and its reasoning (an empty prefix matches every word, so the
      fallback would turn a dot inside a JSON string or a comment into a list
      of unrelated words).
- [x] Add a member-mode pre-cap constant with its own reasoning comment, in the
      voice of the existing `candidateLimit(for:)` note.
- [x] Write tests: a typed dot with an empty prefix lists members and excludes
      types, free functions and container-less symbols; `Worker.` puts
      `Worker`'s own members above another container's identically-named
      member; a receiver that names a *function* rather than a type gets no
      container boost; a member prefix filters fuzzily (`worker.dR` →
      `doRequest`); keywords never appear in member mode; **a bare dot with no
      matching member returns nothing even though the buffer has words**; a
      *non-empty* member prefix with no matching member falls back to buffer
      words; results are still capped and de-duplicated. Plus one the plan did
      not name and the fallback rule needs: a *single* matching member
      suppresses the buffer-word fallback entirely, so words never dilute a real
      member list.
- [x] Run `swift test` — must pass before Task 7.

### Task 7: macOS editor wiring

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Give `CompletionController.update(...)` a `language: SyntaxLanguage?`
      parameter and pass the coordinator's `language` from
      `updateCompletions(explicit:)`.
- [x] Replace the length gate: compute
      `IdentifierScanner.memberContext(in:at:)` first; when it is non-nil, build
      the request with the member prefix (possibly empty) and the context, and
      skip the two-character minimum entirely. Otherwise keep today's gate
      exactly. Explicit invocation (⌃Space) keeps its one-character bypass and
      now also works in a member position.
- [x] Relax `apply(prefix:items:)`'s `range.length > 0` re-check so an empty
      member prefix still opens the popup, while a stale snapshot whose prefix
      no longer matches the buffer is still discarded. The relaxation needed one
      guard the plan did not name, because dropping `range.length > 0` alone is
      *too* permissive: an empty prefix compares equal to the (also empty)
      partial word at a caret sitting in open space, after a `(`, or at the start
      of a line, so a member list would survive a caret move that the ordinary
      prefix comparison was supposed to catch. The zero-length case therefore
      additionally requires `memberContext(in:at:)` to still be non-nil. The same
      condition is applied on the *serving* side (`completions(forPartialWordRange:in:)`,
      with the member-ness carried on `Snapshot`), so a stock ⌥⎋ in open space
      gets nothing rather than the previous dot's members.
- [x] Leave `rangeForUserCompletion`, `insertCompletion` and the
      programmatic-edit bracket untouched — an empty range at the caret is
      already the correct insertion range for a member completion.
- [x] Update the class doc comments to state the new trigger and that the
      snapshot's prefix may now be empty.
- [x] `swift test` must pass (Core is unaffected but the gate is), then build
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build`. Both green: 1782 Core tests, `** BUILD SUCCEEDED **`.

### Task 8: iOS editor wiring

**Files:**
- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`

- [ ] Apply the same member-context gate in `updateCompletions(in:)`, passing
      `language` and the member context into the `CompletionRequest`.
- [ ] Relax the post-await re-check (`range.length > 0`) the same way, keeping
      the "the word this answers has moved" discard.
- [ ] Fix `insertCompletion(_:)`'s guard, which is `hasPrefix`-based and would
      silently swallow a tap on a fuzzy candidate: accept the item when
      `FuzzyMatch.quality(of: item, matching: typedText) != nil`, and accept an
      empty range outright when the caret is in a member position. Update the
      comment that explains the guard.
- [ ] `swift test` must pass, then build
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build`.

### Task 9: Documentation

**Files:**
- Modify: `docs/architecture/core-intelligence.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] `core-intelligence.md`: full entries for `FuzzyMatch.swift` and
      `LanguageKeywords.swift`; updated entries for `SymbolIndex` (the
      word-boundary initial bucket, its memory/scan cost, and the
      first-character-must-hit-a-boundary limit), `IdentifierScanner` (member
      context), `CodeIntelligence` (the two new request fields and why the
      protocol shape is unchanged) and `SymbolIntelligenceProvider` (the full
      new ranking order, the keyword source rule and its documented conflict
      with the current-file rule, the member branch, the receiver heuristic,
      the non-empty-prefix-only buffer-word fallback, and the member-mode
      costs).
- [ ] `CLAUDE.md`: index lines only — two new `PisakaCore` files under
      `docs/architecture/core-intelligence.md`, and a phrase-level refresh of
      the `SymbolIndex`/`IdentifierScanner`/`SymbolIntelligenceProvider` lines.
      No per-file essays.
- [ ] `README.md`: rewrite the completion bullet (fuzzy/camelCase matching, the
      keyword source and which languages have one, member completion after a
      dot and how it is triggered on both platforms); update the known-limits
      entry — drop "no member completion after a `.`", and state that member
      completion is **name-based, not typed** (project-wide, ranked by the
      receiver's spelling), that fuzzy matching requires the first typed
      character to hit a word boundary, that a dot inside a string or comment
      still triggers, and that **a dot with nothing typed after it offers only
      members — if the project declares none, the list stays empty rather than
      falling back to words from the file**.
- [ ] Run `swift test` (the repository-file suites read these paths).

### Task 10: Verify acceptance criteria

- [ ] `swift test` — full suite green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` succeeds.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` succeeds.
- [ ] Re-read the ticket's acceptance list and confirm each named Core test
      exists: `aBu` → `ArrayBuffer`; boundary beats scattered; exact prefix
      beats everything; keywords below symbols and above words; keyword/word
      dedup; `Worker.` members first; a dot after whitespace or `(` is not a
      member position; deleting the dot restores ordinary completion;
      definitions never contain keywords.
- [ ] Confirm no dependency, pin, `project.yml`, `Package.resolved` or
      `symbols.scm` file was touched.

## Post-Completion (manual, on a developer machine)

- Run the macOS app: type `.` after an identifier and confirm the stock AppKit
  popup opens with member candidates. **Known risk to verify here**: AppKit's
  `complete(nil)` is being asked to open over a zero-length partial-word range;
  if the stock popup declines to open in that position, that is a platform
  limitation to record in the README's known limits rather than to work around
  with a synthetic prefix.
- macOS: `arrBuf` surfaces `ArrayBuffer` in a project that declares it; `gua` in
  a Swift file offers `guard`.
- iOS simulator: the strip shows member candidates after a dot and fuzzy matches
  while typing, and tapping a fuzzy candidate actually inserts it.
