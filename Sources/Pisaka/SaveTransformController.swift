#if os(macOS)
import AppKit
import PisakaCore

/// What `SaveTransformController` needs from the editor showing a buffer, so it
/// can apply a save transform *through* the live view instead of behind it.
///
/// Deliberately tiny and stated as a protocol rather than as a bag of closures:
/// every member is a question or an instruction the `CodeEditorView.Coordinator`
/// already answers for its own paths (the tab-switch buffer swap raises the same
/// two guards, `captureViewport()` already reads the anchor, `restoreViewport`
/// already knows how to put one back). Nothing here decides *what* a save
/// rewrites — that is `SaveTransform`'s job alone.
@MainActor
protocol SaveTransformEditor: AnyObject {
    /// The file the attached text view is showing **right now**.
    ///
    /// Read rather than cached because the one trigger that matters is the
    /// tab-switch autosave: it fires from `WorkspaceModel.$selectedID`, before
    /// `updateNSView` swaps the buffer, so at that moment this still names the
    /// *outgoing* file — which is precisely the buffer being saved and the one
    /// the transform must reach through the view.
    var displayedFileID: UUID? { get }

    /// The UTF-16 offset of the character at the top of the viewport, or `nil`
    /// when the views are gone.
    var scrollAnchorOffset: Int? { get }

    /// Scroll so the character at `offset` sits at the top of the viewport again.
    func scrollAnchor(to offset: Int)

    /// Raise the editor's two rewrite guards for the duration of a save
    /// transform: the programmatic-edit flag (so neither `shouldChangeText` nor
    /// the change notification is mistaken for typing) and the buffer-swap flag
    /// (so the incremental blame and diagnostics shifters do not run across what
    /// can be a file-wide edit).
    ///
    /// Raised *before* the edit is even proposed, because `shouldChangeText`
    /// re-enters the delegate's own interceptors.
    func beginSaveTransformRewrite()

    /// Drop the blame column and this document's diagnostics the way a wholesale
    /// replacement does, because the coalesced edit can be file-wide.
    ///
    /// Separate from raising the guards, and called only once the edit is known
    /// to be permitted: a refused `shouldChangeText` changes no text, and
    /// discarding both readers for a rewrite that never happened would leave the
    /// gutter and the underlines empty with no edit to re-publish them.
    func resetIncrementalReadersForSaveTransform()

    /// Lower both guards. Called after `didChangeText()`, so every notification
    /// the rewrite fires is covered.
    func endSaveTransformRewrite()
}

/// The one macOS funnel every save passes through before it writes: it asks
/// `SaveTransform` what saving each buffer changes and applies the answer, so the
/// bytes on disk, the open buffer and the saved baseline agree.
///
/// Shaped like `EditorSearchController`: owned by `PisakaApp` for the app's whole
/// lifetime, attached from the editor's `makeNSView`, holding the text view (and
/// the editor seam) **weakly** so a torn-down editor simply leaves this with
/// nothing on screen to reach — which is not a degraded state but the ordinary
/// one for a background tab.
///
/// **It decides nothing the engine decides.** Properties come from the existing
/// `EditorConfigModel` (the same cache Enter and Tab ask), the plan comes from
/// `SaveTransform.plan(text:config:protectedPositions:)`, and this class owns only
/// the AppKit side: which buffer is on screen, the undo-coalescing bracket, the
/// selection and the scroll anchor. An empty plan — every project without an
/// `.editorconfig`, and every buffer that already satisfies the three properties
/// — costs one cache hit and returns without touching anything.
///
/// **Two application paths, and the second one has a cost worth stating.** A
/// buffer the editor still holds is rewritten *through the text view*, in one
/// `shouldChangeText` / `beginEditing`…`endEditing` / `didChangeText` bracket
/// applied back-to-front — `insertConfiguredTab`'s template — so the whole save is
/// a single undoable step (one ⌘Z restores the pre-save buffer), a single change
/// notification, and every observer (Neon, the gutter, the minimap, the brackets,
/// the symbol index and, through `reindexSymbols`, the LSP push sync) sees an
/// ordinary edit. A buffer the editor no longer holds — a background tab caught by
/// an autosave — has no view to edit through, so it is rewritten through
/// `WorkspaceModel.replaceText(_:for:)`, which bumps that tab's text-replacement
/// revision: **that tab's undo stack and remembered scroll position are dropped**
/// when it is next displayed, exactly as they are for every other off-screen
/// rewrite (Replace All, a revert, a merge apply). Known and bounded — it costs
/// undo history for a tab nobody is looking at, on a save that only happens when
/// the project's own configuration asked for the rewrite.
///
/// **Only a save calls this.** Not open, not close, not a tab switch on its own,
/// not an `.editorconfig` change, and not the worktree writers (project-wide
/// Replace All, every git operation), which keep writing exactly the bytes they
/// write today. The call sites are `PisakaApp.save(id:)` (⌘S, the close prompt's
/// Save, and the run/test pre-run saves, which all funnel through it),
/// `PisakaApp.saveAs(id:)` once the destination is known, and
/// `AutosaveController`'s regular triggers and both flush paths.
@MainActor
final class SaveTransformController {

    /// The editor's text view, held weakly — the coordinator owns it, and this
    /// controller outlives every editor.
    private weak var textView: NSTextView?

    /// The editor seam, held weakly for the same reason. `nil` means no editor is
    /// attached, so every buffer takes the through-the-model path.
    private weak var editor: SaveTransformEditor?

    /// The two models every call needs, bound once: the buffers to rewrite and
    /// the `.editorconfig` cache to ask about them. Held weakly, like
    /// `AutosaveController.model` — the app owns both for its whole lifetime, and
    /// a deallocated one simply means no transform, which is the safe answer.
    private weak var model: WorkspaceModel?
    private weak var editorConfig: EditorConfigModel?

    /// Told about a titled buffer this controller rewrote **behind** the editor —
    /// the background-tab path, which goes through the model and therefore fires
    /// no change notification any reader can see.
    ///
    /// The through-the-view path needs nothing here: it ends in `didChangeText()`,
    /// so the symbol index, the LSP push channel and the diagnostics shifter all
    /// see an ordinary edit. A tab no editor is showing has no such notification,
    /// and a buffer-sourced index entry is *skipped* by every disk refresh
    /// (`SymbolIndexModel`), so without this the pre-transform declarations, their
    /// pre-transform offsets and the document's stale diagnostics would stand
    /// until that tab happened to be displayed again — which is exactly the
    /// resync `reindexReloadedBuffer` performs for every other off-screen rewrite
    /// (Replace All, a revert, a merge apply, a checkout).
    private var onBufferReplaced: ((UUID, URL) -> Void)?

    /// Bind the two models and the off-screen resync (`PisakaApp`'s `.onAppear`,
    /// beside `autosave.start`).
    ///
    /// Bound once here rather than passed on every call so the call sites stay a
    /// single line each and read as what they are — "transform these buffers" —
    /// with no per-save re-statement of where the buffers and the configuration
    /// come from.
    func start(
        model: WorkspaceModel,
        editorConfig: EditorConfigModel,
        onBufferReplaced: @escaping (UUID, URL) -> Void
    ) {
        self.model = model
        self.editorConfig = editorConfig
        self.onBufferReplaced = onBufferReplaced
    }

    /// Bind to the editor that is being built (`CodeEditorView.makeNSView`).
    /// Re-attachment simply replaces both references: one editor exists at a time.
    func attach(textView: NSTextView, editor: SaveTransformEditor) {
        self.textView = textView
        self.editor = editor
    }

    /// Apply the save transform to each of `ids` that has a url, ahead of the
    /// write that is about to happen.
    ///
    /// The caller chooses the set, and the two callers choose differently on
    /// purpose: `PisakaApp.save(id:)` passes the one file ⌘S names, dirty or not,
    /// because that keystroke writes it either way; `AutosaveController` passes
    /// only the buffers `saveAllDirty()` will actually write (dirty and titled),
    /// because transforming a clean background tab would make it dirty and put a
    /// file nobody edited into the next commit.
    ///
    /// Url-less (untitled) buffers are skipped: there is no path to resolve a
    /// configuration against yet. `prepareForSaveAs` is their entry point.
    func prepareForSave(ids: [UUID]) {
        guard let model else { return }
        for id in ids {
            guard let url = model.openFiles.first(where: { $0.id == id })?.url else { continue }
            prepare(id: id, configuredBy: url, resyncing: url, in: model)
        }
    }

    /// Apply the save transform to an untitled buffer that is about to be written
    /// to `destination`.
    ///
    /// The configuration that applies is the **destination's**, not the source's
    /// (there is no source): a Save As into a folder whose `.editorconfig` asks
    /// for CRLF writes CRLF, and the same buffer saved elsewhere does not.
    /// No resync url, and that is not an omission: this is an **untitled** buffer,
    /// so nothing has ever indexed it — under the destination path or any other —
    /// and the write that follows re-indexes it from disk
    /// (`PisakaApp.saveAs`'s `notifyIndexOfProjectFileChanges()`).
    func prepareForSaveAs(id: UUID, destination: URL) {
        guard let model else { return }
        prepare(id: id, configuredBy: destination, resyncing: nil, in: model)
    }

    // MARK: - Internals

    private func prepare(id: UUID, configuredBy url: URL, resyncing resyncURL: URL?, in model: WorkspaceModel) {
        guard let config = editorConfig?.properties(for: url) else { return }
        let live = liveTextView(for: id)
        // The live view is authoritative for the buffer it is showing; the model
        // is authoritative for every other tab. The two agree — the editor's
        // binding writes each change straight into `updateText` — so this is a
        // choice of the cheaper read, not of a different answer.
        let text = live?.string ?? model.text(for: id)
        guard let text else { return }
        let plan = SaveTransform.plan(
            text: text,
            config: config,
            protectedPositions: live.map(protectedPositions(in:)) ?? []
        )
        // The overwhelmingly common answer, and the one that must cost nothing:
        // no configuration, or a buffer that already satisfies it.
        guard !plan.isEmpty else { return }
        if let live {
            apply(plan, in: live)
        } else {
            model.replaceText(plan.text, for: id)
            // The rewrite fired no change notification, so the readers that track
            // this buffer are told the way every other off-screen rewrite tells
            // them. See `onBufferReplaced`.
            if let resyncURL { onBufferReplaced?(id, resyncURL) }
        }
    }

    /// The attached text view when it is showing `id`, and `nil` otherwise — a
    /// background tab, an editor that was torn down, or a window with no file
    /// open at all.
    private func liveTextView(for id: UUID) -> NSTextView? {
        guard let textView, editor?.displayedFileID == id else { return nil }
        return textView
    }

    /// The offsets whose lines trimming must spare, read from `selectedRanges`
    /// rather than `selectedRange()` — the middle-drag column selection makes
    /// several carets a first-class state, and an autosave landing on one of them
    /// must spare every line it sits on, not just the first.
    ///
    /// Which offsets a range contributes is `SaveTransform`'s decision, not this
    /// class's: all that happens here is the unwrap of AppKit's `[NSValue]`.
    private func protectedPositions(in textView: NSTextView) -> [Int] {
        SaveTransform.protectedPositions(
            forSelectedRanges: (textView.selectedRanges as [NSValue]).map(\.rangeValue)
        )
    }

    /// Rewrite the shown buffer through the text view: one undoable step, one
    /// change notification, the selection and the scroll anchor remapped by the
    /// engine.
    private func apply(_ plan: SaveTransformPlan, in textView: NSTextView) {
        // Never mid-composition. This path mutates `textStorage` directly rather
        // than going through `insertText(_:replacementRange:)`, which is exactly
        // the bookkeeping a marked range depends on: moving characters out from
        // under it leaves the next composition update writing at an offset that
        // describes nothing (`insertConfiguredTab`'s guard, for its reason). The
        // save then writes the untransformed bytes and the next one — a keystroke
        // later, the composition long committed — transforms them.
        guard !textView.hasMarkedText(), let textStorage = textView.textStorage else { return }

        let selection = (textView.selectedRanges as [NSValue]).map { plan.remappedRange($0.rangeValue) }
        let anchor = editor?.scrollAnchorOffset.map(plan.remappedOffset)

        let editedRanges = plan.replacements.map { NSValue(range: $0.range) }
        let replacements = plan.replacements.map(\.replacement)
        editor?.beginSaveTransformRewrite()
        defer { editor?.endSaveTransformRewrite() }
        // The guards go up first (this call re-enters the delegate's own
        // interceptors), but the blame column and the diagnostics are dropped only
        // once the edit is permitted: a refusal here rewrites nothing, and
        // discarding both readers for a rewrite that never happened would leave
        // them empty with no change notification to re-publish them.
        guard textView.shouldChangeText(inRanges: editedRanges, replacementStrings: replacements) else { return }
        editor?.resetIncrementalReadersForSaveTransform()
        // The replacements carry `typingAttributes` explicitly: the raw storage
        // path would otherwise inherit whatever the adjacent text has, and in a
        // buffer with no adjacent text, no font at all (`insertConfiguredTab`).
        let attributes = textView.typingAttributes
        textStorage.beginEditing()
        for edit in plan.replacements.reversed() {
            textStorage.replaceCharacters(
                in: edit.range,
                with: NSAttributedString(string: edit.replacement, attributes: attributes)
            )
        }
        textStorage.endEditing()
        textView.didChangeText()
        textView.setSelectedRanges(
            selection.map { NSValue(range: $0) },
            affinity: .downstream,
            stillSelecting: false
        )
        // Deliberately **not** `scrollRangeToVisible`. Every other programmatic
        // edit here is something the user just asked for, so jumping to the caret
        // is the right answer; a save is not, and an autosave is not even a
        // keystroke. The page stays where the reader left it — which, because the
        // transform can delete characters above the viewport, means putting the
        // remapped anchor back at the top rather than doing nothing.
        if let anchor { editor?.scrollAnchor(to: anchor) }
    }
}

#endif
