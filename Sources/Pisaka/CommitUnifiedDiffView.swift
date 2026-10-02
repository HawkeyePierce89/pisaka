#if os(macOS)
import SwiftUI
import PisakaCore

/// The commit dialog's right-hand panel: a **unified** (single-column) diff of one
/// file with a checkbox on every changed line.
///
/// A standalone SwiftUI panel rather than an extension of the AppKit `DiffView`:
/// that view is a read-only *side-by-side* renderer built on two `NSTextView`s, and
/// neither of its two properties survives here — the dialog needs one column (so a
/// `.modified` row shows its old and new line one above the other, sharing a single
/// checkbox) and it needs per-line hit targets. Thin and untested like the rest of
/// the view layer: every decision — what a unit is, how a row flattens into lines,
/// which files may be selected at all — is `CommitDiffUnits`'.
///
/// **The "committed as a whole" branch is the substance of this view, not a
/// fallback.** When `wholeOnlyMessage` is non-`nil` it draws that sentence and
/// *nothing else* — no diff, and not a single line checkbox. Three unrelated-looking
/// cases arrive here that way and all three behave identically (a deleted file, a
/// binary/non-UTF-8 side, and a file whose only difference is its line endings), the
/// one decision being `CommitFileFacts.wholeOnlyReason`. Drawing their diff instead
/// would put a selection UI on screen in which every click does nothing — which
/// reads as broken — and for a binary file the naive old/new diff additionally reads
/// as "every HEAD line removed", i.e. as an invitation to exactly the silent
/// corruption the classification exists to prevent.
struct CommitUnifiedDiffView: View {
    /// The flattened rows, from `CommitDialogModel.unifiedLines(for:)`.
    let lines: [UnifiedDiffLine]
    /// The units currently checked, so each changed line draws its own state.
    let selectedUnits: Set<Int>
    /// The sentence to draw *instead of* the diff, or `nil` to draw the diff.
    /// Comes from `CommitDialogModel.wholeOnlyMessage(for:)`.
    let wholeOnlyMessage: String?
    /// The shared editor font size, so the diff matches the rest of the app.
    let fontSize: Double
    /// Whether the selection may still be changed — false while a commit runs.
    ///
    /// `CommitDialogModel.commit` pins the whole selection at entry, so a unit
    /// toggled mid-run changes nothing while the checkbox visibly moves: the file
    /// is still committed exactly as it was pinned. The same reason the Amend and
    /// "Push after commit" switches are disabled there.
    var isMutable: Bool = true
    /// Toggle one unit (a `.modified` pair's two lines report the same index).
    var onToggleUnit: (Int) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the commit sheet.
    ///
    /// Read by the **placeholder alone**. The diff itself is the code zone: every
    /// row's text draws at `fontSize`, and the fixed geometry around it (the
    /// checkbox column, the number gutter's width, the row's own spacing and
    /// padding) is left off *both* scales — it is chrome that belongs to a code
    /// row, and putting it on the interface scale would make the two zones
    /// interact, which is the Find in Files result rows' rule and the one thing
    /// the three-zone split exists to prevent.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome palette: the row wash (Core's `diffWashRole(for:)`), the
    /// checkbox, the line numbers and the placeholder read their colours from it.
    @Environment(\.chromeTheme) private var theme
    /// The widest natural width any realized row has reported since the last
    /// re-measure. Part of the content's width (`diff`'s doc comment).
    @State private var widestRow: CGFloat = 0
    /// Bumped by every re-measure and used as the rows' identity, so each
    /// realized row is rebuilt and reports its width afresh (`remeasure()`).
    @State private var measureGeneration = 0

    var body: some View {
        if let wholeOnlyMessage {
            placeholder(wholeOnlyMessage)
        } else if lines.isEmpty {
            placeholder("No changes to show.")
        } else {
            diff
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: metrics.scaled(8)) {
            Spacer()
            Image(systemName: "doc.fill")
                .font(metrics.scaledFont(.largeTitle))
                .foregroundStyle(theme.color(.textSecondary))
            Text(text)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
                .multilineTextAlignment(.center)
                .padding(.horizontal, metrics.scaled(24))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The rows draw at `fontSize`, so the region they occupy *is* the code zone:
    /// a gesture over it must grow the diff, not the sheet around it. The marker
    /// is what the pointer walk finds — the same zero-cost representable the Find
    /// in Files result rows and the LeetCode statement carry, and for the same
    /// reason (`docs/architecture/core-zoom.md`): targeting the interface zone
    /// while the text under the pointer follows the code size is incoherent.
    ///
    /// **The content's width is the larger of the pane's visible width and the
    /// widest row's natural width**, and every row fills it, so a changed line's
    /// wash spans the pane however short its text is — and still reaches the
    /// visible trailing edge once the pane is scrolled to the far right of an
    /// overflowing line. Both halves are measured, never assumed: the horizontal
    /// axis proposes no width, so without the first a row's width was its own
    /// text's and its wash stopped there; and a `LazyVStack` takes its own width
    /// from its first row rather than its widest, so without the second an
    /// overflowing line could not widen the content at all. The widest row is
    /// the widest *realized* one — a lazy stack never lays out the rest — so the
    /// content widens as a longer line scrolls into view.
    private var diff: some View {
        GeometryReader { pane in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The index is the identity: the same text can legitimately
                    // appear on many lines, and a `.modified` pair shares its unit
                    // index. It is taken from `indices` rather than by wrapping the
                    // array in `enumerated()`, which would build a fresh array of
                    // one tuple per line on *every* body pass — and this body
                    // re-runs on every keystroke in the message field, over a diff
                    // that can be tens of thousands of lines long, which is the
                    // very cost `CommitDialogModel.unifiedLines(for:)` is memoized
                    // to avoid.
                    ForEach(lines.indices, id: \.self) { index in
                        row(lines[index])
                    }
                }
                .id(measureGeneration)
                .padding(.vertical, 2)
                .frame(minWidth: max(pane.size.width, widestRow), alignment: .leading)
            }
        }
        // A memoized diff hands back the same array, so this comparison is the
        // storage-identity fast path on every pass but a file switch. `initial`
        // covers a diff that reappears after a placeholder, whose earlier
        // widest row this view's state would otherwise still carry.
        .onChange(of: lines, initial: true) { remeasure() }
        .onChange(of: fontSize) { remeasure() }
        .background(ZoomSurfaceMarker(kind: .code))
    }

    /// Forgets the widest row and rebuilds the rows so every realized one
    /// reports again. Zeroing alone is not enough: `onGeometryChange` reports
    /// only a *change*, so a row whose width survived the new lines (same text
    /// length at the same index) would never report, and the content would fall
    /// back to the pane and strand an overflowing line out of scroll reach.
    private func remeasure() {
        widestRow = 0
        measureGeneration += 1
    }

    private func row(_ line: UnifiedDiffLine) -> some View {
        HStack(spacing: 6) {
            checkbox(for: line)
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign(line.kind) + line.text)
                .font(.system(size: fontSize, design: .monospaced))
                // A diff row is file content drawn at the code font, so its
                // colour comes from the one table rather than from SwiftUI's
                // default label: that default is not the design's value (the
                // palette's plain row is `#1d1d1f`/`#dfe1e5`, the label colour is
                // pure black/white), so an unstated foreground would put this
                // panel a step off the table beside the editor behind the sheet.
                // Only the *text* is stated; the added/removed tint stays a
                // background, so a row still reads as added or removed.
                .foregroundStyle(Color(SyntaxTheme.shared.color(for: .plain)))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // The row's natural width, read before the fill below: the row hugs its
        // content here (no spacer inside it), so what it reports is its own
        // width and never the width it is later given, which would ratchet the
        // content wider than the pane after a resize.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width > widestRow { widestRow = width }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .contentShape(Rectangle())
        // Clicking anywhere on a changed line toggles it — the checkbox is a
        // small target and the whole row reads as one change.
        .onTapGesture {
            guard isMutable, let unit = line.unitIndex else { return }
            onToggleUnit(unit)
        }
    }

    @ViewBuilder
    private func checkbox(for line: UnifiedDiffLine) -> some View {
        if let unit = line.unitIndex {
            let isOn = selectedUnits.contains(unit)
            Button { onToggleUnit(unit) } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(theme.color(isOn ? .accent : .textSecondary))
            }
            .buttonStyle(.borderless)
            .help("Include this change in the commit")
            .disabled(!isMutable)
        } else {
            // A context line is not a unit and must never look like one.
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: max(9, fontSize - 2), design: .monospaced))
            .foregroundStyle(theme.color(.textSecondary))
            .frame(width: 34, alignment: .trailing)
    }

    private func sign(_ kind: UnifiedDiffLine.Kind) -> String {
        switch kind {
        case .context: return "  "
        case .removed: return "- "
        case .added: return "+ "
        }
    }

    /// The row's wash: Core's one answer, `nil` (a context line) drawing none.
    private func background(_ kind: UnifiedDiffLine.Kind) -> Color {
        ChromeColorRole.diffWashRole(for: kind).map { theme.color($0) } ?? .clear
    }
}

#endif
