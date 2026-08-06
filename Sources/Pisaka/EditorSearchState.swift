#if os(macOS)
import Foundation
import PisakaCore

/// What the search bar can ask the editor to do.
///
/// The four navigation/replace commands plus the highlight teardown, so the bar
/// (and the Find menu, which drives the same state) never needs a reference to
/// the text view or the layout manager. `EditorSearchController` is the sole
/// conformer; `EditorSearchState` holds it **weakly** — the editor's coordinator
/// owns the controller for the lifetime of the text view, while the state
/// outlives every tab, so a strong reference here would pin a torn-down editor.
@MainActor
protocol EditorSearchActions: AnyObject {
    func findNext()
    func findPrevious()
    func replaceCurrent()
    func replaceAll()
    /// Drop the match highlight (the bar closed, or the editor is going away).
    func clearHighlight()
}

/// The find/replace bar's observable state: the fields and toggles the user
/// edits, the counters the controller publishes back, and the two commands
/// (`open`/`close`) the Find menu drives.
///
/// Window-scoped and owned by `PisakaApp`, not by the editor: the bar's contents
/// and toggles survive a tab switch (JetBrains/VS Code behavior), so the state
/// cannot live in `CodeEditorView`'s coordinator, which is rebuilt with the view.
/// Everything *executed* lives in `EditorSearchController` behind
/// `EditorSearchActions`; this type holds no `NSTextView`, no ranges and no
/// engine call — only what SwiftUI renders.
@MainActor
final class EditorSearchState: ObservableObject {
    /// Whether the bar is shown above the editor. `false` also means "no
    /// highlight": the controller clears its ranges when the bar closes.
    @Published var isVisible = false

    /// Whether the replace row (field + `Replace`/`Replace All`) is expanded.
    /// Kept separate from `isVisible` so ⌘F and ⌘⌥F open the same bar in two
    /// shapes, and so collapsing the row doesn't close the search.
    @Published var isReplaceExpanded = false

    /// The search pattern — literal text, or a regular expression when `isRegex`.
    @Published var pattern = ""

    /// The replacement template. For a regex query, `$1`/`$0` group references
    /// are substituted by `TextSearchEngine`; for a literal query it is inserted
    /// verbatim.
    @Published var template = ""

    /// The `Aa` toggle.
    @Published var caseSensitive = false

    /// The `ab` toggle.
    @Published var wholeWord = false

    /// The `.*` toggle.
    @Published var isRegex = false

    /// How many matches the current query has in the current buffer. `0` while
    /// the pattern is empty or invalid.
    @Published private(set) var matchCount = 0

    /// The 0-based index of the match the editor considers current (the bar
    /// displays it 1-based). `nil` when there is nothing to step to.
    @Published private(set) var currentIndex: Int?

    /// The reason the query could not run — an invalid regular expression's own
    /// message — shown inline in red. An *empty* pattern is deliberately not an
    /// error: it is incomplete input, not a mistake, so it leaves this `nil` and
    /// only blanks the counter.
    @Published private(set) var errorText: String?

    /// Monotonic token the bar watches to take focus and select the field's
    /// contents. Bumped by `open()`, so a repeated ⌘F while the bar is already
    /// open re-focuses and selects rather than doing nothing.
    @Published private(set) var focusRequest = 0

    /// The editor's execution side, registered by `CodeEditorView`'s coordinator
    /// when it attaches the controller. Weak — see `EditorSearchActions`. `nil`
    /// while no editor is mounted (no file open), which makes every command a
    /// no-op rather than a crash.
    private weak var actions: EditorSearchActions?

    /// The query the toggles and the pattern field currently describe.
    var currentQuery: SearchQuery {
        SearchQuery(
            pattern: pattern,
            isRegex: isRegex,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord
        )
    }

    /// Whether there is a match to step to or replace (drives the bar's buttons).
    var hasMatches: Bool { matchCount > 0 }

    /// Show the bar (or re-focus it) and select its contents — ⌘F.
    func open() {
        isVisible = true
        focusRequest += 1
    }

    /// Show the bar with the replace row expanded — ⌘⌥F.
    func openReplace() {
        isReplaceExpanded = true
        open()
    }

    /// Hide the bar and drop the highlight — Esc, in the bar or in the editor.
    ///
    /// The controller is told directly rather than being left to notice
    /// `isVisible` on the next view update: the clear must land whether or not a
    /// SwiftUI pass follows (there may be no editor update scheduled), and the
    /// controller's own `isVisible` check keeps the two paths idempotent.
    func close() {
        guard isVisible else { return }
        isVisible = false
        actions?.clearHighlight()
    }

    /// Bind the editor's execution side. Called by the coordinator on attach; a
    /// later editor (a new tab's view) replaces the previous one.
    func register(actions: EditorSearchActions) {
        self.actions = actions
    }

    /// Unbind `actions` if — and only if — it is still the registered one, so a
    /// torn-down editor cannot unregister the editor that replaced it.
    func unregister(actions: EditorSearchActions) {
        if self.actions === actions { self.actions = nil }
    }

    // MARK: - Commands (forwarded to the editor)

    func findNext() { actions?.findNext() }
    func findPrevious() { actions?.findPrevious() }
    func replaceCurrent() { actions?.replaceCurrent() }
    func replaceAll() { actions?.replaceAll() }

    // MARK: - Results (published by the controller)

    /// Publish a completed search's outcome.
    ///
    /// Unchanged values are dropped rather than re-assigned: the controller
    /// re-runs on every keystroke and every editor update, and each `@Published`
    /// write invalidates `ContentView` — which calls `updateNSView`, which asks
    /// the controller to refresh again. Skipping the no-op write is what makes
    /// that loop settle after one pass.
    func updateResults(matchCount: Int, currentIndex: Int?, errorText: String?) {
        if self.matchCount != matchCount { self.matchCount = matchCount }
        if self.currentIndex != currentIndex { self.currentIndex = currentIndex }
        if self.errorText != errorText { self.errorText = errorText }
    }
}

#endif
