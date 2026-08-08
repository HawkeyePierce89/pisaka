#if os(iOS)
import Foundation
import PisakaCore

/// The navigation half of Go to Definition on iOS — the peer of the macOS
/// `activateSearchMatch` + `EditorRevealState` pair, collapsed into one object
/// because iOS has neither a menu bar to drive the jump nor a window-scoped state
/// container to route it through.
///
/// **Why the text view does not navigate itself.** Opening (or re-selecting) the
/// tab a declaration lives in is the *root view's* job: it owns the
/// `WorkspaceModel`, the compact-width navigation stack, and the security scope
/// the read happens under. The editor coordinator only knows an offset and can
/// only ask. So this reference type sits between them — the shape `DiffRoute_iOS`
/// and `MergeRoute_iOS` already establish for "a screen the root presents on
/// someone else's behalf" — held by `RootView_iOS`, which installs `openFile` and
/// presents the disambiguation dialog.
///
/// It carries the two things that cannot live in either end:
/// - `choices`, the >1-candidate list the root shows as a confirmation dialog;
/// - `reveal`, the one-shot, token-guarded "select this range in this tab"
///   request the editor consumes on its next update — verbatim the macOS
///   `EditorRevealState.Request` contract, and for the same reason: activating a
///   definition may *open* the file, so the `CodeEditorView_iOS` that will show it
///   does not exist yet at the moment the jump is decided.
///
/// Thin view-layer glue, untested by convention: the candidates arrive already
/// ranked from `SymbolIntelligenceProvider`, and their row text is
/// `DefinitionCandidate.displayLabel`, so both platforms show the same string and
/// this file decides nothing about it.
@MainActor
final class DefinitionRoute_iOS: ObservableObject {

    /// A pending "select this range in this tab" request.
    ///
    /// `token` is what makes it one-shot: the editor records the token it last
    /// applied, so an unrelated view update (a keystroke, a rotation) does not
    /// re-select the range and yank the caret back. Comparing the *value* would
    /// not do — jumping to the same declaration twice is a legitimate second
    /// request.
    struct Reveal: Equatable {
        /// The tab the range belongs to; an editor showing another file ignores it.
        let fileID: UUID
        /// The declaration's name range (UTF-16), as the index recorded it.
        let range: NSRange
        /// Monotonic, assigned by `navigate(to:)`.
        let token: Int
    }

    /// One row of the disambiguation dialog. `id` is the candidate's position in
    /// the ranked list rather than anything derived from the symbol: two overloads
    /// can share a name, a file *and* a line, and a `ForEach` over colliding ids
    /// would drop rows the provider deliberately kept.
    struct Choice: Identifiable {
        let candidate: DefinitionCandidate
        let id: Int
    }

    /// The candidates awaiting a tap, or empty when no dialog is up.
    @Published var choices: [Choice] = []

    /// The reveal the editor should apply, or `nil` before the first jump.
    @Published private(set) var reveal: Reveal?

    /// Opens (or re-selects) the tab for a URL and answers its id, or `nil` when
    /// the file could not be read. Installed by `RootView_iOS`; `nil` until then,
    /// which makes a jump a no-op rather than a crash in a preview.
    var openFile: ((URL) -> UUID?)?

    private var nextToken = 0

    /// Act on what the provider answered: nothing, one jump, or a choice.
    ///
    /// The zero case is deliberately quiet — a light haptic and no alert. The user
    /// tapped a word the index does not know (a keyword, a name from a dependency,
    /// a language with no `symbols.scm`), which is an ordinary outcome of asking,
    /// not an error worth a modal.
    func present(_ candidates: [DefinitionCandidate]) {
        switch candidates.count {
        case 0:
            PlatformFeedback.light()
        case 1:
            navigate(to: candidates[0])
        default:
            choices = candidates.enumerated().map { Choice(candidate: $1, id: $0) }
        }
    }

    /// Open the declaration's file and ask its editor to select the name range.
    ///
    /// A declaration in the file already being edited takes this same path — the
    /// tab open is a re-selection and the reveal moves the caret — so a local jump
    /// and a cross-file one are one code path, exactly as on macOS.
    func navigate(to candidate: DefinitionCandidate) {
        choices = []
        guard let openFile, let id = openFile(candidate.symbol.fileURL) else {
            // The index named a file the workspace cannot open — it was deleted or
            // moved since the last walk. Nothing to reveal.
            PlatformFeedback.warning()
            return
        }
        nextToken += 1
        reveal = Reveal(fileID: id, range: candidate.symbol.range, token: nextToken)
    }

    /// Retire the reveal an editor has just applied.
    ///
    /// The token guard on the coordinator alone is **not** enough to keep the
    /// request one-shot, because that guard dies with the coordinator: on compact
    /// width the editor lives in a `navigationDestination`, so popping back to the
    /// tree tears the text view down and re-entering builds a fresh coordinator
    /// whose `appliedRevealToken` is back to `0`. A request left standing here
    /// would then be applied a second time — caret yanked, range re-selected, view
    /// scrolled — on a screen the user opened for an unrelated reason. Clearing it
    /// at the source is the only place that survives the teardown.
    ///
    /// Guarded by the token so a *newer* jump, issued between the editor's deferred
    /// application and this call, is not thrown away.
    func consumeReveal(token: Int) {
        guard reveal?.token == token else { return }
        reveal = nil
    }

    /// Dismiss the disambiguation dialog without jumping.
    func cancelChoices() {
        choices = []
    }
}
#endif
