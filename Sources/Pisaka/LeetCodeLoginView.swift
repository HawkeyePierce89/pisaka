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
/// Every decision worth being right about lives elsewhere: what counts as a
/// session is `LeetCodeCredentials.from(cookies:)` in Core, when to look is
/// `LeetCodeLoginObserver`, and what a captured session *does* — save to the
/// Keychain, confirm with the user-status call, publish the name — is
/// `LeetCodeModel.signIn(with:)`. This view is the chrome around them, untested
/// like the rest of the app layer.
///
/// **Dismiss first, confirm behind it.** The moment the cookies appear the sheet
/// goes away and the confirmation round trip runs on the model, which is where
/// the result belongs anyway: `signedInUsername` fills in when it lands and
/// `lastError` if it does not. Holding a modal web view open over a spinner would
/// make an offline moment look like a failed login, when the session in hand is
/// perfectly good and the name is the only thing missing.
struct LeetCodeLoginView: View {
    @ObservedObject var model: LeetCodeModel

    /// Take the sheet down. Owned by the presenter, because it also owns whatever
    /// state put the sheet up.
    var onDismiss: () -> Void

    /// Guards the presenter against a second dismissal. The observer already fires
    /// once; this is the view's own half of that, so a re-entrant `onDismiss`
    /// cannot reach a presenter that has already torn the sheet down.
    @State private var didCapture = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LeetCodeLoginWebView(onCredentials: capture)
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 760, minHeight: 520, idealHeight: 780)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sign In to LeetCode")
                .font(.headline)
            Text("Pisaka signs in through LeetCode's own page and keeps only the session cookie. Your password is never seen by the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let username = model.signedInUsername {
                Text("Signed in as \(username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func capture(_ credentials: LeetCodeCredentials) {
        guard !didCapture else { return }
        didCapture = true
        onDismiss()
        // Not `.task`: the sheet is going away in the same turn, and a `.task` is
        // cancelled when its view disappears — which would cancel the confirmation
        // this exists to start.
        Task { try? await model.signIn(with: credentials) }
    }
}

/// The `WKWebView` itself. Holds nothing: the observer is the coordinator, and it
/// is the one that builds and owns the configuration.
private struct LeetCodeLoginWebView: NSViewRepresentable {
    let onCredentials: (LeetCodeCredentials) -> Void

    func makeCoordinator() -> LeetCodeLoginObserver {
        LeetCodeLoginObserver(onCredentials: onCredentials)
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
