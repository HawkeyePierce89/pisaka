#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// The Pull Requests panel in the bottom dock: what GitHub says about this
/// repository's open pull requests, read through the user's own `gh`.
///
/// `UsagesPanelView`'s shape — a header, a divider, and a scrolling list of rows
/// — because it is the same kind of surface: a list of things elsewhere, each of
/// which the reader may act on. What it adds is a **not-ready state with a next
/// step**: `gh` is not a library this app ships, it is a binary the reader either
/// has or does not, so the three states in which there is nothing to list each
/// print their own sentence and the one command that fixes it
/// (`GitHubAvailability.message` / `.nextStep`). Neither sentence is composed
/// here.
///
/// The view holds no domain logic. The four-state availability, the rows, their
/// checks summaries, the per-job lists, the one message slot and the write flag
/// are all `PullRequestModel`'s published state; the argument list of every
/// command is `GitHubCommands`'. The only decisions here are which of those to
/// draw and which control to disable, and the disable term is a single one:
/// `isWriteInFlight`, read by New Pull Request, Checkout and refresh alike,
/// because the feature performs exactly one write at a time.
///
/// **The panel-shown refresh trigger lives here** (G9), as the one `.onAppear`
/// below. It is not in the scene and cannot be: the selected bottom panel is
/// `@State` in `ContentView`'s owner, publishing nothing the coordinator could
/// subscribe to, and "the panel is on screen" is a fact only the panel's own view
/// has. There is no timer beside it and no repeat — opening the panel is a read,
/// staying open is not.
///
/// **A browser is opened only on an explicit gesture.** `gh pr create` can open
/// one by itself and is never allowed to (`GitHubCommands` passes no such flag);
/// the two places a browser opens are the row's Open in Browser button and a
/// check's link, both of which are a click on a control that says so.
///
/// Chrome, not a code surface: everything is sized through `\.interfaceMetrics`
/// and the view declares **no** zoom surface, so a scroll over it resizes the
/// interface zone like every other panel in the dock. It states no minimum
/// height either — the slot's height is `BottomPanelHeightRule`'s and a minimum
/// inside it can only overflow (`BottomPanelSourceGatingTests` pins both rules).
struct PullRequestsPanelView: View {
    @ObservedObject var model: PullRequestModel
    /// Who owns the refresh triggers and the one checkout site. Held as a plain
    /// `let` rather than observed: nothing published on it is drawn here — the
    /// state this panel shows is the model's — and observing it as well would
    /// re-render the list for events that changed none of it.
    let coordinator: PullRequestCoordinator

    /// Whether the New Pull Request sheet is up. Local because it is: the sheet
    /// is a presentation of this panel and nothing outside it can raise one.
    @State private var isCreating = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // The panel-shown trigger, and the whole of it. `.onAppear` fires when
        // the panel enters the dock's slot and again each time it is reopened,
        // which is exactly the set of moments its contents are looked at.
        .onAppear { coordinator.panelShown() }
        .sheet(isPresented: $isCreating) {
            NewPullRequestSheet(model: model, coordinator: coordinator)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: metrics.scaled(8)) {
            Text("Pull Requests")
                .font(metrics.scaledFont(.headline, weight: .semibold))
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if !model.pullRequests.isEmpty {
                Text(countLabel)
                    .font(metrics.scaledFont(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("New Pull Request", systemImage: "plus")
                    .font(metrics.scaledFont(.callout))
            }
            .buttonStyle(.plain)
            .disabled(!model.isReady || model.isWriteInFlight)
            .help("Open a pull request from the current branch")

            Button {
                coordinator.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.callout))
            }
            .buttonStyle(.plain)
            .disabled(model.isWriteInFlight)
            .help("Re-read the list from GitHub")
            .accessibilityLabel("Refresh pull requests")
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
    }

    /// The header's count — `50+` at the cap, because `pr list` asks for
    /// `GitHubCommands.openListLimit` rows and no more.
    ///
    /// A repository with two hundred open pull requests would otherwise read
    /// "50 open", which is not a rounding: it is the panel stating a total it
    /// never asked for. The same reason `noChecks` is a case of its own rather
    /// than a `success` with nothing in it.
    private var countLabel: String {
        let count = model.pullRequests.count
        if count >= GitHubCommands.openListLimit { return "\(count)+ open" }
        return "\(count) open"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                messageStrip(message)
            }
            if let availability = model.availability, !availability.isReady {
                notReady(availability)
            } else if model.pullRequests.isEmpty {
                placeholder(emptyText)
            } else {
                list
            }
        }
    }

    /// The one message slot, drawn as a strip above whatever else the panel is
    /// showing rather than instead of it — a failed refresh leaves the previous
    /// list standing (the model's own rule), and a message that replaced the rows
    /// would throw away the only context it has.
    private func messageStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.scaled(6)) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.orange)
            Text(message)
                .font(metrics.scaledFont(.caption))
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    /// The three states in which there is nothing to list, each with the exact
    /// next step. Both strings are `GitHubAvailability`'s — the command is
    /// selectable so it can be copied into the terminal one tab away rather than
    /// retyped.
    private func notReady(_ availability: GitHubAvailability) -> some View {
        VStack(spacing: metrics.scaled(8)) {
            Spacer()
            Text(availability.message)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let step = availability.nextStep {
                Text(step)
                    .font(metrics.scaledFont(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, metrics.scaled(8))
                    .padding(.vertical, metrics.scaled(4))
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(5)))
            }
            Spacer()
        }
        .padding(metrics.scaled(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What an empty list means, distinguished from "not looked yet": the model
    /// publishes `availability == nil` until the first refresh has decided one,
    /// and accusing a repository of having no pull requests before anything has
    /// been asked is the same mistake the four-state enum exists to avoid.
    ///
    /// "Not looked yet" is itself two states, and the third line is the one that
    /// matters: the coordinator's root observer clears without starting a
    /// replacement read, so a folder switch whose branch never resolves — one
    /// detached HEAD to another, a non-repository to a detached HEAD — leaves an
    /// open repository sitting at `availability == nil` with no read in flight.
    /// Keyed on availability alone this said "No repository" about a repository
    /// that is open, and said it until the panel was hidden and shown again,
    /// which for a panel that never hid is never. So the root is asked, and the
    /// state that is really "nobody has looked" names the control that looks.
    private var emptyText: String {
        if model.availability != nil {
            // A read that *failed* never learned there are none. The rows are
            // empty here only because no good list was ever published (a failure
            // never blanks one that was), so the strip above says what went wrong
            // and this line must not claim the repository as evidence for it —
            // the same distinction between "nothing ran" and "everything passed"
            // that `noChecks` is a case of its own for.
            return model.errorMessage == nil ? "No open pull requests" : "Could not read pull requests."
        }
        if model.isLoading { return "Reading…" }
        return model.hasProjectRoot ? "Press Refresh to read pull requests." : "No repository"
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.pullRequests) { pullRequest in
                    PullRequestRow(
                        pullRequest: pullRequest,
                        isSelected: model.selectedNumber == pullRequest.number,
                        isExpanded: model.expandedNumber == pullRequest.number,
                        checks: model.checks[pullRequest.number],
                        checksFailed: model.checksFailures.contains(pullRequest.number),
                        isWriteInFlight: model.isWriteInFlight,
                        onToggle: { Task { await model.toggleExpansion(pullRequest.number) } },
                        onCheckout: { coordinator.checkout(pullRequest.number) }
                    )
                }
            }
            .padding(.vertical, metrics.scaled(4))
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                .padding(metrics.scaled(16))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One pull request: its number, title, author, `head → base`, the draft marker,
/// the review decision and the checks summary, over an expandable list of the
/// per-job checks `gh pr checks` answered for it.
private struct PullRequestRow: View {
    let pullRequest: GitHubPullRequest
    let isSelected: Bool
    let isExpanded: Bool
    /// The per-job list, or `nil` while it is still being read — which is a
    /// different thing from an empty one, and drawn as such.
    let checks: [GitHubCheckRow]?
    /// Whether this row's checks read failed. The third answer `checks` cannot
    /// carry: `nil` there is "still reading", and a failure that kept it would
    /// leave the row spinning for as long as it stays open.
    let checksFailed: Bool
    let isWriteInFlight: Bool
    let onToggle: () -> Void
    let onCheckout: () -> Void

    @State private var isHovering = false

    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryLine
            if isExpanded { checksList }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.accentColor.opacity(0.10) : Color.clear
    }

    private var summaryLine: some View {
        HStack(spacing: metrics.scaled(6)) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(Color.secondary)
                .frame(width: metrics.scaled(12))

            Image(systemName: Self.summarySymbol(pullRequest.summary))
                .foregroundStyle(Self.summaryColor(pullRequest.summary))
                .help(Self.summaryHelp(pullRequest.summary))

            Text("#\(pullRequest.number)")
                .font(metrics.scaledFont(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.secondary)

            Text(pullRequest.title)
                .font(metrics.scaledFont(.body, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if pullRequest.isDraft {
                tag("Draft", color: .secondary)
            }
            if let review = Self.reviewLabel(pullRequest.reviewDecision) {
                tag(review.text, color: review.color)
            }

            Spacer(minLength: metrics.scaled(6))

            Text(branchLabel)
                .font(metrics.scaledFont(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(pullRequest.authorLogin)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)

            Button("Checkout", action: onCheckout)
                .font(metrics.scaledFont(.caption))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isWriteInFlight)
                .help("Check this pull request's branch out into the working tree")

            Button {
                openInBrowser(pullRequest.url)
            } label: {
                Image(systemName: "safari")
                    .font(metrics.scaledFont(.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
            .help("Open on GitHub")
            .accessibilityLabel("Open pull request on GitHub")
        }
        .padding(.horizontal, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(3))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
    }

    private var branchLabel: String {
        "\(pullRequest.headRefName) → \(pullRequest.baseRefName)"
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(metrics.scaledFont(.caption2))
            .padding(.horizontal, metrics.scaled(5))
            .padding(.vertical, metrics.scaled(1))
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    /// The per-job list of the expanded row. `nil` is "still reading" and an
    /// empty array is "GitHub reported no jobs" — two different answers, and a
    /// spinner standing in for the second would never stop.
    ///
    /// A read that *failed* is the third answer and is drawn as such: the model
    /// leaves `checks` unset there, so without it the row would keep the spinner
    /// of the first state for as long as it stays expanded. The reason is `gh`'s
    /// own and is in the panel's message strip; this only stops the row claiming
    /// it is still working.
    @ViewBuilder
    private var checksList: some View {
        if checksFailed {
            Text("Could not read checks")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .padding(.leading, metrics.scaled(34))
                .padding(.bottom, metrics.scaled(4))
        } else if let checks {
            if checks.isEmpty {
                Text("No checks reported")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.leading, metrics.scaled(34))
                    .padding(.bottom, metrics.scaled(4))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Identified by position, not by name: two jobs of two
                    // workflows may share one, and `gh` hands the rows back in
                    // the order it printed them, which is the order drawn.
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, row in
                        checkRow(row)
                    }
                }
                .padding(.bottom, metrics.scaled(4))
            }
        } else {
            HStack(spacing: metrics.scaled(6)) {
                ProgressView().controlSize(.small)
                Text("Reading checks…")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, metrics.scaled(34))
            .padding(.bottom, metrics.scaled(4))
        }
    }

    private func checkRow(_ row: GitHubCheckRow) -> some View {
        HStack(spacing: metrics.scaled(6)) {
            Image(systemName: Self.bucketSymbol(row.bucket))
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(Self.bucketColor(row.bucket))
            Text(row.name)
                .font(metrics.scaledFont(.caption))
                .lineLimit(1)
            if !row.workflow.isEmpty {
                Text(row.workflow)
                    .font(metrics.scaledFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !row.description.isEmpty {
                Text(row.description)
                    .font(metrics.scaledFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: metrics.scaled(4))
            if !row.link.isEmpty {
                Button {
                    openInBrowser(row.link)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(metrics.scaledFont(.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondary)
                .help("Open this check on GitHub")
                .accessibilityLabel("Open check \(row.name) on GitHub")
            }
        }
        .padding(.leading, metrics.scaled(34))
        .padding(.trailing, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one place this feature opens a browser, reached from two buttons that
    /// say so. A url `gh` answered that will not parse simply does nothing:
    /// there is no repair for it here and no sentence worth interrupting a list
    /// with.
    ///
    /// **http/https only**, `LeetCodeDescriptionView`'s rule for its reason: a
    /// check's `detailsUrl` is published by whatever third-party integration
    /// posted the check, so it is untrusted text, and `NSWorkspace.open` would
    /// hand a `file:` url to the Finder or a custom scheme to whichever app
    /// claims it. Anything else is refused the same silent way an unparseable
    /// one is.
    private func openInBrowser(_ address: String) {
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - The vocabulary, drawn

    private static func summarySymbol(_ summary: GitHubChecksSummary) -> String {
        switch summary {
        case .noChecks: return "minus.circle"
        case .pending: return "clock"
        case .failure: return "xmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private static func summaryColor(_ summary: GitHubChecksSummary) -> Color {
        switch summary {
        case .noChecks: return .secondary
        case .pending: return .orange
        case .failure: return .red
        case .success: return .green
        }
    }

    private static func summaryHelp(_ summary: GitHubChecksSummary) -> String {
        switch summary {
        case .noChecks: return "No checks"
        case .pending: return "Checks running"
        case .failure: return "Checks failed"
        case .success: return "Checks passed"
        }
    }

    private static func bucketSymbol(_ bucket: GitHubCheckBucket) -> String {
        switch bucket {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .pending: return "clock"
        case .skipping: return "minus.circle"
        case .cancel: return "slash.circle"
        }
    }

    private static func bucketColor(_ bucket: GitHubCheckBucket) -> Color {
        switch bucket {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .orange
        case .skipping, .cancel: return .secondary
        }
    }

    /// The review decision as a tag, or `nil` for the one case that is not a
    /// decision at all: `""`, which `GitHubReviewDecision.none` carries and which
    /// means no review has been asked for. A tag reading "None" would look like a
    /// verdict.
    private static func reviewLabel(_ decision: GitHubReviewDecision) -> (text: String, color: Color)? {
        switch decision {
        case .none: return nil
        case .approved: return ("Approved", .green)
        case .changesRequested: return ("Changes requested", .red)
        case .reviewRequired: return ("Review required", .orange)
        }
    }
}

#endif
