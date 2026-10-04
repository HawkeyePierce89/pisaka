#if os(macOS)
import SwiftUI
import PisakaCore

/// The one place this app asks to acquire something (D15).
///
/// A non-modal card between the breadcrumb and the editor — drawn by
/// `LSPConsentCard` below — shown only while
/// one of the three contributors' `consentPrompt(forOpening:)` answers for the
/// selected tab's language. Everything about *when* it appears is those rules' —
/// a provisionable language, consent still `unasked`, nothing installed or
/// installing (and, for Go and Rust, a toolchain to drive it) — so this view
/// holds no state of its own and cannot disagree with the Settings surface about
/// whether the question is still open.
///
/// **Three questions, one card, and never more than one at once.** The three
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
/// the card back on the next `.ts` file, which is how a prompt turns into
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
    /// the card appear and disappear is a published change on the model, and
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
                downloadCard(prompt)
            } else if let goPrompt {
                goCard(goPrompt)
            } else if let rustPrompt {
                rustCard(rustPrompt)
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

    /// The pinned downloads' question — TypeScript/JavaScript, Python, YAML —
    /// on one primary line carrying the size, so nobody is asked to download
    /// something unsized (D15).
    ///
    /// The size is `downloadByteCount`, the *pending* byte count, so the second
    /// server offers the ~4 MB it actually costs rather than the ~56 MB the first
    /// one did — see `LSPConsentPrompt`.
    ///
    /// The secondary line is what this server does on the network *after* the
    /// download, when the answer is not "nothing" — printed verbatim from
    /// `LSPConsentPrompt.runtimeNetworkNote`. **The presence of the note is the
    /// whole condition**: no server is named here and there is no per-server
    /// branch, so a server that starts talking to the network says so by carrying
    /// a note in Core rather than by anyone editing this view. Consent is asked
    /// once and never again, which is why the sentence has to be *here* rather
    /// than only in Preferences or the docs.
    ///
    /// `accept` is unawaited: the install runs for minutes and the card must go
    /// away the moment the answer is recorded, which `accept` does synchronously
    /// before its first hop. Progress is the Settings row's business, not this
    /// card's.
    private func downloadCard(_ prompt: LSPConsentPrompt) -> some View {
        LSPConsentCard(
            symbolName: "arrow.down.circle",
            message: "Download the \(prompt.displayName) language server "
                + "(\(Self.size(prompt.downloadByteCount))) for completion and Go to Definition?",
            detail: prompt.runtimeNetworkNote,
            confirmTitle: "Download",
            onConfirm: { Task { await provisioning.accept(prompt.server) } },
            onDecline: { provisioning.decline(prompt.server) }
        )
    }

    /// The Go question: the same card, the same two actions and the same absence
    /// of a dismiss, with the copy that says what actually happens (D20).
    ///
    /// **A hammer rather than a download arrow**, and no size, because there is no
    /// download: accepting runs the user's own `go`, which fetches the module
    /// through Go's tooling and compiles it. The primary line says so — *build*,
    /// with *your own Go toolchain* — and stays short, so the toolchain's path,
    /// which can be any length, sits on the secondary line and a long one wraps
    /// that line rather than the question.
    ///
    /// The caches are named on the secondary line, and the claim is deliberately
    /// narrow: only `GOBIN` is redirected, so the *installed binary* is the app's
    /// and the intermediates are the user's — `go install` writes into their
    /// `GOMODCACHE`/`GOCACHE`, and with `GOTOOLCHAIN=auto` may fetch a newer
    /// toolchain into the same cache (both recorded known limits in
    /// `core-lsp.md`). A sentence that nothing outside the app's folder changes
    /// would be a promise the install does not keep; "installed only inside
    /// Pisaka's own folder", beside the sentence about the caches, is what it does.
    ///
    /// Unawaited for the download card's reason: the build runs for minutes while
    /// the card must go away the moment the answer is recorded, which `accept`
    /// does synchronously before its first hop.
    private func goCard(_ prompt: LSPGoConsentPrompt) -> some View {
        LSPConsentCard(
            symbolName: "hammer",
            message: "Build \(prompt.displayName) \(prompt.version) with your own Go toolchain?",
            detail: "The build runs as your own “go install” would with the Go at "
                + "\(prompt.goExecutablePath), using and adding to your module and build caches; "
                + "the result is installed only inside Pisaka's own folder.",
            confirmTitle: "Install",
            onConfirm: { Task { await gopls.accept() } },
            onDecline: { gopls.decline() }
        )
    }

    /// The Rust question: the download card's arrow and size, because it *is* a
    /// download, on one primary line and no secondary (D21/D24).
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
    /// The version is folded into the line because it is a *date* — the shape
    /// upstream ships — and a date is the one version string worth putting in
    /// front of someone before they agree to download it.
    ///
    /// Unawaited for the other two cards' reason: `accept` records the answer
    /// before it suspends, and the row it publishes reads "installing…" from that
    /// same moment.
    private func rustCard(_ prompt: LSPRustConsentPrompt) -> some View {
        LSPConsentCard(
            symbolName: "arrow.down.circle",
            message: "Download \(prompt.displayName) \(prompt.version) "
                + "(\(Self.size(prompt.downloadByteCount))) for completion and Go to Definition?",
            detail: nil,
            confirmTitle: "Download",
            onConfirm: { Task { await rust.accept() } },
            onDecline: { rust.decline() }
        )
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

/// One consent question, drawn as the design's Banner card in its inset band —
/// the only thing that draws a question, so the three cannot drift into three
/// looks, and the very view the app-layer bitmap suite renders, so what it pins
/// is what ships.
///
/// **The band** is full width on the editor's own ground, `bgEditor`, with an
/// 8-point inset on every side; the card's hairline border is what separates it
/// from the editor below, so there is no bottom rule and no `Divider()` — a
/// divider is drawn in the *system's* separator value, which is not the table's.
///
/// **The card** is the panel ground in a rounded rectangle of the largest chrome
/// radius under a one-hairline border, padded 14 vertically and 18 horizontally:
/// a 16-point accent icon, the text column 10 beyond it, then the actions pushed
/// to the trailing edge at least 16 away, every item vertically centred.
///
/// **The text column takes all the width the actions leave**, rather than
/// sharing it with the spacer and wrapping at half of what it could use. Its
/// `.layoutPriority(1)` states that intent; a hand mutation showed the stack
/// lays the spacer out after the text without it, so the bitmap suite pins the
/// drawn outcome rather than the modifier. The primary line is the body size in
/// `textPrimary`; the optional secondary line is the subheadline size in
/// `textSecondary` and wraps across the whole column. The buttons keep their
/// fitting width, so they never wrap or truncate.
///
/// **The actions** are the shared `.chromePrimary` (the offer) and
/// `.chromeSecondary` (the refusal) styles, 8 apart — the one primary and one
/// secondary button every chrome surface draws — so the card carries no button
/// look of its own to drift from theirs.
///
/// **No `.keyboardShortcut(.defaultAction)`**, deliberately. The card lives in
/// the main editor window, not in a sheet: a default button there takes Return
/// through the window's key-equivalent pass *before* the first responder ever
/// sees it, so every newline typed in the file behind the card would start a
/// download and record consent for it. Both answers stay pointer-only.
struct LSPConsentCard: View {
    let symbolName: String
    /// The primary line: the question itself, short enough for one line.
    let message: String
    /// The secondary line, present only where a fact requires one.
    let detail: String?
    let confirmTitle: String
    let onConfirm: () -> Void
    let onDecline: () -> Void

    /// The interface zone's metrics, inherited from `ContentView`'s root — the
    /// card sits between the breadcrumb and the editor and is chrome like both,
    /// so it grows with them rather than staying a fixed band across a scaled
    /// window.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome's colours, inherited from the same root, so the band, the
    /// card, its border and its text take the roles rather than whatever the
    /// system happens to call a control background.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.cornerRadiusMax))
        HStack(alignment: .center, spacing: 0) {
            // The design's 16-point icon, sized on its own chain through the
            // metrics: the message has no container font, which would be a size
            // nothing but this glyph uses.
            Image(systemName: symbolName)
                .font(.system(size: metrics.scaled(16)))
                .foregroundStyle(theme.color(.accent))

            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text(message)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textPrimary))
                if let detail {
                    Text(detail)
                        .font(metrics.scaledFont(.subheadline))
                        .foregroundStyle(theme.color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, metrics.scaled(10))
            .layoutPriority(1)

            Spacer(minLength: metrics.scaled(16))

            HStack(spacing: metrics.scaled(8)) {
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.chromePrimary)
                Button("No Thanks", action: onDecline)
                    .buttonStyle(.chromeSecondary)
            }
            .fixedSize()
        }
        .padding(.vertical, metrics.scaled(14))
        .padding(.horizontal, metrics.scaled(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.color(.bgPanel)))
        .overlay(
            shape.strokeBorder(
                theme.color(.hairline),
                lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth)
            )
        )
        .padding(metrics.scaled(8))
        .frame(maxWidth: .infinity)
        .background(theme.color(.bgEditor))
    }
}

#endif
