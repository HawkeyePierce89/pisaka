#if os(macOS)
import SwiftUI
import PisakaCore

/// The Local Changes panel in the bottom dock: the changed files on the left,
/// the selected file's diff on the right.
///
/// The toolbar leads with Commit… (the shared primary style), then the revert
/// and refresh glyph buttons. The list is one level of folder rows — one per
/// distinct parent directory, Core's `ChangedFileGroups` — each file indented
/// beneath its folder as checkbox, status letter, name. The macOS view draws no
/// flat/by-folder choice; `LocalChangesModel.groupingMode` stays for iOS.
///
/// The right-hand side embeds `DiffView` for the selected file, headed by its
/// project-relative path. Its rows are the model's `selectionDiff`, loaded
/// under a token claimed synchronously at each trigger (a selection change, a
/// refresh), so a superseded selection never publishes. Double-click, the "Show
/// Diff" context-menu item and Cmd+D still open the diff in its own window,
/// through one activation path in `LocalChangesModel`. The view holds no domain
/// logic: it observes `LocalChangesModel` and renders its published state.
///
/// Every colour is a role, the toolbar draws its own bottom `hairline`, and the
/// status letter, colour and spoken name are Core's one answer.
struct LocalChangesView: View {
    @ObservedObject var model: LocalChangesModel
    /// The current project root, used as the repository root for refresh. `nil`
    /// when no folder is open.
    var projectRoot: URL?
    /// The code zone's font size, which the inline diff is drawn at (the diff
    /// panes are a code surface, not chrome). Defaults to the system size so
    /// previews/tests can construct the view without the app wiring.
    var codeFontSize: Double = Double(NSFont.systemFontSize)
    /// Invoked when a row's context-menu Revert item or the toolbar's revert
    /// button is chosen, with the context file `filesToRevert(contextFile:)`
    /// widens. Defaults to a no-op so previews/tests can construct the view
    /// without the app wiring.
    var onRevert: (ChangedFile) -> Void = { _ in }
    /// Invoked when a row is double-clicked, to open that file's diff in a separate
    /// window (single-click still selects). Defaults to a no-op so previews/tests
    /// can construct the view without the app wiring.
    var onOpenDiff: (ChangedFile) -> Void = { _ in }
    /// Invoked when a *conflicted* file requests resolution (its "Resolve"
    /// context-menu item or double-click), opening the 3-pane merge window.
    /// Defaults to a no-op so previews/tests can construct the view without the
    /// app wiring.
    var onResolveConflict: (ChangedFile) -> Void = { _ in }
    /// Invoked when a row's context-menu "Jump to Source" item is chosen, opening
    /// the file in the editor. The decision is routed through
    /// `LocalChangesModel.offersJumpToSource(for:)` — a deleted file has no
    /// worktree source and hides the item. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onJumpToSource: (ChangedFile) -> Void = { _ in }
    /// Invoked when a file should be opened in the editor by URL (used by the
    /// Cmd+Down shortcut in the focus anchor). Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onOpenFile: (URL) -> Void = { _ in }
    /// Invoked by the toolbar's Commit… button, opening the commit dialog (the
    /// same handler as the ⌘K menu item, so button and command behave
    /// identically). Defaults to a no-op so previews/tests can construct the view
    /// without the app wiring.
    var onCommit: () -> Void = {}
    /// Invoked when a row's context-menu "Commit…" item is chosen, opening the
    /// commit dialog with *only that file* preselected (the "Commit File" gesture).
    /// It goes through the same handler as `onCommit`/⌘K — only the preselect
    /// differs — so the gates, the autosave flush and the generation pinning are
    /// shared verbatim. Defaults to a no-op so previews/tests can construct the
    /// view without the app wiring.
    var onCommitFile: (ChangedFile) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    /// A token bumped on every row selection. A value change is the only signal
    /// an `NSViewRepresentable` receives, so bumping this in `onSelect` lets
    /// `LocalChangesFocusAnchor` request first responder on the panel. The
    /// anchor's coordinator tracks the previous value so focus is only requested
    /// when the token actually changes — not on every body re-evaluation.
    @State private var focusRequest = 0
    /// The list's width once the user has dragged the divider, unscaled; `nil`
    /// keeps the default.
    @State private var listWidth: Double?
    /// The list's width when the current drag began, unscaled; non-`nil`
    /// exactly while the divider is dragged.
    @State private var dragStartWidth: Double?
    /// Whether the pointer is over the divider's drag band.
    @State private var isDividerHovering = false
    /// Whether this view holds a resize cursor on the global stack. Read and
    /// written only by `syncDividerCursor()`, so every push is balanced by
    /// exactly one pop.
    @State private var dividerCursorPushed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        // Refresh when the view first appears or the open folder changes, so
        // toggling to Changes (or switching projects) reflects the repo without
        // requiring a manual refresh first.
        //
        // The change handler refreshes the root its *parameter* carries, never
        // `self.projectRoot`: `projectRoot` is a plain stored property of this view
        // value, and the single-parameter `onChange(of:perform:)` overload runs the closure
        // captured before the change, so off `self` it is still the folder the user
        // just left. The pinned generation below cannot catch that one — the
        // folder-open path has already bumped it, so a stale-root refresh pinning the
        // *current* generation is accepted, re-derives a switch back to the old root
        // in `refreshImpl` and strands the panel on the previous repository, which is
        // exactly what `LocalChangesModel.refresh`'s rejection is meant to prevent.
        // (A `@State` or `@ObservedObject` read would have been live.)
        .onAppear {
            refreshIfPossible()
            loadSelectionDiff()
        }
        .onChange(of: projectRoot) { newRoot in refresh(root: newRoot) }
        // The inline diff follows the selection, and re-reads after every
        // refresh — `listRevision` advances even when the refreshed list is equal,
        // which is exactly when an already-modified file was edited again.
        .onChange(of: model.selected) { _ in loadSelectionDiff() }
        .onChange(of: model.listRevision) { _ in loadSelectionDiff() }
        // The focus anchor sits on the outer VStack (not the list) so focus
        // survives placeholder states and an empty change list.
        .background(
            LocalChangesFocusAnchor(
                focusRequest: focusRequest,
                selectedFile: model.selected,
                repositoryRoot: model.root,
                onOpenDiff: onOpenDiff,
                onResolveConflict: onResolveConflict,
                onOpenFile: onOpenFile
            )
        )
    }

    /// The panel's toolbar, at its leading edge: Commit… in the shared primary
    /// style, then the revert and refresh glyph buttons. It draws its own bottom
    /// `hairline` rather than leaving a `Divider()` to the stack.
    private var toolbar: some View {
        HStack(spacing: metrics.scaled(LocalChangesLayout.toolbarGap)) {
            // Opening the commit dialog needs a repository and nothing else — the
            // same single condition the ⌘K menu item is disabled on, and for the
            // reasons stated there (this list is not live, and a message-only
            // amend is wanted precisely when it is empty).
            Button(action: onCommit) {
                Text("Commit…")
                    .lineLimit(1)
            }
            .buttonStyle(.chromePrimary)
            .disabled(projectRoot == nil)
            .help("Commit changes…")

            // The checked files when any is checked, else the selected file —
            // Core's one answer, handed to the same revert path (and its
            // confirmation) as the row's context-menu Revert.
            Button {
                if let target = model.toolbarRevertTarget { onRevert(target) }
            } label: {
                DesignGlyphImage(
                    .undo2, size: LocalChangesLayout.toolbarGlyphSize,
                    slot: LocalChangesLayout.toolbarGlyphSize, role: .textSecondary
                )
            }
            .buttonStyle(.plain)
            .disabled(model.toolbarRevertTarget == nil)
            .opacity(model.toolbarRevertTarget == nil ? LocalChangesLayout.disabledOpacity : 1)
            .help("Revert checked or selected changes…")
            .accessibilityLabel("Revert changes")

            Button(action: refreshIfPossible) {
                DesignGlyphImage(
                    .refreshCw, size: LocalChangesLayout.toolbarGlyphSize,
                    slot: LocalChangesLayout.toolbarGlyphSize, role: .textSecondary
                )
            }
            .buttonStyle(.plain)
            .disabled(projectRoot == nil)
            .help("Refresh changed files")
            .accessibilityLabel("Refresh changed files")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.scaled(LocalChangesLayout.toolbarPaddingX))
        .frame(height: metrics.scaled(LocalChangesLayout.toolbarHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    @ViewBuilder
    private var content: some View {
        if projectRoot == nil {
            placeholder("Open a folder to see local changes")
        } else if let message = model.errorMessage {
            placeholder(message)
        } else if model.changedFiles.isEmpty {
            placeholder("No local changes")
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: metrics.scaled(listWidth ?? LocalChangesLayout.listDefaultWidth))
                divider
                detail
            }
        }
    }

    /// The grouped list: one folder row per distinct parent directory, each
    /// file indented beneath it.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ChangedFileGroups.group(model.changedFiles, rootName: rootName)) { group in
                    ChangedFileGroupView(
                        model: model, group: group, projectRoot: projectRoot,
                        onRevert: onRevert, onOpenDiff: onOpenDiff,
                        onJumpToSource: onJumpToSource,
                        onResolveConflict: onResolveConflict,
                        onCommitFile: onCommitFile,
                        onFocusRequest: { focusRequest += 1 }
                    )
                }
            }
            .padding(.vertical, metrics.scaled(LocalChangesLayout.listPaddingY))
        }
    }

    /// The `hairline` between the list and the diff, with a wider invisible
    /// band either side that drags the list's width.
    private var divider: some View {
        Rectangle()
            .fill(theme.color(.hairline))
            .frame(width: metrics.scaled(ChromeGeometry.hairlineWidth))
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: metrics.scaled(LocalChangesLayout.dividerGrip))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        isDividerHovering = inside
                        syncDividerCursor()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = dragStartWidth ?? (listWidth ?? LocalChangesLayout.listDefaultWidth)
                                dragStartWidth = start
                                syncDividerCursor()
                                let proposed = start + Double(drag.translation.width) / metrics.scale
                                listWidth = min(
                                    max(proposed, LocalChangesLayout.listMinimumWidth),
                                    LocalChangesLayout.listMaximumWidth
                                )
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                syncDividerCursor()
                            }
                    )
                    // The divider leaves the tree with the panel — a dock tab
                    // switch, the list emptying — and then neither `onHover(false)`
                    // nor `onEnded` arrives, so the push is released here, with
                    // both flags cleared first so the sync has nothing left to want.
                    .onDisappear {
                        isDividerHovering = false
                        dragStartWidth = nil
                        syncDividerCursor()
                    }
            }
            .accessibilityHidden(true)
    }

    /// Push the resize cursor while the divider is hovered or dragged, pop it
    /// otherwise — off the one flag, so a push is never doubled nor a pop spent
    /// on a cursor this view did not push.
    private func syncDividerCursor() {
        let wanted = isDividerHovering || dragStartWidth != nil
        if wanted, !dividerCursorPushed {
            NSCursor.resizeLeftRight.push()
            dividerCursorPushed = true
        } else if !wanted, dividerCursorPushed {
            NSCursor.pop()
            dividerCursorPushed = false
        }
    }

    /// The selected file's diff, headed by its project-relative path; an empty
    /// state with nothing selected.
    @ViewBuilder
    private var detail: some View {
        if let selected = model.selected {
            VStack(spacing: 0) {
                Text(selected.path)
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, metrics.scaled(LocalChangesLayout.toolbarPaddingX))
                    .frame(height: metrics.scaled(LocalChangesLayout.detailHeaderHeight))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.color(.hairline))
                            .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
                    }
                if let diff = model.selectionDiff, diff.file == selected {
                    DiffView(
                        fileID: selected.id,
                        fileName: (selected.path as NSString).lastPathComponent,
                        rows: diff.rows,
                        fontSize: codeFontSize
                    )
                } else {
                    placeholder("Loading…")
                }
            }
        } else {
            placeholder("Select a file to see its changes")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(theme.color(.textSecondary))
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                // The default `.padding()` inset, stated so it scales with the
                // rest of the panel instead of staying a fixed 16pt.
                .padding(metrics.scaled(LocalChangesLayout.placeholderPadding))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The label of the root-level group: the project folder's name.
    private var rootName: String {
        (model.root ?? projectRoot)?.lastPathComponent ?? ""
    }

    /// Refresh for the currently-held root. Safe from `onAppear` and the Refresh
    /// button, where the view's own property is current; a change handler must call
    /// `refresh(root:)` with its parameter instead.
    private func refreshIfPossible() {
        refresh(root: projectRoot)
    }

    private func refresh(root: URL?) {
        guard let root else { return }
        // Pin the current request generation, captured synchronously before the
        // `Task` hop: a backstop refresh (onAppear/onChange/manual button) that
        // ends up running after a newer folder switch is then rejected by the model
        // rather than misread as a switch back to this now-stale root. See
        // `PisakaApp.refreshLocalChanges` for the full rationale.
        let requestGeneration = model.currentRequestGeneration
        Task { await model.refresh(root: root, requestGeneration: requestGeneration) }
    }

    /// Re-load the inline diff for the current selection. The token is claimed
    /// here, synchronously, before the `Task` hop — so of two loads in flight
    /// only the later trigger's may publish.
    private func loadSelectionDiff() {
        let token = model.beginSelectionDiffLoad()
        Task { await model.loadSelectionDiff(token: token) }
    }
}

/// One folder row and, while it is expanded, its files.
///
/// The row is drawn here rather than by a `DisclosureGroup`, whose system
/// disclosure triangle would bring its own colour into a swept surface: the
/// design's chevron, the folder glyph and the folder's path, all in
/// `textSecondary`. Every folder starts expanded.
private struct ChangedFileGroupView: View {
    @ObservedObject var model: LocalChangesModel
    let group: ChangedFileGroup
    let projectRoot: URL?
    let onRevert: (ChangedFile) -> Void
    let onOpenDiff: (ChangedFile) -> Void
    let onJumpToSource: (ChangedFile) -> Void
    let onResolveConflict: (ChangedFile) -> Void
    let onCommitFile: (ChangedFile) -> Void
    let onFocusRequest: () -> Void

    @State private var isExpanded = true

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderHeader
            if isExpanded {
                ForEach(group.files) { file in
                    ChangedFileRow(
                        name: ChangedFileGroups.name(of: file.path),
                        changedFile: file,
                        isSelected: model.selected?.id == file.id,
                        isChecked: model.revertSelection.contains(file.id),
                        onSelect: { model.select(file); onFocusRequest() },
                        onToggleCheck: { model.toggleChecked(file) },
                        onRevert: { onRevert(file) },
                        onOpenDiff: { onOpenDiff(file) },
                        onJumpToSource: { onJumpToSource(file) },
                        onResolveConflict: { onResolveConflict(file) },
                        onCommitFile: { onCommitFile(file) }
                    )
                }
            }
        }
    }

    private var folderHeader: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: metrics.scaled(LocalChangesLayout.folderGap)) {
                DesignGlyphImage(
                    isExpanded ? .chevronDown : .chevronRight,
                    size: LocalChangesLayout.chevronSize, slot: LocalChangesLayout.chevronSize,
                    role: .textSecondary
                )
                DesignGlyphImage(
                    FileGlyph.forFolder(expanded: isExpanded),
                    size: LocalChangesLayout.folderGlyphSize, slot: LocalChangesLayout.folderGlyphSize,
                    role: .textSecondary
                )
                Text(group.label)
                    .font(metrics.scaledFont(.callout))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.color(.textSecondary))
            .padding(.horizontal, metrics.scaled(LocalChangesLayout.folderPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.rowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.label)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// One changed-file row, indented beneath its folder: the revert checkbox, the
/// one-letter status, then the name. Clicking selects the file.
///
/// The letter, its colour and its spoken name are Core's one answer
/// (`FileStatus.letter`, `ChromeColorRole.changedFileRole(for:)`,
/// `FileStatus.spokenName`) — shared with the commit dialog and the Log's detail
/// pane. The letter carries the identity and the colour the weight, so the row
/// reads the same to someone who cannot tell the colours apart.
private struct ChangedFileRow: View {
    let name: String
    let changedFile: ChangedFile
    let isSelected: Bool
    let isChecked: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void
    let onRevert: () -> Void
    let onOpenDiff: () -> Void
    let onJumpToSource: () -> Void
    let onResolveConflict: () -> Void
    let onCommitFile: () -> Void

    private var status: FileStatus { changedFile.status }

    /// The one activation path shared by double-click, "Show Diff" and Cmd+D.
    private func activate() {
        switch LocalChangesModel.activation(for: changedFile) {
        case .diff: onOpenDiff()
        case .resolveConflict: onResolveConflict()
        }
    }

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(LocalChangesLayout.rowGap)) {
            ChromeCheckbox(state: isChecked ? .on : .off, label: "Include \(name) in revert", action: onToggleCheck)
                .help("Select for revert")
            Text(status.letter)
                .font(metrics.scaledFont(.callout, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.color(ChromeColorRole.changedFileRole(for: status)))
                .lineLimit(1)
                .frame(width: metrics.scaled(LocalChangesLayout.statusColumnWidth))
                .accessibilityLabel("Status")
                .accessibilityValue(status.spokenName)
            Text(name)
                .font(metrics.scaledFont(.body))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, metrics.scaled(LocalChangesLayout.fileRowInset))
        .padding(.trailing, metrics.scaled(LocalChangesLayout.rowTrailingInset))
        .frame(height: metrics.scaled(ChromeGeometry.rowHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        // Double-click opens the 3-pane merge window for a conflicted file, else
        // the diff in a separate window; declared before the single-tap so SwiftUI
        // prefers it for a two-click sequence and the single-click select still
        // fires for one click. The row is selected first so "double-click, then
        // Cmd+D on the next row" leaves the panel focused on the right row.
        .onTapGesture(count: 2) {
            onSelect()
            activate()
        }
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        // Grouped by `Section`s rather than separated by `Divider()`s: a menu
        // renders the same separators between sections, and the dock's swept
        // surfaces spell no `Divider()` at all.
        .contextMenu {
            if !LocalChangesModel.offersShowDiff(for: status) {
                Section {
                    Button("Resolve…", action: onResolveConflict)
                }
            }
            Section {
                if LocalChangesModel.offersShowDiff(for: status) {
                    Button("Show Diff", action: activate)
                }
                if LocalChangesModel.offersJumpToSource(for: status) {
                    Button("Jump to Source", action: onJumpToSource)
                }
                // No extra enablement condition: a row exists only when a folder
                // is open, which is exactly the toolbar Commit button's single
                // condition, and `openCommitDialog` re-checks the project root and
                // every one of its gates anyway.
                Button("Commit…", action: onCommitFile)
            }
            Section {
                Button("Revert", role: .destructive, action: onRevert)
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return theme.color(.accentTintStrong) }
        if isHovering { return theme.color(.hoverTint) }
        return .clear
    }
}

/// The panel's own measurements, bare numbers scaled once at the use site. They
/// belong to this panel alone, so deriving them from a `ChromeGeometry` token
/// would couple them to a measurement that means something else (gating rule
/// seven). Internal rather than private so the app-layer layout suite measures
/// against the same numbers.
enum LocalChangesLayout {
    /// The toolbar strip's height: the primary button's 28 plus a 4-point
    /// margin above and below.
    static let toolbarHeight: Double = 36
    /// The toolbar's horizontal inset.
    static let toolbarPaddingX: Double = 10
    /// Between the toolbar's controls.
    static let toolbarGap: Double = 8
    /// The revert and refresh glyphs' drawn size and slot.
    static let toolbarGlyphSize: Double = 15
    /// A disabled glyph button's opacity: the whole control dimmed, its colours
    /// still the roles.
    static let disabledOpacity: Double = 0.5
    /// The list's default width, before the user drags the divider.
    static let listDefaultWidth: Double = 320
    /// The narrowest the divider drags the list to.
    static let listMinimumWidth: Double = 200
    /// The widest the divider drags the list to.
    static let listMaximumWidth: Double = 640
    /// The divider's invisible drag band.
    static let dividerGrip: Double = 8
    /// The diff's path header strip's height.
    static let detailHeaderHeight: Double = 28
    /// Above and below the list inside its scroll view.
    static let listPaddingY: Double = 4
    /// Around the empty-state sentence.
    static let placeholderPadding: Double = 16
    /// A folder row's horizontal inset.
    static let folderPaddingX: Double = 10
    /// Between a folder row's chevron, glyph and path.
    static let folderGap: Double = 6
    /// The folder row's chevron.
    static let chevronSize: Double = 12
    /// The folder row's folder glyph.
    static let folderGlyphSize: Double = 14
    /// A file row's leading inset beneath its folder: past the chevron, level
    /// with the folder's glyph.
    static let fileRowInset: Double = 28
    /// A file row's trailing inset.
    static let rowTrailingInset: Double = 10
    /// Between a file row's parts.
    static let rowGap: Double = 6
    /// The status letter's column, so every name starts at the same x.
    static let statusColumnWidth: Double = 12
}

// MARK: - Focus anchor (Cmd+D interception)

/// An invisible `NSView` behind the Local Changes panel that intercepts
/// Cmd+D and Cmd+Down while the panel owns keyboard focus. Mirrors the gate
/// shape in `EditorTextView.performKeyEquivalent`: the same modifier mask,
/// the same first-responder check. The editor's own gate keeps the two
/// meanings apart. Cmd+Down opens the selected file and hands keyboard
/// focus to the editor (the same `onOpenFile` the project tree uses).
///
/// Not a zoom surface (no `ZoomSurfaceProviding`, no `ZoomSurfaceMarker`):
/// the anchor is chrome, drawn at no font at all — the pointer cannot be
/// "over" it in any meaningful sense, so declaring it a surface would make
/// the zoom pointer walk find it where the user means to zoom the code or
/// the interface.
private struct LocalChangesFocusAnchor: NSViewRepresentable {
    let focusRequest: Int
    let selectedFile: ChangedFile?
    let repositoryRoot: URL?
    let onOpenDiff: (ChangedFile) -> Void
    let onResolveConflict: (ChangedFile) -> Void
    let onOpenFile: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalChangesFocusAnchorView {
        LocalChangesFocusAnchorView(
            selectedFile: selectedFile,
            repositoryRoot: repositoryRoot,
            onOpenDiff: onOpenDiff,
            onResolveConflict: onResolveConflict,
            onOpenFile: onOpenFile
        )
    }

    func updateNSView(_ nsView: LocalChangesFocusAnchorView, context: Context) {
        nsView.selectedFile = selectedFile
        nsView.repositoryRoot = repositoryRoot
        nsView.onOpenDiff = onOpenDiff
        nsView.onResolveConflict = onResolveConflict
        nsView.onOpenFile = onOpenFile
        // Only request first responder when focusRequest actually changed (a row
        // was clicked), not on every body re-evaluation — otherwise a model
        // refresh while the user is in the editor would steal focus back.
        // Dispatched asynchronously so the responder change does not land
        // inside a SwiftUI update pass.
        guard focusRequest != context.coordinator.lastAppliedFocusRequest else { return }
        context.coordinator.lastAppliedFocusRequest = focusRequest
        guard nsView.window?.firstResponder !== nsView else { return }
        DispatchQueue.main.async { [weak nsView] in
            nsView?.window?.makeFirstResponder(nsView)
        }
    }

    final class Coordinator {
        var lastAppliedFocusRequest = 0
    }
}

/// The `NSView` behind `LocalChangesFocusAnchor`. Non-drawing, hit-test
/// transparent, hidden from accessibility. `acceptsFirstResponder` is true so
/// clicking a row focuses the panel; `performKeyEquivalent` intercepts clean
/// Cmd+D and Cmd+Down and routes them through the same activation rules the
/// double-click and context-menu items use. Cmd+Down additionally hands
/// keyboard focus to the editor.
@MainActor
private final class LocalChangesFocusAnchorView: NSView {
    var selectedFile: ChangedFile?
    var repositoryRoot: URL?
    var onOpenDiff: (ChangedFile) -> Void
    var onResolveConflict: (ChangedFile) -> Void
    var onOpenFile: (URL) -> Void

    init(
        selectedFile: ChangedFile?,
        repositoryRoot: URL?,
        onOpenDiff: @escaping (ChangedFile) -> Void,
        onResolveConflict: @escaping (ChangedFile) -> Void,
        onOpenFile: @escaping (URL) -> Void
    ) {
        self.selectedFile = selectedFile
        self.repositoryRoot = repositoryRoot
        self.onOpenDiff = onOpenDiff
        self.onResolveConflict = onResolveConflict
        self.onOpenFile = onOpenFile
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    /// Transparent to every click, drag and mouse-over. The pointer walk never
    /// needs to find this view by geometry — it exists only to own keyboard
    /// focus.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Intercept clean Cmd+D and Cmd+Down when this view is the window's first
    /// responder — the same modifier mask and first-responder check, differing
    /// only in the character test. An arrow event carries `.function` and
    /// `.numericPad` in `modifierFlags`; the existing
    /// `intersection([.command, .shift, .option, .control])` already masks those
    /// out, so only the character comparison changes. Anything else falls
    /// through to `super` so Cmd+Shift+D and friends stay untouched.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
            window?.firstResponder === self
        else { return super.performKeyEquivalent(with: event) }

        let chars = event.charactersIgnoringModifiers
        if chars?.lowercased() == "d" {
            return handleShowDiff()
        }
        if chars == String(UnicodeScalar(NSDownArrowFunctionKey)!) {
            return handleJumpToSource()
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Routes Cmd+D through the same activation rules the double-click and
    /// "Show Diff" context-menu item use. Returns `true` (consumed) even with
    /// no selection — a deliberate no-op, not an oversight.
    private func handleShowDiff() -> Bool {
        guard let selectedFile,
              let activation = LocalChangesModel.shortcutActivation(selected: selectedFile)
        else { return true }

        switch activation {
        case .diff: onOpenDiff(selectedFile)
        case .resolveConflict: onResolveConflict(selectedFile)
        }
        return true
    }

    /// Resolves the selected file against the repository root and opens it,
    /// then hands keyboard focus to the editor. `nil` (no selection, a deleted
    /// row, or no root) is consumed silently — same deliberate no-op as Cmd+D.
    private func handleJumpToSource() -> Bool {
        guard let selectedFile, let repositoryRoot else { return true }
        guard let url = LocalChangesModel.shortcutJumpToSourceURL(
            selected: selectedFile, root: repositoryRoot
        ) else { return true }

        onOpenFile(url)
        focusEditor()
        return true
    }

    /// Hands keyboard focus to the first `EditorTextView` in the window. The
    /// hop is dispatched asynchronously so the tab SwiftUI is about to build
    /// exists by the time the responder change lands. If no editor is found
    /// (no folder open, or the open failed — which already beeps in
    /// `openFile(url:)`) focus stays where it is. One honest limitation: the
    /// handoff cannot see whether the open succeeded, so a failed open with
    /// another tab already showing focuses that tab's editor — the beep is
    /// the failure signal.
    private func focusEditor() {
        guard let window else { return }
        DispatchQueue.main.async {
            guard let content = window.contentView else { return }
            func findEditor(in view: NSView) -> EditorTextView? {
                if let editor = view as? EditorTextView { return editor }
                for subview in view.subviews {
                    if let found = findEditor(in: subview) { return found }
                }
                return nil
            }
            if let editor = findEditor(in: content) {
                window.makeFirstResponder(editor)
            }
        }
    }
}

#endif
