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
}
