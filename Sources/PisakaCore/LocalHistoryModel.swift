import Foundation

/// The app-facing half of Local History's capture side: the long-lived object
/// the app holds for the whole session, which turns "these buffers were just
/// saved" and "this operation is about to rewrite the worktree" into store
/// calls, off the main actor and in order.
///
/// It owns three things and no state anyone observes: the `LocalHistoryStore`
/// (built over the base directory the app supplies — Core never names
/// `~/Library/Application Support`), the private serial queue every ordinary
/// capture runs on, and the **write chain**.
///
/// **The chain is what makes two captures of one file safe.** Every capture is
/// list → decide → write, and the listing is what supplies the hash the dedup
/// compares against; two of those interleaved would each see the state before
/// the other and store the same bytes twice. So each unit of work is *appended*
/// to a single `Task` chain — a new task that first awaits its predecessor —
/// rather than started independently. The chain is per-model, not per-file:
/// captures are rare, small and already off the main actor, and one lane is
/// cheaper to reason about than a map of them.
///
/// **This model is a reader of the user's files and a writer only of its own
/// store.** It never mutates a buffer, never touches the worktree, and therefore
/// never raises `autosave.suspend()` / `localChanges.beginRevert()` and is never
/// gated by them — the symbol index's rule, for the same reason. What it does
/// take from the gated operations is *timing*: see
/// `captureBeforeOperation(event:root:bufferTexts:diskTargets:)`.
///
/// **Every failure is silent**, all the way down: the store degrades, an
/// unreadable or binary target is skipped, a url outside the project root is
/// skipped. There is nothing a user could usefully be asked here.
///
/// It publishes nothing and is deliberately **not** an `ObservableObject`: the
/// app holds it as a plain stored `let` so no view can observe it, and a window
/// that did would re-render on captures it does not show.
@MainActor
public final class LocalHistoryModel {
    /// The store every entry point here goes through. Public because the browser
    /// model and the window read revisions through the very same value — one
    /// store, one layout, one policy, however many readers.
    public let store: LocalHistoryStore

    /// The reads the pre-operation capture does on its own (the store is handed
    /// text, never a url to read).
    private let fileService: FileServicing

    /// Now, injectable. The store already takes its timestamps as parameters so
    /// retention is a pure function of its inputs; this is the same seam one
    /// level up, and it is what lets a test give two overlapping captures two
    /// distinct milliseconds instead of racing the clock.
    ///
    /// The stated limit of *not* having it in production: two captures of one
    /// file landing inside the same millisecond order by file name (i.e. by
    /// content hash) rather than chronologically, because that is all the name
    /// preserves. Reachable only for two *different* texts of one file written
    /// within a millisecond of each other, and it costs a row's position in a
    /// list, never a wrong or missing revision.
    private let clock: () -> Date

    /// Where every ordinary capture's disk work runs. Serial, utility QoS — the
    /// `SymbolIndexModel` arrangement: the model stays `@MainActor` and no file
    /// I/O ever lands on the main thread. Except once; see
    /// `captureSavesSynchronously(urls:root:texts:)`.
    private let queue = DispatchQueue(label: "ws.karmanov.pisaka.local-history", qos: .utility)

    /// The tail of the write chain. Internal rather than private so the tests can
    /// await the fire-and-forget paths causally instead of sleeping.
    private(set) var chain: Task<Void, Never>?

    public init(
        base: URL,
        fileService: FileServicing,
        policy: LocalHistoryPolicy = LocalHistoryPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = LocalHistoryStore(
            layout: LocalHistoryLayout(base: base),
            fileService: fileService,
            policy: policy
        )
        self.fileService = fileService
        self.clock = now
    }

    // MARK: - Saves

    /// Capture the buffers the app has just written to disk.
    ///
    /// Fire-and-forget: a save must not wait on a safety net. `urls` is the
    /// *order* the snapshots are taken in and `texts` the contents — a url with
    /// no entry in `texts` is skipped rather than read back from disk, because
    /// the text the app just wrote is the text that belongs in history and
    /// re-reading it would race the next edit.
    ///
    /// Post-write on purpose (the design's note): a pre-write capture would store
    /// bytes a failed write never landed, and the content here is already
    /// post-`SaveTransform`, because that funnel runs before every write on every
    /// path.
    public func captureSaves(urls: [URL], root: URL?, texts: [URL: String]) {
        captureBuffers(event: .save, urls: urls, root: root, texts: texts)
    }

    /// The general form of `captureSaves(urls:root:texts:)`: capture buffer text
    /// under any label.
    ///
    /// The one other caller is Restore, which snapshots the buffer it is about to
    /// overwrite under `.restore` so a restore is itself reversible from history
    /// as well as by one ⌘Z.
    public func captureBuffers(event: LocalHistoryEvent, urls: [URL], root: URL?, texts: [URL: String]) {
        let units = Self.bufferUnits(urls: urls, root: root, texts: texts)
        guard !units.isEmpty, let root else { return }
        let store = self.store
        let clock = self.clock
        append {
            Self.write(units, to: store, root: root, event: event, clock: clock)
        }
    }

    /// The quit path: capture the same buffers **inline, on the main actor**, so
    /// the bytes are handed to the kernel before this returns.
    ///
    /// The one place in this feature that does disk work on the main thread, and
    /// it is deliberate. `willTerminateNotification` runs on the main thread and
    /// the process exits when the observer returns, so a `Task` hop is not
    /// guaranteed to run *at all* — the last save before a quit, which is exactly
    /// the edit a safety net is for, would be the one that never lands.
    /// `FileServicing.write` is synchronous and throwing, so calling the same
    /// store methods here is both possible and sufficient.
    ///
    /// The cost is bounded and paid once per quit: at most one directory read
    /// plus one ≤1 MiB write per dirty titled buffer, and dedup usually makes it
    /// zero writes.
    ///
    /// It **bypasses the chain**, which cannot deadlock it and cannot be waited
    /// on: whatever is still queued there is about to be discarded with the
    /// process. The worst case is one snapshot written twice — never a corrupt
    /// one, because a snapshot appears in one `move` — and a later identical
    /// capture would have deduplicated it anyway.
    public func captureSavesSynchronously(urls: [URL], root: URL?, texts: [URL: String]) {
        let units = Self.bufferUnits(urls: urls, root: root, texts: texts)
        guard !units.isEmpty, let root else { return }
        Self.write(units, to: store, root: root, event: .save, clock: clock)
    }

    // MARK: - Before a worktree operation

    /// Capture everything one gated operation is about to overwrite, and return
    /// only when it is stored.
    ///
    /// **Awaited, and that is what makes it race-free.** Each of the six gated
    /// operations raises its writer bracket synchronously before its `Task` hop
    /// and collects `bufferTexts`/`diskTargets` in that same synchronous stretch
    /// (the shape `openTabSnapshot()` already has); this call is then the *first*
    /// `await` in the task body, ahead of the operation's own. Every byte stored
    /// here is therefore pre-operation by construction — no clock, no ordering
    /// argument, no gate of its own.
    ///
    /// Three rules decide what is read:
    ///
    /// - **Buffers win.** A file with an open tab is captured from its buffer and
    ///   *not* read from disk, so one operation never leaves two same-labelled
    ///   snapshots of one file — and the buffer is what the user would lose.
    /// - **Binary and oversize files are skipped**, by
    ///   `readTextIfNotBinary(url:maxBytes:)`, which is the one gate for both.
    /// - **The disk set is capped** at `LocalHistoryPolicy.maxPreOperationFiles`,
    ///   a stated limit: this runs in front of a git command the user asked for,
    ///   so a worktree with thousands of changed files must not put an unbounded
    ///   read pass between the click and the operation. Buffers are never capped.
    ///
    /// **Nothing to capture returns without touching the chain.** The wait is on
    /// everything already queued — including the project-open retention sweep —
    /// and paying it to store zero bytes would put this feature's housekeeping in
    /// front of an operation the user asked for, with the writer bracket already
    /// raised.
    public func captureBeforeOperation(
        event: LocalHistoryEvent,
        root: URL?,
        bufferTexts: [URL: String],
        diskTargets: [URL]
    ) async {
        guard let root else { return }
        let units = Self.bufferUnits(urls: bufferTexts.keys.sorted { $0.path < $1.path }, root: root, texts: bufferTexts)

        var claimed = Set(units.map(\.relativePath))
        var pending: [(relativePath: String, url: URL)] = []
        for url in diskTargets {
            guard pending.count < store.policy.maxPreOperationFiles else { break }
            guard let relativePath = Self.relativePath(of: url, under: root) else { continue }
            guard claimed.insert(relativePath).inserted else { continue }
            pending.append((relativePath: relativePath, url: url))
        }
        guard !units.isEmpty || !pending.isEmpty else { return }

        let store = self.store
        let clock = self.clock
        let fileService = self.fileService
        let maxBytes = store.policy.maxContentBytes
        await append {
            Self.write(units, to: store, root: root, event: event, clock: clock)
            for target in pending {
                guard let text = try? fileService.readTextIfNotBinary(
                    url: target.url,
                    maxBytes: maxBytes
                ) else { continue }
                store.capture(
                    text: text,
                    root: root,
                    relativePath: target.relativePath,
                    event: event,
                    now: clock()
                )
            }
        }.value
    }

    // MARK: - Retention

    /// Apply retention to a whole project's area — the once-per-project-open
    /// sweep, fire-and-forget on the chain.
    ///
    /// Capture already prunes the one file it just wrote; this is what reclaims
    /// the history of files nobody has touched since their revisions aged out.
    public func pruneProject(root: URL?) {
        guard let root else { return }
        let store = self.store
        let clock = self.clock
        append { store.prune(root: root, now: clock()) }
    }

    // MARK: - The chain

    /// Append one unit of work to the serial chain and answer the task that will
    /// have finished it.
    ///
    /// Two guarantees in four lines: the new task awaits its predecessor before
    /// it starts (so no two units ever run at once, which is what the dedup read
    /// needs), and the body runs on the private queue (so no file I/O lands on
    /// the main thread). Nothing here captures `self` — the work already holds
    /// the store it needs — so a model released mid-flight still finishes what it
    /// promised rather than dropping a revision.
    @discardableResult
    private func append(_ work: @escaping () -> Void) -> Task<Void, Never> {
        let previous = chain
        let queue = self.queue
        let task = Task {
            await previous?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    work()
                    continuation.resume()
                }
            }
        }
        chain = task
        return task
    }

    // MARK: - Pure helpers

    /// One buffer to capture: where it goes in the store, and the text already in
    /// hand. A disk target is *not* one of these — it is a `(relativePath, url)`
    /// pair whose text does not exist until it is read, on the chain, one hop
    /// later.
    private struct CaptureUnit {
        let relativePath: String
        let text: String
    }

    /// The buffers of `urls` that can be keyed in the store, in the given order
    /// and without duplicates.
    ///
    /// A url with no text, a url outside the project root, and a second url
    /// keying to a path already claimed are all dropped — silently, like every
    /// other refusal in this feature. The remaining skip rules (size, sameness)
    /// belong to `LocalHistoryPolicy` and are asked once, inside the store.
    private nonisolated static func bufferUnits(
        urls: some Sequence<URL>,
        root: URL?,
        texts: [URL: String]
    ) -> [CaptureUnit] {
        guard let root else { return [] }
        var claimed = Set<String>()
        var units: [CaptureUnit] = []
        for url in urls {
            guard let text = texts[url] else { continue }
            guard let relativePath = relativePath(of: url, under: root) else { continue }
            guard claimed.insert(relativePath).inserted else { continue }
            units.append(CaptureUnit(relativePath: relativePath, text: text))
        }
        return units
    }

    private nonisolated static func write(
        _ units: [CaptureUnit],
        to store: LocalHistoryStore,
        root: URL,
        event: LocalHistoryEvent,
        clock: () -> Date
    ) {
        for unit in units {
            store.capture(
                text: unit.text,
                root: root,
                relativePath: unit.relativePath,
                event: event,
                now: clock()
            )
        }
    }

    /// `url`'s path under `root`, or `nil` when it is not a file under `root`.
    ///
    /// Two questions, both of which must answer yes.
    /// `LSPInstallLayout.directory(_:contains:)` is the containment rule — the
    /// one lexical one this feature asks everywhere, reused rather than restated
    /// — and `ProjectFileWalk.relativePath(of:under:)` is the one relative-path
    /// helper. The second is not the first restated: it *degrades* an unexpected
    /// url to its bare file name rather than refusing, so what is checked
    /// afterwards is that it did not degrade — `root` re-joined to the answer
    /// must spell `url` again. Without that check a url reaching the root through
    /// `..` would be keyed under its bare name and share a history with the file
    /// that genuinely has that name.
    ///
    /// Internal rather than private because `LocalHistoryBrowserModel` must key a
    /// file *exactly* as this side did — a second, separately maintained copy of
    /// this rule would show an empty history for a file that has one — and one
    /// function is the only way to say that and mean it.
    nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
        guard LSPInstallLayout.directory(root, contains: url) else { return nil }
        let relative = ProjectFileWalk.relativePath(of: url, under: root)
        guard !relative.isEmpty, root.appendingPathComponent(relative).path == url.path else { return nil }
        return relative
    }
}
