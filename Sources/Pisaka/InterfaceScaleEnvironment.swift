#if os(macOS)
import SwiftUI
import PisakaCore

/// How the **interface** zoom zone reaches the views: one environment value
/// carrying `PisakaCore.InterfaceMetrics`, injected at every SwiftUI root this
/// app owns.
///
/// The environment is the right vehicle for exactly the reason the sweep is
/// wide: the scale has to reach a `RefBadge` nested five containers deep inside a
/// lazily-built commit row, and threading a parameter through every intermediate
/// view would be a per-view API change that the next new view would silently
/// forget. An environment value is inherited by construction — including by
/// sheets and popovers presented from a scaled root — so the only thing a view
/// has to do is declare it.
///
/// Three rules the whole sweep obeys, stated once here:
///
/// - **Nothing computes the scale itself.** A view asks for
///   `metrics.scaledFont(.caption)` or `metrics.scaled(8)`; the arithmetic and its
///   rounding live in Core, where they are unit-tested (`InterfaceMetricsTests`).
///   The two helpers below exist only to hand SwiftUI its own types — a `Font`
///   and a `CGFloat` — over Core's platform-neutral `Double`s.
/// - **The default is the resting one.** A view that has not been reached by the
///   sweep, or one rendered by a preview with no root modifier, reads
///   `InterfaceMetrics.unscaled` and draws exactly what it drew before this
///   existed.
/// - **Code-font sites never come through here.** Anything drawn at
///   `settings.fontSize` (the Find in Files result rows, the commit dialog's
///   unified diff, every editor pane) belongs to the *code* zone; multiplying it
///   by the interface scale would make two independent zones interact, which is
///   the one thing the three-zone split exists to prevent.
private struct InterfaceMetricsKey: EnvironmentKey {
    static let defaultValue = InterfaceMetrics.unscaled
}

extension EnvironmentValues {
    /// The interface zone's metrics for this view tree. `.unscaled` until a root
    /// applies `.interfaceScaled(_:)`.
    var interfaceMetrics: InterfaceMetrics {
        get { self[InterfaceMetricsKey.self] }
        set { self[InterfaceMetricsKey.self] = newValue }
    }
}

extension InterfaceMetrics {
    /// The SwiftUI font for a semantic style at this scale.
    ///
    /// Deliberately a *different name* from Core's `font(_:)` rather than an
    /// overload of it: two functions differing only in return type resolve by
    /// context, and a sweep this wide will eventually put one of them somewhere
    /// the context is ambiguous. The size still comes from Core — this only wraps
    /// it — so the "nothing changes at 100%" guarantee that `InterfaceMetricsTests`
    /// pins covers every call site here too.
    ///
    /// `weight`/`design` carry what the unscaled call sites expressed as
    /// `.caption.weight(.semibold)` or `.caption.monospaced()`; both default to
    /// what `Font.system(size:)` would give.
    func scaledFont(
        _ style: InterfaceTextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: CGFloat(font(style)), weight: weight, design: design)
    }

    /// A layout metric — padding, fixed frame, icon size, row height, minimum
    /// window width — scaled, as the `CGFloat` SwiftUI's layout modifiers take.
    func scaled(_ value: Double) -> CGFloat {
        CGFloat(pt(value))
    }
}

extension SettingsStore {
    /// The interface zone's metrics for the currently stored scale.
    ///
    /// For the *roots*: a view that applies `.interfaceScaled(self)` cannot read
    /// the value it just injected — an environment write reaches descendants, not
    /// the view that made it — so a root computes its own metrics from the same
    /// store the modifier reads. Every non-root view reads
    /// `@Environment(\.interfaceMetrics)` instead.
    var interfaceMetrics: InterfaceMetrics {
        InterfaceMetrics(scale: interfaceScale)
    }
}

/// Injects the interface zone's current scale into a view tree.
///
/// Takes the `SettingsStore` rather than a bare `Double` and observes it, which
/// is what makes a zoom gesture or a Preferences edit re-lay-out the window
/// live: `interfaceScale` is `@Published`, so the root re-evaluates and the new
/// metrics flow down. Every root that applies this already holds the one shared
/// store `PisakaApp` created, so nothing new is threaded anywhere.
private struct InterfaceScaled: ViewModifier {
    @ObservedObject var settings: SettingsStore

    func body(content: Content) -> some View {
        content.environment(\.interfaceMetrics, InterfaceMetrics(scale: settings.interfaceScale))
    }
}

extension View {
    /// Apply the interface zone's scale to this view tree. Applied at each
    /// SwiftUI root: the main window's `ContentView`, the `Settings` scene, and
    /// every `NSHostingController` root (diff windows, the source viewer, Find in
    /// Files, the merge windows, the LeetCode browser) — the sheets inherit it
    /// from the root that presents them.
    func interfaceScaled(_ settings: SettingsStore) -> some View {
        modifier(InterfaceScaled(settings: settings))
    }
}

#endif
