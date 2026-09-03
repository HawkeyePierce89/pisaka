# Pisaka

A native code editor for **macOS** (iPad and iPhone versions coming soon):
a project file tree on the left, a vertical list of open files in the middle,
and the editor on the right. Every feature below is one line; the full,
edge-case-level description of each — and of what it deliberately does *not*
do — is in [`docs/FEATURES.md`](docs/FEATURES.md).

## Features

- **Language servers, one click from zero to working** — Swift via Xcode's
  `sourcekit-lsp`, TypeScript/JavaScript, Python and YAML via servers the app
  offers to download once (checksum-pinned, removable in Preferences), Go via
  `gopls` and Rust via `rust-analyzer`. Errors and warnings appear as you
  type — wavy underlines, gutter markers, a Problems panel — plus hover
  types, precise Go to Definition and project-wide **Rename** (Ctrl+Cmd+R);
  every language falls back to the built-in index silently, no alerts ever.
- **Code intelligence with no setup at all** — a project-wide symbol index
  built from the tree-sitter parse trees powers Go to Definition (Cmd+click /
  Ctrl+Cmd+J) and fuzzy/camelCase completion with kind badges, even when no
  language server is installed.
- **Find Usages** (Ctrl+Cmd+U) — every place a name is used, in a bottom-dock
  panel; a language server answers where there is one, and a whole-word scan of
  the project answers where there is not — the panel says which of the two it is
  showing, always.
- **LeetCode built in** — sign in through LeetCode's own login page, open a
  problem by number/slug/URL or browse and filter the whole catalog, get a
  solution file seeded with the official snippet, read the statement in a
  themed pane beside the editor, and **Run / Submit the editor buffer** with
  full verdicts inline.
- **A real git client** — Local Changes with side-by-side diffs and multi-file
  revert, a commit dialog with per-line selection and amend, a 3-pane
  merge-conflict resolver, a Git Log with branch graph and filters, a branch
  switcher, and git blame in the editor gutter. All through your own `git`.
- **GitHub pull requests (macOS)** — a Pull Requests panel in the bottom dock
  (Cmd+Shift+R) listing this repository's open pull requests with author,
  `head → base`, draft and review state and a live checks summary; expand a row
  for its per-job checks and their links, check one out, or open it in the
  browser. **New Pull Request** pushes the branch first (publishing it if it has
  no upstream), then opens the pull request into the base it named. An indicator
  beside the branch switcher shows `#N` and the checks state for the branch you
  are on. All through your own `gh` — Pisaka holds no token and never talks to
  GitHub itself; if `gh` is missing, too old or signed out, the panel says so and
  prints the one command that fixes it.
- **Embedded terminal** — multiple shell tabs themed with the app; **Run
  File** (Cmd+R) and **Run Test** (Cmd+U) reuse dedicated tabs, with the test
  runner detected from the project's config files.
- **Zoom in three independent zones** — code, terminal and interface each
  keep their own scale, and the zone under the pointer is the one that
  responds: Cmd+= / Cmd+− / Cmd+0, Ctrl- or Cmd-scroll, and trackpad pinch.
- **Autosave & sessions** — automatic saving (idle, tab switch, focus loss,
  quit) and per-project session restore, including hot exit for "Untitled"
  buffers.
- **Local History** — every save, and every file one of the app's eight
  worktree-rewriting operations (including Rename and a pull request checkout)
  is about to overwrite, is snapshotted locally; browse a file's revisions, diff
  them against what it holds now and restore one (Cmd+Shift+H). 14 days or 30
  revisions per file, independent of git.
- **Database viewer (macOS)** — open a `.sqlite`, `.sqlite3` or `.db` file from
  the project tree and get a tab that lists its tables and views, shows the
  selected one's schema, and pages through its rows with click-to-sort headers.
  **Cells are editable in place**: double-click (or press Return on a cell), type,
  and Return writes one row inside a transaction that only commits if the row is
  still the one you were looking at; "Set to NULL" is in the cell's menu, because
  typing the word stores the word. Views, generated columns, blob cells and
  tables with no row identity are not editable and say why. Under the grid is a
  **SQL console**: type statements, press Cmd+Return, and anything that only
  reads runs straight away (capped at 500 rows, nothing appended to your SQL),
  while anything that can change the database asks first — the confirmation says
  how many statements write and that they run as one transaction — and reports
  what it changed. Every failure SQLite reported carries its own words.
- **EditorConfig** — a project's `.editorconfig` drives auto-indent and the
  Tab key, and applies `trim_trailing_whitespace`, `insert_final_newline`
  and `end_of_line` on save.
- **Editor** — line numbers, auto-indent, auto-closing brackets/quotes,
  matched-pair and rainbow bracket highlighting, Cmd+D duplicate, Cmd+/
  toggle comment, middle-mouse column selection, a minimap, and per-tab
  caret/scroll memory.
- **Syntax highlighting** (tree-sitter via Neon) for Swift, JavaScript,
  TypeScript, JSON, Markdown, Python, Go, Rust, HTML, CSS, YAML, SQL,
  Dockerfiles, `.env`, `.editorconfig` and dot-prefixed ignore files.
- **Find & replace** — an in-file search bar (regex, whole word, match case)
  and a project-wide **Find in Files** window that honors your `.gitignore`
  and can Replace All across the project.
- **Projects** — open a folder (Cmd+Shift+O), create/rename/move/delete right
  in the tree, or switch between recent projects from the bottom bar; external
  changes show up on their own via FSEvents. If you attempt to switch to a
  recent project folder that has been deleted or moved, Pisaka will display a
  warning alert and leave your current workspace unchanged.
- **Automatic updates** via Sparkle — consent asked once, every download
  verified; **Check for Updates…** is always in the app menu.
- **Preferences** — theme, tab orientation, fonts, completion on/off, the
  language-server and LeetCode screens, and an Acknowledgements tab with
  every dependency's license.

## Install

Requires macOS 13+. The git features use your own `git` CLI; the language
servers are optional — Xcode unlocks Swift, a Go/Rust toolchain unlocks
`gopls`/`rust-analyzer`, and TypeScript/JavaScript, Python and YAML come as
one-time downloads you explicitly accept.

- Download the zip from [GitHub Releases](../../releases), unzip, drag
  `Pisaka.app` to `/Applications`, open. The app is signed and notarized, so
  the first launch is the ordinary "downloaded from the Internet"
  confirmation — nothing else.
- Or with Homebrew: `brew install --cask HawkeyePierce89/apps/pisaka`.

Updates install themselves afterwards. Nothing phones home besides the update
check (consent asked once, nothing about you or your projects is sent);
git remotes, server downloads and LeetCode touch the network only when you
use them — the one exception, stated in its consent prompt, is the YAML
server fetching JSON schemas while it runs.

## Keyboard Shortcuts

| Shortcut    | Action                                     |
| ----------- | ------------------------------------------ |
| Cmd+N       | New file (an "Untitled" tab)               |
| Cmd+O       | Open a file from disk                      |
| Cmd+Shift+O | Open a folder as a project                 |
| Cmd+S       | Save                                       |
| Cmd+W       | Close the active tab                       |
| Cmd+D       | Duplicate the current line or selection (Show Diff when Local Changes has focus) |
| Cmd+Down    | Jump to Source when Local Changes has focus |
| Cmd+/       | Toggle comment                             |
| Tab         | Insert one indentation level (commits the selected completion row when the popup is open) |
| Cmd+F       | Find in the current file                   |
| Cmd+G / Cmd+Shift+G | Find Next / Previous               |
| Cmd+Option+F| Replace in the current file                |
| Cmd+Shift+F | Find in Files (project-wide)               |
| Ctrl+Cmd+J  | Go to Definition (Cmd+click does the same) |
| Ctrl+Cmd+U  | Find Usages of the name under the caret    |
| Ctrl+Cmd+R  | Rename the symbol under the caret (needs a language server) |
| Middle-drag | Column (rectangular) selection; Option-drag too |
| Ctrl+Space  | Complete the word being typed              |
| Cmd+K       | Commit…                                    |
| Cmd+R       | Run the active file                        |
| Cmd+U       | Run the active test file                   |
| Cmd+Shift+P | Open a LeetCode problem                    |
| Cmd+Shift+B | Browse LeetCode problems                   |
| Cmd+Shift+L | Show/Hide the Git Log panel                |
| Cmd+Shift+T | Show/Hide the terminal panel               |
| Cmd+Shift+C | Show/Hide the Local Changes panel          |
| Cmd+Shift+M | Show/Hide the Problems panel               |
| Cmd+Shift+U | Show/Hide the Usages panel                 |
| Cmd+Shift+R | Show/Hide the Pull Requests panel          |
| Cmd+Shift+H | Local History for the active file          |
| Cmd+,       | Preferences                                |
| Cmd+= / Cmd+− / Cmd+0 | Zoom in / out / reset the zone under the pointer |
| Esc         | Close the search bar or the focused auxiliary window |

## Build & Run

From-source prerequisites: a Swift 6.0+ toolchain (Xcode 16+) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The app is built through an XcodeGen-generated Xcode project; there is no
SwiftPM executable target.

**After cloning, run `make setup` once** — it wires this clone's git hooks
and refuses if the pinned [SwiftLint](docs/architecture/style-lint.md) is
missing; commits that violate `.swiftlint.yml`, the style authority at the
repository root, are refused. `make` also wraps everything below:
`make test`, `make lint`, `make build`, `make build-ios`.

```sh
make setup             # one time per clone: hooks + linter check

xcodegen generate      # regenerate Pisaka.xcodeproj from project.yml
open Pisaka.xcodeproj  # build & run from Xcode

# Or from the command line:
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build

swift test             # run the domain-logic test suite (PisakaCore)
```

`swift test` builds and tests only the platform-agnostic `PisakaCore`
library — the fast, dependency-free gate for the domain logic. The macOS app
runs non-sandboxed so the standard open/save panels work without
entitlements.

## License

Pisaka is MIT-licensed — see [`LICENSE`](LICENSE).

The app links third-party dependencies and ships each one's verbatim license
text in `Resources/Licenses/`, shown in-app under **Preferences →
Acknowledgements**. libgit2 is used under GPL-2.0 with its linking exception
(its bundled `xdiff` code is LGPL-2.1). Adding a dependency means adding its
license there too — `swift test` fails until you do (`LicenseCoverageTests`).
