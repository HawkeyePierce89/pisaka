#if os(macOS)
import PisakaCore
import SwiftUI

/// The SQL console under the database viewer's grid: the reader's text, a Run
/// control, and whatever came back.
///
/// **It decides nothing.** What Run does with a text is
/// `DatabaseConsolePlan.decide(_:)`, reached through `DatabaseConsoleModel
/// .run(_:)`; how far a read goes is `DatabaseConsolePlan.rowLimit`; what the
/// footer under the result says is `DatabaseConsolePlan.resultFooter` or
/// `affectedRowsFooter`; and every sentence in the message line is either
/// SQLite's own or one of the three the plan owns. The confirmation before a
/// mutation is Core's prompt, shown verbatim, in a dialog whose two answers are
/// nothing but `confirm()` and `cancel()`. This file composes no SQL and no
/// English of its own beyond the labels on its controls.
///
/// **The result table is its own, and draws values the grid's way.** A console
/// answer is not a page of a table: it has no row identity, no sort, no paging
/// and — above all — no editing, so reusing the grid's rows would carry four
/// affordances a console result must not have. What it does reuse is the one
/// thing the two must never disagree about: `DatabaseValue.displayText` with
/// NULL styled from `isNull`, because a text value spelling `NULL` renders
/// identically and must not be dressed as a missing one.
///
/// **Everything is sized through `\.interfaceMetrics`, the input included.** The
/// input is monospaced — SQL is aligned text and reads badly proportional — but
/// it is monospaced *at the interface metrics*, which is a font design and not a
/// zoom zone: nothing here is drawn at `SettingsStore.fontSize`. That is
/// deliberate and it is why this view declares **no `ZoomSurface`**. The viewer
/// tab is one zoom zone (chrome), and a code-font input would make the pointer
/// zoom the console one way and the grid one pixel away another, splitting a
/// single pane between two zones. `ZoomSourceGatingTests` pins the surface set by
/// set equality, and this file is deliberately not in it.
struct DatabaseConsoleView: View {
    /// The tab's console. Observed, because every published thing this draws —
    /// the answer, the footer, the message, the spinner, the pending
    /// confirmation — lives on it.
    @ObservedObject var console: DatabaseConsoleModel

    /// Whether **any** write to this database is in flight, the grid's cell edit
    /// included — `DatabaseViewerModel.isWriteInFlight`, asked by the owner and
    /// handed down rather than re-derived here. One write per tab, so Run is not
    /// live while the grid is in the middle of one either.
    let isWriteInFlight: Bool

    @Environment(\.interfaceMetrics) private var metrics

    /// The reader's text.
    ///
    /// `@State` on purpose: this is transient pane state and nothing else. It is
    /// never persisted, never part of the session record, and never a buffer — a
    /// viewer tab is `isDirty == false` by construction and typing SQL into it
    /// must not be the one thing that changes that.
    @State private var text = ""

    /// The width every result column is drawn at — the grid's number, because
    /// the two tables sit one above the other and a different column rhythm in
    /// each would read as a rendering bug.
    private static let columnWidth = 160.0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            input
            Divider()
            resultArea
            Divider()
            statusBar
        }
        // The prompt is Core's, shown verbatim, and the two answers are the
        // console's own two methods. Nothing else about a mutation is decided
        // here — not whether one was asked for, not what it says, not what it
        // runs.
        .confirmationDialog(
            console.pendingConfirmation?.prompt ?? "",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) { Task { await console.confirm() } }
            Button("Cancel", role: .cancel) { console.cancel() }
        }
        // The model asks and answers; this only mirrors the ask onto the flag
        // SwiftUI presents from. The macOS 13 `onChange(of:perform:)` overload,
        // the repository's idiom.
        .onChange(of: console.pendingConfirmation) { pending in isConfirming = pending != nil }
    }

    // MARK: - Running

    private var toolbar: some View {
        HStack(spacing: metrics.scaled(8)) {
            Text("SQL")
                .font(metrics.scaledFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if console.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Run") { run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunDisabled)
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(5))
    }

    /// Run is live only when nothing is already running against this file.
    ///
    /// Two terms, and both are needed: the console's own `isRunning` covers
    /// classification, a read and a confirmed mutation of its own, while
    /// `isWriteInFlight` is the tab's answer and covers the grid's cell edit —
    /// which the console cannot see, and which would refuse a mutation anyway.
    /// Refusing to arm the control is the honest version of a refusal Core would
    /// have to spell out afterwards.
    private var isRunDisabled: Bool { console.isRunning || isWriteInFlight }

    /// The text is read here, in the click, and handed over as a value — not
    /// read inside the task. A confirmation sits in front of the reader for as
    /// long as they take to read it and they may go on typing behind it; what
    /// runs must be what was classified, which is why the model carries the text
    /// through the confirmation rather than asking for it again.
    private func run() {
        let typed = text
        Task { await console.run(typed) }
    }

    /// Whether the confirmation is on screen.
    ///
    /// **State of its own, mirrored from the model rather than derived from it.**
    /// A `Binding` reading `console.pendingConfirmation != nil` with a no-op
    /// setter is the shape this wants to be, and it is wrong in one direction:
    /// SwiftUI writes `false` when the dialog is dismissed, a no-op setter drops
    /// that write, and the pending confirmation the getter still sees is only
    /// cleared a main-actor turn later — `confirm()` is `async`, so *nothing* of
    /// it runs in the button's action. Any re-evaluation in that window
    /// re-presents a dialog the reader has already answered.
    ///
    /// Answering is still the model's alone: the two buttons call `confirm()` and
    /// `cancel()`, and this flag only follows what they publish. It must not
    /// answer for them — a `cancel()` driven from the setter would run *before*
    /// the Run button's task reached `confirm()` and would clear the very
    /// confirmation that call is about to honour.
    @State private var isConfirming = false

    // MARK: - The reader's text

    private var input: some View {
        TextEditor(text: $text)
            .font(metrics.scaledFont(.body, design: .monospaced))
            .frame(minHeight: metrics.scaled(60))
            .padding(.horizontal, metrics.scaled(4))
    }

    // MARK: - What came back

    @ViewBuilder
    private var resultArea: some View {
        if let answer = console.answer, !answer.columnNames.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                // Lazy for the grid's reason: the cap is 500 rows and a wide
                // result is thousands of cells. Safe inside a horizontally
                // scrolling `ScrollView` because every row is the same width by
                // construction — each cell is drawn at the one fixed width the
                // header uses.
                LazyVStack(alignment: .leading, spacing: 0) {
                    headerRow(answer.columnNames)
                    Divider()
                    ForEach(Array(answer.rows.enumerated()), id: \.offset) { index, row in
                        resultRow(row, isTinted: !index.isMultiple(of: 2))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The result's column headings — **by position**, exactly like the grid's,
    /// and for the same reason: a statement may legally name two columns the same
    /// (`SELECT t.id, u.id FROM t JOIN u`), SQLite answers both as `id`, and
    /// keying by the string would draw fewer headings than there are cells and
    /// shift every column. Not a control: a console result has no sort.
    private func headerRow(_ names: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(metrics.scaledFont(.caption, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, metrics.scaled(6))
                    .padding(.vertical, metrics.scaled(4))
                    .frame(width: metrics.scaled(Self.columnWidth), alignment: .leading)
                Divider()
            }
        }
    }

    private func resultRow(_ row: [DatabaseValue], isTinted: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                resultCell(value)
                Divider()
            }
        }
        .background(isTinted ? Color.primary.opacity(0.04) : Color.clear)
    }

    /// One value, drawn **the grid's way**: the rendered text, and NULL dimmed
    /// and italic as well as carrying the marker. The one distinction the viewer
    /// must not blur is NULL against the text `NULL`, and the two tables answer
    /// it out of the same `isNull`.
    ///
    /// Selectable, unlike the grid's cells: nothing here opens an editor on a
    /// double-click, so the gesture is free to mean what it means everywhere else.
    private func resultCell(_ value: DatabaseValue) -> some View {
        Text(value.displayText)
            .font(metrics.scaledFont(.caption))
            .italic(value.isNull)
            .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, metrics.scaled(6))
            .padding(.vertical, metrics.scaled(3))
            .frame(width: metrics.scaled(Self.columnWidth), alignment: .leading)
    }

    // MARK: - The footer and the message

    /// Core's two sentences, side by side: the footer describing what the last
    /// answer was, and the message saying why the last run has none. Both are
    /// shown at once because they describe different runs — a failed run replaces
    /// nothing, so the previous result's footer is still true and blanking it
    /// would leave the message with no context at all.
    private var statusBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(8)) {
            if let footer = console.footer {
                Text(footer)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
            }
            if let message = console.message {
                HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(4)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(metrics.scaledFont(.caption))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(5))
    }
}
#endif
