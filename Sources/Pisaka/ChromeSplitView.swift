#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The split's drag strip, stated outside the generic view so a caller that
/// budgets a nested split's strip into a trailing minimum can name it.
enum ChromeSplitStrip {
    /// The drag strip's thickness, unscaled.
    static let thickness: Double = 5
    /// How far one assistive increment or decrement moves the divider, unscaled.
    static let adjustmentStep: Double = 10
}

/// Width a view inside a horizontal split's trailing pane needs **beyond** the
/// trailing minimum its caller stated, already interface-scaled, for a pane
/// whose width the caller cannot see: the LeetCode statement sits beside the
/// editor at a width it holds itself. Every horizontal `ChromeSplitView` it
/// sits under adds it to its trailing minimum, so the leading pane is the one
/// squeezed; the main window's root reads it too, into the window's floor, so
/// the row never runs past the window's edge — what the platform split did by
/// reading the pane's minimum off its content, which a `GeometryReader` host
/// cannot.
struct ChromeSplitTrailingDemand: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The chrome's one two-pane split: a leading (or top) pane, a divider, and a
/// trailing (or bottom) pane that takes what is left.
///
/// It replaces the platform's split views, which draw their divider in the
/// platform's separator colour — a step off the `hairline` role beside it —
/// and expose no way to change it. The divider here is the four hand-drawn
/// dividers' shape, stated once: a `hairline` line at the scaled
/// `hairlineWidth`, centred in a clear 5-pt drag strip.
///
/// **Sizing.** The caller states the leading pane's minimum, ideal and maximum
/// and the trailing pane's minimum, **already interface-scaled**; every clamp —
/// on screen and during a drag — is `SplitPaneRule`'s, so the two cannot
/// disagree. The extent lives in `@State`, starting at the ideal. A three-pane
/// layout nests a second split as the trailing pane.
///
/// **No clip.** The host applies no `.clipped()`, `.clipShape` or `.mask`: a
/// clip is what cost the platform split's panes the window's top safe-area
/// inset (`BottomDockColumn`), and each pane bounds its own content.
///
/// **The cursor.** One flag drives the resize cursor's push and pop, written
/// only by `syncDividerCursor()`, and `.onDisappear` releases it (rule
/// twenty-two): a split leaving the tree with the pointer on the strip, or
/// mid-drag, gets neither a hover exit nor a drag end.
///
/// **Accessibility.** The strip is one adjustable element — what the platform
/// split's divider was, an `AXSplitter` — so VoiceOver and switch control can
/// find it and move it without a pointer. Its value is the leading pane's
/// share of the panes' extent, and each increment or decrement moves the
/// divider one scaled `adjustmentStep` through `SplitPaneRule`, the drag's clamp.
struct ChromeSplitView<Leading: View, Trailing: View>: View {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    private let axis: Axis
    private let minimum: CGFloat
    private let ideal: CGFloat
    private let maximum: CGFloat
    private let trailingMinimum: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    /// The leading pane's proposed extent — the ideal until a drag writes it.
    /// Never re-clamped when the window shrinks, so a width the window is too
    /// narrow to grant comes back when it grows again.
    @State private var proposedExtent: CGFloat
    /// The rendered extent captured at drag start, so the cumulative
    /// translation applies to a fixed base; `nil` when no drag is in flight.
    @State private var dragBase: CGFloat?
    @State private var isHoveringDivider = false
    /// Whether *this view* holds a pushed cursor. `NSCursor`'s stack is global,
    /// so a pop with nothing of ours on it would discard somebody else's.
    @State private var cursorPushed = false
    /// What the trailing pane's content reports through
    /// `ChromeSplitTrailingDemand`; read on the horizontal axis only.
    @State private var trailingDemand: CGFloat = 0

    init(
        _ axis: Axis,
        minimum: CGFloat, ideal: CGFloat, maximum: CGFloat, trailingMinimum: CGFloat,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.axis = axis
        self.minimum = minimum
        self.ideal = ideal
        self.maximum = maximum
        self.trailingMinimum = trailingMinimum
        self.leading = leading()
        self.trailing = trailing()
        _proposedExtent = State(initialValue: ideal)
    }

    var body: some View {
        GeometryReader { geo in
            let available = paneExtent(in: geo.size)
            let extent = renderedExtent(available: available)
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                leading
                    .frame(
                        width: axis == .horizontal ? extent : nil,
                        height: axis == .vertical ? extent : nil
                    )
                    .frame(
                        maxWidth: axis == .vertical ? .infinity : nil,
                        maxHeight: axis == .horizontal ? .infinity : nil
                    )
                dragStrip(available: available)
                trailing
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onPreferenceChange(ChromeSplitTrailingDemand.self) { trailingDemand = $0 }
            }
        }
    }

    /// The sizing rule: the caller's bounds, the trailing minimum raised by
    /// whatever the trailing pane's content demands on the horizontal axis.
    private var rule: SplitPaneRule {
        let demand = axis == .horizontal ? trailingDemand : 0
        return SplitPaneRule(
            minimum: Double(minimum), ideal: Double(ideal),
            maximum: Double(maximum), trailingMinimum: Double(trailingMinimum + demand)
        )
    }

    /// What the two panes share along the axis: the whole extent less the strip.
    private func paneExtent(in size: CGSize) -> CGFloat {
        let total = axis == .horizontal ? size.width : size.height
        return max(total - metrics.scaled(ChromeSplitStrip.thickness), 0)
    }

    private func renderedExtent(available: CGFloat) -> CGFloat {
        CGFloat(rule.extent(proposed: Double(proposedExtent), available: Double(available)))
    }

    private func dragStrip(available: CGFloat) -> some View {
        let thickness = metrics.scaled(ChromeSplitStrip.thickness)
        let line = metrics.scaled(ChromeGeometry.hairlineWidth)
        return Color.clear
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(
                        width: axis == .horizontal ? line : nil,
                        height: axis == .vertical ? line : nil
                    )
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != isHoveringDivider else { return }
                isHoveringDivider = hovering
                syncDividerCursor()
            }
            .onDisappear {
                // Clear both inputs, so the sync pops what it pushed.
                isHoveringDivider = false
                dragBase = nil
                syncDividerCursor()
            }
            // The window's space, not the strip's own: the strip moves with the
            // extent it sets, so a local translation would collapse back to zero
            // each time the strip re-lays (`ContentView.panelColumnSpace`).
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let beginning = dragBase == nil
                        let base = dragBase ?? renderedExtent(available: available)
                        if beginning {
                            dragBase = base
                            syncDividerCursor()
                        }
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        // The opening frame writes nothing: a bare click must not
                        // overwrite the proposal with the clamped extent on screen.
                        guard !beginning || translation != 0 else { return }
                        proposedExtent = CGFloat(rule.extent(
                            base: Double(base),
                            dragTranslation: Double(translation),
                            available: Double(available)
                        ))
                    }
                    .onEnded { _ in
                        dragBase = nil
                        syncDividerCursor()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Vertical split divider" : "Horizontal split divider")
            .accessibilityValue(accessibilityShare(available: available))
            .accessibilityAdjustableAction { direction in
                let adjustment: SplitPaneRule.Adjustment
                switch direction {
                case .increment: adjustment = .increment
                case .decrement: adjustment = .decrement
                @unknown default: return
                }
                proposedExtent = CGFloat(rule.extent(
                    base: Double(renderedExtent(available: available)),
                    adjusting: adjustment,
                    step: Double(metrics.scaled(ChromeSplitStrip.adjustmentStep)),
                    available: Double(available)
                ))
            }
    }

    /// The leading pane's share of the panes' extent, as VoiceOver reads it.
    private func accessibilityShare(available: CGFloat) -> String {
        guard available > 0 else { return "0%" }
        let share = Double(renderedExtent(available: available) / available)
        return share.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Pushes or pops the resize cursor so that exactly one push of ours is on
    /// `NSCursor`'s stack while the strip is hovered or dragged, and none
    /// otherwise. Every write of the hover flag or the drag base calls this.
    private func syncDividerCursor() {
        let wanted = isHoveringDivider || dragBase != nil
        guard wanted != cursorPushed else { return }
        if wanted {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
        cursorPushed = wanted
    }
}
#endif
