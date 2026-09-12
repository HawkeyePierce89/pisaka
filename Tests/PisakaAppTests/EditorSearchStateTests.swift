#if os(macOS)
import PisakaCore
import XCTest
@testable import Pisaka

/// `EditorSearchState`'s five recording sites — the ⌘F half of the shared search
/// query history.
///
/// **`swift test` is structurally blind to this**: the state lives in
/// `Sources/Pisaka` behind `#if os(macOS)`, so the Core gate cannot compile it,
/// and every decision it makes here is a *sequencing* one no Core test can see —
/// which gestures record, that they record `currentQuery` whole, that a dismissal
/// records once rather than once per redundant close, and that a gesture which is
/// inert with the bar closed records nothing. The one rule about the *value* (a
/// blank is refused, duplicates are promoted, the list is capped) is Core's and
/// is asserted in `SearchQueryHistoryTests`; this suite deliberately asserts the
/// opposite side of that split, namely that the state hands its query over
/// **without testing it**.
@MainActor
final class EditorSearchStateTests: XCTestCase {

    /// The editor's execution side, reduced to a call log. The state holds this
    /// weakly, so the test owns it for the duration.
    private final class ActionsSpy: EditorSearchActions {
        private(set) var calls: [String] = []

        func findNext() { calls.append("findNext") }
        func findPrevious() { calls.append("findPrevious") }
        func replaceCurrent() { calls.append("replaceCurrent") }
        func replaceAll() { calls.append("replaceAll") }
        func clearHighlight() { calls.append("clearHighlight") }
    }

    private var recorded: [SearchQuery] = []
    private var actions: ActionsSpy!
    private var state: EditorSearchState!

    override func setUp() {
        super.setUp()
        recorded = []
        actions = ActionsSpy()
        // `recorded` is captured by the closure the state keeps; the array itself
        // is the test's, so a strong capture of `self` would be the cycle. Append
        // through an unowned test reference instead.
        state = EditorSearchState(recordQuery: { [unowned self] query in self.recorded.append(query) })
        state.register(actions: actions)
    }

    override func tearDown() {
        state = nil
        actions = nil
        super.tearDown()
    }

    /// The bar as the user leaves it before pressing anything: open, with a
    /// pattern and all three toggles on, so a recording that drops one is visible.
    private func openWithAFullQuery() {
        state.open()
        state.pattern = "needle"
        state.caseSensitive = true
        state.wholeWord = true
        state.isRegex = true
    }

    private var fullQuery: SearchQuery {
        SearchQuery(pattern: "needle", isRegex: true, caseSensitive: true, wholeWord: true)
    }

    // MARK: - The four committing gestures

    func testEachCommittingGestureRecordsTheWholeCurrentQuery() {
        openWithAFullQuery()

        state.findNext()
        state.findPrevious()
        state.replaceCurrent()
        state.replaceAll()

        XCTAssertEqual(recorded, Array(repeating: fullQuery, count: 4))
        XCTAssertEqual(actions.calls, ["findNext", "findPrevious", "replaceCurrent", "replaceAll"])
    }

    /// Blankness is Core's rule, not the state's: the hook is called anyway, and
    /// `SearchQueryHistory.record(_:)` is what refuses the value. Asserting this
    /// is what keeps a well-meaning `guard !pattern.isEmpty` out of the app layer,
    /// where it would be a second, drifting copy of the rule.
    func testACommittingGestureAgainstAnEmptyFieldStillRecordsUnconditionally() {
        state.open()

        state.findNext()

        XCTAssertEqual(recorded, [SearchQuery(pattern: "")])
    }

    /// ⌘G / ⌘⇧G stay enabled for any text tab and do nothing with the bar closed —
    /// the controller clears instead of searching, so there is no match list to
    /// step — while `pattern` survives the close. Recording there would promote the
    /// last query back to the front of a list both menus draw, and rewrite the
    /// stored value, for a keystroke with no other effect.
    func testNavigationWithTheBarClosedForwardsButRecordsNothing() {
        openWithAFullQuery()
        state.close()
        recorded = []

        state.findNext()
        state.findPrevious()

        XCTAssertTrue(recorded.isEmpty)
        // The forwarding is unchanged: the command is inert because the controller
        // has nothing applied, not because the state withholds it.
        XCTAssertEqual(actions.calls.suffix(2), ["findNext", "findPrevious"])
    }

    // MARK: - The dismissal

    func testClosingTheBarRecordsOnce() {
        openWithAFullQuery()

        state.close()

        XCTAssertEqual(recorded, [fullQuery])
        XCTAssertEqual(actions.calls, ["clearHighlight"])
    }

    /// The recording sits *after* `close()`'s `isVisible` guard, so the three
    /// dismissal paths (Esc in the bar, Esc in the editor, the close button) can
    /// overlap — as Esc in the bar and Esc in the editor do — without recording
    /// twice.
    func testARedundantCloseRecordsNothing() {
        openWithAFullQuery()

        state.close()
        state.close()
        state.close()

        XCTAssertEqual(recorded, [fullQuery])
    }

    func testOpeningTheBarRecordsNothing() {
        state.pattern = "needle"

        state.open()
        state.openReplace()

        XCTAssertTrue(recorded.isEmpty)
    }
}

#endif
