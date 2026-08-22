#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
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
    var mayBeginFileOperation: () -> Bool = { true }
    /// Create a new file inside the given directory. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onNewFile: (URL, String) -> Void = { _, _ in }
    /// Create a new folder inside the given directory.
    var onNewFolder: (URL, String) -> Void = { _, _ in }
    /// Rename the file or folder at the given url.
    var onRename: (URL, String) -> Void = { _, _ in }
    /// Delete the file or folder at the given url.
    var onDelete: (URL) -> Void = { _ in }
    /// Run the file at the given url in a new embedded-terminal session. Shown
    /// in the file-row context menu only for runnable file types.
    var onRun: (URL) -> Void = { _ in }
    /// Run the tests for the file at the given url in a new embedded-terminal
    /// session. Shown in the file-row context menu only for test file types
    /// (`TestCommand.isTestFile`).
    var onRunTest: (URL) -> Void = { _ in }
    /// Move the file or folder at the first url into the folder at the second —
    /// the one thing dragging a row does. Wired to `PisakaApp.moveItem(at:into:)`,
    /// which decides (through `MoveDropRule`) and performs the move; this view
    /// only reports the gesture.
    var onMove: (URL, URL) -> Void = { _, _ in }

    /// The state a drag in flight carries, shared by every row: the source row
    /// and the memoized decision for the folder the pointer is over. Held here,
    /// at the tree's root, because a drag crosses rows — and as a `@StateObject`
    /// with nothing published, so it survives re-renders without causing any (see
    /// `TreeDragSession`).
    @StateObject private var dragSession = TreeDragSession()

    @State private var draft: TreeEditDraft?

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
            ScrollViewReader { proxy in
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
                        onMove: onMove,
                        mayBeginFileOperation: mayBeginFileOperation,
                        draft: $draft,
                        dragSession: dragSession,
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
                .onChange(of: draft) { newDraft in
                    if newDraft != nil {
                        withAnimation {
                            proxy.scrollTo("draft-row")
                        }
                    }
                }
            }
        }
        .onChange(of: model.projectRoot) { _ in
            draft = nil
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
    let onNewFile: (URL, String) -> Void
    let onNewFolder: (URL, String) -> Void
    let onRename: (URL, String) -> Void
    let onDelete: (URL) -> Void
    let onRun: (URL) -> Void
    let onRunTest: (URL) -> Void
    let onMove: (URL, URL) -> Void
    let mayBeginFileOperation: () -> Bool
    @Binding var draft: TreeEditDraft?
    /// The tree-wide drag state, handed down the recursion so every row reads and
    /// writes the same one.
    let dragSession: TreeDragSession
    /// The project root row offers only create actions (New File / New Folder);
    /// nested directories also offer Rename / Delete. It is also the one folder
    /// row that is a drop *target* without being a drag *source*.
    let isRoot: Bool
    let siblings: [String]

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
        onNewFile: @escaping (URL, String) -> Void,
        onNewFolder: @escaping (URL, String) -> Void,
        onRename: @escaping (URL, String) -> Void,
        onDelete: @escaping (URL) -> Void,
        onRun: @escaping (URL) -> Void,
        onRunTest: @escaping (URL) -> Void,
        onMove: @escaping (URL, URL) -> Void,
        mayBeginFileOperation: @escaping () -> Bool,
        draft: Binding<TreeEditDraft?>,
        dragSession: TreeDragSession,
        isRoot: Bool = false,
        startsExpanded: Bool = false,
        siblings: [String] = []
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
        self.onMove = onMove
        self.mayBeginFileOperation = mayBeginFileOperation
        self._draft = draft
        self.dragSession = dragSession
        self.isRoot = isRoot
        self.siblings = siblings
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if case .create(let parent, let isFolder) = draft, parent == url {
                TreeNameFieldView(
                    draft: draft!,
                    siblings: children?.map(\.name) ?? [],
                    onCommit: { newName in
                        if isFolder {
                            onNewFolder(url, newName)
                        } else {
                            onNewFile(url, newName)
                        }
                        draft = nil
                    },
                    onCancel: { draft = nil }
                )
                .padding(.leading, metrics.scaled(12))
                .id("draft-row")
            }

            let currentChildrenNames = children?.map(\.name) ?? []
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
                        onRunTest: onRunTest,
                        onMove: onMove,
                        mayBeginFileOperation: mayBeginFileOperation,
                        draft: $draft,
                        dragSession: dragSession,
                        siblings: currentChildrenNames
                    )
                    .padding(.leading, metrics.scaled(12))
                } else {
                    FileRowView(
                        entry: entry,
                        onOpen: { onOpenFile(entry.url) },
                        onBeginRename: {
                            if mayBeginFileOperation() {
                                draft = .rename(entry: entry)
                            }
                        },
                        onRename: { newName in
                            onRename(entry.url, newName)
                            draft = nil
                        },
                        onRenameCancel: { draft = nil },
                        onDelete: { onDelete(entry.url) },
                        onRun: { onRun(entry.url) },
                        onRunTest: { onRunTest(entry.url) },
                        dragSession: dragSession,
                        draft: draft,
                        siblings: currentChildrenNames
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
                    // Decorative, and hidden for the same reason the style hides
                    // its chevron: this label sits *inside* the row's combined
                    // accessibility element, so an unhidden symbol prepends its
                    // own name to that element's label ("folder fill, Sources").
                    // Directory-ness is already carried by the row's button
                    // trait and its expanded/collapsed `accessibilityValue`.
                    .accessibilityHidden(true)
                if case .rename(let draftedEntry) = draft, draftedEntry.url == url {
                    TreeNameFieldView(
                        draft: draft!,
                        siblings: siblings,
                        onCommit: { newName in
                            onRename(url, newName)
                            draft = nil
                        },
                        onCancel: { draft = nil }
                    )
                } else {
                    Text(name)
                }
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
            FolderDisclosureStyle(
                url: url,
                isRoot: isRoot,
                dragSession: dragSession,
                isDrafted: {
                    if case .rename(let draftedEntry) = draft, draftedEntry.url == url {
                        return true
                    }
                    return false
                }(),
                onMove: onMove
            ) {
                Button("New File") {
                    if mayBeginFileOperation() { draft = .create(parent: url, isFolder: false) }
                }
                Button("New Folder") {
                    if mayBeginFileOperation() { draft = .create(parent: url, isFolder: true) }
                }
                if !isRoot {
                    Divider()
                    Button("Rename") {
                        if mayBeginFileOperation() {
                            draft = .rename(entry: DirectoryEntry(url: url, isDirectory: true))
                        }
                    }
                    Button("Delete") { onDelete(url) }
                }
            }
        )
        .onChange(of: isExpanded) { expanded in
            if expanded && children == nil {
                loadChildren()
            }
        }
        .onChange(of: draft) { newDraft in
            if case .create(let parent, _) = newDraft, parent == url {
                isExpanded = true
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

            // Parent node drops the draft when a reload loses the drafted entry's url
            if case .rename(let draftedEntry) = draft,
               let currentChildren = children,
               !currentChildren.contains(where: { $0.url == draftedEntry.url }) {
                // To safely determine if this node is the parent, we can check if the drafted entry's URL is a direct child
                if draftedEntry.url.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path {
                    draft = nil
                }
            }
        } catch {
            if !Self.isMissingFileError(error) {
                PlatformFeedback.warning()
            } else if case .create(let parent, _) = draft, parent == url {
                draft = nil
            } else if case .rename(let draftedEntry) = draft,
                      draftedEntry.url.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path {
                draft = nil
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
    /// The folder this row draws: its drag payload and, as a drop target, the
    /// destination a dropped entry moves into.
    let url: URL
    /// The project root row, which drops accept but drags never start from.
    let isRoot: Bool
    /// The tree-wide drag state (see `TreeDragSession`).
    let dragSession: TreeDragSession
    let isDrafted: Bool
    /// Reports an accepted drop; the same callback every row kind receives.
    let onMove: (URL, URL) -> Void
    /// The row's right-click menu items, built by `DirectoryNodeView`.
    @ViewBuilder var menu: () -> Menu

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDisclosureRow(
                configuration: configuration,
                url: url,
                isRoot: isRoot,
                dragSession: dragSession,
                isDrafted: isDrafted,
                onMove: onMove,
                menu: menu
            )
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
    /// The folder this row draws — dragged from, and dropped onto.
    let url: URL
    /// The project root row: a drop target, never a drag source. Moving the open
    /// folder itself is not an operation this tree has.
    let isRoot: Bool
    let dragSession: TreeDragSession
    let isDrafted: Bool
    let onMove: (URL, URL) -> Void
    @ViewBuilder var menu: () -> Menu

    @State private var isHovering = false
    /// Whether a drag currently hovering this row would be accepted. Row-local
    /// `@State`, like `isHovering`: the drag session publishes nothing, so this
    /// is the only thing a drag invalidates — one row, not the subtree under it.
    @State private var isDropTarget = false

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
                // Decorative: the row below combines its children into one
                // element, so an unhidden symbol contributes its own name to
                // that element's label ("chevron.right, Sources"). The state it
                // draws is already carried, properly, by `accessibilityValue`.
                .accessibilityHidden(true)
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
        // The drop highlight replaces the hover one rather than layering over it
        // (the pointer is inside the row, so both are on), and is drawn at the
        // same site from the same enum, which is what keeps the two treatments
        // from drifting apart.
        .background(rowBackground)
        .contentShape(Rectangle())
        // Every non-root row is a drag source. Placed before the tap/hover/menu
        // block, which is untouched: a drag and a click are distinct gestures, so
        // clicking a folder still toggles it and right-clicking still opens the
        // same menu over the same rectangle.
        .projectTreeDragSource(isEnabled: !isRoot && !isDrafted, url: url, session: dragSession)
        // Plain assignment, deliberately not `withAnimation`: animating the
        // insertion of a deep nested subtree is a regression this change does
        // not need.
        .onTapGesture { if !isDrafted { configuration.isExpanded.toggle() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            if !isDrafted {
                menu()
            }
        }
        // Every folder row is a drop target, the root included: that is how an
        // entry is moved back to the top of the project.
        .onDrop(
            of: isDrafted ? [] : [ProjectTreeDrag.contentType],
            delegate: TreeDropDelegate(
                folder: url,
                session: dragSession,
                onMove: onMove,
                isDropTarget: $isDropTarget
            )
        )
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
        .accessibilityElement(children: isDrafted ? .contain : .combine)
        .accessibilityAddTraits(isDrafted ? [] : .isButton)
        .accessibilityValue(isDrafted ? "" : (configuration.isExpanded ? "expanded" : "collapsed"))
        .accessibilityAction { if !isDrafted { configuration.isExpanded.toggle() } }
    }

    /// The row's background: the drop highlight while a droppable drag is over
    /// it, otherwise the ordinary hover treatment.
    private var rowBackground: Color {
        if isDropTarget { return TreeRowLayout.dropHighlight }
        return isHovering ? TreeRowLayout.hoverHighlight : Color.clear
    }
}

/// The unscaled geometry a tree row is drawn with. The first three values are
/// what makes a folder row and a file row read alike, so both row kinds read
/// them from here: duplicated as literals, a change to one row kind would
/// silently desynchronize the other. Each is scaled through
/// `\.interfaceMetrics` at its use site, like every other size in the tree.
enum TreeRowLayout {
    /// The row's horizontal padding, inside the hover highlight.
    static let horizontalPadding: Double = 6
    /// The row's vertical padding, inside the hover highlight.
    static let verticalPadding: Double = 3
    /// The row's hover highlight.
    static let hoverHighlight = Color.accentColor.opacity(0.15)
    /// The highlight a folder row draws while a drag that *would be accepted*
    /// hovers it. Deliberately stronger than `hoverHighlight`, which is on at the
    /// same time (the pointer is inside the row): the two must be told apart at a
    /// glance, since the difference between them is the whole answer to "will
    /// this drop land here?".
    static let dropHighlight = Color.accentColor.opacity(0.4)
    /// The folder row's fixed chevron column width.
    static let chevronWidth: Double = 12
    /// The folder row's gap between the chevron column and the label.
    static let chevronSpacing: Double = 4

    /// The empty chevron gutter a *file* row leads with — the folder row's
    /// chevron column plus its spacing, so a file's icon and a sibling folder's
    /// icon land on the same vertical line.
    ///
    /// Load-bearing, not cosmetic. A child row is inset by
    /// `metrics.scaled(12)`, which is *less* than the gutter: without it a
    /// folder's label sat 22pt in while its own file children sat at 18pt, so
    /// files rendered 4pt to the **left** of the folder containing them and the
    /// hierarchy read inverted. Both row kinds leading with the same gutter puts
    /// every child strictly 12pt right of its parent again, at every depth and
    /// every interface scale.
    ///
    /// Scaled as the sum of the two *separately scaled* constants rather than
    /// `scaled(16)`: `InterfaceMetrics.scaled(_:)` rounds to the half-point
    /// grid, so only scaling each the way the folder row does keeps the two row
    /// kinds in lockstep instead of drifting half a point apart at some scales.
    static func chevronGutter(_ metrics: InterfaceMetrics) -> Double {
        metrics.scaled(chevronWidth) + metrics.scaled(chevronSpacing)
    }
}

/// One file row in the tree: a clickable label that opens the file. The icon
/// is resolved from the file's `DirectoryEntry` via `FileIcon`.
private struct FileRowView: View {
    let entry: DirectoryEntry
    let onOpen: () -> Void
    let onBeginRename: () -> Void
    let onRename: (String) -> Void
    let onRenameCancel: () -> Void
    let onDelete: () -> Void
    let onRun: () -> Void
    let onRunTest: () -> Void
    /// The tree-wide drag state (see `TreeDragSession`). A file row is a drag
    /// *source* only — a file is never a drop destination, so it installs no drop
    /// delegate and never highlights as one.
    let dragSession: TreeDragSession
    let draft: TreeEditDraft?
    let siblings: [String]

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        let icon = FileIcon(for: entry)
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(color(for: icon.color))
            if case .rename(let draftedEntry) = draft, draftedEntry.url == entry.url {
                TreeNameFieldView(
                    draft: draft!,
                    siblings: siblings,
                    onCommit: onRename,
                    onCancel: onRenameCancel
                )
            } else {
                Text(entry.name)
            }
        }
        .font(metrics.scaledFont(.body))
        .lineLimit(1)
        .truncationMode(.middle)
        // A file has nothing to disclose, but it still leads with the space a
        // folder row's chevron column occupies: that is what aligns its icon
        // with a sibling folder's and what keeps a child row from out-denting
        // the folder it sits in (see `TreeRowLayout.chevronGutter`). Applied
        // inside the row's horizontal padding, like the chevron column is.
        .padding(.leading, TreeRowLayout.chevronGutter(metrics))
        // Shared with `FolderDisclosureRow` through `TreeRowLayout`, which is
        // what keeps the two row kinds' treatment identical.
        .padding(.horizontal, metrics.scaled(TreeRowLayout.horizontalPadding))
        .padding(.vertical, metrics.scaled(TreeRowLayout.verticalPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? TreeRowLayout.hoverHighlight : Color.clear)
        .contentShape(Rectangle())
        // As on a folder row: added ahead of the untouched tap/hover/menu block,
        // through the same one drag-source helper.
        .projectTreeDragSource(isEnabled: !isDraftedRow, url: entry.url, session: dragSession)
        .onTapGesture { if !isDraftedRow { onOpen() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            if !isDraftedRow {
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
                Button("Rename") { onBeginRename() }
                Button("Delete") { onDelete() }
            }
        }
    }

    private var isDraftedRow: Bool {
        if case .rename(let draftedEntry) = draft, draftedEntry.url == entry.url {
            return true
        }
        return false
    }
}

/// The private drag payload the project tree publishes and accepts.
///
/// A type identifier of the app's own, deliberately **not** `public.file-url`:
/// registering the file url would offer every tree row to Finder as a file drag
/// and let a Finder file be dropped onto a folder row — a different feature,
/// with its own copy-vs-move, security-scope and cross-volume questions. Under
/// this identifier the payload means nothing outside this tree, so a drag that
/// leaves the window does nothing and a drag that arrives from elsewhere is
/// refused by `validateDrop` before any rule runs.
///
/// The registered item is the source's path, and nothing reads it back: the
/// authoritative source url is the one `TreeDragSession` recorded when the drag
/// started, which only this tree's own drag source sets. The payload exists so
/// the drag is legible to AppKit at all — an item provider registering no type
/// never begins a drag.
private enum ProjectTreeDrag {
    static let contentType = UTType(exportedAs: "ws.karmanov.pisaka.project-tree-row")

    static func itemProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(item: url.path as NSString, typeIdentifier: contentType.identifier)
    }
}

private extension View {
    /// Makes this row the source of a project-tree drag for `url` — or leaves it
    /// exactly as it is, which is how the project root row opts out.
    ///
    /// The opt-out is a `@ViewBuilder` branch rather than an `.onDrag` returning
    /// an empty item provider: a provider with nothing registered still begins a
    /// drag AppKit renders and no target can ever accept. `isEnabled` is fixed
    /// for a row's lifetime, so the branch costs no identity churn.
    @ViewBuilder
    func projectTreeDragSource(
        isEnabled: Bool = true,
        url: URL,
        session: TreeDragSession
    ) -> some View {
        if isEnabled {
            onDrag {
                // The one place a drag's source is recorded.
                session.begin(dragging: url)
                return ProjectTreeDrag.itemProvider(for: url)
            }
        } else {
            self
        }
    }
}

/// What one drag through the project tree carries: the row it started from, and
/// the decision most recently computed for a (source, target folder) pair.
///
/// An `ObservableObject` with **no** `@Published` property, on purpose. Starting
/// a drag, crossing rows and finishing one must invalidate nothing: everything a
/// drag draws is a row's own `isDropTarget` `@State`, so publishing here would
/// re-render the whole tree — including the subtree being dragged over — for
/// state no row reads.
///
/// The memo is what makes the *full*, disk-touching `MoveDropRule` decision
/// affordable as the hover answer. `validateDrop`, `dropUpdated` and
/// `dropEntered` all ask, repeatedly, while the pointer sits in one row, and
/// each fresh answer lists two directories. Keyed on the pair, the listing
/// happens once per row entered instead of once per mouse-moved event.
///
/// The answer computed here is advisory: it lights the row up and refuses an
/// impossible drop early. `PisakaApp.moveItem(at:into:)` runs `MoveDropRule`
/// again, behind the writer gate and through the app's own file service, at the
/// moment the move would happen — that is the authoritative decision, and the
/// one that reports a refusal to the user.
private final class TreeDragSession: ObservableObject {
    /// The row the drag in flight started from, `nil` when no drag is in flight.
    private(set) var source: URL?

    private var memoKey: String?
    private var memoValue: MoveDropDecision?

    /// Reads the two directory listings the full decision needs. A plain
    /// `FileService`, as `PisakaApp` holds: listing a folder for a name
    /// collision is the same read `model.children(of:)` already performs.
    private let fileService: FileServicing = FileService()

    func begin(dragging url: URL) {
        source = url
        memoKey = nil
        memoValue = nil
    }

    /// Ends the drag. Called when a drop is performed; a drag abandoned outside
    /// any target leaves `source` set, which is harmless — nothing consults it
    /// until the next `validateDrop`, and the next drag overwrites it.
    func end() {
        source = nil
        memoKey = nil
        memoValue = nil
    }

    /// `MoveDropRule`'s full decision for this pair, computed at most once per
    /// pair per drag.
    func decision(dropping source: URL, into folder: URL) -> MoveDropDecision {
        // NUL-joined: it cannot occur in a path, so no two distinct pairs can
        // collide on one key.
        let key = "\(source.path)\u{0}\(folder.path)"
        if key == memoKey, let cached = memoValue { return cached }
        let decision = MoveDropRule.decision(source: source, into: folder, fileService: fileService)
        memoKey = key
        memoValue = decision
        return decision
    }
}

/// The drop target every *folder* row installs — nested folders and the project
/// root alike, which is why it takes the destination as a plain url and knows
/// nothing about rows.
///
/// A drag is accepted only when all three hold: the payload carries the tree's
/// own private type identifier, the shared session names a source row, and
/// `MoveDropRule`'s full decision for that pair is `.move`. So a drop back into
/// the current parent, onto the dragged row itself, into its own subtree, onto a
/// colliding name or onto a vanished endpoint is refused — the row does not
/// light up, the pointer shows the refusal cursor, and releasing there does
/// nothing.
///
/// **That refusal is silent, by construction**: SwiftUI documents
/// `dropEntered`, `dropUpdated` and `performDrop` as running only for a drop
/// `validateDrop` accepted, so a refusal decided here never reaches
/// `PisakaApp.moveItem(at:into:)` and never raises an alert. The alert path is
/// for what this answer *cannot* have caught — the writer gate, and a
/// destination that gained the name (or a source that vanished) between the
/// hover and the release, which `moveItem` re-asks about behind that gate.
private struct TreeDropDelegate: DropDelegate {
    let folder: URL
    let session: TreeDragSession
    let onMove: (URL, URL) -> Void
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [ProjectTreeDrag.contentType]),
              let source = session.source else { return false }
        guard case .move = session.decision(dropping: source, into: folder) else { return false }
        return true
    }

    func dropEntered(info: DropInfo) {
        // Asked, not assumed. SwiftUI only reports entry for a *validated* drop,
        // so this should always be true — but the highlight's honesty is the
        // whole point of the rule, and tying it to the answer rather than to
        // that documented ordering costs nothing (the session memoized it for
        // `validateDrop` a moment ago) and cannot light a row up for a drop that
        // would be refused.
        isDropTarget = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }

    /// Puts the move cursor over a folder that would accept the entry, so the
    /// pointer and the highlight always say the same thing. `.forbidden` is the
    /// same hedge `dropEntered` makes: this too runs only for a validated drop,
    /// so it is the answer for a row SwiftUI should never have routed here.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Reached only after `validateDrop` accepted, so the decision is not
        // re-derived here; `moveItem` makes it again anyway, authoritatively.
        isDropTarget = false
        guard let source = session.source else { return false }
        // The session is closed *before* the callback: `onMove` may put a modal
        // alert up, and a session still naming a source behind that alert would
        // answer a later `validateDrop` for a drag that ended long ago.
        session.end()
        // And the callback itself is deferred out of this callout for the same
        // reason: `moveItem` can run a modal alert (the writer gate's notice, a
        // refusal the re-check caught, a failed disk move), and a modal loop
        // spun from inside AppKit's `performDragOperation:` blocks the drag
        // session — and the source app with it — behind a dialog the user must
        // dismiss before the drag can even finish. The drop itself is over: this
        // returns `true` now, and the move runs on the next turn of the loop.
        let move = onMove
        let destination = folder
        DispatchQueue.main.async { move(source, destination) }
        return true
    }
}

/// Maps a semantic `FileIconColor` token to a concrete SwiftUI `Color`.
func color(for token: FileIconColor) -> Color {
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
