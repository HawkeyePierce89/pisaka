# Close the open question about Section separators in the in-window menus

## Overview

This is a documentation-only change to `docs/architecture/core-theme.md`. Part five (d)'s open questions still say that rule twenty-four's four `menuSectionFiles` (`SearchHistoryMenu.swift`, `ProjectTreeView.swift`, `LocalChangesView.swift`, `DatabaseViewerView.swift`) "may be drawing edge separators nobody asked for". The only evidence behind that was a structural probe of a main menu built in a `Commands` builder.

Five in-window menus have since been measured on screen, in the app built from master `4d9f8487`. They come from three of the four files: three context menus in the project tree, one in Local Changes, and the recent-searches `Menu` popup. The fourth file builds no `Section`-grouped menu. All five draw exactly the separators the convention promised: one at each boundary between groups, none at the top edge, none at the bottom edge and none doubled.

This plan closes the question with that measurement, in the document's own idiom. It also makes rule twenty-four say which of the two measurements it stands on, and it qualifies every place the document states the structural premise as a general fact. No Swift source, test, resource or configuration file changes.

## Context

- Files involved: `docs/architecture/core-theme.md` only.
- Part five (d)'s "Open questions, deliberately left" list: the "Whether `Section` is the right menu separator anywhere" bullet, followed by "The spinner question part five (c) left open is **closed**."
- Part five (d)'s decision 1: "Twenty-two `Divider()` sites…". It points at the measurement "under rule twenty-four" and needs no change.
- Rule 24 in the canonical rule list: "No gated file spells `Divider()`; a menu separates with `Section`." Its middle carries the probe paragraph ("A standalone probe against the real AppKit menu (item arrays read after `NSMenu.update()`, heights from `NSMenu.size`)…").
- Sentences that must stay byte-identical:
  - part five (a)'s "context-menu `Divider()`s become `Section`s rendering the same separators";
  - part five (b)'s "grouped into two `Section`s whose boundary draws the separator";
  - `app-git-views.md`'s Local Changes entry;
  - `app-editor.md`'s search-history entry.
- Two Swift sites still carry the unqualified sentence. Both stay untouched, because this change edits no Swift file:
  - `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`, the comment above `Button("Open Problem…")`: "AppKit neither hides the edge ones nor collapses two adjacent ones".
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, the doc comment on `commandsDividerBodies`: "AppKit neither hides the edge separators nor collapses adjacent ones".
- Suites that read this document raw, through `#filePath`:
  - The canonical-list count check opens on the suite's own rule count. Do not renumber, add or remove a rule. Rule 24 is edited in place.
  - The `CodePaneGround` caller passages, anchored on "is called in exactly" and "**Four callers**:". These are not near the edited text.
  - `testNoDocumentCallsTheSweepClosedWhileASurfaceRemains` scans every doc for sweep-closure phrases. The new wording may say a *question* is closed. It must never pair "closed", "finished" or "complete" with "sweep".
- Dependencies: none.

## Development Approach

- **Testing approach**: Regular. The acceptance surface is `swift test` staying green, because the Core gate reads this document. No new test is written: the ticket forbids test changes, and a Markdown record of a manual measurement has nothing a suite could pin.
- Complete each task fully before moving to the next.
- Voice:
  - Measured facts carry their numbers as literals, with the limit of each measurement beside it.
  - No brand or product names.
  - Do not cite a ticket, session, plan or external file.
- Count consistency: wherever the new text gives a count of measured menus, it says five menus built by three of the four `menuSectionFiles`, or names them. It must never say "the four in-window menus", so that the number always matches the list beside it.
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Close the open question in part five (d)

**Files:**
- Modify: `docs/architecture/core-theme.md`

- [x] Remove the "Whether `Section` is the right menu separator anywhere" bullet from the open-questions list. The remaining four bullets (split-view dividers, focus ring, served documents' palette, terminal colours) stay exactly as they are.
- [x] Beside the existing sentence "The spinner question part five (c) left open is **closed**.", add a closure paragraph in the same idiom. It opens by saying the `Section`-separator question part five (d) left open is **closed**, then states the measurement:
  - Scope: five menus, built by three of the four `menuSectionFiles`. That is three context menus in `ProjectTreeView.swift`, one in `LocalChangesView.swift`, and the `Menu` popup in `SearchHistoryMenu.swift`.
  - Method: each menu was measured in the running app while open. Its window was captured by its own window id, its height was read from the window bounds, and its item list was read through accessibility.
  - The project tree's file context menu has three `Section`s (Run | Rename, Delete | Local History). It draws two separators, both between groups, at 128 pt.
  - The folder context menu has two `Section`s (New File, New Folder | Rename, Delete). It draws one separator, between the groups, at 117 pt.
  - The root context menu has one `Section` (New File, New Folder). It draws no separator, at 58 pt; edge separators would put it near 80 pt.
  - The Local Changes row context menu for a modified file has two `Section`s (Show Diff, Jump to Source, Commit… | Revert). It draws one separator, between the groups, at 117 pt.
  - The recent-searches `Menu` popup has two `Section`s (one recorded pattern | Clear History). It draws one separator, between the groups, at 69 pt.
  - The arithmetic is consistent across all five: about 23.5 pt per item, about 11 pt per drawn separator and about 11 pt of padding.
  - Structure versus drawing, as the history popup shows it:
    - Its accessibility item list holds six items for two buttons: a separator item before the first group, two adjacent ones between the groups, and one after the last.
    - So the separator items exist in the menu's structure, and AppKit hides the leading, trailing and adjacent ones when it draws a popup or a context menu.
  - The fourth file, `DatabaseViewerView.swift`: its cell context menu (Copy, Set to NULL) spells no `Section` of its own, so there was nothing to measure, as rule twenty-four already says.
  - The convention the earlier parts established stands, confirmed rather than assumed: a menu's separator is a `Section` boundary.
- [x] Leave decision 1's pointer "(the measurement is under rule twenty-four)" as it is. It still refers to the structural `Commands` numbers, which stay there.
- [x] Run `swift test`. It must pass before task 2.

### Task 2: Make rule twenty-four state what each measurement saw, and qualify the premise

**Files:**
- Modify: `docs/architecture/core-theme.md`

- [x] In rule 24, keep all of the following exactly as they are:
  - the rule's number and heading;
  - both pinned sets;
  - the viewer's explanation;
  - the `commandsDividerBodies` exception;
  - the four probe shapes with their numbers (126 / 104 / 104 / 93 pt).
- [x] After the probe's numbers, say plainly that this probe was a structural measurement, not a screen capture. It read item arrays after `NSMenu.update()` and sizes from `NSMenu.size`.
- [x] Then add the contrast:
  - Five in-window menus, built by three of the four `menuSectionFiles`, were measured on screen. There, AppKit hides the edge and adjacent separator items (the numbers are in part five (d)'s closure).
  - Whether the menu bar draws what a `Commands` menu's structure holds was not measured then and is not measured now. That is the stated limit.
  - The `LeetCodeCommands` `Divider()` exception stands on the structural numbers as before, neither strengthened nor weakened.
- [x] Qualify the premise wherever the document states it as a general fact:
  - Search the whole document for "neither hides", "collapses adjacent" and "edge separator". Reword each hit as the structural reading of a `Commands` menu.
  - The only hit today is the open-question bullet, which task 1 removed. Re-run the search to confirm nothing unqualified remains.
  - The rule-24 line "there the rule's premise … is false" is already scoped to a `Commands` builder and may stay. Tighten it to "false in that menu's structure" only if the new paragraph reads inconsistently without it.
- [x] In the same rule-24 paragraph, record the two Swift sites that still carry the unqualified sentence, so the next writer finds them:
  - the comment above the Open Problem button in `LeetCodeOpenProblemSheet.swift`;
  - the doc comment on `commandsDividerBodies` in `ChromeThemeSourceGatingTests.swift`.

  Say that both describe the structural reading of a `Commands` menu and were left as written.
- [x] Run `swift test`. It must pass before task 3.

### Task 3: Verify acceptance criteria

- [x] Run `swift test`. All suites must be green, including `ChromeThemeSourceGatingTests`: rule count, canonical list, caller passages and the sweep-closure scan.
- [x] Run `git diff --stat`. The only changed file is `docs/architecture/core-theme.md`.
- [x] Grep the added lines:
  - no "sweep";
  - no brand or product names;
  - no "four in-window menus" or any other menu count that disagrees with the five listed.
- [x] Confirm that the part five (a) and (b) "render the same separators" sentences, `app-git-views.md` and `app-editor.md` are unchanged. `git diff` must show no hunk there.
- [x] Linter: not run, because `swiftlint --strict` does not see Markdown.
- [x] Coverage: not applicable, because no code changes.

### Task 4: Update documentation

- [ ] `README.md`: no change, because nothing user-facing changes.
- [ ] `CLAUDE.md`: no change. It carries no sentence about menu separators, and its size ceiling is not spent on one.
