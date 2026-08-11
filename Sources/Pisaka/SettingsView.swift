#if os(macOS)
import SwiftUI
import PisakaCore

/// The Preferences window (⌘,). Hosted by the `Settings` scene in `PisakaApp`,
/// which gives the standard Preferences menu item and ⌘, shortcut automatically.
///
/// Four tabs, in the usual macOS Preferences shape: the settings form itself,
/// the downloadable language servers, the LeetCode account/folder/language, and
/// the third-party Acknowledgements. A `TabView` sizes to its widest tab, so
/// `GeneralSettingsView` keeps its own 340pt width and `AcknowledgementsView` —
/// which needs room to read a license — drives the window.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    /// Which servers may be downloaded and what state each is in. Threaded
    /// through to both of the tabs that read it — the management surface and the
    /// Acknowledgements section for what is installed — rather than each of them
    /// building its own view of the install root.
    @ObservedObject var provisioning: LSPProvisioningModel
    /// The second registry contributor, read by the Language Servers tab alone:
    /// gopls ships no licence file into its install (D17), so unlike the
    /// downloadable servers there is nothing here for Acknowledgements to show —
    /// the Go row's own sentence names its origin and licence instead.
    @ObservedObject var gopls: LSPGoplsProvisioningModel
    /// The third registry contributor, read by the Language Servers tab alone for
    /// the Go row's reason and a second one of its own: the archive is a bare
    /// `.gz` holding one binary, so nothing is unpacked that
    /// `LSPInstalledLicenses` could read and there is nothing here for
    /// Acknowledgements to show (D24). The Rust row's own sentence names its
    /// origin and licence instead.
    @ObservedObject var rust: LSPRustProvisioningModel
    let installEngine: LSPInstallEngine
    /// Who is signed in to LeetCode and where its solution files go. Read by the
    /// LeetCode tab alone, which observes it itself — so this is a plain `let`
    /// like the one the App holds, and for the same reason: nothing in *this*
    /// body reads anything published on it, and observing it here would make the
    /// whole Preferences window — Acknowledgements and its 66 KB license texts
    /// included — re-evaluate on every statement fetch and busy transition.
    let leetCode: LeetCodeModel

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            LSPServerSettingsView(provisioning: provisioning, gopls: gopls, rust: rust)
                .tabItem { Label("Language Servers", systemImage: "arrow.down.circle") }

            LeetCodeSettingsView(settings: settings, model: leetCode)
                .tabItem { Label("LeetCode", systemImage: "curlybraces") }

            AcknowledgementsView(provisioning: provisioning, installEngine: installEngine)
                .tabItem { Label("Acknowledgements", systemImage: "doc.text") }
        }
    }
}

/// The LeetCode Preferences tab: the account, the folder, and the language new
/// solution files are seeded in.
///
/// Its own tab rather than a section of General, because it carries a file path
/// — General is a 340pt column of pickers and a stepper, and a `~/Documents/…`
/// path would either be truncated there or widen every other tab with it.
///
/// The three rows are the three pieces of state the integration keeps, and each
/// is shown where it is *kept*: the account is the model's (a Keychain item plus
/// whatever LeetCode last said about it), while the folder and the language are
/// the store's. Nothing here decides anything — signing out is
/// `LeetCodeWebSession.signOut`, choosing a folder is `LeetCodeFolderChooser`,
/// and the language picker writes straight through to the persisted value, so
/// this pane and the "Open Problem…" sheet cannot disagree about which language
/// is current.
struct LeetCodeSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: LeetCodeModel

    /// Whether the sign-in web view is up over this window. Preferences is a
    /// window of its own, so it needs its own presentation state rather than
    /// borrowing the main window's.
    @State private var isSigningIn = false

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    Text(accountDescription)
                        .foregroundStyle(model.isSignedIn ? .primary : .secondary)
                    Spacer()
                    if model.isSignedIn {
                        Button("Sign Out") {
                            Task { await LeetCodeWebSession.signOut(model: model) }
                        }
                    } else {
                        Button("Sign In…") { isSigningIn = true }
                    }
                }

                // The one persistent home for `lastError`. Everything else that
                // reports a LeetCode failure is transient — the open sheet's own
                // sentence, which goes away with the sheet — and sign-in is
                // confirmed *after* the login view has been dismissed, so
                // without this a rejected session closes the web view and
                // silently flips back to "Sign In…" with no explanation.
                if let error = model.lastError {
                    Text(error.errorDescription ?? "LeetCode reported a failure.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Solution Files") {
                HStack {
                    Text(folderDescription)
                        .foregroundStyle(settings.leetCodeFolderPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.leetCodeFolderPath ?? "")
                    Spacer()
                    Button("Change…") {
                        LeetCodeFolderChooser.choose(settings: settings, model: model)
                    }
                }

                Picker("Default language", selection: $settings.leetCodeLanguage) {
                    ForEach(LeetCodeSolutionFile.offerableLanguages, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(isPresented: $isSigningIn) {
            LeetCodeLoginView(
                model: model,
                onDismiss: { isSigningIn = false },
                // Nothing to raise: this pane renders `lastError` itself, right
                // under the account row the rejection just flipped back to
                // "Sign In…" — an alert over it would say the same sentence twice.
                onFailure: { _ in }
            )
        }
    }

    /// "Signed in as …" once LeetCode has named the account, "Signed in" while
    /// the launch-time confirmation is still out (the model is optimistic about
    /// a stored session on purpose), and "Not signed in" otherwise.
    private var accountDescription: String {
        guard model.isSignedIn else { return "Not signed in" }
        guard let username = model.signedInUsername else { return "Signed in" }
        return "Signed in as \(username)"
    }

    private var folderDescription: String {
        settings.leetCodeFolderPath ?? "No folder chosen yet"
    }
}

/// The Preferences form. A thin view-layer wrapper over `SettingsStore`: all
/// option types, clamping, and persistence live in Core, so this is just the
/// SwiftUI controls bound to the store's `@Published` properties.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Tab orientation", selection: $settings.tabOrientation) {
                Text("Vertical").tag(TabOrientation.vertical)
                Text("Horizontal").tag(TabOrientation.horizontal)
            }

            Picker("Theme", selection: $settings.themePreference) {
                Text("System").tag(ThemePreference.system)
                Text("Light").tag(ThemePreference.light)
                Text("Dark").tag(ThemePreference.dark)
            }

            // The store clamps `fontSize` to `[minFontSize, maxFontSize]` on every
            // write, so the Stepper can never drive it out of range. Display the
            // current value beside it.
            Stepper(
                value: $settings.fontSize,
                in: settings.minFontSize...settings.maxFontSize,
                step: settings.fontSizeStep
            ) {
                Text("Editor font size: \(Int(settings.fontSize)) pt")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

#endif
