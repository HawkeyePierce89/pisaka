#if os(macOS)
import Foundation

/// A one-shot "show me *this* range of *this* tab" request, used by the Find in
/// Files window when the user activates a result row.
///
/// Window-scoped and owned by `PisakaApp`, like `EditorSearchState`: the request
/// outlives the editor view it targets, because activating a match may *open* the
/// file, and the `CodeEditorView` that will show it does not exist yet at that
/// moment. The app therefore opens the tab, resolves its id, and records the
/// request here; the editor consumes it on its next update — which is the same
/// update that installs the file's contents, so the selection always lands on the
/// text it was computed against.
///
/// Thin view-layer state (untested like the rest of `Sources/Pisaka`): it holds a
/// value and a token, decides nothing, and touches no text view.
@MainActor
final class EditorRevealState: ObservableObject {
    /// One pending reveal.
    ///
    /// `token` is what makes the request *one-shot*: the editor records the token
    /// it last applied, so a view update triggered by anything else (a keystroke,
    /// a font change) does not re-select the range and yank the caret back.
    /// Comparing the *value* would not do — activating the same match twice is a
    /// legitimate second request.
    struct Request: Equatable {
        /// The tab the range belongs to. An editor showing a different file
        /// ignores the request rather than selecting a range of someone else's
        /// text.
        let fileID: UUID
        /// The UTF-16 range to select and scroll to, in the coordinates of the
        /// file's contents as searched.
        let range: NSRange
        /// Monotonic, assigned by `reveal(fileID:range:)`.
        let token: Int
    }

    @Published private(set) var request: Request?

    private var nextToken = 0

    /// Ask the editor showing `fileID` to select `range` and scroll it into view.
    func reveal(fileID: UUID, range: NSRange) {
        nextToken += 1
        request = Request(fileID: fileID, range: range, token: nextToken)
    }
}

#endif
