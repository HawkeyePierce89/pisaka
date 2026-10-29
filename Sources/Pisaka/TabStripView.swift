#if os(macOS)
import SwiftUI
import PisakaCore

/// The horizontal tab strip above the editor: the whole strip's chrome, owned
/// here rather than by its host.
///
/// Split out of `TabListView` rather than left as a branch inside it: the strip
/// is not a list of rows that happens to run sideways. It has chrome of its own
/// — a height, a background, a bottom rule the editor below it sits under — that
/// a row view cannot state, and the column's own chrome differs in every one of
/// those three. What the two genuinely share is the trailing slot's precedence,
/// and that is shared as one view (`TabStatusMark` below) rather than as one
/// branching view.
///
/// Which is why the host adds neither a `.frame(height:)` nor a `Divider()`: the
/// strip states its own height (`ChromeGeometry.tabStripHeight`) and draws its
/// own hairline, so the two cannot disagree.
struct TabStripView: View {
    @ObservedObject var model: WorkspaceModel
    var actions = TabActions()

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.openFiles) { file in
                    TabStripCell(
                        file: file,
                        isActive: file.id == model.selectedID,
                        isInConflict: model.isInExternalConflict(file.id),
                        onSelect: { model.select(file.id) },
                        onClose: { actions.close($0, file.id) }
                    )
                    .tabGestures(file: file, files: model.openFiles, actions: actions)
                }
            }
        }
        .frame(height: metrics.scaled(ChromeGeometry.tabStripHeight))
        // The rule between the strip and the editor, drawn *behind* the tabs on
        // the strip's own bottom edge so an active tab — filled in the editor's
        // own background, to read as part of it — sits above it and merges into
        // the editor below, its accent underline interrupting the rule for the
        // tab's width. An overlay here would cover the tab's fill and the lower
        // half of its underline (gating rule sixteen). Layered ground furthest
        // back, then the rule, then the tabs.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        // The strip is the topmost view of the editor column under the
        // transparent title bar, which is the window's top safe-area inset, and
        // this ground deliberately extends into it: the `ContentView` root's
        // ground is `bgCanvas` and would otherwise show there, two-toning the
        // title bar against the sidebar's `bgPanel` (seen on 2026-10-04 with
        // this ground confined). The sidebar and the vertical tab column paint
        // the title bar the same way. The active cell's fill is the one that
        // must not climb (see there; gating rule forty-seven pins both).
        .background(theme.color(.bgPanel))
    }
}

/// One tab in the horizontal strip.
///
/// The active tab is filled in `bgEditor` and carries an `accent` underline as
/// tall as `ChromeGeometry.accentIndicator`, so it reads as the top edge of the
/// editor rather than as a highlighted row. Its label is `textPrimary`; every
/// other tab's is `textSecondary`.
private struct TabStripCell: View {
    let file: OpenFile
    let isActive: Bool
    let isInConflict: Bool
    let onSelect: () -> Void
    let onClose: (TabCloseCommand) -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(6)) {
            TabFileIcon(file: file)

            Text(file.displayName)
                .font(metrics.scaledFont(.callout))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.color(isActive ? .textPrimary : .textSecondary))

            TabStatusMark(
                isHovering: isHovering,
                isDirty: file.isDirty,
                isInConflict: isInConflict,
                isActive: isActive,
                onClose: onClose
            )
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
        .frame(maxHeight: .infinity)
        // Confined to the cell's frame: a default background would climb
        // through the transparent title bar to the window's top edge, while the
        // strip's ground behind it is meant to (see there; gating rule
        // forty-seven).
        .background(isActive ? theme.color(.bgEditor) : Color.clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(theme.color(.accent))
                    .frame(height: metrics.scaled(ChromeGeometry.accentIndicator))
            }
        }
        // The rule between two tabs, drawn on each tab's trailing edge.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(width: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

/// The one slot both tab orientations draw at the trailing edge of a tab, with
/// four claimants, in this order: the close mark while the pointer is in the
/// tab, then the external-change mark, then the unsaved-changes dot, then the
/// close mark on the active tab.
///
/// The dot therefore **outranks** the mark on an active tab — unsaved work is a
/// fact about the file that nothing else states, while the mark is reachable by
/// pointing at the tab — and the mark still shows on the active tab whenever
/// there is nothing to report, so the tab most likely to be closed does not have
/// to be hunted for.
///
/// The external-change mark — `fileWarning` in `statusYellow`, a shape and a
/// colour the dot never takes — outranks the dot: a tab in conflict is usually
/// dirty too, and the dot alone would claim autosave is going to write it,
/// which it will not (`WorkspaceModel.isInExternalConflict`). A clean tab that
/// is stale against the disk carries it as well, because the conflict rule is
/// derived from the texts and not from the dirty flag.
///
/// It is one view rather than one rule restated in each orientation: the strip
/// and the column show the same three facts about the same file, and two
/// spellings of that precedence would drift the moment either is touched. It
/// lives here, beside the strip that first stated the rule.
///
/// The mark closes its own tab; with ⌥ held it closes every *other* tab
/// instead (Close Others), the command answering through the same funnel.
struct TabStatusMark: View {
    let isHovering: Bool
    let isDirty: Bool
    let isInConflict: Bool
    let isActive: Bool
    let onClose: (TabCloseCommand) -> Void

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ZStack {
            if isHovering {
                closeMark
            } else if isInConflict {
                DesignGlyphImage(.fileWarning, size: 12, slot: 12, role: .statusYellow)
                    .help("Changed on disk")
                    .accessibilityLabel("Changed on disk")
            } else if isDirty {
                Circle()
                    .fill(theme.color(.textSecondary))
                    .frame(width: metrics.scaled(7), height: metrics.scaled(7))
                    .help("Unsaved changes")
            } else if isActive {
                closeMark
            }
        }
        .frame(width: metrics.scaled(14), height: metrics.scaled(14))
    }

    /// The close mark, drawn in either of the two slots that claim it.
    private var closeMark: some View {
        Button {
            onClose(NSEvent.modifierFlags.contains(.option) ? .closeOthers : .close)
        } label: {
            DesignGlyphImage(.x, size: 12, slot: 12, role: .textSecondary)
        }
        .buttonStyle(.plain)
        .help("Close")
        // The glyph is hidden from accessibility by the helper, so the button
        // states its own name rather than reading out as an unnamed control.
        .accessibilityLabel("Close")
    }
}

/// The file-type icon both tab orientations draw at the leading edge of a tab.
///
/// It answers one rule, and answers it once: an `OpenFile` that has never been
/// written has no url, and is asked about under its `displayName`, so the icon
/// for a name nothing recognises is `FileTypeIcon`'s own plain-document answer
/// rather than a second guess spelled at the call site.
///
/// It is drawn at the design's 13 points in the vendored icon's own colours,
/// through `FileTypeIconImage`: a file-type icon's colour is its identity, the
/// one icon in the strip no role tints (`core-theme.md`).
///
/// One view rather than one rule restated in each orientation, for
/// `TabStatusMark`'s own reason: the two show the same fact about the same file,
/// and two spellings of it drift the moment either is touched.
struct TabFileIcon: View {
    let file: OpenFile

    var body: some View {
        FileTypeIconImage(
            FileTypeIcon.forFile(named: file.url?.lastPathComponent ?? file.displayName),
            side: 13
        )
    }
}

/// What a tab's gestures and context menu can ask of the app, handed to both
/// orientations by their host.
///
/// Every close — the mark, ⌥-click, the middle click and the menu's five items —
/// arrives as one `close(command, anchor)` the app routes through its one close
/// funnel (`TabCloseRule`), so a batch stops at the first Cancel. The pasteboard
/// and Finder actions need nothing the app holds and are stated here as defaults;
/// the tree reveal and Local History are the app's.
struct TabActions {
    /// The open project root, against which the relative path, the tooltip and
    /// the menu's availability are judged.
    var projectRoot: URL?
    var close: (TabCloseCommand, UUID) -> Void = { _, _ in }
    /// Reveal in Project Tree for the tab with this id and url: the app selects
    /// that tab and expands the tree down to its row.
    var revealInProjectTree: (UUID, URL) -> Void = { _, _ in }
    var showLocalHistory: (URL) -> Void = { _ in }
    /// Copy Path and Copy Relative Path: the string goes to the general pasteboard.
    var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
}

extension View {
    /// The gestures both orientations attach to a tab, in one place so the strip
    /// and the column cannot drift: the middle click that closes it, the path
    /// tooltip, and the context menu.
    func tabGestures(file: OpenFile, files: [OpenFile], actions: TabActions) -> some View {
        overlay(TabMiddleClickCatcher { actions.close(.close, file.id) })
            .help(DisplayPath.tooltip(fileURL: file.url, projectRoot: actions.projectRoot))
            .tabContextMenu(file: file, files: files, actions: actions)
    }

    /// A tab's context menu, answering right click and ⌃-click alike: the close
    /// commands, the path commands, then Local History. Every item is disabled
    /// from `TabCloseRule.MenuAvailability`, never hidden, and every action
    /// takes the tab the menu was opened on, not the active one.
    func tabContextMenu(file: OpenFile, files: [OpenFile], actions: TabActions) -> some View {
        contextMenu {
            let available = TabCloseRule.MenuAvailability(
                files: files, anchor: file.id, projectRoot: actions.projectRoot
            )
            let relative = DisplayPath.relativePath(fileURL: file.url, projectRoot: actions.projectRoot)
            // Grouped by `Section`s rather than separated by `Divider()`s, as
            // every gated menu is: the menu draws its own separators.
            Section {
                ForEach(TabCloseCommand.allCases, id: \.self) { command in
                    Button(command.menuTitle) { actions.close(command, file.id) }
                        .disabled(!available.isEnabled(command))
                }
            }
            Section {
                Button("Copy Path") { if let url = file.url { actions.copyToPasteboard(url.path) } }
                    .disabled(!available.copyPath)
                Button("Copy Relative Path") { if let relative { actions.copyToPasteboard(relative) } }
                    .disabled(!available.copyRelativePath)
                Button("Reveal in Finder") { if let url = file.url { actions.revealInFinder(url) } }
                    .disabled(!available.copyPath)
                Button("Reveal in Project Tree") { if let url = file.url { actions.revealInProjectTree(file.id, url) } }
                    .disabled(!available.copyRelativePath)
            }
            Section {
                Button("Local History") { if let url = file.url { actions.showLocalHistory(url) } }
                    .disabled(!available.localHistory)
            }
        }
    }
}

private extension TabCloseCommand {
    /// The command's item title in the tab menu.
    var menuTitle: String {
        switch self {
        case .close: return "Close"
        case .closeOthers: return "Close Others"
        case .closeToTheRight: return "Close Tabs to the Right"
        case .closeAll: return "Close All"
        case .closeSaved: return "Close Saved"
        }
    }
}

/// Closes a tab on a middle click, laid over each tab in both orientations.
///
/// SwiftUI offers no other-button gesture, so this is the one AppKit view in the
/// tab's stack. It claims a hit only while the event being dispatched is a
/// center-button one, so every other event — left and right clicks, hover and
/// tooltip tracking — falls through to the SwiftUI tab beneath it and selection,
/// the close mark and the context menu are untouched. It draws nothing.
struct TabMiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> TabMiddleClickView {
        let view = TabMiddleClickView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: TabMiddleClickView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }
}

/// `TabMiddleClickCatcher`'s view.
final class TabMiddleClickView: NSView {
    /// The event being dispatched, read by `hitTest`. Injectable so a test can
    /// hand it a synthesized event; AppKit's own answer otherwise.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    var onMiddleClick: () -> Void = {}

    private static let otherMouseTypes: Set<NSEvent.EventType> = [
        .otherMouseDown, .otherMouseDragged, .otherMouseUp
    ]

    /// Whether an event of `type` from button `buttonNumber` is the catcher's:
    /// the three other-mouse types, from the center button.
    static func claims(type: NSEvent.EventType, buttonNumber: Int) -> Bool {
        otherMouseTypes.contains(type) && buttonNumber == 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `buttonNumber` is only defined on mouse events — reading it off a key
        // event raises — so the type is asked first.
        guard let event = currentEvent(), Self.otherMouseTypes.contains(event.type),
              Self.claims(type: event.type, buttonNumber: event.buttonNumber) else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
    }

    /// The tab closes on the release, and only when it lands inside the tab, as
    /// a button would; it is never selected first.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onMiddleClick() }
    }
}

#endif
