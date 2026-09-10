# Vendored: the Markdown preview's page assets

This directory is what the macOS Markdown preview pane *is*, as far as the web
view is concerned: four files, served by the app's own scheme handler out of
`Bundle.main`, and nothing else. Two of them are third-party bundles copied
verbatim; two are written here. The page that links them is composed in Swift
(`Sources/PisakaCore/MarkdownPreviewPage.swift`), never on disk, so there is no
`index.html` in this directory and there must never be one.

**Nothing here is fetched at run time.** The page's Content Security Policy names
no network origin at all (`default-src 'none'`, scripts and styles from the app
scheme alone, `connect-src 'none'`), so a build that did not carry these files
would show an unstyled, unhighlighted page rather than quietly reaching a CDN.
That is the whole reason the two bundles are in the repository instead of in a
`<script src="https://…">`: a preview of a file on disk must not be a network
request, and a file's contents must not be reachable by anything that could send
them anywhere.

## What ships, and what it costs

| File | Origin | Bytes |
|---|---|---|
| `highlight.min.js` | third party, verbatim | 127 496 |
| `mermaid.min.js` | third party, verbatim | 3 312 967 |
| `preview.js` | written here | — |
| `preview.css` | written here | — |

Total ≈ 3.4 MB of third-party JavaScript added to the app bundle, mermaid being
essentially all of it. That growth is **accepted, not overlooked**: it is the
price of diagrams rendering offline, it is within the ~4.5 MB the feature was
planned against, and it is compressed in the shipped archive. The two bundles are
data, not code the app compiles: nothing links them, nothing parses them, and
deleting this directory breaks the preview and nothing else.

## highlight.js

| | |
|---|---|
| Project | <https://github.com/highlightjs/highlight.js> |
| Version | `11.11.1` |
| Commit | `08cb242e7d4aee787114eb04cc7ab18314d82f92` |
| File | `highlight.min.js` |
| Source | <https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js> |
| Bytes | `127496` |
| SHA-256 | `c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381` |
| License | BSD-3-Clause — `Resources/Licenses/highlight.js.txt`, copied verbatim from the tag above (© 2006 Ivan Sagalaev) |

Copied **verbatim**, byte for byte, from the distribution above; the file states
its own version in its first line (`Highlight.js v11.11.1`) and in its
`versionString` constant, which is what `MarkdownPreviewAssetPinTests`
cross-checks against this document.

This is the **standard distributed build** — the single-file `highlight.min.js`
of the release, carrying the common language set: Bash, C, C++, C#, CSS, Diff,
Go, GraphQL, HTML/XML, Java, JavaScript, JSON, Kotlin, Less, Lua, Makefile,
Markdown, Objective-C, PHP, Perl, Plain text, Python, R, Ruby, Rust, SCSS, Shell
session, SQL, Swift, TypeScript, Visual Basic .NET, WebAssembly, YAML. A language
outside that set renders as plain, uncoloured code — never as a guess, because
`preview.js` highlights only elements the renderer gave a `language-…` class and
never asks highlight.js to auto-detect.

### The pinned scope list

`MarkdownHighlightClasses.standardScopes` is the class vocabulary of *this*
build, transcribed from `docs/css-classes-reference.rst` at the commit above.
Restated here so a bump has one place to re-check it against, and asserted in
both directions by `MarkdownPreviewThemeTests` (every scope maps to a
`SyntaxTokenKind`, every kind is reached by at least one scope):

```
keyword built_in type literal number operator punctuation property regexp
string char.escape subst symbol class function variable variable.language
variable.constant title title.class title.class.inherited title.function
title.function.invoke params comment doctag meta meta.prefix meta.keyword
meta.string section tag name attr attribute bullet code emphasis formula link
quote strong selector-tag selector-id selector-class selector-attr
selector-pseudo template-tag template-variable addition deletion
```

A scope highlight.js emits but this list omits renders in body-text colour — the
failure is silent, which is why the list is pinned rather than discovered.

## mermaid

| | |
|---|---|
| Project | <https://github.com/mermaid-js/mermaid> |
| Version | `11.15.0` |
| Commit | `41646dfd43ac83f001b03c70605feb036afae46d` |
| File | `mermaid.min.js` |
| Source | <https://cdnjs.cloudflare.com/ajax/libs/mermaid/11.15.0/mermaid.min.js> |
| Bytes | `3312967` |
| SHA-256 | `70137e77bb273bb2ef972b86e8b0400cca8be53cb25bfc45911a186dc98665de` |
| License | MIT — `Resources/Licenses/mermaid.txt`, copied verbatim from the tag above (© 2014–2022 Knut Sveidqvist), with both bundled-license banners and the verbatim notice of every package in the bundled runtime dependency closure appended |

Copied **verbatim**. This version is the pin for a reason worth stating: it is a
**single self-contained file**. mermaid's ESM distribution splits into chunks
that are loaded through dynamic `import()` at run time, and a chunk is a network
request the page's CSP refuses and the scheme handler does not serve — so the
build to pin is the one whose `dist/mermaid.min.js` is whole. 11.15.0 is: it is
an `esbuild` IIFE ending in `globalThis["mermaid"] = …`, it spells no `import(`
anywhere, and it embeds its own `version:"11.15.0"`, which is what the pin test
cross-checks. **A bump must re-verify that property before anything else** — a
chunked build produces a preview whose diagrams silently never appear.

The licence appendix is the second thing a bump must redo, and it is the step
where the obvious procedure is wrong. mermaid's own MIT `LICENSE` covers
mermaid's own source; the single-file distribution is an `esbuild` bundle of
mermaid's **whole runtime dependency closure**, so every package in that closure
compiles into this app. `Resources/Licenses/mermaid.txt` is upstream's `LICENSE`
with those notices appended below it — the `libgit2.txt` / `tree-sitter.txt`
pattern, for the same reason: a bundled dependency has no package identity, so no
package-level coverage check can see it.

**The bundler's own `Bundled license information` banner is not that closure**,
and taking it for one is the mistake this paragraph exists to prevent. `esbuild`
emits an entry only for a source that happens to carry a `/*! … */` legal
comment — four packages here (DOMPurify, js-yaml, lodash-es, cytoscape) — while
KaTeX, marked, dagre-d3-es, d3, rough.js and some fifty more carry none and are
compiled in silently. The banners are still copied in, above the closure,
because cytoscape's entry names four snippets embedded in cytoscape's own
sources that cytoscape's own `LICENSE` does not. Note also that the file carries
**two** banners, not one; both are reproduced.

Enumerate the closure with npm rather than by reading the bundle:

```sh
mkdir /tmp/mermaid-lic && cd /tmp/mermaid-lic && npm init -y
npm install --omit=dev --ignore-scripts mermaid@<version>
ls node_modules   # then copy each package's LICENSE/NOTICE verbatim
```

Two kinds of package in that closure are left out, and each exclusion must be
*re-verified* rather than carried over: TypeScript declaration packages
(`@types/*`, `@iconify/types`, `@chevrotain/types`), which contain no runtime
code; and the Node-only helpers reached from `@iconify/utils`'s Node entry
points (`@antfu/install-pkg`, `commander`, `iconv-lite`, `import-meta-resolve`,
`package-manager-detector`, `rw`, `safer-buffer`, `tinyexec`), none of whose
string literals appears in `mermaid.min.js`. A package the resolution no longer
reaches but the bundle still names — `js-yaml` today — is added by hand at the
version the banner states. DOMPurify is dual Apache-2.0 / MPL-2.0 and is taken
on its Apache-2.0 side, which is why the manifest's expression names
`Apache-2.0` and why the Apache *text* (not just the banner's one-line
reference) is in the file; the expression stays a flat SPDX one.
`LicenseCoverageTests.testTextsCarryTheirBundledSubDependencyNotices` pins one
holder per library a banner-only re-copy would drop, so this cannot silently
regress.

## What was written here

- `preview.js` — the page's five members (`boot`, `render`, `scrollToLine`,
  `scrollToAnchor`, `setFontSize`) and
  the whole of what the page does on its own: highlight the blocks the renderer
  gave a language to, render each diagram inside its own `try`/`catch`, and
  discard an answer from a superseded render. It decides nothing about *when* —
  that is `MarkdownPreviewModel`'s, and it is covered by `swift test`.
- `preview.css` — the page's shape, and **no colour of its own**: every colour is
  a CSS custom property the Swift-composed shell wrote out of
  `MarkdownPreviewTheme`, so the preview follows the editor's theme rather than
  holding a second opinion about it.

Neither file is minified and neither is generated; both are read as source.

## Updating

Both bundles are updated **by hand**, and the two must be done separately.

1. Download the new single file from the version's own distribution and check it
   against upstream's published SRI digest (cdnjs publishes one per file; the
   `sha512-…` it gives must equal `openssl dgst -sha512 -binary <file> | base64`).
   Never take a file from an unpinned "latest" URL.
2. For mermaid, confirm the bundle is still whole before anything else:
   `grep -c 'import(' mermaid.min.js` must print `0`, and the file must end in a
   `globalThis["mermaid"] = …` assignment. If the version's `dist` has become
   chunked, pin the newest version that still ships one file and record that here.
3. Replace the file in this directory, then re-record its version, commit, byte
   count and SHA-256 in the table above **and** in
   `Tests/PisakaCoreTests/MarkdownPreviewAssetPinTests.swift`. That suite fails
   until both agree, which is what keeps this document from going stale.
4. Re-copy the upstream `LICENSE` at the new tag into `Resources/Licenses/`. For
   mermaid, re-append **both** bundled-license banners *and* re-enumerate the
   runtime dependency closure with the `npm install` recipe above, copying each
   package's `LICENSE`/`NOTICE` verbatim — the banner alone is four packages of
   sixty-odd, and the packages it omits are the ones nothing else names. Update
   the entry's `version`, `revision` and, if a new licence family arrived, its
   `spdx` in `Resources/Licenses/licenses.json`, adding any new SPDX id to
   `LicenseCoverageTests.usedSPDXLicenseIDs`. `LicenseCoverageTests` fails until
   every file in this directory is either one of the two first-party files, this
   document, or the origin of exactly one notice, and until `mermaid.txt` still
   names each holder that suite pins.
5. For highlight.js, re-read `docs/css-classes-reference.rst` at the new tag and
   re-state the scope list above and in `MarkdownHighlightClasses`. Nothing at run
   time can notice a stale entry.
6. Run `swift test`, then `xcodegen generate` and both platform builds, and open a
   Markdown file with a fenced block and a `mermaid` fence in a DEBUG build — the
   two failure modes above (an unknown scope, a chunked bundle) are both silent
   and neither has a gate that compiles this directory.
