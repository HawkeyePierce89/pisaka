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
/// On macOS the one-button alert answers Esc as its button (`answersAsDismiss`),
/// pinned headlessly by `MessageAlertKeyTests`.
enum PlatformAlert {
    /// Present a one-button informational alert. On macOS, Esc answers it as the
    /// button and is consumed, never reaching the window beneath. On iOS, no-ops when no presenting
    /// view controller can be found (e.g. during teardown) rather than trapping.
    static func presentMessage(title: String, message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        // A one-button `NSAlert` gives Esc no answer of its own, so the key fell
        // through to whatever sat beneath — the commit dialog's sheet, which
        // closed under the notice. The monitor lives exactly as long as the modal
        // session: it stops the session with the one button's code and consumes
        // the event, so the window underneath never sees it. Return stays the
        // default button's.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.answersAsDismiss(event) else { return event }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        alert.runModal()
        #elseif os(iOS)
        guard let presenter = Self.topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
        #endif
    }

    #if os(macOS)
    /// Whether `event` dismisses a one-button message alert: a key-down that is Esc
    /// (key code 53, or the escape character) carrying none of ⌘, ⌥ or ⌃, so a
    /// chord that merely contains Esc keeps its own meaning. Factored out so the
    /// app-layer suite can pin the rule with synthesized events
    /// (`MessageAlertKeyTests`); the modal session itself needs an active app.
    static func answersAsDismiss(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags.isDisjoint(with: chordModifiers) else { return false }
        return event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"
    }
    #endif

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
