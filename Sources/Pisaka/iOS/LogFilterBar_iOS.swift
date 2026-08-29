#if os(iOS)
import SwiftUI
import PisakaCore

/// The Log view's filter/search bar — the iOS peer of the macOS `LogFilterBar`.
///
/// A compact bar (a branch `Menu`, a live message-search field, and a button that
/// opens the advanced-filter form) sits above the commit list. The advanced form
/// (author, path, date range) is presented as a sheet to stay phone-friendly; on
/// apply it assembles a `LogFilter` and reports it through `onApplyFilter` (which
/// the owner turns into a generation-guarded re-fetch). The message search reports
/// live via `onSearch` (a client-side filter, no re-query). All the testable
/// argument-building/search logic lives in `PisakaCore.LogFilter` and the shared
/// `PisakaCore.LogFilterDraft`.
///
/// Audit: the advanced form is **immune** to the seed/echo loop by construction —
/// it is seeded once in `init` via `LogFilterDraft(filter:defaultDate:)` and
/// applies only from the explicit Apply button, so no model-published filter
/// reaches it while it is presented. The compact bar's search field previously
/// carried the *same* masquerade shape as the macOS toggles — `.onChange(of:
/// searchQuery)` seeded `search`, whose `.onChange(of: search)` called `onSearch`
/// — and is now routed through a user-intent binding whose `set` both stores the
/// new value and calls `onSearch`, so the seed cannot masquerade as a user edit.
/// The branch picker uses `LogFilterDraft.allRefsTag` / `displayRefTag` /
/// `selectRef`; its write is verbatim, as on iOS it always was. The advanced
/// form's single `LogFilterDraft` owns trimming, day-boundary normalization and
/// verbatim ref preservation exactly as the macOS bar does.
///
/// **A change handler seeds from its parameter**, never from the view's own
/// stored property. On iOS this is uniformity with the macOS bar rather than a
/// bug fix, and the difference is worth naming so neither side is "corrected"
/// into the other: the stale-property trap belongs to the deprecated
/// single-parameter `onChange(of:perform:)`, which macOS 13 is stuck with — it
/// runs the closure captured *before* the change, so a plain stored property
/// read off `self` there (the macOS bar's `filter`/`searchQuery`, a `let`) is
/// still the previous value and seeding from it lags one publish forever. The
/// iOS deployment target is 17, whose two-parameter `onChange(of:_:)` runs the
/// *new* closure, so `searchQuery` would read current here either way; taking
/// the parameter states the intent and makes both bars read alike. (`@State`
/// and `@ObservedObject` reads are live under both overloads — they resolve
/// through their storage, not through the captured view value — which is why
/// only plain stored properties are at risk on macOS.)
///
/// Two handlers are deliberately *not* changed: `LogAdvancedFilterForm_iOS` has
/// no change handlers at all (it is seeded once in `init` and applies only from
/// Apply), and `selectedRef` / `applyRef` read `filter` from the view body and a
/// binding `set` respectively, where the property is current.
///
/// The branch selection is deliberately *not* mirrored in `@State` — it reads
/// straight from `filter` through `LogFilterDraft.displayRefTag(amongKnown:)` and
/// writes only through the apply path, so a model-published filter change can never
/// look like a user selection and drive a refetch loop (the macOS rationale).
struct LogFilterBar_iOS: View {
    /// The branch/tag refs offered in the picker — **full** refnames; the menu shows
    /// a shortened label while the value stays the unambiguous `git log` revision.
    let references: [String]
    /// The current server-side filter, the source of truth for the branch selection
    /// and the seed for the advanced form.
    let filter: LogFilter
    /// The current message-search query, seeding the search field.
    let searchQuery: String
    /// Apply a rebuilt server-side filter (triggers a re-fetch in the owner).
    let onApplyFilter: (LogFilter) -> Void
    /// Report a new client-side message-search query (no re-fetch).
    let onSearch: (String) -> Void

    @State private var search: String = ""
    @State private var showingAdvanced = false

    var body: some View {
        HStack(spacing: 8) {
            branchMenu
            searchField
            Button {
                showingAdvanced = true
            } label: {
                Image(systemName: hasAdvancedFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by author, path, or date")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Both seeds take the value they seed from explicitly — `onAppear` from the
        // current property, the change handler from its parameter. See the type doc
        // for why the parameter is mandatory on macOS and uniformity here.
        .onAppear { search = searchQuery }
        .onChange(of: searchQuery) { _, newQuery in search = newQuery }
        .sheet(isPresented: $showingAdvanced) {
            LogAdvancedFilterForm_iOS(
                filter: filter,
                references: references,
                onApply: { newFilter in
                    showingAdvanced = false
                    onApplyFilter(newFilter)
                },
                onCancel: { showingAdvanced = false }
            )
        }
    }

    /// Whether any commit-limiting (advanced) dimension is active, used to badge the
    /// filter button.
    private var hasAdvancedFilter: Bool {
        let hasAuthor = !(filter.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPath = !(filter.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasAuthor || hasPath || filter.since != nil || filter.until != nil
    }

    /// `references` order-preserving, with later duplicates dropped.
    private var uniqueReferences: [String] {
        var seen = Set<String>()
        return references.filter { seen.insert($0).inserted }
    }

    /// The branch selection read straight from `filter` and written only through the
    /// apply path (the macOS `refSelectionBinding` pattern), now via the shared
    /// `LogFilterDraft` seam so the sentinel and the mapping live in one place.
    private var selectedRef: String {
        LogFilterDraft(filter: filter, defaultDate: Date())
            .displayRefTag(amongKnown: references)
    }

    private var branchMenu: some View {
        Menu {
            Picker("Branch", selection: Binding(
                get: { selectedRef },
                set: { applyRef($0) }
            )) {
                Text("All").tag(LogFilterDraft.allRefsTag)
                ForEach(uniqueReferences, id: \.self) { ref in
                    Text(shortLabel(for: ref)).tag(ref)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(selectedRef.isEmpty ? "All" : shortLabel(for: selectedRef))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 140, alignment: .leading)
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by message", text: searchBinding)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    /// User-intent binding for the live message search: `set` stores the new value
    /// and reports it via `onSearch`, so the `.onChange(of: searchQuery)` seed
    /// (direct assignment) cannot masquerade as a user edit.
    private var searchBinding: Binding<String> {
        Binding(
            get: { search },
            set: { newValue in
                search = newValue
                onSearch(newValue)
            }
        )
    }

    /// Apply a brand-new branch selection while preserving the other dimensions.
    /// Uses `LogFilterDraft.selectRef(tag:)` so the sentinel mapping lives with the
    /// shared draft, but keeps the verbatim write iOS already had (other dimensions
    /// are carried from `filter` unchanged).
    private func applyRef(_ tag: String) {
        var draft = LogFilterDraft(filter: filter, defaultDate: Date())
        draft.selectRef(tag: tag)
        var newFilter = filter
        newFilter.refSelection = draft.refSelection
        onApplyFilter(newFilter)
    }

    /// The user-facing label for a full refname (the macOS `shortLabel` mapping).
    private func shortLabel(for ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") { return String(ref.dropFirst("refs/remotes/".count)) }
        if ref.hasPrefix("refs/tags/") { return String(ref.dropFirst("refs/tags/".count)) + " (tag)" }
        return ref
    }
}

/// The advanced (commit-limiting) filter form: author, path, and a date range,
/// presented as a sheet. Assembles a `LogFilter` (preserving the current branch)
/// and reports it on Apply. The single `LogFilterDraft` owns trimming, day-boundary
/// normalization and verbatim ref preservation exactly as the macOS bar does; the
/// form is seeded once in `init` and applies only from the explicit Apply button, so
/// no model publish reaches it.
private struct LogAdvancedFilterForm_iOS: View {
    let filter: LogFilter
    let references: [String]
    let onApply: (LogFilter) -> Void
    let onCancel: () -> Void

    @State private var draft: LogFilterDraft

    init(
        filter: LogFilter,
        references: [String],
        onApply: @escaping (LogFilter) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.filter = filter
        self.references = references
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: LogFilterDraft(filter: filter, defaultDate: Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Author") {
                    TextField("Name or email", text: $draft.author)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Path") {
                    TextField("Limit to path", text: $draft.path)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Date range") {
                    Toggle("Since", isOn: $draft.sinceEnabled)
                    if draft.sinceEnabled {
                        DatePicker("From", selection: $draft.since, displayedComponents: .date)
                    }
                    Toggle("Until", isOn: $draft.untilEnabled)
                    if draft.untilEnabled {
                        DatePicker("To", selection: $draft.until, displayedComponents: .date)
                    }
                }
                Section {
                    Button("Clear filters", role: .destructive, action: clear)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                }
            }
        }
    }

    private func clear() {
        draft.author = ""
        draft.path = ""
        draft.sinceEnabled = false
        draft.untilEnabled = false
    }

    private func apply() {
        onApply(draft.filter())
    }
}
#endif
