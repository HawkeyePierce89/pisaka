# Log filter bar: stop the Since/Until apply/re-seed loop

## Overview

Checking **Since** (or **Until**) in the Log panel's filter bar starts a
self-sustaining apply → publish → re-seed → apply loop: the checkbox and date
field flip at a ~1.5 s period, the spinner never stops, the commit list empties,
the ref picker degrades to "All", and a `git log` subprocess is spawned on every
cycle until the panel is closed.

The fix makes seeding structurally unable to reach the apply path: the bar's
mirrored `@State` is replaced by a single pure Core value type,
`LogFilterDraft`, edited through **user-intent bindings** whose setters both
store the new value *and* apply it, explicitly, with the new value passed in.
`seedFromFilter` assigns the draft directly and therefore cannot call
`onApplyFilter`/`onSearch` — no value-equality suppression is involved
anywhere. The draft also owns the trimming, the day-boundary normalization and
the **verbatim ref preservation** that today's `applyFilter` loses, and is
shared by the macOS bar and the iOS advanced-filter form.

### Root cause (traced live under a debugger)

Repro: open a project, open the Git Log panel, click Since. Over 20 s after that
one click, breakpoint counters show ~14 full cycles of
`LogFilterBar.seedFromFilter` → `LogFilterBar.applyFilter` →
`CommitLogModel.prepareForFilter` (the no-op guard **passed every time**) →
`CommitLogModel.applyFilter` → publish → `.onChange(of: filter)` → seed again.
One captured stop shows the smoking pair: the bar handed `prepareForFilter` a
filter with `since = nil` while `requestedFilter` held
`since = <the checked date>`, and the backtrace runs through the Toggle's change
handler in `dateBound` (`LogFilterBar.swift:171`) with the *transition to false*
as its payload — a flip the seed itself had just made.

Two interlocking halves:

1. **Seeding masquerades as user edits.** `seedFromFilter`
   (`LogFilterBar.swift:185`) writes
   `sinceEnabled`/`since`/`untilEnabled`/`until`/`author`/`path`/`search`
   whenever the model re-publishes its filter, and the controls' own `.onChange`
   handlers (`:171`, `:175`, and the search field's `:159`) respond by calling
   `applyFilter()` / `onSearch(_:)`. The bar cannot tell a seed from a click.
   The same trap was already diagnosed and cured for the ref picker
   (`refSelectionBinding` — "so a model-published filter change can't
   masquerade as a user selection and drive a refetch loop"); the toggles and
   date pickers reintroduced it through mirrored `@State` + `.onChange`.

2. **The echo guard only works with one apply in flight.**
   `CommitLogModel.prepareForFilter` (`CommitLogModel.swift:308`) drops an echo
   by comparing it to `requestedFilter`, and its comment asserts the re-seed
   echo "still no-ops here (it equals the latest requested value)". That holds
   only while publishes and requests alternate strictly. `applyFilter` publishes
   `filter = newFilter` synchronously at task start (`CommitLogModel.swift:360`)
   and *then* awaits git, so as soon as two applies interleave (the user toggles
   while the panel's opening refresh, or any earlier apply, is still in flight)
   each publish lands one phase behind the latest request. Every seed then
   writes the *opposite* of `requestedFilter`, every echo differs from it, every
   echo is accepted, re-published and re-seeded — a ping-pong needing no timer
   and almost no CPU. The generation tokens correctly make the newest fetch win;
   they do nothing about the alternating publishes that keep the loop fed.

A third, contributing defect found while tracing: `applyFilter` re-derives the
branch through `filter.resolvedRef(amongKnown: references)`, so any apply fired
while `references` is still empty (the panel's opening refresh has not returned
the ref list) silently rewrites `.ref(branch)` into `.all` — which is why the
picker loses the selected branch. `resolvedRef` is a *display* resolution; using
it on the write path is the bug. The draft carries the ref selection verbatim,
so an apply driven by a date/author/path edit can no longer rewrite it.

### Why this construction (recorded in the code too)

Requirement 1 rules out value-equality suppression, which is precisely the guard
that failed under interleaving. A reentrancy latch would work at runtime but
leaves the apply path reading mirrored `@State` — the stale read that let an
apply carry `since = nil` right after the user checked Since. The user-intent
binding removes both hazards structurally: apply is reachable **only** from a
`Binding.set` or an explicit `onSubmit`, and it is handed the new value, never a
re-read of state.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/LogFilterDraft.swift`
  - Create: `Tests/PisakaCoreTests/LogFilterDraftTests.swift`
  - Modify: `Sources/Pisaka/LogFilterBar.swift` (the loop's macOS half)
  - Modify: `Sources/Pisaka/iOS/LogFilterBar_iOS.swift` (audit + shared draft)
  - Modify: `Sources/PisakaCore/CommitLogModel.swift` (false comment;
    `currentRequestedFilter`)
  - Modify: `Sources/PisakaCore/LogFilter.swift` (comments only)
  - Modify: `Tests/PisakaCoreTests/CommitLogModelTests.swift` (interleaving
    regression test)
  - Modify: `docs/architecture/core-git-models.md`,
    `docs/architecture/app-git-views.md`, `docs/architecture/app-ios.md`,
    `CLAUDE.md` (one index line)
- Related patterns:
  - `refSelectionBinding` — the in-repo precedent for a computed binding that
    reads the model and writes only through the apply path.
  - Pure-engine-plus-thin-glue: every decision in Core, unit-tested; views only
    wire triggers.
  - `StubGit.gateCommits` + `waitForGatedCalls(_:in:)` in `CommitLogModelTests`
    — the existing causal rendezvous for staging overlapping fetches (no timed
    waits).
- Dependencies: none.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core type and
  the model test; the view layer stays untested by convention.
- Complete each task fully before moving to the next.
- Core stays Foundation-only; `Calendar` is injectable so date-boundary tests
  are timezone-deterministic.
- **CRITICAL: every task MUST include new/updated tests** (view-only tasks state
  explicitly which Core tests cover the moved decision).
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: `LogFilterDraft` — the pure, testable filter-bar draft

**Files:**
- Create: `Sources/PisakaCore/LogFilterDraft.swift`
- Create: `Tests/PisakaCoreTests/LogFilterDraftTests.swift`

- [x] add `public struct LogFilterDraft: Equatable` holding the bar's editable
      state: `refSelection: LogFilter.RefSelection`, `author: String`,
      `path: String` (both verbatim/untrimmed as typed), `sinceEnabled: Bool`,
      `since: Date`, `untilEnabled: Bool`, `until: Date`
- [x] add `public init(filter: LogFilter, defaultDate: Date)`: seeds every
      dimension from `filter`; a `nil` bound disables its toggle and parks the
      picker on `defaultDate`; a present bound is seeded **verbatim** (the
      inclusive end-of-day instant is still on the selected day, so `filter()`
      re-derives the same bound — the round-trip is idempotent and needs no
      inverse, as `since`'s start-of-day already is)
- [x] add `public func filter(calendar: Calendar = .current) -> LogFilter`:
      trims author/path (blank → `nil`), normalizes `since` to the start of the
      selected day and `until` to the *last second* of the selected day (git's
      `--until` is inclusive), and carries `refSelection` through **verbatim**
      — never re-resolved against the known refs, which is what today's
      `applyFilter` gets wrong
- [x] add the picker seam so both platforms stop duplicating the sentinel:
      `public static let allRefsTag = ""`,
      `public func displayRefTag(amongKnown references: [String]) -> String`
      (the *display* resolution, via `LogFilter.resolvedRef(amongKnown:)`,
      mapping `nil` onto `allRefsTag`) and
      `public mutating func selectRef(tag: String)` (empty tag → `.all`, else
      `.ref(tag)`)
- [x] document on the type *why* it exists: it is the value a user-intent
      binding writes and applies, so seeding a view's state can never reach the
      apply path — the structural cure for the seed/echo loop, replacing the
      equality guard that failed under interleaved applies
- [x] write `LogFilterDraftTests`: seeding both present and absent bounds;
      trimming and blank→`nil` for author/path; start-of-day /
      last-second-of-day normalization against a fixed-timezone `Calendar`;
      idempotent seed→`filter()`→seed round-trip; verbatim ref preservation with
      an **empty** `references` list (the picker still displays "All" via
      `displayRefTag`, while `filter()` still emits `.ref(name)`);
      `selectRef(tag:)` both ways; `Equatable`
- [x] run `swift test` — must pass before Task 2

### Task 2: Rebuild the macOS filter bar on user-intent bindings

**Files:**
- Modify: `Sources/Pisaka/LogFilterBar.swift`

- [x] replace the seven mirrored `@State` properties with
      `@State private var draft: LogFilterDraft` plus
      `@State private var search: String` (the message search is not a
      `LogFilter` dimension)
- [x] add one private helper producing a **user-intent binding**: its `get`
      reads the draft, its `set` writes the mutated draft into `@State` *and*
      calls `onApplyFilter(updated.filter())` with the new value passed
      explicitly — no re-read of possibly-stale state; wire the Since/Until
      toggles and both date pickers through it and delete every `.onChange` on
      those controls
- [x] bind the ref picker's `get` to
      `draft.displayRefTag(amongKnown: references)` and its `set` to
      `selectRef(tag:)` + apply, replacing `refSelectionBinding` and removing
      the view's own `allRefsTag`; delete `applyFilter(refOverride:)`,
      `endOfDay(of:)` and the in-view filter assembly — the draft owns all of
      it now
- [x] keep author/path on plain draft projections plus their existing
      `.onSubmit` trigger (typing must not re-fetch); the Return handler applies
      `draft.filter()` once
- [x] route the search field through a binding whose `set` assigns `search` and
      calls `onSearch(newValue)`, deleting `.onChange(of: search)` so the seed
      cannot echo
- [x] rewrite `seedFromFilter` as a direct assignment of `draft`/`search` from
      `filter`/`searchQuery`; state in its doc comment that it is *unable* to
      reach the apply path because every apply lives in a binding setter or
      `onSubmit`, and that this is the requirement — not an equality check,
      which is what failed before
- [x] update the type's header comment: what the bar mirrors, why the draft is
      the single editable value, and why a model-published filter can now update
      every control silently
- [x] tests: the decisions this task moves out of the view (assembly, trimming,
      normalization, ref preservation, tag mapping) are covered by
      `LogFilterDraftTests` from Task 1; the view itself stays untested per
      convention — re-run `swift test` to confirm the suite is still green
      before Task 3

### Task 3: Audit the iOS filter bar and share the draft

**Files:**
- Modify: `Sources/Pisaka/iOS/LogFilterBar_iOS.swift`

- [x] record the audit outcome in the file's doc comment: the advanced form is
      **immune** to the loop by construction (it is seeded once in `init` and
      applies only from the explicit Apply button, so no model publish reaches
      it), while the compact bar's search field carries the *same* masquerade
      shape — `.onChange(of: searchQuery)` seeds `search`, whose `.onChange`
      calls `onSearch`
- [x] route the iOS search field through the same user-intent binding (set →
      assign + `onSearch(newValue)`) and drop `.onChange(of: search)`
- [x] rebuild `LogAdvancedFilterForm_iOS` on `LogFilterDraft`: one
      `@State private var draft` seeded in `init` via
      `LogFilterDraft(filter:defaultDate:)`, Apply reporting `draft.filter()`,
      Clear resetting the text/toggle fields on the draft; delete the duplicated
      trimming, `endOfDay(of:)` and the hand-rolled seeding (this also unifies
      the empty-bound placeholder date, which the form previously parked at the
      epoch)
- [x] replace the bar's own `allRefsTag`/`selectedRef`/`applyRef` sentinel
      handling with `LogFilterDraft.allRefsTag` and the draft's
      `displayRefTag`/`selectRef` seam, keeping today's verbatim ref write
      (which was already correct on iOS)
- [x] tests: covered by `LogFilterDraftTests`; run `swift test` — must pass
      before Task 4

### Task 4: Correct the model's echo contract and pin the interleaving

**Files:**
- Modify: `Sources/PisakaCore/CommitLogModel.swift`
- Modify: `Tests/PisakaCoreTests/CommitLogModelTests.swift`

- [x] rewrite the false claim on `prepareForFilter` — the re-seed echo does
      **not** always no-op: the published `filter` lags the latest
      `requestedFilter` by one phase whenever two applies interleave, so an echo
      built from the published value is a genuinely different filter and is
      accepted. Say plainly that the model's guard orders requests and cannot
      suppress a view echo, and that not echoing is the *view's* obligation
      (naming the binding construction as the mechanism)
- [x] apply the same correction to the matching commentary in
      `Sources/Pisaka/CommitLogView.swift`'s `applyFilter`, which repeats the
      claim
- [x] expose `public var currentRequestedFilter: LogFilter { requestedFilter }`
      — the symmetric counterpart of the existing `currentRequestGeneration`,
      making the publish-lags-request contract readable and assertable rather
      than folklore
- [x] add a regression test staging two interleaved `applyFilter` tasks with the
      existing `gateCommits`/`waitForGatedCalls` rendezvous (causal, no timed
      waits): with the first apply suspended in git and a second prepared,
      assert `model.filter` (the publish) differs from `currentRequestedFilter`,
      and that `prepareForFilter` fed the *published* filter returns a non-`nil`
      token — i.e. an echo of what the view can see is accepted and would spawn
      a fetch. Name and comment the test as the pin for the one-phase lag the
      view must not rely on
- [x] remove the product-name comparisons from the comments this change rewrites
      (`LogFilter.swift`'s `RefSelection.all` and `search(_:query:)`, and the
      Log view headers), describing the behavior on its own terms
- [x] run `swift test` — must pass before Task 5

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/core-git-models.md`,
  `docs/architecture/app-git-views.md`, `docs/architecture/app-ios.md`,
  `CLAUDE.md`

- [x] `core-git-models.md`: add the full `LogFilterDraft.swift` entry (what it
       holds, the seed/assemble pair, day-boundary normalization, verbatim ref
       preservation vs. `resolvedRef`'s display-only role, the picker tag seam)
       and correct `CommitLogModel`'s echo/no-op contract — the guard orders
       requests, the publish can lag the newest request by one phase, and
       suppressing echoes is the view's job
- [x] `app-git-views.md`: rewrite the `LogFilterBar.swift` entry around the
       seeding rule — seeding assigns the draft directly, every apply is
       reachable only from a binding setter or `onSubmit`, and the ref selection
       is carried verbatim so an apply fired before the ref list arrives can no
       longer collapse the branch to "All"; state that value-equality suppression
       was tried and failed under interleaved applies
- [x] `app-ios.md`: give `LogFilterBar_iOS.swift` a short entry recording the
       audit result (sheet + explicit Apply makes the form immune; the search
       field shared the shape and got the same binding) and its use of the shared
       draft
- [x] `CLAUDE.md`: one index line for `LogFilterDraft.swift` under the
       Log/branch models group, in the existing one-line style (no essay — the
       detail lives in the doc)
- [x] remove the product-name comparisons from the doc passages this change
       rewrites
- [x] run `swift test` (the doc-shape suites read repository files) — must pass

### Task 6: Verify acceptance criteria

- [x] `swift test` green, including `LogFilterDraftTests` and the new model
      regression test
- [x] `swiftlint --strict` clean from the repository root
- [x] `xcodegen generate` then the macOS build:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [x] the iOS build:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [x] grep the touched sources and docs to confirm no product-name comparison
      remains in the rewritten passages

## Post-Completion (manual verification by the user)

- Open a project, open the Git Log panel, and immediately check **Since**: the
  checkbox stays checked, the date field stays enabled, the spinner stops after
  the fetch, the commit list shows the filtered history, and the ref picker
  keeps its selection.
- Repeat for **Until**, for toggling either off, and for a rapid on/off flurry
  (it must settle on the final state).
- Watch process activity (e.g. `pgrep -fl 'git log'` in a loop) and confirm
  there is no repeating spawn after the toggle settles.
- Confirm author/path still apply on Return and the message search still filters
  live, each exactly once per user action, on both macOS and iOS.

## Out of scope

- Filter-bar layout/dimensions; what the filter dimensions mean or how `git log`
  arguments are built (`LogFilter` changes comments only).
- Local Changes / branch-switcher models; persisting filter state across
  sessions.
