# PisakaCore — the LeetCode integration (LC-1: login, open problem, solution file, description panel; LC-2: Run and Submit; LC-3: the problem browser)

Design documentation for the layer that signs in to LeetCode, turns a number, a
slug or a pasted URL into a solution file inside a folder the user set aside for
it, renders the problem statement beside the editor, runs or submits what the
user has typed there, and browses the whole problem list to find the next one.
Each entry records a
file's contract, invariants and the reasoning behind non-obvious decisions —
read the relevant entry before modifying that file, and update it when behavior
changes.

**What this layer is.** A transport seam whose only real implementation is
app-side, one file holding every fact about LeetCode's wire format, two pure
string layers (what the user typed, and how a file name names a problem), a
disk-cached problem catalog, a composed HTML document for the statement, one
`@MainActor ObservableObject` that sequences the awaits, and two companion models
beside it — one holding the judge's own state machine, one holding the browser's
filter and rows. On top of that sit
the app halves: a `URLSession` transport, a cross-platform Keychain store, a shared
`WKNavigationDelegate` that watches the login cookie store, and per-platform
chrome (a macOS menu + sheet + pane + browser window, an iOS screen + adaptive
pane/sheet + pushed browser screen), the pane and the sheet of which host the
judge section under the statement.

**The API is unofficial, and the whole design is shaped by that.** LeetCode
publishes no contract, no versioning and no deprecation notice. Three rules
follow, and they are stated here once so no entry below re-litigates them:

- **Everything schema-shaped is concentrated in one file.** Every URL, GraphQL
  document, header name and JSON key path lives in `LeetCodeAPI.swift`, so a
  LeetCode-side change is diagnosed and fixed in one place rather than hunted
  through a request builder, three models and a view.
- **Nothing shrugs.** A missing key, a null where a value belongs, an
  unrecognised difficulty, a shape-valid *empty* catalog — all of them are
  `LeetCodeError.apiChanged`, carrying the key path that did not match, because
  an empty result is indistinguishable from "that problem does not exist" and the
  user would be told the wrong thing forever. The two deliberate exceptions
  (per-row `status`, and `data.question: null`) are argued where they are made.
- **Requests are composed byte for byte, not delegated.** Core builds the
  `Cookie` header, the `x-csrftoken` LeetCode cross-checks it against and the
  `Referer` it refuses requests without, so the suite asserts them in a target
  that cannot link `URLSession`, and so no cookie jar anywhere in the app can
  quietly substitute a different session.

**Nothing new is bundled and nothing new is linked.** `project.yml`,
`Package.resolved` and `Resources/Licenses/licenses.json` are untouched by this
work: WebKit and Security are system frameworks, and the LeetCode endpoints are
reached with Foundation. (Adding an app-layer *file* still needs `xcodegen
generate` before a build — XcodeGen enumerates the source directory at generation
time — but no manifest changes.)

**Where the platform boundary is.** Everything decision-shaped is in
`PisakaCore`, Foundation-only and unit-tested: the request builders, the parsers,
the input grammar, the file-naming rule, the cache policy, the composed HTML and
the flow. Three things Core cannot do are app files behind protocols or plain
platform helpers — performing an HTTP request (`LeetCodeTransport` →
`LeetCodeURLSessionTransport`), keeping a secret (`LeetCodeCredentialStore` →
`LeetCodeKeychainStore`) and knowing where Application Support is
(`LeetCodeSupportDirectory`) — exactly the `LSPTransport`/`LSPProcessTransport`
split, for the same reason: `swift test` needs neither a network nor a Keychain
to exercise the part with the decisions in it.

**The stack, bottom to top.** `LeetCodeTransport` + `LeetCodeCredentials` +
`LeetCodeError` + `LeetCodeProblem` + `LeetCodeJudge` (the vocabulary) →
`LeetCodeAPI` (what to
send, and what an answer means) → `LeetCodeProblemInput` + `LeetCodeSolutionFile`
(the two pure string layers) → `LeetCodeCacheLayout` + `LeetCodeCatalog` (number
→ slug, cached for a day) + `LeetCodeStatementDocument`/`LeetCodeStatementCache`
(the panel's bytes) + `LeetCodeProblemFilter` (the browser's one pure pass over
catalog rows) → `LeetCodeModel` (the one place that sequences awaits) +
`LeetCodeJudgeModel` and `LeetCodeBrowserModel` (the two companions it owns,
which sequence the judge's awaits and the browser's) → the app surfaces.

**A reader with exactly one create.** The model never calls
`autosave.suspend()`/`localChanges.beginRevert()` and is never gated by them —
the position the symbol index and the LSP client already hold. The justification
is narrower here, because this layer *does* write: it only ever **creates** a
file that does not exist, inside a folder the user set aside for it, plus two
caches inside the app's own Application Support directory. It never rewrites a
file the editor may have buffered, never touches the worktree git is operating
on, and has no plan of its own to invalidate. Taking the writer gate would
serialise "open a LeetCode problem" behind whatever the project's git operations
are doing, for a write that cannot conflict with any of them.
**Run and Submit do not weaken that sentence, they narrow it**: the judge is a
pure reader. It takes the *live editor buffer* — never the disk copy, so nobody
has to save first — posts it, polls for a verdict and publishes value types. It
creates nothing, rewrites nothing, and touches neither the solution file nor
either cache, so the one create the sentence names is still `openProblem`'s.
**The browser narrows it further still**: it *creates* nothing and owns no cache
of its own — it reads the catalog the rest of the area already keeps, filters it
in memory, and opens a row through `openProblem` itself, so there is no second
open path and no second cache anywhere in this area. What it is not is
write-free: a `load()` that finds the catalog stale, and every `refresh()`,
rewrite `catalog.json` through `LeetCodeCatalog` — the catalog's own write, in
the catalog's one file, on the catalog's schedule, but reachable from a button
where before LC-3 only an open could reach it. Neither the write nor the gate
changes: the file is under `Application Support`, not in the worktree.

The decisions L1–L25 are written out at the end of this document, together with
the limits the design carries.

## Files

### `PisakaCore`

  - `LeetCodeTransport.swift` — the whole app/Core boundary of the integration:
    `LeetCodeHTTPRequest` (method, url, headers, optional body),
    `LeetCodeHTTPResponse` (status code, headers, `Data`), and
    `protocol LeetCodeTransport: Sendable { func send(_:) async throws -> … }`.
    Deliberately **not** `URLRequest`/`URLResponse`: the point of the seam is that
    Core composes every byte it cares about, so the schema suite can assert the
    `Cookie`, `x-csrftoken` and `Referer` headers literally in a target that
    cannot link `URLSession`. The body stays `Data` because *every* response shape
    — the GraphQL envelope, the legacy REST catalog, and the HTML interstitial a
    rate-limiting LeetCode serves instead of JSON — is interpreted in one place
    (`LeetCodeAPI`), and that place needs the bytes. A transport never retries,
    never interprets a status code (a 429 is delivered as a 429; calling that
    `throttled` is `LeetCodeAPI`'s job) and makes exactly one interpretation of
    its own: a failure to obtain *any* HTTP response — DNS, TLS, timeout, a
    non-HTTP response — is `LeetCodeError.network`. `headerValue(forName:)`
    matches **case-insensitively**, because RFC 9110 field names are and different
    stacks normalise them differently; the one header this layer reads
    (`Retry-After`) must be found whichever spelling arrived, which is also why
    the app-side transport passes header names through unchanged rather than
    canonicalising them into a second rule.
  - `LeetCodeCredentials.swift` — the session as a value, and where it is kept.
    `LeetCodeCredentials` is the `LEETCODE_SESSION` + `csrftoken` pair
    (`Equatable`, `Sendable`, `Codable` with **explicit** `CodingKeys`, since the
    Keychain item is one JSON blob and a property rename would otherwise silently
    invalidate every stored session). `cookieHeaderValue` renders the pair for the
    wire and lives here rather than in `LeetCodeAPI` so the two cookie *names* are
    written down exactly once — the same constants that find the cookies in the
    `WKWebView` store put them back on the wire.
    `from(cookies:)` is the pure rule both platforms' login observers share, and
    it is pure precisely because those observers are untested view code: *when a
    login succeeded* must not be decided in either of them. Both cookies are
    required (LeetCode sets `csrftoken` for anonymous visitors too, so it alone
    means nothing, and `LEETCODE_SESSION` alone cannot make a mutating call);
    values are trimmed and an empty value counts as absent (a sign-out blanks
    cookies as often as it deletes them, and `LEETCODE_SESSION=""` accepted as a
    session is a login that appears to work and then fails on every call); other
    names are ignored; and when a name appears twice — a store mid-refresh holds
    the old and the new — the **last** non-empty value wins, matching the order a
    jar appends refreshed cookies in. It takes `(name, value)` pairs and therefore
    cannot see a domain, which is deliberate: the domain filter is the app's
    (`LeetCodeWebSession`), because an SSO detour loads the provider's own site in
    the same web view and a `csrftoken` set by whoever that is must not be read as
    LeetCode's.
    `LeetCodeCredentialStore` is the seam over the Keychain wrapper, every member
    defaulted (the `CredentialStore`/`GitServicing` precedent) so a partial
    in-memory stub compiles — and the defaults are chosen so **absence is the
    explicit signal**: a store that implements nothing reads as "signed out",
    which is the safe verdict when every operation here requires a session.
  - `LeetCodeError.swift` — every way an operation can fail, as one
    `Error`/`LocalizedError`: `notLoggedIn`, `network(reason:)`,
    `apiChanged(detail:)`, `paidOnly(slug:)`, `throttled(retryAfter:)`,
    `folderUnavailable`, `fileSystem(reason:)`, and the judge's two:
    `judgeTimedOut(seconds:)` and `judgeUnavailable(reason:)`. **Those two are
    product refusals, not wire mismatches**, and that is why they are cases here
    rather than `apiChanged` details: nothing about the response was wrong when a
    poll runs out its budget (LeetCode simply kept saying `PENDING`) or when the
    file on screen is a Markdown note, so neither must send anybody hunting a
    schema change. `judgeTimedOut` carries the budget so the sentence can name it,
    and that sentence **says the submission was not undone** — LeetCode has it and
    the verdict is on the site — because the alternative reading (that the attempt
    was lost) is the one that makes a user submit twice. It re-applies the
    throttle case's "a wait worth naming" cap for the identical reason: the case is
    `public`, takes a bare `Double`, and `Int(_:)` *traps* on an infinite or
    over-`Int.max` one. `judgeUnavailable`'s `reason` is already user-facing,
    decided one layer up where the file and the session are both in view
    (`LeetCodeJudgeAvailability`), and it carries one answer that is not about the
    file at all: LeetCode's own `state: "FAILURE"`, its judge giving up — a state
    LeetCode documents by sending it, so it is stated rather than reported as a
    schema change. `apiChanged`'s `detail` is the
    whole diagnosis for an unofficial API — it names the key path or value that
    did not match (`data.question.content`, `difficulty.level = 7`), so a bug
    report names the one line of `LeetCodeAPI` to edit. `throttled` carries the
    server's own `Retry-After` when there was one and `nil` when there was not,
    the difference being whether the sentence can name a wait. **Both ends apply
    the same "a wait worth naming" cap** (positive, at most an hour): the parser
    puts the header through `plausibleWait` like every other wait it reads, and
    `errorDescription` re-tests the value because the case is `public` and takes a
    bare `Double`. `Double("inf")` and `Double("1e400")` both parse and are both
    `> 0`, and `Int(_:)` *traps* on either — so without the cap a `Retry-After`
    chosen by a CDN in front of LeetCode terminated the app in the one path whose
    job is reporting a transient failure gracefully. Lives in Core, like
    `GitError`, so every sentence the user reads is unit-tested; without
    `errorDescription` these would all render as "operation couldn't be completed
    (PisakaCore.LeetCodeError error N)", throwing away the one string that says
    what broke.
  - `LeetCodeProblem.swift` — the two domain models and their two enums.
    `LeetCodeDifficulty` is one enum for two wire spellings (GraphQL's
    `"Easy"/"Medium"/"Hard"`, REST's `level: 1/2/3`), both mapped in `LeetCodeAPI`
    and both strict. `LeetCodeProblemStatus` (`notStarted`/`attempted`/`solved`)
    is carried because it arrives with the catalog anyway.
    `LeetCodeProblem` is frontend id + slug + title + difficulty + paid-only +
    status: the identifier that matters *there* is `frontendID` (the number on the
    site and the number a user types), and LeetCode's internal `questionId` stays
    off the catalog row, which has no use for it. It is
    **not** `Codable`: the on-disk cache has its own versioned DTO, so this model
    can be renamed or extended without invalidating every user's cache.
    `LeetCodeProblemDetail` composes it — rather than restating its fields, so the
    catalog and the detail can never disagree about what a problem *is* — and adds
    the HTML `content` **fragment**, `codeSnippets` keyed by LeetCode's language
    slug, `exampleTestCases` in LeetCode's own order (what Run's input box is
    prefilled from), and **`questionID`** (L16). That last one is the internal id,
    modelled here and only here because the judge payloads are the only thing in
    the app that speaks it: `question_id` is how `interpret_solution` and `submit`
    say *which problem* is being answered, and LeetCode accepts no other spelling.
    **It is not `frontendID` and the two must never be swapped** — they agree on
    the older problems and drift freely for newer ones, so a mix-up looks perfectly
    correct on Two Sum and judges a different problem entirely on anything recent.
    It is a `String` because that is what the payload sends and because nothing
    arithmetic is ever done with it; there is deliberately no `Int` accessor to
    reach for by mistake.
  - `LeetCodeJudge.swift` — the judge's whole vocabulary as Foundation-only value
    types, with no behaviour beyond naming itself: the *wire* half (which URL,
    which payload keys, which numeric code) stays in `LeetCodeAPI`, and these are
    what it parses into, so the flow model and both views talk about a verdict
    without ever having seen a JSON key.
    `LeetCodeJudgeKind` (`.run`/`.submit`) **travels with every judge call rather
    than being inferred**, because it decides three separate things — which URL is
    posted to, whether the payload carries `data_input`, and which of two entirely
    different finished shapes a check response is read as. The last is the sharp
    one: both kinds are polled from the *same* `submissions/detail/<id>/check/`
    endpoint with overlapping-but-different key sets, so a check parsed under the
    wrong kind reads plausible and is wrong.
    `LeetCodeJudgeContext` (slug + `questionID` + `exampleTestCases`) is the small
    projection of a detail that the judge actually uses, and it exists because
    **neither thing this app already keeps about a problem holds it**: a file name
    carries the frontend number and the slug, the statement disk cache carries
    markup. Modelled as its own value rather than by keeping whole details around,
    since the statement and every language's starter code are the large half of
    that response and exactly the half the judge never reads (L21).
    `LeetCodeVerdict` is LeetCode's numeric `status_code` as its nine outcomes,
    with the wire codes *as the raw values* so the mapping is one line rather than
    a switch that can drift from the table it mirrors, and with a `displayName`
    spelled the way LeetCode spells it so a user comparing against the site reads
    the same words. **No `unknown` case and no `default`** (L22): a tenth outcome
    silently rendered as "Unknown Error" would be indistinguishable from LeetCode's
    *own* code 21, which it sends on purpose. `isAccepted` is documented as the
    whole answer on a submit and deliberately *not* the headline on a run — code 10
    there means "your code executed", and whether the output was right is
    `LeetCodeRunResult.matchedExpected`.
    `LeetCodeJudgeState` is `PENDING`/`STARTED`/`SUCCESS`/`FAILURE`. The fourth is
    a small, deliberate extension beyond the three the happy path walks: LeetCode
    does answer `FAILURE` when its own judge gives up, and mapping that to a stated
    "the judge did not finish" beats reporting a state LeetCode documents by
    sending it as a schema change.
    `LeetCodeRunResult` and `LeetCodeSubmitResult` are the two finished shapes.
    Every decoration on them is optional and **an absence stays an absence** —
    LeetCode omits the runtime on a compile error, the percentiles on anything that
    is not Accepted, and the counts when nothing reached a test case, and a `0 ms`
    or a `0 / 63` invented to fill the gap would read as a measurement. Runtime and
    memory are `String`s because they are display strings on the wire and nothing
    here computes with them; `errorText` is the compile-or-runtime diagnostic in
    the fullest form LeetCode sent, because a diagnostic cut to its first line is
    precisely what sends a user back to the browser.
    *Two shapes on the run result are where LeetCode's own arrays are easy to
    misread, and both are decided here rather than in a view.* `input` is the
    echoed `data_input` as **one block**, deliberately not split into cases:
    LeetCode spells that field one line per *parameter*, so Two Sum's single case
    is `[2,7,11,15]` then `9` and its three examples are six lines — pairing those
    lines with the per-case arrays labels the wrong text as every case's input on
    any problem taking more than one argument. `caseCount` is read off `answers`
    and `expectedAnswers` and **excludes `stdOutputs`**, which arrives one element
    longer than there are cases on an accepted run (four entries for three, as
    `judge-check-run-accepted.json` records); taking the longest array instead
    rendered an empty phantom final case on the happy path, every time. It is
    still read *per* case, defensively, because it can also be shorter — a runtime
    error stops printing where it stopped running. Both live on the value because
    they are statements about LeetCode's shapes, and this is where those are
    decided and tested; the two untested views only index.
    `LeetCodeJudgeCheck` (`.pending`/`.started`/`.finishedRun`/`.finishedSubmit`/
    `.judgeFailed`) is what the poll loop's whole control flow switches over.
    Modelling "not finished yet" as a *case* rather than as a nil result is what
    makes publishing a half-built verdict impossible: until the check says there is
    a result, there is no value that could be published.
  - `LeetCodeAPI.swift` — **the one schema file** (L1). Endpoints
    (`https://leetcode.com/`, `/graphql`, `/api/problems/all/`), the two GraphQL
    documents and their operation names, the `User-Agent`, `problemURL(slug:)`,
    the three request builders, the three parsers, both difficulty mappings, the
    GraphQL-envelope handling and a private key-path-naming JSON reader.
    *Requests.* `commonHeaders` sends `csrftoken` **twice** — inside `Cookie` and
    as `x-csrftoken` — because that is exactly how Django's CSRF check works: it
    compares the two and rejects the request when they disagree or either is
    missing, which is the single most likely reason a hand-rolled LeetCode call
    gets a 403. The GraphQL body is serialised with `.sortedKeys` so the bytes are
    reproducible and the suite can assert them literally. Credentials are **not
    optional anywhere**: the product decision is that every LeetCode operation
    requires a login (paid-only and solved status only exist with one), and an
    optional-session signature would invite that to be re-litigated per call site.
    *The catalog endpoint is legacy on purpose* (L2): the whole ~4000-row list
    arrives in one `GET`, where the GraphQL equivalent is paged at 100 a time —
    ~41 requests against an unofficial API for data that changes weekly.
    *Parsing.* `parseUserStatus` returns a `UserStatus` (declared here, because it
    is a response shape rather than a domain model) and a signed-out answer is
    **returned, not thrown**: "who am I" is the one question whose honest answer
    can be "nobody", and the sign-in flow needs it as a value. Every other call
    turns the same verdict into `notLoggedIn` via `throwIfSignedOut(_:)`, so
    `userStatus.isSignedIn` is login's single source of truth — which is also why
    `parseProblemList` deliberately **ignores** the catalog's own `user_name`,
    even though it is empty exactly when the caller is signed out.
    `parseQuestionDetail` is **optional-returning**: `data.question: null` is
    LeetCode's recorded answer (HTTP 200) for an unknown slug, and conflating that
    with a shape violation would tell somebody who mistyped `two-sums` that the
    API had changed. A **premium detail parses, it does not throw**: LeetCode
    answers a paid problem with `isPaidOnly: true` and null
    `content`/`codeSnippets`, so the parser tolerates both absences *when the flag
    is set* (and only then) and hands the flag on — the refusal belongs to the
    model, the layer that knows a file was about to be written. The flag alone is
    *not* the refusal there either: a **subscriber** gets the same flag with the
    content present, so what the model refuses is the flag with an empty `content`
    behind it.
    Everything else in the detail is demanded, `exampleTestcaseList` included:
    an empty list is a legitimate answer, so folding an absent key into `[]` would
    make "LeetCode renamed this field" and "this problem ships no example input"
    the same value — and nothing reads the examples yet, which is precisely why
    that drift would surface late, as Run submitting an empty input. The
    `questionFrontendId` is demanded **positive**, on the same principle as the
    slug check and for the same reason: it is the other half of the file name, and
    `parts(fromFileName:)` reads back only a positive number, so a `0` would write
    `0000-two-sum.swift` — a file this app could never associate with a problem
    again, silently and permanently.
    *Envelope order is not arbitrary.* Throttling is decided from the status and
    headers **before** the body is looked at, because a rate-limited LeetCode
    sometimes answers with an HTML interstitial that no JSON parse survives, and
    deciding `throttled` from the body alone would report that as `apiChanged` and
    send whoever reads the bug report hunting a schema change that never happened.
    Then DRF's `{"detail": …}` is told apart by its sentence (both throttling and
    missing credentials use it, and both can be a 403 depending on the endpoint's
    throttle class), then 401, then a GraphQL `errors` array — which is classified
    by **phrase matching**, because LeetCode's Graphene layer sends no
    machine-readable code. Premium phrasings are checked before authentication
    ones (the auth list contains "not authorized", which a premium refusal also
    says), and the **fallback is `apiChanged`** carrying LeetCode's own message,
    which is what keeps phrase matching honest: an unknown phrasing produces the
    loud, self-diagnosing error rather than a confidently wrong verdict.
    *The one leniency* (L3) is `status(fromRESTValue:)`. Difficulty is strict —
    "everything is Easy" is exactly the silent wrongness an unofficial API
    produces when it grows a fourth tier — but per-account `status` degrades to
    `.notStarted`, because it is cosmetic, per-row, and being strict would let one
    odd row out of four thousand kill the whole catalog parse and with it *every
    open*. The asymmetry is asserted by a test so it cannot be "tidied" either way.
    That leniency covers a wrong **type**, not only an unrecognised string, so the
    field is read as `pair.value["status"] as? String` rather than through
    `optionalString` — which throws `apiChanged` for anything present that is not a
    string, and would have handed the whole catalog back to one row's `status` the
    day LeetCode spells it as a number (it already spells `difficulty` two
    different ways across its two endpoints).
    *The JSON reader* is a private `JSONObjectReader` that remembers its own path,
    rather than `Codable`: a `DecodingError` would say
    `keyNotFound(CodingKeys(...))`, and this layer's whole contract is that the
    string in the bug report is `data.question.content`. `integer(_:)` accepts a
    JSON number *or* a numeric string, because GraphQL spells the very same
    problem number as `"1"` and the REST catalog as `1` (both recorded in the
    fixtures); a non-numeric string is still `apiChanged`, naming the value.
    Absent and explicitly-null are not distinguished, because on this API they
    mean the same thing everywhere they are read optionally.
    *The judge's three endpoints* are `interpretURL(slug:)`, `submitURL(slug:)`
    and `checkURL(id:)`, all built on `problemPageURL(slug:)` — the same page as
    `problemURL(slug:)` but **with the trailing slash**, which is not cosmetic and
    is why the two are separate functions rather than one with a flag nobody would
    read. Django's `APPEND_SLASH` answers the slash-less form with a 301, and a
    redirected `POST` is re-sent as a `GET` by every stack that follows RFC 9110's
    historical behaviour, which LeetCode then answers with a 405 that says nothing
    about the real cause. The seeded header comment keeps the slash-less form,
    because that is the link a human clicks.
    A second `commonHeaders(credentials:referer:)` **overload** — not a defaulted
    parameter, so every pre-existing call site's bytes are provably unchanged —
    lets those three send the **problem page** as `Referer` where the GraphQL and
    catalog calls send the site root: that is where a browser is when it runs or
    submits, and LeetCode's CSRF-protected POST views are the ones most likely to
    check it. `interpretRequest`/`submitRequest` compose
    `{"data_input", "lang", "question_id", "typed_code"}` as plain JSON (not
    GraphQL) with the same `.sortedKeys` byte-reproducibility, and **submit omits
    `data_input` rather than sending it empty** (L20): a submission runs LeetCode's
    own suite, and that key on that endpoint would be either ignored or, worse,
    honoured. `checkRequest(id:slug:credentials:)` is a bodyless `GET` that carries
    the slug for one reason only — the `Referer` — since the URL itself does not
    mention the problem.
    *Reading the judge's answers.* `parseInterpretID`/`parseSubmissionID` both go
    through a new `opaqueIdentifier(_:)` reader, and so does the detail's
    `questionId`: an identifier this app never interprets and only ever sends back.
    It is lenient about *form* for `integer(_:)`'s reason (a run's id is the string
    `runcode_…`, a submission's is a JSON number, and `questionId` has arrived both
    ways) and strict about there being a value at all, because a response without
    one means there is nothing to poll and the run silently never happened. A
    non-numeric string is deliberately accepted — the value is opaque and its only
    requirement is to round-trip into a payload verbatim. `questionId` is demanded
    **for every problem including a locked one**, since a Premium problem is still
    a problem the judge would have to be addressed about, and substituting
    `questionFrontendId` would be the one repair that looks right on Two Sum and
    judges something else on anything recent. `interpret_expected_id` is
    deliberately ignored: the expected output arrives inside the run's own check
    response, so polling a second id would double the request rate for data already
    in hand.
    Both ids then pass a second, narrower gate — `judgeID(_:path:)` — for a reason
    `opaqueIdentifier` cannot cover: they **become path components of the check
    URL**, and `appendingPathComponent` percent-encodes almost everything *except*
    the two spellings that matter, passing `/` and `..` through verbatim. An id
    carrying either would send this app's session cookie to a leetcode.com URL
    nothing in this file chose, so unreserved ASCII is required and anything else
    is `apiChanged` naming the key — the same discipline `normalizedSlug(_:)`
    applies to the other wire value that becomes a path component (L4), rather
    than leaving it to the URL loader's discretion. It is not a guess about the
    format: a run's id is `runcode_1770000000.1234567_AbCdEfGhIj` and a
    submission's is a decimal number, and both are in the fixtures.
    `parseJudgeCheck(_:kind:)` is **strict where the verdict lives and lenient
    around it** (L22). `state` and `status_code` decide what the user is told, so an
    unrecognised value of either is `apiChanged` naming it — a tenth code rendered
    as some default is a confidently wrong verdict on somebody's submission, which
    is the loudest version of the wrongness this whole file exists to prevent.
    Everything else is a *display* field read through a grouped family of
    `display…` readers, **none of which throws**: LeetCode omits the percentiles on
    a rejected submit, omits `code_answer` on a compile error, spells runtime as a
    string (and has spelled it as a number), and folds "not applicable" to `""`
    about as often as it omits the key. That asymmetry is the catalog's
    `status(fromRESTValue:)` trade-off appearing again — a missing detail line
    against no verdict at all — and it is grouped in one block in the source so it
    stays visible. `judgeErrorText()`'s *order* is part of the contract: full
    compile, short compile, full runtime, short runtime, with compile preferred
    because a response carrying both compiled nothing, and the full form preferred
    because reading the whole diagnostic in the editor is the entire reason not to
    go back to the browser. `displayNumber` refuses a non-finite value and
    `displayInteger` never substitutes a zero, since "0 of 63 passed" and "the
    judge never got that far" are different things to say. `displayStrings` keeps
    **every element's position**, rendering an unreadable one as `""` rather than
    dropping it: these arrays are read by index against each other and against
    `caseCount`, so a dropped element would shift every later case's output under
    the wrong heading — a silent misattribution, where an empty field is merely an
    absence the surface already knows how to draw as nothing. The `state` table is
    matched case-insensitively after trimming — lenient as to *form*, strict as to
    the set — and `judgeState(fromWireValue:)` answers `nil` for anything outside
    it, which the caller turns into `apiChanged`.
  - `LeetCodeProblemInput.swift` — what the user typed, once understood:
    `.number(Int)` or `.slug(String)`, or `nil`. Pure and here rather than in
    either entry point because both are untested view code and the field is
    **live-validated** — the same function that enables the Open button decides
    what gets fetched. The order of the rules *is* the rule: a LeetCode URL is
    recognised first (a URL contains both a slug and, in `/problems/1/`-style
    links, digits, so reading it as anything else takes the wrong half); anything
    else containing `/` is then rejected outright rather than falling through; an
    **all-digit** string is a number attempt *and nothing else* (L4) — `0` and a
    30-digit paste satisfy the slug shape too, so falling through would fetch the
    slug `0` and answer "no such problem" instead of the honest "that is not a
    problem number", and no LeetCode slug is all digits so nothing is lost;
    otherwise a slug.
    `normalizedSlug(_:)` is **the** slug rule, written once and reused by
    `LeetCodeSolutionFile`'s reverse parse and by `LeetCodeCacheLayout`'s
    sanitiser, so the app cannot accept a slug in the input field that it would
    then refuse to recognise in a file name it wrote itself. Lowercase ASCII,
    digits and interior hyphens; input is lowercased (a pasted `Two-Sum` is the
    same problem) but nothing else is repaired — spaces are *not* turned into
    hyphens, because a title is not reliably a slug (`3Sum` is `3sum`) and a
    silently wrong slug reads as "no such problem".
    URL handling is string surgery rather than `URLComponents`, because people
    also type `leetcode.com/problems/…` with no scheme, which `URL(string:)` reads
    as a path with a nil host; stripping the scheme by hand treats both spellings
    identically and leaves the host check explicit. Query and fragment are dropped
    first (LeetCode's own "Copy Link" appends `?envType=…`), the slug is taken from
    the component *after* `problems` wherever it appears (so `/description/`
    suffixes and contest URLs both resolve), and `leetcode.cn` is accepted because
    its slugs are the same strings and the detail request still goes to
    `leetcode.com`.
  - `LeetCodeSolutionFile.swift` — how a problem becomes a file. `LeetCodeLanguage`
    carries the five facts about an offerable language **in one row**
    (`SyntaxLanguage`, LeetCode's `langSlug`, the file extension, the line-comment
    token, the display name) rather than as four dictionaries that can disagree —
    the failure mode being a picker entry that produces a `.txt` file or a header
    comment that is a syntax error; a test additionally asserts each row's
    extension resolves back through `SyntaxLanguage(fileExtension:)` to the same
    language, so a seeded file always highlights as what it is.
    `offerableLanguages` is a deliberate subset of both LeetCode's ~20 languages
    and the editor's cases — a language belongs only if the editor can highlight it
    *and* LeetCode accepts submissions in it — and all three directions of the
    mapping go through that one list. The third is
    `language(forFileExtension:)` (L19), which exists because the judge has to name
    a `lang` in its payload and the file on screen is all it has: the extension is
    where a solution file's language is written down. It goes through
    `offerableLanguages` rather than through `SyntaxLanguage` — which knows `.rb`
    and `.cpp` this app does not offer — so a file this app *wrote* always maps back
    to what it was written in, and a file it did not write maps either to something
    LeetCode will accept or to nothing at all. `nil` is the honest answer for
    `0001-two-sum.md`, and the judge turns it into a stated refusal rather than
    guessing a language and submitting prose. Matched case-insensitively (a `.PY`
    on a case-insensitive volume is the same file) and tolerant of a leading dot,
    since callers pass `URL.pathExtension`, which carries none, but a hand-written
    `".py"` must not silently answer `nil`. Note the two non-obvious slugs: LeetCode says
    `python3` (plain `python` is Python 2, still listed and still accepted, and
    seeding a Python 2 snippet would be a bug) and `golang`.
    **The name is the association** (L5). This integration keeps no side-car
    database mapping files to problems: the description panel now, and LC-2's
    Run/Submit later, answer "which problem is this tab?" by reading the file name
    back. So `name(number:slug:language:)` → `0001-two-sum.swift` and the reverse
    `parts(fromFileName:)` are written as one unit and tested as a round trip. The
    number leads and is zero-padded to four digits so the folder sorts in problem
    order (wider numbers pass through unchanged); the extension is the language's,
    so the editor highlights and the symbol index reads the file with no extra
    wiring; nothing depends on the *title*, whose spaces, colons and question
    marks would eventually be a name the file system refuses. The consequence the
    user sees is that renaming a solution file detaches it from its problem — which
    is accepted, the alternative being invisible state that goes stale.
    The reverse parse is deliberately **permissive** (`2024-notes.md` reads as
    problem 2024): the second half of the association — the file must sit inside
    the configured LeetCode folder — belongs to `LeetCodeModel`, and nothing is
    written on the strength of a parse. It drops the extension rather than checking
    it, because a solved problem may have been rewritten in another language, and
    validates the slug half through `LeetCodeProblemInput.normalizedSlug(_:)`.
    `header(…)` is **one** line — number, title and the problem URL in that
    language's comment syntax — because this is a file the user is about to type
    in, and six lines of ceremony above the cursor is what people delete first; it
    exists for the human reading the file outside the app and is never parsed back.
    One line is a **guarantee**, not a description of well-behaved input: the title
    is LeetCode's and goes into a *line* comment, so a separator inside it would
    end the comment and leave the remainder as bare, uncommented text on line 2 of
    a file the never-overwrite rule then keeps forever. Trimming the ends does not
    cover that, so every separator inside is collapsed to a space (empty pieces
    dropped, so a CRLF costs one space and not two), and a title that is nothing
    but separators falls back to the slug exactly as a blank one does.
    `contents(header:snippet:)` writes the header, a blank line, then LeetCode's
    snippet **verbatim** — it is the signature the judge expects, so nothing
    reindents, trims or rewrites it — with a trailing newline added only when the
    snippet lacks one, so re-seeding can never differ from itself by a blank line.
    A `nil`/empty header yields the snippet alone, and an empty snippet the header
    alone rather than a stray blank line.
  - `LeetCodeCacheLayout.swift` — pure `URL` math over a base directory the app
    supplies: `catalog.json` and `Statements/<slug>.html`. **No file-system access
    at all** — the `LSPInstallLayout` discipline restated for a second cache root:
    nothing stats, reads, creates or deletes, so the catalog's tests reason about
    paths against a `StubFileTree` while the app points the same math at
    `~/Library/Application Support/Pisaka/LeetCode` (or the iOS container's
    equivalent) with no second implementation. The `init` normalises the base
    **lexically** (`.`/`..` resolved, no `realpath(3)`, no `stat(2)`, and
    explicitly *not* `URL.standardizedFileURL`, which consults the disk under
    `/private/{tmp,var,etc}` — the bug `LSPInstallLayout.normalisedComponents(of:)`
    records at length), so two spellings of one root compare equal; `contains(_:)`
    delegates to `LSPInstallLayout.directory(_:contains:)` so "inside my root" is
    one comparison in this codebase rather than two that can drift.
    Everything derives from one base, so deleting that directory is a complete
    de-provisioning of the integration's cache — the disk *is* the state.
    **A slug is not a path component until it has been checked**:
    `statementFile(forSlug:)` is optional-returning and the check is
    `LeetCodeProblemInput.normalizedSlug(_:)` — the same rule the input field
    applies — so `../../../Library/…` cannot become a write, there is exactly one
    character set to audit, and a statement can never be cached under a name the
    app would later refuse to look up.
  - `LeetCodeCatalog.swift` — the problem list, its disk cache, and the one thing
    it is for: turning the number a person typed into the slug every request is
    made by (nothing in the API answers "what is problem 1"). `@MainActor`, like
    every other model here, so "two opens at once" is a question about ordering
    rather than locking.
    **The policy, stated once so no call site re-decides it** (L6): the cache is
    good for a day (`maximumAge`), within which opening a problem costs exactly one
    request — the detail; a **miss forces one refresh**, because a day-old catalog
    is exactly what a brand-new problem is missing from; *one*, tracked by
    `hasRefreshedFromNetwork`, so a typo'd number cannot become a request per
    keystroke — and a snapshot restored from disk deliberately does **not** set
    that flag, since the disk copy is the one that may predate the problem being
    asked for. `isStale` also treats a `fetchedAt` in the *future* as stale, so a
    clock that moved backwards (or a cache file copied from another machine)
    cannot pin the catalog until the calendar catches up. `refresh` is **coalesced**
    (`refreshTask`), because two problems opened at once is the ordinary way two
    2 MB downloads used to happen. That task is unstructured, so the wait for it is
    wrapped in `withTaskCancellationHandler`: `Task { }` inherits no cancellation
    and `task.value` does not observe the *awaiting* task's either, so pressing Esc
    in the Open Problem sheet used to leave `openProblem` suspended until the
    download finished or the transport's 60-second resource timeout fired — with
    `beginOpen()`'s counter still raised, i.e. the next sheet came up entirely
    disabled. Cancelling the waiter now cancels the fetch; a second, uncancelled
    caller coalesced onto it sees `network(reason: "cancelled")` and can retry,
    which is the cheaper of the two failures. The `refreshTask` slot is cleared
    from **inside** the task rather than in the initiating caller's `defer`, so the
    coalescing window is the task's own lifetime — a caller that goes away while
    the fetch runs on must not open the slot for a second 2 MB download.
    *Off the main actor.* The catalog is ~2 MB and ~4000 rows, and all of the
    expensive part of handling it is pure: `LeetCodeAPI.parseProblemList`, the
    `CachedCatalog` decode and its encode each run in a `Task.detached`, because an
    `await` inside a `@MainActor` method resumes on the main actor and left them
    freezing the editor behind a sheet whose own spinner could not turn. **The
    `FileServicing` calls stay on the actor**: every other reader in this app
    reaches it from the main actor, the test doubles are plain mutable classes, and
    a second thread in one of their dictionaries is a corrupted hash table rather
    than a flaky assertion. So the split is per-step — read on the actor, decode
    off it, publish on it — not per-method.
    **Not-found is a value, not an error** (L7): `resolveSlug` answers `nil`, which
    is the truthful answer to a typo, and `apiChanged` stays reserved for LeetCode
    having changed shape. **A slug input reaches neither disk nor network**: it
    already *is* the key the detail request is made by, so consulting the catalog
    would turn opening a pasted link into a 2 MB download and would refuse a
    problem newer than the cache — LeetCode's own `data.question: null` is the
    authority there. It is still **re-checked against `normalizedSlug`** on the way
    out, and an unusable spelling is `nil` (i.e. "no such problem") rather than a
    request: `LeetCodeProblemInput.slug` is a public case with a plain `String`
    payload, and what `resolveSlug` returns is appended to the user's folder by
    `LeetCodeSolutionFile.name(…)`, where `appendingPathComponent` does not resolve
    `..` — and a name carrying a separator would additionally defeat the
    never-overwrite rule, which compares `lastPathComponent`. That is the same
    boundary `LeetCodeAPI`'s wire-slug check guards, and the point of checking here
    too is that the rule must not hold merely because `parse(_:)` happens to be the
    only producer today. **An empty catalog is never published or cached**: a
    shape-valid zero-row response would poison the cache for a day and make every
    open report "no such problem", so it is `apiChanged`. That rule is enforced at
    **both** doors — `CachedCatalog.init?(json:)` rejects a zero-row file exactly
    as it rejects an unknown difficulty, because a file with no rows and a recent
    `fetchedAt` decodes cleanly (the row validation has nothing to run over) and
    would publish a snapshot that is not stale, so `loadIfNeeded` would return
    without fetching and the browser would sit on "No problems loaded." with no
    error for a day. `resolveSlug(forNumber:)` has the forced-refresh-on-miss
    escape hatch from that; `loadIfNeeded` has none, so the rule belongs on the
    file rather than on either reader.
    `publish` rebuilds two indices (`number → slug`, `slug → problem`) rather than
    searching four thousand rows per keystroke, and on a duplicate number or slug
    the **first** row wins, so the answer is LeetCode's own ordering.
    *The disk cache.* `loadFromDiskIfNeeded` runs once per session — after it,
    "no snapshot" means "there is no cache" rather than "it has not been looked
    at". It is **coalesced like `refreshTask`, and raises `hasConsultedDisk` on the
    way *out*, not on the way in**: the four-thousand-row decode is a suspension
    point, and a flag raised before it made the two states it exists to separate
    indistinguishable again for that whole window. The two callers that overlap
    there are the ordinary pair — the statement panel's `cachedProblem(forSlug:)`
    against an open's `resolveSlug(forNumber:)` — and the second used to read a
    *mid-decode* cache as absent, download the 2 MB list the disk copy was about to
    answer for, and then have its fresh snapshot overwritten by the resuming disk
    one while `hasRefreshedFromNetwork` stayed raised; that spent the
    forced-refresh-on-miss budget, so a problem present only in the fresh list
    answered "no such problem" for the rest of the session. A second caller now
    awaits the read exactly as it awaits an in-flight refresh, and the publish
    additionally refuses to replace a snapshot that is already there — `refresh` is
    public and takes no disk detour, so that rule sits at the publish rather than
    resting on today's call graph. Every failure is treated identically as
    **there is no cache**: no
    file, unreadable file, unparsable JSON, an unknown schema version, or a row
    whose difficulty this build has never heard of. Deliberately not granular: the
    file is this app's own, a mismatch means version drift or a half-written file,
    and salvaging a partial catalog would produce one silently missing problems.
    The on-disk shape is its own `CachedCatalog` DTO with a `schemaVersion`,
    deliberately *not* `LeetCodeProblem`: the bytes on a user's disk are a
    compatibility surface that may only change on purpose, so changing the file is
    a visible edit here and a version bump rather than a side effect of an
    unrelated refactor. Enums travel as raw strings and are mapped back by hand, so
    an unknown value invalidates the cache instead of decoding into a
    wrong-but-plausible default. **The slug is validated on restore too**
    (`LeetCodeProblemInput.normalizedSlug(_:) == slug`), for the reason `LeetCodeAPI`
    validates it on the wire: a restored slug is what the next detail request is
    made by and — through the parser's `requestedSlug` fallback — what a *file
    name* is composed from, so the cache file is the second door into that path and
    must not be the unguarded one. A version that is not *exactly* current is
    rejected in **both** directions, since a newer build's file may carry meaning
    this one would silently drop. Keys are sorted on write so a cache file diffs
    readably.
    **The cache write cannot fail the open** (L8): `writeCache` swallows its errors
    into `lastCacheWriteFailed` and the session runs on an in-memory catalog. The
    user asked to open a problem and that succeeded; the cost of the degradation is
    one extra fetch next launch, which they never see. (`StubFileTree` gained a
    `writeFailures` injection point so it is assertable.)
    *The browsing entry point.* `loadIfNeeded(credentials:)` is the one door for a
    reader that wants **the whole list** rather than one answer: the disk cache
    once (`loadFromDiskIfNeeded()`), then a fetch **only when `isStale`**
    (`refresh(credentials:)`). Both are the existing coalesced ones, so two
    surfaces appearing at once still read the file once and fetch once, and
    nothing new is decided — `maximumAge`, the DTO and `currentSchemaVersion` are
    untouched, and the result is read off the same public `problems`/`fetchedAt`
    accessors every other reader uses. `resolveSlug(forNumber:)` is the *wrong*
    door for it, which is why this exists at all: that one forces a refresh when
    the number it was asked about is missing, and a browser asks about no number,
    so every empty search field would have paid for a 2 MB download. **It throws
    whatever the refresh threw**, deliberately — the one place `resolveSlug`'s
    "stale rows beat no rows" degradation is *not* applied, because that rule needs
    to know what the caller will do with the rows and here the caller is a surface
    with a list already on screen: it keeps what it shows, puts the error beside
    it, and reads the still-populated `problems` off the same accessor. Swallowing
    the failure here would leave that surface unable to tell a refresh that landed
    from one that never happened (L23/L24).
  - `LeetCodeProblemFilter.swift` — what the browser is currently showing, as one
    pure `Equatable, Sendable` value: `query`, `difficulties`, `statuses`, and
    `apply(to rows:)`. **The browser is a client-side filter over the one catalog**
    (L23) — every row is already in hand, so narrowing is a pass over an array
    rather than an endpoint, which is why nothing was added to `LeetCodeAPI.swift`
    for any of this.
    It is *one value* rather than three fields on the model so there is exactly one
    place to recompute from, and so no surface can set a field and forget to re-run
    the filter. `apply(to:)` is **one pass and no sort**, so catalog order is
    preserved *by construction* rather than by a sort that could later drift out of
    agreement with LeetCode's own ordering.
    The rules: the query is trimmed of whitespace and newlines and an empty (or
    all-whitespace) one matches everything; **whether it is a number is asked
    through `LeetCodeProblemInput.parse(_:)`**, so L4 is reused rather than
    restated, and a `.number(n)` matches `frontendID == n` **exactly and nothing
    else** — typing `1` answers problem 1, not the ~1000 rows whose number begins
    with a 1; every other parse result (a slug, a URL, nothing at all) falls
    through to a substring match on the raw trimmed query, so a pasted problem URL
    matches nothing here and the Open Problem field stays that paste's surface;
    the substring match is case-insensitive over the **title or the slug** through
    `range(of:options:)` and deliberately *not* the `localized…` variants, so the
    answer does not depend on the device's locale and the table test is stable; and
    difficulty and status are set membership where an **empty set means no
    filtering**, so "nothing selected" and "everything selected" behave identically
    — which is exactly what a row of toggles needs and why neither surface has an
    "All" case to keep in sync.
    **`isPaidOnly` is not a dimension of this type at all.** Premium rows are always
    listed (with a lock marker on the surface) and can never be hidden: hiding them
    would leave gaps in LeetCode's numbering that read as missing problems. Stating
    that as an *absent field* rather than as a flag defaulted to `false` is what
    makes it structural instead of a default somebody can flip.
    `isEmpty` (no query, no difficulty selection, no status selection) exists so a
    surface can tell "no problems match your filter" from "no problems at all" —
    two different sentences with two different fixes.
  - `LeetCodeStatementDocument.swift` — the panel's whole document, composed here
    so both platforms' web views are thin. LeetCode answers `question.content` with
    an HTML **fragment**: no `<html>`, no charset, no stylesheet, and `<img src>`s
    relative to the site root — handed straight to a `WKWebView` that is Times New
    Roman on white, mojibake for every non-ASCII character, and broken images. So
    `html(fragment:title:theme:fontSize:)` emits `<!DOCTYPE>`, `<meta charset>`, a
    viewport meta, `<base href="https://leetcode.com/">` and an inline stylesheet.
    **Colours arrive as values**: `Theme` is six CSS colour strings plus the
    `color-scheme` keyword (what makes the web view's own scrollbars match), and
    `Theme.resolved(_:systemPrefersDark:)` is the one mapping both platforms call —
    `ThemePreference.system` carries no colour by itself, so the *caller* supplies
    the appearance it is actually running in and the document stays a pure function
    of its inputs, which is what lets a test assert light and dark differ without
    Core importing AppKit. Every field is asserted to reach the CSS, so a colour
    that is declared and never interpolated fails the suite rather than silently
    doing nothing. `fontSize` goes through `SettingsStore.clampFontSize` because an
    unparsable `font-size` drops the whole declaration silently rather than failing
    loudly; code sits one point smaller than prose, since a monospace face at the
    editor's own size renders visibly larger beside proportional text.
    **The fragment is interpolated verbatim, never sanitised** (L9): rewriting
    LeetCode's markup would be a second parser for an unofficial API, drifting
    silently, and the document loads no script and grants no privileges that would
    make the markup interesting — the views turn `allowsContentJavaScript` off,
    which is what keeps "verbatim" from meaning "executable". Escaping applies to
    the *title* alone, which this app supplies.
    `LeetCodeStatementCache` (same file) is the statement half of the disk cache:
    one fragment per slug, stored exactly as LeetCode sent it, for the offline
    reopen. **What is cached is the fragment, not the composed document** — theme
    and font size are session state, so a cache of rendered HTML would be stale the
    instant the user switched appearance. **Blank is absent, in both directions**:
    `store` refuses an empty or blank fragment (the empty-catalog rule restated) and
    `fragment(forSlug:)` reads a blank file back as `nil`, because a truncated cache
    file is how an empty one appears in practice and serving it would render a
    permanently blank panel *and* suppress the fetch that would have repaired it.
    **Neither half throws**: a read failure is "not cached", a write failure is "it
    will be fetched again", and `store` returns a `Bool` so the degradation is
    assertable and every caller may ignore it. Images are not mirrored — the known
    limit of the offline reopen.
  - `LeetCodeModel.swift` — the one `@MainActor ObservableObject` the integration
    is driven through: who is signed in, opening a problem, and the statement for
    the active tab. Everything below it is pure or single-purpose, and **this is
    the only place in the area that sequences awaits**, which is why it is the only
    place generation tokens live.
    *The values it publishes.* `LeetCodeSolution` (url + problem + language) is
    what `openProblem` hands back for the app to open as an ordinary tab.
    `LeetCodeOpenOutcome` is a four-case enum — `created`/`resumed`/`noSuchProblem`
    /`superseded` — because **two of the four answers are values rather than
    errors** (L7 again): a typo is answered truthfully rather than as `apiChanged`
    or as a new `notFound` case sitting beside it, and a superseded open publishes
    *and writes* nothing, so the caller must not open a tab for it.
    `LeetCodeStatement` carries slug, number, title, the verbatim fragment and
    `isFromCache`.
    *Generation tokens.* Three counters, not one (L10) — open, statement, account —
    so a statement refresh cannot cancel an open; each entry point bumps its counter
    **synchronously**, before its first suspension, and discards its result when it
    comes back to find the counter moved. Signing in or out bumps all of them,
    because a session change invalidates everything in flight. `isBusy` is a
    **count** under the hood, so the first of two overlapping operations finishing
    cannot switch the spinner off under the second. `isOpening` is a **second**
    counter, raised by `openProblem` alone, and it is the one the entry sheets bind
    their controls to. The two answer different questions and conflating them was a
    real defect: a statement refresh is started by *switching tabs*, so a single
    counter meant selecting a LeetCode tab on a slow link and then pressing ⌘⇧P
    produced a sheet with a disabled field and a dead Open button — Return silently
    swallowed — waiting on a request for some other tab.
    *The account.* `isSignedIn` is **optimistic at launch**: a stored pair sets it
    before anything is confirmed, rather than showing "signed out" for the duration
    of a round trip. `refreshUserStatus()` is non-throwing and silent on failure —
    it is what the app calls at launch, and an unreachable LeetCode is not a
    sign-out — **but a rejection is not a failure, it is an answer**, so
    `notLoggedIn` is caught by name and flips the state through
    `markSessionRejected()` while everything else (offline, throttled) stays quiet.
    Swallowing it with the rest left a dead session reading as signed in, with the
    account name in the menu, until the user tried to open something.
    `signIn(with:)` stores the pair, confirms it, and discards a session
    LeetCode rejects at the moment it was obtained; a confirmation that could not be
    *made* (offline, throttled) is **not** a rejection, so the cookies stay and the
    name fills in on the next refresh. **Both spellings of a rejection end the same
    way**: LeetCode says "not signed in" with `isSignedIn: false` *or* with a
    401/403 or an auth `errors` array, which reaches `signIn` as a thrown
    `notLoggedIn` — and a catch that only recorded it left the Keychain item saved,
    every surface reading "Signed in", and the state corrected only by whichever
    later operation happened to fail. `notLoggedIn` is therefore caught by name
    there and signs out, exactly as the `isSignedIn == false` branch beside it does. **A rejected request flips `isSignedIn` but
    keeps the stored credentials** (L11, `markSessionRejected`): a 403 from an
    unofficial endpoint is as often a throttle in disguise as a dead session, and
    clearing the Keychain on one would turn a transient failure into a mandatory
    web-view re-login. **And the flip is reversible**, through
    `markSessionAccepted()` on every successfully parsed detail response: keeping
    the credentials only makes sense if the state can come back, and until that
    existed nothing ever put it back — `refreshUserStatus()` is the only other
    writer and the app calls it once, at launch. One throttled response therefore
    left every surface saying "Not signed in" for the rest of the run while
    `requireCredentials()` went on opening problems from the same pair, and the
    macOS menu renders Sign Out only under `isSignedIn`, so signing out became
    unreachable. A response that came back is the same class of evidence the
    rejection is, pointing the other way. It names no account — that stays
    `refreshUserStatus()`'s alone — and it is guarded on the credentials rather
    than on a generation, because the state it must not resurrect is a *sign-out*,
    which clears them. Only `signOut()` forgets them — and the app layer's half of a
    sign-out (the web view's cookies) is `LeetCodeWebSession.signOut(model:)`;
    either half alone leaves the user half signed in. **A sign-out holds whatever
    the Keychain does**: every credential lookup falls back to the store, so a
    `clear()` that threw would leave the pair on disk for the next open to read back
    out — succeeding, and writing a file, while the app showed "signed out". A
    `storedCredentialsAreDiscarded` flag raised by `signOut()` (and cleared by the
    next `signIn`) makes the store unreadable for the rest of the run; the *next*
    launch reads it afresh, since a pair the user asked to forget surviving a
    Keychain failure is one they can sign out of again.
    *Opening.* `openProblem(input:language:)` captures the folder **synchronously**
    (it may be re-pointed while the open runs, and the file belongs where it was
    asked for), then: no folder → `folderUnavailable`; no session → `notLoggedIn`;
    resolve the input through the catalog; fetch the detail — each of those two
    checking the generation **before** it may answer `.noSuchProblem`, since that
    is a sentence the caller shows and a superseded attempt must contribute nothing
    at all; a Premium answer with nothing behind it → `paidOnly` **before anything
    is written** (the *locked shape*, not the flag — a subscriber's Premium detail
    arrives complete and opens); compose the name; and **create the
    file only if it does not exist** (L12) — an existing file is `.resumed`, not
    read, not rewritten and not compared, because the whole point of the naming rule
    is that reopening a problem returns you to your work, and re-seeding would
    silently delete a half-finished solution, the one failure here a user could not
    undo. Existence is asked as a **directory listing**, not as a read: a read that
    failed for any reason other than absence would read as "not there" and the next
    step would overwrite the user's work. **A listing that fails throws rather than
    answering "absent"** — the same argument one step further out, and the hole the
    first version of this left: a folder that is searchable but not readable took
    the identical path an absent file takes. `ensureDirectory` runs *before* the
    listing so the two cases are separable — a failure there is `folderUnavailable`
    (the folder is gone, or something that is not a directory occupies its path),
    and a failure after it is a real one and reported as `fileSystem`. Refusing to
    write is the only answer that keeps "never overwrite" true when the folder
    cannot be seen. **The name comparison is case-insensitive and the outcome
    carries the entry's own URL**, which is the same rule against the volume the
    user actually has: APFS and HFS+ are case-insensitive by default, so
    `0001-Two-Sum.swift` *is* `0001-two-sum.swift`, and an exact comparison would
    call it absent and then write over the user's solution — the very loss the
    listing exists to prevent. Answering with the found entry's URL rather than the
    composed one keeps that correct on a case-sensitive volume too: the tab that
    opens is the file that was found, not a name that exists nowhere. A language
    LeetCode does not offer this
    problem in yields the header alone rather than a refusal — the file, the name
    and the panel are all still correct. `ensureDirectory` failing is reported as
    `folderUnavailable` (the folder is gone, or something that is not a directory
    occupies its path), which is exactly what that sentence asks the user to fix.
    **A cancelled open reports nothing**, the statement refresh's rule applied to
    the path that writes: both entry sheets cancel their open task on disappear, so
    pressing Esc mid-fetch makes `URLSession` throw and arrive as
    `network(reason: "cancelled")`, and the generation token does not cover it —
    that orders a request against its *replacement*, and here there is none. So the
    guard sits on `publish`, which is both where the sentence would land (in
    Preferences and in the iOS account rows, until some later operation cleared it)
    and where a `notLoggedIn` would flip the account state — and a request nobody
    waited for says nothing about the session either. The error is still *thrown*:
    the caller already discards it under the same `Task.isCancelled` test, so the
    two halves agree without the model having to guess what the caller wants.
    **Opening also caches and publishes the statement — but only once the file
    exists**: the fragment is already in hand, so fetching it again when the tab
    opens would be a second request for bytes we have. The ordering is part of the
    rule rather than an accident of where the call sits: the panel is published
    globally and is *not* keyed to the active tab, so adopting the statement before
    `ensureDirectory`/the listing/the write — each of which can throw — would leave
    a statement for a problem the user has no file for sitting beside whatever
    unrelated tab happened to be open, with nothing to clear it until they switch
    tabs — and it is what makes the offline reopen work from the first open
    onwards. Publishing it is not enough to *stop* that second request, though,
    because the panel's refresh is keyed on the tab and the tab is about to change:
    the model therefore keeps `slugsFetchedThisRun`, the set of slugs whose fragment
    came off the network this run, and `statement(forFileAt:in:)` serves those from
    the cache alone. Without it every open cost two identical `questionData`
    requests, and switching back and forth between two LeetCode tabs cost one more
    each way — against an unofficial, rate-limited API the whole design is built
    around not annoying. `slugsKnownAbsent` is the same record for the *negative*
    answer and exists for the same reason read from the other side: the name rule
    is deliberately permissive, so a `2024-notes.md` the user dropped in the folder
    parses as problem 2024 and asks about slug `notes` — a request that is
    permanently going to answer "no such problem", re-issued on every switch to
    that tab. **Three** answers are recorded there: `data.question: null`; a
    detail that arrives with an empty `content` — which is the Premium shape
    (`isPaidOnly: true` with a null `content`), equally settled *about that slug*,
    and reachable because the model refuses to *open* a Premium problem this
    account cannot read but a solution file for one can reach the folder another
    way (written under a subscription that has since lapsed, or by hand); and a **`paidOnly`
    error**, which is that same Premium answer in LeetCode's *other* wire shape — a
    GraphQL `errors` array the classifier reads by phrase rather than a parsed
    detail. Both shapes are reachable (the parser tolerates the first, `classify`
    produces the second), so recording one and not the other left exactly the loop
    this set exists to stop, for the one kind of file most likely to sit in the
    folder unopenable. Offline, throttled and
    rejected are recorded by none of the three: those are failures to ask and must
    still be retried, while all three of these are LeetCode *answering*. `signOut()` **and `signIn(with:)`** empty both sets, since a session
    change in either direction invalidates what was concluded under the old one.
    Both halves are load-bearing: a session can end *without* a sign-out — LeetCode
    rejects one, `markSessionRejected()` flips the published state and the stored
    pair deliberately stays — and the user then signs in again through the login
    sheet with no `signOut()` in between, so clearing on sign-out alone left every
    slug this run had concluded was Premium-locked or absent short-circuited for
    the rest of the app run. Clearing on sign-in is what lets a user who subscribes
    (or fixes their session) mid-run see the statement. The sets are emptied while
    deliberately
    **leaving `statement` standing**: the fragment is public content, is still in
    the disk cache, and is republished from it with no session at all, so clearing
    it would be the one piece of state a sign-out removes that signing back in does
    not restore (the panel's refresh is keyed on the *file*, which a sign-out does
    not change, so nothing would re-ask until the user switched tabs and back).
    *The statement.* `associatedProblem(forFileAt:in:)` is the pure half of the
    association and is exposed separately so a view can ask "is this tab a LeetCode
    problem" without starting a fetch; it checks **both** halves — the name parses
    to a number and slug, *and* the file sits inside the LeetCode folder — through
    `CanonicalPath.canonical` + `ScopedFileAccess.path(_:isWithin:)`, the primitives
    every other "inside this directory" question in the app uses, so a folder
    reached by a symlink still matches. `statement(forFileAt:in:)` takes a **URL,
    not a file name**, because the second half needs the whole path, and it serves
    **cache first, network behind it**: a cached fragment is published before the
    request is made, so switching tabs is instant and an offline reopen shows
    yesterday's statement. The consequence, stated so it is not read as a bug: *a
    failure with a cached fragment present is not an error* and sets no `lastError`,
    because the user is looking at the statement either way. A `nil` url or folder
    clears the panel. **A cancelled refresh reports nothing at all**: the request
    lives in a view's `.task`, cancelled when the window closes or the app is
    backgrounded mid-fetch, and `URLSession` then throws — arriving here as an
    ordinary `network` error. The generation token does not cover it, because that
    orders a request against its *replacement* and there is none, so without the
    `Task.isCancelled` check a "could not reach LeetCode: cancelled" sat on
    `lastError` (visible in Preferences) until some later operation cleared it. It
    is equally not a session rejection — a request nobody waited for said nothing
    about the session — so the check comes before `markSessionRejected()`.
    The question the panel last asked is recorded as `lastStatementRequest`, and
    **`signIn(with:)` asks it again**. The panel's refresh is driven by a view keyed
    on the tab and the folder — everything the *association* depends on, and
    deliberately nothing about the session, which is what lets those views go on not
    observing this model — so a signed-out user looking at a solution file with no
    cached fragment got an empty pane, signed in *because* the pane said they had
    to, and changed neither half of that key: nothing re-asked, and the statement
    only appeared after switching tabs and back. Keeping the question here keeps the
    account dimension where the account lives. Both halves or nothing: a `nil` tab
    or folder is not a question, and re-asking it would only re-publish `nil`. The panel's **title** has its own small store, `titlesBySlug`,
    for a reason that only shows up on the second visit to a tab: two things know a
    title and neither is reachable there. The catalog knows every one, but it is
    loaded only to resolve a *number* — a slug or a URL resolves to itself and never
    fetches it — and the disk fragment cache holds markup, not a title. So a problem
    opened by URL showed "1. Two Sum" while its detail was in hand and then degraded
    to "1. two-sum" the first time the user switched tabs and came back, permanently,
    because that refresh is answered from the cache and short-circuits on
    `slugsFetchedThisRun` before any fetch could correct it. Behind that store the
    catalog is asked through `cachedProblem(forSlug:)`, which **consults the disk
    cache** (never the network) rather than the pure `problem(forSlug:)`: the disk
    copy was otherwise reachable only from the number path, which a statement
    refresh never takes, so the offline reopen this whole cache-first branch exists
    for rendered "1. two-sum" at launch with "Two Sum" sitting unread in
    `catalog.json` beside the fragment. Asked only when this run has no title of its
    own, so the ordinary tab switch still touches no disk. `signOut()` does *not*
    empty it, matching the disk fragment cache it parallels: a problem's title is
    public content, not something the session revealed.
    *The judge's context.* `judgeContexts` is a `[String: LeetCodeJudgeContext]`
    memo of what Run and Submit need about each slug a detail has arrived for this
    run — the internal `questionId` and the examples — because **nothing else in
    this app keeps either** (L21). It is written in `fetchDetail`, *not* at that
    method's three call sites: it is the one place a detail response passes
    through, so opening a problem, refreshing the statement and the judge's own
    lazy fetch all record it by construction and a fourth caller added later
    cannot forget to. In memory and per run — the statement disk cache stores the
    bare fragment and its format is deliberately untouched — and emptied by
    `signIn(with:)` and `signOut()` alongside `slugsFetchedThisRun`, for the same
    reason: a session change invalidates what was fetched under the old one.
    `judgeContext(forSlug:)` is **the memo first, one lazy fetch behind it**: the
    ordinary case costs no request at all, and the slug this run never fetched —
    a solution file left over from a previous launch, opened straight into the
    editor with its statement served off the disk cache — costs exactly one, after
    which the memo answers. Its `nil` is L7 on a new axis: "LeetCode does not know
    this problem" is a *value*, the honest answer for a file the folder happens to
    hold (the name rule is deliberately permissive), and reporting it as
    `apiChanged` would tell someone with a stray note that the API had changed. That
    negative is recorded in the same `slugsKnownAbsent` the statement panel uses,
    for the identical reason: this question is asked every time a judge surface
    resolves its problem, so without it a stray file re-issues a request that is
    permanently going to answer "no such problem".
    *What the companion may reach.* `send`, `requireCredentials`,
    `markSessionRejected()` and `markSessionAccepted()` are **internal rather than
    private** so `LeetCodeJudgeModel` can use them: it is a companion of this
    model, not a stranger, and a second transport call site would be a second place
    the `network` fold could be forgotten. `isSignedIn` gained a `didSet` that tells
    the judge its buttons' answer moved — placed on the property rather than at the
    three sites that write it, because two of those (`markSessionRejected()`/
    `markSessionAccepted()`) are reached from arbitrary request paths including the
    judge's own: one writer, one hook. `invalidateInFlightWork()` bumps the judge's
    token with the other two (L17), since a poll in flight is invalidated by a
    session change exactly as a fetch is.
    *Plumbing.* Every request goes through one `send` that folds a non-`LeetCodeError`
    into `network`, so a decorator or a stub cannot escape this layer's vocabulary
    (the same fold `LeetCodeCatalog` applies). A Keychain that refuses the item does
    not fail the sign-in (`lastCredentialSaveFailed`, the `lastCacheWriteFailed`
    shape). `judge` is owned here the way `catalog` is — and is a `lazy var` for
    the one reason lazy is ever right: it is constructed with `self`, which does
    not exist until this initialiser has run. Nothing observable happens on first
    access, so where it is first touched does not matter.
  - `LeetCodeJudgeModel.swift` — the second `@MainActor ObservableObject` of this
    area: the editable input, the POST, the poll and the verdict. **A companion
    model owned by `LeetCodeModel` the way `catalog` is** (L17), for two structural
    reasons: the owner is already the largest file here and this is a whole second
    state machine, and the judge surfaces observe *this* object, so a keystroke in
    the test-case box invalidates one section of one pane instead of every surface
    bound to the account and the statement. The back-reference is `unowned` and
    deliberately **not** a protocol seam — what it needs (the session, the
    question-id memo, the two session transitions) is `LeetCodeModel`'s and nothing
    else's, this object is reachable only through its owner, and the suites drive
    it through a real model over the scripted transport, so a host protocol would
    be a fourth abstraction standing in for one the tests already build.
    *Availability is a pure, synchronous decision, not a `Bool`.*
    `LeetCodeJudgeAvailability` is `.ready(LeetCodeLanguage)` / `.notASolutionFile`
    / `.unsupportedLanguage(String)` / `.notSignedIn` / `.busy`, **each carrying
    the sentence the disabled button explains itself with** — which is what makes
    "a dead control with nothing to say" a state this layer cannot reach. The
    static `availability(problemSlug:fileExtension:isSignedIn:isRunning:)` is
    resolved from four facts and no request, so it is answered the instant a tab
    becomes active and unit-tested as a table. **The order is the rule**, most
    permanent fact first: what the *file* is cannot be fixed by signing in or
    waiting, the session is fixed by one action, and `busy` resolves itself in
    seconds — reporting "a run is already in progress" for a Markdown file would be
    true and useless. The language half comes from
    `LeetCodeSolutionFile.language(forFileExtension:)` (L19), so the two directions
    can never disagree.
    *Preparing.* `prepare(forFileAt:in:)` is driven by the view's `.task(id:)` on
    the same tab-and-folder key the statement pane uses (the LC-1 pattern), and two
    rules follow from that. **Re-preparing the same file resets nothing** — the
    key fires again on every re-render of the host, and a prepare that reset the box
    would throw away what the user typed and cancel a poll in flight for no reason.
    **A different file is a different problem**: the box, both results and the last
    error are reset and a poll still running is superseded, because its verdict has
    nowhere to go. The context comes from the owner's memo (one lazy fetch at
    worst), and the `nil` answer degrades availability to `.notASolutionFile`
    rather than raising an error. Nothing is asked at all for a surface whose
    buttons are already disabled — a request spent on a signed-out or unsupported
    tab is a request against an unofficial API for nothing.
    *Resolving the context is separate from preparing, and reachable three ways*,
    because "nothing is asked for a disabled surface" left a hole big enough to
    send an empty run through. A surface prepared while signed out returns before
    resolving anything, and one whose resolution failed gives up — and in both
    cases the `.task(id:)` key has not moved, so nothing was ever going to ask
    again: the box stayed empty and the first Run posted an empty `data_input`,
    which is not "run against no cases" but a verdict on input the user never
    chose, while the examples sat visible in the statement directly above. So
    `resolveContextIfNeeded` is called by `prepare` on a new file, by `prepare`
    again on the *same* file (the repeat that used to be a pure no-op), and by
    `sessionDidChange()` when a sign-in turns a surface that could not ask into one
    that can. It is a no-op once the context is in hand, so a re-render still costs
    nothing. `resolveContext(forSlug:)` underneath it **coalesces**: the three
    entry points and a button press can each discover the context missing, and
    signing in then immediately pressing Run would otherwise ask LeetCode the same
    question twice, so the work is one *unstructured* `Task` they share — unstructured
    precisely so it is not cancelled because whichever caller started it went away —
    keyed by the slug, so a resolution for the previous problem is never handed to
    the next one. `adopt(context:)` **prefills the box and never overwrites it**:
    a resolution can land long after the user typed their own case into it, and
    throwing that away because an answer finally arrived is the one thing this
    section must not do to text somebody wrote. The run path holds the matching
    belt-and-braces rule — an empty box on a context that only just resolved sends
    the problem's own examples rather than nothing at all.
    `sessionResolution` is held (and awaited by the suites through
    `awaitSessionResolution()`) because the sign-in path is the one piece of work
    here that no caller is waiting on; without a handle a test could only race it.
    *The flow.* `run()` and `submit()` share one `start(kind:)`: resolve readiness,
    read the **live editor buffer** synchronously — never the disk copy, so the user
    does not have to save first and what they see is what is judged — capture the
    generation, POST, take the id, then poll `check` at a fixed interval until the
    state is terminal. **A second press supersedes rather than being refused**:
    `availability` reports `.busy` so the button can disable itself, but the model's
    own readiness check ignores that, and the first attempt — whose generation has
    just moved — publishes nothing at all. The refusal path still *states* itself
    (`judgeUnavailable`) rather than returning silently, because a button that does
    nothing is the one outcome this area does not allow.
    *Budgets are data* (L18): `Budgets(run: 30, submit: 60)`, defaulted and
    injectable, enforced against a `now()` **deadline rather than an attempt
    count**, so a network that slows down cannot silently double the wait the user
    was promised. Exhaustion publishes the typed `judgeTimedOut`; the one thing a
    poll loop must never do is hang. Submit gets twice Run's because it queues
    behind LeetCode's own judge on the full suite. `pollInterval` is 1 s — about
    what LeetCode's own page uses, and a shorter one on an unofficial API is
    exactly what gets rate-limited — and both `now` and `sleep` are seams, so the
    whole state machine including a thirty-sleep budget exhaustion runs
    deterministically and `swift test` gains no wall-clock time.
    *The fourth generation token* obeys the other three's rule exactly (L17):
    captured synchronously before the first `await`, checked after every
    suspension, and an attempt that comes back to find it moved publishes
    **nothing at all** — not the result, not an error, and *not the phase*, since
    clearing that would switch off a spinner the newer attempt turned on. It is
    bumped by a new attempt, by `cancel()` and by a sign-in or sign-out through the
    owner's `invalidateInFlightWork()`. Cancellation is separate from supersedence
    and handled by `Task.isCancelled`, the LC-1 rule restated: the view's task going
    away makes `URLSession` throw, and a request nobody waited for must not put a
    sentence on screen or say anything about the session. `cancel()` does **not**
    undo the submission — LeetCode has it — which is the same statement
    `judgeTimedOut` makes and the reason neither pretends otherwise.
    *Session transitions on this axis.* A `notLoggedIn` arriving anywhere in the
    flow flips the account state through the owner's `markSessionRejected()`, and
    every parsed judge response calls `markSessionAccepted()` — the owner's rule
    applied wherever a response arrives. `sessionDidChange()` is deliberately
    separate from `invalidateInFlightWork()`, because the two happen at different
    moments: signing in bumps the token *before* the state flips, and the two
    `markSession…` transitions move it with no invalidation at all. Without it,
    signing in while looking at a solution file left the buttons disabled until the
    user switched tabs and back — the stale-key problem `lastStatementRequest`
    solves one layer up.
    *The test-case box* is session state and only that (L20): prefilled from the
    problem's own examples joined by LeetCode's newline convention, sent verbatim
    by Run, **ignored entirely by Submit**, never written to disk, never carried
    across launches, reset when the problem changes.
  - `LeetCodeBrowserModel.swift` — the third `@MainActor ObservableObject` of this
    area: the filter the user is typing into, the rows it leaves, and the two ways
    the catalog behind them is brought up to date. **A companion model owned by
    `LeetCodeModel` the way `catalog` and `judge` are** (L25), for the judge's two
    reasons: the owner is already the largest file here, and the browser surfaces
    observe *this* object, so a keystroke in the search field invalidates the list
    alone rather than every view bound to the account, the statement or the judge.
    The back-reference is `unowned` and deliberately not a protocol seam — what it
    needs (the session and the one catalog) is `LeetCodeModel`'s and nothing
    else's, and the suite drives it through a real model over the scripted
    transport. It is a `lazy var` for the judge's reason: it is constructed with
    `self`.
    *What it publishes.* `filter` (the one bindable value, whose `didSet` is **the
    one place filtering is recomputed**, so a surface cannot set a field and forget
    to re-run it — and which takes no generation token, because
    `LeetCodeProblemFilter.apply(to:)` is synchronous and pure and there is nothing
    to supersede); `problems` (everything the catalog knows) and `visibleProblems`
    (what the filter leaves), both **stored rather than computed**, since a
    computed `visible` would re-filter four thousand rows on every SwiftUI body
    evaluation, which is several per keystroke; `fetchedAt` (what the "Updated …"
    line renders from); `isLoading`; the typed `lastError`; and `availability`.
    `LeetCodeBrowserAvailability` is the judge's availability shape narrowed to two
    cases — `.ready` / `.notSignedIn`, the refusal carrying **the sentence the
    surface shows** ("Sign in to LeetCode to browse problems."). **Signed out is a
    value this browser renders, not an error it dumps**: nobody asked a question
    that failed, there is simply no session yet, and neither platform view has to
    invent a sentence for a `Bool`.
    *The two entries.* `load()` is the idempotent one both surfaces call on appear
    — it goes through `catalog.loadIfNeeded`, so re-entering the browser inside the
    staleness window costs **no request at all**. `refresh()` is the explicit
    affordance, through `catalog.refresh`, and is the only way a solved mark from
    five minutes ago reaches the screen (L24). Both share one private `update`,
    which resolves the session **synchronously before anything suspends**: no
    session publishes `.notSignedIn`, clears no rows and records no error.
    **A failure with rows in hand keeps them** — `resolveSlug`'s degradation rule
    on this axis — so the typed error is published *beside* the rows rather than
    instead of them; with no rows anywhere it stands alone. `adoptCatalog()` is
    guarded on the catalog holding anything at all, so a failed refresh can still
    surface rows the disk read produced and can never blank a populated list.
    `publish(_:)` runs `markSessionRejected()` **before** setting the sentence,
    because that flips `isSignedIn`, which calls `sessionDidChange()` here, which
    clears `lastError` — the reverse order would wipe the very sentence it is
    reporting. `currentCredentials()` asks *both* halves (`isSignedIn` and the
    store), so the browser cannot go on fetching under a session every other
    surface has already stopped believing in (L11).
    *The fifth generation token* obeys the other four's rule exactly: bumped
    synchronously before the first `await`, checked after every suspension, and an
    attempt that comes back to find it moved publishes **nothing at all, the
    spinner included** — clearing `isLoading` there would switch off one a newer
    attempt turned on. Cancellation is separate and handled by `Task.isCancelled`
    (the view's task going away makes `URLSession` throw, and a request nobody
    waited for must not put a sentence on screen), but the spinner *is* cleared on
    that path, because nobody else will. It is bumped by `load()`, `refresh()` and
    `sessionDidChange()`.
    *The one shield in this area.* `update` runs the catalog call inside an
    **unstructured `Task` it then awaits**, so this task's cancellation does not
    reach it. `LeetCodeCatalog.refresh` cancels the *shared*, coalesced 2 MB fetch
    when the caller awaiting it is cancelled — the right trade where that caller is
    the Open Problem sheet, whose canceller is an explicit Esc. Here the canceller
    is SwiftUI tearing down a `.task` because a window closed or a screen was
    popped: routine, and no withdrawal of anybody *else's* question, so an open
    coalesced onto the same download would have failed with `network(reason:
    "cancelled")` on a catalog it still needed. An unstructured `Task` inherits no
    cancellation and `value` does not observe the awaiting task's either, so the
    fetch runs on for whoever is waiting on it while this browser still publishes
    nothing — the `Task.isCancelled` check above is what makes both true at once.
    *The session hook.* `sessionDidChange()` is called from `LeetCodeModel`'s
    `isSignedIn` observer beside the judge's — one writer, one hook — and it bumps
    the token, recomputes `availability`, clears the error and **clears the rows**.
    That last is the point: the status column is per-account, so leaving one
    account's solved marks standing under another's name is the single wrong thing
    this surface could show. The catalog's own cache is per app rather than per
    account, so the next `load()` republishes from it — and inside the staleness
    window republishes the *previous* account's marks until a `refresh()`, which is
    the limit L24 states rather than hides.
  - `SettingsStore.swift` (modified; the entry is in `core-services.md`) — three
    stable keys: `leetCodeFolderPath` (a plain path, stored verbatim; a value
    that is blank once trimmed normalises to `nil` so "unset" has one spelling,
    but a real path keeps the spelling the file system gave it — a folder name
    may end in a space),
    `leetCodeFolderBookmark` (iOS-only in practice: the security-scoped blob for a
    picked override) and `leetCodeLanguage`. The language is held as the whole
    `LeetCodeLanguage` **row** rather than as a slug, which makes "an unparsable
    value falls back" structural: there is no way to *hold* a language this build
    does not offer, an unknown stored slug resolves to `defaultLanguage`, and what
    reaches `UserDefaults` always reads back. `leetCodeFolderURL` is the read side.

### `Pisaka` (app layer — compiled on both destinations unless noted)

  - `Platform/LeetCodeURLSessionTransport.swift` — the real `LeetCodeTransport`,
    the exact counterpart of `LSPDownloadService` on the provisioning seam: Core
    owns which URL, which document, which headers and what the answer means; this
    file owns the socket and knows none of it. Kept to the three decisions it
    actually makes.
    **The cookie jar is switched off four times, at both ends**: `.ephemeral` (no
    persistent jar by construction), `httpCookieStorage = nil` +
    `httpCookieAcceptPolicy = .never` (nothing is *kept* from a response),
    `httpShouldSetCookies = false` and `httpShouldHandleCookies = false` per
    request (nothing is *attached* to one). One intent stated repeatedly, the
    `LSPDownloadService` "nothing is cached" shape — because a jar would be a
    second, invisible source of sessions (the login `WKWebView`'s copies migrate
    into a shared `HTTPCookieStorage` readily) and a stale one can outlive a
    sign-out and keep an account signed in after the Keychain item is gone.
    **The URL cache is off too**, and not merely for tidiness: the catalog's
    once-a-day rule and the statement cache both live on disk in Core, and a URL
    cache answering a forced refresh with the bytes it already had would silently
    shadow the one mechanism that repairs a stale catalog.
    **Redirects are followed, as a browser would**: LeetCode answers some
    signed-out states with a 302 to the login page rather than a JSON error, the
    resulting HTML-where-JSON-was-expected already has an answer (`apiChanged`),
    and the authoritative verdict is `userStatus.isSignedIn` — suppressing
    redirects would trade one confusing case for a different one. **The session
    does not follow them off LeetCode**, though, and that is the other half a
    browser does for free: the pair travels as a *manually set* `Cookie` header,
    and `URLSession` re-sends those verbatim to whatever host a `Location` names,
    so a 30x off `leetcode.com` would hand a third party a live,
    browser-equivalent session — the cookie jar switched off above is exactly the
    mechanism that would otherwise have scoped it. The transport's `RedirectGuard`
    (a per-task `URLSessionTaskDelegate`, so the session holds no delegate for the
    app's lifetime) lets the redirect proceed and strips
    `LeetCodeAPI.credentialHeaderNames` from it unless
    `LeetCodeAPI.redirectMayCarryCredentials(from:to:)` allows the hop. The rule
    lives in Core — the file that decides those headers *are* the session is the
    file that decides where they may go, and it is the half a test can see — and it
    is derived from the request rather than from `siteURL`: same host or a host
    within it (`leetcode.com` → `www.leetcode.com`), same scheme. **The
    containment runs one way only**, which is the part worth writing down: the
    mirror clause — "the original is *within* the new host" — reads as the same
    relaxation and is not, because it walks *up* the name, so `leetcode.com` →
    `com` satisfies it and the pair goes to whoever answers for the public suffix.
    Nothing in this app redirects that way (`task.originalRequest` is always
    `leetcode.com`, so `com` was the only host it ever admitted), but this
    predicate is the one place the same-origin rule is written and a rule that is
    right only because of its call site is not one. It is
    deliberately **not** `LeetCodeProblemInput`'s "is this a LeetCode URL" rule,
    which also accepts `leetcode.cn`: that is a different operator, and a `.com`
    session has no business being sent there. Stripping rather than refusing keeps
    the login-page 302 reading as it did — an off-site hop simply answers as a
    signed-out request would.
    `waitsForConnectivity` stays **off** (offline must fail now and surface
    `network`, not sit silently until the resource timeout, with the user watching
    a spinner); timeouts are 30 s per request / 60 s per resource, sized by the
    2 MB catalog; `httpMaximumConnectionsPerHost = 2` bounds nothing in practice and
    is there so a burst can never look like a scraper. Response header names are
    passed through in whatever case they arrived (see `headerValue(forName:)`).
    `@unchecked Sendable` over immutable `let`s, the `LSPProcessTransport`
    arrangement.
  - `Platform/LeetCodeKeychainStore.swift` — `kSecClassGenericPassword` under a
    fixed service, the **pair as one JSON item** under a constant account, with
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Two items would create a
    half-existing state every reader would need a rule for — the two cookies are
    only ever useful together — and the account is constant because the item *is*
    the session: the user name is something the session tells us, not something
    needed to find it. `ThisDeviceOnly` matches the git PAT store (a
    browser-equivalent credential must not ride along in an encrypted backup or
    migrate on restore); `AfterFirstUnlock` keeps it readable from a background
    refresh. `save` is delete-then-add, so the ordinary path is one idempotent
    branch rather than an add/update fork whose halves can disagree about
    accessibility — but a **duplicate is overwritten, not reported**: the delete is
    `try?`, so a Keychain that refuses it made the add return
    `errSecDuplicateItem` and left the *previous* account's item in place. The
    model prices a failed save at "one sign-in next launch"
    (`lastCredentialSaveFailed`), which is true only if nothing is stored; with the
    old item surviving, the next launch reads a different account's session back
    out and reports it as signed in. So a duplicate falls through to `SecItemUpdate`
    with the same accessibility set alongside the data (the two halves still cannot
    disagree), and only a failure of *that* is thrown.
    `load()` treats undecodable as **absent** — same recovery, one sign-in — and the
    failure type is a local `LocalizedError`, deliberately *not* a `LeetCodeError`:
    the model already knows a save failure costs one sign-in next launch, and
    `fileSystem` would attribute a Keychain refusal to the disk. The existing
    iOS-only `KeychainCredentialStore` (git PATs) is left alone: different secret,
    different service, different key shape.
  - `Platform/LeetCodeSupportDirectory.swift` — the one place that answers "where
    is the cache base on this platform": `…/Application Support/Pisaka/LeetCode`,
    which resolves to `~/Library/…` on the unsandboxed Mac and to the container's
    own on iOS. **Application Support rather than Caches** even though this cache
    is reconstructible: a purge would turn a working airplane-mode reopen into a
    blank pane and put a 2 MB fetch in front of the next open. **It creates
    nothing** — it answers a location, and `LeetCodeCatalog`/`LeetCodeStatementCache`
    each `ensureDirectory` before their first write, which is what makes the iOS
    case work at all (a fresh container has no `Application Support` until
    something makes one). `LeetCodeCacheLayout.directoryName` is the only component
    it does not spell itself, so "delete that directory to forget everything" has
    one spelling.
  - `Platform/LeetCodeWebSession.swift` — the web-view side of the session: the
    login URL, the shared `WKWebsiteDataStore`, the cookie read, the scoped purge,
    `signOut(model:)`, and `LeetCodeLoginObserver`, the `WKNavigationDelegate` both
    platforms' login views return from `makeCoordinator()` (and which also builds
    the web view). In the non-gated `Platform/` layer for `LicenseTextView`'s
    reason: the *policy* is identical on both platforms and only the chrome
    differs, so the part that could actually be wrong — when to look, what to look
    at, how many times to fire — exists once.
    **Why a real web view at all**: LeetCode has no API key and no OAuth flow, a
    session is two cookies a browser obtains, and a great many accounts are
    Google/GitHub SSO, which a scripted username/password login could not drive even
    in principle. The app never sees a password and holds no knowledge of LeetCode's
    login markup.
    **The store is `.default()` (persistent) on purpose**, which is what "SSO
    redirects survive" actually needs — providers keep their "you are signed in
    here" state in cookies of their own, and an ephemeral store would drop them
    between the redirects that need them. The cost, cookies outliving the sheet, is
    exactly what the scoped purge answers.
    **The domain filter lives here, not in Core** (Core's rule takes `(name, value)`
    pairs and cannot see a domain); it matches the bare host or a `.leetcode.com`
    suffix, so both cookie-domain spellings are accepted and a lookalike registrable
    domain is not. **Cookies are purged by host**, not `removeData(ofTypes:)`: the
    default store is process-wide, and signing out of LeetCode is not a reason to
    sign the user out of every other site — and they are purged **before**
    `model.signOut()`, which publishes synchronously, since the other order leaves a
    window in which the UI says "signed out" and the cookies are still live.
    **The same purge runs in `makeWebView()`, before the login page loads**, so what
    the observer sees is a session obtained *here* rather than whatever the shared
    persistent store was holding. Without it the very first `didCommit` — the login
    page's own — captures a stale `LEETCODE_SESSION` from an expired session, and
    that is a lock-out rather than an inconvenience: `signIn` rejects it, the sheet
    has already dismissed, `isSignedIn` stays `false`, and Sign Out (the only thing
    that clears those cookies) renders only when `isSignedIn`, so every later
    attempt captures the same dead cookie forever. It is also what makes "sign in as
    a different account" possible at all. Only `leetcode.com` is purged, so the SSO
    providers' own cookies — the whole reason the store is persistent — survive.
    **Checked at `didCommit` *and* `didFinish`, fired at most once**: `didCommit` is
    when the response's `Set-Cookie` headers have landed, `didFinish` catches a
    cookie set from script after load, and `hasCaptured` — checked *and set* in one
    synchronous step **after** the store read's suspension, since two navigations
    can be in flight and a check made before the read lets both through it — makes
    the pair idempotent, because firing twice would race two `signIn`s, each a
    network call and a Keychain write. `WKHTTPCookieStore`'s two callback APIs are awaited through
    explicit continuations rather than the compiler-generated `async` overloads,
    whose names come from a renaming rule that is invisible at the call site and has
    changed spelling across SDKs.
  - `LeetCodeLoginView.swift` (macOS) / `iOS/LeetCodeLoginView_iOS.swift` — the
    sign-in surfaces: a sheet on macOS, a **full-screen cover** on iOS (a login
    page, especially an SSO provider's mid-redirect, is a full web page with its own
    scrolling and keyboard, and a half-height sheet on a phone leaves almost nothing
    visible once the keyboard is up). Both are four lines of representable around
    `LeetCodeLoginObserver` plus chrome. **Dismiss first, confirm behind it**: the
    moment the cookies appear the surface goes away and the confirmation round trip
    runs on the model, where the result belongs (`signedInUsername`, or
    `lastError`) — holding a modal web view open over a spinner would make an
    offline moment look like a failed login when the session in hand is fine. The
    confirmation runs in a bare `Task`, **not** `.task`, because the view is
    disappearing in the same turn and a `.task` is cancelled on disappear, which
    would cancel the very round trip it was started for. `updateNSView`/`updateUIView`
    re-point the callback and **never reload**: a body re-evaluation (the model
    publishing anything at all) must not restart a login the user is halfway
    through.
    Dismissing first has a consequence the macOS view carries an `onFailure`
    parameter for: the surface is already gone when the confirmation lands, so a
    session LeetCode *rejects* has nothing on screen to appear on unless the
    presenter says where. It is required rather than optional on purpose — each of
    the three macOS presenters names the surface it will use (`PisakaApp` a
    `PlatformAlert`, the Open Problem sheet its own status line, Preferences
    nothing, since that pane renders `lastError` itself) — because the default
    otherwise is silence: `lastError` has exactly one macOS reader, and without
    this a rejected login flipped the menu back to "Sign In…" and said nothing
    anywhere the user was looking. Only `notLoggedIn` is reported; the rest are the
    "offline moment" the paragraph above keeps the cookies for. iOS needs no such
    parameter — both of its presenters render `lastError` inline, immediately under
    the account row.
  - `LeetCodeOpenProblemSheet.swift` (macOS) — three things in one file, because
    they are one decision seen from three places: the Open Problem sheet, the
    `LeetCodeCommands` menu items, and `LeetCodeFolderChooser`.
    The **sheet** is a live-validated text field (parsed on every keystroke, so the
    Open button's enablement and the hint line always describe the current text),
    a picker bound *straight to* `settings.leetCodeLanguage` so choosing a language
    *is* persisting it, progress, and one status line. **While the sheet is up,
    failures are a sentence in it, not a `PlatformAlert`** — the split is by who is
    on screen, and a modal alert over a modal sheet to say "no problem with that
    number" would make a typo look like a crash. Submitting is guarded on
    **`isOpening`** as well as on the parse, because Enter reaches the action even
    while the button is disabled — `isOpening` rather than `isBusy` so a statement
    refresh running for some other tab cannot disable the field or swallow the
    user's Return (the counter's own note in this document). A signed-out user gets
    a **row with a "Sign In…" action in the sheet itself**, which presents the login
    web view **over this sheet** rather than in place of it: LeetCode answers no
    problem detail without a session, and making the user cancel, walk to the menu
    bar and come back is a detour the iOS screen — which puts the account and the
    input on one screen — does not have. Nested rather than swapped into the
    presenter's shared slot, for the reason the swap failed: the two sheets share
    one `.sheet(item:)`, so raising the login one took *this* one down, the typed
    problem went with it, and nothing brought either back — a user who took the
    "one click instead of a trip to the menu bar" the row offers ended the login
    with no sheet and an empty field. This is the shape both `LeetCodeSettingsView`
    and the iOS screen already had.
    The open runs in a **held `Task`, cancelled on disappear**. An unheld one
    outlives the sheet that started it, and both consequences were user-visible:
    `isOpening` stayed up for the life of the abandoned request, so the *next*
    sheet opened with its field, its picker and its Open button all disabled; and
    when the request finally landed it opened a tab for a problem the user had
    pressed Esc on. Cancelling covers the first (the request throws, and
    `openProblem`'s `defer` clears the flag); the presenters cover the second with
    a `Task.isCancelled` check before the tab, since straight-line work past the
    last `await` is not stopped by a cancellation. The file itself may already
    exist, and is deliberately left: it is a file in a folder the user set aside,
    and the never-overwrite rule means reopening the problem returns to it. The iOS
    screen carries the same pair, for the same two consequences.
    `LeetCodeCommands` is a `View` **with its own `@ObservedObject`** inside
    `CommandMenu`, so the Sign In/Sign Out label tracks `isSignedIn` without making
    the scene's `body` — and with it `ContentView`, the project tree, the tab list
    and `CodeEditorView.updateNSView` — a subscriber to every statement fetch: the
    `commitDialog`/`symbolIndex` rule applied to a surface that genuinely does need
    to observe. Nothing in the menu is gated on a project being open — including
    **"Browse Problems…" (⌘⇧B)**, which sits beside "Open Problem…" above the
    divider because the two are the same action reached two ways: type a problem
    you know, or find one you do not. The shortcut was free in this app's audit.

    `LeetCodeFolderChooser` is **a plain persisted path with no security-scoped
    bookmark**, because this app ships no `.entitlements` and `project.yml` enables
    no App Sandbox — the macOS build is unsandboxed and reaches any path the user
    names, exactly as "Open Folder…" already does. It is shared by all three entry
    points (the menu item, first use from the sheet, and Preferences → Change…) and
    writes **both** halves — `SettingsStore` for the next launch and
    `model.solutionsFolder` for this one — so no open can land somewhere Preferences
    is not showing. `~/Documents/LeetCode` is created *before* the panel opens,
    because a panel pre-targeted at a directory that does not exist opens somewhere
    arbitrary. Cancelling is an answer, not a failure: nothing is fetched and
    nothing is alerted.
  - `LeetCodeDescriptionView.swift` (macOS) — the right-hand pane, plus its web
    view. **It observes the model; the window does not**: `ContentView` holds
    `leetCode` as a plain `var` beside `provisioning`/`symbolIndex`, so the
    `@ObservedObject` lives in the one view that shows the state and the pane
    appears and disappears while the rest of the window stays still — which is also
    why the *pane* renders nothing when there is no statement rather than the window
    omitting it (the window cannot see the difference).
    **A sibling in an `HStack`, not a third `HSplitView` column**: a split child that
    appears and disappears re-creates the split and resets every column's width, and
    a conditional *wrapping* the editor would change the editor's structural
    identity — tearing down the `NSTextView`, its undo stack and its scroll position
    every time a LeetCode tab is selected. An `HStack` whose trailing child is
    sometimes an `EmptyView` costs the editor nothing, and the width is then the
    pane's own `@State` behind a `resizeLeftRight` drag handle: the `panelHeight`
    shape turned ninety degrees. Collapsing leaves a strip that is the only way
    back, so the pane can never be folded away and lost.
    The handle's cursor push is paired with an **`onDisappear`**, unlike
    `ContentView.panelDivider`'s otherwise identical `onHover` idiom, and the
    difference is why: that divider goes away only when the user toggles it, while
    this whole pane is removed the moment the statement is — a tab switch under the
    pointer delivers no `onHover(false)`, so the pushed `NSCursor` would never be
    popped and the resize cursor would stick application-wide.
    The web view **reloads only when the composed HTML differs**: `ContentView.body`
    re-evaluates on every keystroke, so an unconditional `loadHTMLString` would
    reload the statement and reset its scroll position once per character typed —
    and comparing the document is simultaneously the right trigger for the reloads
    that *should* happen (a new statement, a theme switch, a font-size step), so
    "re-render on theme/font-size change" and "do not reload while reading" are one
    rule. Scripting is **off** (what keeps Core's "verbatim" from meaning
    "executable"), the data store is `.nonPersistent()` (this view must not become a
    second place a leetcode.com cookie can live, beside the login view's
    deliberately persistent one), and **the main frame only ever holds the document
    this view loaded** — every other main-frame navigation is cancelled, because a
    related-problem or editorial link would otherwise
    replace the statement inside a 380 pt pane with no way back (the pane has no
    back gesture, and the reload gate above will not restore a document whose HTML
    has not changed). The test for *cancelling* is the **frame**, not
    `linkActivated`: a click is only the navigation the user can see coming, and
    this markup is interpolated verbatim, so a `<meta http-equiv="refresh">` or a
    `<form>` in it navigates the pane just as effectively — neither needs the
    scripting that is off. But the test for **handing it to the OS is
    `linkActivated`**, and the two are deliberately not the same test: catching a
    refresh tag and then opening it is the same navigation performed in the user's
    browser instead of the pane, so a statement carrying one used to launch Safari
    at an arbitrary URL the moment the pane rendered — no click, no confirmation,
    and again on every theme or font-size change that reloads the document.
    Everything that is not a click is cancelled and goes nowhere at all. Sub-frame loads are left alone (LeetCode's own markup
    embedding something), and subresource loads never reach the delegate at all.
    **The document is recognised by this view having just asked for it**, not by
    its URL: `isPerformingOwnLoad` is raised immediately before `loadHTMLString`
    and consumed by the first main-frame navigation after it (on the main frame
    alone, so a sub-frame cannot take it, and cleared again in `didCommit` so the
    flag can never outlive one document). Matching `LeetCodeAPI.siteURL` instead
    was unsound in exactly the way this whole rule exists to prevent:
    `https://leetcode.com/` is no private sentinel but an ordinary destination the
    verbatim fragment can reach with a bare `href="/"` — resolved against the
    document's own `<base href>` — or with a `<meta http-equiv="refresh">` to `/`,
    and such a navigation matched the test exactly and was allowed into the main
    frame, stranding the pane on the live site with no way back. `about:blank`
    stays exempt separately: it is the empty page a web view starts on, not a
    destination, and there is nothing there to hand the OS. **Only `http`/`https` are
    handed over**, everything else is cancelled and nothing else happens: this
    markup is rendered verbatim and never sanitized, so the `href` behind a click is
    untrusted by construction, and `NSWorkspace.open` would launch a `file:` URL in
    its default handler or give any other scheme to whichever app claims it —
    scripting being off does not cover this, since it is the delegate and not the
    page that performs the open. The iOS pane's `UIApplication.open` carries the
    same gate for the same reason. `loadHTMLString`'s base URL
    matches the document's own `<base href>`, or LeetCode's relative `<img src>`s
    would resolve against `about:blank`.
  - `LeetCodeJudgeView.swift` (macOS) — `LeetCodeJudgeSection`, hosted by
    `LeetCodeDescriptionPane` below the statement web view and inside the same
    pane, because Run and Submit are about the problem the user is reading.
    **It observes `model.judge`, not `model`** — the whole reason the judge is a
    companion object: this view binds a `TextEditor` to `judge.testInput` and so
    re-renders on every keystroke in the box, and observing the owner would put the
    account state, the statement and the web view above it on that path.
    **The editor arrives deliberately non-observed**, a plain `WorkspaceModel?`
    handed down from `ContentView` — the `commitDialog`/`symbolIndex` rule arriving
    two levels deeper, and for the sharper version of its reason: an
    `@ObservedObject` would re-render this section on every keystroke *in the file
    being solved*, which is the text the user types the most. Nothing here reads a
    buffer at render time; the judge reads one synchronously when a button is
    pressed, which is also what makes "what you see is what is judged" true without
    a save. The **selection travels separately** (`activeFileURL`) precisely because
    the workspace is not observed: that value is what re-runs `prepare`, so it has
    to come from a view that *is* watching it. The `.task(id:)` key is the
    statement's own two halves — the tab and the folder — since re-pointing the
    folder has to re-ask the question for the tab already open.
    The view makes **no decision of its own**: availability, the phase, every
    verdict and every sentence come from Core. What is left is layout plus one
    piece of presentation state, `shownKind`, which only says which of the two
    finished results is on screen — set when a button is pressed rather than
    derived, because "the one the user just asked for" is a fact about this surface
    and not about the judge (`lastRun` and `lastSubmit` are separate published
    values on purpose: they are different shapes, and a submit must not erase what
    a run just showed). The run header's colour comes from `matchedExpected`, not
    from the verdict, for the reason `LeetCodeVerdict.isAccepted` documents. The
    compile/runtime diagnostic is rendered **in full** — monospaced, selectable,
    wrapped rather than clipped, scrolling with the rest inside a capped result
    area so a Wrong Answer with four long fields cannot push the statement off the
    top. The disabled buttons carry `availability.reason` as their help text and as
    a badge beside them, which stands down while a run is in flight because the
    spinner already says the same thing.
    The two buttons' `Task`s are **held in `judgeTask` and cancelled on
    disappear**, alongside `judge.cancel()` — the `LeetCodeOpenProblemSheet` rule
    on this axis. A `Task { }` started from a button inherits no cancellation from
    the enclosing `.task`, so without holding it a poll outlived the section it was
    going to answer and ran its whole budget out against a surface showing
    something else; the two halves do different jobs, since cancelling the task is
    what makes `URLSession` stop and `cancel()` is what moves the generation so a
    request already past its last suspension publishes nothing. Neither undoes a
    submission LeetCode already has.
    The echoed input is drawn **once and whole**, above the cases rather than
    inside them, and the case rows are `result.caseCount` — both decisions live on
    `LeetCodeRunResult` rather than here, since they are statements about
    LeetCode's arrays and this file is meant to hold none.
  - `LeetCodeBrowserWindowController.swift` (macOS) — owns the single, non-modal
    problem browser window (⌘⇧B). `ProjectSearchWindowController` verbatim in
    shape — a retained `EscClosableWindow` hosting a SwiftUI root through an
    `NSHostingController`, released on close by a per-window delegate held
    alongside it (`NSWindow.delegate` is `weak`), with `closeAll()` wired into the
    app's `willTerminateNotification` observer beside the diff/merge/search/
    source-viewer controllers — and for exactly its reason: there is **one**
    `LeetCodeBrowserModel` behind this window, carrying one filter and one row
    list, so two windows over it would fight over that filter the way two Find in
    Files windows would fight over one query. A repeat ⌘⇧B therefore focuses the
    window that exists, and an existing window has its root view *replaced* rather
    than reused, so it picks up the app's current closures. `windowNumber` is
    exposed for one caller: raising the editor window *behind* this one is an
    `order(.below, relativeTo:)` and needs it.
  - `LeetCodeBrowserView.swift` (macOS) — the window's contents: the search field,
    the language picker and the two rows of filter toggles at the top, the `Table`
    below, the count/error/fetch-time/Refresh footer at the bottom.
    **It observes `LeetCodeBrowserModel`, not `LeetCodeModel`** — which is the
    whole reason the browser is a companion model: a text field bound to
    `browser.filter.query` re-renders this view on every keystroke, and observing
    the owner would put the account state, the statement and the judge on that
    path. The owner arrives as a **non-observed plain `let`**, held only to hand to
    the nested `LeetCodeLoginView`; whether this window shows a list or a sign-in
    offer comes from `browser.availability`, which the owner's `isSignedIn`
    observer keeps current, so nothing here watches the model to stay right.
    The load is a `.task(id: browser.availability)`, which covers both halves with
    one rule: the load on appear, and the re-arm after a sign-in that flips
    availability. Inside the staleness window that load costs no request, which is
    what makes re-entering the window free.
    The language `Picker` is bound to `settings.leetCodeLanguage` — the *same*
    persisted setting the Open Problem sheet writes, so the two surfaces cannot
    disagree about the language the next solution file is seeded in. The filter
    toggles need no "All" case, because an empty set and a full one are the same
    list (`LeetCodeProblemFilter`). Premium rows carry a lock marker and are never
    filtered out. `Row` is a view-layer wrapper for its `Identifiable` conformance
    alone (`Table` requires one; `LeetCodeProblem` gains none it does not otherwise
    need). The footer's `countLine` renders the two empty states as two different
    sentences — a filter that matches nothing is not a list with nothing in it —
    and shows `lastError` **beside** the rows rather than instead of them.
    **The selection is pruned, because SwiftUI keeps one whose row is gone.**
    `selection` is a slug, and both narrowing the filter and a landed refresh can
    take that row out of the table; left alone, Open stayed enabled and opened a
    problem the user could not see and did not mean — which on this route creates a
    file. Two `onChange` hooks (`browser.filter`, `browser.fetchedAt`) clear it,
    keyed on the two things that can change the visible set rather than on
    `visibleProblems` itself, whose equality check is four thousand rows on every
    body evaluation.
    Opening hands `.slug(_:)` — the row already carries the slug every detail
    request is made by, so no resolution step is spent — to the app's one open
    handler, so the folder rules, the Premium refusal and the never-overwrite
    guarantee are LC-1's. A refusal is a sentence in the window rather than an
    alert, the sheet's rule for the sheet's reason. The window **stays open** (the
    point is browsing several problems), so the app raises the editor window behind
    it. `openTask` is held and cancelled on disappear, `LeetCodeOpenProblemSheet`'s
    rule on this surface, and the sign-in sheet is presented from *here* rather
    than through the app's shared slot, for that file's reason: the shared slot
    would raise it on the editor window, where the user who pressed the button is
    not looking.
  - `PisakaApp.swift` / `ContentView.swift` / `SettingsView.swift` (macOS, modified;
    entries in `app-shell.md` and `app-window.md`) — the orchestration.
    `makeLeetCode(settings:)` composes the stack once (transport, Keychain store,
    `FileService`, the cache layout, and the folder read out of `SettingsStore`
    *before* the model is built, so `isSignedIn` and the folder are right from the
    first frame); the model is a **non-observed `let`**, and the two sheets are one
    `.sheet(item:)` over an enum attached **outside** `ContentView` — they are
    mutually exclusive by nature (the sign-in sheet exists because an open needs a
    session), and attaching them in the scene keeps `ContentView` free of both the
    parameter and the observation. `openLeetCodeProblem` returns the sentence to the
    sheet and keeps `PlatformAlert` for the one failure that happens with the sheet
    already gone — the tab open itself. **Opening a problem never changes the
    project root**: the file is opened via `WorkspaceModel.open(url:)` like any
    other, and the tree revision is bumped only when the file actually landed inside
    the open project. **That failure also re-asks the statement question**, and is
    the app-side half of the model's ordering rule: `openProblem` published the
    statement it had in hand once the file existed, but the panel is global rather
    than keyed to a tab, and a tab that failed to open left the selection unchanged
    — so the `.task(id:)` below would not re-run and the new statement would sit
    beside an unrelated tab (or none) with nothing to clear it. The catch path
    therefore calls `statement(forFileAt: model.selectedFile?.url, in:)` before it
    alerts, which clears the panel for a non-solution tab and restores an already
    open LeetCode tab's own statement rather than merely blanking it — served from
    the cache under `slugsFetchedThisRun`, so it costs no request.
    Sign Out always goes through `LeetCodeWebSession.signOut`.
    `openLeetCodeBrowser()` shows (or focuses) the browser window over
    `leetCode.browser` — the *one* catalog the rest of this area already reads
    (L23) — and hands it `openLeetCodeProblem(input:language:)` itself as the open
    handler, so a row and a typed number reach LC-1's flow through the same
    function: **there is no second open path.** The only thing this route adds is
    `raiseEditorWindowBehindBrowser()`, and the rule it needs is written down where
    it is used: this app has exactly one `WindowGroup` window and every auxiliary
    window it makes is an `EscClosableWindow` (diff, merge, Find in Files, the
    source viewers, the browser itself), so **the frontmost visible, main-capable
    window that is neither one of ours nor Preferences** is the editor — a no-op
    when there is none, since that window can be closed while the app runs. Both
    qualifiers are load-bearing, because this is identification by exclusion and
    exclusion rots quietly: `NSApp.windows` is in *unspecified* order (so the scan
    is over `orderedWindows`, which is documented front-to-back), and the `Settings`
    window is made by SwiftUI rather than by this app — no `EscClosableWindow`, and
    main-capable — so without naming it the plain rule sends *Preferences* behind
    the browser and leaves the editor where it was. It is excluded by the
    identifier SwiftUI gives that scene, and a future SwiftUI that stops setting it
    costs this one cosmetic re-order, nothing else.
    The launch-time `refreshUserStatus()` joins the existing one-shot `.onAppear`
    block beside `sweepStaging()`/`lspProvisioning.refresh()`, unawaited and silent.
    `ContentView` drives the statement from a `.task(id:)` keyed on **(selected tab,
    LeetCode folder)** — both halves, because the association needs both, and the
    folder is read from `settings` (which the view observes) rather than from
    `model.solutionsFolder`; the fetch is driven from the window root rather than
    from the pane because the pane does not exist until the statement does.
    Preferences gains a LeetCode tab (account, folder, default language), which
    observes the model itself for the menu's reason.
  - `iOS/LeetCodeRoute_iOS.swift` — the iOS folder rules (`LeetCodeFolder_iOS`) and
    the one screen that replaces the macOS menu + dialog pair (iOS has no menu bar
    to hang account state off, so the account section is the first section of the
    same sheet the input field is in — which is also the only place a signed-out
    user would look for the way in). Its entry point is an item in the existing "+"
    toolbar menu rather than a fifth toolbar button.
    **The folder asymmetry with macOS is the point**: the Mac build is unsandboxed
    and persists a plain path, while iOS reaches anything outside its container only
    through a security-scoped URL the picker vended — so this platform keeps *two*
    answers, which is why `SettingsStore` carries both a path and a bookmark. The
    **default needs no bookmark at all** — `<container>/Documents/LeetCode` is
    ordinary unscoped storage, so the common case never involves the picker, never
    involves a bookmark and cannot break when one goes stale — while an **override
    is a `SecurityScopedBookmarks` blob**, registered with the same
    `SecurityScopedFileService` the project root uses, so the solution write and
    every later read run under its grant. A bookmark that no longer resolves is
    **forgotten and the default takes over**, rather than the integration reporting
    `folderUnavailable` forever: silently continuing to work in the container beats
    a feature that has quietly stopped. `leetCodeFolderBookmark` is therefore the
    *authority* on an override and `leetCodeFolderPath` the *display* of whichever
    folder won, which is why both are written on both paths.
    The one case that authority cannot answer is a pick whose bookmark could not be
    *made*: the picker's grant is live and registered right now, but there is
    nothing to reach the folder with next launch. `adopt` keeps that pick in a
    non-persisted `sessionOverride` that `resolve` consults behind the bookmark and
    `isOverridden` counts as an override — which is what makes the documented
    degradation ("in force for the session, back to the default next launch") true.
    Without it the override survived only until the next `publish`, which
    `established(…)` runs on *every* open, so the very next problem was written into
    the container while Settings still showed the picked folder and offered no way
    back. It is deliberately not persisted: a path with no bookmark is unreachable
    after this process ends, and restoring it next launch would present a folder the
    app cannot write to as the one in force.
    **Nothing is created at launch**: `publish` resolves and points both halves (the
    model's `solutionsFolder`, captured synchronously by `openProblem`, and the
    settings path, which the statement `.task` keys on) without touching the disk;
    the `ensureDirectory` waits for `established(…)`, so a user who never opens a
    problem never finds a directory this app made for them. Unlike macOS there is no
    cancellable panel in that path — the default always exists to fall back to, so
    an iOS open never has to ask a question before it can start.
    `browseSection` is the one new entry point on this platform and the peer of the
    macOS menu item: a `NavigationLink` in a section of its own rather than a
    second sheet, because this screen already hosts the `NavigationStack` — the
    browser pushes onto it and the back button returns here, where a sheet over a
    sheet would have to re-present the sign-in cover from a third level.
    `onOpen` is forwarded unchanged, so a row tapped there runs exactly the open a
    slug typed here does; **`onDone` deliberately is not** — see the browser
    screen's entry for why a surface that cannot tell "it opened" from "it was
    withdrawn" must not be handed the sheet's dismissal.
  - `iOS/LeetCodeBrowserView_iOS.swift` — the pushed browser screen: the peer of
    the macOS window over the **same** Core model, so the two platforms cannot
    disagree about what a query matches, when a fetch happens or what opening a row
    does — only about the idioms carrying it. Here those are `.searchable` bound to
    `browser.filter.query`, a toolbar `Menu` of difficulty and status toggles,
    `.refreshable` mapped to `browser.refresh()`, a `.task(id: browser.availability)`
    load (the macOS window's key, covering the load on appear and the re-arm after
    a sign-in with one rule),
    and a `List` of rows keyed `id: \.slug` (so `LeetCodeProblem` needs no
    `Identifiable` conformance it does not otherwise want) carrying the number, the
    title, the Premium lock and the status mark, with a footer row showing
    "showing X of Y" and the fetch time.
    **`lastError` leads the list; it is deliberately not in that footer.** The
    footer sits after four thousand rows, so an error placed there is unreachable —
    a pull-to-refresh that failed with the catalog on screen left the screen
    looking untouched, which is exactly the silent failure the "keep the rows,
    publish the error beside them" rule exists to avoid. It shares the leading
    section with the open attempt's sentence; the count and the fetch time stay
    below, because they are a fact about the list rather than something the user
    has to be told.
    It observes the **browser** and takes the owner as a non-observed plain `let`
    for the macOS view's reasons, and it offers **no language picker of its own**:
    the screen that pushed it has one and the setting is persisted, so there is no
    second place to change it that could disagree.
    **No cap and no truncation.** `List` is lazy, the rows are plain text, and
    filtering the whole catalog is one pure pass; the unfiltered ~4000 rows are
    shown as they are. If a device ever says otherwise the answer is a stated "keep
    typing to narrow" affordance, never a silent cut — a list that quietly stops at
    row 500 tells the user problem 3000 does not exist.
    A tap runs the route's `onOpen(.slug(_:), settings.leetCodeLanguage)` and shows
    whatever sentence comes back, inline; **it dismisses nothing itself**, which is
    `LeetCodeRoute_iOS.open()`'s rule and the one thing this screen must not get
    wrong. `nil` answers three different questions — it opened, the user left
    mid-open (`onDisappear` cancels `openTask`), or a newer open superseded this
    one — and only the first wants the sheet down; the handler already takes it
    down on that one, so calling `onDone` on `nil` here would close the whole
    LeetCode screen out from under somebody who had just tapped Back. The tab is
    open behind the dismissed sheet either way (on compact width, pushed).
    `openTask` is held and cancelled on disappear —
    `LeetCodeRoute_iOS`'s rule, for its reason. Signed out, the screen shows
    `availability`'s sentence and the same sign-in offer the account row makes,
    with the login cover presented from here.
  - `iOS/LeetCodeDescriptionView_iOS.swift` — the statement in the two shapes iOS
    needs, **adaptive the way `MergeRoute_iOS` is**: a pane beside the editor on
    regular width, a sheet raised by a toolbar button on compact, with
    `LeetCodeDescriptionContent_iOS` (header + web view) shared so the only
    difference is the container. The `HStack` is unconditional and the *pane*
    renders itself away — never a conditional wrapping the editor — which is what
    protects the `UITextView`'s undo stack and scroll position from being torn down
    every time a LeetCode tab is selected (`editorArea` was split into itself plus
    `tabbedEditor` for that reason alone). The pane, the compact toggle and the
    screen each carry their own `@ObservedObject` and render nothing when
    `statement` is nil, so `RootView_iOS` holds the model as a plain `let` and the
    macOS rule stays true on both platforms rather than true on one and merely cheap
    on the other. The compact sheet is attached **at the root**, not on the pushed
    editor screen, so a tab switch behind it cannot tear it down mid-read, and it
    shows a placeholder rather than emptying itself when the statement goes away,
    because a sheet that blanks reads as a bug. The web view has the same rules as
    the macOS one (compare-then-load, scripting off, and the main frame pinned to
    the loaded document — a tapped `http`/`https` link out to Safari, everything
    else cancelled, including the un-tapped navigations the frame test catches).
  - `iOS/LeetCodeJudgeView_iOS.swift` — `LeetCodeJudgeSection_iOS`, the peer of the
    macOS section, **written once into `LeetCodeDescriptionContent_iOS`**: that
    view is already what the regular-width pane and the compact-width sheet share,
    so the adaptive pattern LC-1 established carries the judge for free and there
    is no second copy to drift. It observes the judge and not its owner, and takes
    the workspace and the active file non-observed from `RootView_iOS`, both for
    the macOS section's stated reasons.
    What this file has that macOS does not is **keyboard discipline**, and it is
    three rules. The controls sit *above* the input, so the box grows towards the
    bottom of the screen and the buttons never follow it under the keyboard. The
    box carries its own Done affordance (an inline button plus a keyboard
    accessory), so a focused editor is never a trap. And the result area stands
    down while the box is focused, so on a compact width the keyboard, the box and
    both buttons fit at once. In the shared content the web view is the flexible
    child and the judge section the intrinsically-sized one, which is what makes
    the statement — not the controls — give up height when the keyboard shrinks the
    safe area.
  - `iOS/PisakaApp_iOS.swift` / `RootView_iOS.swift` / `SettingsView_iOS.swift`
    (modified; entries in `app-ios.md`) — the iOS composition and wiring.
    `PisakaApp_iOS` composes the stack inline rather than through a factory
    (`ContentView`'s need for a default value has no iOS counterpart) but from the
    *same* three cross-platform seams, with one platform difference: the file
    service is the **scoped** one, since a picked folder is only writable inside its
    grant and the container cache simply finds no covering scope and falls through.
    `SettingsStore` moved into `init` for the macOS app's reason, so the folder can
    be read before the model is built. `RootView_iOS` publishes the folder and calls
    `refreshUserStatus()` once at launch, keys the same `(tab, folder)` statement
    `.task`, and routes the open exactly as macOS does (sentence to the screen,
    alert only for the tab open — with the same re-ask of the statement question
    in that catch path, for the same reason — and no tab at all once the screen's held open
    `Task` has been cancelled — `LeetCodeRoute_iOS` cancels it on disappear for the
    two reasons the macOS sheet's entry gives: a Done that left `isOpening` up, and
    an editor pushed for a problem the user had walked away from). The Settings screen gains a LeetCode section
    (account, folder with Change…/Use Default, default language) and observes the
    model itself.
    **`lastError` is rendered wherever an account can be signed into** — the macOS
    LeetCode Preferences tab, the iOS Settings section, and the iOS
    `LeetCodeRoute_iOS` account section, each under its account row. Everything
    else that reports a LeetCode failure is transient (the entry sheet's own
    sentence, which goes away with the sheet), and sign-in is confirmed *after*
    the login view has been dismissed: without a durable surface a session LeetCode
    rejected closed the web view and silently flipped the row back to "Sign In…"
    with no explanation. The iOS route needs its own copy because it, not Settings,
    is where an iOS user signs in. A successful statement refresh clears it, so the
    sentence never outlives the state it describes.
    Every button in those `Form` rows carries **`.buttonStyle(.borderless)`**, the
    rule the pre-existing git-credentials rows already follow: a `List`/`Form` row
    whose buttons take the default style is a *single* tap target and a tap
    anywhere in it fires all of them — so without it tapping the "Signed in as …"
    label signed the user out, and tapping "Change…" also ran "Use Default",
    dropping the bookmark for the folder the tap was meant to change.

## Tests

`swift test` covers the whole Core half:

  - `LeetCodeCredentialsTests` / `LeetCodeErrorTests` / `LeetCodeTransportTests` —
    the cookie rule (both present, one missing, empty value, duplicates, extra
    cookies ignored), every error sentence non-empty and distinct, the
    case-insensitive header lookup.
  - `LeetCodeAPITests` — exact request bodies and headers per call; every recorded
    fixture parses to the expected model; each hand-authored shape-violation fixture
    throws `apiChanged` naming its key path; logged-out, paid-only and throttled
    responses each produce their own error; and the deliberate difficulty-strict /
    status-lenient asymmetry. Also the two rules that exist because a wire string
    is not automatically usable: a `titleSlug`/`question__title_slug` that is not a
    slug (traversal, a separator, spaces, a leading hyphen) is `apiChanged` naming
    the key path while an absent one still falls back to what was requested (L13),
    and the throttle wait is read from the number its unit follows rather than the
    first number in a joined error message (L14).
  - `LeetCodeProblemInputTests` / `LeetCodeSolutionFileTests` — every accepted and
    rejected input form; the file-name round trip including padding boundaries and
    hyphenated slugs; the language mapping in both directions plus the
    extension → `SyntaxLanguage` check; the header comment per language.
  - `LeetCodeCatalogTests` / `LeetCodeStatementDocumentTests` / `LeetCodeModelTests`
    — driven by `StubFileTree` (including its `writeFailures` injection point) and
    `ScriptedLeetCodeTransport` (`Tests/PisakaCoreTests/Support/`, the
    `ScriptedLSPTransport` shape: canned answers keyed by route — including a
    `.question(slug:)` route read out of the request's own `variables` — a
    recording, gates and per-step delays, plus `InMemoryLeetCodeCredentialStore`
    with `saveFails`/`clearFails`). They cover the cold/warm/stale/miss/corrupt
    cache paths, the light-vs-dark and every-colour-reaches-the-CSS assertions, the
    full open-problem happy path for all three input forms, the byte-identical
    re-open, every failure path leaving no partial file, two overlapping opens
    publishing only the newer one, the offline statement, and the settings keys.
    The rules that are only visible as *counts and refusals* are asserted the same
    way: a stale catalog whose refresh fails still answering from disk while a
    number it does not hold still throws; an unlistable folder refusing to write
    rather than overwriting a half-finished solution; a sign-out holding when
    `clear()` throws (and a later sign-in re-arming the store); a rejected
    `refreshUserStatus` flipping `isSignedIn` where an offline one does not; one
    `questionData` request across an open plus the tab activation that follows it,
    and across a switch away and back; and `isBusy`/`isOpening` tracked separately
    through two genuinely overlapping operations, since one operation would pass a
    plain `Bool` identically.
  - `LeetCodeJudgeAPITests` — the wire half of the judge: byte-exact
    `interpret_solution` and `submit` bodies (the internal `question_id`, and
    Submit carrying **no** `data_input` at all), the trailing slashes, the
    problem-page `Referer` beside the site-root one the GraphQL calls keep, both id
    parses in both forms they arrive in, every fixture-driven verdict on **both**
    finished shapes, and the two strict tables failing loudly — an unknown
    `status_code` and an unknown `state` are each `apiChanged` naming the value.
    The asymmetry has its own test: a *display* field respelled costs that field
    and not the verdict. Plus a 429 and a DRF auth body on a check, so the
    plain-REST classification is pinned on the judge endpoints too, and the
    formatter guard that keeps an implausible budget from trapping.
  - `LeetCodeJudgeModelTests` — the flow, driven through a real `LeetCodeModel`
    over `ScriptedLeetCodeTransport` (which grew `.interpret(slug:)`,
    `.submit(slug:)` and `.check(id:)`, recognised by **path shape**, so a request
    nobody expected still lands in `.other(path:)` and names itself). The
    availability table including the not-offerable refusal and the order refusals
    are reported in; `PENDING → STARTED → SUCCESS` for both kinds, which the
    sticky-last-step queue makes one line; budget exhaustion publishing the typed
    timeout; a throttle mid-poll published and stopping the poll; a logged-out
    check flipping the account state; and the three rules that are only visible as
    a **refusal to publish** — a superseded attempt, a cancelled one and a sign-out
    mid-poll each publishing nothing at all. Also that the edited box reaches the
    interpret payload verbatim while Submit sends none, and that the **live buffer**
    is what is judged rather than any saved copy. The memo's rules are in
    `LeetCodeModelTests` beside the other request-count assertions: warm after an
    open and after a statement refresh, a cold slug fetched exactly once and never
    again, an unknown slug answering `nil`, and a sign-out emptying it.
  - `LeetCodeProblemFilterTests` — the filter as a **table over one fixed,
    deliberately out-of-order row set**: an exact number query and the prefix rows
    it must *not* match, a padded number, a number nothing holds, a number reaching
    a paid row, `0` falling through to the substring branch, title and slug
    substrings, a query matching only paid rows, mixed case in both directions, a
    trimmed query, empty and all-whitespace queries, a pasted problem URL matching
    nothing, each difficulty set plus a two-element one, each status set, the
    empty-and-full-set agreement on both dimensions, query ∩ difficulty ∩ status, a
    combination matching nothing, paid rows surviving **every** combination,
    catalog order preserved from unsorted input, and `isEmpty`.
  - `LeetCodeBrowserModelTests` — the flow, driven through a **real
    `LeetCodeModel`** over `ScriptedLeetCodeTransport` + `StubFileTree` with the
    catalog suite's injected clock: a warm disk cache loading with **zero**
    requests; a cold one fetching exactly once and publishing the rows, the fetch
    time and no error; `refresh()` fetching again *inside* the staleness window; a
    failing refresh keeping the previous rows beside the typed error; a failing
    first load publishing the error with no rows; signed out publishing
    `.notSignedIn` and making no request at all; a sign-in re-arming availability
    and a sign-out clearing the rows; a `load()` held on a `Gate` while a sign-out
    bumps the token publishing **nothing**; setting `filter` republishing
    `visibleProblems` without touching the transport; and a load cancelled mid-fetch
    publishing nothing *while the shared catalog fetch still lands* — the shield,
    asserted with a sleeping delay rather than a `Gate`, because only a cancellable
    wait can show whether cancellation reached the request. The catalog half lives in
    `LeetCodeCatalogTests` beside the other request-count assertions: a cache
    inside the window costing zero `problemList` requests, an absent one and a
    day-old one costing exactly one, two overlapping `loadIfNeeded` calls (staged
    with `Gate`) coalescing onto one, a refresh failure throwing while
    `problems` stays populated, and a fresh-looking but **zero-row** cache file
    being treated as absent instead of suppressing the fetch for a day.
  - Fixtures live in `Tests/PisakaCoreTests/Fixtures/leetcode/`, are recorded from
    the live public endpoints (trimmed to a dozen `stat_status_pairs` for the 2 MB
    list, with a `README.md` recording provenance), are read through `#filePath`,
    and are listed in the test target's `exclude:` — they are data the tests read,
    not a SwiftPM resource. The README labels every file as **verbatim,
    hand-edited or authored**, and the judge's are all authored — categorically, not
    incidentally: all three endpoints require a session and two of them *write* to
    an account, so recording one would mean submitting somebody's code to LeetCode
    from a test run. The `questionId` added by hand to the recorded details is
    labelled the same way rather than passed off as a recording, with the note that
    a re-record makes the label disappear on its own.

The app layer is untested by repository convention, which is why every decision
worth being right about is in Core: what counts as a session, what a typed string
means, what a file is named, when a fetch happens, and what gets written.

## Decisions

- **L1 — every fact about the wire is in `LeetCodeAPI.swift`.** URLs, GraphQL
  documents, header names, JSON key paths, both difficulty spellings and the
  error-phrase lists. The API is unofficial; concentration is the mitigation, and
  `apiChanged(detail:)` naming a key path is what makes a bug report actionable.
- **L2 — the catalog comes from the legacy REST endpoint.** `GET
  /api/problems/all/` is one request for ~4000 problems where GraphQL is ~41 paged
  ones. Its second response shape is parsed in the same file, behind the same
  `apiChanged`.
- **L3 — strict everywhere except per-row `status`.** Difficulty, ids and required
  keys throw; a per-account `status` this build does not recognise degrades to
  `.notStarted`, because being strict there would let one odd row out of four
  thousand kill the catalog and with it every open. A test pins the asymmetry.
- **L4 — an all-digit input is a number attempt and nothing else.** It satisfies
  the slug shape too, and falling through would answer "no such problem" where the
  honest answer is "that is not a problem number". No LeetCode slug is all digits.
- **L5 — the file name is the association, in both directions.** No side-car
  database: `0001-two-sum.swift` is written by one rule and read back by its
  inverse, tested as a round trip. Renaming a solution file detaches it, which is
  the accepted cost of not keeping invisible state.
- **L6 — the catalog is good for a day, and a miss forces exactly one refresh.**
  The window exists to stop hourly 2 MB fetches; the miss path is what makes a
  brand-new problem openable. `hasRefreshedFromNetwork` (not set by a disk
  restore) is what makes it *one*.
- **L7 — "no such problem" is a value, not an error.** `LeetCodeCatalog` answers
  `nil` and `LeetCodeModel` answers `.noSuchProblem`; `apiChanged` stays reserved
  for LeetCode having changed shape, and no `notFound` case joins the error enum.
- **L8 — cache and Keychain failures degrade, they do not fail the operation.**
  `lastCacheWriteFailed` and `lastCredentialSaveFailed` record them; the session
  runs in memory or re-asks for a sign-in next launch. The user asked to open a
  problem, and that succeeded.
- **L9 — the statement fragment is stored and rendered verbatim.** Sanitising it
  would be a second parser for an unofficial API; the document instead loads no
  script (`allowsContentJavaScript = false`) and grants no privileges. Only the
  title — which this app supplies — is escaped.
- **L10 — three generation counters, not one.** Open, statement and account, so a
  statement refresh cannot cancel an open; all three are bumped by a sign-in or
  sign-out, because a session change invalidates everything in flight. `isBusy` is
  a count for the same class of reason.
- **L11 — a rejected request flips the published state but keeps the stored
  session.** A 403 from an unofficial endpoint is as often a throttle in disguise
  as a dead session. Only an explicit sign-out forgets the pair — and it purges the
  web view's cookies in the same call, because either half alone leaves the user
  half signed in.
- **L12 — never overwrite.** An existing solution file is `.resumed` untouched;
  existence is asked as a directory listing rather than as a read, so a read that
  failed for some other reason cannot become an overwrite — and a *listing* that
  fails throws rather than answering "absent", so an unreadable folder cannot
  become one either — and the name comparison is **case-insensitive**, since the
  default Apple volume is, so a solution renamed to a different case is still that
  solution rather than a name the next open writes straight over. This is the one
  failure in the integration a user could not undo, so it is the one the design
  refuses structurally.
- **L13 — a slug off the wire is validated before it is a path component.**
  `LeetCodeAPI` runs every `titleSlug` and `question__title_slug` through
  `LeetCodeProblemInput.normalizedSlug` and reports a failure as `apiChanged`
  naming the key path. A slug becomes a file name appended to the user's folder,
  and `appendingPathComponent` resolves no `..`; it also has to survive
  `LeetCodeSolutionFile.parts(fromFileName:)`, which validates by the same rule.
  Checking at the parse boundary is what makes "the app cannot write a name it
  would then fail to recognise" — and "the file lands inside the folder the user
  chose" — structural rather than hopeful. The one repair made is lowercasing,
  because that is the one `normalizedSlug` makes.
- **L14 — the wait in a throttle sentence is read from the unit, not from the
  first number.** `classify(graphQLErrors:)` passes every message joined together,
  so an unanchored scan reports "for user 12345 … in 30 seconds" as a 12345-second
  wait. Only a digit run the word `second`/`minute` follows counts, and anything
  over an hour is refused: `throttled(retryAfter: nil)` already renders as "in a
  moment", which is strictly better than a confidently wrong number.
- **L15 — the statement is fetched once per slug per run.** `openProblem` already
  holds the detail, and the panel's refresh is keyed on the active tab — so
  publishing the fragment is not enough to stop the tab change that follows from
  re-requesting it. `LeetCodeModel.slugsFetchedThisRun` is the record that makes
  the second request not happen; `signOut()` empties it.
- **L16 — the internal `questionId` is modelled now, and only because the judge
  needs it.** LC-1 deliberately did not carry it; `interpret_solution` and
  `submit` address a problem by it and accept no other spelling, so
  `LeetCodeProblemDetail` carries it beside `frontendID` with both documented as
  the pair they must never be confused for. It never reaches a file name, a URL or
  anything a user types, it is a `String` because that is what the payload sends,
  and it is demanded strictly — including for a Premium problem, since substituting
  `questionFrontendId` is the repair that looks right on Two Sum and judges
  something else on anything recent.
- **L17 — the judge is a companion model with its own generation token.** Owned by
  `LeetCodeModel` the way `catalog` is, so the surfaces observe the narrower
  object and a keystroke in the test-case box invalidates neither the statement nor
  the account. Its token is the **fourth**, beside open, statement and account, so
  a poll and a statement refresh cannot cancel each other — and it is bumped by a
  sign-in or sign-out with the other three, because a session change invalidates a
  poll in flight as surely as a fetch.
- **L18 — polling is a fixed interval against a hard deadline.** One second
  between checks, `Budgets(run: 30, submit: 60)` as injectable data, and the budget
  enforced against a `now()` deadline rather than an attempt count, so a slow
  network cannot silently double the promised wait. Exhaustion is the typed
  `judgeTimedOut`, never a hang — and its sentence says the submission still
  reached LeetCode, because a user who thinks it was lost submits twice.
- **L19 — the submission language is the file extension**, resolved through the
  one `offerableLanguages` list that already answers the other two directions, so
  a file this app wrote always maps back to what it wrote. A file that maps to no
  offerable language is refused with a stated reason rather than guessed at.
- **L20 — the test-case box is session state.** Prefilled from the problem's own
  examples, sent verbatim by Run, **ignored entirely by Submit** (whose payload
  omits `data_input` rather than sending it empty), reset when the problem changes
  and never written anywhere.
- **L21 — the judge context is memoised in memory per run.** Every detail fetch
  that already happens records `(questionId, examples)` by slug — written in
  `fetchDetail`, the one funnel all callers pass through — and a slug this run has
  never fetched costs exactly one lazy request. The statement disk cache goes on
  storing the bare HTML fragment; its format is untouched by any of this.
- **L22 — the verdict and state tables are strict, with no default.** An
  unrecognised `status_code` or `state` is `apiChanged` naming the value, because a
  tenth outcome rendered as some fallback would be a confidently wrong verdict on
  somebody's submission — while the *decorations* around the verdict (percentiles,
  runtime strings, echoed inputs) are read leniently and an absence stays `nil`.
  `FAILURE` is the one addition to the state table rather than an exception to it:
  LeetCode documents that state by sending it.
- **L23 — the browser is a client-side filter over the one catalog.** The whole
  list is already in hand — `LeetCodeCatalog` holds every row from one REST
  request, cached on disk for a day, per-account status included — so searching is
  a pure pass over an array rather than an endpoint: no GraphQL problem-list query,
  no paging, **no new entry in `LeetCodeAPI.swift`**, instant results, and a browser
  that works offline off the disk cache. It reads the *existing*
  `LeetCodeModel.catalog`, because a second catalog would mean a second disk cache
  and a second staleness clock disagreeing with it. The layer creates nothing and
  owns no cache of its own, and opening a row goes through `openProblem`, so LC-1's
  one create stays the only create in the area and there is no second open path.
  The one thing it does write is not its own: a `load()` that finds the catalog
  stale, and every `refresh()`, have `LeetCodeCatalog` rewrite `catalog.json` from
  the response — the same write an open has always caused, now also reachable from
  the Refresh button.
- **L24 — status freshness is the catalog's fetch time, and the surface says so.**
  A row's solved/attempted mark is whatever the account looked like when the list
  was fetched, so a problem solved five minutes ago shows as solved only after a
  refresh. Rather than pretending otherwise, both surfaces show the fetch time
  beside an explicit Refresh — and a refresh that fails keeps the rows it has and
  puts the error beside them (`resolveSlug`'s degradation rule on a new axis),
  because blanking a list somebody is reading is worse than showing it a little
  old. Signing in as a different account shows the previous account's marks until a
  refresh, because the cache is per app, not per account.
- **L25 — the browser is the fifth generation token, and a number query is
  exact.** A companion model like the judge, owned by `LeetCodeModel` and observed
  by the browser surfaces alone, so a keystroke in the search field invalidates
  neither the account, the statement nor the judge; its token is the fifth, bumped
  by `load()`, `refresh()` and `sessionDidChange()`, and superseded work publishes
  nothing at all. And an all-digit query is a **number attempt and nothing else** —
  L4 reused through `LeetCodeProblemInput.parse` rather than restated — matching
  `frontendID` exactly rather than by prefix, so `1` answers problem 1 instead of
  the thousand rows whose number starts with a 1.

## Known limits

- **The API can change without notice.** Every mismatch surfaces as `apiChanged`
  with a key path, and the fix is one file — but it is still a fix that ships in an
  app update. The error-phrase lists (throttle, authentication, premium) are the
  softest part: an unknown phrasing degrades to `apiChanged` rather than to a wrong
  verdict, which is the intended failure mode.
- **Offline statements have no images.** The fragment is cached, LeetCode's CDN
  images are not; mirroring them would turn a text cache into an asset store with
  its own eviction problem.
- **Renaming a solution file detaches it from its problem** (L5), and so does
  moving it out of the configured LeetCode folder — the association needs both
  halves.
- **A problem added in the last day can cost one extra 2 MB fetch** (L6), the one
  forced refresh. After it, a number that is still absent is answered immediately
  for the rest of the session.
- **Premium problems the account cannot read are refused, not partially opened.**
  The refusal is on the *locked shape*, not on the flag: `isPaidOnly` describes
  the **problem**, and LeetCode sets it for every caller, withholding
  `content`/`codeSnippets` only from one who is not subscribed. So the model
  refuses when the flag arrives with an empty `content` — before writing anything,
  rather than seeding a file from a statement the account cannot read — and opens
  normally when LeetCode actually sent the content, which is what a subscriber
  gets. Gating on the flag alone refused the one user entitled to the problem, and
  disagreed with `statement(forFileAt:in:)`, which gates on content and would have
  rendered the statement beside a file the open path had just declined to create.
- **Solution files are not visible in the Files app by default on iOS.** The
  container's `Documents` directory is exposed by `UIFileSharingEnabled`, which this
  build does not set (`project.yml` is unchanged); `LSSupportsOpeningDocumentsInPlace`
  grants in-place access to what the *picker* vends, which is a different question.
  The files are fully usable in the app either way, and a user who wants them
  elsewhere can point the folder at a Files location through Change….
- **SSO cookies outlive the sign-in sheet** (the persistent `WKWebsiteDataStore` is
  what makes SSO work at all). Sign Out purges `leetcode.com` cookies only,
  deliberately leaving every other site a web view in this app has loaded alone.
- **One account at a time.** The Keychain item *is* the session, filed under a
  constant account; switching accounts is a sign-out followed by a sign-in.
- **A Run or Submit that outruns its budget does not undo the submission.**
  LeetCode has it the moment the POST succeeds, and its verdict appears on the
  site; the budget bounds how long *this app* waits, nothing more. The same is true
  of a cancel and of a sign-out mid-poll. Both sentences say so rather than
  implying the attempt was lost, because the failure mode of the other reading is a
  user submitting twice.
- **Edited test cases are not persisted.** The box is session state: switching
  problems resets it to the statement's own examples and quitting forgets it
  entirely. Persisting it would mean a fourth thing on disk keyed by problem, and
  the examples are one request away.
- **Percentiles are absent on most verdicts**, and counts on some. LeetCode simply
  omits them for anything that is not Accepted, and a compile error never reached a
  test case at all; those stay absences rather than being shown as zeros.
- **No submission history and no per-case editing beyond the one box.** The judge
  shows the attempt it just made; earlier submissions, their diffs and the
  editorial stay on leetcode.com, which the pane's header button opens.
- **Run and Submit are reachable only while the statement surface is showing.**
  The section is a child of the pane's `pane(_:)` / `LeetCodeDescriptionContent_iOS`,
  both of which render only under `if let statement = model.statement` and not at
  all when the macOS pane is collapsed — so a solution file whose statement was
  never fetched and is not on disk (a first open while offline) offers no judge
  controls, folding the pane away hides them, and on compact iOS width they live
  inside the toggled sheet. The judge itself needs none of that: its inputs are the
  file, the session and the memoised question id, and it fetches the last of those
  lazily. It is therefore a **placement decision, not a dependency** — Run and
  Submit are about the problem being read, and lifting them out would mean a second
  surface with its own visibility rule and its own answer to "which file is this
  for", which is the coupling the single `.task(id:)` key currently avoids.
- **A run's echoed input is shown as one block, not per case.** `data_input` is
  one line per *argument*, so on any problem taking more than one there is no
  per-case slice of it that could be labelled; the per-case rows carry the output,
  the expected answer and stdout, which genuinely are one entry each.
- **The browser's per-account status is as old as the catalog fetch** (L24). A
  problem solved on leetcode.com a minute ago is still "not started" here until a
  Refresh, and the automatic refresh is the catalog's day-long staleness rule. The
  cross-account form of the same limit: the cache is per app rather than per
  account, so signing in as somebody else shows the previous account's marks until
  the first refresh under the new session.
- **The browser filters by difficulty, status and text, and by nothing else.** No
  topic/tag, company, favourites or study-plan filters, because each of those needs
  a GraphQL surface this design deliberately avoids (L23) — and no sorting beyond
  LeetCode's own ordering, which the one-pass filter preserves by construction. A
  pasted problem URL matches nothing in the search field: the query falls through to
  a substring match on the raw text, and the Open Problem field is where a pasted
  URL is understood.
- **Premium rows cannot be hidden.** `isPaidOnly` is not a filter dimension at all,
  by design: filtering them out would leave gaps in LeetCode's numbering that read
  as missing problems. They are listed with a lock and refused on open with the
  Premium sentence, which is the same refusal a typed number gets.
