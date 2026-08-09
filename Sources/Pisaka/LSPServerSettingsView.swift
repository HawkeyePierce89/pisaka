#if os(macOS)
import SwiftUI
import PisakaCore

/// Preferences → Language Servers: the whole management surface for what this
/// app provisions for itself.
///
/// Deliberately small. One row per downloadable server, each showing the state
/// `LSPProvisioningModel` derived — not installed / declined / installing… /
/// installed at a version — and the actions that apply to *that* state. No
/// progress bar (the engine reports no progress, because `LSPArtifactDownloading`
/// answers whole bytes — D14), no install log, no version picker (the manifest is
/// pinned data changed only by shipping a new app version), and no way to add a
/// server that is not in the manifest.
///
/// **This is also where a "no" is turned around.** The consent banner has two
/// actions and no dismiss, which is only fair because a declined server keeps a
/// visible, permanent Install button here — the same one a removed server gets.
/// The row is likewise the *only* place an install failure is ever surfaced
/// (D15): a sentence and a Retry, never an alert.
///
/// A thin view over the model, in the `GeneralSettingsView` mould: every rule
/// (which actions apply, what the state is, what it costs to install) is a
/// property of `LSPServerRow` and is unit-tested in Core.
struct LSPServerSettingsView: View {
    @ObservedObject var provisioning: LSPProvisioningModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Pisaka can download a language server for these files. "
                + "It is used only for completion and Go to Definition — nothing is downloaded "
                + "until you ask for it, and the languages keep working without it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(provisioning.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    self.row(row)
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor))
            )

            // Where the files are is part of the contract (D12): the state *is*
            // the file system, so deleting this directory de-provisions
            // completely. Saying so here is what makes Remove a convenience
            // rather than the only way out.
            Text("Installed under ~/Library/Application Support/Pisaka/\(LSPInstallLayout.directoryName).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 300, alignment: .topLeading)
    }

    private func row(_ row: LSPServerRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                Text(row.server.serverComponentID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status(of: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The entire failure surface of this feature. Present only after
                // an attempt that failed, and replaced by the next attempt's
                // outcome.
                if let failure = row.failureMessage {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if row.state == .installing {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            }

            if row.canInstall {
                // "Retry" only after a failure: the same action either way, but a
                // button that says Install on a row explaining why the last
                // install failed reads as if the failure were about something
                // else.
                Button(row.failureMessage == nil ? "Install" : "Retry") {
                    Task { await provisioning.install(row.server) }
                }
            }

            if row.canRemove {
                Button("Remove") {
                    Task { await provisioning.remove(row.server) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The row's state as one sentence.
    ///
    /// `declined` is a *consent* state rather than an install state, so it is
    /// read off the row's consent and shown only where there is nothing on disk
    /// — a removed server is `declined` too (removing is the strongest possible
    /// "no"), and that is exactly what it should say.
    private func status(of row: LSPServerRow) -> String {
        switch row.state {
        case .installing:
            return "Installing…"
        case .installed(let version):
            return "Installed · version \(version)"
        case .absent where row.consent == .declined:
            return "Not installed · declined"
        case .absent:
            return "Not installed · \(LSPConsentBanner.size(row.pendingDownloadByteCount)) download"
        }
    }
}

#endif
