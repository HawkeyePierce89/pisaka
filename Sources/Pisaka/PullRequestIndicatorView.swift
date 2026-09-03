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

    var body: some View {
        if let pullRequest = model.currentBranchPullRequest {
            Button {
                onOpen(pullRequest.number)
            } label: {
                HStack(spacing: metrics.scaled(4)) {
                    Image(systemName: Self.symbol(pullRequest.summary))
                        .foregroundStyle(Self.color(pullRequest.summary))
                    Text("#\(pullRequest.number)")
                        .monospacedDigit()
                }
                .font(metrics.scaledFont(.callout))
                .padding(.horizontal, metrics.scaled(8))
                .padding(.vertical, metrics.scaled(3))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText(pullRequest))
            .accessibilityLabel("Pull request #\(pullRequest.number)")
            .accessibilityValue(Self.summaryWords(pullRequest.summary))
        }
    }

    /// The tooltip carries the title, because the button itself is four
    /// characters wide and the number alone identifies a pull request only to
    /// somebody who already knows which one it is.
    private func helpText(_ pullRequest: GitHubPullRequest) -> String {
        "#\(pullRequest.number) \(pullRequest.title) — \(Self.summaryWords(pullRequest.summary))"
    }

    private static func symbol(_ summary: GitHubChecksSummary) -> String {
        switch summary {
        case .noChecks: return "arrow.triangle.pull"
        case .pending: return "clock"
        case .failure: return "xmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private static func color(_ summary: GitHubChecksSummary) -> Color {
        switch summary {
        case .noChecks: return .secondary
        case .pending: return .orange
        case .failure: return .red
        case .success: return .green
        }
    }

    private static func summaryWords(_ summary: GitHubChecksSummary) -> String {
        switch summary {
        case .noChecks: return "No checks"
        case .pending: return "Checks running"
        case .failure: return "Checks failed"
        case .success: return "Checks passed"
        }
    }
}

#endif
