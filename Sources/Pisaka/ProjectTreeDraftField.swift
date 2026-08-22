#if os(macOS)
import SwiftUI
import AppKit
import PisakaCore

enum TreeEditDraft: Equatable {
    case create(parent: URL, isFolder: Bool)
    case rename(entry: DirectoryEntry)
}

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
                    onCommit: onCommit,
                    onCancel: onCancel
                )
            }
            .font(metrics.scaledFont(.body))

            if let issue = issue {
                HStack(alignment: .top, spacing: metrics.scaled(4)) {
                    // The *same* icon column the field sits beside, drawn hidden
                    // and collapsed to zero height: the reason's inset is then
                    // that column's real width by construction, so it cannot
                    // drift from a literal, and a rename draft — which has no
                    // icon column at all — keeps a zero inset for free. The font
                    // must match the row's, since the column's width is the
                    // chevron gutter plus a symbol drawn at that font.
                    iconColumn
                        .font(metrics.scaledFont(.body))
                        .frame(height: 0)
                        .hidden()
                        .accessibilityHidden(true)

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
        let finalComponent = trimmed.components(separatedBy: "/").last ?? ""
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DismissRegionView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
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
        /// away and back preserves the draft: another app's clicks are never
        /// seen. Idempotent, so a re-entered window installs nothing twice.
        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
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
        }

        /// Hand AppKit's facts to the Core rule and act on its answer. No policy
        /// lives here: which window, which point, which rectangle — that is all.
        private func handle(_ event: NSEvent) {
            guard let window else { return }
            let decision = TreeDraftDismissRule.decision(
                clickedWindowIsDraftWindow: event.window === window,
                point: convert(event.locationInWindow, from: nil),
                draftBounds: bounds
            )
            if decision == .cancel {
                onCancel?()
            }
        }
    }
}

struct ProjectTreeDraftFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var issue: EntryPathIssue?
    let draft: TreeEditDraft
    let siblings: [String]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CustomTextField {
        let field = CustomTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        // Wrap, never scroll — exactly as the retired `FilePanels.promptName`
        // dialog did. A deep relative path is the whole reason relative-path
        // create exists, so it has to be readable in full; the row grows to fit
        // it (see `sizeThatFits`). Enter is still never a line break: the
        // coordinator swallows every newline selector and commits instead.
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
    /// retired dialog used: a rename preselects the name minus its extension, a
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
    /// An unspecified or infinite proposed width carries no information to wrap
    /// against, so it falls back to the width the field is currently laid out
    /// at.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CustomTextField, context: Context) -> CGSize? {
        let width = Self.wrappingWidth(proposal.width, of: nsView)
        return CGSize(width: width, height: Self.fittingHeight(of: nsView, at: width))
    }

    private static func wrappingWidth(_ proposed: CGFloat?, of field: CustomTextField) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else {
            return max(field.frame.width, 1)
        }
        return proposed
    }

    private static func fittingHeight(of field: CustomTextField, at width: CGFloat) -> CGFloat {
        let lineHeight = (field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height
        let oneLine = ceil(lineHeight) + fieldVerticalPadding
        let maximum = ceil(lineHeight * CGFloat(maximumLines)) + fieldVerticalPadding
        guard let cell = field.cell else { return oneLine }
        let fitting = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        ).height
        return min(max(ceil(fitting), oneLine), maximum)
    }

    /// The same ceiling the retired dialog used: past six lines the input is
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

        let currentIssue = context.coordinator.computeIssue(for: text)
        if currentIssue != issue {
            DispatchQueue.main.async {
                self.issue = currentIssue
            }
        }

        nsView.textColor = currentIssue != nil ? .systemRed : .labelColor
    }

    func dismantleNSView(_ nsView: CustomTextField, coordinator: Coordinator) {
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

        /// Applied to the field editor exactly once, right after focus is first
        /// taken, then cleared: a later re-attachment must never re-select over
        /// what the user has since typed or selected.
        var pendingSelection: NSRange?

        /// One-shot. A draft replaced by a second command must not have a stale
        /// request steal focus back into the field it is tearing down.
        private var hasTakenFocus = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                isTearingDown = true
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
            pendingSelection = nil
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            editor.setSelectedRange(range)
        }
    }

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

            // Collision
            if !trimmed.contains("/") {
                let excludingName: String?
                switch parent.draft {
                case .create: excludingName = nil
                case .rename(let entry): excludingName = entry.name
                }
                return liveCollisionIssue(finalComponent: trimmed, siblingNames: parent.siblings, excluding: excludingName)
            } else {
                return nil
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

        func controlTextDidEndEditing(_ obj: Notification) {
            if isFinishing { return }
            guard let field = obj.object as? CustomTextField else { return }
            if field.isTearingDown || field.window == nil { return }
            parent.onCancel()
        }
    }
}
#endif
