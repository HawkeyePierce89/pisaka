# Pisaka

A native code editor for **macOS**, ~~**iPad, and iPhone**~~ *(coming soon)*, sharing one
Foundation-only domain core (`PisakaCore`) across platforms. On macOS it uses a
three-column layout: a project file tree on the left, a vertical list of open
files (tabs) in the middle, and a text editor on the right. On iPad it adapts to
a `NavigationSplitView` (tree sidebar + editor detail); on iPhone it collapses
to a navigation stack.

Every feature below is described one line at a time; the full, edge-case-level
description of each — and of what it deliberately does *not* do — is in
[`docs/FEATURES.md`](docs/FEATURES.md).

## Features (macOS)

- **Projects** — open a folder as a project (Cmd+Shift+O) and browse it as a
  tree: create (with relative paths, `a/b/c.ts` in one step), rename, delete,
  and move by dragging a row onto a folder (or onto the project root); external
  changes (Finder, a console `git checkout`, the embedded terminal) show up on
  their own via FSEvents.
- **Editor** — NSTextView-based, monospaced, with a line-number gutter,
  auto-indent, auto-closing brackets/quotes, matched-pair and rainbow bracket
  highlighting, Cmd+D duplicate line/selection, a minimap, and per-tab position
  memory: switch away and back and the tab returns to the caret and scroll
  position you left it at (for the app run; not persisted across launches).
- **Syntax highlighting** (tree-sitter via Neon) for Swift, JavaScript,
  TypeScript, JSON, Markdown, Python, Go, Rust, HTML, CSS, YAML, SQL, Dockerfiles,
  `.env` and dot-prefixed ignore files — detected from the whole file name.
- **Find & replace** — an in-file search bar (regex, whole word,
  match case, Replace All as one undo step) and a project-wide **Find in
  Files** window that honors your `.gitignore` files and can Replace All across
  the project with per-file staleness checks.
- **Code intelligence** — a project-wide symbol index built from the tree-sitter
  parse trees powers Go to Definition (Cmd+click / Ctrl+Cmd+J) and
  fuzzy/camelCase autocompletion (with language keywords and, after a `.`,
  member completion) presented in a custom popup with kind badges. The first row is preselected on open; Enter inserts the selection, Tab replaces the whole identifier, Up/Down arrows navigate, Esc dismisses, and clicking a row commits it. A status-bar lightbulb (and a Preferences checkbox) turns
  completion off entirely.
- **Language servers**, all optional and macOS-only: Swift via Xcode's
  `sourcekit-lsp` (found through `xcrun`, nothing bundled); TypeScript/JavaScript,
  Python and YAML via servers the app *offers to download once* (checksum-pinned,
  installed under `~/Library/Application Support/Pisaka/`, removable in
  Preferences — the YAML one goes on fetching JSON schemas while it runs, which
  the download prompt says before you accept); Go via `gopls` (yours if you have it, otherwise built once with
  your own `go`); Rust via `rust-analyzer` (yours if you have it, otherwise the
  official binary downloaded once — a `cargo` is required either way). Every
  language falls back to the built-in index silently — no alerts, ever. Where a
  server is available, resting the pointer on a symbol also shows its
  type/signature in a small popover (macOS only; there is no popover without a
  server, since the index knows names, not types).
- **Git** — Local Changes with side-by-side diffs and multi-file revert; a
  commit dialog with per-line selection, amend, author editing and
  optional push; a 3-pane merge-conflict resolver; a Git Log with a branch
  graph, filters and per-commit diffs; a branch switcher with checkout, DWIM
  remote checkout and fetch-first branch creation; and a git-blame column in the
  editor gutter. All through your own `git` CLI.
- **Terminal** — an embedded SwiftTerm panel with multiple shell tabs, themed
  with the app; **Run File** (Cmd+R) and **Run Test** (Cmd+U) reuse dedicated
  terminal tabs, with the test runner detected from the project's config files.
- **Autosave & sessions** — automatic saving (idle, tab switch, focus
  loss, quit), and **per-project** session restore: each project folder keeps its
  own tabs and selection, brought back when you open it again and on launch,
  including hot exit for "Untitled" buffers.
- **Automatic updates** via Sparkle 2 — release builds check GitHub, ask once
  for consent, verify every download against a baked-in EdDSA key; **Check for
  Updates…** is always in the app menu. DEBUG builds have no updater at all.
- **LeetCode integration** — sign in through LeetCode's own login page, open a
  problem by number/slug/URL (Cmd+Shift+P) or browse and filter the whole
  problem list (Cmd+Shift+B), get a solution file seeded with the official
  snippet (never overwritten), read the statement in a themed pane beside the
  editor, and **Run / Submit the editor buffer** with full verdicts inline.
- **Zoom in three independent zones** — code, terminal and interface, with the
  one under the pointer the one that grows: Cmd+= / Cmd+− / Cmd+0, Ctrl- or
  Cmd-scroll, and trackpad pinch. Each is stored separately, so resetting one
  leaves the other two alone (details in `docs/FEATURES.md`).
- **Preferences** — tab orientation, theme, shared editor font size, terminal
  font size, completion on/off, the language-server and LeetCode screens,
  and an Acknowledgements tab with every dependency's verbatim license.

## iOS / iPadOS

The same `PisakaCore` logic drives an adaptive SwiftUI/UIKit app: the document
picker with security-scoped bookmarks for file access, a `UITextView` editor
with the same highlighting/indent/auto-pair engines and pinch-to-zoom, the same
index-based Go to Definition (edit menu) and completion (a QuickType-style strip
above the keyboard), and the same git features **in-process via libgit2** (no
`git` binary): Local Changes, diffs, revert, Git Log with graph, 3-pane conflict
resolution, and the branch switcher — with HTTPS-only fetch using per-host
Personal Access Tokens from the Keychain. The LeetCode integration is there in
full, with solution files defaulting to the app's `Documents` (visible in the
Files app). No terminal, no language servers, no commit dialog — details in
[`docs/FEATURES.md`](docs/FEATURES.md).

## Requirements

- macOS 13+ and/or iOS/iPadOS 17+; Swift 6.0+ toolchain (Xcode 16+).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project
  (`brew install xcodegen`).
- Contributing: [SwiftLint 0.65.0](#style-lint-swiftlint) — commits are
  refused without it, deliberately with no graceful degradation.
- macOS: the `git` CLI on your `PATH` for the git features (iOS uses libgit2
  in-process). Optional, each unlocking its language's semantic intelligence:
  Xcode (Swift), a Go toolchain (`gopls`), a Rust toolchain (`rust-analyzer`),
  and a one-time download you explicitly accept (TypeScript/JavaScript, Python,
  YAML).
- Optional: a LeetCode account for the LeetCode integration.
- Network: a release build's only self-initiated request is Sparkle's update
  check against `github.com` (consent asked once, nothing about you or your
  projects is sent). Everything else that touches the network — git remotes,
  the server downloads, LeetCode — happens only when you use it. One thing keeps
  going after its download: the YAML language server, once installed, looks a
  document's JSON schema up while you edit — a catalog from `schemastore.org`,
  then the schema from whatever host that catalog — or the file itself, in a
  `# yaml-language-server: $schema=` line or a top-level `$schema:` key — names. It is the one unpinned request
  Pisaka's own code does not make, and it is stated in the consent prompt.

## Build & Run

The app is built through an XcodeGen-generated Xcode project (a single
multiplatform target with macOS and iOS destinations); there is no SwiftPM
executable target.

```sh
xcodegen generate      # regenerate Pisaka.xcodeproj from project.yml
open Pisaka.xcodeproj  # build & run from Xcode (pick the macOS or an iOS destination)

# Or from the command line:
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

swift test             # run the domain-logic test suite (PisakaCore, all platforms)
```

`swift test` builds and tests only the platform-agnostic `PisakaCore` library —
the fast, dependency-free gate for the domain logic. The macOS app runs
non-sandboxed so the standard open/save panels work without entitlements.

### Style lint (SwiftLint)

Style is enforced with [SwiftLint](https://github.com/realm/SwiftLint),
pinned at **0.65.0** in [`.swiftlint.yml`](.swiftlint.yml) — that file is the
single style authority, and every relaxation in it carries its reason.
One-time contributor setup:

```sh
# The pinned release is the reliable route — brew's formula can be a different
# version, and only 0.65.0 passes the gate:
curl -fsSL --retry 3 -o swiftlint.zip \
  https://github.com/realm/SwiftLint/releases/download/0.65.0/portable_swiftlint.zip
unzip -o swiftlint.zip && rm swiftlint.zip
install -m 755 swiftlint /usr/local/bin/   # or any directory on your PATH

brew install swiftlint    # alternative; whatever it serves, the check below decides
swiftlint version         # MUST print 0.65.0 — any other binary is refused
git config core.hooksPath .githooks
```

From then on every commit lints exactly what is being committed (`--strict`)
and refuses violations instead of fixing them. CI runs the same check on every
pull request, so a bypassed or forgotten hook only defers the failure.

## Installing a released build

Download the zip from [GitHub Releases](../../releases), unzip it, drag
`Pisaka.app` to `/Applications` and open it. That is the whole procedure: the
app is signed with a Developer ID Application certificate, notarized by Apple
and stapled, so the first launch is the ordinary "downloaded from the Internet"
confirmation — the one that says Apple checked it for malicious software, with
an Open button — and nothing else. No blocked launch, no trip through System
Settings, no terminal command. macOS 13 or later.

Or with Homebrew: `brew install --cask HawkeyePierce89/apps/pisaka`. The cask is
bumped by the release workflow itself — version and checksum of the exact zip it
just uploaded — so it tracks GitHub Releases rather than trailing them.

Updates afterwards install themselves through Sparkle, which verifies each one
against the EdDSA key baked into the copy you are running — an integrity chain
independent of Apple's signature.

## Releasing

Pushing a `vX.Y` tag builds and publishes the release:
`.github/workflows/release.yml` re-runs `swift test`, archives the macOS app
signed with a Developer ID Application certificate and the hardened runtime,
launches the signed app as a smoke test so a build that cannot start never
reaches the notary queue, notarizes and staples it, signs the update with
Sparkle's EdDSA key and attaches
the app zip plus `appcast.xml` to a new GitHub Release. It then bumps `version`
and `sha256` in the Homebrew cask (`HawkeyePierce89/homebrew-apps`,
`Casks/pisaka.rb`) to the zip it just uploaded, so `brew install --cask pisaka`
follows the release; that step runs after the release leaves draft and is fatal
like every other, so a failure there leaves the release live and only the tap
stale, with a manual two-line recovery. It refuses up front if
the tag and `MARKETING_VERSION` disagree, or if any signing, notarization or
distribution secret is missing, so bump and commit the version *before* tagging.
The build number comes from `github.run_number` and is never committed. The
whole path — the seven repository secrets, the throwaway signing keychain,
certificate renewal and what is still account-side — is documented in
[`docs/RELEASING.md`](docs/RELEASING.md).

## Continuous Integration

GitHub Actions (`.github/workflows/ci.yml`) runs on every pull request and every
push to `master`: first `swift test`, then — only once tests are green — an
unsigned macOS build and an unsigned iOS build (device arch, including libgit2
linking) in parallel. A fourth, independent `lint` job runs alongside them from
the start: the pinned SwiftLint 0.65.0 (digest-verified download) over the whole
first-party tree with `--strict` — the same check the pre-commit hook enforces
locally, so a pull request that fails style is refused even when the hook was
bypassed. No signing, secrets, or simulator are involved. The macOS
build uses the Release configuration and the iOS build Debug, so both
configurations are compiled on every PR — the auto-updater exists only in
non-DEBUG builds and would otherwise never be compiled until a release. The
macOS job then *launches* what it built and requires the process to still be
alive five seconds later: the only gate here that executes the product, and the
only kind that can see a dynamic-link failure. There is no iOS equivalent, for
want of a simulator.

The release workflow above is the one place that *does* use secrets (the Sparkle
private signing key, the Developer ID certificate and its password, the three
App Store Connect API key values notarization needs, and — the one that is not
signing material — an SSH deploy key whose write access is scoped to the
Homebrew tap alone) and the one place that signs; it runs only on a `v*` tag,
never on a pull request.

## Keyboard Shortcuts (macOS)

| Shortcut    | Action                                     |
| ----------- | ------------------------------------------ |
| Cmd+N       | New file (creates an "Untitled" tab)       |
| Cmd+O       | Open an existing file from disk            |
| Cmd+Shift+O | Open a folder as a project                 |
| Cmd+S       | Save (prompts with Save As for "Untitled") |
| Cmd+W       | Close the active tab (confirms if unsaved) |
| Cmd+D       | Duplicate the current line (or the selection), with the editor focused |
| Cmd+F       | Find in the current file (opens the search bar; a repeat press re-focuses it) |
| Cmd+G       | Find Next (while the search bar is open)   |
| Cmd+Shift+G | Find Previous (while the search bar is open) |
| Cmd+Option+F| Replace in the current file (opens the bar with the replace row) |
| Cmd+Shift+F | Find in Files (project-wide search window) |
| Ctrl+Cmd+J  | Go to Definition of the identifier at the caret (Cmd+click does the same for the identifier under the pointer) |
| Ctrl+Space  | Complete the word being typed, or the members after a `.` (AppKit's stock Option+Esc and F5 work too) |
| Cmd+K       | Commit… (opens the commit dialog for the open project) |
| Cmd+R       | Run the active file in a new terminal session |
| Cmd+U       | Run the active test file in a new terminal session |
| Cmd+Shift+P | Open a LeetCode problem (writes and opens its solution file) |
| Cmd+Shift+B | Browse LeetCode problems (search and filter the problem list) |
| Cmd+Shift+L | Show/Hide the Git Log (commit history) bottom panel |
| Cmd+Shift+T | Show/Hide the embedded terminal bottom panel |
| Cmd+Shift+C | Show/Hide the Local Changes bottom panel   |
| Cmd+,       | Open Preferences                           |
| Cmd+= / Cmd+− / Cmd+0 | Zoom in / out / reset the zone under the pointer (code, terminal, or interface) |
| Cmd+ or Ctrl+scroll, pinch | The same zoom, by gesture |
| Esc         | Close the search bar, or the focused diff / merge / Find in Files / LeetCode Problems / source viewer window |

## Known Limitations (1.0)

The headline items; the complete list, with the reasoning per item, is in
[`docs/FEATURES.md`](docs/FEATURES.md#known-limitations-10-in-detail).

- Much of the surface is macOS-only: find/replace and Find in Files, the commit
  dialog, git blame, the terminal, Run File/Run Test, the path bar, session
  restore, every language server, and automatic updates. iOS covers the editor,
  the index-based intelligence, the libgit2-backed git essentials, and LeetCode.
- Language servers answer Go to Definition, completion and hover types only — no
  diagnostics, rename or Find Usages — and their versions are pinned in the app
  (the YAML server's *schemas* are not: those arrive from the network as you
  edit).
  The hover popover is macOS-only, cannot be scrolled or selected (long answers
  are cut), and has no keyboard trigger. The index fallback matches *names*: no
  scope, type inference, reach into dependencies outside the opened folder — and
  no hover at all.
- The commit dialog has no staging-area interop (a manual `git add` is unstaged
  afterwards); finishing a merge/rebase/cherry-pick stays a console job.
- One editor window; no split views and no tab reordering. The project tree's
  drag and drop moves one entry at a time within the tree — nothing is dragged
  between the tree and Finder, and a drop never copies. External file changes
  refresh the macOS project tree only — open tabs and the git panels refresh on
  demand.
- Automatic updates have no settings of ours (Sparkle's own consent prompt and
  update alert are the whole UI), and the single EdDSA signing key is
  unrecoverable if lost.
- LeetCode rides the site's **unofficial** API, so it can break with no notice
  (surfaced as an "API changed" error, fixed only by an app update). No
  submission history; solved/attempted marks are as fresh as the catalog's last
  refresh; premium problems your account cannot read are refused on open. On
  iOS the solution folder makes the app's `Documents` visible in the Files app.

## License

Pisaka is MIT-licensed — see [`LICENSE`](LICENSE).

The app links third-party dependencies and ships each one's verbatim license
text in `Resources/Licenses/` (alongside `licenses.json`, the manifest that is
the list of record). They are shown in-app under **Preferences →
Acknowledgements** on macOS and **Settings → About → Acknowledgements** on iOS.
libgit2 is used under GPL-2.0 with its linking exception (its bundled `xdiff`
code is LGPL-2.1). Adding a dependency means adding its license there too —
`swift test` fails until you do (`LicenseCoverageTests`).

Downloadable language servers ship inside nothing, so their notices are read out
of the installed tree and appear in Acknowledgements only while installed.
`gopls` (BSD-3-Clause, built by your own `go`) and `rust-analyzer`
(`Apache-2.0 OR MIT`, a single downloaded binary) carry no license file to read;
their rows in **Preferences → Language Servers** name each origin and license.
