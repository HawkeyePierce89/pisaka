#if os(macOS)
import SwiftUI
import PisakaCore

/// The shared chrome field, button and checkbox shapes.
///
/// One file for the chrome's controls: the field box — `bgEditor` ground, a
/// one-point `hairline` border and two points of `accent` on focus — the
/// primary and secondary buttons, and the checkbox. The Log filter bar was the
/// field lifted, Local Changes' revert checkbox the checkbox; every later
/// caller uses these rather than a second copy.
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
/// A plain `TextField` with `textPrimary` content, a `textSecondary`
/// placeholder, an optional leading glyph hidden from accessibility, and a
/// spoken label. Focus comes in as a `FocusState` binding plus the value it
/// equals, so each caller keeps its own focus enum.
struct ChromeThemedTextField<FocusValue: Hashable>: View {
    let title: String
    @Binding var text: String
    var glyph: String?
    let focus: FocusState<FocusValue>.Binding
    let focusedEquals: FocusValue
    var horizontalPadding: Double = ChromeGeometry.fieldPaddingX
    var textStyle: InterfaceTextStyle = .callout
    var spacing: Double = 6

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ChromeControlBox(isFocused: focus.wrappedValue == focusedEquals, horizontalPadding: horizontalPadding) {
            HStack(spacing: metrics.scaled(spacing)) {
                if let glyph {
                    Image(systemName: glyph)
                        .foregroundStyle(theme.color(.textSecondary))
                        .accessibilityHidden(true)
                }
                ZStack(alignment: .leading) {
                    if text.isEmpty {
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

#endif
