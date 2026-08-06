# New File / New Folder / Rename — multiline input with live validation and OK gating

## Overview

Rework `FilePanels.promptName` from a narrow 240 pt single-line `NSTextField` into a wide
(~400 pt) wrapping multiline field that always shows the whole input, with a red reason line
under it and the OK button disabled while the input is invalid or blank. All decision logic and
all reason texts live in `PisakaCore` as a reasoned validation API next to the existing
`parseRelativeEntryPath` / `isValidFileName`, which are refactored to delegate to it so one rule
can never split into two implementations.

Per the answered questions, the two "New Branch" dialogs keep minimal scope: they share the new
field (wide, multiline, Enter = OK, blank blocks OK) but get no live reason text. The `validator`
parameter is required (no default) — both branch call sites pass an explicit `{ _ in nil }` with a
one-line comment, so a future call site cannot silently forget validation.

## Context

- Files involved:
  - `Sources/PisakaCore/FileName.swift` — `isValidFileName`, `parseRelativeEntryPath`; gains
    `EntryPathIssue`, `validateRelativeEntryPath`, `validateSingleEntryName`
  - `Tests/PisakaCoreTests/FileNameTests.swift` — existing suite, extended
  - `Sources/Pisaka/FilePanels.swift` — `promptName` (macOS-only, `#if os(macOS)`), line 83
  - `Sources/Pisaka/PisakaApp.swift` — `newFile(in:)` (~1037), `newFolder(in:)` (~1063),
    `renameItem(at:)` (~1102), `createBranchFromRemote` (~700), `newBranch` (~711), plus
    `reportInvalidName` / `reportReservedName` (unchanged)
  - `Sources/PisakaCore/FileService.swift` — `isReservedCreateName` (case-insensitive, create
    paths) / `isExcludedEntryName` (exact, rename)
  - `CLAUDE.md`, `README.md`
- Related patterns: logic + user-facing text in Core and unit-tested (`GitError.errorDescription`,
  `FileServiceError` `LocalizedError`), view layer thin and untested; `FilePanels` is the only
  AppKit prompt wrapper.
- Dependencies: none new (Foundation in Core, AppKit in the view).

## Design decisions

- `EntryPathIssue` cases (payload only where it helps the message):
  - `.emptyInput` — whole input empty/whitespace-only
  - `.emptyComponent` — a component empty after trimming (covers `a//b`, leading `/`, `a//`,
    `a/ /b`)
  - `.navigationComponent(String)` — `.` or `..`
  - `.separatorInName` — a `/` in a context that takes a single name (rename); its message says
    renaming takes a single name, not a path
  - `.lineBreak` — a line break inside a component (only reachable by paste, since Enter never
    inserts one)
  - `.nulCharacter` — a NUL scalar in a component
  - `.reservedComponent(String)` — `.git` / `.DS_Store`; the message names the offending component
- Single source of truth: one private component-level rule (`componentIssue`) + one private
  splitter shared by `parseRelativeEntryPath`, `validateRelativeEntryPath`,
  `validateSingleEntryName`, and `isValidFileName` (which becomes a boolean facade over the same
  rule). Parity is then structural, and a test asserts it on a matrix anyway.
- Deliberate behavior change: an interior line break in a component becomes invalid everywhere (it
  was silently accepted before, so a pasted `a\nb` created a file with a newline in its name). This
  is required by the acceptance criteria and, because the rule is shared, also tightens
  `parseRelativeEntryPath` and `isValidFileName`.
- Reserved-name semantics stay per-context, matching the existing post-OK guards exactly so the
  dialog can never block a name the guard would accept (or vice versa): create paths use the
  case-insensitive `isReservedCreateName`, rename uses the exact-match `isExcludedEntryName`.
- Blank input: the view disables OK but hides the red line (incomplete input, not an error).
  `.emptyInput` still exists in Core with a message and is tested — the view simply does not
  display it for blank input.
- `validator` is a required parameter of `promptName`; `defaultValue` keeps its existing `= ""`
  default.

## Development Approach

- **Testing approach**: TDD for the Core tasks (tests first, confirmed failing for the expected
  reason), then implementation.
- The AppKit view layer stays untested per project convention; its decision logic is covered by the
  Core tests.
- Complete each task fully — including a green `swift test` — before starting the next.

## Implementation Steps

### Task 1: Core — `EntryPathIssue` + reasoned path validation, parser delegates

**Files:**
- Modify: `Sources/PisakaCore/FileName.swift`
- Modify: `Tests/PisakaCoreTests/FileNameTests.swift`

- [x] write failing tests first: every `EntryPathIssue` case reachable from
      `validateRelativeEntryPath` where applicable and carrying a non-empty `message`;
      `.reservedComponent` message contains the offending name; `.navigationComponent` message
      names `.`/`..`
- [x] write failing tests: `validateRelativeEntryPath` returns the expected case for empty input,
      `/a/b`, `a//b`, `a/ /b`, `a/../b`, `a/./b`, `x/.git/y`, `x/.GIT/y`, `a\0b`, and a pasted
      `a\nb` (line break inside a component)
- [x] write failing parity test over a matrix of valid + every class of invalid input (reusing the
      existing `parseRelativeEntryPath` test inputs): `parseRelativeEntryPath(x) != nil` ⟺
      `validateRelativeEntryPath(x) == nil`
- [x] confirm the new tests fail for the expected reason (missing API / newline currently accepted)
- [x] add `public enum EntryPathIssue: Equatable` with `public var message: String` (English, in
      the style of the existing alert texts)
- [x] add the private shared component rule + splitter; add
      `public func validateRelativeEntryPath(_:) -> EntryPathIssue?`; rewrite
      `parseRelativeEntryPath` to delegate to it (no second copy of the rules)
- [x] update the doc comments of `parseRelativeEntryPath` (delegation, the new line-break rule)
- [x] run `swift test` — must pass before Task 2

### Task 2: Core — `validateSingleEntryName` for Rename, `isValidFileName` delegates

**Files:**
- Modify: `Sources/PisakaCore/FileName.swift`
- Modify: `Tests/PisakaCoreTests/FileNameTests.swift`

- [x] write failing tests: `validateSingleEntryName` returns `nil` for `file.txt`, `.gitignore`,
      `My Document.md`; `.separatorInName` (message mentions a single name, not a path) for `a/b`,
      `/foo`, `foo/`; `.navigationComponent` for `.`/`..`; `.reservedComponent` for `.git` and
      `.DS_Store` naming them; `.emptyInput` for `""`/`" "`; `.nulCharacter` for `a\0b`;
      `.lineBreak` for `a\nb`
- [x] write failing test: `validateSingleEntryName` uses exact-match reserved semantics (`.Git` is
      allowed, matching the rename call-site's `isExcludedEntryName` guard), so the dialog can never
      disagree with the post-OK guard
- [x] write failing tests: for every input in the existing `isValidFileName` suite plus the newline
      case, `isValidFileName(x)` agrees with `validateSingleEntryName(x) == nil` except for the
      reserved-name cases (which `isValidFileName` deliberately does not judge)
- [x] confirm the new tests fail for the expected reason
- [x] add `public func validateSingleEntryName(_:) -> EntryPathIssue?`; rewrite `isValidFileName`
      as a boolean facade over the shared component rule
- [x] update both doc comments (shared rule, rename grammar, the reserved-semantics split and why)
- [x] run `swift test` — must pass before Task 3

### Task 3: View — rework `FilePanels.promptName`

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`

- [x] change the signature to `promptName(title:defaultValue:validator:)` where
      `validator: (String) -> String?` returns `nil` for valid or the reason text; the parameter is
      required (no default) so every call site must state its validation intent — `defaultValue`
      keeps its `= ""`
- [x] build the accessory view with Auto Layout: a container holding a ~400 pt-wide wrapping
      `NSTextField` (`usesSingleLineMode = false`, wrapping non-scrollable cell,
      `maximumNumberOfLines = 0`, `preferredMaxLayoutWidth` set) that grows in height with its
      content, above a hidden wrapping red label (`systemRed`, small system font)
- [x] add a private `NSTextFieldDelegate` (kept alive across `runModal()`, since `delegate` is
      weak): `controlTextDidChange` runs the validator and updates the red label +
      `alert.buttons[0].isEnabled`; `control(_:textView:doCommandBy:)` intercepts `insertNewline:`
      (and `insertNewlineIgnoringFieldEditor:`) to click OK when enabled and swallow the key
      otherwise — a newline is never inserted into the field
- [x] apply the same validation once before `runModal()` so the initial state is right (Rename
      pre-filled and valid → OK enabled; create empty → OK disabled)
- [x] blank/whitespace-only input: OK disabled, red label hidden (single explicit branch); any
      other invalid input shows its reason
- [x] no tests here — the AppKit view layer is intentionally untested per project conventions; the
      decision logic it displays is covered by Tasks 1–2
- [x] run `swift test` (unchanged suite must stay green) and
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`

### Task 4: Call sites — pass the validators in `PisakaApp`

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `newFile(in:)` and `newFolder(in:)` pass `validator: { validateRelativeEntryPath($0)?.message }`
- [x] `renameItem(at:)` passes `validator: { validateSingleEntryName($0)?.message }`
- [x] `createBranchFromRemote` and `newBranch` pass an explicit `validator: { _ in nil }`, each with
      a one-line comment: no live reason — the post-OK `GitRefName` guard stays the only reporter
      (deliberate minimal scope, not an oversight)
- [x] leave the post-OK guards (`parseRelativeEntryPath`, `isValidFileName` +
      `isExcludedEntryName`, `GitRefName.isValid`) and `reportInvalidName` / `reportReservedName`
      exactly as they are — defense-in-depth for programmatic paths; note this in the doc comments
- [x] run `swift test` and the macOS build — must pass before Task 5

### Task 5: Verify acceptance criteria (builds + suite)

- [x] run `swift test` — full suite green (842 tests, 0 failures)
- [x] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      — BUILD SUCCEEDED
- [x] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
      — BUILD SUCCEEDED; confirms no AppKit leaked into shared code (iOS does not use these dialogs)
- [x] grep-verify the reason texts and validation rules exist only in `PisakaCore` (the view holds
      no branching beyond the blank-input case), and that no `promptName` call site relies on a
      defaulted validator — `EntryPathIssue`/`message` appear only in
      `Sources/PisakaCore/FileName.swift` (the sole reference outside Core is one doc comment in
      `PisakaApp`), `PromptNameDelegate.revalidate` branches only on `isBlank`, and `validator` has
      no default with all five call sites passing an explicit closure

### Task 6: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] CLAUDE.md — `FileName.swift`: `EntryPathIssue` (cases + messages in Core),
      `validateRelativeEntryPath` / `validateSingleEntryName`, the shared rule that keeps parser and
      validator in parity, the new line-break rule, and the per-context reserved semantics
      (case-insensitive for create, exact for rename)
- [x] CLAUDE.md — `FilePanels.swift`: the new `promptName(title:defaultValue:validator:)` mechanics
      (wide wrapping multiline field, live red reason line, OK gating, Enter = OK never a newline,
      blank input disables OK without a reason, required validator)
- [x] CLAUDE.md — `FilePanels.swift` / branch dialogs: record explicitly that the two "New Branch"
      dialogs pass `{ _ in nil }` and therefore have no live reason line — a deliberate
      minimal-scope decision, not an omission: they still get the wide multiline field, Enter = OK,
      and blank-blocks-OK, while `GitRefName.isValid` remains the sole (post-OK) reporter. Note the
      known possible follow-up: a reasoned `GitRefName` validator (the `EntryPathIssue` shape
      applied to `GitRefName`'s stricter grammar) would let those dialogs adopt the same live
      validation without any view change, since `validator` is already threaded through
- [x] CLAUDE.md — `PisakaApp` block: which validator each call site passes (including the branch
      sites' explicit no-op and why) and that the post-OK guards remain as defense-in-depth
- [x] README.md — the project-tree section: the create/rename dialog now shows the whole path,
      validates as you type, and keeps OK disabled until the input is valid

## Post-Completion (manual, macOS)

Not agent-automatable; verify by hand after the tasks are done:

- paste `backend/src/dialogs/dialogs.service.ts` — the whole path is visible and wrapped, OK
  enabled, the file is created with the full folder chain
- type `x/.git/y` — red reason naming `.git`, OK disabled, Enter does nothing
- erase to empty — OK disabled, no red text
- Rename: pre-filled name → OK enabled; typing a `/` → red "single name, not a path" reason; Enter
  on a valid name confirms
- a 5+ level path — the field grows and everything stays visible
