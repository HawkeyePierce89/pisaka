# Log filter bar: seed from the change handler's new value

## Overview

The Log filter bar's controls chronically display the state of the *previous*
publish: after picking a branch the ref picker falls back to "All" within
seconds while the model correctly holds `.ref(<branch>)`, and the next apply —
built from that lagging draft — writes the stale state back, silently dropping
the branch selection (a Since toggle after a branch pick was captured handing
the model `refSelection = .all`).

The fix is small and has two halves:

1. **View-side parameter plumbing** (both bars): every `.onChange` seed passes
   the closure's *new value* into the seeding code instead of re-reading the
   view's own observed property.
2. **One new Core seeding form**: a `mutating func seed(from:)` on
   `LogFilterDraft` that seeds an *existing* draft and, when an incoming bound
   is absent, **preserves the day currently shown** instead of re-parking it on
   "now" — so a chosen day survives unticking and re-ticking its bound.

Nothing else changes: the user-intent binding construction is correct and
stays, `CommitLogModel` is untouched, and no filter dimension, layout or
feature is added.

### Root cause (verified — restated here because the plan must carry it)

`LogFilterBar.seedFromFilter()` reads `self.filter`, and it is called from
`.onChange(of: filter) { _ in seedFromFilter() }` (`LogFilterBar.swift:77`).
Inside a change handler the view's own property still carries the **old**
value — that is documented behavior, and the reason the closure is handed the
new value as its parameter. So every publish seeds the draft with the previous
filter: the display lags one publish forever, and any user-intent apply built
from the lagging draft resurrects old state.

Live evidence: fresh session → open the Git Log panel → pick a branch → within
seconds the picker shows "All" while `self.filter` / `requestedFilter` (probed
under a debugger) hold `.ref(<branch>)`; a following Since toggle applied
`refSelection = .all`, and the state ping-ponged one step behind on every
subsequent publish.

The pre-rework bar had the same stale read, but its ref picker read `filter`
live through a binding `get`, which masked the lag *for the picker only*; the
reworked picker reads the seeded draft and inherited it.

The same stale-property read exists in the search seeds:
`.onChange(of: searchQuery) { _ in search = searchQuery }`
(`LogFilterBar.swift:78`) and `.onChange(of: searchQuery) { search = searchQuery }`
(`LogFilterBar_iOS.swift:66`) — one-behind for the search box, same mechanism,
lower stakes (client-side only).

### Where the decisions live (Requirement 4, stated explicitly)

This fix is **view-side parameter plumbing plus exactly one new Core seeding
form**. The plumbing (passing the handler's parameter instead of reading
`self`) is untestable view glue by project convention; the one rule that *is* a
decision — "a seed with an absent bound keeps the day the draft already shows"
— moves into `LogFilterDraft` and is unit-tested there in its
seed-into-an-existing-draft form, not merely through the from-scratch `init`.

### Full inventory of the change handlers audited

| File | Handler | Today | After |
| --- | --- | --- | --- |
| `LogFilterBar.swift:74` | `.onAppear(perform: seedFromFilter)` | reads `filter`/`searchQuery` — correct at appearance, not a change handler | seeds explicitly from `filter`/`searchQuery` |
| `LogFilterBar.swift:77` | `.onChange(of: filter)` | `{ _ in seedFromFilter() }` — stale | `{ newFilter in seed(from: newFilter) }` |
| `LogFilterBar.swift:78` | `.onChange(of: searchQuery)` | `{ _ in search = searchQuery }` — stale | `{ newQuery in search = newQuery }` |
| `LogFilterBar_iOS.swift:65` | `.onAppear { search = searchQuery }` | correct at appearance | unchanged |
| `LogFilterBar_iOS.swift:66` | `.onChange(of: searchQuery)` | `{ search = searchQuery }` — stale | `{ _, newQuery in search = newQuery }` |

`LogAdvancedFilterForm_iOS` has no change handlers (it is seeded once in `init`
and applies only from its Apply button) and needs no change. The iOS compact
bar's `selectedRef` / `applyRef` read `filter` from the view body / a binding
`get`, which is live, not stale — they stay as they are. Task 2 re-greps both
files so the inventory is verified against the tree rather than trusted.

### API-availability note

The deployment targets are macOS 13 and iOS 17, so the two bars must use
*different* `onChange` spellings and this is deliberate, not an inconsistency:

- macOS 13 has only `onChange(of:perform:)`, whose single closure parameter
  **is the new value** — that is what the macOS bar must name and use. Do not
  "modernize" it to the two-parameter form; that is macOS 14+ and will not
  compile against the pinned target.
- iOS 17 has the newer `onChange(of:_:)`; the iOS bar's zero-parameter closure
  is changed to the two-parameter `{ _, newQuery in }` form.

## Context

- Files involved:
  - `Sources/PisakaCore/LogFilterDraft.swift` — the shared draft; gains
    `mutating func seed(from:)`.
  - `Sources/Pisaka/LogFilterBar.swift` — the macOS bar; two change handlers +
    `onAppear` + `seedFromFilter`.
  - `Sources/Pisaka/iOS/LogFilterBar_iOS.swift` — the iOS compact bar; one
    change handler.
  - `Tests/PisakaCoreTests/LogFilterDraftTests.swift` — new seeding tests.
  - `docs/architecture/core-git-models.md` — the `LogFilterDraft` entry.
  - `docs/architecture/app-git-views.md` — the `LogFilterBar.swift` entry.
  - `docs/architecture/app-ios.md` — the `LogFilterBar_iOS.swift` entry.
- Related patterns: pure engine + thin glue (every decision in Core, unit
  tested; views only wire triggers); the existing seed/assemble pair
  `init(filter:defaultDate:)` / `filter(calendar:)`; the user-intent binding
  rule established by the previous ticket (an apply lives only in a
  `Binding.set` or an `onSubmit`, and is handed the new value explicitly).
- Dependencies: none.

## Development Approach

- **Testing approach**: TDD for the Core seeding rule (the preserved-day
  behavior is a genuine behavior change with an existing contrary rule
  documented today), regular for the view plumbing (untested by convention).
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** — for the two
  view-plumbing tasks, the covering test is the Core suite plus both platform
  builds, since the view layer is untested by project convention; that is
  stated per task rather than inventing view tests the repository does not have.
- **CRITICAL: all tests must pass before starting the next task.**
- No product/brand names anywhere: code, comments, docs, this plan, commit
  messages.

## Implementation Steps

### Task 1: `LogFilterDraft.seed(from:)` — a seed that preserves a disabled bound's day

**Files:**
- Modify: `Sources/PisakaCore/LogFilterDraft.swift`
- Modify: `Tests/PisakaCoreTests/LogFilterDraftTests.swift`

- [x] write the failing tests first (TDD):
    - seeding an existing draft from a filter whose `since` is `nil` clears
      `sinceEnabled` but leaves `since` on the day the draft already held
      (not "now"), and the same for `until`
    - seeding from a filter whose bounds are present overwrites both the flag
      and the date verbatim
    - seeding overwrites `refSelection` verbatim (an unknown ref is carried,
      never re-resolved), and `author`/`path` (`nil` → `""`)
    - the untick/re-tick journey as one test: seed a chosen day, seed again
      from a filter with that bound absent, flip the flag back on, and assert
      `filter()` re-derives the same day boundary
    - `init(filter:defaultDate:)` keeps its existing contract (a `nil` bound
      parks on `defaultDate`) — the existing tests must stay green unchanged
- [x] add `public mutating func seed(from filter: LogFilter)`: assigns
    `refSelection`, `author`, `path` and both `…Enabled` flags from `filter`,
    and assigns each date **only when the incoming bound is present**,
    otherwise leaving the date already in the draft untouched
- [x] express `init(filter:defaultDate:)` in terms of the new method (park both
    dates on `defaultDate`, then seed) so there is one seeding rule rather
    than two that can drift
- [x] document on the method *why* the day is preserved: unticking a bound is
    not "forget my day", and a seed is not a user edit — with the from-scratch
    `init` named as the case that has no day to preserve
- [x] run `swift test` — must pass before Task 2

### Task 2: macOS bar — seed from the handler's parameter

**Files:**
- Modify: `Sources/Pisaka/LogFilterBar.swift`

- [ ] replace `seedFromFilter()` with a function of what it seeds from —
    `private func seed(from newFilter: LogFilter)` calling
    `draft.seed(from: newFilter)`
- [ ] `.onChange(of: filter) { newFilter in seed(from: newFilter) }` — using
    the macOS 13 single-parameter form whose parameter is the new value; do
    not switch to the macOS 14+ two-parameter spelling
- [ ] `.onChange(of: searchQuery) { newQuery in search = newQuery }`
- [ ] make `.onAppear` seed both explicitly from the current `filter` /
    `searchQuery` (at appearance the property is current — this is the one
    place the property may legitimately be read)
- [ ] update the type's doc comment and the `seed(from:)` comment to name the
    trap: a change handler seeds from its parameter, because the view's own
    observed property still holds the previous value inside the handler
- [ ] `grep -n "onChange" Sources/Pisaka/LogFilterBar.swift` and confirm no
    remaining handler reads the observed property off `self` (Requirement 1's
    audit, run against the tree)
- [ ] covering checks for this task (the view layer is untested by convention):
    `swift test` still green and the macOS build compiles —
    `xcodegen generate` then
    `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`

### Task 3: iOS compact bar — seed from the handler's parameter

**Files:**
- Modify: `Sources/Pisaka/iOS/LogFilterBar_iOS.swift`

- [ ] change the search seed to the two-parameter form:
    `.onChange(of: searchQuery) { _, newQuery in search = newQuery }`
- [ ] leave `LogAdvancedFilterForm_iOS` alone (no change handlers; seeded once
    in `init`) and leave `selectedRef` / `applyRef` alone (they read `filter`
    live from the body / a binding `get`, which is not the stale path) —
    record both as deliberate in the file's audit comment
- [ ] update the file's audit doc comment with the same rule the macOS bar now
    states
- [ ] `grep -n "onChange" Sources/Pisaka/iOS/LogFilterBar_iOS.swift` and
    confirm the audit holds
- [ ] covering checks for this task: `swift test` still green and the iOS build
    compiles —
    `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`

### Task 4: Update architecture documentation

**Files:**
- Modify: `docs/architecture/core-git-models.md`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `docs/architecture/app-ios.md`

- [ ] `core-git-models.md`, the `LogFilterDraft.swift` entry: record the seeding
    pair as `init(filter:defaultDate:)` *and* `seed(from:)`, and state the
    preservation rule — an absent incoming bound clears its flag and keeps the
    day already shown; only the from-scratch `init`, which has no day to keep,
    parks on `defaultDate`
- [ ] `app-git-views.md`, the `LogFilterBar.swift` entry: replace the
    `seedFromFilter` description with the parameter-seeded one and record the
    rule under its own name — **change handlers seed from their parameter; the
    view's observed property is stale inside the handler** — including why
    `onAppear` is the exception and why the macOS bar keeps the
    single-parameter `onChange` spelling (the macOS 13 target)
- [ ] `app-ios.md`, the `LogFilterBar_iOS.swift` entry: same rule, plus the two
    deliberate non-changes (the advanced form has no change handlers; the
    branch menu reads `filter` live, not through a seed)
- [ ] check whether `CLAUDE.md`'s one-line index entry for `LogFilterDraft.swift`
    still describes the file accurately; adjust the existing line only if it
    no longer does, and never grow it into an essay
- [ ] grep the touched sources and docs to confirm no product-name comparison
    was introduced
- [ ] run `swift test` (the repository-file suites read docs/config shapes) —
    must pass

### Task 5: Verify acceptance criteria

- [ ] `swift test` green, including the new/updated `LogFilterDraftTests`
- [ ] `swiftlint --strict` clean from the repository root
- [ ] `xcodegen generate`, then the macOS build:
    `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] the iOS build:
    `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] final audit grep over both bars: every `onChange` handler names and uses
    its new-value parameter, and none reads the observed property off `self`

## Post-Completion (manual verification by the user)

- Fresh session → open the Git Log panel → pick a branch: the picker keeps
  showing that branch after the fetch settles (not just transiently).
- With the branch still selected, tick **Since** and choose a day: the picker
  still shows the branch and the list is that branch's history since the chosen
  day. Untick **Since**: the full branch history returns and the branch stays
  selected.
- Re-tick **Since**: the date picker still shows the day chosen earlier, not
  today. Repeat for **Until**.
- Switch project folders and confirm the message search box shows the new
  (empty) query immediately, never the previous folder's.
- Repeat the branch/search checks on iOS.

## Out of scope

- Any further rework of the user-intent binding construction — it is correct
  and stays; this ticket only changes what a seed *reads* and what a seed
  *preserves*.
- `CommitLogModel` (untouched; its contracts were corrected in the previous
  ticket).
- Filter-bar layout, dimensions, or new filter features.
