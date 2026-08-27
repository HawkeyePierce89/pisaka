#if os(macOS)
import SwiftUI
import PisakaCore

/// The Log view's filter/search bar, shown above the commit table.
///
/// A thin, untested view (per project convention): it mirrors the server-side
/// `LogFilter` plus the client-side message search. The server-side dimensions
/// live in a single `LogFilterDraft` value; the message search lives in its own
/// `search` string because it is not a `LogFilter` dimension. The draft is the
/// single editable value so seeding a model-published filter can update every
/// control silently: `seed(from:)` assigns the draft directly and is therefore
/// structurally unable to reach the apply path, which lives only in user-intent
/// binding setters (and `onSubmit`). **A change handler seeds from its
/// parameter**, never from the view's own stored property: `filter` and
/// `searchQuery` are plain `let`s of this view value, and macOS 13's only
/// `onChange` overload runs the closure captured *before* the change, so off
/// `self` they still hold the *previous* value — re-reading them seeds the bar
/// one publish behind forever and the next apply, assembled from the lagging
/// draft, writes the stale state back. (`@State` and `@ObservedObject` reads are
/// live even there, resolving through their storage rather than the captured
/// view value; only plain stored properties are at risk.) `onAppear` is the one
/// exception, because at appearance the properties are current. The server-side dimensions
/// are reported via `onApplyFilter` (generation-guarded re-fetch); the message
/// search is reported live via `onSearch` (client-side filter, no re-query).
/// All decision logic
/// (trimming, day-boundary normalization, verbatim ref preservation, tag mapping)
/// lives in `PisakaCore.LogFilterDraft`.
struct LogFilterBar: View {
    /// The branch/tag refs offered in the ref picker — **full** refnames (e.g.
    /// `refs/heads/main`, `refs/tags/v1.0`) sourced from the service. The full name
    /// is the picker's *value* (the unambiguous revision `git log` receives), while
    /// `shortLabel(for:)` derives the user-facing display: a branch `v1.0` and a tag
    /// `v1.0` would collapse to one ambiguous short name, but their full refnames
    /// stay distinct so git resolves exactly the one chosen.
    let references: [String]
    /// The current server-side filter, used to seed the draft on appearance and
    /// to re-seed it when the model re-publishes (e.g. a folder switch).
    let filter: LogFilter
    /// The current search query, used to seed the search field.
    let searchQuery: String
    /// Apply a rebuilt server-side filter (triggers a re-fetch in the owner).
    let onApplyFilter: (LogFilter) -> Void
    /// Report a new client-side message-search query (no re-fetch).
    let onSearch: (String) -> Void

    // The single editable server-side value plus the separate message search.
    // Seeding assigns these directly, so a model-published filter/search change
    // cannot masquerade as a user edit — every apply lives in a user-intent
    // binding setter or an explicit `onSubmit`, and is handed the new value
    // explicitly.
    @State private var draft: LogFilterDraft = LogFilterDraft()
    @State private var search: String = ""

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.scaled(6)) {
            HStack(spacing: metrics.scaled(8)) {
                refPicker
                authorField
                pathField
                Spacer(minLength: metrics.scaled(8))
                searchField
            }
            HStack(spacing: metrics.scaled(8)) {
                dateBound(
                    "Since",
                    enabled: draftBinding(for: \.sinceEnabled),
                    date: draftBinding(for: \.since)
                )
                dateBound(
                    "Until",
                    enabled: draftBinding(for: \.untilEnabled),
                    date: draftBinding(for: \.until)
                )
                Spacer()
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
        .onAppear {
            // The one place the view's own properties may be read: at appearance
            // they are current. A draft that has never been shown also has no
            // chosen day to preserve, which is exactly the from-scratch seeding
            // form's case.
            //
            // This is also the scope of the remembered day, and it is the bar's
            // lifetime, not the app's: `ContentView.panelContent` is a `switch`
            // inside a `@ViewBuilder` under `if let panel = visiblePanel`, so each
            // dock panel is a distinct structural branch and switching away from
            // Log (or hiding the dock) destroys this `@State`. Coming back runs
            // this line again and both pickers park on today. Deliberate: the
            // alternative is holding the two days on `CommitLogModel` beside
            // `filter`, i.e. app-lifetime memory of a value the filter has no room
            // to carry, which is a bigger promise than "unticking is not
            // forgetting". `docs/FEATURES.md` states the limit.
            draft = LogFilterDraft(filter: filter, defaultDate: Date())
            search = searchQuery
        }
        // Re-seed if the model swaps in a different filter/search out from under us
        // (e.g. switching repositories resets to the default filter). Both handlers
        // seed from the closure's *new value*; `filter`/`searchQuery` still hold the
        // previous one here. The single-parameter `onChange` spelling is deliberate:
        // the deployment target is macOS 13, whose only overload hands the new value
        // as that one parameter — the two-parameter form is macOS 14+ (and is what
        // the iOS bar uses, which is why the two bars are spelled differently).
        .onChange(of: filter) { newFilter in seed(from: newFilter) }
        .onChange(of: searchQuery) { newQuery in search = newQuery }
    }

    /// `references` order-preserving, with later duplicates dropped.
    private var uniqueReferences: [String] {
        var seen = Set<String>()
        return references.filter { seen.insert($0).inserted }
    }

    /// A user-intent binding over `draft`: `get` reads the draft, `set` writes the
    /// mutated draft into `@State` and applies the resulting `LogFilter` explicitly
    /// with the new value — no re-read of possibly-stale state. Wiring the
    /// Since/Until toggles and date pickers through this binding is what makes
    /// seeding unable to reach the apply path.
    private func draftBinding<Value>(for keyPath: WritableKeyPath<LogFilterDraft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
                onApplyFilter(draft.filter())
            }
        )
    }

    /// The branch picker's selection, read from the draft's display tag and written
    /// only through the apply path. The `get` uses the draft's `displayRefTag` seam
    /// (via `LogFilter.resolvedRef`), so a model-published filter is reflected
    /// without looking like a user selection; the `set` mutates the draft via
    /// `selectRef(tag:)` and applies the verbatim `refSelection`.
    private var refSelectionBinding: Binding<String> {
        Binding(
            get: { draft.displayRefTag(amongKnown: references) },
            set: { tag in
                draft.selectRef(tag: tag)
                onApplyFilter(draft.filter())
            }
        )
    }

    private var refPicker: some View {
        Picker("Branch", selection: refSelectionBinding) {
            Text("All").tag(LogFilterDraft.allRefsTag)
            // The tag *value* is the full refname (unambiguous as a `git log`
            // revision); only the displayed label is shortened. `references` are
            // already distinct full names, but de-duplicate defensively so
            // `ForEach(id: \.self)` never sees a duplicate id (undefined SwiftUI
            // behavior).
            ForEach(uniqueReferences, id: \.self) { ref in
                Text(shortLabel(for: ref)).tag(ref)
            }
        }
        .labelsHidden()
        .frame(maxWidth: metrics.scaled(200))
        .help("Branch / ref to show history for")
    }

    /// The user-facing label for a full refname: strip the `refs/heads/`,
    /// `refs/remotes/`, and `refs/tags/` namespace prefixes so the picker shows
    /// `main` / `origin/main` / `v1.0` while the underlying value stays the full,
    /// unambiguous refname. A tag is suffixed with " (tag)" so a branch and a tag
    /// that share a short name remain visually distinguishable even though their
    /// values already differ.
    private func shortLabel(for ref: String) -> String {
        if ref.hasPrefix("refs/heads/") {
            return String(ref.dropFirst("refs/heads/".count))
        }
        if ref.hasPrefix("refs/remotes/") {
            return String(ref.dropFirst("refs/remotes/".count))
        }
        if ref.hasPrefix("refs/tags/") {
            return String(ref.dropFirst("refs/tags/".count)) + " (tag)"
        }
        return ref
    }

    private var authorField: some View {
        TextField("Author", text: draftAuthorBinding)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: metrics.scaled(140))
            .onSubmit { onApplyFilter(draft.filter()) }
            .help("Filter by author (press Return to apply)")
    }

    private var pathField: some View {
        TextField("Path", text: draftPathBinding)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: metrics.scaled(160))
            .onSubmit { onApplyFilter(draft.filter()) }
            .help("Limit to commits touching this path (press Return to apply)")
    }

    /// Plain draft projections for text fields that must not re-fetch on every
    /// keystroke — typing updates the draft, Return applies it.
    private var draftAuthorBinding: Binding<String> {
        Binding(get: { draft.author }, set: { draft.author = $0 })
    }

    private var draftPathBinding: Binding<String> {
        Binding(get: { draft.path }, set: { draft.path = $0 })
    }

    private var searchField: some View {
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by message", text: searchBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: metrics.scaled(220))
        }
    }

    /// Search is live, client-side — cheap, so apply on every keystroke — but
    /// seeding must not echo. Routing through this user-intent binding (set →
    /// assign + `onSearch(newValue)`) makes the `.onChange(of: searchQuery)` seed
    /// unable to masquerade as a user edit.
    private var searchBinding: Binding<String> {
        Binding(get: { search }, set: { newValue in
            search = newValue
            onSearch(newValue)
        })
    }

    private func dateBound(
        _ label: String,
        enabled: Binding<Bool>,
        date: Binding<Date>
    ) -> some View {
        HStack(spacing: metrics.scaled(4)) {
            Toggle(label, isOn: enabled)
                .toggleStyle(.checkbox)
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .disabled(!enabled.wrappedValue)
        }
    }

    /// Seed the server-side controls from `newFilter` by direct assignment.
    ///
    /// It takes what it seeds from as a parameter rather than reading `filter`
    /// off `self`, because its caller is a change handler and this view value's
    /// own stored `filter` is still the previous value there. Seeding is
    /// structurally unable to reach the apply path: every apply lives in a
    /// binding setter or an explicit `onSubmit` and is handed the new value
    /// explicitly — no value-equality suppression is involved anywhere, which is
    /// the requirement (an equality guard failed under interleaved applies when
    /// the published `filter` lagged `requestedFilter`).
    ///
    /// `LogFilterDraft.seed(from:)` re-seeds the draft in place, so a bound the
    /// incoming filter does not state keeps the day its picker already shows.
    private func seed(from newFilter: LogFilter) {
        draft.seed(from: newFilter)
    }
}

#endif
