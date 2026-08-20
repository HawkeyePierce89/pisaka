#if os(macOS)
import SwiftUI
import PisakaCore

/// The one place this app asks to acquire something (D15).
///
/// A non-modal strip between the breadcrumb and the editor, shown only while
/// one of the three contributors' `consentPrompt(forOpening:)` answers for the
/// selected tab's language. Everything about *when* it appears is those rules' —
/// a provisionable language, consent still `unasked`, nothing installed or
/// installing (and, for Go and Rust, a toolchain to drive it) — so this view
/// holds no state of its own and cannot disagree with the Settings surface about
/// whether the question is still open.
///
/// **Three questions, one strip, and never more than one at once.** The three
/// contributors serve disjoint languages, so the branches cannot collide today;
/// they are nonetheless ordered and stated to win in that order — the 2b
/// downloads, then Go, then Rust, the order they were composed in and the order
/// the Settings tab lists them — because a banner that asked two questions in one
/// row, or stacked two rows above an editor, would be a worse thing to discover
/// than an arbitrary order.
///
/// **Two actions and no third way out.** There is no ✕, no "Later" and no
/// Esc-to-dismiss, and that is the deliberate half of "asked once": the banner
/// disappears when the consent stops being `unasked`, which happens only through
/// Download or No Thanks. A dismiss would leave the answer `unasked` and bring
/// the strip back on the next `.ts` file, which is how a prompt turns into
/// something people close without reading. Neither answer is destructive and
/// both are reversible from Preferences → Language Servers, which is what makes
/// a forced choice reasonable here.
///
/// **Non-modal on purpose.** The file behind it is open, editable and already
/// answering from the tree-sitter index; the banner is an offer to make those
/// answers better, not a precondition for working. Declining costs nothing but
/// the semantic half.
struct LSPConsentBanner: View {
    @ObservedObject var provisioning: LSPProvisioningModel

    /// The Go half. Observed for the same reason as `provisioning`: what makes
    /// the strip appear and disappear is a published change on the model, and
    /// this view is the one place that reads it.
    @ObservedObject var gopls: LSPGoplsProvisioningModel

    /// The Rust half, observed for the same reason as the two above.
    @ObservedObject var rust: LSPRustProvisioningModel

    /// The selected tab's language, or `nil` when nothing is open or the file's
    /// language is not recognized. Resolved by `ContentView` from the tab's
    /// display name (`SyntaxLanguage(forFileName:)`), so this view takes the
    /// answer rather than the file.
    let language: SyntaxLanguage?

    /// Whether a project folder is open.
    ///
    /// Nothing this banner offers is reachable without one: `LSPWorkspace.prepare`
    /// and `canServe` both open with `guard let root = currentRoot`, and the root
    /// is set by opening a *folder* — a `.ts` file opened on its own with ⌘O leaves
    /// it `nil`. Offering a 52 MB download there would spend the one-shot,
    /// permanent consent (D15 — the banner has no dismiss, so `unasked` is asked
    /// exactly once) in the one state where accepting demonstrably changes nothing.
    /// The question keeps until there is a project, and re-asks itself the moment
    /// one is opened, because this flag is part of the `.task` id below.
    let hasProjectRoot: Bool

    /// The interface zone's metrics, inherited from `ContentView`'s root — the
    /// strip sits between the breadcrumb and the editor and is chrome like both,
    /// so it grows with them rather than staying a fixed band across a scaled
    /// window.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        // An empty `VStack` renders nothing and contributes no height, so the
        // common case — every language no downloadable server serves, and every
        // one of those it does serve whose question has been answered — costs the
        // editor no layout at all. It also keeps the `.task` below
        // attached to a view that exists in *both* cases, which the two branches
        // of an `if` at `ContentView` level would not.
        //
        // **Deliberately not a `Group`**, which is the obvious spelling and the
        // wrong one: a modifier on a `Group` is applied to each of its members
        // individually, so an empty one applies it to nothing and the `.task`
        // below is never installed at all. That failure is silent and total — the
        // banner still works, because its branch is non-empty exactly when there
        // is something to show, while the silent half below only ever runs in the
        // empty case and so would never run.
        VStack(spacing: 0) {
            if let prompt {
                strip { downloadRow(prompt) }
            } else if let goPrompt {
                strip { goRow(goPrompt) }
            } else if let rustPrompt {
                strip { rustRow(rustPrompt) }
            }
        }
        // The silent half of D15, and the reason this modifier is here rather
        // than beside the banner in `ContentView`: a server the user has already
        // accepted installs when a file that needs it is opened, without asking
        // again. Same trigger as the prompt (the selected tab's language), so
        // the two halves of "what happens when this file is opened" stay in one
        // place. `prepareForOpening` does nothing at all in every other case.
        //
        // Cancellation on a tab switch is harmless: the model's install path has
        // no cancellation checks, so an install already in flight runs to
        // completion and publishes its registry regardless of which tab is on
        // screen — which is what the user asked for.
        //
        // Keyed on the project root as well as the language, so opening a folder
        // while a `.ts` file is already on screen re-runs this — without that, the
        // silent half would wait for the *language* to change before it noticed
        // there was finally something to serve.
        .task(id: Trigger(language: language, hasProjectRoot: hasProjectRoot)) {
            guard hasProjectRoot, let language else { return }
            await provisioning.prepareForOpening(language)
            // All three contributors, in the branch order above, and sequential
            // rather than concurrent: each does nothing at all for a language that
            // is not its own, so every call after the one that matched is a guard
            // away from a return.
            await gopls.prepareForOpening(language)
            await rust.prepareForOpening(language)
        }
    }

    /// What the silent half re-runs on: the selected tab's language and whether
    /// there is a project to serve.
    private struct Trigger: Equatable {
        let language: SyntaxLanguage?
        let hasProjectRoot: Bool
    }

    private var prompt: LSPConsentPrompt? {
        guard hasProjectRoot, let language else { return nil }
        return provisioning.consentPrompt(forOpening: language)
    }

    /// The Go question, under the same project-root precondition as the download
    /// one: `LSPWorkspace.prepare` opens with `guard let root = currentRoot`, so a
    /// `.go` file opened on its own with ⌘O has nothing to serve — and gopls needs
    /// a module even more plainly than sourcekit-lsp does. Spending the one-shot
    /// consent there would ask the question in the one state where accepting
    /// demonstrably changes nothing.
    private var goPrompt: LSPGoConsentPrompt? {
        guard hasProjectRoot, let language else { return nil }
        return gopls.consentPrompt(forOpening: language)
    }

    /// The Rust question, under the same project-root precondition as the other
    /// two, and with the sharpest version of its reason: rust-analyzer builds a
    /// project model out of the `Cargo.toml` above the file, so a `.rs` file
    /// opened on its own with ⌘O has nothing for it to load at all. Spending the
    /// one-shot consent — and 13 MB — there would ask in the one state where
    /// accepting demonstrably changes nothing.
    private var rustPrompt: LSPRustConsentPrompt? {
        guard hasProjectRoot, let language else { return nil }
        return rust.consentPrompt(forOpening: language)
    }

    private func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
            // The banner's own bottom rule, so the editor zone needs no
            // conditional `Divider()` beside a view that is usually empty.
            Divider()
        }
    }

    private func downloadRow(_ prompt: LSPConsentPrompt) -> some View {
        HStack(spacing: metrics.scaled(12)) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text("Download the \(prompt.displayName) language server?")
                    .font(metrics.scaledFont(.callout))
                // The size is `pendingDownloadByteCount`, so the second server
                // offers the ~4 MB it actually costs rather than the ~56 MB the
                // first one did — see `LSPConsentPrompt`.
                Text(
                    "\(Self.size(prompt.downloadByteCount)) download. "
                    + "It adds project-wide completion and Go to Definition for these files; "
                    + "without it they keep using the built-in index."
                )
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                // What this server does on the network *after* the download,
                // when the answer is not "nothing" — printed verbatim from
                // `LSPConsentPrompt.runtimeNetworkNote` in the same caption
                // style as the size sentence above it, because it is the same
                // kind of fact and belongs to the same question.
                //
                // **The presence of the note is the whole condition**: no server
                // is named here and there is no per-server branch, so a server
                // that starts talking to the network says so by carrying a note
                // in Core rather than by anyone editing this view. Consent is
                // asked once and never again, which is why the sentence has to
                // be *here* rather than only in Preferences or the docs.
                if let note = prompt.runtimeNetworkNote {
                    Text(note)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: metrics.scaled(8))

            // Unawaited: the install runs for minutes and the banner must go
            // away the moment the answer is recorded, which `accept` does
            // synchronously before its first hop. Progress is the Settings
            // row's business, not this strip's.
            //
            // **No `.keyboardShortcut(.defaultAction)`**, deliberately. This
            // strip lives in the main editor window, not in a sheet: a default
            // button there takes Return through the window's key-equivalent pass
            // *before* the first responder ever sees it, so every newline typed
            // in the file behind the banner would start a 52 MB download and
            // record consent for it. Both answers stay pointer-only.
            Button("Download") {
                Task { await provisioning.accept(prompt.server) }
            }

            Button("No Thanks") {
                provisioning.decline(prompt.server)
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// The Go question: the same strip, the same two actions and the same absence
    /// of a dismiss, with the copy that says what actually happens (D20).
    ///
    /// **A hammer rather than a download arrow**, and no size, because there is no
    /// download: accepting runs the user's own `go`, which fetches the module
    /// through Go's tooling and compiles it. Naming that `go` is the whole
    /// difference between this prompt and the one above — it is the user's
    /// toolchain, their module cache and their build cache doing the work, and a
    /// sentence that said "Pisaka will download gopls" would be false in every
    /// clause.
    ///
    /// The caches are named for the same reason, and the claim is deliberately
    /// narrower than the one this copy first made: only `GOBIN` is redirected, so
    /// the *installed binary* is the app's and the intermediates are the user's —
    /// `go install` writes into their `GOMODCACHE`/`GOCACHE`, and with
    /// `GOTOOLCHAIN=auto` may fetch a newer toolchain into the same cache (both
    /// recorded known limits in `core-lsp.md`). "Nothing outside its own folder is
    /// changed" was therefore a promise the install does not keep; "nothing is
    /// *installed* outside its own folder", plus the sentence about the caches, is
    /// what it does.
    private func goRow(_ prompt: LSPGoConsentPrompt) -> some View {
        HStack(spacing: metrics.scaled(12)) {
            Image(systemName: "hammer")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text("Install \(prompt.displayName) with your Go toolchain?")
                    .font(metrics.scaledFont(.callout))
                Text(
                    "Pisaka will build version \(prompt.version) with the Go at "
                    + "\(prompt.goExecutablePath) and keep the result to itself — nothing is "
                    + "downloaded by Pisaka and nothing is installed outside its own folder. "
                    + "The build runs as your own “go install” would, using and adding to your "
                    + "Go module and build caches. "
                    + "It adds project-wide completion and Go to Definition for these files; "
                    + "without it they keep using the built-in index."
                )
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: metrics.scaled(8))

            // Unawaited, and pointer-only, for the download branch's two reasons:
            // the build runs for minutes while the banner must go away the moment
            // the answer is recorded (`accept` records it synchronously before its
            // first hop), and a `.defaultAction` here would put every Return typed
            // in the file behind this strip on the key-equivalent path.
            Button("Install") {
                Task { await gopls.accept() }
            }

            Button("No Thanks") {
                gopls.decline()
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// The Rust question: the download row's arrow and size, because it *is* a
    /// download, over copy that says the two things that are true of this one and
    /// of neither other prompt (D21/D24).
    ///
    /// **The size is shown**, unlike Go's, because accepting fetches a pinned
    /// artifact whose byte count the manifest knows exactly — D15's rule is that
    /// nobody is asked to download something unsized — and it is
    /// `pendingDownloadByteCount` rather than the component's gross total, so a
    /// half-provisioned state offers what is actually left to fetch.
    ///
    /// **The toolchain is not mentioned**, and that is the model's doing rather
    /// than an omission: this prompt cannot appear without a `cargo` (D23), so a
    /// sentence explaining that one is required would only ever be read by
    /// someone who already has one. The machine that lacks one is told so in
    /// Preferences, where the row has room to say what it means.
    ///
    /// The version is named because it is a *date* — the shape upstream ships —
    /// and a date is the one version string worth putting in front of someone
    /// before they agree to download it.
    private func rustRow(_ prompt: LSPRustConsentPrompt) -> some View {
        HStack(spacing: metrics.scaled(12)) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text("Download the \(prompt.displayName) language server?")
                    .font(metrics.scaledFont(.callout))
                Text(
                    "\(Self.size(prompt.downloadByteCount)) download of the official "
                    + "\(prompt.version) release, verified and kept to itself. "
                    + "It adds project-wide completion and Go to Definition for these files; "
                    + "without it they keep using the built-in index."
                )
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: metrics.scaled(8))

            // Unawaited and pointer-only, for the two rows above's reasons: the
            // download runs for as long as it runs while the banner must go away
            // the moment the answer is recorded (`accept` records it before it
            // suspends, and the row it publishes reads "installing…" from that
            // same moment), and a `.defaultAction` here would put every Return
            // typed in the file behind this strip on the window's key-equivalent
            // path.
            Button("Download") {
                Task { await rust.accept() }
            }

            Button("No Thanks") {
                rust.decline()
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(12))
        .padding(.vertical, metrics.scaled(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// The approximate size, in the unit the user's Mac writes sizes in.
    /// `ByteCountFormatter` is what the Finder uses, so "52.2 MB" here means the
    /// same thing as "52.2 MB" in a download folder.
    static func size(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(byteCount))
    }
}

#endif
