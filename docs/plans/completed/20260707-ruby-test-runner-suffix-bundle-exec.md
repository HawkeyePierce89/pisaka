# Ruby test runner — filename suffix + bundle exec

## Overview

Fix the questionable Ruby test-runner detection in `TestCommand`. Today the runner is chosen by the mere presence of `.rspec` OR `Gemfile` in the project root, which misroutes a minitest-style Rails project (`Gemfile` + `foo_test.rb`) to `rspec 'foo_test.rb'` — a command that fails (rspec doesn't run minitest files and may not even be installed), while the `ruby <file>` branch is nearly dead (only reachable when no `Gemfile` exists at all, rare for a Ruby project).

New behavior (per the confirmed decision):

- The runner is chosen by the file-name suffix — the honest per-file signal already used by `isTestFile`: `*_spec.rb` → `rspec`, everything else (incl. `*_test.rb`) → `ruby`.
- When a `Gemfile` is present in the project root, both paths are prefixed with `bundle exec ` (so the gem versions resolve): `bundle exec rspec <file>` / `bundle exec ruby <file>`.
- `.rspec` in the root is NOT an override — the filename decides the runner. `.rspec` is therefore no longer consulted at all, so its now-dead detection probe is removed from the view layer and from the `ProjectTestEvidence` doc comments.
- The `Gemfile` contents are still not read; only its presence (already a visible root entry in `rootEntryNames`) matters.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/TestCommand.swift` — rewrite the `case "rb"` command resolution; delete the `hasRspec(_:)` helper; drop `.rspec` from the doc-comment example at the top of the file (it is no longer a consulted signal).
  - Modify: `Tests/PisakaCoreTests/TestCommandTests.swift` — replace/extend the Ruby command tests to cover the suffix + `bundle exec` matrix.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — remove `".rspec"` from `testDotfileSignals` (now dead: no code consults it), keep the mocha `.mocharc*` probes, and update the surrounding doc comment to reference only mocha.
  - Modify: `CLAUDE.md` — update the Ruby clause in the `TestCommand` description and the `PisakaApp` `testDotfileSignals`/evidence note.
  - Modify: `README.md` — update the one-line Ruby description.
- Related patterns: the existing extension-`switch` in `TestCommand.command(...)`, `ShellQuote.quote` for `<file>`, `isTestFile`'s `hasSuffix("_spec.rb")`/`hasSuffix("_test.rb")` distinction (the same suffix signal reused here).
- Dependencies: none. PisakaCore stays Foundation-only; the view change is macOS-gated (unchanged gating).

## Development Approach

- **Testing approach**: TDD for the Core change (Task 1) — the case matrix is fully enumerated below; adjust the tests first, then the resolver. Regular (build-verified) for the view/doc cleanup.
- Keep all decision logic in Core; the view layer only assembles evidence.
- Complete each task fully (build + tests green) before the next.
- **CRITICAL: the Core task ships new/updated tests; all tests must pass before the next task.**

## Implementation Steps

### Task 1: Core — Ruby runner by filename suffix + bundle exec

**Files:**
- Modify: `Sources/PisakaCore/TestCommand.swift`
- Modify: `Tests/PisakaCoreTests/TestCommandTests.swift`

- [x] update/replace the Ruby command tests in `TestCommandTests.swift` to the new matrix:
  - `a_spec.rb`, no Gemfile → `rspec '/p/a_spec.rb'`
  - `a_spec.rb`, Gemfile present → `bundle exec rspec '/p/a_spec.rb'`
  - `a_test.rb`, no Gemfile → `ruby '/p/a_test.rb'`
  - `a_test.rb`, Gemfile present → `bundle exec ruby '/p/a_test.rb'`
  - `.rspec` present but filename is `a_test.rb` (no Gemfile) → still `ruby '/p/a_test.rb'` (`.rspec` is not an override)
  - a path with a space / single quote stays shell-quoted (regression guard on the new string assembly)
- [x] rewrite `case "rb"` in `TestCommand.command(...)`: pick `rspec` when `fileName.hasSuffix("_spec.rb")` else `ruby`; prefix `bundle exec ` when `evidence.rootEntryNames.contains("Gemfile")`; return `.command(prefix + runner + " " + file)`
- [x] delete the now-unused `private static func hasRspec(_:)` helper
- [x] drop `.rspec` from the doc-comment example listing config files at the top of `TestCommand.swift` (it is no longer a consulted signal)
- [x] run `swift test` — full suite green before Task 2

### Task 2: View — drop the dead `.rspec` detection probe

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] remove `".rspec"` from `testDotfileSignals` (nothing in `TestCommand` consults it anymore; `Gemfile` is a visible root entry so it already appears in `rootEntryNames` with no probe), and update the surrounding doc comment to reference only mocha's `.mocharc*` variants
- [x] build the macOS target (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`)

### Task 3: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] CLAUDE.md: change the `TestCommand` Ruby clause from "Ruby `rspec <file>` (`.rspec`/`Gemfile` signal) else `ruby <file>`" to the suffix-based rule with the `bundle exec` prefix on a `Gemfile`; update the `PisakaApp` `testDotfileSignals`/evidence note to list only `.mocharc*` (no longer `.rspec`)
- [x] README.md (line 195): update the Ruby phrase to reflect the suffix rule — `rspec` for `*_spec.rb`, `ruby` otherwise, prefixed with `bundle exec` when a `Gemfile` is present

### Task 4: Verify acceptance criteria

- [x] run `swift test` (full PisakaCore suite) — all green
- [x] `xcodegen generate` then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — succeeds
- [x] confirm no new dependency reached PisakaCore (still Foundation-only)
