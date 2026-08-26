# Pisaka app (macOS) — embedded terminal

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `TerminalTheme.swift` — the embedded terminal's built-in (not
    user-configurable) light/dark color table, the `SyntaxTheme` precedent applied
    to SwiftTerm so `PisakaCore` stays color-free. An `enum TerminalTheme` (statics
    only) with an internal `Palette`
    (`background`/`foreground`/`caret`/`selection` + a 16-entry `ansi`)
    and two values: `light` (white background, near-black `#1E1E1E` text) and `dark`
    (black background and SwiftTerm's exact `Color.defaultForeground`,
    35389/65535 per channel — `#8A8A8A` rounded to 8 bits — so the dark theme
    looks exactly as the terminal did before the feature); caret and selection are
    the semantic `.selectedContentBackgroundColor`/`.selectedTextBackgroundColor`
    so they follow the user's accent color. The caret is deliberately *not*
    `.selectedControlColor`: that is byte-identical to
    `.selectedTextBackgroundColor` in both appearances (`#B3D7FF`/`#3F638B`), so
    caret and selection would be indistinguishable, and a block cursor filled with
    the pale light-mode tint would render its `caretTextColor` glyph (the white
    palette background) at 1.5:1.
    `palette(for appearance:)` picks between them
    via `appearance.bestMatch(from: [.aqua, .darkAqua])` (so a high-contrast or
    accessibility variant still resolves to one of the two), and `apply(to view:
    appearance:)` recolors a live `TerminalView`. `key(for appearance:) ->
    ThemeKey` is the companion the *caller's* skip-if-unchanged guard compares
    (`TerminalSession.applyTheme`): the four resolved colors as 16-bit sRGB
    components, produced by the same private `resolvedColors(_:in:)` `apply` uses so
    the guard can never judge a different set than the one installed. It fingerprints
    the whole apply — the fixed background/foreground differ between the two palettes
    (white/black) and so also encode the ANSI-16 set that goes with them — and it is
    *components*, not the `NSColor`s, because a false negative would silently
    reinstate the per-tab-switch color reset the guard exists to prevent. Unlike `SyntaxTheme`, which hands
    dynamic `NSColor`s to AppKit and lets it resolve them *at draw time*, the
    palette is resolved *at apply time* — SwiftTerm stores its own
    `SwiftTerm.Color` structs (plus plain `NSColor`s for caret/selection) and never
    re-resolves them — through a private `resolved(_:in:)` that wraps
    `usingColorSpace(.sRGB)` in `appearance.performAsCurrentDrawingAppearance`:
    without the explicit drawing appearance a dynamic color resolves against the
    *current thread's* (the app's) appearance, so a window forced light by
    `ThemePreference` while the system is dark would receive the dark variant. The
    background/foreground go through the public `setBackgroundColor(source:color:)`/
    `setForegroundColor(source:color:)` pair rather than the direct
    `nativeBackgroundColor`/`nativeForegroundColor` setters, because on macOS only
    the former also call SwiftTerm's internal `colorsChanged()` (clearing the cached
    text attributes and forcing a full repaint) — writing the properties directly
    would leave every already-drawn cell in the old colors. It also sets
    `caretTextColor` to the palette background (text under a block cursor stays
    readable against the accent-colored caret), `selectedTextBackgroundColor`, and
    `layer?.backgroundColor` (SwiftTerm assigns the layer background only once, in
    `setupOptions()`, so a later palette change must update it itself). The
    **ANSI-16 palette is themed too**, through the public `installColors(_:)`
    (which likewise resets the attribute cache and repaints): SwiftTerm's sixteen
    defaults are tuned for its black background and several are unreadable on a
    white one — bright white `#E5E5E5` at 1.26:1, bright yellow 1.35:1, bright
    cyan 1.57:1, ANSI 7 `#BFBFBF` at 1.84:1 — and because `useBrightColors`
    defaults to `true`, *bold* text on colors 0–6 is remapped onto those brights,
    so ordinary prompt/`ls`/`npm` output would vanish in the light theme. `light`
    installs a darkened set (every entry ≥ 4.4:1 against white; "bright" reads as
    more *saturated* rather than lighter, the only direction legible on a light
    background) and `dark` reinstalls SwiftTerm's own
    `Color.defaultInstalledColors` verbatim, spelled out locally so the install is
    unconditional in both directions and dark → light → dark restores exactly what
    the view started with. What remains out of scope is a *user-configurable*
    palette. A private `NSColor → SwiftTerm.Color` converter does the sRGB×65535
    mapping (SwiftTerm's own `getTerminalColor()` is module-internal); its
    per-component helper *rounds* rather than truncates — which is what lets the
    dark foreground reproduce `defaultForeground` as 35389 rather than 35388 —
    clamps to 0…1 (an extended-range color space can report values outside it,
    which would trap the `UInt16` conversion), and rejects a non-finite value in a
    *separate* guard, since `min`/`max` propagate NaN and a clamp alone would still
    trap. View layer, so untested like the rest.
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
    color set and deliberately **not** `NSAppearance.Name`: the caret and selection
    are semantic accent-derived colors, so changing the accent changes them while the
    appearance name stays `.aqua`/`.darkAqua` — a name-keyed guard would pin every
    live session to the old accent (and, since nothing else re-applies, keep it there
    indefinitely).
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
    resetting OSC-set colors on every tab switch). Its `init` also observes
    `NSColor.systemColorsDidChangeNotification` (token removed in `deinit`) and
    re-applies the remembered appearance: the panel host's
    `viewDidChangeEffectiveAppearance` hook covers a light/dark switch, but an
    **accent-color** change — which the caret and selection are derived from — leaves
    the effective appearance untouched and fires no such callback, so without it the
    sessions would keep the old accent until the panel happened to be remounted. The
    same `ThemeKey` guard is what makes subscribing safe: an unrelated system color
    change resolves to the colors already installed and is dropped. Both creation sites — `newSession`
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
