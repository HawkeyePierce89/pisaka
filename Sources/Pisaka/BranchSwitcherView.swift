#if os(macOS)
import SwiftUI
import PisakaCore

/// The branch-switcher widget for the always-visible bottom bar.
///
/// A thin SwiftUI view over `BranchSwitcherModel` — all branching logic
/// (grouping/sorting/marking, filter, the default create-from-remote name) lives
/// in Core. The widget shows the current branch as a bottom-bar button that opens
/// the window's in-window popover (`BranchSwitcherPopover`, presented by
/// `ChromePopoverPresenter`) with a live filter field, a "New Branch…" action and
/// the Local/Remote branch list, the current one marked. Clicking a local branch
/// requests a checkout; a remote branch opens a two-row submenu (Checkout, New
/// Branch from it); "New Branch…" requests a create from `HEAD`.
///
/// The orchestration — the gates (autosave suspend / tree lock), the dirty-tree
/// warning, the create dialogs, tab resync, and refreshing Changes/Log/tree — lives
/// in `PisakaApp`, like the revert/apply-merge paths. This view only presents the
/// list and forwards the user's choice through the callbacks.
struct BranchSwitcherView: View {
    @ObservedObject var model: BranchSwitcherModel
    /// Switch to a local branch (checkout). Wired to `PisakaApp`'s gated
    /// orchestration; a no-op default so previews/tests can construct the view.
    var onSwitch: (BranchRef) -> Void = { _ in }
    /// Create-and-switch a new branch from a remote branch (a pre-filled name).
    /// Wired to `PisakaApp`; default no-op for previews/tests.
    var onCreateFromRemote: (BranchRef) -> Void = { _ in }
    /// Checkout a remote branch (git DWIM): switch to the same-named local if it
    /// exists, else create it from the remote ref (no fetch). Wired to `PisakaApp`;
    /// default no-op for previews/tests.
    var onCheckoutRemote: (BranchRef) -> Void = { _ in }
    /// Create-and-switch a new branch from `HEAD` ("New Branch…"). Wired to
    /// `PisakaApp`; default no-op for previews/tests.
    var onNewBranch: () -> Void = {}

    /// The presenter's id for this widget's popover.
    static let popoverID = "branchSwitcher"

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome theme, read from the environment the window root injects.
    @Environment(\.chromeTheme) private var theme

    /// The window's popover presenter; absent outside a window root, where the
    /// button presents nothing.
    @Environment(\.chromePopoverPresenter) private var presenter

    /// This widget's frame in the root's coordinate space — the popover's anchor.
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            let (model, onSwitch, onCreateFromRemote, onCheckoutRemote, onNewBranch) =
                (model, onSwitch, onCreateFromRemote, onCheckoutRemote, onNewBranch)
            presenter?.present(id: Self.popoverID, anchor: frame) { context in
                AnyView(BranchSwitcherPopover(
                    model: model,
                    context: context,
                    onSwitch: onSwitch,
                    onCreateFromRemote: onCreateFromRemote,
                    onCheckoutRemote: onCheckoutRemote,
                    onNewBranch: onNewBranch
                ))
            }
        } label: {
            // A `Button`'s children are *combined* into one accessibility
            // element; the two glyphs here are decoration beside a name that
            // already says everything, and `DesignGlyphImage` hides each from
            // accessibility itself, so neither folds anything into the name.
            HStack(spacing: metrics.scaled(4)) {
                DesignGlyphImage(.gitBranch, size: 12, slot: 12, role: .textSecondary)
                // One line, always. The bar states its own height now
                // (`ChromeGeometry.bottomBarHeight`), and a flexible `Text` in a
                // fixed-height frame does not make room for itself: a long
                // branch name — the shape this widget meets most often — would
                // wrap and be clipped in half rather than grow the bar.
                // Truncating is the same answer the popover's own rows give.
                Text(currentLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The caret the design draws on a widget that opens a list.
                DesignGlyphImage(.chevronDown, size: 10, slot: 10, role: .textSecondary)
            }
            .font(metrics.scaledFont(.callout))
            .foregroundStyle(theme.color(.textSecondary))
            // No padding of its own: the bottom bar owns the 14-point gaps
            // between its widgets and its own height, so a padding here would
            // make the bar's stated measurements not the ones drawn. The whole
            // label stays the click target through `contentShape`.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.root == nil)
        // The tooltip through AppKit, not `.help` — `BarToolTip` says why; the
        // bar keeps one tooltip mechanism (gating rule ten).
        .background(BarToolTip(text: "Current branch — click to switch or create"))
        // What the widget is, as its name, and the branch it shows as its value
        // — the text the combined label announced before the name was stated.
        .accessibilityLabel("Current branch")
        .accessibilityValue(currentLabel)
        .chromePopoverFrame { [presenter] in
            frame = $0
            presenter?.noteAnchor($0, for: Self.popoverID)
        }
    }

    /// The bottom-bar label: the current branch's short name, or a placeholder for
    /// a detached/unborn HEAD or a non-repository folder.
    private var currentLabel: String {
        if let current = model.current { return current.shortName }
        return model.root == nil ? "No branch" : "Detached"
    }
}

/// The branch popover's content: a filter field and "New Branch…" in the Head,
/// the Local/Remote sections in the List, and the model's error in a Foot drawn
/// only while there is one.
///
/// Its rows are registered with the presenter in display order — the action row
/// first — on appear, on every filter change and whenever the filtered lists
/// change, and each registration returns the keyboard selection to the first
/// row, and again when the current branch changes. A remote row registers a
/// two-row submenu instead of acting itself.
struct BranchSwitcherPopover: View {
    @ObservedObject var model: BranchSwitcherModel
    let context: ChromePopoverContext
    var onSwitch: (BranchRef) -> Void = { _ in }
    var onCreateFromRemote: (BranchRef) -> Void = { _ in }
    var onCheckoutRemote: (BranchRef) -> Void = { _ in }
    var onNewBranch: () -> Void = {}

    static let newBranchRowID = "newBranch"

    @Environment(\.chromePopoverPresenter) private var presenter

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case filter
    }

    var body: some View {
        ChromePopover(maxHeight: context.maxHeight, head: { head }, list: { list }, foot: foot)
            .scrolling(to: context.selectedRowID)
            .onAppear {
                // The overlay mounts this content during its appearance pass,
                // before the field is in the window's responder chain, and a
                // request made now is lost: ask again after that pass.
                focusedField = .filter
                Task { @MainActor in focusedField = .filter }
                registerRows()
            }
            .onChange(of: model.filterText) { _ in registerRows() }
            .onChange(of: rowIDs) { _ in registerRows() }
            // A local row's action reads `isCurrent` at registration, and the
            // ids alone do not change when HEAD moves.
            .onChange(of: model.current?.name) { _ in registerRows() }
    }

    /// The Head: the filter field, then the "New Branch…" action row — one
    /// stack, so the container's padding and rule wrap the slot, not each row.
    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChromePopoverFieldBlock {
                ChromeThemedTextField(
                    title: "Filter branches",
                    text: $model.filterText,
                    designGlyph: .search,
                    focus: $focusedField,
                    focusedEquals: .filter,
                    textStyle: .body,
                    spacing: ChromeGeometry.popoverFieldGlyphGap,
                    height: ChromeGeometry.popoverFieldHeight
                )
            }
            row(id: Self.newBranchRowID, title: "New Branch…", glyph: .gitBranch)
        }
    }

    /// The List: the Local and Remote sections, each omitted when empty, or one
    /// message when both are.
    @ViewBuilder private var list: some View {
        let locals = model.filteredLocalBranches
        let remotes = model.filteredRemoteBranches
        if !locals.isEmpty {
            ChromePopoverSectionHeader(title: "Local")
            ForEach(locals) { branch in
                row(
                    id: Self.localRowID(branch),
                    title: branch.shortName,
                    isCurrent: branch.isCurrent,
                    accessibilityValue: branch.isCurrent ? "Current branch" : nil
                )
            }
        }
        if !remotes.isEmpty {
            ChromePopoverSectionHeader(title: "Remote")
            ForEach(remotes) { branch in
                row(
                    id: Self.remoteRowID(branch),
                    title: branch.shortName,
                    hasChevron: true,
                    accessibilityHint: "Opens Checkout and New Branch from this branch"
                )
            }
        }
        if locals.isEmpty && remotes.isEmpty {
            ChromePopoverMessage(text: "No branches", role: .textSecondary)
        }
    }

    /// The Foot: the model's error, and no Foot at all without one.
    private var foot: ChromePopoverMessage? {
        model.errorMessage.map { ChromePopoverMessage(text: $0, role: .statusRed) }
    }

    /// One registered row, drawn selected when the keyboard has selected it and
    /// activated through the presenter, which dismisses or opens the submenu.
    private func row(
        id: String,
        title: String,
        glyph: DesignGlyph? = nil,
        isCurrent: Bool = false,
        hasChevron: Bool = false,
        accessibilityValue: String? = nil,
        accessibilityHint: String? = nil
    ) -> some View {
        ChromePopoverRow(
            title: title,
            glyph: glyph,
            isCurrent: isCurrent,
            isSelected: context.selectedRowID == id,
            hasChevron: hasChevron,
            accessibilityValue: accessibilityValue,
            accessibilityHint: accessibilityHint,
            action: { context.activateRow(id) }
        )
        .chromePopoverRowAnchor(id: id)
    }

    private static func localRowID(_ branch: BranchRef) -> String { "local:\(branch.name)" }
    private static func remoteRowID(_ branch: BranchRef) -> String { "remote:\(branch.name)" }

    /// The registered rows' ids, in display order.
    private var rowIDs: [String] {
        [Self.newBranchRowID]
            + model.filteredLocalBranches.map(Self.localRowID)
            + model.filteredRemoteBranches.map(Self.remoteRowID)
    }

    /// The row actions in display order. The current branch's row only
    /// dismisses — the presenter dismisses before every row's closure.
    private func registerRows() {
        var rows = [ChromePopoverRowAction(id: Self.newBranchRowID, activate: onNewBranch)]
        for branch in model.filteredLocalBranches {
            rows.append(ChromePopoverRowAction(id: Self.localRowID(branch), activate: { [onSwitch] in
                if !branch.isCurrent { onSwitch(branch) }
            }))
        }
        for branch in model.filteredRemoteBranches {
            rows.append(ChromePopoverRowAction(
                id: Self.remoteRowID(branch),
                activate: {},
                submenu: [
                    ChromePopoverSubmenuRow(id: "checkout", title: "Checkout") { [onCheckoutRemote] in
                        onCheckoutRemote(branch)
                    },
                    ChromePopoverSubmenuRow(
                        id: "newBranchFromRemote",
                        title: "New Branch from '\(branch.shortName)'…"
                    ) { [onCreateFromRemote] in
                        onCreateFromRemote(branch)
                    },
                ]
            ))
        }
        presenter?.setRows(rows)
    }
}

#endif
