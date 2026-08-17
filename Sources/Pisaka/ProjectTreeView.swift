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
///
/// Both row kinds are full-width click targets: a file row opens the file, a
/// directory row toggles its expansion (see `FolderDisclosureStyle`), and both
/// carry the same hover highlight and the same full-row right-click menu, so the
/// tree reads uniformly.
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
///
/// It is drawn with `FolderDisclosureStyle`, so the *whole* row — chevron, icon,
/// name and the blank space right of it — is one click target that toggles
/// expansion, with a file row's hover highlight; the right-click menu is handed
/// to the style so it covers that same rectangle. Expansion state, the lazy
/// first load, the `treeRevision` re-read and the error path are unaffected by
/// that: a row-body click loads children through the identical `onChange(of:
/// isExpanded)` path a chevron click has always used.
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
            // Stretches the label across the row's remaining width, so the name
            // truncates against the pane's edge rather than sitting at its
            // natural width. The click and right-click targets do not depend on
            // it — both live on the row (see `FolderDisclosureStyle`).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The menu travels to the style so it can hang off the *row* rather than
        // the label, exactly as `FileRowView` hangs its own off the row it
        // highlights: the chevron column and the row's padding are inside the
        // hover highlight and the tap target, so they must be inside the
        // right-click target too.
        .disclosureGroupStyle(
            FolderDisclosureStyle {
                Button("New File…") { onNewFile(url) }
                Button("New Folder…") { onNewFolder(url) }
                if !isRoot {
                    Divider()
                    Button("Rename…") { onRename(url) }
                    Button("Delete") { onDelete(url) }
                }
            }
        )
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
/// `configuration.content` is rendered only while expanded, so a collapsed
/// folder shows nothing — the default style does the same, and both tear the
/// content's state down on collapse. `DirectoryNodeView`'s lazy first load does
/// *not* hang off this: it is driven entirely by `onChange(of: isExpanded)` /
/// `onAppear`, and is unaffected either way.
///
/// The style adds **no** inset of its own to `content`. Measured on macOS 13+,
/// the default disclosure style indents content by zero (only its *label* sits
/// right of the triangle), so every point of the tree's nesting indent comes —
/// before and after this change — from the `.padding(.leading,
/// metrics.scaled(12))` `DirectoryNodeView` puts on each child row. An inset
/// here would be indent that never existed: it measured 28pt per level against
/// today's 12pt, truncating names in a pane only ~200pt wide.
///
/// The row's *right*-click menu is passed in rather than left on the label, so
/// the three targets a folder row has — the hover highlight, the tap and the
/// context menu — are the same rectangle, as they are on a file row. Left on the
/// label it would have excluded the chevron column and the row's own horizontal
/// padding while the highlight covered them.
private struct FolderDisclosureStyle<Menu: View>: DisclosureGroupStyle {
    /// The row's right-click menu items, built by `DirectoryNodeView`.
    @ViewBuilder var menu: () -> Menu

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDisclosureRow(configuration: configuration, menu: menu)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// The chevron + label row `FolderDisclosureStyle` draws. A separate view (not
/// inline in `makeBody`) because it needs its own `@State` for hover tracking
/// and its own `\.interfaceMetrics` read — and because keeping the hover state
/// off the enclosing view means hovering a folder invalidates the row, not its
/// whole expanded subtree.
private struct FolderDisclosureRow<Menu: View>: View {
    let configuration: DisclosureGroupStyleConfiguration
    @ViewBuilder var menu: () -> Menu

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.scaled(TreeRowLayout.chevronSpacing)) {
            Image(systemName: "chevron.right")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                // A fixed column so sibling labels line up regardless of the
                // chevron glyph's own metrics.
                .frame(width: metrics.scaled(TreeRowLayout.chevronWidth))
            configuration.label
        }
        // Exactly `FileRowView`'s treatment — the same three `TreeRowLayout`
        // values, not a second copy of them — so a folder row and a file row read
        // and highlight alike. The label brings its own `maxWidth: .infinity`
        // frame, but the row repeats it: the highlight must cover the chevron
        // column too, edge to edge.
        .padding(.horizontal, metrics.scaled(TreeRowLayout.horizontalPadding))
        .padding(.vertical, metrics.scaled(TreeRowLayout.verticalPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? TreeRowLayout.hoverHighlight : Color.clear)
        .contentShape(Rectangle())
        // Plain assignment, deliberately not `withAnimation`: animating the
        // insertion of a deep nested subtree is a regression this change does
        // not need.
        .onTapGesture { configuration.isExpanded.toggle() }
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        // Drawing the chevron ourselves removes the one control in this tree
        // that assistive technology could actuate — a `DisclosureGroup`'s own
        // triangle is a button with an expanded/collapsed value, and an
        // `onTapGesture` on an `HStack` is nothing at all. Re-declare the row as
        // that button, which restores *VoiceOver* actuation: the element carries
        // the button trait, the expansion state as its value and a press action
        // toggling the same binding the tap does, so this adds no second path to
        // expansion. It does **not** restore keyboard focus — an accessibility
        // trait is not a focusable control — so under Full Keyboard Access the
        // triangle can no longer be tabbed to. That is an accepted limitation,
        // not a fixed one: this tree has no keyboard navigation to fit it into
        // (a file row is an `onTapGesture` too, so no file was ever openable
        // that way), and adding focus to folder rows alone would make the tree
        // half-navigable. Restoring it belongs to a tree-wide keyboard pass.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isExpanded ? "expanded" : "collapsed")
        .accessibilityAction { configuration.isExpanded.toggle() }
    }
}

/// The unscaled geometry a tree row is drawn with. The first three values are
/// what makes a folder row and a file row read alike, so both row kinds read
/// them from here: duplicated as literals, a change to one row kind would
/// silently desynchronize the other. Each is scaled through
/// `\.interfaceMetrics` at its use site, like every other size in the tree.
private enum TreeRowLayout {
    /// The row's horizontal padding, inside the hover highlight.
    static let horizontalPadding: Double = 6
    /// The row's vertical padding, inside the hover highlight.
    static let verticalPadding: Double = 3
    /// The row's hover highlight.
    static let hoverHighlight = Color.accentColor.opacity(0.15)
    /// The folder row's fixed chevron column width.
    static let chevronWidth: Double = 12
    /// The folder row's gap between the chevron column and the label.
    static let chevronSpacing: Double = 4
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
        // Shared with `FolderDisclosureRow` through `TreeRowLayout`, which is
        // what keeps the two row kinds' treatment identical.
        .padding(.horizontal, metrics.scaled(TreeRowLayout.horizontalPadding))
        .padding(.vertical, metrics.scaled(TreeRowLayout.verticalPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? TreeRowLayout.hoverHighlight : Color.clear)
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
