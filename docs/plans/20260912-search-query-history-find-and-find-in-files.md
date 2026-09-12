# Search query history for ⌘F and Find in Files (macOS)

## Overview

One shared, persisted list of recent search queries, recorded on committing
gestures and on dismissal by both macOS search surfaces, and offered back from a
clock-icon menu beside each query field. Every decision — the recording rule,
the cap, the on-disk encoding, the menu row's text — lives in a new pure Core
type and is unit-tested; the two surfaces only record and render.

## Context

Files involved:

- Create: `Sources/PisakaCore/SearchQueryHistory.swift` — the type.
- Create: `Tests/PisakaCoreTests/SearchQueryHistoryTests.swift` — its suite.
- Create: `Sources/Pisaka/SearchHistoryMenu.swift` — the one menu view both
  surfaces render (macOS).
- Modify: `Sources/PisakaCore/SettingsStore.swift` — the new persisted
  preference and its two writers.
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift` — round-trip and
  decode-failure coverage.
- Modify: `Sources/Pisaka/EditorSearchState.swift` — the injected recording hook
  and the five recording sites.
- Modify: `Sources/Pisaka/SearchBarView.swift` — the menu in the find row.
- Modify: `Sources/Pisaka/ProjectSearchView.swift` — the menu, activation and
  Replace All recording.
- Modify: `Sources/Pisaka/ProjectSearchWindowController.swift` — a
  `windowWillClose` hook for the caller.
- Modify: `Sources/Pisaka/PisakaApp.swift` — the two wiring sites (the state's
  hook at `init()`, the window's close hook in `openProjectSearch()`).
- Docs: `docs/architecture/core-search.md`, `core-services.md`,
  `app-editor.md`, `CLAUDE.md` (two index lines), `docs/FEATURES.md`
  (two bullets).

Related patterns:

- `SettingsStore.setConsent(_:for:)` — the "a write equal to what is already
  held publishes nothing" precedent this feature's writers copy verbatim.
- `SettingsStore.init(defaults:)` — every stored value read through
  `object(forKey:)` with a cast, so a wrong-typed or absent value falls back
  instead of coercing.
- `SearchQuery` (`TextSearch.swift`) — the entry type, already `Equatable`,
  deliberately left non-`Codable`.
- `EditorSearchState` is `@StateObject` built at `PisakaApp.init()` where a
  local `settings` instance already exists (the `projectSearch` closures
  capture their collaborators the same way, weakly).
- `ProjectSearchView` already holds `settings` as an `@ObservedObject`, so it
  reads and records without a new seam; the *window controller* does not, which
  is why the close hook is a closure passed down from the app.

Dependencies: none. No new package, no key equivalent, no change to the search
engine, the debounce or either generation-token scheme.

### Decisions taken here (the ticket asked for them)

1. **On-disk encoding**: JSON `Data` under one key,
   `"settings.searchQueryHistory"`. The array is encoded from a *private*
   `Entry: Codable` DTO owned by `SearchQueryHistory`, with explicit
   `CodingKeys` (`pattern`, `isRegex`, `caseSensitive`, `wholeWord`), so
   `SearchQuery` stays non-`Codable` and no property rename can silently change
   the stored shape. `Data` rather than an array of plist dictionaries because
   one opaque value makes "decode failed ⇒ empty" a single answer rather than a
   per-element judgement.
2. **Failure is whole-value, not per-entry** — the deliberate opposite of
   `lspServerConsent`, and the reason belongs in the doc comment: a consent map
   that drops one unreadable entry costs one server its answer, while a history
   that drops some entries is a list the user silently cannot trust.
3. **Invariants are enforced on read as well as on write**: decoding replays the
   stored entries oldest-first through the same `record(_:)`, so a stored blank,
   duplicate or over-long list from any build reads back as a list this type
   could have produced.
4. **The menu row's text is Core's**: `SearchQueryHistory.menuLabel(for:)`
   middle-truncates the pattern to 60 characters and appends the flags that are
   on (` Aa`, ` ab`, ` .*`, in the toggles' own order), so the string is
   deterministic and unit-tested rather than left to a menu item's truncation.
5. **Picking focuses without selecting**: the menu writes the pattern and flags
   and sets the surface's own `@FocusState`, rather than going through
   `EditorSearchState.open()`, whose focus request also selects the field's
   contents (right for ⌘F, wrong right after a pick — the next keystroke would
   wipe what was just chosen).
6. **Every window-close path records**, including the termination sweep
   `closeAll()`, which invokes the same stored hook explicitly before dropping
   the delegate.
7. **Blankness is refused in Core alone**: every app-layer site records
   unconditionally and lets the one rule refuse an empty or whitespace-only
   pattern, so no surface restates the test.

## Development Approach

- **Testing approach**: Regular (code first, then tests), per the repository's
  existing suites.
- Per `CLAUDE.md`, **SwiftUI/AppKit glue in `Sources/Pisaka` is untested by
  convention**: Tasks 3–5 add no test file and are gated by `swift test` plus a
  macOS build instead. Every *decision* those tasks need (the recording rule,
  the label) is in Core and covered by Task 1–2.
- Complete each task fully — including its gate — before starting the next.
- Local builds use `~/Library/Developer/Xcode/DerivedData/pisaka-searchhistory`,
  never a path inside the repository.
- No brand names or comparisons to other editors in code, comments, docs or
  commit messages.

## Implementation Steps

### Task 1: The Core history type

**Files:**
- Create: `Sources/PisakaCore/SearchQueryHistory.swift`
- Create: `Tests/PisakaCoreTests/SearchQueryHistoryTests.swift`

- [x] Add `public struct SearchQueryHistory: Equatable` with
      `public static let capacity = 20`, `public private(set) var entries:
      [SearchQuery]` (newest first), `public init()`, `public var isEmpty: Bool`.
- [x] Add the one recording rule as `public mutating func record(_ query:
      SearchQuery)`: a pattern that is empty or whitespace-only when trimmed is
      refused outright; an entry whose pattern matches an existing one exactly
      (case-sensitive, untrimmed comparison) is removed and the new value
      inserted at the front, so the newer flags win; the list is then truncated
      to `capacity`, dropping the oldest. State the whole rule in the type's doc
      comment, including that "no change" is expressed as an unchanged value
      rather than as a return flag — `Equatable` is what the store's writer
      guards on.
- [x] Add `public mutating func clear()`.
- [x] Add `public init(entries: [SearchQuery])`, which replays the given
      newest-first list oldest-first through `record(_:)`, so blanks, duplicates
      and over-long lists cannot enter by this door either.
- [x] Add the persistence pair, keeping `SearchQuery` free of any `Codable`
      conformance: a private nested `Entry: Codable` with explicit `CodingKeys`,
      `public init(persistedData: Data?)` (any failure — absent, not JSON, a JSON
      object rather than an array, an element missing or mistyping a key — reads
      as an empty history, never a partial one) and `public var persistedData:
      Data?` (`nil` while empty, so the store removes the key rather than writing
      an empty array).
- [x] Add `public static func menuLabel(for query: SearchQuery,
      maxPatternLength: Int = 60) -> String`: the pattern middle-truncated with a
      single `…` to at most `maxPatternLength` characters, then a space-separated
      suffix of the flags that are on — `Aa` (case), `ab` (whole word), `.*`
      (regular expression) — in the toggles' own order.
- [x] Write `SearchQueryHistoryTests` covering: the empty/whitespace refusal
      (including a tab-and-space pattern); dedupe-and-promote by pattern with the
      newer flags winning; that a differently-cased pattern is a *different*
      entry; the front no-op (recording the front entry with identical flags
      leaves the value equal); the cap at 20 dropping the oldest; `clear()`;
      `init(entries:)` normalizing a dirty list; `menuLabel` for a short pattern,
      a 200-character pattern (exactly `maxPatternLength` characters out, `…`
      present) and each flag combination.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The persisted preference

**Files:**
- Modify: `Sources/PisakaCore/SettingsStore.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [ ] Add `Keys.searchQueryHistory = "settings.searchQueryHistory"` with a doc
      comment recording that it is **one** history shared by both surfaces (the
      engine is one, and so is the question "what did I search for"), and that
      the value is opaque JSON whose failure mode is whole-value.
- [ ] Add `@Published public private(set) var searchQueryHistory:
      SearchQueryHistory`, whose `didSet` writes `persistedData` or removes the
      key when it is `nil`.
- [ ] Read it in `init(defaults:)` through `data(forKey:)` into
      `SearchQueryHistory(persistedData:)`, so a wrong-typed stored value falls
      back like every other preference here.
- [ ] Add the two writers: `public func recordSearchQuery(_ query: SearchQuery)`
      — build the next value, and `guard next != searchQueryHistory else
      { return }` before assigning, citing `setConsent(_:for:)`'s reason (this
      store is observed by `ContentView`; a no-op publish re-evaluates the tree,
      the tab list and the editor, and the ⌘F bar records on *every* Find Next)
      — and `public func clearSearchQueryHistory()`, guarded on `isEmpty`.
- [ ] Update the type-level doc comment's list of what this store holds.
- [ ] Extend `SettingsStoreTests`: a fresh store reads an empty history; record
      → new store over the same suite sees the same entries in the same order
      (the round trip); the cap survives the round trip; `clearSearchQueryHistory`
      removes the key so a fresh store is empty; and one test per decode-failure
      shape — key absent, a `String` stored under the key, `Data` that is not
      JSON, a JSON object instead of an array, an array element missing
      `pattern`, an array element whose `isRegex` is a string — each reading as
      empty. Add a publish test (Combine, as the file already imports it) that a
      redundant `recordSearchQuery` emits nothing.
- [ ] Run `swift test` — must pass before Task 3.

### Task 3: Recording from the ⌘F bar

**Files:**
- Modify: `Sources/Pisaka/EditorSearchState.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [ ] Give `EditorSearchState` an injected `private let recordQuery:
      (SearchQuery) -> Void` with an `init(recordQuery: @escaping (SearchQuery)
      -> Void = { _ in })`, documenting that the state deliberately does not know
      `SettingsStore` — the hook is wired once, in the app, and a default of "do
      nothing" keeps the type constructible on its own.
- [ ] Call `recordQuery(currentQuery)` at the committing gestures — `findNext`,
      `findPrevious`, `replaceCurrent`, `replaceAll` — and in `close()` after its
      `isVisible` guard, so the bar's dismissal records exactly once whichever
      path (Esc in the bar, Esc in the editor, the close button, the menu) got
      there. Note in the comment that nothing here tests the pattern: Core's one
      rule refuses a blank.
- [ ] In `PisakaApp.init()`, build the state with the hook over the local
      `settings` instance, captured weakly like the neighbouring closures:
      `_search = StateObject(wrappedValue: EditorSearchState(recordQuery:
      { [weak settings] in settings?.recordSearchQuery($0) }))`, with a comment
      naming this as the one wiring site.
- [ ] Run `swift test`, then `xcodegen generate` and the macOS build into the
      out-of-repo derived-data path — both must pass before Task 4.

### Task 4: Recording from Find in Files

**Files:**
- Modify: `Sources/Pisaka/ProjectSearchWindowController.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [ ] Give `ProjectSearchWindowController.show(content:onWillClose:)` a stored
      `onWillClose: () -> Void`, replaced on every call like `rootView` already
      is, invoked from the window delegate's `windowWillClose` before `release()`
      and invoked explicitly by `closeAll()` before it drops the delegate, so the
      termination sweep records too. Document that the controller records nothing
      itself: it owns no model and no query.
- [ ] In `ProjectSearchView`, funnel both activation paths through one private
      `activate(url:range:)` that records `model.query` — the query that actually
      produced the rows — and then calls `onActivate`; use it from the row button
      and from `activateFirstResult()`'s success branch (not from the branch that
      dispatches the pending search instead). Record the same value in
      `confirmReplaceAll()` once the alert is accepted. Document why it is
      `model.query` and not the controls' `currentQuery`: the dispatched query is
      the one the user ran, and it is what the close path can reach.
- [ ] In `PisakaApp.openProjectSearch()`, pass `onWillClose: { [weak settings,
      weak projectSearch] ... }`-shaped wiring that records `projectSearch.query`
      — a window closed before anything was searched carries an empty pattern,
      which Core's rule refuses, so "while a search has been dispatched" needs no
      second test here.
- [ ] Run `swift test` and the macOS build — both must pass before Task 5.

### Task 5: The menu in both surfaces

**Files:**
- Create: `Sources/Pisaka/SearchHistoryMenu.swift`
- Modify: `Sources/Pisaka/SearchBarView.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [ ] Add `SearchHistoryMenu` (macOS-gated, thin): `entries: [SearchQuery]`,
      `metrics: InterfaceMetrics`, `onPick`, `onClear`. A `Menu` labelled with
      `Image(systemName: "clock.arrow.circlepath")` at `metrics.scaledFont(.body)`,
      borderless with the indicator hidden and `.fixedSize()` so it sits in the
      row like the three toggles; `.help("Recent searches")`;
      `.disabled(entries.isEmpty)`. Items are `ForEach(entries, id: \.pattern)`
      (patterns are unique by the recording rule) drawing
      `SearchQueryHistory.menuLabel(for:)`, then a `Divider()` and one
      `Button("Clear History")`. No key equivalents at all, so
      `MenuShortcutUniquenessTests` is untouched.
- [ ] In `SearchBarView`, add `@ObservedObject var settings: SettingsStore`,
      place the menu in `findRow` immediately after the query field and before
      the three toggles, and wire `onPick` to write `pattern`, `isRegex`,
      `caseSensitive`, `wholeWord` into the state and set `isQueryFocused = true`
      — the re-run follows from the published pattern change, exactly as typing
      does. Wire `onClear` to `settings.clearSearchQueryHistory()`. Update the
      one call site in `ContentView.swift` to pass `settings`.
- [ ] In `ProjectSearchView`, place the same menu in the same position (after the
      query field, before the toggles), reading `settings.searchQueryHistory`;
      `onPick` writes the four `@State` values and sets `isQueryFocused = true`,
      leaving the existing `onChange` handlers to schedule the ordinary debounced
      search; `onClear` calls `settings.clearSearchQueryHistory()`. Note in the
      comment that picking is not a committing gesture and records nothing.
- [ ] Run `swift test` and the macOS build — both must pass before Task 6.

### Task 6: Verify the gates

- [ ] `swift test` green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-searchhistory test` — the
      app-layer bundle green.
- [ ] `xcodebuild … -destination 'generic/platform=iOS' build` green (Core builds
      the new type; no iOS surface uses it).
- [ ] `swiftlint --strict` clean from the repository root against the committed
      configuration.
- [ ] If — and only if — `PisakaApp.swift` crosses `file_length` (1890) or
      `type_body_length` (1874), move the crossed ceiling to the *measured* new
      value, extend that rule's existing comment in `.swiftlint.yml` with the one
      sentence naming this change, and update the matching pin in
      `LintConfigurationTests`; re-run `swift test` and the linter. Otherwise
      leave both untouched.

### Task 7: Documentation

**Files:**
- Modify: `docs/architecture/core-search.md`, `docs/architecture/core-services.md`,
  `docs/architecture/app-editor.md`, `CLAUDE.md`, `docs/FEATURES.md`

- [ ] `core-search.md`: a full entry for `SearchQueryHistory.swift` — the one
      recording rule, the cap, why an entry is a whole `SearchQuery` rather than
      a string, the explicit-key encoding and why `SearchQuery` stays
      non-`Codable`, the whole-value failure mode and how it differs on purpose
      from the consent map's per-entry one, the read-side replay, and
      `menuLabel`'s two halves.
- [ ] `core-services.md`: extend the `SettingsStore` entry with the new
      preference — the key, the two writers, the equality guard and its cost
      argument, and that the value is shared by both surfaces.
- [ ] `app-editor.md`: record the recording sites and the menu for
      `EditorSearchState` (the injected hook, the five sites, the one wiring
      site), `SearchBarView`, `ProjectSearchView` (why `model.query` is what is
      recorded) and `ProjectSearchWindowController` (the close hook and why it
      records nothing itself), plus a new entry for `SearchHistoryMenu.swift`.
- [ ] `CLAUDE.md`: one index line under `core-search.md` for
      `SearchQueryHistory.swift` and one under `app-editor.md` for
      `SearchHistoryMenu.swift` — one line each, no essays.
- [ ] `docs/FEATURES.md`: describe the feature under find/replace (the clock
      menu beside both fields, what a committing gesture is, the cap, that flags
      travel with the text, that the list is shared and survives a relaunch, and
      Clear History); drop "no query history" from the find/replace
      known-limitations bullet, leaving the replace-in-selection and gitignore
      sentences intact, and from the same phrase in the find-bar feature
      paragraph. The SQL console's own "no query history" sentence is a different
      feature and stays.
- [ ] Run `swift test` (the documentation-reading suites) and `swiftlint
      --strict` once more.

## Post-Completion Verification (manual, Debug build)

No gate drives the UI, so these are checked by hand in a Debug build and the
result recorded in the final report:

1. Type a query in ⌘F, press Enter, close the bar, reopen — the clock menu lists
   it.
2. Pick it — the field and the three toggles are restored and matches highlight.
3. The same entry is in the Find in Files menu without a relaunch.
4. Clear History from either surface empties both.
5. Relaunch — the list survives.
6. Type `f`, `fo`, `foo` and close the bar — only `foo` is recorded.
7. In Find in Files: type a query, click a result — it is recorded; close the
   window with a dispatched query — it is recorded; a window closed with nothing
   searched records nothing.
8. The menu is greyed out while the history is empty.
