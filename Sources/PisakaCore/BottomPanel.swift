/// Which bottom dock panel is currently shown.
///
/// The Terminal, Log, Local Changes, Problems, Usages and Pull Requests are
/// bottom dock panels above an always-visible bar; a `BottomPanel?` of `nil`
/// means the panel is hidden. The view layer owns the bar and the panels; this
/// enum plus the pure `toggled(_:selecting:)` helper are the only stateful
/// logic, so they live in Core and are unit-tested (the color-free / pure-logic
/// precedent of `FileIconColor`/`LogFilter`).
///
/// **The declaration order is the order on screen**, read through `allCases`:
/// the bottom bar's toggles and the dock's tab row both list the panels in it,
/// and neither keeps a second list. What each strip draws for a panel is a
/// column of the same table — `title` (both strips) and `systemImage` (the
/// bar's icon-only toggle) — so adding, removing or reordering a case changes
/// both strips at once.
public enum BottomPanel: Equatable, CaseIterable, Sendable {
    case terminal
    case log
    case changes
    case problems
    /// Where the identifier under the caret is used — the Find Usages answer.
    ///
    /// A sibling of Problems rather than a mode of it: both are lists of places
    /// in the project, but one is what a server volunteered about the code and
    /// the other is what the user asked about one name, so the two must be
    /// reachable at once (reading a usage list while a diagnostic is on screen is
    /// the ordinary case, not a conflict).
    case usages

    /// The repository's open pull requests, as GitHub answers for them.
    ///
    /// A sibling of Log and Local Changes rather than a mode of either: it is the
    /// same repository read through a second tool (the user's own `gh`), and the
    /// ordinary reason to open it — checking what a branch's checks say while the
    /// branch is being worked on — is a reason to have the editor and one of the
    /// git panels on screen at the same time, not instead of it.
    case pullRequests

    /// The one name of a panel: what the bottom bar's toggle says in its tooltip
    /// and accessibility label, and what the dock's tab row draws on its tab.
    /// Both read this, so the two can never disagree.
    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .log: "Log"
        case .changes: "Local Changes"
        case .problems: "Problems"
        case .usages: "Usages"
        case .pullRequests: "Pull Requests"
        }
    }

    /// The SF Symbol name the bottom bar's icon-only toggle draws for the panel.
    ///
    /// A symbol name is a string, as `FileIcon`'s is, so this stays
    /// Foundation-only and colour-free; the bar reads it alongside `title`.
    public var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .log: "arrow.triangle.branch"
        case .changes: "arrow.triangle.pull"
        case .problems: "exclamationmark.triangle"
        case .usages: "text.magnifyingglass"
        // `arrow.triangle.merge` rather than `arrow.triangle.pull`, which Local
        // Changes three toggles to the left already uses: two dock toggles
        // drawn with one glyph are indistinguishable at a glance, and with the
        // labels gone the glyph is all there is.
        case .pullRequests: "arrow.triangle.merge"
        }
    }

    /// What a click on the dock's tab for `tab` does while `current` is showing.
    ///
    /// **A tab selects and never collapses**: the tab of the panel already on
    /// screen answers `.alreadyShowing`, and any other tab — or any tab while
    /// nothing is showing — answers `.show(tab)`, which the caller hands to the
    /// same funnel the bar's toggles use (`toggled(_:selecting:)` then yields
    /// the target, never `nil`). Collapsing the dock is the bar's toggle's job
    /// and the row's close action's, not a tab's.
    public static func tabActivation(_ current: BottomPanel?, tab: BottomPanel) -> DockTabActivation {
        current == tab ? .alreadyShowing : .show(tab)
    }

    /// Toggle the panel for a clicked/triggered `target`: clicking the panel
    /// that is already shown collapses it (`nil`), otherwise the `target` panel
    /// is shown — so a button or its matching menu command behaves identically.
    public static func toggled(_ current: BottomPanel?, selecting target: BottomPanel) -> BottomPanel? {
        current == target ? nil : target
    }
}

/// The answer of `BottomPanel.tabActivation(_:tab:)`.
///
/// Deliberately **not** a second `BottomPanel?`. `toggled(_:selecting:)`
/// already returns one whose `nil` means "collapse the dock"; a sibling whose
/// `nil` meant "nothing to do" could be handed to `toggled`'s `current:`
/// parameter and compile, reading "nothing to do" as "no panel showing". A
/// distinct type makes that mistake a compile error rather than a test's job.
public enum DockTabActivation: Equatable, Sendable {
    /// Show this panel, through the bar's own funnel.
    case show(BottomPanel)
    /// The clicked tab's panel is already on screen; nothing happens.
    case alreadyShowing
}
