#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A platform-neutral way to present a simple informational/error alert with a
/// single dismiss button, sharing one signature across platforms. macOS runs a
/// modal `NSAlert`; iOS presents a `UIAlertController` on the frontmost view
/// controller.
///
/// This is deliberately the *informational* surface only. The macOS app's
/// confirmation alerts that return a `Bool` synchronously (`FilePanels.confirmClose`
/// / `confirmRevert` / `confirmDelete`) stay where they are — a synchronous modal
/// has no faithful iOS counterpart (iOS alerts are async), so those keep their
/// macOS-specific shape and the iOS views will present their own async confirms.
/// View-layer only — no pure logic to test.
enum PlatformAlert {
    /// Present a one-button informational alert. On iOS, no-ops when no presenting
    /// view controller can be found (e.g. during teardown) rather than trapping.
    static func presentMessage(title: String, message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #elseif os(iOS)
        guard let presenter = Self.topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
        #endif
    }

    #if os(iOS)
    /// The frontmost presented view controller of the active foreground scene's key
    /// window, walking the `presentedViewController` chain so an alert stacks atop
    /// whatever is already showing.
    private static func topViewController() -> UIViewController? {
        let windowScene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
            ?? windowScene?.windows.first
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
    #endif
}
