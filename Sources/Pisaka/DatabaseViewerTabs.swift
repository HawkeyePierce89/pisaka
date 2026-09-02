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
/// and pragmas, and part 2's cell update goes into the database file, which is not
/// a worktree text file any gated operation is snapshotting. Nothing here may name
/// either gate call, and `DatabaseViewerSourceGatingTests` pins that.
///
/// It does, however, **consult** the gate, which is a different thing: a database
/// that git is about to rewrite is one an edit should not land in the middle of.
/// So this owner is handed the question — not the gate's own API — as a closure at
/// `start(isWriteBlocked:didWrite:)` and forwards it into every model it builds,
/// which is why no file under the viewer names `localChanges` at all. `didWrite`
/// is the other direction: a committed edit modifies a tracked file, and the
/// scene's generation-pinned Local Changes refresh is what makes the panel say so.
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

    /// Whether a worktree-mutating operation is in flight right now, asked at the
    /// moment an edit is attempted.
    ///
    /// Stored rather than passed at construction because the scene answers it out
    /// of a model this owner is built alongside (`PisakaApp.init` runs before any
    /// `@StateObject` the answer would have to read). Every model is built with a
    /// closure that hops through *this* property, so a model created before
    /// `start(isWriteBlocked:didWrite:)` still asks the real question afterwards —
    /// the ordering of `.onAppear` against the first tab selection decides nothing.
    private var isWriteBlocked: @MainActor () -> Bool = { false }

    /// What to run after a committed edit — the scene's Local Changes refresh.
    private var didWrite: @MainActor () -> Void = {}

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
        // Both closures read through `self` rather than capturing today's values,
        // so a tab shown before the scene wired them is not stuck with the
        // defaults. Weakly, because a model outliving this owner is a torn-down
        // window's tab: it then answers "nothing is in the way" and refuses
        // nothing, which is the same posture a model built in a test or a preview
        // takes.
        let model = DatabaseViewerModel(
            fileURL: url,
            service: makeService(),
            isWriteBlocked: { [weak self] in self?.isWriteBlocked() ?? false },
            didWrite: { [weak self] in self?.didWrite() }
        )
        models[file.id] = model
        return model
    }

    /// Wire the gate question and the post-write hook, once, from the scene.
    ///
    /// Idempotent and safe to call again: `.onAppear` can fire a second time for a
    /// reopened window, and both closures are answers to standing questions rather
    /// than subscriptions, so replacing them costs nothing.
    func start(
        isWriteBlocked: @escaping @MainActor () -> Bool,
        didWrite: @escaping @MainActor () -> Void
    ) {
        self.isWriteBlocked = isWriteBlocked
        self.didWrite = didWrite
    }

    /// Re-read the database behind tab `id` over a fresh connection.
    ///
    /// What the post-operation resyncs call for a viewer tab whose file is still
    /// there: git replaces a file by renaming a new one over it, so the tab's open
    /// connection would keep answering out of the unlinked old one. A tab that has
    /// never been shown has no model and no connection, so there is nothing stale
    /// to correct — it opens against the new file when it is first selected.
    ///
    /// `url` is the tab's url *now*, which is not always the one its model was
    /// built with: a rename retargets a viewer tab like any other, while the open
    /// connection goes on answering off the renamed inode, so this is the moment —
    /// and the only one — where the difference matters. Passing it through means
    /// the reconnect lands on the file the caller just confirmed is there.
    ///
    /// The hop is a `Task` because `reload(at:)` is `async` (it awaits the actor)
    /// while the resyncs that call this are synchronous.
    func reload(id: UUID, url: URL) {
        guard let model = models[id] else { return }
        Task { await model.reload(at: url) }
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
