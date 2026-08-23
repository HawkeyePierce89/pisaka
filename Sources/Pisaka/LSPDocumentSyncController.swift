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

    /// The in-flight sync work per file; a newer piece of work for the *same*
    /// file cancels the older one, so a burst of keystrokes flushes once —
    /// `SymbolIndexController.bufferTasks`' structure and reasoning verbatim.
    /// Each task removes its own entry when it finishes, so the dictionary is
    /// bounded by the number of files being typed in at once.
    private var bufferTasks: [URL: Task<Void, Never>] = [:]

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
    /// runs to completion and reports `noteSynced` (an evicted task records what
    /// its send really did); that is harmless, because a push for a URI no
    /// server holds is dropped at the workspace (D31) and the document clear has
    /// already emptied the store.
    func noteBufferClosed(url: URL) {
        bufferTasks.removeValue(forKey: url.standardizedFileURL)?.cancel()
    }

    /// Drop every pending debounce — what a folder change means.
    ///
    /// The model's cleared bookkeeping already discards whatever they would
    /// publish; cancelling here just avoids doing the work first. Call it in the
    /// same main-actor turn as `prepareForFolderChange(root:)`.
    func reset() {
        for task in bufferTasks.values { task.cancel() }
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
        bufferTasks.removeValue(forKey: key)?.cancel()
        let interval = bufferDebounce
        bufferTasks[key] = Task { [weak self, model, workspace] in
            if !immediate {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
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
            // An evicted task still reports. Cancellation stops the *report*,
            // never the bytes: a task already inside `prepare` when its
            // replacement scheduled sends its notification to completion, and
            // skipping the report is what would make that harmful. The newer
            // sibling can flush after it — both released from one launch wait
            // resume in unspecified order — leaving the server holding this
            // task's older text at a *higher* version than any record names.
            // Every later push then matches the workspace's own bookkeeping and
            // reaches the model, where the missing report misjudges it: a
            // versioned set is stranded in the hold, an unversioned one — most
            // servers — is accepted against offsets it does not describe, with
            // no settling sync left to correct either. Recording anyway keeps
            // the record truthful about what the server holds, and the stale
            // revision pin turns the outcome into D32's sanctioned trade:
            // rejected until the next debounce re-syncs.
            if let prepared {
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
