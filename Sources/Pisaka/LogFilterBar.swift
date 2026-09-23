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
///
/// On the chrome roles and tokens since part four (b) of the chrome theme: one
/// `panelHeaderHeight` strip on a `bgPanel` ground drawing its own bottom
/// `hairline`, every control in one 22 pt box (`bgEditor` ground, one-point
/// `hairline` border, a two-point `accent` border on focus) — the box shape is
/// shared (`ChromeControls.swift`). The text fields are drawn plain inside the
/// box with their own `textSecondary` placeholder; the branch menu and the two
/// date fields keep their system controls, drawn borderless inside the same box
/// beside a `textSecondary` chevron.
///
/// **Requirement: at the window's minimum width, at every interface scale, every
/// control in the bar is reachable and nothing is clipped.** The single 28 pt row
/// is the shape at a comfortable width, not a floor the window is obliged to
/// provide — the main window's minimum is `metrics.scaled(640)`, well under what
/// the row's design widths add up to. So the design widths are *preferred*
/// widths: the author, path and search fields each take `maxWidth` at the
/// design's figure over a stated minimum, the branch menu is capped and
/// truncates its label, and each date bound's label truncates (the date itself
/// keeps its intrinsic width — its text is the control's value). The row is laid
/// out through `ViewThatFits`: while the minimums compose into the strip, the
/// row fills it and the fields grow back toward their design widths; below that
/// floor the same row, at its minimums, sits in a horizontal scroll view with no
/// scroller furniture, so it scrolls rather than clipping and the strip's
/// height, ground and bottom hairline are unchanged. Crossing the floor while a
/// field holds focus swaps the row and drops the focus — the cost of the two
/// shapes, and harmless (the draft lives in `@State` above both).
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

    /// The text field holding focus, which is the one drawn with the `accent`
    /// border.
    @FocusState private var focusedField: FilterField?
    /// Which date bound's calendar popover is open, if any.
    @State private var calendarShown: DateBound?

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    private enum FilterField: Hashable {
        case author, path, search
    }

    private enum DateBound: Hashable {
        case since, until
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            filterRow
            ScrollView(.horizontal, showsIndicators: false) {
                filterRow
            }
        }
        .font(metrics.scaledFont(.callout))
        .frame(height: metrics.scaled(ChromeGeometry.panelHeaderHeight))
        .background(theme.color(.bgPanel))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
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

    /// The bar's one row, drawn by both of `body`'s shapes. Its ideal width is
    /// the sum of the controls' minimums, which is what `ViewThatFits` tests
    /// against the strip; offered more, the fields grow toward their design
    /// widths and the spacer takes the rest.
    private var filterRow: some View {
        HStack(spacing: metrics.scaled(FilterBarLayout.gap)) {
            refPicker
            authorField
            pathField
            dateBound(
                .since,
                label: "Since",
                enabled: draftBinding(for: \.sinceEnabled),
                date: draftBinding(for: \.since)
            )
            dateBound(
                .until,
                label: "Until",
                enabled: draftBinding(for: \.untilEnabled),
                date: draftBinding(for: \.until)
            )
            Spacer(minLength: metrics.scaled(FilterBarLayout.gap))
            searchField
        }
        .padding(.horizontal, metrics.scaled(FilterBarLayout.padding))
        .frame(maxHeight: .infinity)
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

    /// The branch menu: the system picker, drawn borderless inside the bar's
    /// control box, labelled with the current choice beside a chevron.
    private var refPicker: some View {
        ChromeControlBox(isFocused: false, horizontalPadding: FilterBarLayout.controlPaddingX) {
            HStack(spacing: metrics.scaled(FilterBarLayout.innerGap)) {
                Menu {
                    Picker("Branch", selection: refSelectionBinding) {
                        Text("All").tag(LogFilterDraft.allRefsTag)
                        // The tag *value* is the full refname (unambiguous as a
                        // `git log` revision); only the displayed label is
                        // shortened. `references` are already distinct full names,
                        // but de-duplicate defensively so `ForEach(id: \.self)`
                        // never sees a duplicate id (undefined SwiftUI behavior).
                        ForEach(uniqueReferences, id: \.self) { ref in
                            Text(shortLabel(for: ref)).tag(ref)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(currentRefLabel)
                        .font(metrics.scaledFont(.callout))
                        .foregroundStyle(theme.color(.textPrimary))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                chevron
            }
        }
        .frame(height: metrics.scaled(FilterBarLayout.controlHeight))
        .frame(
            minWidth: metrics.scaled(FilterBarLayout.branchMinWidth),
            maxWidth: metrics.scaled(FilterBarLayout.branchMaxWidth)
        )
        .help("Branch / ref to show history for")
        .accessibilityLabel("Branch")
    }

    /// The branch menu's label: the chosen ref's short name, or "All".
    private var currentRefLabel: String {
        let tag = refSelectionBinding.wrappedValue
        return tag == LogFilterDraft.allRefsTag ? "All" : shortLabel(for: tag)
    }

    /// The chevron beside a borderless system control.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(metrics.scaledFont(.subheadline, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .accessibilityHidden(true)
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
        ChromeThemedTextField(
            title: "Author",
            text: draftAuthorBinding,
            focus: $focusedField,
            focusedEquals: .author,
            horizontalPadding: FilterBarLayout.controlPaddingX
        )
        .frame(height: metrics.scaled(FilterBarLayout.controlHeight))
        .frame(
            minWidth: metrics.scaled(FilterBarLayout.authorMinWidth),
            idealWidth: metrics.scaled(FilterBarLayout.authorMinWidth),
            maxWidth: metrics.scaled(FilterBarLayout.authorWidth)
        )
        .onSubmit { onApplyFilter(draft.filter()) }
        .help("Filter by author (press Return to apply)")
    }

    private var pathField: some View {
        ChromeThemedTextField(
            title: "Path",
            text: draftPathBinding,
            focus: $focusedField,
            focusedEquals: .path,
            horizontalPadding: FilterBarLayout.controlPaddingX
        )
        .frame(height: metrics.scaled(FilterBarLayout.controlHeight))
        .frame(
            minWidth: metrics.scaled(FilterBarLayout.pathMinWidth),
            idealWidth: metrics.scaled(FilterBarLayout.pathMinWidth),
            maxWidth: metrics.scaled(FilterBarLayout.pathWidth)
        )
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
        ChromeThemedTextField(
            title: "Filter by message",
            text: searchBinding,
            glyph: "magnifyingglass",
            focus: $focusedField,
            focusedEquals: .search,
            horizontalPadding: FilterBarLayout.controlPaddingX
        )
        .frame(height: metrics.scaled(FilterBarLayout.controlHeight))
        .frame(
            minWidth: metrics.scaled(FilterBarLayout.searchMinWidth),
            idealWidth: metrics.scaled(FilterBarLayout.searchMinWidth),
            maxWidth: metrics.scaled(FilterBarLayout.searchWidth)
        )
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

    /// One date bound: its checkbox and label, the system date field drawn
    /// borderless, and a chevron opening the calendar — all in one control box.
    private func dateBound(
        _ bound: DateBound,
        label: String,
        enabled: Binding<Bool>,
        date: Binding<Date>
    ) -> some View {
        ChromeControlBox(isFocused: false, horizontalPadding: FilterBarLayout.controlPaddingX) {
            HStack(spacing: metrics.scaled(FilterBarLayout.innerGap)) {
                Toggle(isOn: enabled) {
                    Text(label)
                        .font(metrics.scaledFont(.callout))
                        .foregroundStyle(theme.color(.textPrimary))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
                BorderlessDateField(
                    date: date,
                    isEnabled: enabled.wrappedValue,
                    fontSize: CGFloat(metrics.font(.callout)),
                    textColor: NSColor(theme.color(enabled.wrappedValue ? .textPrimary : .textSecondary))
                )
                .fixedSize()
                .accessibilityLabel(label)
                Button {
                    calendarShown = bound
                } label: {
                    chevron
                }
                .buttonStyle(.borderless)
                .disabled(!enabled.wrappedValue)
                .accessibilityLabel("\(label) calendar")
                .popover(isPresented: calendarBinding(for: bound)) {
                    // The popover's arrow keeps the system material, because the content background cannot reach it.
                    DatePicker("", selection: date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(metrics.scaled(FilterBarLayout.padding))
                        .background(theme.color(.bgPopover))
                }
            }
        }
        .frame(height: metrics.scaled(FilterBarLayout.controlHeight))
    }

    /// Whether `bound`'s calendar popover is open; closing it clears the state.
    private func calendarBinding(for bound: DateBound) -> Binding<Bool> {
        Binding(
            get: { calendarShown == bound },
            set: { if !$0, calendarShown == bound { calendarShown = nil } }
        )
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

/// The bar's own measurements, bare numbers scaled once at the use site (gating
/// rule seven: none is derived from a `ChromeGeometry` token).
private enum FilterBarLayout {
    /// The strip's horizontal inset.
    static let padding: Double = 10
    /// Between the strip's controls.
    static let gap: Double = 10
    /// Every control box's height.
    static let controlHeight: Double = 22
    /// A control box's horizontal inset.
    static let controlPaddingX: Double = 8
    /// Between a glyph (or a checkbox, or a chevron) and the text beside it.
    static let innerGap: Double = 6
    /// The branch menu's widest.
    static let branchMaxWidth: Double = 200
    /// The branch menu's narrowest, below which its label truncates to nothing.
    static let branchMinWidth: Double = 70
    /// The author field's preferred (design) width.
    static let authorWidth: Double = 140
    /// The author field's narrowest.
    static let authorMinWidth: Double = 80
    /// The path field's preferred (design) width.
    static let pathWidth: Double = 160
    /// The path field's narrowest.
    static let pathMinWidth: Double = 80
    /// The message search field's preferred (design) width.
    static let searchWidth: Double = 220
    /// The message search field's narrowest.
    static let searchMinWidth: Double = 120
}

/// The system date field, drawn borderless so the bar's control box is the only
/// frame around it. Its colour is handed in from the chrome theme as a concrete
/// value, so it follows the chosen theme rather than the system appearance.
///
/// Programmatic writes (`dateValue`) send no action, so a seeded draft cannot
/// reach the apply path through this view: only the user's edit calls `date`'s
/// setter, which is the bar's user-intent binding.
private struct BorderlessDateField: NSViewRepresentable {
    @Binding var date: Date
    let isEnabled: Bool
    let fontSize: CGFloat
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .yearMonthDay
        picker.isBordered = false
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateChanged(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
        picker.isEnabled = isEnabled
        picker.font = .systemFont(ofSize: fontSize)
        picker.textColor = textColor
    }

    final class Coordinator: NSObject {
        var date: Binding<Date>

        init(date: Binding<Date>) {
            self.date = date
        }

        @objc func dateChanged(_ sender: NSDatePicker) {
            date.wrappedValue = sender.dateValue
        }
    }
}

#endif
