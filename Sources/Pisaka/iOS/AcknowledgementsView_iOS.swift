#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS Acknowledgements screen — the peer of the macOS `AcknowledgementsView`
/// (a Preferences tab there; a push from Preferences → About here, since the
/// `Form` already sits in a `NavigationStack`).
///
/// A thin view over `LicenseCatalogLoader`, which is itself thin glue over Core's
/// `LicenseCatalog` — this file makes no decisions about what is acknowledged. The
/// two-level shape (list → detail) is what a phone has room for; the detail screen
/// renders the text whole and never truncates or reflows it, the copyright lines
/// and the permission notice being the obligation itself.
struct AcknowledgementsView_iOS: View {
    private let documents = LicenseCatalogLoader.documents
    private let failure = LicenseCatalogLoader.failureDescription

    var body: some View {
        List {
            if let failure {
                // A broken bundle names what is wrong rather than showing an empty
                // list, which would read as "this app has no dependencies".
                Text(failure)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(documents) { document in
                    NavigationLink {
                        LicenseTextView_iOS(document: document)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.notice.name)
                            Text(document.notice.spdx)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One dependency's detail: its identity (name, SPDX, version/revision, origin)
/// above the verbatim license text.
private struct LicenseTextView_iOS: View {
    let document: LicenseDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                Text(document.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationTitle(document.notice.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.notice.spdx)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // `version` is nil for the revision-pinned packages and the vendored
            // grammar with no upstream release — omit the row rather than render a
            // blank one. The revision is always present and is what makes the text
            // verifiable, so it is shown in full.
            if let version = document.notice.version {
                field(label: "Version", value: version)
            }
            field(label: "Revision", value: document.notice.revision, monospaced: true)
            origin
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Remote dependencies get a tappable URL; the two vendored grammars name a
    /// `Vendor/<name>` path in this repository, which is not something to open.
    @ViewBuilder
    private var origin: some View {
        let value = document.notice.origin
        if value.hasPrefix("https://"), let url = URL(string: value) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Origin")
                    .foregroundStyle(.secondary)
                Link(value, destination: url)
            }
            .font(.caption)
        } else {
            field(label: "Origin", value: value)
        }
    }

    private func field(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
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
