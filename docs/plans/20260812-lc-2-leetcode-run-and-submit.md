# LC-2: LeetCode Run and Submit — judge runs on examples, submissions with verdicts

## Overview

Close the solve loop LC-1 opened. With a LeetCode solution file in the active tab, the user presses Run (the example test cases, editable) or Submit (LeetCode's full suite) and sees the verdict in the editor — on macOS in the description pane, on iOS in the shared adaptive description content.

The wire work is three new REST calls behind the existing transport seam: `POST /problems/<slug>/interpret_solution/`, `POST /problems/<slug>/submit/`, and a poll of `GET /submissions/detail/<id>/check/` until `state` reaches `SUCCESS`. All of it — URLs, payload keys, the numeric `status_code` table, the state strings — lands in `LeetCodeAPI.swift`, the one schema file, under the same `apiChanged`-names-the-key-path discipline.

Two structural decisions, both settled before this plan:

- **The internal `questionId` is now modelled.** LC-1 deliberately did not carry it; the run/submit payloads require it, so the detail query and parser gain it and `LeetCodeProblemDetail` carries it beside the frontend number it must never be confused with.
- **questionId + exampleTestCases reach the judge through an in-memory memo per run** (the answered question). Every detail fetch that already happens — `openProblem`, the statement refresh — records the pair by slug; a judge surface opened on a slug this run never fetched makes one lazy detail request. The statement disk cache keeps storing the bare HTML fragment; its format is untouched.

The judge flow lives in a **companion model** `LeetCodeJudgeModel`, owned by `LeetCodeModel` the way `catalog` already is. Two reasons: `LeetCodeModel` is already ~970 lines, and the views can observe the narrower object so typing in the test-case box does not invalidate every surface bound to the account/statement state.

The layer stays a **reader**: it reads the live editor buffer and writes nothing on disk; it neither raises `autosave.suspend()`/`beginRevert()` nor is gated by them.

## Context

**Files involved (Core):**

- Modify: `Sources/PisakaCore/LeetCodeAPI.swift` — the three endpoints, request builders, the two id parsers, the check parser, the `status_code`/`state` tables, `questionId` in the detail query.
- Modify: `Sources/PisakaCore/LeetCodeProblem.swift` — `LeetCodeProblemDetail.questionID`.
- Modify: `Sources/PisakaCore/LeetCodeError.swift` — two new cases with their sentences.
- Modify: `Sources/PisakaCore/LeetCodeSolutionFile.swift` — `language(forFileExtension:)`.
- Modify: `Sources/PisakaCore/LeetCodeModel.swift` — the judge-context memo, the lazy fetch, `public let judge`.
- Create: `Sources/PisakaCore/LeetCodeJudge.swift` — the typed judge value types (kind, verdict, state, run result, submit result, check, availability, context).
- Create: `Sources/PisakaCore/LeetCodeJudgeModel.swift` — the flow: start/poll/supersede/cancel, budgets, the editable input.

**Files involved (app):**

- Create: `Sources/Pisaka/LeetCodeJudgeView.swift` (`#if os(macOS)`).
- Create: `Sources/Pisaka/iOS/LeetCodeJudgeView_iOS.swift`.
- Modify: `Sources/Pisaka/LeetCodeDescriptionView.swift`, `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/iOS/LeetCodeDescriptionView_iOS.swift`, `Sources/Pisaka/iOS/RootView_iOS.swift` — host the section and hand it the workspace.

**Files involved (tests/fixtures/docs):**

- Modify: `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift` (three new routes), `LeetCodeAPITests.swift`, `LeetCodeModelTests.swift`.
- Create: `Tests/PisakaCoreTests/LeetCodeJudgeAPITests.swift`, `LeetCodeJudgeModelTests.swift`.
- Create/modify: `Tests/PisakaCoreTests/Fixtures/leetcode/*.json` + `README.md`.
- Modify: `docs/architecture/core-leetcode.md`, `CLAUDE.md`, `README.md`.

**Related patterns to follow:**

- Byte-exact request assertions (`LeetCodeAPITests.testRequestBodiesAreExact`), `.sortedKeys` serialisation.
- `JSONObjectReader` key-path-naming reads; nothing shrugs.
- Generation tokens captured synchronously before the first `await`; `isBusy`-style flags are counts (`beginWork`/`endWork`).
- `ScriptedLeetCodeTransport` route keying, sticky-last-step queues, `Gate` for staging concurrency.
- `RoutingIntelligenceProvider.withBudget` for the shape of a hard budget; `LSPSession.Budgets` for budgets-as-data.

**Dependencies:** none new. `project.yml`, `Package.resolved`, `licenses.json`, `Package.swift` all stay untouched (the fixtures directory is already `exclude:`d).

## Development Approach

- **Testing approach**: Regular (code first, then tests) — matching how the LC-1 suites are written, with fixtures authored alongside the parser they pin.
- Complete each task fully before moving to the next; `swift test` must be green at the end of every task.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- App-layer tasks (5, 6) are untested by convention; their gate is a successful `xcodebuild` for that destination.
- Every parser decision and every flow rule is a Core unit test — the app layer must contain no decision worth testing.

## Implementation Steps

### Task 1: The detail carries LeetCode's internal question id

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeAPI.swift`, `Sources/PisakaCore/LeetCodeProblem.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeAPITests.swift`
- Modify/create: `Tests/PisakaCoreTests/Fixtures/leetcode/question-detail*.json`, `Fixtures/leetcode/README.md`

The `questionData` document gains `questionId`, and `LeetCodeProblemDetail` gains a `questionID: String` beside `frontendID`. The two must be impossible to confuse: `questionID` is LeetCode's internal, opaque, wire-shaped identifier that only the judge payloads use, `frontendID` is the number the user types and the file name carries. Document that on both properties and in `LeetCodeProblem`'s existing "this layer never uses it, so it is deliberately not modelled" note, which this task retires.

Read it strictly — absent or null is `apiChanged` naming `data.question.questionId` — and read it leniently as to *form*, through the same number-or-numeric-string tolerance `questionFrontendId` already needs, then carry it as a `String` because that is what the payload sends. Recording it as `String` is deliberate: nothing arithmetic is ever done with it.

The recorded fixtures predate the field, and this environment cannot re-record. Add `questionId` by hand to the recorded detail fixtures and say so **explicitly** in the README's provenance table — "verbatim except `questionId`, added by hand because the recording predates the query asking for it; re-record to make it verbatim again" — rather than silently letting a hand edit pass as a recording. Add one authored fixture whose `questionId` differs from `questionFrontendId` (the newer-problem case), so the suite pins the very confusion the ticket warns about, plus a shape-violation derivative with the key missing.

- [x] add `questionId` to `questionDetailQuery` and to `parseQuestionDetail`, strict, key-path-naming
- [x] add `questionID` to `LeetCodeProblemDetail` with the two-identifiers note; retire the stale comment in `LeetCodeProblem`
- [x] hand-add `questionId` to the recorded detail fixtures; author a differs-from-frontend-id fixture and a missing-key violation
- [x] update the fixtures README provenance table honestly (verbatim vs. hand-edited vs. authored)
- [x] extend `LeetCodeAPITests`: the exact new request body, the parse, the differing-id case, the missing-key `apiChanged`
- [x] run `swift test` — must pass before Task 2

### Task 2: The judge wire — interpret, submit, check

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeAPI.swift`, `Sources/PisakaCore/LeetCodeError.swift`
- Create: `Sources/PisakaCore/LeetCodeJudge.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeJudgeAPITests.swift`
- Create: `Tests/PisakaCoreTests/Fixtures/leetcode/judge-*.json`; modify `Fixtures/leetcode/README.md`

`LeetCodeJudge.swift` holds the typed vocabulary, all Foundation-only value types:

- `LeetCodeJudgeKind` — `.run` / `.submit`. It decides which URL, which payload, and which finished shape the check parser builds, so it travels with every judge call.
- `LeetCodeVerdict` — `accepted` (10), `wrongAnswer` (11), `memoryLimitExceeded` (12), `outputLimitExceeded` (13), `timeLimitExceeded` (14), `runtimeError` (15), `internalError` (16), `compileError` (20), `unknownError` (21), each with a display name. No `default`: an unmapped code is `apiChanged(detail: "status_code = 7")`.
- `LeetCodeJudgeState` — `pending`, `started`, `success`, `failure`. `failure` is a small deliberate extension beyond the three states the ticket names: LeetCode does answer `FAILURE` when its own judge gives up, and mapping it to a stated "the judge did not finish" beats reporting a known state as a schema change. Anything else is `apiChanged`.
- `LeetCodeRunResult` — verdict, `matchedExpected: Bool?` (`correct_answer`; on a run, `status_code == 10` means "it ran", not "it is right"), the submitted inputs, `answers`, `expectedAnswers`, `stdout`, runtime/memory display strings, and `errorText` (compile or runtime, preferring the full form).
- `LeetCodeSubmitResult` — verdict, runtime/memory with their percentiles when present, `totalCorrect`/`totalTestcases`, the failing `lastTestcaseInput`, `codeOutput`, `expectedOutput`, `stdOutput`, `errorText`.
- `LeetCodeJudgeCheck` — `.pending`, `.started`, `.finishedRun(_)`, `.finishedSubmit(_)`, `.judgeFailed`.

In `LeetCodeAPI`: `interpretURL(slug:)`, `submitURL(slug:)`, `checkURL(id:)` (trailing slashes as LeetCode wants them); a `commonHeaders(credentials:referer:)` overload so these three carry the **problem page** as `Referer` while the GraphQL calls keep the site root; `interpretRequest(...)` and `submitRequest(...)` composing `{"lang", "question_id", "typed_code", "data_input"}` (the last omitted for submit) with `.sortedKeys`; `checkRequest(id:slug:credentials:)` as a GET. Then `parseInterpretID`, `parseSubmissionID` (a number on the wire, carried as a `String`), and `parseJudgeCheck(_:kind:)`.

Parse **strictly where the verdict lives** (`state`, `status_code`) and **leniently around it** — LeetCode omits percentiles on a rejected submit, omits `code_answer` on a compile error, and spells runtime as a display string. An absent optional is `nil`, never a substituted zero. The existing throttle/auth classification in `jsonObject` applies unchanged: these are plain REST, so 429 and DRF `{"detail": …}` bodies are what appear, and the GraphQL error-array branch simply never fires.

`LeetCodeError` gains exactly two cases, both product refusals rather than wire mismatches, both with a user-facing sentence: `judgeTimedOut(seconds:)` and `judgeUnavailable(reason:)`.

Fixtures: `judge-check-pending.json`, `judge-check-started.json`, and finished pairs for Accepted / Wrong Answer / TLE / Runtime Error / Compile Error on both the run and submit shapes, plus `judge-interpret-id.json`, `judge-submit-id.json`, an unknown-`status_code` and an unknown-`state` violation. These require a session and so are **authored** to the documented DRF shapes — the README's "Authored, not recorded" section grows a subsection saying exactly that, in its own voice, with the note that a future session holding a real cookie should re-record and delete the label.

- [x] add `LeetCodeJudge.swift` with the kind/verdict/state/result/check types
- [x] add the three endpoints, the `Referer` overload, the two POST builders and the GET builder to `LeetCodeAPI`
- [x] add `parseInterpretID`, `parseSubmissionID`, `parseJudgeCheck(_:kind:)` with strict tables and lenient fields
- [x] add the two `LeetCodeError` cases and their sentences
- [x] author the judge fixtures and extend the README with a labelled section
- [x] write `LeetCodeJudgeAPITests`: byte-exact bodies and headers (question id, problem-page `Referer`), both id parses, every fixture-driven verdict on both shapes, unknown code and unknown state as `apiChanged`, a 429 and a DRF auth body on a check
- [x] run `swift test` — must pass before Task 3

### Task 3: The judge context memo and the scripted transport's new routes

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeModel.swift`, `Sources/PisakaCore/LeetCodeJudge.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift`, `Tests/PisakaCoreTests/LeetCodeModelTests.swift`

`LeetCodeJudgeContext` (slug, `questionID`, `exampleTestCases`) is what the judge needs and the statement cache does not hold. `LeetCodeModel` gains a private `[String: LeetCodeJudgeContext]` recorded at **every** point a detail already passes through — `performOpen`, `adoptStatement(from:)` and the statement refresh's success branch — and a `judgeContext(forSlug:) async throws -> LeetCodeJudgeContext?` that answers from the memo or makes exactly one lazy detail request for a slug this run has never fetched.

The `nil` return is L7 applied on a new axis: "LeetCode does not know this problem" is a value, not an `apiChanged`, and the judge turns it into a stated refusal. The memo is emptied by `signIn(with:)` and `signOut()` alongside `slugsFetchedThisRun`, for the same reason: a session change invalidates what was fetched under the old one. Nothing here touches the disk cache format.

`ScriptedLeetCodeTransport` grows `.interpret(slug:)`, `.submit(slug:)` and `.check(id:)`, recognised by path shape in `route(of:)` — so a request nobody expected still lands in `.other(path:)` and names itself in the failure. The existing sticky-last-step and gate behaviours carry over unchanged and are what make a `PENDING → STARTED → SUCCESS` script one line.

- [x] add `LeetCodeJudgeContext` and the memo, recorded at all three existing detail sites (written in `fetchDetail`, the one funnel all three pass through — so the judge's own lazy fetch records it too and a fourth caller cannot forget to)
- [x] add `judgeContext(forSlug:)` with the memo-first / one-lazy-fetch rule; clear the memo on sign-in and sign-out
- [x] add the three routes to `ScriptedLeetCodeTransport`
- [x] test: memo warm after an open and after a statement refresh (no extra request); cold slug fetches exactly once and then never again; unknown slug answers `nil`; sign-out empties it
- [x] run `swift test` — must pass before Task 4

### Task 4: `LeetCodeJudgeModel` — the flow

**Files:**
- Create: `Sources/PisakaCore/LeetCodeJudgeModel.swift`
- Modify: `Sources/PisakaCore/LeetCodeModel.swift`, `Sources/PisakaCore/LeetCodeSolutionFile.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeJudgeModelTests.swift`

A `@MainActor ObservableObject` in Core, constructed by `LeetCodeModel` and exposed as `public let judge`, holding an `unowned` back-reference to its owner. The back-reference rather than a protocol seam: the judge needs the session, the memo and the session-rejected/accepted transitions, all of which are `LeetCodeModel`'s, it is reachable only through its owner, and the suites drive it through a real model with the scripted transport — a stub host would be a fourth abstraction standing in for one that already exists in the tests.

Published surface: `phase` (`.idle` / `.running(LeetCodeJudgeKind)`), `testInput`, `lastRun`, `lastSubmit`, `lastError`, and `availability`. `LeetCodeJudgeAvailability` is a pure, synchronous decision — `.ready(LeetCodeLanguage)`, `.notSignedIn`, `.notASolutionFile`, `.unsupportedLanguage(String)`, `.busy` — each carrying the sentence the disabled button explains itself with. It is what makes "a dead button" impossible, and it is unit-tested as a table. The language comes from the file extension through a new `LeetCodeSolutionFile.language(forFileExtension:)`, matched case-insensitively over the one offerable-language list, so the two directions can never disagree.

`prepare(forFileAt:in:)` — driven by the view's `.task(id:)` on the active tab, the LC-1 pattern — resolves the availability, resolves the context (memo first, one lazy fetch), and prefills `testInput` from `exampleTestCases` joined by LeetCode's own newline convention. A change of problem resets the box; edits are session state and never touch disk.

`run()` and `submit()` share one flow: capture the generation and the live buffer text synchronously before the first `await` (the buffer, never the disk copy — the user must not have to save first), POST, take the id, then poll `check` at a fixed 1 s interval until the state is terminal. Budgets are data (`Budgets(run: 30, submit: 60)`, defaulted, injectable), enforced against a `now()` deadline rather than an attempt count, so a slow network cannot silently double the wait. Exhaustion publishes `judgeTimedOut` — a typed, user-facing failure, never a hang. `Submit` ignores `testInput` entirely.

The LC-1 rules applied to the new axis, each its own test: a superseded operation (a second Run while the first polls) publishes nothing at all; a cancelled one (leaving the surface, closing the tab) publishes nothing; a `notLoggedIn` mid-poll flips the account state through the owner's existing `markSessionRejected()`; a successful check calls `markSessionAccepted()`; a throttle mid-poll publishes the throttle and stops. The judge's counter is a **fourth** generation token beside open/statement/account, bumped by a sign-in or sign-out with the other three, because a session change invalidates a poll in flight as surely as it invalidates a fetch.

Sleeping goes through an injectable seam so the suite runs the whole state machine deterministically and `swift test` gains no wall-clock time.

- [x] add `LeetCodeSolutionFile.language(forFileExtension:)`
- [x] add `LeetCodeJudgeAvailability` and its sentences
- [x] add `LeetCodeJudgeModel`: published state, `prepare`, `run`, `submit`, `cancel`, budgets-as-data, injectable sleep/now, fourth generation token
- [x] wire `public let judge` onto `LeetCodeModel` (a `lazy var`, since the judge is constructed with `self`); bump the judge generation from `invalidateInFlightWork()`/sign-in/sign-out
- [x] test the availability table including the not-offerable refusal
- [x] test the poll machine: `PENDING → STARTED → SUCCESS` for both kinds, budget exhaustion, throttled mid-poll, logged-out mid-poll, supersedence, cancellation — each publishing exactly what the LC-1 rules dictate
- [x] test that the prefilled-then-edited input reaches the interpret payload verbatim and that Submit's payload carries no input
- [x] test that the live buffer text is what is submitted, not any saved copy
- [x] run `swift test` — must pass before Task 5

### Task 5: The macOS judge section

**Files:**
- Create: `Sources/Pisaka/LeetCodeJudgeView.swift`
- Modify: `Sources/Pisaka/LeetCodeDescriptionView.swift`, `Sources/Pisaka/ContentView.swift`

A section below the statement web view inside the existing description pane: the editable test-case box (a monospaced `TextEditor`), Run and Submit, a progress indicator while polling, and the result area — verdict prominently, details beneath, compile and runtime error text shown in full in a scrollable monospaced view rather than truncated to one line, which is the whole reason a user leaves the browser.

It observes `model.judge` and not `model`, so typing in the box does not invalidate the statement or the account surfaces. The buffer reaches it through a **deliberately non-observed** `WorkspaceModel` reference — the pattern `ContentView` already uses for `commitDialog`, and the reason is the same: an observed one would re-render this view on every keystroke in the editor. Read the text at button-press time only. No new file IO anywhere in this task.

Buttons disable themselves from `judge.availability` and explain why in a help tooltip beside them.

- [x] add `LeetCodeJudgeSection` (`#if os(macOS)`) observing `model.judge`
- [x] host it in `LeetCodeDescriptionPane` below the statement; hand it the non-observed workspace from `ContentView`
- [x] drive `judge.prepare(...)` from the pane's `.task(id:)` on the same tab+folder key the statement uses
- [x] build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` must succeed
- [x] run `swift test` — must pass before Task 6

### Task 6: The iOS judge section

**Files:**
- Create: `Sources/Pisaka/iOS/LeetCodeJudgeView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/LeetCodeDescriptionView_iOS.swift`, `Sources/Pisaka/iOS/RootView_iOS.swift`

The same content, added to `LeetCodeDescriptionContent_iOS` — the one view both the regular-width pane and the compact-width sheet already render — so the adaptive pattern LC-1 established carries the judge for free rather than being reimplemented twice.

Input editing must be keyboard-friendly: a `TextEditor` that scrolls clear of the keyboard, a Done affordance to dismiss it, and no layout that puts Run under the keyboard on a compact width.

- [ ] add the iOS judge section view
- [ ] host it in the shared `LeetCodeDescriptionContent_iOS`; hand it the non-observed workspace from `RootView_iOS`
- [ ] keyboard handling: dismissal affordance, no control trapped under the keyboard on compact width
- [ ] build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` must succeed
- [ ] run `swift test` — must pass before Task 7

### Task 7: Documentation

**Files:**
- Modify: `docs/architecture/core-leetcode.md`, `CLAUDE.md`, `README.md`

`core-leetcode.md` gains a full entry per new and changed file, and continues the L-decision series:

- **L16** — the internal `questionId` is modelled now, and only because the judge payloads need it; it is never the number a user types.
- **L17** — the judge is a companion model with its own (fourth) generation token, owned by `LeetCodeModel` the way `catalog` is, so a poll and a statement refresh cannot cancel each other.
- **L18** — polling is a fixed interval against a hard deadline; exhaustion is a typed failure, never a hang.
- **L19** — the submission language is the file extension, through the one offerable-language list; a file that maps to none is refused with a stated reason.
- **L20** — the test-case box is session state, prefilled from the detail's examples, used verbatim by Run and ignored by Submit.
- **L21** — the judge context (question id + examples) is memoised in memory per run; the statement disk cache format is untouched, and a cold slug costs one lazy detail request.
- **L22** — the verdict and state tables are strict; an unknown `status_code` or `state` is `apiChanged`, never a default.

Known limits gain: a Run/Submit that outruns its budget **does not undo the submission** — LeetCode has it, and the result is visible on the site; edited test cases are not persisted across launches; percentiles are absent on some verdicts; no submission history (LC-3 and later).

`CLAUDE.md` gains index lines for the new files under the existing `core-leetcode.md` group and an updated "LeetCode is a reader with exactly one create" invariant — run/submit read the live buffer and write nothing, so the sentence holds unchanged and should say so explicitly.

`README.md`'s LeetCode feature bullet describes Run and Submit on both platforms, and the Known Limitations line that currently says submissions are not implemented ("Use leetcode.com to submit") is corrected.

- [ ] add per-file entries and decisions L16–L22 to `docs/architecture/core-leetcode.md`
- [ ] extend its Known limits and Tests sections
- [ ] add the `CLAUDE.md` index lines and refresh the LeetCode reader invariant
- [ ] update the README feature bullet and Known Limitations
- [ ] run `swift test` — must pass before Task 8

### Task 8: Verify acceptance criteria

- [ ] `swift test` fully green
- [ ] `xcodebuild` macOS build succeeds
- [ ] `xcodebuild` iOS Simulator build succeeds
- [ ] `git diff --stat` confirms `project.yml`, `Package.resolved`, `Package.swift` and `Resources/Licenses/licenses.json` are untouched
- [ ] confirm by inspection that no Core file imports anything outside Foundation and no new file IO was added to the judge path
- [ ] confirm the new fixtures are all under `Tests/PisakaCoreTests/Fixtures/leetcode/` and labelled in the README as verbatim, hand-edited or authored

## Post-Completion (manual, user-run)

These need a real LeetCode session and are for the user, not the agent:

- On macOS, open problem 1 and press Run on the seeded stub — per-case results appear.
- Submit a correct Two Sum — Accepted with runtime and memory.
- Submit a wrong one — Wrong Answer with the failing case.
- Edit the test-case box and Run — the edited input is what runs.
- Repeat the Run case on iPad in both the pane (regular width) and the sheet (compact).
