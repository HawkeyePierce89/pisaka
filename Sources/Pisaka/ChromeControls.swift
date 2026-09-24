#if os(macOS)
import SwiftUI
import PisakaCore

/// The shared chrome field and button shapes.
///
/// Two chrome decisions, one file: the field box — `bgEditor` ground, a
/// one-point `hairline` border and two points of `accent` on focus — and the
/// secondary button. The Log filter bar was the shape lifted; every later
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
