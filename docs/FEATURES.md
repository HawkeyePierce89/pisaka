# Pisaka features in detail

The complete, edge-case-level description of what the app does — and, just as
deliberately, what it does not do. `README.md` carries a one-line summary per
feature and links here; this file is the long form it used to inline. The
*design rationale* behind these behaviors (invariants, decisions, trade-offs)
lives in `docs/architecture/`; this file describes the behavior itself, as a
user sees it.

## Features (macOS)

- **Automatic updates (macOS only).** Release builds check GitHub for a newer
  version through [Sparkle 2](https://sparkle-project.org) and install it in
  place. On first launch Sparkle asks *once* whether it may check automatically;
  whatever you answer, **Pisaka → Check for Updates…** runs a check on demand at
  any time. There is nothing to configure — no update channel, no interval, no
  preference pane of ours — and every download is verified against an EdDSA
  public key baked into the app before it is applied. Development (DEBUG) builds
  never check, never prompt and never download: the updater is not compiled into
  them at all. iOS has no updater.
- Open a folder as a project ("Open Folder…", Cmd+Shift+O) and browse it in a
  project tree on the left; directories expand on demand and clicking a file
  opens it in a tab. Folder and file rows behave alike: the *whole* row is the
  click target, so a directory toggles wherever you hit it — the chevron, the
  folder icon, the name or the blank space right of it, one click one toggle —
  and both row kinds highlight identically under the pointer.
  When the project pane is empty, clicking anywhere in it
  opens the folder picker. Opening a folder auto-expands its first level so the
  immediate children are visible right away. Each entry shows a file-type icon
  (tinted by type) so Swift, JS/TS, JSON, Markdown, images, archives, and other
  common types are recognizable at a glance. Dotfiles are visible,
  so `.gitignore` and `.github` are ordinary entries you can open, rename, and
  delete; only the service entries `.git` and `.DS_Store` are hidden (and cannot
  be created or renamed to from the tree — a create path refuses them in any
  casing, since a case-insensitive volume would resolve `.GIT` onto the real
  `.git`). Entries are sorted directories-first,
  then alphabetically. Right-click anywhere on a row — the same rectangle that
  highlights and that a left click acts on — for a context menu, which never
  changes a folder's expansion: directories offer New
  File, New Folder, Rename, and Delete; files offer Rename and Delete, plus a
  "Run" item for runnable file types and a "Run Test" item for test files; the
  project root offers the two create actions. None of the three names carries an
  ellipsis, because none of them opens a dialog: naming happens **inline, on the
  row itself**. A create swaps in a draft row (drawing the icon its future row
  will have, and expanding a collapsed folder to show it) while a rename swaps
  the row's label for a field pre-filled with the current name, its extension
  left out of the selection so one keystroke replaces the stem and `.swift`
  survives. New File and New Folder accept a
  *relative path*, not just a name: entering
  `centrifugo/config.json` creates the `centrifugo` folder and the file inside it
  in one step. Missing intermediate folders are created and existing ones reused,
  a single trailing slash is fine (`a/b/c/`), but the final entry is never
  overwritten — and if something on the path already exists as a *file*, nothing
  is created and the alert names it (`"centrifugo" already exists and is not a
  folder.`). If a later step fails, any intermediate folders already created stay
  on disk (as with `mkdir -p`) and show up in the tree. The draft field shows the
  *whole* input: it wraps onto as many lines as it needs (up to six) and the row
  grows to fit, so a long pasted path stays visible instead of
  scrolling out of sight. It also validates as you type — the reason a name or
  path cannot be used appears in red under the field, and the text turns red with
  it (an empty part of the path,
  a `.` or `..`, a line break pasted into a name, a reserved `.git`/`.DS_Store`, a
  slash in a rename, which takes a
  single name and not a path, or a name a sibling in that folder already has).
  An invalid draft still stays open and editable: Enter refuses it with a beep
  rather than closing it, and never inserts a line break. Empty input is not an
  error — it shows no reason at all, and Enter simply refuses. Esc cancels.
  Clicking anywhere outside the draft — another row, a tab, the editor, the
  bottom bar — cancels it silently *and* still does what that click would
  normally do (the folder toggles, the file opens, the right-clicked row gets its
  menu — every row but the one being named, which has no menu while its draft is
  open, so that click only cancels and the menu is back on the next one), the way
  an inline rename behaves in Finder; clicking the field, a create
  draft's icon or the reason line does not cancel, and neither does the window's
  title bar or ⌘Tabbing to another app and ⌘Tabbing back, which leaves the draft
  and its text untouched. (Coming back by *clicking* the window is an ordinary
  click and cancels the draft if it lands outside it.) A new file opens in a tab, a rename
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
- **Move an entry by dragging it** (macOS). Every row except the project root can
  be dragged, and every *folder* row is a drop target — the project root row
  included, which is how something is moved back to the top level. A file row is
  never a target. The folder highlights, more strongly than the ordinary hover
  highlight, only when the drop would actually be accepted, and the pointer shows
  the matching move or refusal cursor, so the answer is visible before you let
  go. A move never renames: the entry keeps its name and lands directly in the
  folder. Dropping it back onto the folder it already lives in does nothing (that
  is how a drag is cancelled), and dropping it onto itself, into its own subtree,
  or onto a name the destination already holds is simply refused — the row does
  not light up and nothing happens on release. If the folder or the entry changes
  underneath the drag (a Finder delete, a branch checkout, a name that appeared
  in the meantime), the drop reports it in the same alert as any other tree file
  operation. The move carries everything with it: open tabs follow (a moved
  folder carries all its nested tabs, keeping their contents, unsaved changes,
  undo and caret/scroll position) and the tree and the symbol index refresh in
  place. On a case-insensitive volume a name differing only in case is caught by
  the disk rather than by the highlight, so it surfaces as an "already exists"
  failure on release instead of as a refused drop.
- Vertical tab list with active-tab highlight, an unsaved-changes dot, and a
  per-tab close button.
- NSTextView-based editor: monospaced font, undo/redo, copy/paste, and a
  line-number gutter on the left that tracks scrolling, edits, and the system
  light/dark appearance.
- Each open tab remembers where you left it. Switching tabs restores the caret
  (or the selected range) and the scroll position of the tab you come back to, so
  bouncing between two files keeps both places. The scroll position is remembered
  as a position *in the text*, not as a pixel offset, so changing the code zoom or
  the font size between two visits still lands on the same line. The boundaries:
  it lasts for the app run only — a relaunch starts every tab at the top, since
  session restore brings back *which* tabs are open, not where they were; closing
  a tab forgets its position, so reopening the file starts at the top; if the
  file's text was replaced while the tab sat in the background (a project Replace
  All, a revert, a merge apply) the remembered position is dropped and the tab
  opens at the top; and activating a Find in Files result or a Go to Definition in
  an already-open background tab scrolls to the match rather than to the
  remembered position. macOS only — the iOS editor opens each tab at the top.
- Annotate with Git Blame (macOS): right-click the editor gutter and choose
  "Annotate with Git Blame" to show a column to the left of the line numbers with,
  per line, who last changed it and when. Right-click again ("Close Annotations")
  to hide it and the gutter returns to its previous width. The toggle is per tab,
  so each open file remembers its own state; lines that are not committed yet, and
  lines git had nothing to say about, are left blank. The column follows the editor
  font (it resizes with the code zoom and the Preferences font size) and refreshes
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
- A path bar above the editor shows where the open file lives —
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
  spaces) comes from `.editorconfig` when one applies (see below) and is
  otherwise inferred from the file, defaulting to four spaces; the line
  terminator Enter inserts comes from the same place — `end_of_line` when a
  config states it, an LF otherwise. Each auto-indent is a single undo step.
- EditorConfig: a project's `.editorconfig` files are read and honored for
  indentation and for three things a **save** does. `indent_style` decides tabs
  or spaces, `indent_size`/`tab_width` the width, and whichever of the two a
  config leaves out falls back to what the file's own content suggests — so a
  config can set just the style, just the width, or both. Two things change while
  you type: the unit Enter's auto-indent appends, and what the Tab key inserts.
  **Tab is deliberately stricter** — it inserts spaces only when a config says
  `indent_style = space` outright, so with no `.editorconfig` the key keeps
  inserting a literal tab exactly as before (and with the completion popup open,
  Tab still commits the selected row — it reaches the indentation handler only
  when no popup is showing).
  Three more properties apply **when a file is saved**, and only then:
  `trim_trailing_whitespace = true` deletes the spaces and tabs at the end of
  each line, `insert_final_newline = true` adds a line terminator to a file that
  does not end in one (never a second one, and an existing one is never removed),
  and `end_of_line` (`lf`, `cr` or `crlf`) rewrites the file's line terminators to
  the one it names — which is also the terminator Enter inserts, so what you type
  and what a save writes agree. **The line the caret is on keeps its trailing
  whitespace**: autosave runs on idle, tab switch, focus loss and quit, and
  trimming there would delete the indentation you just typed and were about to
  type into; the next save after you move away trims it (a selection protects the
  lines its two ends are on the same way) — and that next save is not merely
  hoped for: the editor remembers which files it spared and offers them again the
  next time that file is on screen, so a line kept once is not left untrimmed on
  disk just because you stopped editing it. Saving on the way out trims it in
  full, there and then, since there is no caret left to protect: the close
  prompt's Save, switching project folder and quitting all do. The one case a
  kept line survives on disk is closing a tab that is already **clean** — that
  close writes nothing at all, by design (nothing is ever reformatted except by a
  save), so the spared whitespace stays until the file is edited and saved again.
  Every save path applies them — Cmd+S,
  autosave, Save As, the close prompt's Save, and the saves before Run and Test —
  and on macOS the change arrives in the editor as one ordinary edit: a single
  Cmd+Z restores the buffer as it was before the save, and the scroll position
  does not jump. Two details worth knowing: a **Save As** applies the
  *destination's* configuration, not the one where the buffer came from (an
  untitled buffer belongs to no folder until you pick one); and for a **background
  tab** caught by an autosave there is no editor to route the change through, so
  that tab loses its undo history and its remembered scroll position — the same
  cost every other off-screen rewrite (project-wide Replace All, a revert, a merge
  apply) already has.
  The usual rules apply: files closer to the edited file win, later sections win
  inside one file, `root = true` stops the search, and `unset` clears an
  inherited property. Section globs are the full EditorConfig dialect (`*`,
  `**`, `?`, `[abc]`/`[!abc]`, `{a,b}`, `{1..9}`, `\` escapes), and comments are
  whole-line `#`/`;` only, per the format's own rules. Stated limits: only those
  six properties are acted on — everything else (`charset`, `max_line_length`,
  and unknown keys) is read but not applied; the search
  stops at the folder you opened, so a `.editorconfig` in a parent directory
  above it is not read (the same on both platforms, because iOS can only read
  inside the folder you granted); `end_of_line` names LF, CR and CRLF only, so
  the three rarer separators the editor understands (NEL, U+2028, U+2029) are
  left exactly as they are; a save that lands mid-composition (an input method's
  marked text on screen) transforms nothing, and writes the untransformed bytes —
  the next save, once the composition is committed, transforms them; **a save is the only thing that ever rewrites
  anything** — opening a file, closing it, switching tabs and editing the
  `.editorconfig` itself change nothing, indentation already in a file is never
  reformatted (so pressing Enter on a tab-indented line under `indent_style =
  space` keeps that line's own tabs and appends the configured spaces), and there
  is no whole-project reformat command; and on macOS an edit to
  a `.editorconfig` takes effect on the next keystroke, while on iOS (which has
  no file-system watcher) it is picked up when you save the `.editorconfig` in
  Pisaka, on a folder switch, or after the app's own working-tree rewrites — not
  on an out-of-band edit made by another app.
- Auto-closing brackets and quotes: typing an opener (`(`, `[`, `{`) or quote
  (`"`, `'`, `` ` ``) inserts its closer with the caret in between; typing the
  matching closer over an auto-inserted one steps past it instead of doubling;
  Backspace on an empty pair (`(|)`) deletes both characters; and typing an
  opener or quote with a selection wraps the selection. An opener directly before
  a word (or an apostrophe completing a word, like `don'`) is left as-is rather
  than stranding a closer. Each auto-pair edit is a single undo step. (Pairing is
  a simple character heuristic with no string/comment awareness.)
- Bracket highlighting, in two flavors at once. Put the caret next to a bracket
  and both halves of its pair get a background; the
  bracket *after* the caret wins when there is one on each side, a selection
  shows nothing, and moving the caret away clears it. Separately, every bracket
  in the file is colored by its nesting depth through a cycling five-color
  palette — depth 5 starts the palette over —
  and a bracket that has no match, or one that closes the wrong kind, is painted
  red. Both follow the system light/dark appearance and the Preferences theme,
  and neither touches the document, so undo never contains a "highlighting edit".
  Matching is a raw character scan with no string/comment awareness, so a bracket
  inside a string literal or a comment is highlighted like any other (a
  tree-sitter-aware version is a follow-up). macOS only for now — no iOS variant
  and no settings to turn it off or change the number of colors yet.
- Duplicate line or selection (Cmd+D): with no selection the
  caret's line is copied below it and the caret moves into the copy at the same
  column; with a selection the selected text is copied right after itself and the
  copy becomes the new selection, so repeated presses grow the text. A multi-line
  selection is duplicated exactly as selected rather than rounded out to whole
  lines, and each duplication is a single undo step. In a CRLF- or CR-delimited
  file, duplicating the *last* line — the one with no line terminator — inserts a
  plain LF; every terminated line copies its own terminator verbatim. When the
  Local Changes panel has keyboard focus, Cmd+D opens the selected changed file's
  diff (or the merge resolver for a conflicted file); Cmd+Down opens the file
  itself and moves keyboard focus into the editor; with no row selected either
  does nothing and does not beep. macOS only for now — an iOS
  variant for an external keyboard and an Edit > Duplicate Line menu item are
  out of scope.
- Toggle comment (Cmd+/): comments or uncomments the selected lines using the
  language's comment syntax. With no selection, it toggles the caret's line,
  moving the caret to the next line. Each toggle is a single undo step. Line-comment
  languages (Swift, JS/TS, Python, Go, Rust, YAML, Dockerfile, dotenv,
  gitignore, SQL, EditorConfig) insert or remove `//`, `#`,
  or `--` after leading indentation; block-comment languages (HTML, CSS) wrap the
  non-blank edges of the selection in `<!-- -->` or `/* */`, or unwrap them if
  already present. A wholly blank target is a silent no-op, leaving the caret
  and text exactly where they are. JSON, Markdown, and files with an unknown
  language also ignore the command silently, as they have no comment syntax to
  toggle. A menu item (Edit > Toggle Comment) exists, so the command works from
  the keyboard (Cmd+/) or the menu. macOS only for now — no iOS wiring.
- Find and replace in a file (macOS): Cmd+F opens a search bar
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
  In a regular-expression search `^` and `$` are **line** boundaries
  — `^import` finds every import line, not just one at the
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
- Go to Definition: Cmd+click an identifier — put the caret in it and press
  Ctrl+Cmd+J (Find > Go to Definition), or right-click it and choose Go to
  Definition, which acts on the word under the *click* rather than under the caret
  — to jump to where it is declared, in this
  file or anywhere in the open project (for Swift on macOS it reaches beyond it,
  into dependencies and the SDK — see below). The caret lands on the declaration's
  *name*, the file is opened (or its tab re-selected) as needed, and when several
  declarations share the name a small menu at the click point lists them as
  `Container.name — path/to/file.swift:42`, with the current file's first. A name
  nothing declares just beeps. Cmd+drag still selects text, and Cmd+Shift+click /
  Cmd+Option+click keep their usual meaning.
- Right-clicking in the editor (macOS) adds **Go to Definition**, **Find Usages**
  and **Rename…** below the standard text menu (Cut/Copy/Paste, Look Up, Services
  and the substitution submenus all stay). All three act on the name under the
  click rather than under the caret, and all three are greyed out unless the click
  landed on one.
- Column selection (macOS): middle-button drag selects a vertical column (rectangular selection), a purely vertical drag gives multiple insertion points, a plain middle click just places the caret, and the wheel still scrolls. Option-drag still works.
- Autocompletion: as you type an identifier (from the second character), a custom popup
  offers the project's declarations, the keywords of the language you are typing
  in, and the words already in the buffer. The first row is preselected on open. Pressing **Enter** commits the selection by inserting the text; pressing **Tab** commits by replacing the whole identifier under the caret. You can use **Up/Down** arrows to navigate (clamped, no wrap-around), **Esc** to dismiss without inserting, or click on a row to commit it. Each row includes an icon badge indicating its kind (symbol, keyword, or word). Only the declarations you could
  actually type are offered: a Markdown heading is never one (it is a place to
  jump to, not a word you write), and neither is any indexed name that is not a
  single word — `Getting started`, `run(_:)`, a hyphenated CSS class like
  `btn-primary`, a multi-word YAML key. Go to Definition and Go to Symbol still
  find every one of them. Matching is **fuzzy/camelCase**, not
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
  which likewise no crate declares), Dockerfile (`FROM`,
  `HEALTHCHECK`, … in the uppercase
  they are written in), and EditorConfig (property names and value literals); the data formats, Markdown and `.gitignore` deliberately
  have no list, and HTML/CSS are left out until completion knows about position.
  Type a `.` after an identifier or a closing bracket and the list opens right
  there with that receiver's members — methods, properties and constants that
  belong to a type — with the members of the type you actually named
  (`Worker.`) ranked above everyone else's. Arrow keys or the
  mouse choose, Return inserts, Esc dismisses, and the insertion is a single undo
  step. Ctrl+Space (Find > Complete) asks for the list explicitly, from the first
  character, and works after a dot too. Nothing pops up mid-composition with an
  input method. If you would rather it stayed out of the way, there is a
  **lightbulb button at the right end of the always-visible bottom bar** (beside
  the branch switcher, and with a matching "Offer completions as you type"
  checkbox in Preferences → General — the two are the
  same switch) that turns completion off entirely: no popup as you type, and
  Ctrl+Space / Find > Complete do nothing either, the menu item greying out to
  say so. The choice is remembered across launches, takes effect on the next
  keystroke in either direction, and dismisses a popup that is already open.
  Go to Definition is unaffected — the symbol index and any running language
  server keep working exactly as before, so turning completion back on costs
  nothing.
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
  indexed too — as navigation targets in full, and as completions only where the
  name is a single word (above). A file type with no query still completes from the words in the
  buffer.
- Semantic code intelligence for **Swift** (macOS): when Xcode is installed, Swift
  files are answered by `sourcekit-lsp` — found through `xcrun` in the active
  toolchain, started on demand for the project you opened, and never bundled or
  downloaded. Go to Definition becomes a real, compiler-backed jump: across modules
  of a package, into a dependency, and into the SDK. A declaration that lives
  *outside* the opened folder — an SDK interface, a dependency checkout — opens in a
  separate **read-only** window (syntax-highlighted, with the same line-number
  gutter — no blame column — and the same code zoom, one window per file) rather
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
- Semantic code intelligence for **TypeScript / JavaScript, Python and YAML**
  (macOS), if you want it. These servers are not bundled — the app offers to download them,
  once, the first time you open a file of that kind: a strip above the editor names
  the server and its size, with **Download** and **No Thanks** and nothing else.
  Nothing is fetched until you press Download, and nothing is fetched again if you
  don't.
  What arrives is `typescript-language-server` (with the `typescript` it drives),
  `pyright`, or `yaml-language-server` (with the twenty small packages it loads at
  run time), plus one shared Node runtime all three of them use. The first
  acceptance is about **57 MB** (Node is most of it); each further server costs
  about **4–5 MB** because the runtime is already there. The size the
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
  one of three servers frees only its own few MB, because the ~52 MB Node runtime
  they share goes away with the *last* one. Declining is remembered
  across launches and is turned around from that same screen. To de-provision
  everything by hand, quit the app and delete the `LanguageServers` folder above.
  That folder — and the Remove button — cover **what Pisaka installed**: a `gopls`
  of your own in `~/go/bin` is used from where it is, so deleting the folder does
  not touch it and no Remove button is offered for it.
  Acknowledgements (Preferences) grows a *Language Servers* section listing what is
  installed and its verbatim licenses, and loses it again when you remove them.
  **The YAML server is the one that keeps using the network after it is
  installed**, and the download prompt and its Settings row both say so before you
  accept: a YAML file's meaning lives in a JSON schema no bundled byte could
  contain, so the server fetches a catalog from `schemastore.org`, then the schema
  itself from whichever host that catalog names — or from the URL the file names
  for itself, either in a `# yaml-language-server: $schema=` header comment or in
  a plain top-level `$schema:` key. That is what
  completes `services` in a `docker-compose.yml` against the real compose schema
  rather than against words already in the buffer. None of that traffic is pinned
  or checksummed the way the download is; nothing lands on disk for it, so Remove
  still takes the server away completely.
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
- **Hover types** (macOS): rest the pointer on a symbol for a moment and a small
  popover shows what the language server says it is — the type or signature in
  the editor's own monospaced font, and whatever documentation the server attached
  to it below. It works in every language that has a server running (Swift,
  TypeScript/JavaScript, Python, Go, Rust), needs no setting and has no shortcut:
  the pause *is* the trigger, and moving the pointer off the symbol takes it away
  again. So do scrolling, typing, clicking, switching tabs and switching to
  another window.
  It is **purely something to look at**: the popover cannot be clicked, selected,
  copied from or scrolled — every mouse event passes straight through it to the
  code underneath, so a click where the popover appears to be selects the text
  below it exactly as if nothing were there. Long answers are cut off after about
  twenty lines with an ellipsis, and a very wide signature is trimmed at the
  popover's edge rather than wrapped; the whole declaration is one Cmd+click away.
  There is **no hover without a language server** — the built-in index matches
  names and knows nothing about types, and a plausible guess about the wrong
  `count` would be worse than nothing — so on a machine with no Xcode, in a
  language with no server, or while a server is still starting, nothing appears.
  Nothing is ever reported: no server, no answer, a slow answer and a failure all
  look the same, which is no popover at all. Flagged code extends the same
  popover: resting the pointer on an underlined span shows each of its diagnostic
  messages above the type answer (prefixed "error: …", "warning: …"), and it does
  so even when the span is punctuation rather than an identifier — or with no
  type answer at all beneath it.
- **Diagnostics** (macOS): with a language server running, its errors and warnings
  appear in three places while you work — a wavy underline under the offending
  code, a small severity dot in the gutter beside each affected line, and a
  **Problems** panel in the bottom dock listing every open file's findings. The
  panel toggles with "Show/Hide Problems" in the View menu, the ⚠ button on the
  bottom bar, or Cmd+Shift+M, and shares that one dock with Terminal, Git Log,
  Local Changes and Usages. Its header counts errors and warnings across all files; rows
  are grouped by file (path relative to the opened folder) showing severity icon,
  message and line number, ordered top-to-bottom through each file with the most
  serious finding first where several share a position. Clicking a row opens (or
  re-selects) that file and reveals the exact range — the same path Find in Files
  and Go to Definition use — and resting the pointer on an underlined span shows
  its message in the hover popover ("error: …"), above the type answer when there
  is one. Everything tracks your typing: fixing the flagged code removes its
  underline on the first keystroke while findings elsewhere stay anchored to
  their lines, and the server's next report (a fraction of a second after you
  pause) replaces the whole picture — including clearing everything on an
  all-clear. Closing a file drops its rows; quitting or crashing a server clears
  everything it reported. Because the reports arrive unasked, opening a file of a
  served language is itself what starts its server (where available or consented)
  — before diagnostics existed, a server started only when you asked for
  completion, Go to Definition or hover. Diagnostics need a server: files of languages without
  one show none of this, silently, exactly like hover.
- **Find Usages** (macOS, Ctrl+Cmd+U): put the caret in a name — or right-click
  it — and every place it is used appears in a **Usages** panel in the bottom dock,
  beside Problems. Rows are grouped by file (path relative to the opened folder)
  with the line number and the line itself, the occurrence emphasized; clicking one
  opens or re-selects that file and reveals the occurrence, the same way Find in
  Files and Go to Definition do. The panel toggles with "Show/Hide Usages" in the
  View menu, its bottom-bar button, or Cmd+Shift+U — showing it never re-runs
  anything, it holds whatever the last Ctrl+Cmd+U asked. The file you asked from
  comes first; everything after it is in path order, and the list is capped at
  **2 000** usages, with the header saying “more not shown” whenever what you are
  looking at is only the head of a longer answer.
  **The header always says what the rows mean, and this is the part worth
  reading.** With a language server running for that language, the rows are the
  server's resolved references: every one of them really is that symbol. Without
  one — or when the server has nothing to say — Pisaka answers with a **whole-word
  text scan** of the project instead, and the header says "textual matches". Those
  are exactly what they sound like: places that *spell* the name, found by the same
  rule that decides what a Cmd+click resolves (so `foo` is found in `foo.bar` but
  not inside `foobar`, `_foo` or `foo_`, and non-ASCII names work), with no idea of
  scope, shadowing or types. A local `count` in one file and an unrelated
  property `count` in another are both listed, because a text scan cannot tell them
  apart and pretending otherwise would be the dishonest option. The scan honors
  your `.gitignore`, skips binary and very large files, reads unsaved tabs as you
  see them rather than as the disk holds them, and fills the panel as it goes. With
  no folder open it scans the current buffer alone. Nothing is ever reported as an
  error: no server, a slow server and a server that answered nothing all look the
  same, which is the textual list.
  A row is a snapshot of where things were when you asked. If the file has changed
  since, clicking the row **opens the file without selecting anything** rather than
  revealing a span that is now something else. A server can legitimately name a
  file outside the opened folder — an SDK header, a dependency checkout — and such
  a row opens in the same **read-only viewer window** a Go to Definition outside
  the project uses, never as an editable tab.
- **Rename** (macOS, Ctrl+Cmd+R): rename the symbol under the caret — or under a
  right-click — across the whole project, through the language server's own
  understanding of it. A small dialog asks for the new name, prefilled with the old
  one and refusing anything that is not a single identifier, or that is the name it
  already has. Every file the server names is then rewritten in one go: open tabs
  in their buffers (left dirty, so your ordinary save puts them on disk), and files
  with no tab open on disk directly.
  **There is no rename without a language server, deliberately.** If no server
  serves that language, or the one that does cannot rename, or it answers with
  nothing to change, Pisaka beeps and nothing happens — no dialog, no alert, no
  explanation. The alternative would be renaming by text match, which looks
  identical to a correct rename right up to the moment two different symbols share
  a spelling, and then has quietly rewritten the one you were not looking at, in
  files you never opened. A command that is sometimes unavailable is a smaller
  problem than a command that is usually right.
  **It is all-or-nothing, and it is not one undo.** If any file changed between the
  server's answer and the moment of writing — you typed in it, a git command ran, another
  editor saved it — the whole rename is refused with an alert naming that file, and
  **nothing at all is written**. When it does apply, only the tab you are *looking
  at* gets a single undoable step: every other open tab is rewritten in place and
  **loses its undo history**, and files with no tab open change on disk with **no
  undo at all**. So a rename is not reversible as a unit. What is: Local History
  takes a **"Before Rename"** revision of every file it is about to touch, before
  it touches any of them, so each one can be restored individually
  (Cmd+Shift+H). There is no preview of what will change and no way to opt one file
  out — the rename is applied as the server described it.
- A minimap to the right of the editor: a scaled-down,
  syntax-colored overview of the file with a draggable viewport rectangle.
  Click or drag the rectangle to scroll the editor, or scroll the mouse wheel
  over the minimap; scrolling the editor moves the rectangle. Each line keeps a
  fixed minimap height, so for long files the
  overview slides as you scroll rather than squeezing the whole file into the
  panel; colors follow the system light/dark appearance.
- Syntax highlighting (tree-sitter via ChimeHQ's Neon) for Swift, JavaScript,
  TypeScript, JSON, Markdown, Python, Go, Rust, HTML, CSS, YAML, Dockerfiles,
  `.env` files, `.editorconfig` files, and dot-prefixed ignore files (`.gitignore`, `.dockerignore`,
  `.npmignore`, `.eslintignore`, `.prettierignore`, …). The language is
  detected from the whole file name, not just its extension — so `Dockerfile`,
  `Dockerfile.dev`, `.env.local`, `.editorconfig` and any dot-file ending in `ignore` are
  recognized even though they carry no extension. Colors follow the system
  light/dark appearance, and files with no detected language are shown as plain
  text.
- Each tab keeps its own independent text; switching tabs swaps the editor
  contents.
- Save writes to the file's URL; "Untitled" files prompt for a location. When
  the project's `.editorconfig` asks for them, the on-save transforms
  (trailing-whitespace trimming, a final newline, line-terminator normalization)
  are applied first, on every save path — see EditorConfig above.
- Autosave: a file with unsaved changes is written to disk
  automatically — a short idle delay after you stop typing, when the app loses
  focus, when you switch tabs, and when you quit (Cmd+Q). "Untitled" files (with
  no path yet) are never autosaved, so autosave never pops a Save As panel.
- While one of the app's own git operations is writing to the working tree — a
  revert, a merge apply, a branch checkout, a project-wide Replace All, or a
  commit — saving (Cmd+S, the close prompt's Save, and the implicit save before
  Run and Run Test), the project-tree create/rename/delete/move (a drag-and-drop
  move included), and switching the project folder are refused with a
  "Git operation in progress" notice rather than racing git over the same files.
  Autosave pauses for the same window and resumes on its own afterwards.
- Switching to another folder (macOS) swaps the tabs along with the tree: the
  project you leave keeps its tabs and selection, and the one you open comes back
  exactly as you left it — empty the first time you open it, rather than showing
  the previous project's files behind the new tree. "Untitled" buffers travel with
  their project. The bottom bar holds a **project switcher** (a folder icon on the right, next to the branch switcher) listing your recent projects; clicking one switches to it instantly, and its "Open Folder…" item is the same Cmd+Shift+O. Re-opening the folder already open changes nothing. Before the
  switch every unsaved titled file is written to disk; if one cannot be written
  the switch is refused and an alert names it, because switching would close it and
  lose those edits (save it elsewhere or close its tab, then switch). The very
  first folder you open in a run is the exception in one way: there was no project
  to file the already-open tabs under, so they are carried into the folder you
  open instead of being closed. The last 20 projects are remembered; opening a
  21st drops the least recently opened one's session.
- Session restore on launch (macOS): starting the app brings back the last
  session — the last opened project's folder, its open tabs in the same order, and
  the tab that was selected. Sessions are kept **per project**, so returning to a
  project you opened earlier restores that project's own tabs, not the last one
  you were in. "Untitled" buffers get hot exit: their text survives a restart
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
- **Local History (macOS)**: a safety net independent of git. Every time the app
  writes a file — Cmd+S, any autosave, a Save As, the close prompt's Save, the
  saves before Run and Test, and the flush on quit — it keeps a private copy of
  what it wrote. It also takes a *labeled* copy of every file that is about to be
  overwritten by one of the seven operations that rewrite the working tree: a
  commit (whose `pre-commit` hook may reformat), a project-wide Replace All, a
  revert, a merge apply, a branch switch or checkout, a branch create, and a
  project-wide Rename. Those
  rows read "Before Revert", "Before Replace All" and so on, and they are taken
  *before* the operation runs, so what they hold is the state you would otherwise
  have lost — unless those exact bytes are already the newest revision, which an
  autosave moments earlier has usually just made them: the copy is not taken
  twice, and the state you would have lost is the one under the "Save" row above.
  Open the history with **File ▸ Local History…** (Cmd+Shift+H) for the
  active tab, or with the **"Local History"** item on a file's context menu in the
  project tree. The window lists that file's revisions newest first, each with the
  event that took it and both a relative ("2 hours ago") and an absolute
  timestamp; selecting one shows a side-by-side diff of that revision against what
  the file holds *now* — the open buffer if a tab has it, including unsaved edits,
  and the file on disk otherwise. **Restore** puts the selected revision back into
  the buffer as a single edit: one Cmd+Z undoes it, the tab is left unsaved so
  nothing reaches disk until you save (or autosave does), and the text it replaced
  is itself snapshotted first, so a restore is reversible from the history too.
  A revision whose text the file already holds cannot be restored — the diff
  shows no differences and **Restore** is greyed out, so the button always agrees
  with the panes above it. It re-reads the file whenever you click back into the
  window, so an edit made in the meantime re-arms it. A
  file the app has never written simply says "No history for this file yet." —
  that is not an error. Nothing about this is configurable and there is nothing to
  turn on. **Retention**: a revision is kept for **14 days**, each file keeps its
  **30** most recent, and the newest revision of a file is never deleted no matter
  how old it is. Identical content is not stored twice, so a save that changed
  nothing adds no revision. Files larger than **1 MiB** and files that are not
  text are skipped, silently, as are "Untitled" buffers and files outside the
  open project — asking for the history of a file outside the project says "This
  file is not in the open project, so it has no history." rather than showing an
  empty window. There is one window, and opening history for another file
  retargets it.
- Closing a file with unsaved changes shows a Save / Don't Save / Cancel dialog.
- Local Changes: a collapsible bottom panel (toggle with "Show/Hide Local
  Changes" in the View menu, the Changes button on the bottom bar, or
  Cmd+Shift+C) listing files differing from `HEAD` (via `git`).
  View the list flat or grouped by folder; each file shows a type icon tinted by
  its git status plus a one-letter badge (M/A/D/R/U/C). Double-click a file to open
  a side-by-side diff (`HEAD` vs working copy) in a separate
  window, with aligned panes, red/green row backgrounds, per-side line-number
  gutters, change markers, synced scrolling, and syntax highlighting. A
  **"Show Diff"** item appears first in a non-conflicted file's context menu
  (above "Jump to Source", "Commit…" and "Revert") and opens the same diff;
  conflicted files keep their existing "Resolve…" item. **"Jump to Source"**
  opens the changed file itself (the worktree copy, not the diff) — omitted for
  deleted files (no worktree source), shown normally for conflicted files (opens
  the marker-carrying copy). Press **Cmd+D** while the panel has keyboard
  focus to open the selected file's diff (or the merge resolver for a conflicted
  file); press **Cmd+Down** to jump to the file itself and move keyboard focus
  into the editor; with no row selected either shortcut does nothing. A deleted
  row offers neither jump; a successful jump moves keyboard focus into the editor
  so typing continues immediately. The list
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
- Commit (macOS): a modal dialog, opened with Cmd+K (Git > Commit…),
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
  What is committed is exactly what is selected in the UI —
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
  context menu) opens a 3-pane merge editor in a separate window
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
  Cmd+Shift+L). It shows a commit table — short
  hash, ref/branch/tag badges, subject, author, and date — with a colored branch
  graph in the left gutter that draws lanes for branches and merges. A "Load
  more" affordance fetches an additional page of history. Selecting a commit shows
  the files it changed (against its first parent; a merge shows its mainline diff);
  double-click a file to open its side-by-side diff in a separate window — the same
  viewer as Local Changes. A filter bar above the table narrows the history
  server-side by branch
  (or "All"), author, date range (since/until), and path, and a search box filters
  the loaded commits by message text client-side (no re-query). The date range is a
  checkbox plus a day picker per bound: unticking Since or Until drops that bound
  but keeps the day already picked, so re-ticking it filters from the same day
  again rather than from today — for as long as the bar itself lives, which is
  while the Log panel stays shown; switching the bottom dock to another panel or
  hiding it rebuilds the bar, and its pickers then open on today.
  Every control shows the filter the panel is
  actually displaying, including one the app applied itself — switching folders
  clears the filter and the search box immediately. (On iPhone/iPad the advanced
  filter is a sheet built fresh on each presentation, so its pickers open on today
  rather than remembering an unticked day.) All git access is
  read-only — no history mutation, and (like Local Changes) no filesystem
  watching: both panels refresh on demand.
- Branch switcher: a widget in the always-visible bottom bar shows
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
  Git Log, Local Changes, Problems and Usages panels share one bottom dock —
  opening one replaces whichever was shown. The terminal follows the app theme — the system light/dark
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
- **Zoom, in three independent zones, targeted by the pointer.** Cmd+= (or
  Cmd++), Cmd+− and Cmd+0 in the **View** menu zoom in, out and back to normal —
  and so do Ctrl-scroll, Cmd-scroll and a trackpad pinch, which feel continuous
  and land on exactly the same sizes the keyboard produces. What grows is decided
  by **what the pointer is over at that moment**, in whichever window it happens
  to be over:
  - over the editor, a diff or merge pane, the read-only source viewer, a Find in
    Files result, the LeetCode statement text, or the commit dialog's diff and
    message box → the **code** zone, i.e. the shared editor font size, exactly
    what the Preferences row sets. The editor's gutter, its blame column and the
    minimap follow that size as always — and count as the editor for this
    purpose, so zooming with the pointer over any of them grows the code too;
  - over the terminal → the **terminal** font size, its own setting. The running
    shell survives and reflows to the new cell size — nothing is restarted — and
    the panel's tab strip does not change;
  - over anything else — the project tree, the tab list, the bottom bar, the Log,
    Local Changes, the commit dialog's own chrome, Preferences, the LeetCode
    browser → the
    **interface** scale, which grows the chrome proportionally: fonts, paddings,
    row heights, icon sizes and pane widths together, from 80% up to 200%.
  The three are stored separately and never affect one another, so Cmd+0 resets
  only the zone under the pointer. With the pointer outside every Pisaka window,
  the shortcut falls back to whatever the focused surface is (the editor or the
  terminal), and to the interface otherwise. Everything persists across launches;
  the code zone and the Preferences font-size row stay in sync in both
  directions, because they are one value.
- Preferences (Cmd+,): a Settings window with five persisted options — tab
  orientation (a vertical column beside the editor, or a horizontal strip above
  it), theme (follow the system, or force light/dark), a shared editor font
  size used by the editor, diff, and merge views, a terminal font size, and
  whether the editor offers
  completions as you type (the same switch as the bottom bar's lightbulb). The
  two font sizes are also adjustable on the fly by zooming over a code view or
  over the terminal (see Zoom above); the interface scale has no row of its own
  and is set by zooming over the chrome.
  All five settings persist across launches. The Settings window's other tabs are **Language
  Servers** (what may be downloaded, and what is installed), **LeetCode** (the
  account, the solutions folder, and the language new solution files are seeded
  in) and **Acknowledgements**, which lists every third-party dependency the app
  ships — name, SPDX identifier, version/revision, and upstream origin — beside
  its full license text, shown verbatim and selectable.
- LeetCode integration, in its own **LeetCode** menu. None of it needs an open
  project, and opening a problem never changes the project root — the solution
  file just opens as an ordinary tab.
  - **Sign In…** opens leetcode.com's own login page in a web view, so the SSO
    providers (GitHub, Google, …) sign you in as they do in a browser, as long as
    the provider redirects in place rather than opening a popup window (see Known
    limitations). The sheet stays up for the whole round trip and comes down only
    once LeetCode has confirmed the session — the cookies alone are not one. The
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
- **Database viewer (macOS only).** A file named `.sqlite`,
  `.sqlite3` or `.db` opens into a viewer tab instead of the editor: a sidebar
  listing the database's tables and views (marked apart), the selected one's
  schema under it — column name, declared type, primary-key position, `NOT
  NULL`, default expression, and whether the column is hidden or generated — and
  a grid of its rows beside them. The grid pages 200 rows at a time with
  Previous/Next and a footer saying which rows of how many are on screen, and
  every column header sorts: the first click sorts ascending, clicking the same
  header again flips the direction, and selecting another table clears the sort.
  Every page is a fresh bounded query, so a table of any size costs one page-sized
  read. **NULL and the empty string are drawn differently** — a missing value
  reads `NULL` and is styled apart, an empty text cell is simply empty — and a
  blob shows a `BLOB (n bytes)` placeholder rather than its bytes. Anything that
  goes wrong is shown in a banner at the top of the tab **in SQLite's own words**
  ("file is not a database", "database is locked") — or, for an answer whose shape
  the app could not read, a sentence saying what it refused — and a failure leaves
  the rows you were looking at in place rather than blanking them. The tab behaves
  like any other: it carries the database icon in the project tree, is restored
  with the session, and closes without ever asking to save — it holds no text and
  can never be dirty. Merely *opening* a viewer tab never changes the file on
  disk: the tab's connection is opened read-only. (One consequence: a WAL
  database whose sidecar files were left behind by a process that died without
  checkpointing may refuse to open, in SQLite's words, where a read-write
  connection would have recovered it.)
- **Editing a cell.** Double-click a cell — or press Return while it has the
  keyboard — to edit it in place; Return writes it, Escape cancels and writes
  nothing. The write is one `UPDATE` of one row inside a transaction, addressed
  by the row's identity **and** by the value the grid was showing, on a separate,
  short-lived read-write connection (the tab's own stays read-only for its whole
  life). It commits
  only if exactly one row changed: if somebody else changed that row between the
  page being read and Return, nothing is written and the tab says so
  ("this row changed underneath you"). A commit is followed by a WAL checkpoint,
  so the edit reaches the database file itself rather than sitting in the `-wal`
  sidecar: without it the write would be complete and durable and yet leave the
  tracked bytes untouched, so Local Changes, `git commit` and the git-based undo
  below would all miss it. What the checkpoint does *not* do is remove the
  sidecars — SQLite unlinks `-wal`/`-shm` only when the last connection to the
  database closes, and the tab's own read-only one is still open — so on a WAL
  database they stay beside the file until every connection to it is gone. What you type is stored as the column's
  declared type implies — typing `43` into an `INTEGER` column stores the number,
  into a `TEXT` column the two characters — and in a column declared with no type
  at all the cell keeps the kind of value it already held. Nothing is trimmed, an
  empty field stores the **empty string**, and `NULL` is *not* reachable by
  typing the word: it is the cell menu's **Set to NULL**, next to a Copy of what
  the cell is showing. What cannot be edited says so in a tooltip and in the
  banner if you try anyway: a view's rows (they are computed), a generated or
  hidden column, a cell holding binary data, a column whose name the table's
  schema cannot resolve to exactly one column, and a table that declares neither
  a row id nor a primary key. An edit is also refused — with a sentence, and
  without writing anything — while the project is being rewritten on disk (a
  branch switch, a revert, a merge, a commit, a project-wide Replace All or a
  Rename), and while another edit in the same tab is still being written. A committed edit shows up in Local Changes like any other
  change to a tracked file, and is undone the way any other file change is: with
  git, or in the database's own tools. There is no undo inside the viewer.
- **The SQL console.** Under the grid, in a pane you can drag taller or shorter,
  is a console: type SQL, press **Run** (Cmd+Return), and get an answer. What
  happens next depends on what you typed, and the app asks SQLite rather than
  guessing — nothing runs until every statement in the text has been *prepared*
  and SQLite has said which of them can change the database.
  - **Statements that only read run straight away**, in the order you typed them,
    on the tab's own read-only connection. The result table shows the last
    statement that answered columns, with values drawn exactly as the grid draws
    them (a `NULL` styled apart from an empty string, a blob as its size), and
    the footer counts the rows. A read is capped at **500 rows** — nothing is
    appended to your SQL, the rows are simply stopped there — and when the cap is
    reached the footer says so ("500 rows · first 500 rows shown").
  - **Anything that can change the database asks first.** The confirmation says
    how many statements were classified, how many of them write, and that they
    run as one transaction that rolls back whole if any of them fails. Agree and
    the whole text runs on a separate, short-lived read-write connection and the
    footer reports what it changed ("3 rows changed", or "No rows changed" — an
    honest outcome for a `DELETE` that matched nothing or a `CREATE TABLE`).
    Decline and nothing is sent. A mutating batch reports that count and nothing
    else: rows a `SELECT` inside it produced are not shown, which the
    confirmation says before you agree to it.
  - A text whose later statements depend on what its earlier ones create — the
    familiar `CREATE TABLE …; INSERT INTO …;` shape — is exactly the case SQLite
    cannot see through before running it, because it resolves table and column
    names as each statement is prepared. The console does not refuse such a
    script: if what it *could* classify holds a write, the confirmation says so
    and the rest is classified as it runs, inside the same transaction. If what
    it could classify is read-only, the failure is the answer and you are shown
    SQLite's own sentence, because a read cannot have created what the next
    statement needed.
  - **Every failure carries SQLite's own words**, and a failed run changes
    nothing on screen: the previous result and its footer stay where they were,
    with the message under them. After a mutation commits, the sidebar, the
    schema, the row count and the page are all re-read — a batch may have created
    or dropped the very table you were looking at — and the database shows up in
    Local Changes like any other change to a tracked file. While a write is in
    flight, Run, the paging buttons and the sort headers are all disabled, and a
    mutation is refused outright while the project is being rewritten on disk.
  - The console holds no history and no saved queries, and its text is not part
    of the session: it belongs to the tab and goes with it.


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
  highlighting (Neon), auto-indent (`IndentEngine`), EditorConfig-driven
  indentation (`IndentUnitRule` — the same six properties, the same Enter and
  Tab behavior, and the same on-save transforms on the one save iOS has, the
  close confirmation's **Save**, where the file is trimmed in full because the
  buffer is being closed and there is no caret left to protect; with no watcher
  on iOS, an edited `.editorconfig` is picked up on
  a folder switch or after the app's own working-tree rewrites rather than
  immediately), and auto-close brackets/
  quotes (`AutoPairEngine`) as macOS. Font size follows the shared
  `SettingsStore` preference; pinch-to-zoom steps it (the iOS analog of the macOS
  code zoom — iOS has no terminal or interface zone). The editor's line-number
  gutter and minimap are deferred on iOS
  (the side-by-side diff panes do still draw per-side line numbers).
- The same index-based code intelligence as macOS (there is no language server on
  iOS, so Swift is answered the same way every other language is — and, since the
  hover popover needs one, there is no hover on iOS either), through
  touch-appropriate surfaces:
  **Go to Definition** is an extra item in the selection's edit menu (tap an
  identifier → "Go to Definition"), which jumps straight there, or asks which
  declaration you meant when several share the name; a name nothing declares gives
  a light haptic. **Completion** is a QuickType-style strip above the keyboard —
  it appears from the second character typed (or as soon as you type a `.`, with
  that receiver's members), offers the same fuzzy/camelCase matches and language
  keywords as macOS, scrolls horizontally, tapping a word
  inserts it as one undo step, and it disappears when there is nothing to offer,
  so it works the same with the on-screen and a hardware keyboard. The strip can
  be switched off with "Offer completions as you type" in Settings → Editor — the
  same preference as the macOS status-bar lightbulb, remembered across launches
  — which makes it disappear on the next keystroke and come back as soon as you
  turn it on; Go to Definition keeps working either way. iOS has no
  file-system watcher, so the index is built when you open a folder and kept
  current as you open tabs and type, but it does not notice changes made to the
  files by another app.
- A Preferences sheet bound to the same `SettingsStore` (theme, tab orientation,
  font size, completions on/off), with an **About → Acknowledgements** screen listing the same
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
- The database viewer is macOS-only. Opening a `.sqlite` or `.db` file on iOS
  behaves exactly as it did before the viewer existed: the file is read as text,
  fails to decode, and the open reports that — an honest failure rather than a
  tab claiming the database is empty.

## Known limitations (1.0), in detail

- Automatic updates are macOS-only and have no settings of ours: the only
  choices offered are the ones Sparkle's own UI provides — the first-launch
  "check automatically?" prompt, and Skip This Version / Remind Me Later on the
  update alert itself. There is no update channel, no check interval and no
  release-notes pane beyond what the appcast carries. DEBUG builds never update.
  Released builds are Developer ID signed, notarized and stapled, so a download
  launches from the ordinary “downloaded from the Internet” confirmation instead
  of being refused by Gatekeeper (see “Installing a released build” in
  `README.md`). The update signing key is a single EdDSA
  pair — if it is ever lost, installed copies will reject every future update
  and can only be moved forward by downloading a new build by hand.
- Local History is macOS-only, and it only ever sees **the app's own writes**.
  Edits made by another application, a `git` command you run yourself (in the
  embedded terminal or anywhere else), or any other change made outside Pisaka's
  save funnel and its seven worktree operations are not captured and leave no
  revision — the folder watcher keeps the project tree current, it does not
  snapshot. The store holds **copies of your file contents on the local disk**,
  unencrypted, under `~/Library/Application Support/Pisaka/LocalHistory`; anything
  a captured file contained — including a secret you removed afterwards — stays
  there until retention reclaims it (14 days, or 30 revisions of that file) —
  **except the newest revision of each file, which is never reclaimed at all**.
  That is the same rule that makes the feature a safety net rather than a tidy
  cache, and its price is that the last content Pisaka ever wrote for a given path
  stays on disk indefinitely: retention takes every path it has ever captured down
  to one revision and no further. Deleting that directory removes every revision
  completely and breaks nothing else; it is the only thing that does. There is no
  in-app "clear history" command, no export, and no setting for the retention
  numbers. A pre-operation capture reads at most **200** files from
  disk: in a working tree with more changed files than that, the extras are not
  snapshotted (open tabs are never capped, and are always captured from the buffer
  rather than from disk). Files over 1 MiB and non-text files are never captured —
  and because a restore first snapshots what it is about to displace, **Restore
  beeps and does nothing on a file whose current contents are past that ceiling**
  (a file that had history while it was small and has since grown past it): its
  revisions stay listed and readable, but the button will not replace megabytes
  the safety net has just declined to hold.
  The single-Cmd+Z guarantee applies to the tab you are **looking at**: restoring
  into a file with no tab open (one is opened) or into an open background tab
  costs that tab its undo history and its remembered scroll position, because the
  editor has not moved to it yet when the restore runs. A file one of the seven
  operations *deleted* — a reverted untracked file, a file a branch switch removes
  — can no longer be restored from its own "Before …" revision: the revision is
  still listed, but Restore replaces a buffer and there is none, so it beeps;
  re-create the file first. Two revisions of one file taken within the same
  millisecond are listed in a stable but non-chronological order (by event name,
  then content hash). Renaming, moving or deleting a file does **not**
  carry its history along: the store is keyed by the file's path inside the
  project, so a renamed or moved file starts an empty history and the revisions
  taken under its old path stay in the store, no longer reachable from any
  window; retention thins them to the newest one, which then stays for good like
  every other newest revision. The revisions *list* also does not refresh itself
  — a revision taken while the window is open (an autosave, an operation, or the
  copy Restore makes of what it replaced) shows up only after you open the
  history again. The diff and the **Restore** button do refresh, but only when
  you click back into the window; the relative timestamps on the rows keep up on
  their own, to the minute.
- Find/replace (per-file and project-wide) is macOS-only: iOS has neither the
  search bar nor the Find in Files window. There is no query history, no "replace
  in selection", and the project search reads tree `.gitignore` files only (not
  `core.excludesFile` or `.git/info/exclude`).
- The project tree supports create, rename, and delete (via a row context menu)
  and, on macOS, a move by drag and drop. That drag is intra-tree only — its
  payload carries a private type identifier, so nothing can be dragged to or from
  Finder — and it moves one entry at a time: there is no multi-select, no
  copy-on-drag (⌥ does nothing), no rename-on-drop, and no keyboard equivalent,
  so moving an entry needs a pointer. iOS has no tree drag and drop at all, and
  there the tree refreshes only after its own edits, not after changes made
  outside the app.
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
  Go to Definition, completion, hover types, diagnostics, Find Usages and Rename
  only — there is still no signature help, and nothing about the
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
- The downloadable TypeScript/JavaScript, Python and YAML servers are macOS-only
  and cover the same Go to Definition, completion, hover types, diagnostics, Find
  Usages and Rename — no status indicator and no log, and nothing about them is
  configurable: no per-project server, no extra options or arguments, and no
  version picker (the versions are pinned in the app and change only when you
  update it — and when an update does move a pin, the next TypeScript, Python or
  YAML file you open re-downloads the server at the new version without asking
  again,
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
  the app runs what you put there. The YAML server has one limit of its own: its
  schemas are not part of that pinned download, so offline — or on a network that
  blocks `schemastore.org` and the hosts it points at, or one that intercepts TLS,
  since those fetches check certificates like the download does — it keeps running but
  quietly falls back to what the buffer contains, which looks like a server that
  has stopped knowing things rather than like a failed download.
- The Go server (`gopls`) is macOS-only and covers the same Go to Definition,
  completion, hover types, diagnostics, Find Usages and Rename, with the same
  absence of a status indicator and a log. It needs a Go toolchain — there is no offer without one, and
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
  Definition, completion, hover types, diagnostics, Find Usages and Rename, with
  the same absence of a status indicator and a log. It needs a **Rust toolchain** — there is no
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
- The hover popover is macOS-only and deliberately minimal. It **needs a language
  server**: there is no index-based version of it, so every language and every
  situation without a running server simply shows nothing — and nothing is
  reported when a server has no answer, times out or is still starting either. It
  has **no keyboard trigger and no setting**: the pointer resting on a symbol is
  the only way to summon it, the delay before it appears is fixed, and there is no
  way to turn it off short of not pausing. It cannot be **clicked, selected,
  copied from or scrolled** — the panel passes every mouse event through to the
  code, which is what keeps it from interfering with selection and typing — so
  long answers are cut off after about twenty lines with an ellipsis and a wide
  line is trimmed at the edge rather than wrapped. What the server sends is
  *degraded* rather than rendered: fenced code becomes code and everything else
  becomes plain text with its emphasis, headings, rules, HTML tags and link URLs
  removed (a `<br>` leaves a space behind, and HTML entities such as `&lt;` are
  shown as written), so a table or a block quote in a documentation comment
  arrives as its own punctuation. There is no syntax colouring inside the popover, no links to
  follow and no "show more".
- The tree-sitter fallback — which is what every other language, and Swift without
  Xcode, always uses — is index-based, not a compiler: Go to Definition matches a
  *name*, so it cannot tell two same-named declarations apart (it lists both),
  knows nothing about imports, scope, generics or overload resolution, and finds
  nothing in dependencies outside the opened folder. It cannot enumerate
  *references* at all — a reference is not declared anywhere — so Find Usages
  answers from a whole-word text scan instead and says so; **rename refactoring is
  unavailable entirely** without a server, and so is the **hover popover** (both
  need a server — the index knows names, not types). There is no signature help,
  and completion offers
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
- Find Usages and Rename are macOS-only: iOS has neither the panel, the menu
  items nor the editor context menu, so it has no usages answer at all. On macOS,
  **Rename needs a language server** and is silently unavailable without one (a
  beep, no dialog); it has **no preview** of what it will change and no way to
  exclude a file, and it is **not undoable as a unit** — only the tab on screen
  gets an undo step, other open tabs lose their undo history, and files with no tab
  open change on disk with no undo, which is what Local History's "Before Rename"
  revisions exist for. Find Usages always answers something, but a **textual**
  answer is whole-word matches and not references: it lists every place that spells
  the name, including unrelated symbols that happen to share it. A usages row is a
  snapshot — nothing re-runs the query as files change — so a row whose text has
  moved opens the file without revealing anything.
- No tab reordering or split views, and no drag-and-drop outside the project
  tree.
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
  text are not restored — and a folder switch there leaves the previous project's
  tabs open, since there is no per-project session to swap them for. What comes
  back on macOS is the last opened project's folder, its tabs and the selected
  tab, but not per-tab caret or scroll positions — those are remembered only
  within an app run (see the editor section above) and are never written to the
  session — and not the bottom-panel / terminal / project-tree state. One session is kept per project
  (the last 20), so there is no history of earlier sessions *for the same project*
  and no setting to turn restore off.
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
  - The statement pane is a web view, and on macOS its text follows the **code**
    zoom zone (the shared editor font size), not the interface scale: zooming with
    the pointer over the statement grows the problem text, and raising the
    interface scale grows everything around it — the pane's header, the language
    row, the Run/Submit section — while the statement itself stays where the code
    zone put it.
  - A solution file is tied to its problem by its **name and its location**.
    Renaming it, or moving it out of the configured folder, detaches it — the
    description pane goes empty for that tab.
  - Premium problems your account cannot read are refused outright (no file is
    written) rather than opened with the locked part missing. A Premium
    subscription opens them normally — LeetCode sends the statement and the
    snippet, and the refusal is on the locked answer, not on the problem's
    Premium flag.
  - On iOS, solution files written to the default location are visible in the
    Files app under **On My iPhone → Pisaka → LeetCode** — which also means the
    app's whole `Documents` directory is browsable there (today the LeetCode
    folder is the only thing the app keeps in it).
  - Sign Out clears `leetcode.com`'s cookies, but cookies an SSO provider set on
    *its own* domain survive it, so signing back in may not ask for the password
    again.
  - Sign-in providers are followed **in the same web view**: GitHub's flow is a
    redirect chain and works, but a provider that drives its login through a
    **popup window** would have nowhere to open it and would stall. Not every
    provider was verified.
- The database viewer is **macOS-only**, and the *grid* writes **one cell at a
  time**: there is no way to insert or delete rows from it, no schema editing,
  no multi-cell edit and no undo inside the viewer — anything else is typed into
  the SQL console, which is SQL and not a second grid. On iOS a database
  file is not opened in a viewer at all (see above).
  The console's own limits: a mutating batch reports its affected-row count and
  shows no rows; a read batch is not one snapshot (its statements run one after
  another, so a database another process is writing can change between two of
  them); an `ATTACH` typed on its own runs on the tab's read-only connection and
  stays attached until the tab closes, and nothing can be written through it; and
  there is no query history, no saved queries and no syntax highlighting in the
  input. Binary (blob) cells, views,
  generated columns and tables with no row id and no primary key cannot be
  edited, and each says which of those it is. Only
  tables and views are listed — indexes, triggers and SQLite's own `sqlite_`
  bookkeeping tables are not shown — and the listing does not refresh itself
  while you are looking at it, so a table another process creates shows up only
  the next time the tab is selected (switching away and back is enough; the
  listing is re-read every time the tab is shown). The
  page size is fixed at 200 rows and there is no jump-to-page field. The row
  count is read once when a table is selected, so a table being written by
  another process shows a total that is a moment old; if rows were deleted under
  you, a page turn is clamped against that stale total and can land past the new
  end, showing no rows until the table is selected again and the count re-read.
  A database another process
  holds a lock on waits up to five seconds and then reports "database is locked"
  rather than hanging the tab. Encrypted databases and files that are not
  databases simply fail to open, with SQLite's own message in the banner.
