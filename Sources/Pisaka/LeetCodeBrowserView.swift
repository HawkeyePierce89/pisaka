#if os(macOS)
import PisakaCore
import SwiftUI

/// The LeetCode problem browser window's contents (⌘⇧B): the search field and
/// filter controls at the top, the problem rows below, the fetch time and
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
/// the owner's `account` observer keeps current — so nothing here has to watch
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
    @State private var selection: String?

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

    /// The interface zone's metrics. Computed from the store rather than read from
    /// the environment because this view is the *root* of its own window and
    /// injects the value below — an environment write reaches descendants, not the
    /// view that makes it.
    private var metrics: InterfaceMetrics { settings.interfaceMetrics }

    @Environment(\.colorScheme) private var colorScheme

    /// Where the keyboard is: the query field, or the row list — the list is one
    /// focusable container, so the arrows and Return act on the selection only
    /// while it holds focus.
    @FocusState private var focus: BrowserFocus?

    private enum BrowserFocus: Hashable {
        case query
        case list
    }

    /// This view is a window root: it injects the theme below, so it resolves its
    /// own colours from the settings rather than reading `\.chromeTheme`, the
    /// shape `ContentView` and the other window roots use. A child that wants the
    /// environment — `LeetCodeBrowserRow` — is declared at file scope, never
    /// inside this struct.
    private func chromeColor(_ role: ChromeColorRole) -> Color {
        settings.chromeTheme(systemPrefersDark: colorScheme == .dark).color(role)
    }

    /// The one-point rule drawn where a `Divider()` used to stand.
    private func hairline(horizontal: Bool) -> some View {
        Rectangle()
            .fill(chromeColor(.hairline))
            .frame(
                width: horizontal ? nil : metrics.scaled(ChromeGeometry.hairlineWidth),
                height: horizontal ? metrics.scaled(ChromeGeometry.hairlineWidth) : nil
            )
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            hairline(horizontal: true)
            content
            hairline(horizontal: true)
            footer
        }
        .frame(minWidth: metrics.scaled(620), minHeight: metrics.scaled(380))
        .background(chromeColor(.bgPanel))
        .preferredColorScheme(settings.themePreference.colorScheme)
        // Its own SwiftUI root (an `NSHostingController` made by
        // `LeetCodeBrowserWindowController`), so it injects the interface scale
        // itself; the rows and controls above adopt it with the rest of the
        // LeetCode surfaces.
        .interfaceScaled(settings)
        .chromeThemed(settings)
        // Keyed on `loadKey` so this covers every half with one rule: the load on
        // appear, the re-arm after a sign-in that flips `availability`, and the
        // re-arm after a session *replacement*, which clears the rows while
        // leaving `availability` exactly where it was — the case availability
        // alone cannot see, and the reason that key is a pair. Inside the
        // catalog's staleness window a `load()` costs no request at all, which is
        // what makes re-entering the window free.
        // **Unconditional on purpose: the availability test belongs to
        // `update(forced:)`, not here.** A model built before the account is
        // resolved starts `.notSignedIn` (`LeetCodeBrowserModel.init` reads
        // `owner.isSignedIn`, which an unresolved model answers `false`), and
        // `load()` is what resolves it — so a guard on `availability.isReady`
        // deadlocks the one path that could lift it, leaving ⌘⇧B on a cold run
        // showing the sign-in offer for a stored session it never read. Core
        // already answers the signed-out case without a request: `update`
        // publishes `.notSignedIn` and returns before it suspends.
        .task(id: browser.loadKey) {
            await browser.load()
        }
        // **The selection has to be pruned, because SwiftUI keeps one whose row is
        // gone.** `selection` is a slug, and both narrowing the filter and a
        // landed refresh can take that row out of the list — leaving Open enabled
        // and opening a problem the user cannot see and did not mean, which on
        // this route creates a file. Keyed on the two things that can change the
        // visible set rather than on `visibleProblems` itself, whose equality
        // check is four thousand rows on every body evaluation.
        // The refusal from the last open ("that one is Premium") is about a row,
        // so it goes stale the moment the list under it does — the Open Problem
        // sheet clears its sentence on every edit of the field for the same
        // reason. Without this it sat in red above a list it no longer described
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
            // Injected on the content, because this presentation is attached
            // *after* the root's own `.interfaceScaled(settings)` above and so
            // sits outside it: a modifier applied later in a chain wraps the
            // environment write rather than descending from it. Scaled here, the
            // sign-in sheet matches the window it is raised over instead of
            // arriving at 100% on top of a browser at 200%.
            .interfaceScaled(settings)
            .chromeThemed(settings)
        }
    }

    // MARK: - The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            HStack(spacing: metrics.scaled(8)) {
                ChromeThemedTextField(
                    title: "Number, title or slug",
                    text: $browser.filter.query,
                    glyph: "magnifyingglass",
                    focus: $focus,
                    focusedEquals: .query,
                    textStyle: .body
                )
                .frame(maxWidth: metrics.scaled(320))
                .frame(height: metrics.scaled(LeetCodeBrowserLayout.queryFieldHeight))

                // A run-time list of languages, so the picker rule answers the
                // menu field — the Settings problem-catalog tab's answer over
                // the same list.
                ChromeMenuField(
                    label: "Language",
                    options: LeetCodeSolutionFile.offerableLanguages.map { (value: $0, title: $0.displayName) },
                    selection: $settings.leetCodeLanguage,
                    currentTitle: settings.leetCodeLanguage.displayName
                )
                .frame(maxWidth: metrics.scaled(220))
                .frame(height: metrics.scaled(ChromeGeometry.menuFieldHeight))
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: metrics.scaled(4))

                Button("Open") { open(slug: selection) }
                    .buttonStyle(.chromeSecondary)
                    .disabled(selection == nil || isOpening)
            }

            HStack(spacing: metrics.scaled(12)) {
                // Set membership, and an empty set means no filtering — so these
                // checkboxes need no "All" case: nothing selected and everything
                // selected are the same list, which is what `LeetCodeProblemFilter`
                // documents. Each case is independently in or out, an option of
                // one action, so the picker rule answers the checkbox.
                HStack(spacing: metrics.scaled(12)) {
                    ForEach(LeetCodeDifficulty.allCases, id: \.self) { difficulty in
                        filterCheckbox(
                            title: LeetCodeBrowserView.title(for: difficulty),
                            isOn: difficultyBinding(difficulty)
                        )
                    }
                }

                hairline(horizontal: false)
                    .frame(height: metrics.scaled(16))

                HStack(spacing: metrics.scaled(12)) {
                    ForEach(LeetCodeProblemStatus.allCases, id: \.self) { status in
                        filterCheckbox(
                            title: LeetCodeBrowserView.title(for: status),
                            isOn: statusBinding(status)
                        )
                    }
                }

                Spacer(minLength: metrics.scaled(4))
            }

            if let message {
                Text(message)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(chromeColor(.statusRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(metrics.scaled(10))
    }

    /// One filter case as the shared checkbox over its existing binding.
    private func filterCheckbox(title: String, isOn: Binding<Bool>) -> some View {
        ChromeCheckbox(
            state: isOn.wrappedValue ? .on : .off,
            label: title,
            title: title,
            action: { isOn.wrappedValue.toggle() }
        )
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if let reason = browser.availability.reason {
            signedOutOffer(reason)
        } else {
            problemList
        }
    }

    /// What a signed-out user gets **in place of the list**: LeetCode answers no
    /// catalog request without a session, so the offer to make one is the whole
    /// content of the window — a value the browser publishes rather than an error
    /// this view has to invent a sentence for.
    private func signedOutOffer(_ reason: String) -> some View {
        VStack(spacing: metrics.scaled(12)) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: metrics.scaled(28)))
                .foregroundStyle(chromeColor(.textSecondary))
                .accessibilityHidden(true)
            Text(reason)
                .foregroundStyle(chromeColor(.textSecondary))
            Button("Sign In…") { isSigningIn = true }
                .buttonStyle(.chromeSecondary)
        }
        .font(metrics.scaledFont(.body))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The problem rows: the chrome's own, on the Log's row shape rather than a
    /// platform table. There is no per-column drag resize — the Log has none
    /// either — so the number, difficulty and status columns take fixed widths
    /// and the title takes the rest.
    ///
    /// **The list is one focusable container.** Up and down move the selection
    /// (kept on screen by the reader), and Return opens it through a zero-sized
    /// shortcut button enabled only while the list holds focus — the database
    /// grid's Return idiom, since a key-press handler is newer than this target.
    /// A click selects and takes focus, a double-click opens, and the row's
    /// context menu offers Open; the Open button above stays the fourth way in.
    /// Below the last row, a click clears the selection and a right-click offers
    /// Open for it, as the platform table did.
    private var problemList: some View {
        VStack(spacing: 0) {
            columnHeader
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(browser.visibleProblems, id: \.slug) { problem in
                                LeetCodeBrowserRow(
                                    problem: problem,
                                    isSelected: selection == problem.slug,
                                    onSelect: {
                                        selection = problem.slug
                                        focus = .list
                                    },
                                    onOpen: { open(slug: problem.slug) }
                                )
                                .id(problem.slug)
                            }
                        }
                        .frame(minHeight: viewport.size.height, alignment: .top)
                        // The area below the last row, standing in for what the
                        // platform table gave it: a plain click clears the
                        // selection, and a right-click offers Open for the
                        // current selection — nothing at all when there is none.
                        // It sits *behind* the rows, stretched to the viewport by
                        // the frame above, so a row's own click and menu win
                        // wherever there is a row and this answers only where
                        // there is not. Its Open is the same `open(slug:)` every
                        // other way in reaches.
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = nil
                                    focus = .list
                                }
                                .contextMenu {
                                    if let selection {
                                        Button("Open") { open(slug: selection) }
                                    }
                                }
                        }
                    }
                }
                .focusable()
                .focused($focus, equals: .list)
                .onMoveCommand { direction in
                    moveSelection(direction)
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            returnOpensTheSelectedRow
        }
    }

    /// The four column titles over the rows, on the panel ground with its
    /// hairline applied before that ground, so the rule lands over the fill and
    /// under the titles rather than hidden behind it. They read the rows' own widths,
    /// so each title sits over the column it names; non-interactive, since there
    /// is no sorting.
    private var columnHeader: some View {
        HStack(spacing: metrics.scaled(LeetCodeBrowserLayout.columnGap)) {
            columnTitle("#")
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.numberWidth), alignment: .leading)
            columnTitle("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle("Difficulty")
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.difficultyWidth), alignment: .leading)
            columnTitle("Status")
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.statusWidth), alignment: .leading)
        }
        .padding(.horizontal, metrics.scaled(LeetCodeBrowserLayout.rowPaddingX))
        .frame(height: metrics.scaled(LeetCodeBrowserLayout.headerRowHeight))
        .background(alignment: .bottom) { hairline(horizontal: true) }
        .background(chromeColor(.bgPanel))
        .allowsHitTesting(false)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(metrics.scaledFont(.subheadline, weight: .semibold))
            .foregroundStyle(chromeColor(.textSecondary))
            .lineLimit(1)
    }

    /// Return opens the selected row while the list holds the keyboard. Zero
    /// sized and hidden from accessibility: the row's own named Open action is
    /// what an assistive reader is offered.
    private var returnOpensTheSelectedRow: some View {
        Button("Open Selected Problem") { open(slug: selection) }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(focus != .list || selection == nil || isOpening)
            .accessibilityHidden(true)
    }

    // MARK: - The footer

    private var footer: some View {
        HStack(spacing: metrics.scaled(10)) {
            Text(countLine)
                .foregroundStyle(chromeColor(.textSecondary))

            if let error = browser.lastError?.errorDescription {
                // Beside the rows rather than instead of them: a refresh that
                // could not be made keeps whatever list is on screen, which is the
                // degradation rule `LeetCodeBrowserModel` implements and this line
                // reports.
                Text(error)
                    .foregroundStyle(chromeColor(.statusRed))
                    .lineLimit(1)
                    .help(error)
            }

            Spacer(minLength: metrics.scaled(4))

            if browser.isLoading || isOpening {
                // An open names no activity beside it, and "Loading…" is the empty
                // list's sentence alone — a loaded list's count line names none —
                // so the spinner says what it is doing itself.
                ChromeSpinner()
                    .accessibilityLabel(isOpening ? "Opening problem" : "Loading problems")
            }

            // Freshness is the catalog's fetch time, so the surface says so
            // rather than pretending the per-account marks are live (L24).
            if let fetchedAt = browser.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(chromeColor(.textSecondary))
            }

            Button("Refresh") {
                Task { await browser.refresh() }
            }
            .buttonStyle(.chromeSecondary)
            .disabled(browser.isLoading || !browser.availability.isReady)
        }
        .font(metrics.scaledFont(.caption))
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
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

    /// Drop a selection the list is no longer showing. See the two `onChange`
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

    /// Move the selection one row up or down the visible list, starting from
    /// the first row when nothing is selected. Left and right are ignored.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let visible = browser.visibleProblems
        guard !visible.isEmpty else { return }
        let current = selection.flatMap { slug in visible.firstIndex { $0.slug == slug } }
        let next: Int
        switch direction {
        case .down: next = current.map { min($0 + 1, visible.count - 1) } ?? 0
        case .up: next = current.map { max($0 - 1, 0) } ?? 0
        default: return
        }
        selection = visible[next].slug
    }

    // MARK: - Filter bindings

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

    fileprivate static func title(for difficulty: LeetCodeDifficulty) -> String {
        switch difficulty {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    fileprivate static func title(for status: LeetCodeProblemStatus) -> String {
        switch status {
        case .notStarted: return "Not Started"
        case .attempted: return "Attempted"
        case .solved: return "Solved"
        }
    }
}

/// The browser's own measurements, bare numbers scaled once at the use site. The
/// rows and the column header read the same widths, which is what keeps each
/// title over its column (gating rule seven: none is derived from a
/// `ChromeGeometry` token). The three fixed widths are the old table's ideal
/// widths.
private enum LeetCodeBrowserLayout {
    /// A problem row's minimum height.
    static let rowHeight: Double = 24
    /// The column header row's height.
    static let headerRowHeight: Double = 24
    /// A row's and the header's horizontal inset.
    static let rowPaddingX: Double = 10
    /// Between a row's columns (and the header's titles).
    static let columnGap: Double = 12
    /// Between the title and its Premium lock.
    static let lockGap: Double = 6
    /// The number column.
    static let numberWidth: Double = 56
    /// The difficulty column.
    static let difficultyWidth: Double = 88
    /// The status column.
    static let statusWidth: Double = 96
    /// The query field's height. The same 26 as the menu field it shares the
    /// toolbar row with, so the two line up — but this surface's number, not
    /// `ChromeGeometry.menuFieldHeight`, which sizes the menu fields alone.
    static let queryFieldHeight: Double = 26
}

/// One problem row: the number, the title with its Premium lock, the difficulty
/// and the status, each coloured by Core's one answer.
///
/// The Log's row shape: the selection wash is `accentTintStrong` whether or not
/// the window is key, and the pointer's is `hoverTint`. One combined
/// accessibility element carrying the selected trait and a named Open action,
/// so an assistive reader reaches the open without a double-click.
private struct LeetCodeBrowserRow: View {
    let problem: LeetCodeProblem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(LeetCodeBrowserLayout.columnGap)) {
            Text("\(problem.frontendID)")
                .monospacedDigit()
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.numberWidth), alignment: .leading)

            HStack(spacing: metrics.scaled(LeetCodeBrowserLayout.lockGap)) {
                Text(problem.title)
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                // Premium rows are always listed and can never be filtered
                // out — hiding them would leave gaps in LeetCode's numbering
                // that read as missing problems. The lock is what says the
                // open will be refused before it is attempted.
                if problem.isPaidOnly {
                    Image(systemName: "lock.fill")
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(theme.color(.textSecondary))
                        .help("LeetCode Premium")
                        .accessibilityLabel("LeetCode Premium")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(LeetCodeBrowserView.title(for: problem.difficulty))
                .foregroundStyle(theme.color(.difficultyRole(for: problem.difficulty)))
                .lineLimit(1)
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.difficultyWidth), alignment: .leading)

            statusCell
                .foregroundStyle(theme.color(.problemStatusRole(for: problem.status)))
                .lineLimit(1)
                .frame(width: metrics.scaled(LeetCodeBrowserLayout.statusWidth), alignment: .leading)
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(LeetCodeBrowserLayout.rowPaddingX))
        .frame(maxWidth: .infinity, minHeight: metrics.scaled(LeetCodeBrowserLayout.rowHeight), alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { onOpen() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Open", onOpen)
    }

    /// The status's glyph and words; its colour is Core's, applied by the row.
    @ViewBuilder
    private var statusCell: some View {
        switch problem.status {
        case .solved:
            Label("Solved", systemImage: "checkmark.circle.fill")
                .font(metrics.scaledFont(.body))
        case .attempted:
            Label("Attempted", systemImage: "ellipsis.circle")
                .font(metrics.scaledFont(.body))
        case .notStarted:
            Text("—")
        }
    }

    private var rowBackground: Color {
        if isSelected { return theme.color(.accentTintStrong) }
        if isHovering { return theme.color(.hoverTint) }
        return .clear
    }
}

#endif
