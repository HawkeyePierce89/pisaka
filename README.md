# Pisaka

A native code editor for **macOS, iPad, and iPhone**, sharing one
Foundation-only domain core (`PisakaCore`) across platforms. On macOS it uses a
three-column layout: a project file tree on the left, a vertical list of open
files (tabs) in the middle, and a simple text editor on the right. On iPad it
adapts to a `NavigationSplitView` (tree sidebar + editor detail); on iPhone it
collapses to a navigation stack. You can open a folder as a project and browse
it as a tree, create new files (macOS), open existing ones, switch between them,
edit, save (with Save As for new files), see an unsaved-changes indicator, and
close files with a confirmation prompt when there are unsaved changes.

## Requirements

- macOS 13 or later, and/or iOS/iPadOS 17 or later
- Swift 6.0+ toolchain (Xcode 16+ or the matching command-line tools). The
  syntax-highlighting dependency (ChimeHQ's Neon) ships a `swift-tools-version:
  6.0` manifest, so an older toolchain can't resolve the package.
- [XcodeGen](https://github.com/yonbergman/xcodegen) to generate the Xcode
  project from `project.yml` (`brew install xcodegen`).
- macOS only: the `git` command-line tool on your `PATH` (the macOS Local
  Changes / Git Log views, the branch switcher and the gutter's Annotate column
  all shell out to it via `GitCLIService`). Without it, the Changes/Log panels
  show an error and the Annotate column stays silently empty; the rest of the
  editor works normally. On iOS git access is in-process via libgit2 (no `git`
  binary needed).
- macOS, optional: Xcode, for the semantic Swift intelligence. `sourcekit-lsp` is
  located with `xcrun --find` in the active toolchain (so `xcode-select` and
  `DEVELOPER_DIR` decide which one), and nothing is bundled or downloaded. Without
  Xcode, Swift files behave exactly as every other language does — Go to Definition
  and completion answer from the tree-sitter symbol index, silently.
- macOS, optional: an internet connection *once*, if you accept the offer to
  download a TypeScript/JavaScript or Python language server (see Features). No
  Node, `npm` or Python installation of your own is required or used; nothing is
  downloaded unless you ask for it, and declining leaves those languages on the
  built-in index.
- macOS, optional: a **Go toolchain**, for the semantic Go intelligence. Unlike
  the two servers above, `gopls` has no official prebuilt binaries — so Pisaka
  uses the one you already have if it can find it, and otherwise offers to build
  it once with *your* `go`. Without a Go toolchain there is no offer and no
  server: Go files behave exactly as every other language does, on the built-in
  index.
- macOS, optional: a **Rust toolchain**, for the semantic Rust intelligence.
  `rust-analyzer` shells out to `cargo` to understand your project, so a
  toolchain is required *however* the server is acquired — Pisaka uses the
  `rust-analyzer` you already have if it can find one (rustup puts it in
  `~/.cargo/bin`), and otherwise offers once to download the official prebuilt
  binary. Without a `cargo` there is no offer and no server: Rust files behave
  exactly as every other language does, on the built-in index.
- Optional: a **LeetCode account** and network access to `leetcode.com`, for the
  LeetCode integration (see Features). Nothing is bundled and no dependency is
  added for it — the login web view is WebKit and the session is stored through
  the system Keychain. Without an account the feature is simply unused; the rest
  of the editor is unaffected.

## Build & Run

The app is built through an XcodeGen-generated Xcode project (a single
multiplatform target with macOS and iOS destinations). `swift run Pisaka` is
gone — there is no longer a SwiftPM executable target.

```sh
xcodegen generate     # regenerate Pisaka.xcodeproj from project.yml
open Pisaka.xcodeproj  # build & run from Xcode (pick the macOS or an iOS destination)

# Or from the command line:
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

swift test            # run the domain-logic test suite (PisakaCore, all platforms)
```

`swift test` builds and tests only the platform-agnostic `PisakaCore` library —
the fast, dependency-free gate for the domain logic. The macOS app runs
non-sandboxed so the standard open/save panels work without entitlements; the
iOS app uses the document picker with security-scoped bookmarks for file access.

## Releasing

The release version (`MARKETING_VERSION` in `project.yml`, currently `1.0`) is
committed per release. The build number (`CURRENT_PROJECT_VERSION`) deliberately
is **not**: it stays at `1` in the working tree and each upload overrides it on
the `xcodebuild archive` command line, so `git status` stays clean across
re-uploads. Both, plus what is still account-side (signing, notarization, the
App Store Connect records), are documented in [`docs/RELEASING.md`](docs/RELEASING.md).

## Continuous Integration

GitHub Actions (`.github/workflows/ci.yml`) runs on every pull request and every
push to `master`: first `swift test` (the PisakaCore gate), then — only once
tests are green — an unsigned macOS build and an unsigned iOS build (device arch,
including libgit2 linking) in parallel. No signing, secrets, or simulator are
involved.

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
| Cmd+scroll  | Adjust the editor font size over any code view |
| Esc         | Close the search bar, or the focused diff / merge / Find in Files / LeetCode Problems / source viewer window |

## Features

- Open a folder as a project ("Open Folder…", Cmd+Shift+O) and browse it in a
  project tree on the left; directories expand on demand and clicking a file
  opens it in a tab. When the project pane is empty, clicking anywhere in it
  opens the folder picker. Opening a folder auto-expands its first level so the
  immediate children are visible right away. Each entry shows a file-type icon
  (tinted by type) so Swift, JS/TS, JSON, Markdown, images, archives, and other
  common types are recognizable at a glance. Dotfiles are visible (VS Code-style),
  so `.gitignore` and `.github` are ordinary entries you can open, rename, and
  delete; only the service entries `.git` and `.DS_Store` are hidden (and cannot
  be created or renamed to from the tree — a create path refuses them in any
  casing, since a case-insensitive volume would resolve `.GIT` onto the real
  `.git`). Entries are sorted directories-first,
  then alphabetically. Right-click a row for a context menu: directories offer New
  File…, New Folder…, Rename…, and Delete; files offer Rename… and Delete, plus a
  "Run" item for runnable file types and a "Run Test" item for test files; the
  project root offers the two create actions. New File… and New Folder… accept a
  *relative path*, not just a name (VS Code-style): entering
  `centrifugo/config.json` creates the `centrifugo` folder and the file inside it
  in one step. Missing intermediate folders are created and existing ones reused,
  a single trailing slash is fine (`a/b/c/`), but the final entry is never
  overwritten — and if something on the path already exists as a *file*, nothing
  is created and the alert names it (`"centrifugo" already exists and is not a
  folder.`). If a later step fails, any intermediate folders already created stay
  on disk (as with `mkdir -p`) and show up in the tree. The New File… / New
  Folder… / Rename… dialog shows the *whole* input: the field is wide and wraps
  onto as many lines as it needs (up to six), so a long pasted path stays visible
  instead of
  scrolling out of sight. It also validates as you type — the reason a name or
  path cannot be used appears in red under the field (an empty part of the path,
  a `.` or `..`, a line break pasted into a name, a reserved `.git`/`.DS_Store`, a
  slash in a rename, which takes a
  single name and not a path) and OK stays disabled until the input is valid.
  Empty input simply disables OK without complaining. Enter confirms when OK is
  enabled and does nothing otherwise, so it never inserts a line break. A new file opens in a tab, a rename
  retargets any open tab (a renamed folder follows all its nested tabs), and a
  delete closes the affected tabs; the tree refreshes in place without reopening
  the folder. On macOS it also keeps up with changes made *outside* the app: the
  opened folder is watched, so a file created in Finder, a branch checked out in a
  console, or a `npx @nestjs/cli new backend` run in the embedded terminal shows up
  on its own within a second or two. Purely internal `git` churn (a `git commit`
  writes only inside `.git`) is ignored, so the tree does not flicker. A Refresh
  button in the tree header is the manual counterpart — the watcher is the
  automatic path, the button is for when you want it right now (or on a network
  volume, where the watcher may not fire).
- Vertical tab list with active-tab highlight, an unsaved-changes dot, and a
  per-tab close button.
- NSTextView-based editor: monospaced font, undo/redo, copy/paste, and a
  line-number gutter on the left that tracks scrolling, edits, and the system
  light/dark appearance.
- Annotate with Git Blame (macOS): right-click the editor gutter and choose
  "Annotate with Git Blame" to show a column to the left of the line numbers with,
  per line, who last changed it and when. Right-click again ("Close Annotations")
  to hide it and the gutter returns to its previous width. The toggle is per tab,
  so each open file remembers its own state; lines that are not committed yet, and
  lines git had nothing to say about, are left blank. The column follows the editor
  font (it resizes with Cmd+scroll and the Preferences font size) and refreshes
  itself whenever the file on disk changes — after a save or autosave, a Save As, a
  revert, a branch checkout, or renaming the file. Committing from the embedded
  terminal is the one change it does not notice on its own: the file did not move,
  so the just-committed lines keep showing as uncommitted until you switch tabs
  away and back, or toggle the column off and on. It reflects the
  **saved** file, so while you have unsaved edits it can be off by a line or two
  until autosave catches up (a couple of seconds of idle, a tab switch, or clicking
  away), after which it re-aligns on its own. A file outside a git repository, or
  an unsaved "Untitled" buffer, simply has nothing to annotate — the menu item is
  unavailable or the column stays empty, with no error.
- A VS Code-style path bar above the editor shows where the open file lives —
  its path relative to the opened project root, as breadcrumbs
  (`backend › src › dialogs › dialogs.service.ts`). A file outside the project
  (or with no folder open) shows its absolute path, abbreviated to `~` under your
  home directory, and an "Untitled" buffer just says "Untitled". In a narrow
  window the path truncates in the middle so the file name stays visible, and the
  bar keeps a fixed height so the editor never jumps. It appears with either tab
  orientation (in the horizontal layout it sits under the tab strip) and is hidden
  when no file is open. The segments are display-only for now — they are not
  clickable, there is no copy-path action, and the bar is macOS-only (no iOS
  version yet).
- Auto-indent: pressing Enter inherits the current line's indentation, adds one
  indent step after an opening bracket (`{`/`(`/`[`), and splits a freshly
  indented line between a bracket pair; typing a closing bracket (`}`/`)`/`]`)
  on a blank line dedents it to match its opener. The indent unit (tabs or
  spaces) is inferred from the file, defaulting to four spaces. Each auto-indent
  is a single undo step.
- Auto-closing brackets and quotes: typing an opener (`(`, `[`, `{`) or quote
  (`"`, `'`, `` ` ``) inserts its closer with the caret in between; typing the
  matching closer over an auto-inserted one steps past it instead of doubling;
  Backspace on an empty pair (`(|)`) deletes both characters; and typing an
  opener or quote with a selection wraps the selection. An opener directly before
  a word (or an apostrophe completing a word, like `don'`) is left as-is rather
  than stranding a closer. Each auto-pair edit is a single undo step. (Pairing is
  a simple character heuristic with no string/comment awareness.)
- Bracket highlighting, in two flavors at once. Put the caret next to a bracket
  and both halves of its pair get a background (VS Code/Xcode style); the
  bracket *after* the caret wins when there is one on each side, a selection
  shows nothing, and moving the caret away clears it. Separately, every bracket
  in the file is colored by its nesting depth through a cycling five-color
  palette (JetBrains Rainbow Brackets style) — depth 5 starts the palette over —
  and a bracket that has no match, or one that closes the wrong kind, is painted
  red. Both follow the system light/dark appearance and the Preferences theme,
  and neither touches the document, so undo never contains a "highlighting edit".
  Matching is a raw character scan with no string/comment awareness, so a bracket
  inside a string literal or a comment is highlighted like any other (a
  tree-sitter-aware version is a follow-up). macOS only for now — no iOS variant
  and no settings to turn it off or change the number of colors yet.
- Duplicate line or selection (Cmd+D), JetBrains-style: with no selection the
  caret's line is copied below it and the caret moves into the copy at the same
  column; with a selection the selected text is copied right after itself and the
  copy becomes the new selection, so repeated presses grow the text. A multi-line
  selection is duplicated exactly as selected rather than rounded out to whole
  lines, and each duplication is a single undo step. In a CRLF- or CR-delimited
  file, duplicating the *last* line — the one with no line terminator — inserts a
  plain LF; every terminated line copies its own terminator verbatim. It is an
  editor-only key with no menu item yet, so it does nothing while focus is in the
  terminal or the project tree. macOS only for now — an iOS
  variant for an external keyboard and an Edit > Duplicate Line menu item are
  out of scope.
- Find and replace in a file (macOS): Cmd+F opens a JetBrains-style search bar
  above the editor with `Aa` (match case), `ab` (whole word), and `.*` (regular
  expression) toggles, a `3/17` match counter, and ▲/▼ to step through the
  matches — Cmd+G and Cmd+Shift+G do the same from the keyboard, wrapping around
  the ends. Every match is highlighted in the text and the current one gets its
  own color, coexisting with the rainbow brackets and the matched-pair highlight
  rather than replacing them. The search runs as you type, with no delay. A
  regular expression that doesn't compile shows its reason in red in the bar (no
  alert) and simply blanks the counter, so a half-typed pattern is not an error.
  A pattern of only spaces counts as an empty field even in regular-expression
  mode, so search for spaces with `\s`, `[ ]` or `\x20`.
  In a regular-expression search `^` and `$` are **line** boundaries, as in
  VS Code and JetBrains — `^import` finds every import line, not just one at the
  top of the file — while `.` still stops at a line break; the same holds in the
  Find in Files window, which shares the engine.
  Cmd+Option+F (or the bar's expand button) adds the replace row: `Replace` swaps
  the current match and moves to the next, `Replace All` rewrites the whole file
  as a **single undo step** (one Cmd+Z puts it back). In a regular-expression
  search the replacement understands `$0`/`$1` group references; in a literal
  search it is inserted verbatim, so replacing text *with* a `$1` needs no
  escaping. Whole-word works with regular expressions too — it judges the found
  match's own edges, so `\w+` matches whole words while `oo` inside `foo` is
  filtered out. Esc closes the bar and clears the highlight, and a repeated Cmd+F
  re-focuses the field with its text selected — closing it also clears the
  search, so Cmd+G and Cmd+Shift+G do nothing until you reopen the bar. The bar's
  pattern and toggles survive switching tabs. All five commands also live in a
  Find menu (Find…, Replace…, Find Next, Find Previous, Find in Files…), where
  the first four need an open file. There is no query history and no "replace in
  selection" yet, and the bar is macOS-only.
- Find in Files (macOS): Cmd+Shift+F (or Find > Find in Files…, which needs an
  open folder since the search *is* a walk of the project) opens a separate,
  non-modal project-wide
  search window (a repeat press focuses the one already open). It has the same
  `Aa`/`ab`/`.*` toggles plus a file mask (`*.ts,*.tsx`, case-sensitive — `*.TS`
  will not match `foo.ts`), and lists matches
  grouped by file with a preview line per match. The traversal honors your
  `.gitignore` files — the root's and every nested one, with negation and
  directory rules as git applies them — so a JS project's `node_modules` is
  skipped without configuring anything; `.git` and `.DS_Store` are always skipped,
  as are binary files, files over 1 MB, and symlinked directories. A file you have
  open is searched by its *unsaved* buffer, so results match what you see. The
  search is debounced (~300 ms) since each keystroke walks the whole project, and
  a new query supersedes one still running. Results cap at 10 000 matches with a
  note saying so. Click a result to open the file at that match (Enter in the
  query field opens the first one) — the window stays open. Replace All rewrites every match across the project after
  a confirmation naming the file and match counts: files with an open tab are
  replaced *in the buffer*, so your own unsaved edits to those tabs are kept
  (autosave then writes them like any other edit); everything else is written
  straight to disk. Nothing is applied
  blind — each file is re-read and re-checked immediately before its write, and one
  that changed since the results were captured is skipped and reported rather than
  clobbered (that includes an open tab you kept typing into while the batch ran);
  a file that can't be written is reported too, and neither stops the
  rest of the batch. If you open a different folder while a Replace All is being
  confirmed or is still running, the batch stops rather than continuing into the
  new project: whatever was already written stands, the report says the folder
  changed, and the rest is left untouched. Afterwards the summary is shown and the
  search re-runs.
- Go to Definition: Cmd+click an identifier — or put the caret in it and press
  Ctrl+Cmd+J (Find > Go to Definition) — to jump to where it is declared, in this
  file or anywhere in the open project (for Swift on macOS it reaches beyond it,
  into dependencies and the SDK — see below). The caret lands on the declaration's
  *name*, the file is opened (or its tab re-selected) as needed, and when several
  declarations share the name a small menu at the click point lists them as
  `Container.name — path/to/file.swift:42`, with the current file's first. A name
  nothing declares just beeps. Cmd+drag still selects text, and Cmd+Shift+click /
  Cmd+Option+click keep their usual meaning.
- Autocompletion: as you type an identifier (from the second character), a popup
  offers the project's declarations, the keywords of the language you are typing
  in, and the words already in the buffer. Matching is **fuzzy/camelCase**, not
  just literal: `arrBuf`, `aBu` and `buf` all reach `ArrayBuffer`, as long as the
  first character you type starts a word in the name — its first letter, a
  camelCase hump, the character after a `_`/`-`, or either side of a
  digit/letter transition (`base64Encoder` is reachable by `b`, `6` and `E`),
  counting the first eight such starts. Ranking puts the
  best match first — an exact-case prefix, then a prefix ignoring case, then a
  fuzzy match, preferring the ones that land on word boundaries and stay tight —
  then the current file's names, then real declarations before keywords before
  plain words, then shorter names. Keywords are offered for Swift, JavaScript,
  TypeScript, Python, Go (the 25 reserved words plus the predeclared names no
  file can declare — `nil`, `error`, `len`, `make`, …), Rust (the 38 strict
  keywords plus the primitive type names `i32`, `usize`, `f64`, `bool`, `str`, …,
  which likewise no crate declares) and Dockerfile (`FROM`,
  `HEALTHCHECK`, … in the uppercase
  they are written in); the data formats, Markdown and `.gitignore` deliberately
  have no list, and HTML/CSS are left out until completion knows about position.
  Type a `.` after an identifier or a closing bracket and the list opens right
  there with that receiver's members — methods, properties and constants that
  belong to a type — with the members of the type you actually named
  (`Worker.`) ranked above everyone else's. Arrow keys or the
  mouse choose, Return inserts, Esc dismisses, and the insertion is a single undo
  step. Ctrl+Space (Find > Complete) asks for the list explicitly, from the first
  character, and works after a dot too. Nothing pops up mid-composition with an
  input method.
  Both features are backed by a project-wide symbol index built from the same
  tree-sitter parse trees that drive the syntax highlighting — no network, and
  (except for Swift on macOS, below) no language server either. It is built when
  you open a folder, refreshed when files change
  on disk (only the files whose size or modification date actually moved get
  re-parsed), and kept current for the file you are typing in, so a name you just
  wrote is completable before it is saved. Declarations are indexed for Swift,
  JavaScript, TypeScript, Python, Go (types, interface and struct members,
  functions, methods — a pointer receiver `func (w *Worker)` indexes under
  `Worker` — and top-level `const`/`var`, but not locals inside a function) and
  Rust (structs, enums, unions, traits and type aliases; struct fields; enum
  variants; free functions, including those in an inline `mod`; the methods of an
  `impl` or a trait, filed under the type they are implemented *for* — so
  `impl Display for Worker` puts `fmt` under `Worker`, and `impl<T> Holder<T>`
  puts its methods under `Holder` — and top-level `const`/`static`, but not
  locals inside a function);
  Markdown headings, CSS selectors, top-level
  YAML/JSON keys, Dockerfile build stages, `.env` variables and HTML `id`s are
  indexed too. A file type with no query still completes from the words in the
  buffer.
- Semantic code intelligence for **Swift** (macOS): when Xcode is installed, Swift
  files are answered by `sourcekit-lsp` — found through `xcrun` in the active
  toolchain, started on demand for the project you opened, and never bundled or
  downloaded. Go to Definition becomes a real, compiler-backed jump: across modules
  of a package, into a dependency, and into the SDK. A declaration that lives
  *outside* the opened folder — an SDK interface, a dependency checkout — opens in a
  separate **read-only** window (syntax-highlighted, with the same line-number
  gutter — no blame column — and Cmd+scroll zoom, one window per file) rather
  than as an editable tab, so a jump
  into the SDK can never write outside your project. Completion becomes typed
  candidates in the compiler's own ranking, including real members after a `.`, and
  a symbol that needs an `import` inserts the import line together with the symbol —
  caret after the symbol, and a single Cmd+Z undoes both.
  All of this is silent and optional. Every other language keeps the index's
  answers; so does Swift on a machine with no Xcode, in a project the server cannot
  build, while the server is still starting, and if it crashes or hangs — the
  question is simply answered from the index instead, with no alert, no banner and
  no stall. Quitting the app stops every server it started.
- Semantic code intelligence for **TypeScript / JavaScript and Python** (macOS),
  if you want it. These servers are not bundled — the app offers to download them,
  once, the first time you open a file of that kind: a strip above the editor names
  the server and its size, with **Download** and **No Thanks** and nothing else.
  Nothing is fetched until you press Download, and nothing is fetched again if you
  don't.
  What arrives is `typescript-language-server` (with the `typescript` it drives)
  or `pyright`, plus one shared Node runtime the two of them use. The first
  acceptance is about **57 MB** (Node is most of it); the second server, whichever
  it is, costs about **4 MB** because the runtime is already there. The size the
  prompt shows is always what is still missing, not the total. Every file is
  checked against a checksum built into the app before it is unpacked, comes from
  `nodejs.org` or `registry.npmjs.org`, and is installed under
  `~/Library/Application Support/Pisaka/LanguageServers/` — nothing is put on your
  `PATH`, nothing global is touched, and no `npm` or Node installation of your own
  is used or needed. The install is atomic: an interrupted or corrupted download
  leaves nothing behind and the file keeps working exactly as before.
  Once it lands, that language becomes semantic **immediately** — no restart —
  with the same typed completion, real members and cross-file jumps Swift gets
  above. **Preferences → Language Servers** shows each server's state and offers
  Install, Retry and Remove; removing one stops its process at once and the
  language falls straight back to the built-in index. **Removing also answers
  "no"** — the banner will not offer that language again, and reinstalling is a
  button on that same screen. Disk comes back the same way it was spent: removing
  one of two servers frees only its own few MB, because the ~52 MB Node runtime
  they share goes away with the *last* one. Declining is remembered
  across launches and is turned around from that same screen. To de-provision
  everything by hand, quit the app and delete the `LanguageServers` folder above.
  That folder — and the Remove button — cover **what Pisaka installed**: a `gopls`
  of your own in `~/go/bin` is used from where it is, so deleting the folder does
  not touch it and no Remove button is offered for it.
  Acknowledgements (Preferences) grows a *Language Servers* section listing what is
  installed and its verbatim licenses, and loses it again when you remove them.
- Semantic code intelligence for **Go** (macOS), through `gopls` — the same Go to
  Definition and completion Swift gets above, including real members after a `.`
  and an auto-import inserted with the symbol as a single undo step. How it is
  acquired is deliberately different from the two servers above, because `gopls`
  publishes no official binaries: **it is never downloaded by Pisaka.** If you
  already have one (`~/go/bin/gopls`, `$GOBIN`, `$GOPATH/bin`), it is found and
  used with **no prompt at all**. If you don't, the first Go file you open in a
  project offers once — *Install gopls with your Go toolchain?* — and accepting
  runs `go install golang.org/x/tools/gopls@v0.23.0` with **your own `go`**,
  which fetches the module through Go's tooling and verifies it against Go's
  checksum database. A Go toolchain is required either way; on a Mac without one
  there is no prompt, no offer and no server, and the Settings row says so.
  What gets built lands under
  `~/Library/Application Support/Pisaka/LanguageServers/` like everything else
  Pisaka installs — nothing goes on your `PATH`, into `~/go/bin`, or anywhere
  else global, and no `sudo` is involved. Go becomes semantic the moment it
  lands, with no restart. **Preferences → Language Servers** has a Go row showing
  which of the two it is: *installed · found on this Mac* (no Remove button — it
  isn't Pisaka's binary to delete) or *installed by Pisaka · version 0.23.0*
  (Remove, which stops the server and falls back to your own copy if you have
  one). Declining persists across launches and is turned around from that same
  screen; a failed build is a sentence in that row and a Retry button, never an
  alert, and Go keeps using the built-in index throughout. The build uses your
  normal module and build caches, so it is as fast as any other `go install` on
  your machine. `gopls` comes from `github.com/golang/tools` and is BSD-3-Clause;
  it is not in Acknowledgements, because `go install` writes one binary and no
  license file — the Go row names its origin and license instead.
- Semantic code intelligence for **Rust** (macOS), through `rust-analyzer` — the
  same Go to Definition and completion Swift and Go get above, including real
  members after a `.` and an auto-import (a `use` line) inserted with the symbol
  as a single undo step. How it is acquired is the hybrid of the two stories
  above: **used if you already have it, downloaded once if you don't.** If a
  working `rust-analyzer` is already on your Mac — rustup puts one in
  `~/.cargo/bin` — it is found and used with **no prompt at all**, and Pisaka
  downloads nothing. If there isn't one, the first Rust file you open in a project
  offers once, with the download size shown, and accepting fetches the official
  prebuilt binary from `github.com/rust-lang/rust-analyzer` (release
  `2026-08-03`), verifies it against a SHA-256 pinned in this app and installs it
  under `~/Library/Application Support/Pisaka/LanguageServers/` — nothing on your
  `PATH`, nothing global, no `cargo install`, no `sudo`. Rust becomes semantic the
  moment it lands, with no restart. **A Rust toolchain is required either way**:
  `rust-analyzer` runs `cargo` to understand your project, so on a Mac without one
  there is no prompt, no download and no server — the Settings row says so, and
  Rust files keep highlighting, indexing, completing and jumping from the built-in
  index. **Preferences → Language Servers** has a Rust row showing which of the two
  it is: *installed (found on this Mac)* (no Remove button — it isn't Pisaka's
  binary to delete) or *installed by Pisaka · 2026-08-03* (Remove, which stops the
  server and falls back to your own copy if you have one). Declining persists
  across launches and is turned around from that same screen; a failed download is
  a sentence in that row and a Retry button, never an alert.
  `rust-analyzer` is dual-licensed `Apache-2.0 OR MIT`; like `gopls` it is not in
  Acknowledgements, because the download is a single compressed binary carrying no
  license file — the Rust row names its origin and license instead.
- VS Code-style minimap to the right of the editor: a scaled-down,
  syntax-colored overview of the file with a draggable viewport rectangle.
  Click or drag the rectangle to scroll the editor, or scroll the mouse wheel
  over the minimap; scrolling the editor moves the rectangle. Each line keeps a
  fixed minimap height, so for long files the
  overview slides as you scroll rather than squeezing the whole file into the
  panel; colors follow the system light/dark appearance.
- Syntax highlighting (tree-sitter via ChimeHQ's Neon) for Swift, JavaScript,
  TypeScript, JSON, Markdown, Python, Go, Rust, HTML, CSS, YAML, Dockerfiles,
  `.env` files, and dot-prefixed ignore files (`.gitignore`, `.dockerignore`,
  `.npmignore`, `.eslintignore`, `.prettierignore`, …). The language is
  detected from the whole file name, not just its extension — so `Dockerfile`,
  `Dockerfile.dev`, `.env.local` and any dot-file ending in `ignore` are
  recognized even though they carry no extension. Colors follow the system
  light/dark appearance, and files with no detected language are shown as plain
  text.
- Each tab keeps its own independent text; switching tabs swaps the editor
  contents.
- Save writes to the file's URL; "Untitled" files prompt for a location.
- JetBrains-style autosave: a file with unsaved changes is written to disk
  automatically — a short idle delay after you stop typing, when the app loses
  focus, when you switch tabs, and when you quit (Cmd+Q). "Untitled" files (with
  no path yet) are never autosaved, so autosave never pops a Save As panel.
- While one of the app's own git operations is writing to the working tree — a
  revert, a merge apply, a branch checkout, a project-wide Replace All, or a
  commit — saving (Cmd+S, the close prompt's Save, and the implicit save before
  Run and Run Test) and the project-tree create/rename/delete are refused with a
  "Git operation in progress" notice rather than racing git over the same files.
  Autosave pauses for the same window and resumes on its own afterwards.
- Session restore on launch (macOS): starting the app brings back the last
  session — the opened folder, the open tabs in the same order, and the tab that
  was selected. "Untitled" buffers get hot exit: their text survives a restart
  and comes back in a tab still marked unsaved (closing it asks for confirmation
  as usual), which is what autosave cannot do for them since they have no path
  to write to. An empty "Untitled" buffer is not stored — there is nothing in it
  to bring back. Restore is silent: a file deleted or renamed between launches
  simply does not come back, and neither does a folder that no longer exists; the
  rest of the session is restored around it, and if the missing file was the
  selected tab you land on the last restored one. The session is written
  continuously (a second after each change), not only on quit, so it also survives
  a crash or a force-quit — no more than a couple of seconds stale; a launch that
  could not restore everything does not immediately overwrite what was saved, so a
  folder on a volume you have not mounted yet is still recorded until you change
  something. One boundary: the *contents* of a dirty titled file are not part of
  the session, only its path — quitting flushes autosave first, so those edits are
  on disk before the session is written, and a crash loses at most one autosave
  window of typing.
- Closing a file with unsaved changes shows a Save / Don't Save / Cancel dialog.
- Local Changes: a collapsible bottom panel (toggle with "Show/Hide Local
  Changes" in the View menu, the Changes button on the bottom bar, or
  Cmd+Shift+C) listing files differing from `HEAD` (via `git`).
  View the list flat or grouped by folder; each file shows a type icon tinted by
  its git status plus a one-letter badge (M/A/D/R/U/C). Double-click a file to open
  a JetBrains-style side-by-side diff (`HEAD` vs working copy) in a separate
  window, with aligned panes, red/green row backgrounds, per-side line-number
  gutters, change markers, synced scrolling, and syntax highlighting. The list
  refreshes manually (a refresh button) and automatically after you save a file.
  You can revert (discard) local changes: check one or more files and choose
  Revert from a file's context menu to restore the checked set to their `HEAD`
  version (an unchecked file reverts just itself; a reverted untracked file is
  deleted, as it has no `HEAD` version). The action is destructive and always asks
  for confirmation first; any open tab for a reverted file is kept in sync —
  reloaded from disk, or closed if the file was deleted. To commit the listed
  changes, use the header's Commit button or Cmd+K (next bullet); to commit just
  one of them, choose **Commit…** from that file's context menu, which opens the
  same dialog with only that file checked.
- Commit (macOS): an IDEA-style modal dialog, opened with Cmd+K (Git > Commit…),
  the Commit button in the Local Changes header, or **Commit…** in a changed
  file's context menu. On the left the changed files
  with three-state checkboxes and status badges; on the right the selected file's
  unified diff with **a checkbox on every changed line**, so you can commit part
  of a file and leave the rest as local changes; at the bottom the message field,
  the author line, and the Amend and "Push after commit" switches. Everything
  starts checked, so opening the dialog and confirming commits every local change
  — except when you opened it from a single file's Commit… item, where only that
  file starts checked (and scrolled into view) while everything else is left for a
  later commit — if that file is no longer in the list by the time the dialog reads
  the repository, nothing is checked rather than everything, and the dialog says
  which file went missing.
  Commit is Cmd+Return (the message field is multiline, so plain Return inserts a
  newline there); Esc cancels. Opening the dialog first writes every unsaved
  titled buffer to disk, since what it shows and commits is what is *on disk* — if
  a file could not be written an alert names it, and the dialog still opens with
  that file's last saved contents. Opening a different folder while the dialog is
  up dismisses it (its contents describe a repository that is no longer open), and
  a commit issued for the previous project never runs against the new one;
  reopening always starts with Amend unticked.
  What is committed is exactly what is selected in the UI (the JetBrains model) —
  the commit is assembled in a temporary index seeded from `HEAD`, so anything you
  staged manually with `git add` is *not* part of it and is unstaged afterwards
  (its changes stay in your working tree). A real `git commit` runs against that
  index, so your `pre-commit`/`commit-msg` hooks still run (and see exactly the
  content being committed) and git resolves the author as it normally would; a
  failing hook aborts with its own message and leaves the repository untouched.
  The author line always shows the name and email the commit will carry **and
  which config each came from** — `(local)` or `(global)`, named per field so a
  mixed pair cannot be misreported — with an editor that writes the repository's
  **local** config only, never the global one; an unset identity blocks the
  commit. Amend rewrites the previous commit, offering its message into an empty
  message field (and leaving text you have typed alone) — the dialog opens
  whenever a project is open, including on a clean working tree, so a
  message-only amend needs nothing to be checked; "Push after commit"
  pushes when done, using the branch's upstream or creating one
  (`--set-upstream`) when it has none, and reports "commit created, push failed"
  as its own outcome rather than as a failed commit. Files that cannot be split
  line by line — a deleted file, a binary, non-UTF-8, unreadable or very large one
  (over 1 MiB), and a file that differs in something other than its lines (only
  the line endings, only the mode) — show a "committed as a whole" note instead of
  a diff and are committed whole or not at all. Immediately before committing, the
  change list is re-read and every included file re-diffed; if anything changed
  under the dialog (`git` in the terminal, another editor) the whole commit is
  abandoned with a message naming the file, and nothing is written; an *amend* is
  refused outright if `HEAD` itself moved in the meantime, so it cannot rewrite a
  commit you were never shown. If the branch changes between the commit and the
  push — the commit runs your hooks, which takes time — the push is skipped and
  reported as "commit created, push failed" rather than publishing a branch this
  commit is not on. After a successful commit the open tabs are resynced from
  disk (an edited buffer is preserved, not overwritten), so a formatting
  `pre-commit` hook's edits show up in the editor instead of being silently
  written back over by the next autosave. Committing is
  blocked with a reason while a merge, rebase, cherry-pick or revert is in
  progress, or while any file is still conflicted — finishing a merge stays a
  console job — and that check is repeated against a fresh read at the moment you
  commit, so a merge started in the terminal while the dialog is open blocks it
  too.
- Conflict resolution: a file left in a merge-conflict state shows a purple "C"
  badge in Local Changes; double-clicking it (or choosing "Resolve…" from its
  context menu) opens a JetBrains-style 3-pane merge editor in a separate window
  — ours on the left, the editable merged result in the middle, theirs on the
  right — sourced from git's merge index stages (`:1` base, `:2` ours, `:3`
  theirs). Spans changed by only one side are merged automatically; spans both
  sides changed differently are highlighted as conflict hunks. For each hunk you
  can accept ours, accept theirs, accept both (in either order), or edit the
  result directly, with prev/next conflict navigation and synced scrolling across
  the three panes. "Apply" (enabled only once every conflict is resolved) writes
  the resolved text to the working file, stages it (`git add`), refreshes Local
  Changes, and closes the window. Non-binary text files only.
- Git Log: a read-only commit history shown in a collapsible bottom panel (toggle
  with "Show/Hide Git Log" in the View menu, the Git button on the bottom bar, or
  Cmd+Shift+L). It shows a JetBrains-style commit table — short
  hash, ref/branch/tag badges, subject, author, and date — with a colored branch
  graph in the left gutter that draws lanes for branches and merges. A "Load
  more" affordance fetches an additional page of history. Selecting a commit shows
  the files it changed (against its first parent; a merge shows its mainline diff);
  double-click a file to open its side-by-side diff in a separate window — the same
  viewer as Local Changes. A filter bar above the table narrows the history
  server-side by branch
  (or "All"), author, date range (since/until), and path, and a search box filters
  the loaded commits by message text client-side (no re-query). All git access is
  read-only — no history mutation, and (like Local Changes) no filesystem
  watching: both panels refresh on demand.
- Branch switcher: a JetBrains-style widget in the always-visible bottom bar shows
  the current branch. Click it for a popover listing local and remote branches
  (the current one marked) with a filter field: pick a local branch to check it
  out, or choose "New Branch…" to create and switch to a new branch off any
  starting ref (default `HEAD`). Clicking a remote branch (e.g. `origin/master`)
  opens a small menu with two actions: "Checkout" does git's DWIM — switch to a
  same-named local branch if one exists, otherwise create one from the remote ref
  (no fetch, so it's immediate) — and "New Branch from 'origin/…'…" opens the
  create dialog pre-filled with its name and fetches from the remote first (using
  your system git credentials) so the new branch starts up to date. The New Branch
  dialog uses the same wide, wrapping field (Enter confirms, empty input keeps OK
  disabled), but an invalid branch name is reported after OK rather than as you
  type.
  On a dirty working tree a checkout is warned it may be blocked — git makes the
  final call, and a real refusal shows git's exact message naming the conflicting
  files. After a successful switch or create, open tabs are resynced from disk (an
  edited buffer is preserved, not overwritten) and the tree, Local Changes, and Git
  Log refresh to reflect the new branch.
- Embedded terminal: a collapsible bottom panel (toggle with "Show/Hide Terminal"
  in the View menu, the Terminal button on the bottom bar, or Cmd+Shift+T) hosting
  one or more live shell sessions in a
  vertical split below the editor, with a draggable divider. Each session runs a
  login shell — your `$SHELL`, or `/bin/zsh` — started in the open project folder
  (or your home directory when no folder is open). A tab bar lets you open new
  terminals ("＋"), switch between them, and close them; switching tabs never
  restarts a running shell. Shells are terminated when you close their tab and
  when you quit, so no processes leak. Closing the last terminal tab collapses the
  panel (no empty gap), and a repeat click / Cmd+Shift+T reopens it. The Terminal,
  Git Log, and Local Changes panels share one bottom dock — opening one replaces
  whichever was shown. The terminal follows the app theme — the system light/dark
  appearance, or a theme forced in Settings — and recolors live, without restarting
  the shell or losing scrollback; every open tab is recolored, including inactive
  ones.
  (Terminal emulation is provided by
  SwiftTerm; the two built-in palettes are not user-configurable — no custom
  color scheme or ANSI palette, no custom font — and there are no split terminals,
  tab rename/reorder, or session restore.)
- Run File (macOS): run the current file in a new terminal session via the
  Run > Run File menu item, Cmd+R (for the active tab), or the "Run" item in a
  file's project-tree context menu. Runnable
  types are TypeScript (`npx tsx`), JavaScript (`node`), Python (`python3`), Go
  (`go run`), Swift
  (`swift`), and shell scripts (`bash`). Like every entry in that list, Go runs
  the *one file* you are in — a `main` split across several files in a package
  needs `go run .` from the terminal. **Rust is deliberately not on that list**:
  every runner here takes a single file path, and `cargo run` takes none — Rust
  has a project runner and no file runner, so `cargo run` from the terminal panel
  is the answer while Cmd+U below works normally. The file's dirty tab is saved first, the
  session starts in the project folder (or the file's folder when no project is
  open), and re-running the same file reuses its dedicated "Run:" tab rather than
  piling up new ones. Unrunnable file types are skipped with a notice.
- Run Test (macOS): run a file's tests in a new terminal session via the
  Run > Run Test menu item, Cmd+U (for the active tab), or the "Run Test" item in
  a test file's project-tree context menu (shown only for files that match a
  language's test-naming convention — e.g. `*.test.ts`/`*.spec.js`, `test_*.py`,
  `*_spec.rb`, `*Test.php`, `*_test.exs`, `*_test.go`, `*Tests.swift`, and **any**
  `.rs` file, since Rust's tests live beside the code rather than in files named
  for it).
  The project's test runner is detected from its root config files and manifests:
  JavaScript/TypeScript picks vitest, jest, or mocha (from a `vitest.config.*` /
  `jest.config.*` / `.mocharc*` file or a `package.json` mention, first match
  wins) and reports a notice when none is
  found; Python uses `pytest`, Ruby picks `rspec` for `*_spec.rb` and `ruby`
  otherwise, prefixed with `bundle exec` when a `Gemfile` is present, PHP
  `./vendor/bin/phpunit`, Elixir `mix test`, Go `go test`, Rust `cargo test`, and
  Swift `swift test`. Like Run File, the file's dirty tab is saved first, the
  session starts in the project folder (or the file's folder), and re-running the
  same file reuses its dedicated "Test:" tab.
- Preferences (Cmd+,): a Settings window with three persisted options — tab
  orientation (a vertical column beside the editor, or a horizontal strip above
  it), theme (follow the system, or force light/dark), and a shared editor font
  size used by the editor, diff, and merge views. The font size is also
  adjustable on the fly with Cmd+scroll over any code view. All three settings
  persist across launches. The Settings window's other tabs are **Language
  Servers** (what may be downloaded, and what is installed), **LeetCode** (the
  account, the solutions folder, and the language new solution files are seeded
  in) and **Acknowledgements**, which lists every third-party dependency the app
  ships — name, SPDX identifier, version/revision, and upstream origin — beside
  its full license text, shown verbatim and selectable.
- LeetCode integration, in its own **LeetCode** menu. None of it needs an open
  project, and opening a problem never changes the project root — the solution
  file just opens as an ordinary tab.
  - **Sign In…** opens leetcode.com's own login page in a web view, so the SSO
    providers (GitHub, Google, …) work exactly as they do in a browser. The
    session it produces is kept in the Keychain; **Sign Out** clears both that
    item and the `leetcode.com` cookies. One account at a time — switching means
    signing out and back in.
  - **Open Problem…** (Cmd+Shift+P) accepts a **problem number** (`1`), a
    **slug** (`two-sum`), or a **leetcode.com problem URL**, with a language
    picker offering Swift, Python 3, Go, Rust, TypeScript and JavaScript. The
    choice persists, so the next problem opens in the same language.
  - **Browse Problems…** (Cmd+Shift+B) opens the whole problem list in its own
    window: search by number, title or slug (a number matches that problem exactly,
    text matches anywhere in either), narrow by difficulty and by your own progress
    (solved, attempted, not started), and open a row by double-clicking it or with
    the Open button — into the same solution file, under the same rules, as if you
    had typed its number. Premium problems are always listed, marked with a lock,
    and refused on open with the reason. Search is instant and works offline: the
    list is the one cached catalog, not a request per keystroke. Because the solved
    marks come from that cache, the window shows when it was last fetched and has a
    **Refresh** beside it. The window carries the same language picker as **Open
    Problem…**, writing the same persisted setting, so the two cannot disagree; a
    row also opens from its right-click menu.
  - The solution file is written as `0001-two-sum.swift` into the folder you
    chose (**Choose LeetCode Folder…**, suggested `~/Documents/LeetCode` and
    asked for on first use), seeded with a header comment naming the problem and
    LeetCode's own code snippet for that language. **An existing file is never
    overwritten**: reopening a problem reopens your work untouched.
  - The problem statement renders in a resizable pane beside the editor,
    themed to match, and is cached on disk — so reopening a solved problem shows
    its statement even offline. A button in the pane's header opens the problem
    on leetcode.com for the parts it deliberately does not render (discussion,
    submissions, the editorial).
  - **Run and Submit**, in a section under the statement in that same pane.
    Run executes what is in the editor against the problem's example test cases,
    which are prefilled into an editable box — change them and Run again to try
    your own input. Submit sends the same code to LeetCode's full test suite. Both
    judge **what is in the editor right now**, so there is no need to save first,
    and the verdict comes back where you are reading the problem: Accepted or the
    failure, the runtime and memory (with percentiles when LeetCode sends them),
    how many cases passed, the failing case's input, your output and the expected
    one — and compile or runtime errors **in full**, monospaced and selectable,
    rather than clipped to a line. A disabled button always says why (not signed
    in, not a solution file, a language LeetCode does not accept).

## iOS / iPadOS

The same `PisakaCore` domain logic powers an adaptive SwiftUI/UIKit app on iPad
and iPhone. The feature scope landed so far:

- Adaptive layout: iPad uses a `NavigationSplitView` (project-tree sidebar +
  editor detail); iPhone uses a navigation stack (tree → editor). The open-tabs
  UI adapts too — a horizontal/vertical strip of chips on iPad, a compact menu
  switcher on iPhone — driven by the same `TabOrientation` preference.
- File access via the system document picker (`UIDocumentPickerViewController`)
  for opening a folder or files, with folder access persisted across launches by
  security-scoped bookmarks; a `FileService` read/write is bracketed by the
  covering scope's `startAccessingSecurityScopedResource` (an operation with no
  registered covering scope falls through to the base service unbracketed).
- A `UITextView`-backed code editor with the same tree-sitter syntax
  highlighting (Neon), auto-indent (`IndentEngine`), and auto-close brackets/
  quotes (`AutoPairEngine`) as macOS. Font size follows the shared
  `SettingsStore` preference; pinch-to-zoom steps it (the iOS analog of macOS
  Cmd+scroll). The editor's line-number gutter and minimap are deferred on iOS
  (the side-by-side diff panes do still draw per-side line numbers).
- The same index-based code intelligence as macOS (there is no language server on
  iOS, so Swift is answered the same way every other language is), through
  touch-appropriate surfaces:
  **Go to Definition** is an extra item in the selection's edit menu (tap an
  identifier → "Go to Definition"), which jumps straight there, or asks which
  declaration you meant when several share the name; a name nothing declares gives
  a light haptic. **Completion** is a QuickType-style strip above the keyboard —
  it appears from the second character typed (or as soon as you type a `.`, with
  that receiver's members), offers the same fuzzy/camelCase matches and language
  keywords as macOS, scrolls horizontally, tapping a word
  inserts it as one undo step, and it disappears when there is nothing to offer,
  so it works the same with the on-screen and a hardware keyboard. iOS has no
  file-system watcher, so the index is built when you open a folder and kept
  current as you open tabs and type, but it does not notice changes made to the
  files by another app.
- A Preferences sheet bound to the same `SettingsStore` (theme, tab orientation,
  font size), with an **About → Acknowledgements** screen listing the same
  third-party dependencies and their full license texts as the macOS tab.
- Git features backed by **libgit2** in-process (no `git` binary): Local Changes
  (flat / by-folder list, status badges, side-by-side diff, multi-file revert),
  Git Log (commit list with the branch-graph gutter, filter/search, commit-vs-
  first-parent diffs), and 3-pane conflict resolution (apply + stage). These are
  presented as sheets / pushed screens rather than separate windows.
- Branch switcher: the current branch in the toolbar/nav, tapped to a sheet with
  the local/remote branch list, a filter, and "New Branch…" — the iOS peer of the
  macOS widget. Tapping a remote branch shows a menu with "Checkout" (git DWIM —
  switch to a same-named local or create one from the remote ref, no fetch) and
  "New Branch from…" (the fetch-first create flow described next).
  Creating a branch from a remote ref (e.g. `origin/master`) fetches
  first over **HTTPS** using a Personal Access Token you store per host in Settings
  (kept in the Keychain); GitHub PATs use the `x-access-token` username
  automatically. If no token is stored for the remote's host, the flow reports it
  and points you to Settings; you can also create from the local tracking ref
  without fetching, or cancel. Note: only an **HTTPS `origin`** can be fetched with
  a PAT — an SSH remote (`git@…`) cannot, since libgit2's SSH transport is
  exec-based and there is no subprocess on iOS.
- The same LeetCode integration, reached from the "+" toolbar menu: one screen
  combining the account and the problem input rather than the macOS
  menu-plus-sheet pair. Solution files default to the app container's
  `Documents/LeetCode`, which needs no permission and no picker; **Change…**
  points them anywhere the document picker reaches (persisted as a
  security-scoped bookmark), and **Use Default** goes back. The statement is a
  pane beside the editor on regular width and a toggleable sheet on compact, and
  **Run and Submit** sit under it in both shapes — the same editable test-case box
  and the same verdicts as on macOS, with the controls kept above the keyboard and
  a Done affordance to dismiss it. **Browse Problems** pushes the same problem
  list from that screen: a search bar, difficulty and progress filters in a toolbar
  menu, pull to refresh, and a tap to open — which dismisses the sheet and leaves
  you in the solution file.
- The embedded terminal is macOS-only (SwiftTerm) and not present on iOS.

## Known Limitations (1.0)

- Find/replace (per-file and project-wide) is macOS-only: iOS has neither the
  search bar nor the Find in Files window. There is no query history, no "replace
  in selection", and the project search reads tree `.gitignore` files only (not
  `core.excludesFile` or `.git/info/exclude`).
- The project tree supports create, rename, and delete (via a row context menu),
  but has no drag-and-drop. On iOS it refreshes only after its own edits, not
  after changes made outside the app.
- Committing is macOS-only (iOS has no commit dialog) and has no staging area of
  its own: the selection in the dialog *is* the commit, so a manual `git add` is
  overwritten and unstaged afterwards, and a formatting `pre-commit` hook's staged
  edits are unstaged the same way (its worktree edits remain as local changes). A
  merge commit cannot be created from the app — finishing a merge, rebase,
  cherry-pick or revert stays a console job — and there is no force push, no
  warning about amending an already-pushed commit, no message history or
  templates, no signing controls, no changelists, and no per-line revert.
  (Because a real `git commit` runs, your repository's own settings still apply:
  a repository with `commit.gpgsign` on produces signed commits as it always
  would — there is simply no per-commit toggle for it in the dialog.)
- Annotate with Git Blame is macOS-only (iOS has no gutter) and inspection-only:
  clicking an annotation opens no commit detail, there is no "annotate previous
  revision", no jump from an annotation into the Git Log, and the date format is
  fixed (not a setting).
- The semantic Swift intelligence is macOS-only and needs Xcode, and it covers
  Go to Definition and completion only — there is still no Find Usages, no rename,
  no hover types, no signature help and no diagnostics, and nothing about the
  server is configurable or visible: no status indicator, no "restart server", no
  log. It answers for projects `sourcekit-lsp` can build (a `Package.swift`, a
  `compile_commands.json`, an `.xcodeproj` through the build server protocol); a
  loose folder of Swift files is not one, so the server starts, answers little or
  nothing, and everything falls back to the index. The **first** jump or completion
  in a freshly opened project is answered from the index too, while the server is
  still resolving the build system behind it — the next one is semantic. If a
  server crashes it is restarted up to three times for that project and then given
  up on for the rest of the session, silently. An auto-import committed before the
  server finished describing it arrives as a second undo step rather than one, and
  is skipped entirely if you kept typing in between. In a file whose lines are
  separated by NEL / U+2028 / U+2029 the editor and the server count lines
  differently; jumps and edits still land exactly right, since only the numbering
  differs and no server line number is ever shown. On iOS there is no language
  server at all (iOS has no subprocesses), so the next item applies there in full.
- The downloadable TypeScript/JavaScript and Python servers are macOS-only and
  cover the same Go to Definition and completion — no diagnostics, no hover types,
  no rename, no status indicator and no log, and nothing about them is
  configurable: no per-project server, no extra options or arguments, and no
  version picker (the versions are pinned in the app and change only when you
  update it — and when an update does move a pin, the next TypeScript or Python
  file you open re-downloads the server at the new version without asking again,
  replacing the old copy, because you already agreed to install it). Offline,
  behind a proxy that intercepts TLS, or on a network that blocks `nodejs.org` /
  `registry.npmjs.org`, the download simply fails: the Settings row says "not
  installed", there is a Retry button, and the language keeps using the built-in
  index — the same thing that happens if you decline. There is no progress bar,
  no resume (an interrupted download restarts from zero) and no mirror or proxy
  setting, and each file is held in memory while it is verified, so a first
  install peaks around 53 MB of RAM for a few seconds. A Rosetta-translated app
  installs the Intel build of Node. `pyright` with no Python interpreter it can
  find still answers, but only from its own bundled type stubs — it will not know
  about the packages in your virtualenv. And what is installed is verified once,
  when it is downloaded: if you edit the files under `LanguageServers/` yourself,
  the app runs what you put there.
- The Go server (`gopls`) is macOS-only and covers the same Go to Definition and
  completion, with the same absence of diagnostics, hover types, rename, status
  indicator and log. It needs a Go toolchain — there is no offer without one, and
  a `go` that cannot answer `go env` counts as none. A `gopls` you already have
  is used **at whatever version it is**: none is read, required or shown, and it
  is never replaced or updated by Pisaka. A build Pisaka does run is your own
  `go install`, so it uses your module and build caches (only `GOBIN` is
  redirected) and, with Go's default `GOTOOLCHAIN=auto`, an older toolchain may
  fetch a newer one to build with. It is attempted **once per launch**: if it
  fails, the Settings row says why and offers Retry rather than trying again
  every time you switch to a Go file. Discovery happens once per launch too, so a
  Go toolchain installed while Pisaka is running is found at the next launch. The
  version is pinned in the app and there is no version picker.
- The Rust server (`rust-analyzer`) is macOS-only and covers the same Go to
  Definition and completion, with the same absence of diagnostics, hover types,
  rename, status indicator and log. It needs a **Rust toolchain** — there is no
  offer and no server without one, and a `cargo` that cannot answer
  `cargo --version` counts as none. The same applies to a `rust-analyzer` it
  finds: rustup installs a proxy for it whether or not the component was ever
  added, so one that cannot answer `--version` is treated as absent rather than
  used. A `rust-analyzer` you already have is used **at whatever version it is**:
  none is read, required or shown, and it is never replaced or updated by Pisaka —
  which is also why Install is not offered over it. The downloaded version is
  pinned in the app (a *date*, which is how upstream releases it) and there is no
  version picker; when an app update moves that pin, the next Rust file you open
  re-downloads at the new version without asking again, because you already agreed
  to install it — *unless* you also have a `rust-analyzer` of your own, in which
  case Pisaka falls back to using yours rather than downloading the new pin, and
  the row says so ("found on this Mac"). The old copy Pisaka downloaded is still
  removable from Preferences. The download is attempted **once per launch**: if it fails, the
  Settings row says why and offers Retry rather than trying again every time you
  switch to a Rust file, and offline or behind a proxy that blocks `github.com` it
  simply fails and Rust keeps using the built-in index. Discovery happens once per
  launch too, so a Rust toolchain installed while Pisaka is running is found at
  the next launch.
- The tree-sitter fallback — which is what every other language, and Swift without
  Xcode, always uses — is index-based, not a compiler: Go to Definition matches a
  *name*, so it cannot tell two same-named declarations apart (it lists both),
  knows nothing about imports, scope, generics or overload resolution, and finds
  nothing in dependencies outside the opened folder. There is no Find Usages, no
  rename refactoring, no hover types or signature help, and completion offers
  identifiers only — no kind or file column in the macOS popup and no snippets.
  Member completion after a `.` is **name-based, not typed**: it offers every
  member the whole project declares, ranked so the members of a type you named
  outright (`Worker.`) come first, while a receiver whose type would have to be
  inferred (`worker.`, `f().`) gets no such preference. Fuzzy matching needs the
  first character you type to start a word in the candidate, so `buf` finds
  `ArrayBuffer` but `rray` finds nothing. A dot inside a string or a comment
  still opens the member list, since the trigger does not look at the syntax
  tree — but a dot with nothing typed after it offers **members only**, so if the
  project declares none the list simply stays empty rather than falling back to
  words from the file. A language with no bundled symbols query (and
  `.gitignore` deliberately has none) completes from the buffer's words alone, and
  the data formats, Markdown and `.gitignore` have no keyword list either.
  On iOS the index does not see changes made to the files outside the app.
- No tab reordering, drag-and-drop, or split views.
- The path bar above the editor is macOS-only and read-only: its breadcrumb
  segments are not clickable, there is no "copy path" action or window proxy
  icon, and iOS has no equivalent bar.
- Automatic file-change detection covers the project tree on macOS only. Local
  Changes, the Git Log, and open editor tabs are still refreshed on demand — an
  external edit to a file you have open does not reload its tab, and the git
  panels refresh on save, on their Refresh button, or after an operation of their
  own.
- Session restore is macOS-only: on iOS only the last opened folder comes back
  (through its security-scoped bookmark) — the tabs, the selection, and "Untitled"
  text are not restored. What comes back on macOS is the folder, the tabs and the
  selected tab, but not per-tab caret or scroll positions, and not the
  bottom-panel / terminal / project-tree state. There is no history of earlier
  sessions and no setting to turn restore off.
- A single editor window only (diffs open in separate read-only windows on
  double-click; the bottom-panel height is not persisted across launches).
- The LeetCode integration talks to LeetCode's **unofficial** API — the same
  endpoints the website itself uses. It can change or be blocked with no notice,
  which surfaces as an "API changed" error naming the field that no longer
  matched, and is fixable only by an app update. More specifically:
  - Running and submitting work, but there is **no submission history**: the
    section shows the attempt you just made. Earlier submissions, their diffs and
    the editorial stay on leetcode.com.
  - A Run or Submit that takes longer than the app waits for (30 s and 60 s) is
    reported as a timeout — but the submission is **not** undone. LeetCode has it,
    and its result is on the site; do not submit again on the strength of that
    message. The same is true if you close the tab or sign out mid-run.
  - Edited test cases are not persisted: switching problems resets the box to the
    statement's own examples, and quitting forgets it.
  - Run and Submit live **inside the description pane**, so they are only offered
    while it is showing: a problem whose statement has never been fetched and is
    not cached (a first open while offline) has no judge controls at all, folding
    the pane away to its strip hides them with it, and on iPhone width they are
    inside the description sheet rather than beside the editor.
  - The echoed input a Run comes back with is shown as **one block**, not split
    per case: LeetCode spells it one line per argument, so on a problem taking
    more than one there is no per-case slice of it to label.
  - Runtime and memory percentiles are absent on anything that is not Accepted,
    and the case counts are absent on a compile error — LeetCode does not send
    them, and nothing is invented to fill the gap.
  - The problem browser's solved/attempted marks are only as fresh as the last
    fetch — the window says when that was, and **Refresh** is the only thing that
    changes it (the list refreshes on its own at most once a day). The cached list
    is per app rather than per account, so signing in as somebody else shows the
    previous account's marks until the first refresh under the new session.
  - The browser narrows by number/title/slug text, by difficulty and by your own
    progress, and by nothing else: no topics or tags, no company lists, no
    favourites or study plans (each would need an API surface this integration
    deliberately stays off), and no sorting beyond LeetCode's own order. A pasted
    problem **URL** matches nothing in the search field — the **Open Problem…**
    field is where a URL is understood. Premium problems cannot be filtered out
    either: hiding them would leave gaps in the numbering that read as missing
    problems.
  - Cached statements hold LeetCode's HTML only: **images do not load offline**,
    and neither does anything else the page would have fetched.
  - A solution file is tied to its problem by its **name and its location**.
    Renaming it, or moving it out of the configured folder, detaches it — the
    description pane goes empty for that tab.
  - Premium problems your account cannot read are refused outright (no file is
    written) rather than opened with the locked part missing. A Premium
    subscription opens them normally — LeetCode sends the statement and the
    snippet, and the refusal is on the locked answer, not on the problem's
    Premium flag.
  - On iOS, solution files written to the default location are **not visible in
    the Files app** (the app declares no file sharing); point the folder at a
    Files location if you want them there.
  - Sign Out clears `leetcode.com`'s cookies, but cookies an SSO provider set on
    *its own* domain survive it, so signing back in may not ask for the password
    again.

## License

Pisaka is MIT-licensed — see [`LICENSE`](LICENSE).

The app links third-party dependencies and ships each one's verbatim license
text in `Resources/Licenses/` (alongside `licenses.json`, the manifest that is
the list of record). They are shown in-app under **Preferences →
Acknowledgements** on macOS and **Settings → About → Acknowledgements** on iOS.
libgit2 is used under GPL-2.0 with its linking exception (its bundled `xdiff`
code is LGPL-2.1). Adding a dependency means adding its license there too —
`swift test` fails until you do (`LicenseCoverageTests`).

Language servers you choose to download are not in that directory and are not
covered by that test, because they ship inside nothing: their verbatim notices
are read out of the tree that was actually installed, so the notice and the code
it covers are always the same bytes. They appear in the *Language Servers*
section of Acknowledgements while they are installed and disappear when you
remove them.

`gopls` is not in either place, for a related reason: Pisaka bundles none of it
and downloads none of it, and `go install` writes one binary and no license file
to read. It comes from [github.com/golang/tools](https://github.com/golang/tools)
and is BSD-3-Clause; the Go row in **Preferences → Language Servers** says so.

`rust-analyzer` is not in either place either, and it is the sharper case: unlike
`gopls`, Pisaka *does* download it — but the download is a single compressed
binary, and an archive of one file carries no license text to read out of the
installed tree. So there is nothing for `Resources/Licenses/` to cover (none of
those bytes ship in the app) and nothing for the Acknowledgements section to show.
It comes from
[github.com/rust-lang/rust-analyzer](https://github.com/rust-lang/rust-analyzer)
and is dual-licensed `Apache-2.0 OR MIT`; the Rust row in **Preferences →
Language Servers** says so.
