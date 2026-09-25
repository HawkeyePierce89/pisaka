#if os(macOS)
import SwiftUI
import PisakaCore

/// The New Pull Request sheet: a title, a body, the base to open it into, a
/// Draft checkbox — and, above the buttons, the three sentences naming
/// everything Create will actually do.
///
/// `CommitDialogView`'s shape, deliberately: this sheet is reached from the same
/// bottom dock, performs the same kind of irreversible-ish publication, and its
/// refusals are literally the commit dialog's (`PushUnavailableReason`, with the
/// sentences that type already owns). What differs is that Create here runs up
/// to *three* operations the reader did not separately ask for — a push, possibly
/// the first publication of the branch to a remote, and the pull request itself —
/// which is why `GitHubCreatePlan` states each of them in words and this view
/// draws those words rather than composing any of its own.
///
/// Nothing here decides anything. The base default is `gh repo view`'s answer and
/// nothing else (G11); whether Create may run is `GitHubCreatePlan.canCreate`, and
/// the model re-asks it against a *fresh* commit context when the button is
/// pressed, so a branch switched behind an open sheet refuses rather than pushes.
/// A failure leaves the sheet open with every field intact — the reader has just
/// typed a description, and closing over it to show a message would cost more
/// than the message is worth.
struct NewPullRequestSheet: View {
    @ObservedObject var model: PullRequestModel
    /// The refresh triggers' owner, read here for the two things only it can
    /// answer: `HEAD`'s subject for the pre-filled title, and the local branch
    /// list the base field offers.
    let coordinator: PullRequestCoordinator

    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the Pull Requests panel that
    /// presents this sheet.
    @Environment(\.chromeTheme) private var theme

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var base = ""
    @State private var isDraft = false
    @FocusState private var focusedField: Field?

    /// The two text areas, for the shared field's focus ring.
    private enum Field: Hashable {
        case title
        case description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(10)) {
            Text("New Pull Request")
                .font(metrics.scaledFont(.headline, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))

            fields
            sentences

            if let message = model.createMessage {
                Text(message)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.statusRed))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .padding(metrics.scaled(16))
        .frame(width: metrics.scaled(560))
        .background(theme.color(.bgPanel))
        .task { await prepare() }
        // Every way out of the sheet — Cancel, Esc, and the `dismiss()` a
        // successful Create runs — reaches this one place, which is why the
        // clear lives here rather than on the Cancel button. A `.create`
        // sentence is only ever drawn by this view; left behind, the panel would
        // go on showing it above a list that has since refreshed cleanly.
        .onDisappear { model.dismissCreate() }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            ChromeThemedTextField(
                title: "Title",
                text: $title,
                focus: $focusedField,
                focusedEquals: .title,
                textStyle: .body
            )

            // The commit dialog's message box: the shared box around the
            // editor, which hides its own scroll ground so `bgEditor` shows.
            ChromeControlBox(
                isFocused: focusedField == .description,
                horizontalPadding: ChromeGeometry.fieldPaddingX
            ) {
                TextEditor(text: $descriptionText)
                    .font(metrics.scaledFont(.body, design: .monospaced))
                    .foregroundStyle(theme.color(.textPrimary))
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .description)
                    .frame(height: metrics.scaled(140))
            }

            HStack(spacing: metrics.scaled(10)) {
                ChromeMenuField(
                    label: "Base",
                    options: baseOptions,
                    selection: $base,
                    currentTitle: base.isEmpty ? Self.noBaseTitle : base
                )
                .frame(height: metrics.scaled(ChromeGeometry.menuFieldHeight))
                .frame(maxWidth: metrics.scaled(280))
                .onChange(of: base) { model.setCreateBase($0) }

                // An option of this one action, not a standing preference, so
                // it is the commit dialog's checkbox rather than a switch.
                ChromeCheckbox(
                    state: isDraft ? .on : .off,
                    label: "Draft",
                    title: "Draft"
                ) { isDraft.toggle() }

                Spacer()
            }
        }
    }

    /// What the base field shows while `repo view` has not answered.
    private static let noBaseTitle = "—"

    /// The base field's options. The empty selection is a real state — `repo
    /// view` did not answer — and it needs an option of its own while it lasts,
    /// or the field would name no branch while `base` is still `""` and Create
    /// stays disabled with no visible reason.
    private var baseOptions: [(value: String, title: String)] {
        let branches = baseChoices.map { (value: $0, title: $0) }
        return base.isEmpty ? [(value: "", title: Self.noBaseTitle)] + branches : branches
    }

    /// The local branches, plus whatever `repo view` named if the widget's list
    /// does not carry it. The second half is not defensive padding: the default
    /// branch of a fork's *own* repository may well have no local ref here, and a
    /// field that silently dropped the default it was given would replace the
    /// stated base with a different one.
    private var baseChoices: [String] {
        var choices = coordinator.localBranchNames
        if let defaultBranch = model.repository?.defaultBranch,
           !defaultBranch.isEmpty,
           !choices.contains(defaultBranch) {
            choices.insert(defaultBranch, at: 0)
        }
        return choices
    }

    // MARK: - The sentences

    /// Everything Create will do, in the plan's own words. Each is `nil` when
    /// there is nothing truthful to say, and the refusal replaces them when there
    /// is nothing to say it about.
    @ViewBuilder
    private var sentences: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            if let refusal = model.createPlan?.refusal {
                Label(refusal.message, systemImage: "exclamationmark.triangle")
                    .font(metrics.scaledFont(.caption))
                    // The create plan's refusal cannot be waited out.
                    .foregroundStyle(theme.color(.statusRed))
            }
            if let baseSentence = model.createPlan?.baseSentence {
                Text(baseSentence)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.textSecondary))
            }
            if let publish = model.createPlan?.publishSentence {
                Text(publish)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.textSecondary))
            }
            Text(GitHubCreatePlan.uncommittedChangesNote)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(theme.color(.textSecondary))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            if model.isWriteInFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.chromeSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                Task { await submit() }
            }
            .buttonStyle(.chromePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
    }

    /// The button's own gate, which is the plan's plus the two things only this
    /// view knows: a pull request needs a title, and a second Create may not
    /// start while the first is still pushing.
    private var canCreate: Bool {
        guard let plan = model.createPlan, plan.canCreate else { return false }
        return !model.isWriteInFlight
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The two flows

    /// Read the base default and the repository state, then seed the fields.
    ///
    /// The title is seeded from `HEAD`'s subject — the branch's most recent
    /// commit message is what a pull request opened from it is nearly always
    /// about — and only when the reader has not typed anything, so a `.task` that
    /// runs again cannot overwrite what they wrote.
    private func prepare() async {
        await model.prepareCreate()
        if base.isEmpty, let defaultBranch = model.repository?.defaultBranch {
            base = defaultBranch
        }
        // Read first, *then* test — never `if title.isEmpty { title = await … }`,
        // which checks before the suspension and assigns after it. `headSubject`
        // reaches `GitCLIService`'s one serial run queue and can sit behind a
        // Local Changes status or a Log refresh for seconds, which is ample time
        // to type a title this would then silently overwrite.
        let subject = await coordinator.headSubject()
        if title.isEmpty {
            title = subject
        }
    }

    /// Create, and close only on success. A failure has already put `gh`'s own
    /// words in the model's message slot, which this sheet is drawing above the
    /// buttons — `createMessage` rather than the raw slot, so a background
    /// refresh's failure cannot appear here as though Create had been refused.
    private func submit() async {
        let created = await coordinator.create(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: descriptionText,
            base: base,
            draft: isDraft
        )
        if created { dismiss() }
    }
}

#endif
