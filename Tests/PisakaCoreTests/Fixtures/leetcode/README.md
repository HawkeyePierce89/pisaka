# Recorded LeetCode responses

Wire-level fixtures for `LeetCodeAPI`, the one file that holds every fact about
LeetCode's wire format. **No test in this repository ever reaches the network** —
`swift test` stays the offline, dependency-free gate it has always been — and
these files are what makes that possible while still pinning the parsers against
what the *real* endpoints answered rather than against what the shape is
remembered to be.

That distinction matters more here than it did for the LSP fixtures: LeetCode
publishes no contract, no versioning and no deprecation notice, so these files
are the only written-down record of the shape this app was built against. When
`LeetCodeError.apiChanged` starts appearing in the wild, the diff between a fresh
recording and the file beside it *is* the diagnosis.

They are read through `#filePath`, in the `VendoredGrammarQueryTests` /
`SymbolQueryTests` / `Fixtures/LSP` style, so they need no SwiftPM resource
declaration; the test target instead `exclude:`s this directory in
`Package.swift` (a `.json` beside Swift sources is otherwise an
unhandled-resource build warning).

## Provenance

Everything marked *verbatim* below was recorded on **2026-08-11** against the
live public endpoints, **signed out** — anonymous access is enough to pin every
shape this ticket parses, so no session cookie was involved in producing any file
here and none is committed. Bodies are re-indented by `json.dump(indent=2)`;
no key, value or ordering is otherwise altered.

- `POST https://leetcode.com/graphql`, with `Content-Type: application/json` and
  `Referer: https://leetcode.com/`.
- `GET https://leetcode.com/api/problems/all/`.

## The files

| File | How it was produced |
| --- | --- |
| `question-detail.json` | verbatim **except `questionId`** — `questionData(titleSlug: "two-sum")`. The recording predates the query asking for that field, and this environment cannot re-record, so `"questionId": "1"` was added by hand at the position LeetCode returns it (Two Sum is old enough that the internal id and the frontend id agree, which is why it is safe to write down by hand at all — for a newer problem it would be a guess, and that case is covered by the authored `question-detail-newer-problem.json` instead). Re-record to make this file verbatim again. Note `questionFrontendId` is the **string** `"1"` while the REST catalog spells the same number as the integer `1`; that disagreement is exactly why the parser reads a number leniently from either form. |
| `question-detail-paid-only.json` | verbatim **except `questionId`**, added by hand for the reason above (problem 170's two ids also agree). Problem 170, LeetCode Premium: `isPaidOnly: true` arrives with `content: null` **and** `codeSnippets: null`, so the parser must not demand either when the flag is set — the rejection is the model's job (it reports `paidOnly`), not the parser's. `questionId` *is* demanded even here, because a locked problem is still a problem the judge would have to be addressed about. |
| `question-detail-unknown-slug.json` | verbatim — a slug that does not exist answers `{"data":{"question":null}}` with HTTP 200. An explicit `null` here is "no such problem", **not** a shape violation, which is why the detail parser returns an optional instead of throwing. |
| `user-status-signed-out.json` | verbatim — `globalData` anonymous: `isSignedIn: false`, `username: ""`, and `isPremium: null` (absent-as-null, not `false`). |
| `problem-list.json` | verbatim **except trimmed and re-statused** — the real response is 2.0 MB / 4018 `stat_status_pairs`, of which 12 are kept in their recorded order, chosen to cover all three difficulty levels, a `paid_only: true` row (170) and both ends of the id range. The top-level counters (`num_total: 4018`, …) are left as recorded and deliberately disagree with the trimmed array: nothing parses them, and a fixture that quietly "fixed" them would hide that. Anonymous reports `status: null` for every row, so `"ac"` (1) and `"notac"` (2) were injected by hand — the only edit to any row. |
| `errors-schema-drift.json` | verbatim — the real HTTP **400** LeetCode answers when the query asks for a field the schema no longer has. This is the response the whole `apiChanged` design exists for, and it is worth having on record that it is a 400 with an `errors` array and *no* `data` member. |

### Authored, not recorded

These shapes could not be obtained anonymously and without abusing the service,
so they are hand-written to the shape LeetCode's stack (Django REST Framework +
Graphene) produces and labelled here rather than passed off as recordings. If a
future session ever captures a real one, re-record it and delete the note.

| File | Why it is authored |
| --- | --- |
| `user-status-signed-in.json` | Requires a real session cookie, which is not committed. |
| `question-detail-newer-problem.json` | The case a hand-edited recording cannot honestly cover: a problem whose internal `questionId` (`3403`) and user-visible `questionFrontendId` (`3110`) **disagree**, which is true of every problem added after LeetCode's numbering diverged. Authored to the recorded shape, with a trimmed statement and two snippets, because its only job is to pin that the parser keeps the two identifiers apart — swapping them looks correct on Two Sum and judges a different problem here. |
| `question-detail-paid-only-subscriber.json` | The *other* Premium shape: requires a Premium session cookie, which is not committed. Same problem (170) and the same `isPaidOnly: true`, but with `content` and `codeSnippets` present — because the flag describes the **problem**, not the caller's access, and LeetCode withholds those two only from a caller who is not subscribed. It is what the model's refusal distinguishes: the locked answer is refused, this one opens. |
| `errors-not-authenticated.json` | Requires provoking an auth-gated field; the phrasing is Graphene's. |
| `errors-premium.json` | LeetCode answers a premium question with a null `content` (see above) rather than an error, but the errors-array phrasing exists on other premium surfaces; pinned so the classifier's paid-only branch is exercised. |
| `throttled.json` / `throttled-no-wait.json` / `rest-not-authenticated.json` | Provoking a real 429 means hammering the service. The body is DRF's standard `{"detail": …}`, and the two throttle variants pin the difference that matters to the user: whether the message can name a wait. |

### The judge fixtures — every one of them authored

The `judge-*.json` files are **all authored, none recorded**, and the reason is
categorical rather than incidental: `interpret_solution`, `submit` and
`submissions/detail/<id>/check/` all require a signed-in session, and two of the
three *write* to the account — a recording would mean submitting somebody's code
to LeetCode from a test run. No session cookie is committed here and none was
used to produce any of these.

They are written to the shapes LeetCode's stack (Django REST Framework + its
judger) produces: the id endpoints answer a bare object with one identifier, and
the check endpoint answers a growing object that carries only `state` until the
judge is done. A future session holding a real cookie should re-record these
against a throwaway account and delete this heading — until then, treat a
disagreement between one of these files and the live endpoint as this
repository's mistake, not LeetCode's.

| File | What it pins |
| --- | --- |
| `judge-interpret-id.json` | The run handle. The id is a `runcode_<epoch>.<micros>_<random>` **string** — unreserved ASCII, which is what `judgeID(_:path:)` requires before it becomes a path component of the check URL — and `interpret_expected_id` is deliberately ignored by the parser (the expected output arrives inside the run's own check response, so polling a second id would double the request rate for data already in hand). Its `test_case` is the other thing this file pins: **six lines for three cases**, because `data_input` carries one line per *argument*, which is why the echoed input is never split per case. |
| `judge-submit-id.json` | The submission handle — a JSON **number** where the run's is a string. That disagreement is the whole reason both ids go through `opaqueIdentifier`, which carries either form as the `String` the check URL needs. |
| `judge-check-pending.json` / `judge-check-started.json` | The two non-terminal states, each a body carrying **nothing but `state`**. They are what proves the parser does not demand `status_code` before the judge has produced one. |
| `judge-check-failure.json` | `state: "FAILURE"` — LeetCode's own judge giving up. Terminal, and *not* a verdict on the submitted code; also carries no `status_code`, for the same reason as the two above. |
| `judge-check-run-accepted.json` | A finished run, all three Two Sum examples matching: `status_code: 10` **and** `correct_answer: true`. It also pins the array-length trap: `std_output_list` has **four** entries for three cases, which is what LeetCode sends here, so a case count taken as the longest of the parallel arrays renders an empty phantom fourth case on the happy path. `LeetCodeRunResult.caseCount` reads `code_answer`/`expected_code_answer` and ignores this one for that reason. |
| `judge-check-run-wrong-answer.json` | The case the run shape exists to make readable: `status_code` is **still 10** — the code ran — and `correct_answer: false` is the only thing that says the output was wrong. A parser that reported the run's headline from `status_code` alone would call this Accepted. |
| `judge-check-run-time-limit-exceeded.json` | `status_code: 14` with `status_runtime`/`status_memory` spelled `"N/A"` and an empty `code_answer`; nothing measurable, and nothing invented to fill the gap. |
| `judge-check-run-runtime-error.json` | `status_code: 15` with **both** `runtime_error` (one line) and `full_runtime_error` (the whole trace). The parser prefers the full form; the short one is what a browser tooltip shows and is not a diagnosis. |
| `judge-check-run-compile-error.json` | `status_code: 20` with both compile-error spellings, `total_correct`/`total_testcases` explicitly `null` (nothing reached a test case) and no `correct_answer` at all — which is why that member is `Bool?` rather than defaulting to `false`. |
| `judge-check-submit-accepted.json` | The submit shape's happy path: percentiles present, `total_correct == total_testcases`, and `last_testcase`/`expected_output`/`code_output` all `""` — the empty-string spelling of "not applicable" that the display readers fold to `nil`. |
| `judge-check-submit-wrong-answer.json` | The single most useful failure: `last_testcase`, `expected_output` and `code_output` all populated, `total_correct < total_testcases`, and **both percentiles `null`** — LeetCode has no percentile for a submission that failed, so those are absences and not zeros. |
| `judge-check-submit-time-limit-exceeded.json` | `status_code: 14` on the submit shape, with the failing case still named. |
| `judge-check-submit-runtime-error.json` | `status_code: 15` on the submit shape, both error spellings plus the failing case. |
| `judge-check-submit-compile-error.json` | `status_code: 20` on the submit shape: no counts, no percentiles, no failing case — just the diagnostic. |
| `judge-check-unknown-status.json` | A `state: "SUCCESS"` carrying `status_code: 7`, a code this app does not map. The verdict table has no default, so this is `apiChanged` naming the number rather than a confidently wrong verdict on somebody's submission. |
| `judge-check-unknown-state.json` | `state: "QUEUED"` — a fifth state. Same rule, on the other strict key. |

### Shape violations

Deliberately broken derivatives of the two recordings above, each isolating one
mismatch so a test can assert that `apiChanged` names the key path rather than
some other error being reported or — far worse — an empty result being returned.

`invalid-no-data.json`, `invalid-null-data.json`,
`question-detail-missing-content.json`, `question-detail-missing-question-id.json`,
`question-detail-unknown-difficulty.json`,
`question-detail-unnumbered.json`, `problem-list-missing-pairs.json`,
`problem-list-missing-slug.json`, `problem-list-unknown-level.json`.

The `question-detail-*` derivatives carry the same hand-added `questionId` as the
recording they are derived from — except `question-detail-missing-question-id.json`,
whose entire purpose is that the key is gone.

`problem-list-unknown-status.json` is the one violation that is *not* an error:
it pins the single deliberate leniency in this layer (an unrecognised per-account
`status` degrades to `.notStarted` instead of failing the whole catalog). The
reasoning is on `LeetCodeAPI.status(fromRESTValue:)`.

## Refreshing these

Re-record with the requests `LeetCodeAPI` builds — they are printed by
`LeetCodeAPITests.testRequestBodiesAreExact`'s expectations — and re-apply the
two documented edits to `problem-list.json` (trim to the same 12 ids, re-inject
the two statuses). A fresh `questionData` recording carries `questionId` on its
own, so the hand edit noted above disappears with it: drop the "except
`questionId`" label from those rows rather than re-applying anything. Then run
`swift test`: a real LeetCode change shows up as a failing parse, which is the
point of recording them at all.
