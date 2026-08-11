#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The macOS LeetCode entry points: the "Open Problem…" sheet, the menu items
/// that raise it, and the folder chooser both of them (and Preferences) go
/// through.
///
/// Three small things in one file rather than three files, because they are one
/// decision seen from three places: what the user may type, what the app does
/// with it, and where the resulting file goes. Splitting them would put the
/// "where does a solution file live" rule in two places, which is exactly the
/// kind of duplication `LeetCodeSolutionFile` exists to prevent one layer down.
///
/// Everything decidable is Core's and is unit-tested: what a typed string means
/// is `LeetCodeProblemInput.parse(_:)`, which languages may be offered is
/// `LeetCodeSolutionFile.offerableLanguages`, and what an open *does* is
/// `LeetCodeModel.openProblem(input:language:)`. This file is chrome around
/// them, untested like the rest of the app layer.
struct LeetCodeOpenProblemSheet: View {
    @ObservedObject var model: LeetCodeModel
    /// The persisted preferences, for the language picker: the picker is bound
    /// straight to `leetCodeLanguage`, so choosing one *is* persisting it and
    /// the next sheet opens on the last choice with no separate "remember"
    /// step.
    @ObservedObject var settings: SettingsStore

    /// Run the open. Answers `nil` when the problem opened — in which case the
    /// presenter has already taken the sheet down — and the sentence to show
    /// under the field when it did not.
    ///
    /// A returned sentence rather than an alert: while this sheet is up it *is*
    /// the surface the user is looking at, and a modal alert over a modal sheet
    /// to say "no problem with that number" would make a typo look like a
    /// failure. `PlatformAlert` stays for the failures that happen with no sheet
    /// on screen.
    var onOpen: (LeetCodeProblemInput, LeetCodeLanguage) async -> String?

    /// Take the sheet down. Owned by the presenter, which also owns the state
    /// that put it up.
    var onCancel: () -> Void

    /// What the user typed. Parsed on every keystroke — the parse is pure string
    /// work over a short string — so the Open button's enablement and the hint
    /// line are always describing the current text.
    @State private var text = ""

    /// The outcome of the last attempt, or `nil` before the first one. Cleared
    /// on every edit, so a stale sentence never sits under a fresh input.
    @State private var message: String?

    private var parsed: LeetCodeProblemInput? { LeetCodeProblemInput.parse(text) }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            input
            status
            buttons
        }
        .padding(20)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open LeetCode Problem")
                .font(.headline)
            Text("A problem number, its slug, or a leetcode.com problem URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("1, two-sum, or https://leetcode.com/problems/two-sum/", text: $text)
                .textFieldStyle(.roundedBorder)
                // Enter submits, but only when the text names something — the
                // same condition the Open button is under, so the two cannot
                // disagree.
                .onSubmit { open() }
                .onChange(of: text) { _ in message = nil }
                .disabled(model.isBusy)

            Picker("Language", selection: $settings.leetCodeLanguage) {
                ForEach(LeetCodeSolutionFile.offerableLanguages, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .disabled(model.isBusy)
        }
    }

    /// The one line under the controls: the parse hint while typing, the last
    /// attempt's sentence afterwards. Kept at a fixed minimum height so the
    /// sheet does not resize as it appears and disappears.
    @ViewBuilder
    private var status: some View {
        Group {
            if let message {
                Text(message)
                    .foregroundStyle(.red)
            } else if !isBlank, parsed == nil {
                Text("Not a problem number, slug or LeetCode URL.")
                    .foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching from LeetCode…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Open") { open() }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil || model.isBusy)
        }
    }

    /// Hand the parsed input to the presenter and show whatever it answers.
    ///
    /// Guarded on `isBusy` as well as on the parse, because Enter reaches this
    /// even while the button is disabled: two overlapping opens are safe by
    /// construction (the model's generation token discards the older one), but
    /// the second would be a second round trip for a question already in flight.
    private func open() {
        guard let input = parsed, !model.isBusy else { return }
        message = nil
        let language = settings.leetCodeLanguage
        Task { message = await onOpen(input, language) }
    }
}

/// The LeetCode menu's items, as a view of their own rather than inline in
/// `PisakaApp`'s `.commands`.
///
/// Its own `@ObservedObject` deliberately: the Sign In / Sign Out item's label
/// depends on `isSignedIn`, and observing the model from the App's scene body
/// instead would make that body — and with it `ContentView`, the project tree,
/// the tab list and `CodeEditorView.updateNSView` — a subscriber to every
/// statement fetch and every busy transition. The same reasoning `PisakaApp`
/// writes on its non-observed `commitDialog` and `symbolIndex`, applied to a
/// place that genuinely does need to observe: the observation is pushed down to
/// the menu, which is the only thing that re-renders.
struct LeetCodeCommands: View {
    @ObservedObject var model: LeetCodeModel

    var onOpenProblem: () -> Void
    var onSignIn: () -> Void
    var onSignOut: () -> Void
    var onChooseFolder: () -> Void

    var body: some View {
        // ⌘⇧P — free on macOS and beside the other ⌘⇧ panel/window commands.
        Button("Open Problem…") { onOpenProblem() }
            .keyboardShortcut("p", modifiers: [.command, .shift])

        Divider()

        if model.isSignedIn {
            Button(signOutTitle) { onSignOut() }
        } else {
            Button("Sign In…") { onSignIn() }
        }

        Button("Choose LeetCode Folder…") { onChooseFolder() }
    }

    /// "Sign Out" until LeetCode has told us who this session is, and then the
    /// account name — the one place in the macOS chrome that shows it, since a
    /// menu title is where the user looks to check they are on the right
    /// account.
    private var signOutTitle: String {
        guard let username = model.signedInUsername else { return "Sign Out" }
        return "Sign Out (\(username))"
    }
}

/// Where LeetCode solution files go on this Mac, and how the user changes it.
///
/// **A plain persisted path, with no security-scoped bookmark**, because this
/// app ships no `.entitlements` and `project.yml` enables no App Sandbox: the
/// macOS build is unsandboxed and reaches any path the user names, exactly as
/// "Open Folder…" already does. Bookmarks are an iOS-only concern here, which is
/// why `SettingsStore` carries both a `leetCodeFolderPath` and a
/// `leetCodeFolderBookmark` and this platform only ever writes the first.
///
/// The default is `~/Documents/LeetCode`, **created before the panel opens** so
/// the panel starts inside it rather than beside it: an open panel pre-targeted
/// at a directory that does not exist falls back to somewhere arbitrary, and the
/// user would have to make the folder themselves to accept the suggestion.
@MainActor
enum LeetCodeFolderChooser {
    /// The suggested location: `~/Documents/LeetCode`.
    static var defaultFolder: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("LeetCode", isDirectory: true)
    }

    /// The configured folder, asking for one if none has been configured yet —
    /// the "on first use" half of the requirement.
    ///
    /// `nil` means the user cancelled the panel, which is not a failure and gets
    /// no alert: they asked to open a problem, were asked where to put it, and
    /// declined to say.
    static func established(settings: SettingsStore, model: LeetCodeModel) -> URL? {
        if let configured = settings.leetCodeFolderURL {
            // Re-published every time rather than only on change: the model's
            // folder is captured synchronously by `openProblem`, so it must be
            // the configured one *before* the call, and assigning an equal URL
            // costs one publish nobody in this app's chrome renders differently.
            model.solutionsFolder = configured
            return configured
        }
        return choose(settings: settings, model: model)
    }

    /// Ask for the folder and persist the answer.
    ///
    /// Writes to both places that hold it — `SettingsStore` (across launches)
    /// and the live model (this session) — so there is no window in which an
    /// open would land somewhere the Preferences pane is not showing.
    @discardableResult
    static func choose(settings: SettingsStore, model: LeetCodeModel) -> URL? {
        let suggestion = defaultFolder
        try? FileService().ensureDirectory(at: suggestion)
        guard let chosen = FilePanels.showOpenFolderPanel(
            directoryURL: suggestion,
            message: "Choose the folder Pisaka writes LeetCode solution files into."
        ) else { return nil }
        settings.leetCodeFolderPath = chosen.path
        model.solutionsFolder = chosen
        return chosen
    }
}
#endif
