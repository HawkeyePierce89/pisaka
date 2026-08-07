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
    /// Computed, not stored: a `NavigationLink`'s destination is built when the
    /// *Preferences* form's body runs, so a stored property would read the whole
    /// `Licenses/` directory off disk on a screen that may never be opened. The
    /// loader caches, so resolving these per body evaluation costs nothing after
    /// the first.
    private var documents: [LicenseDocument] { LicenseCatalogLoader.documents }
    private var failure: String? { LicenseCatalogLoader.failureDescription }

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
        // The header is pinned above its own scroll region and the license text
        // scrolls on its own, rather than both sharing one `ScrollView`: the text
        // view has to own its scrolling for TextKit to lay out lazily, which is
        // what keeps the 66 KB libgit2 case off the main thread. See
        // `LicenseTextView`.
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            // The pane must take the space the header leaves and scroll inside
            // it. Without an explicit greedy frame the sizing falls to
            // `UITextView`'s own `sizeThatFits`, which reports the *content*
            // height — tens of thousands of points for the 66 KB libgit2 text —
            // and a `VStack` child laid out taller than the screen has its
            // scrolling neutralized, i.e. a silently truncated license.
            LicenseTextView(text: document.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Which is which is `LicenseNotice.originURL`'s decision, not this view's.
    @ViewBuilder
    private var origin: some View {
        let value = document.notice.origin
        if let url = document.notice.originURL {
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
