#if os(macOS)
import SwiftUI
import AppKit
import PisakaCore

enum TreeEditDraft: Equatable {
    case create(parent: URL, isFolder: Bool)
    case rename(entry: DirectoryEntry)
}

struct TreeNameFieldView: View {
    let draft: TreeEditDraft
    let siblings: [String]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.interfaceMetrics) private var metrics

    @State private var text: String
    @State private var issue: EntryPathIssue?

    init(draft: TreeEditDraft, siblings: [String], onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.siblings = siblings
        self.onCommit = onCommit
        self.onCancel = onCancel

        switch draft {
        case .create:
            _text = State(initialValue: "")
        case .rename(let entry):
            _text = State(initialValue: entry.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: metrics.scaled(4)) {
                iconColumn

                ProjectTreeDraftFieldRepresentable(
                    text: $text,
                    issue: $issue,
                    draft: draft,
                    siblings: siblings,
                    onCommit: onCommit,
                    onCancel: onCancel
                )
            }
            .font(metrics.scaledFont(.body))

            if let issue = issue {
                Text(issue.message)
                    .foregroundColor(Color(NSColor.systemRed))
                    .font(metrics.scaledFont(.caption))
                    .lineLimit(nil)
                    .padding(.leading, reasonGutter)
            }
        }
        .padding(.horizontal, metrics.scaled(TreeRowLayout.horizontalPadding))
        .padding(.vertical, metrics.scaled(TreeRowLayout.verticalPadding))
    }

    private var reasonGutter: Double {
        switch draft {
        case .create(_, let isFolder):
            if isFolder {
                return TreeRowLayout.chevronGutter(metrics) + metrics.scaled(4) + metrics.scaled(16) // icon is approx 16
            } else {
                return TreeRowLayout.chevronGutter(metrics) + metrics.scaled(4) + metrics.scaled(16)
            }
        case .rename:
            return TreeRowLayout.chevronGutter(metrics) + metrics.scaled(4) + metrics.scaled(16)
        }
    }

    @ViewBuilder
    private var iconColumn: some View {
        switch draft {
        case .create(_, let isFolder):
            if isFolder {
                HStack(spacing: metrics.scaled(TreeRowLayout.chevronSpacing)) {
                    Color.clear.frame(width: metrics.scaled(TreeRowLayout.chevronWidth))
                    let icon = FileIcon(symbolName: "folder", color: .accent)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: TreeRowLayout.chevronGutter(metrics))
                    let icon = fileIcon(for: text)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            }
        case .rename(let entry):
            if entry.isDirectory {
                HStack(spacing: metrics.scaled(TreeRowLayout.chevronSpacing)) {
                    Color.clear.frame(width: metrics.scaled(TreeRowLayout.chevronWidth))
                    let icon = FileIcon(symbolName: "folder", color: .accent)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: TreeRowLayout.chevronGutter(metrics))
                    let icon = FileIcon(for: entry)
                    Image(systemName: icon.symbolName)
                        .foregroundStyle(color(for: icon.color))
                }
            }
        }
    }

    private func fileIcon(for input: String) -> FileIcon {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FileIcon(symbolName: "doc", color: .gray)
        }
        let finalComponent = trimmed.components(separatedBy: "/").last ?? ""
        let dummyURL = URL(fileURLWithPath: finalComponent)
        let entry = DirectoryEntry(url: dummyURL, isDirectory: false)
        return FileIcon(for: entry)
    }
}

struct ProjectTreeDraftFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var issue: EntryPathIssue?
    let draft: TreeEditDraft
    let siblings: [String]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CustomTextField {
        let field = CustomTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.stringValue = text
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        switch draft {
        case .create(_, let isFolder):
            field.setAccessibilityLabel(isFolder ? "New Folder name" : "New File name")
        case .rename(let entry):
            field.setAccessibilityLabel("rename of \(entry.name)")
        }

        // Take focus
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                let isDir: Bool
                let name: String
                switch draft {
                case .create:
                    isDir = false
                    name = text
                case .rename(let entry):
                    isDir = entry.isDirectory
                    name = entry.name
                }
                let range = initialRenameSelection(in: name, isDirectory: isDir)
                editor.setSelectedRange(range)
            }
        }

        return field
    }

    func updateNSView(_ nsView: CustomTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.textColor = issue != nil ? .systemRed : .labelColor
    }

    func dismantleNSView(_ nsView: CustomTextField, coordinator: Coordinator) {
        nsView.isTearingDown = true
    }

    class CustomTextField: NSTextField {
        var isTearingDown = false

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                isTearingDown = true
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ProjectTreeDraftFieldRepresentable
        var isFinishing = false

        init(_ parent: ProjectTreeDraftFieldRepresentable) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newText = field.stringValue
            parent.text = newText

            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                parent.issue = nil
                return
            }

            // Validator
            let issue: EntryPathIssue?
            switch parent.draft {
            case .create:
                issue = validateRelativeEntryPath(newText)
            case .rename:
                issue = validateSingleEntryName(newText)
            }

            if let issue = issue {
                parent.issue = issue
                return
            }

            // Collision
            if !trimmed.contains("/") {
                let excludingName: String?
                switch parent.draft {
                case .create: excludingName = nil
                case .rename(let entry): excludingName = entry.name
                }
                parent.issue = liveCollisionIssue(finalComponent: trimmed, siblingNames: parent.siblings, excluding: excludingName)
            } else {
                parent.issue = nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) ||
                commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
                commandSelector == #selector(NSResponder.insertParagraphSeparator(_:)) {

                let trimmed = parent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || parent.issue != nil {
                    PlatformFeedback.warning()
                    return true // Handled (swallowed)
                }

                isFinishing = true
                parent.onCommit(parent.text)
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isFinishing = true
                parent.onCancel()
                return true
            }

            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if isFinishing { return }
            guard let field = obj.object as? CustomTextField else { return }
            if field.isTearingDown || field.window == nil { return }
            parent.onCancel()
        }
    }
}
#endif
