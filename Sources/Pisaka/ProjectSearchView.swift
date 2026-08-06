#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The Find in Files window's contents (⌘⇧F): the query controls at the top, the
/// per-file result groups below.
///
/// Thin and untested like the rest of `Sources/Pisaka`. Every decision — which
/// files are walked, what matches, what a replacement expands to, which files a
/// batch skipped — belongs to `PisakaCore.ProjectSearchModel`; this view collects
/// the query, renders `results`, and hands activation and Replace All back to
/// `PisakaApp` through closures (the app owns the open-file path and the
/// disk-writer coordination, neither of which a view may reach into).
///
/// **Debounced, deliberately — the opposite of the editor's find bar.** The
/// per-file bar re-runs synchronously on every keystroke because it scans one open
/// buffer (see `EditorSearchController`'s type comment). Here a single keystroke
/// costs a whole directory traversal plus a read of every file that survives the
/// gitignore/mask/binary filters, so the query is coalesced by
/// `searchDebounceDelay` before it reaches the model. The model's generation token
/// then supersedes whatever the debounce still let through.
struct ProjectSearchView: View {
    /// How long the query controls settle before a search is dispatched.
    private static let searchDebounceDelay: TimeInterval = 0.3

    @ObservedObject var model: ProjectSearchModel

    /// Shared preferences: the result rows use the editor font size, and a forced
    /// Light/Dark theme has to reach this separate window like it does the diff
    /// and merge windows.
    @ObservedObject var settings: SettingsStore

    /// The folder to search, read *at search time* rather than captured as a
    /// value: this window outlives a folder switch, and a stale root would walk
    /// the project the user just left.
    let root: () -> URL?

    /// Open `url` and select `range` in the editor. Wired to `PisakaApp`, which
    /// owns both the open-file path and the reveal request.
    let onActivate: (URL, NSRange) -> Void

    /// Run a project-wide Replace All under the app's disk-writer gates, returning
    /// what happened — or `nil` when the app refused (a revert is in flight and has
    /// already explained itself).
    ///
    /// The `Int` is the project generation this batch was issued for, captured
    /// synchronously by `confirmReplaceAll` and threaded down to
    /// `ProjectSearchModel.replaceAll(template:originGeneration:)`.
    let onReplaceAll: (String, Int) async -> ReplaceSummary?

    @State private var pattern = ""
    @State private var template = ""
    @State private var mask = ""
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var isRegex = false
    /// Whether the replace field and its button are shown (the Find/Replace switch).
    @State private var isReplaceExpanded = false
    /// Raised while a Replace All batch runs, so the button can't be pressed twice.
    @State private var isReplacing = false

    /// Owns the pending debounced dispatch. A `@StateObject` rather than `@State`
    /// so the timer survives the view struct being rebuilt on every keystroke.
    @StateObject private var debounce = SearchDebounce()

    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            resultsArea
        }
        .frame(minWidth: 520, minHeight: 320)
        .preferredColorScheme(settings.themePreference.colorScheme)
        .onAppear {
            // Re-seed from the model so reopening the window shows the query whose
            // results are still on screen.
            pattern = model.query.pattern
            caseSensitive = model.query.caseSensitive
            wholeWord = model.query.wholeWord
            isRegex = model.query.isRegex
            mask = model.fileMask
            isQueryFocused = true
        }
        .onDisappear { debounce.cancel() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    isReplaceExpanded.toggle()
                } label: {
                    Image(systemName: isReplaceExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(isReplaceExpanded ? "Hide replace" : "Show replace")

                TextField("Find in files", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .focused($isQueryFocused)
                    // Enter jumps to the first result, so a search can be walked
                    // without leaving the keyboard.
                    .onSubmit { activateFirstResult() }
                    .onChange(of: pattern) { _ in scheduleSearch() }

                toggle("Aa", isOn: $caseSensitive, help: "Match case")
                toggle("ab", isOn: $wholeWord, help: "Words")
                toggle(".*", isOn: $isRegex, help: "Regular expression")

                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 2)
                }
            }

            if isReplaceExpanded {
                HStack(spacing: 6) {
                    Spacer().frame(width: 12)

                    TextField("Replace with", text: $template)
                        .textFieldStyle(.roundedBorder)

                    Button("Replace All") { confirmReplaceAll() }
                        .disabled(
                            model.results.isEmpty || isReplacing || model.isSearching
                                || !resultsMatchControls
                        )
                }
            }

            HStack(spacing: 6) {
                Spacer().frame(width: 12)

                Text("File mask")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("*.ts, *.tsx", text: $mask)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onChange(of: mask) { _ in scheduleSearch() }

                Spacer(minLength: 4)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.errorMessage {
                // An invalid regular expression reports its reason inline, in red
                // — never as an alert: the pattern is being typed.
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(NSColor.systemRed))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: caseSensitive) { _ in scheduleSearch() }
        .onChange(of: wholeWord) { _ in scheduleSearch() }
        .onChange(of: isRegex) { _ in scheduleSearch() }
    }

    /// One of the three query-mode toggles (`Aa`, `ab`, `.*`), matching the
    /// editor bar's so the two read as the same control.
    private func toggle(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.primary)
        .help(help)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if root() == nil {
            placeholder("Open a folder to search in it.")
        } else if model.results.isEmpty {
            placeholder(emptyText)
        } else {
            List {
                ForEach(model.results, id: \.fileURL) { result in
                    Section {
                        ForEach(Array(result.matches.indices), id: \.self) { index in
                            row(result: result, index: index)
                        }
                    } header: {
                        Text(result.relativePath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.truncated {
                    Text("Results truncated — narrow the query or the file mask to see the rest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
    }

    /// One match: its line number and the clipped preview with the hit
    /// highlighted. A `Button` so a click activates it and keyboard focus can too.
    private func row(result: FileSearchResult, index: Int) -> some View {
        Button {
            onActivate(result.fileURL, result.matches[index].range)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(result.matches[index].lineNumber)")
                    .font(.system(size: settings.fontSize - 2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)

                Text(previewText(result.previews[index]))
                    .font(.system(size: settings.fontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The preview line with the match painted in the same colour the editor's
    /// current match uses, so a result row and the file it opens agree.
    private func previewText(_ preview: MatchPreview) -> AttributedString {
        let line = preview.text as NSString
        let full = NSRange(location: 0, length: line.length)
        let hit = NSIntersectionRange(preview.matchRange, full)
        guard hit.length > 0 else { return AttributedString(preview.text) }

        var result = AttributedString(line.substring(to: hit.location))
        var highlighted = AttributedString(line.substring(with: hit))
        highlighted.backgroundColor = Color(SyntaxTheme.shared.nsCurrentSearchMatchBackground)
        result.append(highlighted)
        result.append(AttributedString(line.substring(from: NSMaxRange(hit))))
        return result
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What to say when there are no rows: nothing typed yet, a search still
    /// running, a query not yet searched for, or one that genuinely matched
    /// nothing.
    ///
    /// "No results" is an *answer*, so it is only said once the empty list is one
    /// this project's own controls produced. Before that — inside the debounce
    /// window, or after a folder switch cleared the previous project's rows — the
    /// list is empty because nothing has been searched yet, and answering the
    /// question anyway would tell the user their project lacks a term nobody
    /// looked for.
    private var emptyText: String {
        if model.errorMessage != nil { return "" }
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type to search the project."
        }
        if model.isSearching { return "Searching…" }
        if !resultsMatchControls { return "Press Return to search." }
        return "No results"
    }

    /// The right-hand counter: matches and files, plus the truncation note.
    private var summaryText: String {
        guard !model.results.isEmpty else { return "" }
        let matches = model.results.reduce(0) { $0 + $1.matchCount }
        let files = model.results.count
        let suffix = model.truncated ? " (truncated)" : ""
        return "\(matches) match\(matches == 1 ? "" : "es") in \(files) file\(files == 1 ? "" : "s")\(suffix)"
    }

    // MARK: - Running the search

    /// Coalesce the query controls into one dispatched search — see the type-level
    /// note on why this one *is* debounced.
    private func scheduleSearch() {
        debounce.schedule(after: Self.searchDebounceDelay) { runSearch() }
    }

    /// The query the controls currently describe. Built in one place so the
    /// dispatched search and the staleness test below can never spell it
    /// differently.
    private var currentQuery: SearchQuery {
        SearchQuery(
            pattern: pattern,
            isRegex: isRegex,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord
        )
    }

    /// Whether the rows on screen were produced by the query now in the controls.
    ///
    /// False for the whole window between a keystroke and its search reaching the
    /// model — the ~300 ms debounce *plus* the `Task` hop `runSearch` dispatches
    /// through — during which `model.results` still describes the previous query.
    /// Everything that *acts* on those rows is refused until they agree: Enter
    /// would open a hit from a query the user has already moved on from, and
    /// Replace All would rewrite files across the whole project for it (the
    /// confirmation names counts, not the pattern, so it would not give the
    /// mistake away). The model records `query`/`fileMask` at the *start* of a
    /// search, having just cleared `results`, so a run still streaming its rows
    /// already reads as current — which is right, those rows are the new query's.
    ///
    /// **Clicking a row is deliberately exempt.** The two guarded acts above are
    /// ones where the user names no target — Enter takes "the first result",
    /// Replace All takes every file — so a stale list substitutes something they
    /// never pointed at. A click designates one visible row, which renders its own
    /// file, line number and preview line with the hit highlighted, and opens
    /// exactly that; the row's content is true regardless of which query produced
    /// it. Gating it would only make rows flicker between clickable and inert
    /// while typing, with a click in the dead window doing nothing and saying
    /// nothing.
    private var resultsMatchControls: Bool {
        model.query == currentQuery && model.fileMask == mask
    }

    private func runSearch() {
        guard let root = root() else { return }
        let query = currentQuery
        // Pin the request generation synchronously, before the `Task` hop: a
        // folder switch landing in the gap must reject this search rather than
        // walk the project the user just left (the `LocalChangesModel` rule).
        let request = model.currentRequestGeneration
        let mask = mask
        Task { await model.search(root: root, query: query, mask: mask, request: request) }
    }

    /// Enter in the query field: open the first result.
    ///
    /// While the rows still belong to the previous query — Enter pressed inside
    /// the debounce window, which is exactly what "type and hit Enter" does — the
    /// pending search is dispatched *now* instead, rather than opening a file the
    /// user never searched for. The next Enter, once the rows are the ones asked
    /// for, activates as usual.
    private func activateFirstResult() {
        guard resultsMatchControls else {
            debounce.cancel()
            runSearch()
            return
        }
        guard let first = model.results.first, let match = first.matches.first else { return }
        onActivate(first.fileURL, match.range)
    }

    // MARK: - Replace All

    /// Confirm the batch (it rewrites files the user cannot all see), then run it
    /// through the app's gated path, report the summary, and re-search — the
    /// captured results describe pre-replacement text.
    private func confirmReplaceAll() {
        // The button is disabled while the rows are stale; this is the backstop,
        // because the whole batch is built from those rows and a mismatch would
        // rewrite the project for the *previous* query.
        guard resultsMatchControls else { return }
        let matches = model.results.reduce(0) { $0 + $1.matchCount }
        let files = model.results.count
        guard matches > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace \(matches) match\(matches == 1 ? "" : "es")?"
        alert.informativeText =
            "\(matches) match\(matches == 1 ? "" : "es") in \(files) "
            + "file\(files == 1 ? "" : "s") will be replaced with "
            + "\"\(template)\". Files open in the editor are changed in their "
            // Deliberately not "and left unsaved": the buffer branch keeps the
            // tab's own unsaved edits, but autosave resumes the moment the batch
            // ends and writes those buffers like any other edit — promising the
            // user a chance to back out would be untrue.
            + "tabs (and autosaved like any other edit); the rest are written "
            + "to disk directly. This cannot be undone from here."
            // The batch replaces exactly the captured matches, so at the cap it
            // leaves the rest of the project half-replaced. That must be said
            // *here*: the confirmation is the only point where the user can still
            // decline, and neither the result list nor `ReplaceSummary` carries a
            // truncation signal, so afterwards a partial batch reads as complete.
            + (model.truncated
                ? " Only the first \(matches) matches were collected — the project "
                    + "contains more, so this replaces part of it. Narrow the query "
                    + "or mask and run it again for the rest."
                : "")
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isReplacing = true
        let template = template
        // Captured *before* the `Task` hop, and that is the whole point: the body
        // below runs on a later main-actor turn, so a folder switch landing in the
        // gap between this click and the batch actually starting would otherwise
        // rewrite the newly opened project with the previous one's results. The
        // model rejects a batch whose pin no longer matches.
        let origin = model.currentRootGeneration
        Task { @MainActor in
            defer { isReplacing = false }
            guard let summary = await onReplaceAll(template, origin) else { return }
            report(summary)
            runSearch()
        }
    }

    /// State the outcome plainly, including what was skipped or failed — a batch
    /// that quietly did less than it claimed would be worse than a slow one.
    private func report(_ summary: ReplaceSummary) {
        guard !summary.isEmpty else {
            PlatformAlert.presentMessage(
                title: "Nothing replaced",
                message: "No file still matched the results that were on screen."
            )
            return
        }
        var lines = [
            "Replaced \(summary.matchesReplaced) match"
            + "\(summary.matchesReplaced == 1 ? "" : "es") in \(summary.filesChanged) "
            + "file\(summary.filesChanged == 1 ? "" : "s")."
        ]
        if summary.filesSkipped > 0 {
            lines.append(
                "\(summary.filesSkipped) file\(summary.filesSkipped == 1 ? " was" : "s were") "
                + "skipped because they changed since the search ran."
            )
        }
        if !summary.errors.isEmpty {
            lines.append("Failed:\n" + summary.errors.joined(separator: "\n"))
        }
        // An abandoned batch stopped part-way, so the counts above are a partial
        // result, not the whole job. Saying so is the point: nothing rolls back,
        // and without this the report would read as complete.
        if summary.abandoned {
            lines.append(
                "The batch stopped early because the opened folder changed. "
                + "The remaining files were left untouched — reopen the project "
                + "and run the search again to finish."
            )
        }
        PlatformAlert.presentMessage(
            title: "Replace All",
            message: lines.joined(separator: "\n\n")
        )
    }
}

/// The Find in Files debounce: one pending `DispatchWorkItem`, replaced whenever a
/// newer keystroke arrives.
///
/// A tiny `ObservableObject` (publishing nothing) purely so the view can hold it
/// in a `@StateObject` — the pending item has to survive the view struct being
/// rebuilt on every keystroke, which `@State` on a class reference would not
/// guarantee across identity changes.
@MainActor
final class SearchDebounce: ObservableObject {
    private var pending: DispatchWorkItem?

    /// Run `action` after `delay`, cancelling whatever was pending.
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: action)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drop the pending dispatch (the window closed).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

#endif
