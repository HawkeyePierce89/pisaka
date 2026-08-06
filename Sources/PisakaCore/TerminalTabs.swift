import Foundation

/// Pure, testable tab-bookkeeping for the embedded terminal's session list.
///
/// The live `TerminalSession`s and their PTYs are owned by the view layer
/// (`TerminalSessionsModel`); only this index math — which tab becomes active
/// after one is closed — lives in Core so it stays Foundation-only and
/// unit-tested, like `TerminalLaunch`.
public enum TerminalTabs {
    /// The id to activate after closing `closingID`, given the tab `order` *before*
    /// removal and the currently `active` id.
    ///
    /// - Closing the active tab selects its left neighbor — or, when the first tab
    ///   is closed, the tab that becomes the new first — and `nil` when the list
    ///   becomes empty.
    /// - Closing a non-active tab, or an id not present in `order`, leaves the
    ///   selection unchanged (returns `active`).
    public static func activeIDAfterClosing(
        _ closingID: UUID,
        order: [UUID],
        active: UUID?
    ) -> UUID? {
        guard let index = order.firstIndex(of: closingID) else { return active }
        guard active == closingID else { return active }
        var remaining = order
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }
        return remaining[max(0, index - 1)]
    }
}
