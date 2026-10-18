#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// What a click on a gutter change marker asks the window to show: the hunk's
/// `HEAD` lines (at most `ChangeHunk.popoverLineLimit`, with the count of those
/// left out), the marker's rect in the ruler's coordinates (the anchor), and
/// what *Revert* does — the editor's own closure, which recomputes the hunk at
/// the moment of the press rather than trusting the one shown here.
struct ChangeHunkPopoverRequest {
    let headLines: [String]
    let omittedLines: Int
    let anchor: NSRect
    let anchorView: NSView
    let revert: () -> Void
}

/// The editor's way to the window's one popover presenter, handed in by
/// `ContentView` as two closures so `CodeEditorView` names no presenter.
///
/// `dismiss` closes the presenter only while *this* popover is the open one: an
/// edit or a tab switch must never close the branch or project popover a user
/// opened from the bar meanwhile.
struct ChangeHunkPopoverPresenting {
    let present: (ChangeHunkPopoverRequest) -> Void
    let dismiss: () -> Void

    /// The presenter's id for the change popover — one marker's popover at a
    /// time, and a second click on the open marker closes it (the toggle).
    static let popoverID = "gitChangeHunk"

    /// The two closures over `presenter`, drawing the lines at the code font
    /// `settings` holds now and after every zoom.
    @MainActor
    static func over(_ presenter: ChromePopoverPresenter, settings: SettingsStore) -> Self {
        Self(
            present: { [weak presenter] request in
                guard let presenter,
                      let anchor = presenter.rootRect(request.anchor, from: request.anchorView)
                else { return }
                presenter.present(id: popoverID, anchor: anchor, placement: .beside) { [weak presenter] context in
                    AnyView(ChangeHunkPopover(
                        headLines: request.headLines,
                        omittedLines: request.omittedLines,
                        context: context,
                        settings: settings,
                        onRevert: {
                            presenter?.dismiss()
                            request.revert()
                        }
                    ))
                }
            },
            dismiss: { [weak presenter] in
                guard let presenter, presenter.openID == popoverID else { return }
                presenter.dismiss()
            }
        )
    }
}

/// The change marker's popover: a `ChromePopover` whose Head says "HEAD", whose
/// List is the hunk's `HEAD` lines at the code font — or "No lines in HEAD" for
/// an added hunk — and whose Foot is the *Revert* button. A hunk longer than
/// `ChangeHunk.popoverLineLimit` draws its first lines and a count of the rest,
/// so a newline-dense hunk never builds one view per line.
///
/// The chrome — container, Head, message, Foot — is coloured only by popover
/// roles through the injected theme. The lines are code-zone text, so the List
/// declares itself a code zoom surface, builds its font through `EditorFont` at
/// `SettingsStore.fontSize` (never the interface scale) and states the code
/// table's plain row as its base foreground (`SyntaxBaseForegroundGatingTests`). No row is registered with the presenter, so the arrows and
/// Return keep reaching the editor (which keeps the focus) and only Esc and a
/// click outside close it.
struct ChangeHunkPopover: View {
    let headLines: [String]
    let omittedLines: Int
    let context: ChromePopoverContext
    @ObservedObject var settings: SettingsStore
    let onRevert: () -> Void

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        ChromePopover(maxHeight: context.maxHeight, head: {
            ChromePopoverSectionHeader(title: "HEAD")
        }, list: {
            if headLines.isEmpty {
                ChromePopoverMessage(text: "No lines in HEAD", role: .textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(headLines.indices, id: \.self) { index in
                        Text(verbatim: headLines[index].isEmpty ? " " : headLines[index])
                            .font(EditorFont.swiftUIFont(
                                size: CGFloat(settings.fontSize),
                                family: settings.editorFontFamily
                            ))
                            // File content at the code font: the code table's
                            // plain row, as every code-zone surface states it —
                            // not a chrome role, and not the platform label.
                            .foregroundStyle(Color(SyntaxTheme.shared.color(for: .plain)))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, metrics.scaled(ChromeGeometry.popoverMessagePaddingX))
                .padding(.vertical, metrics.scaled(ChromeGeometry.popoverMessagePaddingY))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZoomSurfaceMarker(kind: .code))
                if omittedLines > 0 {
                    ChromePopoverMessage(
                        text: "\(omittedLines) more \(omittedLines == 1 ? "line" : "lines") in HEAD",
                        role: .textSecondary
                    )
                }
            }
        }, foot: ChromePopoverRow(title: "Revert", glyph: .undo2, action: onRevert))
    }
}
#endif
