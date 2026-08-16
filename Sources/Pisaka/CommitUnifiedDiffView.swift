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
    /// row draws at `fontSize`, so the checkbox column, the number gutter and the
    /// row's own spacing are derived from that same number and are deliberately
    /// left off the interface scale — the Find in Files result rows' rule, which
    /// exists so the two zones cannot interact.
    @Environment(\.interfaceMetrics) private var metrics

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
                .foregroundStyle(.tertiary)
            Text(text)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, metrics.scaled(24))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diff: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                // The index is the identity: the same text can legitimately appear
                // on many lines, and a `.modified` pair shares its unit index. It
                // is taken from `indices` rather than by wrapping the array in
                // `enumerated()`, which would build a fresh array of one tuple per
                // line on *every* body pass — and this body re-runs on every
                // keystroke in the message field, over a diff that can be tens of
                // thousands of lines long, which is the very cost
                // `CommitDialogModel.unifiedLines(for:)` is memoized to avoid.
                ForEach(lines.indices, id: \.self) { index in
                    row(lines[index])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func row(_ line: UnifiedDiffLine) -> some View {
        HStack(spacing: 6) {
            checkbox(for: line)
            number(line.oldNumber)
            number(line.newNumber)
            Text(sign(line.kind) + line.text)
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
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
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
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
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
    }

    private func sign(_ kind: UnifiedDiffLine.Kind) -> String {
        switch kind {
        case .context: return "  "
        case .removed: return "- "
        case .added: return "+ "
        }
    }

    private func background(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .context: return .clear
        case .removed: return Color.red.opacity(0.14)
        case .added: return Color.green.opacity(0.14)
        }
    }
}

#endif
