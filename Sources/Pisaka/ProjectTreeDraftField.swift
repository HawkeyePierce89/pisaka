#if os(macOS)
import SwiftUI
import AppKit
import PisakaCore

// The project tree's inline naming draft — the whole of it, in five types:
//
//   `TreeEditDraft`                    what is being named, and where
//   `TreeNameFieldView`                the row-shaped SwiftUI draft
//   `TreeDraftDismissRegion`           the invisible mouse-down observer
//   `ProjectTreeDraftFieldRepresentable` the `NSTextField` and its coordinator
//   `CustomTextField`                  the field that takes its own focus
//
// **The layer split.** Not one rule lives here. Whether the typed text names a
// creatable entry is `FileName`'s answer (`validateRelativeEntryPath`,
// `validateSingleEntryName`, `liveCollisionIssue`), what a rename preselects is
// `initialRenameSelection`, what a mouse-down means to an open draft is
// `TreeDraftDismissRule`, and what the accepted name *does* to disk is
// `PisakaApp`'s (`newFile(in:name:)` and its two siblings, behind the writer
// gate). This file collects keystrokes, draws the refusal, and reports two
// events — committed with this text, or cancelled. That is the same division the
// tree's retired `FilePanels` prompts kept (`promptName` itself is still
// live code — it serves the two branch prompts); only the surface moved into
// the row.

/// What an open draft is naming: a new entry inside `parent` (a file or a
/// folder), or the existing `entry` being renamed.
///
/// The two cases differ in more than a label, which is why they are one enum
/// read in several places rather than a pair of flags: a create validates the
/// *relative-path* grammar and starts empty, a rename validates the
/// *single-name* grammar and starts pre-filled with a preselected stem; a create
/// draws the icon column its future row will have, a rename draws none because
/// it sits inside the row that already draws one; and a create's collision check
/// excludes nothing while a rename's excludes the entry's own current name.
/// `Equatable` because the tree stores it in `@State` and swaps rows on change.
enum TreeEditDraft: Equatable {
    case create(parent: URL, isFolder: Bool)
    case rename(entry: DirectoryEntry)
}

/// The draft as the tree draws it: an icon column, the text field, and — only
/// when the input is refused — a red reason line beneath them.
///
/// **Validation is composed in one order, in `Coordinator.computeIssue(for:)`,
/// and that order is the contract**: blank first (an empty draft is *not* an
/// error — the user has typed nothing yet, so it shows no reason line and simply
/// refuses to commit), then the grammar validator for the draft's kind, then —
/// only for single-component input, and only if the grammar passed — the live
/// collision check against the siblings the tree already listed. Multi-component
/// input skips collision on purpose: `a/b/c.txt` lands its final component in a
/// folder the tree has not read, so the only honest answer is the one disk gives
/// at commit time (`.alreadyExists`).
///
/// The reason line is `EntryPathIssue.message` verbatim, and the field's text
/// turns red in the same pass, so the refusal is visible without reading.
/// Nothing about it blocks typing: an invalid draft stays open and editable, and
/// only Enter refuses (with a beep).
struct TreeNameFieldView: View {
    let draft: TreeEditDraft
    let siblings: [String]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.interfaceMetrics) private var metrics

    @State private var text: String
    @State private var issue: EntryPathIssue?

    init(draft: TreeEditDraft, siblings: [String], onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.siblings = siblings
        self.onCommit = onCommit
        self.onCancel = onCancel

        switch draft {
        case .create:
            _text = State(initialValue: "")
        case .rename(let entry):
            _text = State(initialValue: entry.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: metrics.scaled(4)) {
                iconColumn

                ProjectTreeDraftFieldRepresentable(
                    text: $text,
                    issue: $issue,
                    draft: draft,
                    siblings: siblings,
                    // The field is AppKit, so the row's `.font` modifier cannot
                    // reach it: the interface zone's size has to be handed over
                    // as a number and set on the `NSFont` itself, exactly as
                    // `HoverPanel` does for the one other AppKit text surface in
                    // the chrome. Without it the drafted row draws at 13 pt
                    // beside a label the same row drew scaled — invisible at
                    // 100%, wrong at every other interface zoom.
                    metrics: metrics,
                    onCommit: onCommit,
                    onCancel: onCancel
                )
            }
            .font(metrics.scaledFont(.body))

            if let issue = issue {
                // The spacing is the create draft's icon-column gap, so it is
                // branched with the column itself: an `HStack` inserts its
                // spacing between *subviews*, and a modified `EmptyView` is
                // still a subview — a zero-width one. Leaving the hidden column
                // in for a rename would therefore inset its reason line by that
                // gap instead of the zero the field sits at.
                HStack(alignment: .top, spacing: isCreate ? metrics.scaled(4) : 0) {
                    // The *same* icon column the field sits beside, drawn hidden
                    // and collapsed to zero height: the reason's inset is then
                    // that column's real width by construction, so it cannot
                    // drift from a literal. The font must match the row's, since
                    // the column's width is the chevron gutter plus a symbol
                    // drawn at that font.
                    if isCreate {
                        iconColumn
                            .font(metrics.scaledFont(.body))
                            .frame(height: 0)
                            .hidden()
                            .accessibilityHidden(true)
                    }

                    Text(issue.message)
                        .foregroundColor(Color(NSColor.systemRed))
                        .font(metrics.scaledFont(.caption))
                        .lineLimit(nil)
                }
            }
        }
        .padding(.horizontal, isCreate ? metrics.scaled(TreeRowLayout.horizontalPadding) : 0)
        .padding(.vertical, isCreate ? metrics.scaled(TreeRowLayout.verticalPadding) : 0)
        // Outermost, *after* the padding: SwiftUI sizes a background to its
        // primary view, so the region's bounds is this whole draft — icon
        // column, field and reason line together. Clicking any of them is
        // therefore "inside" by construction rather than by a measured inset.
        .background(TreeDraftDismissRegion(onCancel: onCancel))
    }

    private var isCreate: Bool {
        if case .create = draft { return true }
        return false
    }

    @ViewBuilder
    private var iconColumn: some View {
        switch draft {
        case .create(_, let isFolder):
            if isFolder {
                HStack(spacing: metrics.scaled(TreeRowLayout.chevronSpacing)) {
                    Color.clear.frame(width: metrics.scaled(TreeRowLayout.chevronWidth))
                    let icon = FileIcon(symbolName: "folder", color: .accent)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: TreeRowLayout.chevronGutter(metrics))
                    let icon = fileIcon(for: text)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            }
        case .rename:
            EmptyView()
        }
    }

    private func fileIcon(for input: String) -> FileIcon {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FileIcon(symbolName: "doc", color: .gray)
        }
        // A trailing slash leaves an empty final component, and
        // `URL(fileURLWithPath: "")` resolves to the process's current
        // directory — an icon read off a path the user never typed. There is no
        // final name yet, so the default doc icon is the honest answer.
        let finalComponent = trimmed.components(separatedBy: "/").last ?? ""
        if finalComponent.isEmpty {
            return FileIcon(symbolName: "doc", color: .gray)
        }
        let dummyURL = URL(fileURLWithPath: finalComponent)
        let entry = DirectoryEntry(url: dummyURL, isDirectory: false)
        return FileIcon(for: entry)
    }
}

/// The draft's invisible dismiss region: the one view that hears a mouse-down
/// anywhere in the window and asks `TreeDraftDismissRule` what it means.
///
/// It exists because a project-tree row is a plain SwiftUI view that never takes
/// first responder, so clicking one moves focus nowhere and the field's
/// `controlTextDidEndEditing` never fires. A local `NSEvent` monitor hears the
/// click before any view does; that delegate callback stays as the fallback for
/// what genuinely *does* move first responder.
///
/// Attached as the draft's outermost `.background`, so its `bounds` is the whole
/// draft's rectangle. It draws nothing, hit-tests to `nil` and declares no size
/// of its own, so it can neither intercept a click nor influence layout.
struct TreeDraftDismissRegion: NSViewRepresentable {
    /// Cancel the draft. Called for a mouse-down elsewhere in the draft's own
    /// window; never for another window's, and never for a click on the draft.
    let onCancel: () -> Void

    func makeNSView(context: Context) -> DismissRegionView {
        let view = DismissRegionView()
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: DismissRegionView, context: Context) {
        nsView.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: DismissRegionView, coordinator: ()) {
        nsView.uninstallMonitor()
    }

    /// Claim exactly what is proposed and nothing more. A background is sized to
    /// its primary view, so this only makes explicit that the region never adds
    /// a millimetre to the draft.
    ///
    /// The unspecified and infinite proposals are answered as zero rather than
    /// passed through: a representable that returns `.infinity` for SwiftUI's
    /// max probe claims unbounded width, which is a broken frame the moment this
    /// view is used anywhere but as a background. Zero is the honest answer for
    /// a view that draws nothing.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DismissRegionView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: .zero)
        return CGSize(width: size.width.isFinite ? size.width : 0, height: size.height.isFinite ? size.height : 0)
    }

    /// Owns the local mouse-down monitor for exactly as long as the draft lives.
    ///
    /// Lifetime is tied to the window, not to `init`/`deinit`: installed in
    /// `viewDidMoveToWindow` once there is a window to compare events against,
    /// removed when the window goes away and again from `dismantleNSView`. Both
    /// halves are idempotent, so no monitor can outlive its draft or double up —
    /// and one draft at a time is already the tree's invariant.
    final class DismissRegionView: NSView {
        var onCancel: (() -> Void)?

        private var monitor: Any?

        /// A left-click whose *down* the rule answered `cancel` for, waiting for
        /// its own mouse-up. See `installMonitor`.
        private var leftClickCancelPending = false

        /// Invisible to the pointer: the region must observe clicks, never
        /// receive them. Returning `nil` leaves every row, tab and pane below it
        /// as clickable as if it were not there.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                uninstallMonitor()
            } else {
                installMonitor()
            }
        }

        /// A *local* monitor — this app's events only, which is also why ⌘Tab
        /// away and ⌘Tab back preserves the draft: another app's clicks are
        /// never seen. (Clicking the window to come back *is* this app's event
        /// and cancels; `TreeDraftDismissRule` states that limit.) Idempotent,
        /// so a re-entered window installs nothing twice.
        ///
        /// **The rule is asked on the down; a left-click acts on the up.** The
        /// *decision* has to be read from the mouse-down — that is the point the
        /// user aimed at, and it is what keeps a drag that starts inside the
        /// field and leaves it (selecting text with the mouse) from reading as a
        /// click elsewhere. But cancelling *there* would move the tree before
        /// the click finished: a create draft's row disappears, a rename draft's
        /// reason line collapses, and every row below shifts up while the button
        /// is still held — so SwiftUI's tap, which completes only if the release
        /// is still inside the view it began in, would fail on exactly the rows
        /// decision A promises to serve. Holding the cancel until the matching
        /// `.leftMouseUp` keeps the geometry the user clicked standing for the
        /// whole click; the cancel then runs immediately before AppKit dispatches
        /// that up, so the tap it enables is the same one it always was.
        /// A right-click is unaffected and stays on the down, because that is
        /// when `NSMenu` opens.
        func installMonitor() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self else { return event }
                // AppKit delivers a local monitor on the main thread — the same
                // reasoning `ZoomController` records for the app's other one.
                MainActor.assumeIsolated { self.handle(event) }
                // ALWAYS the event, unchanged: cancelling a draft does not
                // swallow the click. The folder still toggles, the file still
                // opens, the right-clicked row still gets its menu.
                return event
            }
        }

        func uninstallMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            // A pending cancel belongs to a click this view is no longer around
            // to finish. Dropping it is the safe half: the draft survives a
            // teardown-mid-click rather than being destroyed by one.
            leftClickCancelPending = false
        }

        /// Hand AppKit's facts to the Core rule and act on its answer. No policy
        /// lives here: which window, which point, which rectangle — that is all.
        private func handle(_ event: NSEvent) {
            if event.type == .leftMouseUp {
                // The decision was made on this click's down; the up is only
                // when it is allowed to take effect.
                guard leftClickCancelPending else { return }
                leftClickCancelPending = false
                onCancel?()
                return
            }
            guard let window else { return }
            // The window's *content* area, which the title bar, the toolbar and
            // the traffic lights are not: dragging the window one is typing in
            // must not destroy a half-typed name.
            //
            // `contentLayoutRect`, **not** `contentView.bounds`: a plain
            // SwiftUI `WindowGroup` window — which is the one this app makes —
            // carries `fullSizeContentView` in its style mask, so its content
            // view spans the whole frame *including* the title bar. Measuring
            // there answers `true` for every title-bar click and drag, which
            // would make the rule's chrome answer unreachable and destroy the
            // draft on exactly the gesture that answer exists to survive.
            // `contentLayoutRect` excludes the title bar (and any toolbar)
            // whatever the style mask says, and is in window coordinates — the
            // same unflipped space as `locationInWindow`, so the point goes in
            // unconverted; converting it into the (flipped) content view first
            // is what makes the naive spelling answer `true` again.
            //
            // The resize band along the content area's own bottom/left/right
            // edges *is* inside this rectangle and is a stated limit of the
            // rule, not an oversight — see `TreeDraftDismissRule`'s chrome
            // answer. A window with no content view answers `false` and so
            // preserves the draft; the draft lives in that view, so the case
            // cannot arise.
            let insideContent = window.contentView != nil
                && window.contentLayoutRect.contains(event.locationInWindow)
            // `bounds` intersected with `visibleRect`, not `bounds`: the tree is
            // a scroll view, so a draft scrolled out of the clip view keeps a
            // rectangle that now maps over the pane's header and the panes
            // above and below it. Clipped away, it owns none of that — and a
            // fully scrolled-out draft yields the empty rectangle the rule
            // already answers `cancel` for.
            let decision = TreeDraftDismissRule.decision(
                clickedWindowIsDraftWindow: event.window === window,
                clickedInsideWindowContent: insideContent,
                point: convert(event.locationInWindow, from: nil),
                draftBounds: bounds.intersection(visibleRect)
            )
            guard decision == .cancel else {
                // A down *on* the draft also clears any pending cancel: without
                // that, a previous down whose up was never seen (a click that
                // ended in another app, say) would cancel the draft on the next
                // release anywhere.
                leftClickCancelPending = false
                return
            }
            if event.type == .leftMouseDown {
                leftClickCancelPending = true
            } else {
                onCancel?()
            }
        }
    }
}

/// The draft's `NSTextField`, wrapped for SwiftUI.
///
/// AppKit rather than SwiftUI's `TextField` for three things SwiftUI cannot
/// express here: a field editor whose selection can be set exactly once on
/// appearance, `doCommandBy` (which is how Enter commits and Esc cancels without
/// either ever reaching the row behind), and a delegate that can tell a
/// click-away from a teardown.
struct ProjectTreeDraftFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var issue: EntryPathIssue?
    let draft: TreeEditDraft
    let siblings: [String]
    /// The interface zone's metrics, handed down from `TreeNameFieldView` rather
    /// than read from the environment here: an `NSViewRepresentable` may read
    /// `@Environment`, but the font has to be applied to the `NSFont` in
    /// `makeNSView`/`updateNSView` either way, and taking it as a stored
    /// property keeps `sizeThatFits`'s height arithmetic — which measures at the
    /// same font — reading one value.
    let metrics: InterfaceMetrics
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// The field's font: the row's `.body`, at the interface zone's scale.
    private var scaledFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(metrics.font(.body)))
    }

    func makeNSView(context: Context) -> CustomTextField {
        let field = CustomTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.stringValue = text
        field.font = scaledFont

        // Wrap, never scroll — exactly as the tree's retired dialog did
        // (`FilePanels.promptName`, which now serves only the branch prompts).
        // A deep relative path is the whole reason relative-path create exists,
        // so it has to be readable in full; the row grows to fit it (see
        // `sizeThatFits`). Enter is still never a line break: the coordinator
        // swallows every newline selector and commits instead.
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping

        switch draft {
        case .create(_, let isFolder):
            field.setAccessibilityLabel(isFolder ? "New Folder name" : "New File name")
        case .rename(let entry):
            field.setAccessibilityLabel("rename of \(entry.name)")
        }

        // The selection is decided once, here, from the one Core rule; the field
        // applies it the moment it first takes focus (see `CustomTextField`).
        // Focus itself is *not* requested here: at `makeNSView` time the field
        // has no window yet, and asking on the next runloop turn silently loses
        // every draft whose row joins the window later (expanding a collapsed
        // folder and drafting in it is one command).
        field.pendingSelection = initialSelection

        return field
    }

    /// The range to preselect when the draft opens, by the same Core rule the
    /// tree's retired dialog used: a rename preselects the name minus its extension, a
    /// create has nothing to select yet.
    private var initialSelection: NSRange {
        switch draft {
        case .create(_, let isFolder):
            return initialRenameSelection(in: text, isDirectory: isFolder)
        case .rename(let entry):
            return initialRenameSelection(in: entry.name, isDirectory: entry.isDirectory)
        }
    }

    /// The height the wrapping field needs at the width the tree pane offers, so
    /// a path long enough to wrap is shown in full instead of being clipped to a
    /// fraction of its first line.
    ///
    /// Deliberately *not* shared with `FilePanels.promptFieldHeight(of:)`, whose
    /// arithmetic is the same idea in a different shape: the dialog measures
    /// against its own fixed 400 pt accessory width and feeds the answer to an
    /// `NSLayoutConstraint` it mutates on every keystroke, while this field's
    /// width is whatever the tree pane proposes on each layout pass and the
    /// answer is simply returned. Only the clamp — at least one line, at most
    /// `maximumLines` — is a shared *number*, and it is stated in both places.
    ///
    /// **Only a concrete, positive, finite width is answered.** The unspecified,
    /// zero and infinite proposals are the enclosing `HStack` probing for
    /// flexibility, and they carry no width to wrap against — but the tempting
    /// fallback, "the width the field is currently laid out at", is the one
    /// answer this view must never give: SwiftUI positions an `NSTextField`
    /// representable by its *alignment rect*, so the field's frame ends up four
    /// points wider than the width it was assigned. Reporting that frame back as
    /// the row's minimum makes the row four points wider on the next pass, whose
    /// frame is four points wider again — a ratchet that ends in AppKit aborting
    /// the window's constraint loop ("more Update Constraints in Window passes
    /// than there are views"). The create draft, whose row is *not* capped at
    /// `maxWidth: .infinity`, took exactly that path.
    ///
    /// Returning `nil` hands a probe back to SwiftUI's default sizing and leaves
    /// the concrete placement proposal — the only one that says how wide the
    /// tree pane actually is — to decide the row. Nothing about the row's own
    /// frame is ever fed back into its layout.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CustomTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: fittingHeight(of: nsView, at: width))
    }

    private func fittingHeight(of field: CustomTextField, at width: CGFloat) -> CGFloat {
        // `scaledFont` rather than the system default as the fallback: the
        // height must be measured at the size the field draws at, and that size
        // is the interface zone's.
        let lineHeight = (field.font ?? scaledFont).boundingRectForFont.height
        let oneLine = ceil(lineHeight) + Self.fieldVerticalPadding
        let maximum = ceil(lineHeight * CGFloat(Self.maximumLines)) + Self.fieldVerticalPadding
        guard let cell = field.cell else { return oneLine }
        let fitting = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        ).height
        return min(max(ceil(fitting), oneLine), maximum)
    }

    /// The same ceiling the tree's retired dialog used: past six lines the input is
    /// pathological and a taller row would push the tree around more than it
    /// helps.
    private static let maximumLines = 6

    /// A couple of points of slack so the field editor's caret and the font's
    /// descenders are not clipped. Smaller than the dialog's, which also has to
    /// clear a bezel this borderless field does not draw.
    private static let fieldVerticalPadding: CGFloat = 2

    func updateNSView(_ nsView: CustomTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Re-applied, not set once: an interface zoom step while a draft is open
        // re-runs this pass with new metrics, and the height `sizeThatFits`
        // returns is measured off `field.font` — so a stale font would size the
        // row for text it is no longer drawing.
        let font = scaledFont
        if nsView.font != font {
            nsView.font = font
        }

        let currentIssue = context.coordinator.computeIssue(for: text)
        if currentIssue != issue {
            DispatchQueue.main.async {
                self.issue = currentIssue
            }
        }

        nsView.textColor = currentIssue != nil ? .systemRed : .labelColor
    }

    static func dismantleNSView(_ nsView: CustomTextField, coordinator: Coordinator) {
        nsView.isTearingDown = true
    }

    /// The draft's field, which takes keyboard focus itself rather than being
    /// handed it from outside.
    ///
    /// `viewDidMoveToWindow` is the symmetric hook to the `viewWillMove(toWindow:)`
    /// this class already overrides, and the first moment AppKit guarantees a
    /// window: it fires for the whole subtree when an ancestor joins one, so the
    /// late-attachment path (a collapsed folder expanded and drafted in the same
    /// command) is covered, which the old "ask on the next runloop turn, give up
    /// if there is no window" block was not.
    class CustomTextField: NSTextField {
        var isTearingDown = false

        /// The range to install in the field editor the next time this field
        /// takes focus, then cleared so it is applied exactly once per
        /// acquisition.
        ///
        /// Seeded by `makeNSView` from the one Core rule
        /// (`initialRenameSelection(in:isDirectory:)`), and refilled by
        /// `viewWillMove(toWindow:)` with the *live* selection whenever the field
        /// leaves its window — never with the rule again, so a re-attachment
        /// restores what the user had rather than re-selecting the stem of a name
        /// they have since edited.
        var pendingSelection: NSRange?

        /// One-shot *per attachment*. A draft replaced by a second command must
        /// not have a stale request steal focus back into the field it is
        /// tearing down — but a field that leaves a window and rejoins one is
        /// alive again and needs the caret back, so this is cleared alongside
        /// `isTearingDown`, which is why the two flags are separate.
        ///
        /// Re-acquiring must not re-select over what the user has typed, and the
        /// spent `pendingSelection` alone does not deliver that: taking first
        /// responder makes `NSTextField` select its whole contents, and an
        /// already-applied (therefore `nil`) range leaves that select-all
        /// standing, so the next keystroke would replace everything typed so far.
        /// `viewWillMove(toWindow:)` refills the range with the live selection on
        /// the way out for exactly that reason.
        private var hasTakenFocus = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                isTearingDown = true
                // Carry the caret across a detach. On a real teardown this field
                // is discarded and the range with it; on a re-attachment it is
                // what `becomeFirstResponder`'s select-all is overridden with,
                // so a field that leaves a window and rejoins one comes back
                // exactly where the user left it.
                if let editor = currentEditor() as? NSTextView {
                    pendingSelection = editor.selectedRange
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Both flags mean "this attachment is over", so joining a window
            // clears both: a re-attached field is alive again — a latched
            // `isTearingDown` would leave it unable to report the focus loss
            // `controlTextDidEndEditing` exists to catch, and a latched
            // `hasTakenFocus` would leave it open, editable and permanently
            // without the caret, which is the defect this hook exists to remove.
            if window != nil {
                isTearingDown = false
                hasTakenFocus = false
            }
            acquireFocus(retryOnRefusal: true)
        }

        /// Take first responder and apply the initial selection, at most once.
        ///
        /// `makeFirstResponder` can refuse (another responder declines to
        /// resign), which no window hook can foresee; that one case retries a
        /// single time on the next runloop turn, re-checking the window and the
        /// teardown flag. One attempt, never a poll.
        private func acquireFocus(retryOnRefusal: Bool) {
            guard !hasTakenFocus, !isTearingDown, let window else { return }

            // Already editing in this window — nothing to acquire. AppKit
            // re-sends `viewDidMoveToWindow` for the *same* window when an
            // ancestor is re-added, and that path clears `hasTakenFocus` one
            // line before calling here, so the flag alone cannot say no.
            // `makeFirstResponder(self)` would then resign the live field
            // editor, which posts `controlTextDidEndEditing` with none of its
            // three tests tripped — cancelling, silently, the draft the user is
            // still typing into. Owning the field editor *is* having taken
            // focus, so record that and stop.
            if let editor = currentEditor(), window.firstResponder === editor {
                hasTakenFocus = true
                return
            }

            guard window.makeFirstResponder(self) else {
                guard retryOnRefusal else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.acquireFocus(retryOnRefusal: false)
                }
                return
            }

            hasTakenFocus = true
            applyPendingSelection(in: window)
        }

        private func applyPendingSelection(in window: NSWindow) {
            guard let range = pendingSelection else { return }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            editor.setSelectedRange(range)
            // Cleared only now that it has been applied: dropping it before the
            // field editor was found would leave `becomeFirstResponder`'s
            // select-all standing, which is exactly what the range prevents.
            pendingSelection = nil
        }
    }

    /// The field's delegate: live validation, Enter/Esc, and the end-editing
    /// fallback.
    ///
    /// `isFinishing` is set by whichever of Enter and Esc ran, because both end
    /// the draft themselves and the field then resigns first responder — without
    /// the flag, `controlTextDidEndEditing` would fire *after* a successful
    /// commit and cancel the draft a second time.
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ProjectTreeDraftFieldRepresentable
        var isFinishing = false

        init(_ parent: ProjectTreeDraftFieldRepresentable) {
            self.parent = parent
        }

        func computeIssue(for newText: String) -> EntryPathIssue? {
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }

            // Validator
            let issue: EntryPathIssue?
            switch parent.draft {
            case .create:
                issue = validateRelativeEntryPath(newText)
            case .rename:
                issue = validateSingleEntryName(newText)
            }

            if let issue = issue {
                return issue
            }

            // Collision, for single-component input only. Whether the input is
            // one component is the *parser's* question, not the string's: a
            // single trailing slash is the natural way to spell a folder, so
            // `Sources/` is one component (`parseRelativeEntryPath`) while a
            // `contains("/")` test would skip its collision check and then
            // compare the raw `Sources/` against the siblings.
            switch parent.draft {
            case .create:
                // The grammar passed above, so the path parses.
                guard let components = parseRelativeEntryPath(newText), components.count == 1 else {
                    return nil
                }
                return liveCollisionIssue(finalComponent: components[0], siblingNames: parent.siblings, excluding: nil)
            case .rename(let entry):
                // A rename takes one name — `validateSingleEntryName` already
                // rejected every `/` — so the trimmed input *is* the component.
                return liveCollisionIssue(finalComponent: trimmed, siblingNames: parent.siblings, excluding: entry.name)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newText = field.stringValue
            parent.text = newText
            parent.issue = computeIssue(for: newText)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
                commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
                commandSelector == #selector(NSResponder.insertParagraphSeparator(_:)) {

                let currentIssue = computeIssue(for: parent.text)
                let trimmed = parent.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty || currentIssue != nil {
                    if parent.issue != currentIssue {
                        parent.issue = currentIssue
                    }
                    PlatformFeedback.warning()
                    return true // Handled (swallowed)
                }

                isFinishing = true
                parent.onCommit(parent.text)
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isFinishing = true
                parent.onCancel()
                return true
            }

            return false
        }

        /// The fallback path for a focus loss the mouse-down monitor does not
        /// see: something that genuinely moves first responder — Tab away, a
        /// control that takes focus, a programmatic `makeFirstResponder`.
        ///
        /// Three tests, in order, and each rules out one thing that is not a
        /// click-away: `isFinishing` (Enter or Esc already ended this draft);
        /// `isTearingDown` (the field is being removed — the row was replaced, a
        /// second draft opened, the project switched — and SwiftUI must not be
        /// told to cancel a draft that no longer exists); `window == nil` (the
        /// same case seen from the other side, for a removal that skipped the
        /// flag). Anything left is a real focus loss and cancels silently.
        ///
        /// **Why the responder chain cannot be read here.** The obvious test —
        /// "is the new first responder inside my draft?" — is unanswerable at
        /// this moment: the notification is posted from within
        /// `resignFirstResponder`, *before* the window installs the incoming
        /// responder, so `window.firstResponder` is still the field editor being
        /// dismissed. Hence the flags, which are set by hooks that fire in a
        /// defined order, rather than a read of state that has not happened yet.
        ///
        /// Idempotent with the monitor's path: both end at `draft = nil`, so a
        /// click that goes through both cancels once.
        func controlTextDidEndEditing(_ obj: Notification) {
            if isFinishing { return }
            guard let field = obj.object as? CustomTextField else { return }
            if field.isTearingDown || field.window == nil { return }
            parent.onCancel()
        }
    }
}
#endif
