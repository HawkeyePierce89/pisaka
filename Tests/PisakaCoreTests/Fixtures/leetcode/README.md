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
| `question-detail.json` | verbatim — `questionData(titleSlug: "two-sum")`. Note `questionFrontendId` is the **string** `"1"` while the REST catalog spells the same number as the integer `1`; that disagreement is exactly why the parser reads a number leniently from either form. |
| `question-detail-paid-only.json` | verbatim — problem 170, LeetCode Premium. `isPaidOnly: true` arrives with `content: null` **and** `codeSnippets: null`, so the parser must not demand either when the flag is set: the rejection is the model's job (it reports `paidOnly`), not the parser's. |
| `question-detail-unknown-slug.json` | verbatim — a slug that does not exist answers `{"data":{"question":null}}` with HTTP 200. An explicit `null` here is "no such problem", **not** a shape violation, which is why the detail parser returns an optional instead of throwing. |
| `user-status-signed-out.json` | verbatim — `globalData` anonymous: `isSignedIn: false`, `username: ""`, and `isPremium: null` (absent-as-null, not `false`). |
| `problem-list.json` | verbatim **except trimmed and re-statused** — the real response is 2.0 MB / 4018 `stat_status_pairs`, of which 12 are kept in their recorded order, chosen to cover all three difficulty levels, a `paid_only: true` row (170) and both ends of the id range. The top-level counters (`num_total: 4018`, …) are left as recorded and deliberately disagree with the trimmed array: nothing parses them, and a fixture that quietly "fixed" them would hide that. Anonymous reports `status: null` for every row, so `"ac"` (1) and `"notac"` (2) were injected by hand — the only edit to any row. |
| `errors-schema-drift.json` | verbatim — the real HTTP **400** LeetCode answers when the query asks for a field the schema no longer has. This is the response the whole `apiChanged` design exists for, and it is worth having on record that it is a 400 with an `errors` array and *no* `data` member. |

### Authored, not recorded

Four shapes could not be obtained anonymously and without abusing the service, so
they are hand-written to the shape LeetCode's stack (Django REST Framework +
Graphene) produces and labelled here rather than passed off as recordings. If a
future session ever captures a real one, re-record it and delete the note.

| File | Why it is authored |
| --- | --- |
| `user-status-signed-in.json` | Requires a real session cookie, which is not committed. |
| `errors-not-authenticated.json` | Requires provoking an auth-gated field; the phrasing is Graphene's. |
| `errors-premium.json` | LeetCode answers a premium question with a null `content` (see above) rather than an error, but the errors-array phrasing exists on other premium surfaces; pinned so the classifier's paid-only branch is exercised. |
| `throttled.json` / `throttled-no-wait.json` / `rest-not-authenticated.json` | Provoking a real 429 means hammering the service. The body is DRF's standard `{"detail": …}`, and the two throttle variants pin the difference that matters to the user: whether the message can name a wait. |

### Shape violations

Deliberately broken derivatives of the two recordings above, each isolating one
mismatch so a test can assert that `apiChanged` names the key path rather than
some other error being reported or — far worse — an empty result being returned.

`invalid-no-data.json`, `invalid-null-data.json`,
`question-detail-missing-content.json`, `question-detail-unknown-difficulty.json`,
`question-detail-unnumbered.json`, `problem-list-missing-pairs.json`,
`problem-list-missing-slug.json`, `problem-list-unknown-level.json`.

`problem-list-unknown-status.json` is the one violation that is *not* an error:
it pins the single deliberate leniency in this layer (an unrecognised per-account
`status` degrades to `.notStarted` instead of failing the whole catalog). The
reasoning is on `LeetCodeAPI.status(fromRESTValue:)`.

## Refreshing these

Re-record with the requests `LeetCodeAPI` builds — they are printed by
`LeetCodeAPITests.testRequestBodiesAreExact`'s expectations — and re-apply the
two documented edits to `problem-list.json` (trim to the same 12 ids, re-inject
the two statuses). Then run `swift test`: a real LeetCode change shows up as a
failing parse, which is the point of recording them at all.
