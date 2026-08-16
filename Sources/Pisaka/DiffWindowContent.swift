#if os(macOS)
import SwiftUI
import PisakaCore

/// The SwiftUI content of a separate diff window (opened on double-click of a Local
/// Changes row or a commit's file). Independent of the main window's selection: it
/// is handed a `load` closure that produces the side-by-side `[DiffRow]` for *this*
/// file (e.g. `LocalChangesModel.rows(for:)` or `CommitLogModel.rows(for:in:)`),
/// so the view stays model-agnostic — the owner binds the model and arguments into
/// the closure.
///
/// Shows "Loading…" until the async load resolves (the row methods shell out to
/// `git show`), then renders the read-only `DiffView`. The load is guarded by a
/// `@State` generation token, mirroring `DiffPane`/`CommitDiffPane`, so a stale
/// result can never land — though in practice a diff window's `(fileID, load)` is
/// fixed for its lifetime, the token keeps the single in-flight load honest.
struct DiffWindowContent: View {
    /// Identity of the file being diffed (its `ChangedFile.id`/repo-relative path).
    let fileID: String

    /// The file's name (last path component); selects the syntax language.
    let fileName: String

    /// Produces the aligned side-by-side rows asynchronously.
    let load: () async -> [DiffRow]

    /// Shared user preferences, observed so the separate diff window's font
    /// updates live when the editor font size changes (Stepper or Cmd+scroll).
    @ObservedObject var settings: SettingsStore

    @State private var rows: [DiffRow] = []
    @State private var isLoaded = false
    /// Monotonic token identifying the latest load; only the latest may assign.
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if isLoaded {
                DiffView(
                    fileID: fileID,
                    fileName: fileName,
                    rows: rows,
                    fontSize: settings.fontSize
                )
            } else {
                Text("Loading…")
                    .font(settings.interfaceMetrics.scaledFont(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Apply the theme preference here too, so a forced Light/Dark reaches this
        // separate window's hosted AppKit content (the main window does the same on
        // its root). The shared font size already propagates via `settings`.
        .preferredColorScheme(settings.themePreference.colorScheme)
        // Its own SwiftUI root (an `NSHostingController` made by
        // `DiffWindowController`), so it injects the interface scale itself. The
        // diff panes themselves stay on `settings.fontSize` — the code zone.
        .interfaceScaled(settings)
        .onAppear(perform: reload)
    }

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        Task { @MainActor in
            let computed = await load()
            guard generation == loadGeneration else { return }
            rows = computed
            isLoaded = true
        }
    }
}

#endif
