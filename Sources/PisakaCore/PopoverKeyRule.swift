/// A key the popover has an opinion about. Closed: anything else — and any of
/// these carrying ⌘, ⌃ or ⌥ — is `other`.
public enum PopoverKey: CaseIterable, Equatable {
    case up
    case down
    case `return`
    case escape
    case left
    case right
    case other
}

/// What the popover knows when a key arrives.
public struct PopoverKeyState: Hashable {
    /// Whether the remote-row submenu is open.
    public let submenuOpen: Bool
    /// Whether any row is selected — in the submenu when it is open.
    public let hasSelection: Bool
    /// Whether the main list's selected row opens a submenu.
    public let selectedHasSubmenu: Bool

    public init(submenuOpen: Bool, hasSelection: Bool, selectedHasSubmenu: Bool) {
        self.submenuOpen = submenuOpen
        self.hasSelection = hasSelection
        self.selectedHasSubmenu = selectedHasSubmenu
    }
}

/// What a key does. Closed.
public enum PopoverKeyAction: Equatable {
    case moveUp
    case moveDown
    case activate
    case openSubmenu
    case closeSubmenu
    case dismiss
    /// The key is none of the popover's business: the event goes on unconsumed.
    case passThrough
}

/// Every decision about which key does what in which popover state.
///
/// The app layer only maps a key code to a `PopoverKey`, builds the state and
/// executes the answer; it holds no key logic of its own.
///
/// Two properties the table is built around:
///
/// - **`other` always passes through**, in every state, so typing keeps
///   reaching the filter field, which keeps the text focus throughout.
/// - **`selectedHasSubmenu` without `hasSelection` is impossible**, and is read
///   as no selection: a row that is not selected cannot be asked what it opens.
public enum PopoverKeyRule {
    public static func action(for key: PopoverKey, state: PopoverKeyState) -> PopoverKeyAction {
        let selected = state.hasSelection
        if state.submenuOpen {
            switch key {
            case .up: return selected ? .moveUp : .passThrough
            case .down: return selected ? .moveDown : .passThrough
            case .return: return selected ? .activate : .passThrough
            case .escape, .left: return .closeSubmenu
            case .right, .other: return .passThrough
            }
        }
        let opensSubmenu = selected && state.selectedHasSubmenu
        switch key {
        case .up: return selected ? .moveUp : .passThrough
        case .down: return selected ? .moveDown : .passThrough
        case .return:
            if opensSubmenu { return .openSubmenu }
            return selected ? .activate : .passThrough
        case .right: return opensSubmenu ? .openSubmenu : .passThrough
        case .left, .other: return .passThrough
        case .escape: return .dismiss
        }
    }
}
