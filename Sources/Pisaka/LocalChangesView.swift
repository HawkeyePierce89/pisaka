#if os(macOS)
import SwiftUI
import PisakaCore

/// The Local Changes list in the VS Code-style bottom dock panel.
///
/// Renders the files differing from `HEAD` either flat or grouped by folder
/// (`ChangeTree`), per `model.groupingMode`. A segmented control toggles the
/// grouping and a button refreshes against the current project root. Three
/// triggers share one activation path through `LocalChangesModel`: double-click,
/// the "Show Diff" context-menu item, and Cmd+D while the panel has focus. The
/// view holds no domain logic: it observes `LocalChangesModel` and renders its
/// published state.
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
    /// Invoked by the header's Commit button, opening the commit dialog (the same
    /// handler as the ⌘K menu item, so button and command behave identically).
    /// Defaults to a no-op so previews/tests can construct the view without the
    /// app wiring.
    var onCommit: () -> Void = {}
    /// Invoked when a row's context-menu "Commit…" item is chosen, opening the
    /// commit dialog with *only that file* preselected (JetBrains' "Commit File").
    /// It goes through the same handler as `onCommit`/⌘K — only the preselect
    /// differs — so the gates, the autosave flush and the generation pinning are
    /// shared verbatim. Defaults to a no-op so previews/tests can construct the
    /// view without the app wiring.
    var onCommitFile: (ChangedFile) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Refresh when the view first appears or the open folder changes, so
        // toggling to Changes (or switching projects) reflects the repo without
        // requiring a manual refresh first.
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) { _ in refreshIfPossible() }
    }

    private var header: some View {
        HStack(spacing: metrics.scaled(8)) {
            Picker("", selection: $model.groupingMode) {
                Image(systemName: "list.bullet")
                    .tag(LocalChangesModel.GroupingMode.flat)
                Image(systemName: "folder")
                    .tag(LocalChangesModel.GroupingMode.byFolder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(metrics.scaledFont(.body))
            .frame(maxWidth: metrics.scaled(96))
            .help("Group changes flat or by folder")

            Spacer()

            // Opening the commit dialog needs a repository and nothing else — the
            // same single condition the ⌘K menu item is disabled on, and for the
            // reasons stated there (this list is not live, and a message-only
            // amend is wanted precisely when it is empty).
            Button(action: onCommit) {
                Image(systemName: "checkmark.circle")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.borderless)
            .disabled(projectRoot == nil)
            .help("Commit changes…")

            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.borderless)
            .disabled(projectRoot == nil)
            .help("Refresh changed files")
        }
        .padding(.horizontal, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(6))
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
                                isSelected: model.selected?.id == file.id,
                                isChecked: model.revertSelection.contains(file.id),
                                onSelect: { model.select(file) },
                                onToggleCheck: { model.toggleChecked(file) },
                                onRevert: { onRevert(file) },
                                onOpenDiff: { onOpenDiff(file) },
                                onResolveConflict: { onResolveConflict(file) },
                                onCommitFile: { onCommitFile(file) }
                            )
                        }
                    case .byFolder:
                        ForEach(model.tree) { node in
                            ChangeNodeView(
                                model: model, node: node,
                                onRevert: onRevert, onOpenDiff: onOpenDiff,
                                onResolveConflict: onResolveConflict,
                                onCommitFile: onCommitFile
                            )
                        }
                    }
                }
                .padding(.vertical, metrics.scaled(4))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                // The default `.padding()` inset, stated so it scales with the
                // rest of the panel instead of staying a fixed 16pt.
                .padding(metrics.scaled(16))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Absolute url for a repo-relative path, for the row's icon resolution.
    private func url(for path: String) -> URL {
        (projectRoot ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
    }

    private func refreshIfPossible() {
        guard let projectRoot else { return }
        // Pin the current request generation, captured synchronously before the
        // `Task` hop: a backstop refresh (onAppear/onChange/manual button) that
        // ends up running after a newer folder switch is then rejected by the model
        // rather than misread as a switch back to this now-stale root. See
        // `PisakaApp.refreshLocalChanges` for the full rationale.
        let requestGeneration = model.currentRequestGeneration
        Task { await model.refresh(root: projectRoot, requestGeneration: requestGeneration) }
    }
}

/// One node in the by-folder tree: a directory `DisclosureGroup` (recursing over
/// in-memory `ChangeNode.children`, so no disk read is needed) or a file leaf
/// rendered as a `ChangedFileRow`.
private struct ChangeNodeView: View {
    @ObservedObject var model: LocalChangesModel
    let node: ChangeNode
    let onRevert: (ChangedFile) -> Void
    let onOpenDiff: (ChangedFile) -> Void
    let onResolveConflict: (ChangedFile) -> Void
    let onCommitFile: (ChangedFile) -> Void

    @State private var isExpanded = true

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        if let file = node.file {
            ChangedFileRow(
                name: node.name,
                url: node.url,
                changedFile: file,
                isSelected: model.selected?.id == file.id,
                isChecked: model.revertSelection.contains(file.id),
                onSelect: { model.select(file) },
                onToggleCheck: { model.toggleChecked(file) },
                onRevert: { onRevert(file) },
                onOpenDiff: { onOpenDiff(file) },
                onResolveConflict: { onResolveConflict(file) },
                onCommitFile: { onCommitFile(file) }
            )
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    ChangeNodeView(
                        model: model, node: child,
                        onRevert: onRevert, onOpenDiff: onOpenDiff,
                        onResolveConflict: onResolveConflict,
                        onCommitFile: onCommitFile
                    )
                        .padding(.leading, metrics.scaled(12))
                }
            } label: {
                let icon = FileIcon(for: DirectoryEntry(url: node.url, isDirectory: true))
                HStack(spacing: metrics.scaled(4)) {
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(iconColor(for: icon.color))
                    Text(node.name)
                }
                .font(metrics.scaledFont(.body))
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }
}

/// One changed-file row: the file-type icon tinted by its git status, the name,
/// and a one-letter status badge. Clicking selects the file.
private struct ChangedFileRow: View {
    let name: String
    let url: URL
    let changedFile: ChangedFile
    let isSelected: Bool
    let isChecked: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void
    let onRevert: () -> Void
    let onOpenDiff: () -> Void
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

    var body: some View {
        let icon = FileIcon(for: DirectoryEntry(url: url, isDirectory: false))
        HStack(spacing: metrics.scaled(4)) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Select for revert")
            Image(systemName: icon.symbolName)
                .foregroundStyle(statusColor(status))
            Text(name)
            Spacer(minLength: metrics.scaled(4))
            Text(statusLetter(status))
                .font(metrics.scaledFont(.caption2, design: .monospaced))
                .foregroundStyle(statusColor(status))
        }
        .font(metrics.scaledFont(.body))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, metrics.scaled(6))
        .padding(.vertical, metrics.scaled(3))
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
        .contextMenu {
            if status == .conflicted {
                Button("Resolve…", action: onResolveConflict)
                Divider()
            } else {
                Button("Show Diff", action: activate)
            }
            // No extra enablement condition: a row exists only when a folder is
            // open, which is exactly the header Commit button's single condition,
            // and `openCommitDialog` re-checks the project root and every one of
            // its gates anyway. Placed above the destructive Revert item.
            Button("Commit…", action: onCommitFile)
            Button("Revert", role: .destructive, action: onRevert)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.accentColor.opacity(0.15) }
        return .clear
    }
}

/// Semantic color for a git `FileStatus`, matching common VCS conventions
/// (added → green, deleted → red, modified → blue, renamed → orange,
/// untracked → gray).
///
/// Internal rather than file-private so the commit dialog's file list draws the
/// same badge: two lists of changed files that disagreed about what "M" looks
/// like would be a needless inconsistency, and the mapping is one rule.
func statusColor(_ status: FileStatus) -> Color {
    switch status {
    case .modified: return .blue
    case .added: return .green
    case .deleted: return .red
    case .renamed: return .orange
    case .untracked: return .gray
    case .conflicted: return .purple
    }
}

/// One-letter status badge, mirroring `git status`'s short codes. Internal for
/// the same reason as `statusColor(_:)` — the commit dialog shows the same badge.
func statusLetter(_ status: FileStatus) -> String {
    switch status {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .untracked: return "U"
    case .conflicted: return "C"
    }
}

/// Maps a semantic `FileIconColor` token to a concrete SwiftUI `Color` (directory
/// icons in the tree). Mirrors the helper in `ProjectTreeView`.
private func iconColor(for token: FileIconColor) -> Color {
    switch token {
    case .orange: return .orange
    case .yellow: return .yellow
    case .blue: return .blue
    case .green: return .green
    case .purple: return .purple
    case .red: return .red
    case .pink: return .pink
    case .gray: return .gray
    case .accent: return .accentColor
    }
}

#endif
