#if os(macOS)
import SwiftUI
import PisakaCore

/// The external-change bar: a full-width row between the breadcrumb and the
/// editor, shown for the selected tab while it is in external conflict
/// (`WorkspaceModel.isInExternalConflict`) and gone the moment the conflict is.
///
/// **When it shows is the model's rule, not this view's.** `ContentView` draws it
/// only while the selected tab is in conflict, and that state is derived from the
/// texts — an entry recorded by a disk check, and a buffer that differs from it —
/// so the clean-but-stale case (the buffer edited back to its baseline while the
/// disk moved on) keeps the bar up exactly as the tab's marker does, and editing
/// the buffer to the disk's text takes it down. The view holds no state.
///
/// **Three actions, equally weighted.** Reload, Overwrite and Compare are all the
/// shared `.chromeSecondary` style: two of them give up one side and neither is
/// the safer one to recommend, so none is drawn as the offer. Reload and
/// Overwrite run through the same capture-then-act helpers the modal question
/// uses (`DiskSyncController`), so whichever side loses is in Local History
/// first; Compare opens the buffer against the disk and changes nothing.
///
/// **No `.keyboardShortcut(.defaultAction)`**, for `LSPConsentBar`'s reason: the
/// bar lives in the editor window, and a default button there would take every
/// Return typed in the file below it. There is no dismiss either — the conflict
/// is a fact about the file, and it ends only through an answer or an edit.
///
/// The geometry is the consent bar's: `bgPanel` ground padded 14 by 18, the
/// design's 16-point icon with the text 10 beyond it, the actions at least 16
/// away at the trailing edge and 8 apart, one scaled `hairline` rule along the
/// bottom. The icon is the `fileWarning` design glyph in `statusYellow`, the
/// same mark the tab carries, so the bar and the tab say the same thing.
struct ExternalChangeBar: View {
    /// The tab's display name, quoted in the message.
    let fileName: String
    let onReload: () -> Void
    let onOverwrite: () -> Void
    let onCompare: () -> Void

    /// The interface zone's metrics, inherited from `ContentView`'s root.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome's colours, inherited from the same root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                DesignGlyphImage(.fileWarning, size: 16, slot: 16, role: .statusYellow)

                VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                    Text("\u{201C}\(fileName)\u{201D} changed on disk since it was opened or last saved.")
                        .font(metrics.scaledFont(.body))
                        .foregroundStyle(theme.color(.textPrimary))
                    Text("Autosave will not write it. The version you give up is kept in Local History.")
                        .font(metrics.scaledFont(.subheadline))
                        .foregroundStyle(theme.color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, metrics.scaled(10))

                Spacer(minLength: metrics.scaled(16))

                HStack(spacing: metrics.scaled(8)) {
                    Button("Reload", action: onReload)
                        .buttonStyle(.chromeSecondary)
                    Button("Overwrite", action: onOverwrite)
                        .buttonStyle(.chromeSecondary)
                    Button("Compare", action: onCompare)
                        .buttonStyle(.chromeSecondary)
                }
                .fixedSize()
            }
            .padding(.vertical, metrics.scaled(14))
            .padding(.horizontal, metrics.scaled(18))
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        .background(theme.color(.bgPanel))
    }
}

#endif
