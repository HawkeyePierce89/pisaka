#if os(macOS)
import Foundation
import PisakaCore

/// Schedules the diagnostics channel's one unprompted act (D30): flushing every
/// open buffer of a served language to its language server, so a push-only
/// channel (`textDocument/publishDiagnostics`) has something to answer. D2's
/// sync is request-driven; diagnostics are not requested by anything, so
/// without this the server never re-diagnoses after an edit.
///
/// Lives beside `SymbolIndexController`'s exact idiom — an `@MainActor` map of
/// per-URL cancellable `Task`s over a `BracketHighlightController`-shaped
/// debounce — because it is that class's analogue for the LSP sync: thin glue
/// that decides only *when*, with every decision about *what* a sync means
/// living in Core (`LSPWorkspace.prepare`, `DiagnosticsModel`'s acceptance
/// gate) and tested there. Untested view-layer code like the rest of
/// `Sources/Pisaka`.
///
/// **One debounce, 400 ms**, deliberately the symbol index's length: both
/// readers fire from the same triggers and their costs are the same shape —
/// one whole-file notification per settled burst per edited file, exactly what
/// D30 sanctioned. A tab open or switch bypasses it: the file the user is
/// looking at must be diagnosed before they finish reading it, and a switch is
/// not a burst.
///
/// macOS-gated because its only consumers are (`CodeEditorView`, `PisakaApp`);
/// there is no iOS diagnostics UI.
@MainActor
final class LSPDocumentSyncController {
    /// The model whose acceptance gate the reported syncs feed. Held strongly —
    /// the app owns both, like `SymbolIndexController` holds its model.
    private let model: DiagnosticsModel

    /// The workspace the flush goes through. `prepare(url:language:text:)` is
    /// the whole of it: launch coalescing, the root check, D7's unavailability
    /// gate and D2's didOpen/didChange/no-op machinery are already inside, so
    /// this controller adds a trigger, not a second code path.
    private let workspace: LSPWorkspace

    /// One scheduled flush, boxed so the task can read the verdict its own
    /// eviction writes.
    ///
    /// A reference type rather than a per-URL counter deliberately: the flag has
    /// to outlive nothing but its own map entry, while a counter would have to
    /// survive every close forever to still be read correctly by a task that
    /// pinned it — the unbounded map this flag exists to prevent.
    private final class Schedule {
        /// Assigned by `schedule` immediately after the task is created, which
        /// is before the body can run: `schedule` never suspends, so the first
        /// hop the body takes is after this store.
        var task: Task<Void, Never>?

        /// Set by `noteBufferClosed`/`reset()` — the two paths that drop a
        /// schedule *outright* — and never by an ordinary eviction, whose
        /// successor chains on this task and needs its report to land first.
        /// A discarded task reports nothing: the model has been told to forget
        /// the document, so there is no record left for a report to keep
        /// truthful (see the report site).
        var isDiscarded = false
    }

    /// The in-flight sync work per file; a newer piece of work for the *same*
    /// file cancels the older one and chains on its completion — a burst
    /// flushes once, and the reports cannot reorder (see `schedule`). Each task
    /// removes its own entry when it finishes uncancelled, so the dictionary is
    /// bounded by the number of files being typed in at once.
    private var bufferTasks: [URL: Schedule] = [:]

    private let bufferDebounce: Duration = .milliseconds(400)

    init(model: DiagnosticsModel, workspace: LSPWorkspace) {
        self.model = model
        self.workspace = workspace
    }

    // MARK: - Buffers

    /// The buffer for `url` changed: flush it once the typing settles.
    ///
    /// Same optional-language shape as the index controller's, so callers hand
    /// over the editor's own without branching; an unserved language is dropped
    /// here rather than costing a task whose `prepare` would answer `nil`. The
    /// gate is `canServe` — policy only, nothing is started by asking it — so a
    /// consent-pending or unavailable server simply schedules nothing, silently,
    /// and a registry change is picked up on the next trigger.
    func noteBufferChanged(url: URL, text: String, language: SyntaxLanguage?) {
        schedule(url: url, text: text, language: language, immediate: false)
    }

    /// A tab was opened or switched to: flush it **now**.
    ///
    /// Supersedes a pending debounced flush *of this same file* only — the file
    /// being switched away from keeps its debounce, which is the one chance its
    /// last keystrokes have of reaching the server.
    func noteBufferOpened(url: URL, text: String, language: SyntaxLanguage?) {
        schedule(url: url, text: text, language: language, immediate: true)
    }

    /// A tab was closed: take out this file's in-flight flush.
    ///
    /// Cancelling is all the close needs here — telling the *server* is
    /// `lspWorkspace.didClose(url:)`'s job, fired beside this call from the same
    /// app-side guard. A sync still inside its `prepare` when the cancel lands
    /// runs its send to completion, but the discard marks its report dead: the
    /// same guard has already told the model to forget the document
    /// (`DiagnosticsModel.noteDocumentClosed`), and a report landing after that
    /// would re-create the sync record the close just pruned — leaving a
    /// document no tab shows in the model's maps, and gating the file's *next*
    /// life against its predecessor's version instead of from zero.
    func noteBufferClosed(url: URL) {
        let schedule = bufferTasks.removeValue(forKey: url.standardizedFileURL)
        schedule?.isDiscarded = true
        schedule?.task?.cancel()
    }

    /// Drop every pending debounce — what a folder change means.
    ///
    /// The model's cleared bookkeeping already discards whatever they would
    /// publish; cancelling here just avoids doing the work first. Call it in the
    /// same main-actor turn as `prepareForFolderChange(root:)`.
    func reset() {
        for schedule in bufferTasks.values {
            schedule.isDiscarded = true
            schedule.task?.cancel()
        }
        bufferTasks.removeAll()
    }

    // MARK: - Scheduling

    private func schedule(url: URL, text: String, language: SyntaxLanguage?, immediate: Bool) {
        guard let language, workspace.canServe(language) else { return }

        // Pin the model's revision **synchronously, before the hop** — the
        // generation-token rule. Reported verbatim on success, so a sync that
        // raced a keystroke records the old revision and the acceptance gate
        // rejects its pushes until the next debounce re-syncs (D32's
        // self-correction; never replayed, never drifted).
        let revision = model.currentRevision(for: url)

        let key = url.standardizedFileURL
        // Captured before eviction so the replacement can wait out the task it
        // supersedes — see the body comment for why that ordering is load-bearing.
        let predecessor = bufferTasks[key]
        predecessor?.task?.cancel()
        let interval = bufferDebounce
        let schedule = Schedule()
        bufferTasks[key] = schedule
        schedule.task = Task { [weak self, model, workspace, predecessor, schedule] in
            if Task.isCancelled { return }
            if !immediate {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            // Wait out the evicted task *to completion*, report included, before
            // preparing. Both tasks are released from the same shared awaits
            // (the per-document flush wait chief among them) in unspecified
            // order, so without this their `noteSynced` reports could land
            // newest-pin-first: the record would then name the evicted task's
            // older pin while `currentRevision` has moved past it, and with no
            // further trigger scheduled — a wholesale rewrite of the displayed
            // tab is exactly two such schedules and nothing after — every later
            // push fails the acceptance gate's revision half and strands the
            // document blank until the user touches it. Chaining makes the order
            // deterministic instead: the older report lands first, the newer
            // overwrites it, and the final record is always the last sender's.
            await predecessor?.task?.value
            if Task.isCancelled { return }
            // One prepare call, no follow-up request — forced, because the sync
            // is the channel's whole supply: a completion/hover/definition flush
            // may already have delivered this exact text (its push then died at
            // the gate, version moved past the record), and an unforced landing
            // here would send nothing for a push-only server to answer. The
            // forced republish is what makes D32's self-correction unconditional.
            // A `nil` answer — no server, unavailable, outside the root, folder
            // moved, pipe gone — does nothing at all, silently: D7's fallback
            // discipline applies to this layer's one unprompted act too.
            let prepared = await workspace.prepare(
                url: url,
                language: language,
                text: text,
                forceFlush: true
            )
            guard let self else { return }
            // An *evicted* task still reports, and the report is deliberately
            // not cancellation-gated for it: the chaining above orders two
            // schedules of the same file, and skipping the older one's record
            // would leave the bookkeeping describing less than what the server
            // provably holds. The stale revision pin turns any mismatch into
            // D32's sanctioned trade — rejected until the next trigger
            // re-syncs.
            //
            // A *discarded* task is the other half, and it is not the same
            // case. `noteBufferClosed` and `reset()` carry no successor, and
            // both run beside a model call that forgets the document outright
            // (`noteDocumentClosed`, `prepareForFolderChange`): there is no
            // record left for a report to keep truthful, so a report here would
            // only re-create one — an entry for a document no tab shows, which
            // nothing prunes again, and which gates the file's next life
            // against this one's version rather than from zero. Silence is what
            // keeps the model's maps bounded by the open tabs.
            if let prepared, !schedule.isDiscarded {
                model.noteSynced(url: url, version: prepared.version, revision: revision)
            }
            guard !Task.isCancelled else { return }
            // Past this point only an uncancelled task arrives, and every
            // replacement cancels the task it evicts — so this is still the
            // entry's owner, and clearing it cannot drop the replacement's.
            self.bufferTasks[key] = nil
        }
    }
}

#endif
