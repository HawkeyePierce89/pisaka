#if os(macOS)
import SwiftUI
import PisakaCore

/// The project file tree on the left side of the window.
///
/// Renders the directory rooted at `model.projectRoot`; clicking a file row
/// calls `onOpenFile` (which opens it in a tab). When no folder is open a
/// placeholder is shown instead. The view holds no domain logic: directory
/// listing goes through `model.children(of:)`. File operations (create / rename
/// / delete) are surfaced as context menus that call back into the app
/// (`onNewFile`/`onNewFolder`/`onRename`/`onDelete`), which performs the disk I/O
/// and bumps `model.treeRevision` so the affected directory re-reads its cached
/// children.
///
/// `model.treeRevision` — the one re-read trigger `DirectoryNodeView` observes —
/// now has three sources: the app's own operations (the callbacks above, plus
/// Save As and a branch checkout), the FSEvents `ProjectWatcher` (external
/// changes, macOS-only), and the header's Refresh button below (the manual
/// fallback for anything the watcher misses — a buffer overflow, a network
/// volume, or simply not wanting to wait out the 1 s latency). The button calls
/// `model.bumpTreeRevision()` directly rather than through a callback, since
/// this view already observes the model and the bump needs no disk I/O.
struct ProjectTreeView: View {
    @ObservedObject var model: WorkspaceModel
    var onOpenFile: (URL) -> Void = { _ in }
    /// Invoked when the empty-pane placeholder is clicked. Defaults to a no-op
    /// so previews/tests can construct the view without the app wiring.
    var onOpenFolder: () -> Void = {}
    /// Create a new file inside the given directory. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onNewFile: (URL) -> Void = { _ in }
    /// Create a new folder inside the given directory.
    var onNewFolder: (URL) -> Void = { _ in }
    /// Rename the file or folder at the given url.
    var onRename: (URL) -> Void = { _ in }
    /// Delete the file or folder at the given url.
    var onDelete: (URL) -> Void = { _ in }
    /// Run the file at the given url in a new embedded-terminal session. Shown
    /// in the file-row context menu only for runnable file types.
    var onRun: (URL) -> Void = { _ in }
    /// Run the tests for the file at the given url in a new embedded-terminal
    /// session. Shown in the file-row context menu only for test file types
    /// (`TestCommand.isTestFile`).
    var onRunTest: (URL) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        Group {
            if let root = model.projectRoot {
                VStack(spacing: 0) {
                    header
                    Divider()
                    tree(root: root)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Click to open a folder")
                        .foregroundStyle(.secondary)
                        .font(metrics.scaledFont(.callout))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Make the whole pane (not just the text) the click target.
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenFolder)
            }
        }
    }

    /// Shown only when a folder is open (the placeholder pane keeps no header so
    /// its whole area stays the open-folder click target). Modeled on the
    /// `LocalChangesView` header.
    private var header: some View {
        HStack(spacing: metrics.scaled(8)) {
            Spacer()

            Button {
                // Re-read every expanded directory's cached listing. The watcher
                // covers external changes automatically; this is the manual path.
                model.bumpTreeRevision()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.borderless)
            .help("Refresh project tree")
        }
        .padding(.horizontal, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(6))
    }

    private func tree(root: URL) -> some View {
        ScrollView {
            // A plain VStack (not LazyVStack): the tree is already lazy
            // via DisclosureGroup, which only reads a directory on
            // expansion. A lazy container could discard an off-screen
            // node's cached @State children/expansion and force a
            // re-read on re-scroll, breaking the caching documented on
            // DirectoryNodeView.
            VStack(alignment: .leading, spacing: 0) {
                DirectoryNodeView(
                    model: model,
                    url: root,
                    name: root.lastPathComponent,
                    onOpenFile: onOpenFile,
                    onNewFile: onNewFile,
                    onNewFolder: onNewFolder,
                    onRename: onRename,
                    onDelete: onDelete,
                    onRun: onRun,
                    onRunTest: onRunTest,
                    isRoot: true,
                    startsExpanded: true
                )
                // Tie the root node's identity to the open folder so
                // switching projects starts a fresh node instead of
                // reusing the previous root's cached @State children.
                .id(root)
            }
            .padding(.vertical, metrics.scaled(4))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One directory row: a `DisclosureGroup` that lazily loads its children the
/// first time it is expanded. Children are cached in `@State` so collapsing and
/// re-expanding does not re-read the disk on every toggle.
private struct DirectoryNodeView: View {
    @ObservedObject var model: WorkspaceModel
    let url: URL
    let name: String
    let onOpenFile: (URL) -> Void
    let onNewFile: (URL) -> Void
    let onNewFolder: (URL) -> Void
    let onRename: (URL) -> Void
    let onDelete: (URL) -> Void
    let onRun: (URL) -> Void
    let onRunTest: (URL) -> Void
    /// The project root row offers only create actions (New File / New Folder);
    /// nested directories also offer Rename / Delete.
    let isRoot: Bool

    @State private var isExpanded: Bool
    @State private var children: [DirectoryEntry]?

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    /// `startsExpanded` seeds the initial expansion state. The root node is
    /// built with `true` so a freshly opened folder shows its immediate
    /// children right away; nested nodes default to `false` and load lazily on
    /// first expansion.
    init(
        model: WorkspaceModel,
        url: URL,
        name: String,
        onOpenFile: @escaping (URL) -> Void,
        onNewFile: @escaping (URL) -> Void,
        onNewFolder: @escaping (URL) -> Void,
        onRename: @escaping (URL) -> Void,
        onDelete: @escaping (URL) -> Void,
        onRun: @escaping (URL) -> Void,
        onRunTest: @escaping (URL) -> Void,
        isRoot: Bool = false,
        startsExpanded: Bool = false
    ) {
        self.model = model
        self.url = url
        self.name = name
        self.onOpenFile = onOpenFile
        self.onNewFile = onNewFile
        self.onNewFolder = onNewFolder
        self.onRename = onRename
        self.onDelete = onDelete
        self.onRun = onRun
        self.onRunTest = onRunTest
        self.isRoot = isRoot
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children ?? []) { entry in
                if entry.isDirectory {
                    DirectoryNodeView(
                        model: model,
                        url: entry.url,
                        name: entry.name,
                        onOpenFile: onOpenFile,
                        onNewFile: onNewFile,
                        onNewFolder: onNewFolder,
                        onRename: onRename,
                        onDelete: onDelete,
                        onRun: onRun,
                        onRunTest: onRunTest
                    )
                    .padding(.leading, metrics.scaled(12))
                } else {
                    FileRowView(
                        entry: entry,
                        onOpen: { onOpenFile(entry.url) },
                        onRename: { onRename(entry.url) },
                        onDelete: { onDelete(entry.url) },
                        onRun: { onRun(entry.url) },
                        onRunTest: { onRunTest(entry.url) }
                    )
                    .padding(.leading, metrics.scaled(12))
                }
            }
        } label: {
            // The root node is built from a URL, so synthesize an equivalent
            // directory entry to resolve the folder icon through `FileIcon`.
            let icon = FileIcon(for: DirectoryEntry(url: url, isDirectory: true))
            HStack(spacing: metrics.scaled(4)) {
                Image(systemName: icon.symbolName)
                    .foregroundStyle(color(for: icon.color))
                Text(name)
            }
            .font(metrics.scaledFont(.body))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("New File…") { onNewFile(url) }
                Button("New Folder…") { onNewFolder(url) }
                if !isRoot {
                    Divider()
                    Button("Rename…") { onRename(url) }
                    Button("Delete") { onDelete(url) }
                }
            }
        }
        .disclosureGroupStyle(FolderDisclosureStyle())
        .onChange(of: isExpanded) { expanded in
            if expanded && children == nil {
                loadChildren()
            }
        }
        // A node seeded as expanded (the root) starts `isExpanded == true`, so
        // `onChange` never fires for it — load its children on first appearance.
        .onAppear {
            if isExpanded && children == nil {
                loadChildren()
            }
        }
        // A file operation anywhere in the tree bumps `treeRevision`; re-read
        // this directory's children if it is currently expanded so a created /
        // renamed / deleted entry appears without reopening the folder. A
        // collapsed node instead drops its cached children so its next expansion
        // re-reads from disk (the lazy first-load only fires when `children ==
        // nil`); without this, a previously-loaded node targeted while collapsed
        // would show a stale listing until the folder is reopened.
        .onChange(of: model.treeRevision) { _ in
            if isExpanded {
                loadChildren()
            } else {
                children = nil
            }
        }
    }

    /// Read this directory's contents through the model. A read failure must
    /// not crash the view: we beep and leave `children` unset (mirroring the
    /// error handling in `PisakaApp`). Leaving it `nil` rather than caching an
    /// empty list lets a transient failure be retried by collapsing and
    /// re-expanding the directory.
    ///
    /// One failure is *not* worth feedback: the directory no longer existing. A
    /// revision-driven reload runs for every expanded node, and an external
    /// `rm -rf build` (now reaching the tree on its own through `ProjectWatcher`)
    /// bumps while `build/` and its expanded descendants are still in the
    /// hierarchy — each would throw `ENOENT` and beep before the parent's re-read
    /// drops them. Beeping a burst at the user for an ordinary delete they
    /// themselves performed is noise, not information.
    private func loadChildren() {
        do {
            children = try model.children(of: url)
        } catch {
            if !Self.isMissingFileError(error) {
                PlatformFeedback.warning()
            }
            children = nil
        }
    }

    /// Whether `error` is "this path is gone" — the node is about to disappear from
    /// the tree anyway, so its read failure is expected rather than reportable.
    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
    }
}

/// The disclosure style every directory row in the tree is drawn with: chevron
/// and label as one full-width row that toggles expansion wherever it is
/// clicked, matching a file row's hover treatment.
///
/// It exists so there is exactly *one* toggle path. The default macOS style
/// keeps the chevron as its own control, so making the label clickable too would
/// give a chevron click two chances to fire and a row click and a chevron click
/// different code. Drawing the chevron here removes that control entirely: the
/// row's single `.onTapGesture` is the only way expansion changes.
///
/// `configuration.content` is rendered only while expanded — the default style
/// does the same, and `DirectoryNodeView`'s lazy first load depends on it. The
/// style re-supplies the leading inset the default style used to add to
/// `content`, since a custom style indents nothing on its own.
private struct FolderDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDisclosureRow(configuration: configuration)
            if configuration.isExpanded {
                configuration.content
                    .modifier(FolderContentInset())
            }
        }
    }
}

/// The chevron + label row `FolderDisclosureStyle` draws. A separate view (not
/// inline in `makeBody`) because it needs its own `@State` for hover tracking
/// and its own `\.interfaceMetrics` read.
private struct FolderDisclosureRow: View {
    let configuration: DisclosureGroupStyleConfiguration

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.scaled(FolderRowLayout.spacing)) {
            Image(systemName: "chevron.right")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                // A fixed column so sibling labels line up regardless of the
                // chevron glyph's own metrics.
                .frame(width: metrics.scaled(FolderRowLayout.chevronWidth))
            configuration.label
        }
        // Exactly `FileRowView`'s treatment, so a folder row and a file row read
        // and highlight alike. The label brings its own `maxWidth: .infinity`
        // frame, but the row repeats it: the highlight must cover the chevron
        // column too, edge to edge.
        .padding(.horizontal, metrics.scaled(6))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        // Plain assignment, deliberately not `withAnimation`: animating the
        // insertion of a deep nested subtree is a regression this change does
        // not need.
        .onTapGesture { configuration.isExpanded.toggle() }
        .onHover { isHovering = $0 }
    }
}

/// Re-supplies the leading inset the default disclosure style adds to `content`
/// and a custom style does not: the chevron column plus the row's spacing, so
/// nesting lands where it did before. A modifier rather than a `.padding` inside
/// `makeBody` because the inset is scaled and `DisclosureGroupStyle.makeBody`
/// cannot read the environment.
private struct FolderContentInset: ViewModifier {
    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .padding(
                .leading,
                metrics.scaled(FolderRowLayout.chevronWidth)
                    + metrics.scaled(FolderRowLayout.spacing)
            )
    }
}

/// The two unscaled sizes the folder row and its content inset must agree on.
private enum FolderRowLayout {
    /// The fixed chevron column's width.
    static let chevronWidth: Double = 12
    /// The gap between the chevron column and the label.
    static let spacing: Double = 4
}

/// One file row in the tree: a clickable label that opens the file. The icon
/// is resolved from the file's `DirectoryEntry` via `FileIcon`.
private struct FileRowView: View {
    let entry: DirectoryEntry
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onRun: () -> Void
    let onRunTest: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        let icon = FileIcon(for: entry)
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(color(for: icon.color))
            Text(entry.name)
        }
        .font(metrics.scaledFont(.body))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, metrics.scaled(6))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .contextMenu {
            if RunCommand.canRun(fileName: entry.name) {
                Button {
                    onRun()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
            }
            if TestCommand.isTestFile(fileName: entry.name) {
                Button {
                    onRunTest()
                } label: {
                    Label("Run Test", systemImage: "checkmark.diamond")
                }
            }
            if RunCommand.canRun(fileName: entry.name)
                || TestCommand.isTestFile(fileName: entry.name) {
                Divider()
            }
            Button("Rename…") { onRename() }
            Button("Delete") { onDelete() }
        }
    }
}

/// Maps a semantic `FileIconColor` token to a concrete SwiftUI `Color`.
private func color(for token: FileIconColor) -> Color {
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
