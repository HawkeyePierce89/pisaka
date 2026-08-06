# Terminal follows the app theme (light/dark)

## Overview

The embedded terminal is currently always dark: SwiftTerm 1.5.0 starts from hardcoded defaults (black background, gray text) and does not react to appearance. We add two terminal palettes in the view layer (macOS-only) and apply them from the *effective* appearance of the hosting view — one mechanism covers both a system theme change and the forced `ThemePreference` from Settings (SwiftUI's `.preferredColorScheme` already changes the `effectiveAppearance` of hosted AppKit views). The theme is applied to *every* live session, including inactive tabs. Core is untouched; a *user-configurable* palette stays out of scope.

> **Revised during code review** (see the tasks below for the details): the ANSI-16 palette is themed too rather than left at SwiftTerm's defaults, the caret uses `.selectedContentBackgroundColor` rather than `.selectedControlColor`, and applying a theme is skipped for an appearance a session already carries.

## Context

- Files:
  - Create: `Sources/Pisaka/TerminalTheme.swift` (next to `SyntaxTheme.swift` — the precedent for light/dark color tables in the view layer)
  - Modify: `Sources/Pisaka/TerminalSession.swift`, `Sources/Pisaka/TerminalSessionsModel.swift`, `Sources/Pisaka/TerminalPanelView.swift`
  - Modify (docs): `CLAUDE.md`, `README.md`
- Existing patterns:
  - `SyntaxTheme` — a built-in (not user-configurable) light/dark color table in the view layer, keeping Core color-free.
  - "resolve at draw time" from `MinimapView`/`SyntaxTheme`; here it is resolve *at apply time* (SwiftTerm stores its own `Color` structs and does not resolve dynamic colors itself).
  - `TerminalSession` — a thin wrapper over `LocalProcessTerminalView`; all pure logic lives in `PisakaCore.TerminalLaunch`.
  - `TerminalHostView` — swaps the on-screen view only on an actual tab change (`terminalView.superview !== container`) and calls `makeFirstResponder` only from `install(_:in:)`, deliberately not on every `updateNSView`. This is documented, load-bearing behavior that the new container must preserve.
  - XcodeGen pulls in all of `Sources/Pisaka` (`sources: - path: Sources/Pisaka`), so a new file needs no `project.yml` change.
- SwiftTerm 1.5.0 API we use (public only; pins untouched):
  - `public func setBackgroundColor(source: Terminal, color: Color)` / `setForegroundColor(source:color:)` — these set `native*Color` **and** call the internal `colorsChanged()` (attribute-cache reset + `updateFullScreen` + redraw). Writing `nativeBackgroundColor`/`nativeForegroundColor` directly does NOT do that on macOS (unlike SwiftTerm's iOS branch), so a live theme change through them would leave stale cached attributes and never repaint.
  - `public var caretColor: NSColor`, `caretTextColor: NSColor?`, `selectedTextBackgroundColor: NSColor`, `public var terminal: Terminal!` / `getTerminal()`.
  - `SwiftTerm.Color(red:green:blue:)` — `UInt16` components, 0…65535.
  - `layer?.backgroundColor` is only set by SwiftTerm in `setupOptions()`, so we update it ourselves after a palette change (public `NSView` API).
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular. The change is entirely presentational and lives in the view layer, where the repository convention has no tests (`Tests/PisakaCoreTests` covers `PisakaCore` only). Core does not change, so the suite stays as is — each task's gate is a green `swift test` plus green builds.
- Complete each task fully before moving to the next.
- Everything new goes under `#if os(macOS)` (there is no terminal on iOS); the iOS build is verified separately to confirm nothing leaked.

## Implementation Steps

### Task 1: Terminal palettes and their application (`TerminalTheme`)

**Files:**
- Create: `Sources/Pisaka/TerminalTheme.swift`

- [x] Create the file under `#if os(macOS)` with `import AppKit` + `import SwiftTerm`; type `enum TerminalTheme` (statics only, like the `SyntaxTheme.shared` table — built-in, not user-configurable).
- [x] An internal `struct Palette { let background: NSColor; let foreground: NSColor; let caret: NSColor; let selection: NSColor }` and two static palettes:
  - `light` — a `textBackgroundColor`-style white background with dark text;
  - `dark` — SwiftTerm's current look (black background, light-gray text `#8A8A8A` matching its default), so the dark theme is visually unchanged;
  - caret and selection — semantic system colors so they follow the user's accent color; they are dynamic and therefore resolved (see below). **Revised in review:** the caret is `.selectedContentBackgroundColor`, not `.selectedControlColor` — the latter is byte-identical to `.selectedTextBackgroundColor` in both appearances (`#B3D7FF`/`#3F638B`), so caret and selection were indistinguishable (a stated acceptance criterion) and the `caretTextColor` glyph sat at 1.5:1 against the pale light-mode tint.
- [x] `static func palette(for appearance: NSAppearance) -> Palette` — chosen via `appearance.bestMatch(from: [.aqua, .darkAqua])`.
- [x] Private dynamic-color resolution: `resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor` via `appearance.performAsCurrentDrawingAppearance { … usingColorSpace(.sRGB) … }` (macOS 13+ target, API available) — with a doc comment on why, without it, SwiftTerm would receive a color resolved under the *current thread's* appearance rather than the view's.
- [x] Private `NSColor → SwiftTerm.Color` converter (sRGB components × 65535); SwiftTerm's internal `getTerminalColor()` is not public, so we do our own.
- [x] `static func apply(to view: TerminalView, appearance: NSAppearance)`:
  - background/foreground via `view.setBackgroundColor(source:color:)` / `setForegroundColor(source:color:)` (they also clear the attribute cache and repaint; doc comment on why not the direct `native*Color` setters);
  - `view.caretColor` = the resolved caret color, `view.caretTextColor` = the palette background (so text under a block cursor stays readable in both themes);
  - `view.selectedTextBackgroundColor` = the resolved selection color;
  - `view.layer?.backgroundColor = background.cgColor` (SwiftTerm sets it only in `setupOptions()`).
- [x] ~~Doc comment recording the decision: the ANSI-16 palette is deliberately left alone in this iteration — the default is readable on both backgrounds; fine-tuning and user-configurable palettes are a follow-up.~~ **Revised in review — that justification was factually wrong.** SwiftTerm's sixteen defaults are tuned for its black background and several are unreadable on a white one (bright white `#E5E5E5` 1.26:1, bright yellow 1.35:1, bright cyan 1.57:1, ANSI 7 `#BFBFBF` 1.84:1), and since `useBrightColors` defaults to `true`, *bold* text on colors 0–6 is remapped onto those brights — so ordinary prompt/`ls`/`npm` output vanished in the light theme. The light palette now installs a darkened set (every entry ≥ 4.4:1 against white, "bright" reading as more *saturated* rather than lighter) through the public `installColors`, and the dark palette reinstalls SwiftTerm's own `defaultInstalledColors` verbatim so dark → light → dark restores exactly what the view started with. Only a *user-configurable* palette remains out of scope.
- [x] Tests: none new — the file is entirely view layer (repository convention), Core untouched.
- [x] `swift test` — must stay green before moving to Task 2.

### Task 2: Applying the theme to sessions (session + sessions model)

**Files:**
- Modify: `Sources/Pisaka/TerminalSession.swift`
- Modify: `Sources/Pisaka/TerminalSessionsModel.swift`

- [x] `TerminalSession.applyTheme(for appearance: NSAppearance)` — a thin forward to `TerminalTheme.apply(to: terminalView, appearance:)`; doc comment noting the recolor happens on the live view, leaving the shell and scrollback untouched. **Added in review:** it remembers the colors it last applied (a `TerminalTheme.ThemeKey` — the four resolved colors as 16-bit sRGB components) and skips a repeat for the same ones. Applying is a full *reset* of the very state the terminal's escape sequences write to (`installPalette` assigns `ansiColors = defaultAnsiColors`, discarding OSC 4; the fore/background/caret setters overwrite OSC 10/11/12), and the host calls in on every mount and tab switch across *all* sessions — so without the guard an ordinary tab switch would silently undo colors a program or the user's profile set. A real theme change still resets them: there the app theme wins by design. **Revised again in review:** the key is the resolved colors and *not* `NSAppearance.Name`, because the caret and selection are accent-derived semantic colors — an accent change alters them while the name stays `.aqua`/`.darkAqua`, so a name-keyed guard would pin every live session to the old accent. `TerminalSessionsModel` correspondingly observes `NSColor.systemColorsDidChangeNotification` (no appearance callback fires for an accent change) and re-applies the remembered appearance; the key guard makes that subscription inert whenever nothing actually changed.
- [x] In `TerminalSessionsModel` — a stored `private var appearance: NSAppearance?` (a plain property, not `@Published`: the recolor bypasses SwiftUI invalidation, and an extra panel redraw is unwanted).
- [x] `func applyTheme(for appearance: NSAppearance)` — remembers the appearance and applies it to **every** session in `sessions` (not just the active one), so switching to an inactive tab never shows the old theme.
- [x] In `newSession(projectRoot:)` (and therefore in `runFile`/`testFile`, which go through it / the shared `run`) — apply the theme to the freshly created session immediately: `appearance ?? NSApp.effectiveAppearance`; doc comment that `NSApp.effectiveAppearance` is a fallback only until the host first mounts (a forced theme from Settings lives on the window, not the application), and the host corrects the color on the same main-loop turn. (Applied through a shared private `applyCurrentTheme(to:)` at both creation sites — `newSession` and the `runFile`/`testFile` `run` body, which builds its session directly rather than via `newSession`.)
- [x] Tests: none new (view layer; no pure logic added — `TerminalLaunch` untouched).
- [x] `swift test` — green before Task 3.

### Task 3: Intercepting the appearance change in the panel host

**Files:**
- Modify: `Sources/Pisaka/TerminalPanelView.swift`

- [x] A private `final class TerminalContainerView: NSView` with `var onAppearanceChange: ((NSAppearance) -> Void)?`, overriding `viewDidChangeEffectiveAppearance()` (call `super`, then the closure with `effectiveAppearance`).
- [x] `TerminalHostView` — take `model: TerminalSessionsModel` in addition to `session`; in `makeNSView` create a `TerminalContainerView` (in place of the plain `NSView`) and set `onAppearanceChange = { model.applyTheme(for: $0) }`.
- [x] **Preserve the host's existing semantics unchanged** while introducing the container — this is the spot where they are easy to break:
  - `updateNSView` keeps its `guard terminalView.superview !== container else { return }` early-out, so the on-screen view is swapped only on an actual tab change, never on an ordinary re-render (the panel re-renders on any SwiftUI invalidation, e.g. an editor keystroke republishing `WorkspaceModel`);
  - `makeFirstResponder(terminalView)` stays inside `install(_:in:)` only (initial mount and tab switch), so focus is never yanked back from the editor mid-typing;
  - the container's parameter/return type change must not turn the guard into an unconditional reinstall, and the theme application added below must not be routed through `install`.
- [x] Apply the theme on mount / view installation (`makeNSView`, and inside the actual tab-change branch of `updateNSView` *after* the existing guard) via `model.applyTheme(for: container.effectiveAppearance)` — `viewDidChangeEffectiveAppearance` is not guaranteed to fire on view insertion, and the panel may have been hidden when the theme changed (while the sessions stayed alive). This is an idempotent recolor of already-live views: it neither swaps the hierarchy nor touches the responder, so it cannot re-enter the focus path.
- [x] In `TerminalPanelView.body`, pass `model` into `TerminalHostView`.
- [x] Doc comments: why we key off the view's `effectiveAppearance` rather than `SettingsStore` (one point covers both a system change and a forced `.preferredColorScheme`), why we apply to all sessions rather than just the active one, and a note that the container subclass exists purely for the appearance hook — the swap-on-tab-change / focus-on-install semantics are unchanged.
- [x] Tests: none new (view layer).
- [x] `swift test` — green before Task 4.

### Task 4: Verify acceptance criteria 1–2 (suite and builds)

**Files:**
- Modify: none (runs only)

- [x] `swift test` — green (Core untouched, suite unchanged). 849 tests, 0 failures.
- [x] `xcodegen generate` (the new file under `Sources/Pisaka` is picked up by the directory config; no `project.yml` change needed).
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green (BUILD SUCCEEDED).
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — green (confirming nothing leaked out from under `#if os(macOS)`).
- [x] Confirm all new code in `Sources/Pisaka/TerminalTheme.swift` and the edits in the terminal files stay under `#if os(macOS)`, and that `PisakaCore` gained neither a SwiftTerm/AppKit dependency nor new files. All four terminal files open with `#if os(macOS)` and close with `#endif`; the branch diff touches no `Sources/PisakaCore` file.
- [x] Re-read the final `TerminalHostView` diff and confirm the two invariants survived: the `superview !== container` guard is the only path to a view swap, and `makeFirstResponder` is called only from `install(_:in:)`. Both hold — the new `applyTheme(from:)` sits outside `install` on the mount and tab-change paths.

### Task 5: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] `CLAUDE.md`: add a `TerminalTheme.swift` entry to the `Pisaka` file list (two built-in palettes, resolving dynamic `NSColor`s under the target appearance, applying through the public `setBackgroundColor`/`setForegroundColor` — because the direct `native*Color` setters on macOS neither clear the attribute cache nor repaint — ~~plus the explicit decision to leave ANSI-16 alone~~ **revised in review, per Task 1:** plus the themed ANSI-16 palette installed through the public `installColors(_:)` (a darkened, ≥ 4.4:1-against-white set for `light`; SwiftTerm's own `defaultInstalledColors` verbatim for `dark`) and why SwiftTerm's defaults are unreadable on a white background, with only a *user-configurable* palette left out of scope).
- [x] `CLAUDE.md`: update the descriptions of `TerminalSession` (`applyTheme(for:)`), `TerminalSessionsModel` (remembered appearance, application to all sessions, theme for a freshly created session) and `TerminalPanelView` (`TerminalContainerView` + `viewDidChangeEffectiveAppearance`, application on mount/tab change, why the key is `effectiveAppearance` and not `SettingsStore`), keeping the existing sentence about swapping the on-screen view only on an actual tab change — now stated as an invariant the container preserves.
- [x] `README.md`: in the embedded-terminal paragraph, add that the terminal follows the app theme (system and forced from Settings), and refine the "no custom theme/font" caveat — the two built-in palettes (ANSI-16 included) are not *user-configurable*, which is what remains out of scope.
- [x] `swift test` — final run, green. 849 tests, 0 failures.

## Post-Completion (manual verification, macOS)

Not automatable by the agent — done by a human after the build/merge:

- light system + `ThemePreference.system` → terminal is light; dark → dark;
- a forced light/dark in Settings overrides the system one — the terminal follows it live, without recreating the session (typed text and scrollback are preserved);
- changing the theme with two terminal tabs open — both are recolored, including the inactive one after switching to it;
- changing the theme while the terminal panel is *hidden* — reopening the panel shows it already in the new theme;
- changing the theme *while typing into the terminal* does not steal focus from it — the caret stays in the terminal and subsequent keystrokes still land there;
- typing in the editor with the terminal panel visible still does not pull focus into the terminal (the pre-existing behavior is unchanged);
- selection and caret are distinguishable in both themes;
- changing the **accent color** in System Settings recolors the caret and selection of every live session (they are semantic accent-derived colors; the appearance name does not change, so this goes through `NSColor.systemColorsDidChangeNotification` rather than the appearance callback).
