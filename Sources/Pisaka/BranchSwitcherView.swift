#if os(macOS)
import SwiftUI
import PisakaCore

/// The JetBrains-style branch-switcher widget for the always-visible bottom bar.
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

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(currentLabel, systemImage: "arrow.triangle.branch")
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
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

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter branches", text: $model.filterText)
                .textFieldStyle(.roundedBorder)

            Button {
                isPresented = false
                onNewBranch()
            } label: {
                Label("New Branch…", systemImage: "plus")
            }
            .buttonStyle(.plain)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 300)

            if let error = model.errorMessage {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: 300)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func branchRow(_ branch: BranchRef, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: 16)
                    .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                Text(branch.shortName)
                    .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A remote-branch row: a two-item menu — Checkout (git DWIM: switch to the
    /// same-named local or create it from the remote ref, no fetch) and "New Branch
    /// from '…'…" (the create-with-a-pre-filled-name flow). Selecting either
    /// dismisses the popover before the handler runs.
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
            HStack(spacing: 6) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: 16)
                    .foregroundStyle(Color.secondary)
                Text(branch.shortName)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
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
