#if os(macOS)
import SwiftUI
import PisakaCore

/// The bottom dock's own tab row: one row across the top of the dock that names
/// the panel on screen and offers the other five, with a close action at the
/// trailing end.
///
/// **Drawn once, inside the dock's fixed-height slot.** `ContentView
/// .panelContent(_:)` puts it above whichever panel is showing, so every panel
/// gets it from one call site and the slot's pinned height, its top alignment,
/// its clip, the divider above it and `BottomPanelHeightRule` are all untouched:
/// the row is part of the slot's content, not a second strip competing with it.
/// It states no minimum height anywhere, for the slot's own reason
/// (`BottomPanelSourceGatingTests`).
///
/// **Its own file so it can be gated**, the breadcrumb's and the tab strip's
/// precedent; gating rule twelve pins that `ContentView.swift` is its only
/// caller and that no hosted panel names it.
///
/// Decisions recorded here because the row is where they are spent:
///
/// - **Six tabs, not seven.** The design draws a seventh naming a panel this
///   application does not have, and a tab that does nothing when clicked is a
///   defect rather than a placeholder. The six come from `BottomPanel.allCases`,
///   in the bar's own order, with their names from `BottomPanel.title` — the
///   same table the bar's toggles read, so a tab and a tooltip cannot disagree.
/// - **A tab selects and never collapses.** A click asks
///   `BottomPanel.tabActivation(_:tab:)` and hands a `.show` answer to the
///   bar's own funnel; the tab of the panel already showing does nothing.
///   Collapsing is the bar's toggle's job and the close action's.
/// - **Close alone.** Minimise and close would perform the same action on a dock
///   that has one state, so only close is drawn.
/// - **No weight change between states.** The selected tab differs in colour and
///   in its accent strip alone: a label that turned semibold when selected would
///   widen, and every tab after it would shift sideways on each click.
///
/// The row has no ground of its own — the slot already paints `bgPanel` under
/// it — and draws its own one-point `hairline` along its bottom edge rather than
/// leaving a `Divider()` to its host (part two's precedent). That rule is drawn
/// **behind** the tabs, never over them: each tab's accent strip sits on the
/// row's very bottom edge, so a rule overlaid there would paint over the lower
/// point of the selected tab's two-point indicator. Behind, the indicator
/// interrupts the rule for its own width, which is the look the design asks for
/// (gating rule sixteen; the tab strip above the editor draws its rule the same
/// way for the same reason).
struct DockTabRow: View {
    /// The panel on screen.
    let selection: BottomPanel
    /// A tab was clicked.
    let onSelect: (BottomPanel) -> Void
    /// The close action was clicked.
    let onClose: () -> Void

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: metrics.scaled(DockTabRowLayout.tabGap)) {
                ForEach(BottomPanel.allCases, id: \.self) { panel in
                    tabButton(panel)
                }
            }
            Spacer(minLength: metrics.scaled(DockTabRowLayout.closeGap))
            closeButton
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.dockTabRowPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.dockTabRowHeight))
        .background(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    /// One tab: its title above an accent strip as wide as the tab.
    ///
    /// The strip is drawn in both states — `Color.clear` when not selected — so
    /// a tab's height and its title's position never change with selection. It
    /// is hidden from accessibility because it *is* the selection, which the
    /// tab speaks as its value instead (gating rule thirteen).
    private func tabButton(_ panel: BottomPanel) -> some View {
        let isSelected = panel == selection
        return Button {
            onSelect(panel)
        } label: {
            VStack(spacing: 0) {
                Text(panel.title)
                    .font(metrics.scaledFont(.callout))
                    .lineLimit(1)
                    .foregroundStyle(theme.color(isSelected ? .textPrimary : .textSecondary))
                    .padding(.horizontal, metrics.scaled(ChromeGeometry.dockTabLabelPaddingX))
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(isSelected ? theme.color(.accent) : Color.clear)
                    .frame(height: metrics.scaled(ChromeGeometry.accentIndicator))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(panel.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    /// The row's close action: collapses the dock through the bar's funnel. The
    /// glyph does not name it — a `Button` would fold the symbol's own name into
    /// the announcement — so the label and the tooltip are spelled out.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(theme.color(.textSecondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close panel")
        .accessibilityLabel("Close panel")
    }
}

/// The row's own gaps, bare numbers scaled once at the use site. They belong
/// to this row alone, so deriving them from a `ChromeGeometry` token would couple
/// them to a measurement that means something else (gating rule seven).
private enum DockTabRowLayout {
    /// Between two tabs: the tabs sit nearly shoulder to shoulder, each
    /// already carrying its own label box.
    static let tabGap: Double = 2
    /// The least room kept between the last tab and the close action.
    static let closeGap: Double = 10
}
#endif
