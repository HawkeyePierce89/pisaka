#if os(macOS)
import SwiftUI
import PisakaCore

/// The Acknowledgements tab of Preferences (⌘,): every third-party dependency the
/// app ships, beside its verbatim license text.
///
/// A thin view over `LicenseCatalogLoader`, which is itself thin glue over Core's
/// `LicenseCatalog` — this file makes no decisions about what is acknowledged. The
/// text is rendered whole and never truncated or reflowed: the copyright lines and
/// the permission notice *are* the obligation, so shortening them would defeat the
/// screen.
///
/// Two sources, one screen. The bundled dependencies come from the app's own
/// `Resources/Licenses/`; the *provisioned* language servers come from whatever
/// is installed under Application Support right now (`LSPInstalledLicenses`), so
/// that section exists only while something is installed and disappears when it
/// is removed. Both are `LicenseDocument`s by the time they get here, which is
/// why the detail pane needs no idea which list a selection came from.
struct AcknowledgementsView: View {
    /// Observed so an install or a removal re-reads the installed section: the
    /// model republishes its rows on every transition, which is what drives the
    /// `.task(id:)` below.
    @ObservedObject var provisioning: LSPProvisioningModel
    /// Where the installed license texts are read from. The engine owns the
    /// manifest and the layout, and knows which components are actually on disk.
    let installEngine: LSPInstallEngine

    /// Computed, not stored. The Preferences host builds only the selected page
    /// now, so this no longer guards against an eager build of every tab; it
    /// stays computed because the loader caches, so resolving these per body
    /// evaluation costs nothing after the first and nothing is held twice.
    private var documents: [LicenseDocument] { LicenseCatalogLoader.documents }
    private var failure: String? { LicenseCatalogLoader.failureDescription }

    /// The installed language servers' notices. State rather than a computed
    /// property because these are *not* cached — an install changes them — and
    /// this view's body re-evaluates on every selection change.
    @State private var installed: [LicenseDocument] = []

    /// Resets on each visit: the host builds only the selected page, so leaving
    /// Acknowledgements for another tab discards this view and its state, and
    /// coming back selects the first bundled entry again (the `.task` below).
    @State private var selection: LicenseDocument.ID?

    /// The interface zone's metrics, inherited from the `Settings` scene root.
    ///
    /// Reaches the list, the header, the pane's own size — and the license *text*
    /// below the header, which `LicenseTextView` draws through TextKit rather than
    /// SwiftUI and so cannot inherit a `Font`: this view hands it the point size
    /// explicitly (`metrics.font(.subheadline)`, which rests at
    /// `NSFont.smallSystemFontSize`). The iOS half of that shared pane is passed
    /// no size and keeps its own.
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let failure {
                // A broken bundle names what is wrong rather than showing an empty
                // list, which would read as "this app has no dependencies".
                VStack(spacing: metrics.scaled(8)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(metrics.scaledFont(.largeTitle))
                        .foregroundStyle(theme.color(.textSecondary))
                        .accessibilityHidden(true)
                    Text(failure)
                        .font(metrics.scaledFont(.body))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.color(.textSecondary))
                }
                .padding(metrics.scaled(24))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    dependencyList
                    detail
                }
            }
        }
        // Fills the page the Preferences host frames: the one page size every tab
        // shares is the size this pane needs for reading a license, and it lives
        // in `SettingsView`'s layout. Both dimensions scale there, so the detail
        // pane keeps its share of the width as the list beside it grows —
        // `InterfaceMetricsTests` pins that the room left over never shrinks.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-read on open and whenever a row changes state. Keyed on the rows
        // rather than on a timer or a notification: `rows` is the model's own
        // published summary, so an install completing, a removal finishing and a
        // relaunch's `refresh()` all land here for free.
        .task(id: provisioning.rows) {
            installed = LSPInstalledLicenses.documents(engine: installEngine)
            // A removal can delete the entry that was selected. Fall back to the
            // first bundled one rather than leaving the detail pane on the
            // "Select a dependency." placeholder.
            if selection == nil || allDocuments.allSatisfy({ $0.id != selection }) {
                selection = documents.first?.id
            }
        }
    }

    /// Both lists, for the detail pane and the selection check. Bundled first, in
    /// manifest order; installed servers after, in the provisioning manifest's
    /// order. Ids cannot collide — the bundled ones are `project.yml` package
    /// keys and these are component ids — and the first match would win if they
    /// ever did.
    private var allDocuments: [LicenseDocument] { documents + installed }

    private var dependencyList: some View {
        // The platform draws the selection: no row background is set, so nothing
        // paints over the selected row's box (rule thirty-five).
        List(selection: $selection) {
            Section {
                ForEach(documents) { row($0) }
            } header: {
                sectionHeader("Bundled")
            }
            // Present only while something is provisioned: a section listing
            // nothing would suggest the app ships these, which is the one thing
            // this screen must not imply.
            if !installed.isEmpty {
                Section {
                    ForEach(installed) { row($0) }
                } header: {
                    sectionHeader("Language Servers")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.color(.bgPanel))
        .frame(
            minWidth: metrics.scaled(180),
            idealWidth: metrics.scaled(200),
            maxWidth: metrics.scaled(280)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.subheadline))
            .foregroundStyle(theme.color(.textSecondary))
    }

    private func row(_ document: LicenseDocument) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text(document.notice.name)
                .font(metrics.scaledFont(.body))
                .foregroundStyle(theme.color(.textPrimary))
            Text(document.notice.spdx)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(theme.color(.textSecondary))
        }
        .padding(.vertical, metrics.scaled(2))
    }

    @ViewBuilder
    private var detail: some View {
        if let document = allDocuments.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                header(for: document.notice)
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
                // TextKit-backed rather than `ScrollView { Text(…) }`: libgit2's
                // text is 66 KB and a single `Text` would lay all of it out on the
                // main thread and risk clipping the tail. See `LicenseTextView`.
                // The size is handed down rather than read from the environment:
                // it is an `NSViewRepresentable`, which sets a font on a text view
                // instead of inheriting one. `.subheadline` because its base is 11
                // — `NSFont.smallSystemFontSize`, the size the pane drew at before
                // this — so 100% still renders exactly what it always did. The
                // margin is handed down for the same reason and from the same
                // base as the header's own `padding(metrics.scaled(12))` above,
                // so the license text stays in line with the header it belongs
                // to at every step of the range. The `bgEditor` ground is painted
                // here, behind the representable, which keeps drawing no
                // background of its own — an AppKit `backgroundColor` would be a
                // second ground (rule thirty-one).
                LicenseTextView(
                    text: document.text,
                    pointSize: metrics.font(.subheadline),
                    inset: metrics.pt(12)
                )
                .background(theme.color(.bgEditor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a dependency.")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(theme.color(.textSecondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for notice: LicenseNotice) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            Text(notice.name)
                .font(metrics.scaledFont(.headline, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
            Text(notice.spdx)
                .font(metrics.scaledFont(.subheadline))
                .foregroundStyle(theme.color(.textSecondary))
            // `version` is nil for the revision-pinned packages and the vendored
            // grammar with no upstream release — omit the row rather than render a
            // blank one. The revision is always present and is what makes the text
            // verifiable, so it is shown in full.
            if let version = notice.version {
                LabeledField(label: "Version", value: version)
            }
            LabeledField(label: "Revision", value: notice.revision, monospaced: true)
            origin(for: notice)
        }
        .padding(metrics.scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(.bgPanel))
    }

    /// Remote dependencies get a clickable URL; the two vendored grammars name a
    /// `Vendor/<name>` path in this repository, which is not something to open.
    /// Which is which is `LicenseNotice.originURL`'s decision, not this view's.
    @ViewBuilder
    private func origin(for notice: LicenseNotice) -> some View {
        if let url = notice.originURL {
            HStack(spacing: metrics.scaled(4)) {
                Text("Origin")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.textSecondary))
                // A plain button with an `accent` label rather than a `Link`,
                // whose colour is the platform's link colour, not the role.
                Button(notice.origin) { openURL(url) }
                    .buttonStyle(.plain)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.accent))
            }
        } else {
            LabeledField(label: "Origin", value: notice.origin)
        }
    }
}

/// One caption-sized `label: value` row in the detail header.
private struct LabeledField: View {
    let label: String
    let value: String
    var monospaced = false

    /// The interface zone's metrics, inherited from the `Settings` scene root.
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(4)) {
            Text(label)
                .foregroundStyle(theme.color(.textSecondary))
            Text(value)
                .font(metrics.scaledFont(.caption, design: monospaced ? .monospaced : .default))
                .foregroundStyle(theme.color(.textPrimary))
                .textSelection(.enabled)
        }
        .font(metrics.scaledFont(.caption))
    }
}

#endif
