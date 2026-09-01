#if os(macOS)
import Combine
import Foundation
import PisakaCore

/// Who owns a viewer tab's connection, and for exactly how long.
///
/// One `DatabaseViewerModel` per viewer tab, keyed by the tab's id, created the
/// first time that tab is shown and released when the tab goes away. The model
/// holds a `DatabaseConnectionService`, and a connection is one file, so "one
/// model per tab" and "one connection per open database" are the same sentence.
/// Re-selecting a tab hands back the model it already had — with its selected
/// table, its page and its sort intact, which is the whole reason this state does
/// not live in the view.
///
/// **A whole file of its own on purpose.** `PisakaApp.swift` sits exactly at its
/// measured `file_length` ceiling with `type_body_length` one behind it, and
/// `.swiftlint.yml` says in as many words that the number is not a licence to
/// grow. Per-tab lifetime is state with a shape, not scene wiring, so it lands
/// here and `PisakaApp` gains a `@StateObject` and nothing else.
///
/// **The reader boundary.** The viewer neither raises the disk-writer gate
/// (`autosave.suspend()` / `localChanges.beginRevert()`) nor waits on it — the
/// terminal's and the symbol index's position. Part 1 sends nothing but `SELECT`s
/// and pragmas, and even part 2's writes will go into the database file, which is
/// not a worktree text file any gated operation is snapshotting. Nothing here may
/// name either gate call, and `DatabaseViewerSourceGatingTests` pins that.
///
/// **Tab close is observed, not called.** The owner subscribes to the workspace's
/// `openFiles` and closes the connection of any tab that is no longer there,
/// rather than asking `PisakaApp.closeFile(id:)` to remember to tell it. A tab can
/// leave through the close button, ⌘W, a force-close after a checkout, or a
/// folder switch that replaces the whole tab set; one subscription covers all
/// four, where four call sites would eventually be three.
@MainActor
final class DatabaseViewerTabs: ObservableObject {

    /// The live models, keyed by tab id.
    ///
    /// Not `@Published`: the views observe the *model* they were handed, and a
    /// republish here would re-render the window every time a tab opened or
    /// closed for no visible change. Nothing outside this type reads the table at
    /// all — a tab asks for its own model and gets it.
    private var models: [UUID: DatabaseViewerModel] = [:]

    /// How a connection is made. Injected so a future test — or a preview — can
    /// hand over something that is not SQLite; the app always passes the real one.
    private let makeService: () -> DatabaseServicing

    private var openFilesObserver: AnyCancellable?

    /// - Parameters:
    ///   - workspace: the tab set to follow. Held **weakly** through the
    ///     subscription alone, so this owner never keeps a torn-down workspace
    ///     alive; `nil` (previews, tests) simply follows nothing.
    ///   - makeService: how to build a connection for a new tab.
    init(
        workspace: WorkspaceModel? = nil,
        makeService: @escaping () -> DatabaseServicing = { DatabaseConnectionService() }
    ) {
        self.makeService = makeService
        guard let workspace else { return }
        openFilesObserver = workspace.$openFiles
            .sink { [weak self] files in
                // `@Published` fires *before* the property is written, so the
                // incoming value is the new tab set and `workspace.openFiles` is
                // still the old one — which is why the closure reads its argument
                // and never the model.
                self?.retainTabs(Set(files.map(\.id)))
            }
    }

    /// The model showing `file`, creating it on the first selection and handing
    /// back the same one on every selection after that.
    ///
    /// Returns `nil` for anything that is not a viewer tab with a url, which is a
    /// combination `WorkspaceModel` cannot produce — a viewer tab always has one
    /// — so the caller may treat it as "not a database tab" rather than as a
    /// failure.
    func model(for file: OpenFile) -> DatabaseViewerModel? {
        guard file.kind == .viewer, let url = file.url else { return nil }
        if let existing = models[file.id] { return existing }
        let model = DatabaseViewerModel(fileURL: url, service: makeService())
        models[file.id] = model
        return model
    }

    /// Drop every model whose tab is no longer open, closing its connection.
    ///
    /// The connection is released in a detached `Task` because `close()` is
    /// `async` (it awaits the actor) while this runs synchronously inside the
    /// publisher's `sink`. The model is removed from the table *first*, so a
    /// re-open of the same file — which gets a new tab id anyway — can never find
    /// the closing one.
    private func retainTabs(_ ids: Set<UUID>) {
        let departed = models.keys.filter { !ids.contains($0) }
        for id in departed {
            guard let model = models.removeValue(forKey: id) else { continue }
            Task { await model.close() }
        }
    }

    /// Close every connection — what termination calls.
    ///
    /// It drops the models synchronously and asks each one to close on a `Task`,
    /// which at termination is **best effort and said to be**: this runs from
    /// `NSApplication.willTerminateNotification`, the last notification AppKit
    /// posts, so there may be no further run-loop turn for the hop to be picked
    /// up in. That is acceptable here and would not be for a writer — part 1
    /// holds read-only connections with nothing unflushed, and process exit
    /// closes the descriptors either way. What the call does buy is the
    /// non-terminating path (a folder switch that empties the window, a future
    /// caller) releasing everything at a point where the hop certainly runs.
    ///
    /// `DatabaseViewerModel.close()` latches, so a connection is released at most
    /// once however this is reached: the tab may already have gone through
    /// `retainTabs(_:)` above.
    func closeAll() {
        let closing = models.values
        models.removeAll()
        for model in closing {
            Task { await model.close() }
        }
    }
}
#endif
