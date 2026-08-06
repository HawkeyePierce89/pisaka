#if os(macOS)
import SwiftUI
import PisakaCore

/// The Preferences form (⌘,). A thin view-layer wrapper over `SettingsStore`:
/// all option types, clamping, and persistence live in Core, so this is just the
/// SwiftUI controls bound to the store's `@Published` properties. Hosted by the
/// `Settings` scene in `PisakaApp`, which gives the standard Preferences menu item
/// and ⌘, shortcut automatically.
struct SettingsView: View {
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
