#if os(macOS)
import AppKit
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
///
/// **Editing decides nothing either.** Whether a cell may be written at all is
/// `DatabaseViewerModel.editRefusal(row:column:)`, what a typed string means as a
/// stored value is `DatabaseCellEntry`, and whether the write landed is the
/// model's message: this opens a field, hands over what was typed, and draws
/// whatever came back. NULL is reachable only through the cell menu's explicit
/// item and never by typing the word — an empty field means the empty string,
/// which is why a NULL cell seeds an *empty* editor rather than the marker it
/// renders.
struct DatabaseViewerView: View {
    @ObservedObject var model: DatabaseViewerModel

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    /// The cell whose editor is open, or `nil` while the grid is only being read.
    ///
    /// A coordinate, not a value: the row number is the *page's*, so an editor
    /// left open across a page turn would be typing into whatever landed at the
    /// same coordinates. Every path that replaces the rows raises
    /// `isLoadingRows` first, which is what closes it.
    @State private var editing: CellCoordinate?
    /// The rows token as it stood when `editing` opened.
    ///
    /// The anchor for the write's staleness check is the moment the reader chose
    /// the value they are editing, not the moment they press Return: every
    /// rows-replacing path bumps the token before its first hop, so a load
    /// starting under an open editor makes this stale by construction and the
    /// write is refused. Reading the token at Return instead would leave that
    /// property to `.onChange(of: model.isLoadingRows)` closing the editor first —
    /// a per-render diff, which a load that raises and lowers the flag between two
    /// renders never fires at all (`DatabaseViewerModel.rowsToken`).
    @State private var editingToken: Int?

    /// What is in the open field, seeded from the cell and never trimmed —
    /// `DatabaseCellEntry` stores exactly what was typed, spaces included.
    @State private var draft = ""

    /// Where the keyboard is inside the grid: on a cell, where Return opens its
    /// editor, or in the open field. One `@FocusState` rather than two, so the
    /// two states cannot both claim to hold it.
    @FocusState private var focus: GridFocus?

    /// What a cell Core refuses is drawn at. Faint enough to read as unavailable
    /// beside an editable neighbour, legible enough that the value is still the
    /// point — a viewer's whole job is showing what is there, and a view or an
    /// unaddressable table refuses *every* cell it has.
    private static let refusedCellOpacity = 0.5

    /// One cell's place on the page.
    private struct CellCoordinate: Hashable {
        let row: Int
        let column: Int
    }

    /// What the keyboard is on inside the grid.
    private enum GridFocus: Hashable {
        case cell(CellCoordinate)
        case editor(CellCoordinate)
    }

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
        // Keyed on the model, not on its `fileURL`: a rename retargets the tab and
        // the model follows it, and a task re-fired by that would race a `reload()`
        // already in flight for the same reconnect. One model is one tab is one
        // connection, so the object *is* the identity the load belongs to.
        .task(id: ObjectIdentifier(model)) { await model.load() }
        // Every rows-replacing path — a selection, a page turn, a sort, the
        // re-query after a committed write — raises this before its hop, so it is
        // the one signal that says "the cell under the open editor is about to
        // stop being that cell". Closing writes nothing, which is the honest
        // answer for an edit the reader never committed.
        .onChange(of: model.isLoadingRows) { isLoading in
            if isLoading { cancelEditing() }
        }
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
    ///
    /// The token is captured **here**, in the click, and carried into the task —
    /// the repository's standing rule, and `prepareForRowsChange()` says why two
    /// quick clicks need it.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedTable },
            set: { name in
                guard let name else { return }
                let request = model.prepareForRowsChange()
                Task { await model.select(table: name, request: request) }
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
            placeholder(placeholderText)
        } else {
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    // Lazy, because a page is 200 rows and a wide table's page is
                    // thousands of cells: an eager stack builds every one of them
                    // on the main actor before the first is drawn, on every table
                    // select, page turn and sort toggle. Safe to be lazy here even
                    // inside a horizontally scrolling `ScrollView`, where a lazy
                    // stack sizes to its *visible* children: every row is the same
                    // width by construction, since each cell is drawn at the one
                    // fixed column width `headerRow` uses.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        headerRow
                        Divider()
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                            dataRow(row, at: index, isTinted: !index.isMultiple(of: 2))
                        }
                    }
                }
                Divider()
                footer
                returnOpensTheFocusedCell
            }
        }
    }

    /// What stands in for the grid before a table is selected.
    ///
    /// "No tables or views" is a **claim about the database**, so it is made only
    /// once there is one to make it about: while the listing is still in flight
    /// nobody has read the file yet, and under an error banner the banner is
    /// already saying what happened — a second, contradicting sentence beneath it
    /// is `positionText`'s reasoning one pane over.
    private var placeholderText: String {
        if !model.entries.isEmpty { return "Select a table" }
        if model.isLoadingEntries { return "Loading…" }
        return model.errorMessage == nil ? "No tables or views" : ""
    }

    /// The column headers, which are also the sort control: a click asks
    /// `toggleSort(column:index:)` and the arrow shows what came back.
    ///
    /// Keyed by **position**, exactly like `dataRow` below, and not by the name:
    /// a view may legally select two columns with the same name
    /// (`SELECT t.id, u.id FROM t JOIN u`), SQLite answers both of them as `id`,
    /// and identifying a header by a string that repeats would draw fewer headers
    /// than there are cells — shifting every column heading in that view.
    /// The position is also what the *sort* is keyed by — passed to
    /// `toggleSort` and compared against for the arrow — for the same reason:
    /// keying either by the name would make a click on one duplicate flip the
    /// other and draw the arrow on both (`DatabaseSortState`).
    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.gridColumns.enumerated()), id: \.offset) { index, name in
                Button {
                    let request = model.prepareForRowsChange()
                    Task { await model.toggleSort(column: name, index: index, request: request) }
                } label: {
                    HStack(spacing: metrics.scaled(3)) {
                        Text(name)
                            .font(metrics.scaledFont(.caption, weight: .semibold))
                            .lineLimit(1)
                        if let sort = model.sort, sort.columnIndex == index {
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

    private func dataRow(_ row: [DatabaseValue], at index: Int, isTinted: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                cell(value, at: CellCoordinate(row: index, column: column))
                Divider()
            }
        }
        .background(isTinted ? Color.primary.opacity(0.04) : Color.clear)
    }

    /// One cell: the field while it is being edited, the value the rest of the
    /// time.
    @ViewBuilder
    private func cell(_ value: DatabaseValue, at coordinate: CellCoordinate) -> some View {
        if editing == coordinate {
            cellEditor(coordinate)
        } else {
            cellText(value, at: coordinate)
        }
    }

    /// One cell's value. NULL is dimmed and italic **as well as** carrying the
    /// marker, which is the only thing that tells it apart from a text value
    /// spelling the same word.
    ///
    /// No longer `.textSelection(.enabled)`: on selectable text a double-click
    /// selects a word, and that is the gesture that now has to open the editor.
    /// Copying is the cell menu's `Copy`, which puts on the pasteboard exactly the
    /// rendered text a selection would have carried.
    ///
    /// A cell Core refuses is drawn dimmed, is not focusable — so Return cannot
    /// reach it either — and carries the refusal's own sentence as its tooltip.
    /// The reason is asked once, here, and nothing about it is re-derived: the
    /// dimming, the tooltip, the menu's disabled item and the banner the
    /// double-click produces are four renderings of the one answer.
    ///
    /// The dimming is `.opacity` on the whole cell rather than a second
    /// foreground style, so it composes with the NULL rendering instead of
    /// competing with it: a refused NULL stays italic and tertiary and simply
    /// reads fainter, where a greyer `foregroundStyle` would have made a refused
    /// value and an editable NULL the same colour. It is what tells a view or an
    /// unaddressable table apart from an editable one at a glance, which hovering
    /// every cell in turn is not.
    private func cellText(_ value: DatabaseValue, at coordinate: CellCoordinate) -> some View {
        let refusal = model.editRefusal(row: coordinate.row, column: coordinate.column)
        // Captured beside the refusal, and for the same reason the double-click
        // captures `editingToken`: this is the page the reader is looking at when
        // they reach for the cell. The menu's own gesture is two moments — the
        // right-click that builds it and the click on an item — and only the first
        // is "the value they chose". Read inside the item's action instead, the
        // token would be whatever the generation had become while the menu sat
        // open, so a page that landed underneath it would pass the staleness check
        // and NULL would be written to whichever row now occupies this coordinate,
        // carrying that row's identity and that row's previous value — and so
        // committing. `refusal` is already frozen here and `.disabled` does not
        // re-evaluate under an open menu; the token belongs to the same snapshot.
        let request = model.rowsToken
        return Text(value.displayText)
            .font(metrics.scaledFont(.caption))
            .italic(value.isNull)
            .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, metrics.scaled(6))
            .padding(.vertical, metrics.scaled(3))
            .frame(width: metrics.scaled(160), alignment: .leading)
            .opacity(refusal == nil ? 1 : Self.refusedCellOpacity)
            .contentShape(Rectangle())
            .help(refusal?.message ?? "")
            .focusable(refusal == nil && isGridIdle)
            .focused($focus, equals: .cell(coordinate))
            .onTapGesture(count: 2) { beginEditing(value, at: coordinate) }
            // The single click is what makes the Return shortcut reachable at all.
            // `.focusable` alone leaves Tab traversal as the only route to a cell,
            // and Tab reaches a non-text control only when "Use keyboard
            // navigation to move focus between controls" is on — off by default —
            // so without this the documented "press Return while the cell has the
            // keyboard" is dead on an ordinary Mac. Declared *after* the
            // double-click so the two-click gesture still wins the disambiguation,
            // and guarded by the same answer the cell is drawn from: a cell nothing
            // may edit is not focusable, and focusing it would arm Return over a
            // refusal.
            //
            // It also closes an editor open somewhere *else*. Focus moving out of
            // a field is not by itself a signal the model ever sees, so without
            // this the abandoned field stays on screen unfocused while `editing`
            // still points at it — and `focusedCoordinate` answers `nil` while an
            // editor is open, so Return would silently stop working on the cell
            // the reader just clicked. Closing writes nothing, the same answer
            // Escape and every rows-replacing load give.
            .onTapGesture {
                let mayFocus = refusal == nil && isGridIdle
                // Before the focus is set, because `cancelEditing()` clears it —
                // and only for an editor open somewhere *else*, which is the whole
                // of what this is for. A cell being edited draws the field rather
                // than this text, so `editing == coordinate` here is reachable only
                // within the double-click SwiftUI has not re-rendered yet; closing
                // it there would leave the feature's primary gesture opening an
                // editor and shutting it again, and only when the arbitration
                // happened to run the two handlers in that order.
                if let editing, editing != coordinate { cancelEditing() }
                if mayFocus { focus = .cell(coordinate) }
            }
            .contextMenu { cellMenu(value, at: coordinate, refusal: refusal, request: request) }
    }

    /// The open editor: a plain field seeded from the cell.
    ///
    /// A NULL cell seeds **empty**, because an empty entry is the empty string and
    /// NULL is a gesture: seeding the marker would make Return store the *text*
    /// `NULL`, which is the one confusion the marker exists to prevent. Return
    /// commits through the model, Escape closes the field and writes nothing.
    private func cellEditor(_ coordinate: CellCoordinate) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(metrics.scaledFont(.caption))
            .focused($focus, equals: .editor(coordinate))
            .onSubmit { commitEditing(coordinate) }
            .onExitCommand { cancelEditing() }
            .padding(.horizontal, metrics.scaled(2))
            .frame(width: metrics.scaled(160), alignment: .leading)
            .onAppear { focus = .editor(coordinate) }
    }

    /// The cell's menu: the rendered text, and the one gesture that reaches NULL.
    @ViewBuilder
    private func cellMenu(
        _ value: DatabaseValue,
        at coordinate: CellCoordinate,
        refusal: DatabaseEditRefusal?,
        request: Int
    ) -> some View {
        Button("Copy") { copy(value) }
        Button("Set to NULL") {
            // `request` was captured with the cell, not read here and not inside
            // the task: see `cellText(_:at:)` and `DatabaseViewerModel.rowsToken`.
            Task {
                await model.setCellToNull(row: coordinate.row, column: coordinate.column, request: request)
            }
        }
        .disabled(refusal != nil || !isGridIdle)
    }

    // MARK: - Opening, committing and abandoning an editor

    /// Whether an edit may start at all.
    ///
    /// Not a judgement about the cell — that is Core's — but about the grid: a
    /// write in flight was planned against the values currently on screen and is
    /// about to replace one of them, and a page in flight is about to replace all
    /// of them. An editor opened over either would be typing into rows that no
    /// longer exist by the time Return arrives.
    private var isGridIdle: Bool { !model.isWriting && !model.isLoadingRows }

    /// Double-click, or Return on the focused cell.
    ///
    /// A refused cell opens no editor and the attempt is reported instead, which
    /// is what puts the refusal's own sentence in the banner. Reported
    /// synchronously and through `reportEditRefusal` rather than through the write
    /// API: nothing is sent, nothing is composed, and no entry nobody typed is
    /// invented to be refused (`DatabaseViewerModel.reportEditRefusal`).
    private func beginEditing(_ value: DatabaseValue, at coordinate: CellCoordinate) {
        guard isGridIdle else { return }
        guard model.canEdit(row: coordinate.row, column: coordinate.column) else {
            model.reportEditRefusal(row: coordinate.row, column: coordinate.column)
            return
        }
        draft = value.isNull ? "" : value.displayText
        // Captured here rather than at Return: see `editingToken`.
        editingToken = model.rowsToken
        editing = coordinate
    }

    /// Return commits what is in the field. The editor closes first, so the row
    /// the write re-reads is drawn as a value rather than under a stale field.
    ///
    /// The rows token is the one `beginEditing` captured, so any page that
    /// replaced the rows between opening the field and this keystroke — landed or
    /// still in flight — refuses the write rather than letting it be planned
    /// against whatever row has taken this coordinate (`editingToken`,
    /// `DatabaseViewerModel.rowsToken`).
    private func commitEditing(_ coordinate: CellCoordinate) {
        let typed = draft
        let request = editingToken ?? model.rowsToken
        cancelEditing()
        Task {
            await model.updateCell(
                row: coordinate.row,
                column: coordinate.column,
                entry: .typed(typed),
                request: request
            )
        }
    }

    /// Escape — and every path that replaces the rows under an open editor.
    private func cancelEditing() {
        editing = nil
        editingToken = nil
        draft = ""
        focus = nil
    }

    /// The rendered text, which is the same string the grid is showing: a blob
    /// copies its placeholder and NULL copies the marker, because that is what the
    /// reader pointed at.
    private func copy(_ value: DatabaseValue) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value.displayText, forType: .string)
    }

    /// Return opens the focused cell's editor.
    ///
    /// A zero-sized button carrying the shortcut rather than a key handler on the
    /// cell itself: `onKeyPress(_:)` is macOS 14 and this app runs on 13. It is
    /// enabled **only** while a grid cell actually holds the keyboard, so it can
    /// take Return neither from the field it opens nor from anything else the
    /// window is showing.
    private var returnOpensTheFocusedCell: some View {
        Button("Edit Cell") { beginEditingFocusedCell() }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(focusedCoordinate == nil)
            .accessibilityHidden(true)
    }

    /// The cell holding the keyboard, or `nil` when an editor is open or the
    /// keyboard is somewhere else entirely.
    private var focusedCoordinate: CellCoordinate? {
        guard editing == nil, case .some(.cell(let coordinate)) = focus else { return nil }
        return coordinate
    }

    private func beginEditingFocusedCell() {
        guard let coordinate = focusedCoordinate,
              model.rows.indices.contains(coordinate.row),
              model.rows[coordinate.row].indices.contains(coordinate.column)
        else { return }
        beginEditing(model.rows[coordinate.row][coordinate.column], at: coordinate)
    }

    // MARK: - Where the reader is

    private var footer: some View {
        HStack(spacing: metrics.scaled(8)) {
            Button {
                // Both the target index and the token are read here, in the
                // click, not inside the task — see `goToPage(_:request:)`.
                let target = model.page.index - 1
                let request = model.prepareForRowsChange()
                Task { await model.goToPage(target, request: request) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.page.hasPrevious)
            Button {
                let target = model.page.index + 1
                let request = model.prepareForRowsChange()
                Task { await model.goToPage(target, request: request) }
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
