#if os(macOS)
import PisakaCore
import SwiftUI

/// The Local History window's contents (⌘⇧H): one file's stored revisions on the
/// left, the selected revision diffed against what the file holds *now* on the
/// right, and a Restore button under the list.
///
/// **It observes `LocalHistoryBrowserModel` alone.** The capture model — the
/// long-lived object every write path in the app hands its bytes to — is
/// deliberately not here: it publishes nothing, and a window that observed it
/// would re-render on captures it does not show. What this view renders is the
/// browser's four published values (the rows, the selection, the loaded content,
/// the diff), which is the whole reason the browser is a companion model rather
/// than more members on its owner.
///
/// **The current text arrives as a closure, read at the moment it is needed.**
/// The window outlives edits to the file it is showing — and outlives a folder
/// switch — so the "new" side of every diff has to be asked for rather than
/// captured: `currentText` answers with the open buffer when a tab holds the file
/// and with the disk copy otherwise, which is `PisakaApp`'s decision, not this
/// view's.
///
/// **A file with no history is empty, not broken.** Almost every file in a
/// project has never been saved by this app; the store answers a missing
/// directory with an empty list, and the sentence below is what the user sees. It
/// is not an error state and there is none in this feature.
///
/// Thin and untested like the rest of `Sources/Pisaka`. Every decision is Core's:
/// what the revisions are and how they sort is `LocalHistorySnapshot`, what a row
/// is called is `LocalHistoryEvent.title`, what the diff shows is `LineDiff`
/// through the browser model, and whether a Restore is worth doing at all is
/// `LocalHistoryBrowserModel.restore(currentText:)` — which answers `nil` for a
/// revision the buffer already holds, so this view never has to decide it.
struct LocalHistoryView: View {
    /// The window's own state: the target file, its revisions, the selection and
    /// the diff. The one thing observed here.
    @ObservedObject var browser: LocalHistoryBrowserModel

    /// Shared preferences: the diff panes read `fontSize` (the code zone) and a
    /// forced Light/Dark has to reach this separate window like it does the diff
    /// and merge ones.
    @ObservedObject var settings: SettingsStore

    /// What the file holds right now — the "new" side of every diff, and the text
    /// a restore displaces. See the type's note for why it is a closure.
    var currentText: () -> String

    /// Carry out the restore the browser model planned. `PisakaApp` opens a tab
    /// if none holds the file, snapshots the buffer under the `restore` label and
    /// applies the replacement through the editor; nothing about that is this
    /// view's to decide.
    var onRestore: (LocalHistoryRestore) -> Void

    /// The selected row's file name — a snapshot's identity inside its file
    /// directory, and the one thing about it that is unique.
    ///
    /// Read straight off the model rather than kept as `@State` beside it. The
    /// window is reused across files and a retarget clears the selection
    /// synchronously, so a second copy here would have to be reset back *through*
    /// the model — and that reset, arriving one SwiftUI pass later, would cancel
    /// the listing the retarget had just started (`LocalHistoryBrowserModel
    /// .select(_:currentText:)`). One owner, no echo.
    private var selection: Binding<String?> {
        Binding(
            get: { browser.selected?.fileName },
            set: { name in
                browser.select(
                    browser.revisions.first { $0.fileName == name },
                    currentText: currentText()
                )
            }
        )
    }

    /// The interface zone's metrics. Computed from the store rather than read
    /// from the environment because this view is the *root* of its own window and
    /// injects the value below — an environment write reaches descendants, not
    /// the view that makes it.
    private var metrics: InterfaceMetrics { settings.interfaceMetrics }

    var body: some View {
        HSplitView {
            revisions
                .frame(
                    minWidth: metrics.scaled(220),
                    idealWidth: metrics.scaled(260),
                    maxWidth: metrics.scaled(380)
                )
            detail
                .frame(minWidth: metrics.scaled(360), maxWidth: .infinity)
        }
        .frame(minWidth: metrics.scaled(640), minHeight: metrics.scaled(380))
        .preferredColorScheme(settings.themePreference.colorScheme)
        // Its own SwiftUI root (an `NSHostingController` made by
        // `LocalHistoryWindowController`), so it injects the interface scale
        // itself. The diff panes stay on `settings.fontSize` — the code zone —
        // exactly as they do in a separate diff window.
        .interfaceScaled(settings)
    }

    // MARK: - The revisions list

    private var revisions: some View {
        VStack(spacing: 0) {
            if browser.isEmpty {
                // Two different answers: a file inside the project gets a
                // history the moment the app writes it, one outside never does.
                Text(browser.isUnsupportedTarget
                    ? "This file is not in the open project, so it has no history."
                    : "No history for this file yet.")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(metrics.scaled(16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(browser.revisions, id: \.fileName, selection: selection) { snapshot in
                    RevisionRow(snapshot: snapshot)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: metrics.scaled(8)) {
            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Restore") {
                guard let plan = browser.restore(currentText: currentText()) else { return }
                onRestore(plan)
                // The buffer the right-hand pane diffs against is exactly what
                // the restore just replaced, so the rows on screen now describe
                // a state that no longer exists — which reads as "the restore
                // did nothing". Re-asking with the restored text settles the
                // pane to no differences at all, which is what a restore that
                // worked looks like.
                browser.select(browser.selected, currentText: currentText())
            }
            // Armed by the *loaded* content rather than by the selection: the
            // content is what a restore writes into the buffer, and it arrives a
            // hop after the click. `restore(currentText:)` still has the last
            // word — a revision identical to the buffer plans nothing — but
            // that answer costs a read of the current text, so it is asked when
            // the button is pressed, not on every body evaluation.
            .disabled(browser.selectedContent == nil)
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(8))
    }

    // MARK: - The diff

    @ViewBuilder
    private var detail: some View {
        if let snapshot = browser.selected, browser.selectedContent != nil {
            DiffView(
                // The revision's own file name, so switching rows rebuilds the
                // panes wholesale rather than re-using the previous revision's.
                fileID: snapshot.fileName,
                // The *file's* name, which is what selects the syntax language;
                // a snapshot's own name is a timestamp with a `.snapshot`
                // extension and would highlight as nothing at all.
                fileName: displayName,
                rows: browser.diffRows,
                fontSize: settings.fontSize
            )
        } else {
            Text(browser.revisions.isEmpty ? "" : "Select a revision to see what changed.")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The last path component of the file being browsed — the syntax language's
    /// only input, and empty before the first `open`.
    private var displayName: String {
        browser.fileURL?.lastPathComponent ?? ""
    }
}

/// One revision row: what took the snapshot, and when — twice, because the two
/// readings answer different questions. The relative one ("2 hours ago") is how
/// a user finds the edit they remember making; the absolute one is how they tell
/// two of them apart.
private struct RevisionRow: View {
    let snapshot: LocalHistorySnapshot

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text(snapshot.event.title)
                .font(metrics.scaledFont(.body))
            Text("\(Self.relative.localizedString(for: snapshot.timestamp, relativeTo: Date())) · "
                + Self.absolute.string(from: snapshot.timestamp))
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, metrics.scaled(2))
    }

    private static let relative = RelativeDateTimeFormatter()
    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

#endif
