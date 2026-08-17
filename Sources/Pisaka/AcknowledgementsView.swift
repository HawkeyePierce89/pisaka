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

    /// Computed, not stored: `SettingsView`'s `TabView` builds every tab view
    /// eagerly, so a stored property would read the whole `Licenses/` directory
    /// off disk whenever Preferences opens — including the General tab. The
    /// loader caches, so resolving these per body evaluation costs nothing after
    /// the first.
    private var documents: [LicenseDocument] { LicenseCatalogLoader.documents }
    private var failure: String? { LicenseCatalogLoader.failureDescription }

    /// The installed language servers' notices. State rather than a computed
    /// property because these are *not* cached — an install changes them — and
    /// this view's body re-evaluates on every selection change.
    @State private var installed: [LicenseDocument] = []

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

    var body: some View {
        Group {
            if let failure {
                // A broken bundle names what is wrong rather than showing an empty
                // list, which would read as "this app has no dependencies".
                VStack(spacing: metrics.scaled(8)) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(metrics.scaledFont(.largeTitle))
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .font(metrics.scaledFont(.body))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
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
        // Sized for reading a license: the Preferences window takes the widest tab,
        // so the General form keeps its own 340pt width and this one drives the
        // window. Both dimensions scale, so the detail pane keeps its share of the
        // width as the list beside it grows — `InterfaceMetricsTests` pins that the
        // room left over never shrinks.
        .frame(width: metrics.scaled(640), height: metrics.scaled(420))
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
        List(selection: $selection) {
            Section("Bundled") {
                ForEach(documents) { row($0) }
            }
            // Present only while something is provisioned: a section listing
            // nothing would suggest the app ships these, which is the one thing
            // this screen must not imply.
            if !installed.isEmpty {
                Section("Language Servers") {
                    ForEach(installed) { row($0) }
                }
            }
        }
        .frame(
            minWidth: metrics.scaled(180),
            idealWidth: metrics.scaled(200),
            maxWidth: metrics.scaled(280)
        )
    }

    private func row(_ document: LicenseDocument) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text(document.notice.name)
                .font(metrics.scaledFont(.body))
            Text(document.notice.spdx)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, metrics.scaled(2))
    }

    @ViewBuilder
    private var detail: some View {
        if let document = allDocuments.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                header(for: document.notice)
                Divider()
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
                // to at every step of the range.
                LicenseTextView(
                    text: document.text,
                    pointSize: metrics.font(.subheadline),
                    inset: metrics.pt(12)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a dependency.")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for notice: LicenseNotice) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            Text(notice.name)
                .font(metrics.scaledFont(.headline, weight: .semibold))
            Text(notice.spdx)
                .font(metrics.scaledFont(.subheadline))
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Link(notice.origin, destination: url)
                    .font(metrics.scaledFont(.caption))
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

    var body: some View {
        HStack(spacing: metrics.scaled(4)) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(metrics.scaledFont(.caption, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
        .font(metrics.scaledFont(.caption))
    }
}

#endif
