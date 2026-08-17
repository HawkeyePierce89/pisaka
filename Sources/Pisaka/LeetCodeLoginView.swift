#if os(macOS)
import PisakaCore
import SwiftUI
import WebKit

/// The macOS sign-in sheet: LeetCode's own login page in a web view, and nothing
/// else.
///
/// Deliberately not a form. There is no LeetCode API key and no OAuth flow to
/// obtain a session — it is two cookies a browser gets — and a large share of
/// accounts sign in through Google or GitHub SSO, which no scripted
/// username/password field could drive. So the user signs in exactly as they
/// would in Safari, the app never sees a password, and this file holds no
/// knowledge of LeetCode's login markup that could break when the page changes.
///
/// Every decision worth being right about lives elsewhere: what the cookies parse
/// to is `LeetCodeCredentials.from(cookies:)` in Core, whether that pair is
/// actually a session is `LeetCodeLoginGate`, when to look is
/// `LeetCodeLoginObserver`, and what a captured session *does* — save to the
/// Keychain, confirm with the user-status call, publish the name — is
/// `LeetCodeModel.signIn(with:)`. This view is the chrome around them, untested
/// like the rest of the app layer.
///
/// **Confirm, then dismiss.** The sheet comes down only once LeetCode has
/// confirmed the session the cookie store produced — the cookie pair alone is a
/// candidate, and django-allauth hands one out mid-SSO while the user is still
/// anonymous, so dismissing on it ended the round trip halfway. Everything after
/// that dismissal is unchanged and stays deliberately tolerant: `signIn` confirms
/// once more on the model, `signedInUsername` fills in when it lands and
/// `lastError` if it does not. Holding a modal web view open over a spinner would
/// make an offline moment look like a failed login, when the session in hand is
/// perfectly good and the name is the only thing missing — which is also why the
/// gate itself accepts a candidate it could not reach LeetCode to check.
struct LeetCodeLoginView: View {
    @ObservedObject var model: LeetCodeModel

    /// Take the sheet down. Owned by the presenter, because it also owns whatever
    /// state put the sheet up.
    var onDismiss: () -> Void

    /// What to say when the confirmation running behind the dismissed sheet
    /// *rejects* the session.
    ///
    /// A required parameter rather than an optional one, because the failure it
    /// carries is invisible by construction: the sheet is already gone, and
    /// `lastError` has exactly one macOS reader (the LeetCode Preferences tab).
    /// Everywhere else, discarding this leaves a login that flips the menu back to
    /// "Sign In…" and says nothing at all — so each presenter is made to name the
    /// surface it will use, including the one that answers "the pane already
    /// reads `lastError`".
    var onFailure: (LeetCodeError) -> Void

    /// Guards the presenter against a second dismissal. The observer already fires
    /// once; this is the view's own half of that, so a re-entrant `onDismiss`
    /// cannot reach a presenter that has already torn the sheet down.
    @State private var didCapture = false

    /// The interface zone's metrics, arriving from whichever surface presented
    /// this sheet — the main window, the LeetCode Preferences tab, the browser
    /// window or the Open Problem sheet — with nothing threaded through the
    /// initializer.
    ///
    /// Two of those four *inherit* it, because the injection is an ancestor of
    /// the body that attaches the presentation (the Preferences tab, scaled by
    /// `PisakaApp` at the `Settings` scene; the Open Problem sheet, itself
    /// scaled on its content). The other two inject it on this view directly,
    /// because there the presentation is attached above or after the scale —
    /// see the comments at both call sites.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LeetCodeLoginWebView(model: model, onCredentials: capture)
            Divider()
            footer
        }
        // Scaled with its own header and footer: the web view in the middle is
        // LeetCode's page at LeetCode's own size, so the sheet has to be at least
        // as tall as the chrome around it however far the interface is zoomed.
        .frame(
            minWidth: metrics.scaled(520),
            idealWidth: metrics.scaled(760),
            minHeight: metrics.scaled(520),
            idealHeight: metrics.scaled(780)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text("Sign In to LeetCode")
                .font(metrics.scaledFont(.headline, weight: .semibold))
            Text("Pisaka signs in through LeetCode's own page and keeps only the session cookie. Your password is never seen by the app.")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(metrics.scaled(12))
    }

    private var footer: some View {
        HStack {
            if let username = model.signedInUsername {
                Text("Signed in as \(username)")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .font(metrics.scaledFont(.body))
        }
        .padding(metrics.scaled(12))
    }

    private func capture(_ credentials: LeetCodeCredentials) {
        guard !didCapture else { return }
        didCapture = true
        onDismiss()
        // Not `.task`: the sheet is going away in the same turn, and a `.task` is
        // cancelled when its view disappears — which would cancel the confirmation
        // this exists to start.
        //
        // Only `notLoggedIn` is reported. The other failures are the ones this
        // file's header calls "an offline moment": the cookies came out of a
        // browser session that had just signed in, `signIn` keeps them, and the
        // name fills in on the next refresh — so an alert would be telling the
        // user a login worked failed.
        Task {
            do {
                try await model.signIn(with: credentials)
            } catch let error as LeetCodeError where error == .notLoggedIn {
                onFailure(error)
            } catch {}
        }
    }
}

/// The `WKWebView` itself. Holds nothing: the observer is the coordinator, and it
/// is the one that builds and owns the configuration.
private struct LeetCodeLoginWebView: NSViewRepresentable {
    /// Only used to vend the coordinator's gate — this view observes nothing.
    let model: LeetCodeModel

    let onCredentials: (LeetCodeCredentials) -> Void

    /// Built once per sheet, which is exactly the gate's intended scope: its
    /// one-shot latch and its rejected-value memo belong to this login attempt,
    /// so a second sheet after a failed one starts clean.
    func makeCoordinator() -> LeetCodeLoginObserver {
        LeetCodeLoginObserver(gate: model.makeLoginGate(), onCredentials: onCredentials)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    /// Re-points the callback at the current closure and **does not reload**: a
    /// body re-evaluation (the model publishing anything at all) must not restart
    /// a login the user is halfway through typing.
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCredentials = onCredentials
    }
}
#endif
