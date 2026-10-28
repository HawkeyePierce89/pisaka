#if os(macOS)
import PisakaCore
import SwiftUI

/// The chrome's tag: a short word in a role colour inside a `hairline`-bordered
/// capsule, with no fill.
///
/// One view for the form, so its two users — the Pull Requests panel's state
/// tags and the project tree's `dependencies` mark on a dependency root — cannot
/// drift apart. The caller names the text's role and its `InterfaceTextStyle`;
/// the insets are `ChromeGeometry.tagPaddingX` / `tagPaddingY` and the ring is
/// `hairlineWidth`, all scaled here. What the tag does inside its row — whether
/// it may be compressed, whether it is spoken — is the call site's to state, so
/// this carries no `.fixedSize()` and no accessibility modifier.
struct ChromeTag: View {
    private let text: String
    private let role: ChromeColorRole
    private let style: InterfaceTextStyle

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    init(_ text: String, role: ChromeColorRole, style: InterfaceTextStyle) {
        self.text = text
        self.role = role
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(metrics.scaledFont(style))
            .foregroundStyle(theme.color(role))
            .lineLimit(1)
            .padding(.horizontal, metrics.scaled(ChromeGeometry.tagPaddingX))
            .padding(.vertical, metrics.scaled(ChromeGeometry.tagPaddingY))
            .overlay(
                Capsule().strokeBorder(
                    theme.color(.hairline),
                    lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth)
                )
            )
    }
}
#endif
