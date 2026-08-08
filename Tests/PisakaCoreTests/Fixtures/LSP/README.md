# Recorded `sourcekit-lsp` transcripts

Wire-level fixtures for the LSP client's Core layer. `LSPProtocolTypesTests`
decodes each one and re-encodes the request shapes; later phases
(`LSPIntelligenceProviderTests`) drive the provider from them. **No test in this
repository ever spawns a language server** — `swift test` stays the
dependency-free, offline gate it has always been, and these files are what make
that possible while still pinning against a *real* server's output rather than
against what the spec is remembered to say.

They are read through `#filePath`, in the `VendoredGrammarQueryTests` /
`SymbolQueryTests` style, so they need no SwiftPM resource declaration; the test
target instead `exclude:`s this directory in `Package.swift` (a `.json` beside
Swift sources is otherwise an unhandled-resource warning).

## Provenance

Everything below was recorded on **2026-08-09** against the `sourcekit-lsp`
shipped in **Xcode 26.6 (17F113)**, found through
`xcrun --find sourcekit-lsp`, driven by a throwaway JSON-RPC script over a
throwaway SwiftPM package with two modules:

```
Package.swift               // library Core, executable App depending on Core
Sources/Core/Greeter.swift  // public struct Greeter { salutation; init; greet(_:) }
Sources/App/main.swift      // import Core; let greeter = Greeter(); …
```

`Greeter.swift`'s line numbering, which several fixtures point into, is:

```
 0  /// A greeter used by the recorded LSP fixtures.
 1  public struct Greeter {
 2      public let salutation: String
 3
 4      public init(salutation: String = "Hello") {
 5          self.salutation = salutation
 6      }
 7
 8      public func greet(_ name: String) -> String {
 9          "\(salutation), \(name)!"
10      }
11  }
```

and `main.swift`'s is:

```
 0  import Core
 1  import Foundation
 2
 3  let greeter = Greeter()
 4  let message = greeter.greet("world")
 5  print(message)
```

The `file:///private/tmp/lspfix/pkg/…` and `/var/folders/…` URIs are left exactly
as the server wrote them — including the `/private` prefix it resolved `/tmp`
into, which is the very symlink caveat `CanonicalPath` exists for and worth
having on record — so a test that needs a project root spells that recorded root
out rather than the fixtures being rewritten to something tidier.

## The files

| File | How it was produced |
| --- | --- |
| `initialize-result.json` | verbatim |
| `definition-cross-module.json` | verbatim — `Greeter` in `main.swift`, answered with **two** `Location`s in `Greeter.swift` (the type and its `init`) |
| `definition-sdk.json` | verbatim — `String`, answered with a `Location` in a generated `.swiftinterface` under `/var/folders/…`, i.e. outside any project root (D3) |
| `definition-none.json` | verbatim — a position that resolves to nothing: `"result": null` |
| `completion-member.json` | verbatim — after `greeter.`, with `triggerCharacter: "."` |
| `completion-identifier.json` | verbatim **except trimmed**: the server returned 200 items and 176 KB, of which the first 6 and the last 4 are kept in their recorded order. The trim is deliberate rather than arbitrary — `Greeter` was the *last* item in the array and carries the *lowest* `sortText` (`4939.…` against the others' `4987.…`–`5001.…`), so this fixture pins D6's rule that ranking reads `sortText`, not array order, against output a real server actually produced. |
| `completion-resolve-request.json` | verbatim — the item echoed back as `completionItem/resolve`'s params |
| `completion-resolve.json` | verbatim — this server resolved that item to itself, unchanged |
| `shutdown-result.json` | verbatim — `"result": null` |
| `definition-location-link.json` | **authored, not recorded** (see below) |
| `completion-auto-import.json` | **authored, not recorded** (see below) |

## The two authored fixtures, and why

Two shapes the client must handle could not be obtained from this server, so
they are hand-written to the specification and labelled here rather than passed
off as recordings:

- **`definition-location-link.json`.** Every position tried (a local variable, a
  cross-module type, a method, a module name) answered with `Location[]` even
  with `textDocument.definition.linkSupport: true` advertised. `LocationLink[]`
  is a legal answer to the same request, is what phase 2b's servers send, and is
  the only shape that carries `targetSelectionRange` — the identifier range,
  which is a *better* jump target than `targetRange`'s whole declaration. The
  file describes the same `Greeter` jump the recorded `definition-cross-module`
  fixture does, expressed as a link.
- **`completion-auto-import.json`.** This `sourcekit-lsp` does not offer symbols
  from unimported modules, so it never emitted `additionalTextEdits` here. That
  edit list is the entire point of D4 (auto-import as one undo step), so the
  fixture states the shape: a `textEdit` replacing the typed prefix on line 3 and
  an `additionalTextEdits` entry inserting `import Core\n` at line 1 — an edit
  *before* the completion point, which is the case whose caret math is easy to
  get wrong.

If a future toolchain does produce either shape, re-record it and delete the
note; a real transcript is always worth more than a faithful reconstruction.

## One recorded fact worth remembering

`initialize-result.json` advertises `textDocumentSync.change: 2`
(**Incremental**), while D2 sends full-text `didChange` notifications. That
combination is what the recording session itself used, and completion answered
correctly afterwards: this server's `didChange` handler treats a content change
with no `range` as a whole-document replacement. It is a deliberate simplifying
choice, not an oversight — noted here because the fixture is the evidence.
