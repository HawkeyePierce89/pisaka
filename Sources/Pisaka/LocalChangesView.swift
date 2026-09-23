#if os(macOS)
import SwiftUI
import PisakaCore

/// The Local Changes list in the bottom dock panel.
///
/// Renders the files differing from `HEAD` either flat or grouped by folder
/// (`ChangeTree`), per `model.groupingMode`. A two-segment control in the toolbar
/// toggles the grouping, Commit is the toolbar's one primary button, and a glyph
/// refreshes against the current project root. Three
/// triggers share one activation path through `LocalChangesModel`: double-click,
/// the "Show Diff" context-menu item, and Cmd+D while the panel has focus. The
/// view holds no domain logic: it observes `LocalChangesModel` and renders its
/// published state.
///
/// On the chrome roles and tokens since part four (b) of the chrome theme: every
/// colour is a role, the toolbar draws its own bottom `hairline`, and the status
/// letter, colour and spoken name are Core's one answer.
struct LocalChangesView: View {
    @ObservedObject var model: LocalChangesModel
    /// The current project root, used as the repository root for refresh. `nil`
    /// when no folder is open.
    var projectRoot: URL?
    /// Invoked when a row's context-menu Revert item is chosen. Defaults to a
    /// no-op so previews/tests can construct the view without the app wiring.
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
    /// Invoked by the header's Commit button, opening the commit dialog (the same
    /// handler as the ⌘K menu item, so button and command behave identically).
    /// Defaults to a no-op so previews/tests can construct the view without the app
    /// wiring.
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
        // value, and the macOS 13 `onChange(of:perform:)` overload runs the closure
        // captured before the change, so off `self` it is still the folder the user
        // just left. The pinned generation below cannot catch that one — the
        // folder-open path has already bumped it, so a stale-root refresh pinning the
        // *current* generation is accepted, re-derives a switch back to the old root
        // in `refreshImpl` and strands the panel on the previous repository, which is
        // exactly what `LocalChangesModel.refresh`'s rejection is meant to prevent.
        // (A `@State` or `@ObservedObject` read would have been live.)
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) { newRoot in refresh(root: newRoot) }
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

    /// The panel's toolbar: the grouping control, then Commit as the one primary
    /// button and the refresh glyph. It draws its own bottom `hairline` rather
    /// than leaving a `Divider()` to the stack.
    private var toolbar: some View {
        HStack(spacing: metrics.scaled(LocalChangesLayout.toolbarGap)) {
            groupingControl

            Spacer()

            // Opening the commit dialog needs a repository and nothing else — the
            // same single condition the ⌘K menu item is disabled on, and for the
            // reasons stated there (this list is not live, and a message-only
            // amend is wanted precisely when it is empty).
            Button(action: onCommit) {
                Text("Commit")
                    .font(metrics.scaledFont(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.color(.onAccent))
                    .lineLimit(1)
                    .padding(.horizontal, metrics.scaled(ChromeGeometry.buttonPaddingX))
                    .frame(height: metrics.scaled(LocalChangesLayout.buttonHeight))
                    .background(
                        RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.buttonCornerRadius))
                            .fill(theme.color(.accent))
                    )
            }
            .buttonStyle(.plain)
            .disabled(projectRoot == nil)
            .opacity(projectRoot == nil ? LocalChangesLayout.disabledOpacity : 1)
            .help("Commit changes…")

            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textSecondary))
                    .frame(width: metrics.scaled(LocalChangesLayout.glyphSide))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(projectRoot == nil)
            .help("Refresh changed files")
            .accessibilityLabel("Refresh changed files")
        }
        .padding(.horizontal, metrics.scaled(LocalChangesLayout.toolbarPaddingX))
        .frame(height: metrics.scaled(LocalChangesLayout.toolbarHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    /// The flat/by-folder choice: two glyph segments in one hairline-bordered
    /// box, the chosen one on the accent's wash. Each segment names itself and
    /// speaks its selection, since the glyphs alone say nothing to a listener.
    private var groupingControl: some View {
        HStack(spacing: 0) {
            groupingSegment(.flat, symbol: "list.bullet", label: "Flat list")
            groupingSegment(.byFolder, symbol: "folder", label: "Group by folder")
        }
        .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(LocalChangesLayout.segmentRadius)))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.scaled(LocalChangesLayout.segmentRadius))
                .strokeBorder(theme.color(.hairline), lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth))
        )
        .help("Group changes flat or by folder")
    }

    private func groupingSegment(
        _ mode: LocalChangesModel.GroupingMode,
        symbol: String,
        label: String
    ) -> some View {
        let isChosen = model.groupingMode == mode
        return Button { model.groupingMode = mode } label: {
            Image(systemName: symbol)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(isChosen ? .textPrimary : .textSecondary))
                .frame(
                    width: metrics.scaled(LocalChangesLayout.segmentWidth),
                    height: metrics.scaled(LocalChangesLayout.buttonHeight)
                )
                .background(isChosen ? theme.color(.accentTint) : Color.clear)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.groupingMode {
                    case .flat:
                        ForEach(model.changedFiles) { file in
                            ChangedFileRow(
                                name: (file.path as NSString).lastPathComponent,
                                url: url(for: file.path),
                                changedFile: file,
                                leadingInset: LocalChangesLayout.flatRowInset,
                                isSelected: model.selected?.id == file.id,
                                isChecked: model.revertSelection.contains(file.id),
                                onSelect: { model.select(file); focusRequest += 1 },
                                onToggleCheck: { model.toggleChecked(file) },
                                onRevert: { onRevert(file) },
                                onOpenDiff: { onOpenDiff(file) },
                                onJumpToSource: { onJumpToSource(file) },
                                onResolveConflict: { onResolveConflict(file) },
                                onCommitFile: { onCommitFile(file) }
                            )
                        }
                    case .byFolder:
                        ForEach(model.tree) { node in
                            ChangeNodeView(
                                model: model, node: node, depth: 0,
                                onRevert: onRevert, onOpenDiff: onOpenDiff,
                                onJumpToSource: onJumpToSource,
                                onResolveConflict: onResolveConflict,
                                onCommitFile: onCommitFile,
                                onFocusRequest: { focusRequest += 1 }
                            )
                        }
                    }
                }
                .padding(.vertical, metrics.scaled(LocalChangesLayout.listPaddingY))
            }
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

    /// Absolute url for a repo-relative path, for the row's icon resolution.
    private func url(for path: String) -> URL {
        (projectRoot ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
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
}

/// One node in the by-folder tree: a folder header (recursing over in-memory
/// `ChangeNode.children`, so no disk read is needed) or a file leaf rendered as a
/// `ChangedFileRow`.
///
/// The header is drawn here rather than by a `DisclosureGroup`, whose system
/// disclosure triangle would bring its own colour into a swept surface: a
/// `textSecondary` chevron, the monochrome folder glyph (like the Problems
/// panel's group headers) and the folder's name. Each level indents by
/// `treeIndentStep`, the project tree's own step.
private struct ChangeNodeView: View {
    @ObservedObject var model: LocalChangesModel
    let node: ChangeNode
    /// How many folders enclose this node — the indent it is drawn at.
    let depth: Int
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

    /// The indent this node's own level adds, unscaled.
    private var levelIndent: Double { Double(depth) * ChromeGeometry.treeIndentStep }

    var body: some View {
        if let file = node.file {
            ChangedFileRow(
                name: node.name,
                url: node.url,
                changedFile: file,
                leadingInset: LocalChangesLayout.folderRowInset + levelIndent,
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
        } else {
            VStack(alignment: .leading, spacing: 0) {
                folderHeader
                if isExpanded {
                    ForEach(node.children ?? []) { child in
                        ChangeNodeView(
                            model: model, node: child, depth: depth + 1,
                            onRevert: onRevert, onOpenDiff: onOpenDiff,
                            onJumpToSource: onJumpToSource,
                            onResolveConflict: onResolveConflict,
                            onCommitFile: onCommitFile,
                            onFocusRequest: onFocusRequest
                        )
                    }
                }
            }
        }
    }

    private var folderHeader: some View {
        let icon = FileIcon(for: DirectoryEntry(url: node.url, isDirectory: true))
        return Button { isExpanded.toggle() } label: {
            HStack(spacing: metrics.scaled(LocalChangesLayout.folderGap)) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(metrics.scaledFont(.subheadline))
                    .frame(width: metrics.scaled(LocalChangesLayout.chevronWidth))
                Image(systemName: icon.symbolName)
                    .font(metrics.scaledFont(.callout))
                Text(node.name)
                    .font(metrics.scaledFont(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.color(.textSecondary))
            .padding(.leading, metrics.scaled(LocalChangesLayout.folderPaddingX + levelIndent))
            .padding(.trailing, metrics.scaled(LocalChangesLayout.folderPaddingX))
            .frame(height: metrics.scaled(LocalChangesLayout.folderHeaderHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.name)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// One changed-file row: the revert checkbox, the monochrome file-type glyph,
/// the name, and the one-letter status badge. Clicking selects the file.
///
/// The letter, its colour and its spoken name are Core's one answer
/// (`FileStatus.letter`, `ChromeColorRole.changedFileRole(for:)`,
/// `FileStatus.spokenName`) — shared with the commit dialog and the Log's detail
/// pane. The letter carries the identity and the colour the weight, so the row
/// reads the same to someone who cannot tell the colours apart.
private struct ChangedFileRow: View {
    let name: String
    let url: URL
    let changedFile: ChangedFile
    /// The row's leading inset, unscaled: the flat list's, or the by-folder
    /// grouping's past its folder's glyph.
    let leadingInset: Double
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
        let icon = FileIcon(for: DirectoryEntry(url: url, isDirectory: false))
        HStack(spacing: metrics.scaled(LocalChangesLayout.rowGap)) {
            checkbox
            Image(systemName: icon.symbolName)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
                .accessibilityHidden(true)
            Text(name)
                .font(metrics.scaledFont(.body))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: metrics.scaled(LocalChangesLayout.rowGap))
            Text(status.letter)
                .font(metrics.scaledFont(.callout, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.color(ChromeColorRole.changedFileRole(for: status)))
                .lineLimit(1)
                .accessibilityLabel("Status")
                .accessibilityValue(status.spokenName)
        }
        .padding(.leading, metrics.scaled(leadingInset))
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

    /// The revert checkbox, drawn rather than a system glyph: a hairline-bordered
    /// square when off, the accent filled with an `onAccent` check when on. It
    /// says which file it includes and speaks on/off as its value.
    private var checkbox: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(LocalChangesLayout.checkboxRadius))
        return Button(action: onToggleCheck) {
            ZStack {
                if isChecked {
                    shape.fill(theme.color(.accent))
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.color(.onAccent))
                        .frame(width: metrics.scaled(LocalChangesLayout.checkmarkSide))
                } else {
                    shape.strokeBorder(
                        theme.color(.hairline),
                        lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth)
                    )
                }
            }
            .frame(
                width: metrics.scaled(LocalChangesLayout.checkboxSide),
                height: metrics.scaled(LocalChangesLayout.checkboxSide)
            )
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .help("Select for revert")
        .accessibilityLabel("Include \(name) in revert")
        .accessibilityValue(isChecked ? "On" : "Off")
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
/// seven).
private enum LocalChangesLayout {
    /// The toolbar strip's height.
    static let toolbarHeight: Double = 32
    /// The toolbar's horizontal inset.
    static let toolbarPaddingX: Double = 10
    /// Between the toolbar's controls.
    static let toolbarGap: Double = 8
    /// The Commit button's and the grouping segments' height.
    static let buttonHeight: Double = 22
    /// One grouping segment's width.
    static let segmentWidth: Double = 28
    /// The grouping control's corner radius.
    static let segmentRadius: Double = 4
    /// The refresh glyph's box.
    static let glyphSide: Double = 15
    /// A disabled Commit button's opacity: the whole control dimmed, its colours
    /// still the roles.
    static let disabledOpacity: Double = 0.5
    /// Above and below the list inside its scroll view.
    static let listPaddingY: Double = 4
    /// Around the empty-state sentence.
    static let placeholderPadding: Double = 16
    /// A folder header's height.
    static let folderHeaderHeight: Double = 22
    /// A folder header's horizontal inset.
    static let folderPaddingX: Double = 10
    /// Between a folder header's chevron, glyph and name.
    static let folderGap: Double = 6
    /// The folder chevron's box, so the glyph after it sits still as it turns.
    static let chevronWidth: Double = 10
    /// A file row's leading inset in the flat list.
    static let flatRowInset: Double = 10
    /// A file row's leading inset under a folder header: past its chevron, level
    /// with the folder's glyph.
    static let folderRowInset: Double = 26
    /// A file row's trailing inset.
    static let rowTrailingInset: Double = 10
    /// Between a file row's parts.
    static let rowGap: Double = 6
    /// The revert checkbox's side.
    static let checkboxSide: Double = 14
    /// The revert checkbox's corner radius.
    static let checkboxRadius: Double = 3
    /// The check glyph's width inside the filled box.
    static let checkmarkSide: Double = 8
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
