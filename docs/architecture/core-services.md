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
    `python3`, `swift` → `swift`, `sh`/`bash` → `bash`), mirroring
    `FileIcon`/`SyntaxLanguage`'s extension-map pattern. `command(forFileName:
    absolutePath:) -> String?` looks up the file's extension (via
    `(fileName as NSString).pathExtension.lowercased()`) and, when known, returns
    the joined runner tokens plus the shell-quoted path (`nil` for an unknown/empty
    extension); `canRun(fileName:) -> Bool` reports whether the extension has a
    runner (drives the "Run" context-menu item and the ⌘R menu enablement);
    `workingDirectory(projectRoot:fileURL:) -> URL` returns `projectRoot ??
    fileURL.deletingLastPathComponent()`. Paths are shell-quoted via the shared
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
    already has. **Three deliberate limits, recorded on `EditorSession` itself.**
    (1) The contents of dirty *titled* files are **not** persisted, only their
    paths: their text has somewhere to live and autosave already puts it there —
    on quit `flushNow` writes every dirty titled buffer *before* the snapshot is
    taken (the ordering `PisakaApp` owns), and a crash loses at most one autosave
    window (~2 s), the exposure the editor already has; an Untitled buffer is the
    opposite case, skipped by autosave because it has nowhere to write, so the
    session is the only thing carrying its text across a restart. (2) Untitled text
    is **not size-capped** — if a pathologically large scratch buffer written on
    every debounce ever bites, move the blob to Application Support, which changes
    `SessionStore`'s backing store and not the model. (3) **One session under one
    key, with no per-window identity** — exact today rather than a limitation,
    since the app is single-window and its `WorkspaceModel` is one `@StateObject`
    on the `App` shared by every scene, so there is only ever one workspace state
    to snapshot; it becomes a limitation the moment genuinely independent windows
    exist (two would write under this one key, last writer winning, and merging
    their tabs would need an identity this model does not carry). `SessionStore` follows
    `BookmarkStore`'s shape exactly: injected `UserDefaults`, one property-list blob
    under the stable `Keys.lastSession` (`"session.lastSession"`, never renamed),
    `load()`/`save(_:)`/`clear()`. Everything that can go wrong reading resolves to
    `nil` rather than trapping (`try?` — a missing key, a wrong-typed value, a
    truncated or hand-edited plist), since there is nothing better to do with a
    corrupt session than start blank and a launch is where a trap would be least
    recoverable; forward compatibility *inside* a well-formed blob is `SessionTab`'s
    job. An **empty session is an ordinary value** — stored, read back and returned
    like any other, never conflated with "nothing stored", so a user who closed
    every tab and quit comes back to an empty editor rather than to the session
    before last. Unit-tested in `EditorSessionTests`.
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
  - `PisakaCore.swift` — package constants/version.

## Release-metadata resources

Files that ship inside the app bundle but have no Swift code behind them, so the
only thing standing between a typo and an App Store Connect rejection is a test.
They live under `Resources/` and are verified statically by
`ReleaseMetadataTests`, which reads them through `#filePath` with Foundation only
— the `VendoredGrammarQueryTests`/`DependencyPinTests` precedent — so the checks
run in `swift test` rather than needing an Xcode build.

  - `Resources/Info.plist` — a *partial* Info.plist carrying only the two keys
    App Store Connect validation wants: `LSApplicationCategoryType` =
    `public.app-category.developer-tools` and `ITSAppUsesNonExemptEncryption` =
    Boolean `false`. `GENERATE_INFOPLIST_FILE` stays `YES` and `INFOPLIST_FILE`
    points here, so Xcode merges its generated per-destination keys and every
    `INFOPLIST_KEY_*` build setting *into* this file's contents — the built plist
    is the union, not a replacement. Two failure modes drive the tests: a
    category typo builds fine and is rejected at validation time, and
    `ITSAppUsesNonExemptEncryption` written as the *string* `"NO"` (what a
    stringifying build setting produces) survives `as? Bool` bridging while the
    export-compliance check ignores it, so every upload keeps asking the question
    the key exists to pre-answer — hence the assertion goes through
    `CFBooleanGetTypeID`, on the type and not just the truthiness. A third test
    pins the key *set* to exactly those two, keeping anything Xcode can generate
    out of the hand-written file. Release versioning
    (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` and the per-upload
    command-line build-number override) is documented in `docs/RELEASING.md`.
  - `Resources/PrivacyInfo.xcprivacy` — the privacy manifest. Declared in
    `project.yml` as a single-file resource (a plain file reference, not a folder
    reference, and not via the recursive `Sources/Pisaka` entry), which is what
    lands it at the top level of the built bundle's resources on both
    destinations — `Contents/Resources/` on macOS, the `.app` root on iOS — the
    only place App Store Connect's privacy-report aggregation looks. Contents:
    `NSPrivacyTracking` = `false`, `NSPrivacyTrackingDomains` and
    `NSPrivacyCollectedDataTypes` both empty (the app has no telemetry and no
    network egress other than the user's own git remotes; everything it stores is
    local), and exactly two `NSPrivacyAccessedAPITypes` entries.
    `ReleaseMetadataTests` asserts the accessed-API set by *set equality* on
    category/reason pairs, so an added, dropped or re-coded category fails the
    suite until the manifest and the audit below are reconciled.

    **Required-reason API audit** (re-run over `Sources/`; a later audit should
    be a diff against this record, not a rediscovery):

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
        macOS open panel or the iOS document picker. Four real call sites, all
        `lstat`-into-a-`stat` existence/identity probes:
        `GitCLIService.swift:627` (same-inode comparison),
        `GitCLIService.swift:787` and `LibGit2Service.swift:914` (does anything,
        including a dangling symlink, occupy this path), and
        `GitCLIService.swift:1186` (the file's git mode). The remaining `lstat`
        hits in `Sources/` are prose in comments. `3B52.1`, **not `DDA9.1`**:
        `DDA9.1` is for displaying a file timestamp to the user, and this app
        never does — the dates in the blame column come from git's own
        `--porcelain` output, parsed by `BlameLine`, never from `stat`.
      - System boot time (`systemUptime`/`mach_absolute_time`/`sysctl`) — **no
        hits**, not declared.
      - Disk space (`statfs`/`volumeAvailableCapacity`/`systemFreeSize`/
        `volumeTotalCapacity`) — **no hits**, not declared. `FileService`'s
        `.fileSizeKey` probe (the oversize-file guard) is a *per-file* size, which
        is not on Apple's disk-space list; `.isDirectoryKey`,
        `.fileResourceIdentifierKey` and
        `.volumeSupportsCaseSensitiveNamesKey` are likewise not required-reason
        APIs.
      - Active keyboard (`activeInputModes`/`UITextInputMode`) — **no hits**, not
        declared.
