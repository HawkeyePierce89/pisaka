#if os(macOS)
import SwiftUI
import PisakaCore

/// The one place this app asks to download something (D15).
///
/// A non-modal strip between the breadcrumb and the editor, shown only while
/// `LSPProvisioningModel.consentPrompt(forOpening:)` answers for the selected
/// tab's language. Everything about *when* it appears is that rule's — a
/// downloadable language, consent still `unasked`, nothing installed or
/// installing — so this view holds no state of its own and cannot disagree with
/// the Settings surface about whether the question is still open.
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
        // common case — every language that is not TypeScript, JavaScript or
        // Python, and every one of those whose question has been answered —
        // costs the editor no layout at all. It also keeps the `.task` below
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
                strip(prompt)
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

    private func strip(_ prompt: LSPConsentPrompt) -> some View {
        VStack(spacing: 0) {
            row(prompt)
            // The banner's own bottom rule, so the editor zone needs no
            // conditional `Divider()` beside a view that is usually empty.
            Divider()
        }
    }

    private func row(_ prompt: LSPConsentPrompt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Download the \(prompt.displayName) language server?")
                    .font(.callout)
                // The size is `pendingDownloadByteCount`, so the second server
                // offers the ~4 MB it actually costs rather than the ~56 MB the
                // first one did — see `LSPConsentPrompt`.
                Text(
                    "\(Self.size(prompt.downloadByteCount)) download. "
                    + "It adds project-wide completion and Go to Definition for these files; "
                    + "without it they keep using the built-in index."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
