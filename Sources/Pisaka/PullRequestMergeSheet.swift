#if os(macOS)
import SwiftUI
import PisakaCore

/// The Merge sheet: how this pull request will be merged, what the commit will
/// say, and — above the button — every consequence of pressing it.
///
/// `NewPullRequestSheet`'s shape, deliberately: the same dock, the same kind of
/// publication, and the same division of labour. **Nothing here decides
/// anything.** Whether the button may be pressed, what it says, which methods
/// the picker offers, which of them it opens on, the pre-filled subject and each
/// of the three sentences are all `GitHubMergePlan`'s — one value the button, the
/// model's own refusal and every tick of `PullRequestMergeWait` are read from, so
/// none of the three can word a state differently from the others.
///
/// **The button is two buttons.** When the plan allows a merge it reads *Merge*
/// and merges; when the plan's refusal is one a reader would knowingly sit
/// through — checks still running, and nothing else — it reads *Merge when checks
/// pass* and arms the wait instead. Which of the two it is is the plan's
/// `armsWait`, and the label is the plan's too: a button reading "Merge" that
/// quietly armed a half-hour wait would be the same bug as one reading "Merge
/// when checks pass" that merged immediately. Every other refusal disables it
/// under that refusal's own sentence.
///
/// A failure leaves the sheet open with every field intact and `gh`'s own words
/// under them, for the create sheet's reason: the reader has just chosen a method
/// and possibly typed a commit message, and closing over that to show a sentence
/// costs more than the sentence is worth. A merge that *landed* closes the
/// sheet — the row is gone from the list behind it — and so does an arming, whose
/// whole point is to stop anybody sitting in front of this.
struct PullRequestMergeSheet: View {
    @ObservedObject var model: PullRequestModel
    /// The wait, observed as well as the model.
    ///
    /// It is a separate object on purpose (the panel's rows observe it rather
    /// than the whole model), so a sheet that only observed the model would draw
    /// its button from a wait it never hears from — and this sheet is the one
    /// place a wait is armed.
    @ObservedObject var wait: PullRequestMergeWait
    /// The refresh triggers' owner, and the one route from a surface to the
    /// merge's post-merge tail.
    let coordinator: PullRequestCoordinator
    /// Which pull request this sheet is about. The row itself is deliberately not
    /// carried: the plan is decided from the row the model holds when
    /// `prepareMerge` runs, and a copy taken when the sheet was raised would be a
    /// second reading free to disagree with it.
    let number: Int

    init(model: PullRequestModel, coordinator: PullRequestCoordinator, number: Int) {
        self._model = ObservedObject(wrappedValue: model)
        self._wait = ObservedObject(wrappedValue: model.mergeWait)
        self.coordinator = coordinator
        self.number = number
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceMetrics) private var metrics

    /// The selected method — `nil` until the plan has said which ones exist, so
    /// the sheet never opens on one this repository disallows.
    @State private var method: GitHubMergeMethod?
    @State private var subject = ""
    /// The commit body. Not `body`, which is the view's own.
    @State private var commitBody = ""

    /// Whether `prepareMerge(number:)` came back having published neither a plan
    /// nor a sentence — the one way this sheet can be left with nothing to draw.
    ///
    /// **View-local on purpose.** That read returns silently when its generation
    /// token moved, which is `clearRows()` blanking the panel behind the sheet: a
    /// refresh that found `gh` not ready, a project closed, a folder switched.
    /// The model is right not to publish there — the sentence explaining *that*
    /// is already in its one slot under `.refresh`, and a `.merge` message
    /// written over it would replace a specific reason with a general one. But
    /// `reading` draws its spinner on "no plan **and** no message", so the sheet
    /// would sit on "Reading this repository's merge settings…" for as long as
    /// it is left open: `.task` runs once, so nothing retries and nothing ever
    /// says why. The state is therefore read back *here*, where saying so costs
    /// the model nothing.
    @State private var readWasSuperseded = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(10)) {
            Text("Merge Pull Request")
                .font(metrics.scaledFont(.headline, weight: .semibold))

            if let plan = model.mergePlan {
                fields(plan)
                sentences(plan)
            } else {
                reading
            }

            if let message = model.mergeMessage {
                Text(message)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .padding(metrics.scaled(16))
        .frame(width: metrics.scaled(560))
        .task { await prepare() }
        // Every way out — Cancel, Esc, and the `dismiss()` a merge or an arming
        // runs — reaches this one place, which is why the clear is here and not
        // on the Cancel button. The panel draws the slot raw, so a refusal left
        // behind would sit above a list that has since refreshed cleanly.
        .onDisappear { model.dismissMerge() }
    }

    /// What the sheet shows before `gh repo view` has answered.
    ///
    /// Once there *is* a sentence it draws nothing at all: the message slot
    /// below carries the reason in the failing read's own words, and every way
    /// of reaching this state without a plan now leaves one — a failed
    /// `repo view`, `gh` no longer being ready, and a row a refresh dropped are
    /// three different sentences, and a fixed second line above them could only
    /// agree with one.
    ///
    /// The fourth way leaves no sentence in the model's slot by design (see
    /// ``readWasSuperseded``), so this draws that one itself rather than
    /// spinning forever: the *panel* behind the sheet is already saying what
    /// went wrong with `gh` or the project, and what is owed here is the same
    /// thing every other exit owes — why the sheet has nothing, and what to do.
    @ViewBuilder
    private var reading: some View {
        if readWasSuperseded {
            Text(PullRequestModel.unavailableMessage)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(Color.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.mergeMessage == nil {
            HStack(spacing: metrics.scaled(6)) {
                ProgressView().controlSize(.small)
                Text("Reading this repository’s merge settings…")
            }
            .font(metrics.scaledFont(.callout))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fields

    /// The method, and — for the two methods GitHub composes a commit for — what
    /// that commit will say.
    ///
    /// Both fields are hidden for Rebase, which replays the pull request's own
    /// commits and writes nothing of its own; the command sends neither there
    /// either, and `GitHubMergeMethod.composesACommit` is the one place that is
    /// decided.
    @ViewBuilder
    private func fields(_ plan: GitHubMergePlan) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            if plan.showsMethodPicker {
                Picker("Method", selection: $method) {
                    ForEach(plan.allowedMethods, id: \.self) { allowed in
                        Text(Self.methodLabel(allowed)).tag(Optional(allowed))
                    }
                }
                .font(metrics.scaledFont(.body))
                .frame(maxWidth: metrics.scaled(320))
            }

            if method?.composesACommit == true {
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .font(metrics.scaledFont(.body))

                TextEditor(text: $commitBody)
                    .font(metrics.scaledFont(.body, design: .monospaced))
                    .frame(height: metrics.scaled(110))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.scaled(5))
                            .stroke(Color.secondary.opacity(0.35))
                    )
            }
        }
    }

    /// The one merge method that is *not* a merge commit is still a merge, so all
    /// three are named the way GitHub names them.
    private static func methodLabel(_ method: GitHubMergeMethod) -> String {
        switch method {
        case .merge: return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    // MARK: - The sentences

    /// Everything the button will do, in the plan's own words — each `nil` when
    /// there is nothing truthful to say.
    ///
    /// The refusal is drawn *beside* them rather than instead of them: what the
    /// merge is about stays true while the button under it is greyed out, which
    /// is exactly when a reader is looking for it.
    @ViewBuilder
    private func sentences(_ plan: GitHubMergePlan) -> some View {
        VStack(alignment: .leading, spacing: metrics.scaled(4)) {
            if let refusal = plan.refusal {
                Label(refusal.message, systemImage: "exclamationmark.triangle")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(Color.orange)
            }
            Text(plan.mergeSentence)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
            if let tail = plan.tailSentence {
                Text(tail)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
            }
            if let deletion = plan.deleteBranchSentence {
                Text(deletion)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(.secondary)
            }
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
                .keyboardShortcut(.cancelAction)
            Button(model.mergePlan?.buttonTitle ?? GitHubMergePlan.mergeButtonTitle) {
                Task { await submit() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    /// The button's gate, and every term of it is Core's: the plan's own — which
    /// covers the method, the subject a commit-producing method needs, and
    /// whether this state offers anything at all — and the model's
    /// `mergeIsAvailable`, which is this feature's one-write rule plus "no wait is
    /// already armed".
    private var canSubmit: Bool {
        guard let plan = model.mergePlan, let method else { return false }
        return model.mergeIsAvailable && plan.buttonIsEnabled(method: method, subject: subject)
    }

    // MARK: - The two flows

    /// Read the repository and the checked-out branch, then seed the fields from
    /// the plan that read produced.
    ///
    /// The method is the plan's default — the viewer's own, falling back to the
    /// first the repository allows — and the subject is GitHub's, `<title> (#N)`,
    /// so a reader who changes nothing gets the commit GitHub would have written.
    private func prepare() async {
        await model.prepareMerge(number: number)
        // Asked in exactly this order: a plan is the good answer, a sentence in
        // the merge slot is the honest bad one, and neither means the read was
        // dropped past a moved token with the panel behind it already blanked.
        readWasSuperseded = model.mergePlan == nil && model.mergeMessage == nil
        guard let plan = model.mergePlan else { return }
        if method == nil { method = plan.defaultMethod }
        if subject.isEmpty { subject = plan.defaultSubject }
    }

    /// Merge now, or arm the wait — whichever the button said it would do.
    ///
    /// The plan is read here rather than captured when the button was drawn,
    /// because `prepareMerge(number:)` publishes it asynchronously and this sheet
    /// is on screen before that read lands. The only thing that republishes it
    /// behind an open sheet is a merge started *from* this sheet, which re-decides
    /// and publishes the plan it decided from — so what is read here is either the
    /// sheet's own prepared plan or the one its own press produced.
    ///
    /// Neither branch below trusts it as the last word anyway, which is what
    /// makes that fine: `merge(…)` re-decides from the row the list holds now and
    /// refuses a state that went bad, and an armed wait polls immediately, so a
    /// row that went green behind the sheet is merged by that first tick rather
    /// than waited out.
    private func submit() async {
        guard let plan = model.mergePlan, let method else { return }
        if plan.canMerge {
            let merged = await coordinator.merge(
                number: number,
                method: method,
                subject: subject,
                body: commitBody
            )
            if merged { dismiss() }
        } else if wait.arm(plan: plan, method: method, subject: subject, body: commitBody) {
            dismiss()
        }
    }
}

#endif
