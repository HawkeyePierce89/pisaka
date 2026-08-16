#if os(iOS)
import PisakaCore
import SwiftUI
import WebKit

/// The iOS sign-in screen: LeetCode's own login page in a web view, presented as
/// a full-screen cover.
///
/// The iPhone/iPad peer of the macOS `LeetCodeLoginView`, and identical to it in
/// everything but chrome — both are a `View`Representable around
/// `LeetCodeLoginObserver`, which is where the cookie watching lives so the two
/// cannot drift apart about what a successful login is. See that file and the
/// macOS one for why this is a real web view rather than a form (no API key, no
/// OAuth, and SSO accounts a scripted login could not serve), why the cover comes
/// down only after `LeetCodeLoginGate` has confirmed the session with LeetCode,
/// and why the confirmation on the model then runs behind the dismissal anyway.
///
/// **Full screen rather than a sheet**, unlike most secondary surfaces here: a
/// login page — especially an SSO provider's, mid-redirect — is a full web page
/// with its own scrolling and keyboard, and a half-height sheet on a phone leaves
/// almost nothing of it visible once the keyboard is up. The presenter chooses the
/// presentation (Task 11); this view supplies the navigation bar and its one way
/// out.
struct LeetCodeLoginView_iOS: View {
    @ObservedObject var model: LeetCodeModel

    /// Take the cover down. Owned by the presenter, because it also owns whatever
    /// state put it up.
    var onDismiss: () -> Void

    /// The view's own half of "fires once" — the gate behind the observer has the
    /// other half.
    @State private var didCapture = false

    var body: some View {
        NavigationStack {
            LeetCodeLoginWebView_iOS(model: model, onCredentials: capture)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In to LeetCode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onDismiss() }
                    }
                }
        }
    }

    private func capture(_ credentials: LeetCodeCredentials) {
        guard !didCapture else { return }
        didCapture = true
        onDismiss()
        // Not `.task`: this view is disappearing in the same turn, and a `.task`
        // is cancelled on disappear — which would cancel the very confirmation it
        // was started for. The model owns the result either way.
        Task { try? await model.signIn(with: credentials) }
    }
}

/// The `WKWebView` itself. Holds nothing: the observer is the coordinator, and it
/// builds and owns the configuration.
private struct LeetCodeLoginWebView_iOS: UIViewRepresentable {
    /// Only used to vend the coordinator's gate — this view observes nothing.
    let model: LeetCodeModel

    let onCredentials: (LeetCodeCredentials) -> Void

    /// Built once per cover, which is exactly the gate's intended scope: its
    /// one-shot latch and its rejected-value memo belong to this login attempt,
    /// so a second attempt after a failed one starts clean.
    func makeCoordinator() -> LeetCodeLoginObserver {
        LeetCodeLoginObserver(gate: model.makeLoginGate(), onCredentials: onCredentials)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    /// Re-points the callback at the current closure and **does not reload**: a
    /// body re-evaluation (the model publishing anything at all) must not restart
    /// a login the user is halfway through typing.
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCredentials = onCredentials
    }
}
#endif
