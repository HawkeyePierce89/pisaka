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
struct AcknowledgementsView: View {
    /// Computed, not stored: `SettingsView`'s `TabView` builds both tab views
    /// eagerly, so a stored property would read the whole `Licenses/` directory
    /// off disk whenever Preferences opens — including the General tab. The
    /// loader caches, so resolving these per body evaluation costs nothing after
    /// the first.
    private var documents: [LicenseDocument] { LicenseCatalogLoader.documents }
    private var failure: String? { LicenseCatalogLoader.failureDescription }

    @State private var selection: LicenseDocument.ID?

    var body: some View {
        Group {
            if let failure {
                // A broken bundle names what is wrong rather than showing an empty
                // list, which would read as "this app has no dependencies".
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(failure)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
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
        // window.
        .frame(width: 640, height: 420)
    }

    private var dependencyList: some View {
        List(selection: $selection) {
            ForEach(documents) { document in
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.notice.name)
                    Text(document.notice.spdx)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 280)
        .onAppear {
            if selection == nil { selection = documents.first?.id }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let document = documents.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                header(for: document.notice)
                Divider()
                // TextKit-backed rather than `ScrollView { Text(…) }`: libgit2's
                // text is 66 KB and a single `Text` would lay all of it out on the
                // main thread and risk clipping the tail. See `LicenseTextView`.
                LicenseTextView(text: document.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a dependency.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(for notice: LicenseNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notice.name)
                .font(.headline)
            Text(notice.spdx)
                .font(.subheadline)
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Remote dependencies get a clickable URL; the two vendored grammars name a
    /// `Vendor/<name>` path in this repository, which is not something to open.
    /// Which is which is `LicenseNotice.originURL`'s decision, not this view's.
    @ViewBuilder
    private func origin(for notice: LicenseNotice) -> some View {
        if let url = notice.originURL {
            HStack(spacing: 4) {
                Text("Origin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(notice.origin, destination: url)
                    .font(.caption)
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

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

#endif
