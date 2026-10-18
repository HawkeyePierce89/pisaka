#if os(macOS)
import AppKit
import Combine
import PisakaCore

/// External-change wiring: the two disk-check passes (the folder watcher's
/// coalesced event and app activation), the Overwrite / Reload / Cancel question
/// a guarded save puts, and the capture-then-act helpers both answers run
/// through. Every decision is `WorkspaceModel`'s (`checkDisk(id:)`,
/// `syncAllWithDisk()`, the conflict map); this class only decides *when* to ask
/// and what to capture into Local History before the losing side is gone.
///
/// The passes are **deferred while the writer gate is up**: a git operation
/// rewriting the worktree resyncs its own tabs from a snapshot, and a pass landing
/// mid-operation would read files git is still writing. A pass requested then is
/// recorded and run once when the gate comes down. The pass is synchronous on the
/// main actor and publishes nothing when nothing moved, so a watcher burst does not
/// re-arm the autosave idle debounce.
@MainActor
final class DiskSyncController {
    /// The user's answer to the external-change question.
    enum Answer: Equatable {
        case overwrite
        case reload
        case cancel
    }

    /// What a guarded save does after the check (`resolveBeforeSave`).
    enum SaveResolution: Equatable {
        /// Write, under this policy: `.refuse` when there was no conflict (the
        /// model re-checks), `.overwrite` when the user chose Overwrite and the
        /// disk side has been captured.
        case write(WorkspaceModel.ExternalChangePolicy)
        /// The user chose Reload: the edits were captured and discarded, and the
        /// tab is clean on the disk's text. Nothing is left to write.
        case reloaded
        /// The user cancelled, or the reload failed: nothing was written.
        case cancelled
    }

    private weak var model: WorkspaceModel?
    private var localHistory: LocalHistoryModel?
    private var onReloaded: (UUID, URL) -> Void = { _, _ in }
    private let ask: (_ fileName: String) -> Answer
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    /// The writer gate's last value, as the gate publisher reported it.
    private var gateUp = false
    /// A pass was requested while the gate was up; run it when it comes down.
    private(set) var passPending = false

    init(ask: @escaping (_ fileName: String) -> Answer = DiskSyncController.askAboutExternalChange) {
        self.ask = ask
    }

    /// Begin observing app activation and the writer gate. `gate` is the writer
    /// gate's publisher (`localChanges.$isReverting`); its value is taken from
    /// the emission itself, because `@Published` emits before the property is
    /// assigned. `onReloaded` is the resync's reindex for a tab whose baseline
    /// moved — blame and the gutter follow the `diskRevision` bump on their own.
    /// Idempotent, like the autosave start it sits beside.
    func start(
        model: WorkspaceModel,
        localHistory: LocalHistoryModel?,
        gate: AnyPublisher<Bool, Never>,
        onReloaded: @escaping (UUID, URL) -> Void
    ) {
        guard self.model == nil else { return }
        self.model = model
        self.localHistory = localHistory
        self.onReloaded = onReloaded
        gate
            .sink { [weak self] up in self?.gateChanged(up) }
            .store(in: &cancellables)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.requestPass() }
            }
        )
    }

    /// Stop observing. Safe to call more than once.
    func stop() {
        cancellables.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    /// Run a disk-check pass over every titled text tab now, or once the writer
    /// gate comes down when it is up. The watcher's `onChange` and app
    /// activation both call this.
    func requestPass() {
        guard model != nil else { return }
        guard !gateUp else {
            passPending = true
            return
        }
        runPass()
    }

    private func gateChanged(_ up: Bool) {
        gateUp = up
        guard !up, passPending else { return }
        runPass()
    }

    private func runPass() {
        passPending = false
        guard let model else { return }
        for id in model.syncAllWithDisk().reloaded {
            if let url = url(of: id) { onReloaded(id, url) }
        }
    }

    // MARK: - The guarded save

    /// Check tab `id` against the disk before a save writes it and, when it is in
    /// external conflict, put the question — or act on `answer` when the caller
    /// already has one (the editor's bar). A clean tab the check reloaded is
    /// reindexed here. Overwrite captures the disk side under `.overwrite` before
    /// answering `.write(.overwrite)`; Reload captures the buffer under `.discard`
    /// and reloads.
    func resolveBeforeSave(_ id: UUID, answer: Answer? = nil) -> SaveResolution {
        guard let model else { return .write(.refuse) }
        let verdict = model.checkDisk(id: id)
        if verdict == .reload || verdict == .adoptBaseline, let url = url(of: id) {
            onReloaded(id, url)
        }
        guard model.isInExternalConflict(id) else { return .write(.refuse) }
        let name = model.openFiles.first { $0.id == id }?.displayName ?? "Untitled"
        switch answer ?? ask(name) {
        case .overwrite:
            captureDiskSide(of: id)
            return .write(.overwrite)
        case .reload:
            return discardEdits(of: id) ? .reloaded : .cancelled
        case .cancel:
            return .cancelled
        }
    }

    /// Capture the disk side of tab `id`'s conflict under `.overwrite` — the half
    /// of Overwrite that runs before the write.
    func captureDiskSide(of id: UUID) {
        guard let model, let url = url(of: id), let disk = model.diskText(forConflict: id) else { return }
        localHistory?.captureBuffers(event: .overwrite, urls: [url], root: model.projectRoot, texts: [url: disk])
    }

    /// Reload: capture the buffer under `.discard`, then reload tab `id` from
    /// disk, discarding its edits. Answers whether the reload succeeded; a failed
    /// one beeps and leaves the tab as it was.
    @discardableResult
    func discardEdits(of id: UUID) -> Bool {
        guard let model, let url = url(of: id), let text = model.text(for: id) else { return false }
        localHistory?.captureBuffers(event: .discard, urls: [url], root: model.projectRoot, texts: [url: text])
        guard model.reloadDiscardingEdits(id) else {
            PlatformFeedback.warning()
            return false
        }
        onReloaded(id, url)
        return true
    }

    // MARK: - The quit

    /// The quit's question (`AppDelegate.externalChangeQuestion`): every dirty
    /// titled tab is checked against the disk, and each one in conflict goes
    /// through `save` — the app's guarded ⌘S funnel, which puts the question.
    /// The first `false` (Cancel, or a failed write) cancels the quit. When any
    /// question was put, the quit waits for the Local History chain, so the side
    /// an answer gave up is on disk before the process goes. Asks nothing while
    /// the writer gate is up: the termination flush is gated too, so nothing
    /// would be written either way.
    func questionBeforeQuit(save: (UUID) -> Bool) -> ExternalChangeQuitAnswer {
        guard let model, !gateUp else { return .proceed(awaiting: nil) }
        let conflicted = model.partitionDirtyTabsForSave().conflicted
        guard !conflicted.isEmpty else { return .proceed(awaiting: nil) }
        for id in conflicted where !save(id) { return .cancel }
        let history = localHistory
        return .proceed(awaiting: { await history?.waitForQueuedWrites() })
    }

    private func url(of id: UUID) -> URL? {
        model?.openFiles.first { $0.id == id }?.url
    }

    /// The modal question. No choice is the default: Return answers nothing, so a
    /// keystroke meant for the editor cannot pick a side; Escape is Cancel.
    static func askAboutExternalChange(fileName: String) -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\"\(fileName)\" changed on disk since it was opened or last saved."
        alert.informativeText = "Overwrite replaces the file on disk with the editor's text. "
            + "Reload discards your edits and shows the file on disk. "
            + "Either way, the version you give up is kept in Local History."
        alert.addButton(withTitle: "Overwrite").keyEquivalent = ""
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .reload
        default: return .cancel
        }
    }
}

#endif
