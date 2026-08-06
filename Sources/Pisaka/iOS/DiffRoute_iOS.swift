#if os(iOS)
import SwiftUI
import PisakaCore

/// The SwiftUI content of a diff route on iOS — the peer of the macOS
/// `DiffWindowContent`. iOS has no separate windows, so this is shown either as a
/// modal sheet (regular width — iPad) or pushed onto the navigation stack (compact
/// width — iPhone), per `RoutePresentation.preferred(isCompactWidth:)`.
///
/// Independent of the main selection: it is handed a `load` closure that produces
/// the side-by-side `[DiffRow]` for *this* file (binding `LocalChangesModel.rows`),
/// so the view stays model-agnostic. Shows "Loading…" until the async load resolves
/// (the libgit2 service reads `HEAD` + the working copy off the main thread), then
/// renders the read-only `DiffView_iOS`. The load is guarded by a `@State`
/// generation token so a stale result can never land.
struct DiffRoute_iOS: View {
    /// Identity of the file being diffed (its `ChangedFile.id`/repo-relative path).
    let fileID: String

    /// The file's name (last path component); selects the syntax language.
    let fileName: String

    /// Produces the aligned side-by-side rows asynchronously.
    let load: () async -> [DiffRow]

    /// Shared user preferences, observed so the diff's font tracks the editor font
    /// size and a forced theme reaches this surface.
    @ObservedObject var settings: SettingsStore

    @State private var rows: [DiffRow] = []
    @State private var isLoaded = false
    /// Monotonic token identifying the latest load; only the latest may assign.
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if isLoaded {
                DiffView_iOS(
                    fileID: fileID,
                    fileName: fileName,
                    rows: rows,
                    fontSize: settings.fontSize
                )
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(settings.themePreference.colorScheme)
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
