#if os(macOS)
import Combine
import SwiftUI
import AppKit
import Neon
import PisakaCore

/// A monospaced code editor backed by `NSTextView` inside an `NSScrollView`,
/// with tree-sitter syntax highlighting via Neon's `TextViewHighlighter`.
///
/// The text is driven by a SwiftUI `Binding`; user edits flow back through that
/// binding so the workspace model can track dirty state.
///
/// `fileID` identifies which file is currently shown. When it changes (the user
/// switched tabs) the editor contents are replaced with the new file's text,
/// rather than being treated as an in-place edit. `fileName` drives language
/// detection: the *whole name* resolves to a `SyntaxLanguage` — by extension, by
/// exact name (`Dockerfile`, `.env`), or by dot-ignore shape (`.gitignore`) — or
/// to `nil` for an untitled/unknown file, which shows plain text with no
/// highlighter attached.
struct CodeEditorView: NSViewRepresentable {
    /// Identity of the file being edited; a change means a tab switch.
    let fileID: UUID

    /// The selected file's display name. Its extension selects the syntax
    /// language; `"Untitled"` (and unknown extensions) resolve to plain text.
    let fileName: String

    /// The IDs of all currently open files. Used to prune per-file undo managers
    /// for files that have been closed, so undo history doesn't accumulate.
    let openFileIDs: Set<UUID>

    /// The selected file's external-replacement token
    /// (`WorkspaceModel.textReplacementRevision(for:)`). Compared against the
    /// value this coordinator last saw for the same `fileID` to tell an ordinary
    /// tab switch (keep that file's undo stack — the whole point of the per-file
    /// managers) from a switch back to a tab whose buffer was replaced while it
    /// was off screen (drop it — its actions name ranges the new text no longer
    /// has). Defaults to `0` so a default-constructed view compiles.
    var externalTextRevision: Int = 0

    /// The selected file's on-disk location, or `nil` for an untitled buffer.
    /// Drives the gutter's git-blame column: it is what `BlameController` blames,
    /// and a `nil` disables the "Annotate with Git Blame" menu item (there is no
    /// file to blame). Defaults to `nil` so a default-constructed view compiles.
    var fileURL: URL?

    /// The selected file's disk-revision token (`WorkspaceModel.diskRevision(for:)`).
    /// Its contract is "the on-disk content this buffer corresponds to changed",
    /// which is exactly when a worktree blame goes stale, so `BlameController`
    /// compares it against the last value it saw for the same file and recomputes
    /// the column when it differs. Defaults to `0` so a default-constructed view
    /// compiles.
    var diskRevision: Int = 0

    /// The workspace's project root, or `nil` while no folder is open. A change
    /// under an unchanged buffer means every earlier sync of that buffer answered
    /// against a different root — or against none, where a sync could not run at
    /// all — so it joins the retarget test in `updateNSView`. Defaults to `nil`
    /// so a default-constructed view compiles.
    var projectRoot: URL?

    /// The editor contents. Edits are written back through this binding.
    @Binding var text: String

    /// The shared editor font size (points). Owned by `SettingsStore`; a change
    /// re-applies the font and re-syncs the gutter/minimap in `updateNSView`.
    let fontSize: Double

    /// Whether the completion popup is offered at all — `SettingsStore.completionEnabled`,
    /// which `ContentView` already observes and passes down.
    ///
    /// A **plain value**, exactly like `fontSize`, rather than a second observed
    /// object: the store is observed once, where the view is built, and the flag
    /// simply travels with the update that observation already causes. Making the
    /// editor observe anything itself would add a per-keystroke re-render path to
    /// the one view in the app that must not have one. It is applied in
    /// `makeNSView` (beside `attachCompletion`) and re-applied in `updateNSView`,
    /// so flipping the toggle takes effect on the next SwiftUI update — no
    /// restart, no tab switch.
    ///
    /// Undefaulted, unlike the optional/no-op conveniences below and exactly like
    /// `fontSize`: a default would have to be `true`, so a second editor host
    /// added later would compile clean and offer completions to a user who turned
    /// them off — a silent regression of the whole feature that nothing in the
    /// repo could catch (`swift test` compiles Core alone and the view layer is
    /// untested by convention). Requiring it makes that a compile error.
    let completionEnabled: Bool

    /// Whether the leading whitespace of every line is tinted by indentation
    /// level — `SettingsStore.indentLevelHighlightingEnabled`, which
    /// `ContentView` already observes and passes down.
    ///
    /// Travels `completionEnabled`'s route exactly, and is **undefaulted** for
    /// its reason: a default would have to be `true`, so a second editor host
    /// added later would compile clean and paint for a user who turned the
    /// blocks off, which nothing in the repository could catch. Applied in
    /// `makeNSView` and re-applied in `updateNSView`, so flipping the toggle
    /// stops or resumes the painting in every open tab on the next update — no
    /// reload, no tab switch.
    let indentLevelHighlightingEnabled: Bool

    /// The interface zone's metrics, for the one piece of *chrome* this editor
    /// owns: the hover popover's prose.
    ///
    /// A **plain value beside `fontSize`**, following that property's precedent
    /// exactly, and undefaulted for its reason too. The two are deliberately
    /// different zones travelling together: the popover draws code at `fontSize`
    /// (the code zone, untouched) and prose at these metrics (the interface
    /// zone), and the raw interface scale is never named here — an
    /// `NSViewRepresentable` cannot read `@Environment` for an AppKit window it
    /// creates itself, and multiplying anything inline is the mistake
    /// `ZoomSourceGatingTests` exists to catch.
    let interfaceMetrics: InterfaceMetrics

    /// The find/replace bar's state. Window-scoped and owned by `PisakaApp` so
    /// the pattern and toggles survive a tab switch; the coordinator's
    /// `EditorSearchController` registers itself as its executor on attach.
    /// Defaults to a fresh state so a default-constructed view (previews/tests)
    /// still compiles.
    @ObservedObject var search: EditorSearchState = EditorSearchState()

    /// Pending "select this range" request from the Find in Files window. Also
    /// window-scoped and owned by `PisakaApp`, because activating a result may
    /// *open* the file — so the request is recorded before the editor that will
    /// show it exists. Consumed once, by token, in `updateNSView`. Defaults to a
    /// fresh state so a default-constructed view (previews/tests) still compiles.
    @ObservedObject var reveal: EditorRevealState = EditorRevealState()

    /// Keeps the shown file's symbols current: an immediate re-index when the tab
    /// is opened or switched to, a debounced one while typing. Owned by
    /// `PisakaApp`; not observed here (it publishes nothing — see `ContentView`'s
    /// note on why the index model must stay off this view's update path).
    /// Defaults to a controller over a fresh, never-walked index so a
    /// default-constructed view (previews/tests) still compiles.
    var symbolIndex: SymbolIndexController = SymbolIndexController(model: SymbolIndexModel())

    /// What `.editorconfig` says about the shown file: the configured half of the
    /// indentation unit Enter appends and of what Tab inserts (`IndentUnitRule`
    /// merges it with the content inference). Owned by `PisakaApp`, which is also
    /// the only thing that invalidates it; not observed here (it publishes
    /// nothing).
    ///
    /// Undefaulted, unlike `symbolIndex` — a default would be a second live disk
    /// reader for a view nobody constructs, and this property is a *plain value*
    /// held for the coordinator's synchronous key handlers, not a second observed
    /// object (`completionEnabled`'s note on keeping this view off any
    /// per-keystroke update path).
    var editorConfig: EditorConfigModel

    /// The one funnel every macOS save passes through before it writes. Owned by
    /// `PisakaApp` (it has to outlive every editor — the saves it serves are
    /// menu commands and autosave ticks, not editor events); this view only
    /// *attaches* it, from `makeNSView`, so a rewrite of the shown buffer can go
    /// through the live text view instead of behind it. Not observed (it
    /// publishes nothing); optional so a default-constructed view
    /// (previews/tests) compiles and simply transforms nothing.
    var saveTransform: SaveTransformController?

    /// Schedules the diagnostics channel's push sync (D30) beside the index
    /// re-index above, from the *same* three triggers — so both readers of a
    /// buffer are told about every change in the same order and can never
    /// disagree about which buffer is current. Owned by `PisakaApp`; not observed
    /// (it publishes nothing); optional so a default-constructed view
    /// (previews/tests) compiles and simply syncs nothing.
    var lspSync: LSPDocumentSyncController?

    /// The diagnostics channel's observable model: the store the squiggles are
    /// painted from. Owned by `PisakaApp` like `symbolIndex`; held as a plain
    /// value here and **observed by the coordinator, not by this view** — a
    /// model change must repaint underlines inside the existing AppKit view
    /// without a SwiftUI re-render of the editor (`completionEnabled`'s note on
    /// why this view must not gain a per-keystroke invalidation path; a
    /// diagnostics shift lands on exactly those keystrokes). Defaults to `nil`
    /// so a default-constructed view (previews/tests) compiles.
    var diagnostics: DiagnosticsModel?

    /// Open the file a chosen definition lives in and select the declaration's
    /// name range. Wired to the very `PisakaApp.activateSearchMatch(url:range:)`
    /// a Find in Files result goes through — opening the tab is the app's job, and
    /// a definition in the *current* file deliberately takes the same route so the
    /// caret move and the scroll are one code path. Default no-op so a
    /// default-constructed view (previews/tests) still compiles.
    var onGoToDefinition: (URL, NSRange) -> Void = { _, _ in }

    /// Show a definition that lives *outside* the opened folder — an SDK
    /// interface, a dependency checkout — in the separate read-only source viewer
    /// window instead of opening it as a tab (D3). Wired to
    /// `PisakaApp.viewDefinitionOutsideProject(url:range:)`, which beeps when the
    /// file cannot be read. Default no-op so a default-constructed view
    /// (previews/tests) still compiles.
    ///
    /// A separate closure rather than a flag on `onGoToDefinition`, because the two
    /// destinations are different app-level operations: one opens a tab through
    /// `WorkspaceModel`, the other opens a window that has no model behind it at
    /// all. Only the LSP provider ever marks a candidate out-of-root, so on the
    /// tree-sitter path this is never called.
    var onViewDefinitionOutsideProject: (URL, NSRange) -> Void = { _, _ in }

    /// Ask "where is this name used" about the identifier the caret (or a
    /// right-click) resolved. Wired to `PisakaApp`, which owns the
    /// `FindUsagesModel`, shows the bottom dock's Usages panel and runs the
    /// query — none of which is this view's to do. Default no-op so a
    /// default-constructed view (previews/tests) still compiles.
    var onFindUsages: (UsagesRequest) -> Void = { _ in }

    /// Ask to rename the identifier the caret (or a right-click) resolved.
    ///
    /// Carries a `UsagesRequest` rather than a `RenameRequest` on purpose: the
    /// *read* half of a rename asks exactly the four things a usages query does
    /// — the name, the file, the offset and the live buffer — and the new name
    /// does not exist yet at this point. It is the app that puts up the dialog
    /// and builds the `RenameRequest` from the answer, because the dialog, the
    /// writer gate and the Local History capture are all its. Default no-op so a
    /// default-constructed view (previews/tests) still compiles.
    var onRenameSymbol: (UsagesRequest) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// The shared monospaced editor font at the current size.
    private func editorFont() -> NSFont {
        .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        // Build the text view explicitly as TextKit 1. Neon's `TextViewHighlighter`
        // supports both TextKit systems, but a fixed, known-good configuration
        // (matching Neon's own example) avoids any per-OS ambiguity about which
        // layout system `NSTextView.scrollableTextView()` would hand back.
        // `EditorTextView` adds only the Cmd+D duplicate key on top of
        // `NSTextView` (the zoom gesture now arrives at `ZoomController`'s
        // monitor, not at a `scrollWheel` override here).
        let textView = EditorTextView(usingTextLayoutManager: false)
        // Swap in the bracket-overlay layout manager before anything else is
        // wired up. `replaceLayoutManager` is the documented API for exactly this
        // job: it moves the container (and through it the text storage and the
        // text view) onto the new manager, preserving the whole
        // storage↔container↔view graph — so not one other line of this method
        // changes. In particular `allowsNonContiguousLayout` below is set through
        // `textView.layoutManager`, i.e. *after* this swap, so it lands on the new
        // manager; keep that ordering when editing.
        //
        // Everything downstream resolves the layout manager dynamically rather
        // than caching one: the gutter reads `textView.layoutManager` per draw and
        // Neon's `LayoutManagerSystemInterface` resolves it at write time, so both
        // find the subclass and the overlay override sees every style write.
        let overlayLayoutManager = BracketOverlayLayoutManager()
        textView.textContainer?.replaceLayoutManager(overlayLayoutManager)
        assert(textView.layoutManager === overlayLayoutManager, "bracket overlay layout manager did not install")
        // Cmd+D → the coordinator's duplicate handler. The coordinator is captured
        // *weakly*: it holds this text view only weakly itself, but Neon's
        // `TextViewHighlighter` (which the coordinator owns strongly) keeps a
        // strong `textView` reference, so a strong capture here would close the
        // cycle coordinator → highlighter → text view → closure → coordinator and
        // leak the whole editor (text storage, per-file undo managers, tree-sitter
        // state) on every teardown. A deallocated coordinator yields `false`,
        // which `performKeyEquivalent` returns as "key not handled".
        textView.onDuplicate = { [weak coordinator = context.coordinator] tv in
            coordinator?.duplicateSelection(in: tv) ?? false
        }
        // Cmd+/ → the coordinator's toggle-comment handler. Weakly captured for
        // the same retain-cycle reason as the closures above.
        textView.onToggleComment = { [weak coordinator = context.coordinator] tv in
            coordinator?.toggleComment(in: tv)
        }
        // Esc → close an open search bar. Captured weakly for the same
        // retain-cycle reason as `onDuplicate` above; a deallocated coordinator
        // (or a bar that isn't open) yields `false`, which `cancelOperation`
        // turns back into the stock behavior.
        textView.onCancelSearch = { [weak coordinator = context.coordinator] in
            coordinator?.closeSearchBar() ?? false
        }
        // ⌘-click / ⌃⌘J → the coordinator's go-to-definition entry point. Weakly
        // captured for the same retain-cycle reason as the two closures above; a
        // deallocated coordinator simply navigates nowhere.
        textView.onGoToDefinition = { [weak coordinator = context.coordinator] tv, offset in
            coordinator?.goToDefinition(in: tv, at: offset)
        }
        // ⌃⌘U / the context menu → the coordinator's find-usages entry point.
        // Weakly captured for the same retain-cycle reason as the closures
        // above; a deallocated coordinator simply asks nothing.
        textView.onFindUsages = { [weak coordinator = context.coordinator] tv, offset in
            coordinator?.findUsages(in: tv, at: offset)
        }
        // ⌃⌘R / the context menu → the coordinator's rename entry point, which
        // resolves the word and hands it to the app; the dialog and the write
        // are the app's (see `onRenameSymbol`).
        textView.onRenameSymbol = { [weak coordinator = context.coordinator] tv, offset in
            coordinator?.renameSymbol(in: tv, at: offset)
        }
        // ⌃Space (and the Find menu's "Complete") → an undebounced candidate
        // refresh, which opens the popup itself once the provider answers. Weakly
        // captured for the same retain-cycle reason as the closures above.
        textView.onRequestCompletions = { [weak coordinator = context.coordinator] in
            coordinator?.requestCompletions()
        }
        // Intercept completion-popup keys. Return and Tab commit; arrows navigate.
        textView.onCompletionKey = { [weak coordinator = context.coordinator] event in
            coordinator?.handleCompletionKey(event) ?? false
        }
        textView.onCancelCompletion = { [weak coordinator = context.coordinator] in
            coordinator?.cancelCompletion() ?? false
        }

        // The pointer resting over an identifier asks the intelligence seam what
        // it is (D25). Weakly captured for the same retain-cycle reason as the
        // closures above; a deallocated coordinator simply shows no popover.
        textView.onPointerMoved = { [weak coordinator = context.coordinator] tv, point in
            coordinator?.pointerMoved(to: point, in: tv)
        }
        textView.onPointerExited = { [weak coordinator = context.coordinator] in
            coordinator?.pointerExitedEditor()
        }

        // `CodeScrollView`, not `NSScrollView`: the text view below is
        // content-sized, so the pane's empty region belongs to no conforming view
        // and a zoom aimed there would grow the chrome instead of the code.
        let scrollView = CodeScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView

        let maxSize = CGFloat.greatestFiniteMagnitude
        textView.minSize = .zero
        textView.maxSize = NSSize(width: maxSize, height: maxSize)
        textView.isVerticallyResizable = true
        // Disable soft-wrapping: long lines extend horizontally (with a horizontal
        // scroller) instead of wrapping onto multiple visual rows. The minimap's
        // overview is logical-line indexed (one row per source line, x = column)
        // and its vertical mapping assumes a uniform line height. If the editor
        // wrapped, a single logical line would occupy several visual rows, so the
        // document's real height (the `documentToMinimap` ratio's divisor) would
        // exceed `lineCount * editorLineHeight` and the minimap's token rows would
        // drift out of alignment with both the document and the viewport rectangle.
        // Keeping the editor unwrapped makes document space == logical-line space,
        // so the minimap stays exactly aligned without forcing full TextKit layout
        // to discover per-line wrapped positions (which would defeat the
        // non-contiguous layout used to stay responsive on large files).
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: maxSize, height: maxSize)
        // Non-contiguous layout keeps highlighting responsive on large files
        // under TextKit 1 (the highlighter only styles the visible range).
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = editorFont()
        context.coordinator.appliedFontSize = CGFloat(fontSize)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        let ruler = makeRuler(scrollView: scrollView, textView: textView, coordinator: context.coordinator)

        let minimap = MinimapView()
        let container = EditorContainerView(scrollView: scrollView, minimap: minimap)

        let language = SyntaxLanguage(forFileName: fileName)
        context.coordinator.fileID = fileID
        // Do *not* pre-assign `coordinator.language` here: `updateHighlighter`
        // compares the incoming language against the stored one to decide whether
        // to (re)build the highlighter, and sets `coordinator.language` itself.
        // Pre-assigning would make that comparison always equal, so the initial
        // highlighter would never be built (plain text until a tab switch).
        context.coordinator.updateHighlighter(
            for: textView,
            language: language,
            contentReplaced: false
        )
        // Wire the editor/minimap together: observe scroll and frame changes to
        // keep the minimap's viewport rectangle and geometry in sync, route the
        // minimap's drag back into the editor's clip view, and recompute geometry
        // when the container lays out (resize).
        context.coordinator.attachMinimap(
            scrollView: scrollView,
            textView: textView,
            minimap: minimap
        )
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.refreshGeometry()
        }
        // Seed the minimap's overview from the initial contents.
        context.coordinator.updateMinimap(
            text: text,
            language: language,
            fileID: fileID,
            immediate: true
        )
        // Wire the bracket overlays: observe the text storage for edits and seed
        // the first scan from the initial contents. The seed cannot come from the
        // edit observer — the `textView.string` assignment above posted its
        // notification before this observer existed (the same reason the gutter
        // scans once in its own `init`).
        context.coordinator.attachBracketHighlighting(textView: textView)
        context.coordinator.updateBrackets(text: text, fileID: fileID, immediate: true)
        // Wire code folding: the controller holds the text view and the gutter
        // weakly, and the first question is asked at the bottom of this method —
        // after the index controller and the configuration model are bound, since
        // the source closure reads both.
        context.coordinator.attachFolding(textView: textView, ruler: ruler)
        // Wire the find/replace bar: bind the controller to this text view and
        // register it as the state's executor, then run whatever the bar already
        // holds (it is window-scoped, so it may have been left open on the
        // previous tab with a pattern typed).
        context.coordinator.attachSearch(textView: textView, state: search)
        context.coordinator.updateSearch(state: search, force: true)
        // Bind the completion popup's candidate source. Nothing is computed here:
        // the list is asked for on the first keystroke (or an explicit ⌃Space),
        // never on a tab that has only been looked at.
        context.coordinator.attachCompletion(textView: textView)
        // ...and whether it may offer anything at all. Applied here as well as in
        // `updateNSView` so an editor built while the preference is already off
        // never asks the provider even once.
        context.coordinator.setCompletionEnabled(completionEnabled)
        // Bind the hover popover. Nothing is asked here either: the first request
        // is made once the pointer has rested over an identifier for
        // `HoverContent.dwellDelay`.
        context.coordinator.attachHover(textView: textView)
        context.coordinator.syncHover(
            codeFontSize: CGFloat(fontSize),
            metrics: interfaceMetrics
        )
        // Record which file the gutter would annotate (enabling/disabling its menu
        // item). Nothing loads here: annotate starts off for every tab and is only
        // turned on from the context menu.
        context.coordinator.syncBlame(
            fileURL: fileURL,
            diskRevision: diskRevision,
            contentReplaced: true
        )
        // Index the file being shown from its *buffer* text, at once: the tab the
        // user is looking at must have symbols before they finish reading it, and
        // the disk walk may not have reached this file yet (or may be gone
        // entirely, for a file outside the opened folder).
        context.coordinator.symbolIndex = symbolIndex
        context.coordinator.editorConfig = editorConfig
        context.coordinator.lspSync = lspSync
        // Whether the indentation-level blocks are painted. Deliberately *after*
        // the configuration model is bound: this is the call that derives the
        // widths for the first time, and it must be able to ask what
        // `.editorconfig` says rather than falling back to the content inference
        // for one update. A `false` here means the derivation never runs at all
        // for an editor built with the preference already off.
        context.coordinator.setIndentLevelHighlighting(enabled: indentLevelHighlightingEnabled)
        // Bind the save funnel to this editor. It holds both references weakly, so
        // a torn-down editor leaves it with nothing on screen to reach — which is
        // the ordinary state for every background tab, not a degraded one. With
        // more than one window open the last editor built wins, exactly as the
        // other app-owned, editor-attached singletons behave; a buffer shown in
        // the other window is then rewritten through the model instead.
        saveTransform?.attach(textView: textView, editor: context.coordinator)
        // Bind the diagnostics store and start observing it (one subscription for
        // the coordinator's lifetime; re-attachment is an identity-checked no-op).
        context.coordinator.attachDiagnostics(model: diagnostics)
        context.coordinator.navigateToDefinition = onGoToDefinition
        context.coordinator.viewDefinitionOutsideProject = onViewDefinitionOutsideProject
        context.coordinator.requestUsages = onFindUsages
        context.coordinator.requestRename = onRenameSymbol
        // Seed the retarget comparison so the first update after creation does
        // not read as one: the immediate sync below already happened here.
        context.coordinator.syncedProjectRoot = projectRoot
        context.coordinator.reindexSymbols(
            text: text,
            language: language,
            immediate: true
        )
        // Ask where this file's blocks are, at once: the tab the user is looking
        // at must have its chevrons before they reach for one. Deliberately after
        // the index controller and the configuration model are bound — the fold
        // source reads the provider through the first and the indentation widths
        // through the second.
        context.coordinator.syncFolds(text: text, immediate: true)
        context.coordinator.syncFoldInputs(alreadyAsked: true)
        // Seed the underlines from whatever the store already holds (a fresh
        // sync has nothing yet, so this is usually a no-op).
        context.coordinator.refreshDiagnosticOverlays()
        return container
    }

    /// Build the line-number gutter and wire the three things it reports back:
    /// the blame column's menu item, a chevron click, and the pre/post line-start
    /// tables every incremental reader shifts across an edit.
    ///
    /// Split out of `makeNSView` so that method stays inside the style limit; the
    /// ordering it depended on is preserved by where it is called from — after
    /// the buffer is populated, before the minimap and the overlays are wired.
    private func makeRuler(
        scrollView: NSScrollView,
        textView: NSTextView,
        coordinator: Coordinator
    ) -> LineNumberRulerView {
        // Built after the buffer is populated (the caller's ordering) and does an
        // initial full scan in its `init`: the `string` assignment there did post
        // a text-storage edit notification, but the ruler did not exist yet to
        // observe it, so it seeds its own line count here. From now on the ruler
        // observes the text view (scroll/resize/edit) to keep numbers in sync; it
        // draws right-aligned numbers in the editor's monospaced font following
        // the system appearance.
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        // The ruler maintains a synchronous document line count; the minimap
        // geometry scales from it (not the async minimap model) so wheel scrolling
        // works for plain/unsupported files and isn't briefly wrong on tab switch.
        coordinator.lineNumberRuler = ruler
        // Wire the gutter's git-blame column. The coordinator is captured
        // *weakly* for the same retain-cycle reason as `onDuplicate`/
        // `onCancelSearch` in `makeNSView`: the ruler is owned by the scroll view,
        // which the coordinator (through Neon's highlighter) is reachable from, so
        // a strong capture here would keep the whole editor alive past teardown.
        coordinator.attachBlame(ruler: ruler)
        ruler.onToggleAnnotate = { [weak coordinator] in
            coordinator?.toggleBlame()
        }
        // A click on a gutter chevron folds or unfolds that candidate. Captured
        // *weakly* for `onToggleAnnotate`'s retain-cycle reason.
        ruler.onToggleFold = { [weak coordinator] region in
            coordinator?.toggleFold(region)
        }
        // The diagnostics shift and the fold shift both consume the ruler's
        // pre/post line-start tables. Captured *weakly* for `onToggleAnnotate`'s
        // reason.
        ruler.onEdit = { [weak coordinator] previous, new, edited, delta in
            coordinator?.bufferEdited(
                previousLineStarts: previous,
                newLineStarts: new,
                editedRange: edited,
                changeInLength: delta
            )
        }
        return ruler
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        // Keep the binding the coordinator writes to current across view updates.
        context.coordinator.text = $text

        // Re-apply the shared font when its size changed (the Stepper or a
        // Cmd+scroll). Setting `NSTextView.font` re-styles the whole buffer; the
        // tree-sitter colors (temporary attributes on the layout manager) survive.
        // The gutter re-derives its own font from the text view per draw, so a
        // thickness recompute + redraw re-syncs it; the minimap geometry depends on
        // the (now-changed) document height, so refresh it too. (The text view's
        // frame-change notification also drives `refreshGeometry`, but call it
        // explicitly so the viewport rectangle is correct on the same turn.)
        let desiredFontSize = CGFloat(fontSize)
        if context.coordinator.appliedFontSize != desiredFontSize {
            context.coordinator.appliedFontSize = desiredFontSize
            textView.font = editorFont()
            context.coordinator.lineNumberRuler?.editorFontChanged()
            context.coordinator.refreshGeometry()
            // A font change re-lays out the whole buffer, so a popover anchored in
            // *screen* coordinates now points at a different line and is drawn at
            // the previous code size. This is the one dismissal the pointer cannot
            // stand in for: ⌘+/⌘− involves no mouse movement at all, and the
            // ⌘-scroll path is consumed by `ZoomController`'s event monitor, so the
            // clip view never posts the bounds change that would otherwise catch it.
            context.coordinator.dismissHover()
            context.coordinator.cancelCompletion()
        }

        // Re-apply the completion preference. Unconditional because the controller
        // itself ignores an unchanged value; a *change* to `false` additionally
        // cancels whatever was pending and dismisses a popup that is on screen,
        // which is why this runs before the buffer/blame/index reconciliation
        // below rather than after it.
        context.coordinator.setCompletionEnabled(completionEnabled)

        // Keep the popover's two font inputs current. Cheap and unconditional:
        // the controller only stores them, and they are read when the *next*
        // answer is drawn.
        context.coordinator.syncHover(
            codeFontSize: CGFloat(fontSize),
            metrics: interfaceMetrics
        )
        context.coordinator.syncCompletionAppearance(
            codeFontSize: CGFloat(fontSize),
            metrics: interfaceMetrics
        )

        let previousFileID = context.coordinator.fileID
        let switchedFile = previousFileID != fileID
        context.coordinator.fileID = fileID

        // Same tab, new coordinates. Two retargets keep the file id and the text
        // while invalidating every sync the buffer ever did:
        //
        // - A **URL change** — Save As (an untitled buffer's first path) or a
        //   project-tree rename/move (`applyRenamePlan`). The rename path has
        //   already `didClose`d the old URL (`forgetIndexedBuffer`, which also
        //   cleared that document's diagnostics via D33), and nothing else would
        //   ever tell the server about the new one: a push-only server sits
        //   silent until asked, and the push channel's triggers are exactly the
        //   ones this branch funnels.
        // - A **root change** — the first Open Folder of a run carrying tabs.
        //   Those buffers were never synced at all (every earlier trigger ran
        //   with no root, where `prepare` answers `nil` by design), their views
        //   persist unchanged across the open, and neither of the two triggers
        //   above fires for them.
        let retargetedBuffer = context.coordinator.fileURL != fileURL
            || context.coordinator.syncedProjectRoot != projectRoot
        // A folder switch is a different set of files, so the folds remembered
        // for the previous project's are dropped wholesale — the one place the
        // per-run fold memory is cleared, and the reason it needs no prune on
        // tab close (a fold is a statement about a file, not about a tab).
        if context.coordinator.syncedProjectRoot != projectRoot {
            context.coordinator.forgetAllFolds()
        }
        context.coordinator.syncedProjectRoot = projectRoot

        // Remember where the *outgoing* tab was sitting. Ordering is load-bearing
        // twice over, which is why this is the first thing a switch does:
        //
        // - It must run before the `textView.string = text` swap below. One text
        //   view serves every tab, so once the incoming file's contents are
        //   installed the previous file's selection and scroll offset are gone —
        //   there is nothing left to read.
        // - It must run before `prunePerFileState(keeping:)` on purpose, not by
        //   accident: closing the displayed tab records its position and the prune
        //   immediately discards it again (the id is no longer in `openFileIDs`),
        //   so a closed tab retains nothing and reopening the file starts at the
        //   top. Recording afterwards would leave that entry alive for the run.
        if switchedFile, let previousFileID {
            context.coordinator.recordViewport(for: previousFileID)
            // ...and what was folded in it, for the same reason and at the same
            // moment: one fold controller serves every tab, so this is the last
            // point at which the outgoing file's state is still the live one.
            // Unlike the viewport, this survives the prune below — closing a tab
            // must not discard a fold the user made on purpose.
            context.coordinator.recordFolds()
        }

        // Did this file's buffer get replaced from outside the editor since this
        // coordinator last showed it? A replacement of the *displayed* tab is
        // caught by the `!switchedFile` test below, but Replace All applies to
        // every matching open tab: a background tab gets no update of its own, so
        // by the time the user switches to it the swap looks exactly like an
        // ordinary tab switch. The token is what tells them apart. A file being
        // shown for the first time has no recorded value and so is never treated
        // as replaced (there is no stack to drop yet).
        let externallyReplaced = context.coordinator.noteExternalTextRevision(
            externalTextRevision,
            for: fileID
        )

        // Drop the per-file state of files that are no longer open so closed tabs
        // don't retain their undo history (and text snapshots) — or their
        // remembered viewport — indefinitely.
        context.coordinator.prunePerFileState(keeping: openFileIDs)

        let language = SyntaxLanguage(forFileName: fileName)

        // Replace the contents when the file changed, or when the model's text
        // diverged from the view (e.g. an external save/load). Avoid clobbering
        // the user's in-progress edit and cursor when they match.
        //
        // Assigning `string` directly is not itself an undoable action, so this
        // swap does not pollute the incoming file's undo history. The text view
        // is reused across tabs, but the coordinator hands it a *per-file* undo
        // manager (see `Coordinator.undoManager(for:)`), so each tab keeps its
        // own undo/redo stack across switches and one file's edits can never be
        // undone onto another's contents.
        let contentReplaced = switchedFile || textView.string != text
        if contentReplaced {
            // A *plain tab switch* (the incoming file's own text, untouched while
            // it sat off screen) is not D32's wholesale replacement: the store is
            // keyed by URL precisely so a background document's set survives the
            // view swap, and the set is still true text-for-text — nothing was
            // typed into that buffer while it sat off screen, so there is
            // nothing to shift and nothing to clear. Dropping it here would
            // blank the file for as long as it takes the switch-back sync to be
            // answered, and for a server that answers a re-published identical
            // document with nothing at all, for as long as it takes someone to
            // edit it again. The swap below still posts one full-range
            // edit — suppressed in *every* case via `isSwappingBuffer`: shifting
            // either document's set across swap geometry would drop entries, and
            // the recorded URL still names the *outgoing* file here, so the
            // shift would target the wrong document outright. A genuine
            // replacement — the displayed buffer swapped, or this file rewritten
            // off screen by Replace All / reload / merge apply (what
            // `externallyReplaced` reports) — clears as D32 says.
            let diagnosticsSurvive = switchedFile && !externallyReplaced
            context.coordinator.isSwappingBuffer = true
            defer { context.coordinator.isSwappingBuffer = false }
            // Detach the active highlighter *before* swapping the buffer. Neon
            // installs itself as the text storage's delegate and schedules
            // highlighting asynchronously; if the outgoing grammar observed this
            // wholesale replacement it could repaint the incoming file with the
            // old grammar after the new highlighter is installed (a stale
            // cross-language race). Tearing it down first means the old grammar
            // never sees the new text; `updateHighlighter` rebuilds below.
            context.coordinator.detachHighlighter(from: textView)
            // Drop the blame column *before* the swap. The assignment below posts a
            // single full-range edit notification, which the ruler would otherwise
            // run `BlameShift` over — shifting the annotations across a
            // whole-document replacement. The `syncBlame` after this block reloads
            // for the incoming contents.
            context.coordinator.beginBlameBufferSwap()
            // Drop the replaced document's diagnostics ahead of a wholesale
            // replacement, at the same point as the blame column's (D32).
            // Skipped for the plain-switch case above. The cleared document is
            // the one whose *text* was replaced — the view's `fileURL` names
            // exactly that: the incoming file on a switch (rewritten off screen
            // by Replace All / reload / merge apply; the recorded URL still
            // names the outgoing one until `syncBlame` re-records), and this
            // file itself when it is displayed.
            if !diagnosticsSurvive {
                context.coordinator.beginDiagnosticsBufferSwap(clearing: fileURL)
            }
            // Whatever the *store* does with the outgoing set, the *paint* does
            // not survive the assignment below — TextKit drops every temporary
            // attribute over the replaced characters — so the overlay's cache
            // has to stop claiming it does. Unconditional, unlike the clear
            // above: without it the incoming document renders unpainted
            // whenever its merged runs happen to equal the outgoing document's,
            // because `setDiagnosticRuns` treats an unchanged set as a no-op.
            context.coordinator.invalidateDiagnosticPaint()
            // Assigning `string` replaces the whole buffer, which the text storage
            // posts as a single `didProcessEditingNotification` (edited range = the
            // full new length). The line-number ruler observes that notification
            // and rebuilds its offset cache + gutter width from it, so the gutter
            // re-seeds for the incoming file with no second explicit scan. (Two
            // files that share both content and height need no re-seed: identical
            // content yields identical line numbers, so the cache is already right.)
            textView.string = text

            // A wholesale swap of the *same* file's buffer invalidates that
            // file's undo stack: assigning `string` registers no undo action of
            // its own, yet every action already recorded names a range in the
            // pre-swap text. Undoing one afterwards would replay an unrelated
            // older edit at coordinates the new contents no longer share —
            // silently corrupting the buffer when the range still fits, and
            // raising an out-of-range exception from the text storage when the
            // new text is shorter. So drop the stack whenever the contents were
            // replaced out from under it: a project-wide Replace All landing in
            // an open tab (`ProjectSearchModel.replaceAll` → `applyBufferText`),
            // a post-revert `reloadFromDisk`, or a merge apply. A *tab switch*
            // is excluded — there the incoming file's own manager is installed
            // alongside its own contents, which is exactly the pairing the
            // per-file managers exist to preserve — *unless* that file's buffer
            // was replaced while it sat off screen, which `externallyReplaced`
            // reports: all three of those replacements reach tabs other than the
            // displayed one, and the stale stack would otherwise survive the
            // switch and be replayed against contents it never described.
            if !switchedFile || externallyReplaced {
                textView.undoManager?.removeAllActions()
                // The remembered viewport goes stale for exactly the same reason
                // and on exactly the same signal: a Replace All, a post-revert
                // `reloadFromDisk` or a merge apply rewrote this file while it sat
                // off screen, so the recorded selection and anchor name characters
                // the incoming text never had. Drop it; the restore below then
                // finds nothing and puts the tab at the top of the file, the same
                // state a first visit gets.
                if externallyReplaced {
                    context.coordinator.forgetViewport(for: fileID)
                    // The remembered *folds* go stale on exactly the same signal
                    // and for exactly the same reason: a Replace All, a
                    // post-revert `reloadFromDisk`, a Local History restore or a
                    // rename retarget rewrote this file, so the recorded regions
                    // name text it no longer has. The URL is the view's — the
                    // incoming file's — because the coordinator's still names the
                    // outgoing one until `syncBlame` below re-records it.
                    context.coordinator.forgetFolds(url: fileURL, fileID: fileID)
                }
            }
        }

        // Build/swap/detach the highlighter to match the selected file's
        // language. When the contents were replaced, the previous highlighter was
        // already detached above, so this rebuilds from the new buffer.
        //
        // `updateHighlighter` owns the `coordinator.language` comparison/assignment
        // (see `makeNSView`); pre-assigning it here would hide a pure language
        // change — e.g. a "Save As" to a new extension that doesn't replace the
        // buffer — so the new grammar would never attach.
        context.coordinator.updateHighlighter(
            for: textView,
            language: language,
            contentReplaced: contentReplaced
        )

        // Rebuild the minimap overview for the (possibly new) file/language. A
        // tab/language switch refreshes at once; otherwise the tokenizer's cache
        // makes an unchanged (file, text, language) a no-op.
        context.coordinator.updateMinimap(
            text: textView.string,
            language: language,
            fileID: fileID,
            immediate: switchedFile || contentReplaced
        )

        // Same for the bracket overlays: a tab switch / buffer swap rescans at
        // once (the debounce would otherwise leave the previous file's colors on
        // screen), while an unchanged buffer is a no-op through the cache key.
        context.coordinator.updateBrackets(
            text: textView.string,
            fileID: fileID,
            immediate: switchedFile || contentReplaced
        )

        // Re-run the find bar. A tab switch or a wholesale buffer swap forces it
        // (the pattern is unchanged but its matches are not); otherwise the
        // controller compares the query against the one it last applied, so an
        // ordinary keystroke-driven update is a no-op here — the text-edit path
        // (`bracketTextStorageDidProcessEditing`) is what re-runs on edits.
        context.coordinator.updateSearch(
            state: search,
            force: switchedFile || contentReplaced
        )

        // Reconcile the gutter's blame column. Deliberately *after* the buffer swap
        // above: the ruler sizes the installed array to its line count, which the
        // swap's edit notification has just rebuilt. A reload is issued only for a
        // file annotate is on for, and only when the shown file changed, its buffer
        // was replaced, or its disk revision moved (a save/autosave/revert/checkout
        // — exactly when a worktree blame goes stale).
        context.coordinator.syncBlame(
            fileURL: fileURL,
            diskRevision: diskRevision,
            contentReplaced: contentReplaced
        )

        // Re-index the shown file's symbols. On a tab switch, a wholesale
        // buffer swap, or a retarget (new URL or new root under an unchanged
        // buffer — see `retargetedBuffer`), and then immediately: ordinary
        // keystrokes are covered by `textDidChange` (debounced), so scheduling
        // here as well would re-parse the file twice per settled burst of
        // typing.
        context.coordinator.symbolIndex = symbolIndex
        context.coordinator.editorConfig = editorConfig
        context.coordinator.lspSync = lspSync
        // Re-apply the indentation-level preference. Unconditional, and cheap: the
        // coordinator re-derives the widths only when the preference has just been
        // switched on, the configuration model's revision moved, or the shown file
        // changed — never on an ordinary keystroke-driven update, whose content
        // half rides the debounced text path instead.
        //
        // Deliberately here rather than beside the completion preference above,
        // for `refreshDiagnosticOverlays`' reason and the configuration model's:
        // the derivation resolves `.editorconfig` against `syncBlame`'s recorded
        // URL through the model bound on the line above, so it has to run after
        // both. The bracket rescan a tab switch forces has already recomputed once
        // by now, against the outgoing file — the widths cache carries the URL it
        // used, so this call is what corrects it, inside the same update.
        context.coordinator.setIndentLevelHighlighting(enabled: indentLevelHighlightingEnabled)
        // Keep the diagnostics binding current (an identity-checked no-op when
        // unchanged, like `updateHighlighter`'s language comparison).
        context.coordinator.attachDiagnostics(model: diagnostics)
        // Keep the navigation closure current: it captures `PisakaApp`'s state, so
        // a stale one from a previous update would open tabs through a torn-down
        // scene's workspace. The out-of-root destination is kept current for the
        // same reason.
        context.coordinator.navigateToDefinition = onGoToDefinition
        context.coordinator.viewDefinitionOutsideProject = onViewDefinitionOutsideProject
        context.coordinator.requestUsages = onFindUsages
        context.coordinator.requestRename = onRenameSymbol
        if switchedFile || contentReplaced || retargetedBuffer {
            context.coordinator.reindexSymbols(
                text: textView.string,
                language: language,
                immediate: true
            )
            // The candidates computed for the outgoing buffer answer a file that
            // is no longer on screen (see `clearCompletions`).
            context.coordinator.clearCompletions()
            // ...and so does a popover: it describes an offset in a buffer this
            // very update has replaced.
            context.coordinator.dismissHover()
            // Paint the incoming document's squiggles at once (the model
            // observation covers ordinary changes; a switch must not wait for
            // one). Deliberately after `syncBlame` above, so the coordinator's
            // URL already names the incoming file.
            context.coordinator.refreshDiagnosticOverlays()
            // Restore what was folded in the incoming file and ask for its
            // chevrons at once — waiting out the debounce would leave the
            // previous file's on screen. After `syncBlame` for its reason: the
            // memory is keyed by the file, which the coordinator's URL now names.
            context.coordinator.syncFolds(text: textView.string, immediate: true)
        }
        // A language change or an `.editorconfig` edit moves where the blocks
        // are. Unconditional and cheap: the coordinator re-asks only when one of
        // the two actually moved, and the branch above has already asked for a
        // switch (which this then records as the new baseline rather than
        // re-asking for).
        context.coordinator.syncFoldInputs(
            alreadyAsked: switchedFile || contentReplaced || retargetedBuffer
        )

        // Put the incoming tab back where it was last left. Deliberately last, and
        // only on a tab switch:
        //
        // - After the buffer swap for the same reason the reveal is, and after the
        //   minimap/bracket/search/blame reconciliation above so the bounds
        //   notification the scroll posts refreshes geometry that already describes
        //   the incoming file rather than the outgoing one.
        // - Only on a *switch*: an update driven by an ordinary keystroke must
        //   leave the user's own scrolling alone.
        // - An explicit reveal outranks the memory. Activating a Find in Files
        //   result (or a go-to-definition) in an already-open background tab is a
        //   switch too, and must land on the match rather than on where the tab
        //   happened to be; `hasPendingReveal` asks the question without consuming
        //   the request, which `applyReveal` below still does.
        if switchedFile,
           !context.coordinator.hasPendingReveal(reveal.request, fileID: fileID) {
            context.coordinator.restoreViewport(for: fileID)
        }

        // Consume a pending Find in Files activation. Deliberately *after* the
        // buffer swap above: when the activation opened the file, this very update
        // is the one that installs its contents, so selecting earlier would land
        // the range in the previous tab's text.
        context.coordinator.applyReveal(reveal.request, fileID: fileID)
    }

    /// Remove the scroll/frame observers and cancel any in-flight minimap parse
    /// when the view is torn down (e.g. a tab is closed), so nothing leaks across
    /// tab switches.
    static func dismantleNSView(_ nsView: EditorContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Bridges `NSTextView` edits back into the SwiftUI binding and owns the
    /// tree-sitter highlighter for the currently shown file.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SaveTransformEditor {
        var text: Binding<String>
        var fileID: UUID?

        /// The workspace root the buffer's last immediate sync ran against
        /// (`nil` = none yet / no folder). Owned here — unlike `fileURL`, which
        /// `syncBlame` records for the blame column — because its only reader is
        /// `updateNSView`'s retarget test, and seeding it in `makeNSView` is
        /// what keeps a freshly created view from re-reading as one.
        var syncedProjectRoot: URL?

        /// The language whose highlighter is currently attached (`nil` = plain
        /// text, no highlighter). Used to decide when to rebuild on tab switch,
        /// and to feed the minimap tokenizer on in-place edits.
        var language: SyntaxLanguage?

        /// The text view, scroll view, and minimap this coordinator syncs. Held
        /// weakly: the view hierarchy owns them; the coordinator only observes.
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var minimap: MinimapView?

        /// The line-number gutter, held weakly (the scroll view owns it). Its
        /// synchronous, incrementally-maintained line count drives the minimap
        /// geometry's `contentHeight`.
        weak var lineNumberRuler: LineNumberRulerView?

        /// The editor font size currently applied to the text view, so
        /// `updateNSView` re-applies the font (and re-syncs the gutter/minimap)
        /// only when the shared size actually changed.
        var appliedFontSize: CGFloat?

        /// The minimap's own full-file tokenizer (debounced/cached). Separate
        /// from Neon's visible-range highlighter by design.
        private let tokenizer = MinimapTokenizer()

        /// The bracket overlays' owner: the cached `BracketDepthScanner` result
        /// (debounced/cached like the tokenizer) plus the caret's
        /// `BracketMatchEngine` pair, painted through
        /// `BracketOverlayLayoutManager`.
        private let bracketHighlight = BracketHighlightController()

        /// Code folding's owner: the debounced ask for this file's collapsible
        /// blocks, the folded state over them, and the per-run memory of both.
        /// Owned strongly here (it holds the text view and the gutter weakly, so
        /// there is no cycle), like the search and completion controllers.
        private let folds = FoldController()

        /// The find/replace bar's execution side: runs `TextSearchEngine` against
        /// the live buffer, paints the matches through the same overlay layout
        /// manager the brackets use, and applies the replace commands. Owned
        /// strongly here (it holds the text view and the bar's state weakly, so
        /// there is no cycle).
        private let searchController = EditorSearchController()

        /// The find bar's state, so Esc in the *editor* can close it. Held weakly
        /// (the app owns it, exactly as the controller does).
        private weak var searchBarState: EditorSearchState?

        /// The gutter's git-blame column: the per-tab on/off state and the
        /// `git blame --porcelain` loads feeding `LineNumberRulerView`.
        private let blame = BlameController()

        /// Precomputes the completion popup's candidates from the async code
        /// intelligence seam, so AppKit's synchronous completions delegate has an
        /// answer ready when it asks. Owned strongly here (it holds the text view
        /// weakly, so there is no cycle), like the search controller.
        private let completion = CompletionController()

        /// The hover popover: the pointer's dwell, the request it makes of the
        /// same intelligence seam, and the pass-through panel that draws the
        /// answer. Owned strongly here (it holds the text view weakly, so there
        /// is no cycle), like the search and completion controllers.
        private let hover = HoverController()

        /// Schedules the symbol index's re-index of the shown file. Held *weakly*,
        /// like `searchBarState`: the app owns it for its whole lifetime, and the
        /// coordinator only asks it for work. A deallocated one simply means no
        /// re-index, which is the same graceful nothing a preview gets.
        weak var symbolIndex: SymbolIndexController?

        /// Answers what `.editorconfig` says about the shown file, for the two
        /// synchronous key handlers below. Held *weakly*, like `symbolIndex`: the
        /// app owns it for its whole lifetime and this only ever asks it a
        /// question. A deallocated one means empty properties, which is exactly
        /// the "no configuration applies" answer — so the editor degrades to the
        /// content inference rather than misbehaving.
        weak var editorConfig: EditorConfigModel?

        /// Schedules the diagnostics channel's push sync for the shown file
        /// (`reindexSymbols` forwards to it beside the index calls). Held
        /// weakly for `symbolIndex`'s exact reason.
        weak var lspSync: LSPDocumentSyncController?

        /// The displayed file's URL, as last seen by `syncBlame`. Kept so the
        /// gutter's context-menu action (which passes nothing) knows *what* to
        /// blame, and so `updateNSView`'s retarget test can see a Save As or a
        /// project-tree rename/move (same tab, new path); `nil` for an untitled
        /// buffer. Readable within the type because both readers live here;
        /// still only ever *written* by `syncBlame`.
        var fileURL: URL?

        /// Fixed minimap row height per document line, in points. The proportional
        /// minimap multiplies this by the line count for `contentHeight`; the
        /// content slides rather than scaling to fit.
        private let minimapLineHeight: CGFloat = 3

        /// The active Neon highlighter. It installs itself as the text storage's
        /// delegate; replacing it (or setting it to `nil`) detaches the old one.
        private var highlighter: TextViewHighlighter?

        /// Identifies the current highlighter so a superseded one can't restyle
        /// the reused text view. Each `rebuildHighlighter` advances it; every
        /// highlighter's attribute provider captures the value it was built with
        /// and compares against the live counter (see `rebuildHighlighter`).
        private let highlighterGeneration = HighlighterGeneration()

        /// One undo manager per file. The single reused text view asks its
        /// delegate for an undo manager whenever it registers an edit; handing
        /// back a per-file instance keeps each tab's undo/redo history isolated
        /// and intact across tab switches.
        private var undoManagers: [UUID: UndoManager] = [:]

        /// Where each file was last left: the caret and the scroll anchor. Keyed
        /// by the same `fileID` as `undoManagers` and pruned on the same call —
        /// the single reused text view forgets the outgoing tab's position the
        /// moment its buffer is swapped, so this is the only thing that remembers
        /// it. App-run lifetime only; nothing is persisted.
        private var viewports = EditorViewportMemory()

        /// Guards against re-entering the change interceptors while applying a
        /// programmatic indent or auto-pair edit. `insertText(_:replacementRange:)`
        /// re-invokes `shouldChangeTextIn` synchronously, and a dedent whose
        /// replacement is a no-op (closing bracket at column 0 under an unindented
        /// opener — a zero-length range and empty replacement) would re-pass the
        /// guard and recurse until the stack overflows; an auto-pair insert/wrap/
        /// type-over would likewise re-trigger auto-pairing on its own programmatic
        /// insertion. While this is set, the interceptor lets the programmatic edit
        /// through untouched.
        private var isApplyingProgrammaticEdit = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Read once. `NSTextView.string` bridges a *mutable* `NSTextStorage`, so
            // every access materializes a fresh Swift `String` — copying the whole
            // buffer. Three reads per keystroke made typing latency scale with file
            // size on the main thread, in the one path that has to stay cheap.
            let contents = textView.string
            text.wrappedValue = contents
            // Refresh the minimap overview from the edited text (debounced and
            // cache-guarded inside the tokenizer, so this is cheap per keystroke).
            if let fileID {
                updateMinimap(
                    text: contents,
                    language: language,
                    fileID: fileID,
                    immediate: false
                )
            }
            // Keep this file's symbols in step with what is being typed, behind the
            // controller's 400 ms debounce (a re-parse per keystroke would be felt).
            reindexSymbols(text: contents, language: language, immediate: false)
            // Ask again where this file's blocks are, behind the fold
            // controller's own debounce of the same length. The candidates in
            // hand were already shifted across the edit (`bufferEdited`), so the
            // chevrons stay put in the meantime instead of blinking.
            syncFolds(text: contents, immediate: false)
            // Offer completions for the word being typed, behind the completion
            // controller's own (shorter) debounce. Its gates — a bare caret, no
            // marked text, and either two typed characters or a member position
            // (the caret sitting after `receiver.`) — mean an ordinary keystroke
            // outside an identifier costs one prefix scan and no task.
            //
            // Not while a *programmatic* edit is being applied. The commit path
            // brackets its own insertion with this flag, so the edit notification
            // the committed word fires does not schedule a fresh request for it
            // and re-open the popup a debounce later — the treadmill the iOS
            // strip avoids by clearing after an insertion. Auto-pair and the
            // indented newline take the same path and are equally not typing.
            if !isApplyingProgrammaticEdit {
                updateCompletions(explicit: false, caretMove: false)
            }
        }

        // MARK: - Completion

        /// Bind the completion popup's candidate source to this text view
        /// (`makeNSView`).
        ///
        /// The controller is additionally given the programmatic-edit flag: both
        /// of its insertion paths — the simple replacement and a plan carrying an
        /// auto-import — bracket themselves with it, so the edit notification
        /// they fire is not mistaken for typing and re-open the popup over the
        /// word just committed. Captured weakly — the coordinator owns the
        /// controller — so a torn-down editor simply leaves the flag alone,
        /// which is right because there is then no interceptor left to guard.
        func attachCompletion(textView: NSTextView) {
            completion.attach(textView: textView)
            completion.noteProgrammaticEdit = { [weak self] isApplying in
                self?.isApplyingProgrammaticEdit = isApplying
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            if let window = notification.object as? NSWindow, window === textView?.window {
                // Gated on visibility for the same reason the scroll handler is:
                // with nothing shown — the state right after a commit — this is
                // pure D4 teardown and must leave the late auto-import in
                // flight; a *visible* popup still comes down.
                if completion.isVisible {
                    completion.dismiss()
                }
            }
        }

        /// Forward the completion on/off preference to the controller
        /// (`makeNSView`/`updateNSView`).
        ///
        /// A thin forwarder rather than a stored flag here: the controller owns
        /// the state, ignores an unchanged value, and is the only thing that can
        /// act on a change — cancelling in-flight work and dismissing a live
        /// popup. Nothing in the symbol index or the LSP layer is touched.
        func setCompletionEnabled(_ enabled: Bool) {
            completion.setEnabled(enabled)
        }

        /// Forward the panel's two font inputs (`updateNSView`). Cheap and
        /// unconditional: the controller only stores them, and reads them when
        /// the next answer is presented.
        func syncCompletionAppearance(codeFontSize: CGFloat, metrics: InterfaceMetrics) {
            completion.syncAppearance(codeFontSize: codeFontSize, metrics: metrics)
        }

        /// Recompute the popup's candidates for what is being typed.
        ///
        /// The provider is re-read from the index controller on every call rather
        /// than stored: the controller hands out the model's latest snapshot, so a
        /// held reference would answer from the state a folder was opened in.
        ///
        /// `language` is the one the highlighter is attached to (`updateHighlighter`
        /// owns it), so the keywords offered are always the ones being highlighted;
        /// a plain-text buffer passes `nil` and gets none.
        ///
        /// `caretMove` marks the selection-change entry: a bare caret move may
        /// only invalidate a stale list, never ask for one — see
        /// `CompletionController.update`.
        private func updateCompletions(explicit: Bool, caretMove: Bool) {
            completion.update(
                provider: symbolIndex?.provider,
                fileURL: fileURL,
                language: language,
                explicit: explicit,
                caretMove: caretMove
            )
        }

        /// The Find menu's "Complete" (⌃Space), AppKit's stock ⌥⎋/F5 and the
        /// `complete(_:)` override: refresh the candidates *now* and let the
        /// controller open its panel once the provider answers.
        ///
        /// Deliberately not a "show whatever is cached" path: the panel only
        /// appears from `apply(…)`, behind the staleness guards, so an explicit
        /// invocation on a still-debouncing prefix waits for the fresh answer
        /// rather than flashing the previous word's list.
        func requestCompletions() {
            updateCompletions(explicit: true, caretMove: false)
        }

        /// Drop the candidate snapshot because the editor is now showing a
        /// different file (or a wholesale new buffer).
        ///
        /// The snapshot's staleness guards match it against the *text* of the
        /// partial word it was computed for, which a coincidentally identical
        /// word in the incoming file would satisfy — ranked with the wrong file
        /// as "current", so the declarations actually in view are missing or
        /// demoted. Clearing here removes the question; the iOS editor clears its
        /// strip on the same condition.
        func clearCompletions() {
            completion.reset()
        }

        func handleCompletionKey(_ event: NSEvent) -> Bool {
            guard completion.isVisible,
                  let textView = self.textView,
                  textView.isEditable,
                  !textView.hasMarkedText(),
                  event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control])
            else { return false }

            switch event.keyCode {
            case 36, 76: // Return/Enter
                return completion.commit(.insert)
            case 48: // Tab
                return completion.commit(.replace)
            case 126: // Up
                completion.moveSelection(.moveUp)
                return true
            case 125: // Down
                completion.moveSelection(.moveDown)
                return true
            default:
                return false
            }
        }

        @discardableResult
        func cancelCompletion() -> Bool {
            if completion.isVisible {
                completion.dismiss()
                return true
            }
            return false
        }

        // MARK: - Hover

        /// Bind the hover popover to this text view (`makeNSView`).
        ///
        /// The source closure is what keeps the request honest across a folder
        /// switch: the provider, the file URL and the index's project token are
        /// all read *at the moment a question is asked* rather than captured now,
        /// exactly as `updateCompletions` re-reads the provider per call. Captured
        /// weakly — the coordinator owns the controller — so a torn-down editor
        /// answers "nothing to ask", which is the same graceful nothing a preview
        /// gets.
        func attachHover(textView: NSTextView) {
            hover.attach(textView: textView)
            hover.source = { [weak self] in
                guard let self, let symbolIndex = self.symbolIndex else { return nil }
                return HoverController.Source(
                    provider: symbolIndex.provider,
                    fileURL: self.fileURL,
                    rootGeneration: symbolIndex.currentRootGeneration,
                    diagnosticsAtOffset: { [weak self] url, offset in
                        // D34's lookup: the same store the squiggles and the
                        // gutter read, queried at the moment the hover asks.
                        // Empty for an undiagnosed document, which leaves the
                        // controller's dwell rule exactly as it was.
                        self?.diagnosticsModel?.diagnostics(at: offset, in: url) ?? []
                    }
                )
            }
        }

        /// Forward the two font inputs the popover draws with
        /// (`makeNSView`/`updateNSView`).
        func syncHover(codeFontSize: CGFloat, metrics: InterfaceMetrics) {
            hover.syncAppearance(codeFontSize: codeFontSize, metrics: metrics)
        }

        /// The pointer moved over the text, in the text view's coordinates.
        func pointerMoved(to point: NSPoint, in textView: NSTextView) {
            hover.pointerMoved(to: point, in: textView)
        }

        /// The pointer left the text view.
        func pointerExitedEditor() {
            hover.pointerExited()
        }

        /// Take any popover down — the single entry point every dismissal
        /// trigger outside `HoverController` itself goes through.
        func dismissHover() {
            hover.dismiss()
        }

        // MARK: - Symbol index

        /// Re-index the shown file from its live buffer text.
        ///
        /// `immediate` is the tab-switch / buffer-swap case; typing goes through the
        /// debounce. An untitled buffer is skipped: the index is keyed by file URL,
        /// so there is nothing to file it under. The language gate lives in the
        /// controller, so a plain-text or unindexable file costs one call and no
        /// task.
        ///
        /// The diagnostics sync (D30) rides the exact same two calls — the three
        /// call sites above this method are its whole trigger surface, and riding
        /// here rather than beside them is what guarantees the index and the LSP
        /// server are always told about the same buffer in the same order.
        func reindexSymbols(text: String, language: SyntaxLanguage?, immediate: Bool) {
            guard let symbolIndex, let fileURL else { return }
            if immediate {
                symbolIndex.noteBufferOpened(url: fileURL, text: text, language: language)
                lspSync?.noteBufferOpened(url: fileURL, text: text, language: language)
            } else {
                symbolIndex.noteBufferChanged(url: fileURL, text: text, language: language)
                lspSync?.noteBufferChanged(url: fileURL, text: text, language: language)
            }
        }

        // MARK: - Go to definition

        /// Opens a chosen declaration's file and selects its name range. Assigned
        /// from `CodeEditorView` on every update, because it captures the app's
        /// scene state (see the property's note there).
        var navigateToDefinition: (URL, NSRange) -> Void = { _, _ in }

        /// Shows a declaration that lives outside the opened folder in the separate
        /// read-only viewer window. Assigned from `CodeEditorView` on every update,
        /// like `navigateToDefinition`, and for the same reason.
        var viewDefinitionOutsideProject: (URL, NSRange) -> Void = { _, _ in }

        /// Jump to the declaration of the identifier at `offset` — the single
        /// entry point behind both ⌘-click and the ⌃⌘J menu item, so the two can
        /// never disagree about what counts as an identifier or how a jump is made.
        ///
        /// Every decision here is Core's: `IdentifierScanner` says which word the
        /// offset names, and the provider ranks the candidates. This method only
        /// picks the surface — beep, jump, or picker — from how many came back.
        ///
        /// The lookup is `async` because the seam is (an LSP provider must await a
        /// socket), so the answer arrives a turn later; the text view is
        /// re-captured weakly for that hop, and the picker is anchored on the range
        /// the question was asked about, which `DefinitionPicker` clamps against
        /// the buffer as it is by then.
        func goToDefinition(in textView: NSTextView, at offset: Int) {
            let text = textView.string
            guard let provider = symbolIndex?.provider,
                  let match = IdentifierScanner.identifier(in: text as NSString, at: offset)
            else {
                PlatformFeedback.warning()
                return
            }
            // The buffer travels with the question (D2): an LSP provider has to
            // tell the server the current text before it can ask about an offset
            // in it, and this is the one macOS path that reaches one. Leaving
            // `text` to its default here would not fail to compile — it would
            // quietly ask about offset N in an empty document.
            let request = DefinitionRequest(
                identifier: match.text,
                fileURL: fileURL,
                offset: match.range.location,
                text: text
            )
            // The folder this question is being asked in, pinned *synchronously*
            // before the hop — the generation-token rule, applied at the point an
            // answer is finally read rather than where it is computed.
            //
            // Both providers already refuse to answer for a folder the user has
            // left (the index is cleared by `prepareForFolderChange`;
            // `LSPWorkspace.stillHolds(_:)` drops a response its root no longer
            // matches), but neither gate reaches past its own `return`: the
            // candidates cross one more main-actor hop to get here, and ⌘⇧O lands
            // in a single synchronous turn, so a switch scheduled inside that hop
            // would leave this task opening a file from the previous project — the
            // one outcome every one of those gates exists to prevent. Silently,
            // with no beep: the user asked for a different folder, and a warning
            // sound for an answer they are no longer waiting on is noise.
            let rootGeneration = symbolIndex?.currentRootGeneration
            Task { [weak self, weak textView] in
                let candidates = await provider.definitions(for: request)
                guard let self, let textView else { return }
                guard self.symbolIndex?.currentRootGeneration == rootGeneration else { return }
                switch candidates.count {
                case 0:
                    // Nothing declares that name in the indexed project — the
                    // documented "no definition" outcome, and deliberately silent
                    // beyond the beep: an alert for a mistyped ⌘-click would be
                    // worse than the click itself.
                    PlatformFeedback.warning()
                case 1:
                    self.navigate(to: candidates[0])
                default:
                    DefinitionPicker.present(
                        candidates,
                        in: textView,
                        anchoredTo: match.range
                    ) { [weak self] candidate in
                        self?.navigate(to: candidate)
                    }
                }
            }
        }

        // MARK: - Find usages / rename

        /// Ask the app "where is this used" about the identifier at `offset`.
        /// Assigned from `CodeEditorView` on every update, because it captures
        /// the app's scene state (see the property's note there).
        var requestUsages: (UsagesRequest) -> Void = { _ in }

        /// Ask the app to rename the identifier at `offset`. Assigned from
        /// `CodeEditorView` on every update, like `requestUsages`, and for the
        /// same reason.
        var requestRename: (UsagesRequest) -> Void = { _ in }

        /// The one place the caret's word becomes a question, shared by the two
        /// commands below so they can never disagree about what a name is or
        /// which offset the question is asked at.
        ///
        /// `IdentifierScanner` decides — the same rule Go to Definition,
        /// completion and the textual scan all use — and the *first* character
        /// of the resolved word is what travels, so the answer does not depend
        /// on where inside a name the caret happened to be. The live buffer
        /// travels with it (D2), for `goToDefinition(in:at:)`'s reason: the seam
        /// may reach a server, and a server must be told the text before it can
        /// be asked about an offset in it.
        private func caretQuery(in textView: NSTextView, at offset: Int) -> UsagesRequest? {
            let text = textView.string
            guard let match = IdentifierScanner.identifier(in: text as NSString, at: offset) else {
                return nil
            }
            return UsagesRequest(
                identifier: match.text,
                fileURL: fileURL,
                offset: match.range.location,
                text: text
            )
        }

        /// Find Usages at `offset` — ⌃⌘U's and the context menu's one entry
        /// point. Nothing resolved is a beep, exactly as a ⌘-click on whitespace
        /// is: the command did not happen, and an alert for a misplaced caret
        /// would be worse than the caret.
        func findUsages(in textView: NSTextView, at offset: Int) {
            guard let query = caretQuery(in: textView, at: offset) else {
                PlatformFeedback.warning()
                return
            }
            requestUsages(query)
        }

        /// Rename at `offset` — ⌃⌘R's and the context menu's one entry point.
        /// Beeps on an unresolved word for `findUsages(in:at:)`'s reason; every
        /// other refusal (no server, a server with no rename capability, an
        /// answer with no edits) belongs to the app, which is where the sheet
        /// and the writer gate are.
        func renameSymbol(in textView: NSTextView, at offset: Int) {
            guard let query = caretQuery(in: textView, at: offset) else {
                PlatformFeedback.warning()
                return
            }
            requestRename(query)
        }

        /// Land on a chosen declaration: a tab for a file inside the opened folder,
        /// the read-only viewer window for one outside it (D3).
        ///
        /// The fork is the candidate's own `isOutsideProjectRoot` — the provider
        /// knows the project root, this view does not — and it is applied in one
        /// place so the single-candidate jump and the picker's choice can never
        /// disagree about where a target opens. Every tree-sitter candidate takes
        /// the first branch: the index only ever walks the opened folder.
        private func navigate(to candidate: DefinitionCandidate) {
            if candidate.isOutsideProjectRoot {
                viewDefinitionOutsideProject(candidate.fileURL, candidate.range)
            } else {
                navigateToDefinition(candidate.fileURL, candidate.range)
            }
        }

        // MARK: - Bracket highlighting

        /// Bind the bracket overlays to the text view and start observing edits.
        ///
        /// The edit trigger is the *text storage's* `didProcessEditingNotification`
        /// rather than `NSText.didChange` (the `LineNumberRulerView` precedent): it
        /// carries the edited range — which the overlays need in order to drop the
        /// now-stale coloring before the rescan — and it covers programmatic edits
        /// (auto-pair, dedent, duplicate, a buffer swap) as well as typing. Being a
        /// notification, it coexists with Neon owning the storage's `delegate`.
        func attachBracketHighlighting(textView: NSTextView) {
            bracketHighlight.attach(textView: textView)
            // The indentation-level widths ride this controller's debounce and
            // generation token rather than growing a second pair (see
            // `bracketScanApplied()`). The closure captures `self` weakly: the
            // controller is owned by this coordinator, so a strong capture would
            // be the retain cycle `CodeEditorView`'s own rule forbids.
            bracketHighlight.onScanApplied = { [weak self] in
                self?.bracketScanApplied()
            }
            guard let textStorage = textView.textStorage else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(bracketTextStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: textStorage
            )
        }

        /// Rescan the buffer's brackets (debounced unless `immediate`) and
        /// re-evaluate the caret's pair.
        ///
        /// `immediate` is for a tab switch / wholesale buffer swap: waiting out the
        /// debounce there would leave the previous file's colors on screen. The
        /// controller's cache key makes an unchanged buffer a no-op either way.
        func updateBrackets(text: String, fileID: UUID, immediate: Bool) {
            bracketHighlight.update(text: text, fileID: fileID, immediate: immediate)
            if immediate, let textView {
                bracketHighlight.updateSelection(textView.selectedRange())
            }
        }

        /// A character edit landed: clear the stale coloring over the edited range
        /// and schedule a (debounced) rescan. Attribute-only edits — Neon's own
        /// styling, and the overlays' — are ignored, so the two can't drive each
        /// other in a loop.
        @objc private func bracketTextStorageDidProcessEditing(_ notification: Notification) {
            guard
                let textStorage = notification.object as? NSTextStorage,
                textStorage.editedMask.contains(.editedCharacters)
            else { return }
            // Any text edit invalidates a popover: it describes an offset in the
            // buffer as it was, and the edit may have moved, rewritten or deleted
            // the very thing it names. The *storage's* notification rather than
            // `textDidChange`, for the same reason the brackets use it — it
            // covers programmatic edits (auto-pair, dedent, ⌘D, a buffer swap) as
            // well as typing.
            completion.noteEdit()
            hover.dismiss()
            bracketHighlight.noteEdit(
                in: textStorage.editedRange,
                changeInLength: textStorage.changeInLength,
                postEditLength: textStorage.length
            )
            // The find bar's matches moved with the edit too. The re-run is
            // deferred to the next main-loop turn rather than done here: this
            // notification is posted *before* the storage notifies its layout
            // managers, so freshly painted (post-edit) backgrounds would be
            // shifted straight off their characters — the mirror image of the
            // pre-edit coordinate problem `clearBackgrounds(storageLength:)`
            // solves. `noteEdit` above already dropped the stale highlight, so
            // nothing wrong is on screen in the meantime.
            searchController.setNeedsRefresh()
            guard let fileID else { return }
            bracketHighlight.update(text: textStorage.string, fileID: fileID, immediate: false)
        }

        /// The caret (or selection) moved: highlight the bracket pair it sits next
        /// to, or clear the previous highlight. No rescan — the buffer is unchanged.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // A caret may not rest strictly inside hidden text: there is no glyph
            // there to draw it beside. Applied first, so everything below reads
            // the selection the user will actually see. The guard is the
            // re-entrancy one the rule's own `setSelectedRange` needs, exactly as
            // the change interceptors guard their programmatic edits.
            if !isApplyingFoldCaret {
                applyFoldCaretRule(previous: previousFoldSelection)
            }
            previousFoldSelection = textView.selectedRange()
            bracketHighlight.updateSelection(textView.selectedRange())
            // A selection change is the user working in the text rather than
            // reading an annotation of it — and a click, a drag-select or an
            // arrow key can all move the caret out from under a popover that is
            // still on screen.
            hover.dismiss()
            if completion.isVisible {
                // The one caret-move entry: the controller may only *invalidate*
                // a stale list here, never ask for a new one — a click or an
                // arrow key must not pop a list. Asking on typing is handled by
                // `textDidChange` above.
                updateCompletions(explicit: false, caretMove: true)
            } else {
                // Nothing is shown, but a request may already be in flight
                // behind its debounce: without this, an answer computed for one
                // caret position could land after a click moved the caret onto
                // an identically-spelled word — `apply` compares the prefix
                // *text*, not the location — and open over a question nobody
                // asked. Cancelled here rather than through `update(…)`
                // deliberately: the full entry runs `forgetList()`, which would
                // kill D4's late auto-import scheduled moments ago by a commit
                // whose own caret move lands in this branch.
                completion.invalidatePendingRequest()
            }
            // The find bar's "current" match follows the caret (see
            // `EditorSearchController.selectionChanged()`), so it must move with
            // it — otherwise Replace edits a different match than the one shown.
            searchController.selectionChanged()
        }

        func textDidEndEditing(_ notification: Notification) {
            // Same visibility gate as the scroll and resign-key handlers: a
            // first-responder loss with nothing shown is the post-commit state,
            // and dismissing there would cancel D4's late auto-import.
            if completion.isVisible {
                completion.dismiss()
            }
        }

        // MARK: - Indentation levels

        /// Whether the indentation-level blocks are painted at all — the value
        /// `ContentView` read off the store, travelling `completionEnabled`'s
        /// route. The coordinator is the only thing that reads it: the layout
        /// manager is *told*.
        private var indentLevelsEnabled = false

        /// The widths last handed to the layout manager, and the two inputs they
        /// were derived under: the configuration revision, and the file the
        /// configuration was resolved *for*.
        ///
        /// The cache is what keeps the derivation off the SwiftUI update path:
        /// its content half is `IndentEngine.inferIndentUnit(text:)`, a walk of
        /// the whole buffer, which must not run on every re-render. `nil` means
        /// nothing has been computed yet — the state a freshly built editor and a
        /// just-switched-on preference are both in, and the one that forces the
        /// next sync to compute.
        ///
        /// The URL is part of the key because `.editorconfig` answers *per file*:
        /// a tab switch, and a rename that moves a file into a different section
        /// (`foo.txt` → `foo.py`), both change the applicable properties while the
        /// revision stands still. Without it the widths derived for the outgoing
        /// file would be re-asserted forever — nothing else in the key moves for a
        /// buffer that is only looked at.
        private var appliedIndentWidths: IndentLevelWidths?
        private var appliedIndentConfigRevision: Int?
        private var appliedIndentFileURL: URL?

        /// Apply the preference, from `makeNSView` and every `updateNSView`.
        ///
        /// Turning it **off** clears the cache and tells the layout manager to
        /// stop, so a user who does not want the blocks pays for no derivation at
        /// all; turning it back **on** finds an empty cache and therefore computes
        /// once, here, on the turn the toggle flipped.
        func setIndentLevelHighlighting(enabled: Bool) {
            indentLevelsEnabled = enabled
            guard enabled else {
                appliedIndentWidths = nil
                appliedIndentConfigRevision = nil
                appliedIndentFileURL = nil
                overlayLayoutManager?.setIndentLevelPainting(
                    enabled: false,
                    widths: IndentLevelWidths(unitWidth: 0, tabWidth: 0)
                )
                return
            }
            refreshIndentLevelWidths(textChanged: false)
        }

        /// A bracket scan was applied: the buffer this editor shows just changed,
        /// or the tab switched into a different one. Either way the content half
        /// of the derivation is stale, so the widths are recomputed here — on the
        /// editor's one debounced, generation-guarded text path, never on a second
        /// one of this feature's own.
        private func bracketScanApplied() {
            refreshIndentLevelWidths(textChanged: true)
        }

        /// Recompute the two widths and hand them over, when anything they are
        /// derived from can have moved.
        ///
        /// **The configuration revision is compared on both paths, and that is
        /// deliberate.** `EditorConfigModel` is a plain class this editor does not
        /// observe: an on-disk `.editorconfig` edit reaches `updateNSView` only
        /// because the same FSEvents turn that calls `noteProjectFilesChanged()`
        /// also bumps `WorkspaceModel.treeRevision`, whose `@Published` change
        /// re-renders the content view. That path is indirect and could go quiet,
        /// so the revision is compared in `bracketScanApplied()` too — one integer
        /// against the last one seen, on a path that already runs on every
        /// debounced edit and every tab switch. A stale width therefore never
        /// outlives the next edit or tab switch even when no re-render arrives.
        ///
        /// **The shown file is compared too**, and it is the input the other two
        /// cannot stand in for. `fileURL` is recorded by `syncBlame`, which
        /// `updateNSView` calls *after* the bracket rescan a tab switch forces —
        /// so the recompute this feature rides on a tab switch resolves
        /// `.editorconfig` against the file being *left*. Keeping the URL in the
        /// key is what lets the re-apply that follows (`syncBlame` has run by
        /// then) notice and derive again; without it the outgoing file's unit
        /// would be cached and re-asserted for as long as the incoming buffer is
        /// only read.
        ///
        /// When nothing moved the widths are simply re-asserted, which the layout
        /// manager answers as a no-op; the buffer is not walked again.
        private func refreshIndentLevelWidths(textChanged: Bool) {
            guard indentLevelsEnabled else { return }
            guard let textView, let layoutManager = overlayLayoutManager else { return }
            let revision = editorConfig?.revision
            if let applied = appliedIndentWidths,
               !textChanged,
               revision == appliedIndentConfigRevision,
               fileURL == appliedIndentFileURL {
                layoutManager.setIndentLevelPainting(enabled: true, widths: applied)
                return
            }
            let widths = indentLevelWidths(text: textView.string as NSString)
            appliedIndentWidths = widths
            appliedIndentConfigRevision = revision
            appliedIndentFileURL = fileURL
            layoutManager.setIndentLevelPainting(enabled: true, widths: widths)
        }

        /// The two column widths one indentation level is worth in this buffer.
        ///
        /// **One derivation, two consumers.** The indentation-level painting was
        /// the first; the fold scanner is the second, and it measures a block
        /// with exactly the unit the editor types with rather than deriving one
        /// of its own. The answer Enter and Tab are given is asked through
        /// `indentUnit(text:)` — `.editorconfig` first, the content inference
        /// second — and turned into columns by Core alone, so nothing here is a
        /// second opinion about what a level is.
        ///
        /// Uncached on purpose: the painting path keeps its own cache (see
        /// `refreshIndentLevelWidths`) because it runs on every SwiftUI update,
        /// while the fold ask reaches this once per settled burst of typing —
        /// the same order of work as the bracket rescan it rides behind.
        private func indentLevelWidths(text nsText: NSString) -> IndentLevelWidths {
            IndentLevelScanner.widths(
                unit: indentUnit(text: nsText),
                statedTabWidth: editorConfigProperties().tabWidth
            )
        }

        // MARK: - Folding

        /// Bind the fold controller to the text view and the gutter, and give it
        /// the four inputs a question needs (`makeNSView`).
        ///
        /// The source closure re-reads all four *at the moment a question is
        /// asked* — `attachHover`'s shape and for its reason: a folder switch
        /// swaps the provider and the root under a live editor, and a closure
        /// that captured either would ask yesterday's question. Captured weakly,
        /// so a torn-down editor answers "nothing to ask".
        func attachFolding(textView: NSTextView, ruler: LineNumberRulerView) {
            folds.attach(textView: textView, ruler: ruler)
            folds.source = { [weak self] in
                guard let self, let symbolIndex = self.symbolIndex, let textView = self.textView else { return nil }
                return FoldController.Source(
                    provider: symbolIndex.provider,
                    fileURL: self.fileURL,
                    language: self.language,
                    widths: self.indentLevelWidths(text: textView.string as NSString)
                )
            }
        }

        /// The key this file's folds are remembered under: the canonical path of
        /// a url-backed file, the tab id of an unsaved buffer.
        ///
        /// **Not `OpenFile.id`**, which is a fresh `UUID` per open: closing and
        /// reopening a file would then lose its folds, which is exactly what the
        /// memory exists to keep for the length of the run. The canonical
        /// spelling is `SourceViewerWindowController`'s — `standardizedFileURL`
        /// then `resolvingSymlinksInPath()`, the app-layer form of the same
        /// identity comparison the workspace makes.
        private var foldMemoryKey: String? {
            Coordinator.foldMemoryKey(url: fileURL, fileID: fileID)
        }

        /// The same key for a file this coordinator is not currently showing —
        /// which is the case at the one moment it has to be asked about the
        /// *incoming* file: `updateNSView`'s content-replaced branch runs before
        /// `syncBlame` re-records the URL, so the property above still names the
        /// outgoing one there. One spelling, two callers.
        static func foldMemoryKey(url: URL?, fileID: UUID?) -> String? {
            if let url { return url.standardizedFileURL.resolvingSymlinksInPath().path }
            return fileID?.uuidString
        }

        /// Reconcile the folds with the displayed file: a switch/open/retarget
        /// restores what was folded in it and asks at once, an ordinary edit asks
        /// behind the controller's own 400 ms debounce, and a language or
        /// `.editorconfig` change asks again because both move where blocks are.
        func syncFolds(text: String, immediate: Bool) {
            if immediate {
                folds.noteBufferOpened(key: foldMemoryKey, text: text)
            } else {
                folds.noteBufferChanged(text: text)
            }
        }

        /// The two inputs a fold answer depends on that are neither the text nor
        /// the file: the buffer's language, and the `.editorconfig` revision the
        /// indentation widths are derived under. `nil` until the first sync,
        /// which is a seed rather than a change.
        private var appliedFoldInputs: (language: SyntaxLanguage?, revision: Int?)?

        /// Re-ask when either of those moved, and do nothing at all when neither
        /// did — this runs on every SwiftUI update.
        ///
        /// Both change *where blocks are*: a language change swaps which server
        /// (if any) answers, and an `.editorconfig` edit moves the widths the
        /// fallback scanner measures indentation blocks with. Neither disturbs
        /// what is folded: the answer that lands is reconciled with the folded
        /// state by header line, exactly as every other answer is.
        ///
        /// The revision is compared here rather than ridden on the indentation
        /// painting's cache because that cache exists only while the preference
        /// is on, and folding does not ask the user's permission to know where a
        /// block ends.
        ///
        /// `alreadyAsked` is the tab switch (and the editor's construction),
        /// where the language moves *and* an immediate ask has just run: the new
        /// values are recorded as the baseline and no second question is asked.
        func syncFoldInputs(alreadyAsked: Bool) {
            let inputs = (language: language, revision: editorConfig?.revision)
            let changed = appliedFoldInputs.map {
                $0.language != inputs.language || $0.revision != inputs.revision
            } ?? true
            appliedFoldInputs = inputs
            guard changed, !alreadyAsked, let textView else { return }
            folds.noteConfigurationChanged(text: textView.string)
        }

        /// Remember where the *outgoing* tab's folds were, beside
        /// `recordViewport(for:)` and for the same reason: one controller serves
        /// every tab, so the switch is the last moment the outgoing state is
        /// still the live one.
        func recordFolds() {
            folds.recordCurrent()
        }

        /// Drop this file's remembered folds — its text was replaced out from
        /// under it, so they describe a buffer that no longer exists. Beside
        /// `forgetViewport(for:)` and on exactly the same signal.
        func forgetFolds(url: URL?, fileID: UUID) {
            guard let key = Coordinator.foldMemoryKey(url: url, fileID: fileID) else { return }
            folds.forget(key: key)
        }

        /// Drop every remembered fold, on a folder switch.
        func forgetAllFolds() {
            folds.forgetAll()
        }

        /// The chevron in the gutter was clicked: fold or unfold that candidate,
        /// then put the caret somewhere it can be drawn.
        ///
        /// The decision is `FoldState`'s (`toggle`) and the caret's is
        /// `FoldCaretRule`'s; this only sequences the two.
        func toggleFold(_ region: FoldRegion) {
            folds.toggleFold(region)
            // A fold gesture carries no direction — the caret did not move, the
            // text under it stopped having a position — so the rule is asked
            // with no previous selection and lands it beside the placeholder.
            applyFoldCaretRule(previous: NSRange(location: NSNotFound, length: 0))
        }

        /// Up while the caret rule is putting the caret back, so the selection
        /// notification that move posts is not re-inspected as a user move
        /// (`isApplyingProgrammaticEdit`'s shape, for the selection path).
        private var isApplyingFoldCaret = false

        /// Where the caret was before the selection change being handled, which
        /// is the *direction* `FoldCaretRule` reads: forward past a folded block,
        /// backward before it. `NSNotFound` until the first move — a click and a
        /// programmatic selection carry no direction either, and land beside the
        /// placeholder.
        private var previousFoldSelection = NSRange(location: NSNotFound, length: 0)

        /// Put the caret where it can actually be drawn, if the selection change
        /// just landed it strictly inside hidden text.
        ///
        /// **The one place `FoldCaretRule` is applied.** A selection with length
        /// is returned untouched by the rule itself, so selecting across a
        /// collapsed block still copies the whole block.
        private func applyFoldCaretRule(previous: NSRange) {
            guard let textView, !folds.state.isEmpty else { return }
            let proposed = textView.selectedRange()
            let sanitized = FoldCaretRule.caret(for: proposed, previous: previous, in: folds.state)
            guard sanitized != proposed else { return }
            isApplyingFoldCaret = true
            defer { isApplyingFoldCaret = false }
            textView.setSelectedRange(sanitized)
        }

        /// **The reveal funnel**: select `range` and scroll it into view, after
        /// unfolding every folded block it reaches.
        ///
        /// Every jump-to-a-range in the editor goes through here — a find-bar
        /// match, a Find in Files row, Go to Definition, a Problems row, a Usages
        /// row — because revealing text that has no on-screen position lands the
        /// reader somewhere arbitrary. Its two callers are `applyReveal` in this
        /// file and `EditorSearchController.select(_:)` through the hook
        /// `attachSearch` installs; the rule it applies is `FoldReveal`'s, and
        /// this is the one file that names it.
        func revealRange(_ range: NSRange) {
            guard let textView else { return }
            folds.apply(FoldReveal.unfolding(range, in: folds.state))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }

        /// The overlay layout manager currently installed, resolved dynamically
        /// for `BracketHighlightController`'s reason: `replaceLayoutManager` can
        /// swap it under the text view, and a cached reference would paint into a
        /// manager nothing draws from.
        private var overlayLayoutManager: BracketOverlayLayoutManager? {
            textView?.layoutManager as? BracketOverlayLayoutManager
        }

        // MARK: - Blame column

        /// Bind the blame controller to the gutter (`makeNSView`).
        func attachBlame(ruler: LineNumberRulerView) {
            blame.attach(ruler: ruler)
        }

        /// Reconcile the blame column with the displayed file. Also records the
        /// file's URL for the context-menu action.
        func syncBlame(fileURL: URL?, diskRevision: Int, contentReplaced: Bool) {
            self.fileURL = fileURL
            guard let fileID else { return }
            blame.sync(
                fileID: fileID,
                fileURL: fileURL,
                diskRevision: diskRevision,
                contentReplaced: contentReplaced
            )
        }

        /// The gutter's "Annotate with Git Blame" / "Close Annotations" item.
        func toggleBlame() {
            guard let fileID else { return }
            blame.toggle(fileID: fileID, fileURL: fileURL)
        }

        /// Drop the column ahead of a wholesale buffer replacement, so the ruler
        /// does not shift annotations across a full-document edit.
        func beginBlameBufferSwap() {
            blame.beginBufferSwap()
        }

        // MARK: - Diagnostics underlines

        /// The diagnostics channel's observable model, held *weakly* like
        /// `symbolIndex`: the app owns it for its whole lifetime, and the
        /// coordinator only reads the displayed file's entry out of its store.
        weak var diagnosticsModel: DiagnosticsModel?

        /// Up while `updateNSView` replaces the text view's whole buffer: the
        /// full-range edit that assignment posts must not reach
        /// `bufferEdited`'s shift (a plain tab switch keeps the outgoing
        /// document's set; a genuine replacement has nothing left to shift).
        /// Set and cleared synchronously inside the content-replaced branch.
        var isSwappingBuffer = false

        /// The store observation (one for the coordinator's lifetime). The model
        /// is mutated from several directions — accepted pushes, teardown clears,
        /// the edit-driven shift, wholesale-replacement drops — and every one of
        /// them must repaint the underlines; subscribing to the published store
        /// once is what makes that true by construction instead of by a checklist
        /// of call sites.
        private var diagnosticsSubscription: AnyCancellable?

        /// Coalesces repaint requests onto one main-loop turn: a keystroke fires
        /// both the shift's mutation and this handler's explicit schedule, and
        /// TextKit needs to have finished shifting temporary attributes before
        /// new ones are written at post-edit coordinates (the same turn-deferral
        /// `searchController.setNeedsRefresh()` exists for). Cancelling-and-
        /// rescheduling makes any number of same-turn triggers one repaint.
        private var pendingDiagnosticRepaint: DispatchWorkItem?

        /// Bind the diagnostics model and start observing it. Re-attachment with
        /// the same instance (every SwiftUI update) is a no-op, so exactly one
        /// subscription exists per coordinator.
        ///
        /// The subscription defers to the next main-loop turn before reading:
        /// `objectWillChange` fires *before* the store's value lands, so a
        /// synchronous read would paint the previous state.
        func attachDiagnostics(model: DiagnosticsModel?) {
            guard diagnosticsModel !== model else { return }
            diagnosticsSubscription?.cancel()
            diagnosticsSubscription = nil
            diagnosticsModel = model
            guard let model else { return }
            diagnosticsSubscription = model.objectWillChange.sink { [weak self] _ in
                self?.scheduleDiagnosticOverlaysRefresh()
            }
        }

        /// Repaint the squiggles for the displayed document from the store.
        ///
        /// Runs on the next main-loop turn after any model change (and
        /// immediately on a tab switch, where `updateNSView` calls it directly):
        /// it reads the whole entry — ranges and severities, already in buffer
        /// offsets — and hands them to the layout manager, which merges overlaps
        /// into worst-severity spans and strokes the waves itself. The gutter's
        /// severity markers are fed from the same read. An untitled buffer names
        /// no document and clears both surfaces.
        func refreshDiagnosticOverlays() {
            pendingDiagnosticRepaint?.cancel()
            pendingDiagnosticRepaint = nil
            guard let textView,
                  let layoutManager = textView.layoutManager as? BracketOverlayLayoutManager
            else { return }
            refreshGutterMarkers()
            guard let url = fileURL else {
                layoutManager.setDiagnosticRuns([])
                return
            }
            let runs = (diagnosticsModel?.diagnostics(in: url) ?? []).map {
                DiagnosticRun(range: $0.range, severity: $0.severity)
            }
            layoutManager.setDiagnosticRuns(runs)
        }

        /// Feed the ruler's diagnostic-marker column from the same model read
        /// the squiggles come out of: worst severity per displayed line, indexed
        /// by the ruler's own line geometry (`lineCount` + `lineStarts`, so a
        /// multi-line span marks every line it crosses). This one method covers
        /// all three feeds the column needs — every model change (the
        /// subscription defers here), every edit (`bufferEdited` schedules the
        /// same repaint), and every tab switch / buffer replacement
        /// (`updateNSView` calls `refreshDiagnosticOverlays` directly) — because
        /// each feed must show the *incoming* file's column from whatever its
        /// store entry now holds (all-`nil` when a genuine replacement just
        /// cleared it, the retained set after a plain switch to a diagnosed
        /// background file).
        private func refreshGutterMarkers() {
            guard let ruler = lineNumberRuler else { return }
            let severities: [DiagnosticSeverity?]
            if let url = fileURL {
                severities = diagnosticsModel?.worstSeverityPerLine(
                    url: url,
                    lineCount: ruler.lineCount,
                    lineStarts: ruler.lineStarts
                ) ?? Array(repeating: nil, count: ruler.lineCount)
            } else {
                severities = Array(repeating: nil, count: ruler.lineCount)
            }
            ruler.setDiagnosticSeverities(severities)
        }

        /// Queue `refreshDiagnosticOverlays` onto the next main-loop turn,
        /// superseding anything queued earlier.
        private func scheduleDiagnosticOverlaysRefresh() {
            pendingDiagnosticRepaint?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshDiagnosticOverlays()
            }
            pendingDiagnosticRepaint = work
            DispatchQueue.main.async(execute: work)
        }

        /// One character edit landed (via the ruler's `onEdit`, which hands over
        /// the pre/post line-start tables it maintained anyway): shift the stored
        /// set across the edit — dropping what it touched (D32) — and clear the
        /// stale underline attributes now, while the temporary-attribute space is
        /// still in **pre-edit** coordinates (`didProcessEditingNotification`
        /// precedes the layout managers' own notification; the mirror of
        /// `bracketHighlight.noteEdit`). The repaint itself is deferred: painting
        /// here would write post-edit coordinates that TextKit then shifts again.
        func bufferEdited(
            previousLineStarts: [Int],
            newLineStarts: [Int],
            editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedRange.location != NSNotFound else { return }
            // The one full-range edit a buffer swap posts is *not* an edit to
            // shift across: for a plain tab switch the outgoing document's set
            // deliberately survives (`updateNSView`'s content-replaced branch),
            // and shifting it here would drop every entry; for a genuine
            // replacement the store entry is already gone, so there is nothing
            // to do either way.
            guard !isSwappingBuffer else { return }
            // The fold regions and the folded state travel across the edit by the
            // same three-way rule, on the same two line-start tables the ruler
            // maintained anyway — beside the diagnostics shift and under the same
            // suppression, because a buffer swap has nothing to shift either.
            folds.noteEdit(
                previousLineStarts: previousLineStarts,
                newLineStarts: newLineStarts,
                editedRange: editedRange,
                changeInLength: delta
            )
            if let url = fileURL {
                diagnosticsModel?.noteEdit(
                    url: url,
                    previousLineStarts: previousLineStarts,
                    newLineStarts: newLineStarts,
                    editedRange: editedRange,
                    changeInLength: delta
                )
            }
            // Back the edited span and the valid extent out of the storage's
            // post-edit report into the pre-edit coordinates the attributes are
            // still in (`BracketHighlightController.noteEdit`'s arithmetic).
            let postEditLength = textView?.textStorage?.length ?? 0
            let preEditLength = max(0, postEditLength - delta)
            let preEditRange = NSRange(
                location: editedRange.location,
                length: max(0, editedRange.length - delta)
            )
            (textView?.layoutManager as? BracketOverlayLayoutManager)?
                .clearDiagnostics(in: preEditRange, storageLength: preEditLength)
            // The model's mutation schedules a repaint through the subscription;
            // scheduling here as well keeps the contract explicit and coalesces
            // into the same single turn.
            scheduleDiagnosticOverlaysRefresh()
        }

        /// Drop the overlay's belief about what is painted, ahead of the
        /// wholesale replacement that wipes the attributes themselves. Beside
        /// `beginDiagnosticsBufferSwap` in `updateNSView`, but on *every*
        /// content replacement rather than only a genuine one — see
        /// `BracketOverlayLayoutManager.invalidateDiagnosticPaint()`.
        func invalidateDiagnosticPaint() {
            (textView?.layoutManager as? BracketOverlayLayoutManager)?
                .invalidateDiagnosticPaint()
        }

        /// Drop one document's diagnostics ahead of a wholesale buffer
        /// replacement (`updateNSView`'s content-replaced branch, beside
        /// `beginBlameBufferSwap`). The URL is handed in rather than read from
        /// `fileURL` because on a tab switch the recorded URL still names the
        /// *outgoing* file at that point — `syncBlame` has not re-recorded yet —
        /// while the replaced document is the incoming one.
        func beginDiagnosticsBufferSwap(clearing url: URL?) {
            guard let url else { return }
            diagnosticsModel?.noteBufferReplaced(url: url)
            scheduleDiagnosticOverlaysRefresh()
        }

        // MARK: - Save transform

        /// `SaveTransformEditor`: which file this text view is showing right now.
        /// On the tab-switch autosave this is still the *outgoing* file, which is
        /// exactly the buffer being saved.
        var displayedFileID: UUID? { fileID }

        /// `SaveTransformEditor`: the character currently at the top of the
        /// viewport, so the save transform can put the same one back there.
        var scrollAnchorOffset: Int? { captureViewport()?.topCharacterOffset }

        /// `SaveTransformEditor`: raise both rewrite guards around a save
        /// transform.
        ///
        /// Raised before `shouldChangeText`, which re-invokes the auto-pair
        /// interceptor synchronously: a one-character replacement (the LF or CR a
        /// terminator normalization emits) must pass through as the programmatic
        /// edit it is rather than be inspected as a keystroke.
        func beginSaveTransformRewrite() {
            isApplyingProgrammaticEdit = true
            isSwappingBuffer = true
        }

        /// `SaveTransformEditor`: drop the two readers that shift incrementally,
        /// once the rewrite is known to be going ahead.
        ///
        /// The composed transform is applied as several small replacements, but
        /// `endEditing` coalesces them into **one** edited range — for a
        /// whole-file terminator normalization, the whole buffer. That is the
        /// buffer-swap case in everything but name, so it takes the buffer-swap
        /// treatment: `isSwappingBuffer` suppresses the diagnostics shift (a
        /// file-wide edit would drop every entry anyway, D32) and the blame column
        /// is dropped rather than shifted. Neither stays empty: this document's
        /// diagnostics are re-published by the push sync that `textDidChange`
        /// schedules, and the blame column reloads on the next update pass, which
        /// the save's own `diskRevision` bump guarantees happens.
        ///
        /// `invalidateDiagnosticPaint()` is deliberately **not** called, unlike on
        /// a real buffer swap: no `textView.string` assignment happened here, so
        /// the temporary attributes over the untouched text are still there, and
        /// forgetting the cache would make the clearing repaint a no-op and leave
        /// stale underlines painted.
        func resetIncrementalReadersForSaveTransform() {
            beginBlameBufferSwap()
            beginDiagnosticsBufferSwap(clearing: fileURL)
        }

        /// `SaveTransformEditor`: move the fold bounds through the plan, exactly
        /// as the selection endpoints and the scroll anchor are moved. The shift
        /// rule is deliberately not asked here — see the protocol's note and
        /// `FoldState.remapped(through:)`.
        func remapFolds(through plan: SaveTransformPlan) {
            folds.remap(through: plan)
        }

        /// `SaveTransformEditor`: lower both guards, after `didChangeText()` — so
        /// every notification the rewrite fires was covered by them.
        func endSaveTransformRewrite() {
            isSwappingBuffer = false
            isApplyingProgrammaticEdit = false
        }

        // MARK: - Find bar

        /// Bind the search controller to this text view and register it as the
        /// bar's executor (`makeNSView`).
        func attachSearch(textView: NSTextView, state: EditorSearchState) {
            searchController.attach(textView: textView)
            // The bar's one jump — next/previous match and the step the replace
            // takes after it — lands in the editor's reveal funnel rather than
            // selecting and scrolling itself, so a match inside a folded block
            // opens it first. Captured weakly: the coordinator owns the
            // controller, so a strong capture would be the retain cycle this
            // file's rule forbids.
            searchController.revealRange = { [weak self] range in
                self?.revealRange(range)
            }
            searchBarState = state
            searchController.bind(state: state)
        }

        /// Re-run the search for the current state, forcing it past the
        /// applied-query comparison when the buffer itself changed.
        func updateSearch(state: EditorSearchState, force: Bool) {
            searchBarState = state
            searchController.bind(state: state)
            searchController.refresh(force: force)
        }

        /// The `EditorRevealState.Request` token this editor last acted on, so a
        /// standing request is applied exactly once. `0` is below every issued
        /// token (they start at 1), so the first request always lands.
        private var appliedRevealToken = 0

        /// Select and scroll to a pending Find in Files activation, if it targets
        /// the file this editor is showing and has not been applied yet.
        ///
        /// The selection is deferred by one main-loop turn: the caller runs inside
        /// `updateNSView`, where the buffer may have just been replaced wholesale
        /// and TextKit has not laid the new text out — `scrollRangeToVisible` there
        /// would compute against the outgoing layout. Hopping out lets the layout
        /// pass finish first. The range is clamped to the live buffer, so a result
        /// row that pre-dates an edit shrinking the file can never raise.
        ///
        /// Window ordering is deliberately left alone: the Find in Files window
        /// stays key so the user can keep walking results, and the editor window is
        /// not yanked forward under it.
        func applyReveal(_ request: EditorRevealState.Request?, fileID: UUID) {
            guard let request,
                  request.token != appliedRevealToken,
                  request.fileID == fileID,
                  let textView
            else { return }
            // Resolved *before* the token is marked applied, since the resolver
            // asks that same question. Consuming the token regardless of whether a
            // range came back preserves the "a standing request is applied exactly
            // once" rule: an unusable range is a dead request, not one to retry on
            // every later update.
            let target = pendingRevealRange(request, fileID: fileID)
            appliedRevealToken = request.token
            guard let target else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                // Re-clamped against the buffer as it is *now*: the hop is a whole
                // main-loop turn, and nothing promises the text did not shrink in
                // between.
                let length = textView.textStorage?.length ?? 0
                guard target.location <= length else { return }
                let range = NSRange(
                    location: target.location,
                    length: min(target.length, length - target.location)
                )
                // Through the funnel, never by hand: an activation may name a
                // range inside a block this tab has folded, and scrolling to text
                // with no on-screen position lands the reader nowhere.
                self.revealRange(range)
            }
        }

        /// The range a pending reveal would select in the live buffer, or `nil`
        /// when there is nothing for this file to act on.
        ///
        /// **The one place the reveal's admission rule lives.** Two callers ask the
        /// same question — `applyReveal`, which consumes the request, and
        /// `hasPendingReveal`, which must not — and answering it twice is how the
        /// two silently drift apart. Concretely: a result row that pre-dates an
        /// edit shrinking the file names a range that no longer fits, and a
        /// predicate that only compared tokens and file ids would call that
        /// "pending" — suppressing the viewport restore for a reveal that then
        /// declines to select anything, leaving the tab at whatever offset the
        /// reused text view carried over.
        ///
        /// The range is clamped by *truncating the length*, not by intersecting: a
        /// range whose location is exactly the buffer end shares no unit with the
        /// document, and `NSIntersectionRange` answers `{0, 0}` for that — which
        /// would scroll to the top of the file instead of leaving the caret at the
        /// end.
        private func pendingRevealRange(
            _ request: EditorRevealState.Request?,
            fileID: UUID
        ) -> NSRange? {
            guard let request,
                  request.token != appliedRevealToken,
                  request.fileID == fileID,
                  let textView
            else { return nil }
            let length = textView.textStorage?.length ?? 0
            guard request.range.location != NSNotFound,
                  request.range.location >= 0,
                  request.range.location <= length
            else { return nil }
            return NSRange(
                location: request.range.location,
                length: min(max(request.range.length, 0), length - request.range.location)
            )
        }

        /// Whether `applyReveal` would act on this request for this file, asked
        /// without consuming anything (no token is recorded, no selection moved).
        ///
        /// `updateNSView` uses it to let an explicit reveal outrank the remembered
        /// viewport: activating a Find in Files result (or a go-to-definition) in
        /// an already-open background tab must land on the match, not on wherever
        /// the tab was last left.
        func hasPendingReveal(_ request: EditorRevealState.Request?, fileID: UUID) -> Bool {
            pendingRevealRange(request, fileID: fileID) != nil
        }

        /// Esc in the editor: close an open search bar (and drop its highlight),
        /// reporting whether it did — `false` leaves Esc to its stock behavior.
        func closeSearchBar() -> Bool {
            guard let state = searchBarState, state.isVisible else { return false }
            state.close()
            return true
        }

        // MARK: - Auto-indent

        /// Intercept Enter so the new line lands at a sensible indent, and Tab so a
        /// project that asks for spaces gets them.
        ///
        /// All indent computation is pure and lives in `PisakaCore` —
        /// `IndentEngine` for the edit, `IndentUnitRule` for which whitespace one
        /// level *is*; this only reads the live buffer + caret, applies the
        /// engine's result via `insertText(_:replacementRange:)` (so the per-file
        /// undo manager records it as one ordinary, single-step-undoable edit),
        /// repositions the caret, and suppresses the default newline by returning
        /// `true`.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return insertIndentedNewline(in: textView)
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                return deleteAutoPair(in: textView)
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return insertConfiguredTab(in: textView)
            }
            return false
        }

        /// What `.editorconfig` says about the shown file, or nothing at all when
        /// no configuration applies (and when the app's model is gone, which is
        /// the same answer).
        private func editorConfigProperties() -> EditorConfigProperties {
            editorConfig?.properties(for: fileURL) ?? EditorConfigProperties()
        }

        /// One indentation level for the shown buffer: what `.editorconfig` says,
        /// falling back per half to what the content itself looks like.
        ///
        /// The single place Enter asks, so it and Tab can never disagree about the
        /// unit — they differ only in *whether* the unit is used, which is
        /// `IndentUnitRule`'s own distinction.
        private func indentUnit(text nsText: NSString) -> String {
            IndentUnitRule.unit(
                config: editorConfigProperties(),
                inferred: IndentEngine.inferIndentUnit(text: nsText)
            )
        }

        /// The terminator a newly typed Return splices: the one `end_of_line`
        /// names, and LF whenever it names none.
        ///
        /// `end_of_line` is consumed in full, so it decides what a *new*
        /// terminator is as well as what the already-written ones become on save;
        /// typing Enter in a CRLF project would otherwise write the one line the
        /// save has to come back and fix. A project stating no `end_of_line` keeps
        /// splicing LF byte for byte, which is `IndentEngine`'s own default. The
        /// iOS coordinator holds the identical pair.
        private func newlineTerminator() -> String {
            editorConfigProperties().endOfLine?.terminator ?? "\n"
        }

        /// Intercept Tab so `indent_style = space` inserts spaces.
        ///
        /// `IndentUnitRule.tabInsertion` is deliberately stricter than the unit
        /// rule: it answers a literal tab unless the configuration says spaces
        /// outright, and this returns `false` for that answer so **AppKit's own
        /// `insertTab` runs** — the key then behaves byte-for-byte as it did
        /// before this layer existed, at every insertion point, with the stock
        /// undo grouping and the stock `NSTextView` field-editor semantics.
        ///
        /// When it does answer spaces, the fan-out matters: native `insertTab`
        /// inserts at *all* of `selectedRanges`, and the middle-drag column
        /// selection makes several zero-width carets a first-class state, so
        /// replacing only `selectedRange()` would silently collapse the selection
        /// to one caret. The whole plan is applied **back-to-front** (later ranges
        /// first, so earlier offsets stay valid) inside one
        /// `shouldChangeText` / `beginEditing` … `endEditing` / `didChangeText`
        /// bracket, which is what makes it a single undoable step and a single
        /// change notification. `insertBacktab` is untouched.
        private func insertConfiguredTab(in textView: NSTextView) -> Bool {
            // Never mid-composition. This is the one programmatic edit here that
            // mutates `textStorage` directly instead of going through
            // `insertText(_:replacementRange:)`, and that is exactly the
            // bookkeeping `insertText` does for us: it commits or discards the
            // marked text and tells the input context about it. A raw
            // `replaceCharacters` moves the composition's characters out from
            // under a `markedRange` that is left pointing at them, so the next
            // composition update writes at an offset that no longer describes
            // anything. `false` hands the key back to AppKit's own `insertTab:`,
            // which is what this key did before the feature existed — the same
            // guard `handleCompletionKey` above takes, for the same reason.
            guard !textView.hasMarkedText() else { return false }
            // The rule is asked, never restated: whether the key inserts spaces at
            // all is `IndentUnitRule.tabInsertion`'s decision, and this reads only
            // its answer. Pre-checking `indent_style` here would put half of that
            // decision in the view layer and buy nothing, because the `inferred:`
            // argument is an **autoclosure**: a configuration that answers a
            // literal tab — the no-`.editorconfig` case, the overwhelmingly common
            // one — never evaluates it, and neither does a fully-stated
            // `indent_style = space` + `indent_size`. Only spaces of an unstated
            // width read the buffer, to carry the file's own width over. That
            // laziness is what matters: `textView.string` bridges a mutable
            // `NSTextStorage`, so reading it copies the whole buffer, and
            // `inferIndentUnit` then walks every line of the copy — the very
            // main-thread cost `textDidChange` above is careful to avoid.
            let insertion = IndentUnitRule.tabInsertion(
                config: editorConfigProperties(),
                inferred: IndentEngine.inferIndentUnit(text: textView.string as NSString)
            )
            guard insertion != "\t" else { return false }
            guard let textStorage = textView.textStorage else { return false }

            let ranges = (textView.selectedRanges as [NSValue]).map(\.rangeValue)
            let plan = IndentUnitRule.tabInsertionPlan(ranges: ranges, insertion: insertion)
            guard !plan.isEmpty else { return false }

            // The guard covers the whole bracket, not just the storage mutation:
            // `shouldChangeText(inRanges:replacementStrings:)` reaches the
            // single-range delegate callback when there is exactly one range, and
            // a one-character insertion there is precisely what the auto-pair
            // interceptor acts on.
            isApplyingProgrammaticEdit = true
            defer { isApplyingProgrammaticEdit = false }
            let editedRanges = plan.replacements.map { NSValue(range: $0.range) }
            let replacements = plan.replacements.map(\.replacement)
            // A refusal is *not* "handled": returning `true` would eat the key and
            // do nothing, where `false` hands it back to the responder chain, the
            // same as the literal-tab answer above.
            guard textView.shouldChangeText(
                inRanges: editedRanges,
                replacementStrings: replacements
            ) else { return false }
            // The spaces carry `typingAttributes` explicitly. Every other
            // programmatic edit here goes through `insertText(_:replacementRange:)`,
            // which applies them; the raw storage path (which the multi-range
            // fan-out needs) would otherwise inherit whatever the adjacent text
            // has — and in a buffer with no adjacent text, no font at all.
            let attributes = textView.typingAttributes
            textStorage.beginEditing()
            for replacement in plan.replacements.reversed() {
                textStorage.replaceCharacters(
                    in: replacement.range,
                    with: NSAttributedString(string: replacement.replacement, attributes: attributes)
                )
            }
            textStorage.endEditing()
            textView.didChangeText()
            textView.setSelectedRanges(
                plan.carets.map { NSValue(range: $0) },
                affinity: .downstream,
                stillSelecting: false
            )
            // The one thing the raw-storage path does not inherit. Every other
            // programmatic edit here goes through `insertText(_:replacementRange:)`,
            // which scrolls the insertion point into view; `setSelectedRanges` and
            // `didChangeText()` do not, and neither does
            // `textViewDidChangeSelection`. Without this, Tab under
            // `indent_style = space` would type into a scrolled-away caret while a
            // literal tab — the same key, one property apart — jumps back to it.
            // The *first* caret, which is what `selectedRange()` reports for a
            // multi-range selection and therefore what the native key scrolls to.
            //
            // **The one scroll in this file that is not the reveal funnel**, and
            // named rather than routed. It re-shows a caret `setSelectedRanges`
            // above has just produced, which the fold caret rule has already
            // sanitized through `textViewDidChangeSelection` — so it can never
            // target hidden text, and asking `revealRange` here would put the
            // reveal rule a question whose answer is always "nothing to unfold".
            if let caret = plan.carets.first { textView.scrollRangeToVisible(caret) }
            return true
        }

        /// Intercept Backspace so an empty auto-inserted pair `(|)`, `"|"`, … is
        /// deleted whole.
        ///
        /// When the selection is empty and `AutoPairEngine.shouldDeletePair`
        /// confirms the caret sits between a matching opener/closer, the two
        /// characters are removed in one `insertText("", replacementRange:)` (so a
        /// single undo restores both) and `true` suppresses the default delete.
        /// Every other Backspace passes through unchanged (`false`).
        private func deleteAutoPair(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return false }
            let nsText = textView.string as NSString
            guard AutoPairEngine.shouldDeletePair(
                text: nsText,
                location: selectedRange.location
            ) else { return false }

            let pairRange = NSRange(location: selectedRange.location - 1, length: 2)
            isApplyingProgrammaticEdit = true
            textView.insertText("", replacementRange: pairRange)
            isApplyingProgrammaticEdit = false
            return true
        }

        private func insertIndentedNewline(in textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            let nsText = textView.string as NSString
            let unit = indentUnit(text: nsText)
            let edit = IndentEngine.newlineIndentation(
                text: nsText,
                location: selectedRange.location,
                unit: unit,
                selectionLength: selectedRange.length,
                terminator: newlineTerminator()
            )
            // Replace the selection (a bare caret has length 0) with the computed
            // newline+indent. `consumeAfter` extends the range to also delete
            // trailing whitespace just past the selection (the opener case), so it
            // doesn't stack on the freshly inserted indent. `insertText` records the
            // edit on the active (per-file) undo manager and posts the change
            // notification that updates the binding.
            let replacementRange = NSRange(
                location: selectedRange.location,
                length: selectedRange.length + edit.consumeAfter
            )
            isApplyingProgrammaticEdit = true
            textView.insertText(edit.text, replacementRange: replacementRange)
            isApplyingProgrammaticEdit = false
            // Place the caret at the engine's offset — which, for the
            // between-brackets split, sits on the indented middle line rather than
            // after the whole inserted string.
            textView.setSelectedRange(
                NSRange(location: selectedRange.location + edit.cursorOffset, length: 0)
            )
            return true
        }

        // MARK: - Duplicate line/selection

        /// Duplicate the caret's line (or the selection) — the Cmd+D handler.
        ///
        /// All the math is pure and lives in `PisakaCore.DuplicateEngine`; this
        /// reads the live buffer + selection, applies the engine's edit with one
        /// `insertText(_:replacementRange:)` at a zero-length range (so the
        /// per-file undo manager records the whole duplication as a single
        /// undoable step), then installs the resulting selection — a caret inside
        /// the copied line, or the inserted copy itself for a selection, so
        /// repeated presses grow the text.
        ///
        /// `isApplyingProgrammaticEdit` is mandatory here, not defensive:
        /// `insertText` re-invokes `shouldChangeTextIn` synchronously and the
        /// auto-pair interceptor fires on any single-character replacement, so
        /// duplicating a one-character *selection* holding a lone `(` would
        /// otherwise fall into auto-pair and insert `()`. (The line path can emit
        /// a single character too — duplicating an *empty* line inserts just
        /// `"\n"` — so the guard covers both paths unconditionally.)
        ///
        /// Always returns `true` (the key is consumed).
        func duplicateSelection(in textView: NSTextView) -> Bool {
            let edit = DuplicateEngine.duplicate(
                text: textView.string as NSString,
                selectedRange: textView.selectedRange()
            )
            isApplyingProgrammaticEdit = true
            textView.insertText(
                edit.text,
                replacementRange: NSRange(location: edit.insertionLocation, length: 0)
            )
            isApplyingProgrammaticEdit = false
            textView.setSelectedRange(edit.selectedRange)
            return true
        }

        func toggleComment(in textView: NSTextView) {
            guard let edit = ToggleCommentEngine.toggle(
                text: textView.string as NSString,
                selectedRange: textView.selectedRange(),
                language: language
            ) else { return }
            isApplyingProgrammaticEdit = true
            textView.insertText(
                edit.text,
                replacementRange: edit.replacementRange
            )
            isApplyingProgrammaticEdit = false
            textView.setSelectedRange(edit.selectedRange)
        }

        /// Intercept single-character input for auto-close brackets/quotes and,
        /// for a closing bracket that doesn't auto-pair, the dedent-on-closing
        /// rewrite.
        ///
        /// All the decision logic is pure and lives in `PisakaCore.AutoPairEngine`
        /// (auto-pair) and `IndentEngine` (dedent); this reads the live buffer +
        /// selection, applies the chosen edit via `insertText(_:replacementRange:)`
        /// (so the per-file undo manager records it as one ordinary, single-step
        /// edit), repositions the caret, and returns `false` to suppress the
        /// default insertion. Every other change passes through unchanged (`true`).
        ///
        /// `isApplyingProgrammaticEdit` guards re-entry: `insertText` re-invokes
        /// this synchronously, so the programmatic auto-pair/dedit edit must pass
        /// through untouched rather than re-triggering auto-pairing on itself.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard
                !isApplyingProgrammaticEdit,
                // The find bar's replace commands go through `insertText` too, so
                // they need the same exemption: replacing a match with `(` would
                // otherwise be auto-closed into `()`.
                !searchController.isApplyingEdit,
                let replacementString,
                replacementString.count == 1
            else { return true }

            let nsText = textView.string as NSString
            switch AutoPairEngine.action(
                text: nsText,
                selectedRange: affectedCharRange,
                typed: replacementString
            ) {
            case .wrap(let open, let close):
                // Surround the selection with the pair in one edit; leave the
                // selection on the (unchanged) inner text between the inserted
                // delimiters.
                let inner = nsText.substring(with: affectedCharRange)
                isApplyingProgrammaticEdit = true
                textView.insertText(open + inner + close, replacementRange: affectedCharRange)
                isApplyingProgrammaticEdit = false
                textView.setSelectedRange(
                    NSRange(location: affectedCharRange.location + (open as NSString).length,
                            length: (inner as NSString).length)
                )
                return false

            case .insertPair(let close):
                // Insert opener+closer, then drop the caret between them.
                isApplyingProgrammaticEdit = true
                textView.insertText(replacementString + close, replacementRange: affectedCharRange)
                isApplyingProgrammaticEdit = false
                textView.setSelectedRange(
                    NSRange(location: affectedCharRange.location + (replacementString as NSString).length, length: 0)
                )
                return false

            case .typeOver:
                // The identical closer already sits after the caret: step over it
                // instead of inserting a duplicate.
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false

            case .passthrough:
                return applyDedentIfNeeded(in: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
            }
        }

        /// The dedent-on-closing path, reached only when auto-pair passed the
        /// keystroke through. When the replacement is a single `}`/`)`/`]` on a
        /// whitespace-only line prefix and `IndentEngine` finds a matching opener,
        /// this rewrites the leading-whitespace range *and* inserts the bracket in
        /// one `insertText(_:replacementRange:)` (a single undoable edit) and
        /// returns `false`; otherwise the keystroke passes through (`true`).
        private func applyDedentIfNeeded(
            in textView: NSTextView,
            affectedCharRange: NSRange,
            replacementString: String
        ) -> Bool {
            guard
                affectedCharRange.length == 0,
                let closing = replacementString.first,
                closing == "}" || closing == ")" || closing == "]"
            else { return true }

            let nsText = textView.string as NSString
            guard let replacement = IndentEngine.dedentOnClosing(
                text: nsText,
                location: affectedCharRange.location,
                closing: closing
            ) else { return true }

            // Rewrite the leading whitespace and add the bracket in one edit, so a
            // single undo reverses the dedent together with the typed character.
            isApplyingProgrammaticEdit = true
            textView.insertText(
                replacement.replacement + String(closing),
                replacementRange: replacement.range
            )
            isApplyingProgrammaticEdit = false
            return false
        }

        // MARK: - Minimap sync

        /// Wire the editor and minimap together. Observes the clip view's scroll
        /// (bounds) and size (frame) plus the text view's content height (frame)
        /// to keep the minimap geometry/viewport rectangle current, and routes
        /// the minimap's drag callback back into the clip view.
        func attachMinimap(scrollView: NSScrollView, textView: NSTextView, minimap: MinimapView) {
            self.scrollView = scrollView
            self.textView = textView
            self.minimap = minimap

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            textView.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            center.addObserver(
                self,
                selector: #selector(syncableFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
            center.addObserver(
                self,
                selector: #selector(syncableFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: textView
            )

            // Minimap → editor: the minimap reports the cursor's panel y (the
            // desired viewport center); the geometry solves directly for the
            // document scroll offset whose viewport rectangle is centered there,
            // and we scroll the clip view. The bounds notification then moves the
            // viewport rectangle back (closed loop).
            minimap.onScroll = { [weak self] centerY in
                guard let self, let minimap = self.minimap else { return }
                let offset = minimap.geometry.scrollOffset(forMinimapCenterY: centerY)
                self.scrollEditor(to: offset)
            }

            // Minimap wheel → editor: the minimap has already mapped the wheel's
            // panel-space delta to an absolute document offset; scroll the clip
            // view there and let the bounds notification move the rectangle.
            minimap.onScrollToOffset = { [weak self] offset in
                self?.scrollEditor(to: offset)
            }
        }

        /// The clip view scrolled: move the minimap's viewport rectangle and
        /// re-apply the rainbow colors and the search-match backgrounds for the
        /// newly revealed range. Neither the bracket tokens nor the search matches
        /// are changed by a scroll, so this only re-resolves *which* of them are on
        /// screen — no rescan, no re-search.
        @objc private func clipViewBoundsChanged() {
            // A scroll moves the text out from under a popover anchored to screen
            // coordinates, so it comes down. Reusing this observation — the one
            // the minimap already installs — rather than adding a second is the
            // point: two observers of the same notification would eventually
            // disagree about what a scroll is.
            hover.dismiss()
            // Routed through the controller rather than dismissed here: it can
            // tell a user scroll (panel down) from the text view's own
            // insertion-point autoscroll — a keystroke past the right edge of
            // an unwrapped line, Enter at the bottom edge, an arrow along a
            // long word — which must keep the list up and narrowing, not kill
            // it mid-word (see `clipViewDidScroll`). Like the resign-key and
            // end-editing handlers it does nothing when nothing is shown,
            // leaving the post-commit D4 state alone.
            completion.clipViewDidScroll()
            refreshGeometry()
            bracketHighlight.refreshVisible()
            searchController.refreshVisibleHighlight()
        }

        /// The clip view resized or the document height changed: rebuild geometry.
        /// A resize changes the visible range too, so the brackets and the search
        /// matches are re-applied (again without a rescan) — which is also what
        /// paints them the first time, since the view has no layout yet when
        /// `makeNSView` seeds the scan.
        @objc private func syncableFrameChanged() {
            // Same reasoning as the scroll above, and the same reasoning as the
            // font change: a reflow moves the text out from under the *hover*
            // popover, which is anchored in screen coordinates under a still
            // pointer. Unlike a scroll, this one can happen with the pointer
            // perfectly still — a window resized from the keyboard, the bottom
            // panel toggled, the sidebar dragged — so the next mouse-moved event
            // cannot be relied on to clean it up.
            hover.dismiss()
            // The completion panel is deliberately *not* dismissed here: a frame
            // change fires for ordinary typing (a character that grows the
            // document), and dismissing would cancel the debounced narrowing
            // request on every such keystroke — the list would close instead of
            // narrowing with the first row still selected. The panel's anchor is
            // recomputed from the live text view on every presentation, and any
            // real viewport movement reports through the bounds notification,
            // which does dismiss it.
            refreshGeometry()
            bracketHighlight.refreshVisible()
            searchController.refreshVisibleHighlight()
        }

        /// Recompute `MinimapGeometry` from the live document/viewport/minimap
        /// heights and push the current scroll offset and fixed row height to the
        /// minimap (it derives the content slide itself from geometry + offset).
        /// The clip view of a flipped document view reports `bounds.origin.y`
        /// already in the geometry's top-down convention.
        func refreshGeometry() {
            guard let scrollView, let textView, let minimap else { return }
            let clipView = scrollView.contentView
            // Scale from the gutter's synchronous line count, which tracks the live
            // document for every file. The minimap's own `model.lineCount` is filled
            // asynchronously (it is 0/`.empty` for plain or unsupported files and
            // briefly stale right after a tab switch), which would otherwise leave
            // wheel scrolling dead or mis-scaled. Fall back to the model only if the
            // ruler is somehow unavailable.
            let lineCount = lineNumberRuler?.lineCount ?? minimap.model.lineCount
            let contentHeight = CGFloat(lineCount) * minimapLineHeight
            let geometry = MinimapGeometry(
                documentHeight: textView.frame.height,
                viewportHeight: clipView.bounds.height,
                minimapHeight: minimap.bounds.height,
                contentHeight: contentHeight
            )
            minimap.geometry = geometry
            minimap.minimapLineHeight = minimapLineHeight
            minimap.scrollOffset = clipView.bounds.origin.y
        }

        /// Scroll the editor's clip view to a document-space top offset (clamped),
        /// converting back into AppKit's coordinates. `reflectScrolledClipView`
        /// fires the bounds notification that updates the minimap rectangle.
        func scrollEditor(to offset: CGFloat) {
            guard let scrollView, let textView else { return }
            let clipView = scrollView.contentView
            let maxOffset = max(0, textView.frame.height - clipView.bounds.height)
            let y = min(max(offset, 0), maxOffset)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Recompute the minimap overview for the given input. The tokenizer
        /// debounces and skips unchanged (file, text, language) inputs; on a real
        /// change it swaps the model on the main actor and we redraw + re-sync.
        func updateMinimap(text: String, language: SyntaxLanguage?, fileID: UUID, immediate: Bool) {
            tokenizer.update(
                text: text,
                language: language,
                fileID: fileID,
                immediate: immediate
            ) { [weak self] in
                guard let self, let minimap = self.minimap else { return }
                minimap.model = self.tokenizer.model
                self.refreshGeometry()
            }
        }

        /// Remove all observers (including the bracket overlays' text-storage
        /// observer) and cancel any in-flight parse or bracket rescan. Called from
        /// `dismantleNSView` so a closed tab leaves nothing behind.
        func teardown() {
            NotificationCenter.default.removeObserver(self)
            tokenizer.reset()
            bracketHighlight.reset()
            // Drops the match highlight and unregisters this editor from the
            // (window-scoped, longer-lived) bar state, so a torn-down tab can't
            // keep serving its commands.
            searchController.reset()
            searchBarState = nil
            // Drops the candidate snapshot and supersedes an in-flight provider
            // call, so a torn-down tab can neither serve a closed file's
            // identifiers nor open a popup over the tab that replaced it.
            completion.reset()
            // Takes the popover down, supersedes an in-flight hover answer and
            // stops observing the key-window notification, so a torn-down tab
            // cannot leave a floating annotation of a closed file on screen.
            hover.reset()
            // Empties the column, supersedes an in-flight blame load and drops the
            // per-tab annotate state wholesale (see `BlameController.enabledFileIDs`
            // on why nothing prunes it before this point).
            blame.reset()
            // Supersedes an in-flight fold answer and empties both halves of the
            // hiding, so a torn-down tab cannot leave a closed file's text hidden
            // in the view that replaces it. The memory is dropped with the
            // controller — it lives for the app run, not beyond this editor.
            folds.reset()
            // Ends the store observation and cancels a queued repaint, so a
            // torn-down tab can neither repaint squiggles for a closed file nor
            // keep the app's diagnostics model alive through the subscription.
            diagnosticsSubscription?.cancel()
            diagnosticsSubscription = nil
            pendingDiagnosticRepaint?.cancel()
            pendingDiagnosticRepaint = nil
        }

        /// The undo manager NSTextView should use for the currently shown file.
        /// Returns a stable per-file instance so switching tabs preserves each
        /// file's undo stack instead of clearing or cross-contaminating it.
        func undoManager(for view: NSTextView) -> UndoManager? {
            guard let fileID else { return view.undoManager }
            if let existing = undoManagers[fileID] { return existing }
            let manager = UndoManager()
            undoManagers[fileID] = manager
            return manager
        }

        /// Removes every per-file dictionary's entries for files no longer open:
        /// the undo managers, the external-replacement tokens and the remembered
        /// viewports. Without this, closing a tab would leave its undo manager
        /// (and the text snapshots it holds) alive for the lifetime of the
        /// coordinator, and reopening the file would resume at a position from a
        /// previous life rather than at the top.
        ///
        /// All three are keyed by `OpenFile.id` and pruned together on purpose:
        /// they answer the same question about the same object, so they must not
        /// disagree about which files still exist.
        func prunePerFileState(keeping openFileIDs: Set<UUID>) {
            undoManagers = undoManagers.filter { openFileIDs.contains($0.key) }
            externalTextRevisions = externalTextRevisions.filter { openFileIDs.contains($0.key) }
            viewports.prune(keeping: openFileIDs)
        }

        // MARK: - Viewport memory

        /// Where the text view is *right now*: the selection and the character at
        /// the top of the visible rectangle.
        ///
        /// The scroll anchor is resolved to a character offset rather than kept as
        /// a point, for the reason `EditorViewport` documents: the geometry that
        /// produced the point does not survive a code-zoom change, a font change,
        /// a window resize or a rewrite of the text.
        ///
        /// The hit test goes through `NSTextView.characterIndexForInsertion(at:)`
        /// rather than the layout manager's `glyphIndex(for:in:)`. It takes the
        /// point in the *text view's* coordinates — which `documentVisibleRect`
        /// already is, so no container-origin correction — answers a character
        /// index directly, and is clamped rather than raising, so it needs no
        /// bounds guard. That last part is the reason for the choice:
        /// `NSLayoutManager.numberOfGlyphs`, the only way to write such a guard,
        /// forces glyph generation for the *entire* document, which would put an
        /// O(file size) main-thread cost on every single tab switch — exactly what
        /// `allowsNonContiguousLayout` (see `makeNSView`) exists to avoid.
        ///
        /// Answers `nil` only when the views are gone (a torn-down tab); an empty
        /// buffer anchors at `0`.
        func captureViewport() -> EditorViewport? {
            guard let textView, let scrollView else { return nil }
            let visible = scrollView.documentVisibleRect
            return EditorViewport(
                selection: textView.selectedRange(),
                topCharacterOffset: textView.characterIndexForInsertion(
                    at: NSPoint(x: visible.minX, y: visible.minY)
                )
            )
        }

        /// Remember where `fileID` is currently sitting. Must be called *before*
        /// anything touches the buffer: the text view is reused, so once the
        /// incoming file's text is installed the outgoing position is gone.
        func recordViewport(for fileID: UUID) {
            guard let viewport = captureViewport() else { return }
            viewports.record(viewport, for: fileID)
        }

        /// Drop `fileID`'s remembered position — its text was replaced out from
        /// under it, so the recorded offsets describe characters that no longer
        /// exist. The next visit starts at the top, exactly as a first visit does.
        func forgetViewport(for fileID: UUID) {
            viewports.forget(fileID)
        }

        /// Put `fileID` back where it was left — or at the top of the file when
        /// nothing was recorded for it.
        ///
        /// **The "nothing recorded" case has to be spelled out, not skipped.**
        /// A first visit, a closed-and-reopened tab and a tab whose text was
        /// replaced from outside all arrive here with no entry, and the intended
        /// outcome for all three is a plain top-of-file state. Leaving the text
        /// view alone does not produce that: assigning `textView.string` (the
        /// buffer swap in `updateNSView`) leaves the caret at the *end* of the new
        /// contents, and the clip view keeps the outgoing tab's scroll offset. So
        /// the top is set explicitly.
        ///
        /// Everything here is synchronous, unlike the reveal path's one-turn hop
        /// (`applyReveal`). It has to be: a restore deferred to the next main-loop
        /// turn would run after a *second* tab switch had already swapped the
        /// buffer again, scrolling the newly shown file to the previous file's
        /// offset. What makes synchronous work is the explicit `ensureLayout`
        /// below — the layout manager runs with `allowsNonContiguousLayout`, so
        /// the incoming text is not laid out yet at this point in `updateNSView`
        /// and the anchor's rectangle would otherwise be an estimate.
        ///
        /// That `ensureLayout` is the one real cost of this feature and it is not
        /// free: the anchor's *position* is the sum of every preceding line's
        /// height, so the layout has to run from offset 0 to the anchor, and it is
        /// paid again on every switch back (the buffer swap invalidates layout).
        /// It is bounded by how far into the file the tab was left, so it is
        /// negligible for ordinary source files and measurable — order 0.5s — for
        /// a multi-megabyte file left scrolled near its end. Accepted knowingly:
        /// the alternative is a non-contiguous *estimate*, which lands the restore
        /// on the wrong line, and there is no third option that yields an exact
        /// document-space `y` without laying out what is above it.
        ///
        /// The range comes back clamped to the live buffer (`EditorViewport
        /// .clamped(toLength:)`), and the scroll goes through `scrollEditor(to:)`,
        /// which clamps to the document's real end — so neither a shrunken file
        /// nor a stale anchor can position past the end.
        func restoreViewport(for fileID: UUID) {
            guard let textView else { return }
            let length = textView.textStorage?.length ?? 0
            guard let viewport = viewports.viewport(for: fileID, clampedToLength: length) else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                scrollEditor(to: 0)
                return
            }
            // A caret at `length` is a legal selection (the end of the file), so
            // the selection needs no end-of-buffer special case. The anchor needs
            // none either: `clamped(toLength:)` guarantees it names a character
            // that exists, so there is exactly one path below.
            textView.setSelectedRange(viewport.selection)
            scrollAnchor(to: viewport.topCharacterOffset)
        }

        /// Scroll so the character at `anchor` sits at the top of the viewport,
        /// leaving the selection alone.
        ///
        /// The scroll half of `restoreViewport(for:)`, split out because the save
        /// transform needs exactly this and nothing else: it has already put the
        /// remapped selection back through the text view, and must move the page
        /// only far enough to keep the same character on the top line after an
        /// edit that may have deleted characters above it.
        ///
        /// `anchor` is clamped to a character that exists, so an offset that
        /// outran a shrunken buffer resolves to the last line rather than to
        /// nothing.
        func scrollAnchor(to anchor: Int) {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            let length = textView.textStorage?.length ?? 0
            guard length > 0 else {
                scrollEditor(to: 0)
                return
            }
            let anchor = min(max(anchor, 0), length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: anchor + 1))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: anchor, length: 1),
                actualCharacterRange: nil
            )
            // Back from container space into the document's, i.e. the coordinates
            // `scrollEditor(to:)` scrolls the clip view in.
            let top = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).minY
                + textView.textContainerOrigin.y
            // The anchor's own `y` is exact — everything above it was just laid
            // out — but `scrollEditor(to:)` clamps against `textView.frame.height`,
            // and *that* is still an estimate for whatever sits below the anchor.
            // A tab left within the last screenful of its file would be clamped
            // short by the size of that error (measured: ~220pt, a dozen-odd
            // lines, on a 3000-line file left at the bottom). So when the clamp is
            // about to bind, finish the layout first. It is self-limiting: the
            // clamp only binds near the end of the document, and by then
            // everything above the anchor is laid out already, so this costs the
            // remaining tail rather than the file.
            if let scrollView,
               top > max(0, textView.frame.height - scrollView.contentView.bounds.height) {
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
            }
            scrollEditor(to: top)
        }

        /// The `WorkspaceModel.textReplacementRevision(for:)` value last seen for
        /// each file this coordinator has displayed.
        private var externalTextRevisions: [UUID: Int] = [:]

        /// Record `revision` as the current external-replacement token for
        /// `fileID` and report whether it *changed* since this coordinator last
        /// displayed that file.
        ///
        /// `false` for a file being shown for the first time: there is no recorded
        /// value to compare against and no undo history to invalidate yet.
        func noteExternalTextRevision(_ revision: Int, for fileID: UUID) -> Bool {
            defer { externalTextRevisions[fileID] = revision }
            guard let previous = externalTextRevisions[fileID] else { return false }
            return previous != revision
        }

        /// Detach the active highlighter (if any) from the text view's storage.
        ///
        /// Called before a wholesale buffer replacement so the outgoing grammar
        /// doesn't observe — and asynchronously repaint — the incoming file's
        /// text. `updateHighlighter` rebuilds afterward.
        func detachHighlighter(from textView: NSTextView) {
            highlighter = nil
            textView.textStorage?.delegate = nil
        }

        /// Attach, swap, or detach the highlighter so it matches `language`.
        ///
        /// - When the language changes, the existing highlighter is torn down and
        ///   a fresh one is built for the new grammar (or none, for plain text).
        /// - When the language is unchanged but `contentReplaced` is `true` (a
        ///   switch between two files of the same language), the buffer was
        ///   swapped wholesale and the previous highlighter detached, so a fresh
        ///   one is built to parse the new text from a clean tree.
        func updateHighlighter(
            for textView: NSTextView,
            language: SyntaxLanguage?,
            contentReplaced: Bool
        ) {
            let languageChanged = language != self.language
            self.language = language
            if languageChanged || contentReplaced {
                rebuildHighlighter(for: textView, language: language)
            }
        }

        /// Tears down the current highlighter and, if `language` resolves to a
        /// loadable grammar, builds a new one whose attribute provider maps each
        /// tree-sitter capture name through `SyntaxTokenKind` to a theme color.
        private func rebuildHighlighter(for textView: NSTextView, language: SyntaxLanguage?) {
            // Supersede any previous highlighter. Detaching it (below) stops it
            // observing further edits, but Neon parses/styles partly via
            // MainActor-isolated async work that reads the *reused* text view's
            // storage live. Already-scheduled styling from the outgoing grammar
            // could therefore run after the buffer was swapped. Advancing the
            // generation lets that stale work resolve to no attributes (see the
            // attribute provider) so it can't paint a *previous grammar's colors*
            // onto the current file.
            //
            // Note this guard bounds the damage to miscolouring, not to nothing:
            // Neon's `LayoutManagerSystemInterface.applyStyles` clears the token
            // range's temporary attributes *before* it consults the attribute
            // provider, and its async validator only checks the content version
            // before awaiting the parse, not after. So a stale parse that resumes
            // post-swap can still transiently *clear* (never miscolour) styling
            // over its range; the live highlighter repaints it on the next
            // validation (scroll/edit). Fully eliminating that transient needs a
            // per-file text view (so a superseded highlighter can't reach the
            // visible layout manager) — an architectural change left as follow-up.
            let generation = highlighterGeneration.advance()

            // Detach the old highlighter (it is the text storage's delegate).
            highlighter = nil
            textView.textStorage?.delegate = nil

            guard
                let language,
                let languageConfiguration = SyntaxLanguageConfiguration.configuration(for: language)
            else {
                // Untitled / unknown extension: plain text, no highlighter.
                // Clear any colors a previous highlighter left behind (e.g. a
                // highlighted file "Saved As" to an unknown extension, where the
                // buffer text is unchanged so it isn't replaced).
                //
                // The text view is TextKit 1 (`usingTextLayoutManager: false`), so
                // Neon styled it through `LayoutManagerSystemInterface`, which
                // writes *temporary attributes* on the layout manager rather than
                // attributes on the text storage. Clearing the storage's
                // foreground color alone would leave the old syntax colors visible;
                // the temporary attributes must be cleared too.
                if let textStorage = textView.textStorage, textStorage.length > 0 {
                    let fullRange = NSRange(location: 0, length: textStorage.length)
                    textView.layoutManager?.setTemporaryAttributes([:], forCharacterRange: fullRange)
                    textStorage.removeAttribute(.foregroundColor, range: fullRange)
                    textStorage.addAttribute(
                        .foregroundColor,
                        value: textView.textColor ?? .labelColor,
                        range: fullRange
                    )
                }
                return
            }

            let theme = SyntaxTheme.shared
            // Capture the generation counter (a reference type, not the
            // `@MainActor` coordinator) so the provider stays free of
            // actor-isolated state. A stale highlighter — one built before a
            // later rebuild advanced the counter — yields no attributes, so its
            // lingering async styling can't paint a previous grammar's colors
            // onto the current buffer (it may still transiently clear styling —
            // see `rebuildHighlighter`).
            let highlighterGeneration = self.highlighterGeneration
            let attributeProvider: TokenAttributeProvider = { token in
                guard highlighterGeneration.current == generation else { return [:] }
                let kind = SyntaxTokenKind(captureName: token.name)
                return [.foregroundColor: theme.nsColor(for: kind)]
            }

            let configuration = TextViewHighlighter.Configuration(
                languageConfiguration: languageConfiguration,
                attributeProvider: attributeProvider,
                // Resolve injected sub-languages (e.g. Markdown's `markdown_inline`
                // for emphasis/links/code spans, fenced code blocks, embedded
                // HTML/YAML). Without this, injections stay unhighlighted.
                languageProvider: { name in
                    SyntaxLanguageConfiguration.configuration(forInjectionName: name)
                },
                locationTransformer: { _ in nil }
            )

            // A grammar that fails to start the parser degrades to plain text
            // rather than crashing the editor.
            highlighter = try? TextViewHighlighter(textView: textView, configuration: configuration)
        }
    }
}

/// Lays out the editor's scroll view and the minimap side by side: the scroll
/// view fills the area left of a fixed-width minimap pinned to the right edge.
///
/// On each `layout()` it repositions both subviews and invokes `onLayout`, which
/// the coordinator uses to recompute `MinimapGeometry` for the new size (so the
/// minimap stays correct across window/split resizes).
@MainActor
final class EditorContainerView: NSView {
    private let scrollView: NSScrollView
    private let minimap: MinimapView

    /// Fixed width of the minimap gutter, in points.
    private let minimapWidth: CGFloat = 80

    /// Invoked after each layout pass (resize) so the owner can refresh geometry.
    var onLayout: (() -> Void)?

    init(scrollView: NSScrollView, minimap: MinimapView) {
        self.scrollView = scrollView
        self.minimap = minimap
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(minimap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let gutter = min(minimapWidth, width)
        let editorWidth = max(0, width - gutter)
        scrollView.frame = NSRect(x: 0, y: 0, width: editorWidth, height: height)
        minimap.frame = NSRect(x: editorWidth, y: 0, width: gutter, height: height)
        onLayout?()
    }
}

/// The editor's `NSTextView`, adding only the Cmd+D duplicate-line/selection key
/// over the stock behavior and declaring itself the code zoom surface. A plain
/// `NSTextView` otherwise (TextKit 1, configured by `CodeEditorView.makeNSView`).
@MainActor
final class EditorTextView: NSTextView, ZoomSurfaceProviding {
    /// The editor is the code zone's own surface: a zoom gesture over it grows
    /// the shared editor font, and the gutter and minimap follow because they are
    /// drawn from that same size. Declared here rather than handled here — the
    /// app's one event monitor resolves and applies it (`ZoomController`).
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    /// Duplicates the caret's line (or the selection) on Cmd+D, returning whether
    /// it handled the key. Set by `CodeEditorView.makeNSView` to the coordinator's
    /// `duplicateSelection(in:)`; `nil` until then.
    var onDuplicate: ((NSTextView) -> Bool)?

    /// Closes an open find bar on Esc, returning whether it did. Set by
    /// `CodeEditorView.makeNSView` to the coordinator's `closeSearchBar()`; `nil`
    /// until then.
    var onCancelSearch: (() -> Bool)?

    /// Jumps to the declaration of the identifier at a UTF-16 offset (a ⌘-click's
    /// character index, or the caret's for the ⌃⌘J menu item). Set by
    /// `CodeEditorView.makeNSView` to the coordinator's
    /// `goToDefinition(in:at:)`; `nil` until then.
    var onGoToDefinition: ((NSTextView, Int) -> Void)?

    /// Lists every usage of the identifier at a UTF-16 offset (the caret's for
    /// ⌃⌘U, the clicked one for the context menu). Set by
    /// `CodeEditorView.makeNSView` to the coordinator's `findUsages(in:at:)`;
    /// `nil` until then.
    var onFindUsages: ((NSTextView, Int) -> Void)?

    /// Renames the identifier at a UTF-16 offset (the caret's for ⌃⌘R, the
    /// clicked one for the context menu). Set by `CodeEditorView.makeNSView` to
    /// the coordinator's `renameSymbol(in:at:)`; `nil` until then.
    var onRenameSymbol: ((NSTextView, Int) -> Void)?

    /// Toggles the comment state of the selected lines on Cmd+/. Set by
    /// `CodeEditorView.makeNSView` to the coordinator's
    /// `toggleComment(in:)`; `nil` until then.
    var onToggleComment: ((NSTextView) -> Void)?

    /// Recomputes the completion candidates immediately and opens the popup over
    /// them. Set by `CodeEditorView.makeNSView` to the coordinator's
    /// `requestCompletions()`; `nil` until then.
    var onRequestCompletions: (() -> Void)?

    /// Intercepts keys for the completion popup (Return, Tab, Up, Down) before
    /// they reach the editor. Set by `CodeEditorView.makeNSView`.
    var onCompletionKey: ((NSEvent) -> Bool)?

    /// Closes an open completion popup on Esc, returning whether it did. Set by
    /// `CodeEditorView.makeNSView`.
    var onCancelCompletion: (() -> Bool)?

    /// Reports where the pointer is over the text, in this view's coordinates, so
    /// the hover controller can resolve the character under it. Set by
    /// `CodeEditorView.makeNSView` to the coordinator's `pointerMoved(to:in:)`;
    /// `nil` until then.
    var onPointerMoved: ((NSTextView, NSPoint) -> Void)?

    /// Reports that the pointer left the text: whatever a popover was describing,
    /// the pointer is no longer on it. Set by `CodeEditorView.makeNSView`.
    var onPointerExited: (() -> Void)?

    /// The hover feature's own tracking area, kept so it can be replaced rather
    /// than accumulated — `updateTrackingAreas` runs on every resize.
    private var hoverTrackingArea: NSTrackingArea?

    /// Install (or reinstall) the tracking area hover is driven by.
    ///
    /// `.inVisibleRect` is what scopes it to the *visible* rect and — crucially —
    /// keeps it there: AppKit resizes such an area itself as the view scrolls
    /// inside its clip view, so the passed rect is ignored and there is no
    /// scroll-position staleness to manage. `.activeInKeyWindow` scopes it to the
    /// window the user is working in, which is the only one a popover may appear
    /// over; `super` keeps every tracking area `NSTextView` installs for its own
    /// cursor and link handling.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?(self, convert(event.locationInWindow, from: nil))
    }

    /// Only *this* area's exit is the pointer leaving the text. `NSTextView`
    /// installs tracking areas of its own (cursor rects, link hovering), and
    /// treating their exits as ours would dismiss a popover the pointer never
    /// left.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === hoverTrackingArea else { return }
        onPointerExited?()
    }

    /// Complete from the caret — the entry point shared by this view's own ⌃Space
    /// (`keyDown`), the Find menu's "Complete" (which reaches this view as the
    /// key window's first responder, exactly like ⌃⌘J), and AppKit's stock
    /// ⌥⎋/F5 completion command.
    ///
    /// The popup is *not* opened here: the request is handed to the coordinator's
    /// completion controller, which computes candidates asynchronously and opens
    /// its own panel behind the staleness guards the moment the provider
    /// answers. Overriding this is what retires AppKit's native popup — no stock
    /// invocation can ever reach it.
    override func complete(_ sender: Any?) {
        onRequestCompletions?()
    }

    /// Go to Definition from the caret — the Find menu's ⌃⌘J entry point, which
    /// reaches this view as the key window's first responder rather than through
    /// any editor-side state.
    ///
    /// The *start* of the selection is used, so the command behaves the same
    /// whether the user placed a caret in a name or double-clicked to select it;
    /// `IdentifierScanner` additionally resolves the word a caret sitting just
    /// past its last character belongs to, which is where the caret lands after
    /// typing one.
    func goToDefinitionAtCaret() {
        onGoToDefinition?(self, selectedRange().location)
    }

    /// Find Usages from the caret — the Find menu's ⌃⌘U entry point, which
    /// reaches this view as the key window's first responder for the reason
    /// `goToDefinitionAtCaret()` states.
    ///
    /// The *start* of the selection, for that method's reason too: the command
    /// behaves the same whether the user placed a caret in a name or
    /// double-clicked to select it.
    func findUsagesAtCaret() {
        onFindUsages?(self, selectedRange().location)
    }

    /// Rename from the caret — the Find menu's ⌃⌘R entry point, reached and
    /// resolved exactly as `findUsagesAtCaret()` is. What happens after the word
    /// resolves is the app's: this view knows nothing about servers, dialogs or
    /// the writer gate.
    func renameAtCaret() {
        onRenameSymbol?(self, selectedRange().location)
    }

    // MARK: - Context menu

    /// The stock text menu plus the three code-intelligence commands, each
    /// acting on the identifier under the **click** rather than under the caret.
    ///
    /// The click is the whole reason these three exist here as well as in the
    /// Find menu: a right-click does not move the insertion point, so a menu
    /// built from `selectedRange()` would answer about wherever the caret was
    /// last left — which is exactly the wrong word, and silently so. The
    /// resolved offset is therefore stashed here and read by the actions below.
    ///
    /// `super`'s menu is *appended to* rather than replaced, so Cut/Copy/Paste,
    /// Look Up, Services and the substitution submenus all survive. What `super`
    /// hands back is not promised to be a fresh menu — `NSTextView` builds one
    /// from a template it shares across every instance — so the additions are
    /// **removed and re-made** rather than skipped when they are already there.
    /// Appending unconditionally would grow a reused menu by four items per
    /// click; *skipping* a reused menu would be worse, because the items it
    /// already carries are targeted at whichever text view built them, and a
    /// second editor would then run Find Usages and Rename against the first
    /// one's buffer. Rebuilding is right under both behaviours and costs three
    /// items. Enablement stays AppKit's — `autoenablesItems` is left
    /// alone, because turning it off for our three items would turn it off for
    /// every stock item too — and is answered in `validateMenuItem(_:)`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        contextMenuOffset = characterIndexForInsertion(
            at: convert(event.locationInWindow, from: nil)
        )
        for item in menu.items where item.tag == Self.intelligenceMenuTag {
            menu.removeItem(item)
        }

        let separator = NSMenuItem.separator()
        separator.tag = Self.intelligenceMenuTag
        menu.addItem(separator)

        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Go to Definition", #selector(goToDefinitionFromMenu(_:)), "j", [.control, .command]),
            ("Find Usages", #selector(findUsagesFromMenu(_:)), "u", [.control, .command]),
            ("Rename…", #selector(renameFromMenu(_:)), "r", [.control, .command]),
        ]
        for (title, action, key, modifiers) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.tag = Self.intelligenceMenuTag
            menu.addItem(item)
        }
        return menu
    }

    /// The three context-menu items are live only where a name is. Everything
    /// else — the stock items, and any command reaching this view through the
    /// responder chain — stays `super`'s answer.
    ///
    /// **Both validation entry points, and that is not belt-and-braces.**
    /// `NSTextView` conforms to `NSMenuItemValidation`, and a menu validating an
    /// `NSMenuItem` asks a target that implements `validateMenuItem(_:)` and never
    /// falls through to `validateUserInterfaceItem(_:)` — so overriding only the
    /// latter would leave all three items permanently enabled and silently
    /// inert on a right-click that resolved no name, which is precisely the state
    /// the enablement exists to avoid. `validateUserInterfaceItem(_:)` is kept for
    /// every other validating client (a toolbar item, a `NSUserInterfaceValidations`
    /// walk of the responder chain), and both defer to `super` for anything else.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let enabled = intelligenceItemEnablement(for: item.action) else {
            return super.validateMenuItem(item)
        }
        return enabled
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let enabled = intelligenceItemEnablement(for: item.action) else {
            return super.validateUserInterfaceItem(item)
        }
        return enabled
    }

    /// Whether one of the three added items may fire, or `nil` when the action is
    /// not one of them — the single answer both validation overrides give, so the
    /// two entry points cannot disagree about the same click.
    private func intelligenceItemEnablement(for action: Selector?) -> Bool? {
        switch action {
        case #selector(goToDefinitionFromMenu(_:)),
             #selector(findUsagesFromMenu(_:)),
             #selector(renameFromMenu(_:)):
            return clickedIdentifierOffset() != nil
        default:
            return nil
        }
    }

    /// The offset the last right-click resolved to, or `nil` before the first
    /// one. Kept as an offset rather than a resolved word so the identifier is
    /// re-read from the buffer as it is when the item fires, not as it was when
    /// the menu opened.
    private var contextMenuOffset: Int?

    /// Marks the items this view adds to the stock menu, so a second right-click
    /// appends nothing.
    private static let intelligenceMenuTag = 0x5D5A

    /// The clicked offset, but only when it actually names an identifier — the
    /// one question the three items' enablement asks.
    private func clickedIdentifierOffset() -> Int? {
        guard let offset = contextMenuOffset,
              IdentifierScanner.identifier(in: string as NSString, at: offset) != nil
        else { return nil }
        return offset
    }

    @objc private func goToDefinitionFromMenu(_ sender: Any?) {
        guard let offset = clickedIdentifierOffset() else { return }
        onGoToDefinition?(self, offset)
    }

    @objc private func findUsagesFromMenu(_ sender: Any?) {
        guard let offset = clickedIdentifierOffset() else { return }
        onFindUsages?(self, offset)
    }

    @objc private func renameFromMenu(_ sender: Any?) {
        guard let offset = clickedIdentifierOffset() else { return }
        onRenameSymbol?(self, offset)
    }

    /// Exposes the `onToggleComment` routing closure to the macOS first-responder
    /// chain without requiring callers to reach into the closure property itself.
    func toggleCommentAtSelection() {
        onToggleComment?(self)
    }

    /// A Command-held click navigates to the clicked identifier's declaration;
    /// every other click keeps the stock behavior.
    ///
    /// **Command-*drag* must still select**, and AppKit gives no way to learn that
    /// from the mouse-down alone: `super.mouseDown` runs its own modal tracking
    /// loop until the button comes up, so a `mouseUp` override is never reached
    /// during a drag-select. The events that follow this one are therefore peeked
    /// at here — a mouse-up within the slop radius is the click, and the first
    /// real movement hands the *original* event back to `super`, whose tracking
    /// loop anchors on it and picks the drag up from the current mouse position.
    /// Only a plain, single Command-click is claimed: ⌘⇧-click extends a selection
    /// and ⌘⌥-click starts a rectangular one, both of which stay AppKit's.
    ///
    /// **The claimed click still behaves like a click.** `super.mouseDown` cannot
    /// be called on this path — its tracking loop would block on a mouse-up this
    /// method has already taken off the queue — so the two things it would have
    /// done are done here instead: the view takes first responder, and the caret
    /// moves to the clicked offset. Without them a ⌘-click that resolves nothing
    /// (whitespace, punctuation, a keyword — `goToDefinition` just beeps) is
    /// swallowed whole, leaving the click with no effect at all, and a ⌘-click in
    /// an editor that is not yet focused would jump without ever focusing it.
    override func mouseDown(with event: NSEvent) {
        guard
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
            event.clickCount == 1,
            let onGoToDefinition
        else { return super.mouseDown(with: event) }

        let anchor = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                let point = convert(event.locationInWindow, from: nil)
                let offset = characterIndexForInsertion(at: point)
                if window?.firstResponder !== self { window?.makeFirstResponder(self) }
                setSelectedRange(NSRange(location: offset, length: 0))
                onGoToDefinition(self, offset)
                return
            }
            let moved = hypot(
                next.locationInWindow.x - anchor.x,
                next.locationInWindow.y - anchor.y
            )
            if moved > Self.clickSlop { return super.mouseDown(with: event) }
        }
        super.mouseDown(with: event)
    }

    /// How far the mouse may travel between down and up and still count as a
    /// click rather than the start of a Command-drag selection. Two points is the
    /// usual hand-tremor allowance and less than one character cell, so a
    /// tolerated wobble can never resolve a different word than the one clicked.
    private static let clickSlop: CGFloat = 2

    /// The start of the current middle-button drag in view coordinates, or `nil`
    /// if no such drag is in flight. Stored in view coordinates so autoscrolling
    /// does not shift the anchor away from the document point it started at.
    private var columnDragAnchor: CGPoint?

    /// Whether the current middle-button drag has moved further than `clickSlop`.
    /// Until it does, a release is a plain click (one caret, no movement).
    private var columnDragMoved = false

    /// The timer that fires to continue autoscrolling when the pointer is held
    /// still outside the view during a middle-button drag.
    private var columnDragAutoscrollTimer: Timer?
    private var columnDragLastEvent: NSEvent?

    private func stopColumnDragAutoscroll() {
        columnDragAutoscrollTimer?.invalidate()
        columnDragAutoscrollTimer = nil
        columnDragLastEvent = nil
    }

    deinit {
        columnDragAutoscrollTimer?.invalidate()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            columnDragAnchor = nil
            columnDragMoved = false
            stopColumnDragAutoscroll()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, isSelectable else {
            return super.otherMouseDown(with: event)
        }
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        columnDragAnchor = convert(event.locationInWindow, from: nil)
        columnDragMoved = false
        stopColumnDragAutoscroll()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let anchor = columnDragAnchor else {
            return super.otherMouseDragged(with: event)
        }

        columnDragLastEvent = event
        if columnDragAutoscrollTimer == nil {
            columnDragAutoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                guard let self = self, let anchor = self.columnDragAnchor, let event = self.columnDragLastEvent else {
                    timer.invalidate()
                    self?.columnDragAutoscrollTimer = nil
                    self?.columnDragLastEvent = nil
                    return
                }
                if self.autoscroll(with: event) {
                    let point = self.convert(event.locationInWindow, from: nil)
                    self.updateColumnSelection(anchor: anchor, point: point, stillSelecting: true)
                }
            }
        }

        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)

        updateColumnSelection(anchor: anchor, point: point, stillSelecting: true)
    }

    private func updateColumnSelection(anchor: CGPoint, point: CGPoint, stillSelecting: Bool) {
        if !columnDragMoved {
            let moved = hypot(point.x - anchor.x, point.y - anchor.y)
            if moved > Self.clickSlop {
                columnDragMoved = true
            } else {
                return
            }
        }

        if let ranges = columnSelectionRanges(anchor: anchor, head: point), !ranges.isEmpty {
            setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: stillSelecting)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let anchor = columnDragAnchor else {
            return super.otherMouseUp(with: event)
        }

        if columnDragMoved {
            let point = convert(event.locationInWindow, from: nil)
            updateColumnSelection(anchor: anchor, point: point, stillSelecting: false)
        } else {
            let offset = characterIndexForInsertion(at: anchor)
            setSelectedRange(NSRange(location: offset, length: 0))
        }

        columnDragAnchor = nil
        columnDragMoved = false
        stopColumnDragAutoscroll()
    }

    /// Evaluates the middle-button drag bounds into the per-line `selectedRanges`.
    ///
    /// The bounds are first widened to the container horizontally and inflated
    /// out of degeneracy (given at least 1pt of width and height if needed)
    /// before they reach the layout manager. This inflation is necessary because
    /// `glyphRange(forBoundingRect:in:)` can otherwise enumerate no fragments at
    /// all for a zero-height single-line drag or a purely vertical zero-width
    /// drag. The edge offsets themselves are still taken from the *un-inflated*
    /// bounds, probed on the fragment's vertical centre, so the inflation never
    /// widens the actual selected columns.
    ///
    /// The gesture never edits the document, and because `NSTextView` ignores
    /// `otherMouseDown`, no modal event loop is needed — AppKit delivers the
    /// dragged and up events to this view normally. The probe is per line
    /// fragment because visual columns mean horizontal edges must be resolved
    /// by the glyph layout per line (one fragment per line with soft wrap off).
    private func columnSelectionRanges(anchor: CGPoint, head: CGPoint) -> [NSRange]? {
        guard let layoutManager = layoutManager, let textContainer = textContainer,
              let string = textStorage?.string else { return nil }

        let bounds = ColumnSelectionEngine.bounds(anchor: anchor, head: head)

        var probeRect = bounds.rect
        probeRect.origin.x = 0
        probeRect.size.width = textContainer.size.width
        probeRect.origin.y -= self.textContainerOrigin.y

        if probeRect.size.width < 1 { probeRect.size.width = 1 }
        if probeRect.size.height < 1 { probeRect.size.height = 1 }

        layoutManager.ensureLayout(forBoundingRect: probeRect, in: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: probeRect, in: textContainer)

        var lines = [ColumnSelectionLine]()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentRange, _ in
            let y = rect.midY + self.textContainerOrigin.y
            let leftPoint = CGPoint(x: bounds.left, y: y)
            let rightPoint = CGPoint(x: bounds.right, y: y)
            let leftOffset = self.characterIndexForInsertion(at: leftPoint)
            let rightOffset = self.characterIndexForInsertion(at: rightPoint)
            let lineRange = layoutManager.characterRange(forGlyphRange: fragmentRange, actualGlyphRange: nil)
            lines.append(ColumnSelectionLine(lineRange: lineRange, leftOffset: leftOffset, rightOffset: rightOffset))
        }

        return ColumnSelectionEngine.ranges(for: lines, in: string as NSString)
    }

    /// Esc with the find bar open closes it (and drops the match highlight);
    /// otherwise the key falls through to the stock behavior.
    ///
    /// AppKit dispatches Esc down the responder chain as `cancelOperation(_:)`,
    /// so this fires only while the editor is the first responder — Esc inside
    /// the bar's own field is the bar's business (`.onExitCommand`), not this.
    /// The handler answers `false` whenever the bar is closed, so nothing else
    /// Esc normally does in a text view is swallowed.
    override func cancelOperation(_ sender: Any?) {
        if onCancelCompletion?() == true { return }
        if onCancelSearch?() == true { return }
        super.cancelOperation(sender)
    }

    /// Intercept a *clean* ⌃Space (no Command/Shift/Option) as "complete the word
    /// at the caret"; every other combination falls through to stock handling.
    ///
    /// Deliberately bound here rather than as the Find menu item's key equivalent,
    /// which is where it started: a menu key equivalent is claimed **app-wide**,
    /// and the menu is offered the keystroke before the key window's first
    /// responder ever sees it. ⌃Space is the only Control-only shortcut this app
    /// binds — every other one carries ⌘, which no terminal wants — and it is a
    /// keystroke the embedded terminal genuinely needs (NUL; readline's and Emacs'
    /// `set-mark`). As a menu equivalent it therefore swallowed ⌃Space out of a
    /// *focused terminal* and beeped instead, `complete(_:)`'s first-responder
    /// cast having failed — and did so only once a tab was open, since a disabled
    /// item does not claim its equivalent. Scoping the binding to this view keeps
    /// the terminal whole; the menu item, AppKit's stock ⌥⎋ and F5 all still reach
    /// the same request.
    ///
    /// Bails while an IME composition is in flight for the same reason ⌘D does:
    /// `rangeForUserCompletion` would measure a partial word across uncommitted
    /// marked text, and accepting a row would replace the composition.
    override func keyDown(with event: NSEvent) {
        if let onCompletionKey = onCompletionKey, onCompletionKey(event) {
            return
        }

        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.control],
           isEditable,
           !hasMarkedText(),
           onRequestCompletions != nil {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// Intercept a *clean* Cmd+D (no Shift/Option/Control) to duplicate the line
    /// or selection; every other combination falls through to the stock handling,
    /// so Cmd+Shift+D and friends are not swallowed.
    ///
    /// `performKeyEquivalent` is dispatched down the whole window's view tree, not
    /// just to the focused view, so this additionally requires the editor to be
    /// editable *and* its window's first responder — otherwise Cmd+D would
    /// duplicate into the editor while the user is typing in the embedded
    /// terminal or the project tree.
    ///
    /// It also bails while an IME composition is in flight (`hasMarkedText()`).
    /// Unlike the `doCommandBy:`/`shouldChangeTextIn:` interceptors — which run
    /// only *after* the input context has processed the event — a key equivalent
    /// is dispatched by `NSWindow` before `keyDown:`, so it can fire mid-
    /// composition. Marked text lives in the text storage, so the duplication
    /// would copy the *uncommitted* composition as ordinary text and leave the
    /// marked range pointing at a region the insertion moved.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            event.charactersIgnoringModifiers?.lowercased() == "d",
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
            isEditable,
            window?.firstResponder === self,
            !hasMarkedText(),
            let onDuplicate
        else { return super.performKeyEquivalent(with: event) }

        return onDuplicate(self)
    }
}

/// A monotonic counter identifying the live highlighter.
///
/// Each rebuilt highlighter captures the value returned by `advance()`; its
/// attribute provider compares that snapshot against `current` and styles only
/// while it matches. A reference type (rather than the `@MainActor` coordinator)
/// is captured into the provider closure so the closure carries no
/// actor-isolated state. All access is on the main actor (the rebuild path and
/// Neon's styling are both main-actor-bound), so no synchronization is needed.
private final class HighlighterGeneration {
    private(set) var current = 0

    /// Advance to a fresh generation and return it, superseding all prior ones.
    func advance() -> Int {
        current += 1
        return current
    }
}

#endif
