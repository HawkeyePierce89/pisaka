#if os(macOS)
import PisakaCore
import SwiftUI

/// The database viewer's whole surface: what a `.viewer` tab shows instead of the
/// code editor.
///
/// A sidebar of the database's tables and views, the selected one's schema under
/// it, and the paged grid beside them with clickable sorting headers and the
/// paging controls in its footer. An error banner sits above everything, because
/// a failure that scrolled away with the grid would be a failure nobody read.
///
/// **The view decides nothing.** Which page exists, whether there is a next one,
/// what row range is on screen, which way a header click sorts, and how a cell is
/// written are all answered by Core — `DatabasePage`, `DatabaseSortState`,
/// `DatabaseValue.displayText` — and this only draws the answers, the way
/// `LocalChangesView` draws `LocalChangesModel`. The one thing it does judge is
/// ink: a NULL cell is styled from `isNull` rather than by comparing its text to
/// the marker, because a text value spelling `NULL` renders identically and must
/// not be dressed as a missing one.
///
/// Everything is sized through `\.interfaceMetrics`: nothing here is drawn at the
/// code font, so the viewer is chrome for zoom purposes and declares no
/// `ZoomSurface` — the pointer over it zooms the interface, which is what a table
/// of data means.
struct DatabaseViewerView: View {
    @ObservedObject var model: DatabaseViewerModel

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                errorBanner(message)
                Divider()
            }
            HStack(spacing: 0) {
                sidebar
                    .frame(width: metrics.scaled(220))
                Divider()
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.fileURL) { await model.load() }
    }

    // MARK: - The failure

    /// SQLite's own sentence, never one written here. Kept at the top of the pane
    /// and out of the scrolling grid so it is visible whatever the reader is
    /// looking at.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(6)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(metrics.scaledFont(.callout))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Tables, views and the schema

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section("Tables") {
                    ForEach(model.entries.filter { $0.kind == .table }) { entry in
                        entryRow(entry)
                    }
                }
                Section("Views") {
                    ForEach(model.entries.filter { $0.kind == .view }) { entry in
                        entryRow(entry)
                    }
                }
            }
            .listStyle(.sidebar)
            if !model.columns.isEmpty {
                Divider()
                schema
            }
        }
    }

    /// The sidebar's selection, routed through `select(table:)` so picking a row
    /// is the same code path a programmatic selection would take.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedTable },
            set: { name in
                guard let name else { return }
                Task { await model.select(table: name) }
            }
        )
    }

    private func entryRow(_ entry: DatabaseTableEntry) -> some View {
        Label(entry.name, systemImage: entry.kind == .table ? "tablecells" : "eye")
            .font(metrics.scaledFont(.body))
            .tag(entry.name)
    }

    /// The selected table's columns, as `PRAGMA table_xinfo` described them.
    private var schema: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(2)) {
            Text("Schema")
                .font(metrics.scaledFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, metrics.scaled(2))
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.scaled(3)) {
                    // By position, for `headerRow`'s reason: `PRAGMA table_xinfo`
                    // on a view repeats whatever names the view selected.
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { _, column in
                        schemaRow(column)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(metrics.scaled(8))
        .frame(maxHeight: metrics.scaled(200))
    }

    private func schemaRow(_ column: DatabaseColumn) -> some View {
        HStack(spacing: metrics.scaled(4)) {
            if column.isPrimaryKey {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .help("Primary key, position \(column.primaryKeyPosition ?? 1)")
            }
            Text(column.name)
                .font(metrics.scaledFont(.caption))
            Text(schemaDetail(column))
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// The column's declaration, in the order a reader scans it: the type it was
    /// declared with (possibly none — SQLite allows that), then only the facts
    /// that are true.
    private func schemaDetail(_ column: DatabaseColumn) -> String {
        var parts: [String] = []
        if !column.declaredType.isEmpty { parts.append(column.declaredType) }
        if column.isNotNull { parts.append("NOT NULL") }
        if let value = column.defaultExpression { parts.append("DEFAULT \(value)") }
        if column.isHidden { parts.append("GENERATED") }
        return parts.joined(separator: " · ")
    }

    // MARK: - The grid

    @ViewBuilder
    private var grid: some View {
        if model.selectedTable == nil {
            placeholder(model.entries.isEmpty ? "No tables or views" : "Select a table")
        } else {
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow
                        Divider()
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            dataRow(row, isAlternate: index.isMultiple(of: 2))
                        }
                    }
                }
                Divider()
                footer
            }
        }
    }

    /// The column headers, which are also the sort control: a click asks
    /// `toggleSort(column:)` and the arrow shows what came back.
    ///
    /// Keyed by **position**, exactly like `dataRow` below, and not by the name:
    /// a view may legally select two columns with the same name
    /// (`SELECT t.id, u.id FROM t JOIN u`), SQLite answers both of them as `id`,
    /// and identifying a header by a string that repeats would draw fewer headers
    /// than there are cells — shifting every column heading in that view.
    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.gridColumns.enumerated()), id: \.offset) { _, name in
                Button {
                    Task { await model.toggleSort(column: name) }
                } label: {
                    HStack(spacing: metrics.scaled(3)) {
                        Text(name)
                            .font(metrics.scaledFont(.caption, weight: .semibold))
                            .lineLimit(1)
                        if let sort = model.sort, sort.column == name {
                            Image(systemName: sort.direction.isAscending ? "chevron.up" : "chevron.down")
                                .font(metrics.scaledFont(.caption2))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, metrics.scaled(6))
                    .padding(.vertical, metrics.scaled(4))
                    .frame(width: metrics.scaled(160), alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func dataRow(_ row: [DatabaseValue], isAlternate: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                cell(value)
                Divider()
            }
        }
        .background(isAlternate ? Color.clear : Color.primary.opacity(0.04))
    }

    /// One cell. NULL is dimmed and italic **as well as** carrying the marker,
    /// which is the only thing that tells it apart from a text value spelling the
    /// same word.
    private func cell(_ value: DatabaseValue) -> some View {
        Text(value.displayText)
            .font(metrics.scaledFont(.caption))
            .italic(value.isNull)
            .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, metrics.scaled(6))
            .padding(.vertical, metrics.scaled(3))
            .frame(width: metrics.scaled(160), alignment: .leading)
    }

    // MARK: - Where the reader is

    private var footer: some View {
        HStack(spacing: metrics.scaled(8)) {
            Button {
                Task { await model.goToPage(model.page.index - 1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.page.hasPrevious)
            Button {
                Task { await model.goToPage(model.page.index + 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.page.hasNext)
            Text(positionText)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
            if model.isLoadingRows {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(5))
    }

    /// What the footer says, straight off `DatabasePage`. An uncounted total is
    /// left unsaid rather than drawn as a zero — the type's own rule.
    private var positionText: String {
        guard let range = model.displayedRows else {
            if model.isLoadingRows { return "Loading…" }
            // Uncounted *and* not loading is where a failed select lands, and the
            // banner above already says what happened: claiming a load is in
            // flight under it would be the one sentence contradicting the error.
            return model.page.isCounted ? "No rows" : ""
        }
        guard let total = model.page.totalRows, let pages = model.page.pageCount else {
            return "Rows \(range.lowerBound)–\(range.upperBound)"
        }
        return "Rows \(range.lowerBound)–\(range.upperBound) of \(total) · Page \(model.page.index + 1) of \(pages)"
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(metrics.scaledFont(.body))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The one thing `ContentView.editorZone` renders for a viewer tab: it resolves
/// the tab's model out of `DatabaseViewerTabs` and hands it to the surface.
///
/// A wrapper rather than a lookup inside `editorZone` so `ContentView` gains no
/// dependency on the owner at all — it routes on the tab kind and nothing else.
/// The lookup happens in `body` because that is where the tab first becomes
/// visible, and it is idempotent by construction: the owner creates a model the
/// first time and returns the same one on every re-render, so a body that runs
/// ten times still opens one connection.
struct DatabaseViewerHost: View {
    /// The viewer tab to show.
    let file: OpenFile

    @EnvironmentObject private var viewers: DatabaseViewerTabs

    var body: some View {
        if let model = viewers.model(for: file) {
            // Keyed on the tab, so switching between two viewer tabs rebuilds the
            // surface against the other model rather than reusing this one's
            // scroll and selection state under a different database's rows.
            DatabaseViewerView(model: model)
                .id(file.id)
        }
    }
}
#endif
