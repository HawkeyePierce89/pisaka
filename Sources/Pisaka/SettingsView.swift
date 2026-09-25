#if os(macOS)
import SwiftUI
import PisakaCore

/// The Preferences window (⌘,). Hosted by the `Settings` scene in `PisakaApp`,
/// which gives the standard Preferences menu item and ⌘, shortcut automatically.
///
/// Four pages, in the usual macOS Preferences order: the settings form itself,
/// the downloadable language servers, the LeetCode account/folder/language, and
/// the third-party Acknowledgements. The host is a `ChromeSettingsTabBar` over
/// the selected page, and every page is framed at the one size
/// (`SettingsLayout`) Acknowledgements needs to read a license — so switching
/// tabs never resizes the window. Only the selected page is built.
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

    /// The selected page; the window opens on General.
    @State private var selection: SettingsTab = .general

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ChromeSettingsTabBar(
                tabs: SettingsTab.allCases.map { (tab: $0, title: $0.title) },
                selection: $selection
            )
            page
                .frame(
                    width: metrics.scaled(SettingsLayout.pageWidth),
                    height: metrics.scaled(SettingsLayout.pageHeight),
                    alignment: .topLeading
                )
        }
        .background(theme.color(.bgPanel))
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .general:
            GeneralSettingsView(settings: settings)
        case .languageServers:
            LSPServerSettingsView(provisioning: provisioning, gopls: gopls, rust: rust)
        case .leetCode:
            LeetCodeSettingsView(settings: settings, model: leetCode)
        case .acknowledgements:
            AcknowledgementsView(provisioning: provisioning, installEngine: installEngine)
        }
    }
}

/// The Preferences window's four pages, in tab order.
private enum SettingsTab: CaseIterable, Hashable {
    case general
    case languageServers
    case leetCode
    case acknowledgements

    var title: String {
        switch self {
        case .general: "General"
        case .languageServers: "Language Servers"
        case .leetCode: "LeetCode"
        case .acknowledgements: "Acknowledgements"
        }
    }
}

/// The one page size every Preferences page is framed at, in points before the
/// interface scale: the size Acknowledgements needs to hold its list beside a
/// license (`InterfaceMetricsTests` pins that arithmetic).
private enum SettingsLayout {
    static let pageWidth: Double = 640
    static let pageHeight: Double = 420
}

/// One labelled Preferences row: a `settingsLabelColumnWidth` label column
/// (`callout`, `textSecondary`, wrapping rather than clipped),
/// `settingsLabelGap`, then the control at its natural width.
///
/// When the control is one of the shared shapes it speaks the row's label
/// itself, so the label column is hidden from accessibility and the name is
/// read once (`controlSpeaksLabel`); a composite row keeps its label readable.
private struct SettingsRow<Control: View>: View {
    let label: String
    var controlSpeaksLabel = true
    @ViewBuilder let control: () -> Control

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: metrics.scaled(ChromeGeometry.settingsLabelGap)) {
            Text(label)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: metrics.scaled(ChromeGeometry.settingsLabelColumnWidth), alignment: .leading)
                .accessibilityHidden(controlSpeaksLabel)
            control()
            Spacer(minLength: 0)
        }
    }
}

/// A page of `SettingsRow`s: `settingsRowSpacing` apart, padded by
/// `settingsPagePadding`.
private struct SettingsPage<Rows: View>: View {
    @ViewBuilder let rows: () -> Rows

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(ChromeGeometry.settingsRowSpacing)) {
            rows()
        }
        .padding(metrics.scaled(ChromeGeometry.settingsPagePadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The LeetCode Preferences tab: the account, the folder, and the language new
/// solution files are seeded in.
///
/// Its own tab rather than a section of General, because it carries a file path
/// — General is a column of pickers, steppers and switches, and a
/// `~/Documents/…` path would be truncated there to the point of naming nothing.
///
/// The three rows are the three pieces of state the integration keeps, and each
/// is shown where it is *kept*: the account is the model's (a Keychain item plus
/// whatever LeetCode last said about it), while the folder and the language are
/// the store's. Nothing here decides anything — signing out is
/// `LeetCodeWebSession.signOut`, choosing a folder is `LeetCodeFolderChooser`,
/// and the language field writes straight through to the persisted value, so
/// this pane and the "Open Problem…" sheet cannot disagree about which language
/// is current.
struct LeetCodeSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: LeetCodeModel

    /// Whether the sign-in web view is up over this window. Preferences is a
    /// window of its own, so it needs its own presentation state rather than
    /// borrowing the main window's.
    @State private var isSigningIn = false

    /// The interface zone's metrics, inherited from the `Settings` scene root.
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        SettingsPage {
            SettingsRow(label: "Account", controlSpeaksLabel: false) {
                VStack(alignment: .leading, spacing: metrics.scaled(6)) {
                    HStack(spacing: metrics.scaled(ChromeGeometry.settingsLabelGap)) {
                        Text(accountDescription)
                            .font(metrics.scaledFont(.body))
                            .foregroundStyle(theme.color(model.isSignedIn ? .textPrimary : .textSecondary))
                        if model.isSignedIn {
                            Button("Sign Out") {
                                Task { await LeetCodeWebSession.signOut(model: model) }
                            }
                            .buttonStyle(.chromeSecondary)
                        } else {
                            Button("Sign In…") { isSigningIn = true }
                                .buttonStyle(.chromeSecondary)
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
                            .font(metrics.scaledFont(.caption))
                            .foregroundStyle(theme.color(.statusRed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsRow(label: "Solution Files", controlSpeaksLabel: false) {
                HStack(spacing: metrics.scaled(ChromeGeometry.settingsLabelGap)) {
                    Text(folderDescription)
                        .font(metrics.scaledFont(.body))
                        .foregroundStyle(
                            theme.color(settings.leetCodeFolderPath == nil ? .textSecondary : .textPrimary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.leetCodeFolderPath ?? "")
                    Button("Change…") {
                        LeetCodeFolderChooser.choose(settings: settings, model: model)
                    }
                    .buttonStyle(.chromeSecondary)
                }
            }

            SettingsRow(label: "Default language") {
                ChromeMenuField(
                    label: "Default language",
                    options: LeetCodeSolutionFile.offerableLanguages.map { (value: $0, title: $0.displayName) },
                    selection: $settings.leetCodeLanguage,
                    currentTitle: settings.leetCodeLanguage.displayName
                )
                .frame(height: metrics.scaled(ChromeGeometry.menuFieldHeight))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        // This pane renders the account row, so it resolves the account on appear
        // (L27). The host builds only the selected page, so this runs when the
        // LeetCode tab is actually shown — opening Preferences on another tab
        // resolves nothing.
        .onAppear { model.resolveAccount() }
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
    /// the confirmation first use started is still out (the model is optimistic
    /// about a stored session on purpose), and "Not signed in" otherwise — which
    /// is also what an account nobody has resolved yet reads as.
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
/// shared chrome controls bound to the store's `@Published` properties.
struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// The interface zone's metrics, inherited from the `Settings` scene root.
    ///
    /// The form is chrome like any other, including the two font-size steppers:
    /// what they *set* is the code and terminal zones, but the row that sets it
    /// belongs to the interface — so a 150% Preferences window shows a 150% label
    /// beside a value that is still whatever the editor is drawn at.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        SettingsPage {
            SettingsRow(label: "Tab orientation") {
                ChromeSegmentedControl(
                    label: "Tab orientation",
                    options: [
                        (value: TabOrientation.vertical, title: "Vertical"),
                        (value: TabOrientation.horizontal, title: "Horizontal"),
                    ],
                    selection: $settings.tabOrientation
                )
            }

            SettingsRow(label: "Theme") {
                ChromeSegmentedControl(
                    label: "Theme",
                    options: [
                        (value: ThemePreference.system, title: "System"),
                        (value: ThemePreference.light, title: "Light"),
                        (value: ThemePreference.dark, title: "Dark"),
                    ],
                    selection: $settings.themePreference
                )
            }

            // Bounds and step come from `ZoomScaleRule.editorFont`, the same rule
            // the zoom gestures and ⌘0 go through, so a stepper press and a zoom
            // step land on the same grid, and the store's clamp-on-write can never
            // be driven out of range from here.
            SettingsRow(label: "Editor font size") {
                ChromeStepper(
                    label: "Editor font size",
                    value: $settings.fontSize,
                    rule: ZoomScaleRule.editorFont,
                    format: { "\(Int($0)) pt" }
                )
            }

            // The terminal zone's size, beside the code zone's — the two are
            // independent settings and this is the one place both are visible at
            // once. Its grid is `ZoomScaleRule.terminalFont`, for the editor row's
            // reason.
            SettingsRow(label: "Terminal font size") {
                ChromeStepper(
                    label: "Terminal font size",
                    value: $settings.terminalFontSize,
                    rule: ZoomScaleRule.terminalFont,
                    format: { "\(Int($0)) pt" }
                )
            }

            // The same flag the status-bar lightbulb writes: both bind straight
            // through to the store, so the two surfaces can never disagree. Off
            // is total — the automatic popup *and* explicit invocation (⌃Space,
            // Find > Complete, AppKit's stock ⌥⎋/F5) — while the symbol index,
            // the LSP layer and Go to Definition are untouched.
            SettingsRow(label: "Offer completions as you type") {
                ChromeSwitch(label: "Offer completions as you type", isOn: $settings.completionEnabled)
            }

            // The editor's second switch, bound straight through to the store
            // like the first: no local state, so the surface and the preference
            // cannot disagree, and the change reaches every open tab at once
            // through the value the content view passes down. Off draws nothing
            // and computes nothing; the text, the selection and every other
            // background are unchanged either way, because the blocks are a pass
            // underneath them rather than a styling of the text.
            SettingsRow(label: "Highlight indentation levels") {
                ChromeSwitch(label: "Highlight indentation levels", isOn: $settings.indentLevelHighlightingEnabled)
            }
        }
    }
}

#endif
