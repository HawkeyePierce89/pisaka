#if os(macOS)
import SwiftUI
import PisakaCore

/// The Usages panel in the bottom dock: every place the identifier the user
/// asked about is used, grouped by file.
///
/// `ProblemsPanelView`'s shape throughout — a header strip, and one group
/// per file over rows that activate through the app's single
/// `activateSearchMatch(url:range:)`-style entry point — because the two panels
/// answer the same kind of question (where in this project is *this*) and a
/// second row idiom would be a second thing to learn for nothing. What it adds
/// over Problems is the **honesty line**: the header states whether the rows are
/// a language server's resolved references or `TextualUsageScanner`'s whole-word
/// matches, and says so in words rather than through an icon, because the
/// difference is a difference in what the list *claims* and not a difference in
/// severity.
///
/// The view holds no domain logic. Grouping, ordering, the cap and the empty
/// reason are all `FindUsagesModel`'s published state; the one thing that looks
/// like a decision here — what a click does — is `UsageResult.revealRange` in
/// Core, asked by the app against the buffer the click actually lands in.
///
/// Chrome, not a code surface: everything is sized through `\.interfaceMetrics`
/// and the view declares **no** zoom surface, so a scroll over it resizes the
/// interface zone like every other panel in the dock. It states no minimum
/// height either — the slot's height is `BottomPanelHeightRule`'s and a minimum
/// inside it can only overflow (`BottomPanelSourceGatingTests` pins both rules).
///
/// On the chrome roles and tokens since part four (a) of the chrome theme, in
/// Problems' shape: a `panelHeaderHeight` header drawing its own one-point
/// `hairline` along its bottom edge rather than a `Divider()` (gating rule
/// fourteen), and every colour a role.
struct UsagesPanelView: View {
    @ObservedObject var model: FindUsagesModel
    /// Invoked when a row is activated, with the row itself rather than a
    /// `(url, range)` pair: the range a click may reveal depends on the file's
    /// text *at click time*, which only the app can read, so the decision is
    /// deferred to it (`UsageResult.revealRange(naming:in:)`) instead of being
    /// half-made here. Defaults to a no-op so previews/tests can construct the
    /// view without the app wiring.
    var onActivate: (UsageResult) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    private var header: some View {
        HStack(spacing: metrics.scaled(UsagesPanelLayout.headerGap)) {
            Text("Usages")
                .font(metrics.scaledFont(.body, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
            if !model.identifier.isEmpty {
                Text(model.identifier)
                    .font(metrics.scaledFont(.callout, design: .monospaced))
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let note = provenanceNote {
                Text(note)
                    .font(metrics.scaledFont(.subheadline))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
            }
            if model.isSearching {
                ChromeSpinner()
                    .accessibilityLabel("Searching")
            }
            Spacer()
            if !model.groups.isEmpty {
                Text(countLabel)
                    .font(metrics.scaledFont(.subheadline))
                    .monospacedDigit()
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.panelHeaderPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.panelHeaderHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }

    /// What the rows mean, in words. Absent until a question has been *answered*:
    /// before that there is nothing to characterise, and labelling a panel nobody
    /// has asked anything of would be a claim about a list that does not exist.
    /// An answer that found nothing still says which kind of nothing it is —
    /// "searched textually, found none" is the honest reading of an empty textual
    /// answer, and `emptyText` says the rest of it.
    private var provenanceNote: String? {
        switch model.provenance {
        case .none: return nil
        case .semantic: return "references"
        case .textual: return "textual matches"
        }
    }

    /// The count, plus a note when the answer is only the head of a longer one.
    ///
    /// The note deliberately does *not* print `UsagesAnswer.cap`: `isTruncated`
    /// is true for two reasons and only one of them is the cap. A walk that
    /// abandoned the project once it held one row past the cap can still hand
    /// over a deduplicated list below it (`FindUsagesModel`'s final publish says
    /// so in full), and "first 2 000 — 1 431 in 12 files" is a header
    /// contradicting itself. What is true in both cases is that there are more,
    /// and the count beside it is the count of what is drawn.
    private var countLabel: String {
        let count = model.groups.reduce(0) { $0 + $1.rows.count }
        let files = model.groups.count
        let base = "\(count) in \(files) \(files == 1 ? "file" : "files")"
        return model.isTruncated ? "\(base) — more not shown" : base
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            placeholder(emptyText)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups, id: \.fileURL) { group in
                        fileGroup(group)
                    }
                }
                .padding(.vertical, metrics.scaled(UsagesPanelLayout.listPaddingY))
            }
        }
    }

    /// The empty state says *which* nothing it means — `UsagesEmptyReason`'s
    /// whole point, spelled out here in the three sentences it distinguishes.
    private var emptyText: String {
        if model.isSearching { return "Searching…" }
        switch model.emptyReason {
        case .notAnIdentifier: return "The caret is not on a name"
        case .noUsages: return "No usages of \(model.identifier)"
        case .noQuery, .none: return "Find Usages on a name to list where it is used"
        }
    }

    private func fileGroup(_ group: UsageFileGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.scaled(UsagesPanelLayout.groupGap)) {
                let icon = FileIcon(for: DirectoryEntry(url: group.fileURL, isDirectory: false))
                Image(systemName: icon.symbolName)
                    .foregroundStyle(theme.color(.textSecondary))
                Text(group.relativePath)
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(metrics.scaledFont(.body, weight: .medium))
            .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
            .padding(.vertical, metrics.scaled(UsagesPanelLayout.groupPaddingY))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            // The row identity is *(file, range)* rather than the row value: two
            // rows in one file are distinguished by where they are, and the
            // answer's dedup already guarantees that pair is unique.
            ForEach(group.rows, id: \.range) { row in
                UsageRow(row: row, onActivate: { onActivate(row) })
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(theme.color(.textSecondary))
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                .padding(metrics.scaled(UsagesPanelLayout.placeholderPadding))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One usage row: the line number, then the line the occurrence sits on with the
/// occurrence itself emphasized. Clicking activates — open-and-reveal through
/// the callback above.
///
/// The preview text is drawn in the *interface* font rather than the editor's:
/// this is a list of places, not a view of code, and drawing it at the code font
/// would additionally make the panel a zoom surface the dock's other panels are
/// not.
private struct UsageRow: View {
    let row: UsageResult
    let onActivate: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(UsagesPanelLayout.rowGap)) {
            Text("\(row.line)")
                .font(metrics.scaledFont(.subheadline, design: .monospaced))
                .foregroundStyle(theme.color(.textSecondary))
                .frame(minWidth: metrics.scaled(UsagesPanelLayout.lineNumberWidth), alignment: .trailing)
            preview
                .font(metrics.scaledFont(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: metrics.scaled(UsagesPanelLayout.trailingGap))
        }
        .padding(.leading, metrics.scaled(UsagesPanelLayout.rowIndent))
        .padding(.trailing, metrics.scaled(ChromeGeometry.rowPaddingX))
        .padding(.vertical, metrics.scaled(UsagesPanelLayout.rowPaddingY))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? theme.color(.hoverTint) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
    }

    /// The preview line with the match emphasized, assembled from
    /// `MatchPreview.matchRange` — which is already clamped to the clipped
    /// window, so the three pieces below always exist even for a match the
    /// window cut. A range the split cannot honor (an empty preview) simply
    /// draws the line unemphasized rather than dropping the row.
    private var preview: Text {
        let text = row.preview.text as NSString
        let match = row.preview.matchRange
        guard match.location >= 0, NSMaxRange(match) <= text.length else {
            return Text(row.preview.text).foregroundColor(theme.color(.textPrimary))
        }
        let before = text.substring(to: match.location)
        let hit = text.substring(with: match)
        let after = text.substring(from: NSMaxRange(match))
        return Text(before).foregroundColor(theme.color(.textSecondary))
            + Text(hit).foregroundColor(theme.color(.textPrimary)).fontWeight(.semibold)
            + Text(after).foregroundColor(theme.color(.textSecondary))
    }
}

/// The panel's own measurements, bare numbers scaled once at the use site. They
/// belong to this panel alone, so deriving them from a `ChromeGeometry` token
/// would couple them to a measurement that means something else (gating rule
/// seven).
private enum UsagesPanelLayout {
    /// Between a file group's icon and its path.
    static let groupGap: Double = 4
    /// Around the empty-state sentence: the default `.padding()` inset, stated
    /// so it scales with the rest of the panel instead of staying a fixed 16pt.
    static let placeholderPadding: Double = 16
    /// Between the header's title, identifier, note and count.
    static let headerGap: Double = 8
    /// Above and below the list inside its scroll view.
    static let listPaddingY: Double = 4
    /// A file group's vertical inset.
    static let groupPaddingY: Double = 3
    /// Between a row's line number and its preview.
    static let rowGap: Double = 6
    /// The line-number column's least width, so previews align down a group.
    static let lineNumberWidth: Double = 34
    /// The least room kept after a row's preview.
    static let trailingGap: Double = 4
    /// A row's leading inset: it sits under its file group's name.
    static let rowIndent: Double = 16
    /// A row's vertical inset.
    static let rowPaddingY: Double = 2
}

#endif
