#if os(macOS)
import SwiftUI
import PisakaCore

/// The Problems panel in the VS Code-style bottom dock: every diagnostic the
/// language servers currently hold, grouped by file.
///
/// A header carries the error/warning counts from `DiagnosticsModel.counts`
/// (information and hint deliberately absent — the header answers "how much is
/// broken", not "how much was said"), below it one group per diagnosed file in
/// the store's stable reading order (`Diagnostic.orderingKey`: path, then
/// buffer position, then severity worst-first, then span/message/source — a
/// total order). Each
/// row shows the severity icon
/// in `SyntaxTheme`'s severity color, the message, and the one-based line;
/// activating a row calls back with `(url, range)` so the app can open-or-reveal
/// through the same `activateSearchMatch(url:range:)` entry point Find in Files
/// and Go to Definition use. The view holds no domain logic — it observes
/// `DiagnosticsModel` and renders its published store, mirroring
/// `LocalChangesView`/`CommitLogView`.
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        let counts = model.counts
        return HStack(spacing: metrics.scaled(8)) {
            Text("Problems")
                .font(metrics.scaledFont(.headline, weight: .semibold))
            if counts.errors > 0 {
                severityBadge(icon: "xmark.octagon.fill", count: counts.errors, label: "errors", color: severityColor(.error))
            }
            if counts.warnings > 0 {
                severityBadge(
                    icon: "exclamationmark.triangle.fill",
                    count: counts.warnings,
                    label: "warnings",
                    color: severityColor(.warning)
                )
            }
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
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
                .padding(.vertical, metrics.scaled(4))
            }
        }
    }

    private func fileGroup(_ group: DiagnosticStore.FileRows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.scaled(4)) {
                let icon = FileIcon(for: DirectoryEntry(url: group.url, isDirectory: false))
                Image(systemName: icon.symbolName)
                    .foregroundStyle(Color.secondary)
                Text(group.pathComponents.joined(separator: " / "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(metrics.scaledFont(.body, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, metrics.scaled(6))
            .padding(.vertical, metrics.scaled(3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            ForEach(group.rows, id: \.self) { row in
                ProblemRow(row: row, onActivate: { onActivate(group.url, row.range) })
            }
        }
    }

    private func severityBadge(icon: String, count: Int, label: String, color: Color) -> some View {
        HStack(spacing: metrics.scaled(3)) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(metrics.scaledFont(.callout))
        .accessibilityLabel("\(count) \(label)")
        .help("\(count) \(label)")
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                // The default `.padding()` inset, stated so it scales with the
                // rest of the panel instead of staying a fixed 16pt.
                .padding(metrics.scaled(16))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The severity colors come from the same table the squiggles and gutter
    /// markers use — three surfaces, one palette (`SyntaxTheme`'s rule).
    private func severityColor(_ severity: DiagnosticSeverity) -> Color {
        Color(nsColor: SyntaxTheme.shared.diagnosticColor(for: severity))
    }
}

/// One problem row: severity icon, message, and the one-based line at the
/// trailing edge. Clicking activates — open-or-reveal via the callback above.
private struct ProblemRow: View {
    let row: DiagnosticStore.Row
    let onActivate: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    private var severitySymbol: String {
        switch row.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return "info.circle.fill"
        case .hint: return "lightbulb"
        }
    }

    var body: some View {
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: severitySymbol)
                .foregroundStyle(severityColor)
            Text(row.message)
                .lineLimit(2)
            Spacer(minLength: metrics.scaled(4))
            // One-based for display: `Row.line` is zero-based buffer geometry,
            // while the number shown beside a message is what the user reads in
            // the gutter.
            Text(":\(row.line + 1)")
                .font(metrics.scaledFont(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
        .font(metrics.scaledFont(.body))
        .padding(.leading, metrics.scaled(22))
        .padding(.trailing, metrics.scaled(6))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        isHovering ? Color.accentColor.opacity(0.15) : .clear
    }

    private var severityColor: Color {
        Color(nsColor: SyntaxTheme.shared.diagnosticColor(for: row.severity))
    }
}

#endif
