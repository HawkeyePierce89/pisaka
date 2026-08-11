# LC-1: LeetCode integration core — login, open problem, solution file, description panel

## Overview

Foundation of the LeetCode integration on macOS, iPad and iPhone: sign in through a real
browser session (WKWebView), open a problem by number / slug / URL, materialise a solution
file seeded from LeetCode's own code snippet inside a dedicated LeetCode folder, and render
the problem statement in a panel beside the editor.

All decidable logic lives in a new `core-leetcode` area of `PisakaCore` (Foundation-only,
fully unit-tested), built on the same shapes the LSP layer established: a transport **seam
protocol** with a scripted fake in tests, a single file that owns every piece of LeetCode
schema knowledge so an upstream change is a one-file fix, typed errors with user-facing
sentences, generation tokens captured synchronously before the first `await`, and a layer
that is a **reader** everywhere except the one solution-file write, which goes through
`FileServicing` and never takes the writer gate.

The app layer stays thin and untested: a shared `URLSession` transport, a cross-platform
Keychain credential store, two WKWebView surfaces (login, statement) per platform, and the
entry points (macOS menu + dialog, iOS root-navigation section).

Per the iteration-1 answer, the problem catalog is built from the legacy REST
`GET /api/problems/all/` — one request for all ~4000 problems instead of ~41 paged GraphQL
calls — and that second response shape is parsed in the same schema file as the GraphQL
ones, behind the same "API changed" error.

## Context

- **Core seam/model precedents**: `Sources/PisakaCore/LSPTransport.swift` (bytes-in/bytes-out
  seam whose only implementation is app-side), `LSPProvisioning.swift` (main-actor
  `ObservableObject` owning an async flow), `LSPInstallLayout.swift` (pure path math over a
  base directory the app supplies), `SymbolIndexModel.swift` (generation-pinned async work),
  `GitCredentials.swift` (value type + `CredentialStore` protocol with defaulted members).
- **App seam precedents**: `Sources/Pisaka/LSPDownloadService.swift` (the real URLSession side
  of a Core seam), `Sources/Pisaka/iOS/KeychainCredentialStore.swift` (Security-framework IO,
  iOS-only — the new store is its cross-platform sibling under `Sources/Pisaka/Platform/`).
- **Settings/persistence**: `Sources/PisakaCore/SettingsStore.swift` (injected `UserDefaults`,
  stable key enum), `ScopedFileAccess.swift` + `Sources/Pisaka/iOS/SecurityScopedBookmarks.swift`
  (iOS bookmark story), `Sources/Pisaka/FilePanels.swift` (macOS open panels).
- **Sandbox fact that simplifies macOS**: the repo ships **no** `.entitlements` file and
  `project.yml` enables no App Sandbox, so the macOS app is unsandboxed. The macOS LeetCode
  folder is therefore a plain persisted path chosen through an `NSOpenPanel` pre-targeted at
  `~/Documents/LeetCode` — *no* security-scoped bookmark, exactly like how projects are opened
  today. Bookmarks stay an iOS-only concern.
- **Cache root**: `PisakaApp.swift` already resolves `~/Library/Application Support/Pisaka` for
  the LSP install root; the LeetCode catalog + statement cache sit beside it under
  `…/Pisaka/LeetCode/`. On iOS the same subdirectory lives in the container's Application
  Support. Core does the path math, the app supplies the base.
- **Editor/panel wiring**: `Sources/Pisaka/ContentView.swift` (`HSplitView` + bottom dock),
  `Sources/Pisaka/PisakaApp.swift` (menu commands, folder/tab orchestration),
  `Sources/Pisaka/iOS/RootView_iOS.swift`, `MergeRoute_iOS.swift` (the adaptive
  side-by-side-vs-screen pattern the statement panel imitates on iPad/iPhone).
- **Tests**: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift` (the fake to imitate),
  `StubFileTree.swift` (in-memory `FileServicing`, mutable half), `Package.swift`'s
  `exclude: ["Fixtures/LSP"]` (fixtures are read via `#filePath`, never bundled).
- **Dependencies**: none new. WebKit and Security are system frameworks; `project.yml` pins,
  `Package.resolved` and `licenses.json` are untouched.

### LeetCode API surface this ticket uses (all schema knowledge in one Core file)

- `POST https://leetcode.com/graphql` with `Cookie: LEETCODE_SESSION=…; csrftoken=…`,
  `x-csrftoken`, `Referer: https://leetcode.com/`, `Content-Type: application/json`.
- `globalData { userStatus { username isSignedIn isPremium } }` → login confirmation;
  `isSignedIn == false` is the canonical logged-out signal.
- `questionData(titleSlug:)` → `questionFrontendId`, `title`, `titleSlug`, `content`,
  `difficulty`, `isPaidOnly`, `codeSnippets { langSlug code }`, `exampleTestcaseList`.
- `GET https://leetcode.com/api/problems/all/` → `stat_status_pairs[]` with
  `stat.frontend_question_id`, `stat.question__title`, `stat.question__title_slug`,
  `difficulty.level`, `paid_only`, `status` — the whole catalog in one response.

### Product decisions taken here (stated so the implementation does not re-litigate them)

- **Every LeetCode operation requires login.** Logged out, "Open Problem…" reports
  `notLoggedIn` and offers sign-in rather than silently fetching anonymous content; LC-2's
  Run/Submit need the session anyway, and `paid_only`/solved status only exist with it.
- **Opening a problem never changes the project root.** The solution file is opened as a
  regular editor tab through `WorkspaceModel.open(url:)`; choosing to browse the LeetCode
  folder as a project stays the user's separate action.
- **Association is by file name**, both for the description panel now and for LC-2 later: the
  active tab's last path component parses back to a problem number, and the tab's URL must sit
  inside the configured LeetCode folder.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Every Core task ends with new suites;
  `swift test` must be green before the next task starts.
- Domain logic in `PisakaCore` (Foundation-only — no WebKit, no `URLSession` beyond the seam
  protocol's value types); app views thin and untested; macOS under `#if os(macOS)`, iOS in
  `Sources/Pisaka/iOS/`, shared app code in `Sources/Pisaka/Platform/`.
- Fixtures are recorded from the live public endpoints, trimmed to a handful of entries for the
  2 MB list, committed under `Tests/PisakaCoreTests/Fixtures/leetcode/`, read through
  `#filePath`, and added to the test target's `exclude:`.
- Generation tokens captured synchronously before the first `await`; superseded work discards
  its result instead of publishing over newer state.
- **CRITICAL: every task ships new/updated tests, and all tests pass before the next task.**

## Implementation Steps

### Task 1: Core — value types, transport seam, credentials, typed errors

**Files:**
- Create: `Sources/PisakaCore/LeetCodeTransport.swift`, `LeetCodeCredentials.swift`,
  `LeetCodeError.swift`, `LeetCodeProblem.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeCredentialsTests.swift`, `LeetCodeErrorTests.swift`

Intent: the vocabulary the rest of the area speaks, ahead of any IO — a transport seam whose
only real implementation is app-side, credentials as a value behind a store protocol, and the
one error type every failure funnels into.

- [x] `LeetCodeHTTPRequest` (method, url, headers, optional body) and `LeetCodeHTTPResponse`
  (status code, headers, `Data`) as plain value types, plus
  `protocol LeetCodeTransport: Sendable { func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse }`.
  No `URLRequest`, no `URLSession`, no cookie jar — Core composes headers itself so the tests
  can assert them byte for byte.
- [x] `LeetCodeCredentials` — the `LEETCODE_SESSION` + `csrftoken` pair, `Equatable`, with the
  pure rule that turns a list of `(name, value)` cookie pairs into credentials or `nil` (both
  required, empty values rejected) so the two WKWebView cookie observers share one rule.
- [x] `LeetCodeCredentialStore` protocol (`load()` / `save(_:)` / `clear()`), members defaulted
  so partial in-memory stubs compile, absence being the explicit "logged out" signal.
- [x] `LeetCodeError: Error, LocalizedError` with `notLoggedIn`, `network(reason:)`,
  `apiChanged(detail:)`, `paidOnly(slug:)`, `throttled(retryAfter:)`, `folderUnavailable`,
  `fileSystem(reason:)` — each with a user-facing `errorDescription` sentence.
- [x] `LeetCodeProblem` (frontend id, slug, title, difficulty, paid-only, solved/attempted
  status) and `LeetCodeProblemDetail` (the above + HTML statement, `[langSlug: code]` snippets,
  example test cases).
- [x] Tests: cookie-pair → credentials (both present, one missing, empty value, extra cookies
  ignored), every error's `errorDescription` is non-empty and distinct.
- [x] `swift test` — green.

### Task 2: Core — the one schema file: request building and response parsing

**Files:**
- Create: `Sources/PisakaCore/LeetCodeAPI.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeAPITests.swift`
- Create: `Tests/PisakaCoreTests/Fixtures/leetcode/*.json` (recorded responses)
- Modify: `Package.swift` (`exclude:` gains `Fixtures/leetcode`)

Intent: concentrate every fact about LeetCode's wire format here — URLs, GraphQL documents,
header names, JSON key paths — so a LeetCode-side change is diagnosed and fixed in one file,
and every shape mismatch becomes `apiChanged` rather than a silent empty result.

- [x] Request builders for the three calls (user status, question detail, the REST problem
  list): exact GraphQL query strings and variables, `Cookie`, `x-csrftoken`, `Referer`,
  `Content-Type`, `User-Agent`.
- [x] Parsers producing the Task 1 models. A `data` member that is absent, null, or missing a
  required key throws `apiChanged` naming the key path; a GraphQL `errors` array is inspected
  for the paid-only/authentication phrasings and mapped to `paidOnly` / `notLoggedIn`; HTTP 429
  (or a 403 with LeetCode's throttle body) maps to `throttled`; `userStatus.isSignedIn == false`
  is the logged-out verdict wherever it appears.
- [x] Difficulty mapping for both spellings: GraphQL's `"Easy"/"Medium"/"Hard"` and REST's
  `level: 1/2/3`, with an unknown value being `apiChanged` rather than a silent default.
- [x] Record fixtures from the live endpoints (anonymous is enough for shape): a question
  detail, a user-status response signed-in and signed-out, a paid-only detail, a trimmed
  problem list (a dozen `stat_status_pairs`), a throttle body, and hand-authored
  shape-violation variants.
- [x] Tests: exact request bodies/headers per call; every fixture parses to the expected model;
  each violation fixture throws `apiChanged`; logged-out, paid-only and throttled responses each
  produce their own error.
- [x] `swift test` — green.

Notes from the implementation (decisions the later tasks inherit):

- **`data.question: null` is "no such problem", not `apiChanged`** — recorded from the live
  endpoint, which answers HTTP 200 with that body for an unknown slug. `parseQuestionDetail`
  therefore returns an **optional** detail, which is what lets Task 4's catalog report
  not-found without an error and Task 6 tell a typo apart from a schema change.
- **Premium detail parses, it does not throw.** LeetCode answers a paid problem with
  `isPaidOnly: true` *and* null `content`/`codeSnippets`; the parser tolerates both and hands
  the flag on, so the `paidOnly` refusal stays where Task 6 puts it — the layer that knows a
  file was about to be written.
- **`status` is the one lenient mapping.** An unrecognised per-account `status` degrades to
  `.notStarted` rather than failing the parse: it is cosmetic and per-row, and being strict
  would let one odd row out of ~4000 kill the whole catalog, and with it every open. Difficulty
  stays strict; the asymmetry is asserted by a test so it cannot be "tidied" either way.
- `LeetCodeAPI.UserStatus` is declared in the schema file (it is a response shape, not a domain
  model). `parseProblemList` deliberately ignores the catalog's own `user_name`, so login has
  exactly one source of truth.

### Task 3: Core — problem input parser, solution file names, language mapping

**Files:**
- Create: `Sources/PisakaCore/LeetCodeProblemInput.swift`, `LeetCodeSolutionFile.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeProblemInputTests.swift`,
  `LeetCodeSolutionFileTests.swift`

Intent: the two pure string layers the entry points and the description panel stand on — what
the user typed, and how a file name names a problem.

- [x] `LeetCodeProblemInput.parse(_:)` → `.number(Int)` / `.slug(String)`, accepting a bare
  number, a slug, and a full URL (`https://leetcode.com/problems/two-sum/`, with or without
  scheme, trailing path like `/description/`, query and fragment, `www.` host), trimming
  whitespace and rejecting empty/garbage with `nil`.
- [x] `LeetCodeSolutionFile.name(number:slug:language:)` → `0001-two-sum.swift` (four-digit zero
  padding, wider numbers pass through), and the reverse `problemNumber(fromFileName:)` plus
  `slug(fromFileName:)` tolerant of paths and unknown extensions.
- [x] `SyntaxLanguage` ↔ LeetCode `langSlug` mapping covering at least swift, python3, golang,
  rust, typescript, javascript, exposed as an ordered list of offerable languages (what the
  picker shows) with a test asserting the mapping round-trips and that every offerable language
  has both directions.
- [x] `LeetCodeSolutionFile.contents(header:snippet:)` — the seeded file: one header comment
  line carrying number, title and problem URL in that language's line-comment syntax, a blank
  line, then the API snippet verbatim with a trailing newline.
- [x] Tests: input parser over every accepted and rejected form; file-name round trip including
  padding boundaries and hyphenated slugs; language mapping; header comment per language.
- [x] `swift test` — green.

Notes from the implementation (decisions the later tasks inherit):

- **The slug rule is written once**, as `LeetCodeProblemInput.normalizedSlug(_:)`, and the
  file-name reverse parse calls it — the app cannot accept a slug in the input field that it
  would then fail to recognise in the file name it wrote itself.
- **An all-digit input is a number attempt and nothing else.** `0` and a 30-digit paste satisfy
  the slug shape too, so falling through would fetch the *slug* `0` and report "no such problem"
  instead of "that is not a problem number". No LeetCode slug is all digits, so nothing is lost.
- **Language facts travel as one row** (`LeetCodeLanguage`: `SyntaxLanguage`, `langSlug`,
  extension, line-comment token, display name) rather than as four dictionaries, which is what
  makes "every offerable language has all four" structural. A test additionally asserts each
  row's extension resolves back through `SyntaxLanguage(fileExtension:)` to the same language —
  the seeded file must highlight as what it is.
- **The reverse parse is deliberately permissive** (`2024-notes.md` reads as problem 2024): the
  second half of the association — the file sits inside the configured LeetCode folder — belongs
  to Task 6, and nothing is written on the strength of a parse.
- `contents(header:snippet:)` takes an **optional** header (a language with no line comment gets
  the snippet alone) and adds the trailing newline only when the snippet lacks one, so re-seeding
  can never differ from itself by a blank line.

### Task 4: Core — cache layout and the problem catalog

**Files:**
- Create: `Sources/PisakaCore/LeetCodeCacheLayout.swift`, `LeetCodeCatalog.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`

Intent: resolve a human-visible number to a slug without a network round trip in the common
case, with a refresh policy that is explicit rather than incidental. Pure path math plus a disk
cache written through `FileServicing`, so `StubFileTree` drives the whole thing.

- [x] `LeetCodeCacheLayout` — pure `URL` math over a base directory (no `stat`, no
  `standardizedFileURL`, the `LSPInstallLayout` discipline): `catalog.json` and
  `Statements/<slug>.html`, plus a slug-sanitising rule so a hostile slug cannot escape the
  directory.
- [x] `LeetCodeCatalog` — decode/encode the cached list (its own `Codable` DTO with a schema
  version, so an unreadable or older cache is treated as absent rather than crashing),
  `slug(forNumber:)` and `problem(forSlug:)` lookups, `fetchedAt` staleness with the
  once-per-day rule, and the miss path: consult cache → on miss force one refresh → retry once →
  `apiChanged`-free "no such problem" result if still absent.
- [x] A corrupt/half-written cache file is discarded and refetched; the refresh writes through
  `FileServicing` (`ensureDirectory` + `write`) and a write failure degrades to an in-memory
  catalog for the session rather than failing the open.
- [x] Tests against `StubFileTree` + the scripted transport: cold start fetches once; a warm
  cache within the day fetches nothing; a stale cache refreshes; a number missing from a warm
  cache forces exactly one refresh and then resolves; a number missing after the refresh reports
  not-found and does not refresh again; corrupt cache recovers; write failure is survivable.
- [x] `swift test` — green.

Notes from the implementation (decisions the later tasks inherit):

- **`ScriptedLeetCodeTransport` exists already**, in `Tests/PisakaCoreTests/Support/` — Task 6's
  first bullet is written as "create" but this task needed it, so it was written here in the
  shape that task describes (canned answers keyed by route, a recording, gates and per-step
  delays). Task 6 extends it rather than creating it.
- **Resolution answers `nil`, it does not throw.** "No problem with that number" is a truthful
  answer to a typo, so `apiChanged` stays reserved for LeetCode having changed shape.
- **A slug input reaches neither the disk nor the network.** The slug already *is* the key the
  detail request is made by; consulting the catalog would turn opening a pasted link into a 2 MB
  download and would refuse a problem newer than the cache. LeetCode's own `data.question: null`
  is the authority for "no such slug".
- **One forced refresh, tracked by `hasRefreshedFromNetwork`** — a snapshot restored from disk
  does not set it (that is the copy that may predate the problem being asked for), so a miss
  forces exactly one fetch and every later miss in the session is answered immediately.
- **An empty catalog is `apiChanged`, never published or cached**: a shape-valid zero-row
  response would poison the cache for a day and make every open report "no such problem".
- **The cache write cannot fail the open.** `writeCache` swallows its errors into
  `lastCacheWriteFailed` and the session runs in memory; `StubFileTree` gained a `writeFailures`
  injection point so that degradation is assertable.
- `LeetCodeCacheLayout.statementFile(forSlug:)` is **optional-returning**, and the sanitising
  rule is `LeetCodeProblemInput.normalizedSlug(_:)` — the same rule the input field uses — so a
  statement can never be cached under a name the app would later refuse to look up. Task 5
  inherits both.

### Task 5: Core — the statement document and its cache

**Files:**
- Create: `Sources/PisakaCore/LeetCodeStatementDocument.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeStatementDocumentTests.swift`

Intent: the panel's WKWebView is thin because the HTML it loads is composed and tested here —
LeetCode's fragment wrapped in the app's own document with theme-aware CSS.

- [x] `LeetCodeStatementDocument.html(fragment:title:theme:fontSize:)` — a complete document
  with `<meta charset>`, a viewport meta, an inline stylesheet honouring light/dark
  (`ThemePreference`-derived colours passed in as values, not read from AppKit), the editor font
  size, code/pre styling, and a `<base href="https://leetcode.com/">` so relative CDN image URLs
  resolve.
- [x] Statement caching helpers over `LeetCodeCacheLayout` + `FileServicing`: store the raw
  fetched fragment per slug, read it back when the network fails, treat an unreadable cache as
  absent.
- [x] Tests: the wrapper contains the fragment verbatim and the expected structural pieces;
  light and dark differ; the cache round-trips and survives a missing/unreadable file.
- [x] `swift test` — green.

Notes from the implementation (decisions the later tasks inherit):

- **The theme arrives as six colour strings, and `.system` is resolved by the caller.**
  `ThemePreference.system` carries no colour, so `Theme.resolved(_:systemPrefersDark:)` takes the
  appearance the app is actually running in and the document stays a pure function of its inputs
  — which is what lets a test assert light and dark differ without Core importing AppKit. Every
  field is asserted to reach the CSS, so a colour that is declared and never interpolated fails
  the suite rather than silently doing nothing.
- **The fragment is interpolated verbatim, never sanitised.** Rewriting LeetCode's markup would
  be a second parser for an unofficial API, drifting silently; the document loads no script and
  grants no privileges that would make the markup interesting. Escaping applies to the *title*
  alone, which this app supplies.
- **What is cached is the fragment, not the rendered document** — theme and font size are session
  state, so a cache of composed HTML would be stale the instant the user switched appearance.
  Task 6 composes on the way to the web view, every time.
- **Blank is absent, in both directions.** `LeetCodeStatementCache` refuses to store an empty or
  blank fragment (the `LeetCodeCatalog` empty-catalog rule restated) and reads a blank file back
  as `nil` — a truncated cache file is how an empty one appears in practice, and serving it would
  render a permanently blank panel *and* suppress the fetch that would have repaired it.
- **Neither half throws.** A read failure is "not cached" and a write failure is "it will be
  fetched again"; `store` returns a `Bool` so the degradation is assertable and every caller may
  ignore it. Images are not mirrored — the known limit of the offline reopen.
- `fontSize` goes through `SettingsStore.clampFontSize`, because an unparsable `font-size` drops
  the whole declaration silently rather than failing loudly.

### Task 6: Core — `LeetCodeModel`, the main-actor flow

**Files:**
- Create: `Sources/PisakaCore/LeetCodeModel.swift`
- Create: `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeModelTests.swift`
- Modify: `Sources/PisakaCore/SettingsStore.swift`
- Create: `Tests/PisakaCoreTests/SettingsStoreTests.swift` (extend if present)

Intent: one `@MainActor ObservableObject` owning login state, the open-problem operation and the
statement for the active tab — the only place in the area that sequences awaits, and therefore
the only place generation tokens live.

- [x] `ScriptedLeetCodeTransport`: canned responses keyed by request (GraphQL operation name /
  URL path), a recording of what was sent, per-step delays and failures, in the shape and spirit
  of `ScriptedLSPTransport`.
- [x] `SettingsStore` gains three stable keys: the LeetCode folder path, the iOS folder bookmark
  blob, and the last/default language slug — with the existing per-key defaulting discipline
  (unset ≠ empty, an unparsable value falls back rather than poisoning the store).
- [x] Model state: `signedInUsername`/`isSignedIn`, `isBusy`, `lastError`, and the published
  statement for the active tab. `signIn(with:)` stores credentials and confirms via user status;
  `signOut()` clears the store and publishes logged-out; any operation whose response says
  logged-out flips the state and surfaces `notLoggedIn`.
- [x] `openProblem(input:language:)`: resolve input → slug (via the catalog), fetch detail,
  reject `isPaidOnly` with `paidOnly`, compute the file name, `ensureDirectory` the LeetCode
  folder, and **create the file only if it does not exist** — an existing file is returned
  untouched. Publishes an outcome value naming the URL to open plus whether it was created or
  resumed.
- [x] `statement(forFileName:in:)`: parse the number/slug from the active tab's name, verify the
  tab is inside the LeetCode folder, serve the cached fragment immediately when present and
  refresh behind it; a network failure with a cache present is not an error.
- [x] Every async entry point captures its generation synchronously before the first `await` and
  discards its result when superseded; the model never calls `autosave.suspend()` or
  `beginRevert()` — it is a reader, plus one create that clobbers nothing.
- [x] Tests: full open-problem happy path (number and slug and URL inputs); re-open leaves an
  existing file byte-identical; paid-only, throttled, network-failure, logged-out and
  API-changed paths each surface their own error and leave no partial file; two overlapping opens
  publish only the newer one; statement serves cache offline; sign-out then any operation reports
  `notLoggedIn`; the new settings keys persist and default correctly.
- [x] `swift test` — green.

Notes from the implementation (decisions the later tasks inherit):

- **The statement entry point takes a URL, not a file name** (`statement(forFileAt:in:)`). Both
  halves of the association are checked — the *name* parses to a number and slug, and the *file*
  sits inside the LeetCode folder — and the second half needs the whole path. The pure half is
  exposed separately as `associatedProblem(forFileAt:in:)` so the views can ask "is this tab a
  LeetCode problem" without starting a fetch. Containment goes through
  `CanonicalPath.canonical` + `ScopedFileAccess.path(_:isWithin:)`, the primitives every other
  "inside this directory" question in the app uses.
- **"No such problem" is an outcome, not an error.** `LeetCodeOpenOutcome` is a four-case enum —
  `created`/`resumed`/`noSuchProblem`/`superseded` — because two of the answers are not failures:
  a typo is answered truthfully (the `LeetCodeCatalog` rule carried one layer up, so no
  `notFound` case had to join `LeetCodeError` and sit beside `apiChanged`), and a superseded open
  publishes *and writes* nothing, so the caller must not open a tab for it.
- **Three generation counters, not one** (open, statement, account): a statement refresh must not
  cancel an open. Signing in or out bumps all of them, because a session change invalidates
  everything in flight.
- **A rejected request flips `isSignedIn` but keeps the stored credentials.** A 403 from an
  unofficial endpoint is as often a throttle in disguise as a dead session, and clearing the
  Keychain on one would turn a transient failure into a mandatory web-view re-login. Only the
  explicit `signOut()` forgets them; `signIn` also discards a session LeetCode rejects at the
  moment it was obtained.
- **`isSignedIn` is optimistic at launch**: a stored pair sets it before anything is confirmed,
  rather than showing "signed out" for the duration of a round trip. `refreshUserStatus()` is
  non-throwing and silent on failure — it is what the app calls at launch, and an unreachable
  LeetCode is not a sign-out.
- **Existence is asked as a directory listing**, not as a read: a read that failed for any reason
  other than absence would read as "not there" and the next step would overwrite the user's work.
- **Opening also caches and publishes the statement.** The fragment is already in hand, so
  fetching it again when the tab opens would be a second request for bytes we have — and it is
  what makes the offline reopen work from the first open onwards.
- A Keychain that refuses the item does not fail the sign-in (`lastCredentialSaveFailed`, the
  `LeetCodeCatalog.lastCacheWriteFailed` shape), and `isBusy` is a **count**, so the first of two
  overlapping operations finishing cannot switch the spinner off under the second.
- `SettingsStore` holds the whole `LeetCodeLanguage` row rather than a slug, which makes "an
  unparsable value falls back" structural: there is no way to *hold* a language this build does
  not offer, and what reaches `UserDefaults` always reads back.
- `ScriptedLeetCodeTransport` gained a `.question(slug:)` route (finer than the operation name,
  read out of the request's own `variables`) and `InMemoryLeetCodeCredentialStore`, with
  `saveFails`/`clearFails` injection points.

### Task 7: App — the real transport and a cross-platform Keychain store

**Files:**
- Create: `Sources/Pisaka/Platform/LeetCodeURLSessionTransport.swift`,
  `Sources/Pisaka/Platform/LeetCodeKeychainStore.swift`,
  `Sources/Pisaka/Platform/LeetCodeSupportDirectory.swift`
- Modify: `project.yml` only if a new source directory needs declaring (no dependency changes)

Intent: the two app halves of the Core seams, plus the one place that answers "where is the
cache base on this platform" — all compiled on both destinations, none of it tested by
repository convention.

- [x] `LeetCodeURLSessionTransport`: one ephemeral `URLSession` with cookies disabled
  (`httpCookieStorage = nil`, `httpShouldSetCookies = false`) so the only session cookie in play
  is the one Core puts in the header; sensible timeouts; non-HTTP responses and transport errors
  surface as `LeetCodeError.network`.
- [x] `LeetCodeKeychainStore`: `kSecClassGenericPassword` under a fixed service, the pair stored
  as one JSON item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, compiled for both
  platforms (the existing iOS-only `KeychainCredentialStore` is left alone).
- [x] `LeetCodeSupportDirectory`: `…/Application Support/Pisaka/LeetCode` on macOS and the
  container equivalent on iOS, fed to `LeetCodeCacheLayout`.
- [x] Verify both platforms compile: `xcodegen generate` then the macOS and iOS `xcodebuild`
  invocations from CLAUDE.md.

Notes from the implementation (decisions the later tasks inherit):

- **`project.yml` is untouched, and that is load-bearing for the rest of the branch.** The app
  target declares `Sources/Pisaka` as one recursive path, so a new file under `Platform/` is
  picked up without regenerating anything — which is why Tasks 8–11 can add views without a
  dependency or project change either, and why Task 13's "these three files are unchanged by this
  branch" check stays satisfiable.
- **The cookie jar is switched off four times, at both ends**: `.ephemeral` (no persistent jar),
  `httpCookieStorage = nil` + `httpCookieAcceptPolicy = .never` (nothing is *kept* from a
  response), `httpShouldSetCookies = false` on the configuration and `httpShouldHandleCookies =
  false` per request (nothing is *attached* to one). One intent stated repeatedly, the
  `LSPDownloadService` "nothing is cached" shape: a jar would be a second, invisible source of
  sessions — the login `WKWebView`'s copies migrate into a shared `HTTPCookieStorage` readily —
  and a stale one can outlive a sign-out and keep an account signed in after the Keychain item is
  gone.
- **Redirects are followed, as a browser would.** LeetCode answers some signed-out states with a
  302 to the login page rather than a JSON error; the resulting HTML-where-JSON-was-expected
  already has an answer (`apiChanged`) and the authoritative verdict is `userStatus.isSignedIn`,
  so suppressing redirects would trade one confusing case for a different one.
- **The URL cache is off too**, not just for tidiness: the catalog's once-a-day staleness rule and
  the statement cache both live on disk in Core, and a URL cache answering a forced refresh with
  the bytes it already had would silently shadow the one mechanism that repairs a stale catalog.
- **Response header names are passed through in whatever case they arrived.** `Retry-After` is
  read through `LeetCodeHTTPResponse.headerValue(forName:)`, which matches case-insensitively; a
  normalisation here would be a second rule to keep in step with that one.
- **The Keychain item is one JSON blob under a constant account**, not two items and not one keyed
  by user name: the two cookies are only ever useful together, so two items would create a
  half-existing state every reader would need a rule for, and the account is fixed because the item
  *is* the session — the user name is something the session tells us, not something needed to find
  it. `load()` treats undecodable as absent (same recovery, one sign-in) and the failure type is a
  local `LocalizedError`, deliberately not a `LeetCodeError`: the model already knows a save
  failure costs one sign-in next launch (`lastCredentialSaveFailed`), and `fileSystem` would
  attribute a Keychain refusal to the disk.
- **`LeetCodeSupportDirectory` creates nothing.** It answers a location; `LeetCodeCatalog` and
  `LeetCodeStatementCache` each `ensureDirectory` before their first write, which is what makes the
  iOS case work — a fresh container has no `Application Support` directory until something makes
  one. Application Support rather than Caches even though this cache *is* reconstructible: a purge
  would turn a working airplane-mode reopen into a blank pane and put a 2 MB fetch in front of the
  next open.

### Task 8: App — the login WebView on both platforms

**Files:**
- Create: `Sources/Pisaka/LeetCodeLoginView.swift` (macOS),
  `Sources/Pisaka/iOS/LeetCodeLoginView_iOS.swift`
- Modify: `Sources/Pisaka/Platform/` as needed for the shared cookie-observation helper

Intent: the user signs in exactly as in a browser — including Google/GitHub SSO — and the app
only watches the cookie store.

- [ ] A WKWebView on `https://leetcode.com/accounts/login/` in a sheet (macOS) / full-screen
  cover (iOS), with a persistent `WKWebsiteDataStore` so SSO redirects survive.
- [ ] After each navigation, read `httpCookieStore.getAllCookies` and run Core's cookie →
  credentials rule; on success save through the store, dismiss, and confirm with the user-status
  call, showing the username where the integration surfaces state.
- [ ] Sign Out clears the credential store *and* the WebView data store's cookies for
  `leetcode.com`, and flips the model to logged-out.
- [ ] Both builds succeed (`xcodebuild`, macOS + iOS).

### Task 9: macOS — LeetCode menu, Open Problem dialog, Settings

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/SettingsView.swift`
- Create: `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`

Intent: the macOS entry points, wired into the existing menu/orchestration conventions.

- [ ] A `LeetCode` menu with "Open Problem…", "Sign In…"/"Sign Out" (state-dependent), and
  "Choose LeetCode Folder…".
- [ ] The Open Problem sheet: one text field (number / slug / URL, live-validated through Core's
  parser), a language picker seeded from the persisted last choice, progress and inline error
  while the fetch runs.
- [ ] Folder establishment on first use: an `NSOpenPanel` in directories-only mode pre-targeted
  at `~/Documents/LeetCode` (created if absent), the chosen path persisted in `SettingsStore` —
  no bookmark, since the macOS app is unsandboxed.
- [ ] A LeetCode section in Preferences → General (or its own tab, following the existing tab
  host): signed-in username with Sign In/Out, the folder path with a Change… button, and the
  default language.
- [ ] On success the returned URL is opened as a regular tab via `WorkspaceModel.open(url:)` and
  the tree revision bumped if the file landed inside the open project; failures surface through
  `PlatformAlert`.
- [ ] macOS build succeeds.

### Task 10: macOS — the description pane

**Files:**
- Create: `Sources/Pisaka/LeetCodeDescriptionView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

Intent: a collapsible right-hand pane that appears exactly when the active tab is a LeetCode
solution file, rendering Core's composed document.

- [ ] A WKWebView-backed `NSViewRepresentable` loading `LeetCodeStatementDocument`'s HTML with a
  base URL, navigation delegate opening any link click in the default browser instead of
  in-pane, and no JavaScript-driven state of its own.
- [ ] Pane visibility follows the model's statement state (present only for a LeetCode tab), is
  user-collapsible, remembers its width in `@State` like the bottom dock, and re-renders on
  theme/font-size change.
- [ ] macOS build succeeds.

### Task 11: iOS — LeetCode section, folder, and adaptive description screen

**Files:**
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`, `SettingsView_iOS.swift`, `PisakaApp_iOS.swift`
- Create: `Sources/Pisaka/iOS/LeetCodeDescriptionView_iOS.swift`, `LeetCodeRoute_iOS.swift`

Intent: the same flow with iOS's navigation and file-access realities.

- [ ] A LeetCode section in the root navigation: sign-in state, the same input field and
  language picker, and the open action producing a normal editor tab.
- [ ] Folder resolution: default to a `LeetCode` directory inside the app container
  (`LSSupportsOpeningDocumentsInPlace` already exposes it in Files), created on first use; an
  override chosen through the document picker is persisted as a security-scoped bookmark and
  reached through the existing `SecurityScopedFileService` decorator.
- [ ] The description screen: side-by-side with the editor on regular width, a toggleable screen
  on compact, following `MergeRoute_iOS`'s adaptive pattern.
- [ ] Settings screen gains the LeetCode rows (account, folder, default language).
- [ ] iOS build succeeds.

### Task 12: Documentation

**Files:**
- Create: `docs/architecture/core-leetcode.md`
- Modify: `CLAUDE.md`

Intent: follow the `core-provisioning.md` precedent — one doc holding the Core half and its
app-layer seams on both platforms — and keep CLAUDE.md to index lines.

- [ ] `core-leetcode.md`: one entry per new file with its contract, invariants and the reasoning
  behind the non-obvious choices (the unofficial-API risk and the single schema file, why the
  catalog uses the REST list, the once-a-day + forced-on-miss staleness rule, the never-overwrite
  rule, the reader-not-writer position relative to the writer gate, the
  macOS-unsandboxed/iOS-bookmark asymmetry, the known limits).
- [ ] CLAUDE.md: a `core-leetcode.md` index block in the `PisakaCore` section, app-layer index
  lines beside it, and a cross-cutting bullet stating that the LeetCode layer is a reader with
  exactly one create.
- [ ] `swift test` — green (documentation-only, but the gate stays).

### Task 13: Verify acceptance criteria

- [ ] `swift test` — full suite green, including every new LeetCode suite.
- [ ] `xcodegen generate` and both builds:
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
  and the iOS Simulator destination from CLAUDE.md.
- [ ] Confirm `project.yml`, `Package.resolved` and `Resources/Licenses/licenses.json` are
  unchanged by this branch (`git diff --stat` over those paths is empty).
- [ ] Confirm `Package.swift`'s test-target `exclude:` lists `Fixtures/leetcode`, and that no
  fixture is declared as a SwiftPM resource.

## Post-Completion (manual verification by the user)

- macOS: sign in through the WebView (including an SSO provider), open problem `1`, confirm
  `0001-two-sum.swift` appears in the chosen folder with the header comment and Swift snippet,
  the statement renders beside the editor, and re-opening `two-sum` reopens the same file with
  edits intact.
- iOS/iPadOS: the same flow against the container-default folder; check the file is visible in
  the Files app and the description is side-by-side on iPad, toggleable on iPhone.
- Sign out, then attempt "Open Problem…": the reported error is "not signed in to LeetCode".
- Airplane mode: a previously opened problem still shows its statement (images may be absent).
