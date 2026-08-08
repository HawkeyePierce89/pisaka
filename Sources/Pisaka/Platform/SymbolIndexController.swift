#if os(macOS) || os(iOS)
import Foundation
import PisakaCore

/// Schedules the symbol index's incremental work: the buffer re-index behind a
/// keystroke debounce, and the project refresh behind an FSEvents debounce.
///
/// Lives in the non-gated `Platform/` layer because both destinations drive both
/// halves. The project refresh is *watcher*-driven only on macOS; iOS has none, so
/// there it is driven by the working-tree rewrites the app performs itself (revert,
/// merge apply, checkout — see `RootView_iOS.notifyIndexOfProjectFileChanges`), and
/// a genuinely external change stays uncovered rather than worked around.
///
/// Thin glue by design: every decision about *what* the index does on a re-index
/// or a refresh — generations, stamp gating, buffer-over-disk precedence — lives
/// in `SymbolIndexModel` and is tested there. This class decides only *when*, and
/// is therefore untested view-layer code like the rest of `Sources/Pisaka`.
///
/// **Two debounces, deliberately different lengths**, both the
/// `BracketHighlightController` idiom (a cancellable `Task.sleep`, superseded by
/// the next call):
/// - **400 ms for a buffer edit.** Longer than the bracket scan's 100 ms or the
///   minimap's 150 ms, because this one re-parses the whole file *and* republishes
///   the index; the payoff is a completion list one word behind, which nobody
///   sees, versus a full parse per keystroke, which everybody feels.
/// - **500 ms for the watcher**, on top of the 1 s coalescing `ProjectWatcher`
///   already applies. A refresh walks the whole project (cheaply — it re-extracts
///   only what changed), and a build or an `npm i` produces bursts that outlive
///   the watcher's own window.
///
/// A tab open or switch bypasses the debounce entirely: the file the user is
/// looking at must have symbols before they finish reading it, and a tab switch
/// is not a burst.
@MainActor
final class SymbolIndexController {
    /// The index this controller drives. Held strongly — the app owns both, and
    /// the controller's whole purpose is to outlive individual editor views.
    private let model: SymbolIndexModel

    /// The in-flight buffer re-index **per file**; a newer re-index of the *same*
    /// file cancels the older one, so a burst of keystrokes re-parses once.
    ///
    /// Keyed rather than a single slot, because the two are not interchangeable:
    /// a tab switch re-indexes the incoming file immediately, and with one slot
    /// that call would cancel the outgoing file's still-sleeping debounce — the
    /// only thing that would ever publish those keystrokes. Nothing else picks
    /// them up: the file is already buffer-sourced, so a refresh neither
    /// re-extracts nor removes it, and the entry would stay frozen at its last
    /// parse until the tab was re-selected or closed.
    ///
    /// Each task removes its own entry when it finishes, so the dictionary is
    /// bounded by the number of files being typed in at once — in practice one.
    ///
    /// Keys are standardized rather than canonical: every caller hands over the
    /// URL its tab already holds, and `SymbolIndex.fileKey(for:)` resolves
    /// symlinks — a file-system round trip this would pay on the main actor on
    /// every keystroke, to distinguish spellings no tab produces.
    private var bufferTasks: [URL: Task<Void, Never>] = [:]

    /// The in-flight project refresh; cancelled the same way, so an FSEvents burst
    /// re-walks once.
    private var refreshTask: Task<Void, Never>?

    private let bufferDebounce: Duration = .milliseconds(400)
    private let refreshDebounce: Duration = .milliseconds(500)

    init(model: SymbolIndexModel) {
        self.model = model
    }

    /// The seam the editor surfaces ask their questions through.
    ///
    /// Exposed here rather than handing the *model* to the views: the views hold
    /// this controller already (it is what they tell about a keystroke), the model
    /// republishes after every chunk of a walk and so must stay off their update
    /// path, and a view that could reach the model could also drive the index —
    /// which is this class's job. Reading the property each time is deliberate:
    /// the provider reads the model's latest snapshot on demand, so no caller can
    /// end up answering from the state a folder was opened in.
    var provider: CodeIntelligenceProviding { model.provider }

    // MARK: - Buffers

    /// The buffer for `url` changed: re-index it once the typing settles.
    ///
    /// `language` is optional so callers can hand over the editor's own
    /// (`nil` for an untitled or unrecognized file) without branching; an
    /// unindexable one is dropped here rather than costing a `Task` that the model
    /// would then discard.
    func noteBufferChanged(url: URL, text: String, language: SyntaxLanguage?) {
        schedule(url: url, text: text, language: language, immediate: false)
    }

    /// A tab was opened or switched to: re-index it **now**.
    ///
    /// Same call, no debounce — see the type's note. It supersedes a pending
    /// keystroke re-index *of this same file* only; the file being switched away
    /// from keeps its debounce, which is the one chance its last keystrokes have
    /// of reaching the index (see `bufferTasks`).
    func noteBufferOpened(url: URL, text: String, language: SyntaxLanguage?) {
        schedule(url: url, text: text, language: language, immediate: true)
    }

    /// A tab was closed: hand its entry back to disk.
    ///
    /// A passthrough, but the one the debounce has to respect — so it cancels
    /// this file's in-flight re-index first, which would otherwise re-mark it
    /// buffer-sourced right after this un-marked it and pin the index to text no
    /// editor holds any more. `reindexBuffer` re-checks cancellation after its
    /// parse, so the cancel bites whether the work is still sleeping out the
    /// debounce or already inside the extractor.
    ///
    /// The URL match is what keeps that cancel from being collateral damage:
    /// closing tab A must not throw away a re-index of tab B that happens to be
    /// the one in flight.
    func noteBufferClosed(url: URL) {
        let key = url.standardizedFileURL
        bufferTasks.removeValue(forKey: key)?.cancel()
        model.forgetBuffer(url: url)
    }

    private func schedule(url: URL, text: String, language: SyntaxLanguage?, immediate: Bool) {
        guard let language, SymbolIndexModel.isIndexable(language) else { return }

        let key = url.standardizedFileURL
        bufferTasks.removeValue(forKey: key)?.cancel()
        let interval = bufferDebounce
        bufferTasks[key] = Task { [weak self, model] in
            if !immediate {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            await model.reindexBuffer(url: url, text: text, language: language)
            // The cancellation check is also what keeps this from clearing a
            // *newer* task's slot: every replacement cancels the task it evicts,
            // so a task that reaches here is still the one the entry names.
            guard let self, !Task.isCancelled else { return }
            self.bufferTasks[key] = nil
        }
    }

    // MARK: - Project

    /// Something under `root` changed on disk (the FSEvents callback): refresh the
    /// index once the burst settles.
    ///
    /// Nothing here is gated on the autosave/revert bracket, and that is
    /// deliberate — the index is a *reader* (see `SymbolIndexModel`), so a refresh
    /// landing mid-revert costs at worst one stale entry that the next refresh
    /// corrects. Taking the writer gate would serialize the editor behind a
    /// background walk for no benefit.
    func noteProjectFilesChanged(root: URL) {
        refreshTask?.cancel()
        let interval = refreshDebounce
        refreshTask = Task { [weak self, model] in
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await model.refresh(root: root)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
        }
    }

    /// Drop both pending debounces — what a folder change means.
    ///
    /// The model's generation token already discards whatever they would publish;
    /// cancelling here just avoids doing the work first. Call it in the same
    /// main-actor turn as `prepareForFolderChange(root:)`.
    func reset() {
        for task in bufferTasks.values { task.cancel() }
        bufferTasks.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }
}

#endif
