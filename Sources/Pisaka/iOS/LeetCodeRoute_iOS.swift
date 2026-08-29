#if os(iOS)
import PisakaCore
import SwiftUI

/// Where LeetCode solution files go on iOS, and how the user changes it.
///
/// **The asymmetry with macOS is the whole point of this type.** The Mac build is
/// unsandboxed (the repo ships no `.entitlements` and `project.yml` enables no App
/// Sandbox), so `LeetCodeFolderChooser` there persists a plain path and reaches it
/// directly. iOS has no such freedom: a directory outside the app container is
/// reachable only through a security-scoped url the document picker vended, and
/// only for as long as a bookmark keeps resolving. So this platform keeps *two*
/// answers, which is why `SettingsStore` carries both a `leetCodeFolderPath` and a
/// `leetCodeFolderBookmark`:
///
/// - **The default needs no bookmark at all.** `Documents/LeetCode` inside the app
///   container is ordinary, unscoped, always-writable storage, so the common case
///   never involves the picker, never involves a bookmark, and cannot break when
///   one goes stale. It is created on first use rather than at launch — a user who
///   never opens a problem gets no directory they did not ask for.
/// - **An override is a bookmark**, resolved through the same
///   `SecurityScopedBookmarks` the project-folder restore uses and registered with
///   the same `SecurityScopedFileService`, so the solution write, the statement
///   cache and every later read run under its grant exactly like the opened
///   project's do.
///
/// A bookmark that no longer resolves is **forgotten, and the default takes over**
/// rather than the integration reporting `folderUnavailable` forever: the folder
/// moved or the user revoked access, and silently continuing to work in the
/// container is a better answer than a feature that has quietly stopped.
///
/// `leetCodeFolderPath` is written on both paths, because it is what the Settings
/// screen shows and what `RootView_iOS` keys its statement `.task` on — the
/// bookmark is the *authority* on an override, the path is the *display* of
/// whichever folder won.
@MainActor
enum LeetCodeFolder_iOS {
    /// `<container>/Documents/LeetCode` — visible in the Files app under
    /// "On My iPhone → Pisaka" (`UIFileSharingEnabled` in `project.yml`, pinned
    /// by `ReleaseMetadataTests`), and reachable by this app regardless.
    ///
    /// The fallback is unreachable in practice and exists so this is a `URL`
    /// rather than an optional threaded through every caller, the shape
    /// `LeetCodeSupportDirectory.cacheBase` already takes.
    /// A picked folder this run is using **without** a bookmark behind it.
    ///
    /// The failure it exists for is narrow and its handling is what the doc above
    /// promises: `SecurityScopedBookmarks.makeBookmark(for:)` answered `nil`, so
    /// there is nothing to reach this folder with at the *next* launch — but the
    /// picker's grant is live now, `scopedService` has it registered, and the user
    /// just said this is where their solutions go. Without this the override would
    /// be honoured until the next `publish` — which `established(…)` runs on every
    /// open — and then silently revert to the container, writing the file
    /// somewhere the Settings screen was not showing.
    ///
    /// Deliberately *not* persisted: a path with no bookmark is unreachable after
    /// this process ends, and re-reading it next launch would be a folder the app
    /// cannot write to presented as the one in force.
    private static var sessionOverride: URL?

    static var containerDefault: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("LeetCode", isDirectory: true)
    }

    /// Resolve the configured folder and publish it to both places that hold it —
    /// **without creating anything**.
    ///
    /// This is what launch calls. The model's `solutionsFolder` is captured
    /// synchronously by `openProblem`, and the *settings* path is what the
    /// statement `.task` keys on, so both must be right before the first open and
    /// before the first tab is restored — but a user who never touches LeetCode
    /// must not find a directory this app made for them, so the `ensureDirectory`
    /// waits for `established(…)`.
    @discardableResult
    static func publish(
        settings: SettingsStore,
        model: LeetCodeModel,
        scopedService: SecurityScopedFileService
    ) -> URL {
        let folder = resolve(settings: settings, scopedService: scopedService)
        // Only when it actually changed: the setter writes through to
        // `UserDefaults` and republishes, and this runs on every open.
        if settings.leetCodeFolderPath != folder.path {
            settings.leetCodeFolderPath = folder.path
        }
        model.solutionsFolder = folder
        return folder
    }

    /// The configured folder, created if it is not there yet — the "on first use"
    /// half of the requirement, and the iOS peer of
    /// `LeetCodeFolderChooser.established`.
    ///
    /// `nil` means the directory could not be made, which the caller reports as
    /// `folderUnavailable`. Unlike macOS there is no cancellable panel in this
    /// path: the default always exists to fall back to, so an iOS open never has
    /// to ask the user a question before it can start.
    static func established(
        settings: SettingsStore,
        model: LeetCodeModel,
        scopedService: SecurityScopedFileService
    ) -> URL? {
        let folder = publish(settings: settings, model: model, scopedService: scopedService)
        // Through the scoped service, not a bare `FileService`: an overridden
        // folder is only writable inside its grant, and this is the first write
        // that touches it.
        guard (try? scopedService.ensureDirectory(at: folder)) != nil else { return nil }
        return folder
    }

    /// Adopt a folder the document picker vended: register its scope, persist a
    /// bookmark, and point both halves at it.
    ///
    /// Bookmarked *and* registered, in that order, for `FileAccessController`'s
    /// reason — the bookmark is how the next launch reaches it, the registration
    /// is how *this* launch does. A bookmark that cannot be created leaves the
    /// override in force for the session (`sessionOverride`) and reverts to the
    /// default next launch, which is the same degradation the project-folder path
    /// already accepts.
    static func adopt(
        _ picked: URL,
        settings: SettingsStore,
        model: LeetCodeModel,
        scopedService: SecurityScopedFileService
    ) {
        scopedService.register(picked)
        let bookmark = SecurityScopedBookmarks.makeBookmark(for: picked)
        // Assigned either way, so a *previous* override cannot survive a pick
        // that replaced it; the session copy is what carries this one when there
        // is no bookmark to carry it with.
        settings.leetCodeFolderBookmark = bookmark
        sessionOverride = bookmark == nil ? picked : nil
        settings.leetCodeFolderPath = picked.standardizedFileURL.path
        model.solutionsFolder = picked
        try? scopedService.ensureDirectory(at: picked)
    }

    /// Drop an override and go back to the container default. The bookmark is the
    /// authority, so forgetting it *is* the revert — along with the bookmark-less
    /// session copy, which is an override too.
    static func useDefault(
        settings: SettingsStore,
        model: LeetCodeModel,
        scopedService: SecurityScopedFileService
    ) {
        settings.leetCodeFolderBookmark = nil
        sessionOverride = nil
        settings.leetCodeFolderPath = nil
        publish(settings: settings, model: model, scopedService: scopedService)
    }

    /// Whether the folder in force is a picked override rather than the container
    /// default — what the Settings screen offers "Use Default" for. Both kinds
    /// count: a folder the user has to be able to leave is a folder they picked,
    /// whether or not a bookmark for it could be made.
    static func isOverridden(settings: SettingsStore) -> Bool {
        settings.leetCodeFolderBookmark != nil || sessionOverride != nil
    }

    /// The override if it still resolves, the container default otherwise.
    private static func resolve(
        settings: SettingsStore,
        scopedService: SecurityScopedFileService
    ) -> URL {
        guard let bookmark = settings.leetCodeFolderBookmark else {
            // No bookmark, but possibly a folder picked this run that none could
            // be made for. Re-registered on every resolve for the same reason the
            // bookmark branch below registers: the grant is what makes it
            // writable, and registration is idempotent.
            if let sessionOverride {
                scopedService.register(sessionOverride)
                return sessionOverride
            }
            return containerDefault
        }
        var isStale = false
        guard let url = SecurityScopedBookmarks.resolve(bookmark, isStale: &isStale) else {
            // Gone for good: forget it here rather than re-attempting the same
            // failed resolve on every open, and let the default take over.
            settings.leetCodeFolderBookmark = nil
            return containerDefault
        }
        scopedService.register(url)
        if isStale, let refreshed = SecurityScopedBookmarks.makeBookmark(for: url) {
            settings.leetCodeFolderBookmark = refreshed
        }
        return url
    }
}

/// The iOS LeetCode screen: who is signed in, and what to open.
///
/// The peer of the macOS pair `LeetCodeCommands` (the menu) + `LeetCodeOpenProblemSheet`
/// (the dialog), merged into one screen because iOS has no menu bar to hang the
/// account state off — so the account row lives at the top of the same sheet the
/// input field is in, which is also the only place a signed-out user would look
/// for the way in.
///
/// Everything decidable is Core's and is unit-tested: what a typed string means
/// is `LeetCodeProblemInput.parse(_:)`, which languages may be offered is
/// `LeetCodeSolutionFile.offerableLanguages`, and what an open *does* is
/// `LeetCodeModel.openProblem(input:language:)`. This is chrome around them,
/// untested like the rest of the app layer.
struct LeetCodeRoute_iOS: View {
    @ObservedObject var model: LeetCodeModel
    /// The persisted preferences, for the language picker: bound straight to
    /// `leetCodeLanguage`, so choosing one *is* persisting it and the next open
    /// starts on the last choice with no separate "remember" step — the macOS
    /// sheet's rule, so the two platforms cannot disagree about which language is
    /// current.
    @ObservedObject var settings: SettingsStore

    /// Run the open. Answers `nil` when the problem opened — in which case the
    /// presenter has already taken this screen down — and the sentence to show
    /// under the field when it did not.
    ///
    /// A returned sentence rather than an alert, for the macOS sheet's reason:
    /// while this screen is up it *is* what the user is looking at, and an alert
    /// stacked on it to say "no problem with that number" would make a typo look
    /// like a failure.
    var onOpen: (LeetCodeProblemInput, LeetCodeLanguage) async -> String?

    /// Take the screen down. Owned by the presenter, which also owns the state
    /// that put it up.
    var onDone: () -> Void

    /// What the user typed. Parsed on every keystroke — pure string work over a
    /// short string — so the Open button's enablement and the hint line always
    /// describe the current text.
    @State private var text = ""

    /// The outcome of the last attempt, or `nil` before the first one. Cleared on
    /// every edit, so a stale sentence never sits under a fresh input.
    @State private var message: String?

    /// Whether the login web view is up over this screen.
    @State private var isSigningIn = false

    /// The open in flight, held so that leaving this screen can cancel it — the
    /// macOS sheet's `openTask`, for the same two consequences: an unheld `Task`
    /// outlives the screen that started it, so Done and a swipe-down left
    /// `isOpening` up (the next open screen came up with everything disabled) and
    /// then pushed a tab for a file the user had already walked away from.
    @State private var openTask: Task<Void, Never>?

    private var parsed: LeetCodeProblemInput? { LeetCodeProblemInput.parse(text) }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                problemSection
                browseSection
            }
            .navigationTitle("LeetCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            // Full screen rather than a sheet-over-sheet: a login page —
            // especially an SSO provider's, mid-redirect — is a full web page
            // with its own scrolling and keyboard. See `LeetCodeLoginView_iOS`.
            .fullScreenCover(isPresented: $isSigningIn) {
                LeetCodeLoginView_iOS(model: model, onDismiss: { isSigningIn = false })
            }
        }
        // Every closing path — Done, the swipe-down, and the presenter taking the
        // screen down after a successful open — comes through here, so this is the
        // one place the in-flight open has to be cancelled. Straight-line work
        // already past its last `await` is unaffected, which is why the successful
        // path needs no special case: `openLeetCodeProblem` has opened the tab
        // before this can run.
        .onDisappear { openTask?.cancel() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            // `.borderless` on both buttons: a `Form` row whose buttons take the
            // default style is one tap target and a tap anywhere in it fires all
            // of them, so without this tapping the "Signed in as …" label signs
            // the user out. The same rule the git-credentials rows in
            // `SettingsView_iOS` already follow.
            HStack {
                Text(accountDescription)
                    .foregroundStyle(model.isSignedIn ? .primary : .secondary)
                Spacer()
                if model.isSignedIn {
                    // Never `model.signOut()` on its own: that clears the Keychain
                    // and leaves the web view's cookies, which signs the user
                    // straight back in the next time this login cover opens.
                    Button("Sign Out") {
                        Task { await LeetCodeWebSession.signOut(model: model) }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Sign In…") { isSigningIn = true }
                        .buttonStyle(.borderless)
                }
            }

            // Sign-in is confirmed *behind* the dismissed login cover, so a
            // session LeetCode rejects would otherwise just flip this row back to
            // "Sign In…" and say nothing — and this screen, not Settings, is
            // where an iOS user signs in. The same reader `SettingsView_iOS`
            // carries, for the same reason.
            if let error = model.lastError {
                Text(error.errorDescription ?? "LeetCode reported a failure.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var problemSection: some View {
        Section {
            TextField("1, two-sum, or a problem URL", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { open() }
                .onChange(of: text) { _, _ in message = nil }
                .disabled(model.isOpening)

            Picker("Language", selection: $settings.leetCodeLanguage) {
                ForEach(LeetCodeSolutionFile.offerableLanguages, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .disabled(model.isOpening)

            HStack {
                Button("Open Problem") { open() }
                    .disabled(parsed == nil || model.isOpening)
                Spacer()
                if model.isOpening {
                    ProgressView()
                }
            }
        } header: {
            Text("Open Problem")
        } footer: {
            status
        }
    }

    /// The way to the problem browser — the one new entry point on this platform,
    /// and the peer of the macOS `LeetCode ▸ Browse Problems…` menu item.
    ///
    /// A `NavigationLink` in a section of its own rather than a second sheet:
    /// this screen already hosts the `NavigationStack`, so the browser pushes onto
    /// it and the back button returns here — and a sheet over a sheet would have to
    /// re-present the sign-in cover from a third level.
    ///
    /// `onOpen` is forwarded unchanged, so a row tapped over there runs exactly the
    /// open a slug typed over here does — `onDone` deliberately is *not*: that
    /// handler already takes this sheet down on a successful open, and the browser
    /// cannot tell that outcome from a withdrawn one (both answer `nil`), so
    /// forwarding it would let a cancelled open dismiss the whole screen.
    /// `model.browser` is the companion model the owner already holds; reaching it
    /// does not observe it.
    @ViewBuilder
    private var browseSection: some View {
        Section {
            NavigationLink("Browse Problems") {
                LeetCodeBrowserView_iOS(
                    browser: model.browser,
                    settings: settings,
                    model: model,
                    onOpen: onOpen
                )
            }
        } footer: {
            Text("Search the problem list by number, title or slug.")
        }
    }

    /// The one line under the controls: the last attempt's sentence when there is
    /// one, the parse hint while typing otherwise.
    @ViewBuilder
    private var status: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
        } else if !isBlank, parsed == nil {
            Text("Not a problem number, slug or LeetCode URL.")
        } else {
            Text("A problem number, its slug, or a leetcode.com problem URL.")
        }
    }

    /// "Signed in as …" once LeetCode has named the account, "Signed in" while the
    /// launch-time confirmation is still out (the model is optimistic about a
    /// stored session on purpose), and "Not signed in" otherwise.
    private var accountDescription: String {
        guard model.isSignedIn else { return "Not signed in" }
        guard let username = model.signedInUsername else { return "Signed in" }
        return "Signed in as \(username)"
    }

    /// Hand the parsed input to the presenter and show whatever it answers.
    ///
    /// Guarded on `isOpening` as well as on the parse, because the keyboard's Go
    /// key reaches this even while the button is disabled: two overlapping opens
    /// are safe by construction (the model's generation token discards the older
    /// one), but the second would be a second round trip for a question already
    /// in flight. `isOpening` rather than `isBusy` — a statement refresh running
    /// for some other tab must not swallow the user's Go.
    private func open() {
        guard let input = parsed, !model.isOpening else { return }
        message = nil
        let language = settings.leetCodeLanguage
        openTask = Task { message = await onOpen(input, language) }
    }
}
#endif
