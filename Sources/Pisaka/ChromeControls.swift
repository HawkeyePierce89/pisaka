#if os(macOS)
import SwiftUI
import PisakaCore

/// The shared chrome field, button, checkbox, spinner and settings shapes.
///
/// One file for the chrome's controls: the field box — `bgEditor` ground, a
/// one-point `hairline` border and two points of `accent` on focus — the
/// primary and secondary buttons, the checkbox, the spinner, the segmented
/// control, the stepper, the switch, the settings tab bar and the menu field.
/// The Log filter
/// bar was the field lifted (and its branch menu the menu field), Local
/// Changes' revert checkbox the checkbox; every later caller uses these rather
/// than a second copy.
///
/// **The picker rule.** A choice over a fixed, small, closed set is a
/// `ChromeSegmentedControl`; a choice over a dynamic or long list is a
/// `ChromeMenuField`. A segmented control whose segment count is unknown at
/// build time is the wrong shape, because it cannot be laid out.
struct ChromeControlBox<Content: View>: View {
    let isFocused: Bool
    let horizontalPadding: Double
    @ViewBuilder let content: () -> Content

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.fieldCornerRadius))
        content()
            .padding(.horizontal, metrics.scaled(horizontalPadding))
            .background(shape.fill(theme.color(.bgEditor)))
            .overlay(
                shape.strokeBorder(
                    theme.color(isFocused ? .accent : .hairline),
                    lineWidth: isFocused
                        ? metrics.scaled(ChromeGeometry.fieldFocusedBorderWidth)
                        : metrics.scaled(ChromeGeometry.hairlineWidth)
                )
            )
    }
}

/// A themed text field built on `ChromeControlBox`.
///
/// A plain `TextField` with `textPrimary` content, an optional leading glyph
/// hidden from accessibility, and a spoken label. Focus comes in as a
/// `FocusState` binding plus the value it equals, so each caller keeps its own
/// focus enum.
///
/// The name is always spoken; whether it is also *drawn* is the initializer's
/// label, so the choice is visible at every call site. `title:` draws it as a
/// `textSecondary` placeholder while the field is empty — right for a field the
/// name describes. `spokenName:` draws nothing in an empty field — right where
/// an empty field is itself a value a grey word would misrepresent (the
/// database grid's cell editor, where grey is how the grid draws NULL).
struct ChromeThemedTextField<FocusValue: Hashable>: View {
    let title: String
    let drawsTitle: Bool
    @Binding var text: String
    var glyph: String?
    let focus: FocusState<FocusValue>.Binding
    let focusedEquals: FocusValue
    var horizontalPadding: Double
    var textStyle: InterfaceTextStyle
    var spacing: Double

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    /// A field whose name is spoken *and* drawn as its empty-state placeholder.
    init(
        title: String,
        text: Binding<String>,
        glyph: String? = nil,
        focus: FocusState<FocusValue>.Binding,
        focusedEquals: FocusValue,
        horizontalPadding: Double = ChromeGeometry.fieldPaddingX,
        textStyle: InterfaceTextStyle = .callout,
        spacing: Double = 6
    ) {
        self.init(
            name: title, drawsName: true, text: text, glyph: glyph, focus: focus,
            focusedEquals: focusedEquals, horizontalPadding: horizontalPadding,
            textStyle: textStyle, spacing: spacing
        )
    }

    /// A field whose name is spoken to assistive technology and never drawn:
    /// an empty field stays empty.
    init(
        spokenName: String,
        text: Binding<String>,
        glyph: String? = nil,
        focus: FocusState<FocusValue>.Binding,
        focusedEquals: FocusValue,
        horizontalPadding: Double = ChromeGeometry.fieldPaddingX,
        textStyle: InterfaceTextStyle = .callout,
        spacing: Double = 6
    ) {
        self.init(
            name: spokenName, drawsName: false, text: text, glyph: glyph, focus: focus,
            focusedEquals: focusedEquals, horizontalPadding: horizontalPadding,
            textStyle: textStyle, spacing: spacing
        )
    }

    private init(
        name: String,
        drawsName: Bool,
        text: Binding<String>,
        glyph: String?,
        focus: FocusState<FocusValue>.Binding,
        focusedEquals: FocusValue,
        horizontalPadding: Double,
        textStyle: InterfaceTextStyle,
        spacing: Double
    ) {
        self.title = name
        self.drawsTitle = drawsName
        self._text = text
        self.glyph = glyph
        self.focus = focus
        self.focusedEquals = focusedEquals
        self.horizontalPadding = horizontalPadding
        self.textStyle = textStyle
        self.spacing = spacing
    }

    var body: some View {
        ChromeControlBox(isFocused: focus.wrappedValue == focusedEquals, horizontalPadding: horizontalPadding) {
            HStack(spacing: metrics.scaled(spacing)) {
                if let glyph {
                    Image(systemName: glyph)
                        .foregroundStyle(theme.color(.textSecondary))
                        .accessibilityHidden(true)
                }
                ZStack(alignment: .leading) {
                    if drawsTitle, text.isEmpty {
                        Text(title)
                            .foregroundStyle(theme.color(.textSecondary))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.color(.textPrimary))
                        .focused(focus, equals: focusedEquals)
                        .accessibilityLabel(title)
                }
            }
            .font(metrics.scaledFont(textStyle))
        }
    }
}

/// The secondary button style: 28 high, a one-point `hairline` border, radius
/// `buttonCornerRadius`, padding 14 and a `callout` label in `textPrimary`.
///
/// A disabled button dims rather than vanishing: the same colours at half
/// opacity, so a *Replace All* that cannot run does not look actionable.
struct ChromeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(metrics.scaledFont(.callout))
            .foregroundStyle(theme.color(.textPrimary))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.secondaryButtonPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.secondaryButtonHeight))
            .background(
                RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.buttonCornerRadius))
                    .strokeBorder(theme.color(.hairline), lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}

extension ButtonStyle where Self == ChromeSecondaryButtonStyle {
    static var chromeSecondary: ChromeSecondaryButtonStyle { ChromeSecondaryButtonStyle() }
}

/// The primary button style: the secondary's geometry — 28 high, radius
/// `buttonCornerRadius`, padding 14 — with a `callout` semibold label in
/// `onAccent` on an `accent` ground.
///
/// It dims exactly as the secondary style does: half opacity disabled, 0.7
/// while pressed.
struct ChromePrimaryButtonStyle: ButtonStyle {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(metrics.scaledFont(.callout, weight: .semibold))
            .foregroundStyle(theme.color(.onAccent))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.secondaryButtonPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.secondaryButtonHeight))
            .background(
                RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.buttonCornerRadius))
                    .fill(theme.color(.accent))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}

extension ButtonStyle where Self == ChromePrimaryButtonStyle {
    static var chromePrimary: ChromePrimaryButtonStyle { ChromePrimaryButtonStyle() }
}

/// The one chrome checkbox, lifted from Local Changes' revert checkbox.
///
/// A `checkboxSide` square with `checkboxCornerRadius`: off is a `hairline`
/// border and no ground, on an `accent` ground with an `onAccent` check, mixed
/// the same ground with an `onAccent` dash. The box is hidden from
/// accessibility; the control speaks its label and "On", "Off" or "Mixed" as
/// its value. An optional trailing title (the Amend and Push rows, a Log date
/// bound) is part of the click target. Disabled, the whole control dims.
struct ChromeCheckbox: View {
    enum State: Equatable {
        case on, off, mixed
    }

    let state: State
    /// The spoken name, which may say more than the visible title.
    let label: String
    var title: String?
    let action: () -> Void

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.checkboxCornerRadius))
        Button(action: action) {
            HStack(spacing: metrics.scaled(ChromeCheckboxLayout.titleGap)) {
                ZStack {
                    if state == .off {
                        shape.strokeBorder(
                            theme.color(.hairline),
                            lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth)
                        )
                    } else {
                        shape.fill(theme.color(.accent))
                        Image(systemName: state == .on ? "checkmark" : "minus")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(theme.color(.onAccent))
                            .frame(width: metrics.scaled(ChromeCheckboxLayout.glyphSide))
                    }
                }
                .frame(
                    width: metrics.scaled(ChromeGeometry.checkboxSide),
                    height: metrics.scaled(ChromeGeometry.checkboxSide)
                )
                .accessibilityHidden(true)
                if let title {
                    Text(title)
                        .font(metrics.scaledFont(.callout))
                        .foregroundStyle(theme.color(.textPrimary))
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .mixed: "Mixed"
        }
    }
}

extension ChromeCheckbox.State {
    /// The commit plan's three states, read as the checkbox draws them.
    init(_ state: CheckboxState) {
        switch state {
        case .checked: self = .on
        case .unchecked: self = .off
        case .mixed: self = .mixed
        }
    }
}

/// The checkbox's own numbers: they belong to the one shape, so they are named
/// here rather than as `ChromeGeometry` tokens.
private enum ChromeCheckboxLayout {
    /// The check's (and the dash's) width inside the 14-point box. 10 is the
    /// design's check; Local Changes' former 8 was a private choice for one
    /// caller, made before the shape was shared and never checked against the
    /// drawing. One shape serving five callers takes the drawing's value, so the
    /// revert checkbox's check grew by two points.
    static let glyphSide: Double = 10
    /// Between the box and its trailing title.
    static let titleGap: Double = 6
}

/// The query-mode toggle (`Aa`, `ab`, `.*`), drawn once for the two shapes that
/// used to diverge: the find bar's and Find in Files' builders had drifted in
/// size and colour (subheadline `textPrimary` off vs. a raw 16 `textSecondary`
/// off), the latter reading an icon box as a font size.
struct ChromeQueryToggle: View {
    let label: String
    @Binding var isOn: Bool
    let help: String

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(metrics.scaledFont(.subheadline, weight: .semibold, design: .monospaced))
                .padding(.horizontal, metrics.scaled(5))
                .padding(.vertical, metrics.scaled(2))
                .background(isOn ? theme.color(.accentTint) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(4)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? theme.color(.accent) : theme.color(.textPrimary))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A choice over a fixed, small, closed set (the picker rule above).
///
/// A `segmentedControlHeight` box — `bgEditor` ground, a `hairline` border at
/// `cornerRadiusMax`, `segmentedControlInset` padding — holding one plain
/// button per option, `segmentGap` apart. The selected segment is an
/// `accentTintStrong` fill at `fieldCornerRadius` under a `textPrimary` label;
/// the others draw no ground and a `textSecondary` label. The control speaks
/// its label and the selected title; each segment speaks its selection.
struct ChromeSegmentedControl<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.cornerRadiusMax))
        HStack(spacing: metrics.scaled(ChromeGeometry.segmentGap)) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .padding(metrics.scaled(ChromeGeometry.segmentedControlInset))
        .frame(height: metrics.scaled(ChromeGeometry.segmentedControlHeight))
        .background(outer.fill(theme.color(.bgEditor)))
        .overlay(
            outer.strokeBorder(theme.color(.hairline), lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }

    private func segment(_ option: (value: Value, title: String)) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Text(option.title)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(isSelected ? .textPrimary : .textSecondary))
                .lineLimit(1)
                .padding(.horizontal, metrics.scaled(ChromeGeometry.segmentPaddingX))
                .frame(height: metrics.scaled(ChromeGeometry.segmentHeight))
                .background(
                    RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.fieldCornerRadius))
                        .fill(isSelected ? theme.color(.accentTintStrong) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

/// A numeric preference stepped along a `ZoomScaleRule`'s grid.
///
/// A `stepperHeight` box — `bgEditor` ground, a `hairline` border at
/// `fieldCornerRadius`, `stepperPaddingX` padding — holding minus, the value
/// (`callout`, `textPrimary`) and plus, `stepperPartGap` apart. Every step goes
/// through the rule's `stepped(_:by:)`, so the grid and the clamp are the
/// rule's, and a glyph button whose step would not move the value is disabled.
struct ChromeStepper: View {
    let label: String
    @Binding var value: Double
    let rule: ZoomScaleRule
    let format: (Double) -> String

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.fieldCornerRadius))
        HStack(spacing: metrics.scaled(ChromeGeometry.stepperPartGap)) {
            stepButton(glyph: "minus", spoken: "Decrease \(label)", by: -1)
            Text(format(value))
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
                .monospacedDigit()
            stepButton(glyph: "plus", spoken: "Increase \(label)", by: 1)
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.stepperPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.stepperHeight))
        .background(shape.fill(theme.color(.bgEditor)))
        .overlay(
            shape.strokeBorder(theme.color(.hairline), lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction(adjust)
    }

    /// The adjustable action goes through the same `stepped(_:by:)` the glyph
    /// buttons do.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: value = rule.stepped(value, by: 1)
        case .decrement: value = rule.stepped(value, by: -1)
        @unknown default: break
        }
    }

    private func stepButton(glyph: String, spoken: String, by steps: Double) -> some View {
        let next = rule.stepped(value, by: steps)
        return Button {
            value = next
        } label: {
            Image(systemName: glyph)
                .font(metrics.scaledFont(.subheadline))
                .foregroundStyle(theme.color(.textSecondary))
                .accessibilityHidden(true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(next == value)
        .accessibilityLabel(spoken)
    }
}

/// A standing preference that is on or off.
///
/// A `switchWidth` × `switchHeight` capsule track — `accent` on, `hairline`
/// off — with a `switchKnobSide` `onAccent` knob inset by `switchInset`,
/// leading when off and trailing when on. It dims when disabled and speaks its
/// label and "On" or "Off".
///
/// It is not the checkbox, and neither is folded into the other: a preference
/// that is on or off is a switch; one selection among many (an option of one
/// action, a row in a list) is a checkbox. Two meanings, two shapes.
struct ChromeSwitch: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(theme.color(isOn ? .accent : .hairline))
                Circle()
                    .fill(theme.color(.onAccent))
                    .frame(
                        width: metrics.scaled(ChromeGeometry.switchKnobSide),
                        height: metrics.scaled(ChromeGeometry.switchKnobSide)
                    )
                    .padding(metrics.scaled(ChromeGeometry.switchInset))
            }
            .frame(
                width: metrics.scaled(ChromeGeometry.switchWidth),
                height: metrics.scaled(ChromeGeometry.switchHeight)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The Preferences window's tab bar.
///
/// A `settingsTabBarHeight` strip on `bgPanel`, inset by
/// `settingsTabBarPaddingX`, its tabs `settingsTabGap` apart. Each tab is a
/// plain button with `settingsTabLabelPaddingX` around a `callout` semibold
/// label — `textPrimary` active, `textSecondary` otherwise — and the active
/// tab carries an `accent` indicator of `accentIndicator` thickness across its
/// full width at its bottom. The strip's `hairline` bottom rule is drawn
/// *behind* the tabs, so it never paints over the indicator.
///
/// It is not the dock's tab row: it has no close action, a different height and
/// a different inset. It shares the indicator's thickness and the
/// behind-the-tabs rule.
struct ChromeSettingsTabBar<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(ChromeGeometry.settingsTabGap)) {
            ForEach(tabs.indices, id: \.self) { index in
                tabButton(tabs[index])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.settingsTabBarPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.settingsTabBarHeight))
        // The rule goes on *before* the ground: each later `.background` is drawn
        // further back, so a rule applied after an opaque ground lands behind it
        // and is never seen (gating rule sixteen). `TabStripView` states the same
        // ordering.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        .background(theme.color(.bgPanel))
    }

    private func tabButton(_ item: (tab: Tab, title: String)) -> some View {
        let isSelected = item.tab == selection
        return Button {
            selection = item.tab
        } label: {
            Text(item.title)
                .font(metrics.scaledFont(.callout, weight: .semibold))
                .foregroundStyle(theme.color(isSelected ? .textPrimary : .textSecondary))
                .lineLimit(1)
                .padding(.horizontal, metrics.scaled(ChromeGeometry.settingsTabLabelPaddingX))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Rectangle()
                            .fill(theme.color(.accent))
                            .frame(height: metrics.scaled(ChromeGeometry.accentIndicator))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

/// A choice over a dynamic or long list (the picker rule above), lifted from
/// the Log filter bar's branch menu.
///
/// A `ChromeControlBox` holding a borderless, indicator-less menu whose label is
/// the current title (`callout`, `textPrimary`, one line) beside a
/// `textSecondary` chevron. Each option is a button; the chosen one is labelled
/// with a checkmark. The field speaks its label and the current title. The
/// caller supplies the height and the width limits.
struct ChromeMenuField<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let currentTitle: String
    var horizontalPadding: Double = ChromeGeometry.fieldPaddingX
    var spacing: Double = 6

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ChromeControlBox(isFocused: false, horizontalPadding: horizontalPadding) {
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                // The chevron is part of the label, so the arrow the field
                // draws is the control: a sibling of the `Menu` would be a
                // glyph that opens nothing when clicked.
                HStack(spacing: metrics.scaled(spacing)) {
                    Text(currentTitle)
                        .font(metrics.scaledFont(.callout))
                        .foregroundStyle(theme.color(.textPrimary))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(metrics.scaledFont(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.color(.textSecondary))
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(currentTitle)
    }
}

/// The chrome's activity indicator, drawn rather than the platform's.
///
/// An open arc stroked in `textSecondary` — a spinner reports activity, not
/// selection, so it is not `accent` — `spinnerSide` square at a
/// `spinnerLineWidth` stroke, both scaled through the metrics. The turn is a
/// function of the clock read through a `TimelineView` whose schedule pauses on
/// Reduce Motion, so it follows the setting as it is *now*, in both directions:
/// switched on under a turning spinner, the schedule pauses and the arc draws
/// still at its resting angle; switched off under a still one, the schedule
/// resumes and it turns — no flag latched at appearance stands between the
/// setting and the drawing.
///
/// **The call site decides what it speaks, and says so exactly once.** Every
/// construction carries one of two markers in its own modifier chain:
///
/// - `.accessibilityHidden(true)` when a neighbour already names the activity
///   (a "Reading checks…" beside it), so the sentence is read once rather than
///   followed by a second, vaguer one;
/// - `.accessibilityLabel(…)` naming what is happening when it stands alone.
///
/// There is no label parameter and no default label: a default would be exactly
/// the duplicate the first marker avoids, and a missing marker would be an
/// unnamed element. The body carries `.updatesFrequently`, inert when hidden.
struct ChromeSpinner: View {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = metrics.scaled(ChromeGeometry.spinnerSide)
        let lineWidth = metrics.scaled(ChromeGeometry.spinnerLineWidth)
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            // Inset by half the stroke so the arc's outer edge meets the frame
            // rather than overhanging it.
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: ChromeSpinnerLayout.arcFraction)
                .stroke(theme.color(.textSecondary), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(reduceMotion ? .zero : ChromeSpinnerLayout.angle(at: context.date))
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The spinner's own numbers, belonging to the one shape.
private enum ChromeSpinnerLayout {
    /// How much of the circle the arc covers; the gap is what reads as motion.
    static let arcFraction: Double = 0.75
    /// Seconds per full turn.
    static let turnDuration: Double = 1

    /// Where the arc stands at `date`: the fraction of the current turn,
    /// as an angle.
    static func angle(at date: Date) -> Angle {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turnDuration)
        return .degrees(phase / turnDuration * 360)
    }
}

#endif
