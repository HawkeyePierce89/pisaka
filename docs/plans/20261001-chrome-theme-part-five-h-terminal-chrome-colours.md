# Chrome theme, part five (h): the terminal's four chrome colours become roles

## Overview

`TerminalTheme.swift` is exempt from the chrome gating suite because "an ANSI-16 palette is a protocol's vocabulary". That reason is true of the two sixteen-entry arrays and of nothing else in the file. The other four colours in each palette are chrome, and they become roles read from `ChromePalette`:

| Terminal colour | Role | Dark | Light |
|---|---|---|---|
| ground | `bgCanvas` | `0x1E1F22` | `0xF5F5F7` |
| default text | `textPrimary` | `0xDFE1E5` | `0x1D1D1F` |
| caret | `accent` | `0x4F8DFF` | `0x2F6FE0` |
| selection | `accentTintStrong` | accent hues at alpha `0x33` | accent hues at alpha `0x33` |

What changes:

- The ANSI-16 arrays stay literal and keep the exemption.
- Three light ANSI entries are darkened so they stay readable on the new light ground.
- The system-accent observer is removed, because no terminal colour follows the system accent any more.
- A new gating rule, forty-four, pins the new boundary in `swift test`.
- A new app-bundle suite, `TerminalThemeTests`, pins the resolved colours and the light set's contrast floor.
- The documents are updated to match.

Pixels change on purpose: the ground, the default text, the caret and the selection all move.

## Context

- Files involved:
  - `Sources/Pisaka/TerminalTheme.swift`
  - `Sources/Pisaka/TerminalSessionsModel.swift`
  - `Sources/Pisaka/ChromePalette.swift` (read only; the concrete accessor `nsColor(_:in:)` already exists)
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - `Tests/PisakaAppTests/TerminalThemeTests.swift` (new)
  - `docs/architecture/core-theme.md`
  - `docs/architecture/app-terminal.md`
  - `CLAUDE.md`
- Related patterns:
  - `ChromePaletteTests` and `SyntaxThemeTests`: macOS-gated app-bundle suites that use `@testable import Pisaka`.
  - The gating suite's own helpers: `LSPSourceGatingTests.strippingCommentsAndStringLiterals`, `containsToken`, `matchedBody(after:in:)` / `matchedBodyRange(after:in:)`, and `forbiddenSemanticColors`.
  - Rules twenty-nine and forty-three record a live mutation check in their entries. Rule forty-four does the same.
  - The part-entry shape of `core-theme.md` (Part five (f), (g)) and the six-step sweep guide at the end of that document.
- Dependencies: none new. SwiftTerm stays at its pin.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Each task ships the test that would have caught its absence.
- Complete each task fully before moving to the next.
- No brand or product names anywhere: code, comments, documents, commit messages, branch name.
- Every value needed is stated in this plan as a literal. Nothing is looked up in a design file.
- Local Xcode builds use a derived-data path outside the repository (`~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`).
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Read the terminal's four chrome colours from the palette

**Files:**
- Modify: `Sources/Pisaka/TerminalTheme.swift`
- Modify: `Sources/Pisaka/TerminalSessionsModel.swift`
- Create: `Tests/PisakaAppTests/TerminalThemeTests.swift`

**Intent.** `TerminalTheme` stops spelling the four chrome colours. It names them as the four roles in the table above and resolves them through `ChromePalette.nsColor(_:in:)`.

**Resolution.**
- The appearance used for resolution is the `ChromeAppearance` matched from the hosting `NSAppearance`. The file already performs the `.aqua`/`.darkAqua` best match: `.darkAqua` maps to `.dark`, anything else to `.light`.
- Colours are resolved at apply time, as they are today. SwiftTerm stores concrete colours and never re-resolves them, so the dynamic bridge `nsColor(_:)` cannot be used. The existing re-apply on every appearance change keeps the stored colours current.
- The text drawn under a block caret stays the resolved ground.
- The `performAsCurrentDrawingAppearance` resolver existed only to resolve dynamic system colours. With nothing dynamic left it is dead; remove it if nothing else uses it.
- The `Palette` type may shrink to whatever carries the ANSI set and the appearance choice. That is an implementation decision. What is fixed:
  - the role tokens `.bgCanvas`, `.textPrimary`, `.accent` and `.accentTintStrong` appear in the file's code;
  - outside the two ANSI arrays, there is no `NSColor(` construction and no `0x` literal. Rule forty-four (Task 2) checks both.

**ThemeKey.**
- `ThemeKey` and `key(for:)` keep fingerprinting the 16-bit components of the four resolved colours, in the order ground, text, caret, selection. The ground still encodes the ANSI set.
- Its doc comment no longer cites the accent as the reason the key is not the appearance name. The reason that remains is that comparing components keeps the guard deterministic.
- The skip-if-unchanged guard in `TerminalSession.applyTheme(for:)` does not change, and neither does the protection it gives OSC 4/10/11/12 state on a tab switch.

**ANSI arrays.**
- The dark array stays SwiftTerm's sixteen defaults, verbatim. Its stated reason changes from "so the dark theme looks exactly as before" to "it is the terminal's own vocabulary and the one thing this file still spells for itself".
- Three light entries are darkened, each keeping its hue:

  | Entry | Contrast on `0xF5F5F7` today | Old | New |
  |---|---|---|---|
  | ANSI 8 | 4.2:1 | `0x757575` | `0x707070` |
  | ANSI 11 | 4.1:1 | `0x9A7000` | `0x926A00` |
  | ANSI 14 | 4.3:1 | `0x00808F` | `0x007C8B` |

- The light array's comment states the floor as at least 4.5:1 and names the ground it was measured against, `0xF5F5F7`.
- The file's header comment is rewritten to match: the ground is no longer white or black, the dark array no longer looks "exactly as before", and no colour follows the accent.
- `darkANSIColors` and `lightANSIColors` lose `private` (internal is enough) so the app bundle can read them. Both keep their names and their `[SwiftTerm.Color] = [ … ]` declaration form, which rule forty-four reads.

**Accent observer.**
- In `TerminalSessionsModel`, the `systemColorsDidChangeNotification` subscription goes, together with everything that exists only for it: the observer property, the `init`, the `deinit` removal and their doc comments.
- The doc comment of `applyTheme(for:)` no longer mentions the accent-colour observer.
- Every other behaviour of the sessions model stays the same.

**Tests: `TerminalThemeTests`.** A new suite under `#if os(macOS)` with `@testable import Pisaka` and three assertions:
1. For both `NSAppearance(named: .aqua)` and `.darkAqua`, `TerminalTheme.key(for:).colors` equals the 16-bit sRGB components of `ChromePalette.nsColor(_:in:)` for `bgCanvas`, `textPrimary`, `accent` and `accentTintStrong`, in that order, alpha included. The test converts components with its own arithmetic (×65535, rounded) instead of calling the theme's private converter, so the comparison is not a tautology.
2. Every entry of the light ANSI array clears 4.4:1 against the light `bgCanvas` by the relative-luminance contrast formula. Each failure message names the entry's index and its measured ratio.
3. Both ANSI arrays have exactly sixteen entries.

- [x] Replace the four literal and system colours with the four roles, resolved through `ChromePalette.nsColor(_:in:)` at apply time; keep the caret text as the resolved ground
- [x] Remove the dynamic-colour resolver if it is now dead; rewrite the `ThemeKey` doc comment, the file's header comment and the array comments as described
- [x] Darken light ANSI 8, 11 and 14 to the stated values and restate the floor against `0xF5F5F7`; make both ANSI arrays internal
- [x] Remove the `systemColorsDidChangeNotification` observer and its comments from `TerminalSessionsModel`
- [x] Write `TerminalThemeTests` with the three assertions above
- [x] Run `xcodegen generate`, the app-layer bundle (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`) and `swift test`; all must pass before Task 2

### Task 2: Add rule forty-four to pin the narrowed exemption

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (only the canonical list's opening count, rule three's entry and the new rule forty-four entry)
- Modify: `CLAUDE.md` (the rule-count word only)

**Intent.** `TerminalTheme.swift` stays in `colorExemptions`. The exemption now shelters the two ANSI arrays and nothing else, and a new rule reads the file to prove it.

**Rule three's doc comment.** The `TerminalTheme.swift` bullet says the exemption covers the two sixteen-entry arrays and nothing else. It also says the file's four chrome colours are roles, pinned by rule forty-four.

**New helper: `matchedBracketBodyRange(after:in:)`.**
- The arrays cannot be found with the existing `matchedBodyRange(after:in:)`. That helper matches `{` and `}`, but `darkANSIColors` and `lightANSIColors` are bracket literals, so the first `{` after either declaration belongs to a later function body. The rule would carve out the wrong region.
- The new helper sits beside `matchedBodyRange(after:in:)` and has the same contract:
  - it finds the declaration;
  - it searches for the first `=` after the declaration and the first `[` after that `=`. The search must start after the `=`, because the type annotation `[SwiftTerm.Color]` also contains a `[`;
  - it matches that `[` by depth to its closing `]`;
  - it returns the range between the two brackets, or `nil` if the declaration, the `=`, the `[` or the matching `]` is not found.
- Its doc comment says why it exists beside the brace-matching helper.

**Rule forty-four.**
- Its marker sits after rule forty-three's section and before the self-check. The marker uses the same wording as the rule's header bullet, for example "the terminal's exemption shelters its two ANSI arrays and nothing else".
- It reads `TerminalTheme.swift` through `strippingCommentsAndStringLiterals`.
- It finds the bracket-matched bodies of `darkANSIColors` and `lightANSIColors` with `matchedBracketBodyRange(after:in:)`. If either is `nil`, the rule fails loudly with an `XCTFail` naming the file and the missing declaration, instead of passing vacuously.
- With both bodies removed from the text, the remainder must contain:
  - no `0x` hex literal of any width (stricter than rule two's six-digit pattern, on purpose);
  - no `NSColor(` construction at all. This is broader than "from components" and is the simplest form that holds after the change;
  - no token of `forbiddenSemanticColors`.
- The remainder must also spell each of `.bgCanvas`, `.textPrimary`, `.accent` and `.accentTintStrong` as a token.
- Inside each bracket-matched range there are exactly sixteen entries, counted as top-level `rgb8(` calls within that range.
- The doc comment records that the presence check is what catches a restored `.selectedTextBackgroundColor` selection. That token is also the name of SwiftTerm's view property, so it is deliberately not on rule one's list; restoring it removes `.accentTintStrong` from the file.

**Live mutation check.** Done the way rules twenty-nine and forty-three were:
1. Put `.selectedContentBackgroundColor` back as the caret.
2. Run the suite and see rule forty-four fail, with a message naming `TerminalTheme.swift`.
3. Restore the file and see the rule pass.
4. Record the outcome in the rule's doc comment, in the same shape as rule forty-three's entry.

**Bookkeeping.**
- The `spelled` map gains `44: "forty-four"`.
- The header inventory gains rule forty-four's bolded bullet in marker order, titled with exactly the marker's wording (`testTheSuitesHeaderInventoriesEveryRule`).
- `testBothSummariesSpellTheSuitesOwnRuleCount` fails until both summaries say forty-four, so both move in this task:
  - `core-theme.md`'s canonical list opens "The forty-four rules, each invisible to the compiler:" and gains rule forty-four's entry, including the mutation check. Rule three's entry there gets the narrowed exemption text.
  - `CLAUDE.md` says "and its forty-four rules".

- [x] Narrow rule three's `TerminalTheme.swift` bullet in the doc comment of `colorExemptions`
- [x] Add `matchedBracketBodyRange(after:in:)` beside `matchedBodyRange(after:in:)`, with the contract above
- [x] Add rule forty-four (marker, doc comment, test) with the checks outside and inside the arrays described above, failing loudly when either range is not found
- [x] Run the live mutation check, record its outcome in the rule's doc comment, and confirm the tree is restored
- [x] Add `44: "forty-four"` to `spelled` and the header-inventory bullet in marker order
- [x] Update `core-theme.md`'s canonical-list opening, rule three's entry and the new rule forty-four entry; update `CLAUDE.md`'s count word
- [x] Run `swift test`; it must pass before Task 3

### Task 3: Update the documents to say what is now true

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-terminal.md`
- Modify: `CLAUDE.md`

**`core-theme.md`.**
- **New entry "Part five (h) — the terminal's four chrome colours"**, after part five (g), in the existing part-entry shape. It records:
  - the decision: the boundary is drawn where the exemption's own reason puts it;
  - the before and after values: the dark ground goes from black to `0x1E1F22` and the text from `#8A8A8A` to `0xDFE1E5` (contrast 6.1:1 → 12.6:1); the light ground goes from white to `0xF5F5F7` and the text from `#1E1E1E` to `0x1D1D1F`. The caret and the selection move from the system accent to `accent` and `accentTintStrong`;
  - the three darkened light ANSI entries, with old and new values, and the new 4.5:1 floor on `0xF5F5F7`;
  - the stated exception and its reasoning: a host that stores concrete colours is handed concrete colours through `nsColor(_:in:)`, and the existing re-apply on appearance change keeps them current. This is the exception to "AppKit asks for a dynamic colour and caches nothing";
  - the removal of the accent observer;
  - the dark ANSI set's measured contrast on `0x1E1F22` (ANSI 4 at 1.3:1, ANSI 1 at 1.8:1, ANSI 12 at 1.9:1), each as poor as it was on the black it was tuned for. Tuning the set is named as an open item;
  - the two new tests, and the bracket-matching helper rule forty-four reads through.
- **Part four (a)** (near line 850, "the terminal palette are untouched"): qualify the sentence to what is still true. The ANSI-16 is the terminal zone; the four chrome colours were swept in part five (h).
- **Part five (d)** (near line 1908, "The terminal's colours stay `TerminalTheme`'s"): qualify it the same way.
- **Part five (f)'s closing paragraph** (near line 2112) lists the terminal's palette as open. Add "(its four chrome colours since swept, part five (h))" so the history does not read as current.
- **What is still waiting**:
  - The terminal's own palette leaves the deferred list. The caret readout, the lane hues and the unified diff's two departures stay.
  - Tuning the dark ANSI-16 set is added as an open item.
  - Part five (h) is added to the sentence listing what has been swept.
  - The terminal pane counts as a swept surface, so "after fifty-six surfaces" becomes "after fifty-seven surfaces". The same sentence currently says `ChromeColorRole.swift`'s doc comment states "the same two and the same count". That is wrong: the doc comment names the two unspent roles (`currentLine`, `bracketMatch`) but states no surface count. Correct it to claim only the same two roles. No role is newly spent, so the two-unspent-roles statement stays true.
- **Two ride-along corrections**:
  - Part five (d)'s "would be the refusal's own case" (near line 1803) becomes "a role of its own".
  - Rule twenty-nine's entry says the helper-call form matches "a leading-dot raw value". The entry also states that the suite accepts a role qualified by `ChromeColorRole`.

**`app-terminal.md`.** Update the `TerminalTheme`, `TerminalSession`, `TerminalSessionsModel` and `TerminalPanelView` entries wherever they describe any of the following:
- the two system colours, or the caret and selection taken from the accent;
- the accent observer;
- the white and black grounds and the `#1E1E1E`/`#8A8A8A` text;
- the "≥ 4.4:1 against white" floor;
- the palette being "untouched".

Each entry should state the roles, the concrete-accessor exception and the narrowed exemption.

**`CLAUDE.md`.** In the chrome-theme invariant bullet, which currently calls `hairlineWidth` on an AppKit code-zoom surface "the one stated exception", word the theme's two exceptions as a pair: "two stated exceptions". One is `hairlineWidth` on an AppKit code-zoom surface, drawn unscaled. The other is the terminal, a host that stores concrete colours and is handed concrete colours resolved by appearance. Neither is called "one" or "second". The file must stay under its measured 60,000-character ceiling (about 49,700 today).

- [ ] Add the Part five (h) entry, and qualify the part four (a), part five (d) and part five (f) sentences
- [ ] Update *What is still waiting*: the terminal item out, the dark ANSI tuning in, part five (h) added to the swept list, "fifty-six" → "fifty-seven", and the role-file claim corrected to the two roles only
- [ ] Apply the two ride-along corrections (part five (d)'s wording, rule twenty-nine's entry)
- [ ] Update the four `app-terminal.md` entries
- [ ] Reword `CLAUDE.md`'s chrome-theme bullet to name two stated exceptions
- [ ] Run `swift test` (rule forty-three's document half, the rule-count checks and `LintConfigurationTests`); it must pass before Task 4

### Task 4: Verify acceptance criteria

- [ ] Run `swift test`: green, with the chrome suite at forty-four rules
- [ ] Run `xcodegen generate`, then the app-layer bundle (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`): green, including the three `TerminalThemeTests` assertions
- [ ] Run `swiftlint --strict` from the repository root: clean
- [ ] Build macOS Release (`-configuration Release`) and iOS Debug (`-destination 'generic/platform=iOS'`): both green
- [ ] `git grep -n 'systemColorsDidChangeNotification' Sources/` finds nothing
- [ ] `git grep -n 'selectedContentBackgroundColor\|NSColor.selectedTextBackgroundColor\|srgbRed' Sources/Pisaka/TerminalTheme.swift` finds nothing
- [ ] Coverage: the new behaviour is pinned by rule forty-four and `TerminalThemeTests`. SwiftUI and AppKit glue stays untested by convention, so there is no percentage gate

### Task 5: Update documentation

- [ ] README.md and `docs/FEATURES.md`: check whether they describe the terminal's colours, and update them only if they do
- [ ] CLAUDE.md: already updated in Tasks 2 and 3. Confirm the count word and the two-exceptions wording are present and the file is under its ceiling

## Post-Completion

Manual checks at the acceptance review, in the running app (captured by window id):
- The terminal pane's ground reads `0x1E1F22` under the dark appearance and `0xF5F5F7` under the light one.
- The caret is the chrome accent.
- Switching the Theme preference recolours a live session without restarting its shell.
