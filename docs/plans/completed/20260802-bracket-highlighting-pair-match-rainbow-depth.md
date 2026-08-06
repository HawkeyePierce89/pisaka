# Bracket Highlighting: Caret Pair Match + Rainbow by Depth

## Overview

Two mechanics at once, both built on one pool of logic in `PisakaCore`:

1. **Pair highlighting** — the caret sits next to a bracket → it and its match get a background (VS Code/Xcode).
2. **Rainbow** — every bracket is colored by its nesting depth, cycling through a 5-color palette; an unmatched bracket is red (JetBrains Rainbow Brackets).

The logic lives in two pure Core engines (`BracketMatchEngine`, `BracketDepthScanner`), Foundation-only and color-free. The view layer is an `NSLayoutManager` subclass that intercepts Neon's temporary-attribute writes and mixes the bracket colors back in — installed on the *existing* text view via `replaceLayoutManager(_:)`, so `makeNSView`'s current configuration stays untouched.

## Context

- Files:
  - Create: `Sources/PisakaCore/BracketMatchEngine.swift`, `Sources/PisakaCore/BracketDepthScanner.swift`
  - Create: `Tests/PisakaCoreTests/BracketMatchEngineTests.swift`, `Tests/PisakaCoreTests/BracketDepthScannerTests.swift`
  - Create: `Sources/Pisaka/BracketOverlayLayoutManager.swift`, `Sources/Pisaka/BracketHighlightController.swift` (both `#if os(macOS)`)
  - Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/SyntaxTheme.swift`, `CLAUDE.md`, `README.md`
- Precedents:
  - `AutoPairEngine` — surrogate-safe reads, range clamping, the opener/closer tables, raw scan with no string/comment awareness (the same deliberate boundary).
  - `IndentEngine.dedentOnClosing` — same-kind nesting depth counting.
  - `MinimapTokenizer` — debounce + cache key (fileID + text hash) for re-scanning.
  - `LineNumberRulerView` — observing `NSTextStorage.didProcessEditingNotification` filtered on `.editedCharacters` (Neon owns `textStorage.delegate`; the notification coexists with it).
  - `SyntaxTheme` — `PlatformColor.dynamic(light:dark:)`, color only in the view; a dynamic `NSColor` resolves at draw time, so a theme switch recolors for free.
  - `Coordinator.clipViewBoundsChanged` — the already existing clip-view scroll observer.
- Verified fact (Neon `Sources/Neon/TextViewSystemInterface.swift`): `LayoutManagerSystemInterface.applyStyles` writes **only** through `layoutManager.setTemporaryAttributes(attrs, forCharacterRange:)`, clearing the range first. So a single override in an `NSLayoutManager` subclass intercepts every Neon write — that is the chosen mechanism.

## Development Approach

- **Testing approach**: TDD for Core (tests before code, failing first for the expected reason); the view layer stays untested per project convention (verified by the builds).
- Each task is completed fully, with `swift test` green before moving to the next.
- Logic only in Core (Foundation-only, color-free); the view owns attributes and the palette.

### The two engines diverge on pathological input — deliberate, documented, and pinned by tests

The two engines answer *different questions* and therefore count depth differently:

- `BracketMatchEngine` counts **its own kind only** (the `IndentEngine.dedentOnClosing` rule): "which `]` closes *this* `[`" ignores unrelated `(`/`{`.
- `BracketDepthScanner` keeps **one shared stack across all three kinds** (JetBrains rainbow semantics): nesting depth is a single number for the whole document, so `{[()]}` reads 0,1,2.

On well-formed code the two always agree. On *crossed* brackets they do not: in `{[(]}` the matcher pairs `[`↔`]` (its own kind, correctly nested when `(` is ignored), while the scanner sees `]` arriving with `(` on top of the stack, marks it unmatched, and leaves `[` unmatched as a leftover — so the caret at `[` can show a **red bracket that nonetheless has a highlighted pair**. This is accepted (the input is broken code mid-typing; neither answer is wrong for its own question), and both engines' doc comments must state the divergence *and name the other engine*, with a test in each suite pinning the exact `{[(]}` outcome so a future reader finds the intent instead of filing a bug.

### Other deliberate deviations from the original brief

- `BracketMatchEngine.pair` takes `selectedRange: NSRange` rather than `caretLocation: Int` — otherwise the "non-empty selection → nil" rule cannot be tested in Core (acceptance criterion #2 requires it). Precedent: `AutoPairEngine.action(text:selectedRange:typed:)`.
- The rainbow scan runs on the main actor after the debounce (O(n) over characters, no tree-sitter — cheap), **but only because the scan reads through a bulk `getCharacters(_:range:)` copy rather than per-character `character(at:)` calls** — a per-character objc message send over a megabyte-sized file would turn that "cheap O(n)" into visible main-thread jank. Pinned as an implementation requirement in Task 2. The generation token is still there and protects the deferred debounce task from going stale on a tab switch.
- `BracketMatchEngine` deliberately keeps the `AutoPairEngine`-style single-character reads: it scans outward from the caret and stops at the match, which for real code is a handful of characters away, so a whole-buffer bulk copy on every selection change would cost more than it saves. The scanner is the opposite shape — it always touches every character — which is why the two differ.

## Implementation Steps

### Task 1: Core — BracketMatchEngine (pair highlighting)

**Files:**
- Create: `Sources/PisakaCore/BracketMatchEngine.swift`
- Create: `Tests/PisakaCoreTests/BracketMatchEngineTests.swift`

- [x] write `BracketMatchEngineTests` before the code: caret before and after an opener; before and after a closer; brackets on both sides (the character *after* the caret wins — VS Code order); same-kind nesting (`{a{b}c}` — from a caret at the outer bracket the outer pair is found); mixed kinds don't get confused (`{[a(b]}` — the unmatched `(` yields nil; `{[(]}` — `[` matches `]`); unbalanced buffer → nil; non-empty selection → nil; caret at the start and at the end of the buffer; empty buffer; out-of-bounds location / `NSNotFound` → nil without trapping; a bracket adjacent to a surrogate pair (emoji) is read correctly
- [x] add the **divergence-pinning test** `testCrossedBracketsPairPerKindUnlikeDepthScanner`: on `{[(]}` the caret at `[` yields the pair `[`↔`]`, with a comment naming `BracketDepthScanner` (which reports both as unmatched) and stating that the disagreement is intended on crossed input
- [x] confirm the tests fail for the expected reason (missing type/function)
- [x] implement `public struct BracketPair: Equatable { public let open: NSRange; public let close: NSRange }` (both length 1)
- [x] implement `public enum BracketMatchEngine { public static func pair(text: NSString, selectedRange: NSRange) -> BracketPair? }`: non-empty selection → nil; an out-of-range/`NSNotFound` location → nil (the one documented deviation from `AutoPairEngine`'s clamping: a caret outside the buffer names nothing to highlight, while `AutoPairEngine` must still decide what a keystroke does); the character after the caret first, then the one before; for an opener scan forward counting *its own* kind's depth, for a closer scan backward; no pair → nil
- [x] doc comment: raw character scan, no string/comment awareness — the same boundary as `IndentEngine`/`AutoPairEngine`; a bracket inside a string literal still matches (known limitation; tree-sitter-aware matching is a follow-up); why this engine reads per character while `BracketDepthScanner` bulk-copies; **and an explicit "divergence" paragraph**: this engine counts *its own kind only* while `BracketDepthScanner` keeps one shared stack, so on crossed input (`{[(]}`) this returns a pair for brackets the scanner colors red — deliberate, since the two answer different questions, and pinned by a test in both suites
- [x] `swift test` — green

### Task 2: Core — BracketDepthScanner (rainbow)

**Files:**
- Create: `Sources/PisakaCore/BracketDepthScanner.swift`
- Create: `Tests/PisakaCoreTests/BracketDepthScannerTests.swift`

- [x] write `BracketDepthScannerTests` before the code: empty text → `[]`; text with no brackets → `[]`; flat sequence `()()` — both pairs at depth 0; nesting `((()))` — depths 0,1,2 and the same on the closers; shared stack across kinds `{[()]}` — depths 0,1,2; a closer of the wrong kind → `isUnmatched` (and does not pop the stack); a stray closer → unmatched; an opener left over at the end → unmatched; a depth > 5 is reported as an honest `Int` (cycling is the view's job); tokens sorted by `location`; surrogate pairs in the text don't skew the UTF-16 offsets
- [x] add the mirror **divergence-pinning test** `testCrossedBracketsAllUnmatchedUnlikeMatchEngine`: on `{[(]}` every token is `isUnmatched`, in particular `[` and `]` — with a comment naming `BracketMatchEngine` (which *does* pair those two) and stating the disagreement is intended
- [x] add a **chunk-boundary test**: build a text longer than `BracketDepthScanner.chunkSize` (referenced from the test via `@testable import PisakaCore`) with a nested pair whose opener and closer straddle a chunk boundary, and with a bracket sitting at the exact first and last unit of a chunk — depths and locations must be identical to what a short equivalent yields, so the chunked read can never drop or misplace a token
- [x] confirm the tests fail for the expected reason
- [x] implement `public struct BracketToken: Equatable { public let location: Int; public let depth: Int; public let isUnmatched: Bool }`
- [x] implement `public enum BracketDepthScanner { public static func scan(text: NSString) -> [BracketToken] }` with the **required access pattern**: no `character(at:)` in the loop. Read the text through `getCharacters(_:range:)` into a reusable `[unichar]` buffer of a fixed `internal static let chunkSize` (4096 units) — `withUnsafeMutableBufferPointer` + one `getCharacters` call per chunk, then a plain pointer walk over the chunk — so the whole scan costs `ceil(n / 4096)` objc message sends instead of `n`, and the allocation stays bounded regardless of file size (a megabyte file does not get a second megabyte-sized copy). Chunking is invisible to the result: the depth stack and the token array are carried across chunks and each token's `location` is `chunkStart + indexInChunk`
- [x] scanning semantics (unchanged by the chunking): one O(n) pass, a shared stack across all three kinds; an opener gets the depth *before* the increment; a matching closer gets its opener's depth; a closer of the wrong kind or with no opener → `isUnmatched: true, depth: 0` (leaves the stack untouched); openers still on the stack when the scan ends are patched to unmatched (order by `location` preserved)
- [x] doc comment: the same raw scan with no string/comment awareness; depth is semantic, the view resolves the palette by `depth % N` (the `FileIconColor` precedent); **why the chunked bulk read exists** — the caller runs this on the main actor after a debounce, so the per-character objc-call pattern would make a large file janky while a bulk copy keeps it a plain memory walk; **and the mirror "divergence" paragraph**: the shared stack is JetBrains semantics and differs from `BracketMatchEngine`'s per-kind counting, so on crossed input (`{[(]}`) a bracket colored red here can still show a highlighted pair — deliberate, accepted for broken code, pinned by a test in both suites
- [x] `swift test` — green

### Task 3: View — palette and BracketOverlayLayoutManager

**Files:**
- Modify: `Sources/Pisaka/SyntaxTheme.swift`
- Create: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] `SyntaxTheme`: add `bracketDepthColors: [PlatformColor]` (5 cycling `.dynamic(light:dark:)` colors), `bracketColor(forDepth:)` (`depth % count`), `unmatchedBracketColor` (red), `matchedPairBackground` — all through `PlatformColor` so the iOS variant (follow-up) comes for free; on macOS additionally `nsColor` wrappers alongside the existing one
- [x] create `BracketOverlayLayoutManager: NSLayoutManager` (macOS): holds `rainbowRuns: [(NSRange, NSColor)]` (visible range only, sorted) and `pairRanges: [NSRange]` + the background color; `override func setTemporaryAttributes(_:forCharacterRange:)` calls `super`, then mixes the intersecting overlays back in via `addTemporaryAttributes` (merge, not replace — Neon's colors are preserved), under a re-entrancy flag so nested calls don't recurse
- [x] `setRainbowRuns(_:)` / `setPairRanges(_:)` methods: apply the attributes, clear the previous pair (`removeTemporaryAttribute(.backgroundColor,…)` — nobody but us uses `.backgroundColor`, so removing it is safe) and call `invalidateDisplay(forCharacterRange:)` for the affected ranges; plus `clearRainbow(in:)` to clear `.foregroundColor` over the edited range (Neon repaints that same range after an edit anyway)
- [x] **install it via `replaceLayoutManager` — the primary path**: in `CodeEditorView.makeNSView`, right after the existing `EditorTextView(usingTextLayoutManager: false)` is created (and before the gutter / minimap / Neon attach), call `textView.textContainer?.replaceLayoutManager(BracketOverlayLayoutManager())`. This is the documented API for exactly this job: it swaps the layout manager while preserving the storage↔container↔view wiring, so **no other line of `makeNSView` changes** — `allowsNonContiguousLayout`, container sizing, disabled soft-wrap, undo, font and build order all stay as they are (note that `allowsNonContiguousLayout` is set on `textView.layoutManager` *after* the swap, so it lands on the new manager; verify the ordering when editing)
- [x] verify the swap is transparent before writing any further wiring (static verification + a debug `assert`; the on-screen part is manual — see Post-Completion): `textView.layoutManager === ` the new instance, the `LineNumberRulerView` gutter still draws and follows scroll/edits, the minimap still updates, and Neon's `TextViewHighlighter` still attaches and highlights (its `LayoutManagerSystemInterface` resolves `textView.layoutManager` at write time, so it must land on the subclass — confirm by breakpoint/log in the `setTemporaryAttributes` override, or simply by observing that syntax colors and bracket colors coexist)
- [x] **fallback only if the swap proves not transparent** (not needed — the `replaceLayoutManager` path installs and both builds are green; the manual stack was not used): build the TextKit 1 stack manually — `NSTextStorage` → `BracketOverlayLayoutManager` → `NSTextContainer` → `EditorTextView(frame:textContainer:)` — porting the entire current configuration verbatim. If it comes to this, the classic manual-stack trap must be handled explicitly: **`NSTextView` does not retain its `NSTextStorage`** (the ownership runs storage → layoutManager → textContainer → textView, all the *other* way), so a locally-created storage is deallocated the moment `makeNSView` returns and the editor dies with a crash or an empty buffer — the `Coordinator` must hold a strong reference to the `NSTextStorage` for the text view's lifetime (and release it in `dismantleNSView`/`teardown` alongside the existing observers)
- [x] doc comments: why temporary attributes (they don't touch text storage → they don't pollute undo), why interception (Neon clears the range before every write, and the JSON grammar doesn't capture brackets at all, so an `attributeProvider` won't do), and why `replaceLayoutManager` rather than a hand-built stack
- [x] `swift test` — green (Core regression)
- [x] `xcodebuild -destination 'platform=macOS'` and `-destination 'generic/platform=iOS'` — both builds green

### Task 4: View — BracketHighlightController and Coordinator wiring

**Files:**
- Create: `Sources/Pisaka/BracketHighlightController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] create `BracketHighlightController` (`@MainActor`, macOS): holds the cached `[BracketToken]` for the current buffer, a cache key (`fileID` + text hash) and a generation token, with a debounced rescan (~100 ms, `immediate` for a tab switch / buffer swap — the `MinimapTokenizer` precedent); the rescan is the single `BracketDepthScanner.scan` call, whose bulk-read pattern (Task 2) is what keeps it main-actor-safe
- [x] `refreshVisible()`: compute the visible character range (`glyphRange(forBoundingRect:in:)` → `characterRange(forGlyphRange:)`), binary-search the token slice, resolve colors (`SyntaxTheme.bracketColor(forDepth:)`, unmatched → red) and hand them to `setRainbowRuns` — attributes are applied to the visible range only, while the O(n) scan stays cheap even on a large file
- [x] `updateSelection(_:)`: `BracketMatchEngine.pair(text:selectedRange:)` → `setPairRanges` (clearing the previous one), `nil` → clear
- [x] `Coordinator`: observe `NSTextStorage.didProcessEditingNotification` filtered on `.editedCharacters` (the `LineNumberRulerView` precedent) → `clearRainbow(in: editedRange)` + debounced rescan; implement `textViewDidChangeSelection(_:)` → `updateSelection`; call `refreshVisible()` from the existing `clipViewBoundsChanged` (no rescan; also from `syncableFrameChanged`, since a resize changes the visible range too and it is what paints the first time — `makeNSView` seeds the scan before any layout exists); from `updateNSView`, an `immediate` refresh on a `fileID` change / buffer swap; from `teardown()`, remove the observer and cancel the pending task
- [x] `swift test` — green (Core regression)
- [x] both builds (macOS, `generic/platform=iOS`) green

### Task 5: Verify acceptance criteria

- [x] `swift test` — the whole package green (945 tests, 0 failures)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — BUILD SUCCEEDED
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — BUILD SUCCEEDED
- [x] verify Core imports nothing but Foundation (`grep -n "^import" Sources/PisakaCore/Bracket*.swift`), that `BracketDepthScanner` contains no `character(at:)` call in its scan loop (`grep -n "character(at:" Sources/PisakaCore/BracketDepthScanner.swift` → no hit), that both engines' doc comments carry the divergence paragraph naming the other engine (`grep -n "BracketDepthScanner" Sources/PisakaCore/BracketMatchEngine.swift` and the reverse), and that the new types are covered by both new suites
  - Verified: both files import Foundation only. The single `character(at:` grep hit in `BracketDepthScanner.swift` is line 41, inside the doc comment explaining *why* it is avoided — no live call; the loop reads through `getCharacters(_:range:)` into a `chunkSize`-unit (4096) `[unichar]` buffer under `withUnsafeMutableBufferPointer`. Each engine's doc comment carries a **Divergence from …** paragraph naming the other. Both suites exist with the mirror pins `testCrossedBracketsPairPerKindUnlikeDepthScanner` (21 tests) and `testCrossedBracketsAllUnmatchedUnlikeMatchEngine` (18 tests).

### Task 6: Update documentation

- [x] `CLAUDE.md`: add `BracketMatchEngine.swift` and `BracketDepthScanner.swift` to the Core list (semantics, including the raw-scan limitation, the unmatched rule, and the scanner's chunked `getCharacters` read with the reason — a main-actor scan must not pay a per-character objc call)
- [x] `CLAUDE.md`: record the **engine divergence** in both entries — per-kind counting (matcher, the `dedentOnClosing` rule) vs. one shared stack (scanner, JetBrains semantics); they agree on well-formed code and disagree on crossed input (`{[(]}` → the matcher pairs `[`↔`]`, the scanner marks both unmatched, so a red bracket can still show a highlighted pair); accepted for broken code, pinned by a test in each suite
- [x] `CLAUDE.md`: describe the `CodeEditorView` wiring — `BracketOverlayLayoutManager` installed with `replaceLayoutManager` (and why: the storage↔container↔view wiring survives, so `makeNSView` is otherwise untouched) intercepting `setTemporaryAttributes` (why temporary attributes and why interception), visible-range-only application, debounce + generation, clearing the pair via `.backgroundColor`; note that `DiffView`/`MergeView` are untouched. If the fallback manual stack was used instead, document the `NSTextStorage` retention requirement in its place
- [x] `CLAUDE.md`: record the follow-ups — tree-sitter-aware matching (skipping strings/comments, which would also close the crossed-input divergence), an iOS variant over the same engines, settings (on/off, number of colors)
- [x] `README.md`: describe both features in the editor section (caret pair highlighting, rainbow by depth with a cycling 5-color palette, red unmatched bracket, follows the system theme, macOS-only for now, the "a bracket inside a string literal is highlighted too" limitation)

## Post-Completion (manual verification, macOS)

- Caret next to `{` — both brackets of the pair get a background; moving the caret away clears it.
- Deeply nested JSON/TS — colors by depth, readable in both light and dark.
- An unmatched bracket is red.
- Crossed input (`{[(]}`) — the caret at `[` shows a highlighted pair even though both brackets are red; that is the documented divergence, not a bug.
- Typing in a large (megabyte-scale) file doesn't lag — the debounced rescan's bulk read stays imperceptible on the main actor; scrolling colors newly revealed brackets.
- Undo contains no "highlighting edits".
- Switching the theme (Preferences → Theme) recolors the brackets.
