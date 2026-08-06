#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS peer of the macOS `BranchSwitcherView` — the JetBrains-style branch
/// widget for the toolbar / navigation bar.
///
/// A thin SwiftUI view over `BranchSwitcherModel`; all branching logic
/// (grouping/sorting/marking, filter, the default create-from-remote name) lives
/// in Core. The widget shows the current branch as a toolbar button that presents
/// a sheet with the Local/Remote branch list (the current one marked), a live
/// filter field, and a "New Branch…" action. Tapping a local branch requests a
/// checkout (with a dirty-tree confirmation, since git may refuse to overwrite
/// local changes); tapping a remote branch, or "New Branch…", prompts for a name
/// (pre-filled from the remote's short name for the former) and requests a
/// create-and-switch.
///
/// The orchestration — snapshotting open tabs, running the git op, resyncing tabs,
/// refreshing Local Changes/Log, and handling a failed remote fetch (offer
/// create-from-local) — lives in `RootView_iOS`, the iOS peer of `PisakaApp`'s
/// branch handlers. This view only presents the list and forwards the choice.
struct BranchSwitcherView_iOS: View {
    @ObservedObject var model: BranchSwitcherModel

    /// Switch to a local branch (checkout). Wired to `RootView_iOS`'s gated
    /// orchestration; a no-op default so previews can construct the view.
    var onSwitch: (BranchRef) -> Void = { _ in }

    /// Create-and-switch a new branch `name` at `startPoint` (`.head` for
    /// "New Branch…", `.ref` for a remote/local start). Wired to `RootView_iOS`;
    /// default no-op for previews.
    var onCreateBranch: (String, BranchSwitcherModel.StartPoint) -> Void = { _, _ in }

    /// Check out a remote branch via git DWIM (switch to the same-named local if it
    /// exists, else create it from the remote ref, no fetch). Wired to `RootView_iOS`;
    /// default no-op for previews.
    var onCheckoutRemote: (BranchRef) -> Void = { _ in }

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(currentLabel, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
        }
        .disabled(model.root == nil)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                BranchListSheet_iOS(
                    model: model,
                    onSwitch: { branch in
                        isPresented = false
                        onSwitch(branch)
                    },
                    onCreateBranch: { name, startPoint in
                        isPresented = false
                        onCreateBranch(name, startPoint)
                    },
                    onCheckoutRemote: { branch in
                        isPresented = false
                        onCheckoutRemote(branch)
                    },
                    onDone: { isPresented = false }
                )
            }
        }
    }

    /// The toolbar label: the current branch's short name, or a placeholder for a
    /// detached/unborn HEAD or a non-repository folder.
    private var currentLabel: String {
        if let current = model.current { return current.shortName }
        return model.root == nil ? "No branch" : "Detached"
    }
}

/// The sheet content: the filter field, "New Branch…", the Local/Remote lists, and
/// the name-entry / dirty-switch prompts. Presented inside a `NavigationStack` so
/// it gets a title bar and a Done button.
private struct BranchListSheet_iOS: View {
    @ObservedObject var model: BranchSwitcherModel
    var onSwitch: (BranchRef) -> Void
    var onCreateBranch: (String, BranchSwitcherModel.StartPoint) -> Void
    var onCheckoutRemote: (BranchRef) -> Void
    var onDone: () -> Void

    /// The pending target of a dirty-tree checkout confirmation. Typed so a confirmed
    /// checkout routes to the correct path: a `.local` branch through `onSwitch` (a plain
    /// `git checkout <branch>`), a `.remote` branch through `onCheckoutRemote` (git DWIM)
    /// — routing a remote through `onSwitch` would `git checkout origin/foo` into a
    /// detached HEAD.
    private enum DirtyCheckoutTarget: Equatable {
        case local(BranchRef)
        case remote(BranchRef)
    }

    /// The branch the user tapped while the working tree is dirty, awaiting a
    /// "Switch anyway" confirmation (git may refuse to overwrite local changes).
    @State private var dirtyCheckoutTarget: DirtyCheckoutTarget?

    /// The start point of an in-progress create (drives the name-entry alert): `.head`
    /// for "New Branch…", `.ref(remote)` for a remote-branch tap.
    @State private var createStartPoint: BranchSwitcherModel.StartPoint?
    /// The editable new-branch name for the create alert (pre-filled for a remote).
    @State private var createName = ""

    var body: some View {
        List {
            Section {
                Button {
                    beginCreate(from: .head, defaultName: "")
                } label: {
                    Label("New Branch…", systemImage: "plus")
                }
            }

            let locals = model.filteredLocalBranches
            if !locals.isEmpty {
                Section("Local") {
                    ForEach(locals) { branch in
                        branchRow(branch) { tapLocal(branch) }
                    }
                }
            }

            let remotes = model.filteredRemoteBranches
            if !remotes.isEmpty {
                Section("Remote") {
                    ForEach(remotes) { branch in
                        remoteBranchRow(branch)
                    }
                }
            }

            if locals.isEmpty && remotes.isEmpty {
                Text("No branches")
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.filterText, prompt: "Filter branches")
        .navigationTitle("Branches")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .confirmationDialog(
            "Working tree has uncommitted changes",
            isPresented: dirtySwitchBinding,
            presenting: dirtyCheckoutTarget
        ) { target in
            Button("Switch") {
                switch target {
                case .local(let branch): onSwitch(branch)
                case .remote(let branch): onCheckoutRemote(branch)
                }
            }
            Button("Cancel", role: .cancel) { dirtyCheckoutTarget = nil }
        } message: { _ in
            Text("Switching branches may be blocked if it would overwrite local changes.")
        }
        .alert("New Branch", isPresented: createAlertBinding) {
            TextField("Branch name", text: $createName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create") {
                if let startPoint = createStartPoint {
                    let name = createName.trimmingCharacters(in: .whitespacesAndNewlines)
                    createStartPoint = nil
                    onCreateBranch(name, startPoint)
                }
            }
            Button("Cancel", role: .cancel) { createStartPoint = nil }
        } message: {
            Text("Enter a name for the new branch.")
        }
    }

    /// Tap on a local branch: no-op for the current one, straight to `onSwitch` on a
    /// clean tree, or via the dirty-switch confirmation otherwise.
    private func tapLocal(_ branch: BranchRef) {
        guard !branch.isCurrent else { return }
        if model.isWorkingTreeDirty {
            dirtyCheckoutTarget = .local(branch)
        } else {
            onSwitch(branch)
        }
    }

    /// Tap "Checkout" on a remote branch (git DWIM): straight to `onCheckoutRemote` on a
    /// clean tree, or via the dirty-checkout confirmation otherwise. No `isCurrent` guard —
    /// a remote ref is never the current branch.
    private func tapCheckoutRemote(_ branch: BranchRef) {
        if model.isWorkingTreeDirty {
            dirtyCheckoutTarget = .remote(branch)
        } else {
            onCheckoutRemote(branch)
        }
    }

    /// Seed and present the name-entry alert for a create from `startPoint`.
    private func beginCreate(from startPoint: BranchSwitcherModel.StartPoint, defaultName: String) {
        createName = defaultName
        createStartPoint = startPoint
    }

    private var dirtySwitchBinding: Binding<Bool> {
        Binding(
            get: { dirtyCheckoutTarget != nil },
            set: { if !$0 { dirtyCheckoutTarget = nil } }
        )
    }

    private var createAlertBinding: Binding<Bool> {
        Binding(
            get: { createStartPoint != nil },
            set: { if !$0 { createStartPoint = nil } }
        )
    }

    private func branchRow(_ branch: BranchRef, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: 18)
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
    /// from '…'…" (the create-with-a-pre-filled-name flow).
    private func remoteBranchRow(_ branch: BranchRef) -> some View {
        Menu {
            Button("Checkout") { tapCheckoutRemote(branch) }
            Button("New Branch from '\(branch.shortName)'…") {
                beginCreate(
                    from: .ref(branch),
                    defaultName: BranchSwitcherModel.defaultBranchName(forRemote: branch)
                )
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: rowIcon(for: branch))
                    .frame(width: 18)
                    .foregroundStyle(Color.secondary)
                Text(branch.shortName)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }

    private func rowIcon(for branch: BranchRef) -> String {
        if branch.isCurrent { return "checkmark" }
        return branch.isRemote ? "cloud" : "arrow.triangle.branch"
    }
}
#endif
