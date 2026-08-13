#if os(macOS)
import PisakaCore
import SwiftUI

/// The LeetCode problem browser window's contents (⌘⇧B): the search field and
/// filter controls at the top, the problem table below, the fetch time and
/// Refresh in the footer.
///
/// **It observes `LeetCodeBrowserModel`, not `LeetCodeModel`.** That is the whole
/// reason the browser is a companion model rather than more members on its owner:
/// this view binds a text field to `browser.filter.query`, so it re-renders on
/// every keystroke in the search field — and observing the owner would put the
/// account state, the statement and the judge on that path (the argument
/// `LeetCodeJudgeSection` already makes on its own axis).
///
/// **The owning model arrives deliberately non-observed.** `model` is a plain
/// `let`, held for two things that are not rendering: the nested
/// `LeetCodeLoginView` needs it, and that sheet observes it itself. Whether this
/// view shows a list or a sign-in offer comes from `browser.availability`, which
/// the owner's `isSignedIn` observer keeps current — so nothing here has to watch
/// the model to stay right.
///
/// Thin and untested like the rest of `Sources/Pisaka`. Every decision is Core's:
/// what a query matches is `LeetCodeProblemFilter`, when a fetch happens is
/// `LeetCodeCatalog`'s staleness policy through `LeetCodeBrowserModel`, and what
/// opening a row *does* is `LeetCodeModel.openProblem` — reached through the same
/// `PisakaApp` handler the Open Problem sheet uses, because **there is no second
/// open path**.
struct LeetCodeBrowserView: View {
    /// The browser's own state: the filter, the rows, the fetch time, the
    /// availability. The one thing observed here.
    @ObservedObject var browser: LeetCodeBrowserModel

    /// Shared preferences: the language picker is bound straight to
    /// `leetCodeLanguage` — the *same* persisted setting the Open Problem sheet
    /// writes, so the two surfaces cannot disagree about which language the next
    /// solution file is seeded in — and a forced Light/Dark theme has to reach
    /// this separate window like it does the diff and merge ones.
    @ObservedObject var settings: SettingsStore

    /// The session owner. See the type's note for why this is not observed;
    /// it exists here only to hand to the nested sign-in sheet.
    var model: LeetCodeModel

    /// Open the problem a row names. Answers `nil` when it opened and otherwise
    /// the sentence to show in the window — the Open Problem sheet's contract,
    /// reused verbatim along with its handler.
    ///
    /// A sentence rather than an alert, for the sheet's reason: this window *is*
    /// the surface the user is looking at, and a modal alert to say "that one is
    /// Premium" would make a refusal look like a failure.
    var onOpen: (LeetCodeProblemInput, LeetCodeLanguage) async -> String?

    /// The selected row's slug, or `nil`. Single selection: the Open button acts
    /// on one problem and a double-click names one.
    @State private var selection: Row.ID?

    /// The outcome of the last open attempt, or `nil` before the first one.
    @State private var message: String?

    /// The open in flight, held so closing the window can cancel it —
    /// `LeetCodeOpenProblemSheet.openTask`'s rule on this surface. An unheld
    /// `Task` outlives the window that started it and would leave `isOpening`
    /// raised on the next one.
    @State private var openTask: Task<Void, Never>?

    /// Whether an open is running, so the controls can say so and a second one
    /// cannot be started under it.
    @State private var isOpening = false

    /// Whether the sign-in web view is up **over this window**, presented from
    /// here for `LeetCodeOpenProblemSheet`'s reason: raising it from the app's
    /// shared presentation slot would put it on the editor window instead, where
    /// the user who pressed the button in *this* window is not looking.
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 380)
        .preferredColorScheme(settings.themePreference.colorScheme)
        // Keyed on availability so this covers both halves with one rule: the
        // load on appear, and the re-arm after a sign-in — which flips
        // `availability` through the owner's `isSignedIn` observer. Inside the
        // catalog's staleness window a `load()` costs no request at all, which is
        // what makes re-entering the window free.
        .task(id: browser.availability) {
            guard browser.availability.isReady else { return }
            await browser.load()
        }
        // **The selection has to be pruned, because SwiftUI keeps one whose row is
        // gone.** `selection` is a slug, and both narrowing the filter and a
        // landed refresh can take that row out of the table — leaving Open enabled
        // and opening a problem the user cannot see and did not mean, which on
        // this route creates a file. Keyed on the two things that can change the
        // visible set rather than on `visibleProblems` itself, whose equality
        // check is four thousand rows on every body evaluation.
        // The refusal from the last open ("that one is Premium") is about a row,
        // so it goes stale the moment the list under it does — the Open Problem
        // sheet clears its sentence on every edit of the field for the same
        // reason. Without this it sat in red above a table it no longer described
        // until the *next* open cleared it.
        .onChange(of: browser.filter) { _ in
            pruneSelection()
            message = nil
        }
        .onChange(of: browser.fetchedAt) { _ in pruneSelection() }
        .onDisappear {
            openTask?.cancel()
            openTask = nil
        }
        .sheet(isPresented: $isSigningIn) {
            LeetCodeLoginView(
                model: model,
                onDismiss: { isSigningIn = false },
                // This window's own sentence line, not an alert: it is back in
                // front of the user the moment the login sheet goes down, and it
                // is where every other refusal in this flow is already reported.
                onFailure: { message = $0.errorDescription }
            )
        }
    }

    // MARK: - The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Number, title or slug",
                    text: $browser.filter.query
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

                Picker("Language", selection: $settings.leetCodeLanguage) {
                    ForEach(LeetCodeSolutionFile.offerableLanguages, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .frame(maxWidth: 220)

                Spacer(minLength: 4)

                Button("Open") { open(slug: selection) }
                    .disabled(selection == nil || isOpening)
            }

            HStack(spacing: 12) {
                // Set membership, and an empty set means no filtering — so these
                // toggles need no "All" case: nothing selected and everything
                // selected are the same list, which is what `LeetCodeProblemFilter`
                // documents.
                HStack(spacing: 4) {
                    ForEach(LeetCodeDifficulty.allCases, id: \.self) { difficulty in
                        Toggle(
                            LeetCodeBrowserView.title(for: difficulty),
                            isOn: difficultyBinding(difficulty)
                        )
                        .toggleStyle(.button)
                    }
                }

                Divider()
                    .frame(height: 16)

                HStack(spacing: 4) {
                    ForEach(LeetCodeProblemStatus.allCases, id: \.self) { status in
                        Toggle(
                            LeetCodeBrowserView.title(for: status),
                            isOn: statusBinding(status)
                        )
                        .toggleStyle(.button)
                    }
                }

                Spacer(minLength: 4)
            }
            .font(.callout)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let reason = browser.availability.reason {
            signedOutOffer(reason)
        } else {
            table
        }
    }

    /// What a signed-out user gets **in place of the list**: LeetCode answers no
    /// catalog request without a session, so the offer to make one is the whole
    /// content of the window — a value the browser publishes rather than an error
    /// this view has to invent a sentence for.
    private func signedOutOffer(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(reason)
                .foregroundStyle(.secondary)
            Button("Sign In…") { isSigningIn = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("#") { row in
                Text("\(row.problem.frontendID)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 56, max: 90)

            TableColumn("Title") { row in
                HStack(spacing: 6) {
                    Text(row.problem.title)
                        .lineLimit(1)
                    // Premium rows are always listed and can never be filtered
                    // out — hiding them would leave gaps in LeetCode's numbering
                    // that read as missing problems. The lock is what says the
                    // open will be refused before it is attempted.
                    if row.problem.isPaidOnly {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("LeetCode Premium")
                    }
                }
            }

            TableColumn("Difficulty") { row in
                Text(LeetCodeBrowserView.title(for: row.problem.difficulty))
                    .foregroundStyle(LeetCodeBrowserView.color(for: row.problem.difficulty))
            }
            .width(min: 72, ideal: 88, max: 120)

            TableColumn("Status") { row in
                statusCell(row.problem.status)
            }
            .width(min: 72, ideal: 96, max: 140)
        }
        // Double-click opens (`primaryAction`), and the same action is in the
        // row's context menu — the explicit Open button above is the third way in,
        // for a user who reached the row with the keyboard.
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            Button("Open") { open(slug: ids.first ?? selection) }
        } primaryAction: { ids in
            open(slug: ids.first)
        }
    }

    @ViewBuilder
    private func statusCell(_ status: LeetCodeProblemStatus) -> some View {
        switch status {
        case .solved:
            Label("Solved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .attempted:
            Label("Attempted", systemImage: "ellipsis.circle")
                .foregroundStyle(.orange)
        case .notStarted:
            Text("—")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(countLine)
                .foregroundStyle(.secondary)

            if let error = browser.lastError?.errorDescription {
                // Beside the rows rather than instead of them: a refresh that
                // could not be made keeps whatever list is on screen, which is the
                // degradation rule `LeetCodeBrowserModel` implements and this line
                // reports.
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }

            Spacer(minLength: 4)

            if browser.isLoading || isOpening {
                ProgressView()
                    .controlSize(.small)
            }

            // Freshness is the catalog's fetch time, so the surface says so
            // rather than pretending the per-account marks are live (L24).
            if let fetchedAt = browser.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }

            Button("Refresh") {
                Task { await browser.refresh() }
            }
            .disabled(browser.isLoading || !browser.availability.isReady)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// "Showing X of Y", or the two different empty sentences: a filter that
    /// matches nothing is not the same problem as a list that has nothing in it,
    /// which is what `LeetCodeProblemFilter.isEmpty` exists to tell apart.
    private var countLine: String {
        let total = browser.problems.count
        let shown = browser.visibleProblems.count
        if total == 0 { return browser.isLoading ? "Loading…" : "No problems loaded." }
        if shown == 0 { return "No problems match the filter (\(total) loaded)." }
        return "Showing \(shown) of \(total)"
    }

    // MARK: - Opening

    /// Drop a selection the table is no longer showing. See the two `onChange`
    /// hooks on `body`.
    private func pruneSelection() {
        guard let slug = selection else { return }
        if !browser.visibleProblems.contains(where: { $0.slug == slug }) {
            selection = nil
        }
    }

    /// Hand the row's slug to the app's one open handler and show whatever it
    /// answers.
    ///
    /// `.slug(_:)` rather than the number: the catalog row already carries the
    /// slug every detail request is made by, so this costs no resolution step —
    /// and it is the same input the Open Problem sheet produces for a typed slug,
    /// through the same handler, so the folder rules, the Premium refusal and the
    /// never-overwrite guarantee are LC-1's rather than restated here.
    ///
    /// **The window stays open.** Browsing several problems in a row is the point,
    /// so the app raises the editor window *behind* this one instead of taking it
    /// down.
    private func open(slug: String?) {
        guard let slug, !isOpening else { return }
        message = nil
        isOpening = true
        let language = settings.leetCodeLanguage
        openTask = Task {
            let outcome = await onOpen(.slug(slug), language)
            // The window may have gone while this ran; assigning to `@State` on a
            // view that is gone is a no-op, but the flag has to come down for the
            // window that is still here.
            message = outcome
            isOpening = false
        }
    }

    // MARK: - Filter bindings

    /// The rows the table renders.
    ///
    /// A view-layer wrapper for its `Identifiable` conformance alone: `Table`
    /// requires one, and `LeetCodeProblem` has no identity of its own to speak of
    /// outside a list (the iOS screen uses `id: \.slug` for the same reason). The
    /// map is one pass over the *visible* rows — the same order of work the filter
    /// that produced them already did.
    private var rows: [Row] {
        browser.visibleProblems.map(Row.init)
    }

    private struct Row: Identifiable {
        let problem: LeetCodeProblem
        var id: String { problem.slug }
    }

    private func difficultyBinding(_ difficulty: LeetCodeDifficulty) -> Binding<Bool> {
        Binding(
            get: { browser.filter.difficulties.contains(difficulty) },
            set: { isOn in
                if isOn {
                    browser.filter.difficulties.insert(difficulty)
                } else {
                    browser.filter.difficulties.remove(difficulty)
                }
            }
        )
    }

    private func statusBinding(_ status: LeetCodeProblemStatus) -> Binding<Bool> {
        Binding(
            get: { browser.filter.statuses.contains(status) },
            set: { isOn in
                if isOn {
                    browser.filter.statuses.insert(status)
                } else {
                    browser.filter.statuses.remove(status)
                }
            }
        )
    }

    // MARK: - Presentation

    private static func title(for difficulty: LeetCodeDifficulty) -> String {
        switch difficulty {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    private static func color(for difficulty: LeetCodeDifficulty) -> Color {
        switch difficulty {
        case .easy: return .green
        case .medium: return .orange
        case .hard: return .red
        }
    }

    private static func title(for status: LeetCodeProblemStatus) -> String {
        switch status {
        case .notStarted: return "Not Started"
        case .attempted: return "Attempted"
        case .solved: return "Solved"
        }
    }
}

#endif
