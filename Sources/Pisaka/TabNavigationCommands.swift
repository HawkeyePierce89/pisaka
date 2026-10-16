#if os(macOS)
import PisakaCore
import SwiftUI

/// The Window menu's tab-navigation commands, placed above the window list:
/// *Show Next Tab* (⌘⇧], and again as ⌃Tab), *Show Previous Tab* (⌘⇧[, and
/// again as ⌃⇧Tab) and a *Select Tab* submenu, *Tab 1*…*Tab 8* (⌘1…⌘8) and
/// *Last Tab* (⌘9).
///
/// Every answer is `TabNavigationRule`'s, and a nil answer is the item's
/// disabled state, so no item is ever enabled and inert. Two items per adjacent
/// move follow the View menu's duplicated Zoom In: ⌘⇧] is the chord the menu
/// displays, ⌃Tab the one muscle memory reaches for. ⌃Tab is ours only because
/// `AppDelegate` turns automatic window tabbing off — otherwise AppKit's own
/// "Show Next Tab" would claim it. The nine Select Tab items are spelled one by
/// one so `MenuShortcutUniquenessTests` sees each chord.
///
/// **Why a type of its own.** `PisakaApp`'s `.commands` builder held ten
/// entries, the most a `CommandsBuilder` block accepted in the then-pinned
/// Xcode 16.4 SDK; an eleventh compiled on a newer toolchain and failed on CI
/// (`error: extra argument in call`). The ceiling is now whatever the pinned
/// SDK declares (`app-shell.md`), and a new command type joins a `Group`
/// whatever the figure. So this type and `FoldCommands`
/// share one entry, a `Group`, and the items live in a view of their own, as
/// the LeetCode menu's do, so *it* observes the workspace and the scene's body
/// does not re-render on every tab change.
struct TabNavigationCommands: Commands {
    let model: WorkspaceModel

    var body: some Commands {
        CommandGroup(before: .windowList) {
            TabNavigationItems(model: model)
        }
    }
}

/// The items, observing the workspace so each `.disabled` follows the open tabs.
private struct TabNavigationItems: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Button("Show Next Tab") { selectAdjacentTab(forward: true) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(adjacentTab(forward: true) == nil)
        Button("Show Next Tab") { selectAdjacentTab(forward: true) }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(adjacentTab(forward: true) == nil)
        Button("Show Previous Tab") { selectAdjacentTab(forward: false) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(adjacentTab(forward: false) == nil)
        Button("Show Previous Tab") { selectAdjacentTab(forward: false) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(adjacentTab(forward: false) == nil)

        Menu("Select Tab") {
            Button("Tab 1") { selectTab(at: 1) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(positionalTab(1) == nil)
            Button("Tab 2") { selectTab(at: 2) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(positionalTab(2) == nil)
            Button("Tab 3") { selectTab(at: 3) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(positionalTab(3) == nil)
            Button("Tab 4") { selectTab(at: 4) }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(positionalTab(4) == nil)
            Button("Tab 5") { selectTab(at: 5) }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(positionalTab(5) == nil)
            Button("Tab 6") { selectTab(at: 6) }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(positionalTab(6) == nil)
            Button("Tab 7") { selectTab(at: 7) }
                .keyboardShortcut("7", modifiers: .command)
                .disabled(positionalTab(7) == nil)
            Button("Tab 8") { selectTab(at: 8) }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(positionalTab(8) == nil)
            Button("Last Tab") { selectTab(at: 9) }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(positionalTab(9) == nil)
        }

        // One `Divider()`, the one shape a `Commands` builder renders as a
        // single separator (a `Section` draws one on each side).
        Divider()
    }

    /// The tab ⌘⇧] / ⌃Tab (`forward`) or ⌘⇧[ / ⌃⇧Tab would select; nil
    /// disables the item.
    private func adjacentTab(forward: Bool) -> UUID? {
        TabNavigationRule.adjacent(in: model.openFiles.map(\.id), selected: model.selectedID, forward: forward)
    }

    private func selectAdjacentTab(forward: Bool) {
        if let id = adjacentTab(forward: forward) { model.select(id) }
    }

    /// The tab ⌘`number` would select (9 is the last tab); nil disables the item.
    private func positionalTab(_ number: Int) -> UUID? {
        TabNavigationRule.positional(number, in: model.openFiles.map(\.id))
    }

    private func selectTab(at number: Int) {
        if let id = positionalTab(number) { model.select(id) }
    }
}

#endif
