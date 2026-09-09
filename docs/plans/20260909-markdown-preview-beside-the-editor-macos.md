# Markdown preview beside the editor (macOS)

## Overview

A macOS-only, read-only live preview pane for Markdown tabs: editor left, rendered preview right, a draggable divider between them. Parsing is done by `apple/swift-markdown` in exactly one app file; every decision — the document tree, the HTML, the page shell, the CSP, the app-scheme ↔ project-file mapping in both directions, the link rule, the scroll line, the width arithmetic, **and the whole update ordering** — lives in `PisakaCore` and is covered by `swift test`. highlight.js and mermaid ship as pinned offline assets. The feature writes nothing to the worktree, never raises the writer gate and is never gated by it; its only persisted state is two `SettingsStore` preferences.

Three shape decisions fixed before this plan:

- **Dependency shape** — the transitive set is accepted: `swift-markdown` pinned by revision in `project.yml`, `swift-cmark` recorded as a *second* documented branch-pin exception in `DependencyPinTests` (its pin *is* the recorded revision, SwiftTreeSitter's own argument), its license shipped in its own right, and any build-tool-plugin identities (`swift-docc-plugin`, `swift-docc-symbolkit`) listed in `licenses.json`'s `excluded` array with the reason "build-tool plugin, never linked".
- **Focus** — the web view stays focusable. The six `NSApp.keyWindow?.firstResponder as? EditorTextView` sites (five in `PisakaApp.swift`, one in `FoldCommands.focusedEditor()`) are replaced by one helper whose single definition the gating suite pins. The helper falls back to the key window's editor text view **only when the first responder is the preview web view or a descendant of it**, so the terminal, the project tree and every other responder keep beeping exactly as they do today.
- **One origin** — the page is *served*, never string-loaded: the shell itself is answered by the scheme handler and the web view reaches it with `load(URLRequest(url:))`, so the document, the bundled files and every asset share one app-scheme origin. The feature spells `loadHTMLString` nowhere.

## Context

Files involved (existing):

- `project.yml` — packages block, `Resources/*` folder references.
- `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — the committed pin file (regenerated, never hand-edited).
- `Resources/Licenses/licenses.json` + texts.
- `Sources/Pisaka/ContentView.swift` — `editorZone` (the `.viewer` routing site), `panelDivider(available:)` + `panelColumnSpace` (the divider precedent), `descriptionPane` (the LeetCode statement pane beside the editor).
- `Sources/Pisaka/PisakaApp.swift` — the View menu, `openFile(url:)` (the tree's open path, reached from `ContentView` as `onOpenFile`), the five responder sites.
- `Sources/Pisaka/FoldCommands.swift` — the sixth responder site.
- `Sources/Pisaka/CodeEditorView.swift` — `Coordinator.captureViewport()`, `clipViewBoundsChanged`.
- `Sources/Pisaka/SyntaxTheme.swift`, `Sources/Pisaka/ZoomSurface.swift`.
- `Sources/PisakaCore/SettingsStore.swift`, `BottomPanelHeightRule.swift`, `SyntaxTokenKind.swift`, `SyntaxLanguage.swift`, `LineStartIndex.swift`, `CanonicalPath.swift`, `SHA256.swift`, `LeetCodeStatementDocument.swift`, `DiagnosticsModel.swift` (the `@MainActor` model mould).
- `Tests/PisakaCoreTests/` — `DependencyPinTests`, `LicenseCoverageTests`, `ReleaseMetadataTests`, `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` (the shared scanner), `GitHubSourceGatingTests.strippingComments(_:)` (the literal-**keeping** scanner), `BottomPanelSourceGatingTests` (the gating style), `LSPProvisioningManifestTests` (the byte-pin style), `Support/StubFileTree.swift` (`Gate`).
- `Tests/PisakaAppTests/` — the second bundle, where the parser may actually run.
- `docs/architecture/`, `docs/FEATURES.md`, `README.md`, `CLAUDE.md`.

Files created (Core): `MarkdownDocument.swift`, `MarkdownPreviewTheme.swift`, `MarkdownHighlightClasses.swift`, `MarkdownRenderer.swift`, `MarkdownPreviewPage.swift`, `MarkdownPreviewAsset.swift`, `MarkdownLinkRule.swift`, `MarkdownScrollRule.swift`, `MarkdownPreviewWidthRule.swift`, `MarkdownPreviewModel.swift`.

Files created (app, all `#if os(macOS)`): `MarkdownParser.swift` (the only `import Markdown`), `MarkdownPreviewSchemeHandler.swift`, `MarkdownPreviewWebView.swift` (the only `import WebKit` in the feature), `MarkdownPreviewController.swift` (thin glue, no logic), `MarkdownPreviewPane.swift`, `EditorCommandTarget.swift` (the focus helper).

Resources created: `Resources/MarkdownPreview/{highlight.min.js, mermaid.min.js, preview.js, preview.css, VENDORED.md}`, `Resources/Licenses/{swift-markdown.txt, swift-cmark.txt, highlight.js.txt, mermaid.txt}`.

Related patterns to follow by name: `LeetCodeStatementDocument` (themed document, colours as CSS strings), `DiagnosticsModel` / `LeetCodeJudgeModel` (`@MainActor` Core model with injected seams and a generation token), `DatabaseViewerHost` (`.viewer` routing site), `BottomPanelHeightRule` + `panelDivider` (fixed base, named coordinate space), `LSPProvisioningManifestTests` (SHA-256 + byte pins), `Vendor/*/VENDORED.md` (update procedure), the source-gating suites (comment- and literal-stripped matching, with `GitHubSourceGatingTests`' literal-keeping scan as the precedent for the one rule that needs literals).

Dependencies: `apple/swift-markdown` (transitively `swift-cmark`, plus DocC plugin identities that link nothing).

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core value types and rules; the renderer, page shell, asset/link/width/scroll rules and the preview model are written together with their tests in the same task.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task** — `swift test` after every task; `xcodebuild … -destination 'platform=macOS' build` after any task touching `project.yml` or the app layer, always with a derived-data path outside the repository.
- Core stays Foundation-only. The app layer composes no HTML, spells no scheme name, host or path prefix, classifies no link and no path, and owns no ordering.
- Every gating assertion matches comment- and literal-stripped text, with one stated exception recorded in the suite's doc comment (Task 15).
- Async tests stage with a causal rendezvous (`Gate` / a `waitFor` helper), never a delay; assertions poll for a sink's record rather than assuming a hop count.
- No product or brand comparisons anywhere in code, comments, docs or commit messages.

## Implementation Steps

### Task 1: The dependency, its pins and its licenses

**Files:**
- Modify: `project.yml`, `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, `Resources/Licenses/licenses.json`, `Tests/PisakaCoreTests/DependencyPinTests.swift`, `Tests/PisakaCoreTests/LicenseCoverageTests.swift`
- Create: `Resources/Licenses/swift-markdown.txt`, `Resources/Licenses/swift-cmark.txt`

- [x] Add `SwiftMarkdown` to `project.yml`'s `packages:` (url `https://github.com/swiftlang/swift-markdown`, `revision:` the exact commit of the current release) and to the `Pisaka` target's `dependencies:` (product `Markdown`); write the comment block that explains the transitive `swift-cmark` branch requirement the way the SwiftTreeSitter block explains Neon's.
- [x] Regenerate the project and resolve (`xcodegen generate`, `xcodebuild -resolvePackageDependencies`), committing the regenerated v2 `Package.resolved` — never hand-edited.
- [x] Turn `DependencyPinTests`' branch-pin rule into a documented **set** of two (`swifttreesitter`, `swift-cmark`), each with its own recorded revision assertion and its own stated reason; update the suite's doc comment and the tests that read it so a *third* branch pin still fails.
- [x] Copy the verbatim `LICENSE` of swift-markdown and of swift-cmark at their resolved revisions into `Resources/Licenses/`, appending swift-cmark's bundled GFM-extension notice the way `libgit2.txt` carries its `LINKING EXCEPTION`; add both `licenses.json` notices with their resolved revisions and SPDX expressions.
- [x] Record `swift-cmark` as a transitive-but-linked identity in `LicenseCoverageTests` (the Neon/SwiftTreeSitter precedent), and add any DocC plugin identities that appear in `Package.resolved` to `licenses.json`'s `excluded` array with the reason "build-tool plugin, never linked".
- [x] Run `swift test` — `DependencyPinTests` and `LicenseCoverageTests` must be green — then the macOS build.

### Task 2: The Core document tree

**Files:**
- Create: `Sources/PisakaCore/MarkdownDocument.swift`, `Tests/PisakaCoreTests/MarkdownDocumentTests.swift`

- [x] Define `MarkdownBlock` and `MarkdownInline` as `Equatable, Sendable` value types covering CommonMark plus the GFM extensions this feature renders: paragraph, heading(level), fenced/indented code (language, code), blockquote, ordered/unordered list, list item (with an optional checkbox state), table (alignment per column, header row, body rows), thematic break, and inline text, emphasis, strong, strikethrough, inline code, link, image, autolink, line break.
- [x] Give every **top-level** block a `sourceLine: Int?` (1-based, the block's first source line) — the value `data-line` is rendered from; nested blocks carry none.
- [x] Define `MarkdownDocument` as the ordered top-level block list, with no parsing, no HTML and no platform types anywhere in the file; state in the doc comment that the tree has **no raw-HTML case at all**, which is what makes the drop rule structural.
- [x] Write construction/equality tests covering each case, including a nested list with checkboxes and a table with mixed alignment.
- [x] Run `swift test`.

### Task 3: The parser bridge (the one `import Markdown`)

**Files:**
- Create: `Sources/Pisaka/MarkdownParser.swift`, `Tests/PisakaAppTests/MarkdownParserTests.swift`, `Tests/PisakaAppTests/Fixtures/every-element.md`

- [x] Write `MarkdownParser` under `#if os(macOS)`: one `parse(_ text: String) -> MarkdownDocument` that walks swift-markdown's AST and maps it onto the Core tree, taking `sourceLine` from each top-level node's source range and **making no decisions** — no filtering, no normalisation, no defaults beyond the mapping itself.
- [x] Conform it to Core's parser seam protocol (Task 11), so the model never names swift-markdown.
- [x] Map raw HTML nodes (block and inline) to **nothing**, which is not a decision but the absence of a target case; state that in the doc comment.
- [x] Write the fixture containing every supported element (headings, nested lists, task items, a table, both fence forms, a `mermaid` fence, images, autolinks, strikethrough, a raw HTML block and an inline raw HTML span).
- [x] Add the headless `PisakaAppTests` case asserting the resulting tree's shape and every top-level `sourceLine` — the only place in the pipeline where the parser executes.
- [x] Run `swift test` and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.

### Task 4: The theme and the highlight class table

**Files:**
- Create: `Sources/PisakaCore/MarkdownPreviewTheme.swift`, `Sources/PisakaCore/MarkdownHighlightClasses.swift`, `Tests/PisakaCoreTests/MarkdownPreviewThemeTests.swift`
- Modify: `Sources/Pisaka/SyntaxTheme.swift`, `Sources/PisakaCore/SyntaxTokenKind.swift` (the `CaseIterable`/`Hashable`/`Sendable` conformances the set-equality tests and the per-kind CSS emission need)

- [x] Define `MarkdownPreviewTheme` as CSS colour strings only (background, text, secondary text, link, code background, border, table border, `colorScheme`) **plus one colour per `SyntaxTokenKind`**, in the `LeetCodeStatementDocument.Theme` mould — no platform colours anywhere in the file.
- [x] Define `MarkdownHighlightClasses`: the mapping from highlight.js class name to `SyntaxTokenKind`, plus the pinned list of the standard build's emitted class names, with the source of that list recorded in the doc comment (and re-stated in `VENDORED.md` in Task 9).
- [x] Add the app-side derivation in `SyntaxTheme.swift`: one function turning the editor palette + a resolved appearance into a `MarkdownPreviewTheme`, so preview code matches editor code.
- [x] Test the table **both ways** by set equality: every `SyntaxTokenKind` is reachable from at least one class, and every class of the pinned standard set maps to a kind.
- [x] Test that a light and a dark theme differ in every colour field, and that `colorScheme` is exactly `"light"`/`"dark"`.
- [x] Run `swift test`.

### Task 5: The renderer (tree → HTML body)

**Files:**
- Create: `Sources/PisakaCore/MarkdownRenderer.swift`, `Tests/PisakaCoreTests/MarkdownRendererTests.swift`

- [x] Write `MarkdownRenderer.body(for:context:)` as a pure function of the tree and a `MarkdownDocumentContext` (document URL, project root): HTML escaping for text and attribute values, `data-line="N"` on every top-level block, task items as `<input type="checkbox" disabled>`, a fence with a language as `<pre><code class="language-…">`, a `mermaid` fence as `<pre class="mermaid">`, a fence without a language as plain `<pre><code>` (no auto-detection).
- [x] Rewrite every relative `src`/`href` through Task 7's asset rule — an approved target becomes an **app-scheme URL**, everything else is emitted unresolved so it renders as a broken image with its alt text and, for a link, is later refused. The renderer is therefore what puts an app-scheme URL into the page, which is what the navigation delegate will see (Task 7's inverse is the other half of the round trip).
- [x] Emit tables with per-column alignment, blockquotes, both list kinds with `start`, thematic breaks, strikethrough and autolinks.
- [x] Write per-kind tests: escaping of `<`, `&`, quotes in text *and* in attributes; `data-line` on top-level blocks only; the three fence variants; checkbox items; a table's alignment attributes; a document whose source contained raw HTML producing nothing for it; a relative image inside the root emitted as an app-scheme URL and one outside it emitted unresolved.
- [x] Run `swift test`.

### Task 6: The page shell, the scheme and the CSP

**Files:**
- Create: `Sources/PisakaCore/MarkdownPreviewPage.swift`, `Tests/PisakaCoreTests/MarkdownPreviewPageTests.swift`

- [x] Write `MarkdownPreviewPage`: the whole `<head>` (charset, `color-scheme`, the theme as CSS custom properties including one per `SyntaxTokenKind`, the code font size), the CSP meta, `<link>`/`<script>` tags for the four bundled files by fixed name, an empty body container, and the shell's one bootstrap call.
- [x] Spell the custom scheme name, the shell's URL, the host and the bundled-file path prefix **in this one Core file** as public constants; nothing in the app layer may spell any of them.
- [x] Compose the CSP so every network origin is forbidden: `default-src 'none'`, scripts and styles from the app scheme only, `'unsafe-inline'` for styles alone (mermaid inlines `<style>` into its SVG) and never for scripts, images from the app scheme and `data:`, `connect-src 'none'`.
- [x] Add the body-update and scroll entry points as Core-composed JavaScript: one function returning the `evaluateJavaScript` source that replaces the container's inner HTML with a JSON-encoded body string and re-runs highlight/mermaid, and one returning the `scrollToLine` call — both escaping their arguments here, so the app passes values, never fragments.
- [x] Test the CSP string verbatim, the presence and order of the script tags, that the shell names no `http`/`https` URL at all, that light and dark shells differ, that the code font size reaches the CSS, and that the body-update source round-trips a body containing quotes, backslashes, newlines and `</script>`.
- [x] Run `swift test`.

### Task 7: The app-scheme mapping (both directions), the link rule and the scroll rule

**Files:**
- Create: `Sources/PisakaCore/MarkdownPreviewAsset.swift`, `Sources/PisakaCore/MarkdownLinkRule.swift`, `Sources/PisakaCore/MarkdownScrollRule.swift`, `Tests/PisakaCoreTests/MarkdownPreviewAssetTests.swift`, `Tests/PisakaCoreTests/MarkdownLinkRuleTests.swift`

- [x] Put **both directions of the app-scheme ↔ project-file mapping in this one Core file**: forward (`assetURL(forTarget:context:)`) resolves a relative path against the document's directory and answers an app-scheme URL only when the result is inside the project root after canonical comparison (symlinks resolved through `CanonicalPath`); inverse (`projectFileURL(forPreviewURL:context:)`) turns an app-scheme URL back into a file URL, answering `nil` unless it is inside the root under the same canonical comparison. `http(s)`, absolute `file:` outside the root, `../` escapes and any path in a document with **no URL** answer nothing in the forward direction; a forged or foreign app-scheme URL answers `nil` in the inverse.
- [x] Express the scheme handler's whole dispatch as one Core classifier over an incoming URL — `shell`, `bundled(name)`, `asset(fileURL)` (the file URL coming from the inverse), `refused` — so the handler dispatches and parses nothing.
- [x] Write `MarkdownLinkRule` taking the **navigation URL** (which is what the renderer emitted: an app-scheme URL for a project target) plus the document context, with exactly four answers: `external(URL)` for `http`/`https`/`mailto`, `openInEditor(URL)` carrying the file URL **obtained through the inverse**, `anchor(String)` for a fragment on the shell URL, `refused` for everything else (`javascript:`, `data:`, an app-scheme URL the inverse rejects, `file:` outside the root) — one closed enum the navigation delegate can only dispatch on. The delegate and the handler both call the Core inverse; neither parses a path.
- [x] Write the scroll rule: the editor's top character offset plus a `LineStartIndex` yields the 1-based top visible line that is sent to the page; nothing maps in the other direction.
- [x] Add the **round-trip test**: render a document containing a relative link to a project file, take the `href` the renderer emitted, feed it to `MarkdownLinkRule`, and assert `openInEditor` carrying the original file URL (canonically equal).
- [x] Test both rules over a real temporary tree including a **symlink pointing out of the root**, a `../` escape, a document with no URL, an anchor, a `javascript:` URL, a path with spaces and percent-encoding, a file inside the root reached through a symlinked ancestor, and an app-scheme URL naming a path outside the root (refused, not opened).
- [x] Test the scroll rule at offset 0, mid-document, at the last line and past the end.
- [x] Run `swift test`.

### Task 8: The width rule and the two preferences

**Files:**
- Create: `Sources/PisakaCore/MarkdownPreviewWidthRule.swift`, `Tests/PisakaCoreTests/MarkdownPreviewWidthRuleTests.swift`
- Modify: `Sources/PisakaCore/SettingsStore.swift`, `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [x] Write `MarkdownPreviewWidthRule` beside `BottomPanelHeightRule` and in its shape: a fraction clamped to `[0.2, 0.8]`, a 240 pt minimum for each half, half the width when the window cannot fit both minimums, and the same non-finite/non-positive guards.
- [x] Give it the drag form too — `fraction(base:dragTranslation:available:)` applied to a fixed base, matching the divider's fixed-base scheme.
- [x] Add `markdownPreviewEnabled` (default `false`) and `markdownPreviewFraction` (default `0.5`) to `SettingsStore` with the file's existing write discipline: clamped inside `didSet`, clamped again on read at `init`.
- [x] Test the clamps at both ends, both minimums, the degenerate narrow window, the drag mapping's one-to-one behaviour inside the bounds, and the non-finite guards.
- [x] Test the settings defaults, that a corrupt stored fraction is clamped on read, and that the enabled flag round-trips.
- [x] Run `swift test`.

### Task 9: The bundled assets, their pins and their licenses

**Files:**
- Create: `Resources/MarkdownPreview/{highlight.min.js, mermaid.min.js, preview.js, preview.css, VENDORED.md}`, `Resources/Licenses/{highlight.js.txt, mermaid.txt}`, `Tests/PisakaCoreTests/MarkdownPreviewAssetPinTests.swift`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`, `Tests/PisakaCoreTests/LicenseCoverageTests.swift`, `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

- [x] Add the two third-party files (highlight.js standard build; mermaid's single-file bundle — if the chosen version's `dist` is split into chunks, pin the newest version that ships one file, and record that in `VENDORED.md`) and write the first-party `preview.js` (`render(bodyHTML)` and `scrollToLine(line)`, highlight.js invoked per `code[class^=language-]` with auto-detection **off**, mermaid initialised with `startOnLoad: false`, `securityLevel: 'strict'` and the theme taken from the shell's colour scheme, each diagram rendered in a `try`/`catch` that writes mermaid's own error into that block and leaves the page intact) and `preview.css` (reading the shell's CSS custom properties only).
- [x] Write `Resources/MarkdownPreview/VENDORED.md` in the `Vendor/*/VENDORED.md` mould: upstream project, exact version, what is verbatim vs. authored here, the by-hand update procedure, the pinned highlight.js class list and the accepted bundle growth (~4.5 MB, mermaid being most of it).
- [x] Declare `Resources/MarkdownPreview` in `project.yml` as a `type: folder` reference beside `Resources/Queries`, with the same comment; attempt `destinationFilters: [macOS]` on that entry and, if XcodeGen or the iOS build rejects it, keep it unfiltered and record the reason in the comment (the unfiltered SwiftTerm/libgit2 precedent).
- [x] Write `MarkdownPreviewAssetPinTests` in the `LSPProvisioningManifestTests` mould: read each of the two third-party files through `#filePath`, assert its byte count and its SHA-256 (Core's own `SHA256`), and cross-check that the version string embedded in each file matches what `VENDORED.md` states.
- [x] Ship both license texts (BSD-3 for highlight.js; MIT for mermaid plus the third-party notices its distribution carries) and add their `licenses.json` notices with `origin` naming their shipped path; extend `LicenseCoverageTests` with that third **source class** — the coverage set becomes packages ∪ transitive ∪ bundled assets, every notice with a `Resources/` origin must name a file that exists, and every file in `Resources/MarkdownPreview/` must be either a named first-party file (`preview.js`, `preview.css`, `VENDORED.md`) or the origin of exactly one notice, so an unlicensed file there fails the suite.
- [x] Extend `ReleaseMetadataTests` with the `Resources/MarkdownPreview` folder-reference assertion, written the way the `Licenses`/`Queries` ones are (path *and* `type: folder` together, not a bare `contains`).
- [x] Run `swift test`, then `xcodegen generate` and both platform builds.

### Task 10: The scheme handler and the web view

**Files:**
- Create: `Sources/Pisaka/MarkdownPreviewSchemeHandler.swift`, `Sources/Pisaka/MarkdownPreviewWebView.swift`
- Modify: `Tests/PisakaAppTests/` (one new case)

- [x] Write the `WKURLSchemeHandler` under `#if os(macOS)`: it hands every incoming URL to Task 7's Core classifier and answers exactly three kinds — the **shell** (the page HTML Core composed, held as retargetable state the glue sets), the four bundled files by fixed name from `Bundle.main`, and project files whose file URL the Core inverse produced. Everything else is a plain 404 response, never a thrown error and never a log line. It parses no path and spells no scheme, host or prefix.
- [x] Give it the document context (document URL, project root) as retargetable state too, so the one handler serves whichever Markdown tab is active.
- [x] Write `MarkdownPreviewWebView` as the only `import WebKit` of the feature: an `NSViewRepresentable` over a `WKWebView` configured with the handler, a non-persistent data store, no back-forward gestures, and a navigation delegate that dispatches on `MarkdownLinkRule`'s four answers and decides nothing itself (external → `NSWorkspace.open`, `openInEditor` → the injected open callback with the rule's file URL, anchor → an `evaluateJavaScript` scroll, refused → `.cancel`).
- [x] **Load the shell through the handler** — `load(URLRequest(url: <Core's shell URL>))` at exactly one site — so the document has one app-scheme origin; the body is thereafter updated only through `evaluateJavaScript` with the source Core composes, and a theme/font change re-installs the new shell HTML on the handler and re-loads that same URL.
- [x] Conform the web view to Core's page-sink seam (Task 11): evaluate a JavaScript source, or perform the shell reload.
- [x] Add a smoke test in `PisakaAppTests` that constructs the handler with a temporary project tree and asserts the three answered request kinds plus a 404 for a `../` escape and for a forged app-scheme URL, with no error thrown.
- [x] Run `swift test` and the macOS app-layer test bundle. (`swift test` green — 5470 tests; `xcodebuild … -destination 'platform=macOS' build` and `generic/platform=iOS` build both green; `swiftlint --strict` clean. The app-layer *test action* could not execute in this environment: `xcodebuild … test` fails with "The test runner hung before establishing connection" for the application-hosted bundle, and does so identically on a clean tree with these changes stashed, so it is environmental and not caused by this task. The new suite compiles as part of that run.)

### Task 11: The Core preview model (the whole ordering)

**Files:**
- Create: `Sources/PisakaCore/MarkdownPreviewModel.swift`, `Tests/PisakaCoreTests/MarkdownPreviewModelTests.swift`, `Tests/PisakaCoreTests/Support/ScriptedMarkdownSeams.swift`

- [x] Write `MarkdownPreviewModel` as an `@MainActor` Core model in the `DiagnosticsModel`/`LeetCodeJudgeModel` mould, with **two injected seams**: a parser seam (a `Sendable` protocol with one method, `String -> MarkdownDocument`, which `MarkdownParser` conforms to) and a page-sink seam (a protocol the web view conforms to: evaluate a JavaScript source, and reload the shell with a given page HTML).
- [x] Give the model everything that decides *when*: the generation token captured **synchronously** before every hop with superseded results discarded; the 300 ms debounce on the active buffer's text with the first render after a retarget **immediate**; the last tree and last body it holds; the theme and code-font-size inputs; the rule that a theme or font change **reloads the shell and re-renders the body from the last tree without re-parsing**, while a text change re-parses off the main actor and updates the body in place.
- [x] Give it the retarget (a new document context clears the body, re-parses immediately and re-serves) and the clear (a non-Markdown tab, the preference going off, a folder switch), plus Task 14's coalescing: a scroll line marks the model dirty and is flushed **once per main-runloop turn**, never a timer, and never more than one `scrollToLine` per turn.
- [x] Write `ScriptedMarkdownSeams`: a scripted parser (recording every text it was asked to parse, with a `Gate` per text so two parses can be staged in a chosen resume order) and a scripted sink (recording every evaluated source and every shell reload in order).
- [x] Test: a superseded parse never publishes over a newer one (both racers held on the gate and resumed in call order, so the stale run finishes first); a theme change reloads the shell and re-renders **without a second parse** (the scripted parser's record is unchanged); a retarget renders immediately rather than after the debounce; a clear empties the body and sends nothing afterwards; a burst of scroll lines produces exactly one `scrollToLine` per turn, carrying the last line. All staged with `Gate`/`waitFor`, polling the sink's record, never a delay.
- [x] Run `swift test`. (5484 tests green; `swiftlint --strict` clean; `xcodebuild … -destination 'platform=macOS' build` green with a derived-data path outside the repository.)

### Task 12: The app glue, placement, divider, menu item and preference

**Files:**
- Create: `Sources/Pisaka/MarkdownPreviewController.swift`, `Sources/Pisaka/MarkdownPreviewPane.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

- [x] Write `MarkdownPreviewController` as **thin glue with no logic of its own**: it owns the one web view per window and the handler, constructs `MarkdownPreviewModel` with the app's parser and the web view as the sink, and forwards the workspace's facts to the model (active tab text, document context on selection change, project root on folder switch, theme and code font size). It holds no token, no debounce, no dirty flag and no branch on what to reload; it gets no tests of its own — the model's tests and the gating suite cover it.
- [x] Retarget the single web view on selection change the way the Local History window is retargeted, rather than keeping one view per tab.
- [x] Route the split in `editorZone` at the same site the `.viewer` kind is routed: below the breadcrumb, for a `.text` tab whose `SyntaxLanguage(forFileName:)` is `.markdown` while the preference is on, an `HStack` of `textEditorZone(for:)` and the preview pane with a divider between them; every other tab is untouched.
- [x] Drive the divider with `MarkdownPreviewWidthRule` in the bottom dock's exact scheme: `DragGesture(minimumDistance: 0, coordinateSpace: .named(...))` on a named space published on the pinned split rect, a base captured at drag start, the opening zero-translation frame written nowhere, the resize cursor pushed for hover-or-drag through one sync function, and `onDisappear` releasing both. Write the fraction to `SettingsStore` **once, in `onEnded`**.
- [x] Give the pane `.background(ZoomSurfaceMarker(kind: .code))` and feed it the code font size, exactly as the LeetCode statement pane does.
- [x] Add View → *Markdown Preview* as a checkmark item with ⌘⇧P, disabled unless the active tab is Markdown, toggling the one global preference from a single app site.
- [x] Extend `MarkdownPreviewModelTests` with the cases this glue drives — retarget on selection change, clear on folder switch, clear when the preference goes off — asserted through the scripted seams.
- [x] Run `swift test` and the macOS build. (5487 Core tests green; `xcodebuild … -destination 'platform=macOS' build` green with a derived-data path outside the repository; `swiftlint --strict` clean after bumping `PisakaApp.swift`'s two measured ceilings by the four lines the menu item costs, with `LintConfigurationTests` updated to match.)

### Task 13: The focus helper

**Files:**
- Create: `Sources/Pisaka/EditorCommandTarget.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/FoldCommands.swift`

- [x] Write the one helper: the key window's first responder when it is an `EditorTextView`; otherwise, **only when the first responder is the preview web view or a descendant of it**, the editor text view in that window's hierarchy; otherwise `nil` — so every existing beep is preserved byte for byte. (`EditorCommandTarget.focusedEditor(in:)`; the preview region is recognised through the `EditorCommandFocusPassthrough` marker its one conformer `MarkdownPreviewWKWebView` carries, walked up from the responder, so the helper needs no WebKit import and the preview keeps its one WebKit file.)
- [x] Route all six sites through it (`goToDefinitionAtCaret`, `findUsagesAtCaret`, `renameAtCaret`, `toggleCommentAtCaret`, `completeAtCaret`, `FoldCommands.focusedEditor()`), each keeping its own extra guards (`isEditable`, `hasMarkedText()`).
- [x] Document on the helper why the fallback is scoped to the preview rather than being a general search.
- [x] Add a `PisakaAppTests` case over a constructed window hierarchy: the helper answers the editor when the responder is the preview web view, and answers `nil` for an unrelated responder. (`EditorCommandTargetTests` — five cases: the editor itself, the preview, a descendant of the preview, an unrelated responder, and no window.)
- [x] Run `swift test` and the macOS app-layer test bundle. (5487 Core tests green; `swiftlint --strict` clean; `xcodebuild … -destination 'platform=macOS' build` and `build-for-testing` both green with a derived-data path outside the repository. The app-layer *test action* still cannot execute in this environment — "The test runner hung before establishing connection" — and does so identically for the pre-existing, untouched `BoundedBodyCollectorTests`, so it is environmental, as Task 10 recorded. The new suite compiles as part of `build-for-testing`.)

### Task 14: Scroll sync

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/MarkdownPreviewController.swift`, `Sources/Pisaka/ContentView.swift`

- [x] Add one optional callback to `CodeEditorView` that the coordinator calls from its existing clip-view bounds observer, carrying the top character offset it already captures. (`onScrolled` → `Coordinator.reportScrolled`, called from `clipViewBoundsChanged` through `reportScroll()`, which is guarded on the closure so an unwatched editor does not even capture a viewport.)
- [x] Have the glue map that offset to a line through `MarkdownScrollRule` and hand the line to the model — the coalescing, the flush and the single `scrollToLine` per turn are the model's (Task 11), not the controller's. (`MarkdownPreviewController.noteScrolled(topOffset:)`; the line starts of the text it was already handed are memoised there and dropped on every forward, so a scroll frame costs no re-scan and a keystroke with nobody scrolling costs none at all.)
- [x] Scroll the page without animation to the last top-level block whose `data-line` is at or before that line (`preview.js`); scrolling the preview sends nothing back. (`PisakaPreview.scrollToLine`, written with the page in Task 9/10: one `window.scrollTo`, no `behavior: "smooth"`, and the page installs no message handler at all, so there is no channel back.)
- [x] Extend the Core tests: the rule's mapping at a scrolled offset, and the model's coalescing under a burst delivered in one turn, asserted by polling the scripted sink's record. (`MarkdownScrollRuleTests.testAScrolledOffsetAnswersTheSourceLineOfTheBlockItIsIn` — every block's `data-line`, a blank line between two, and mid-block; `MarkdownPreviewModelTests` gains a sixty-frame gesture collapsing to one call carrying line 60, plus a pending scroll dropped by a retarget and by a clear.)
- [x] Run `swift test` and the macOS build. (5491 Core tests green; `swiftlint --strict` clean; `xcodebuild … -destination 'platform=macOS' build` green with a derived-data path outside the repository.)

### Task 15: The source-gating suite

**Files:**
- Create: `Tests/PisakaCoreTests/MarkdownPreviewSourceGatingTests.swift`

- [ ] Write it in the established style, reusing `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`, with the feature's file set enumerated explicitly and the shared hosts (`ContentView.swift`, `PisakaApp.swift`, `CodeEditorView.swift`, `SyntaxTheme.swift`, `FoldCommands.swift`) named as such.
- [ ] Pin, by set equality where the rule is a set: `import Markdown` in exactly one app file; the feature's `import WebKit` in exactly one file; every app file of the feature inside `#if os(macOS)` and named by no file under `Sources/Pisaka/iOS/`.
- [ ] Pin the reader rule: neither `autosave` nor `localChanges` is named anywhere in the feature.
- [ ] Pin the one-origin rule: the feature spells `loadHTMLString` **nowhere**, the shell is loaded (`load(URLRequest`) from exactly one app site, and every body update goes through `evaluateJavaScript`.
- [ ] Pin the mapping rule: the scheme name, the shell URL, the host and the bundled-file prefix are spelled in exactly one Core file and in no app file; no app file of the feature spells a path-component split, `pathComponents` or `URLComponents` against a preview URL — the inverse is Core's.
- [ ] Pin that `markdownPreviewEnabled` is written from exactly one app site, and the focus helper's single definition with its six call sites, with no file of the feature spelling `firstResponder as? EditorTextView` itself.
- [ ] Pin "no app file of the feature composes HTML" — no `<` tag literal outside Core — using the **literal-keeping** scan (`GitHubSourceGatingTests.strippingComments(_:)`'s form), because the tag *is* a string literal and the shared scanner would delete the very thing the rule checks; record this as the suite's **one stated exception** in its doc comment.
- [ ] Run `swift test`.

### Task 16: Verify acceptance criteria

- [ ] `swift test` — full Core suite green, including the renderer, the rules, the model, the pins, license coverage, settings and the gating suite.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test` — the app-layer bundle green.
- [ ] `xcodebuild … -destination 'platform=macOS' build` and `-destination 'generic/platform=iOS' build` both green, with a derived-data path outside the repository.
- [ ] `swiftlint --strict` from the repository root clean.
- [ ] Re-read the CSP emitted by `MarkdownPreviewPage` and confirm by inspection that it names no network origin, and that the shell's only URLs are app-scheme ones.

### Task 17: Update documentation

**Files:**
- Create: `docs/architecture/core-markdown-preview.md`
- Modify: `CLAUDE.md`, `docs/FEATURES.md`, `README.md`, plus the architecture entries of every file whose behaviour changed (`core-editor.md`, `core-services.md`, `app-window.md`, `app-shell.md`, `app-editor.md`, `app-editor-overlays.md`, `core-folding.md`)

- [ ] Write `core-markdown-preview.md` covering both halves file by file, with numbered decisions: raw HTML dropped, the CSP, the page served through the handler under one origin (no `loadHTMLString`), the app-scheme ↔ file mapping owned in one Core file in both directions, one web view per window, the ordering owned by the Core model behind two seams, the global preference, the offline pins and the accepted ~4.5 MB, the in-place body update, the scoped focus fallback, the second documented branch pin, and the gating suite's literal-keeping exception.
- [ ] Add one index line per new file to `CLAUDE.md` under the new doc — including `MarkdownPreviewModel.swift` — plus one cross-cutting invariant paragraph stating the reader rule (writes nothing, never raises the writer gate, never gated by it; two preferences its only persisted state), and extend the Tests section's "two stated exceptions" sentence to name this suite's literal-keeping rule as the third.
- [ ] Add the feature to `docs/FEATURES.md` and a one-line summary to `README.md`, naming ⌘⇧P and the three stated limits (no raw HTML, no external images, no formulas).
- [ ] Update the entries of the touched existing files: the divider precedent (`app-window.md`), the two new settings (`core-services.md`), the focus helper and the six command sites (`app-shell.md`, `core-folding.md`), the editor's scroll callback (`app-editor.md`), the theme derivation (`app-editor-overlays.md`).

## Post-Completion (manual verification by the user)

- Open a `.md` file with the preference on: side-by-side layout, typing updates within roughly a third of a second with no visible reload and no lost scroll position; ⌘⇧P hides and shows; the divider drags within bounds and its position survives a relaunch.
- A `bash`, `c` and `java` fence is coloured with the editor's palette; a `mermaid` fence renders; a broken diagram shows its error in place and the rest of the page stays intact.
- A relative image inside the project shows; `../`, a symlink out of the root and `http(s)` show as broken images with alt text.
- An external link opens the browser; a relative link to a project file opens that tab (a `.md` target gets the preview, a `.db` target becomes a viewer tab); a `javascript:` link does nothing.
- Scrolling the editor scrolls the preview; clicking in the preview leaves ⌘S, ⌘/ and ⌘F working while selection and links still work.
- Light/dark switch live; changing the code font size changes the preview's code and body text.
