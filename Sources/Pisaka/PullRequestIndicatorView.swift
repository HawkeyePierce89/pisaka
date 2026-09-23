#if os(macOS)
import SwiftUI
import PisakaCore

/// The bottom-bar pull request indicator: `#53` plus what its checks say, for the
/// branch that is checked out right now.
///
/// It sits beside the branch switcher because it answers the branch widget's
/// unasked second question. The widget says which branch this is; this says
/// whether that branch has a pull request open and whether its checks are green
/// — the two facts that decide what happens next on a branch being worked on,
/// and the reason the alternative is a browser tab kept open beside the editor.
///
/// **Absent rather than empty.** Nothing is drawn when the current branch has no
/// open pull request, when `gh` is not ready, and — the case worth naming — on a
/// detached HEAD, where there is no branch to have one. A widget reading "no
/// pull request" would occupy the bar permanently to say nothing, and on a
/// repository nobody opens pull requests from it would say it forever.
/// `PullRequestModel.currentBranchPullRequest` is `nil` in all three, which is
/// the whole condition below.
///
/// It reads the same model the panel does — one `gh` answer, two surfaces, no
/// second read — and clicking it opens the panel with that row expanded, which
/// is the one thing it does. Chrome, sized through `\.interfaceMetrics`, and no
/// zoom surface, like every other control in the bar.
struct PullRequestIndicatorView: View {
    @ObservedObject var model: PullRequestModel
    /// Show the Pull Requests panel and expand this row. Wired in `ContentView`
    /// to the same panel toggle the bottom bar's buttons use; default no-op so
    /// previews/tests can construct the view without the app wiring.
    var onOpen: (Int) -> Void = { _ in }

    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome theme, read from the environment the window root injects: the
    /// widget's own colours are roles, the checks mark's three status roles
    /// included.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        if let pullRequest = model.currentBranchPullRequest {
            Button {
                onOpen(pullRequest.number)
            } label: {
                HStack(spacing: metrics.scaled(4)) {
                    // Three elements: what this is, which one it is, and what
                    // its checks say. The leading glyph is the one the Pull
                    // Requests toggle uses — the two now sit at opposite ends of
                    // the bar, so the adjacency that once argued against sharing
                    // a glyph no longer applies.
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundStyle(theme.color(.textSecondary))
                    // The same single-line rule its two neighbours carry, swept
                    // as a construct rather than fixed where it already hurts: a
                    // number does not wrap today, but every `Text` drawn inside
                    // the bar's fixed-height frame is clipped rather than
                    // accommodated when it does, so the rule is the bar's, not
                    // this string's.
                    Text("#\(pullRequest.number)")
                        .lineLimit(1)
                        .monospacedDigit()
                        .foregroundStyle(theme.color(.textSecondary))
                    // Glyph, role and words are Core's one answer, shared with the
                    // panel's row: `circle` for no checks is this widget's own
                    // earlier choice, now the panel's too.
                    Image(systemName: pullRequest.summary.symbolName)
                        .foregroundStyle(theme.color(.checksRole(for: pullRequest.summary)))
                }
                .font(metrics.scaledFont(.callout))
                // No padding of its own: the bottom bar owns the 14-point gaps
                // between its widgets and its own height. The whole label stays
                // the click target through `contentShape`.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText(pullRequest))
            .accessibilityLabel("Pull request #\(pullRequest.number)")
            .accessibilityValue(pullRequest.summary.spokenWords)
        }
    }

    /// The tooltip carries the title, because the button itself is four
    /// characters wide and the number alone identifies a pull request only to
    /// somebody who already knows which one it is.
    private func helpText(_ pullRequest: GitHubPullRequest) -> String {
        "#\(pullRequest.number) \(pullRequest.title) — \(pullRequest.summary.spokenWords)"
    }
}

#endif
