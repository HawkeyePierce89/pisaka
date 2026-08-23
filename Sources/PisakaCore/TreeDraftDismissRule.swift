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
/// The view layer therefore keeps a local
/// `.leftMouseDown`/`.leftMouseUp`/`.rightMouseDown`
/// monitor alive for exactly as long as a draft is, and asks this rule what each
/// event means. Everything the rule needs is an AppKit *fact* — which window the
/// event came from, whether it landed in that window's content area at all,
/// where in the draft's own coordinates it landed, and how big the draft is — so
/// no policy is left in the view.
///
/// ## The four answers
///
/// - **Another window → `ignore`.** Find in Files, a diff window, an alert or the
///   Preferences window each own their clicks; a draft in the project window has
///   no opinion about them, and cancelling on one would destroy a half-typed name
///   because the user reached for a different window. (Nor does the *app* losing
///   activation cancel: a local monitor sees no other app's events at all, so
///   ⌘Tab away and ⌘Tab back preserves the draft for free. Coming back by
///   *clicking* the window is a different thing — that click is this app's own,
///   the monitor sees it, and it cancels like any other click outside the draft;
///   it is stated again under the chrome answer, with the other limit of that
///   kind.)
/// - **Inside the draft → `ignore`.** Clicking the field to place the caret, or
///   dragging to select, is an ordinary edit. So is clicking the draft's own
///   icon column or its validation-reason line — which is why the caller
///   measures the *whole* draft, not the text field (see "What `draftBounds`
///   is").
/// - **The window's chrome → `ignore`.** A click on the title bar, the traffic
///   lights or the toolbar lands in the draft's own window and outside the
///   draft, but the user is moving or minimising the window they are typing in —
///   their attention did not move at all. Finder does not abandon an inline
///   rename when the window is dragged, and silently destroying a half-typed
///   name for it would be the worst kind of surprise. The caller answers this
///   with one fact: did the click land inside the window's *content* area.
///
///   That fact draws the line where AppKit draws it, which leaves **two stated
///   limits**, both of them clicks that land in the content area and therefore
///   `cancel`. A **resize drag** begun from the content side of the bottom, left
///   or right edge is one: the few points where AppKit starts a resize instead
///   of delivering the click to a view are inside that rectangle, and at
///   mouse-down there is no fact that separates them from an ordinary click on
///   whatever is drawn there — guessing at a band would instead make real clicks
///   near the pane's left edge stop cancelling, which is the worse error. (The
///   *top* edge is the title bar, so resizing from it is already exempt. And
///   because a resize *drag* takes the mouse over from its own down, that
///   answer is one the view layer never gets to apply — see the deferral limit
///   below.) The
///   **activating click** that brings the app back to the front is the other:
///   see the note on ⌘Tab above — the monitor sees no other app's events, but it
///   does see the click that returns to this one.
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
/// clicks for one intent.
///
/// One row is the exception, and by construction rather than by oversight: the
/// **drafted row itself** carries no context menu while its draft is open (a
/// menu that empties itself instead flashes an empty panel shut, so the view
/// layer omits the modifier). Right-clicking it beside the field — its icon, its
/// chevron column, its padding — is outside the draft, so the rule answers
/// `cancel` and the draft ends, but AppKit resolves the menu in that same
/// dispatch, before the row has been re-rendered with one. Nothing opens; the
/// next right-click gets the ordinary menu. It is the one place the sentence
/// above does not reach.
///
/// This rule answers a *point*, and the view layer reads that point from the
/// mouse-**down** — the position the user aimed at, and the one fact that keeps
/// a text-selection drag out of the field from reading as a click elsewhere.
/// *Applying* the answer is a separate moment, and for a left-click it is the
/// matching mouse-**up**: a SwiftUI tap completes only when the release is still
/// inside the view the press began in, while cancelling removes a create draft's
/// row (and a rename draft's reason line) and shifts every row below it up. Were
/// the cancel run on the down, that shift would land in the middle of the click
/// and the row the user pressed would no longer be under the release. A
/// right-click needs no such wait — `NSMenu` opens on the down.
///
/// Waiting has one cost, and it is a **stated limit**: a left-click whose
/// mouse-**up** the monitor never sees leaves the draft standing. AppKit
/// gestures that take the mouse over from their own mouse-down run a modal
/// tracking loop that dequeues events itself instead of letting them through
/// `NSApp.sendEvent`, so the local monitor hears the down — answered `cancel`
/// here — and never the release that would apply it. A window resize begun in
/// the band along the content area's own edges is one such gesture; a
/// project-tree row drag (every row but the drafted one is a drag source) is the
/// other. The answer is unapplied rather than lost: the draft stays open,
/// editable and cancellable by Esc or by the next click outside it, and a drag
/// that moves the drafted row's own entry drops the draft anyway when the tree
/// re-reads that directory. Applying the cancel on the down instead would trade
/// this edge for the far commoner one above, which is the whole reason to wait.
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
/// Two consequences of *by construction* are worth stating, because both are
/// the geometry answering rather than a rule bending:
///
/// - The caller passes the **visible** part of that rectangle
///   (`bounds.intersection(visibleRect)`). The tree scrolls, and a draft
///   scrolled out of the clip view keeps a rectangle that maps over the pane's
///   header and its neighbours; clipped away, the draft owns none of those
///   clicks, and a fully scrolled-out draft lands on the degenerate case below.
/// - Only a **create** draft draws an icon column of its own. A *rename* draft
///   sits inside the row that already draws one, so that icon — and the row's
///   padding around the field — belongs to the row, is outside the rectangle,
///   and a click there cancels like any other click on the row.
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
    ///   - clickedInsideWindowContent: whether the event landed inside that
    ///     window's content area. `false` is the window's chrome — title bar,
    ///     traffic lights, toolbar — and *not* the resize band along the content
    ///     area's own edges, which is inside it (the limit stated above).
    ///     Meaningful only when the window matches, and a window with no content
    ///     view at all answers `false`, which preserves the draft rather than
    ///     destroying it on a state that cannot occur. The caller measures
    ///     `NSWindow.contentLayoutRect`, which is the one AppKit rectangle that
    ///     excludes the title bar even under `fullSizeContentView` — the style a
    ///     plain SwiftUI window carries, and under which the content view itself
    ///     spans the title bar and would answer `true` for every drag of it.
    ///   - point: the event location converted into the draft region's own
    ///     coordinates. Meaningful only when the window matches, and ignored
    ///     otherwise.
    ///   - draftBounds: the draft region's rectangle — the whole draft, clipped
    ///     to what is visible, in that same space.
    public static func decision(
        clickedWindowIsDraftWindow: Bool,
        clickedInsideWindowContent: Bool,
        point: CGPoint,
        draftBounds: CGRect
    ) -> TreeDraftClickDecision {
        guard clickedWindowIsDraftWindow else { return .ignore }
        // Ahead of the rectangle, and therefore ahead of the degenerate case
        // below: a window dragged by its title bar before the draft has laid out
        // must not be the one click that destroys the name.
        guard clickedInsideWindowContent else { return .ignore }
        // `contains` already answers `false` for an empty or null rect, so the
        // degenerate case needs no branch of its own — it falls out as `cancel`,
        // which is the documented answer.
        return draftBounds.contains(point) ? .ignore : .cancel
    }
}
