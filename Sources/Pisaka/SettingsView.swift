#if os(macOS)
import SwiftUI
import PisakaCore

/// The Preferences window (⌘,). Hosted by the `Settings` scene in `PisakaApp`,
/// which gives the standard Preferences menu item and ⌘, shortcut automatically.
///
/// Three tabs, in the usual macOS Preferences shape: the settings form itself,
/// the downloadable language servers, and the third-party Acknowledgements. A
/// `TabView` sizes to its widest tab, so `GeneralSettingsView` keeps its own
/// 340pt width and `AcknowledgementsView` — which needs room to read a license —
/// drives the window.
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

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            LSPServerSettingsView(provisioning: provisioning, gopls: gopls, rust: rust)
                .tabItem { Label("Language Servers", systemImage: "arrow.down.circle") }

            AcknowledgementsView(provisioning: provisioning, installEngine: installEngine)
                .tabItem { Label("Acknowledgements", systemImage: "doc.text") }
        }
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
