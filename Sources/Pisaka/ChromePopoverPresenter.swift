#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// One row of a remote row's submenu: a title and what activating it does.
struct ChromePopoverSubmenuRow: Identifiable {
    let id: String
    let title: String
    let activate: () -> Void
}

/// One row the open popover registers, in display order. An action row
/// ("New Branch…", "Open Folder…") is an ordinary entry; a row that opens a
/// submenu carries that submenu's rows instead of acting itself.
struct ChromePopoverRowAction: Identifiable {
    let id: String
    let activate: () -> Void
    var submenu: [ChromePopoverSubmenuRow]?
}

/// What the host hands the open content each time it draws it: the height the
/// placement leaves the container, which row the keyboard has selected, and
/// the one way a row is activated — through the presenter, which dismisses
/// everything before the row's closure runs.
struct ChromePopoverContext {
    let maxHeight: CGFloat
    let selectedRowID: String?
    let activateRow: (String) -> Void
}

/// The window's one open bar popover: what is open, where its widget is, which
/// rows it offers and which of them the keyboard has selected.
///
/// The popover is an **in-window overlay** — `ChromePopoverHost`, mounted once at
/// the window root — rather than a child panel: it is inside the window by
/// construction, re-places itself on a resize through the root's geometry, and
/// never takes key status, so the field inside it keeps the text focus and
/// "closes when the window resigns key" is one notification.
///
/// Dismissal and keys go through two local `NSEvent` monitors and one
/// observer, installed on present and removed on dismiss, scoped to the root's
/// window. Neither monitor swallows a click. The key monitor holds **no key
/// logic**: it maps a key code to `PopoverKey`, asks `PopoverKeyRule` what that
/// key means in this state, and executes the answer — `passThrough` returns the
/// event untouched, which is how typing keeps reaching the filter field.
@MainActor
final class ChromePopoverPresenter: ObservableObject {
    /// The window root's named coordinate space: top-left origin, y down — the
    /// convention `PopoverPlacement` works in. The widgets, the bar, the rows
    /// and the host all report their frames in it.
    static let coordinateSpace = "pisaka.chromePopoverRoot"

    /// The open submenu: the row it hangs from, that row's top edge, its rows
    /// and its own selection. The top follows the row: a resize or a popover
    /// height change that moves the row moves the submenu with it.
    struct Submenu {
        let anchorRowID: String
        var anchorRowTop: CGFloat
        let rows: [ChromePopoverSubmenuRow]
        var selection: PopoverSelection
    }

    @Published private(set) var openID: String?
    /// The open popover's widget, in the root's coordinate space.
    @Published private(set) var anchor: CGRect = .zero
    /// The open popover's content. Not published on its own: it changes only
    /// together with `openID`, and the content structs observe their own models.
    private(set) var content: ((ChromePopoverContext) -> AnyView)?
    /// The bottom bar's top edge, in the root's coordinate space.
    @Published private(set) var barTop: CGFloat = 0
    private(set) var rows: [ChromePopoverRowAction] = []
    @Published private(set) var selection = PopoverSelection(count: 0)
    @Published private(set) var submenu: Submenu?
    /// The drawn popover's frame — the submenu is placed beside it.
    @Published private(set) var popoverFrame: CGRect = .zero
    /// The drawn submenu's frame, read only by the mouse monitor.
    private(set) var submenuFrame: CGRect = .zero

    /// Each registered row's top edge, as the rows last reported it. Read when
    /// a submenu opens; never drawn from, so never published.
    private var rowTops: [String: CGFloat] = [:]

    /// The root's flipped AppKit stand-in: it supplies the window the monitors
    /// are scoped to and converts an event's point into the root's space.
    private weak var rootView: NSView?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// What held the window's focus when the popover opened — a field
    /// editor's owning control, never the field editor itself. The filter
    /// field takes the focus inside this same window, so nothing gives it back
    /// on its own when the overlay goes away.
    private weak var priorResponder: NSResponder?

    var isOpen: Bool { openID != nil }

    /// The keyboard-selected row's id, if any.
    var selectedRowID: String? {
        guard let index = selection.selectedIndex, rows.indices.contains(index) else { return nil }
        return rows[index].id
    }

    // MARK: - API

    /// Open the popover `id` from the widget at `anchor`, or close it when it is
    /// the one already open — the widget's button is a toggle.
    func present(id: String, anchor: CGRect, content: @escaping (ChromePopoverContext) -> AnyView) {
        if openID == id {
            dismiss()
            return
        }
        if openID == nil {
            priorResponder = Self.focusOwner(rootView?.window?.firstResponder)
        }
        closeSubmenu()
        rows = []
        rowTops = [:]
        selection = PopoverSelection(count: 0)
        self.anchor = anchor
        self.content = content
        openID = id
        installMonitors()
    }

    /// Close the popover and its submenu and remove every monitor.
    func dismiss() {
        removeMonitors()
        guard openID != nil else { return }
        restoreFocus()
        submenu = nil
        submenuFrame = .zero
        openID = nil
        content = nil
        rows = []
        rowTops = [:]
        selection = PopoverSelection(count: 0)
        popoverFrame = .zero
    }

    /// Register the open content's rows in display order. The selection returns
    /// to the first row, and a submenu hanging from the old rows closes.
    func setRows(_ rows: [ChromePopoverRowAction]) {
        guard isOpen else { return }
        self.rows = rows
        selection = selection.reset(count: rows.count)
        closeSubmenu()
    }

    /// Open the submenu of the row `id`, beside the popover at that row's top.
    func openSubmenu(for id: String) {
        guard let row = rows.first(where: { $0.id == id }),
              let submenuRows = row.submenu, !submenuRows.isEmpty
        else { return }
        submenu = Submenu(
            anchorRowID: id,
            anchorRowTop: rowTops[id] ?? popoverFrame.minY,
            rows: submenuRows,
            selection: PopoverSelection(count: submenuRows.count)
        )
    }

    func closeSubmenu() {
        guard submenu != nil else { return }
        submenu = nil
        submenuFrame = .zero
    }

    /// Activate the keyboard-selected row: the submenu's when one is open.
    func activateSelected() {
        if let submenu {
            guard let index = submenu.selection.selectedIndex,
                  submenu.rows.indices.contains(index)
            else { return }
            activateSubmenuRow(id: submenu.rows[index].id)
        } else if let id = selectedRowID {
            activateRow(id: id)
        }
    }

    /// Activate a registered row: open its submenu when it has one, otherwise
    /// dismiss everything and only then run its closure.
    func activateRow(id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        if row.submenu != nil {
            openSubmenu(for: id)
            return
        }
        dismiss()
        row.activate()
    }

    /// Activate a submenu row: dismiss everything, then run its closure.
    func activateSubmenuRow(id: String) {
        guard let row = submenu?.rows.first(where: { $0.id == id }) else { return }
        dismiss()
        row.activate()
    }

    // MARK: - Geometry reports

    /// The open widget's frame moved (a resize re-lays the bar).
    func noteAnchor(_ frame: CGRect, for id: String) {
        guard openID == id, anchor != frame else { return }
        anchor = frame
    }

    func noteBarTop(_ top: CGFloat) {
        guard barTop != top else { return }
        barTop = top
    }

    func notePopoverFrame(_ frame: CGRect) {
        guard popoverFrame != frame else { return }
        popoverFrame = frame
    }

    func noteSubmenuFrame(_ frame: CGRect) {
        submenuFrame = frame
    }

    func noteRowTop(_ top: CGFloat, for id: String) {
        rowTops[id] = top
        if submenu?.anchorRowID == id, submenu?.anchorRowTop != top {
            submenu?.anchorRowTop = top
        }
    }

    func attachRootView(_ view: NSView) {
        rootView = view
    }

    // MARK: - Focus

    /// The responder a focus belongs to: a field editor's owning control, or
    /// the responder itself.
    private static func focusOwner(_ responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSResponder {
            return owner
        }
        return responder
    }

    /// Give the focus back to what held it at open time — but only while a
    /// field editor the popover took still holds it. A popover that never took
    /// the focus (the project popover) changes nothing, and a click outside
    /// still lands after this and moves the focus where it was aimed.
    private func restoreFocus() {
        defer { priorResponder = nil }
        guard let window = rootView?.window,
              let prior = priorResponder,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              Self.focusOwner(editor) !== prior
        else { return }
        window.makeFirstResponder(prior)
    }

    // MARK: - Keys

    /// The key-down's `PopoverKey`. Anything but the six named keys is `other`,
    /// and so is any of them carrying ⌘, ⌃ or ⌥ — a chord is never navigation.
    nonisolated static func popoverKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PopoverKey {
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return .other }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .return
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        default: return .other
        }
    }

    /// The state `PopoverKeyRule` decides from.
    var keyState: PopoverKeyState {
        if let submenu {
            return PopoverKeyState(
                submenuOpen: true,
                hasSelection: submenu.selection.selectedIndex != nil,
                selectedHasSubmenu: false
            )
        }
        let selected = selectedRowID.flatMap { id in rows.first { $0.id == id } }
        return PopoverKeyState(
            submenuOpen: false,
            hasSelection: selected != nil,
            selectedHasSubmenu: selected?.submenu != nil
        )
    }

    /// Execute what the rule answered for `key`. `false` is `passThrough`: the
    /// event goes on, unconsumed, to whatever has the focus.
    @discardableResult
    func handle(_ key: PopoverKey) -> Bool {
        switch PopoverKeyRule.action(for: key, state: keyState) {
        case .moveUp: move { $0.movedUp() }
        case .moveDown: move { $0.movedDown() }
        case .activate: activateSelected()
        case .openSubmenu:
            if let id = selectedRowID { openSubmenu(for: id) }
        case .closeSubmenu: closeSubmenu()
        case .dismiss: dismiss()
        case .passThrough: return false
        }
        return true
    }

    /// Move the selection the keys act on — the submenu's while it is open.
    private func move(_ step: (PopoverSelection) -> PopoverSelection) {
        if var open = submenu {
            open.selection = step(open.selection)
            submenu = open
        } else {
            selection = step(selection)
        }
    }

    // MARK: - Monitors

    private func installMonitors() {
        guard mouseMonitor == nil, let window = rootView?.window else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // AppKit delivers a local monitor on the main thread.
            MainActor.assumeIsolated { self.handleMouseDown(event) }
            // Always the event, unchanged: the click that dismisses still lands.
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard event.window === self.rootView?.window else { return false }
                // An input method composing in the field owns Return and the
                // arrows until it commits.
                if let client = event.window?.firstResponder as? NSTextInputClient,
                   client.hasMarkedText() {
                    return false
                }
                return self.handle(Self.popoverKey(keyCode: event.keyCode, modifiers: event.modifierFlags))
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        mouseMonitor = nil
        keyMonitor = nil
        resignObserver = nil
    }

    /// A press outside the popover, the submenu and the widget dismisses. A
    /// press on the widget is left to the widget's own toggle.
    private func handleMouseDown(_ event: NSEvent) {
        guard let rootView, event.window === rootView.window else { return }
        let point = rootView.convert(event.locationInWindow, from: nil)
        let inside = popoverFrame.contains(point)
            || (submenu != nil && submenuFrame.contains(point))
            || anchor.contains(point)
        if !inside { dismiss() }
    }
}

private struct ChromePopoverPresenterKey: EnvironmentKey {
    static let defaultValue: ChromePopoverPresenter? = nil
}

extension EnvironmentValues {
    /// The window's popover presenter. Absent wherever a widget is hosted
    /// outside a window root (the bar's own suites), where its button then
    /// presents nothing.
    var chromePopoverPresenter: ChromePopoverPresenter? {
        get { self[ChromePopoverPresenterKey.self] }
        set { self[ChromePopoverPresenterKey.self] = newValue }
    }
}

extension View {
    /// Report this view's frame in the window root's coordinate space, on
    /// appear and on every change.
    func chromePopoverFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named(ChromePopoverPresenter.coordinateSpace))
            Color.clear
                .onAppear { report(frame) }
                .onChange(of: frame) { report($0) }
        })
    }

    /// Report a registered row's top edge to the presenter, so its submenu can
    /// open beside it, and give the row its id as the List's scroll target. The
    /// report is a no-op where no presenter is in the environment.
    func chromePopoverRowAnchor(id: String) -> some View {
        modifier(ChromePopoverRowAnchor(id: id))
    }
}

private struct ChromePopoverRowAnchor: ViewModifier {
    let id: String
    @Environment(\.chromePopoverPresenter) private var presenter

    func body(content: Content) -> some View {
        content
            // The id the List scrolls to when the keyboard selects this row.
            .id(id)
            .chromePopoverFrame { presenter?.noteRowTop($0.minY, for: id) }
    }
}

/// The window root's popover layer, mounted once in `ContentView.body`, inside
/// the root's theme and scale injections and above the bar.
///
/// It reads the root's size, asks `PopoverPlacement` where the popover goes and
/// how tall it may be, and draws the open content bottom-leading at the
/// answer; an open submenu is the same `ChromePopover`, Head-less, placed by
/// `PopoverPlacement.submenu`. A resize re-places both through the geometry and
/// a window move needs nothing. Only the drawn surfaces hit-test: the layer's
/// empty space and its AppKit stand-in take no click.
struct ChromePopoverHost: View {
    @ObservedObject var presenter: ChromePopoverPresenter

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        GeometryReader { proxy in
            let window = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                if presenter.isOpen, let content = presenter.content {
                    popover(content: content, window: window)
                }
                if let submenu = presenter.submenu {
                    submenuView(submenu, window: window)
                }
            }
        }
        .background(ChromePopoverRootAnchor(presenter: presenter))
    }

    private func popover(
        content: (ChromePopoverContext) -> AnyView,
        window: CGRect
    ) -> some View {
        let placed = PopoverPlacement.popover(
            widget: presenter.anchor,
            barTop: presenter.barTop,
            window: window,
            width: metrics.scaled(ChromeGeometry.popoverWidth),
            maxHeight: metrics.scaled(ChromeGeometry.popoverMaxHeight),
            gap: metrics.scaled(ChromeGeometry.popoverBarGap)
        )
        let context = ChromePopoverContext(
            maxHeight: placed.availableHeight,
            selectedRowID: presenter.selectedRowID,
            activateRow: { [presenter] in presenter.activateRow(id: $0) }
        )
        return content(context)
            .chromePopoverFrame { [presenter] in presenter.notePopoverFrame($0) }
            .padding(.leading, placed.x)
            .frame(width: window.width, height: max(0, placed.bottom), alignment: .bottomLeading)
    }

    private func submenuView(_ submenu: ChromePopoverPresenter.Submenu, window: CGRect) -> some View {
        let rowHeight = metrics.scaled(ChromeGeometry.popoverRowHeight)
        let size = CGSize(
            width: metrics.scaled(ChromeGeometry.popoverWidth),
            height: rowHeight * CGFloat(submenu.rows.count)
                + metrics.scaled(ChromeGeometry.popoverListPaddingBottom)
        )
        let frame = PopoverPlacement.submenu(
            popover: presenter.popoverFrame,
            anchorRowTop: submenu.anchorRowTop,
            size: size,
            window: window,
            gap: metrics.scaled(ChromeGeometry.popoverSubmenuGap)
        )
        let selectedIndex = submenu.selection.selectedIndex
        return ChromePopover(maxHeight: frame.height) {
            ForEach(Array(submenu.rows.enumerated()), id: \.element.id) { index, row in
                ChromePopoverRow(
                    title: row.title,
                    isSelected: index == selectedIndex,
                    action: { [presenter] in presenter.activateSubmenuRow(id: row.id) }
                )
            }
        }
        .chromePopoverFrame { [presenter] in presenter.noteSubmenuFrame($0) }
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// The root's AppKit stand-in: a flipped, click-transparent view filling the
/// root, which hands the presenter its window and converts a window point into
/// the root's top-left, y-down space.
private struct ChromePopoverRootAnchor: NSViewRepresentable {
    let presenter: ChromePopoverPresenter

    func makeNSView(context: Context) -> RootAnchorView {
        let view = RootAnchorView()
        presenter.attachRootView(view)
        return view
    }

    func updateNSView(_ nsView: RootAnchorView, context: Context) {
        presenter.attachRootView(nsView)
    }

    final class RootAnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
