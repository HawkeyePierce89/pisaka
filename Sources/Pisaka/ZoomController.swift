#if os(macOS)
import AppKit
import PisakaCore

/// The one place a zoom gesture arrives, whatever produced it.
///
/// It owns three things and nothing else: one accumulator per zone (so a
/// half-finished step in the editor never spends itself in the terminal), one
/// local `NSEvent` monitor, and the answer to "which zone is the pointer over".
/// Every number it applies comes from `SettingsStore.stepZoom/resetZoom`, and
/// every rule it follows is Core's — this file decides only *what an `NSEvent`
/// is*.
///
/// **Why a monitor rather than per-view `scrollWheel` overrides.** The overrides
/// this replaced (`CodeFontScroll.swift`) could only ever reach the views that
/// carried them, which is exactly the two zones that already had a font of their
/// own — and neither of the two zones this feature adds. SwiftTerm's terminal
/// view consumes scrolls to move its scrollback and a SwiftUI `List` consumes
/// them to scroll, so a Control-scroll over the terminal or the project tree
/// would never have surfaced at all. A local monitor sees the event before any
/// view does, which is what makes all three zones reachable by the same gesture.
@MainActor
final class ZoomController {
    private let settings: SettingsStore

    /// One accumulator per zone, created on first use. Per zone rather than per
    /// gesture because the pointer can cross zones mid-gesture, and the zone it
    /// leaves must keep nothing (see `activeZone`).
    private var accumulators: [ZoomZone: ZoomGestureAccumulator] = [:]

    /// The zone the in-flight gesture is currently over, or `nil` between
    /// gestures. Crossing into another zone resets the one being left, so its
    /// remainder cannot make a later, unrelated flick step immediately.
    private var activeZone: ZoomZone?

    /// Whether the momentum that follows the scroll now in progress belongs to a
    /// zoom, and must therefore be swallowed whatever the modifiers say by then.
    ///
    /// Stated by the *content* events, which are the only ones that carry the
    /// user's intent: a scroll held under ⌘/⌃ claims its momentum, an unmodified
    /// one disclaims it. See `handle(_:)` for why the modifier flags on the
    /// momentum events themselves cannot be trusted to say this.
    private var momentumIsOurs = false

    /// The installed monitor's opaque token, or `nil` while none is installed.
    private var monitor: Any?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    /// Start watching for zoom gestures. Idempotent: a re-fired `.onAppear`
    /// (a reopened window, a second scene) must not install a second monitor
    /// that would double every step.
    ///
    /// A *local* monitor — this app's events only. A global one would need the
    /// Accessibility permission and would zoom the app while another one is
    /// front, which is neither asked for nor wanted.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            // AppKit delivers a local monitor on the main thread — the
            // `willTerminateNotification` observer's reasoning applied to the one
            // other main-thread callback this app installs.
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    /// Stop watching, forgetting any half-finished gesture. Called from the app's
    /// termination observer beside the other teardown, so no monitor outlives the
    /// app.
    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endGesture()
    }

    // MARK: - The menu items

    /// Step the zone under the pointer by `steps` whole steps (positive =
    /// larger). The three View-menu items are this and `resetZoomUnderPointer`.
    ///
    /// The zone is resolved *at invocation time* and from the pointer, exactly as
    /// a gesture's is: a key equivalent fires wherever the pointer happens to be,
    /// so ⌘= over the terminal grows the terminal even though the editor has the
    /// focus. When the pointer is over no window of ours, Core falls back to the
    /// key window's focused surface.
    func stepZoomUnderPointer(by steps: Double) {
        let zone = zoneUnderPointer()
        // A keyboard step belongs to no gesture, and a gesture interrupted by one
        // has no claim on its remainder.
        endGesture()
        settings.stepZoom(zone, by: steps)
    }

    /// Return the zone under the pointer to its resting value. Only that zone —
    /// the other two are untouched, which is what makes ⌘0 as targeted as the
    /// gestures are.
    func resetZoomUnderPointer() {
        let zone = zoneUnderPointer()
        endGesture()
        settings.resetZoom(zone)
    }

    // MARK: - The gesture path

    /// Handle one event, answering it (swallowed) or passing it through.
    ///
    /// Everything recognized is swallowed on **every** path below, including the
    /// paths that step nothing: a Command-held scroll that leaks out as an
    /// ordinary scroll would scroll the editor while the user is zooming it,
    /// which is the bug the deleted overrides also guarded against.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // The end of *any* scroll or pinch closes an in-flight zoom gesture,
        // whether or not the modifier is still held. Releasing ⌘ before lifting
        // the fingers is ordinary, and the `.ended` event that follows carries no
        // modifier at all — so reading the phase only inside the modifier-gated
        // classification below would strand that gesture's remainder and its
        // `activeZone` indefinitely, and a much later, unrelated flick would step
        // immediately. That is exactly what `reset()` exists to prevent.
        //
        // Observed here rather than folded into `sample(for:)` because the event
        // must still be *classified* normally: an unmodified scroll's end phase is
        // not ours, and swallowing it would deny the scroll view the phase it uses
        // to finish the scroll and start momentum.
        if ZoomController.isGestureEnd(event) { endGesture() }

        // **Momentum belongs to the scroll that produced it, not to the modifiers
        // still held when it arrives.** Momentum events are synthesized after the
        // fingers have lifted and report the modifier flags of that later moment,
        // so releasing ⌘ as you lift — the ordinary way a zoom gesture ends, and
        // the very case the paragraph above handles for the *end phase* — would
        // drop the whole momentum tail out of the gated classification below and
        // scroll the editor the user had just finished zooming. The content
        // events say whose the momentum is; this is where that is honoured.
        if event.type == .scrollWheel {
            if event.momentumPhase.isEmpty {
                // End phases carry no modifiers and so claim nothing either way —
                // only a began/changed event states an intent.
                if !ZoomController.isEnd(event.phase) {
                    momentumIsOurs = ZoomController.isZoomModified(event)
                }
            } else if momentumIsOurs {
                if ZoomController.isEnd(event.momentumPhase) { momentumIsOurs = false }
                return nil
            }
        }

        guard let sample = ZoomController.sample(for: event) else { return event }

        if sample.endsGesture {
            endGesture()
            return nil
        }

        let zone = zoneUnderPointer()
        if zone != activeZone {
            if let previous = activeZone { accumulators[previous]?.reset() }
            activeZone = zone
        }

        guard let input = sample.input else { return nil }
        let steps = accumulators[zone, default: ZoomGestureAccumulator()].accumulate(input)
        if steps != 0 { settings.stepZoom(zone, by: Double(steps)) }
        return nil
    }

    /// Forget the in-flight gesture: every zone's remainder and which zone it was
    /// over. Reached from a gesture's end phase, from either menu item and from
    /// `uninstall()`.
    private func endGesture() {
        activeZone = nil
        for zone in accumulators.keys { accumulators[zone]?.reset() }
    }

    /// Whether `event` carries a modifier that makes a scroll a zoom.
    private static func isZoomModified(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) || flags.contains(.control)
    }

    private func zoneUnderPointer() -> ZoomZone {
        ZoomZone.resolve(
            pointer: ZoomHitTest.pointerLocation(),
            focusedSurface: ZoomHitTest.focusedSurfaceKind()
        )
    }

    /// What one event means to the zoom: an accumulator input, the end of a
    /// gesture, or nothing at all (`nil` — pass it through untouched).
    private struct GestureSample {
        /// The sample to fold in, or `nil` for an event that is ours to swallow
        /// but carries no zoom (a momentum tail).
        let input: ZoomGestureAccumulator.Input?
        let endsGesture: Bool
    }

    /// Classify an event. The one place `NSEvent` vocabulary is spoken.
    ///
    /// - A scroll counts only while **⌘ or ⌃** is held. ⌃-scroll is the macOS
    ///   system zoom gesture and ⌘-scroll is what this app has always used, so
    ///   both are honoured; an unmodified scroll is a scroll and passes through.
    /// - Every **pinch** counts, with no modifier: that is what a pinch means.
    /// - **Momentum is swallowed but never zoomed.** It is the trackpad coasting
    ///   after the fingers have lifted; letting it zoom would carry a flick two
    ///   or three steps past where the user stopped, and letting it through would
    ///   scroll whatever is under the pointer instead.
    private static func sample(for event: NSEvent) -> GestureSample? {
        switch event.type {
        case .scrollWheel:
            guard isZoomModified(event) else { return nil }
            if isEnd(event.phase) || isEnd(event.momentumPhase) {
                return GestureSample(input: nil, endsGesture: true)
            }
            guard event.momentumPhase.isEmpty else {
                return GestureSample(input: nil, endsGesture: false)
            }
            return GestureSample(
                input: .scroll(
                    delta: event.scrollingDeltaY,
                    precise: event.hasPreciseScrollingDeltas
                ),
                endsGesture: false
            )
        case .magnify:
            if isEnd(event.phase) { return GestureSample(input: nil, endsGesture: true) }
            return GestureSample(input: .magnification(event.magnification), endsGesture: false)
        default:
            return nil
        }
    }

    private static func isEnd(_ phase: NSEvent.Phase) -> Bool {
        phase.contains(.ended) || phase.contains(.cancelled)
    }

    /// Whether `event` is the end of a continuous gesture, read without the
    /// modifier gate. See `handle(_:)`.
    ///
    /// A legacy mouse wheel reports both phases empty on every event and so never
    /// answers `true` — it has no end to report. That costs nothing here: a wheel
    /// detent is one whole line, which is exactly one whole step, so the
    /// accumulator holds no remainder between detents to strand.
    private static func isGestureEnd(_ event: NSEvent) -> Bool {
        switch event.type {
        case .scrollWheel: return isEnd(event.phase) || isEnd(event.momentumPhase)
        case .magnify: return isEnd(event.phase)
        default: return false
        }
    }
}

#endif
