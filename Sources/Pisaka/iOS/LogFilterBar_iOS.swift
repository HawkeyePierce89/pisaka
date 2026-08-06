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
/// argument-building/search logic lives in `PisakaCore.LogFilter`.
///
/// The branch selection is deliberately *not* mirrored in `@State` — it reads
/// straight from `filter` through `LogFilter.resolvedRef(amongKnown:)` and writes
/// only through the apply path, so a model-published filter change can never look
/// like a user selection and drive a refetch loop (the macOS rationale).
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

    /// Sentinel ref-picker tag meaning "all refs" (`--all`); a real ref name can
    /// never be empty, so this is unambiguous.
    private static let allRefsTag = ""

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
        .onAppear { search = searchQuery }
        .onChange(of: searchQuery) { search = searchQuery }
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
    /// apply path (the macOS `refSelectionBinding` pattern).
    private var selectedRef: String {
        filter.resolvedRef(amongKnown: references) ?? Self.allRefsTag
    }

    private var branchMenu: some View {
        Menu {
            Picker("Branch", selection: Binding(
                get: { selectedRef },
                set: { applyRef($0) }
            )) {
                Text("All").tag(Self.allRefsTag)
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
            TextField("Filter by message", text: $search)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: search) { onSearch(search) }
        }
    }

    /// Apply a brand-new branch selection while preserving the other dimensions.
    private func applyRef(_ ref: String) {
        let refSelection: LogFilter.RefSelection = ref.isEmpty ? .all : .ref(ref)
        var newFilter = filter
        newFilter.refSelection = refSelection
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
/// and reports it on Apply. Date bounds are normalized to day boundaries exactly as
/// the macOS bar does (`since` → start of day, `until` → last second of day, the
/// inclusive upper bound git's `--until` expects).
private struct LogAdvancedFilterForm_iOS: View {
    let filter: LogFilter
    let references: [String]
    let onApply: (LogFilter) -> Void
    let onCancel: () -> Void

    @State private var author: String
    @State private var path: String
    @State private var sinceEnabled: Bool
    @State private var since: Date
    @State private var untilEnabled: Bool
    @State private var until: Date

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
        _author = State(initialValue: filter.author ?? "")
        _path = State(initialValue: filter.path ?? "")
        _sinceEnabled = State(initialValue: filter.since != nil)
        _since = State(initialValue: filter.since ?? Date(timeIntervalSince1970: 0))
        _untilEnabled = State(initialValue: filter.until != nil)
        _until = State(initialValue: filter.until ?? Date(timeIntervalSince1970: 0))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Author") {
                    TextField("Name or email", text: $author)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Path") {
                    TextField("Limit to path", text: $path)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Date range") {
                    Toggle("Since", isOn: $sinceEnabled)
                    if sinceEnabled {
                        DatePicker("From", selection: $since, displayedComponents: .date)
                    }
                    Toggle("Until", isOn: $untilEnabled)
                    if untilEnabled {
                        DatePicker("To", selection: $until, displayedComponents: .date)
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
        author = ""
        path = ""
        sinceEnabled = false
        untilEnabled = false
    }

    /// Assemble the filter, preserving the current branch selection and normalizing
    /// the date bounds to inclusive day boundaries.
    private func apply() {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFilter = LogFilter(
            refSelection: filter.refSelection,
            author: trimmedAuthor.isEmpty ? nil : trimmedAuthor,
            since: sinceEnabled ? Calendar.current.startOfDay(for: since) : nil,
            until: untilEnabled ? endOfDay(of: until) : nil,
            path: trimmedPath.isEmpty ? nil : trimmedPath
        )
        onApply(newFilter)
    }

    /// The last second of `date`'s calendar day — the inclusive `--until` bound (the
    /// macOS `endOfDay`).
    private func endOfDay(of date: Date) -> Date {
        let startOfDay = Calendar.current.startOfDay(for: date)
        guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) else {
            return date
        }
        return nextDay.addingTimeInterval(-1)
    }
}
#endif
