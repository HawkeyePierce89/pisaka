#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS Local Changes screen — the peer of the macOS `LocalChangesView`.
/// Presented as a sheet from `RootView_iOS`; it lists the files differing from
/// `HEAD` either flat or grouped by folder (`ChangeTree`), with a status-tinted
/// icon + one-letter badge per row, a leading checkbox for multi-file revert, and a
/// context action to revert. Tapping a row opens its working-copy-vs-`HEAD` diff via
/// the iOS route abstraction (a sheet on iPad, a push on iPhone) — no separate
/// windows.
///
/// The view holds no domain logic: it observes `LocalChangesModel` and renders its
/// published state. Refresh and revert flow through the model; the parent supplies
/// `onRevert` (which does the model revert + open-tab resync).
struct LocalChangesView_iOS: View {
    @ObservedObject var model: LocalChangesModel
    @ObservedObject var settings: SettingsStore
    /// The current project root, used as the repository root for refresh. `nil` when
    /// no folder is open.
    var projectRoot: URL?
    /// Reverts the given files (confirm has already been shown). Does the model
    /// revert + open-tab resync; supplied by the parent which owns the workspace.
    var onRevert: ([ChangedFile]) async -> Void
    /// Opens the 3-pane merge editor for a conflicted file (the parent builds the
    /// `MergeModel` and presents the route, since it owns the workspace).
    var onResolveConflict: (ChangedFile) -> Void = { _ in }
    /// Dismisses this screen.
    var onDone: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The file whose diff is currently routed (sheet or push). `nil` = none.
    /// Wrapped so it satisfies both `sheet(item:)` (Identifiable) and
    /// `navigationDestination(item:)` (Hashable) — `ChangedFile` is Identifiable but
    /// not Hashable.
    @State private var diffTarget: DiffTarget?
    /// Files awaiting a revert confirmation (empty = no dialog).
    @State private var revertCandidates: [ChangedFile] = []

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Local Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(item: pushTarget) { target in
                    diffRoute(for: target.file)
                }
        }
        .sheet(item: sheetTarget) { target in
            NavigationStack { diffRoute(for: target.file) }
        }
        .confirmationDialog(
            "Revert changes?",
            isPresented: revertConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) {
                let files = revertCandidates
                revertCandidates = []
                Task { await onRevert(files) }
            }
            Button("Cancel", role: .cancel) { revertCandidates = [] }
        } message: {
            Text(revertMessage)
        }
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) { refreshIfPossible() }
    }

    // MARK: - Content

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
                            ChangedFileRow_iOS(
                                name: (file.path as NSString).lastPathComponent,
                                url: url(for: file.path),
                                status: file.status,
                                isChecked: model.revertSelection.contains(file.id),
                                onTap: { open(file) },
                                onToggleCheck: { model.toggleChecked(file) },
                                onRevert: { requestRevert(file) },
                                onResolve: file.status == .conflicted ? { onResolveConflict(file) } : nil
                            )
                        }
                    case .byFolder:
                        ForEach(model.tree) { node in
                            ChangeNodeView_iOS(
                                model: model,
                                node: node,
                                onOpenDiff: open,
                                onRevert: requestRevert,
                                onResolveConflict: onResolveConflict
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Picker("", selection: $model.groupingMode) {
                Image(systemName: "list.bullet").tag(LocalChangesModel.GroupingMode.flat)
                Image(systemName: "folder").tag(LocalChangesModel.GroupingMode.byFolder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(projectRoot == nil)
            Button("Done", action: onDone)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func diffRoute(for file: ChangedFile) -> some View {
        DiffRoute_iOS(
            fileID: file.id,
            fileName: (file.path as NSString).lastPathComponent,
            load: { await model.rows(for: file) },
            settings: settings
        )
    }

    // MARK: - Routing helpers

    /// Bindings that route the diff target to a sheet (regular width) or a push
    /// (compact width), per the platform route abstraction, so exactly one of the
    /// two presents at a time.
    private var sheetTarget: Binding<DiffTarget?> {
        Binding(
            get: { isCompact ? nil : diffTarget },
            set: { diffTarget = $0 }
        )
    }

    private var pushTarget: Binding<DiffTarget?> {
        Binding(
            get: { isCompact ? diffTarget : nil },
            set: { diffTarget = $0 }
        )
    }

    private var revertConfirmationBinding: Binding<Bool> {
        Binding(
            get: { !revertCandidates.isEmpty },
            set: { if !$0 { revertCandidates = [] } }
        )
    }

    private var revertMessage: String {
        let names = revertCandidates.map { ($0.path as NSString).lastPathComponent }
        return "Discard local changes to:\n" + names.joined(separator: "\n")
    }

    /// Open a changed file: a conflicted file routes to the 3-pane merge editor,
    /// every other status to its working-copy-vs-`HEAD` diff (the macOS double-click
    /// routing).
    private func open(_ file: ChangedFile) {
        if file.status == .conflicted {
            onResolveConflict(file)
        } else {
            diffTarget = DiffTarget(file: file)
        }
    }

    /// Resolve the batch-vs-single set (checked files, or just this row) and stage
    /// the confirmation dialog.
    private func requestRevert(_ file: ChangedFile) {
        let files = model.filesToRevert(contextFile: file)
        guard !files.isEmpty else { return }
        revertCandidates = files
    }

    /// Absolute url for a repo-relative path, for the row's icon resolution.
    private func url(for path: String) -> URL {
        (projectRoot ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
    }

    private func refreshIfPossible() {
        guard let projectRoot else { return }
        // Pin the current request generation synchronously before the `Task` hop, so
        // a backstop refresh that ends up running after a newer folder switch is
        // rejected by the model rather than misread as a switch back to this
        // now-stale root (the macOS `LocalChangesView.refreshIfPossible` rationale).
        let requestGeneration = model.currentRequestGeneration
        Task { await model.refresh(root: projectRoot, requestGeneration: requestGeneration) }
    }
}

/// A routable diff target: a `ChangedFile` wrapped so it satisfies both
/// `sheet(item:)` (Identifiable) and `navigationDestination(item:)` (Hashable),
/// since `ChangedFile` is Identifiable but not Hashable. Identity is the file's
/// repo-relative path (its `id`).
private struct DiffTarget: Identifiable, Hashable {
    let file: ChangedFile
    var id: String { file.id }

    static func == (lhs: DiffTarget, rhs: DiffTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One node in the by-folder tree: a directory `DisclosureGroup` (recursing over
/// in-memory `ChangeNode.children`, so no disk read is needed) or a file leaf —
/// the iOS mirror of the macOS `ChangeNodeView`.
private struct ChangeNodeView_iOS: View {
    @ObservedObject var model: LocalChangesModel
    let node: ChangeNode
    let onOpenDiff: (ChangedFile) -> Void
    let onRevert: (ChangedFile) -> Void
    let onResolveConflict: (ChangedFile) -> Void

    @State private var isExpanded = true

    var body: some View {
        if let file = node.file {
            ChangedFileRow_iOS(
                name: node.name,
                url: node.url,
                status: file.status,
                isChecked: model.revertSelection.contains(file.id),
                onTap: { onOpenDiff(file) },
                onToggleCheck: { model.toggleChecked(file) },
                onRevert: { onRevert(file) },
                onResolve: file.status == .conflicted ? { onResolveConflict(file) } : nil
            )
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children ?? []) { child in
                    ChangeNodeView_iOS(
                        model: model,
                        node: child,
                        onOpenDiff: onOpenDiff,
                        onRevert: onRevert,
                        onResolveConflict: onResolveConflict
                    )
                    .padding(.leading, 12)
                }
            } label: {
                let icon = FileIcon(for: DirectoryEntry(url: node.url, isDirectory: true))
                HStack(spacing: 6) {
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(iconColor(for: icon.color))
                    Text(node.name)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }
}

/// One changed-file row: a leading checkbox (multi-file revert), the file-type icon
/// tinted by its git status, the name, and a one-letter status badge. Tapping the
/// row opens its diff; a long-press context menu reverts.
private struct ChangedFileRow_iOS: View {
    let name: String
    let url: URL
    let status: FileStatus
    let isChecked: Bool
    let onTap: () -> Void
    let onToggleCheck: () -> Void
    let onRevert: () -> Void
    /// Non-nil for a conflicted file: adds a "Resolve…" context action opening the
    /// 3-pane merge editor.
    var onResolve: (() -> Void)?

    var body: some View {
        let icon = FileIcon(for: DirectoryEntry(url: url, isDirectory: false))
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            Image(systemName: icon.symbolName)
                .foregroundStyle(statusColor(status))
            Text(name)
            Spacer(minLength: 4)
            Text(statusLetter(status))
                .font(.caption.monospaced())
                .foregroundStyle(statusColor(status))
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            if let onResolve {
                Button("Resolve…", action: onResolve)
            }
            Button("Revert", role: .destructive, action: onRevert)
        }
    }
}

/// Semantic color for a git `FileStatus`, matching the macOS VCS conventions
/// (added → green, deleted → red, modified → blue, renamed → orange, untracked →
/// gray, conflicted → purple).
private func statusColor(_ status: FileStatus) -> Color {
    switch status {
    case .modified: return .blue
    case .added: return .green
    case .deleted: return .red
    case .renamed: return .orange
    case .untracked: return .gray
    case .conflicted: return .purple
    }
}

/// One-letter status badge, mirroring `git status`'s short codes.
private func statusLetter(_ status: FileStatus) -> String {
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
/// icons in the by-folder tree).
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
