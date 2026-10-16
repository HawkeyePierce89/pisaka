import Foundation

/// The tab menu's five close commands.
public enum TabCloseCommand: CaseIterable, Sendable {
    case close
    case closeOthers
    case closeToTheRight
    case closeAll
    case closeSaved
}

/// Which tabs a batch close affects, where its walk stops, and which items of a
/// tab's context menu are enabled.
///
/// The app routes every batch through its one close funnel; this rule only
/// names the targets and the order. A Cancel in the funnel's Save / Don't Save
/// / Cancel prompt stops the batch, leaving that tab and every later one open —
/// `walk` is the single statement of that. Close Saved needs no special case:
/// its targets are clean, so the funnel never prompts for them.
public enum TabCloseRule {
    /// The ids `command` closes, anchored on the tab `anchor`, always in tab
    /// order. An anchor that is not open answers `[]` for every command.
    public static func targets(_ command: TabCloseCommand, in files: [OpenFile], anchor: UUID) -> [UUID] {
        guard let index = files.firstIndex(where: { $0.id == anchor }) else { return [] }
        switch command {
        case .close:
            return [anchor]
        case .closeOthers:
            return files.filter { $0.id != anchor }.map(\.id)
        case .closeToTheRight:
            return files[(index + 1)...].map(\.id)
        case .closeAll:
            return files.map(\.id)
        case .closeSaved:
            return files.filter { !$0.isDirty }.map(\.id)
        }
    }

    /// Calls `closing` for each target in order and stops at the first `false`
    /// (the user cancelled that tab's prompt). Answers the ids actually closed —
    /// always a prefix of `targets`.
    @discardableResult
    public static func walk(_ targets: [UUID], closing: (UUID) -> Bool) -> [UUID] {
        var closed: [UUID] = []
        for id in targets {
            guard closing(id) else { break }
            closed.append(id)
        }
        return closed
    }

    /// The enabled state of every item of one tab's context menu.
    public struct MenuAvailability: Equatable, Sendable {
        public let close: Bool
        public let closeOthers: Bool
        public let closeToTheRight: Bool
        public let closeAll: Bool
        public let closeSaved: Bool
        /// Copy Path and Reveal in Finder: the tab has a file.
        public let copyPath: Bool
        /// Copy Relative Path and Reveal in Project Tree: the file lies inside
        /// the open project root.
        public let copyRelativePath: Bool
        /// Local History: a text tab with a file — the same condition the app
        /// applies to the active tab, stated once here for any tab.
        public let localHistory: Bool

        public init(files: [OpenFile], anchor: UUID, projectRoot: URL?) {
            func enabled(_ command: TabCloseCommand) -> Bool {
                !TabCloseRule.targets(command, in: files, anchor: anchor).isEmpty
            }
            close = enabled(.close)
            closeOthers = enabled(.closeOthers)
            closeToTheRight = enabled(.closeToTheRight)
            closeAll = enabled(.closeAll)
            closeSaved = enabled(.closeSaved)
            let file = files.first { $0.id == anchor }
            let url = file?.url
            copyPath = url != nil
            copyRelativePath = DisplayPath.relativePath(fileURL: url, projectRoot: projectRoot) != nil
            localHistory = file?.kind == .text && url != nil
        }

        /// Whether `command`'s item is enabled.
        public func isEnabled(_ command: TabCloseCommand) -> Bool {
            switch command {
            case .close: return close
            case .closeOthers: return closeOthers
            case .closeToTheRight: return closeToTheRight
            case .closeAll: return closeAll
            case .closeSaved: return closeSaved
            }
        }
    }
}
