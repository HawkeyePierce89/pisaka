#if os(macOS)
import AppKit
import PisakaCore

/// The two modal questions Local History's File menu commands ask before doing
/// anything: the text of a **Put Label…** and which file **Deleted Files…**
/// should open.
///
/// `NSAlert`-based, the way `FilePanels` hosts the delete confirmation, and
/// thin: what a label may be is `LocalHistoryPolicy.label(from:)` — asked here
/// only to enable the button — and which paths are offered is
/// `LocalHistoryBrowserModel.deletedPaths(root:)`, handed in already sorted.
/// Neither prompt writes anything; the caller acts on the answer.
enum LocalHistoryPrompts {
    /// Ask for a label. Answers the text as typed when the user confirms, `nil`
    /// on Cancel. The **Put Label** button is enabled only while
    /// `LocalHistoryPolicy.label(from:)` accepts the field's text, so a confirmed
    /// answer is always one the capture will take.
    @MainActor
    static func askLabel() -> String? {
        let alert = NSAlert()
        alert.messageText = "Put Label"
        alert.informativeText = "Snapshot every open project file under a label of your own."
        let confirm = alert.addButton(withTitle: "Put Label")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Label"
        let enabler = LabelFieldEnabler(button: confirm)
        field.delegate = enabler
        confirm.isEnabled = false
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = withExtendedLifetime(enabler) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Ask which deleted file to open, out of `paths` in the order given.
    /// Answers the chosen project-relative path, or `nil` on Cancel.
    ///
    /// An empty list is a fact, not a choice: it says so in a short
    /// informational alert and answers `nil`, so nothing opens.
    @MainActor
    static func chooseDeletedPath(from paths: [String]) -> String? {
        let alert = NSAlert()
        guard !paths.isEmpty else {
            alert.messageText = "No deleted files with history in this project."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
        alert.messageText = "Deleted Files"
        alert.informativeText = "Files in this project that have Local History and are no longer on disk."
        alert.addButton(withTitle: "Show History")
        alert.addButton(withTitle: "Cancel")

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        popUp.addItems(withTitles: paths)
        alert.accessoryView = popUp

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popUp.indexOfSelectedItem
        return paths.indices.contains(index) ? paths[index] : nil
    }
}

/// Keeps the label prompt's confirm button in step with the field: enabled
/// exactly while `LocalHistoryPolicy.label(from:)` accepts what is typed.
private final class LabelFieldEnabler: NSObject, NSTextFieldDelegate {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        button?.isEnabled = LocalHistoryPolicy.label(from: field.stringValue) != nil
    }
}

#endif
