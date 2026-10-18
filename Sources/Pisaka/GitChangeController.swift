#if os(macOS)
import AppKit
import Foundation
import PisakaCore

/// Drives the editor gutter's git change column: it holds the displayed file's
/// `HEAD` text (the *base*), recomputes the hunks against the live buffer a
/// quarter-second after the last edit, and hands the markers to
/// `LineNumberRulerView`.
///
/// Shaped like `BlameController` — weak view references, a monotonic
/// `generation` token captured synchronously before every hop, at most one base
/// read in flight plus one pending, silent failure — with one difference in what
/// it describes: blame describes the file *on disk*, this column describes the
/// **buffer**. So the base is the only thing read from git, and everything else
/// is `GutterChangeModel.compute` over the base and whatever the text view holds
/// now. Every decision is that Core function's; this class only schedules it.
///
/// **When the base is re-read.** A different file or path, a wholesale buffer
/// replacement, a moved `diskRevision`, or a moved `gitRevision`
/// (`LocalChangesModel.listRevision`, bumped on every refresh publish — commit,
/// pull, checkout, merge apply, the pull-request checkout and the post-merge
/// tail). A commit made in the embedded terminal moves none of them, so the
/// column keeps describing the old `HEAD` until one of those happens: the limit
/// `BlameController` already states as its inaccuracy 3, for the same reason.
///
/// **Two answers, one function.** The async recompute only feeds *drawing*.
/// The commands (revert, next/previous change) ask `currentChanges(buffer:)`,
/// which recomputes synchronously from the held base and the buffer handed in,
/// so a command never acts on an answer computed for an older buffer.
///
/// **Errors are swallowed.** An untracked file, a file outside a repository, a
/// binary or oversized blob, a missing `git` — each leaves the column empty, with
/// no alert and no beep: markers are an inspection affordance.
@MainActor
final class GitChangeController {
    /// The quiet interval after the last edit before the column is recomputed:
    /// a typing burst (inter-key intervals are typically under 200 ms) coalesces
    /// into one diff, yet the markers settle within a quarter-second of a pause.
    static let recomputeDelay: Duration = .milliseconds(250)

    /// The gutter this controller feeds. Held weakly: the scroll view owns it.
    private weak var ruler: LineNumberRulerView?

    /// The editor whose buffer is diffed. Held weakly, as the coordinator does.
    private weak var textView: NSTextView?

    /// The real `git show` runner; its method is not `@MainActor`, so the
    /// subprocess and the blob classification stay off the main thread.
    private let gitService = GitCLIService()

    /// The displayed file, its path and the two revision tokens as last seen by
    /// `sync`. Compared for (in)equality only — "it changed", never "+1".
    private var fileID: UUID?
    private var fileURL: URL?
    private var diskRevision: Int?
    private var gitRevision: Int?

    /// The displayed file's `HEAD` text, or `nil` when there is none (yet).
    private(set) var base: String?

    /// Monotonic token guarding a base read against a newer one, a file switch
    /// and teardown. A read resuming with a stale token discards its answer.
    private var generation = 0

    /// Monotonic token guarding one recompute against a newer one: a later
    /// recompute, an edit after the snapshot, a buffer swap or a new base. Kept
    /// apart from `generation` so an edit never supersedes a base read.
    private var computeToken = 0

    /// Whether a `git show` is running for this controller. With `pending`, it
    /// bounds the backlog at one running plus one waiting, as on `BlameController`.
    private var isLoading = false

    /// The one read held back while `isLoading`: its token and its path.
    private var pending: (token: Int, fileURL: URL)?

    /// The coalescing timer: the newest edit cancels the one before it.
    private var recomputeTask: Task<Void, Never>?

    /// Whether a worktree-mutating git operation holds the writer gate
    /// (`LocalChangesModel.isReverting`), handed in by the editor on every update.
    /// Read-only: a hunk revert *consults* it and refuses silently while it is
    /// raised; nothing here ever raises it.
    var writeInFlight: () -> Bool = { false }

    /// The window's change popover, handed in by the editor on every update.
    /// `nil` (a default-constructed editor, the app tests) shows nothing.
    var popover: ChangeHunkPopoverPresenting?

    /// What the popover's *Revert* does with the marker line it was opened for:
    /// the coordinator's `revertChange(atMarker:)`, installed by `attach`.
    var revert: ((Int) -> Void)?

    /// Take the editor's two per-update inputs (`updateNSView`): the writer
    /// gate's read-only consult and the window's change popover. One call
    /// rather than two assignments keeps `CodeEditorView.swift` inside its
    /// `file_length` ceiling.
    func configure(writeInFlight: @escaping () -> Bool, popover: ChangeHunkPopoverPresenting?) {
        self.writeInFlight = writeInFlight
        self.popover = popover
    }

    /// Called on the main actor after every answer reaches the ruler, an empty
    /// one included — the causal rendezvous the app tests wait on.
    var onChangesInstalled: ((GutterChanges) -> Void)?

    /// Bind the controller to the editor's gutter and text view (`makeNSView`),
    /// with what the popover's *Revert* does (`revert`). The owner captures
    /// itself **weakly** in `revert`, for `onToggleAnnotate`'s retain-cycle reason.
    func attach(ruler: LineNumberRulerView, textView: NSTextView, revert: ((Int) -> Void)? = nil) {
        self.ruler = ruler
        self.textView = textView
        if let revert { self.revert = revert }
        ruler.onChangeMarkerClicked = { [weak self] line, rect in
            self?.markerClicked(line: line, rect: rect)
        }
    }

    /// A marker was clicked: show its hunk's `HEAD` lines beside it. The hunk is
    /// recomputed now, as every command's is; the popover remembers the clicked
    /// *line*, not this hunk, and any buffer change dismisses it, so its
    /// *Revert* recomputes against the same buffer it was shown for.
    func markerClicked(line: Int, rect: NSRect) {
        guard let ruler, let base, let buffer = textView?.string,
              let hunk = currentChanges(buffer: buffer).hunk(atMarkerLine: line)
        else { return }
        popover?.present(ChangeHunkPopoverRequest(
            headLines: hunk.headLines(in: base),
            anchor: rect,
            anchorView: ruler,
            revert: { [weak self] in self?.revert?(line) }
        ))
    }

    /// Reconcile the column with the file the editor is showing (`updateNSView`,
    /// so this must be cheap when nothing moved). A `nil` `fileURL` (an untitled
    /// buffer) has no `HEAD` and draws nothing.
    func sync(fileID: UUID, fileURL: URL?, diskRevision: Int, gitRevision: Int, contentReplaced: Bool) {
        let switched = fileID != self.fileID || fileURL != self.fileURL
        let needsReload = switched
            || contentReplaced
            || diskRevision != self.diskRevision
            || gitRevision != self.gitRevision
        self.fileID = fileID
        self.fileURL = fileURL
        self.diskRevision = diskRevision
        self.gitRevision = gitRevision
        guard needsReload else { return }
        // A switched file must not keep the outgoing file's base or marks while
        // its own base loads; the same file keeps both, so a save never flickers.
        if switched { clearColumn() }
        guard let fileURL else {
            clearColumn()
            return
        }
        load(fileURL: fileURL)
    }

    /// An edit landed in the buffer: recompute once the typing pauses. Between
    /// now and then the ruler shifts the installed marks with `LineShift`.
    func noteEdit() {
        computeToken += 1
        popover?.dismiss()
        guard base != nil else { return }
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recomputeDelay)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    /// The hunks of `buffer` against the held base, computed now — the answer
    /// the commands act on. Empty when there is no base.
    func currentChanges(buffer: String) -> GutterChanges {
        GutterChangeModel.compute(base: base, buffer: buffer)
    }

    /// Drop the marks ahead of a wholesale `textView.string = text` assignment,
    /// whose single full-range edit the ruler would otherwise shift them across.
    /// The base is kept: the `sync` that follows (`contentReplaced: true`)
    /// re-reads it.
    func beginBufferSwap() {
        popover?.dismiss()
        recomputeTask?.cancel()
        computeToken += 1
        ruler?.clearChangeMarkers()
    }

    /// Drop all state and supersede any in-flight read or recompute (teardown).
    func reset() {
        clearColumn()
        // Unconditional, for `BlameController.reset()`'s reason: "nothing
        // installed" and "nothing running" must always mean the same thing.
        isLoading = false
        fileID = nil
        fileURL = nil
        diskRevision = nil
        gitRevision = nil
        onChangesInstalled = nil
        popover = nil
        revert = nil
        ruler?.onChangeMarkerClicked = nil
        ruler = nil
        textView = nil
    }

    // MARK: - Internals

    /// Empty the column and supersede whatever read or recompute fed it.
    private func clearColumn() {
        popover?.dismiss()
        generation += 1
        computeToken += 1
        pending = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        base = nil
        ruler?.clearChangeMarkers()
    }

    /// Read the base for `fileURL`, or hold the request while another read runs.
    private func load(fileURL: URL) {
        generation += 1
        let token = generation
        guard !isLoading else {
            pending = (token, fileURL)
            return
        }
        run(fileURL: fileURL, token: token)
    }

    /// Issue one read and, once it resolves, install its base (when still
    /// current), recompute, and drain whatever was held back meanwhile.
    private func run(fileURL: URL, token: Int) {
        isLoading = true
        let service = gitService
        Task { [weak self] in
            let text = try? await service.headText(fileURL: fileURL)
            guard let self else { return }
            self.isLoading = false
            if token == self.generation {
                self.base = text
                self.recompute()
            }
            if let next = self.pending {
                self.pending = nil
                if next.token == self.generation { self.run(fileURL: next.fileURL, token: next.token) }
            }
        }
    }

    /// Snapshot the buffer and the token synchronously, diff off the main thread,
    /// and install the answer only if nothing superseded it meanwhile.
    private func recompute() {
        recomputeTask?.cancel()
        recomputeTask = nil
        computeToken += 1
        let token = computeToken
        guard let base, let buffer = textView?.string else {
            ruler?.clearChangeMarkers()
            onChangesInstalled?(GutterChanges(hunks: [], lineCount: 0))
            return
        }
        Task { [weak self] in
            let changes = await Task.detached(priority: .userInitiated) {
                GutterChangeModel.compute(base: base, buffer: buffer)
            }.value
            guard let self, token == self.computeToken else { return }
            // Cleared explicitly rather than through `setChangeMarkers`, which
            // refuses an array whose length is not the ruler's line count.
            if changes.hunks.isEmpty {
                self.ruler?.clearChangeMarkers()
            } else {
                self.ruler?.setChangeMarkers(changes.markers)
            }
            self.onChangesInstalled?(changes)
        }
    }
}

#endif
