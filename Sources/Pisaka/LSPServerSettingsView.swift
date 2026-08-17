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

    /// The Go row's model. A second contributor rather than a second tab: what
    /// the user is managing here is "which languages have a language server and
    /// what may be done about it", and how a server was acquired is a detail of
    /// the row rather than a reason to look somewhere else for it.
    @ObservedObject var gopls: LSPGoplsProvisioningModel

    /// The Rust row's model. A third contributor beside the Go one and for the
    /// same reason, in the same toolchain-gated part of the list: what these two
    /// rows have in common is that they can report *no toolchain*, which is a
    /// state no downloadable row can reach and the reason Rust reuses 2b's engine
    /// without reusing its row (D21).
    @ObservedObject var rust: LSPRustProvisioningModel

    /// The interface zone's metrics, inherited from the `Settings` scene root.
    /// Reaches the pane's own fixed size too: the failure sentences this tab
    /// exists to show are the longest text in Preferences, and a scaled sentence
    /// inside an unscaled 480×300 frame is the one that gets clipped.
    @Environment(\.interfaceMetrics) private var metrics

    /// The pane scrolls rather than sizing to its content, and that is about the
    /// failure messages rather than about the rows.
    ///
    /// Three rows, their states and the footer fit the fixed 480×300 with room to
    /// spare — but `failureMessage` is unbounded in a way nothing here controls:
    /// `LSPArchiveUnpacker` reports up to 200 characters of `tar`'s last line, and
    /// a `URLError` adds a whole sentence to the engine's own prefix, each of
    /// which wraps to several `.caption` lines inside the row's narrow text
    /// column. Two of the servers failing therefore overflows the frame, and since a
    /// plain `VStack` neither clips nor scrolls, the overflow would simply draw
    /// past the frame — losing the bottom of the very sentence the user opened
    /// this tab to read, because D15 makes this row the *only* place an install
    /// failure is ever surfaced. Dropping the fixed height instead would fix the
    /// clipping and resize the Preferences window when a message arrived, since
    /// `TabView` sizes to its largest tab.
    var body: some View {
        ScrollView {
            content
        }
        .frame(width: metrics.scaled(480), height: metrics.scaled(300))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(14)) {
            // "download or build", because the last row is neither downloaded nor
            // bundled: gopls has no official prebuilt binaries, so it is built by
            // the user's own Go toolchain (D17). Saying only "download" here would
            // make that row's own sentence the first the user hears of it.
            Text(
                "Pisaka can download or build a language server for these files. "
                + "It is used only for completion and Go to Definition — nothing is installed "
                + "until you ask for it, and the languages keep working without it."
            )
            .font(metrics.scaledFont(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(provisioning.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    self.row(row)
                }
                // Last, and after a rule like every other row: the downloadable
                // servers are a fixed, stated list (`LSPDownloadableServer.allCases`)
                // and appending to it keeps that order visible rather than
                // interleaving a row that obeys different rules.
                //
                // The two toolchain-gated rows then follow in the order they were
                // added, which is also the order they read best in: Go's row is
                // never a download and Rust's always is, so the section runs from
                // the row least like the ones above it to the one most like them.
                Divider()
                goRow(gopls.row)
                Divider()
                rustRow(rust.row)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(6)))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.scaled(6))
                    .stroke(Color(NSColor.separatorColor))
            )

            // Where the files are is part of the contract (D12): the state *is*
            // the file system, so deleting this directory de-provisions
            // completely. Saying so here is what makes Remove a convenience
            // rather than the only way out. "Anything Pisaka installed" rather
            // than "everything here", because a gopls found in ~/go/bin is used
            // from where it is and is no more affected by deleting this directory
            // than it is by the Remove button that does not appear for it.
            Text(
                "Anything Pisaka installs lives under ~/Library/Application Support/Pisaka/"
                + "\(LSPInstallLayout.directoryName)."
            )
            .font(metrics.scaledFont(.caption))
            .foregroundStyle(.secondary)

            // gopls's whole licence surface, and the reason it is a sentence
            // rather than a row in Acknowledgements: `go install` writes one
            // binary and nothing else, so there is no licence file in the
            // installed tree for `LSPInstalledLicenses` to read — and nothing for
            // `licenses.json` to cover either, this app bundling no gopls bytes at
            // all. Naming the origin and the licence here is the honest
            // substitute, and it is stated rather than omitted.
            Text(
                "\(LSPGopls.displayName) comes from \(LSPGopls.origin) and is licensed under "
                + "\(LSPGopls.licenseSPDX). Pisaka bundles none of it: it is built from source "
                + "by your own Go toolchain, which verifies the module against Go's checksum "
                + "database."
            )
            .font(metrics.scaledFont(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // rust-analyzer's whole licence surface, for gopls's reason arrived at
            // from the opposite direction (D24): this one *is* downloaded, but the
            // archive is a bare `.gz` holding a single binary, so there is no
            // licence file in the installed tree for `LSPInstalledLicenses` to
            // read — and nothing for `licenses.json` either, this app bundling no
            // rust-analyzer bytes at all. Naming the origin and the dual licence
            // here is the honest substitute, and it is stated rather than left as
            // an omission. Both fields are read off the row, which reads the
            // *manifest*, so the expression here cannot drift from the pin.
            Text(
                "\(LSPRustAnalyzer.displayName) comes from \(LSPRustAnalyzer.origin) and is "
                + "licensed under \(rust.row.licenseSPDX). Pisaka bundles none of it: the "
                + "official release binary is downloaded on request and checked against a "
                + "pinned checksum before it is used."
            )
            .font(metrics.scaledFont(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.scaled(20))
        .frame(width: metrics.scaled(480), alignment: .topLeading)
    }

    private func row(_ row: LSPServerRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(12)) {
            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text(row.displayName)
                Text(row.server.serverComponentID)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                Text(status(of: row))
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                // The entire failure surface of this feature. Present only after
                // an attempt that failed, and replaced by the next attempt's
                // outcome.
                if let failure = row.failureMessage {
                    Text(failure)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: metrics.scaled(8))

            if row.state == .installing || row.isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            }

            if row.canInstall {
                // "Retry" only after a failed *install*: the same action either
                // way, but a button that says Install on a row explaining why the
                // last install failed reads as if the failure were about something
                // else. A failed *removal* is the opposite case — the message
                // there is about files this button would not touch, and "Retry"
                // beside it would read as retrying the removal while starting a
                // ~52 MB download.
                Button(row.failureMessage == nil || row.failureWasRemoval ? "Install" : "Retry") {
                    Task { await provisioning.install(row.server) }
                }
            }

            if row.canRemove {
                Button("Remove") {
                    Task { await provisioning.remove(row.server) }
                }
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Go row — the same shape as the ones above, over a model that answers
    /// different questions (D19).
    ///
    /// Two differences, both the model's: Install needs a Go toolchain to build
    /// with (`canInstall` is false without one, and false for a gopls already on
    /// the machine, which already answers), and Remove appears **only** for this
    /// app's own copy — never for a binary in `~/go/bin` that Pisaka did not put
    /// there. Neither rule is spelled here; both are properties of `LSPGoServerRow`
    /// and are unit-tested in Core.
    private func goRow(_ row: LSPGoServerRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(12)) {
            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text("Go")
                Text(LSPGopls.componentID)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                Text(status(of: row))
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                if let failure = row.failureMessage {
                    Text(failure)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: metrics.scaled(8))

            if row.status == .installing || row.isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            }

            if row.canInstall {
                // The download rows' rule verbatim: "Retry" only after a failed
                // *install*, because a button reading Install above a sentence
                // explaining why the last install failed reads as if the failure
                // were about something else — and after a failed *removal* the
                // message is about files this button would not touch.
                Button(row.failureMessage == nil || row.failureWasRemoval ? "Install" : "Retry") {
                    Task { await gopls.install() }
                }
            }

            if row.canRemove {
                Button("Remove") {
                    Task { await gopls.remove() }
                }
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Rust row — the Go row's shape over a model that answers one more
    /// question (D21/D24).
    ///
    /// The same two rules as Go's, both the model's: Install needs a `cargo` for
    /// the server to drive (`canInstall` is false without one, and false for a
    /// rust-analyzer already on the machine, which already answers), and Remove
    /// appears **only** for files under this app's own install root — never for
    /// the binary rustup put in `~/.cargo/bin`. The one difference is the download
    /// size, which this row shows and Go's has none of; it too is the model's
    /// field, read from the manifest.
    private func rustRow(_ row: LSPRustServerRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(12)) {
            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text("Rust")
                Text(LSPRustAnalyzer.componentID)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                Text(status(of: row))
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                if let failure = row.failureMessage {
                    Text(failure)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: metrics.scaled(8))

            if row.status == .installing || row.isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            }

            if row.canInstall {
                // The other rows' rule verbatim: "Retry" only after a failed
                // *install*, never after a failed removal, whose message is about
                // files this button would not touch.
                Button(row.failureMessage == nil || row.failureWasRemoval ? "Install" : "Retry") {
                    Task { await rust.install() }
                }
            }

            if row.canRemove {
                Button("Remove") {
                    Task { await rust.remove() }
                }
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The row's state as one sentence.
    ///
    /// `declined` is a *consent* state rather than an install state, so it is
    /// read off the row's consent and shown only where there is nothing on disk
    /// — a removed server is `declined` too (removing is the strongest possible
    /// "no"), and that is exactly what it should say.
    private func status(of row: LSPServerRow) -> String {
        // Ahead of the install state, because a removal keeps reading `installed`
        // right up until the files go — the wait in between is a live session
        // being stopped (D16), and a row that says "Installed" while its button
        // has just vanished is the one thing that window must not look like.
        if row.isRemoving { return "Removing…" }
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

    /// The Go row's state as one sentence — D19's five, plus the one the lifecycle
    /// starts in.
    ///
    /// `pending` says what is happening rather than guessing: the search shells out
    /// to `go`, so it cannot answer inside the turn that draws this row, and a row
    /// that read "No Go toolchain" for that first moment would say something false
    /// and then quietly correct itself.
    ///
    /// The two installed states are deliberately different sentences and not one
    /// with a footnote: "found on this Mac" is the whole explanation for why there
    /// is no Remove button beside it.
    private func status(of row: LSPGoServerRow) -> String {
        // Ahead of the status for the download rows' reason: a removal keeps
        // reading `installed` right up until the files go, and that wait is a live
        // server being stopped (D16).
        if row.isRemoving { return "Removing…" }
        switch row.status {
        case .pending:
            return "Looking for a Go toolchain…"
        case .noToolchain:
            // No Install button accompanies this, so the sentence has to carry
            // both halves: why nothing is offered, and that Go files are not
            // broken by it.
            return "No Go toolchain found · Go files use the built-in index"
        case .installing:
            return "Building with your Go toolchain…"
        case .discovered:
            return "Installed · found on this Mac"
        case .appInstalled(let version):
            return "Installed by Pisaka · version \(version)"
        case .notInstalled where row.consent == .declined:
            return "Not installed · declined"
        case .notInstalled:
            return "Not installed · built from source by your Go toolchain"
        }
    }

    /// The Rust row's state as one sentence — D24's seven.
    ///
    /// The Go row's sentences with the one field it has no use for folded in:
    /// what is *not installed* here has a size, because Install downloads a pinned
    /// artifact rather than building one. The declined case keeps saying only
    /// "declined", deliberately — a size beside a "no" reads as an argument
    /// against it, and the Install button standing right there is what turns it
    /// around.
    ///
    /// The version is a *date*, which is what upstream ships, so it is printed
    /// bare rather than behind the word "version" the download rows use.
    private func status(of row: LSPRustServerRow) -> String {
        // Ahead of the status for the other rows' reason: a removal keeps reading
        // `installed` right up until the files go, and that wait is a live server
        // being stopped (D16).
        if row.isRemoving { return "Removing…" }
        switch row.status {
        case .pending:
            return "Looking for a Rust toolchain…"
        case .noToolchain:
            // No Install button accompanies this, so the sentence carries all
            // three halves: why nothing is offered, that it is Rust itself that
            // is missing rather than the server, and that `.rs` files are not
            // broken by it (D23).
            return "No Rust toolchain found · rust-analyzer needs cargo · "
                + "Rust files use the built-in index"
        case .installing:
            return "Downloading…"
        case .discovered:
            return "Installed · found on this Mac"
        case .appInstalled(let version):
            return "Installed by Pisaka · \(version)"
        case .notInstalled where row.consent == .declined:
            return "Not installed · declined"
        case .notInstalled:
            return "Not installed · "
                + "\(LSPConsentBanner.size(row.pendingDownloadByteCount)) download"
        }
    }
}

#endif
