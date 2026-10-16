import Foundation

/// Which tab a tab-switch command selects: ⌘⇧] / ⌘⇧[ (and ⌃Tab / ⌃⇧Tab) move
/// to the adjacent tab, ⌘1…⌘8 select by position and ⌘9 selects the last tab.
///
/// A nil answer means there is nothing to select, and the app draws the menu
/// item disabled from that same answer.
public enum TabNavigationRule {
    /// The tab after (`forward`) or before the selected one, wrapping at both
    /// ends. Nil with fewer than two tabs — nothing to move to. A selection
    /// that is nil or not open answers the first tab forward, the last backward.
    public static func adjacent(in ids: [UUID], selected: UUID?, forward: Bool) -> UUID? {
        guard ids.count > 1 else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return forward ? ids.first : ids.last
        }
        let step = forward ? 1 : ids.count - 1
        return ids[(index + step) % ids.count]
    }

    /// The tab ⌘`number` selects: 1…8 the nth tab (nil past the count), 9 the
    /// last tab, anything outside 1…9 nil.
    public static func positional(_ number: Int, in ids: [UUID]) -> UUID? {
        switch number {
        case 1...8:
            return number <= ids.count ? ids[number - 1] : nil
        case 9:
            return ids.last
        default:
            return nil
        }
    }
}
