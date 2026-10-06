/// The keyboard selection over a popover's rows: a row count and the selected
/// index, or none when there are no rows.
///
/// Moving clamps at both ends — there is no wrap — and a reset returns to the
/// first row, which is what happens whenever the popover's filter changes. The
/// popover's submenu uses the same type over its own rows.
public struct PopoverSelection: Equatable {
    /// How many rows there are to select from.
    public let count: Int
    /// The selected row's index, or `nil` when `count` is zero.
    public let selectedIndex: Int?

    /// Selects the first row, or nothing when there are no rows.
    public init(count: Int) {
        self.count = max(0, count)
        self.selectedIndex = self.count > 0 ? 0 : nil
    }

    private init(count: Int, selectedIndex: Int?) {
        self.count = count
        self.selectedIndex = selectedIndex
    }

    /// One row down, staying on the last row.
    public func movedDown() -> PopoverSelection {
        guard let index = selectedIndex else { return self }
        return PopoverSelection(count: count, selectedIndex: min(index + 1, count - 1))
    }

    /// One row up, staying on the first row.
    public func movedUp() -> PopoverSelection {
        guard let index = selectedIndex else { return self }
        return PopoverSelection(count: count, selectedIndex: max(index - 1, 0))
    }

    /// Row `index`, clamped to the rows; nothing when there are no rows.
    public func selecting(_ index: Int) -> PopoverSelection {
        guard count > 0 else { return self }
        return PopoverSelection(count: count, selectedIndex: min(max(index, 0), count - 1))
    }

    /// Back to the first row of `count` rows — the answer after any filter
    /// change, wherever the selection was.
    public func reset(count: Int) -> PopoverSelection {
        PopoverSelection(count: count)
    }
}
