# Pisaka app (macOS) — embedded terminal

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds a per-file index and the cross-cutting invariants). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `TerminalTheme.swift` — the embedded terminal's built-in (not
    user-configurable) light/dark color table, applied to SwiftTerm in the view
    layer so `PisakaCore` stays color-free. An `enum TerminalTheme` (statics
    only). **Only the two ANSI-16 arrays are spelled here**; the four colors
    around them are chrome and are read from `ChromePalette` as roles since part
    five (h) (`core-theme.md`): the ground is `bgPanel` (`0x2B2D30` dark,
    `0xECECEF` light — black and white before part five (h), then `bgCanvas`
    until the design pass moved it onto the role the dock slot paints, so the
    terminal and the inset around it read as one surface), the default text `textPrimary`
    (`0xDFE1E5` / `0x1D1D1F` — it was SwiftTerm's `#8A8A8A` and `#1E1E1E`), the
    caret `accent` and the selection `accentTintStrong`. Before part five (h) the
    caret and selection were the semantic
    `.selectedContentBackgroundColor`/`.selectedTextBackgroundColor`, following
    the user's accent color; **no terminal color follows the system accent any
    more**. The caret is the saturated `accent`, never the pale
    `accentTintStrong` wash, so the caret and a selected region stay
    distinguishable and a block cursor's glyph — drawn in the ground color —
    stays readable against it. `chromeAppearance(for:)` matches the hosting
    `NSAppearance` via `bestMatch(from: [.aqua, .darkAqua])` (`.darkAqua` →
    `.dark`, anything else → `.light`, so a high-contrast or accessibility
    variant still resolves to one of the two), `ansiColors(for:)` picks the
    ANSI set that goes with it, and `apply(to view: appearance:)` recolors a live
    `TerminalView`. `key(for appearance:) -> ThemeKey` is the companion the
    *caller's* skip-if-unchanged guard compares (`TerminalSession.applyTheme`):
    the four resolved colors as 16-bit sRGB components, in the order ground,
    text, caret, selection, produced by the same private `resolvedColors(in:)`
    `apply` uses so the guard can never judge a different set than the one
    installed. It fingerprints the whole apply — the ground differs between the
    two appearances and so also encodes the ANSI-16 set — and it is
    *components*, not the `NSColor`s, because comparing components keeps the
    guard deterministic: a false negative would silently reinstate the
    per-tab-switch color reset the guard exists to prevent. **The concrete
    accessor is the chrome theme's stated exception for this file**: the rest of
    the AppKit chrome hands AppKit a dynamic color and caches nothing, but
    SwiftTerm stores its own `SwiftTerm.Color` structs (plus plain `NSColor`s for
    caret/selection) and never re-resolves them, so the four roles are resolved
    *at apply time* through `ChromePalette.nsColor(_:in:)` — a host that stores
    concrete colors is handed concrete colors — and the existing re-apply on
    every appearance change keeps them current. (The former private
    `resolved(_:in:)`, which wrapped `usingColorSpace(.sRGB)` in
    `performAsCurrentDrawingAppearance` to resolve dynamic system colors, is gone
    with nothing dynamic left to resolve.) The background/foreground go through
    the public `setBackgroundColor(source:color:)`/
    `setForegroundColor(source:color:)` pair rather than the direct
    `nativeBackgroundColor`/`nativeForegroundColor` setters, because on macOS only
    the former also call SwiftTerm's internal `colorsChanged()` (clearing the cached
    text attributes and forcing a full repaint) — writing the properties directly
    would leave every already-drawn cell in the old colors. It also sets
    `caretTextColor` to the resolved ground, `selectedTextBackgroundColor`, and
    `layer?.backgroundColor` (SwiftTerm assigns the layer background only once, in
    `setupOptions()`, so a later palette change must update it itself). The
    **ANSI-16 palette is themed too**, through the public `installColors(_:)`
    (which likewise resets the attribute cache and repaints): SwiftTerm's sixteen
    defaults are tuned for its black background and several are unreadable on a
    light one — bright white `#E5E5E5` at 1.26:1 on white, bright yellow 1.35:1,
    bright cyan 1.57:1, ANSI 7 `#BFBFBF` at 1.84:1 — and because `useBrightColors`
    defaults to `true`, *bold* text on colors 0–6 is remapped onto those brights,
    so ordinary prompt/`ls`/`npm` output would vanish in the light theme.
    `lightANSIColors` is a darkened set, every entry at least 4.5:1 against the
    light ground `0xECECEF` ("bright" reads as more *saturated* rather than
    lighter, the only direction legible on a light background; ANSI 8, 11 and 14
    were darkened in part five (h) to hold that floor on `0xF5F5F7`, and ANSI 8,
    11, 13 and 14 again — to `0x6A6A6A`, `0x8A6400`, `0xA63AB3` and `0x007583`
    — when the ground moved to `bgPanel`), and `darkANSIColors` is SwiftTerm's
    `Color.defaultInstalledColors` hues with nine entries brightened so every
    entry but ANSI 0's exact black clears 4.5:1 against the terminal's ground,
    `bgPanel` dark `0x2B2D30` — ANSI 1 `0xFF6B6B` (4.98:1), 2 `0x00B803` (5.17),
    3 `0xA0A000` (4.95), 4 `0x9393FF` (5.17), 5 `0xE070E0` (4.97), 8 `0x9E9D9E`
    (5.11), 9 `0xFF8C8C` (6.17), 12 `0xAAAAFF` (6.51) and 13 `0xFF8CFF` (6.87);
    the other seven are SwiftTerm's values verbatim and already clear. Both sets
    are fixed, so the install is unconditional in both directions and dark →
    light → dark restores exactly the same sixteen. Both arrays are internal so the app bundle's
    `TerminalThemeTests` can read them. **The chrome suite's exemption covers
    those two arrays and nothing else**: rule forty-four refuses any `0x` literal,
    `NSColor(` construction, colour construction beyond the two converters or
    system colour name outside them (the `.…Color` members pinned by set
    equality), and requires the four role tokens and exactly sixteen `rgb8(`
    entries in each array. `TerminalThemeTests` pins the dark floor (reading the
    ground from the palette, never a literal) and the exact sixteen dark values;
    the tuning is recorded in `core-theme.md`. What remains out of scope is a
    *user-configurable* palette. A private `NSColor → SwiftTerm.Color` converter
    does the sRGB×65535 mapping (SwiftTerm's own `getTerminalColor()` is
    module-internal); its per-component helper *rounds* rather than truncates —
    which keeps an 8-bit palette value on the exact ×257 point of the 16-bit
    scale — clamps to 0…1 (an extended-range color space can report values
    outside it, which would trap the `UInt16` conversion), and rejects a
    non-finite value in a *separate* guard, since `min`/`max` propagate NaN and a
    clamp alone would still trap. `TerminalThemeTests` (app bundle) pins the key
    against the palette's four roles under both appearances and both
    high-contrast variants, with its own
    component arithmetic, the ground an apply actually leaves on a live
    (process-less) `TerminalView` — its layer background and the text under the
    caret, both `bgPanel` in either appearance — the light set's floor (every
    entry ≥ 4.5:1 on the light `bgPanel`, each failure naming the index and
    ratio), which set each appearance installs, and both arrays' sixteen
    entries.
  - `TerminalSession.swift` — one live shell session in the embedded terminal: a
    final class holding a stable `id` (UUID), a display `title`, and the SwiftTerm
    `LocalProcessTerminalView` that hosts the PTY-backed shell. Thin view-layer
    code (like `CodeEditorView`); all the pure logic — which shell, which directory
    — is resolved by `PisakaCore.TerminalLaunch` and passed in. `init(title:shell:
    workingDirectory:)` starts the shell immediately: SwiftTerm 1.5.0's *view-level*
    `startProcess` takes no working directory, but the module-internal
    `LocalProcess.startProcess` does — and that instance is already reachable
    through `Mirror` (see `terminate()`), so `workingDirectory` is passed straight
    through it rather than mutating the app-wide current directory (which would
    race any concurrent relative-path work and, on a silently failed `chdir`, start
    the shell in the wrong place). Only if that reflection fails does it fall back
    to the cwd-swap the view API forces — point `FileManager`'s current directory at
    `workingDirectory` just long enough for `forkpty` (the child inherits it) then
    restore it, the approach SwiftTerm's own sample uses. Either way it
    launches a *login* shell (argv[0] prefixed with `-`) so the user's profile is
    sourced. `terminate()` sends `SIGTERM` to the shell: SwiftTerm 1.5.0 keeps the
    view's `LocalProcess` module-internal, so it reaches the public
    `LocalProcess.terminate()` through `Mirror` (stable because the dependency is
    pinned to an exact version) — but only after gating on the public
    `running`/`shellPid > 0`, since an exited shell's `shellPid` is stale (and may
    have been reused by an unrelated process) and a failed launch leaves it 0, where
    `kill(0, SIGTERM)` would signal the app's whole process group; SwiftTerm's own
    `terminate()` makes neither check. `run(command:)` types a command into the running
    shell via SwiftTerm's `terminalView.send(txt: command + "\n")` (emulating user
    input — the login shell and cwd are already set, so no `cd` is needed); it backs
    the Run File feature. `applyTheme(for appearance:)` is a thin forward to
    `TerminalTheme.apply(to: terminalView, appearance:)`: the recolor happens on the
    live view, so the shell process, its PTY and the whole scrollback are untouched
    (a theme change repaints what is on screen rather than restarting anything), and
    it is idempotent so the panel host can call it on every mount without checking
    whether the palette actually changed — because the session *remembers the colors
    it last applied* (a `TerminalTheme.ThemeKey`) and skips a repeat for the same
    ones. That guard is load-bearing, not an optimization: applying a theme is a
    full **reset** of exactly the state the terminal's own escape sequences write to
    — `installColors` goes through SwiftTerm's `installPalette`, which assigns
    `ansiColors = defaultAnsiColors` and so discards every OSC 4 entry, while the
    background/foreground/caret setters overwrite what OSC 10/11/12 set — and the
    panel host calls in on every mount *and every tab switch*, each call recoloring
    **all** sessions, so without it an ordinary tab switch would silently undo a
    palette a program or the user's shell profile had set. A real theme change still
    resets them: there the app theme deliberately wins. `applyFont(size:)` is the
    terminal **zoom zone's** analogue (the zone's own entry is `core-zoom.md`):
    it sets `terminalView.font` to
    `NSFont.monospacedSystemFont(ofSize:weight: .regular)` — exactly how SwiftTerm
    builds its own default, so at the zone's resting 13 pt
    (`NSFont.systemFontSize`) it is the very font the view was already drawing
    with and a fresh install at 100% is identical to before. Setting that property
    re-derives the whole font set, recomputes the cell dimensions and `resize`s
    the terminal, which resizes the **PTY** — so the running shell reflows to the
    new size rather than being restarted, and the scrollback and the process are
    untouched. The remembered-size guard (`appliedFontSize`) is load-bearing for
    `applyTheme`'s reason and one more: SwiftTerm's font setter also calls
    `selectNone()`, so an unconditional assignment would drop the user's
    selection — and since the window root calls in on mount and on every settings
    change, each call fanning out over every live session, without the guard an
    unrelated preference edit would clear a selection in a terminal the user never
    touched and pay a full font-set rebuild plus PTY resize per session for it.
    The terminal zone's *surface* is declared on SwiftTerm's `TerminalView` (an
    extension in this same file conforming it to `ZoomSurfaceProviding`) and not
    on the session: the pointer walk finds `NSView`s, and a session is not one.
    The key is the whole resolved
    color set rather than `NSAppearance.Name`: comparing components keeps the
    guard deterministic, and whatever the apply would install is exactly what is
    compared. (It once also had to see an accent-color change, while the caret and
    selection followed the system accent; since part five (h) they are the
    `accent` and `accentTintStrong` roles and follow nothing but the appearance.)
  - `TerminalSessionsModel.swift` — `ObservableObject` owning the embedded
    terminal's sessions and active tab (thin view-layer state, like
    `WorkspaceModel` but with no pure logic to test beyond `TerminalLaunch`).
    Publishes `sessions: [TerminalSession]` (tab order) and `activeID: UUID?`, with
    a computed `activeSession`. `newSession(projectRoot:)` resolves shell/cwd via
    `TerminalLaunch` (from `ProcessInfo.processInfo.environment` and
    `FileManager.default.homeDirectoryForCurrentUser`), appends a uniquely titled
    ("Terminal N", via a monotonic counter) session, and makes it active;
    `activate(id:)` just changes `activeID` (so switching tabs never recreates a
    running shell); `close(id:)` terminates the session's shell, drops the tab, and
    re-selects a neighbor resolved by Core's `TerminalTabs.activeIDAfterClosing`
    against the pre-removal order; `terminateAll()` terminates every shell and clears the
    tabs (called on app termination so no shell processes leak). For the Run File /
    Run Test features it keeps a private `runSessions: [String: UUID]`
    (`sessionKey` → the id of the session launched for it) driven by a shared
    private `run(sessionKey:command:workingDirectory:title:)`: it `close(id:)`s any
    still-live session under `sessionKey` first (a re-run recreates the tab rather
    than piling up a new one), creates a session (shell via `TerminalLaunch`, the
    passed `workingDirectory`), makes it active, records it under `sessionKey`, and
    types the command in via `session.run(command:)`. Two thin entry points key off
    `url.resolvingSymlinksInPath().path` with a distinct prefix so a file's run and
    test sessions are independent: `runFile(url:command:workingDirectory:title:)`
    uses `"run:" + path` and `testFile(url:command:workingDirectory:title:)` uses
    `"test:" + path`. `close(id:)` drops any `runSessions` entry pointing at the
    closed id by value (a manual close → the next run/test is fresh, for either
    prefix) and `terminateAll()` clears the whole map. For the terminal theme it
    keeps a `private var appearance: NSAppearance?` — the appearance last themed
    for, deliberately a plain stored property rather than `@Published` because
    applying a theme recolors the AppKit views directly and bypasses SwiftUI, so
    publishing it would only invalidate the panel for a redraw that changes nothing.
    `applyTheme(for appearance:)` remembers it and applies it to **every** session
    in `sessions`, not just the active one: an inactive session's view is out of the
    hierarchy and gets no appearance callback of its own, so it would otherwise
    surface the old theme on the next tab switch (idempotent, so the host may call
    it on mount and on every appearance change — each session drops a request whose
    resolved colors it already carries, which is what keeps the fan-out from
    resetting OSC-set colors on every tab switch). The panel host's
    `viewDidChangeEffectiveAppearance` hook is the only re-apply trigger: the
    `NSColor.systemColorsDidChangeNotification` observer it once kept (with its
    `init` and `deinit`) existed only to follow an accent-color change, and was
    removed in part five (h) when no terminal color followed the system accent
    any more. Both creation sites — `newSession`
    and the `runFile`/`testFile` `run` body, which builds its session directly —
    color the fresh session before it is ever drawn through a shared private
    `applyCurrentTheme(to:)` (`appearance ?? NSApp.effectiveAppearance`), so a new
    tab does not appear in SwiftTerm's dark defaults and then flip;
    `NSApp.effectiveAppearance` is only a fallback for the window between app launch
    and the host's first mount (a theme forced through `ThemePreference` is applied
    by `.preferredColorScheme` to the *window*, not the application, so it is not
    visible there), and the host corrects the color from the container's own
    `effectiveAppearance` on the same main-loop turn.
    The terminal font size takes the **same shape for the same reasons**: a
    `private var fontSize: Double?` remembers what the sessions were last set to
    (a plain stored property, not `@Published`, because applying a font mutates
    the AppKit view directly and re-lays the PTY out itself), `applyFontSize(_:)`
    remembers it and fans it over **every** session — an inactive session's view
    is out of the hierarchy and would surface the old size on the next tab switch
    — and a private `applyCurrentFontSize(to:)` sizes each freshly created session
    at both creation sites before it is ever drawn, so a new tab (or a Run/Test
    session started while the panel was hidden) does not appear at SwiftTerm's
    default and then flip. Its fallback is that same default —
    `ZoomScaleRule.terminalFont`'s resting value *is* `NSFont.systemFontSize` —
    so the pre-seeding window between app launch and the window root's first push
    is a no-op rather than a wrong guess. `applyFontSize` is idempotent, so the
    root may call it on mount and on every change without tracking whether the
    value moved. **Where it is pushed from is the one difference from the theme**:
    `ContentView` (`.onAppear` + `.onChange(of: settings.terminalFontSize)`), not
    the panel — a session can be created while the panel is not on screen (⌘R/⌘U
    make one and only then show it) and the panel is torn down whenever the dock
    shows Log or Changes instead. The panel's own tab strip stays on the
    *interface* zone: it is chrome, and only the cells follow the terminal size.
  - `TerminalPanelView.swift` — the embedded terminal panel: a `View` with a tab
    bar (per-session tabs + "＋" new + per-tab close `xmark`) above the active
    session's terminal. **It states no minimum height, and must not**: it is
    rendered into a bottom-dock slot of exactly `BottomPanelHeightRule`'s height,
    and a minimum inside a fixed-height slot can only overflow — over the divider
    above and the bottom bar below — because the child cannot make the slot grow.
    It carried `minHeight: metrics.scaled(120)` until that rule was written; the
    full reasoning, and the `BottomPanelSourceGatingTests` pin that now keeps this
    file honest, are in `app-window.md`. So `\.interfaceMetrics` here reaches the
    tab strip and nothing else. The panel observes `TerminalSessionsModel` and
    takes the current `projectRoot` (read only when creating a *new* session — existing sessions keep
    their start directory). The active session's `LocalProcessTerminalView` is
    hosted by a private `TerminalHostView: NSViewRepresentable` that swaps the
    on-screen view only on an actual tab change (the `terminalView.superview !==
    container` guard is the *only* path to a swap, so re-renders — the panel
    re-renders on any SwiftUI invalidation, e.g. an editor keystroke republishing
    `WorkspaceModel` — don't churn the hierarchy or steal focus mid-typing) and
    makes it first responder from `install(_:in:)` alone (initial mount and tab
    switch); SwiftTerm handles keyboard capture and PTY resize on the view itself.
    Both remain invariants under the theme wiring below, which introduced the
    container subclass. The host's container is a private `TerminalContainerView:
    NSView` existing *purely* for the appearance hook: it overrides
    `viewDidChangeEffectiveAppearance()` and forwards `effectiveAppearance` to an
    `onAppearanceChange` closure, which `makeNSView` wires to
    `model.applyTheme(for:)`. Keying off the *view's* effective appearance rather
    than observing `SettingsStore` is what lets one mechanism cover both cases —
    a system light/dark switch and a theme forced through `ThemePreference`, which
    SwiftUI applies as `.preferredColorScheme` to the window, so the hosted AppKit
    views' `effectiveAppearance` changes with it. The theme is also applied on mount
    and inside the tab-change branch (after the guard) via a private
    `applyTheme(from container:)` → `model.applyTheme(for: container
    .effectiveAppearance)`, because `viewDidChangeEffectiveAppearance()` is not
    guaranteed to fire on view insertion and the panel may have been hidden (with
    its sessions still alive) while the theme changed; it is deliberately *not*
    routed through `install(_:in:)` — an idempotent recolor of already-live views
    that touches neither the hierarchy nor the responder chain, so it cannot
    re-enter the focus path. The recolor goes to every live session (see
    `TerminalSessionsModel.applyTheme`), not just the hosted one.
    **The host is on the chrome roles since part four (a)** (`core-theme.md`):
    the view reads `\.chromeTheme` beside `\.interfaceMetrics`, and like the
    metrics it reaches the strip and the empty ground only. **The session strip
    is this panel's header strip**: it spends `ChromeGeometry.panelHeaderHeight`
    where it used to spell a bare 28, and draws its own one-point `hairline`
    along its bottom edge in place of the `Divider()` that sat under it (gating
    rule fourteen); its gaps and insets are bare local numbers in `private enum
    TerminalTabStripLayout`. The selected session tab is an `accentTintStrong`
    wash — it was the platform's `selectedControlColor` — clipped at
    `cornerRadiusMax`, the chrome's one radius; a title is `textPrimary` when
    selected and `textSecondary` otherwise; the close glyph moved off a bare
    8-point bold onto `.subheadline` bold, matching the label beside it; and
    the `+` and `xmark` glyphs state `textSecondary` explicitly, because a
    borderless button would otherwise tint them itself. The no-session
    placeholder draws `bgPanel` rather than the platform's `textBackgroundColor`.
    `TerminalHostView` and the container view are **untouched**; the host sits
    inside `TerminalPanelInset`, which pads it 14 points left and right — an
    interface-zone measurement through `metrics.scaled(_:)`, so zooming the
    terminal leaves it alone — and paints the margin `bgPanel`, the terminal's
    own ground and the dock slot's, so the panel reads as one surface. The inset
    is its own generic view so `TerminalPanelInsetTests` (app bundle) can measure
    it around a stand-in, at scale 1.0 and 1.8, without spawning a shell. The terminal's
    ANSI-16 arrays (`TerminalTheme`, one of the chrome suite's four exemptions,
    narrowed by rule forty-four to those two arrays) are the terminal zone, not
    chrome; its four chrome colors — ground, text, caret, selection — have been
    the `bgPanel` (`bgCanvas` until the design pass), `textPrimary`, `accent`
    and `accentTintStrong` roles since part five (h), resolved concretely by
    appearance (`TerminalTheme`'s entry).
