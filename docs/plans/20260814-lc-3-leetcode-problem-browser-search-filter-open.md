# LC-3: LeetCode problem browser — search, filter, open

## Overview

The last piece of the approved LeetCode design: a browsable problem list. A window on macOS ("Browse Problems…", ⌘⇧B in the LeetCode menu), a pushed screen on iOS (from the existing LeetCode sheet). The user finds a problem by number, title or slug, narrows by difficulty and by their own progress, sees which rows are Premium-locked, and opens one straight into a solution file through the **existing** `openProblem` flow — same folder rules, same Premium refusal, same never-overwrite guarantee.

Three structural decisions settle the shape before any code:

- **The browser is a pure, client-side filter over the one catalog.** `LeetCodeCatalog` already holds every row (~4000 from one REST request, cached on disk for a day, per-account status included). No GraphQL problem-list query, no paging, no new entry in `LeetCodeAPI.swift` — the browser adds **zero wire surface**, searches instantly, and works offline off the disk cache.
- **`LeetCodeBrowserModel` is a companion model**, owned by `LeetCodeModel` the way `catalog` and `judge` are, holding an `unowned` back-reference for the session. Two reasons, both the LC-2 discipline: `LeetCodeModel` is already ~1070 lines, and the browser surfaces observe *it* — so a keystroke in the search field invalidates the list and nothing bound to the account, the statement or the judge. It carries the **fifth** generation token.
- **Status freshness is the catalog's fetch time.** A row's solved/attempted mark is whatever the account looked like when the list was fetched. So the surface shows *when* it was fetched and offers an explicit Refresh beside the automatic staleness rule, rather than pretending the marks are live.

The layer stays a **reader with no create at all**: it never raises `autosave.suspend()`/`beginRevert()`, is never gated by them, and writes nothing — LC-1's one create (`openProblem`) remains the only write in the area.

## Context

**Files involved (Core):**

- Create: `Sources/PisakaCore/LeetCodeProblemFilter.swift` — the one pure filter function and its value type.
- Create: `Sources/PisakaCore/LeetCodeBrowserModel.swift` — the companion model: published filter/rows, load, explicit refresh, the fifth generation token, the signed-out value.
- Modify: `Sources/PisakaCore/LeetCodeCatalog.swift` — one new entry point, `loadIfNeeded(credentials:)` (disk cache, then a refresh only when stale). No change to the wire format, the staleness policy or the cache schema.
- Modify: `Sources/PisakaCore/LeetCodeModel.swift` — `public private(set) lazy var browser`, and `browser.sessionDidChange()` beside the judge's in `isSignedIn.didSet`.
- **Not modified: `Sources/PisakaCore/LeetCodeAPI.swift`.** That is an acceptance criterion, not an aspiration.

**Files involved (app):**

- Create: `Sources/Pisaka/LeetCodeBrowserView.swift`, `Sources/Pisaka/LeetCodeBrowserWindowController.swift` (`#if os(macOS)`).
- Create: `Sources/Pisaka/iOS/LeetCodeBrowserView_iOS.swift`.
- Modify: `Sources/Pisaka/LeetCodeOpenProblemSheet.swift` (the `LeetCodeCommands` menu gains "Browse Problems…"), `Sources/Pisaka/PisakaApp.swift` (the controller, the open handler, the terminate `closeAll()`), `Sources/Pisaka/iOS/LeetCodeRoute_iOS.swift` (the `NavigationLink` destination).

**Files involved (tests/docs):**

- Create: `Tests/PisakaCoreTests/LeetCodeProblemFilterTests.swift`, `Tests/PisakaCoreTests/LeetCodeBrowserModelTests.swift`.
- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`.
- Modify: `docs/architecture/core-leetcode.md`, `CLAUDE.md`, `README.md`.

**Related patterns to follow:**

- `LeetCodeJudgeModel` — the companion-model shape end to end: `unowned let owner`, `lazy var` on the owner, `sessionDidChange()`, its own generation token, a pure availability enum whose every non-ready case carries the sentence the surface shows.
- `LeetCodeCatalog.resolveSlug` — the degradation rule this ticket reapplies: a refresh that could not be made never throws away what is already in hand.
- `ProjectSearchWindowController` — the single-window macOS pattern (retained `EscClosableWindow`, held delegate, root view replaced on re-show, `closeAll()` on terminate).
- `ScriptedLeetCodeTransport` (`.problemList` route, sticky-last-step queues, `count(for:)` assertions), `StubFileTree`, `Gate`, and `LeetCodeCatalogTests`' injected `now` clock.
- Generation tokens captured synchronously before the first `await`; superseded work publishes nothing.

**Dependencies:** none new. `project.yml`, `Package.resolved`, `Package.swift` and `licenses.json` stay untouched.

## Development Approach

- **Testing approach**: Regular (code first, then tests), matching how the LC-1/LC-2 suites are written.
- Complete each task fully before moving to the next; `swift test` must be green at the end of every task.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- App-layer tasks (4, 5) are untested by convention; their gate is a successful `xcodebuild` for that destination.
- Every decision lives in Core. The views bind controls to published state and contain nothing worth a test.

## Implementation Steps

### Task 1: The filter, as one pure function

**Files:**
- Create: `Sources/PisakaCore/LeetCodeProblemFilter.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeProblemFilterTests.swift`

`LeetCodeProblemFilter` is an `Equatable, Sendable` value with three fields — `query: String`, `difficulties: Set<LeetCodeDifficulty>`, `statuses: Set<LeetCodeProblemStatus>` — and one method, `apply(to rows: [LeetCodeProblem]) -> [LeetCodeProblem]`. One pass over the rows, so **catalog order is preserved by construction** rather than by a sort that could later disagree with it.

The rules, each stated on the type:

- **The query is trimmed of whitespace and newlines.** Empty (or all-whitespace) means every row.
- **Whether a query is a number is asked through `LeetCodeProblemInput.parse(_:)`**, so L4 — "an all-digit input is a number attempt and nothing else" — is reused rather than restated. A `.number(n)` matches `frontendID == n` **exactly**, and matches nothing else: `1` answers problem 1 rather than the ~1000 rows whose number starts with a 1. Every other parse result — a slug, a URL, or nothing at all — falls through to the substring branch (so a pasted problem URL matches nothing here; the Open Problem field is that paste's surface, and it already handles it).
- **The substring match is case-insensitive over the title *or* the slug**, through `range(of:options: .caseInsensitive)` — deliberately not the `localized…` variants, so the answer does not depend on the device's locale and the table test is stable.
- **Difficulty and status are set membership, and an empty set means no filtering.** That makes "nothing selected" and "everything selected" behave identically, which is what a row of toggles needs.
- **`isPaidOnly` is not a dimension of this type at all.** Premium rows are shown with a lock marker and can never be hidden — hiding them would misrepresent LeetCode's numbering. Stating it as an absent field rather than as a flag defaulted to `false` is what makes it structural.

Add `var isEmpty: Bool` (no query, no difficulty selection, no status selection) so a surface can tell "no problems match your filter" from "no problems at all".

- [x] write `LeetCodeProblemFilter.swift` with the value type, `apply(to:)`, `isEmpty`, and the rules documented on the type
- [x] write `LeetCodeProblemFilterTests` as a table over a fixed, deliberately out-of-order row set: exact number query; a number with no such problem; leading/trailing whitespace; title substring; slug substring; mixed-case query both ways; empty query; each difficulty set and a two-element one; each status set; difficulty ∩ status ∩ query combined; paid rows present under every combination including a query that matches only paid rows; catalog order preserved when the input order is not sorted; `isEmpty`
- [x] run `swift test` — must pass before Task 2

### Task 2: The catalog's browsing entry point

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeCatalog.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`

The catalog today is reachable for *browsing* only through `resolveSlug(forNumber:)` (which forces a refresh on a miss — wrong here) and `cachedProblem(forSlug:)` (disk only, never the network). Add one method:

```swift
public func loadIfNeeded(credentials: LeetCodeCredentials) async throws
```

Consult the disk cache once (the existing coalesced `loadFromDiskIfNeeded()`), then refresh **only when `isStale`**, through the existing coalesced `refresh(credentials:)`. Nothing else: no forced-on-miss branch (there is no miss — the browser wants the whole list), no new policy, no change to `maximumAge`, the DTO or `currentSchemaVersion`. `problems` and `fetchedAt` are already public, so the caller reads the result off the same accessors every other reader uses.

It **throws whatever the refresh threw**, deliberately: the degradation rule ("stale rows beat no rows") belongs to the surface that has rows on screen, not to the catalog, and `problems` is right there for the caller to check. Document that in one sentence on the method, pointing at `resolveSlug`'s own version of the rule.

- [ ] add `loadIfNeeded(credentials:)` with its note; no other catalog change
- [ ] extend `LeetCodeCatalogTests`: a cache written inside the staleness window makes **zero** `problemList` requests; an absent cache makes exactly one; a cache older than `maximumAge` makes exactly one; two overlapping `loadIfNeeded` calls (staged with `Gate`) coalesce onto one request; a refresh failure with a warm disk cache throws while `problems` stays populated
- [ ] run `swift test` — must pass before Task 3

### Task 3: `LeetCodeBrowserModel` — the companion

**Files:**
- Create: `Sources/PisakaCore/LeetCodeBrowserModel.swift`
- Modify: `Sources/PisakaCore/LeetCodeModel.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeBrowserModelTests.swift`

A `@MainActor public final class LeetCodeBrowserModel: ObservableObject` with `private unowned let owner: LeetCodeModel`, constructed as `LeetCodeModel`'s `public private(set) lazy var browser` for exactly the judge's reason (it is constructed with `self`).

Published state:

- `@Published public var filter: LeetCodeProblemFilter { didSet { refilter() } }` — one bindable value, and the one place filtering is recomputed, so no surface can set a field and forget to re-run it. Filtering is **synchronous and pure**; it takes no generation token because there is nothing to supersede.
- `@Published public private(set) var problems: [LeetCodeProblem]` (everything known) and `visibleProblems: [LeetCodeProblem]` (what the filter leaves). Both stored — a computed `visible` would re-filter 4000 rows on every SwiftUI body evaluation.
- `@Published public private(set) var fetchedAt: Date?` — what "Updated …" renders from.
- `@Published public private(set) var isLoading: Bool`, `@Published public private(set) var lastError: LeetCodeError?`.
- `@Published public private(set) var availability: LeetCodeBrowserAvailability` — the judge's pattern: `.ready` / `.notSignedIn`, with a `reason` sentence on the refusal ("Sign in to LeetCode to browse problems."). **Signed out is a value the surface renders, not an error dump**, and not a `Bool` the view has to invent a sentence for.

Behaviour:

- `public func load() async` — the idempotent entry the surfaces call on appear. Bumps the token synchronously, resolves the session (none → publish `.notSignedIn`, no rows cleared, no error), calls `catalog.loadIfNeeded`, and publishes `catalog.problems` + `catalog.fetchedAt` under the token. Costs no request inside the staleness window.
- `public func refresh() async` — the explicit affordance. Same shape but through `catalog.refresh(credentials:)`, which fetches whatever the age.
- **A failure with rows already published keeps them**, and publishes the typed `LeetCodeError` beside them (`resolveSlug`'s rule, applied here): a refresh that could not be made must not blank a list the user is reading. With no rows in hand the error stands alone.
- `func sessionDidChange()` — bumps the token (so anything in flight publishes nothing), recomputes `availability`, clears `lastError`, and **clears the rows**: the status column is per-account, and leaving one account's solved marks under another's name is the one wrong thing this surface could show. The next `load()` republishes from the catalog.
- The token is the **fifth**, beside open/statement/account/judge, and is bumped by `load()`, `refresh()` and `sessionDidChange()`.

In `LeetCodeModel`: add the `lazy var browser`, and call `browser.sessionDidChange()` in `isSignedIn`'s `didSet` beside `judge.sessionDidChange()` — one writer, one hook, exactly as that property already documents.

- [ ] write `LeetCodeBrowserModel.swift` (+ `LeetCodeBrowserAvailability`) with the notes above
- [ ] wire `browser` and its `sessionDidChange()` into `LeetCodeModel`
- [ ] write `LeetCodeBrowserModelTests` driving a real `LeetCodeModel` over `ScriptedLeetCodeTransport` + `StubFileTree` with an injected clock: a warm disk cache loads with zero requests; a cold one fetches once and publishes rows, `fetchedAt` and no error; `refresh()` fetches again inside the staleness window and republishes; a failing refresh keeps the previous rows and publishes the typed error; a failing first load publishes the error with no rows; signed out publishes `.notSignedIn` and makes no request; a sign-in re-arms availability and a sign-out clears the rows; a `load()` held on a `Gate` while a sign-out bumps the token publishes **nothing**; setting `filter` republishes `visibleProblems` without touching the transport
- [ ] run `swift test` — must pass before Task 4

### Task 4: The macOS browser window

**Files:**
- Create: `Sources/Pisaka/LeetCodeBrowserView.swift`, `Sources/Pisaka/LeetCodeBrowserWindowController.swift`
- Modify: `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`, `Sources/Pisaka/PisakaApp.swift`

`LeetCodeBrowserWindowController` is `ProjectSearchWindowController` verbatim in shape — one window per app, an existing one has its root view replaced and is focused rather than duplicated, released by a held `NSWindowDelegate`, `closeAll()` joined to the app's `willTerminateNotification` observer beside the diff/merge/search controllers. Two windows over one browser model would fight over its single filter, which is the same argument Find in Files already makes.

`LeetCodeBrowserView` observes the **browser** and the `SettingsStore`, and takes the open handler as a closure. It carries: a search field bound to `browser.filter.query`; difficulty and status filter controls; a language `Picker` bound to `settings.leetCodeLanguage` (the same persisted setting the Open Problem sheet writes, so the two cannot disagree); a `Table` with number, title, difficulty and status columns, a lock marker on `isPaidOnly` rows; a footer with "showing X of Y", the fetched-at time and a Refresh button; open on double-click **and** an explicit Open button. Signed out, it shows the offer in place and presents the existing `LeetCodeLoginView` nested — the sheet's rule, and for the sheet's reason — then `load()`s once signed in.

Opening reuses `PisakaApp.openLeetCodeProblem(input:language:)` with `.slug(row.slug)`: the same folder establishment, the same Premium refusal, the same never-overwrite, the same tab. **No second open path exists.** A refusal is shown inline in the window rather than as an alert, matching the sheet. The window stays open (browsing several problems is the point) and the editor window is raised behind it — the app has one `WindowGroup` window and its auxiliary windows are all `EscClosableWindow`, so "the first visible, main-capable window that is not one of ours" is the rule, written down where it is used.

`LeetCodeCommands` gains `Button("Browse Problems…")` with ⌘⇧B (free — the shortcut audit in this repo shows ⌘⇧B unused), above the divider beside "Open Problem…", gated on nothing: a LeetCode problem needs no open project.

- [ ] write the window controller (single window, held delegate, `closeAll()`)
- [ ] write `LeetCodeBrowserView` (search, filters, language picker, table with lock marker, footer with fetched-at + Refresh, double-click and Open, signed-out offer with the nested login sheet)
- [ ] add the menu item and its ⌘⇧B shortcut; wire the controller, the open handler and the terminate `closeAll()` in `PisakaApp`
- [ ] build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` (untested by convention; the build is the gate)
- [ ] run `swift test` — must pass before Task 5

### Task 5: The iOS browser screen

**Files:**
- Create: `Sources/Pisaka/iOS/LeetCodeBrowserView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/LeetCodeRoute_iOS.swift`

`LeetCodeRoute_iOS` already hosts a `NavigationStack`, so the destination is a `NavigationLink("Browse Problems")` row in a section of its own — the one new entry point on this platform.

`LeetCodeBrowserView_iOS` uses native idioms and the same Core model: `.searchable` bound to `browser.filter.query`, a toolbar `Menu` of difficulty and status toggles, `.refreshable` mapped to `browser.refresh()`, `.task { await browser.load() }`, and a `List` of rows carrying number, title, difficulty, the lock marker and the status mark. A footer row shows "showing X of Y" and the fetched-at time.

**No cap and no truncation.** `List` is lazy on iOS, the rows are plain text, and filtering ~4000 rows is one pure pass; if profiling on device ever says otherwise the answer is a stated "keep typing to narrow" affordance, never a silent cut. `ForEach(…, id: \.slug)` keeps `LeetCodeProblem` free of an `Identifiable` conformance it does not otherwise need.

Tapping a row calls the route's existing `onOpen(.slug(row.slug), settings.leetCodeLanguage)`; a `nil` sentence means it opened, so the screen calls the route's `onDone` and the whole sheet dismisses with the tab open behind it — LC-1's open behaviour, including the compact-width push. A sentence is shown inline. Signed out, the screen shows the same offer as the account row and no list.

- [ ] write `LeetCodeBrowserView_iOS` (searchable, filter menu, refreshable, lazy list, open on tap, signed-out offer)
- [ ] add the `NavigationLink` destination in `LeetCodeRoute_iOS`, forwarding `onOpen`/`onDone`
- [ ] build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] run `swift test` — must pass before Task 6

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture/core-leetcode.md`, `CLAUDE.md`, `README.md`

`core-leetcode.md` gains full entries for `LeetCodeProblemFilter.swift`, `LeetCodeBrowserModel.swift`, the catalog's new entry point, and the three app files, plus the L-series continued:

- **L23 — the browser is a client-side filter over the one catalog.** The whole list is already in hand, so search is a pure pass over rows rather than an endpoint: no GraphQL problem-list query, no paging, **no new entry in `LeetCodeAPI.swift`**, instant results, and a browser that works offline off the disk cache. It reads the *existing* `LeetCodeModel.catalog` — a second catalog would mean a second disk cache and a second staleness clock.
- **L24 — status freshness is the catalog's fetch time, and the surface says so.** A problem solved five minutes ago shows as solved only after a refresh, so the fetched-at time is shown beside an explicit Refresh; a refresh that fails keeps the rows it has (`resolveSlug`'s degradation rule on a new axis). Signing in as a different account shows the previous account's marks until a refresh, because the cache is per app, not per account.
- **L25 — the browser is the fifth generation token, and the number query is exact.** A companion model like the judge, observed by the browser surfaces alone; and an all-digit query is a number attempt and nothing else (L4 reused through `LeetCodeProblemInput.parse`, not restated), matching `frontendID` exactly rather than by prefix.

Known limits gain: the per-account status is as old as the catalog fetch (with the cross-account note); no topic/tag, company, favorites or study-plan filters, because each needs a GraphQL surface this design avoids; no sorting beyond LeetCode's own order; a pasted problem URL matches nothing in the search field. The existing "no submission history" line stays true and unchanged.

`CLAUDE.md` gains one index line per new file in the LeetCode blocks, and the LeetCode cross-cutting invariant gains a clause: the browser is a reader that creates nothing at all, so LC-1's one create stays the only write in the area.

`README.md` gains the browser to the LeetCode bullets on both platforms (the ⌘⇧B menu item on macOS, the Browse Problems screen on iOS) and to the shortcut list.

- [ ] update `docs/architecture/core-leetcode.md`: file entries, L23–L25, known limits
- [ ] update `CLAUDE.md` index lines and the LeetCode invariant clause
- [ ] update `README.md` features and shortcuts
- [ ] run `swift test` — must pass before Task 7

### Task 7: Verify acceptance criteria

- [ ] run `swift test` — full suite green
- [ ] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] confirm with `git diff --name-only` that `project.yml`, `Package.resolved`, `Package.swift`, `Resources/Licenses/licenses.json` and **`Sources/PisakaCore/LeetCodeAPI.swift`** are untouched
- [ ] confirm the new Core suites cover every acceptance bullet: filter table, cache-served load, forced refresh, refresh failure keeping rows, superseded load publishing nothing, signed-out as a value, session change re-arming

## Post-Completion (manual, user-run)

- macOS: LeetCode → Browse Problems… (⌘⇧B); type `two` and see Two Sum with every title containing it; type `1` and see problem 1; filter Hard + unsolved; double-click a row and confirm the solution file opens under LC-1's rules with the editor window raised; confirm a Premium row shows the lock and refuses with the Premium sentence; press Refresh and watch the fetched-at time move.
- macOS: sign out, reopen the window, confirm the sign-in offer renders in place and the list populates after signing in.
- iOS: LeetCode screen → Browse Problems; the same search and filters; pull to refresh; tap a row and confirm the sheet dismisses and the tab opens (compact width pushes the editor).
- iOS: scroll the unfiltered ~4000-row list and confirm it stays smooth.
