#if os(macOS)
import Combine
import SwiftUI

#if !DEBUG
import Sparkle
#endif

/// The app's entire Sparkle surface: one updater instance and the state the
/// "Check for Updates…" menu item needs to enable itself.
///
/// **Why there is nothing in `PisakaCore` behind this.** Sparkle here is
/// configuration, not a decision. What feed to read and which key verifies it
/// are `SUFeedURL`/`SUPublicEDKey` in `Resources/Info.plist`, read by Sparkle
/// itself; when to check, what to show and how to install are Sparkle's own
/// standard behaviour, deliberately left untouched (no `SPUUpdaterDelegate`, no
/// `SPUStandardUserDriverDelegate`, no custom UI). That leaves no pure rule to
/// extract, so this file follows the app layer's convention and carries no unit
/// test. The static guarantees for the feature live where the facts do:
/// `ReleaseMetadataTests` pins the two plist keys (the feed URL's shape and that
/// the public key is well-formed base64 decoding to 32 bytes), and
/// `ReleaseWorkflowTests` pins the release workflow that produces what the feed
/// points at. **That absence is a recorded decision, not an omission** — if a
/// real decision ever appears here (a version-comparison rule, a channel policy,
/// an eligibility gate), it belongs in Core with tests, and this file goes back
/// to being glue.
///
/// **Inert in DEBUG, and this is the whole of that requirement.** Under `#if
/// DEBUG` no `SPUStandardUpdaterController` is constructed at all: the framework
/// is not even imported, `canCheckForUpdates` stays `false` (so the menu item is
/// permanently disabled) and `checkForUpdates()` returns without doing anything.
/// Nothing schedules a background check, nothing fetches the feed, and Sparkle's
/// first-launch "check automatically?" consent prompt never appears — which
/// matters because a development build would otherwise raise it against a feed
/// that may carry no releases yet, and because the *answer* is persisted per
/// bundle identifier and would then be inherited by a later release build. There
/// is no extra machinery for this — no scheme argument, no defaults key, no
/// stub updater. Not compiling the updater in is the mechanism.
///
/// Owned as a plain `let` by `PisakaApp` (the `commitDialog`/`diffWindows`
/// precedent: the `@main` App is created once, so a `let` is a stable instance).
/// The `.commands` block *does* read `canCheckForUpdates`, so the menu item
/// observes this object through its own `@ObservedObject` wrapper rather than
/// subscribing the whole scene body — the invalidation argument every other
/// non-`@StateObject` model in `PisakaApp` states.
final class SoftwareUpdater: ObservableObject {
    /// Whether "Check for Updates…" may be invoked right now.
    ///
    /// In a release build this republishes Sparkle's own KVO-compliant
    /// `SPUUpdater.canCheckForUpdates`, which is exactly what upstream documents
    /// as the property to validate that menu item against: it goes `false` while
    /// an update session is running or a background download is in flight, and
    /// back to `true` when the updater is idle. In DEBUG it is `false` forever,
    /// by the rule above.
    @Published private(set) var canCheckForUpdates = false

    #if DEBUG
    init() {}

    /// No-op in DEBUG. The menu item that calls this is disabled anyway
    /// (`canCheckForUpdates` never becomes `true`); this stays callable so the
    /// two builds share one call site rather than gating the command itself.
    func checkForUpdates() {}
    #else
    /// The standard controller: it creates the `SPUUpdater`, the standard user
    /// driver (Sparkle's own windows and alerts) and starts the updater
    /// immediately, which is what arms the scheduled check and, on first launch,
    /// Sparkle's own permission prompt. Both delegates are `nil` on purpose —
    /// every default is the requested behaviour.
    ///
    /// `startingUpdater: true` makes a misconfigured bundle a hard failure at
    /// launch (Sparkle aborts the app when it cannot start, e.g. a malformed
    /// `SUPublicEDKey`), which is deliberate: the alternative is an app that
    /// silently never updates. The plist keys are pinned by `swift test`, and
    /// the release workflow refuses to publish while the placeholder key is
    /// still in place, so the two ways to reach that failure are both closed
    /// before a build ships.
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Republish rather than expose the updater: the menu item needs one Bool
        // and nothing else in the app should reach for Sparkle's types. `assign(to:)`
        // on a `@Published` projection keeps the subscription owned by this object,
        // so there is no cancellable to store and no retain cycle to weaken.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Run a user-initiated check, showing Sparkle's standard UI — including its
    /// "you're up to date" alert, which is why this is only ever called from the
    /// menu item and never on a timer.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
    #endif
}

/// The "Check for Updates…" menu item, in its own view so it — and not
/// `PisakaApp`'s scene body — is what `canCheckForUpdates` invalidates.
///
/// A `CommandGroup`'s content is a view builder, so an `@ObservedObject` here is
/// the narrowest possible subscriber: the published `Bool` re-renders one button.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
