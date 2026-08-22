#if os(macOS)
import AppKit

/// Thin wrappers over AppKit's open/save panels.
///
/// These are intentionally kept out of `PisakaCore`: they touch UIKit/AppKit
/// and present modal dialogs, so they live in the executable layer while the
/// model stays pure and testable.
enum FilePanels {
    /// Present an open panel and return the chosen file url, or `nil` if the
    /// user cancelled.
    static func showOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Present an open panel restricted to directories and return the chosen
    /// folder url, or `nil` if the user cancelled.
    ///
    /// Both parameters default to the plain "Open Folder…" behaviour, which is
    /// what every existing call site wants: no pre-targeting (the panel resumes
    /// wherever it was last), no explanatory message. The LeetCode folder
    /// chooser supplies both, because it is *suggesting* a location rather than
    /// asking the user to find one — and a suggestion needs the panel to open
    /// inside the suggested directory and a sentence saying what the folder is
    /// for.
    static func showOpenFolderPanel(
        directoryURL: URL? = nil,
        message: String? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Only when asked: setting `canCreateDirectories` unconditionally would
        // add a New Folder button to every "open a project" panel in the app.
        if let directoryURL {
            panel.directoryURL = directoryURL
            panel.canCreateDirectories = true
        }
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Present a save panel seeded with `suggestedName` and return the chosen
    /// destination url, or `nil` if the user cancelled.
    static func showSavePanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The user's choice when closing a file with unsaved changes.
    enum CloseChoice {
        case save
        case dontSave
        case cancel
    }

    /// Present a Save / Don't Save / Cancel confirmation for a dirty file.
    static func confirmClose(fileName: String) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \"\(fileName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    /// Present a destructive confirmation before reverting the given files to
    /// their `HEAD` version (discarding local changes). Returns `true` only when
    /// the user clicks Revert. Mirrors the `confirmClose` style.
    static func confirmRevert(fileNames: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = fileNames.count
        alert.messageText = count == 1
            ? "Revert changes to \"\(fileNames[0])\"?"
            : "Revert changes to \(count) files?"
        alert.informativeText =
            "This discards local changes and cannot be undone:\n"
            + fileNames.joined(separator: "\n")
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Prompt for a file/folder name (or a relative path) via an `NSAlert`
    /// hosting a wide, wrapping multiline `NSTextField` accessory. Returns the
    /// entered string on OK (pre-filled with `defaultValue` — empty for New, the
    /// current name for Rename), or `nil` on Cancel.
    ///
    /// The field wraps instead of scrolling, so even a deep path
    /// (`backend/src/dialogs/dialogs.service.ts`) is visible in full and the
    /// dialog grows in height with it. `validator` is run on every keystroke and
    /// once before the dialog is shown: it returns `nil` for a valid input or the
    /// reason text to display, which drives a red reason line under the field and
    /// the enabled state of OK. It is *required* — every call site must state its
    /// validation intent, so a new one cannot silently forget it. All the rules and
    /// their wording live in `PisakaCore` (`validateRelativeEntryPath` /
    /// `validateSingleEntryName`); the only decision made here is that blank input
    /// disables OK *without* showing a reason (incomplete input, not an error).
    ///
    /// Enter never inserts a line break: it clicks OK when OK is enabled and is
    /// swallowed otherwise.
    static func promptName(
        title: String,
        defaultValue: String = "",
        validator: @escaping (String) -> String?
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        // A plain `NSTextField` is already editable, bezeled and wrapping; the
        // wrapping properties are still stated explicitly because multiline
        // input is the point of this field, not an inherited default.
        let field = NSTextField()
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.preferredMaxLayoutWidth = promptFieldWidth
        field.stringValue = defaultValue
        field.translatesAutoresizingMaskIntoConstraints = false

        let reason = NSTextField(wrappingLabelWithString: "")
        reason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reason.textColor = .systemRed
        reason.preferredMaxLayoutWidth = promptFieldWidth
        reason.isHidden = true
        reason.translatesAutoresizingMaskIntoConstraints = false

        // The reason label is only hidden, never removed from the layout, so the
        // dialog does not jump in height as a reason appears and disappears.
        // The container itself stays frame-based (`translatesAutoresizingMask…`
        // left `true`) even though its subviews are laid out with constraints:
        // `NSAlert` sizes its window from the accessory view's *frame*, not its
        // `fittingSize`, so a constraint-driven container handed over with the
        // default zero frame opens the alert at its minimum width and clips the
        // 400 pt field. `syncContainerFrame` is what keeps that frame in step.
        let container = NSView()
        container.addSubview(field)
        container.addSubview(reason)
        let fieldHeight = field.heightAnchor.constraint(equalToConstant: promptFieldHeight(of: field))
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: promptFieldWidth),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldHeight,
            reason.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            reason.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            reason.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            reason.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // `NSTextField.delegate` is weak, so the delegate must outlive `runModal()`.
        let delegate = PromptNameDelegate(
            alert: alert,
            container: container,
            field: field,
            fieldHeight: fieldHeight,
            reasonLabel: reason,
            validator: validator
        )
        field.delegate = delegate
        // Get the initial state right before the dialog is shown: a pre-filled
        // Rename opens with OK enabled, an empty create with OK disabled. Run it
        // before the frame is sized so a reason shown from the start is included.
        delegate.revalidate(text: defaultValue)

        syncContainerFrame(container)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        // `withExtendedLifetime` is what actually keeps the weakly-referenced
        // delegate alive: ARC may otherwise release a local after its last use,
        // which would silently drop live validation and the Enter interception.
        let response = withExtendedLifetime(delegate) { alert.runModal() }
        field.delegate = nil
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Resolve the constraint-driven accessory container's Auto Layout size into
    /// the concrete `frame` `NSAlert` reads when it sizes its window. Must be
    /// called before the container is handed to the alert and again whenever the
    /// field height or the reason line changes, otherwise the alert keeps the
    /// stale (initially zero) size and clips the field.
    private static func syncContainerFrame(_ container: NSView) {
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(origin: .zero, size: container.fittingSize)
    }

    /// Width of the `promptName` field — wide enough that a typical relative path
    /// fits on one line, with wrapping (not scrolling) handling anything longer.
    private static let promptFieldWidth: CGFloat = 400

    /// Height the wrapping `promptName` field needs for its current text, so a
    /// deep path grows the field (and the dialog) instead of being clipped.
    /// Clamped to at least one line and at most `promptFieldMaxLines`.
    private static func promptFieldHeight(of field: NSTextField) -> CGFloat {
        let lineHeight = (field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height
        let oneLine = ceil(lineHeight) + promptFieldVerticalPadding
        let maximum = ceil(lineHeight * CGFloat(promptFieldMaxLines)) + promptFieldVerticalPadding
        guard let cell = field.cell else { return oneLine }
        let fitting = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: promptFieldWidth, height: .greatestFiniteMagnitude)
        ).height
        return min(max(ceil(fitting), oneLine), maximum)
    }

    private static let promptFieldMaxLines = 6
    private static let promptFieldVerticalPadding: CGFloat = 8

    /// Live validation for `promptName`: re-runs the validator on every edit,
    /// showing/hiding the red reason line, enabling/disabling OK, and growing the
    /// field to fit wrapped input. Retained by `promptName` for the lifetime of
    /// the modal because `delegate` is weak.
    private final class PromptNameDelegate: NSObject, NSTextFieldDelegate {
        private let alert: NSAlert
        private let container: NSView
        private let field: NSTextField
        private let fieldHeight: NSLayoutConstraint
        private let reasonLabel: NSTextField
        private let validator: (String) -> String?

        private var okButton: NSButton { alert.buttons[0] }

        init(
            alert: NSAlert,
            container: NSView,
            field: NSTextField,
            fieldHeight: NSLayoutConstraint,
            reasonLabel: NSTextField,
            validator: @escaping (String) -> String?
        ) {
            self.alert = alert
            self.container = container
            self.field = field
            self.fieldHeight = fieldHeight
            self.reasonLabel = reasonLabel
            self.validator = validator
        }

        /// Apply the validator to `text`: blank input disables OK but shows no
        /// reason (incomplete, not wrong); any other invalid input shows its reason.
        /// Returns whether the reason line changed, so the caller can re-lay out
        /// the alert — a reason that wraps onto a second line makes the accessory
        /// view taller, which the alert only accounts for on an explicit layout.
        @discardableResult
        func revalidate(text: String) -> Bool {
            let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let issue = isBlank ? nil : validator(text)
            let message = issue ?? ""
            let changed = message != reasonLabel.stringValue
            reasonLabel.stringValue = message
            reasonLabel.isHidden = issue == nil
            okButton.isEnabled = !isBlank && issue == nil
            return changed
        }

        /// Grow/shrink the field to its wrapped content. Returns whether the
        /// height actually changed, so ordinary typing costs no re-layout.
        private func resizeFieldIfNeeded() -> Bool {
            let height = FilePanels.promptFieldHeight(of: field)
            guard abs(height - fieldHeight.constant) > 0.5 else { return false }
            fieldHeight.constant = height
            return true
        }

        func controlTextDidChange(_ obj: Notification) {
            let reasonChanged = revalidate(text: field.stringValue)
            let heightChanged = resizeFieldIfNeeded()
            guard reasonChanged || heightChanged else { return }
            // Re-resolve the container's frame first: the alert lays out against
            // that frame, so growing the field or wrapping the reason onto a
            // second line would otherwise be clipped by the old height.
            FilePanels.syncContainerFrame(container)
            alert.layout()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // The field is multiline, so every line-break-inserting command would
            // otherwise put a newline in the name — Enter, and Control-Return,
            // which `StandardKeyBinding.dict` maps to `insertLineBreak:`.
            // Confirm instead when the input is valid, and swallow the key when not.
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                || commandSelector == #selector(NSResponder.insertLineBreak(_:))
                || commandSelector == #selector(NSResponder.insertParagraphSeparator(_:))
            else { return false }
            if okButton.isEnabled { okButton.performClick(nil) }
            return true
        }
    }

    /// Present a destructive confirmation before deleting the given files or
    /// folders from disk. Returns `true` only when the user clicks Delete.
    /// Mirrors the `confirmClose`/`confirmRevert` style.
    static func confirmDelete(fileNames: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = fileNames.count
        alert.messageText = count == 1
            ? "Delete \"\(fileNames[0])\"?"
            : "Delete \(count) items?"
        alert.informativeText =
            "This cannot be undone:\n"
            + fileNames.joined(separator: "\n")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

#endif
