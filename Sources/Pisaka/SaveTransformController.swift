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
/// buffer the editor still holds — and whose view still agrees with the model —
/// is rewritten *through the text view*, in one
/// `shouldChangeText` / `beginEditing`…`endEditing` / `didChangeText` bracket
/// applied back-to-front — `insertConfiguredTab`'s template — so the whole save is
/// a single undoable step (one ⌘Z restores the pre-save buffer), a single change
/// notification, and every observer (Neon, the gutter, the minimap, the brackets,
/// the symbol index and, through `reindexSymbols`, the LSP push sync) sees an
/// ordinary edit. A dense or file-wide run of edits is handed over as the single
/// replacement covering it instead, because applying them one by one is quadratic
/// in the file (`SaveTransformPlan.applicableReplacements(originalLength:)`). A
/// buffer the editor no longer holds — a background tab caught by an autosave, a
/// shown tab whose view has not yet caught up with a model-side rewrite (see
/// `prepare`), or a buffer being *abandoned* whose view refused the rewrite —
/// has no view to edit through, so it is rewritten through
/// `WorkspaceModel.replaceText(_:for:)`, which bumps that tab's text-replacement
/// revision: **that tab's undo stack and remembered scroll position are dropped**
/// when it is next displayed, exactly as they are for every other off-screen
/// rewrite (Replace All, a revert, a merge apply). Known and bounded — it costs
/// undo history for a tab nobody is looking at, on a save that only happens when
/// the project's own configuration asked for the rewrite — and bounded is the
/// operative word: an owed trim, which is re-offered on ticks of this controller's
/// own choosing rather than because the user did anything, deliberately does
/// **not** take this path (`prepareForAutosave`).
///
/// **A save is what *decides* a rewrite here, and it is no longer the only thing
/// that *performs* one.** No transform is computed for anything but a save: not
/// open, not close, not a tab switch on its own, not an `.editorconfig` change,
/// and not the worktree writers (project-wide Replace All, every git operation),
/// which keep writing exactly the bytes they write today. The transform's call
/// sites are `PisakaApp.save(id:)` (⌘S, the close prompt's Save, and the run/test
/// pre-run saves, which all funnel through it), `PisakaApp.saveAs(id:)` once the
/// destination is known, and `AutosaveController`'s regular triggers and both
/// flush paths.
///
/// The through-the-view bracket below is a second thing, and it is shared:
/// `applyRestore(_:to:)` hands Local History's restore the very same
/// `shouldChangeText` / `beginEditing`…`endEditing` / `didChangeText` path, so a
/// restored revision is one undoable step with one change notification, exactly
/// as a save transform is. It is *not* a save — it computes no plan from an
/// `.editorconfig`, writes no disk, and leaves the tab dirty for the ordinary
/// save funnel to settle — and it lives here rather than in the window because
/// copying that AppKit bracket into a second file is how the two would drift.
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

    /// The buffers whose last save left trailing whitespace standing on a spared
    /// line — the trims this controller owes.
    ///
    /// Sparing promises that "the next save after the caret leaves trims it", and
    /// nothing else offers that next save: once autosave has written the buffer
    /// it is clean, and moving the caret does not dirty it, so `saveAllDirty()`
    /// never looks at it again. `prepareForAutosave` therefore re-offers exactly
    /// this set alongside the dirty buffers; the transform dirties whichever of
    /// them the caret has since left, and the same tick writes them.
    ///
    /// Maintained by `prepare` on every save: inserted when the plan reports a
    /// deferred trim, removed otherwise — so a buffer drops out the moment it is
    /// trimmed, its configuration stops asking for trimming, or it is saved with
    /// no caret to protect. Re-inserted, too, when the view refuses the rewrite
    /// (`apply` answering `false`), because a save that changed nothing still
    /// owes everything it was going to change — except on a save that is
    /// abandoning the buffer, which has no later save to owe it to and settles
    /// the refusal through the model instead (`prepare`).
    private var owedTrims: Set<UUID> = []

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
    /// The caller chooses the set, and the callers choose differently on
    /// purpose: `PisakaApp.save(id:)` passes the one file ⌘S names, dirty or not,
    /// because that keystroke writes it either way; `AutosaveController` passes
    /// only the buffers `saveAllDirty()` will actually write (dirty and titled),
    /// because transforming a clean background tab would make it dirty and put a
    /// file nobody edited into the next commit — plus, through
    /// `prepareForAutosave`, the buffers this controller owes a spared trim,
    /// which *were* edited and whose rewrite was deferred rather than declined.
    ///
    /// `protectingCaret` is `false` where the buffer is being abandoned (the
    /// close prompt's Save, the quit and folder-switch flushes): there is no
    /// caret to protect and no next save to defer to.
    ///
    /// Url-less (untitled) buffers are skipped: there is no path to resolve a
    /// configuration against yet. `prepareForSaveAs` is their entry point.
    func prepareForSave(ids: [UUID], protectingCaret: Bool = true) {
        guard let model else { return }
        for id in ids {
            guard let url = model.openFiles.first(where: { $0.id == id })?.url else { continue }
            prepare(id: id, configuredBy: url, resyncing: url, in: model, protectingCaret: protectingCaret)
        }
    }

    /// The autosave's entry point: the buffers this tick will write, **plus the
    /// trims sparing deferred** on earlier ticks.
    ///
    /// The union is made here rather than in `AutosaveController` because the
    /// owed set is this class's bookkeeping — the autosave knows which buffers
    /// are dirty, not which ones a caret spared. `prepareForSave` deliberately
    /// does *not* union: ⌘S names one file and must rewrite that file alone,
    /// since transforming a second tab would dirty a buffer the keystroke is not
    /// going to write.
    ///
    /// `abandoningBuffers` is what the quit flush, the folder-switch flush and
    /// the close prompt pass: there is no caret left to protect and no later save
    /// to defer to, so the file is trimmed in full — the answer the iOS save
    /// already gives for the same user action. The commit dialog's flush keeps
    /// protecting: editing continues after it, so sparing still has its reason,
    /// and the owed set means the trim is not lost.
    func prepareForAutosave(ids: [UUID], abandoningBuffers: Bool = false) {
        guard let model else { return }
        let open = Set(model.openFiles.map(\.id))
        owedTrims.formIntersection(open)
        // **An owed trim is settled through the editor, or not yet.** The buffer
        // that owes one is, overwhelmingly, the tab the user just left: the
        // tab-switch autosave spares the caret's line while that file is still
        // displayed, and `saveAllDirty()` republishes `$openFiles`, so the idle
        // tick two seconds later re-offers it — by which time the *new* tab is on
        // screen and the old one would take the through-the-model path, dropping
        // its undo stack and its remembered scroll position for a whitespace trim
        // nobody asked for. That cost is stated for a background tab an autosave
        // happens to catch; paying it on every tab switch is a different thing, so
        // an owed buffer waits for a save that can reach it through its view
        // (the user comes back and types) rather than being settled behind it.
        // It stays owed meanwhile — nothing removes it but a save that runs.
        // **Abandonment settles it regardless**: the quit flush, the folder-switch
        // flush and the close prompt are about to destroy every undo stack and
        // every viewport there is, so there is nothing left for waiting to protect
        // and the trim would otherwise never happen at all.
        let owed = owedTrims.subtracting(ids).filter { abandoningBuffers || liveTextView(for: $0) != nil }
        prepareForSave(ids: ids + owed, protectingCaret: !abandoningBuffers)
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
    ///
    /// `protectingCaret` carries the same meaning it has on `prepareForSave`, and
    /// it is a parameter here for one reason: the close prompt's Save reaches
    /// *this* method whenever the buffer is untitled (`model.save` answers
    /// `.needsSaveAs` and `PisakaApp.save` hands off to `saveAs`). Defaulting it
    /// to `true` there would spare a line on a buffer whose tab closes on the next
    /// statement — a deferral with nowhere to come true, since the owed set is
    /// pruned to open files.
    func prepareForSaveAs(id: UUID, destination: URL, protectingCaret: Bool = true) {
        guard let model else { return }
        prepare(id: id, configuredBy: destination, resyncing: nil, in: model, protectingCaret: protectingCaret)
    }

    // MARK: - Restore

    /// Replace the buffer `id` holds with `text` — Local History's restore, and
    /// the one caller of this class that is not a save.
    ///
    /// **A buffer edit, never a disk write.** Local History is a reader of the
    /// user's files: it takes no writer gate, is not gated by one, and its only
    /// writes land in its own store. So a restore does exactly what typing the
    /// old revision back in would do — it replaces the text and leaves the tab
    /// dirty — and the ordinary save funnel puts it on disk when the user (or the
    /// autosave) says so. That is also what makes it undoable: through the view
    /// it is a single coalesced step, so one ⌘Z brings the pre-restore buffer
    /// back.
    ///
    /// The plan is built here rather than by `SaveTransform`, because there is
    /// nothing to decide: one replacement covering the whole buffer, whose text
    /// *is* the revision. Going through `SaveTransformPlan` anyway is what buys
    /// the position remap for free — the caret, every selection endpoint and the
    /// scroll anchor are moved by the same three rules a save uses, which for a
    /// whole-buffer replacement clamps each of them into the new text instead of
    /// leaving an offset past its end.
    ///
    /// The two application paths and their costs are the class's, unchanged: the
    /// view when it holds this buffer and agrees with the model, and
    /// `WorkspaceModel.replaceText(_:for:)` otherwise — which is the *usual* path
    /// here rather than the exception, because restoring a file with no open tab
    /// opens one first and SwiftUI has not yet built its editor when this runs.
    /// It costs that fresh tab an undo stack it never had.
    ///
    /// A restore whose text the buffer already holds does nothing at all. The
    /// browser model refuses that case before it ever becomes a plan
    /// (`LocalHistoryBrowserModel.restore(currentText:)`); it is re-checked here
    /// because this method is reachable with any text, and rewriting a buffer
    /// with itself would dirty a clean tab for no change. Compared as `NSString`
    /// for `prepare`'s reason: canonical equivalence would call a decomposed and
    /// a precomposed spelling equal and skip a restore that does change bytes.
    ///
    /// `owedTrims` is deliberately left alone: what a save owes is recomputed by
    /// the next save from the buffer as it then stands, and this is not a save.
    func applyRestore(_ text: String, to id: UUID) {
        guard let model, let current = model.text(for: id) else { return }
        let currentString = current as NSString
        guard !currentString.isEqual(to: text) else { return }
        let plan = SaveTransformPlan(
            replacements: [
                IndentReplacement(
                    range: NSRange(location: 0, length: currentString.length),
                    replacement: text
                ),
            ],
            text: text
        )
        applyExternalRewrite(plan, to: id, in: model, current: current)
    }

    // MARK: - Rename

    /// Rewrite the buffer `id` holds with a rename's per-file plan — the second
    /// caller of this class that is not a save, and the second one that is a
    /// buffer edit rather than a disk write.
    ///
    /// Only the *files no tab holds* are written to disk by the rename engine;
    /// every open tab is rewritten here instead, because writing under an editor
    /// would leave a tab showing text that is no longer what the file contains and
    /// a dirty tab's own edits overwritten with no undo. The tab is left dirty and
    /// the ordinary save funnel puts it on disk, exactly as a restore is.
    ///
    /// The plan is the engine's own (`RenameFilePlan.applied(to:)`), so nothing is
    /// decided here: it is already ascending, non-overlapping and expressed against
    /// the text this buffer is being asked to hold. Routing it through the same two
    /// application paths is the whole point — the displayed tab gets one undoable
    /// step with one change notification and a remapped caret, and every other tab
    /// gets `WorkspaceModel.replaceText(_:for:)` and loses its undo stack, which is
    /// the cost this feature states rather than hides.
    ///
    /// A buffer that already holds the plan's result is left untouched — the same
    /// no-op guard `applyRestore` makes, and compared as `NSString` for the same
    /// reason: rewriting a buffer with itself would dirty a clean tab for no
    /// change. It is *not* a staleness check, and deliberately so: whether the
    /// buffer is still what the plan was computed against was settled by
    /// `RenameEditPlan.apply`, which verified every file before producing any of
    /// these plans, and this method is called in the same main-actor turn — there
    /// is no `await` between the two for anything to change in. A second check here
    /// would need the plan's *input* text, which a `SaveTransformPlan` does not
    /// carry, so it would be a check that could not be written rather than one
    /// that was left out.
    func applyRename(_ plan: SaveTransformPlan, to id: UUID) {
        guard let model, let current = model.text(for: id) else { return }
        let currentString = current as NSString
        guard !plan.replacements.isEmpty, !currentString.isEqual(to: plan.text) else { return }
        applyExternalRewrite(plan, to: id, in: model, current: current)
    }

    // MARK: - Internals

    /// The two application paths, shared by the restore and the rename: the live
    /// text view when it is showing this buffer and agrees with the model, and
    /// `WorkspaceModel.replaceText(_:for:)` otherwise.
    ///
    /// One body rather than two copies because the *choice* between the paths is
    /// the decision, and two spellings of it is how the off-screen half would
    /// eventually stop telling its readers. The model path fires no change
    /// notification, so the readers that track this buffer are told the way every
    /// other off-screen rewrite tells them (see `onBufferReplaced`).
    private func applyExternalRewrite(
        _ plan: SaveTransformPlan,
        to id: UUID,
        in model: WorkspaceModel,
        current: String
    ) {
        let displayed = liveTextView(for: id)
        let live = (displayed?.string as NSString?)?.isEqual(to: current) == true ? displayed : nil
        if let live, apply(plan, in: live) { return }
        model.replaceText(plan.text, for: id)
        if let url = model.openFiles.first(where: { $0.id == id })?.url {
            onBufferReplaced?(id, url)
        }
    }

    private func prepare(
        id: UUID,
        configuredBy url: URL,
        resyncing resyncURL: URL?,
        in model: WorkspaceModel,
        protectingCaret: Bool = true
    ) {
        guard let config = editorConfig?.properties(for: url) else { return }
        // Asked before anything is read, and that order is the point: the live
        // text view's `string` materializes a fresh copy of the whole buffer, so
        // reading it first would put two full-buffer traversals on the main
        // thread at every ⌘S and every autosave tick of every project that states
        // none of the three properties — the case this feature promised to cost
        // nothing. `SaveTransform.plan`'s own early-out is reached too late to
        // help, because the view read happens on the way to calling it.
        guard SaveTransform.rewrites(under: config) else {
            owedTrims.remove(id)
            return
        }
        guard let text = model.text(for: id) else { return }
        // The model is authoritative, always; the shown view is *also* the buffer
        // — and the cheaper thing to rewrite — only while the two agree. They
        // normally do, because the editor's binding writes every change straight
        // into `updateText`. They disagree for exactly one window: a model-side
        // rewrite (Replace All, a revert, a merge apply, a reload) lands in the
        // model first and reaches the view on SwiftUI's next update pass, and
        // those writers replay a deferred autosave *synchronously* from their own
        // `defer { autosave.resume() }` — i.e. inside that window. Transforming
        // the view's stale text there would push it straight back through
        // `didChangeText` and silently undo the rewrite in that tab, then write
        // the result to disk. When they disagree the model wins and the rewrite
        // takes the off-screen path, exactly as `updateNSView`'s content-replaced
        // branch already decides it.
        //
        // Compared as `NSString`, deliberately, and not with Swift's `==`: this
        // guard's whole job is to establish that a plan measured in UTF-16
        // offsets against `text` addresses the same code units the text storage
        // holds, and Swift's `String` equality is *canonical equivalence* — it
        // answers `true` for a decomposed and a precomposed spelling of the same
        // characters, which have different `NSString` lengths. A model-side
        // rewrite differing from the view only in Unicode normalization would
        // pass a semantic comparison and then hand `replaceCharacters(in:)`
        // ranges measured against a differently-lengthed string: misplaced edits,
        // or an out-of-range exception on the main thread during an unattended
        // autosave. `isEqual(to:)` compares the code units themselves, which is
        // the property the offsets actually rest on.
        let displayed = liveTextView(for: id)
        let live = (displayed?.string as NSString?)?.isEqual(to: text) == true ? displayed : nil
        let plan = SaveTransform.plan(
            text: text,
            config: config,
            protectedPositions: protectingCaret ? (live.map(protectedPositions(in:)) ?? []) : []
        )
        // Record — or clear — what sparing deferred, *before* the empty-plan
        // return: a save whose every edit was spared answers an empty plan and is
        // precisely the case the owed set exists for.
        if plan.deferredTrim {
            owedTrims.insert(id)
        } else {
            owedTrims.remove(id)
        }
        // The overwhelmingly common answer, and the one that must cost nothing:
        // a buffer that already satisfies its configuration.
        guard !plan.isEmpty else { return }
        if let live {
            if apply(plan, in: live) { return }
            // A rewrite the view could not make — mid-composition, or a delegate that
            // declined the change — applied nothing, so the untransformed bytes are
            // about to be written and everything this plan was going to do is still
            // owed.
            //
            // **An ordinary save defers it; an abandoning one cannot.** Re-arming the
            // owed set is the right answer while a later save can settle it: the
            // buffer stays open, the user keeps typing, and the next save through the
            // view does the rewrite with the undo stack intact. Without it, a save
            // that spared a run (owed), followed by a save that refused (owed cleared,
            // nothing written), would leave a clean tab, untrimmed bytes on disk and
            // nothing tracking either.
            //
            // A save with `protectingCaret == false` has no later save to defer to —
            // it is the close prompt's Save, the quit flush or the folder-switch
            // flush, and the tab is gone by the next statement (the owed set is pruned
            // to open files, so the record dies with it). Deferring there would write
            // untransformed bytes as the file's last word, which is exactly what
            // "a buffer being abandoned is trimmed in full" promises not to happen.
            // So it settles through the model instead, the same path a background tab
            // takes: it costs that tab its undo stack and its remembered viewport,
            // which is nothing at all for a buffer about to be destroyed — the same
            // reasoning by which abandonment settles an owed trim regardless of
            // whether a view still holds it (`prepareForAutosave`).
            if protectingCaret {
                owedTrims.insert(id)
                return
            }
        }
        model.replaceText(plan.text, for: id)
        // The rewrite fired no change notification, so the readers that track this
        // buffer are told the way every other off-screen rewrite tells them.
        // See `onBufferReplaced`.
        if let resyncURL { onBufferReplaced?(id, resyncURL) }
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
    ///
    /// Answers whether the rewrite actually happened: a composition in progress
    /// and a refused `shouldChangeText` both leave the buffer untouched, and the
    /// caller has bookkeeping that must not record a save that did not occur.
    private func apply(_ plan: SaveTransformPlan, in textView: NSTextView) -> Bool {
        // Never mid-composition. This path mutates `textStorage` directly rather
        // than going through `insertText(_:replacementRange:)`, which is exactly
        // the bookkeeping a marked range depends on: moving characters out from
        // under it leaves the next composition update writing at an offset that
        // describes nothing (`insertConfiguredTab`'s guard, for its reason). The
        // save then writes the untransformed bytes and the next one — a keystroke
        // later, the composition long committed — transforms them.
        guard !textView.hasMarkedText(), let textStorage = textView.textStorage else { return false }

        let selection = (textView.selectedRanges as [NSValue]).map { plan.remappedRange($0.rangeValue) }
        let anchor = editor?.scrollAnchorOffset.map(plan.remappedOffset)

        // Which shape the edits take — the plan's own, or the one replacement
        // covering them — is the engine's arithmetic, not this class's
        // (`applicableReplacements(originalLength:)`). Collapsing costs nothing
        // here: `endEditing` already coalesces the edited ranges into a single
        // one, so the highlighter, the gutter and the minimap see the same edit
        // either way. Its one cost is that the untouched text inside the span is
        // re-attributed to `typingAttributes` until the highlighter repaints —
        // which it is about to do regardless, precisely because the coalesced
        // edited range already spans it.
        let edits = plan.applicableReplacements(originalLength: textStorage.length)
        let editedRanges = edits.map { NSValue(range: $0.range) }
        let replacements = edits.map(\.replacement)
        editor?.beginSaveTransformRewrite()
        defer { editor?.endSaveTransformRewrite() }
        // **The save is its own undo group, and that takes saying so.**
        // `NSTextView` coalesces successive typing into one open undo action, and
        // `shouldChangeText` below registers this rewrite into whichever action is
        // open — so without this call an autosave firing two seconds after the
        // user typed `foo` at the end of an unterminated file appends its
        // `insert_final_newline` terminator *into the typing action*, and the ⌘Z
        // that was supposed to restore the pre-save buffer takes `foo` with it.
        // Single-edit plans are exactly the ones this bites: a multi-range plan
        // usually breaks coalescing incidentally, one insertion adjacent to the
        // caret never does. Called before `shouldChangeText` because that is where
        // the undo action is registered, and again after `didChangeText` so the
        // *next* keystroke opens a new action instead of coalescing into the
        // save's — one break on each side is what makes the whole transform one
        // undoable step rather than merely the start of one.
        textView.breakUndoCoalescing()
        // The guards go up first (this call re-enters the delegate's own
        // interceptors), but the blame column and the diagnostics are dropped only
        // once the edit is permitted: a refusal here rewrites nothing, and
        // discarding both readers for a rewrite that never happened would leave
        // them empty with no change notification to re-publish them.
        guard textView.shouldChangeText(inRanges: editedRanges, replacementStrings: replacements) else {
            return false
        }
        editor?.resetIncrementalReadersForSaveTransform()
        // The replacements carry `typingAttributes` explicitly: the raw storage
        // path would otherwise inherit whatever the adjacent text has, and in a
        // buffer with no adjacent text, no font at all (`insertConfiguredTab`).
        let attributes = textView.typingAttributes
        textStorage.beginEditing()
        for edit in edits.reversed() {
            textStorage.replaceCharacters(
                in: edit.range,
                with: NSAttributedString(string: edit.replacement, attributes: attributes)
            )
        }
        textStorage.endEditing()
        textView.didChangeText()
        textView.breakUndoCoalescing()
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
        return true
    }
}

#endif
