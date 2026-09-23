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

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ChromeControlBox(isFocused: focus.wrappedValue == focusedEquals, horizontalPadding: horizontalPadding) {
            HStack(spacing: metrics.scaled(6)) {
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
            .font(metrics.scaledFont(.callout))
        }
    }
}

/// The secondary button style: 28 high, a one-point `hairline` border, radius
/// `buttonCornerRadius`, padding 14 and a `callout` label in `textPrimary`.
struct ChromeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

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
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == ChromeSecondaryButtonStyle {
    static var chromeSecondary: ChromeSecondaryButtonStyle { ChromeSecondaryButtonStyle() }
}

#endif
