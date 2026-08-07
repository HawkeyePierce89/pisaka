#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS Preferences screen — the peer of the macOS `SettingsView` (which is a
/// `Settings` scene reached via ⌘,; iOS has no such scene, so this is presented
/// as a sheet from `RootView_iOS`). A thin view-layer wrapper over
/// `SettingsStore`: all option types, clamping, and persistence live in Core, so
/// this is just the SwiftUI controls bound to the store's `@Published` properties.
///
/// The applied effects live where each setting is read: the theme via
/// `.preferredColorScheme` on `RootView_iOS`, the tab orientation via `TabLayout`
/// in the tab strip, and the font size in the editor — same split as macOS.
struct SettingsView_iOS: View {
    @ObservedObject var settings: SettingsStore
    /// The Keychain PAT store, managed by the Git Credentials section. Thin IO — the
    /// by-host selection logic lives in Core, so only these controls live here.
    let credentialStore: KeychainCredentialStore
    /// A host to pre-fill in the token field (set when the user is directed here from
    /// a `credentialsRequired` failure); `nil` when opened directly from the toolbar.
    var prefillHost: String?
    /// Dismisses the sheet (wired to the presenter's binding).
    var onDone: () -> Void = {}

    /// The hosts that currently have a stored token — read from the Keychain on
    /// appear and after each save/delete (the store is not observable, so the list is
    /// re-queried explicitly rather than published).
    @State private var storedHosts: [String] = []
    @State private var newHost: String = ""
    @State private var newToken: String = ""
    @State private var patError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.themePreference) {
                        Text("System").tag(ThemePreference.system)
                        Text("Light").tag(ThemePreference.light)
                        Text("Dark").tag(ThemePreference.dark)
                    }
                }

                Section("Tabs") {
                    Picker("Tab orientation", selection: $settings.tabOrientation) {
                        Text("Horizontal").tag(TabOrientation.horizontal)
                        Text("Vertical").tag(TabOrientation.vertical)
                    }
                }

                Section("Editor") {
                    // The store clamps `fontSize` to `[minFontSize, maxFontSize]` on
                    // every write, so the Stepper can never drive it out of range.
                    Stepper(
                        value: $settings.fontSize,
                        in: settings.minFontSize...settings.maxFontSize,
                        step: settings.fontSizeStep
                    ) {
                        Text("Font size: \(Int(settings.fontSize)) pt")
                    }
                }

                gitCredentialsSection

                // The peer of the macOS Preferences "Acknowledgements" tab. A push
                // rather than a tab: the `Form` is already inside a
                // `NavigationStack`, and a license text needs a full screen.
                Section("About") {
                    NavigationLink("Acknowledgements") {
                        AcknowledgementsView_iOS()
                    }
                }
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .onAppear {
                storedHosts = credentialStore.storedHosts()
                if let prefillHost, newHost.isEmpty { newHost = prefillHost }
            }
        }
    }

    /// The Git Credentials section: the stored tokens (deletable) plus a form to add
    /// a PAT for a host. Used only on iOS to fetch private repositories over HTTPS —
    /// the host is the remote's host (`github.com`), the token a Personal Access
    /// Token used as the HTTPS password.
    @ViewBuilder
    private var gitCredentialsSection: some View {
        Section {
            if storedHosts.isEmpty {
                Text("No tokens stored.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(storedHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(role: .destructive) {
                            deleteToken(forHost: host)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            TextField("Host (e.g. github.com)", text: $newHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Personal Access Token", text: $newToken)
            Button("Save Token", action: saveToken)
                .disabled(
                    newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newToken.isEmpty
                )

            if let patError {
                Text(patError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        } header: {
            Text("Git Credentials")
        } footer: {
            Text("Stored in the Keychain and used to fetch private repositories over HTTPS on iOS. For GitHub, create a fine-grained or classic Personal Access Token.")
        }
    }

    private func saveToken() {
        let host = newHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !newToken.isEmpty else { return }
        do {
            try credentialStore.save(token: newToken, forHost: host)
            newToken = ""
            patError = nil
            storedHosts = credentialStore.storedHosts()
        } catch {
            patError = error.localizedDescription
        }
    }

    private func deleteToken(forHost host: String) {
        do {
            try credentialStore.delete(forHost: host)
            patError = nil
            storedHosts = credentialStore.storedHosts()
        } catch {
            patError = error.localizedDescription
        }
    }
}
#endif
