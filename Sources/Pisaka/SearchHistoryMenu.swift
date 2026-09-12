#if os(macOS)
import PisakaCore
import SwiftUI

/// The clock menu beside a query field, listing the recently-searched queries
/// newest first and offering to clear them.
///
/// The one view both search surfaces render — the find bar above the editor and
/// the Find in Files window — so the history reads identically in each. Thin and
/// untested like the rest of `Sources/Pisaka`: every decision it draws is
/// `PisakaCore.SearchQueryHistory`'s. The row's text is `menuLabel(for:)`, so the
/// pattern's truncation and the flag suffix are computed once, in Core, and unit
/// tested there rather than left to a menu item's own eliding.
///
/// Picking is **not** a committing gesture and records nothing: the caller writes
/// the pattern and the three flags back into its own state, which re-runs the
/// search the way typing does, and the next committing gesture — or the
/// dismissal — records it like any other.
///
/// The rows carry no key equivalents at all, deliberately: a history is a list
/// whose length and contents change under the user, so a shortcut on row *n*
/// would name a different query tomorrow.
struct SearchHistoryMenu: View {
    /// The remembered queries, newest first, exactly as the store holds them.
    let entries: [SearchQuery]

    /// The interface zone's metrics. The menu is chrome beside the field, not a
    /// code surface, so it grows with the rest of the interface — passed in
    /// rather than read from the environment because the Find in Files window
    /// computes its own (it is the root of its window and injects the value).
    let metrics: InterfaceMetrics

    /// Put this query back into the caller's controls.
    let onPick: (SearchQuery) -> Void

    /// Empty the shared history.
    let onClear: () -> Void

    var body: some View {
        Menu {
            // Keyed on the pattern because the recording rule makes patterns
            // unique: a second recording of the same pattern promotes the entry
            // rather than adding a row.
            ForEach(entries, id: \.pattern) { entry in
                Button(SearchQueryHistory.menuLabel(for: entry)) { onPick(entry) }
            }
            Divider()
            Button("Clear History") { onClear() }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(metrics.scaledFont(.body))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Without this the menu claims the row's spare width and pushes the
        // toggles beside it out of place; the three toggles size to their own
        // content the same way.
        .fixedSize()
        .help("Recent searches")
        .disabled(entries.isEmpty)
    }
}

#endif
