#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A platform-neutral "rejected/failed action" cue — the cross-platform
/// replacement for the scattered `NSSound.beep()` calls. macOS plays the system
/// beep; iOS fires an error notification haptic (the closest mobile analogue for
/// "this action was refused"). View-layer only — no pure logic to test.
enum PlatformFeedback {
    /// Signal that an action was rejected or failed (invalid name, blocked file
    /// operation, autosave write failure, …). Call on the main thread.
    static func warning() {
        #if os(macOS)
        NSSound.beep()
        #elseif os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// Signal that an action ran but found nothing to do — a Go to Definition on a
    /// name the index does not know, and nothing more consequential than that.
    ///
    /// Deliberately gentler than `warning()`: nothing failed and nothing was
    /// refused, so an error notification haptic (three sharp taps) would read as a
    /// problem the user has to act on. macOS has no such gradation in its stock
    /// cues and keeps the system beep.
    static func light() {
        #if os(macOS)
        NSSound.beep()
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
