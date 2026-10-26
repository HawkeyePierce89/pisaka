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
/// Creating and renaming happen **inline, not in a dialog**: choosing New File,
/// New Folder or Rename opens a draft on the row itself
/// (`TreeEditDraft` + `TreeNameFieldView`, `ProjectTreeDraftField.swift`), which
/// validates live and commits on Enter. That is why the three callbacks are
/// `(URL, String)` and not `(URL)`: they carry the text the field already
/// accepted — the target directory or entry, plus the name — where the retired
/// prompts collected it themselves. Delete, Run and Run Test have nothing to
/// type and stay parameterless.
///
/// `model.treeRevision` — the one re-read trigger `DirectoryNodeView` observes —
/// now has three sources: the app's own operations (the callbacks above, plus
/// Save As and a branch checkout), the FSEvents `ProjectWatcher` (external
/// changes, macOS-only), and the header's Refresh button below (the manual
/// fallback for anything the watcher misses — a buffer overflow, a network
/// volume, or simply not wanting to wait out the 1 s latency). The button calls
/// `model.bumpTreeRevision()` directly rather than through a callback, since
/// this view already observes the model and the bump needs no disk I/O; it then
/// calls `onRefreshGitStatus`, because the names' colours are the other half of
/// what the button promises and a git refresh is the app's to run.
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
    /// Delete the file or folder at the given url. The name is the one the
    /// row's menu item quoted, for the confirmation to quote too — a chain
    /// row's label (`TreeChain.deleteConfirmationName`); nil for a file or a
    /// plain folder, whose confirmation names the url's last component.
    var onDelete: (URL, String?) -> Void = { _, _ in }
    /// Run the file at the given url in a new embedded-terminal session. Shown
    /// in the file-row context menu only for runnable file types.
    var onRun: (URL) -> Void = { _ in }
    /// Run the tests for the file at the given url in a new embedded-terminal
    /// session. Shown in the file-row context menu only for test file types
    /// (`TestCommand.isTestFile`).
    var onRunTest: (URL) -> Void = { _ in }
    /// Show Local History for the file at the given url. Shown in the file-row
    /// context menu only — a directory has no revisions, because the store keys
    /// snapshots by a file's project-relative path.
    var onShowLocalHistory: (URL) -> Void = { _ in }
    /// Move the file or folder at the first url into the folder at the second —
    /// the one thing dragging a row does. Wired to `PisakaApp.moveItem(at:into:)`,
    /// which decides (through `MoveDropRule`) and performs the move; this view
    /// only reports the gesture.
    var onMove: (URL, URL) -> Void = { _, _ in }
    /// The latest Reveal in Project Tree request, or nil for none. Handed down
    /// the recursion beside the selection while it is live (see
    /// `TreeRevealRequest`).
    var reveal: TreeRevealRequest?
    /// What git says about each row, as `LocalChangesModel` last published it:
    /// the one source of the tree's git state, read as a value. Empty by
    /// default — every row plain — so previews and tests construct the view
    /// without a repository. The tree adds no git call, no trigger and no timer
    /// of its own; it is redrawn when the model publishes a new lookup.
    var gitStatus: TreeGitStatus = .empty
    /// The worst diagnostic severity at or below each row, as
    /// `DiagnosticsModel` last published it: read as a value, beside
    /// `gitStatus` and for its reasons. Empty by default — no row marked — so
    /// previews and tests construct the view without a language server.
    var diagnostics: TreeDiagnostics = .empty
    /// Invoked by the header's Refresh button right after it bumps the tree's
    /// revision, so a manual refresh re-reads git state as well as listings.
    /// Wired to `PisakaApp.refreshLocalChanges()`, which pins its request
    /// generation synchronously. Defaults to a no-op so previews and tests
    /// construct the view without the app wiring.
    var onRefreshGitStatus: () -> Void = {}

    /// The state a drag in flight carries, shared by every row: the source row
    /// and the memoized decision for the folder the pointer is over. Held here,
    /// at the tree's root, because a drag crosses rows — and as a `@StateObject`
    /// with nothing published, so it survives re-renders without causing any (see
    /// `TreeDragSession`).
    @StateObject private var dragSession = TreeDragSession()
    /// The tree's one `TreeListingMemo`, which every node's load — each chain
    /// probe included — lists through, so a directory is read at most once per
    /// `treeRevision` (see `TreeListingSource`).
    @StateObject private var listings = TreeListingSource()
    /// Holds the scroll offset the pinned stack reads (`TreeStickyViewport`).
    /// Nothing published here, like `listings`: the offset changes every scroll
    /// frame, and only the stack may be invalidated by it.
    @StateObject private var stickyViewport = TreeStickyViewportSource()

    @State private var draft: TreeEditDraft?
    @State private var draftAppearedTrigger: Int = 0
    /// The token of the last reveal whose target row reported itself on screen,
    /// or whose path an ancestor's listing turned out not to hold. From then on
    /// the request is withdrawn from the recursion, so a node the user collapses
    /// — or one rebuilt by a later re-expansion of its parent — is never
    /// re-expanded by a request already honoured or one that cannot be.
    @State private var completedRevealToken: Int?
    /// The keys (`TreeChainRule.key(for:)`) of the folders the user asked to see
    /// as separate folders, handed down the recursion as a value. Never written
    /// to the session, cleared on a project-root change and never pruned: a key
    /// whose folder is gone simply matches no row.
    @State private var separatedFolders: Set<String> = []
    /// The keys of folders whose node starts expanded the first time it appears
    /// — the remainder of an expanded chain the user just unfolded. Each such
    /// node removes its own key when it appears; cleared on a root change.
    @State private var opensOnAppearance: Set<String> = []

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Group {
            if let root = model.projectRoot {
                VStack(spacing: 0) {
                    // The header draws its own bottom rule, so no `Divider()`
                    // sits between it and the tree: a `Divider()` is painted in
                    // the system's separator value, which disagrees with the
                    // `hairline` role beside it in either appearance.
                    header
                    tree(root: root)
                }
            } else {
                // Reached only with tabs open and no folder: with neither, the
                // Welcome screen replaces the whole split, this pane included.
                VStack {
                    Spacer()
                    Text("Click to open a folder")
                        .foregroundStyle(theme.color(.textSecondary))
                        .font(metrics.scaledFont(.callout))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Make the whole pane (not just the text) the click target.
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenFolder)
            }
        }
        // Both branches draw the **sidebar's** ground, not the window's.
        //
        // The open-a-folder placeholder is not a hole showing the window
        // behind it: it stands inside the same split slot as the tree it
        // replaces, and a pane whose ground changed depending on whether a
        // folder happened to be open would read as a gap in the sidebar. It
        // therefore takes `bgPanel` like the tree.
        .background(theme.color(.bgPanel))
    }

    /// Shown only when a folder is open (the placeholder pane keeps no header so
    /// its whole area stays the open-folder click target).
    ///
    /// A fixed `sidebarHeaderHeight` strip, inset by `barPaddingX` — the one
    /// measurement the bottom bar also draws — carrying the open folder's name
    /// uppercased at the leading end and the Refresh button at the trailing one,
    /// with its own one-point `hairline` along the bottom edge.
    ///
    /// **The Refresh button is a deliberate deviation from the design**, which
    /// draws the project label alone: a restyle does not remove a working
    /// control, and this button is the tree's only manual re-read path (the
    /// watcher covers everything else, but not a buffer overflow or a network
    /// volume).
    private var header: some View {
        HStack(spacing: metrics.scaled(8)) {
            Text(model.projectRoot?.lastPathComponent.uppercased() ?? "")
                .font(metrics.scaledFont(.subheadline, weight: .semibold))
                .tracking(metrics.scaled(0.5))
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                // Re-read every expanded directory's cached listing. The watcher
                // covers external changes automatically; this is the manual path.
                // Then git state, which the names are coloured from.
                model.bumpTreeRevision()
                onRefreshGitStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .help("Refresh project tree")
            // A tooltip is not a name. This button's whole label is an
            // `Image(systemName:)`, and a `Button` combines its children, so
            // without an explicit label it announces the *symbol* — "arrow
            // clockwise" — which is not the command. The same sentence the
            // bottom bar's icon-only toggles carry, which is why both now
            // spell both.
            .accessibilityLabel("Refresh project tree")
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.barPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.sidebarHeaderHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    private func tree(root: URL) -> some View {
        // The reader wraps the scroll view, not the other way round: a proxy
        // drives only the scroll views its reader contains.
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack (not LazyVStack): the tree is already lazy
                // via DisclosureGroup, which only reads a directory on
                // expansion. A lazy container could discard an off-screen
                // node's cached @State children/expansion and force a
                // re-read on re-scroll, breaking the caching documented on
                // DirectoryNodeView. The pinned stack measures through
                // preferences for the same reason: each expanded node reports
                // its frame in the content space, which a scroll never moves,
                // so scrolling changes one offset value and lists nothing.
                VStack(alignment: .leading, spacing: 0) {
                    DirectoryNodeView(
                        model: model,
                        // The root is built as itself, a single segment: it is
                        // never one of a listing's entries, so `TreeChainRule`
                        // never sees it and it heads no chain.
                        shape: .folder(DirectoryEntry(url: root, isDirectory: true), offersShowAsOneRow: false),
                        revealURL: root,
                        depth: 0,
                        listingMemo: listings.memo(listingThrough: model),
                        separated: separatedFolders,
                        opensOnAppearance: opensOnAppearance,
                        onSeparation: apply,
                        onOpenFile: onOpenFile,
                        onNewFile: onNewFile,
                        onNewFolder: onNewFolder,
                        onRename: onRename,
                        onDelete: onDelete,
                        onRun: onRun,
                        onRunTest: onRunTest,
                        onShowLocalHistory: onShowLocalHistory,
                        onMove: onMove,
                        mayBeginFileOperation: mayBeginFileOperation,
                        onDraftAppeared: { draftAppearedTrigger += 1 },
                        draft: $draft,
                        dragSession: dragSession,
                        selection: TreeSelection(model.selectedFile?.url),
                        reveal: liveReveal,
                        gitStatus: gitStatus,
                        diagnostics: diagnostics,
                        onRevealed: { token, target in
                            guard completedRevealToken != token else { return }
                            completedRevealToken = token
                            guard let target else { return }
                            withAnimation {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        },
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
                // The content's top edge in the viewport's space — minus the
                // scroll offset — read on the padded content, which is also
                // the space every folder report is measured in, and written
                // into the holder's object, which only the pinned stack
                // observes: a scroll frame invalidates neither this view nor
                // any row. Written from the reader rather than handed up as a
                // preference: measured, a change caused by scrolling alone
                // never reaches an `onPreferenceChange` outside the scroll
                // view, while the reader itself sees every offset.
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(
                            of: geometry.frame(in: .named(TreeStickySpace.viewport)).minY, initial: true
                        ) { _, minY in
                            stickyViewport.viewport.scroll(to: -minY)
                        }
                    }
                }
                .coordinateSpace(.named(TreeStickySpace.content))
                .onChange(of: draftAppearedTrigger) { _ in
                    withAnimation {
                        proxy.scrollTo("draft-row")
                    }
                }
            }
            .coordinateSpace(.named(TreeStickySpace.viewport))
            // The pinned stack, on the scroll view rather than in its content:
            // it sits at the viewport's top edge — directly under the header,
            // which is outside the scroll view — whatever the offset. It reads
            // the expanded folders' reports as they cross the scroll view, and
            // its own reader answers the viewport's height.
            .overlayPreferenceValue(TreeStickyFoldersKey.self, alignment: .top) { reports in
                GeometryReader { geometry in
                    TreeStickyStackView(
                        reports: reports,
                        viewport: stickyViewport.viewport,
                        viewportHeight: Double(geometry.size.height),
                        gitStatus: gitStatus,
                        diagnostics: diagnostics
                    )
                }
            }
            .onChange(of: model.projectRoot) { _ in
                draft = nil
                listings.memo(listingThrough: model).reset()
                separatedFolders = []
                opensOnAppearance = []
            }
        }
    }

    /// The one change point of the unfold memory, reported by the rows.
    private func apply(_ change: TreeSeparationChange) {
        switch change {
        case .separate(let head, let opening):
            separatedFolders.insert(TreeChainRule.key(for: head))
            if let opening { opensOnAppearance.insert(TreeChainRule.key(for: opening)) }
        case .join(let folder):
            separatedFolders.remove(TreeChainRule.key(for: folder))
        case .appeared(let folder):
            opensOnAppearance.remove(TreeChainRule.key(for: folder))
        }
    }

    /// The reveal request while its target row has not yet reported itself.
    private var liveReveal: TreeRevealRequest? {
        guard let reveal, reveal.token != completedRevealToken else { return nil }
        return reveal
    }
}

/// A change to the tree's unfold memory, reported by a row through the one
/// callback the recursion hands down. Nothing here lists: the rows re-run the
/// rule against the listing memo.
private enum TreeSeparationChange {
    /// `Show as Separate Folders` on the chain headed at `head`; `opening` is
    /// its remainder's head when the chain was expanded, so that node starts
    /// expanded, and nil for a collapsed chain.
    case separate(head: URL, opening: URL?)
    /// `Show as One Row` on a separated folder.
    case join(URL)
    /// The node for `folder` appeared expanded, as recorded by `separate`, and
    /// drops its key so a later appearance starts collapsed as usual.
    case appeared(URL)
}

/// One Reveal in Project Tree request: the tab's file as the tree spells its
/// row, and every directory from the root down to that row's parent
/// (`TreeRevealRule.ancestors`). The token is monotonic, so revealing the same
/// file twice is two requests — the second re-expands what the user collapsed
/// in between.
///
/// It expands and scrolls; it never selects. The row is highlighted by
/// `TreeSelection`, because the app selects the tab before it builds the
/// request — one selection, not a second spelling of it.
///
/// Both questions compare standardized *paths*: a listing spells a directory
/// with a trailing slash, an appended component does not, and the two must
/// still match. They are asked of a node's `revealURL` — the opened root plus
/// one listing name per level — never of its listed `url`, because a listing
/// may spell its entries under a resolved parent (`/tmp` lists as
/// `/private/tmp`) the request does not share.
///
/// A chain row stands for several folders, so it asks the chain variants: it
/// expands when any segment is an ancestor, and its listing is its tail's,
/// below which its children's reveal spelling continues.
struct TreeRevealRequest: Equatable {
    let token: Int
    let target: URL
    let ancestors: [URL]

    /// The request that follows `previous` for the file at `fileURL`: the next
    /// token, the ancestors `TreeRevealRule` answers, and the target spelled as
    /// the tree spells the row — the last ancestor plus the file's name. Nil
    /// without a root or for a file outside it.
    init?(after previous: TreeRevealRequest?, revealing fileURL: URL, root: URL?) {
        guard let root,
              let ancestors = TreeRevealRule.ancestors(of: fileURL, root: root),
              let parent = ancestors.last else { return nil }
        token = (previous?.token ?? 0) + 1
        target = parent.appendingPathComponent(fileURL.lastPathComponent)
        self.ancestors = ancestors
    }

    /// Whether the directory row at `url` is one the request expands.
    func expands(_ url: URL) -> Bool {
        step(below: url) != nil
    }

    /// Whether the file row at `url` is the one being revealed.
    func targets(_ url: URL) -> Bool {
        Self.rowID(url) == Self.rowID(target)
    }

    /// The row the request needs inside the directory at `url` — the next
    /// ancestor, or the target inside the deepest one — or nil when the request
    /// does not expand `url`.
    func step(below url: URL) -> URL? {
        let path = Self.rowID(url)
        guard let index = ancestors.firstIndex(where: { Self.rowID($0) == path }) else { return nil }
        return index + 1 < ancestors.count ? ancestors[index + 1] : target
    }

    /// Whether a listing of the directory at `url` lacks the row the request
    /// needs there — an excluded entry (`.git`), a deleted file, or an entry of
    /// the wrong kind: an ancestor step must be a directory and the target must
    /// not be, or no row would ever continue or complete the request. The tree
    /// then withdraws the request, which would otherwise stay live and
    /// re-expand rebuilt folders the user collapsed.
    ///
    /// Entries are matched by **name**, not by url: the listing may spell them
    /// under a resolved parent the request does not share.
    func isUnreachable(below url: URL, listing: [DirectoryEntry]) -> Bool {
        guard let step = step(below: url) else { return false }
        let needsDirectory = Self.rowID(step) != Self.rowID(target)
        return !listing.contains { $0.name == step.lastPathComponent && $0.isDirectory == needsDirectory }
    }

    /// Whether the chain row whose segments are spelled `segments` (head first,
    /// in reveal spelling) is one the request expands: any one segment naming
    /// an ancestor is enough, since the row stands for all of them.
    func expands(anyOf segments: [URL]) -> Bool {
        segments.contains(where: expands)
    }

    /// `isUnreachable(below:listing:)` for a chain row: `listing` is the
    /// **tail's**. An inner segment has no listing to ask — the chain itself
    /// says that folder holds exactly the next segment, a directory — so a
    /// request whose step below an inner segment is anything else (another
    /// folder, or the target itself) can never continue and is unreachable.
    /// Below the tail it is the plain check. A single segment is a plain folder.
    func isUnreachable(belowChain segments: [URL], listing: [DirectoryEntry]) -> Bool {
        guard let tail = segments.last else { return false }
        for (inner, next) in zip(segments, segments.dropFirst()) {
            guard let step = step(below: inner) else { continue }
            if Self.rowID(step) != Self.rowID(next) || Self.rowID(step) == Self.rowID(target) { return true }
        }
        return isUnreachable(below: tail, listing: listing)
    }

    /// The scroll id a file row carries, so the tree can scroll to the target
    /// without a second spelling of it.
    static func rowID(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// The tree's selection, resolved **once per render** and handed down the
/// recursion.
///
/// A tree row is drawn as selected when its file is the active editor tab's
/// file, and the two sides are spelled by different producers: a row's url is
/// built by appending a listing's component to the opened root, while the tab's
/// came from wherever that tab was opened (a panel, a session record, a
/// definition jump). So the tab's url is carried in both spellings — as the tab
/// spells it, standardized, and canonically — and a row matches either.
///
/// Resolving it here rather than per row is the point. `resolvingSymlinksInPath()`
/// touches the file system, `DirectoryNodeView` observes the workspace, and a
/// keystroke in the editor re-renders every visible row: comparing per row cost
/// one `realpath(3)` per row per keystroke. One resolution per render costs one,
/// whatever the tree's size.
///
/// **The one limit, accepted.** A row reached through a *symlinked* root while
/// the tab's url is already canonical does not match, because the canonical side
/// is computed only for the tab and the row is compared as it is spelled. Tabs
/// opened from the tree share the tree's own spelling, and the paths that arrive
/// canonical (a definition jump) are canonical on both sides, so the gap is a
/// row highlight missing in a configuration neither producer creates.
struct TreeSelection: Equatable {
    /// The active tab's url as that tab spells it, standardized.
    let spelled: URL?
    /// The same url with its symlinks resolved.
    let canonical: URL?

    init(_ url: URL?) {
        let spelled = url?.standardizedFileURL
        self.spelled = spelled
        self.canonical = spelled?.resolvingSymlinksInPath()
    }

    /// Whether the row at `url` is the selected one. No file-system call: the
    /// row's own url is standardized (lexical) and compared against the two
    /// spellings resolved at the top of the render.
    func contains(_ url: URL) -> Bool {
        guard spelled != nil else { return false }
        let row = url.standardizedFileURL
        return row == spelled || row == canonical
    }
}

/// One directory row: a `DisclosureGroup` that lazily loads its children the
/// first time it is expanded. Children are cached in `@State` so collapsing and
/// re-expanding does not re-read the disk on every toggle.
///
/// The row draws a `TreeNodeShape` its parent hands it: one folder, or a chain
/// of folders `TreeChainRule` answered. Either way the head is the row's
/// identity and the **contents directory** — the tail — is what it lists and
/// expands to. Every listing, this node's own and each probe of its children,
/// is read through the tree's one `TreeListingMemo`, and the children drawn are
/// `TreeChainRule.rows` over that listing, so a folder and a chain go through
/// one `ForEach` branch and keep their `@State` when one turns into the other.
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
    /// What this row draws, as its parent's rows answered it (see
    /// `TreeNodeShape`); the root is a single folder.
    let shape: TreeNodeShape
    /// This node's head as a reveal request spells it — the opened root, then
    /// one listing name per level — which its listed url need not be: a listing
    /// may spell its entries under a resolved parent (`/tmp` lists as
    /// `/private/tmp`).
    let revealURL: URL
    /// The node's nesting depth: `0` for the root, the parent's plus one for a
    /// child. A chain row is one node and so one depth, whatever its segment
    /// count — what the pinned stack's rule reads (`TreeStickyRule.Folder`).
    let depth: Int
    /// The tree's one listing memo, handed down the recursion.
    let listingMemo: TreeListingMemo
    /// The keys (`TreeChainRule.key(for:)`) of folders the user asked to see as
    /// separate folders, handed down as a value.
    let separated: Set<String>
    /// The keys of folders whose node starts expanded on first appearance,
    /// handed down as a value beside `separated`.
    let opensOnAppearance: Set<String>
    /// The one way a row changes either set (`TreeSeparationChange`).
    let onSeparation: (TreeSeparationChange) -> Void
    let onOpenFile: (URL) -> Void
    let onNewFile: (URL, String) -> Void
    let onNewFolder: (URL, String) -> Void
    let onRename: (URL, String) -> Void
    let onDelete: (URL, String?) -> Void
    let onRun: (URL) -> Void
    let onRunTest: (URL) -> Void
    let onShowLocalHistory: (URL) -> Void
    let onMove: (URL, URL) -> Void
    let mayBeginFileOperation: () -> Bool
    let onDraftAppeared: () -> Void
    @Binding var draft: TreeEditDraft?
    /// The tree-wide drag state, handed down the recursion so every row reads and
    /// writes the same one.
    let dragSession: TreeDragSession
    /// The tree's selection, resolved once by `ProjectTreeView` and handed down
    /// the recursion so each file row can answer whether it is the selected one
    /// without a file-system call of its own (see `TreeSelection`). It carries no
    /// url at all when no tab is open, or when the active tab has no file on
    /// disk.
    let selection: TreeSelection
    /// The live reveal request, handed down beside `selection`, or nil.
    let reveal: TreeRevealRequest?
    /// The tree's git lookup, handed down beside `selection`. Each row asks it
    /// once — lexically, with no file-system call (see `TreeGitStatus`).
    let gitStatus: TreeGitStatus
    /// The tree's diagnostic lookup, handed down beside `gitStatus` and asked
    /// the same way: once per row, lexically (see `TreeDiagnostics`).
    let diagnostics: TreeDiagnostics
    /// Reported by the target file row once it is on screen, with the request's
    /// token and the row's scroll id; the tree then scrolls to it. A nil id
    /// withdraws a request this node's listing shows cannot be honoured.
    let onRevealed: (Int, String?) -> Void
    /// The project root row offers only create actions (New File / New Folder);
    /// nested directories also offer Rename / Delete. It is also the one folder
    /// row that is a drop *target* without being a drag *source*.
    let isRoot: Bool
    let siblings: [String]

    @State private var isExpanded: Bool
    /// The contents directory's listing, kept for the create draft's siblings
    /// and for reveal.
    @State private var children: [DirectoryEntry]?
    /// The rows drawn below this one: `TreeChainRule`'s answer over `children`.
    @State private var rows: [TreeRow]?
    /// The token of the last reveal request this node expanded for, so it acts
    /// on each request once and never fights a later collapse by the user.
    @State private var honouredRevealToken: Int?

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    /// `startsExpanded` seeds the initial expansion state. The root node is
    /// built with `true` so a freshly opened folder shows its immediate
    /// children right away; nested nodes default to `false` and load lazily on
    /// first expansion.
    init(
        model: WorkspaceModel,
        shape: TreeNodeShape,
        revealURL: URL,
        depth: Int,
        listingMemo: TreeListingMemo,
        separated: Set<String>,
        opensOnAppearance: Set<String>,
        onSeparation: @escaping (TreeSeparationChange) -> Void,
        onOpenFile: @escaping (URL) -> Void,
        onNewFile: @escaping (URL, String) -> Void,
        onNewFolder: @escaping (URL, String) -> Void,
        onRename: @escaping (URL, String) -> Void,
        onDelete: @escaping (URL, String?) -> Void,
        onRun: @escaping (URL) -> Void,
        onRunTest: @escaping (URL) -> Void,
        onShowLocalHistory: @escaping (URL) -> Void,
        onMove: @escaping (URL, URL) -> Void,
        mayBeginFileOperation: @escaping () -> Bool,
        onDraftAppeared: @escaping () -> Void,
        draft: Binding<TreeEditDraft?>,
        dragSession: TreeDragSession,
        selection: TreeSelection,
        reveal: TreeRevealRequest?,
        gitStatus: TreeGitStatus,
        diagnostics: TreeDiagnostics,
        onRevealed: @escaping (Int, String?) -> Void,
        isRoot: Bool = false,
        startsExpanded: Bool = false,
        siblings: [String] = []
    ) {
        self.model = model
        self.shape = shape
        self.revealURL = revealURL
        self.depth = depth
        self.listingMemo = listingMemo
        self.separated = separated
        self.opensOnAppearance = opensOnAppearance
        self.onSeparation = onSeparation
        self.onOpenFile = onOpenFile
        self.onNewFile = onNewFile
        self.onNewFolder = onNewFolder
        self.onRename = onRename
        self.onDelete = onDelete
        self.onRun = onRun
        self.onRunTest = onRunTest
        self.onShowLocalHistory = onShowLocalHistory
        self.onMove = onMove
        self.mayBeginFileOperation = mayBeginFileOperation
        self.onDraftAppeared = onDraftAppeared
        self._draft = draft
        self.dragSession = dragSession
        self.selection = selection
        self.reveal = reveal
        self.gitStatus = gitStatus
        self.diagnostics = diagnostics
        self.onRevealed = onRevealed
        self.isRoot = isRoot
        self.siblings = siblings
        _isExpanded = State(initialValue: startsExpanded)
    }

    /// The folder this row lists and expands to — the head for a plain folder,
    /// the tail for a chain — and the one a create writes into.
    private var contentsDirectory: URL { shape.contentsDirectory }

    /// Every segment of this row as a reveal request spells it, head first
    /// (`TreeNodeShape.revealURLs`); a plain folder's is its `revealURL` alone.
    private var segmentRevealURLs: [URL] { shape.revealURLs(underHead: revealURL) }

    /// The contents directory as a reveal request spells it — the tail's
    /// reveal url, which every child's reveal spelling continues from.
    private var contentsRevealURL: URL { segmentRevealURLs.last ?? revealURL }

    var body: some View {
        // Asked once per render, each of the head: the row stands for the
        // head's subtree, so its spoken state (and a plain folder's name
        // colour) is drawn from the one answer, and the glyph's one dot and
        // the spoken state from the other. A chain's segment names are
        // coloured per segment in `nameLabel(gitState:)`.
        let gitState = gitStatus.state(for: shape.spokenGitStateURL)
        let diagnosticMark = diagnostics.mark(for: shape.diagnosticMarkURL)
        DisclosureGroup(isExpanded: $isExpanded) {
            if case .create(let parent, let isFolder) = draft, parent == contentsDirectory {
                Group {
                    TreeNameFieldView(
                        // Rebuilt from the payload the `if case` just bound, not
                        // re-read out of the optional: the binding is the proof
                        // the draft is a create for *this* folder, so nothing
                        // here can be nil and no force-unwrap is needed to say so.
                        draft: .create(parent: parent, isFolder: isFolder),
                        siblings: children?.map(\.name) ?? [],
                        onCommit: { newName in
                            if isFolder {
                                onNewFolder(contentsDirectory, newName)
                            } else {
                                onNewFile(contentsDirectory, newName)
                            }
                            draft = nil
                        },
                        onCancel: { draft = nil }
                    )
                    .id("draft-\(isFolder ? "folder" : "file")")
                }
                .padding(.leading, metrics.scaled(ChromeGeometry.treeIndentStep))
                .id("draft-row")
                .onAppear {
                    onDraftAppeared()
                }
            }

            let currentChildrenNames = children?.map(\.name) ?? []
            // One branch for a plain folder and a chain alike, identified by the
            // row's head (`TreeRow.id`): a folder that turns into a chain, or
            // back, keeps its node and therefore its expansion.
            ForEach(rows ?? []) { row in
                if let childShape = TreeNodeShape(row) {
                    DirectoryNodeView(
                        model: model,
                        shape: childShape,
                        revealURL: contentsRevealURL.appendingPathComponent(childShape.head.lastPathComponent),
                        depth: depth + 1,
                        listingMemo: listingMemo,
                        separated: separated,
                        opensOnAppearance: opensOnAppearance,
                        onSeparation: onSeparation,
                        onOpenFile: onOpenFile,
                        onNewFile: onNewFile,
                        onNewFolder: onNewFolder,
                        onRename: onRename,
                        onDelete: onDelete,
                        onRun: onRun,
                        onRunTest: onRunTest,
                        onShowLocalHistory: onShowLocalHistory,
                        onMove: onMove,
                        mayBeginFileOperation: mayBeginFileOperation,
                        onDraftAppeared: onDraftAppeared,
                        draft: $draft,
                        dragSession: dragSession,
                        selection: selection,
                        reveal: reveal,
                        gitStatus: gitStatus,
                        diagnostics: diagnostics,
                        onRevealed: onRevealed,
                        startsExpanded: opensOnAppearance.contains(TreeChainRule.key(for: childShape.head)),
                        siblings: childShape.renameSiblings ?? currentChildrenNames
                    )
                    .padding(.leading, metrics.scaled(ChromeGeometry.treeIndentStep))
                } else if case .file(let entry) = row {
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
                        onDelete: { onDelete(entry.url, nil) },
                        onRun: { onRun(entry.url) },
                        onRunTest: { onRunTest(entry.url) },
                        onShowLocalHistory: { onShowLocalHistory(entry.url) },
                        dragSession: dragSession,
                        draft: draft,
                        siblings: currentChildrenNames,
                        isSelected: selection.contains(entry.url),
                        gitState: gitStatus.state(for: entry.url),
                        diagnosticMark: diagnostics.mark(for: entry.url)
                    )
                    .padding(.leading, metrics.scaled(ChromeGeometry.treeIndentStep))
                    .id(TreeRevealRequest.rowID(entry.url))
                    // Causal, not timed: the target row reports itself when it
                    // appears (its folder just expanded) or, already on screen,
                    // when the request arrives.
                    .onAppear { reportIfRevealed(entry) }
                    .onChange(of: reveal) { _ in reportIfRevealed(entry) }
                }
            }
        } label: {
            TreeFolderLabel(isExpanded: isExpanded, diagnosticMark: diagnosticMark) {
                nameLabel(gitState: gitState)
            }
        }
        // The menu travels to the style so it can hang off the *row* rather than
        // the label, exactly as `FileRowView` hangs its own off the row it
        // highlights: the chevron column and the row's padding are inside the
        // hover highlight and the tap target, so they must be inside the
        // right-click target too.
        .disclosureGroupStyle(
            FolderDisclosureStyle(
                dragSource: shape.dragSource,
                dropDestination: shape.dropDestination,
                isRoot: isRoot,
                dragSession: dragSession,
                isDrafted: isDrafted,
                gitState: gitState,
                diagnosticMark: diagnosticMark,
                scrollID: TreeRevealRequest.rowID(shape.head),
                onMove: onMove
            ) {
                folderMenu
            }
        )
        .background { stickyReport }
        // Collapsing takes this node's whole subtree out of the hierarchy, not
        // just its direct children — so a draft anywhere *below* this folder
        // loses the view that renders it. It has to be dropped here, or it
        // survives with nothing drawing it: no field to press Esc in, no
        // mouse-down monitor (the region view went away with the row), and a
        // later re-expansion would revive an editable field that steals focus
        // for a rename the user believes they ended by collapsing the folder.
        //
        // Asked about the contents directory, not the head: a chain's own rename
        // draft is anchored inside the head (at the tail's parent) and is drawn
        // in this row's label, which a collapse keeps on screen.
        .onChange(of: isExpanded) { expanded in
            if !expanded {
                if draftIsBelow(contentsDirectory) {
                    draft = nil
                }
            } else if children == nil {
                loadChildren()
            }
        }
        .onChange(of: draft) { newDraft in
            if case .create(let parent, _) = newDraft, parent == contentsDirectory {
                isExpanded = true
            }
        }
        // A reveal expands every ancestor of its target. A node already on
        // screen sees the request change; a node created by its parent's
        // expansion sees it only on appear, so both ask.
        .onChange(of: reveal) { _ in expandIfRevealed() }
        // A node seeded as expanded (the root) starts `isExpanded == true`, so
        // `onChange` never fires for it — load its children on first appearance.
        .onAppear {
            // The remainder of an unfolded, expanded chain started expanded
            // (`startsExpanded`); it spends its key now, once.
            if opensOnAppearance.contains(TreeChainRule.key(for: shape.head)) {
                onSeparation(.appeared(shape.head))
            }
            expandIfRevealed()
            // A reshape can hand a draft to a node built collapsed — a
            // shortened chain's old tail, now a plain row of its own, or a
            // folder under an unfolded chain's tail — where nothing draws it.
            dropDraftHiddenByCollapse()
            if isExpanded && children == nil {
                loadChildren()
            }
        }
        // A file operation anywhere in the tree bumps `treeRevision`, so a
        // created / renamed / deleted entry appears without reopening the folder.
        .onChange(of: model.treeRevision) { _ in reloadOrForget() }
        // The parent's rows re-ran and handed this node a different shape — a
        // chain that extended or shortened keeps its head, and so this node,
        // but now lists another tail. The memo already holds that listing
        // (the parent's probe read it), so this reload reads nothing new.
        .onChange(of: shape) { _ in reloadOrForget() }
        // Which folders are separated changed: the same listing, new rows. The
        // rule re-runs against the memo alone, which holds every probe this
        // node's listing already caused, and nothing is listed — a probe that
        // failed under the load is answered as that failure again, and is
        // retried by the next load, never by the toggle.
        //
        // The memo answers only for a load it still remembers. A project-root
        // change resets it in the tree's `onChange(of: projectRoot)`, which
        // SwiftUI may run *after* the new root node's `onAppear` load — the
        // same root change also clears `separated`, so this handler would then
        // re-run over an empty memo and draw every chain as a plain folder.
        // When this node's own listing is not remembered, the toggle has no
        // load behind it, so it reloads (or forgets, collapsed) instead.
        //
        // The remembered listing is the one the rows are computed from, and it
        // is stored as `children`: the rows and the listing the create draft
        // and reveal read then always come from one read.
        .onChange(of: separated) { _ in
            guard children != nil else { return }
            guard let listing = try? listingMemo.rememberedListing(
                of: contentsDirectory, revision: model.treeRevision
            ) else {
                reloadOrForget()
                return
            }
            let childRows = childRows(for: listing, revision: model.treeRevision, rememberedOnly: true)
            children = listing
            rows = childRows
            dropDraftNotLed(by: childRows)
        }
    }

    /// Whether the open draft renames this row — a plain folder, or a chain's
    /// tail, which is the entry a chain row's rename names.
    private var isDrafted: Bool {
        if case .rename(let draftedEntry) = draft, draftedEntry.url == shape.renameEntry.url {
            return true
        }
        return false
    }

    /// The row's name, or the rename field standing in for it.
    ///
    /// The name itself is `TreeFolderName`, the one the pinned copy draws too.
    /// A chain's rename field replaces the tail's name only: the leading
    /// segments and their `/` stay drawn before it, coloured as in the label.
    @ViewBuilder
    private func nameLabel(gitState: TreeGitState) -> some View {
        if case .rename(let draftedEntry) = draft, draftedEntry.url == shape.renameEntry.url {
            TreeNameFieldView(
                // The bound entry, not the optional re-read: see the create row
                // in the body.
                draft: .rename(entry: draftedEntry),
                siblings: siblings,
                leading: shape.chain.map {
                    TreeFolderName.segmentsText(
                        $0.leadingSegments, under: $0, trailingSeparator: true,
                        gitStatus: gitStatus, resolving: theme.color
                    )
                },
                onCommit: { newName in
                    onRename(draftedEntry.url, newName)
                    draft = nil
                },
                onCancel: { draft = nil }
            )
        } else {
            TreeFolderName(shape: shape, gitState: gitState, gitStatus: gitStatus)
        }
    }

    /// This node's report to the pinned stack while it is expanded: its frame
    /// in the tree's content space, and what a pinned copy of its row needs to
    /// draw and act. A collapsed node attaches no reader — it has no subtree
    /// to measure — and the frame it reports does not move while the tree
    /// scrolls, so a scroll changes no report and reads nothing.
    @ViewBuilder
    private var stickyReport: some View {
        if isExpanded {
            GeometryReader { geometry in
                let report = TreeStickyFolderReport(
                    frame: geometry.frame(in: .named(TreeStickySpace.content)),
                    depth: depth,
                    isExpanded: isExpanded,
                    shape: shape,
                    scrollID: TreeRevealRequest.rowID(shape.head),
                    expansion: $isExpanded
                )
                Color.clear.preference(key: TreeStickyFoldersKey.self, value: [report])
            }
        }
    }

    /// The row's right-click menu. Every title and every address is the
    /// shape's — for a chain, `TreeChain`'s: a create opens under the tail,
    /// a rename names the tail, a delete removes the head.
    ///
    /// Grouped by `Section`s rather than separated by `Divider()`s: a menu
    /// renders the same separators between sections, and the dock's swept
    /// surfaces spell no `Divider()` at all.
    @ViewBuilder
    private var folderMenu: some View {
        Section {
            Button("New File") {
                if mayBeginFileOperation() { draft = .create(parent: contentsDirectory, isFolder: false) }
            }
            Button("New Folder") {
                if mayBeginFileOperation() { draft = .create(parent: contentsDirectory, isFolder: true) }
            }
        }
        if !isRoot {
            Section {
                Button(shape.renameTitle) {
                    if mayBeginFileOperation() {
                        draft = .rename(entry: shape.renameEntry)
                    }
                }
                Button(shape.deleteTitle) { onDelete(shape.deleteTarget, shape.deleteConfirmationName) }
            }
        }
        // A view choice, not a file operation: no draft, no gate. Unfolding an
        // expanded chain opens its remainder, so the row the user was looking
        // at stays expanded; the head keeps its own expansion, its identity
        // unchanged. Folders opened *below* the tail are rebuilt under the new
        // remainder node and come back collapsed — a stated limit.
        if let chain = shape.chain {
            Section {
                Button(TreeChain.showAsSeparateFoldersTitle) {
                    onSeparation(.separate(head: chain.identity, opening: isExpanded ? chain.remainderHead : nil))
                }
            }
        } else if shape.offersShowAsOneRow {
            Section {
                Button(TreeChain.showAsOneRowTitle) { onSeparation(.join(shape.head)) }
            }
        }
    }

    /// Re-read the contents directory if this node is expanded; otherwise drop
    /// the cached listing so the next expansion re-reads it (the lazy first load
    /// only fires when `children == nil`). Without the drop, a previously loaded
    /// node changed while collapsed would show a stale listing until reopened.
    private func reloadOrForget() {
        if isExpanded {
            loadChildren()
        } else {
            children = nil
            rows = nil
            // A shortened chain keeps its node but moves its contents up: a
            // draft its old tail drew now sits below this collapsed row.
            dropDraftHiddenByCollapse()
        }
    }

    /// A collapsed node draws nothing below its contents directory, so a draft
    /// anchored there is drawn nowhere and is dropped — the collapse handler's
    /// rule, re-asserted where a reshape rather than a click leaves the node
    /// collapsed with such a draft.
    private func dropDraftHiddenByCollapse() {
        if !isExpanded && draftIsBelow(contentsDirectory) {
            draft = nil
        }
    }

    /// Drop the draft when it hangs off this node's rows and none of
    /// `childRows` still offers the way down to it.
    private func dropDraftNotLed(by childRows: [TreeRow]) {
        if let hanging = draftHangingBelow(),
           !childRows.contains(where: { $0.leads(toDraftAnchor: hanging.anchor, renaming: hanging.renamed) }) {
            draft = nil
        }
    }

    /// `TreeChainRule`'s rows for this node's listing, every probe read through
    /// the memo under `revision` — or, with `rememberedOnly`, answered by the
    /// memo alone, a miss reading nothing. A probe failure is silent by the
    /// rule: it shapes the answer (a plain row) and never beeps.
    private func childRows(for listing: [DirectoryEntry], revision: Int, rememberedOnly: Bool = false) -> [TreeRow] {
        let memo = listingMemo
        return TreeChainRule.rows(
            in: listing,
            separated: separated,
            isSymbolicLink: { model.isSymbolicLink($0) },
            list: rememberedOnly
                ? { try memo.rememberedListing(of: $0, revision: revision) }
                : { try memo.listing(of: $0, revision: revision) }
        )
    }

    /// Expand this node once for a reveal request naming it — for a chain,
    /// naming any one of its segments. Expansion goes through the ordinary
    /// `onChange(of: isExpanded)` → `loadChildren()` path.
    private func expandIfRevealed() {
        guard let reveal, reveal.token != honouredRevealToken,
              reveal.expands(anyOf: segmentRevealURLs) else { return }
        honouredRevealToken = reveal.token
        isExpanded = true
        // Already expanded with a listing in hand: no `loadChildren()` follows,
        // so the reachability check runs here.
        withdrawRevealIfUnreachable()
    }

    /// Withdraw the live reveal when this node's listing lacks the row it needs
    /// here, or — for a chain — when the request turns off at an inner segment
    /// (`TreeRevealRequest.isUnreachable(belowChain:listing:)`).
    private func withdrawRevealIfUnreachable() {
        guard let reveal, let children,
              reveal.isUnreachable(belowChain: segmentRevealURLs, listing: children) else { return }
        onRevealed(reveal.token, nil)
    }

    /// Tell the tree the reveal's target row is on screen. The row is matched
    /// in the request's spelling and scrolled to by its own scroll id.
    private func reportIfRevealed(_ entry: DirectoryEntry) {
        guard let reveal, reveal.targets(contentsRevealURL.appendingPathComponent(entry.name)) else { return }
        onRevealed(reveal.token, TreeRevealRequest.rowID(entry.url))
    }

    /// Read the contents directory through the tree's listing memo, then draw
    /// `TreeChainRule`'s rows over it. A read failure must not crash the view:
    /// we beep and leave `children` unset (mirroring the error handling in
    /// `PisakaApp`). Leaving it `nil` rather than caching an empty list — and the
    /// memo remembering successes only — lets a transient failure be retried by
    /// collapsing and re-expanding the directory. Only this node's own read can
    /// beep; a failure while probing a child is silent by the rule.
    ///
    /// One failure is *not* worth feedback: the directory no longer existing. A
    /// revision-driven reload runs for every expanded node, and an external
    /// `rm -rf build` (now reaching the tree on its own through `ProjectWatcher`)
    /// bumps while `build/` and its expanded descendants are still in the
    /// hierarchy — each would throw `ENOENT` and beep before the parent's re-read
    /// drops them. Beeping a burst at the user for an ordinary delete they
    /// themselves performed is noise, not information.
    private func loadChildren() {
        let revision = model.treeRevision
        do {
            let listing = try listingMemo.listing(of: contentsDirectory, revision: revision)
            let childRows = childRows(for: listing, revision: revision)
            children = listing
            rows = childRows
            withdrawRevealIfUnreachable()

            // A successful reload can lose the draft just as thoroughly as a
            // collapse or an `ENOENT` does — the entry the draft is drawn at, or
            // the child folder its subtree hangs from, is simply no longer
            // listed (an external delete, rename or move), or a reshape folded
            // the folder it was anchored on into a chain's inner segment. That
            // row is gone from the hierarchy with nothing left to draw the
            // field, so the draft is dropped here for the reason recorded on the
            // collapse above.
            dropDraftNotLed(by: childRows)
        } catch {
            if !Self.isMissingFileError(error) {
                PlatformFeedback.warning()
            } else if draftIsBelow(contentsDirectory) {
                // This directory is gone, so everything under it is too — the
                // same reach as a collapse, for the same reason.
                draft = nil
            }
            children = nil
            rows = nil
        }
    }

    /// Whether the open draft is anchored anywhere inside `directory` — which is
    /// exactly the set of drafts that stop being rendered when `directory`
    /// collapses or disappears.
    ///
    /// Both draft kinds are asked about the folder they would *write* into: a
    /// create's target parent, and a rename's containing directory. Asking about
    /// the containing directory rather than the entry itself is what keeps a
    /// folder's own rename draft alive when that folder collapses — that draft is
    /// drawn in the folder's label row, which stays on screen, and its containing
    /// directory is the folder's parent, outside `directory`.
    ///
    /// The containment test is `ScopedFileAccess.path(_:isWithin:)` over
    /// `standardizedFileURL` alone — deliberately **not** the symlink-resolving
    /// transform `PisakaApp.isInsideProject(_:root:)` applies, which asks a
    /// different question. That one asks "is this file the same file as one
    /// inside the project", where two spellings of one file must agree; this one
    /// asks "does this row hang off that row", which is a question about the
    /// *tree*. The tree is built by appending components to the opened root and
    /// to each listing, so both sides here are already spelled the same way, and
    /// resolving would answer about the filesystem instead: a project containing
    /// `link -> deep/real` would drop a draft rendered under `link` when the
    /// unrelated `deep` collapses, and would keep one alive unrendered when
    /// `link` points outside the collapsed directory. `standardizedFileURL` is
    /// still applied on both sides — it removes `.`/`..` and trailing slashes
    /// without touching symlinks.
    private func draftIsBelow(_ directory: URL) -> Bool {
        guard let draft else { return false }
        let anchor: URL
        switch draft {
        case .create(let parent, _): anchor = parent
        case .rename(let draftedEntry): anchor = draftedEntry.url.deletingLastPathComponent()
        }
        return ScopedFileAccess.path(
            anchor.standardizedFileURL.path,
            isWithin: directory.standardizedFileURL.path
        )
    }

    /// The open draft's anchor — the folder it writes into — and the entry it
    /// renames, when the draft hangs off one of *this* node's rows: `nil` when no
    /// draft is anchored below the contents directory, or when the draft is
    /// drawn by this node's own row (a create in this very folder — this folder
    /// exists, we just read it).
    ///
    /// This is the reload half of `draftIsBelow(_:)`, and deliberately the same
    /// reach: rows that no longer offer the way down to the drafted row have
    /// taken that row out of the hierarchy exactly as a collapse would. Whether a
    /// row still offers it is `TreeRow.leads(toDraftAnchor:renaming:)`'s answer,
    /// which also requires a folder further down to *still be one*, because a
    /// folder replaced by a file of the same name (an external
    /// `rm -rf src && touch src`) stops rendering its subtree without ever
    /// losing the name.
    private func draftHangingBelow() -> (anchor: URL, renamed: URL?)? {
        guard let draft, draftIsBelow(contentsDirectory) else { return nil }
        switch draft {
        case .create(let parent, _):
            let isThisFolder = parent.standardizedFileURL.path == contentsDirectory.standardizedFileURL.path
            return isThisFolder ? nil : (parent, nil)
        case .rename(let draftedEntry):
            return (draftedEntry.url.deletingLastPathComponent(), draftedEntry.url)
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

/// What one directory node draws, as its parent's rows hand it down: a single
/// folder (the root, a plain folder row) or a chain `TreeChainRule` answered.
/// Every address is read off the Core value; the view derives none of them.
///
/// Equatable as a whole, chain listing included, so a node notices a reshape
/// that kept its head — an extended or shortened chain — and reloads.
private enum TreeNodeShape: Equatable {
    /// One folder; `offersShowAsOneRow` is the rule's answer for a separated
    /// folder that would otherwise head a chain.
    case folder(DirectoryEntry, offersShowAsOneRow: Bool)
    case chain(TreeChain)

    /// The shape a directory row draws; nil for a file row.
    init?(_ row: TreeRow) {
        switch row {
        case .file: return nil
        case .folder(let entry, let offersShowAsOneRow): self = .folder(entry, offersShowAsOneRow: offersShowAsOneRow)
        case .chain(let chain): self = .chain(chain)
        }
    }

    /// The row's identity: the folder, or the chain's head.
    var head: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.identity
        }
    }

    /// What the row lists and expands to: the folder, or the chain's tail.
    var contentsDirectory: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.contentsDirectory
        }
    }

    /// The chain this row draws, or nil for a single folder.
    var chain: TreeChain? {
        if case .chain(let chain) = self { return chain }
        return nil
    }

    /// Whether the row's menu offers `Show as One Row`: a separated folder
    /// whose joining the rule says would draw a chain of more than one segment.
    var offersShowAsOneRow: Bool {
        if case .folder(_, let offers) = self { return offers }
        return false
    }

    /// The row's name: the folder's, or the segments joined with `/`.
    var label: String {
        switch self {
        case .folder(let entry, _): return entry.name
        case .chain(let chain): return chain.label
        }
    }

    /// What a drag of this row moves: the folder, or the chain's head.
    var dragSource: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.dragSource
        }
    }

    /// Where an entry dropped on this row moves into: the folder, or the
    /// chain's tail.
    var dropDestination: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.dropDestination
        }
    }

    /// What Delete removes: the folder, or the chain's head.
    var deleteTarget: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.deleteTarget
        }
    }

    /// Whose diagnostic mark the row's one dot draws: the folder's, or the
    /// chain's head's.
    var diagnosticMarkURL: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.diagnosticMarkURL
        }
    }

    /// Whose git state the row speaks: the folder's, or the chain's head's.
    var spokenGitStateURL: URL {
        switch self {
        case .folder(let entry, _): return entry.url
        case .chain(let chain): return chain.spokenGitStateURL
        }
    }

    /// The Rename item's title: plain for a folder, the chain's own
    /// (`Rename "<tail>"`) for a chain.
    var renameTitle: String {
        switch self {
        case .folder: return "Rename"
        case .chain(let chain): return chain.renameTitle
        }
    }

    /// The Delete item's title: plain for a folder, the chain's own
    /// (`Delete "<label>"`) for a chain.
    var deleteTitle: String {
        switch self {
        case .folder: return "Delete"
        case .chain(let chain): return chain.deleteTitle
        }
    }

    /// The name the delete confirmation quotes: the chain's own, the one its
    /// title quotes; nil for a plain folder, whose confirmation names the
    /// folder's last path component.
    var deleteConfirmationName: String? {
        switch self {
        case .folder: return nil
        case .chain(let chain): return chain.deleteConfirmationName
        }
    }

    /// The entry a rename of this row names: the folder, or the chain's tail.
    var renameEntry: DirectoryEntry {
        switch self {
        case .folder(let entry, _): return entry
        case .chain(let chain): return chain.renameTarget
        }
    }

    /// The names a rename must not collide with when they are not the parent's
    /// listing: a chain's tail sits in its parent segment, not in the listing the
    /// row was drawn from. Nil for a plain folder, whose siblings are that
    /// listing's names.
    var renameSiblings: [String]? {
        switch self {
        case .folder: return nil
        case .chain(let chain): return chain.renameSiblings
        }
    }

    /// Each segment as a reveal request spells it, head first, under the head's
    /// reveal url: that url alone for a folder, the chain's own spelling
    /// (`TreeChain.revealURLs`) for a chain. The last is the tail's.
    func revealURLs(underHead headRevealURL: URL) -> [URL] {
        switch self {
        case .folder: return [headRevealURL]
        case .chain(let chain): return chain.revealURLs(underHeadRevealURL: headRevealURL)
        }
    }
}

/// Holds the project tree's one `TreeListingMemo` for the tree's lifetime. An
/// `ObservableObject` with nothing published, like `TreeDragSession`: listing
/// through the memo must invalidate nothing. The memo is made on the first ask,
/// because its listing function is the model's `children(of:)` and a
/// `@StateObject`'s initial value cannot read the view's `model`.
private final class TreeListingSource: ObservableObject {
    private var memo: TreeListingMemo?

    func memo(listingThrough model: WorkspaceModel) -> TreeListingMemo {
        if let memo { return memo }
        let made = TreeListingMemo { try model.children(of: $0) }
        memo = made
        return made
    }
}

/// The two coordinate spaces the pinned stack measures in: the padded scroll
/// content, which every folder report is framed in and which a scroll never
/// moves, and the scroll view itself, in which the content's top edge is the
/// scroll offset negated.
private enum TreeStickySpace {
    static let content = "tree-sticky-content"
    static let viewport = "tree-sticky-viewport"
}

/// What one expanded folder node reports to the pinned stack: its whole node's
/// frame in `TreeStickySpace.content`, its depth, and what a pinned copy of its
/// row draws and acts on — the shape (name, segments, git and diagnostic
/// urls), the row's scroll id and the node's own expansion binding, which the
/// copy's chevron sets to collapse the very `@State` the real row toggles.
private struct TreeStickyFolderReport: Equatable {
    let frame: CGRect
    let depth: Int
    let isExpanded: Bool
    let shape: TreeNodeShape
    let scrollID: String
    let expansion: Binding<Bool>

    /// The rule's input for this node.
    var folder: TreeStickyRule.Folder {
        TreeStickyRule.Folder(
            depth: depth, isExpanded: isExpanded, top: Double(frame.minY), bottom: Double(frame.maxY)
        )
    }

    /// Everything but the binding, which has no equality of its own and is the
    /// same node's `@State` for as long as the other fields are.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frame == rhs.frame && lhs.depth == rhs.depth && lhs.isExpanded == rhs.isExpanded
            && lhs.shape == rhs.shape && lhs.scrollID == rhs.scrollID
    }
}

/// Every expanded folder node's report, in tree order.
private struct TreeStickyFoldersKey: PreferenceKey {
    static let defaultValue: [TreeStickyFolderReport] = []
    static func reduce(value: inout [TreeStickyFolderReport], nextValue: () -> [TreeStickyFolderReport]) {
        value.append(contentsOf: nextValue())
    }
}

/// The tree's scroll offset — the content offset at the viewport's top edge —
/// published for the pinned stack, its one observer. A scroll frame therefore
/// re-renders the stack alone, never the tree root or any row.
private final class TreeStickyViewport: ObservableObject {
    @Published private(set) var top: Double = 0

    /// Publishes `offset` when it differs from the last one, so a re-reported
    /// unchanged value invalidates nothing.
    func scroll(to offset: Double) {
        if top != offset { top = offset }
    }
}

/// Holds the tree's one `TreeStickyViewport` for the tree's lifetime. An
/// `ObservableObject` with nothing published, like `TreeListingSource`, so the
/// tree root that owns it is never invalidated by the offset it carries.
private final class TreeStickyViewportSource: ObservableObject {
    let viewport = TreeStickyViewport()
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
/// today's 12pt, truncating names in a pane only ~200pt wide. What it does add
/// to `content` is a background: the indent guide (`TreeIndentGuide`), which
/// takes no width.
///
/// The row's *right*-click menu is passed in rather than left on the label, so
/// the three targets a folder row has — the hover highlight, the tap and the
/// context menu — are the same rectangle, as they are on a file row. Left on the
/// label it would have excluded the chevron column and the row's own horizontal
/// padding while the highlight covered them.
private struct FolderDisclosureStyle<Menu: View>: DisclosureGroupStyle {
    /// What a drag of this row moves — the folder, or a chain's head.
    let dragSource: URL
    /// Where an entry dropped on this row moves into — the folder, or a
    /// chain's tail.
    let dropDestination: URL
    /// The project root row, which drops accept but drags never start from.
    let isRoot: Bool
    /// The tree-wide drag state (see `TreeDragSession`).
    let dragSession: TreeDragSession
    let isDrafted: Bool
    /// The folder's git state, spoken after its expansion word.
    let gitState: TreeGitState
    /// The worst diagnostic at or below the folder, spoken after its git word.
    let diagnosticMark: TreeDiagnosticMark
    /// The row's scroll id — its head's `TreeRevealRequest.rowID` — so a click
    /// on its pinned copy scrolls to the *row*, whose height alone the anchor
    /// arithmetic assumes, rather than to the whole node.
    let scrollID: String
    /// Reports an accepted drop; the same callback every row kind receives.
    let onMove: (URL, URL) -> Void
    /// The row's right-click menu items, built by `DirectoryNodeView`.
    @ViewBuilder var menu: () -> Menu

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDisclosureRow(
                configuration: configuration,
                dragSource: dragSource,
                dropDestination: dropDestination,
                isRoot: isRoot,
                dragSession: dragSession,
                isDrafted: isDrafted,
                gitState: gitState,
                diagnosticMark: diagnosticMark,
                onMove: onMove,
                menu: menu
            )
            .id(scrollID)
            if configuration.isExpanded {
                // One stack around the content so the guide is *one* background
                // spanning the whole children block — nested expanded blocks and
                // an open create-draft included — rather than a modifier the
                // content's rows would each receive. A background, so every
                // row's own background paints over it exactly as before.
                VStack(alignment: .leading, spacing: 0) {
                    configuration.content
                }
                .background(alignment: .leading) { TreeIndentGuide() }
            }
        }
    }
}

/// The hairline an expanded folder draws down beside its children block, on
/// the centre of the folder's own chevron column.
///
/// Placed by layout, never by arithmetic on a token: the row's horizontal
/// padding inset, then a frame exactly one chevron column wide with the rule
/// centred in it — the chevron's own two measurements, so the guide stays on
/// the chevron's centre at every interface scale. Nested folders sit one
/// indent step in, so their guides land one step deeper with nothing here
/// knowing about depth. A collapsed folder draws nothing because its content
/// is not rendered at all. Decoration only: no hit target, no highlight, and
/// hidden from accessibility.
private struct TreeIndentGuide: View {
    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.color(.hairline))
            .frame(width: metrics.scaled(ChromeGeometry.hairlineWidth))
            .frame(width: metrics.scaled(TreeRowLayout.chevronWidth))
            .frame(maxHeight: .infinity)
            .padding(.leading, metrics.scaled(ChromeGeometry.rowPaddingX))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The chevron + label row `FolderDisclosureStyle` draws. A separate view (not
/// inline in `makeBody`) because it needs its own `@State` for hover tracking
/// and its own `\.interfaceMetrics` read — and because keeping the hover state
/// off the enclosing view means hovering a folder invalidates the row, not its
/// whole expanded subtree.
private struct FolderDisclosureRow<Menu: View>: View {
    let configuration: DisclosureGroupStyleConfiguration
    /// What a drag of this row moves: the folder, or a chain's head — the row
    /// stands for the head's subtree.
    let dragSource: URL
    /// Where a drop onto this row moves the entry: the folder, or a chain's
    /// tail — the folder whose contents the row shows.
    let dropDestination: URL
    /// The project root row: a drop target, never a drag source. Moving the open
    /// folder itself is not an operation this tree has.
    let isRoot: Bool
    let dragSession: TreeDragSession
    let isDrafted: Bool
    /// The folder's git state — the strongest change below it, or ignored.
    let gitState: TreeGitState
    /// The folder's diagnostic mark — the worst severity below it.
    let diagnosticMark: TreeDiagnosticMark
    let onMove: (URL, URL) -> Void
    @ViewBuilder var menu: () -> Menu

    @State private var isHovering = false
    /// Whether a drag currently hovering this row would be accepted. Row-local
    /// `@State`, like `isHovering`: the drag session publishes nothing, so this
    /// is the only thing a drag invalidates — one row, not the subtree under it.
    @State private var isDropTarget = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme
    /// Whether this row's window is the key one — the app layer's whole
    /// definition of "focused" for a tree row. `.key` is focused, every other
    /// value is not.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TreeFolderRowLayout(isExpanded: configuration.isExpanded, isDrafted: isDrafted) {
            configuration.label
        }
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
        .projectTreeDragSource(isEnabled: !isRoot && !isDrafted, url: dragSource, session: dragSession)
        // Plain assignment, deliberately not `withAnimation`: animating the
        // insertion of a deep nested subtree is a regression this change does
        // not need.
        .onTapGesture { if !isDrafted { configuration.isExpanded.toggle() } }
        .onHover { isHovering = $0 }
        // Not `.contextMenu { if !isDrafted { menu() } }`: that installs the
        // modifier either way, so right-clicking the drafted row opens an empty
        // panel and flashes it shut. The helper omits the modifier instead.
        .projectTreeContextMenu(isEnabled: !isDrafted, menuItems: menu)
        // Every folder row is a drop target, the root included: that is how an
        // entry is moved back to the top of the project.
        .onDrop(
            of: isDrafted ? [] : [ProjectTreeDrag.contentType],
            delegate: TreeDropDelegate(
                folder: dropDestination,
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
        // The expansion word, then the git state's and the diagnostics' words
        // when there are any — Core's composition, so the two row kinds speak
        // the state alike.
        .accessibilityValue(
            isDrafted
                ? ""
                : TreeGitState.accessibilityValue(
                    state: gitState, mark: diagnosticMark, row: .folder(isExpanded: configuration.isExpanded)
                )
        )
        .accessibilityAction { if !isDrafted { configuration.isExpanded.toggle() } }
    }

    /// The row's background, asked of `TreeRowState` and painted through
    /// `TreeRowBackground.color(for:resolving:)` — the same two lines a file row
    /// runs, so the two row kinds cannot answer the question differently.
    ///
    /// A folder row passes `isSelected: false` unconditionally: selection here is
    /// *derived* from the active editor tab, and a folder is never one.
    private var rowBackground: Color {
        let state = TreeRowState.state(
            isSelected: false,
            isWindowKey: controlActiveState == .key,
            isHovering: isHovering,
            isDropTarget: isDropTarget
        )
        return TreeRowBackground.color(for: state, resolving: theme.color)
    }
}

/// A folder row's layout — the chevron column, the label after it, the row's
/// padding and its fixed frame — shared by `FolderDisclosureRow` and the pinned
/// copy, so a copy draws exactly as the real row does by construction. The
/// background, the gestures and the accessibility element stay with each
/// caller.
private struct TreeFolderRowLayout<Label: View>: View {
    let isExpanded: Bool
    /// Whether the row hosts a rename draft, which lifts the height ceiling.
    let isDrafted: Bool
    @ViewBuilder let label: () -> Label

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.scaled(TreeRowLayout.chevronSpacing)) {
            // Two glyphs rather than one rotated: the design draws `chevron-down`
            // for an open folder and `chevron-right` for a closed one. The slot
            // is the chevron column itself, so sibling labels line up whatever
            // the glyph's own shape. Hidden from accessibility by the helper: the
            // real row combines its children into one element, and the state
            // the chevron draws is carried, properly, by `accessibilityValue`.
            DesignGlyphImage(
                isExpanded ? .chevronDown : .chevronRight,
                size: TreeRowLayout.chevronWidth, slot: TreeRowLayout.chevronWidth, role: .textSecondary
            )
            label()
        }
        // Exactly `FileRowView`'s treatment — the same `ChromeGeometry` tokens,
        // not a second copy of them — so a folder row and a file row read and
        // highlight alike. The row is a *fixed* `rowHeight` tall rather than
        // padded to its content's height: every chrome list measures its rows
        // with the one token, so a tree row and a tab row cannot drift apart as
        // one of them gains a taller glyph. The label brings its own
        // `maxWidth: .infinity` frame, but the row repeats it: the highlight must
        // cover the chevron column too, edge to edge.
        //
        // The ceiling is lifted while the row hosts a **rename draft**: the draft
        // is a `VStack` that grows a wrapped validation-reason line under the
        // field, so a row capped at `rowHeight` would clip the reason it exists
        // to show. `minHeight` stays either way, so an undrafted row and a
        // drafted one with nothing to report are the same height.
        .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.scaled(ChromeGeometry.rowHeight),
            maxHeight: isDrafted ? nil : metrics.scaled(ChromeGeometry.rowHeight),
            alignment: .leading
        )
    }
}

/// A folder row's label — the folder glyph, its diagnostic dot and the name —
/// shared by the real row and the pinned copy. `name` is `TreeFolderName`, or
/// the rename field the real row puts in its place.
private struct TreeFolderLabel<Name: View>: View {
    let isExpanded: Bool
    let diagnosticMark: TreeDiagnosticMark
    @ViewBuilder let name: () -> Name

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(4)) {
            // The open folder while the row is expanded, the closed one
            // otherwise — `FileGlyph`'s answer, in `textSecondary` like every
            // glyph in the tree. The helper hides it from accessibility: this
            // label sits *inside* the row's combined accessibility element,
            // and directory-ness is already carried by the row's button trait
            // and its expanded/collapsed `accessibilityValue`. One dot, the
            // head's, for a chain as for a plain folder.
            DesignGlyphImage(
                FileGlyph.forFolder(expanded: isExpanded),
                size: TreeRowLayout.iconSize, slot: TreeRowLayout.iconSize, role: .textSecondary
            )
            .treeDiagnosticDot(
                diagnosticMark, diameter: metrics.scaled(TreeRowLayout.diagnosticDotSize), resolving: theme.color
            )
            name()
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
}

/// A folder row's name: a plain folder's in the head's git colour, a chain's
/// segments as one text (`segmentsText`), each name in its own segment's
/// colour. The glyph beside it stays `textSecondary` either way.
private struct TreeFolderName: View {
    let shape: TreeNodeShape
    /// The head's git state, asked once by the caller.
    let gitState: TreeGitState
    /// The tree's git lookup, asked per segment for a chain.
    let gitStatus: TreeGitStatus

    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        if let chain = shape.chain {
            Self.segmentsText(
                chain.segments, under: chain, trailingSeparator: false, gitStatus: gitStatus, resolving: theme.color
            )
        } else {
            Text(shape.label)
                .treeNameForeground(ChromeColorRole.treeNameRole(for: gitState), resolving: theme.color)
        }
    }

    /// `segments` of `chain` as **one** text — concatenated runs, so a long
    /// label truncates in the middle as a whole rather than per segment. Each
    /// name takes the role its own segment's git state answers (the chain's
    /// per-segment git urls), or the inherited foreground when there is none;
    /// each `/` is drawn in `textSecondary`. The theme arrives as `resolving`,
    /// for `TreeRowBackground`'s reason.
    static func segmentsText(
        _ segments: [DirectoryEntry],
        under chain: TreeChain,
        trailingSeparator: Bool,
        gitStatus: TreeGitStatus,
        resolving: (ChromeColorRole) -> Color
    ) -> Text {
        let separator = Text(verbatim: "/").foregroundStyle(resolving(.textSecondary))
        var runs: [Text] = []
        // Read once: the chain computes the array on every ask.
        let gitStatusURLs = chain.gitStatusURLs
        // `segments` is always a prefix of the chain's own — all of them, or
        // the leading ones — so each index names its segment's git url.
        for (index, segment) in segments.enumerated() {
            if index > 0 { runs.append(separator) }
            let name = Text(verbatim: segment.name)
            let state = gitStatus.state(for: gitStatusURLs[index])
            if let role = ChromeColorRole.treeNameRole(for: state) {
                runs.append(name.foregroundStyle(resolving(role)))
            } else {
                runs.append(name)
            }
        }
        if trailingSeparator { runs.append(separator) }
        return runs.reduce(Text(verbatim: ""), +)
    }
}

/// The one mapping from a `TreeRowState` to the colour its background is painted
/// in.
///
/// Both row kinds read it, for the reason they share `ChromeGeometry`'s tokens:
/// restated at each row kind, a change to one would silently leave the other
/// painting the old answer.
enum TreeRowBackground {
    /// The role a state paints itself in — every state answers with a role or
    /// with nothing.
    ///
    /// `nil` has one reason only: `.plain` is the *absence* of a background
    /// rather than a colour of its own, so a row in no state paints nothing.
    /// `.dropTarget` answers `dropTargetTint`, whose strength — heavier than
    /// the selection wash, so a drop over a selected row still reads — is the
    /// palette's, not composed here.
    static func role(for state: TreeRowState) -> ChromeColorRole? {
        switch state {
        case .plain: return nil
        case .hover: return .hoverTint
        case .selectedFocused: return .accentTintStrong
        case .selectedUnfocused: return .selectionInactive
        case .dropTarget: return .dropTargetTint
        }
    }

    /// The colour a row actually paints: the state's role where it has one, and
    /// `.clear` for `.plain`. Nothing is composed on top — every wash's alpha is
    /// the palette's. Both row kinds call this one method, which is what keeps
    /// the two treatments from drifting apart.
    ///
    /// The theme arrives as `resolving`, a role-to-colour function the row hands
    /// over, rather than as the theme value itself: a view file that named the
    /// theme's *type* would join the set the gating suite keeps to the plumbing
    /// (`core-theme.md`, rule five), and this mapping has no business holding a
    /// theme — it is asked one question per state.
    static func color(
        for state: TreeRowState,
        resolving: (ChromeColorRole) -> Color
    ) -> Color {
        guard let role = role(for: state) else { return Color.clear }
        return resolving(role)
    }
}

/// The chevron geometry a tree row is drawn with — the part of a row's
/// measurements that is the *tree's own*, not the chrome's.
///
/// Everything else a row measures itself with now comes from `ChromeGeometry`:
/// a row's height is `ChromeGeometry.rowHeight`, its horizontal padding
/// `ChromeGeometry.rowPaddingX`, and one level of nesting insets a child by
/// `ChromeGeometry.treeIndentStep`. What stays here is the chevron column's
/// width, its gap and the gutter rule derived from the two — a rule about how a
/// disclosure row and a leaf row line up, which no other chrome surface has and
/// which is deliberately *not* what this part is changing.
///
/// Each value is scaled through `\.interfaceMetrics` at its use site, like
/// every other size in the tree.
///
/// Internal rather than `private` because the draft field in
/// `ProjectTreeDraftField.swift` is a second reader, and it is one by necessity
/// — an inline draft occupies the row it stands in, so it must be gutter-inset
/// with these very numbers or the tree would visibly shift as a draft opens and
/// closes. Both readers are project-tree view files; the type is not part of any
/// wider view vocabulary.
enum TreeRowLayout {
    /// The folder row's fixed chevron column width — also the chevron glyph's
    /// drawn size, the design's 12.
    static let chevronWidth: Double = 12
    /// The file or folder glyph's drawn size and square slot, the design's 14:
    /// one value for both row kinds and the inline draft, so a file's glyph and
    /// a sibling folder's are the same width and their names line up.
    static let iconSize: Double = 14
    /// The folder row's gap between the chevron column and the label.
    static let chevronSpacing: Double = 4
    /// The diameter of the severity dot a row's glyph carries in its
    /// bottom-trailing corner when an error or a warning lies at or below the
    /// row — under half the glyph's slot, so the glyph still reads.
    static let diagnosticDotSize: Double = 6

    /// The empty chevron gutter a *file* row leads with — the folder row's
    /// chevron column plus its spacing, so a file's icon and a sibling folder's
    /// icon land on the same vertical line.
    ///
    /// Load-bearing, not cosmetic. A child row is inset by
    /// `metrics.scaled(ChromeGeometry.treeIndentStep)`, which is *less* than the
    /// gutter: without it a
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

/// One file row in the tree: a clickable label that opens the file. The glyph
/// is resolved from the file's name via `FileGlyph`.
private struct FileRowView: View {
    let entry: DirectoryEntry
    let onOpen: () -> Void
    let onBeginRename: () -> Void
    let onRename: (String) -> Void
    let onRenameCancel: () -> Void
    let onDelete: () -> Void
    let onRun: () -> Void
    let onRunTest: () -> Void
    /// Show this file's Local History — the second of the feature's two open
    /// sites, and the same `PisakaApp` handler ⌘⇧H reaches, so the single window
    /// has one owner.
    let onShowLocalHistory: () -> Void
    /// The tree-wide drag state (see `TreeDragSession`). A file row is a drag
    /// *source* only — a file is never a drop destination, so it installs no drop
    /// delegate and never highlights as one.
    let dragSession: TreeDragSession
    let draft: TreeEditDraft?
    let siblings: [String]
    /// Whether this row is the active editor tab's file. *Derived*, never
    /// clicked: the tree introduces no selection gesture of its own, so the one
    /// row drawn as selected is the one the editor is showing.
    let isSelected: Bool
    /// This file's git state, asked of the tree's lookup once by the folder
    /// listing it. A selected row keeps it: the background is a separate answer.
    let gitState: TreeGitState
    /// This file's diagnostic mark, asked of the tree's lookup once by the
    /// folder listing it, like `gitState`.
    let diagnosticMark: TreeDiagnosticMark

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme
    /// Whether this row's window is the key one — see `FolderDisclosureRow`.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: metrics.scaled(4)) {
            // Monochrome, like every other icon in the chrome: `FileGlyph`
            // answers database, text or code, drawn in `textSecondary`. A column
            // of tinted glyphs competes with the row highlight, which is the one
            // thing a tree row has to say.
            DesignGlyphImage(
                FileGlyph.forFile(named: entry.name),
                size: TreeRowLayout.iconSize, slot: TreeRowLayout.iconSize, role: .textSecondary
            )
            .treeDiagnosticDot(
                diagnosticMark, diameter: metrics.scaled(TreeRowLayout.diagnosticDotSize), resolving: theme.color
            )
            if case .rename(let draftedEntry) = draft, draftedEntry.url == entry.url {
                TreeNameFieldView(
                    // The bound entry, not the optional re-read, exactly as the
                    // folder row does it.
                    draft: .rename(entry: draftedEntry),
                    siblings: siblings,
                    onCommit: onRename,
                    onCancel: onRenameCancel
                )
            } else {
                Text(entry.name)
                    .treeNameForeground(ChromeColorRole.treeNameRole(for: gitState), resolving: theme.color)
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
        // Shared with `FolderDisclosureRow` through `ChromeGeometry`, which is
        // what keeps the two row kinds' treatment identical — including the
        // lifted ceiling while this row hosts a rename draft, whose wrapped
        // validation-reason line a fixed `rowHeight` would clip.
        .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.scaled(ChromeGeometry.rowHeight),
            maxHeight: isDraftedRow ? nil : metrics.scaled(ChromeGeometry.rowHeight),
            alignment: .leading
        )
        .background(rowBackground)
        .contentShape(Rectangle())
        // As on a folder row: added ahead of the untouched tap/hover/menu block,
        // through the same one drag-source helper.
        .projectTreeDragSource(isEnabled: !isDraftedRow, url: entry.url, session: dragSession)
        .onTapGesture { if !isDraftedRow { onOpen() } }
        .onHover { isHovering = $0 }
        // Through the same helper the folder row uses, for the same reason: a
        // drafted row must have no menu at all, not an empty one.
        .projectTreeContextMenu(isEnabled: !isDraftedRow) {
            // Grouped by `Section`s rather than separated by `Divider()`s: a menu
            // renders the same separators between sections, and the dock's swept
            // surfaces spell no `Divider()` at all — see the folder menu above and
            // `LocalChangesView.swift` for the same idiom.
            if RunCommand.canRun(fileName: entry.name)
                || TestCommand.isTestFile(fileName: entry.name) {
                Section {
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
                }
            }
            Section {
                Button("Rename") { onBeginRename() }
                Button("Delete") { onDelete() }
            }
            Section {
                Button("Local History") { onShowLocalHistory() }
            }
        }
        // One element carrying the git state's and the diagnostics' words as its
        // value, as a folder row carries its expansion; a plain, clean file says
        // nothing more than its name. `.contain` while a rename draft is open, as
        // on a folder row, so the field stays reachable as itself.
        .accessibilityElement(children: isDraftedRow ? .contain : .combine)
        .accessibilityValue(
            isDraftedRow ? "" : TreeGitState.accessibilityValue(state: gitState, mark: diagnosticMark, row: .file)
        )
    }

    private var isDraftedRow: Bool {
        if case .rename(let draftedEntry) = draft, draftedEntry.url == entry.url {
            return true
        }
        return false
    }

    /// The row's background, through the same rule and the same mapping a folder
    /// row asks. A file row is never a drop target — a file is not a
    /// destination — so that input is constantly `false`.
    private var rowBackground: Color {
        let state = TreeRowState.state(
            isSelected: isSelected,
            isWindowKey: controlActiveState == .key,
            isHovering: isHovering,
            isDropTarget: false
        )
        return TreeRowBackground.color(for: state, resolving: theme.color)
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
    /// Puts the row's severity dot on its glyph: a circle `diameter` across in
    /// the glyph's bottom-trailing corner, filled with the severity's one role
    /// (`ChromeColorRole.diagnosticRole(for:)`) — or an empty overlay for a
    /// row with no error or warning at or below it, which then draws exactly
    /// as before.
    ///
    /// The severity is the mark's, handed straight to Core's mapping, so the
    /// tree switches over no severity itself. An overlay, so the glyph's slot,
    /// and with it every name's alignment, is untouched — and always installed,
    /// so a mark appearing or clearing changes what it draws, never the glyph's
    /// identity. Hidden from accessibility, because the row's value already
    /// speaks the mark. The theme arrives as `resolving`, for
    /// `TreeRowBackground`'s reason.
    func treeDiagnosticDot(
        _ mark: TreeDiagnosticMark,
        diameter: Double,
        resolving: (ChromeColorRole) -> Color
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let severity = mark.severity {
                Circle()
                    .fill(resolving(ChromeColorRole.diagnosticRole(for: severity)))
                    .frame(width: diameter, height: diameter)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Draws a row's name in `role` — or leaves its foreground exactly as
    /// inherited when there is none, which is what a plain row wants: outside a
    /// repository the tree stays pixel-identical to the tree before git state.
    ///
    /// The theme arrives as `resolving`, for `TreeRowBackground`'s reason.
    @ViewBuilder
    func treeNameForeground(
        _ role: ChromeColorRole?,
        resolving: (ChromeColorRole) -> Color
    ) -> some View {
        if let role {
            foregroundStyle(resolving(role))
        } else {
            self
        }
    }

    /// Gives this row the right-click menu `menuItems` builds — or leaves the
    /// row exactly as it is, which is what a *drafted* row wants.
    ///
    /// Deliberately a `@ViewBuilder` branch rather than an empty menu body:
    /// `.contextMenu` installed with nothing in it still opens on a right-click,
    /// so the drafted row answered with an empty panel that flashed shut.
    /// Omitting the modifier leaves AppKit no menu to open at all — the click
    /// then only cancels the draft (`TreeDraftDismissRegion`), which is the whole
    /// intent.
    ///
    /// The branch changes the row's view identity, and that costs nothing here:
    /// the flag flips at most twice per draft (opened, then committed or
    /// cancelled), and the row is being rebuilt at both those moments anyway —
    /// the same bound `projectTreeDragSource(isEnabled:url:session:)`'s flag
    /// carries, since both are driven by the row's drafted-ness.
    @ViewBuilder
    func projectTreeContextMenu<MenuItems: View>(
        isEnabled: Bool,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        if isEnabled {
            contextMenu(menuItems: menuItems)
        } else {
            self
        }
    }

    /// Makes this row the source of a project-tree drag for `url` — or leaves it
    /// exactly as it is, which is how the project root row opts out.
    ///
    /// The opt-out is a `@ViewBuilder` branch rather than an `.onDrag` returning
    /// an empty item provider: a provider with nothing registered still begins a
    /// drag AppKit renders and no target can ever accept. `isEnabled` flips only
    /// with the row's drafted-ness — at most twice per draft, when the row is
    /// being rebuilt anyway — so the branch's identity churn is bounded, the same
    /// argument `projectTreeContextMenu(isEnabled:menuItems:)` records.
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

/// The pinned stack: a copy of every expanded ancestor's row whose real row
/// has scrolled above the viewport, as `TreeStickyRule` answers it. Drawn over
/// the scroll view's top edge, so directly under the header.
///
/// The one observer of `TreeStickyViewport`: a scroll frame re-renders this
/// view alone. Its frame is **exactly the stack's height** and clipped, so a
/// row being pushed out never draws over the header and everything below the
/// stack keeps receiving clicks, drags and menus. Rows are drawn outermost on
/// top, so a deeper row whose subtree ends slides up under its parent. A
/// navigation aid only: no drag, no drop, no menu, no draft, and hidden from
/// accessibility — the real rows carry everything a reader needs.
private struct TreeStickyStackView: View {
    /// Every expanded folder node's report, in tree order.
    let reports: [TreeStickyFolderReport]
    @ObservedObject var viewport: TreeStickyViewport
    let viewportHeight: Double
    /// The tree's lookups, read as the real rows read them.
    let gitStatus: TreeGitStatus
    let diagnostics: TreeDiagnostics

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let stack = TreeStickyRule.stack(
            folders: reports.map(\.folder),
            viewport: TreeStickyRule.Viewport(top: viewport.top, height: viewportHeight),
            rowHeight: Double(metrics.scaled(ChromeGeometry.rowHeight))
        )
        let pinned = stack.rows.enumerated().map { level, row in
            TreeStickyPinnedRow(level: level, row: row, report: reports[row.index])
        }
        ZStack(alignment: .top) {
            ForEach(pinned) { pinnedRow in
                TreeStickyRowView(report: pinnedRow.report, gitStatus: gitStatus, diagnostics: diagnostics)
                    .offset(y: pinnedRow.row.top)
                    // Outermost on top.
                    .zIndex(Double(pinned.count - pinnedRow.level))
            }
        }
        .frame(maxWidth: .infinity, minHeight: stack.height, maxHeight: stack.height, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if !pinned.isEmpty {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One row of the stack: its level, the rule's answer and the report it was
/// drawn from, identified by the folder's scroll id so a copy keeps its hover
/// state while the stack above it changes.
private struct TreeStickyPinnedRow: Identifiable {
    let level: Int
    let row: TreeStickyRule.Stack.Row
    let report: TreeStickyFolderReport

    var id: String { report.scrollID }
}

/// A pinned copy of an expanded folder's row, drawn exactly as the real row
/// draws — the same `TreeFolderRowLayout`, `TreeFolderLabel` and
/// `TreeFolderName`, asked of the same lookups with the same urls.
///
/// The indent is built by layout: one `treeIndentStep`-wide spacer per depth
/// level, each carrying `TreeIndentGuide` as its leading background, so every
/// enclosing folder's guide runs through the copy as it runs through the real
/// row. Back to front: the `bgPanel` ground across the full width, the guides,
/// then the row over its own hover background. The copy always draws the
/// expanded chevron, because only expanded folders pin. A tap on the chevron
/// slot collapses the folder through its node's own expansion binding — the
/// very `@State` the real row toggles, so its collapse handler drops any draft
/// below.
private struct TreeStickyRowView: View {
    let report: TreeStickyFolderReport
    let gitStatus: TreeGitStatus
    let diagnostics: TreeDiagnostics

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme
    /// Whether this row's window is the key one, as the real row reads it.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let shape = report.shape
        HStack(spacing: 0) {
            ForEach(0..<report.depth, id: \.self) { _ in
                Color.clear
                    .frame(width: metrics.scaled(ChromeGeometry.treeIndentStep))
                    .background(alignment: .leading) { TreeIndentGuide() }
            }
            TreeFolderRowLayout(isExpanded: true, isDrafted: false) {
                TreeFolderLabel(isExpanded: true, diagnosticMark: diagnostics.mark(for: shape.diagnosticMarkURL)) {
                    TreeFolderName(
                        shape: shape, gitState: gitStatus.state(for: shape.spokenGitStateURL), gitStatus: gitStatus
                    )
                }
            }
            .background(rowBackground)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .overlay(alignment: .leading) {
                // The chevron slot: the row's leading padding, the chevron
                // column and its gap, each scaled as the row lays them out.
                Color.clear
                    .frame(
                        width: metrics.scaled(ChromeGeometry.rowPaddingX) + TreeRowLayout.chevronGutter(metrics)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { report.expansion.wrappedValue = false }
            }
        }
        .frame(height: metrics.scaled(ChromeGeometry.rowHeight))
        .background(theme.color(.bgPanel))
    }

    /// The copy's background, through the one mapping both real row kinds
    /// use. Never selected — a folder is never the active tab — and never a
    /// drop target, because the copy accepts no drop.
    private var rowBackground: Color {
        let state = TreeRowState.state(
            isSelected: false,
            isWindowKey: controlActiveState == .key,
            isHovering: isHovering,
            isDropTarget: false
        )
        return TreeRowBackground.color(for: state, resolving: theme.color)
    }
}

#endif
