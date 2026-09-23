#if os(macOS)
import SwiftUI
import PisakaCore

/// The Problems panel in the bottom dock: every diagnostic the
/// language servers currently hold, grouped by file.
///
/// A header carries the error/warning counts from `DiagnosticsModel.counts`
/// (information and hint deliberately absent — the header answers "how much is
/// broken", not "how much was said"), below it one group per diagnosed file in
/// the store's stable reading order (`Diagnostic.orderingKey`: path, then
/// buffer position, then severity worst-first, then span/message/source — a
/// total order). Each
/// row shows the severity icon
/// in its severity's chrome role (`ChromeColorRole.diagnosticRole(for:)`), the
/// message, and the one-based line;
/// activating a row calls back with `(url, range)` so the app can open-or-reveal
/// through the same `activateSearchMatch(url:range:)` entry point Find in Files
/// and Go to Definition use. The view holds no domain logic — it observes
/// `DiagnosticsModel` and renders its published store, mirroring
/// `LocalChangesView`/`CommitLogView`.
///
/// On the chrome roles and tokens since part four (a) of the chrome theme: the
/// header is a `panelHeaderHeight` strip that draws its own one-point
/// `hairline` along its bottom edge rather than leaving a `Divider()` to the
/// stack (gating rule fourteen), and every colour is a role.
struct ProblemsPanelView: View {
    @ObservedObject var model: DiagnosticsModel
    /// The current project root; the rows' paths are displayed relative to it.
    /// `nil` when no folder is open (and then no server can have reported).
    var projectRoot: URL?
    /// Invoked when a row is activated, with the file and the diagnostic's
    /// buffer range. Defaults to a no-op so previews/tests can construct the
    /// view without the app wiring.
    var onActivate: (URL, NSRange) -> Void = { _, _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    private var header: some View {
        let counts = model.counts
        return HStack(spacing: metrics.scaled(ProblemsPanelLayout.headerGap)) {
            Text("Problems")
                .font(metrics.scaledFont(.body, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
            if counts.errors > 0 {
                severityBadge(icon: "xmark.octagon.fill", count: counts.errors, label: "errors", severity: .error)
            }
            if counts.warnings > 0 {
                severityBadge(
                    icon: "exclamationmark.triangle.fill",
                    count: counts.warnings,
                    label: "warnings",
                    severity: .warning
                )
            }
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.panelHeaderPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.panelHeaderHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    @ViewBuilder
    private var content: some View {
        let groups = model.rows(relativeTo: projectRoot ?? URL(fileURLWithPath: "/"))
        if groups.isEmpty {
            placeholder("No problems")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.url) { group in
                        fileGroup(group)
                    }
                }
                .padding(.vertical, metrics.scaled(ProblemsPanelLayout.listPaddingY))
            }
        }
    }

    private func fileGroup(_ group: DiagnosticStore.FileRows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.scaled(ProblemsPanelLayout.groupGap)) {
                let icon = FileIcon(for: DirectoryEntry(url: group.url, isDirectory: false))
                Image(systemName: icon.symbolName)
                    .foregroundStyle(theme.color(.textSecondary))
                Text(group.pathComponents.joined(separator: " / "))
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(metrics.scaledFont(.body, weight: .medium))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
            .padding(.vertical, metrics.scaled(ProblemsPanelLayout.rowPaddingY))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            ForEach(group.rows, id: \.self) { row in
                ProblemRow(row: row, onActivate: { onActivate(group.url, row.range) })
            }
        }
    }

    private func severityBadge(icon: String, count: Int, label: String, severity: DiagnosticSeverity) -> some View {
        HStack(spacing: metrics.scaled(ProblemsPanelLayout.badgeGap)) {
            Image(systemName: icon)
                .foregroundStyle(theme.color(ChromeColorRole.diagnosticRole(for: severity)))
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
        }
        .font(metrics.scaledFont(.callout))
        .accessibilityLabel("\(count) \(label)")
        .help("\(count) \(label)")
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(theme.color(.textSecondary))
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                .padding(metrics.scaled(ProblemsPanelLayout.placeholderPadding))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One problem row: severity icon, message, and the one-based line at the
/// trailing edge. Clicking activates — open-or-reveal via the callback above.
///
/// Severity colours: two tables, one per zone. The glyph here, the header's
/// badges and the gutter's severity dot are chrome and read
/// `ChromeColorRole.diagnosticRole(for:)`; the squiggle under the text is the
/// code zone and reads `SyntaxTheme`'s own table. The panel names no
/// `SyntaxTheme` at all (gating rule fifteen).
private struct ProblemRow: View {
    let row: DiagnosticStore.Row
    let onActivate: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    private var severitySymbol: String {
        switch row.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return "info.circle.fill"
        case .hint: return "lightbulb"
        }
    }

    var body: some View {
        HStack(spacing: metrics.scaled(ProblemsPanelLayout.rowGap)) {
            Image(systemName: severitySymbol)
                .foregroundStyle(theme.color(ChromeColorRole.diagnosticRole(for: row.severity)))
            Text(row.message)
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(2)
            Spacer(minLength: metrics.scaled(ProblemsPanelLayout.rowGap))
            // One-based for display: `Row.line` is zero-based buffer geometry,
            // while the number shown beside a message is what the user reads in
            // the gutter.
            Text(":\(row.line + 1)")
                .font(metrics.scaledFont(.subheadline, design: .monospaced))
                .foregroundStyle(theme.color(.textSecondary))
        }
        .font(metrics.scaledFont(.body))
        .padding(.leading, metrics.scaled(ProblemsPanelLayout.rowIndent))
        .padding(.trailing, metrics.scaled(ChromeGeometry.rowPaddingX))
        .padding(.vertical, metrics.scaled(ProblemsPanelLayout.rowPaddingY))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        isHovering ? theme.color(.hoverTint) : .clear
    }
}

/// The panel's own measurements, bare numbers scaled once at the use site. They
/// belong to this panel alone, so deriving them from a `ChromeGeometry` token
/// would couple them to a measurement that means something else (gating rule
/// seven).
private enum ProblemsPanelLayout {
    /// Between a file group's icon and its path.
    static let groupGap: Double = 4
    /// Around the empty-state sentence: the default `.padding()` inset, stated
    /// so it scales with the rest of the panel instead of staying a fixed 16pt.
    static let placeholderPadding: Double = 16
    /// Between the header's title and its badges.
    static let headerGap: Double = 8
    /// Between a badge's glyph and its count.
    static let badgeGap: Double = 3
    /// Above and below the list inside its scroll view.
    static let listPaddingY: Double = 4
    /// Between a row's glyph, message and line number.
    static let rowGap: Double = 4
    /// A row's and a file group's vertical inset.
    static let rowPaddingY: Double = 3
    /// A row's leading inset: it sits under its file group's name, past the
    /// group's icon.
    static let rowIndent: Double = 22
}

#endif
