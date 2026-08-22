import CoreGraphics

/// What a mouse-down means to an open inline-naming draft in the project tree.
///
/// Two cases, and neither of them is about the *click*: this rule decides the
/// draft's fate only. See "`cancel` is not a swallow" on `TreeDraftDismissRule`.
public enum TreeDraftClickDecision: Equatable {
    /// The draft stays open. The click is none of its business.
    case ignore
    /// The draft is cancelled — silently, creating and renaming nothing.
    case cancel
}

/// The one rule that decides whether a mouse-down cancels the project tree's
/// open inline-naming draft.
///
/// The draft (`ProjectTreeDraftField`) is an `NSTextField` inside a SwiftUI row
/// that no other tree row can take first responder away from — a row is a plain
/// SwiftUI view, so `controlTextDidEndEditing` never fires for a click on one.
/// The view layer therefore keeps a local `.leftMouseDown`/`.rightMouseDown`
/// monitor alive for exactly as long as a draft is, and asks this rule what each
/// event means. Everything the rule needs is an AppKit *fact* — which window the
/// event came from, where in the draft's own coordinates it landed, and how big
/// the draft is — so no policy is left in the view.
///
/// ## The three answers
///
/// - **Another window → `ignore`.** Find in Files, a diff window, an alert or the
///   Preferences window each own their clicks; a draft in the project window has
///   no opinion about them, and cancelling on one would destroy a half-typed name
///   because the user reached for a different window. (Nor does the *app* losing
///   activation cancel: a local monitor sees no other app's events at all, so
///   ⌘Tab away and back preserves the draft for free.)
/// - **Inside the draft → `ignore`.** Clicking the field to place the caret, or
///   dragging to select, is an ordinary edit. So is clicking the draft's icon
///   column or its validation-reason line — which is why the caller measures the
///   *whole* draft, not the text field (see "What `draftBounds` is").
/// - **Anything else in the draft's own window → `cancel`.** Another tree row,
///   the editor, a tab, the bottom bar: the user's attention moved, and the
///   Finder-like answer is to end the naming silently rather than to commit
///   something they stopped looking at.
///
/// ## `cancel` is not a swallow
///
/// A cancelled draft does **not** consume the event: the monitor returns it
/// unchanged, so the click also does what it would have done anyway — the folder
/// toggles, the file opens, the right-clicked row gets its context menu. This is
/// Finder's behaviour (and Zed's), and the alternative would charge the user two
/// clicks for one intent. Cancelling is a SwiftUI state change, which invalidates
/// layout for the *next* display pass, so the click AppKit dispatches
/// immediately after the monitor returns still hit-tests the geometry the user
/// was looking at: the row that shifts up once the draft disappears is not the
/// row that gets the click.
///
/// ## What `draftBounds` is
///
/// The rectangle is the draft's *whole* region — icon column, text field and
/// reason line — expressed in the same coordinate space as `point`. The view
/// layer gets both from one invisible `NSView` installed as the draft's
/// outermost `.background`: SwiftUI sizes a background to its primary view, so
/// that view's `bounds` **is** the draft's rectangle by construction, and
/// `convert(_:from: nil)` puts the event in the same space. Nothing here needs
/// to know about flipped coordinates, and the "clicking the icon does not
/// cancel" behaviour holds without a measured inset.
///
/// ## Edges, and the degenerate rectangle
///
/// Containment is `CGRect.contains(_:)` — half-open, so the origin edges are
/// inside and the bottom/right edges are outside. A one-point disagreement at a
/// boundary is invisible to a user and not worth a bespoke rule; matching
/// AppKit's own convention is what keeps this predictable.
///
/// An empty or null rectangle is `cancel`: a draft with no measured area cannot
/// own a click. That is not a theoretical case — it is the state between the
/// draft appearing and its first layout pass, and treating it as "inside" would
/// make the draft briefly uncancellable, which is the worse failure.
public enum TreeDraftDismissRule {

    /// Decide what a mouse-down does to the open draft.
    ///
    /// - Parameters:
    ///   - clickedWindowIsDraftWindow: whether the event's window is the window
    ///     the draft lives in. The caller compares object identity; an event with
    ///     no window at all is not the draft's window and so is `false`.
    ///   - point: the event location converted into the draft region's own
    ///     coordinates. Meaningful only when the window matches, and ignored
    ///     otherwise.
    ///   - draftBounds: the draft region's `bounds` — the whole draft, in that
    ///     same space.
    public static func decision(
        clickedWindowIsDraftWindow: Bool,
        point: CGPoint,
        draftBounds: CGRect
    ) -> TreeDraftClickDecision {
        guard clickedWindowIsDraftWindow else { return .ignore }
        // `contains` already answers `false` for an empty or null rect, so the
        // degenerate case needs no branch of its own — it falls out as `cancel`,
        // which is the documented answer.
        return draftBounds.contains(point) ? .ignore : .cancel
    }
}
