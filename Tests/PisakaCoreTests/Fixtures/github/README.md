# Recorded `gh` output

Wire-level fixtures for `GitHubAPI`, the one file that holds every fact about
`gh`'s output schema (G2). **No test in this repository ever runs `gh` or reaches
the network** — `swift test` stays the offline, dependency-free gate it has
always been, and the test target cannot link `Process` at all — so these files
are what makes the parsers assertable against what the *real* command answered
rather than against a remembered shape.

They are read through `#filePath`, in the `Fixtures/leetcode` / `Fixtures/LSP`
style, so they need no SwiftPM resource declaration; the test target instead
`exclude:`s this directory in `Package.swift` (a `.json` beside Swift sources is
otherwise an unhandled-resource build warning).

## Provenance

Everything marked *verbatim* below was recorded with
`gh version 2.99.0 (2026-09-01)` against this repository
(`HawkeyePierce89/pisaka`), signed in as its owner — on **2026-09-03** for
`pr-checks.json` and `pr-list-empty.json`, and re-recorded on **2026-09-04** for
the three files the merge fields grew (`pr-list-merged.json`, `pr-view.json`,
`repo-view.json`). The `--json` field lists are
`GitHubCommands.pullRequestFields`, `.checkFields` and `.repositoryFields`
verbatim, which is what makes these files a check on the *request* as well as on
the parser. Bodies are re-indented by `json.dump(indent=2)`; no key, value or
ordering is otherwise altered.

## The files

| File | How it was produced |
| --- | --- |
| `pr-list-merged.json` | verbatim — `gh pr list --state merged --limit 1 --json <pullRequestFields>`. Pull request #54, whose rollup is the four `CheckRun` entries this repository's own CI publishes (`test`, `lint`, `build-macos`, `build-ios`), all `COMPLETED`/`SUCCESS`. Recorded against `merged` rather than `open` because nothing was open on the day; the row shape is identical and `state` carries the difference. Also the fixture behind `reviewDecision: ""` → `.none` (this repository requires no review) and behind `mergeable`/`mergeStateStatus` reading `UNKNOWN` — which is what GitHub answers for a pull request that has already been merged, and an honest reminder that neither field is a verdict a *closed* row can be judged by. |
| `pr-list-empty.json` | verbatim — what both list commands answer when nothing matches. It is the ordinary answer to the `--head` lookup for a branch with no pull request, and it must parse to an empty array rather than throw; that distinction is the whole reason the parser is strict about everything else. |
| `pr-checks.json` | verbatim — `gh pr checks 53 --json <checkFields>`. The nine-field rows for the same four jobs. Note the command's exit status was **not** recorded and is not consulted anywhere (G3): this file is what a *successful* parse looks like, and the same shape arrives under exit 8 ("checks pending") and exit 1 ("some check failed"). |
| `pr-view.json` | verbatim — `gh pr view 54 --json <pullRequestFields>`, **the same pull request `pr-list-merged.json` holds**, so the two files together are the assertion that a row read by number and a row read out of a list are the same value under the same tables. One object rather than an array element; that is the whole difference, and the only reason `GitHubAPI` has a second entry point rather than a second parser. |
| `repo-view.json` | verbatim — `gh repo view --json <repositoryFields>`. The only source of the create sheet's default base (G11) *and* of the merge sheet's method list: this repository allows all three methods, prefers `SQUASH` and does not delete the head branch on merge. |
| `pr-list-unknown-mergeable.json` | **authored** — one row whose `mergeable` is `PERHAPS`. The `GitHubMergeability` violation fixture: it pins that an unknown mergeability throws `unknownValue` naming `pr list[0].mergeable` rather than being read as "probably fine", which is the reading that would offer a Merge button for a state nobody has looked at. |
| `pr-list-unknown-merge-state.json` | **authored** — one row whose `mergeStateStatus` is `DRAFT`. Chosen deliberately over a nonsense word: `DRAFT` is a value GitHub's own enum *used* to carry and removed in a scheduled breaking change, so this fixture is simultaneously the `GitHubMergeStateStatus` refusal (naming `pr list[0].mergeStateStatus`) and the record of why the table has seven cases rather than eight — a draft answers `BLOCKED` and says it is a draft in `isDraft`, which is where the draft refusal is decided from. |
| `pr-list-mixed-typename.json` | **authored**, in the recorded row's shape. A rollup carrying one `CheckRun` and two `StatusContext` entries, which no repository here publishes: the legacy commit-status API is what non-Actions integrations still report through, and a rollup mixing the two kinds is decided over two different tables at once. Also carries `isDraft: true` and `reviewDecision: "APPROVED"`, the two row fields the verbatim capture leaves at their defaults. Summarises to `pending` — the unfinished `StatusContext` outranks the passed `CheckRun`. |
| `pr-list-unknown-conclusion.json` | **authored** — one `CheckRun` whose `conclusion` is `TELEPORTED`. The violation fixture, and the one that matters most: it pins that an unknown value in a closed table throws `GitHubSchemaError.unknownValue` naming `pr list[0].statusCheckRollup[0].conclusion`, rather than being rounded to something that renders as a checkmark. A parser that shrugged would pass every other test in this directory. |

## Re-recording

Re-record the five verbatim files whenever `GitHubCommands`' field lists change,
with the field list the constants then hold — the fixture and the request are
meant to be the same list, and a fixture recorded under an older one hides the
drift it exists to catch. The four authored files are maintained by hand; when
GitHub adds a conclusion, `pr-list-unknown-conclusion.json` keeps naming a value
that is still unknown, which is the point.
