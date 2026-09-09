# PisakaCore + Pisaka app (macOS) — the Markdown preview

Design documentation for the Markdown preview pane: the document tree, the
renderer, the page and its policy, the app-scheme mapping in both directions,
the update ordering, and the six app files that supply the capability the Core
half decides with. Each entry records a file's contract, invariants and the
reasoning behind non-obvious decisions — read the relevant entry before
modifying that file, and update it when behavior changes.

## The shape of the feature, in one paragraph

A Markdown tab shows its file rendered beside the editor: editor left, preview
right, a draggable divider between them, View → *Markdown Preview* (⌘⇧P) to show
and hide it. **The preview writes nothing.** It never raises
`autosave.suspend()` / `localChanges.beginRevert()` and is never gated by them;
it reads a buffer the editor already holds, and its only persisted state is two
`SettingsStore` preferences — whether the pane is shown and where the divider
sits. Every *decision* is pure and lives in `PisakaCore`: what the document is
(`MarkdownDocument`), what it renders to (`MarkdownRenderer`), what the page is
and what it may fetch (`MarkdownPreviewPage`), which file a target resolves to
and back (`MarkdownPreviewAsset`), what a click does (`MarkdownLinkRule`), which
line the editor is at (`MarkdownScrollRule`), how wide each half is
(`MarkdownPreviewWidthRule`) and — the part that is usually the app layer's —
**when any of it happens** (`MarkdownPreviewModel`). The app layer supplies two
capabilities and no judgement: a parser (`MarkdownParser`, the feature's one
`import Markdown`) and a page (`MarkdownPreviewWebView`, its one `import
WebKit`), each behind a one-method seam. macOS only: iOS has no `WKWebView`
scheme handler surface, no menu item and no split, and its app files are
`#if os(macOS)` throughout.

## Decisions

### M1 — Raw HTML is dropped structurally, not filtered

`MarkdownDocument` has **no case** for an HTML block or an inline HTML span, so
`MarkdownParser` has nowhere to map one and it is gone. That is deliberately not
a filter: a filter is a branch that can be forgotten, re-enabled by a later case
or bypassed by a renderer that interpolates something it was handed, and a
filter's absence is invisible. With no target in the tree, the property holds for
every path through the mapping at once, and the renderer — which escapes every
author-supplied string exactly once (`MarkdownRenderer.escaped(_:)`) — has
nothing left that could reach the page as markup.

The same guarantee is stated a second time, from the other side, by the page's
CSP (M2): once where markup could enter, once where a script could. Two
independent reasons, so neither is the only one.

The cost is stated as a limit, not hidden: a document that uses raw HTML for
layout shows nothing where that markup was. Table cell spans, block directives,
symbol links, Doxygen commands and inline attributes are dropped for the same
structural reason.

### M2 — The page's CSP names no network origin at all

`MarkdownPreviewPage.contentSecurityPolicy` is emitted as a `<meta http-equiv>`
in the shell and reads:

```
default-src 'none'; script-src pisaka-preview: '<sha256 of the bootstrap>';
style-src pisaka-preview: 'unsafe-inline'; img-src pisaka-preview: data:;
connect-src 'none'; base-uri 'none'; form-action 'none'
```

No `http`, no `https`, no `ws`, no `*` — a document that cannot reach the
network cannot leak the contents of the file it is previewing. Term by term:

- `script-src` names the app scheme and **one hash**, never `'unsafe-inline'`.
  The hash is computed in Swift from `bootstrapSource`'s own bytes
  (`SHA256.digest(of:)`, base64), so the pinned line and the policy cannot
  disagree — changing the line moves the hash with it. Any *other* inline
  script, authored or injected, fails to match and does not run.
- `style-src` adds `'unsafe-inline'`, the one relaxation, and it is forced: the
  diagram renderer emits a `<style>` element into the SVG it builds, so a page
  refusing inline styles renders every diagram unstyled. It is the cheap
  relaxation to make precisely because `connect-src` is `'none'` and `img-src`
  carries no network origin — there is nowhere for a style to exfiltrate to.
- `img-src` adds `data:` for the same renderer's inlined raster fallbacks;
  project images arrive under the app scheme.
- `connect-src 'none'` is redundant with `default-src` and stated anyway, being
  the clause a reader looks for.
- `base-uri 'none'` and `form-action 'none'` close the two ways a document can
  re-point or post itself elsewhere without fetching anything.

### M3 — The page is *served*, never string-loaded

The shell HTML is handed to the scheme handler and the web view then **fetches**
it: `webView.load(URLRequest(url: MarkdownPreviewPage.shellURL))`, the one load
site in the feature. `loadHTMLString` is spelled nowhere, and
`MarkdownPreviewSourceGatingTests` pins that.

The reason is the origin. A string-loaded document has a **null origin**, and a
null origin can be granted access to nothing: every bundled file and every
project image would be a cross-origin fetch that fails, and the CSP the shell
carries would be enforced against nothing the handler serves. The alternative —
inlining the assets — is a 3.4 MB document per theme change. Serving the shell
under `pisaka-preview://preview/index.html` puts the document, the four bundled
files and every project image on **one origin**.

The failure this rules out is silent in exactly the wrong way: the page still
renders, just unstyled and unhighlighted, with no build error anywhere.

### M4 — The app-scheme vocabulary lives in one Core file, and the mapping is a function in both directions

The scheme (`pisaka-preview`), the host (`preview`), the shell path and the two
path prefixes (`/assets/`, `/file/`) are constants of `MarkdownPreviewPage`, and
**no app file spells any of them**. `MarkdownPreviewAsset` owns both directions:

- forward, `assetURL(forTarget:context:)` — the renderer hands it a source's own
  spelling of an `src`/`href` and emits what it answers;
- inverse, `projectFileURL(forPreviewURL:context:)` — the navigation rule and
  the scheme handler hand it a URL and receive the file it names;
- dispatch, `classify(_:context:)` — the handler's four-case answer (`shell`,
  `bundled(name:)`, `asset(fileURL:)`, `refused`), so the handler switches and
  decides nothing.

This is `GitHubCommands`' rule applied to a URL space. Two spellings would be
two answers to *which origin is this*, and the half that composes a URL and the
half that consumes one would be free to drift — in the one place where drift is
a file-access bug rather than a rendering one.

**The inverse is not a lookup of what the forward direction produced.** A page is
a document and can navigate to a URL its Markdown source never contained, so the
inverse re-derives the file from the URL and re-asks the containment question
from scratch, against the root it is handed *now*.

Containment is **canonical** — `CanonicalPath.canonical(_:)` on both sides,
compared component by component — because a lexical check answers yes for
`root/link/../../../etc/passwd` and for a symlink inside the tree pointing
anywhere at all. The *answer* is spelled from the root the caller gave, since
that is the spelling the rest of the app opens tabs under; only the check is
canonical.

An unresolvable target is emitted **as the source spelled it**, which renders as
a broken image showing its alt text and as a link the navigation rule refuses.
There is no third outcome: nothing is silently rewritten, and nothing is
dropped — a dropped image is indistinguishable from a document that never had
one.

### M5 — One page per window, retargeted

`ContentView` holds one `MarkdownPreviewController` as a `@StateObject`, so the
lifetime is the window's and a second window previews its own tab. The web view
and its handler are built once and **re-pointed** at whichever Markdown tab is
active — the Local History window's shape, for a sharper reason: a `WKWebView`
per tab is a web content process per tab, and switching tabs would re-load a
document instead of replacing a body.

**Nothing is built until the pane is shown.** The page and the model are `lazy`
on the controller, so a window whose preference is off — the default — pays one
object with two unevaluated properties. The first touch comes from
`MarkdownPreviewPane`, which exists only while the pane is on screen.

Both pieces of retargetable state live on the handler
(`shellHTML`, `context`), and the web view exposes the context as a computed
property over it, so the file a *fetch* is checked against and the file a *click*
is checked against are one value.

### M6 — The ordering is Core's, behind two seams

`MarkdownPreviewModel` owns every question of *when*: the generation token, the
300 ms debounce, the memory of the last tree, the rule that an appearance change
re-renders without re-parsing, the "unchanged body sends nothing" comparison and
the once-per-turn coalescing of scroll lines. It reaches the parser through
`MarkdownParsing` (`Sendable`, not main-actor — the parse hops off) and the page
through `MarkdownPreviewPageSink` (`@MainActor`, two verbs: `evaluate(_:)` and
`reloadShell(html:)`).

So the whole ordering is asserted in `swift test` with **neither a parser nor a
web view present**, and `MarkdownPreviewController` — the app's glue — holds no
token, no debounce and no dirty flag, because every model method is total for the
fact it is handed: re-forwarding the document already shown is a text change,
re-forwarding the text already parsed sends nothing, an unchanged appearance
reloads nothing.

The token obeys the repository-wide rule: captured **synchronously** before the
hop, re-checked after every suspension, and a run that returns to find it moved
publishes nothing. It is bumped by a text change, a retarget and a clear.

The model is the one `@MainActor` Core model here with **no `@Published`
state**, and that is deliberate: the preview's surface is the page, so a
published mirror would be a second copy of the page's state that nothing reads
and that could disagree with the page itself.

### M7 — A keystroke is an `innerHTML` assignment, not a page load

The shell ships its container element empty; the body arrives afterwards through
`PisakaPreview.render(…)`, and only a **theme or code-font-size change** reloads
the shell. That is what makes typing cost no navigation and the preview's scroll
position survive a keystroke.

The body crosses the seam as a **JavaScript string literal Core escapes**
(`javaScriptStringLiteral(_:)`), never as a fragment spliced into source: a
document containing a quote, a backslash, a newline or the characters
`</script>` produces a call with one argument rather than a syntax error or a
second statement. The escape is deliberately stricter than JSON — `<`, `>` and
`&` are escaped so the literal survives being read inside a `<script>` element,
and U+2028/U+2029 because older parsers read them as line terminators inside a
literal — while remaining valid JSON, which is what lets a test decode it back
and compare. The markup inside was already escaped once by the renderer; this
escaping is about the transport.

The scroll line crosses as an `Int` and is interpolated as one: a number has no
spelling that could end the call and start a statement.

Because a body sent while the shell is still loading would run in the *outgoing*
document and be lost with it, the web view holds sources arriving in that window
and delivers them, in order, on either ending of the load. That is **capability,
not a decision** — nothing is reordered, coalesced or dropped, so the page sees
exactly the sequence the model sent, and the seam's contract ("run this in the
page") is true.

### M8 — The preview is a global preference, off by default, written from one site

`SettingsStore.markdownPreviewEnabled` is **one** flag rather than one per tab,
for the reason `completionEnabled` is one flag: it is a preference about how
Markdown is edited, not a property of a file, so a user who turned the pane off
does not meet it again on the next `.md` they open. It defaults **off** — the
pane takes half the window and starts a web view, so it is asked for rather than
met — and off costs the feature everything but the flag.

View → *Markdown Preview* (⌘⇧P) is the only thing that writes it, a `Toggle`
rather than a Show/Hide button because a checkmark says what the next `.md` file
will do, and disabled unless the active tab is Markdown, because an item that
silently does nothing is worse than one that says so.
`MarkdownPreviewSourceGatingTests` pins the single writer.

**The chord is shared with LeetCode's *Open Problem…*.** Both spell ⌘⇧P; the
View item is the one AppKit meets first and is disabled off a Markdown tab, so
which command a press reaches depends on the active tab. That is a collision
recorded rather than designed — see “What is still owed” below.

### M9 — What may be shown offline is pinned, and the ~3.4 MB is accepted

`Resources/MarkdownPreview/` ships four files served by the app's own handler out
of `Bundle.main`: `highlight.min.js` and `mermaid.min.js` (third party, copied
verbatim) and `preview.js` / `preview.css` (written here). There is no
`index.html` in that directory and there must never be one — the page is composed
in Swift.

Nothing is fetched at run time (M2), so the bundles are in the repository rather
than behind a `<script src="https://…">`: a preview of a file on disk must not be
a network request. The cost is ~3.4 MB of third-party JavaScript, mermaid being
essentially all of it — **accepted, not overlooked**, within the ~4.5 MB the
feature was planned against, compressed in the shipped archive, and carried only
on macOS (the folder reference states `destinationFilters: [macOS]`, this file's
second such filter and the first on a *source* entry rather than on a package
dependency).

Each asset is pinned by version, upstream commit, byte count and SHA-256 in
`Resources/MarkdownPreview/VENDORED.md`, cross-checked by
`MarkdownPreviewAssetPinTests` against the bytes on disk and against the version
each bundle states about itself. The update procedure lives in that document; a
bump means re-reading it, and `MarkdownHighlightClasses.standardScopes` must be
re-transcribed from the new build's own CSS-classes reference (M10).

### M10 — The preview highlights with the editor's palette, through one table

A fenced Swift block in the preview and the same block in the text view beside
it are the same code read twice, so the preview carries no palette of its own.
highlight.js classifies a token by writing a *scope* into a `class`;
`MarkdownHighlightClasses.scopeKinds` maps every scope of the bundled standard
build onto a `SyntaxTokenKind`, and `SyntaxTheme.markdownPreviewTheme(prefersDark:)`
resolves that vocabulary against an `NSAppearance` and hands Core the colours as
`#rrggbb` strings. `MarkdownPreviewTheme.light`/`.dark` keep only the chrome;
every code colour is overwritten through `withCodeColors(_:)`, so adding a token
kind reaches the preview with no second edit.

Coverage is asserted by **set equality in both directions** — every scope maps to
a kind, every kind is reached by at least one scope — which is what `CaseIterable`
on `SyntaxTokenKind` buys. Both gaps are otherwise silent: an unmapped scope
renders in body-text colour (which looks like ordinary unhighlighted code), and a
kind no scope reaches is a colour the page computes, ships and never uses.

A scope is not a class name: highlight.js writes `title.function.invoke` as
`class="hljs-title function_ invoke__"`, and `cssSelector(forScope:)` is that
rule written once. A refinement therefore wins on **specificity** — more class
selectors — so the stylesheet's generated rules can be emitted in sorted order
for a diffable document, with no precedence riding on it.

**Nothing is auto-detected.** A fence with no language is emitted as a bare
`<pre><code>`, which `preview.js`'s selector cannot reach, so highlight.js is
never asked to guess: a shell transcript highlighted as Ruby reads as a syntax
error in the document rather than as a guess by the viewer.

### M11 — The focus fallback is scoped to the preview and to nothing else

App-wide chords act "at the caret" — Go to Definition, Find Usages, Rename,
Toggle Comment, Complete, and `FoldCommands`' four items — and each used to spell
`NSApp.keyWindow?.firstResponder as? EditorTextView` itself. They ask from **six
call sites**: five in `PisakaApp.swift`, one in `FoldCommands.swift`, which asks
once for all four fold items. (Every count of "six" in this feature is a count of
those sites, not of chords.) The preview is a **focusable** web view (selection
and links must work), so clicking into it made all of them beep.

`EditorCommandTarget.focusedEditor(in:)` is that expression's one definition, and
the gating suite pins that no seventh site spells it. The fallback is granted to
exactly one region: when the first responder is the preview's web view **or a
descendant of it** — recognised through the marker protocol
`EditorCommandFocusPassthrough`, whose one conformer is
`MarkdownPreviewWKWebView` — the helper looks for the key window's
`EditorTextView`. Every other responder answers `nil` and keeps beeping byte for
byte as it does today.

"Find *an* editor in the key window" was the rejected rule: the terminal, the
project tree and the search field would then answer with an editor the keystroke
was never aimed at, silently editing a buffer the user is not looking at. The
walk is up the superview chain because a web view's first responder is usually an
internal subview; the search for the editor is down the content view, and there
is at most one `EditorTextView` per window.

### M12 — swift-markdown is the second documented branch pin

`swift-markdown` is pinned in `project.yml` **by revision, not by version**,
because the repository publishes no semantic versions — its tags are the Swift
toolchain's own. The pin is tag `swift-6.2.2-RELEASE`, deliberately not the
newest: `swift-6.3-RELEASE` and later raise the manifest to
`swift-tools-version:6.2`, which the SwiftPM in CI's pinned Xcode refuses to
read, so moving past it means moving CI's Xcode first and the two are one change.

Its manifest requires `swift-cmark` **by branch** (`release/6.2` — a frozen
release branch, but a branch), which reaches this project exactly as Neon's
SwiftTreeSitter requirement does: the identity records a `branch:` in
`Package.resolved` and its *pin is the whole pin*. `DependencyPinTests` therefore
knows a documented **set of two** branch-pinned identities, `swifttreesitter` and
`swift-cmark`, each with its own recorded revision and its own stated reason —
and a **third** one still fails the suite.

`swift-cmark` is linked (transitively) and so ships its own license the way
SwiftTreeSitter does, with its bundled GFM-extension notice appended the way
`libgit2.txt` carries its linking exception. The DocC plugin identities the same
manifest asks for never reach the committed `Package.resolved` — SwiftPM prunes
a non-root package's plugin-only dependencies — so there is nothing to
acknowledge and nothing to exclude, and `LicenseCoverageTests`' rule would say so
if a resolve ever did record them.

### M13 — The gating suite's literal-keeping exception is the third in the repository

`MarkdownPreviewSourceGatingTests` matches comment- **and** literal-stripped text
like every other source-gating suite, with two rules excepted: the HTML shapes no
app file may compose (`</p`, `<!`, `<img src=`, a lowercase opening tag) and the
four spellings of the app scheme's vocabulary. Both rules' subjects **are** string
literals, so the ordinary scanner deletes exactly the text they are about and
would pass an app file that composed a `<div>` or spelled `pisaka-preview`
itself. They read `GitHubSourceGatingTests.strippingComments(_:)` instead — the
same scanner with the literals kept, that suite's own argument about `gh`'s
flags, read here about markup.

This is the third stated exception to the repository's comment- and
literal-stripped matching rule, after `GitHubSourceGatingTests`' `gh` vocabulary
and `ReleaseWorkflowTests`' build-output roots, and it is recorded in `CLAUDE.md`
beside them.

## `PisakaCore` — the decisions

### `MarkdownDocument.swift`

The document tree: what the parser produces and what the renderer consumes, with
nothing platform-shaped in between. It parses nothing, composes no HTML and names
no platform type, so every question about *what the preview shows* is answerable
against a tree built by hand.

- `MarkdownInline` (`indirect`) — `text`, `emphasis`, `strong`, `strikethrough`,
  `code`, `link`, `image`, `autolink`, `lineBreak`, `softBreak`. Text is carried
  **unescaped**, exactly as the source spelled it: escaping is the renderer's
  job and happens once, there. Inline `code` is a string, never children — its
  content is literal by definition. A `link`'s `destination` is the source's own
  spelling, because the asset rule needs it to resolve. `autolink` is its own
  case rather than a `link` whose text matches its destination, so the renderer
  never has to compare the two to find out which it holds. `softBreak` exists
  because dropping a non-hard newline would run two lines' words together.
- `MarkdownBlock` (`indirect`) — `paragraph`, `heading`, `codeBlock`,
  `blockQuote`, `unorderedList`, `orderedList`, `table`, `thematicBreak`. A
  code block's `language` is `nil` for an indented block or a bare fence, which
  is the whole difference the renderer needs (M10). An ordered list carries its
  `start`, so `3.` does not silently restart at one.
- `MarkdownTopLevelBlock` — a block *plus* the 1-based source line it started
  on. Nested blocks have nowhere to put one, not "carry `nil`": scroll sync only
  ever asks about top-level positions, and a nested line would be a second,
  unread number that could disagree with the first.
- `MarkdownTableRow`, `MarkdownTableAlignment` (`.none` is not `.left`),
  `MarkdownCheckbox`, `MarkdownListItem` (an optional checkbox — an ordinary
  item has none at all, distinct from an unchecked one).
- `MarkdownParsing` — the parser seam (M6). `Sendable` and not `@MainActor`;
  synchronous, because parsing is, and the hop is the caller's decision. No
  `throws`: an unparseable document is not a thing Markdown has.

The closed set covers exactly what the preview renders — CommonMark plus the
three GFM extensions it draws (tables, task items, strikethrough) — because an
unrendered case is one no test can distinguish from a dropped one. **There is no
raw-HTML case** (M1).

### `MarkdownPreviewTheme.swift`

Every colour the page draws with, as CSS strings — the
`LeetCodeStatementDocument.Theme` mould, one size larger. Nothing here reads
`NSColor` or the system appearance: the view layer resolves the appearance it is
running in and passes the answer across, so the page stays a pure function of its
inputs and a test can assert light and dark differ.

Eight chrome fields (`background`, `text`, `secondaryText`, `link`,
`codeBackground`, `border`, `tableBorder`, `colorScheme`) plus `codeColors`, one
entry per `SyntaxTokenKind` (M10). `tableBorder` is separate from `border`
because a table draws a *grid* of them — a weight that reads as structure between
cells would read as a scar across a paragraph. `colorScheme` is emitted as CSS
`color-scheme`, which is what makes the web view's own scrollbars and the
disabled task-item checkboxes match a dark pane.

`color(for:)` makes reading the dictionary total (falling back to `text`);
`cssVariableName(for:)` is the custom-property name per kind;
`resolved(_:systemPrefersDark:)` is `ThemePreference`'s total mapping, the
statement panel's signature; `withCodeColors(_:)` is the app's one use — keep
Core's chrome, replace the code palette — as a dedicated member so adding a
chrome colour later cannot silently drop out of the app's copy.

### `MarkdownHighlightClasses.swift`

The bridge between the two highlighters (M10): `scopeKinds` (scope → kind),
`standardScopes` (the pinned class vocabulary of the bundled build),
`kind(forScope:)` and `cssSelector(forScope:)` (the `hljs-` prefix and the
trailing-underscore-per-depth rule, written once).

**The scope list is pinned, not discovered** — transcribed from the bundled
release's own `docs/css-classes-reference.rst`, restated in `VENDORED.md`, and
re-checked on every bump. Nothing at run time can notice a stale entry, so the
coverage is asserted statically in both directions instead. Where a scope has an
obvious counterpart in the editor's own capture table it is given the same kind
(`tag`/`name` → `.type`, `attr` → `.property`, `section`/`emphasis`/`strong` →
`.keyword`, `code` → `.string`, `link` → `.label`), so the two highlighters agree
by construction rather than by coincidence.

### `MarkdownRenderer.swift`

The tree turned into an HTML **body** — the fragment written into the shell's one
container. A pure function of the tree and the document's context, so the whole
of *what the preview shows* is assertable with no web view, no parser and no file
system.

Three properties hold by construction: every author-supplied string is escaped
exactly once and the tree has no raw-HTML case to interpolate (M1); only
top-level blocks carry `data-line`, because the line lives on
`MarkdownTopLevelBlock` and the nested path is called with an empty attribute
string; and a file target is either an app-scheme URL or the source's own
spelling, the one decision about reach belonging to `MarkdownPreviewAsset` (M4).

Three presentational decisions the tree deliberately leaves open, each because
HTML has no way to express the alternative:

- a heading level is **clamped** to 1…6 (a `<h9>` is an unknown inline element,
  so the deepest heading HTML has is truer than a working `<h7>` that does not
  exist);
- a fence's info string is reduced to its **first word** (CommonMark's info
  string is free text, and the whole of it in `class="language-…"` matches
  nothing);
- that word is **lowercased** (every highlight.js name and alias is, and folding
  it once makes the `mermaid` comparison case-insensitive for free).

A code block has three shapes and no fourth: a `mermaid` fence is
`<pre class="mermaid">` holding its escaped source, any other language is
`<pre><code class="language-…">`, and a fence with none — like every indented
block — is a bare `<pre><code>` (M10). A task item gets a **disabled** checkbox:
the preview is read-only, and a live one would be a control that either does
nothing or writes to the worktree. Table alignment travels as
`style="text-align: …"` (HTML5 removed the `align` attribute), `.none` emits
nothing at all, and nothing pads or truncates a row. `<ol start>` is always
emitted, including for `1`: one shape rather than a branch whose `1` case is
untestable from the markup. An attribute with an absent value is omitted rather
than emitted empty — `<a>` with no `href` is not a link, while `href=""` would
reload the shell. `alt` is the image's inline content flattened, since HTML's
`alt` is a plain attribute value.

`escaped(_:)` is one function for text position and attribute value alike (the
two differ only in whether quotes are folded, and folding them in text costs
nothing while not folding them in an attribute is an injected attribute), with
`&` replaced first so it cannot re-escape what the later replacements introduce.

### `MarkdownPreviewPage.swift`

The scheme, the URLs, the document and the two entry points (M2, M3, M4, M7).

- The vocabulary: `scheme`, `host` (fixed, so a document's *path* never becomes
  part of the origin and retargeting is not a cross-origin navigation),
  `shellPath`, `bundledPathPrefix`, `filePathPrefix` (carrying a
  **project-relative** path, so the page never learns where the project sits on
  disk) and `shellURL`.
- The bundled set: `bundledFileNames` in **load order** — stylesheet, the two
  third-party scripts, then `preview.js`, which touches `hljs` and `mermaid` at
  boot — as one list rather than four call sites, because the handler serves
  exactly this set and nothing else.
- The document: `html(theme:fontSize:)`, a pure function of the two inputs a
  change in which re-writes the shell. Everything else about the page reaches it
  through JavaScript instead. `themeStylesheet` generates both halves — the
  custom properties `preview.css` reads (including `--code-font-size`, a point
  smaller than the body for the statement panel's reason) and one colour rule
  per highlight scope, emitted by walking the class table so a scope added there
  gets its rule for free. The `<link>` precedes the generated block: the theme
  is what must win, so it is written last.
- The entry points: `bodyUpdateSource(body:)`, `scrollToAnchorSource(anchor:)`
  and `scrollToLineSource(line:)`, plus `javaScriptStringLiteral(_:)` (M7). The
  fragment is escaped for the same reason the body is — it arrives from an
  `href` in a document nobody in this app wrote.
- The seam: `MarkdownPreviewPageSink`, `@MainActor`, two verbs and no third
  (M6). Neither returns anything: the page answers no questions, so there is
  nothing to await and no failure the model could act on.

### `MarkdownPreviewAsset.swift`

`MarkdownDocumentContext` — the previewed document's URL and the project root,
both optional because both are genuinely absent sometimes (an unsaved buffer, no
folder open). Absence makes every relative target unresolvable, which is the
honest answer: a relative path has nothing to be relative *to*.

The forward direction refuses, as **one outcome**, a target with any scheme other
than `file` (including the app's own, which a document has no business
spelling), a fragment-only target, a `../` escape or a symlink pointing out of
the tree, an absolute path landing outside the root, and every target at all
when either half of the context is missing. An **absolute** target *inside* the
root does resolve — refusing it would be a rule about spelling rather than about
reach. So does one carrying a **fragment**: `other.md#usage` — the ordinary shape
of a cross-file link in a documentation tree — resolves to `other.md`, the `#`
opening a fragment in any reading of a URL. (The `file:` branch already answered
this way, `URL` reading the fragment out for it; the scheme-less branch does it by
hand, since `URL(string:)` must not be asked to parse that target's path.) The
split happens **before** percent-decoding, so a literal `#` in a name — which a
document has to spell `%23` for any renderer at all — stays part of it, and a
fragment cannot smuggle a path past the containment check. The anchor itself is
dropped: the renderer emits no `id`, so there is nothing to carry it to (a stated
limit below), and the file is what the link was for.

`URL(string:)` is consulted only for the **scheme** (the component Foundation
reads the way WebKit does); reading the path back out of it would re-encode a
target that was never encoded. A destination may be percent-encoded (`a%20b.png`)
or may contain a literal `%` that decodes to nothing, so decoding is attempted
and the raw spelling kept when it fails — the only reading under which both files
are reachable. The URL is composed through `URLComponents`, so the path is
encoded once by Foundation rather than by a hand-written escape that has to agree
with WebKit's decoder.

The inverse reads `url.path` (percent-**decoded**, which is what round-trips the
forward direction) and **appends** the relative path to the root rather than
resolving against it as a base: a base URL that does not end in a slash names a
*file*, and resolving would drop the root's own last component — a path that is
outside the root and would simply be refused, the kind of wrong answer that looks
correct from the outside. `standardized`, not `standardizedFileURL`, so the
caller's `/private` spelling survives into the answer while containment is still
checked canonically.

`MarkdownPreviewRequest` + `classify(_:context:)` are the handler's dispatch
(M4). A bundled name is checked by **membership, not existence**: the set is
fixed at build time, so a name outside it is refused without touching the bundle,
and a nested path is refused for being no member rather than for looking like an
escape.

### `MarkdownLinkRule.swift`

`MarkdownLinkDecision` — `external(URL)`, `openInEditor(URL)`, `anchor(String)`,
`refused` — and `decision(for:context:)`. Four answers and no fifth, so the
navigation delegate is a `switch` with no `default` that could quietly become a
permission. In particular there is no "let the web view handle it": the preview
never navigates *itself* anywhere, so a navigation is always a link.

`http`/`https`/`mailto` leave the app (lowercased on comparison, since
`URL.scheme` is not normalized). An app-scheme URL on the shell's own path with a
non-empty fragment is an anchor; a fragment on any *other* path is not an anchor
but a navigation to another resource that happens to carry one, and is judged as
that resource. Everything else goes through the inverse mapping, and a `nil` is
`refused` — which also covers `javascript:`, `data:` and a `file:` URL the page
had no business composing.

A target the renderer could not resolve arrives here as whatever the page's base
URL made of it: an `http` URL stays one and opens externally; a relative path
resolves against the shell into an app-scheme URL naming a file that is either
inside the root (opening it is right — the forward direction's refusal was about
the *document's* directory, not about reach) or outside it, and refused here.

### `MarkdownScrollRule.swift`

`line(forTopOffset:lineStarts:)` and its text-taking form. Scroll sync is
**one-directional** by design: the editor is the document, the preview a view of
it, and a view does not move its document — which is also what keeps the two from
chasing each other through a feedback loop neither side could damp.

The line is the editor's own: `LineStartIndex`' separator set (LF/CR/CRLF/NEL/
LS/PS), numbered from 1, so it means what the gutter means, and it meets
`data-line`, which the renderer wrote from the parser's 1-based source lines.
Total by construction: a negative offset reads as the start and one past the end
as the last line, both being things a scroll view reports during a live resize.

### `MarkdownPreviewWidthRule.swift`

`BottomPanelHeightRule`'s shape turned on its side and expressed as a
**fraction** — the panel's height is a number the user set once and wants back at
that many points, while this split is remembered across windows and resizes,
where a stored point width would overflow a narrower window and leave a gap in a
wider one.

`paneMinimum` arrives **already interface-scaled** (the view scales it, Core
stays scale-agnostic). A legal fraction is at least `minimumFraction` (0.2) and
at least `paneMinimum / available`, and symmetrically bounded above: the
proportional bound is the aesthetic one and binds in every ordinary window, the
point bound the structural one and binds only in a narrow one. When the two
cross — `available < 2 * paneMinimum` — there is no legal fraction and the rule
answers `defaultFraction`, so both panes are equally too narrow and no stored
preference becomes an invisible pane the user cannot drag back.

A non-finite proposal falls back to `defaultFraction` rather than surviving the
clamp (`min`/`max` let NaN through every comparison) and rather than falling back
to a *bound*, which is what the panel rule does: there the floor is the resting
state, here either bound is a pane squeezed to its limit.

`fraction(base:dragTranslation:available:)` applies a cumulative translation to a
fixed base, so pointer travel maps one-to-one to editor width inside the bounds.
`editorWidth`/`previewWidth` derive from a fraction the rule clamps itself, so no
caller can turn an out-of-range preference into a width, and the two always sum
to `available`. `clampFraction(_:)` is the width-free half — what `SettingsStore`
persists through, there being no window at write time.

### `MarkdownPreviewModel.swift`

The whole ordering (M6). Seams: `parser`, `sink`, `debounceInterval` (0.3 s) and
an injectable `sleep`, so the ordering — including a second edit landing while
the first parse runs — is deterministic in `swift test` and adds no wall clock.

State: the `context`, the last forwarded `text`, `lastDocument` (held precisely
so a theme or font change re-renders **without re-parsing**), `lastBody` (so an
update that would change nothing sends nothing), the `appearance` the installed
shell was composed from, the generation token, the in-flight `renderTask` and the
pending scroll line.

The four facts the glue forwards:

- `updateAppearance(theme:fontSize:)` — unchanged is a no-op; changed reloads the
  shell and re-renders the body from the last tree. `lastBody` is cleared first,
  because the reloaded document ships its container empty, which is what lets a
  byte-identical body be re-sent.
- `retarget(to:text:)` — a *different* context clears the body, forgets the tree
  and parses **immediately** rather than after the debounce: 300 ms of the
  previous tab's content beside the new tab's editor is worse than a blank pane
  for the same 300 ms. The same context is not a retarget but a text change,
  which is what lets the controller call this on every selection change without
  comparing anything.
- `noteTextChanged(_:)` — debounced and idempotent.
- `clear()` — a tab that is not Markdown became active, the preference was
  switched off, or the folder changed. The body is cleared and the token moves;
  the shell **stays installed**, being the page rather than the document.
- `noteScrolled(toLine:)` — coalesced to one call per turn of the main run loop
  and **never by a timer**: a gesture delivers a bounds change per frame, and
  marking the model dirty then flushing from a main-actor `Task` (which runs
  after the current synchronous work drains) collapses the burst into one
  `scrollToLine` carrying the last line. Nothing is sent while the page shows no
  body — there is no element to scroll to, and the position will be part of the
  next scroll anyway.
- `pageIsGone()` — the page's web content process died and took the document
  with it. The shell is composed again from the appearance already forwarded and
  the body re-sent **from the tree already parsed**: the buffer did not change,
  only the page did, so this costs a render and not a parse — exactly as an
  appearance change does. It is the one method whose *purpose* is to falsify the
  memory the others compare against: `lastBody` and `appearance` describe a page
  that no longer exists, and while they stand every method above is correctly a
  no-op, so no keystroke, no ⌘⇧P and no tab switch would put anything back and
  the blank pane would last the window's life. Before the first
  `updateAppearance(theme:fontSize:)` there is no shell to reinstall and nothing
  was ever shown, which is the guard. The fact is observable only in the app
  half (`webViewWebContentProcessDidTerminate(_:)`); the recovery is possible
  only here.

The parse runs in a detached task at `.userInitiated` and the token is re-checked
on return; cancellation is a courtesy, not the mechanism.

## `Pisaka` (macOS) — the capability

### `MarkdownParser.swift`

The feature's **only `import Markdown`** (M6). It makes no decisions: every
method is a mapping from one AST node onto the Core case that means the same
thing — nothing filtered, normalised, defaulted, clamped, guessed, resolved or
escaped. Where a node has no Core case the mapping has nowhere to put it, which
is the drop (M1).

Two parse options, both refusals rather than choices: `.disableSmartOpts` keeps
text exactly as the source spelled it (smart punctuation would rewrite quotes and
dashes, precisely the normalisation this file may not do), and source positions
stay **on**, `sourceLine` being read from them. The GFM extensions the preview
renders are attached unconditionally by swift-markdown and need no option;
bare-URL autolinking is not among them, so `.autolink` arrives only from the
`<https://…>` form. `link.isAutolink` is asked here — swift-markdown's own answer
to "is this link's text its destination" — which is why the renderer never has
to.

### `MarkdownPreviewSchemeHandler.swift`

What the page may fetch and the bytes each fetch answers with (M4). It decides
none of it: a URL goes straight to `classify(_:context:)` and this file switches
over the four cases. It deliberately does **not** import WebKit — the
`WKURLSchemeHandler` conformance is one adapter in `MarkdownPreviewWebView.swift`
over `answer(for:)`, which is a plain function of a URL and this object's state
and is therefore assertable in `PisakaAppTests` with no web view, window or task.

**A refusal is a 404, not an error.** Nothing throws, fails the task or writes a
log line: failing would put a WebKit error in the console for every broken link
in every document, and a log line would be a channel from a document's contents
into the app's diagnostics. A read that fails is the same outcome as a refusal —
a file deleted between the render and the fetch is not distinguishable from one
that was never reachable, and the page has nothing useful to do with the
difference.

`shellHTML` is `nil` before one is installed, which is a 404 rather than an empty
page: the only way to reach the shell URL before the glue composed a document is
a navigation the app did not ask for, and an empty `text/html` looks like a
rendering failure. `bundledDirectory` ("MarkdownPreview") is the app's one piece
of knowledge here — *where* the copy lands; the names inside it are Core's. MIME
types come from `UTType`, so a project image of any format the system knows is
served as itself, with `application/octet-stream` as the fallback every web
server uses. Bundled files claim `utf-8` (a subresource has no `<meta charset>`
to fall back on); a project file claims **no** encoding, that being a statement
this layer is in no position to make.

### `MarkdownPreviewWebView.swift`

The feature's **one `import WebKit`**, and the production
`MarkdownPreviewPageSink`. It holds no token, no debounce and no memory of what
the page is showing.

- `MarkdownPreviewWKWebView` — the subclass exists for its
  `EditorCommandFocusPassthrough` conformance alone (M11); it overrides nothing.
- Configuration: the scheme handler registered for `MarkdownPreviewPage.scheme`,
  a **non-persistent** website data store (the document is composed from a file
  already open in the editor, and a persistent store would keep copies in caches
  and local storage nothing in this app would clean up), back-forward
  gestures off (there is nothing to go back to) and **`allowsLinkPreview` off**.
  The last one is the only entry here that is spelled to *unset* a default, and
  it is the one that keeps M2's claim true from the other side: a link preview
  loads the URL it is showing in a web view of WebKit's own, which the delegate
  below never sees and which the shell's `default-src 'none'` cannot reach —
  a CSP being a property of a document, not of the process. Left at its default
  of `true`, a force press on an `http(s)` link in a rendered document would be
  the single path by which this feature fetched anything from the network, and
  the property `docs/FEATURES.md` and `README.md` both state outright would be
  false. `MarkdownPreviewSourceGatingTests` pins the line.
- `documentContext` is a computed property over the handler's, so there is one
  answer (M5).
- `evaluate(_:)` / `reloadShell(html:)` — the seam, plus the pending-source queue
  (M7). `reloadShell` is the one `load(URLRequest` in the feature (M3).
- Navigation: **every navigation is cancelled.** The allowed loads are
  recognised by *having just been asked for* — `ownLoadsAwaitingDecision`,
  raised immediately before this object's own load and spent by the next policy
  decision — because the shell's URL is *not* a usable test: a document can link
  to it (`href="/index.html"`, a bare `href="#"`) and would then reload the page
  under the user. That is `LeetCodeStatementWebView`'s precedent. Everything else
  goes through `MarkdownLinkRule` and ends in `.cancel`, whichever of the four
  answers it was.
- **The count is a discriminator, never the whole test**, and three conditions
  stand beside it: the main frame, `MarkdownPreviewPage.shellURL`, and
  `navigationType == .other`, which is what `load(_:)` produces. The count is
  what separates this from a document linking to the shell's own path — that one
  is `.linkActivated` and fails the type test on its own — while the three are
  what bound a count that *leaked* (a page whose process dies while a load is
  still provisional decides no policy for it) to the page's own shell. Without
  them a leak hands the next navigation an unconditional `.allow` into the main
  frame: one click on an `http` link in a rendered document and the pane is a
  live remote page, outside the shell's CSP, with no back gesture and nothing
  that reloads the shell.
- **Only a click carries a side effect.** Three of the rule's four answers act
  outside the page — the system opens a URL, the app opens a tab, the page
  scrolls — so anything that is not `.linkActivated` is cancelled before the
  rule is asked. Same refusal, same reason, as the LeetCode delegate's: a
  `<meta http-equiv="refresh">` would otherwise launch a browser at an arbitrary
  URL the moment the pane rendered, with no click and no confirmation. That this
  page's tree has **no raw-HTML case** to author one with is a second property
  (M1), not a reason to rest the first on it.
- **A page can die, and it is the model that puts it back.**
  `webViewWebContentProcessDidTerminate(_:)` drops the state describing a page
  that no longer exists — the dead process decides no policy and ends no
  navigation, so the count, the awaited navigation and the pending queue would
  otherwise be held forever — and calls `pageIsGone`, the second injected
  closure. It reloads nothing itself: the shell is a string the model composed
  and the body one only the model remembers, so the app half has nothing to
  reload *from*. Recovery is therefore
  `MarkdownPreviewModel.pageIsGone()`'s, and it is what keeps the model's early
  returns honest — with `lastBody` and `appearance` both still describing the
  page that died, no keystroke, no ⌘⇧P and no tab switch would send anything at
  all, and the blank pane would last the window's life.
- **Two reloads can be in flight, and both halves above are counted rather than
  latched because of it.** Every code-zoom step is an appearance change, so two
  presses in a row ask for two shells before the first one's policy decision has
  arrived. A single `Bool` would be spent by the first decision and the second
  navigation would be judged as a *link* — and the shell's own fragment-less URL
  is `.refused` there, so the page would never load. Symmetrically, the queue is
  released by `shellLoadEnded(_:)` only for the load it is **waiting on**, held
  by `WKNavigation` identity: WebKit ends a superseded load with
  `didFailProvisionalNavigation`, and flushing on that ending would evaluate the
  queued body in the outgoing document — losing it, and leaving the arriving
  shell empty with nothing able to re-send it, since the model has already
  recorded that body as the one the page is showing. An unidentifiable ending
  (either side `nil`) still flushes: a queue nobody drains is the worse failure.
- The `WKURLSchemeHandler` adapter: every branch ends in `didFinish()`;
  `didFailWithError` appears once, for a request WebKit started without a URL.
  `stop` is empty — every answer is produced synchronously and finished before
  `start` returns.
- `MarkdownPreviewWebViewRepresentable` — `updateNSView` is empty **by design**:
  every change reaches the page through the seam, never through a re-evaluated
  body.

### `MarkdownPreviewController.swift`

Glue with no logic of its own (M5, M6): it owns the page and the model, forwards
four facts, and holds no token, no debounce and no dirty flag. It has no tests of
its own because there is nothing here `MarkdownPreviewModelTests` does not
already assert; its *shape* — one `import Markdown` away, one `import WebKit`
away, naming no writer gate — is pinned by the gating suite.

It makes **one wire** rather than forwarding it, and that is still not a
decision of its own: the model is built in a `lazy` that also hands the page its
`pageIsGone` closure, so the pair cannot exist unjoined. A page that died is a
fact only the web view can observe and a recovery only the model can perform;
this is simply where both are already owned. The model is captured weakly — it
holds the page as its sink, and the closure travels the other way.

Two translations, neither a decision: `preview(_:projectRoot:)` turns "no
previewable tab" into `clear()` and otherwise sets the context on the page **and**
hands it to the model; `noteScrolled(topOffset:)` maps an offset to a line
through `MarkdownScrollRule`. Line starts are computed on the first scroll after
a keystroke rather than on the keystroke itself — a burst of typing with nobody
scrolling costs none of them — and dropped whenever the text moves, the only
place they can go stale.

### `MarkdownPreviewPane.swift`

The pane: the one web view, plus the facts the window forwards while it is on
screen. It draws nothing of its own — everything the user sees is the page. What
it contributes is the **lifetime**: `onDisappear` is the only place `clear` is
reached from, which is why the feature's three clears (a non-Markdown tab, the
preference off, a folder switch) are one code path.

The document and the appearance travel on different paths in the model, so they
are forwarded through different `onChange` modifiers; the appearance is keyed on
its **inputs** (`prefersDark` + font size) rather than on the theme, because
deriving the theme resolves every editor colour against an `NSAppearance` and
this body is re-evaluated on every keystroke. `onAppear` forwards the appearance
first — it installs the shell, and the body that follows is held by the page
until that document has loaded (M7).

The document is forwarded on **four** changes, not three: the text, the tab's
`id`, the project root, and the tab's `url`. The last is there because a rename
or move (`WorkspaceModel.applyRenamePlan`) and a Save As both rewrite a tab's
`url` **in place**, keeping its id and its text — so none of the other three
fires, and without it the preview would go on resolving relative images and links
against the file's old directory. Forwarding is free when nothing moved:
`retarget(to:text:)` compares the context and reads an unchanged one as a text
change, which is then itself idempotent.

It declares a **code** zoom surface (`ZoomSurfaceMarker(kind: .code)`): the
page's body text and its fenced blocks are sized from `settings.fontSize`, so a
zoom gesture over the preview must move the code zone, exactly as over the
LeetCode statement pane. `ZoomSourceGatingTests` counts it as the fifth
SwiftUI-drawn code region.

### `EditorCommandTarget.swift`

`EditorCommandFocusPassthrough` (the marker) and
`EditorCommandTarget.focusedEditor(in:)` (the one definition) — M11. The window
is a parameter rather than read from `NSApp` here, so the rule is assertable over
a constructed hierarchy (`PisakaAppTests/EditorCommandTargetTests`); every call
site passes `NSApp.keyWindow`. Callers keep their own extra guards —
`isEditable` and `hasMarkedText()` are asked by the commands that edit, not by
this.

## The bundled page assets

`Resources/MarkdownPreview/` — four files, a folder reference filtered to macOS
(M9). `VENDORED.md` records each third-party bundle's project, version, commit,
source URL, byte count, SHA-256 and license, the pinned scope list (M10), and the
by-hand update procedure; `MarkdownPreviewAssetPinTests` asserts the bytes, the
self-stated versions, that the directory holds exactly the files the page asks
for, that the diagram bundle is a single self-contained file, that the
highlighter defines its global, and the first-party files' cross-file contracts
(below).

`preview.js` is the page's half of two seams and **decides nothing** — no opinion
about when to render, what to render or which line is the top one. Three
properties are load-bearing and are why it is a file rather than injected source:
auto-detection is off (M10); a diagram that fails to parse takes down its own
block and nothing else (mermaid throws on a syntax error, so each diagram is
rendered in its own `try`/`catch` and a failure writes mermaid's own words into
that block as **text**, and the temporary element mermaid leaves behind on a
throw is removed, or the page grows one orphan per bad edit); and a render
supersedes the one before it (diagram rendering is asynchronous, so the script
keeps the same generation counter the Swift model keeps, for the same reason —
this is the one place in the page where two answers can be in flight at once).
`mermaid` is initialized with `startOnLoad: false` and `securityLevel: "strict"`.

**A fence never renders as nothing.** A diagram block still holds its own source
until the script replaces it, and hiding that source is keyed on
`mermaid-pending` — a class the script adds when it *starts* a render and removes
on every ending — rather than on `pre.mermaid` itself. So the two paths where no
render ever arrives (the bundle missing, and an answer of a shape the page does
not recognise) leave the fence showing its source instead of blank. Blank was the
worse answer twice over: it is indistinguishable from a document that never had
the block, and it is the one failure the page has no words for — inventing some
would be the page saying something about a source it did not read.

Neither first-party file is byte-pinned (they are read and reviewed as source),
but the **cross-file names** are asserted: `MarkdownPreviewAssetPinTests` checks
that `preview.js` spells `containerElementID`, defines `window.<namespace>` and
defines and exposes each of the four members Core composes calls to (read out of
those sources, not listed again), that every `var(--…)` in `preview.css` is a
property the shell's `:root` block declares, and that the stylesheet styles the
container and both diagram-state classes the script spells. Nothing else in the
pipeline compares the two sides — the page tests assert the shell *through* the
same constants, so a rename would keep them green while the page rendered into an
element that no longer exists.

`scrollToLine` walks the container's **children** — `data-line` is on top-level
blocks alone, so that is the whole candidate set — and takes the last one at or
before the line, falling back to the top. `scrollToAnchor` is an `id` lookup and
nothing more; the renderer emits no `id` today, so a fragment lands on nothing
and the page stays where it is, which is the honest answer for a link into a
document that carries no targets.

## The touched hosts

- `ContentView.swift` (`app-window.md`) — the split. `isMarkdownPreviewShown(for:)`
  is the third branch beside the tab kind, and it is a branch rather than an
  always-present trailing pane because the split needs the available width and a
  `GeometryReader` around every editor would erase the editor column's minimum
  widths. The price is the bottom dock's own: toggling the preview re-creates the
  text view. The divider is the dock's divider turned on its side, with one
  difference — the fraction it reaches is **persisted, once, in `onEnded`**,
  because writing on every changed frame would put a `UserDefaults` write on the
  drag's per-frame path and republish the window sixty times a second.
- `PisakaApp.swift` (`app-shell.md`) — the View-menu toggle (M8) and five of the
  six caret-command call sites now routed through `EditorCommandTarget` (M11).
- `FoldCommands.swift` (`core-folding.md`) — the sixth site, same routing, asking
  once for all four fold items.
- `CodeEditorView.swift` (`app-editor.md`) — `onScrolled`, an **optional**
  callback carrying the top visible character offset. `nil` for every editor
  nobody is watching, and the guard is on the closure rather than on the
  viewport, so an ordinary tab does not even capture one: `captureViewport()`
  asks the layout system for the character at a point, which is work worth
  skipping on every scroll frame. It carries an offset rather than a line
  because that is what the editor has.
- `SyntaxTheme.swift` (`app-editor-overlays.md`) — `markdownPreviewTheme(prefersDark:)`
  (M10), resolving inside `performAsCurrentDrawingAppearance` so the answer is
  the one the caller asked for rather than the one the calling thread happens to
  be in; the preview follows the *page's* colour scheme, which the app resolves
  from `ThemePreference` and which may not be the window's. Alpha is dropped
  rather than emitted, nothing in the table being translucent.
- `SettingsStore.swift` (`core-services.md`) — the two preferences (M8), both
  read through `object(forKey:)` so a wrong-typed value falls back rather than
  coercing, the fraction clamped in `didSet` through the rule's width-free half
  with the re-entrant assignment reaching a fixed point on the second pass.
- `SyntaxTokenKind.swift` (`core-editor.md`) — `CaseIterable, Hashable, Sendable`,
  written down because they are now load-bearing (M10).

## Tests

- Core (`swift test`): `MarkdownDocumentTests`, `MarkdownRendererTests`,
  `MarkdownPreviewPageTests`, `MarkdownPreviewAssetTests`,
  `MarkdownLinkRuleTests`, `MarkdownScrollRuleTests`,
  `MarkdownPreviewThemeTests` (the two set-equality directions of M10),
  `MarkdownPreviewWidthRuleTests`, `MarkdownPreviewModelTests` (the whole
  ordering, staged through `ScriptedMarkdownSeams`: a scripted parser recording
  every text it was handed, with a per-text `Gate` that holds a parse mid-flight
  so a superseding edit can be staged causally, and a scripted sink recording
  every source and every shell, decoding each call's argument back out of the
  literal Core composed — no delays and no `Task.yield()` spins).
- Repository-file suites, read through `#filePath` with Foundation only:
  `MarkdownPreviewSourceGatingTests` (M13 and the rules it pins — one parser
  file, one WebKit file, the page served and updated in place, the scheme
  vocabulary in one Core file, no app file of the feature splitting a preview URL
  or composing HTML, one preference writer, the focus helper's one definition and
  six call sites, the app files macOS-gated and unnamed by the iOS layer, and the
  reader rule), `MarkdownPreviewAssetPinTests` (M9), plus the entries this branch
  added to `DependencyPinTests` (M12), `LicenseCoverageTests`,
  `ReleaseMetadataTests` (the third folder reference, matched with its
  destination filter) and `ZoomSourceGatingTests` (the fifth code surface).
- App bundle (`PisakaAppTests`, `xcodebuild … -destination 'platform=macOS' test`):
  `MarkdownParserTests` — the one place the real parser runs, over the
  `every-element.md` fixture — `MarkdownPreviewSchemeHandlerTests`, which
  asserts `answer(for:)` and the `WKURLSchemeTask` adapter without a web view,
  including the forged-URL and escape refusals, and
  `MarkdownPreviewNavigationTests`, the feature's **one gate that drives a real
  `WKWebView`**: the shell the page asks for is allowed and loads. Three of the
  four facts the own-load policy reads are WebKit's answers rather than this
  repository's, and a wrong reading of any of them compiles, breaks no Core
  test, and cancels the one load the feature performs — leaving the pane blank
  for the app's life. Asserted end to end (the shell's container element exists
  in the loaded document) rather than by standing a probe in for the delegate,
  so the real object is the one deciding.

## Stated limits

- **No raw HTML** (M1). Markup in the source shows nothing where it was.
- **No external images.** Only files inside the opened project root are fetched;
  an `http(s)` image, a `../` escape and a symlink out of the tree all render as
  a broken image with its alt text (M2, M4). A document with no file yet, or a
  window with no folder open, resolves nothing at all.
- **No formulas.** There is no math rendering of any kind; a `$…$` span is text.
- No table of contents, no heading anchors (the renderer emits no `id`, so an
  intra-document `#fragment` lands on nothing), no footnotes, no printing and no
  export.
- Scroll sync is **editor → preview only** (M6/`MarkdownScrollRule`).
- macOS only.

## What is still owed

- **⌘⇧P is bound twice** — View → *Markdown Preview* and LeetCode → *Open
  Problem…* (M8). The View item is disabled off a Markdown tab, so the two do not
  both fire, but with a Markdown tab active the LeetCode chord is unreachable.
  Picking a free chord for one of them is a product decision and has not been
  made.
- ~~The app-layer bundle's *execution* is owed a run in a normal desktop
  session.~~ Settled: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
  -destination 'platform=macOS' test` ran the application-hosted runner on
  2026-09-09 — 56 tests, 0 failures, including this feature's three suites. The
  original note stands only as a record of why the branch's CI-shaped runs could
  compile `PisakaAppTests.xctest` without ever launching it.
