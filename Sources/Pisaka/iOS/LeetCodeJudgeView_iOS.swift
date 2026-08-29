#if os(iOS)
import PisakaCore
import SwiftUI
import UIKit

/// Run and Submit on iOS — the peer of the macOS `LeetCodeJudgeSection`, and the
/// same section in both of the statement's two shapes.
///
/// **Written once, into `LeetCodeDescriptionContent_iOS`.** That view is what the
/// regular-width pane and the compact-width sheet already share, so the adaptive
/// pattern LC-1 established carries the judge for free: there is no second copy
/// of this section for the sheet, and the two cannot drift apart.
///
/// **It observes `LeetCodeJudgeModel`, not `LeetCodeModel`** — the macOS section's
/// reason, restated: this view binds a `TextEditor` to `judge.testInput` and so
/// re-renders on every keystroke in the test-case box, and observing the owner
/// would put the account state, the statement and the web view above it on that
/// path.
///
/// **The editor arrives deliberately non-observed.** `workspace` is a plain `let`,
/// the hand-off `RootView_iOS` already makes for `commitDialog`-shaped values: an
/// `@ObservedObject` would re-render this section on every keystroke *in the file
/// being solved*. Nothing here reads the buffer at render time — the judge reads
/// it once, synchronously, when a button is pressed, which is what makes "what you
/// see is what is judged" true without a save.
///
/// The one thing this file has that macOS does not is **keyboard discipline**, and
/// it is three rules: the controls sit *above* the input so the keyboard can never
/// cover them; the box carries its own Done affordance (an inline button plus the
/// keyboard accessory) so a focused editor is never a trap; and the result area
/// stands down while the box is focused, so on a compact width the keyboard, the
/// box and the two buttons all fit at once.
struct LeetCodeJudgeSection_iOS: View {
    @ObservedObject var judge: LeetCodeJudgeModel

    /// The editor the judged bytes come out of. See the type's note for why this
    /// is not observed; `nil` only in a default-constructed view (previews).
    var workspace: WorkspaceModel?

    /// The active tab's file and the configured LeetCode folder — the pair the
    /// association rule needs, since a file's *name* names a problem only when the
    /// file also sits inside that folder.
    var fileURL: URL?
    var folder: URL?

    /// Which result the area below the controls shows. Set when a button is
    /// pressed rather than derived from the model, for the macOS section's reason:
    /// `lastRun` and `lastSubmit` are separate values on purpose, so "the one the
    /// user just asked for" is a fact about this surface alone.
    @State private var shownKind: LeetCodeJudgeKind = .run

    /// Whether the test-case box has the keyboard. Drives the Done affordance and
    /// the result area's standing down — see the type's note.
    @FocusState private var isEditingInput: Bool

    /// The run or submission in flight, held so leaving the surface can stop it.
    ///
    /// A `Task { }` started from a button inherits **no** cancellation from the
    /// enclosing `.task`, so without holding it a poll outlives the section it was
    /// going to answer — the `LeetCodeRoute_iOS` rule, on this axis. It matters
    /// more here than on macOS: on a compact width this section lives inside a
    /// sheet the user swipes away.
    @State private var judgeTask: Task<Void, Never>?

    /// How tall the result area may grow before it scrolls. The statement above is
    /// what the surface is mostly for; a Wrong Answer with four long fields must
    /// not push it off the top.
    private static let resultMaximumHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            testCaseBox
            resultArea
        }
        .padding(10)
        // The statement's own key, on the same two halves: re-pointing the folder
        // has to re-ask the question for the tab already open. `prepare` is a no-op
        // for a repeat of the same file, so a re-render costs nothing and never
        // throws away what the user typed into the box.
        .task(id: preparationKey) {
            judge.workspace = workspace
            await judge.prepare(forFileAt: fileURL, in: folder)
        }
        // Leaving the surface — the sheet swiped away, the statement cleared, the
        // screen popped — abandons whatever is in flight. Both halves are needed:
        // cancelling the task is what makes `URLSession` stop, and `cancel()` is
        // what moves the generation so a request already past its last suspension
        // publishes nothing. Neither undoes a submission LeetCode already has.
        .onDisappear {
            judgeTask?.cancel()
            judgeTask = nil
            judge.cancel()
        }
    }

    private var preparationKey: String {
        (fileURL?.path ?? "") + "\u{0}" + (folder?.path ?? "")
    }

    // MARK: - The controls

    /// Run, Submit and the progress indicator — **above** the input, which is the
    /// layout rule that keeps them off the keyboard on a compact width: the box
    /// grows towards the bottom of the screen and the buttons never follow it
    /// there.
    private var controls: some View {
        HStack(spacing: 10) {
            Button("Run") {
                isEditingInput = false
                shownKind = .run
                judgeTask = Task { await judge.run() }
            }
            .buttonStyle(.bordered)
            .disabled(!judge.availability.isReady)

            Button("Submit") {
                isEditingInput = false
                shownKind = .submit
                judgeTask = Task { await judge.submit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!judge.availability.isReady)

            if judge.phase.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(judge.phase.kind == .submit ? "Submitting…" : "Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
        }
        .overlay(alignment: .bottomLeading) {
            // A disabled button always has something to say — that is what
            // `LeetCodeJudgeAvailability` carries a sentence per case for. There is
            // no hover on a touch screen, so unlike macOS the sentence is *shown*
            // rather than offered as a tooltip; while a run is in flight the
            // spinner beside the buttons already says the same thing, so it stands
            // down rather than repeating it.
            if !judge.phase.isRunning, let reason = judge.availability.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 18)
                    .accessibilityLabel(reason)
            }
        }
        // The sentence hangs below the row, so the row reserves the space for it
        // instead of letting it overlap the box underneath.
        .padding(.bottom, judge.phase.isRunning || judge.availability.reason == nil ? 0 : 20)
    }

    // MARK: - The editable input

    private var testCaseBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Test Cases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // The dismissal affordance, in the section itself rather than only
                // on the keyboard's accessory bar: this view is hosted both inside
                // a `NavigationStack` (the compact sheet) and outside one (the
                // regular-width pane), and an inline button is the one that is
                // certainly there in both.
                if isEditingInput {
                    Button("Done") { isEditingInput = false }
                        .font(.caption)
                }
            }
            // Prefilled from the problem's own examples and used verbatim by Run;
            // Submit ignores it entirely. Session state — never written to disk.
            TextEditor(text: $judge.testInput)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isEditingInput)
                .frame(minHeight: 54, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(uiColor: .separator))
                )
                .toolbar {
                    // The second half of the Done affordance: the accessory bar
                    // above the keyboard, which is where iOS users look first.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isEditingInput = false }
                    }
                }
        }
    }

    // MARK: - The result

    /// The verdict and its details — **hidden while the box is focused**.
    ///
    /// On a compact width the keyboard takes roughly half the screen, and this
    /// area is the one piece of the section that can be given up for it: the
    /// controls must stay reachable and the box is what is being typed into, but a
    /// result the user is not looking at can wait until the keyboard goes away. It
    /// is not thrown away — nothing here is model state — so dismissing the
    /// keyboard brings it straight back.
    @ViewBuilder
    private var resultArea: some View {
        if !isEditingInput {
            if let error = judge.lastError {
                scrolling {
                    Text(error.localizedDescription)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            } else {
                switch shownKind {
                case .run:
                    if let result = judge.lastRun { scrolling { runResult(result) } }
                case .submit:
                    if let result = judge.lastSubmit { scrolling { submitResult(result) } }
                }
            }
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.resultMaximumHeight)
        // A drag over the result is also a way out of the keyboard, for the reader
        // who scrolled here instead of pressing Done.
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func runResult(_ result: LeetCodeRunResult) -> some View {
        // On a **run**, code 10 means "it executed", not "it is right" — which is
        // exactly why `matchedExpected` exists and why it, not the verdict, is what
        // colours this header.
        verdict(result.verdict, isGood: result.verdict == .accepted && result.matchedExpected != false)
        if let matched = result.matchedExpected {
            Text(matched
                    ? "Output matched the expected answer."
                    : "Output did not match the expected answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        measurements(runtime: result.runtime, memory: result.memory)
        // The echoed input, once and whole: LeetCode spells it one line per
        // *parameter*, so there is no per-case slice of it to show. See
        // `LeetCodeRunResult.input`.
        field("Input", result.input)
        ForEach(Array(0..<result.caseCount), id: \.self) { index in
            VStack(alignment: .leading, spacing: 2) {
                Text("Case \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                field("Output", result.answers[safe: index])
                field("Expected", result.expectedAnswers[safe: index])
                field("Stdout", result.stdOutputs[safe: index])
            }
            .padding(.top, 2)
        }
        errorText(result.errorText)
    }

    @ViewBuilder
    private func submitResult(_ result: LeetCodeSubmitResult) -> some View {
        verdict(result.verdict, isGood: result.verdict.isAccepted)
        if let correct = result.totalCorrect, let total = result.totalTestcases {
            Text("\(correct) / \(total) test cases passed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        measurements(
            runtime: result.runtime.map { measured($0, percentile: result.runtimePercentile) },
            memory: result.memory.map { measured($0, percentile: result.memoryPercentile) }
        )
        field("Input", result.lastTestcaseInput)
        field("Output", result.codeOutput)
        field("Expected", result.expectedOutput)
        field("Stdout", result.stdOutput)
        errorText(result.errorText)
    }

    /// The verdict, spelled the way LeetCode spells it so a user comparing against
    /// the site reads the same words.
    private func verdict(_ verdict: LeetCodeVerdict, isGood: Bool) -> some View {
        Text(verdict.displayName)
            .font(.headline)
            .foregroundStyle(isGood ? Color.green : Color.red)
    }

    @ViewBuilder
    private func measurements(runtime: String?, memory: String?) -> some View {
        // Absences stay absences: LeetCode omits the runtime on a compile error,
        // and a "0 ms" invented to fill the gap would read as a measurement.
        let parts = [runtime.map { "Runtime \($0)" }, memory.map { "Memory \($0)" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func measured(_ display: String, percentile: Double?) -> String {
        guard let percentile else { return display }
        return display + String(format: " (beats %.2f%%)", percentile)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// The compile or runtime diagnostic, **in full**.
    ///
    /// Truncating it to a line is the single thing that would send the user back to
    /// the browser, which is the whole reason this section exists: the text is
    /// monospaced, selectable, wrapped rather than clipped, and scrolls with the
    /// rest of the result area.
    @ViewBuilder
    private func errorText(_ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
    }

}

private extension Array {
    /// The element at `index`, or `nil` — the four arrays above are parallel but
    /// not guaranteed equal in length, and this view is not the place to crash
    /// over that.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
