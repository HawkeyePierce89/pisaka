#if os(macOS)
import SwiftUI
import PisakaCore

/// The branch-switcher widget for the always-visible bottom bar.
///
/// A thin SwiftUI view over `BranchSwitcherModel` — all branching logic
/// (grouping/sorting/marking, filter, the default create-from-remote name) lives
/// in Core. The widget shows the current branch as a bottom-bar button that opens
/// a popover with the Local/Remote branch list (the current one marked), a live
/// filter field, and a "New Branch…" action. Clicking a local branch requests a
/// checkout; clicking a remote branch requests a create-from-that-remote (with a
/// pre-filled name); "New Branch…" requests a create from `HEAD`.
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

    @State private var isPresented = false

    /// The interface zone's metrics, inherited from the window root. The popover
    /// inherits the environment from this view, so its rows scale with the widget
    /// that opened them.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome theme, read from the environment the window root injects. The
    /// popover inherits it from this view, so its content is drawn on `bgPopover`
    /// too.
    @Environment(\.chromeTheme) private var theme

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case filter
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            // A `Button`'s children are *combined* into one accessibility
            // element, and an unhidden SF Symbol folds its own name into that
            // element's name — the announcement part one recorded on the tree
            // row ("chevron.right, folder fill, Sources") is the same mechanism
            // read from the other side. Both symbols here are decoration beside
            // a name that already says everything, so both are hidden, in
            // `ProjectTreeView`'s idiom.
            HStack(spacing: metrics.scaled(4)) {
                Image(systemName: "arrow.triangle.branch")
                    .accessibilityHidden(true)
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
                // Neither switcher carried one before this sweep.
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
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
        .help("Current branch — click to switch or create")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    /// The bottom-bar label: the current branch's short name, or a placeholder for
    /// a detached/unborn HEAD or a non-repository folder.
    private var currentLabel: String {
        if let current = model.current { return current.shortName }
        return model.root == nil ? "No branch" : "Detached"
    }

    /// The popover's content, drawn on `bgPopover`. The popover's arrow keeps the
    /// system material, because the content background cannot reach it.
    private var popoverContent: some View {
        // The popover's arrow keeps the system material, because the content background cannot reach it.
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            ChromeThemedTextField(
                title: "Filter branches",
                text: $model.filterText,
                focus: $focusedField,
                focusedEquals: .filter
            )

            Button {
                isPresented = false
                onNewBranch()
            } label: {
                Label("New Branch…", systemImage: "plus")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                    let locals = model.filteredLocalBranches
                    if !locals.isEmpty {
                        sectionHeader("Local")
                        ForEach(locals) { branch in
                            branchRow(branch) {
                                isPresented = false
                                if !branch.isCurrent { onSwitch(branch) }
                            }
                        }
                    }
                    let remotes = model.filteredRemoteBranches
                    if !remotes.isEmpty {
                        sectionHeader("Remote")
                        ForEach(remotes) { branch in
                            remoteBranchRow(branch)
                        }
                    }
                    if locals.isEmpty && remotes.isEmpty {
                        Text("No branches")
                            .font(metrics.scaledFont(.callout))
                            .foregroundStyle(theme.color(.textSecondary))
                            .padding(.vertical, metrics.scaled(4))
                    }
                }
            }
            .frame(maxHeight: metrics.scaled(300))

            if let error = model.errorMessage {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
                Text(error)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.statusRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(metrics.scaled(10))
        .frame(width: metrics.scaled(300))
        .background(theme.color(.bgPopover))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.caption, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .padding(.top, metrics.scaled(4))
    }

    /// A local-branch row.
    ///
    /// This row's glyph is the one symbol in this file whose *name and colour
    /// are both chosen by a value* — `checkmark`/accent for the branch that is
    /// checked out, the branch symbol/secondary for every other. That is the
    /// row's **state**, not decoration, and the accent on the name beside it
    /// carries the same state in the same unreadable currency: colour. So the
    /// glyph stays hidden — a spoken value says it better than a folded-in
    /// symbol name would — and the state it showed is spoken by the row itself,
    /// as an accessibility *value* on the combined element the `Button` makes
    /// of its children. A non-current row has no state to report and says
    /// nothing.
    private func branchRow(_ branch: BranchRef, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: metrics.scaled(6)) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: metrics.scaled(16))
                    .foregroundStyle(theme.color(branch.isCurrent ? .accent : .textSecondary))
                    // Hidden because the state it showed is now spoken: the
                    // value below is the carrier, and an unhidden symbol would
                    // fold its own name into the row's instead.
                    .accessibilityHidden(true)
                Text(branch.shortName)
                    .foregroundStyle(theme.color(branch.isCurrent ? .accent : .textPrimary))
                Spacer()
            }
            .font(metrics.scaledFont(.body))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(branch.isCurrent ? "Current branch" : "")
    }

    /// A remote-branch row: a two-item menu — Checkout (git DWIM: switch to the
    /// same-named local or create it from the remote ref, no fetch) and "New Branch
    /// from '…'…" (the create-with-a-pre-filled-name flow). Selecting either
    /// dismisses the popover before the handler runs.
    ///
    /// Unlike `branchRow(_:action:)` this row carries **no state**, and so owes
    /// no spoken value: `BranchRef.parse` builds every remote ref with
    /// `isCurrent: false` — HEAD is a local branch — so `rowIcon(for:)` answers
    /// `cloud` here for every row and the colour is the same secondary on every
    /// row. A glyph that is identical in every state is decoration, which is
    /// what hiding it silently means; that is worth saying once, because the
    /// shared `rowIcon(for:)` reads as though it varied.
    private func remoteBranchRow(_ branch: BranchRef) -> some View {
        Menu {
            Button("Checkout") {
                isPresented = false
                onCheckoutRemote(branch)
            }
            Button("New Branch from '\(branch.shortName)'…") {
                isPresented = false
                onCreateFromRemote(branch)
            }
        } label: {
            HStack(spacing: metrics.scaled(6)) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: metrics.scaled(16))
                    .foregroundStyle(theme.color(.textSecondary))
                    // Decoration: the same glyph in the same colour on every
                    // remote row, so hiding it removes nothing — see the note
                    // on this declaration.
                    .accessibilityHidden(true)
                Text(branch.shortName)
                    .foregroundStyle(theme.color(.textPrimary))
                Spacer()
            }
            .font(metrics.scaledFont(.body))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func rowIcon(for branch: BranchRef) -> String {
        if branch.isCurrent { return "checkmark" }
        return branch.isRemote ? "cloud" : "arrow.triangle.branch"
    }
}

#endif
