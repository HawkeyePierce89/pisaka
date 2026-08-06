#if os(iOS)
import SwiftUI
import PisakaCore

/// The SwiftUI content of a conflict-resolution route on iOS — the peer of the
/// macOS merge window (`MergeWindowController` + `MergeView`). iOS has no separate
/// windows, so this is shown as a sheet (presented by the owner). It wraps the
/// adaptive `MergeView_iOS` (three panes side by side on iPad, stacked on iPhone)
/// with a navigation bar carrying the resolution status and the gated "Apply"
/// button.
///
/// The `MergeModel` is built and `load`ed by the owner before presentation (so the
/// document is already loading when this appears); this view only observes it. The
/// `onApply` closure performs the guarded apply (write resolved text + stage, then
/// refresh Local Changes and resync any open tab — the owner does it because it owns
/// the workspace) and returns whether it succeeded; on success the route dismisses
/// itself via `onDone`.
struct MergeRoute_iOS: View {
    @ObservedObject var model: MergeModel
    @ObservedObject var settings: SettingsStore

    /// Performs the guarded apply; returns `true` on success (the route then closes).
    let onApply: () async -> Bool
    /// Dismisses this route.
    var onDone: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The conflict the control bar acts on (conflict order), shared with the panes.
    @State private var currentConflict = 0
    /// True while an apply is in flight, to disable the button and avoid re-entry.
    @State private var isApplying = false

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        MergeView_iOS(
            model: model,
            settings: settings,
            currentConflict: $currentConflict,
            isCompact: isCompact
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(settings.themePreference.colorScheme)
        .toolbar { toolbarContent }
    }

    private var title: String {
        guard let path = model.file?.path else { return "Resolve Conflict" }
        return "Resolve \((path as NSString).lastPathComponent)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel", action: onDone)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Apply") { apply() }
                .disabled(!model.isFullyResolved || isApplying)
        }
    }

    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        Task { @MainActor in
            let success = await onApply()
            isApplying = false
            if success { onDone() }
        }
    }
}
#endif
