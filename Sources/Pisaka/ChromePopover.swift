#if os(macOS)
import SwiftUI
import PisakaCore

/// The bottom bar's one popover component: a container with three slots and the
/// pieces both bar popovers are built from.
///
/// The project switcher and the branch switcher are one design component, so
/// they are one view here: a **Head** (fixed, ruled along its bottom), a **List**
/// (the only part that scrolls) and a **Foot** (fixed, ruled along its top, drawn
/// only when the caller passes one). The Head is optional the same way, because
/// the remote row's submenu has none.
///
/// The container hugs its content and caps itself at the `maxHeight` it is
/// handed — the placement's available height, already capped at
/// `popoverMaxHeight` — and the List alone gives up height when the cap bites.
/// It draws no arrow and no material: a flat `bgPopover` fill at
/// `cornerRadiusMax`, a `hairline` stroke and a `bgCanvas` shadow. Every
/// measurement is a `ChromeGeometry` token scaled here, at the use site.
struct ChromePopover<Head: View, List: View, Foot: View>: View {
    /// The height the container may take, unscaled-out: a point value the
    /// placement already computed at the current interface scale.
    let maxHeight: CGFloat
    private let head: Head?
    private let list: List
    private let foot: Foot?

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    init(
        maxHeight: CGFloat,
        @ViewBuilder head: () -> Head,
        @ViewBuilder list: () -> List,
        @ViewBuilder foot: () -> Foot
    ) {
        self.maxHeight = maxHeight
        self.head = head()
        self.list = list()
        self.foot = foot()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.cornerRadiusMax))
        ChromePopoverStack(maxHeight: maxHeight) {
            if let head {
                head
                    .padding(.bottom, metrics.scaled(ChromeGeometry.popoverHeadPaddingBottom))
                    .overlay(alignment: .bottom) { rule }
            }
            ViewThatFits(in: .vertical) {
                listContent
                ScrollView(.vertical) { listContent }
            }
            .clipped()
            .layoutValue(key: ChromePopoverListSlot.self, value: true)
            if let foot {
                foot
                    .overlay(alignment: .top) { rule }
            }
        }
        .frame(width: metrics.scaled(ChromeGeometry.popoverWidth))
        .background(theme.color(.bgPopover), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                theme.color(.hairline),
                lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth)
            )
        }
        .shadow(
            color: theme.color(.bgCanvas),
            radius: Self.shadowRadius(forBlur: metrics.scaled(ChromeGeometry.popoverShadowBlur)),
            x: 0,
            y: metrics.scaled(ChromeGeometry.popoverShadowOffsetY)
        )
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) { list }
            .padding(.bottom, metrics.scaled(ChromeGeometry.popoverListPaddingBottom))
    }

    /// A `hairline` rule one `hairlineWidth` thick, the slots' separator.
    private var rule: some View {
        Rectangle()
            .fill(theme.color(.hairline))
            .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
    }

    /// The design states a shadow's *blur*; SwiftUI's `shadow(radius:)` is a
    /// Gaussian radius, and a blur of `b` points is drawn by a radius of `b / 2`.
    /// The conversion is a unit change, not a second design value, and it is
    /// spelled once, here.
    static func shadowRadius(forBlur blur: CGFloat) -> CGFloat {
        blur / 2
    }
}

extension ChromePopover where Head == EmptyView {
    /// A popover with no Head — the remote row's submenu.
    init(
        maxHeight: CGFloat,
        @ViewBuilder list: () -> List,
        @ViewBuilder foot: () -> Foot
    ) {
        self.maxHeight = maxHeight
        self.head = nil
        self.list = list()
        self.foot = foot()
    }
}

extension ChromePopover where Foot == EmptyView {
    /// A popover with no Foot: no rule is drawn above a Foot that is absent.
    init(
        maxHeight: CGFloat,
        @ViewBuilder head: () -> Head,
        @ViewBuilder list: () -> List
    ) {
        self.maxHeight = maxHeight
        self.head = head()
        self.list = list()
        self.foot = nil
    }
}

extension ChromePopover where Head == EmptyView, Foot == EmptyView {
    /// A popover with a List alone.
    init(maxHeight: CGFloat, @ViewBuilder list: () -> List) {
        self.maxHeight = maxHeight
        self.head = nil
        self.list = list()
        self.foot = nil
    }
}

/// Marks the one subview of `ChromePopoverStack` that gives up height.
private struct ChromePopoverListSlot: LayoutValueKey {
    static let defaultValue = false
}

/// The container's vertical stack: the Head and Foot at their own heights, the
/// List at its own height up to whatever the cap leaves it.
///
/// A plain `VStack` under a `frame(maxHeight:)` cannot hug: the frame takes the
/// whole proposal and the List's `ScrollView` is greedy. This layout ignores the
/// proposed height and reports the hugging one instead, so the popover is only
/// as tall as its rows until the cap bites. The List is a `ViewThatFits` over its
/// plain rows and the same rows in a `ScrollView`: asked for its ideal height it
/// answers the plain rows', and placed at less it falls through to the scroller.
private struct ChromePopoverStack: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height
        }
    }

    /// Each subview's height: fixed slots at their ideal, the List at its ideal
    /// capped by what the fixed slots leave under `maxHeight`, never negative.
    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let fixed = zip(subviews, ideal)
            .filter { !$0.0[ChromePopoverListSlot.self] }
            .map(\.1)
            .reduce(0, +)
        let room = max(0, maxHeight - fixed)
        return zip(subviews, ideal).map { subview, height in
            subview[ChromePopoverListSlot.self] ? min(height, room) : height
        }
    }
}

/// The ground every popover row takes: `accentTintStrong` when selected,
/// otherwise `hoverTint` under the pointer, otherwise clear — selection wins.
private func popoverRowGround(isSelected: Bool, isHovered: Bool) -> ChromeColorRole? {
    if isSelected { return .accentTintStrong }
    if isHovered { return .hoverTint }
    return nil
}

/// One popover row: a glyph slot, a one-line title and an optional trailing
/// chevron, `popoverRowHeight` high.
///
/// The slot holds an optional design glyph at 14, or nothing; a current row
/// draws `.check` there and its title in `accent`. The trailing chevron marks a
/// row that opens a submenu, in `textSecondary` at rest and `textPrimary` while
/// the row is hovered or selected. The whole row is one accessibility element
/// named by its title, with an optional value (a current row's state) and an
/// optional hint (the submenu it opens).
struct ChromePopoverRow: View {
    let title: String
    var glyph: DesignGlyph?
    var isCurrent = false
    var isSelected = false
    var hasChevron = false
    var accessibilityValue: String?
    var accessibilityHint: String?
    let action: () -> Void

    @State private var isHovered = false

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.scaled(ChromeGeometry.popoverRowGap)) {
                ChromePopoverGlyphSlot(glyph: isCurrent ? .check : glyph, isCurrent: isCurrent)
                Text(title)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(isCurrent ? .accent : .textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasChevron {
                    DesignGlyphImage(
                        .chevronRight, size: 12, slot: 12,
                        role: isHovered || isSelected ? .textPrimary : .textSecondary
                    )
                }
            }
            .padding(.horizontal, metrics.scaled(ChromeGeometry.popoverRowPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.popoverRowHeight))
            .background(popoverRowGround(isSelected: isSelected, isHovered: isHovered).map(theme.color) ?? .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// One project row: a glyph slot beside a name line over a path line,
/// `popoverProjectRowHeight` high, with the same slot, padding and ground rules
/// as `ChromePopoverRow`.
struct ChromePopoverProjectRow: View {
    let name: String
    let path: String
    var glyph: DesignGlyph?
    var isCurrent = false
    var isSelected = false
    var accessibilityValue: String?
    let action: () -> Void

    @State private var isHovered = false

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.scaled(ChromeGeometry.popoverRowGap)) {
                ChromePopoverGlyphSlot(glyph: isCurrent ? .check : glyph, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: metrics.scaled(ChromeGeometry.popoverProjectRowLineGap)) {
                    Text(name)
                        .font(metrics.scaledFont(.body))
                        .foregroundStyle(theme.color(isCurrent ? .accent : .textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(path)
                        .font(metrics.scaledFont(.subheadline))
                        .foregroundStyle(theme.color(.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, metrics.scaled(ChromeGeometry.popoverRowPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.popoverProjectRowHeight))
            .background(popoverRowGround(isSelected: isSelected, isHovered: isHovered).map(theme.color) ?? .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// A row's leading slot, `popoverRowGlyphSlot` wide: a design glyph at 14 —
/// `accent` on a current row, `textSecondary` otherwise — or an empty slot that
/// keeps the titles aligned.
private struct ChromePopoverGlyphSlot: View {
    let glyph: DesignGlyph?
    let isCurrent: Bool

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        if let glyph {
            DesignGlyphImage(
                glyph, size: 14, slot: ChromeGeometry.popoverRowGlyphSlot,
                role: isCurrent ? .accent : .textSecondary
            )
        } else {
            Color.clear
                .frame(width: metrics.scaled(ChromeGeometry.popoverRowGlyphSlot), height: 0)
        }
    }
}

/// A List section's header: `subheadline` semibold in `textSecondary`, padded
/// by the three header tokens.
struct ChromePopoverSectionHeader: View {
    let title: String

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Text(title)
            .font(metrics.scaledFont(.subheadline, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .lineLimit(1)
            .padding(.top, metrics.scaled(ChromeGeometry.popoverSectionHeaderPaddingTop))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.popoverSectionHeaderPaddingX))
            .padding(.bottom, metrics.scaled(ChromeGeometry.popoverSectionHeaderPaddingBottom))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A message line — an empty state in `textSecondary`, an error in
/// `statusRed` — in `subheadline`, wrapping rather than truncating.
struct ChromePopoverMessage: View {
    let text: String
    let role: ChromeColorRole

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Text(text)
            .font(metrics.scaledFont(.subheadline))
            .foregroundStyle(theme.color(role))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, metrics.scaled(ChromeGeometry.popoverMessagePaddingY))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.popoverMessagePaddingX))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Any field, stretched to the popover's inner width with
/// `popoverFieldBlockPadding` on every side.
struct ChromePopoverFieldBlock<Field: View>: View {
    @ViewBuilder let field: () -> Field

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        field()
            .frame(maxWidth: .infinity)
            .padding(metrics.scaled(ChromeGeometry.popoverFieldBlockPadding))
    }
}
#endif
