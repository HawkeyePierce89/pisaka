# PisakaCore — the LeetCode integration (LC-1: login, open problem, solution file, description panel)

Design documentation for the layer that signs in to LeetCode, turns a number, a
slug or a pasted URL into a solution file inside a folder the user set aside for
it, and renders the problem statement beside the editor. Each entry records a
file's contract, invariants and the reasoning behind non-obvious decisions —
read the relevant entry before modifying that file, and update it when behavior
changes.

**What this layer is.** A transport seam whose only real implementation is
app-side, one file holding every fact about LeetCode's wire format, two pure
string layers (what the user typed, and how a file name names a problem), a
disk-cached problem catalog, a composed HTML document for the statement, and one
`@MainActor ObservableObject` that sequences the awaits. On top of that sit the
app halves: a `URLSession` transport, a cross-platform Keychain store, a shared
`WKNavigationDelegate` that watches the login cookie store, and per-platform
chrome (a macOS menu + sheet + pane, an iOS screen + adaptive pane/sheet).

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
`LeetCodeError` + `LeetCodeProblem` (the vocabulary) → `LeetCodeAPI` (what to
send, and what an answer means) → `LeetCodeProblemInput` + `LeetCodeSolutionFile`
(the two pure string layers) → `LeetCodeCacheLayout` + `LeetCodeCatalog` (number
→ slug, cached for a day) + `LeetCodeStatementDocument`/`LeetCodeStatementCache`
(the panel's bytes) → `LeetCodeModel` (the one place that sequences awaits) →
the app surfaces.

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

The decisions L1–L15 are written out at the end of this document, together with
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
    `folderUnavailable`, `fileSystem(reason:)`. `apiChanged`'s `detail` is the
    whole diagnosis for an unofficial API — it names the key path or value that
    did not match (`data.question.content`, `difficulty.level = 7`), so a bug
    report names the one line of `LeetCodeAPI` to edit. `throttled` carries the
    server's own `Retry-After` when there was one and `nil` when there was not,
    the difference being whether the sentence can name a wait. Lives in Core, like
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
    status: the identifier that matters is `frontendID` (the number on the site
    and the number a user types), and LeetCode's internal `question_id`, which
    drifts from it for newer problems, is deliberately **not** modelled. It is
    **not** `Codable`: the on-disk cache has its own versioned DTO, so this model
    can be renamed or extended without invalidating every user's cache.
    `LeetCodeProblemDetail` composes it — rather than restating its fields, so the
    catalog and the detail can never disagree about what a problem *is* — and adds
    the HTML `content` **fragment**, `codeSnippets` keyed by LeetCode's language
    slug, and `exampleTestCases` in LeetCode's own order (the default input for
    LC-2's Run).
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
    model, the layer that knows a file was about to be written.
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
    *The JSON reader* is a private `JSONObjectReader` that remembers its own path,
    rather than `Codable`: a `DecodingError` would say
    `keyNotFound(CodingKeys(...))`, and this layer's whole contract is that the
    string in the bug report is `data.question.content`. `integer(_:)` accepts a
    JSON number *or* a numeric string, because GraphQL spells the very same
    problem number as `"1"` and the REST catalog as `1` (both recorded in the
    fixtures); a non-numeric string is still `apiChanged`, naming the value.
    Absent and explicitly-null are not distinguished, because on this API they
    mean the same thing everywhere they are read optionally.
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
    *and* LeetCode accepts submissions in it — and both directions of the mapping
    go through that one list. Note the two non-obvious slugs: LeetCode says
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
    2 MB downloads used to happen.
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
    open report "no such problem", so it is `apiChanged`.
    `publish` rebuilds two indices (`number → slug`, `slug → problem`) rather than
    searching four thousand rows per keystroke, and on a duplicate number or slug
    the **first** row wins, so the answer is LeetCode's own ordering.
    *The disk cache.* `loadFromDiskIfNeeded` runs once per session — after it,
    "no snapshot" means "there is no cache" rather than "it has not been looked
    at" — and every failure is treated identically as **there is no cache**: no
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
    web-view re-login. Only `signOut()` forgets them — and the app layer's half of a
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
    at all; Premium → `paidOnly` **before anything is written**; compose the name; and **create the
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
    that tab. **Two** answers are recorded there: `data.question: null`, and a
    detail that arrives with an empty `content` — which is the Premium shape
    (`isPaidOnly: true` with a null `content`), equally settled *about that slug*,
    and reachable because the model refuses to *open* a Premium problem but a
    solution file for one can reach the folder another way. Offline, throttled and
    rejected are recorded by neither: those are failures to ask and must still be
    retried. `signOut()` **and `signIn(with:)`** empty both sets, since a session
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
    `slugsFetchedThisRun` before any fetch could correct it. `signOut()` does *not*
    empty it, matching the disk fragment cache it parallels: a problem's title is
    public content, not something the session revealed.
    *Plumbing.* Every request goes through one `send` that folds a non-`LeetCodeError`
    into `network`, so a decorator or a stub cannot escape this layer's vocabulary
    (the same fold `LeetCodeCatalog` applies). A Keychain that refuses the item does
    not fail the sign-in (`lastCredentialSaveFailed`, the `lastCacheWriteFailed`
    shape).
  - `SettingsStore.swift` (modified; the entry is in `core-services.md`) — three
    stable keys: `leetCodeFolderPath` (a plain path; blank-trimmed, and an empty
    string normalises to `nil` so "unset" has one spelling),
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
    refresh. `save` is delete-then-add, so the path is one idempotent branch rather
    than an add/update fork whose halves can disagree about accessibility.
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
    to observe. Nothing in the menu is gated on a project being open.
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
    this view loaded** — every other main-frame navigation goes to `NSWorkspace` and
    is cancelled, because a related-problem or editorial link would otherwise
    replace the statement inside a 380 pt pane with no way back (the pane has no
    back gesture, and the reload gate above will not restore a document whose HTML
    has not changed). The test is the *frame and the URL*, not `linkActivated`
    alone: a click is only the navigation the user can see coming, and this
    markup is interpolated verbatim, so a `<meta http-equiv="refresh">` or a
    `<form>` in it navigates the pane just as effectively — neither needs the
    scripting that is off. Sub-frame loads are left alone (LeetCode's own markup
    embedding something), and subresource loads never reach the delegate at all.
    The document itself is recognised by its URL, `LeetCodeAPI.siteURL`, which is
    what `loadHTMLString` was handed as its base and what the document's own
    `<base href>` carries. **Only `http`/`https` are
    handed over**, everything else is cancelled and nothing else happens: this
    markup is rendered verbatim and never sanitized, so the `href` behind a click is
    untrusted by construction, and `NSWorkspace.open` would launch a `file:` URL in
    its default handler or give any other scheme to whichever app claims it —
    scripting being off does not cover this, since it is the delegate and not the
    page that performs the open. The iOS pane's `UIApplication.open` carries the
    same gate for the same reason. `loadHTMLString`'s base URL
    matches the document's own `<base href>`, or LeetCode's relative `<img src>`s
    would resolve against `about:blank`.
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
    the loaded document — everything else `http`/`https` out to Safari, everything
    else cancelled).
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
  - Fixtures live in `Tests/PisakaCoreTests/Fixtures/leetcode/`, are recorded from
    the live public endpoints (trimmed to a dozen `stat_status_pairs` for the 2 MB
    list, with a `README.md` recording provenance), are read through `#filePath`,
    and are listed in the test target's `exclude:` — they are data the tests read,
    not a SwiftPM resource.

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
- **Premium problems are refused, not partially opened.** LeetCode sends
  `isPaidOnly: true` with null `content`/`codeSnippets`; the model refuses before
  writing anything rather than seeding a file from a statement the account cannot
  read.
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
