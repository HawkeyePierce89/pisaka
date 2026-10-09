#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// The Welcome screen's own measurements, at interface scale 1.0. Every use
/// site scales them through the injected metrics.
enum WelcomeLayout {
    /// The widest the centred content grows, so a full-screen window keeps
    /// the two columns together rather than flinging them to its edges.
    static let contentMaxWidth: Double = 760
    /// The padding around the content, inside the scroll view.
    static let contentPadding: Double = 32
    /// The vertical gap between the header, the columns and the footer.
    static let sectionGap: Double = 28
    /// The actions column's width in the two-column layout.
    static let actionsWidth: Double = 300
    /// The recents column's width in the two-column layout.
    static let recentsWidth: Double = 380
    /// The gap between the two columns, side by side or stacked.
    static let columnGap: Double = 24
    /// The app icon's side.
    static let iconSide: Double = 72
    /// A recent row's height: a name line over a path line.
    static let recentRowHeight: Double = 40
    /// The column cards' corner radius.
    static let cardCornerRadius: Double = 6
    /// The padding inside a column card.
    static let cardPadding: Double = 8
    /// The gap between footer entries.
    static let footerGap: Double = 20
}

/// The Welcome screen: what the window shows instead of the tree + editor
/// split when nothing is open — no folder and no tab (`WelcomeScreen.shows`).
///
/// Four parts: a header (the app icon, the name and the version), the actions
/// column, the recent-projects column and a footer of key shortcuts. Every
/// title, glyph, chord string and the recents list come from Core; this view
/// only lays them out, and every action it runs is a closure the scene already
/// owns for the matching menu item — the footer runs nothing at all.
///
/// The keyboard selection is Core's `WelcomeSelection`: ↑/↓ move through the
/// flattened rows, Tab jumps to the other column's first row and Return
/// activates the selected one. The view takes focus when it appears. Every row
/// is also a real button with its own accessibility label. Moving the
/// selection scrolls its row into view, so a stacked layout taller than the
/// window never highlights a row the user cannot see.
///
/// The recents and the selection live in a `WelcomeViewState` the window owns,
/// not in this view: opening or closing a dock panel moves the workspace to a
/// different branch of `ContentView.mainArea`, which recreates this view, and
/// that must not reset the selection, reload the recents or take focus from
/// the panel. The state is loaded once per showing; focus is taken on its first
/// appear and again whenever the view reappears with the dock closed, since
/// closing the dock removed whatever held focus.
struct WelcomeView: View {
    /// Fetches the MRU project list. Read when the view appears, never per
    /// body evaluation: it reads the session catalog and checks each folder.
    var recentProjects: () -> [RecentProject] = { [] }
    var onAction: (WelcomeAction) -> Void = { _ in }
    var onOpenRecent: (URL) -> Void = { _ in }
    @ObservedObject var state = WelcomeViewState()
    /// Whether a dock panel is open below this view — read on appear, to tell
    /// a dock closing (take focus back) from one opening (leave it there).
    var isDockOpen = false

    @FocusState private var isFocused: Bool

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    content
                        .frame(maxWidth: metrics.scaled(WelcomeLayout.contentMaxWidth))
                        .padding(metrics.scaled(WelcomeLayout.contentPadding))
                        // Centred both ways while the content fits; once it
                        // does not, the minimum height is the viewport's and
                        // the scroll view takes over.
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .onChange(of: selection.selectedIndex) { _, index in
                    guard let index else { return }
                    scroller.scrollTo(index)
                }
            }
        }
        .background(theme.color(.bgCanvas))
        // Focus here exists only so the whole screen receives its key
        // equivalents; it marks no control. So the root draws no focus border —
        // one around the whole canvas would suggest a selection that does not
        // exist, the keyboard selection being the row's `accentTint` — and the
        // platform's ring is suppressed for the same reason (rule forty-nine).
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            let isFirstAppear = !state.isLoaded
            if isFirstAppear { state.load(WelcomeScreen.recents(recentProjects())) }
            // A later appear is a dock panel opening or closing. Closing one
            // takes the focused panel away with it, so focus comes back here;
            // opening one leaves focus with the panel.
            if isFirstAppear || !isDockOpen { isFocused = true }
        }
        .onKeyPress(.downArrow) {
            selection = selection.movedDown()
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = selection.movedUp()
            return .handled
        }
        .onKeyPress(.tab) {
            // A switch that changes nothing (the other column is empty) lets
            // Tab through to ordinary focus navigation instead of trapping it.
            let switched = selection.switchedColumn()
            guard switched != selection else { return .ignored }
            selection = switched
            return .handled
        }
        .onKeyPress(.return) {
            guard let target = selection.selectedTarget else { return .ignored }
            activate(target)
            return .handled
        }
    }

    private var recents: [RecentProject] { state.recents }

    private var selection: WelcomeSelection {
        get { state.selection }
        nonmutating set { state.selection = newValue }
    }

    private var content: some View {
        VStack(spacing: metrics.scaled(WelcomeLayout.sectionGap)) {
            header
            // Side by side when both columns fit at their own widths, stacked
            // otherwise — the stacked layout is the narrow window's, and the
            // scroll view around it is what keeps it reachable.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: metrics.scaled(WelcomeLayout.columnGap)) {
                    actionsColumn
                        .frame(width: metrics.scaled(WelcomeLayout.actionsWidth))
                    recentsColumn
                        .frame(width: metrics.scaled(WelcomeLayout.recentsWidth))
                }
                VStack(spacing: metrics.scaled(WelcomeLayout.columnGap)) {
                    actionsColumn
                    recentsColumn
                }
            }
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: metrics.scaled(6)) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: metrics.scaled(WelcomeLayout.iconSide), height: metrics.scaled(WelcomeLayout.iconSide))
                .accessibilityHidden(true)
            Text("Pisaka")
                .font(metrics.scaledFont(.largeTitle, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
            if let version = Self.version {
                Text("Version \(version)")
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(.textSecondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Columns

    private var actionsColumn: some View {
        card(title: "Start") {
            ForEach(Array(selection.actions.enumerated()), id: \.offset) { index, action in
                WelcomeActionRow(action: action, isSelected: selection.selectedIndex == index) {
                    selection = selection.selecting(index)
                    activate(.action(action))
                }
                .id(index)
            }
        }
    }

    private var recentsColumn: some View {
        card(title: "Recent") {
            if recents.isEmpty {
                Text("Open a folder to get started — it will appear here next time")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
                    .padding(.vertical, metrics.scaled(6))
            } else {
                ForEach(Array(recents.enumerated()), id: \.element.id) { offset, project in
                    let index = selection.actions.count + offset
                    WelcomeRecentRow(project: project, isSelected: selection.selectedIndex == index) {
                        selection = selection.selecting(index)
                        activate(.recent(project.url))
                    }
                    .id(index)
                }
            }
        }
    }

    /// A column: its caption over its rows, on the panel ground inside a
    /// one-point `hairline` outline.
    private func card<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            Text(title)
                .font(metrics.scaledFont(.subheadline, weight: .semibold))
                .foregroundStyle(theme.color(.textSecondary))
                .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
                .accessibilityAddTraits(.isHeader)
            rows()
        }
        .padding(metrics.scaled(WelcomeLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(WelcomeLayout.cardCornerRadius)))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.scaled(WelcomeLayout.cardCornerRadius))
                .strokeBorder(theme.color(.hairline), lineWidth: metrics.scaled(ChromeGeometry.hairlineWidth))
        )
    }

    // MARK: - Footer

    /// The shortcuts that work with no folder open, drawn from Core. Purely
    /// informational: nothing here runs a command, so the menu item stays the
    /// one implementation of each.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.scaled(WelcomeLayout.footerGap)) { footerEntries }
            VStack(spacing: metrics.scaled(6)) { footerEntries }
        }
    }

    private var footerEntries: some View {
        ForEach(WelcomeFooterEntry.allCases, id: \.self) { entry in
            HStack(spacing: metrics.scaled(6)) {
                Text(entry.label)
                    .foregroundStyle(theme.color(.textSecondary))
                Text(entry.chordsDisplay)
                    .foregroundStyle(theme.color(.textPrimary))
            }
            .font(metrics.scaledFont(.callout))
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Activation

    private func activate(_ target: WelcomeTarget) {
        switch target {
        case .action(let action): onAction(action)
        case .recent(let url): onOpenRecent(url)
        }
    }
}

/// The Welcome screen's state across recreations of `WelcomeView`: the
/// recents read when it was first shown and the keyboard selection over them.
/// `ContentView` owns one and resets it whenever the Welcome screen stops
/// showing, so the next showing reads the recents afresh.
final class WelcomeViewState: ObservableObject {
    @Published private(set) var recents: [RecentProject] = []
    @Published var selection = WelcomeSelection(recents: [])
    /// Whether this showing has read its recents (and taken focus) yet.
    private(set) var isLoaded = false

    func load(_ recents: [RecentProject]) {
        self.recents = recents
        selection = WelcomeSelection(recents: recents.map(\.url))
        isLoaded = true
    }

    func reset() {
        recents = []
        selection = WelcomeSelection(recents: [])
        isLoaded = false
    }
}

/// The ground a Welcome row takes: `accentTint` when selected, otherwise
/// `hoverTint` under the pointer, otherwise clear — selection wins.
private func welcomeRowGround(isSelected: Bool, isHovered: Bool) -> ChromeColorRole? {
    if isSelected { return .accentTint }
    if isHovered { return .hoverTint }
    return nil
}

/// One action row: the glyph, the title, and the menu item's chord
/// right-aligned.
private struct WelcomeActionRow: View {
    let action: WelcomeAction
    let isSelected: Bool
    let perform: () -> Void

    @State private var isHovered = false

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button(action: perform) {
            HStack(spacing: metrics.scaled(8)) {
                DesignGlyphImage(action.glyph, size: 16, slot: 20, role: .textSecondary)
                Text(action.title)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(action.chord.display)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
            .frame(height: metrics.scaled(ChromeGeometry.verticalTabRowHeight))
            .background(welcomeRowGround(isSelected: isSelected, isHovered: isHovered).map(theme.color) ?? .clear)
            .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.buttonCornerRadius)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title)
        .accessibilityValue(action.chord.display)
        .accessibilityAddTraits(.isButton)
    }
}

/// One recent-project row: the folder name over its path, the path
/// middle-truncated so both ends of it survive.
private struct WelcomeRecentRow: View {
    let project: RecentProject
    let isSelected: Bool
    let perform: () -> Void

    @State private var isHovered = false

    @Environment(\.interfaceMetrics) private var metrics
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                Text(project.name)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(project.path)
                    .font(metrics.scaledFont(.subheadline))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
            .frame(height: metrics.scaled(WelcomeLayout.recentRowHeight))
            .background(welcomeRowGround(isSelected: isSelected, isHovered: isHovered).map(theme.color) ?? .clear)
            .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(ChromeGeometry.buttonCornerRadius)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.name)
        .accessibilityValue(project.path)
        .accessibilityHint("Opens this folder")
        .accessibilityAddTraits(.isButton)
    }
}
#endif
