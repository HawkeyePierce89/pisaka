#if os(iOS)
import PisakaCore
import SwiftUI

/// The iOS problem browser: a screen pushed from `LeetCodeRoute_iOS`, showing the
/// catalog as a list the user searches, narrows and taps to open.
///
/// The peer of the macOS `LeetCodeBrowserView` window over the *same* Core model,
/// so the two platforms cannot disagree about what a query matches, when a fetch
/// happens or what opening a row does — only about the idioms that carry it. Here
/// those are `.searchable` for the query, a toolbar `Menu` for the two filter
/// dimensions, `.refreshable` for the explicit fetch and a `List` for the rows.
///
/// **It observes `LeetCodeBrowserModel`, not `LeetCodeModel`** — the companion
/// model's whole reason. Every keystroke in the search bar invalidates this view,
/// and observing the owner would put the account state, the statement and the
/// judge on that path.
///
/// **The owning model arrives non-observed**, a plain `let`, held for one thing
/// that is not rendering: the nested sign-in cover needs it, and that cover
/// observes it itself. Whether this screen shows a list or a sign-in offer comes
/// from `browser.availability`, which the owner's `isSignedIn` observer keeps
/// current.
///
/// **No cap and no truncation.** `List` is lazy, the rows are plain text, and
/// filtering the whole catalog is one pure pass in `LeetCodeProblemFilter`; the
/// unfiltered ~4000 rows are shown as they are. If a device ever says otherwise
/// the answer is a stated "keep typing to narrow" affordance, never a silent cut —
/// a list that quietly stops at row 500 tells the user problem 3000 does not
/// exist.
///
/// Thin and untested like the rest of `Sources/Pisaka`.
struct LeetCodeBrowserView_iOS: View {
    /// The browser's own state: the filter, the rows, the fetch time, the
    /// availability. The one thing observed here.
    @ObservedObject var browser: LeetCodeBrowserModel

    /// Shared preferences, for `leetCodeLanguage` alone: this screen offers no
    /// language picker of its own because the screen that pushed it does, and that
    /// setting is persisted — so a row opens in whatever language the last choice
    /// on either platform left current, and there is no second place to change it
    /// that could disagree.
    @ObservedObject var settings: SettingsStore

    /// The session owner. See the type's note for why this is not observed; it is
    /// here only to hand to the nested sign-in cover.
    var model: LeetCodeModel

    /// Open the problem a row names. Answers `nil` when it opened and otherwise the
    /// sentence to show — `LeetCodeRoute_iOS`'s contract, forwarded verbatim along
    /// with its handler, because **there is no second open path**: a tap here runs
    /// the same `openProblem` a typed slug does, with the same folder rules, the
    /// same Premium refusal and the same never-overwrite guarantee.
    var onOpen: (LeetCodeProblemInput, LeetCodeLanguage) async -> String?

    /// The outcome of the last open attempt, or `nil` before the first one.
    @State private var message: String?

    /// The slug being opened, or `nil` — the row's spinner and the guard against a
    /// second tap while the first is still out.
    @State private var openingSlug: String?

    /// The open in flight, held so leaving this screen can cancel it —
    /// `LeetCodeRoute_iOS.openTask`'s rule, for its reason: an unheld `Task`
    /// outlives the screen that started it and would push a tab for a file the user
    /// had already walked away from.
    @State private var openTask: Task<Void, Never>?

    /// Whether the sign-in web view is up over this screen.
    @State private var isSigningIn = false

    var body: some View {
        content
            .navigationTitle("Browse Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            // Keyed on availability so one rule covers both halves: the load on
            // appear, and the re-arm after a sign-in — which flips `availability`
            // through the owner's `isSignedIn` observer. Inside the catalog's
            // staleness window a `load()` costs no request at all.
            .task(id: browser.availability) {
                guard browser.availability.isReady else { return }
                await browser.load()
            }
            // The refusal from the last open ("that one is Premium") is about a
            // row, so it goes stale the moment the list under it does — the same
            // rule the macOS window follows, and the account screen's field
            // already does. Without this it led the list, in red, above rows it
            // no longer described until the *next* tap cleared it.
            .onChange(of: browser.filter) { _, _ in message = nil }
            .onDisappear {
                openTask?.cancel()
                openTask = nil
            }
            // Full screen rather than a sheet: a login page — especially an SSO
            // provider's, mid-redirect — is a full web page with its own scrolling
            // and keyboard. See `LeetCodeLoginView_iOS`.
            .fullScreenCover(isPresented: $isSigningIn) {
                LeetCodeLoginView_iOS(model: model, onDismiss: { isSigningIn = false })
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let reason = browser.availability.reason {
            signedOutOffer(reason)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            // Both sentences lead the list, and the failure one deliberately does
            // **not** live in the footer beside the count: the footer sits after
            // four thousand rows, so an error placed there is unreachable — a
            // pull-to-refresh that failed with the catalog on screen would leave
            // the screen looking untouched, which is the silent failure the
            // "keep the rows, publish the error beside them" rule exists to
            // avoid. The count and the fetch time stay below; they are a fact
            // about the list, not something the user has to be told.
            if message != nil || browser.lastError != nil {
                Section {
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let error = browser.lastError?.errorDescription {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                // `id: \.slug` rather than an `Identifiable` conformance:
                // `LeetCodeProblem` has no identity of its own outside a list, and
                // the slug is the key every request in this integration is already
                // made by.
                ForEach(browser.visibleProblems, id: \.slug) { problem in
                    Button { open(problem) } label: { row(problem) }
                        // Without this the whole row takes the accent colour and
                        // reads as one big link; the row is still fully tappable.
                        .buttonStyle(.plain)
                }
            } footer: {
                footer
            }
        }
        .listStyle(.plain)
        .searchable(
            text: $browser.filter.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Number, title or slug"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        // Pull to refresh *is* the explicit affordance here — the peer of the
        // macOS window's Refresh button, and the only way a solved mark from five
        // minutes ago reaches the screen (L24).
        .refreshable { await browser.refresh() }
        .overlay {
            if browser.visibleProblems.isEmpty, !browser.isLoading {
                Text(emptyLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private func row(_ problem: LeetCodeProblem) -> some View {
        HStack(spacing: 10) {
            Text("\(problem.frontendID)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 46, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(problem.title)
                        .lineLimit(1)
                    // Premium rows are always listed and can never be filtered
                    // out — hiding them would leave gaps in LeetCode's numbering
                    // that read as missing problems. The lock is what says the
                    // open will be refused before it is attempted.
                    if problem.isPaidOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("LeetCode Premium")
                    }
                }
                Text(LeetCodeBrowserView_iOS.title(for: problem.difficulty))
                    .font(.caption)
                    .foregroundStyle(LeetCodeBrowserView_iOS.color(for: problem.difficulty))
            }

            Spacer(minLength: 4)

            if openingSlug == problem.slug {
                ProgressView()
            } else {
                statusMark(problem.status)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusMark(_ status: LeetCodeProblemStatus) -> some View {
        switch status {
        case .solved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Solved")
        case .attempted:
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Attempted")
        case .notStarted:
            EmptyView()
        }
    }

    /// What a signed-out user gets **in place of the list**: LeetCode answers no
    /// catalog request without a session, so the offer to make one is the whole
    /// content of the screen — a value the browser publishes rather than an error
    /// this view has to invent a sentence for. The same offer the account row on
    /// the screen behind this one makes, so either is a way in.
    private func signedOutOffer(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In…") { isSigningIn = true }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filters

    /// Difficulty and status as one toolbar menu of toggles.
    ///
    /// Set membership with "empty means everything" (`LeetCodeProblemFilter`), so
    /// there is deliberately no "All" item: nothing selected and everything
    /// selected leave the same list, and a menu that offered both would imply they
    /// differ.
    private var filterMenu: some View {
        Menu {
            Section("Difficulty") {
                ForEach(LeetCodeDifficulty.allCases, id: \.self) { difficulty in
                    Toggle(
                        LeetCodeBrowserView_iOS.title(for: difficulty),
                        isOn: difficultyBinding(difficulty)
                    )
                }
            }
            Section("Status") {
                ForEach(LeetCodeProblemStatus.allCases, id: \.self) { status in
                    Toggle(
                        LeetCodeBrowserView_iOS.title(for: status),
                        isOn: statusBinding(status)
                    )
                }
            }
            if !browser.filter.isEmpty {
                Section {
                    Button("Clear Filters") { browser.filter = LeetCodeProblemFilter() }
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: browser.filter.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
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

    // MARK: - The footer

    /// "Showing X of Y" and the fetch time. The last failure is **not** here — it
    /// leads the list instead, for the reason written where it does.
    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(countLine)
            // Freshness is the catalog's fetch time, so the surface says so rather
            // than pretending the per-account marks are live (L24).
            if let fetchedAt = browser.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countLine: String {
        let total = browser.problems.count
        let shown = browser.visibleProblems.count
        if total == 0 { return browser.isLoading ? "Loading…" : "No problems loaded." }
        return "Showing \(shown) of \(total)"
    }

    /// The two different empty states: a filter that matches nothing is not the
    /// same problem as a list that has nothing in it, which is what
    /// `LeetCodeProblemFilter.isEmpty` exists to tell apart.
    private var emptyLine: String {
        if browser.problems.isEmpty {
            return browser.lastError == nil
                ? "No problems loaded. Pull down to refresh."
                : "The problem list could not be loaded."
        }
        return "No problems match the filter."
    }

    // MARK: - Opening

    /// Hand the row's slug to the route's one open handler and show whatever it
    /// answers.
    ///
    /// `.slug(_:)` rather than the number: the catalog row already carries the slug
    /// every detail request is made by, so this costs no resolution step — and it
    /// is the same input a typed slug produces, through the same handler.
    ///
    /// **Nothing is dismissed from here**, which is `LeetCodeRoute_iOS.open()`'s
    /// rule and for a reason this screen makes sharper: `nil` is the answer to
    /// three different questions — it opened, the user left mid-open (`onDisappear`
    /// cancels `openTask`), or a newer open superseded this one — and only the
    /// first of them wants the sheet down. The handler takes it down itself on
    /// that one, so taking it down here as well would close the whole LeetCode
    /// screen out from under somebody who had just tapped Back.
    ///
    /// A sentence — "that one is Premium", "no problem matching that" — is shown
    /// inline instead, for `LeetCodeRoute_iOS`'s reason: an alert stacked on the
    /// screen the user is looking at makes a refusal look like a failure.
    private func open(_ problem: LeetCodeProblem) {
        guard openingSlug == nil else { return }
        message = nil
        openingSlug = problem.slug
        let language = settings.leetCodeLanguage
        openTask = Task {
            let outcome = await onOpen(.slug(problem.slug), language)
            openingSlug = nil
            message = outcome
        }
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
