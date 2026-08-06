#if os(macOS)
import SwiftUI
import PisakaCore

/// The Log view's filter/search bar, shown above the commit table.
///
/// A thin, untested view (per project convention): it holds editable local state
/// for the author, date range, and path filter dimensions plus the message-search
/// box (the ref scope is deliberately *not* mirrored — see `refSelectionBinding`,
/// which reads it straight from `filter`), and reports changes back through two
/// callbacks. The
/// server-side dimensions are assembled into a `LogFilter` and reported via
/// `onApplyFilter` (which the owner turns into a generation-guarded re-fetch); the
/// message search is reported live via `onSearch` (a client-side filter over the
/// already-loaded commits, so it never re-queries git). All the testable
/// argument-building and search logic lives in `PisakaCore.LogFilter`.
struct LogFilterBar: View {
    /// The branch/tag refs offered in the ref picker — **full** refnames (e.g.
    /// `refs/heads/main`, `refs/tags/v1.0`) sourced from the service. The full name
    /// is the picker's *value* (the unambiguous revision `git log` receives), while
    /// `shortLabel(for:)` derives the user-facing display: a branch `v1.0` and a tag
    /// `v1.0` would collapse to one ambiguous short name, but their full refnames
    /// stay distinct so git resolves exactly the one chosen.
    let references: [String]
    /// The current server-side filter, used to seed the controls on appearance and
    /// to re-seed them when the model re-publishes (e.g. a folder switch).
    let filter: LogFilter
    /// The current search query, used to seed the search field.
    let searchQuery: String
    /// Apply a rebuilt server-side filter (triggers a re-fetch in the owner).
    let onApplyFilter: (LogFilter) -> Void
    /// Report a new client-side message-search query (no re-fetch).
    let onSearch: (String) -> Void

    // Local editable state, seeded from `filter`/`searchQuery`. The branch picker
    // is deliberately *not* mirrored here — it reads straight from `filter` via a
    // computed `Binding` (see `refSelectionBinding`) so a model-published filter
    // change can't masquerade as a user selection and drive a refetch loop.
    @State private var author: String = ""
    @State private var path: String = ""
    @State private var sinceEnabled = false
    @State private var since = Date()
    @State private var untilEnabled = false
    @State private var until = Date()
    @State private var search: String = ""

    /// Sentinel ref-picker tag meaning "all refs" (`--all`); a real ref name can
    /// never be empty, so this is unambiguous.
    private static let allRefsTag = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                refPicker
                authorField
                pathField
                Spacer(minLength: 8)
                searchField
            }
            HStack(spacing: 8) {
                dateBound("Since", enabled: $sinceEnabled, date: $since)
                dateBound("Until", enabled: $untilEnabled, date: $until)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear(perform: seedFromFilter)
        // Re-seed if the model swaps in a different filter/search out from under us
        // (e.g. switching repositories resets to the default filter).
        .onChange(of: filter) { _ in seedFromFilter() }
        .onChange(of: searchQuery) { _ in search = searchQuery }
    }

    /// `references` order-preserving, with later duplicates dropped.
    private var uniqueReferences: [String] {
        var seen = Set<String>()
        return references.filter { seen.insert($0).inserted }
    }

    /// The branch picker's selection, read straight from `filter` and written only
    /// through the apply path. Reading via the pure `resolvedRef(amongKnown:)`
    /// helper (mapping its `nil` "all refs" onto `allRefsTag`) means a
    /// model-published filter change is reflected without ever looking like a user
    /// selection — the loop that a mirrored `@State` + `.onChange` would form is
    /// gone. The setter routes through `applyFilter(refOverride:)` so a selection
    /// flows only one way: into the model.
    private var refSelectionBinding: Binding<String> {
        Binding(
            get: { filter.resolvedRef(amongKnown: references) ?? Self.allRefsTag },
            set: { applyFilter(refOverride: $0) }
        )
    }

    private var refPicker: some View {
        Picker("Branch", selection: refSelectionBinding) {
            Text("All").tag(Self.allRefsTag)
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
        .frame(maxWidth: 200)
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
        TextField("Author", text: $author)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 140)
            .onSubmit { applyFilter() }
            .help("Filter by author (press Return to apply)")
    }

    private var pathField: some View {
        TextField("Path", text: $path)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160)
            .onSubmit { applyFilter() }
            .help("Limit to commits touching this path (press Return to apply)")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by message", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                // Live, client-side — cheap, so apply on every keystroke.
                .onChange(of: search) { onSearch($0) }
        }
    }

    private func dateBound(
        _ label: String,
        enabled: Binding<Bool>,
        date: Binding<Date>
    ) -> some View {
        HStack(spacing: 4) {
            Toggle(label, isOn: enabled)
                .toggleStyle(.checkbox)
                .onChange(of: enabled.wrappedValue) { _ in applyFilter() }
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .disabled(!enabled.wrappedValue)
                .onChange(of: date.wrappedValue) { _ in
                    if enabled.wrappedValue { applyFilter() }
                }
        }
    }

    /// Seed every control from the current `filter`/`searchQuery`. The branch
    /// picker is excluded: it reads `filter` live through `refSelectionBinding`, so
    /// there is nothing to seed (and seeding it would re-introduce the refetch
    /// loop this fix removes).
    private func seedFromFilter() {
        author = filter.author ?? ""
        path = filter.path ?? ""
        sinceEnabled = filter.since != nil
        if let s = filter.since { since = s }
        untilEnabled = filter.until != nil
        // `filter.until` is the *inclusive* last-second-of-day bound `applyFilter`
        // computed from the picker's selected day (see `endOfDay`). That instant is
        // still on the selected day, so seeding it verbatim shows the right day and
        // `endOfDay` re-derives the same bound — the round-trip is idempotent, so it
        // needs no inverse (the same reason `since`'s `startOfDay` doesn't).
        if let u = filter.until { until = u }
        search = searchQuery
    }

    /// Assemble a `LogFilter` from the current control state and report it.
    ///
    /// `refOverride` carries a brand-new branch selection from the picker; when
    /// `nil` (an apply driven by author/path/date) the branch is taken from the
    /// current `filter` via the same `resolvedRef(amongKnown:)` resolution the
    /// picker reads, so those applies preserve the selected branch instead of
    /// resetting it to "all".
    private func applyFilter(refOverride: String? = nil) {
        let selectedRef = refOverride
            ?? filter.resolvedRef(amongKnown: references)
            ?? Self.allRefsTag
        let refSelection: LogFilter.RefSelection =
            selectedRef.isEmpty ? .all : .ref(selectedRef)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = LogFilter(
            refSelection: refSelection,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor,
            // The date pickers only edit a calendar day, but the bound `Date` keeps
            // whatever time-of-day it was seeded with — so a raw `until` of "today
            // at 14:30" would drop commits made later today. Normalize each bound to
            // its day boundary: `since` to the start of the selected day, `until` to
            // the *last second* of the selected day, so `--until` includes every
            // commit made on the selected day but none on the next. (git's `--until`
            // is inclusive — a commit dated exactly at the bound is shown — so the
            // bound must be the day's last second, not the next day's midnight, which
            // would let a commit dated exactly at next-day-00:00 slip in.) Using
            // `Calendar.current` keeps "the selected day" in the user's local time;
            // the absolute instants are then formatted (in UTC) by `LogFilter`.
            since: sinceEnabled ? Calendar.current.startOfDay(for: since) : nil,
            until: untilEnabled ? endOfDay(of: until) : nil,
            path: trimmedPath.isEmpty ? nil : trimmedPath
        )
        onApplyFilter(filter)
    }

    /// The last second of `date`'s calendar day (next-day midnight minus one
    /// second). git's `--until` is *inclusive*, so this includes every commit made
    /// on `date`'s day while excluding a commit dated exactly at the next day's
    /// midnight. Falls back to `date` itself in the (practically impossible) case
    /// the calendar can't advance a day.
    private func endOfDay(of date: Date) -> Date {
        let startOfDay = Calendar.current.startOfDay(for: date)
        guard let nextDay = Calendar.current.date(
            byAdding: .day, value: 1, to: startOfDay
        ) else { return date }
        return nextDay.addingTimeInterval(-1)
    }
}

#endif
