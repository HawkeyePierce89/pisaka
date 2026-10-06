import Foundation

/// The Welcome screen's decisions: when it shows, which recent projects it
/// lists, what its rows and footer advertise, and what a keyboard selection
/// over its rows activates.
///
/// The screen replaces the window's tree + editor split when nothing is open,
/// with no folder and no tab. That makes it a front door rather than a mode: the
/// moment either exists, the workspace is back. Every value the app view draws
/// comes from here — titles, glyphs, chord strings, the recents list — so the
/// view only lays them out.
///
/// **What the screen advertises is pinned to the menus.** Each action and each
/// footer entry names the menu item it stands for (`menuTitle`) and the chord
/// that item carries; `WelcomeShortcutPinTests` reads `Sources/Pisaka` and
/// fails when the chord drifts. The same suite holds the footer to commands that
/// are **enabled with no folder open**, because that is the only state the
/// screen is ever drawn in, and advertising a dead shortcut there would be a lie.
public enum WelcomeScreen {
    /// How many recent projects the screen lists at most.
    public static let recentsCap = 10

    /// Whether the Welcome screen replaces the workspace: exactly when there is
    /// no project root and no open tab.
    public static func shows(projectRoot: URL?, openFileCount: Int) -> Bool {
        projectRoot == nil && openFileCount <= 0
    }

    /// The recent projects the screen lists, in the MRU order `RecentProject.rows`
    /// produced, capped at `cap`.
    ///
    /// A row marked `isCurrent` is dropped. The screen only shows with no folder
    /// open, so no row should be current; dropping one anyway keeps the list
    /// honest if a stale catalog says otherwise. An empty answer means the
    /// column shows its hint instead.
    public static func recents(_ rows: [RecentProject], cap: Int = recentsCap) -> [RecentProject] {
        Array(rows.lazy.filter { !$0.isCurrent }.prefix(max(0, cap)))
    }
}

/// A modifier key of a `WelcomeChord`. The raw value is the SwiftUI
/// `EventModifiers` member name, which is what the pin suite compares against.
public enum WelcomeModifier: String, CaseIterable, Sendable {
    case control
    case option
    case shift
    case command

    /// The macOS menu symbol.
    public var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

/// A key equivalent as a menu item declares it: one key character plus a set of
/// modifiers.
public struct WelcomeChord: Equatable, Hashable, Sendable {
    /// The key character as the menu declares it (`"o"`, `"+"`, `"-"`, `"0"`).
    public let key: Character
    /// The modifiers held with it.
    public let modifiers: Set<WelcomeModifier>

    public init(_ key: Character, _ modifiers: Set<WelcomeModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The chord as a menu draws it: modifiers in the macOS canonical order
    /// ⌃⌥⇧⌘, then the key upper-cased, with the minus key drawn as "−".
    public var display: String {
        let prefix = WelcomeModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined()
        let keyText = key == "-" ? "−" : String(key).uppercased()
        return prefix + keyText
    }
}

/// One row of the Welcome screen's actions column. Closed: each case is a menu
/// command that works with no folder open.
public enum WelcomeAction: CaseIterable, Sendable {
    case openFolder
    case openFile
    case newFile
    case openLeetCodeProblem

    /// The row's title.
    public var title: String {
        switch self {
        case .openFolder: return "Open Folder…"
        case .openFile: return "Open File…"
        case .newFile: return "New File"
        case .openLeetCodeProblem: return "Open LeetCode Problem…"
        }
    }

    /// The menu item this row stands for, spelled as its `Button` literal.
    public var menuTitle: String {
        switch self {
        case .openFolder: return "Open Folder…"
        case .openFile: return "Open…"
        case .newFile: return "New File"
        case .openLeetCodeProblem: return "Open Problem…"
        }
    }

    /// The row's glyph.
    public var glyph: DesignGlyph {
        switch self {
        case .openFolder: return .folderOpen
        case .openFile: return .fileText
        case .newFile: return .plus
        case .openLeetCodeProblem: return .fileCode
        }
    }

    /// The menu item's chord.
    public var chord: WelcomeChord {
        switch self {
        case .openFolder: return WelcomeChord("o", [.command, .shift])
        case .openFile: return WelcomeChord("o", [.command])
        case .newFile: return WelcomeChord("n", [.command])
        case .openLeetCodeProblem: return WelcomeChord("p", [.command, .option])
        }
    }
}

/// One footer entry: a label and one or more chords, each naming the menu item
/// it belongs to. Informational only — the screen implements none of them.
public enum WelcomeFooterEntry: CaseIterable, Sendable {
    case terminal
    case browseProblems
    case zoom

    /// One chord and the menu item it is pinned to.
    public struct Shortcut: Equatable, Sendable {
        public let chord: WelcomeChord
        public let menuTitle: String
    }

    /// The entry's label.
    public var label: String {
        switch self {
        case .terminal: return "Show Terminal"
        case .browseProblems: return "Browse Problems…"
        case .zoom: return "Zoom"
        }
    }

    /// The entry's chords, in display order.
    public var shortcuts: [Shortcut] {
        switch self {
        case .terminal:
            return [Shortcut(chord: WelcomeChord("t", [.command, .shift]), menuTitle: "Show Terminal")]
        case .browseProblems:
            return [Shortcut(chord: WelcomeChord("b", [.command, .shift]), menuTitle: "Browse Problems…")]
        case .zoom:
            return [
                Shortcut(chord: WelcomeChord("+", [.command]), menuTitle: "Zoom In"),
                Shortcut(chord: WelcomeChord("-", [.command]), menuTitle: "Zoom Out"),
                Shortcut(chord: WelcomeChord("0", [.command]), menuTitle: "Reset Zoom"),
            ]
        }
    }

    /// The chords as drawn, space-separated: "⌘+ ⌘− ⌘0".
    public var chordsDisplay: String {
        shortcuts.map(\.chord.display).joined(separator: " ")
    }

    /// The whole entry as one line: "Zoom ⌘+ ⌘− ⌘0".
    public var display: String {
        "\(label) \(chordsDisplay)"
    }
}

/// What activating a Welcome row does.
public enum WelcomeTarget: Equatable, Sendable {
    case action(WelcomeAction)
    case recent(URL)
}

/// Which column a Welcome row sits in.
public enum WelcomeColumn: Equatable, Sendable {
    case actions
    case recents
}

/// The keyboard selection over the Welcome screen's rows: the actions, then the
/// recents, as one flattened list over a `PopoverSelection`.
///
/// ↑/↓ move within the flattened list and clamp at both ends; switching
/// columns lands on the other column's first row, and does nothing when that
/// column is empty.
public struct WelcomeSelection: Equatable {
    /// The actions column, in display order.
    public let actions: [WelcomeAction]
    /// The recents column's urls, in display order.
    public let recents: [URL]
    /// The selection over the flattened list.
    public let selection: PopoverSelection

    public init(actions: [WelcomeAction] = WelcomeAction.allCases, recents: [URL]) {
        self.actions = actions
        self.recents = recents
        self.selection = PopoverSelection(count: actions.count + recents.count)
    }

    private init(actions: [WelcomeAction], recents: [URL], selection: PopoverSelection) {
        self.actions = actions
        self.recents = recents
        self.selection = selection
    }

    /// The selected flattened index, or `nil` when there are no rows.
    public var selectedIndex: Int? { selection.selectedIndex }

    /// One row down, staying on the last row.
    public func movedDown() -> WelcomeSelection {
        with(selection.movedDown())
    }

    /// One row up, staying on the first row.
    public func movedUp() -> WelcomeSelection {
        with(selection.movedUp())
    }

    /// The other column's first row, or unchanged when that column is empty.
    public func switchedColumn() -> WelcomeSelection {
        guard let index = selectedIndex else { return self }
        let target: Int
        switch column(of: index) {
        case .actions:
            guard !recents.isEmpty else { return self }
            target = actions.count
        case .recents:
            guard !actions.isEmpty else { return self }
            target = 0
        }
        return selecting(target)
    }

    /// The selection moved to flattened `index`, clamped to the rows.
    public func selecting(_ index: Int) -> WelcomeSelection {
        with(selection.selecting(index))
    }

    /// The column flattened `index` sits in.
    public func column(of index: Int) -> WelcomeColumn {
        index < actions.count ? .actions : .recents
    }

    /// What activating flattened `index` does, or `nil` outside the rows.
    public func target(at index: Int) -> WelcomeTarget? {
        guard index >= 0 else { return nil }
        if index < actions.count { return .action(actions[index]) }
        let recentIndex = index - actions.count
        guard recentIndex < recents.count else { return nil }
        return .recent(recents[recentIndex])
    }

    /// What Return activates: the selected row's target.
    public var selectedTarget: WelcomeTarget? {
        selectedIndex.flatMap(target(at:))
    }

    private func with(_ selection: PopoverSelection) -> WelcomeSelection {
        WelcomeSelection(actions: actions, recents: recents, selection: selection)
    }
}
