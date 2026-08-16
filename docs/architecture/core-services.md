# PisakaCore — terminal/run/test resolution, settings & session

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `TerminalLaunch.swift` — pure, testable launch-parameter resolution for the
    embedded terminal (Foundation only, no AppKit/Process — the PTY/rendering/
    lifecycle all live in `Pisaka`, the same split as `CodeEditorView`/
    `GitCLIService`). A `public enum TerminalLaunch` with two branch-free static
    functions: `shell(environment:) -> String` returns `environment["SHELL"]` when
    set and non-empty, else `/bin/zsh` (the macOS default); `workingDirectory(
    projectRoot:home:) -> URL` returns `projectRoot` when a folder is open, else
    `home`. Unit-tested in `TerminalLaunchTests`.
  - `TerminalTabs.swift` — pure, testable tab bookkeeping for the embedded
    terminal's session list (Foundation-only, the `TerminalLaunch` precedent — the
    live sessions and their PTYs stay in the view layer, only the off-by-one-prone
    index math lives here). `static func activeIDAfterClosing(_:order:active:) ->
    UUID?` takes the tab `order` *before* removal: closing the active tab selects
    its left neighbor (or the tab that becomes the new first, when the first is
    closed), and `nil` when the list empties; closing a non-active tab, or an id
    absent from `order`, leaves the selection unchanged. Unit-tested in
    `TerminalTabsTests`.
  - `RunCommand.swift` — pure, testable resolution of how to *run* the editor's
    current file in the embedded terminal (Foundation only, no AppKit/Process — the
    PTY/session lifecycle lives in `Pisaka`, the same split as `TerminalLaunch`).
    A `public enum RunCommand` backed by a private static lowercased-extension →
    runner-tokens map (`ts`/`tsx` → `npx tsx`, `js`/`mjs`/`cjs` → `node`, `py` →
    `python3`, `swift` → `swift`, `go` → `go run`, `sh`/`bash` → `bash`), mirroring
    `FileIcon`/`SyntaxLanguage`'s extension-map pattern. `command(forFileName:
    absolutePath:) -> String?` looks up the file's extension (via
    `(fileName as NSString).pathExtension.lowercased()`) and, when known, returns
    the joined runner tokens plus the shell-quoted path (`nil` for an unknown/empty
    extension); `canRun(fileName:) -> Bool` reports whether the extension has a
    runner (drives the "Run" context-menu item and the ⌘R menu enablement);
    `workingDirectory(projectRoot:fileURL:) -> URL` returns `projectRoot ??
    fileURL.deletingLastPathComponent()`.
    **Rust deliberately has no `rs` entry**, and the asymmetry with `TestCommand`
    — which answers `cargo test` for the same file — is real and explainable
    rather than an oversight. This map answers a command for a *single file* and
    appends the quoted path; `cargo run` takes neither. Rust has a project-level
    runner and no file-level one — `rustc` compiles to a binary you then run,
    which is two steps and a different thing — so ⌘U works, ⌘R is disabled, and
    `cargo run` from the terminal panel is the answer. Pinned by
    `RunCommandTests.testRustHasNoRunner` (including the uppercase `MAIN.RS`,
    since `canRun` lowercases before the lookup) in its own section, so it reads
    as a decision rather than as `.rs` falling through the "unsupported extension"
    test beside `.md` and `Makefile`, and by a third test asserting that
    `SyntaxLanguage(forFileName:)`, `isTestFile` and `canRun` agree on one Rust
    file: `.rust`, testable, **not** runnable. Paths are shell-quoted via the shared
    `ShellQuote.quote(_:)` (extracted from the former private `shellQuoted`), so
    spaces and shell metacharacters (`$`, backtick, `;`) survive intact.
    Unit-tested in `RunCommandTests`.
  - `ShellQuote.swift` — pure, testable POSIX-shell single-quoting shared by the
    run/test command resolvers (`RunCommand`/`TestCommand`): `public enum
    ShellQuote { static func quote(_:) -> String }` wraps the value in single
    quotes and escapes each embedded `'` as `'\''` (everything else is literal
    inside single quotes). Foundation-only, unit-tested in `ShellQuoteTests`.
  - `TestCommand.swift` — pure, testable resolution of how to *test* the editor's
    current file in the embedded terminal, mirroring `RunCommand` (Foundation
    only, no AppKit/Process — the PTY/session lifecycle lives in `Pisaka`). Two
    value types + a resolver enum. `public struct ProjectTestEvidence: Equatable`
    carries the detection signals the view layer gathers through `FileServicing`
    (so `TestCommand` stays pure): `rootEntryNames: Set<String>` (the project
    root's entry names — config files like `vitest.config.ts`, `Gemfile`)
    and `manifests: [String: String]` (the raw contents of a fixed manifest set,
    keyed by file name, e.g. `"package.json"`). `public enum TestResult: Equatable`
    is `.command(String)` / `.runnerUndetected` (the latter only for JS/TS with no
    detectable runner, or an unknown extension — every other supported language has
    a single canonical runner). `public enum TestCommand` has:
    `isTestFile(fileName:) -> Bool` (per-language test-naming convention — JS/TS
    `*.test.*`/`*.spec.*`, Python `test_*.py`/`*_test.py`, Ruby `*_spec.rb`/
    `*_test.rb`, PHP `*Test.php`, Elixir `*_test.exs`, Go `*_test.go`, Swift
    `*Tests.swift`/`*Test.swift`, Rust any `.rs`; drives the "Run Test" menu/context
    item enablement); `command(forFileName:absolutePath:evidence:) -> TestResult`
    over an extension-ordered runner catalog with `<file>`/`<dir>` shell-quoted via
    `ShellQuote` — JS/TS first-matched-signal-wins vitest > jest > mocha (vitest/
    jest from a `vitest.config.*`/`jest.config.*` root entry, mocha from a
    `.mocharc*` root entry, or any of the three from a `package.json` substring)
    else `.runnerUndetected`,
    Python `pytest <file>`, Ruby by filename suffix — `rspec <file>` for
    `*_spec.rb` else `ruby <file>` — each prefixed with `bundle exec ` when a
    `Gemfile` is a root entry (`.rspec` is *not* consulted — the suffix decides the
    runner), PHP `./vendor/bin/phpunit <file>`, Elixir `mix test <file>`, Go
    `go test <dir>`, Rust `cargo test`, Swift `swift test`; and
    `workingDirectory(projectRoot:fileURL:)` (delegates to
    `RunCommand.workingDirectory` so run and test sessions agree on cwd).
    Unit-tested in `TestCommandTests`.
    **Rust's two answers are both "everything, unconditionally", and both are
    decisions.** `isTestFile` is true for *any* `.rs` file because Rust's tests
    live beside the code in `#[cfg(test)]` modules, so there is no naming
    convention to match — and the suite pins the three *foreign* conventions
    (`foo_test.rs`, `test_foo.rs`, `foo.test.rs`) as answering **true** for that
    reason rather than because they matched anything, which states the failure
    mode a borrowed suffix check would introduce: it would *exclude* ordinary
    files. The command is the constant `cargo test`, taking neither the file nor
    its directory — cargo finds the workspace from the cwd — so no evidence is
    consulted and, unlike Go's `go test <dir>`, a path full of shell
    metacharacters cannot reach the command line at all.
  - `BottomPanel.swift` — pure, testable VS Code-style bottom-dock-panel state
    (Foundation-free — semantic enum only, the `FileIconColor`/`LogFilter`
    precedent). A `public enum BottomPanel: Equatable { case terminal, log,
    changes }` (which panel, if any, sits in the bottom dock above the
    always-visible bar; a `BottomPanel?` of `nil` = hidden — Terminal, Git Log,
    and Local Changes share the one dock) plus the only stateful logic, the pure
    `static func toggled(_ current: BottomPanel?, selecting target: BottomPanel)
    -> BottomPanel?`: re-selecting the shown panel collapses it (`nil`), otherwise
    the `target` is shown — so a bottom-bar button and its matching View-menu
    command behave identically (the helper is generic over the case, so `.changes`
    needs no special handling). Unit-tested in `BottomPanelTests`.
  - `DiffWindowTitle.swift` — pure, testable window-title builder for the separate
    (non-modal) diff windows opened on double-click (Foundation-only, color/UI-free
    — the `FileIcon`/`LogFilter` move-logic-into-Core precedent, so the
    off-by-one-prone short-hash truncation is unit-tested rather than living in the
    view layer). A `public enum DiffWindowTitle` with `shortHashLength = 7` (git's
    conventional short hash) and two static builders pairing the file path with its
    context so several open diff windows stay distinguishable: `localChanges(path:)
    -> String` (path + " — Local Changes") and `commit(path:hash:subject:) ->
    String` (path + " — " + the hash truncated to `shortHashLength` + subject; a
    full-length or already-short hash both yield a sensible prefix). Unit-tested in
    `DiffWindowTitleTests`.
  - `TabOrientation.swift` / `ThemePreference.swift` — pure, color/SwiftUI-free
    semantic enums (`String`/`CaseIterable`/`Equatable`, the
    `FileIconColor`/`BottomPanel` precedent) for the two non-numeric preferences,
    their `String` raw values the stable persisted form. `TabOrientation`
    (`.vertical`/`.horizontal`) is how the open-tabs list is laid out (a vertical
    column beside the editor, or a horizontal strip above it); `ThemePreference`
    (`.system`/`.light`/`.dark`) is the appearance preference, mapped to a SwiftUI
    `ColorScheme?` in the view layer (`.system → nil`).
  - `SettingsStore.swift` — `ObservableObject` (Foundation only, the
    `WorkspaceModel` precedent) holding the three persisted preferences:
    `@Published` `tabOrientation`, `themePreference`, and the shared editor
    `fontSize` (`Double`). `UserDefaults` is injected (`init(defaults: .standard)`)
    so tests run against an isolated `UserDefaults(suiteName:)`; values are loaded
    in `init` (falling back to `.vertical`/`.system`/`defaultFontSize`), and each
    `@Published` change is written straight back through `didSet` under stable
    keys (`Keys.*`, never renamed). `fontSize` is clamped to
    `[minFontSize, maxFontSize]` (8…32) on every write — the `didSet` re-assigns
    the clamped value (a one-pass fixed point) so neither the Stepper, the
    Cmd+scroll path, nor a corrupt persisted value can drive it out of range — and
    `init` distinguishes "unset" (→ `defaultFontSize` 13) from a stored 0 via
    `object(forKey:)`. Exposes `minFontSize`/`maxFontSize`/`defaultFontSize`/
    `fontSizeStep` (static + instance mirrors), `clampFontSize(_:)`, and
    `stepFontSize(by:)` (steps then clamps — the Cmd+scroll path calls it with
    `+1`/`-1`). Fully unit-tested in `SettingsStoreTests` (defaults, clamping at
    both bounds, the step helper staying clamped, a persistence round-trip across
    two instances over one suite, and the enums' raw-value stability).
    Phase 2b adds a fourth persisted value, `lspServerConsent`: one dictionary of
    server id → `LSPServerConsent.rawValue` under `Keys.lspServerConsent`, read
    **leniently** (a value the current app does not recognise reads back as
    `unasked`, so a downgrade cannot be poisoned by a newer build's answer) and
    written through `setConsent(_:for:)` alone — `private(set)`, because a
    dictionary bound directly into a view would let a surface record an answer
    without going through the model that owns what an answer *means*. `unasked` is
    stored as **absence** rather than as a value, so "never asked" and "erased"
    are the same state on disk. `consent(for:)` answers `unasked` for anything
    unseen, which is what makes a fresh install prompt exactly once per server.
    Recording an answer equal to the one already stored is a **no-op**: the
    dictionary is `@Published` and `ContentView` observes this store, so a
    redundant write would republish it — re-evaluating the project tree, the tab
    list and the editor — and the provisioning model records `accepted` on every
    install call, including the ones its silent half makes on tab opens.
    The rules built on it are D15 in `core-provisioning.md`; `SettingsStoreTests`
    covers the round trip across a rebuilt store, the lenient read, and that an
    unchanged answer publishes nothing.
    LC-1 adds three more under the same discipline (the layer's entry is in
    `core-leetcode.md`): `leetCodeFolderPath` (the solutions folder as a plain
    path — stored **verbatim**, with a value that is blank once trimmed
    normalising to `nil` so "unset" has exactly one spelling, and
    `leetCodeFolderURL` as the read side. Blankness is decided on the trimmed
    string but the trimmed string is never what is stored: both platforms permit
    a directory name ending in a space, and `NSOpenPanel`/the document picker
    hand back exactly that path, so trimming it would leave the session writing
    to the folder the user picked — the model's `solutionsFolder` is assigned the
    untrimmed `URL` — while the next launch resolved a different, absent spelling
    and created a second folder beside it),
    `leetCodeFolderBookmark` (the security-scoped blob for an iOS override; empty
    data is likewise `nil`, and macOS never writes it, being unsandboxed), and
    `leetCodeLanguage` — which is held as the whole `LeetCodeLanguage` **row**
    rather than as a slug. That is what makes "an unparsable value falls back"
    structural rather than a rule someone has to remember: a slug this build does
    not offer (LeetCode's `kotlin`, or one a later build dropped) resolves to
    `LeetCodeSolutionFile.defaultLanguage` at load, there is no way to *hold* a
    language that is not offerable, and what reaches `UserDefaults` always reads
    back. `SettingsStoreTests` covers the three defaults, the round trip across a
    rebuilt store, the blank-to-`nil` normalisation in both directions, the
    trimming, an unofferable stored slug falling back, and the three key strings.
    T-4 adds one more, `completionEnabled` (`Keys.completionEnabled =
    "settings.completionEnabled"`, stable like the rest), default **on**. It is
    read in `init` as `(defaults.object(forKey:) as? Bool) ?? true` rather than
    through `bool(forKey:)` — the `fontSize` precedent, for its reason and one
    more: `bool(forKey:)` answers `false` for a missing key, so every user who
    has never touched the preference would launch with completion silently off,
    and a value of the wrong type (an older build, a hand-edited domain) would do
    the same. `object(forKey:)` tells "unset" from a stored `false` and lets a
    failed cast fall back to on. It is deliberately **one** flag rather than one
    per platform — the macOS AppKit popup and the iOS accessory strip are two
    presentations of the same preference — and the single source of truth for
    every surface that *shows* the state: the macOS status-bar button
    (`app-window.md`), the Preferences checkbox and the iOS Settings row
    (`app-ios.md`) all bind straight to this property with no local state, so
    they cannot disagree. Off is **total**: neither the automatic popup/strip nor
    an explicitly invoked completion (⌃Space, Find > Complete, AppKit's stock
    ⌥⎋/F5) produces anything. The narrower JetBrains behaviour — auto-popup off,
    explicit invocation still alive — was considered and deliberately **not**
    taken: it needs a second piece of state (the reason a completion was asked
    for) threaded through every entry point, and a switch labelled "off" that
    still pops a list up on a keystroke combination is the worse default. That is
    a decision, not an omission; it stays a possible follow-up. Nothing in the
    intelligence stack is torn down when the flag goes off — no language server
    is stopped, no session shut down, the registry is untouched and the symbol
    index keeps walking and refreshing — only completion *requests* stop being
    made and completion *UI* stops being shown, which is what makes the toggle
    instant and free in both directions and why go-to-definition, which shares
    the same provider, is entirely unaffected. `SettingsStoreTests` covers the
    default on a fresh store, the round trip across a rebuilt store, a
    wrong-typed stored value falling back to on, and the key string.
  - `EditorSession.swift` — the persisted editor session behind launch-time
    session restore and "Untitled" hot exit (macOS today; the iOS variant is a
    follow-up over this same model). Foundation-only: the value types, the pure
    snapshot and the store live here, while the view layer contributes only
    *when* to write (`SessionController`) and *when* to restore (`PisakaApp`);
    applying a session to the model is `WorkspaceModel.restoreSession(_:)`.
    `SessionTab` (`Codable`/`Equatable`) is one recorded tab as a **flat struct
    with two optional fields** — `path` and `text`, with `file(path:)` /
    `untitled(text:)` factories that make it read like an enum — and the struct
    shape is the whole forward-compatibility decision: a synthesized enum
    `Codable` encodes the *case name* and throws `DataCorrupted` on an unknown
    one, so a session written by a future version that adds a third kind of tab
    would fail to decode **wholesale**, one unknown record costing the user every
    other tab, whereas a keyed struct decoder skips keys it does not know. The
    price is a deliberately **permissive** decoder: a record carrying neither
    field decodes fine, as a tab with both `nil` — which *is* the future-version
    tab (a kind whose fields this build has no property for) — and deciding what
    it means is not the decoder's job but restore's, the only place that knows how
    to turn a record into a tab, and which skips it exactly as it skips a file it
    cannot read. `EditorSession` (`Codable`/`Equatable`) is `folderPath: String?`
    + `tabs: [SessionTab]` + `selectedIndex: Int?` (an index into the records
    actually **stored**), with an `isEmpty` computed property. `EditorSession
    .snapshot(openFiles:selectedID:projectRoot:)` is the pure write side: tabs in
    `openFiles` order, a titled file contributing its path, an Untitled buffer its
    text unless that text is **literally empty** (no trimming — a whitespace-only
    buffer is something the user typed and is restored; an empty scratch buffer
    carries nothing worth bringing back), `selectedIndex` shifting past every dropped
    record and `nil` when nothing is selected or the selected buffer's own record
    was dropped. **Paths are stored exactly as the tab spells them** — no
    `CanonicalPath`, no symlink resolution: the stored spelling is the one the user
    opened, which is what keeps the restored tab, the project tree and the
    breadcrumb agreeing after a restart (`DisplayPath` prefers the lexical
    spelling for the same reason), while canonicalization is a *matching* rule and
    so lives on the read side, where `restoreSession` applies it for dedup — the
    same store-as-given / match-canonically asymmetry `WorkspaceModel.open(url:)`
    already has. `EditorSession.merging(_:onto:)` is the second pure rule, for the
    **one caller that applies a session on top of tabs already open** — the first
    Open Folder of a run, where the no-folder workspace's tabs travel into the
    project instead of being force-closed. It returns what
    `WorkspaceModel.restoreSession(_:)` leaves behind, expressed as a session to
    *store*: the carried tabs then the incoming ones, under `incoming`'s
    `folderPath`, with `restoreSession`'s own selection rule restated (anything
    restored takes the selection, at the recorded index or — absent/out of range —
    the incoming session's last tab; an incoming session with no tabs leaves the
    carried selection standing). It is load-bearing rather than a convenience
    because of the switch's store-vs-live invariant, stated in full on
    `SessionController.noteProjectSwitch(promoting:)`: the session filed for the
    incoming project must be a **superset** of what the live model then holds,
    since the app seeds that controller's "already written" marker with the
    post-swap live snapshot and the marker suppresses every later equal write, the
    quit-time flush included. Filing the unmerged incoming entry would make the
    carried tabs unwritable for the rest of the run — the pre-folder Untitled
    buffer on screen, absent from the store, gone at the next launch.
    **Three deliberate limits, recorded on `EditorSession` itself.**
    (1) The contents of dirty *titled* files are **not** persisted, only their
    paths: their text has somewhere to live and autosave already puts it there —
    on quit `flushNow` writes every dirty titled buffer *before* the snapshot is
    taken (the ordering `PisakaApp` owns), and a crash loses at most one autosave
    window (~2 s), the exposure the editor already has; an Untitled buffer is the
    opposite case, skipped by autosave because it has nowhere to write, so the
    session is the only thing carrying its text across a restart. (2) Untitled text
    is **not size-capped**, and the blob being the whole `SessionCatalog` means one
    write decodes and re-encodes *every* remembered project rather than only the
    current one — the cost is proportional to the summed scratch text of up to
    `maxStoredProjects` entries. `SessionController`'s equal-snapshot guard keeps
    that off the steady state (an unchanged session is not rewritten), so it is paid
    only while the session actually keeps changing; if it ever bites, the escape
    hatch is unchanged — move the blob to Application Support, or key each project
    separately, which changes `SessionStore`'s backing store and not the model.
    (3) **One session per
    project, with no per-window identity** — the *project* half is what
    `SessionCatalog` (below) makes exact; the *window* half is exact today rather
    than a limitation, since the app is single-window and its `WorkspaceModel` is
    one `@StateObject` on the `App` shared by every scene, so there is only ever
    one workspace state to snapshot. It becomes a limitation the moment genuinely
    independent windows exist: two windows on the same project would write under
    that one project's key, last writer winning, and merging their tabs would need
    an identity this model does not carry.
    `SessionCatalog` (`Codable`/`Equatable`, in this same file) is **every
    project's session, keyed by its folder and MRU-ordered**: an
    `entries: [EditorSession]` array, index 0 the last opened. **Head is the
    pointer** — `lastOpened` is `entries.first`, a *derivation* rather than a stored
    field, which is the whole reason the order is load-bearing: a separate
    "last opened folder" field could name a folder no entry carries, and "the
    pointer points at a session that is not stored" would be a state someone has to
    handle; here it is unrepresentable. **A session is likewise its own key** —
    there is no key field stored beside it, because `EditorSession.folderPath`
    already records the folder verbatim. That is the same reasoning one level down:
    a key naming a *different* folder than the session next to it would be a state
    someone has to handle (a lookup for `/a` handing back a session whose own path
    is `/b`, which the next `store(_:)` then files under `/b`, orphaning `/a`), and
    a decoder cannot enforce agreement between two independent fields. **Keying
    follows store-as-spelled /
    match-canonically**, the same asymmetry `snapshot` and `open(url:)` already
    share: the entry records the spelling the user opened, while
    `session(forFolder:)` and `store(_:)` both match through
    `CanonicalPath.canonical(_:).path` — the *path*, the key `SymbolIndex` and
    `ProjectSearchModel` use, not the url, since two urls for one directory differ
    by a trailing slash (`file:///p/root/` vs. `file:///p/root`) and compare unequal
    while naming the same folder. So `/tmp` and `/private/tmp`, a trailing slash and
    a `.`/`..` detour all land on one entry instead of quietly accumulating one
    session per spelling; a `nil` `folderPath` is a key like any other (the
    no-folder workspace) and matches only itself, never a real folder. `store(_:)`
    replaces the canonical match — adopting the *incoming* verbatim spelling, the
    user's latest one — inserts when absent, promotes to the head, then drops the
    tail past the limit (clamped to at least one, so the entry just stored can never
    be the one evicted). **Retention is capped by entry count, never by byte
    size**: `maxStoredProjects = 20`, the same number and rationale as
    `ScopedFileAccess.updatedRecents`' recents cap. The count rule is the point, not
    a simplification — entries are independent values, so one project's
    pathologically large untitled buffer (limit 2 above) cannot evict *another*
    project's session, and nothing one project stores changes what another decodes
    to; the only shared failure mode left is an unreadable *whole* blob, which
    resolves to a blank slate exactly as the single blob did. `migrating(_:)` is the
    one-entry catalog a legacy blob becomes.
    `SessionStore` follows `BookmarkStore`'s shape exactly: injected
    `UserDefaults`, one property-list blob — now the `SessionCatalog` — under the
    stable `Keys.projectSessions` (`"session.projects"`), with
    `loadLastOpened()` (the head, what launch restore follows),
    `session(forFolder:)` (that project's session, or `nil` — which is what a
    folder opened for the first time looks like), `save(_:)` and `clear()`.
    `save(_:)` keeps its single-argument signature on purpose and is now an
    **upsert**: the snapshot already names the project it belongs to, so it is
    stored under its own `folderPath`, promoted to the head and capped — and the
    debounced writer (`SessionController`) needs to know nothing about the keying.
    An encode failure is swallowed, leaving the previous blob — every *other*
    project's session included — in place. **Migration**: `Keys.lastSession`
    (`"session.lastSession"`, the pre-catalog single blob) is read **only when
    `session.projects` is absent** and seeds a one-entry catalog whose key is that
    blob's own `folderPath` (possibly `nil`) and which is therefore also the head,
    so the first launch after the upgrade restores exactly what the last launch
    would have. Presence is tested on the *object*, not on `data(forKey:)`, so a
    wrong-typed value under the new key still counts as written rather than falling
    back to the legacy one — garbage under the new key means something wrote it, and
    resurrecting a stale session then would be worse than a blank slate. The legacy
    key is never written again and deliberately **not deleted** (deleting buys
    nothing, and keeping it lets a downgrade still restore); neither key may ever be
    renamed. `clear()` removes **both**, since otherwise clearing would migrate the
    pre-upgrade blob back in on the very next read. Everything that can go wrong
    reading resolves to "nothing stored" rather than trapping (`try?` — a missing
    key, a wrong-typed value, a truncated or hand-edited plist), since there is
    nothing better to do with a corrupt catalog than start blank and a launch is
    where a trap would be least recoverable; forward compatibility *inside* a
    well-formed blob is `SessionTab`'s job. An **empty session is an ordinary
    value** — stored, read back and returned like any other, never conflated with
    "nothing stored", so a user who closed every tab and quit comes back to an empty
    editor rather than to the session before last. Unit-tested in
    `EditorSessionTests`.
  - `ScopedFileAccess.swift` — pure, Foundation-only iOS security-scoped-access
    helpers (the `FileIcon`/`SettingsStore` move-the-testable-math-into-Core
    precedent). `FolderBookmark` (`Codable`/`Equatable`: standardized `path`
    identity + the opaque security-scoped `bookmark` blob, created/resolved in the
    iOS view layer — Core only stores/orders/returns it) plus two pure functions:
    `updatedRecents(_:remembering:max:)` (insert at front, dedup by `path`,
    most-recent-first, capped at `maxRecentFolders` = 20; a negative `max` disables
    the cap) and `path(_:isWithin:)` (trailing-slash-normalized same-or-descendant
    check the iOS `SecurityScopedFileService` decorator uses to find the covering
    scope, and the macOS `TreeRefreshFilter` uses for both its root-containment and
    its `.git` rule — where the normalization is what keeps `.gitignore`/`.github`
    from matching `.git`). Also `BookmarkStore` (`ObservableObject`, injected `UserDefaults`,
    mirroring `SettingsStore`): persists the recents list as one property-list blob
    under the stable `bookmarks.recentFolders` key — `folders()` (empty on an
    undecodable blob), `bookmark(forPath:)`, `rememberFolder(...)`,
    `forgetFolder(...)`. Covered by `ScopedFileAccessTests`/`BookmarkStoreTests`.
  - `TabLayout.swift` — pure, SwiftUI-free decision for the iOS open-tabs
    presentation (the `BottomPanel.toggled` precedent):
    `presentation(isCompactWidth:orientation:) -> Presentation` returns `.switcher`
    for compact width regardless of orientation, else `.horizontalStrip`/
    `.verticalColumn` per `TabOrientation`. Covered by `TabLayoutTests`.
  - `LicenseNotice.swift` — the third-party-license domain behind the
    Acknowledgements screens: `LicenseNotice` (one shipped dependency — `id`,
    `name`, `origin`, `version`, `revision`, `spdx`, `file`, plus `originURL` —
    the one behavioral decision on the type: `origin` as something to open, `nil`
    unless it is `https://`, so neither Acknowledgements screen has to repeat the
    rule and an `http://`, `file://` or `javascript:` origin out of a malformed
    manifest never becomes a tap target), `LicenseExclusion`
    (a `Package.resolved` identity deliberately *not* acknowledged, with the
    reason), `LicenseManifest` (the decoded `licenses.json`: `notices` +
    `excluded`), `LicenseDocument` (a notice paired with its verbatim text — what
    the UI renders), the `LocalizedError`-conforming `LicenseCatalogError`, and
    the `LicenseCatalog` enum itself with `decode(manifest:)` /
    `resolve(manifest:texts:)`. See the "Third-party license catalog" section
    below for the contract, the invariants and the test guarantees.
  - `PisakaCore.swift` — package constants/version.

## Release-metadata resources

Files that ship inside the app bundle but have no Swift code behind them, so the
only thing standing between a typo and an App Store Connect rejection is a test.
They live under `Resources/` and are verified statically by
`ReleaseMetadataTests`, which reads them through `#filePath` with Foundation only
— the `VendoredGrammarQueryTests`/`DependencyPinTests` precedent — so the checks
run in `swift test` rather than needing an Xcode build.

  - `Resources/Info.plist` — a *partial* Info.plist carrying only the keys Xcode
    cannot generate: two that App Store Connect validation wants —
    `LSApplicationCategoryType` = `public.app-category.developer-tools` and
    `ITSAppUsesNonExemptEncryption` = Boolean `false` — and two Sparkle reads
    (below). `GENERATE_INFOPLIST_FILE` stays `YES` and `INFOPLIST_FILE`
    points here, so Xcode merges its generated per-destination keys and every
    `INFOPLIST_KEY_*` build setting *into* this file's contents — the built plist
    is the union, not a replacement. Two failure modes drive the tests: a
    category typo builds fine and is rejected at validation time, and
    `ITSAppUsesNonExemptEncryption` written as the *string* `"NO"` (what a
    stringifying build setting produces) survives `as? Bool` bridging while the
    export-compliance check ignores it, so every upload keeps asking the question
    the key exists to pre-answer — hence the assertion goes through
    `CFBooleanGetTypeID`, on the type and not just the truthiness. A third test
    pins the key *set* to exactly those four, keeping anything Xcode can generate
    out of the hand-written file. Release versioning
    (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` and the per-upload
    command-line build-number override) is documented in `docs/RELEASING.md`.

    **The two Sparkle keys** (`SUFeedURL`, `SUPublicEDKey`) are here rather than
    in `project.yml` for a mechanical reason: neither has an `INFOPLIST_KEY_*`
    equivalent, so `GENERATE_INFOPLIST_FILE` cannot produce them at all. They are
    also the release-metadata case where *nothing in this repository reads the
    value* — Sparkle reads them out of the built bundle at runtime, on an
    end user's machine — so a typo is invisible until an installed copy silently
    stops finding updates. Hence a test per key, each asserting the strongest
    property that is checkable without the network:

      - `testPartialInfoPlistCarriesAWellFormedSparkleFeedURL` — parses as a URL,
        scheme `https` (Sparkle 2 refuses a plain-HTTP feed unless the app opts
        out, which it does not), host `github.com`, last path component exactly
        `appcast.xml`. The feed is
        `…/releases/latest/download/appcast.xml` deliberately: GitHub's
        latest-download redirect resolves by *asset name*, so that one URL always
        points at the newest release's feed, whereas a per-release URL would be
        baked into the shipped binary and go stale the moment the next version
        exists. The last-component check is half of a cross-file invariant —
        `ReleaseWorkflowTests` asserts from the other side that the release
        workflow attaches the asset under exactly that name.
      - `testPartialInfoPlistCarriesAWellFormedSparklePublicKey` — the value is
        base64 decoding to exactly 32 bytes (an ed25519 public key). A key short
        by a character or two still base64-decodes, so the byte count is what
        catches a truncated paste.

    **The placeholder-key scheme (retired 2026-08-16), and what it can and
    cannot guarantee.** The committed `SUPublicEDKey` is now the **real** one;
    the placeholder it replaced was
    `UExBQ0VIT0xERVItUkVQTEFDRS1XSVRILVJFQUwtS1k=` — base64 of the ASCII
    `PLACEHOLDER-REPLACE-WITH-REAL-KY` — and was *structurally valid on purpose*
    so that `swift test` could assert the shape of whatever is in the file
    without the suite having to special-case it. That reasoning still governs
    what is assertable: asserting the key is the *right* one is structurally
    impossible here, because the matching private half exists only in the
    `SPARKLE_PRIVATE_EDDSA_KEY` repository secret, which nothing in `swift test`
    can reach. The two checks that do cover it live elsewhere and are named so
    the gap is not mistaken for coverage: the release workflow's preflight greps
    the placeholder string out of the plist and refuses to publish while it is
    there — kept permanently, as a revert guard, so no release can ship signed
    by a key installed copies do not trust — and the one-time manual end-to-end
    update pass in `docs/RELEASING.md`.

    Deliberately **absent**: `SUEnableAutomaticChecks` and
    `SUScheduledCheckInterval`. With neither key present Sparkle asks the user
    once, on first launch, whether it may check automatically — the wanted UX at
    no cost in machinery; either key would answer that on the user's behalf. The
    key-set test spells this out, so restoring one is a deliberate act.

    Both Sparkle keys also land in the **iOS** bundle — there is one partial
    plist and it is merged into both destinations — where nothing reads them:
    Sparkle links on macOS only (the `destinationFilters: [macOS]` dependency)
    and every line of `SoftwareUpdater.swift` is inside `#if os(macOS)`. That is
    the same deliberate spill `INFOPLIST_KEY_UILaunchScreen_Generation` and
    `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` already make in the other
    direction; two inert strings are cheaper than splitting the plist in two.
  - `Resources/PrivacyInfo.xcprivacy` — the privacy manifest. Declared in
    `project.yml` as a single-file resource (a plain file reference, not a folder
    reference, and not via the recursive `Sources/Pisaka` entry), which is what
    lands it at the top level of the built bundle's resources on both
    destinations — `Contents/Resources/` on macOS, the `.app` root on iOS — the
    only place App Store Connect's privacy-report aggregation looks. Contents:
    `NSPrivacyTracking` = `false`, `NSPrivacyTrackingDomains` and
    `NSPrivacyCollectedDataTypes` both empty (the app has no telemetry, and every
    network egress is either the user's own git remotes or a fetch they asked
    for — the LSP server downloads, LeetCode, and now Sparkle's update check;
    everything it stores is local), and exactly three `NSPrivacyAccessedAPITypes`
    entries. **Sparkle is the first *unattended* egress** — after the one-time
    first-launch consent it polls `github.com` on Sparkle's own schedule with no
    further user action — which is why the sentence above says "asked for" rather
    than "in response to a command". It is still not tracking: the request
    carries no identifier of ours, the response is a static appcast, and nothing
    is correlated with any other data, so `NSPrivacyTracking` = `false` and the
    empty `NSPrivacyTrackingDomains` stand.
    `ReleaseMetadataTests` asserts the accessed-API set by *set equality* on
    category/reason pairs, so an added, dropped or re-coded category fails the
    suite until the manifest and the audit below are reconciled.

    **Required-reason API audit.** The unit of audit is the **linked binary**,
    not `Sources/`: libgit2 and every tree-sitter grammar compile from C source
    *into* the app, and none of the 21 dependencies ships a
    `PrivacyInfo.xcprivacy` of its own (`find DerivedData/SourcePackages/checkouts
    -name '*.xcprivacy'` returns nothing — **but that path alone is now
    incomplete**: Sparkle is a SwiftPM `binaryTarget`, so it lands in
    `SourcePackages/artifacts/`, not `checkouts/`, and the `find` above would
    miss it. Scan both. Checked by hand: the shipped `Sparkle.framework` carries
    no `.xcprivacy` either; the build would surface one if it ever
    appeared, since every grammar's resource bundle is handed to *both*
    destinations' `ProcessInfoPlistFile` step as a `-scanforprivacyfile`
    argument — 16 bundles today, `TreeSitterRust_TreeSitterRust.bundle` among
    them), so their required-reason calls must be
    declared by this manifest. A `Sources/`-only grep misses them — that is how
    the boot-time entry below was originally missed. Re-run the audit as a grep
    over `Sources/` **plus** a symbol check on the built binary:

    ```sh
    nm -u DerivedData/Build/Products/Debug-iphoneos/Pisaka.app/Pisaka.debug.dylib \
      | grep -E '_(stat|lstat|fstat|fstatat|statfs|statvfs|fstatfs|getattrlist|getattrlistat|fgetattrlist|getattrlistbulk|mach_absolute_time|sysctl)$'
    ```

    **Check the right binary, or the audit silently passes.** The path above is a
    *Debug* build: Xcode's debug-dylib packaging puts the app's code (and the
    statically linked C of libgit2 and the grammars) in `Pisaka.debug.dylib`,
    leaving `Pisaka.app/Pisaka` a launch stub whose undefined symbols are none of
    the above. In a Release or archive build there is no debug dylib and the
    symbols are in the main executable instead — `Pisaka.app/Pisaka` on iOS,
    `Pisaka.app/Contents/MacOS/Pisaka` on macOS. Running the grep against the
    wrong one of that pair returns *nothing*, which reads exactly like "no
    required-reason APIs are used" — the conclusion this record exists to prevent.
    Confirm the file you scanned is non-trivial (`nm -u` on it should list
    hundreds of symbols) before believing an empty match.

    **Last re-run: 2026-08-15**, after linking Sparkle — a newly linked
    dependency, which this file's own convention says obliges a re-run. Sparkle
    is the case the recipe above structurally **cannot** see, and that is the
    lesson worth keeping: it is not compiled into the app binary at all but
    linked as its own dynamic framework in `Contents/Frameworks/`, so its calls
    never appear in an `nm -u` of the executable — the exact "one level down"
    trap already flagged for a grammar that linked as its own framework, except
    here it is the real shape rather than a hypothetical. So the scan must cover
    the embedded frameworks too:

    ```sh
    nm -u Pisaka.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle \
      | grep -E '_(stat|lstat|fstat|fstatat|statfs|statvfs|fstatfs|getattrlist|getattrlistat|fgetattrlist|getattrlistbulk|mach_absolute_time|sysctl)$'
    ```

    Run over a Release build (222 undefined symbols in the framework, 2039 in
    `Contents/MacOS/Pisaka`), it answers **`_statfs` and `_mach_absolute_time`**.
    The main executable answered the familiar `_stat`, `_lstat`, `_fstat`,
    `_mach_absolute_time`.

    `_statfs` is a **disk-space** required-reason symbol, and the record below
    says disk space is "no hits … not declared". That entry stays as written and
    `PrivacyInfo.xcprivacy` is **unchanged** — not because the symbol is absent
    but because required-reason declarations are an iOS/iPadOS/tvOS/watchOS/
    visionOS obligation, and Sparkle is the one dependency carrying
    `destinationFilters: [macOS]`: it is genuinely not in the iOS binary, so it
    contributes nothing to the manifest that has to answer for it. **This is the
    one conclusion in this record that depends on a build setting rather than on
    a symbol**, so it has to be re-derived rather than assumed if that filter is
    ever dropped — an unfiltered Sparkle would put `_statfs` in an iOS binary and
    make the disk-space category owed. `ReleaseMetadataTests`' set equality still
    passes.

    **The same framework has a "one level down" trap on the *signing* side, and
    it is the release workflow's problem rather than this manifest's.** As shipped
    from the `binaryTarget`, `Sparkle.framework` is not one binary but five:
    `Versions/B/Sparkle` plus four nested helper bundles — `Versions/B/Autoupdate`,
    `Versions/B/Updater.app` and the two XPC services `XPCServices/Downloader.xpc`
    and `XPCServices/Installer.xpc` — each arriving with upstream's **ad-hoc**
    signature (`flags=0x10002(adhoc,runtime)`, no team identifier, no secure
    timestamp). Xcode's archive re-signs the framework *bundle* with the release
    identity and does not recurse into those four, so they reach the notary
    service exactly as upstream signed them; that is what got `v1.0` rejected.
    `.github/workflows/release.yml` therefore runs an explicit, inside-out
    re-sign pass between the archive and the verification, and its verification
    reads the Developer ID facts back off *every* Mach-O in the app rather than
    off the two bundles. A Sparkle version bump that moves any of those four paths
    must re-derive both lists by hand — `docs/RELEASING.md`'s "Upgrading Sparkle"
    carries the recipe and the reasoning, and `ReleaseWorkflowTests` pins it.

    **Previous re-run: 2026-08-10**, over both destinations' Debug dylibs
    (`Debug-iphoneos/Pisaka.app/Pisaka.debug.dylib`, 2184 undefined symbols, and
    `Debug/Pisaka.app/Contents/MacOS/Pisaka.debug.dylib`, 2308), after adding the
    `tree-sitter-rust` grammar — the Rust language work's one change to what is
    *linked* (rust-analyzer is neither linked nor bundled; it arrives over the
    network or not at all), and so the reason a re-run was owed: a grammar is C
    compiled into the app, exactly the half a `Sources/` grep cannot see. Both
    binaries answered the same four symbols the record below already explains —
    `_stat`, `_lstat`, `_fstat`, `_mach_absolute_time` — with no disk-space and
    no keyboard symbol, so `PrivacyInfo.xcprivacy` is unchanged and
    `ReleaseMetadataTests`' set equality still passes. That the new grammar was
    really inside what was scanned is confirmed rather than assumed: `nm` finds
    `_tree_sitter_rust` **defined** (`T`) in both, beside the grammars that were
    there before — the same "check the right binary" trap one level down, since a
    grammar that had linked as its own dynamic framework would keep its C calls
    out of this grep.

    This grammar earns a second confirmation the others did not need, and it is
    the one the iOS device build exists to make: all five
    `_tree_sitter_rust_external_scanner_*` symbols are **defined** in both
    binaries too. `tree-sitter-rust`'s manifest lists `src/scanner.c` in its
    `sources:`, which is why nothing is vendored for it — and the
    `TreeSitterDotenv` failure mode is precisely a manifest that omits that line,
    compiles cleanly, and leaves those five undefined until the consuming app
    links. Reading upstream's manifest predicts the answer; the link *is* it.

    The `Sources/` half turned up no new *category*, and one call site that has
    since become a family, because the next reader will meet it and wonder:
    `FileManager.isExecutableFile(atPath:)`. It was `LSPGoToolchainService`'s
    `go`/`gopls` discovery probe alone; there are now also `LSPToolchain`'s and
    `LSPRustToolchainService`'s probes, `LSPArchiveUnpacker`'s check on what it
    just gunzipped, and — the first time this question is asked from *Core* —
    `FileServicing.isExecutableFile(at:)`, which `LSPInstallEngine` puts between
    a `.gzip` unpack and its commit rename. Every one of them asks a
    *permission* question and reads no timestamp, and none is one of the
    file-timestamp APIs Apple's list names, so the family adds nothing to
    declare — the five timestamp call sites below are still all of them.

    A later audit should be a diff against this record, not a rediscovery:

      - `UserDefaults` — **used**, so
        `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` (access is limited
        to the app itself; there is no app group). Three call sites, all
        Foundation-only Core stores with the defaults injected:
        `SettingsStore` (preferences), `BookmarkStore` (the iOS
        security-scoped-bookmark recents) and `SessionStore` (the restored editor
        session), plus the `SessionController` writer in the app layer.
      - File timestamps (`lstat`/`stat`/`getattrlist`/`creationDate`/
        `modificationDate`/`attributesOfItem`) — **used**, so
        `NSPrivacyAccessedAPICategoryFileTimestamp` / **`3B52.1`**: timestamps of
        files and directories the *user specifically granted access to*, via the
        macOS open panel or the iOS document picker. Five real call sites. Four
        are `lstat`-into-a-`stat` existence/identity probes:
        `GitCLIService.swift:627` (same-inode comparison),
        `GitCLIService.swift:787` and `LibGit2Service.swift:914` (does anything,
        including a dangling symlink, occupy this path), and
        `GitCLIService.swift:1186` (the file's git mode). The fifth is the symbol
        index's change gate, `FileService.fileStamp(at:)`, which reads
        `(.size, .modificationDate)` through one `FileManager.attributesOfItem`
        call per walked file on every index refresh — the first call site that
        reads a timestamp *value* rather than merely probing existence, and the
        reason this bullet lists `attributesOfItem`/`modificationDate` above.
        The remaining `lstat`
        hits in `Sources/` are prose in comments. `3B52.1`, **not `DDA9.1`**:
        `DDA9.1` is for displaying a file timestamp to the user, and this app
        never does — the dates in the blame column come from git's own
        `--porcelain` output, parsed by `BlameLine`, never from `stat`.
      - System boot time (`systemUptime`/`mach_absolute_time`/`sysctl`) — no
        hits in `Sources/`, but **used by a linked dependency**, so
        `NSPrivacyAccessedAPICategorySystemBootTime` / **`35F9.1`**: libgit2's
        `git_time_monotonic` (`src/util/util.h`, the `__APPLE__` branch) calls
        `mach_absolute_time()`, reached from `rand.c`, `pack-objects.c` and
        `transports/smart_protocol.c`, and `_mach_absolute_time` is an undefined
        symbol of both built binaries. `35F9.1` is the elapsed-time-within-the-app
        reason, which is exactly what a monotonic clock for progress throttling
        and seed mixing is; nothing derived from it leaves the device. Not
        `8FFB.1` (absolute timestamps for UIKit/AVFAudio events) and not `3D61.1`
        (bug reports) — the app has neither.
      - Disk space (`statfs`/`volumeAvailableCapacity`/`systemFreeSize`/
        `volumeTotalCapacity`) — **no hits** in `Sources/` and no matching symbol
        in either binary, not declared. `FileService`'s
        `.fileSizeKey` probe (the oversize-file guard) and `fileStamp(at:)`'s
        `.size` read are *per-file* sizes, which
        are not on Apple's disk-space list; `.isDirectoryKey`,
        `.fileResourceIdentifierKey` and
        `.volumeSupportsCaseSensitiveNamesKey` are likewise not required-reason
        APIs.
      - Active keyboard (`activeInputModes`/`UITextInputMode`) — **no hits** in
        `Sources/` and no matching symbol in either binary, not declared.

  - `Resources/Licenses/` — `licenses.json` plus one verbatim `<id>.txt` per
    shipped dependency (21 today). Declared in `project.yml` as a **folder
    reference** (`type: folder`), so the whole directory is copied into the
    bundle as `Licenses/` and adding a future text needs no project
    regeneration. That convenience is exactly why the directory's *contents* are
    unchecked by the build — nothing in Xcode knows which dependencies those
    files correspond to — so the list of record is the manifest, and
    `LicenseCoverageTests` is what keeps it honest (next section).

One release-metadata requirement is not a file at all but a single build
setting, and it is asserted here for the same reason: **`project.yml`'s
`INFOPLIST_KEY_UILaunchScreen_Generation: YES`**, which makes Xcode generate the
empty `UILaunchScreen` dictionary in the iOS plist. Apple has required a launch
screen of every app built against the iOS 13+ SDK since April 2020; a SwiftUI
`@main` app ships no storyboard and `GENERATE_INFOPLIST_FILE` does not add the
key by itself, so without this setting the app builds and runs — letterboxed in
compatibility mode, with no iPad multitasking — and is rejected only at App Store
Connect validation. One base setting covers both destinations, so the key also
lands in the macOS plist, where AppKit never reads it (the same harmless spill as
`INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace`).

### The macOS runpath, and the one gate that can see it

A second build setting is pinned here, for a sharper version of the same reason:
**`LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]`** in `project.yml`'s
`targets.Pisaka.settings.base`, `$(inherited)` plus
`"@executable_path/../Frameworks"`. Nothing in this repository dereferences it —
not the compiler, not the linker, not `swift test`, not CI's build. The *shipped
app* dereferences it, once, in dyld, before any of our code runs.

XcodeGen's preset is `$(inherited)` plus `@executable_path/Frameworks`, applied
unconditionally and therefore to both destinations. That is the iOS layout, where
the executable sits at the bundle root; on macOS the executable is in
`Contents/MacOS/` and the frameworks in `Contents/Frameworks/`, so the entry has
to climb one level. The wrong default survived from the first commit to the
published `v1.0`, which **aborted at launch** with `Library not loaded:
@rpath/Sparkle.framework/Versions/B/Sparkle`, having searched
`Contents/MacOS/Frameworks/` — the preset resolving against the macOS layout.
Sparkle is the project's first *embedded dynamic framework* (everything else
links statically into the executable), so it is the first thing ever to resolve
through this setting. The whole incident is in `docs/RELEASING.md`.

Four decisions in that one line, each measured rather than assumed:

  - **A `[sdk=macosx*]` condition rather than a rewritten unconditional value**,
    so iOS keeps the preset untouched — confirmed by rebuilding
    `generic/platform=iOS` and re-reading its `LC_RPATH` set (`@executable_path`,
    the `PackageFrameworks` entry, `@executable_path/Frameworks`), which is
    unchanged. XcodeGen passes the bracketed key through verbatim into both the
    Debug and Release target configurations; it needs no XcodeGen feature beyond
    "emit what you were given".
  - **`$(inherited)` picks up the target's own unconditional entry**, not just a
    project-level one. Xcode layers the conditional assignment on top of the
    *same-level* unconditional one, so the macOS product carries both
    `@executable_path/Frameworks` (dead — it resolves to nothing) and
    `@executable_path/../Frameworks` (the one that works). Dropping `$(inherited)`
    would prune the dead entry and is deliberately not done: it would also drop
    whatever a future project-level or xcconfig value contributes, to buy a
    shorter `otool` listing.
  - **`/usr/lib/swift` is not this setting's to preserve.** The Swift toolchain
    emits that `LC_RPATH` itself, so overriding the search paths cannot lose it —
    read back with `otool -l` on the Release product rather than reasoned about.
  - **`ReleaseMetadataTests.testProjectPinsTheMacOSRunpath` pins the three
    lines**, matched consecutively over the comment-stripped `project.yml`.
    Deleting them leaves every build green, both destinations linking, and every
    byte-level release check passing; only a launch can tell.

That last point is the general one. Every other gate in this repository is
byte-level — `swift test` compiles Core and reads repository files, CI builds the
app, the release workflow reads signatures, plist keys and a notary verdict back
off the archive — and a dynamic-link failure is invisible to all of them. So the
two workflows that build the shipping configuration now **run the product**:
`ci.yml`'s macOS job launches the DerivedData Release app, and `release.yml`
launches the archived app after the re-sign and before the notary submission.
Both use the same script (identical apart from `APP=`, which
`ReleaseWorkflowTests` asserts): background-launch, poll with `kill -0` for five
seconds, kill it. Being killed is the pass; the process going away on its own is
a refusal whatever its status, `0` included.

**Known limit: there is no iOS runtime equivalent.** CI runs no simulator by
design — the iOS job builds `generic/platform=iOS` and boots nothing — so the iOS
product's dynamic loading is checked by nothing. The setting above is
macOS-conditional precisely so iOS keeps a preset that is correct for it, but the
class of failure is unguarded on that destination and is recorded rather than
designed around.

## Third-party license catalog

`LicenseNotice.swift` is the domain half of license compliance: the app must
acknowledge every third-party dependency it links, with the *verbatim* text
(copyright lines and permission notice included — those are the obligation), and
neither the compiler nor App Store validation will say a word if one goes
missing. The design puts every decision in Core, where `swift test` can reach it.

**The catalog takes bytes, not a `Bundle`.** `LicenseCatalog.resolve(manifest:
texts:)` receives the manifest `Data` and a `[file name: text]` dictionary; it
has no idea where either came from. Two reasons: Core is Foundation-only and must
stay portable and UI-free, and every failure mode becomes reachable from an
in-memory fixture instead of requiring a deliberately-broken app bundle. The
reading is the app layer's job (`Platform/LicenseCatalogLoader.swift`, documented
in `app-shell.md`).

**What `decode`/`resolve` reject**, each because the alternative is a silent
compliance failure rather than a visible bug:

  - `malformedManifest(reason:)` — not the JSON shape `LicenseManifest`
    describes. `excluded` is the one optional key (decoded via
    `decodeIfPresent` → `[]`), so a manifest with nothing to exclude may omit it.
  - `emptyManifest` — decoded but lists nothing. The app links plenty, so an
    empty list is a truncated or wrong file, never an app without dependencies.
  - `duplicateIdentifier(_:)` — two notices share an id, so one would be
    unreachable in an `Identifiable`/keyed context.
  - `missingText(id:file:)` — a notice names a text the caller did not supply:
    the license did not make it into the bundle.
  - `emptyText(id:file:)` — the text is blank or whitespace-only, which
    acknowledges nothing.

`LicenseCatalogError` is a `LocalizedError` on purpose: a broken bundle has to
*say* what is wrong, because "no dependencies" is a plausible-looking empty
screen. Manifest order is preserved rather than sorted — `licenses.json` lists
dependencies in `project.yml` order, which keeps the tree-sitter family together;
a UI that wants alphabetical can sort, but the reverse is not recoverable.
`version` is optional (`nil` for Neon and SwiftTreeSitter, both revision-pinned
past their newest tags, and for the vendored gitignore grammar, which has no
upstream release), so the UI omits the row instead of rendering a blank one;
`revision` is always present, since the exact commit is what makes a shipped text
verifiable rather than merely plausible.

**The coverage invariant.** `LicenseCoverageTests` is the guard against the one
failure this design cannot express in code — a dependency added to `project.yml`
whose license nobody copied. It covers what the app *ships*; a second, runtime
source of `LicenseDocument`s exists for the language servers a user chooses to
download, is read out of the installed tree rather than the bundle, and is
deliberately outside this invariant — see `LSPInstalledLicenses` in
`core-provisioning.md`. In the `VendoredGrammarQueryTests` style it reads
repository files through `#filePath` (Foundation only; Core links no YAML parser
and must not start, so `project.yml` is read by a deliberately tiny,
shape-specific line scanner) and asserts:

  - the manifest's id set **equals** the `Pisaka` target's linked package set
    from `project.yml` (minus `PisakaCore`) plus the documented transitive
    `tree-sitter` C runtime — *set* equality, so a new dependency fails the suite
    until its license is added, and a dropped one fails until its entry goes.
    **The set is destination-blind, deliberately, and Sparkle is the first entry
    where that shows.** `licenses.json` has no platform dimension and
    `Resources/Licenses/` is a folder reference copied to *both* destinations, so
    the iOS Acknowledgements screen lists Sparkle even though
    `destinationFilters: [macOS]` keeps it out of the iOS binary entirely (unlike
    SwiftTerm and libgit2, which link unused on the other destination and so are
    genuinely shipped there). That is over-attribution, not under-attribution:
    naming a component the binary does not contain is harmless where omitting one
    it does contain is the actual risk, and the alternative — a `platforms:` field
    threaded through `LicenseNotice`, `LicenseCatalog`, both Acknowledgements
    screens and this suite's scanner — buys nothing but a second way to
    under-attribute. Recorded rather than fixed, so the next filtered dependency
    inherits a decision instead of an accident;
  - the declared `packages:` set equals the linked `dependencies:` set, which
    doubles as proof the scanner is still reading something rather than comparing
    two empty sets (verified by mutation: adding a fake package + dependency does
    fail the suite);
  - every `Package.resolved` identity is either acknowledged or carries a
    non-empty `excluded` reason;
  - each remote entry's `revision` **equals** that identity's `Package.resolved`
    pin, so a text can never quietly come from upstream HEAD;
  - the `.txt` files on disk are exactly the manifest's set — the folder
    reference ships whatever is there, so a text left behind after a dependency
    is dropped would otherwise keep shipping;
  - each vendored entry names a real `Vendor/<name>/LICENSE` and is
    byte-identical to it;
  - each text names *its own* dependency's copyright holder, against a table
    (`expectedCopyrightHolders`) asserted by set equality against the manifest's
    ids. This is the only check that reads a *remote* text's bytes at all: every
    other assertion here is satisfied by any non-empty file, because the pin a
    text is compared against belongs to the manifest entry rather than to the
    file's contents. Copying the wrong `LICENSE` into a slot — an easy slip
    among sixteen near-identical MIT texts, where a name and a year are the only
    visible difference — would otherwise ship the wrong attribution with the
    whole suite green. The three `tree-sitter-html/-javascript/-json` texts are
    byte-identical upstream and so are indistinguishable from one another by any
    content check; they carry the same grant from the same holder, so that is
    not a gap;
  - `libgit2`'s text contains the `LINKING EXCEPTION` section (what permits
    linking GPLv2 code into a closed-source app);
  - the two texts that carry a *sub*-dependency notice still carry it (below);
  - and the real manifest resolves through `LicenseCatalog` itself, so this
    suite's own reader cannot pass a file the app would fail on.

**What the id-set check cannot see: sub-dependencies.** Every assertion above is
*package*-granular — it compares manifest ids against SwiftPM package identities.
Three packages carry third-party code of their own into the app; for two of them
the top-level `LICENSE`/`COPYING` does not cover it, and no package-level
comparison can notice:

  - **libgit2** compiles five vendored trees — its `Package.swift` `sources:`
    lists `deps/llhttp`, `deps/pcre`, `deps/xdiff`, `deps/zlib` and
    `deps/ntlmclient`, and nothing in `excludedPaths` removes any of them, so all
    five reach the binary. What `excludedPaths` *does* drop is the build-system
    and non-Apple-backend files: CMake/Windows/mbedTLS/OpenSSL, plus — inside the
    manifest's `#if os(macOS)` branch, which is where SwiftPM evaluates it for
    every Apple destination — the whole builtin hash layer
    (`src/util/hash/builtin.{c,h}`, `collisiondetect.{c,h}`, `rfc6234/`,
    `sha1dc/`) and `deps/ntlmclient/crypt_openssl.{c,h}`, because the app uses
    CommonCrypto instead. Note that this is the same fact the
    `ITSAppUsesNonExemptEncryption = false` rationale rests on, and that
    `deps/winhttp` is not in `sources:` at all: neither the bundled SHA1DC nor
    winhttp ever compiles into this app, so neither is part of the obligation.
    Upstream's `COPYING` enumerates every one of the five compiled trees *except*
    `deps/xdiff/` (LibXDiff by Davide Libenzi, LGPL-2.1-or-later), which is the
    appendix below. Its `spdx` therefore reads
    `LicenseRef-libgit2-GPL-2.0-only-with-linking-exception AND LGPL-2.1-or-later
    AND Zlib AND BSD-3-Clause AND MIT`: the LGPL operand is `deps/xdiff`, `Zlib`
    is `deps/zlib`, `BSD-3-Clause` is `deps/pcre`, and the `MIT` operand covers
    `deps/llhttp` and `deps/ntlmclient`.
    The expression enumerates what *compiles in*, not just what the top-level
    license says — the field is documented above as the app's obligation
    statement, so half-applying that rule (naming xdiff but not the other four)
    would make it read as complete while understating the obligation. The left
    operand is a `LicenseRef-` because libgit2's GPLv2-with-linking-exception has
    no SPDX List identifier and `WITH` takes only listed *exception* ids, so
    `GPL-2.0-only WITH linking-exception` would be an expression no SPDX parser
    accepts (`testEverySPDXExpressionIsWellFormed` pins that).

    Known limit: nothing derives this expression from the pinned checkout, so a
    libgit2 bump that adds or drops a vendored tree needs its `sources:` re-read
    by hand. `testEverySPDXExpressionIsWellFormed` checks only that every operand
    is a well-formed, known id.
  - **tree-sitter** compiles `lib/src/unicode/` (ICU-derived headers, reached via
    `lib/src/unicode.h`). Upstream ships the notice as `lib/src/unicode/LICENSE`
    and then `exclude:`s that file from the SwiftPM target, so it never reaches
    the bundle on its own. Its `spdx` reads `MIT AND Unicode-DFS-2016`.

  - **Sparkle** is the third, and the one where upstream already did the
    aggregating: its own `LICENSE` ends in an `EXTERNAL LICENSES` section
    covering the third-party sources it compiles into the framework — bsdiff
    (Colin Percival), sais-lite (Yuta Mori), the portable C implementation of
    ed25519 from `github.com/orlp/ed25519` (Orson Peters) and
    `SUSignatureVerifier.m` (Mark Hamlin). Four entries, and the third is
    ed25519 rather than pdqsort: Orson Peters wrote both, Sparkle vendors only
    the former, and the mistake is easy to make from the copyright line alone —
    which is precisely why this record names the file each notice covers rather
    than only its author. So unlike
    the two above there is **no appendix**: the verbatim copy already *is* the
    whole obligation, and the thing that has to be pinned is the opposite one —
    that the copy stays whole. A re-copy that grabbed only the MIT grant at the
    top of upstream's file, which reads like a complete licence on its own, would
    silently drop four attributions while every other check in the suite still
    passed (the text would be present, non-empty and would still name Andy
    Matuschak). `testTextsCarryTheirBundledSubDependencyNotices` asserts the
    `EXTERNAL LICENSES` heading and all four copyright holders for exactly that
    reason. Worth stating plainly, because "no appendix" and "nobody checked"
    look identical in the directory listing.

The first two are closed by **appending** the missing notice to the shipped `.txt`, the
way libgit2's own `COPYING` already aggregates its bundled deps — not by adding a
manifest entry, because a sub-dependency has no SwiftPM identity: no
`Package.resolved` pin for the provenance tests to check, no `- package:` line
for the coverage test to match. Each appendix opens with a line saying where
upstream's verbatim text ends and this repository's addition begins, and
`testTextsCarryTheirBundledSubDependencyNotices` pins both appendices — and,
for Sparkle, the upstream section that makes an appendix unnecessary — because
otherwise bumping the pin and pasting upstream's file over ours would drop them
in silence.

**Recording a read that found nothing.** The same check was run over
`tree-sitter-go` when it was added (pin `0.25.0`, revision `1547678a`): its
manifest compiles `src/parser.c` alone — the conditional `src/scanner.c` append
does not fire, because the grammar declares no external scanner — and the only
other thing under `src/` is tree-sitter's own `src/tree_sitter/` (`parser.h`,
`alloc.h`, `array.h`), the MIT headers every generated grammar in this repository
carries and that the `tree-sitter` entry already covers. So there is no second
license and no appendix, and `tree-sitter-go.txt` is upstream's `LICENSE`
verbatim. That is worth writing down rather than leaving implicit: an absent
appendix is indistinguishable from a read nobody performed, and the next grammar
addition should be able to see which of the two this was.

The general rule this leaves behind: **a package's own LICENSE is not
automatically the whole obligation.** When adding a dependency, read its
manifest's `sources:`/`exclude:` for vendored trees before assuming one text
covers it.

**The documented exclusion.** `swift-argument-parser` appears in
`Package.resolved` only because SwiftTerm's `Termcast` executable target depends
on it; it is not linked into the app, so no license ships for it. That is
recorded in the manifest's `excluded` array rather than left out, because "no
text for this one" is indistinguishable from an oversight unless the reason is
written down — and the coverage test requires *every* resolved identity to be one
or the other.
