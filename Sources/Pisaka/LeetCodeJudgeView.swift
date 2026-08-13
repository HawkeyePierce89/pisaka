#if os(macOS)
import PisakaCore
import SwiftUI

/// Run and Submit, under the statement in the description pane.
///
/// **It observes `LeetCodeJudgeModel`, not `LeetCodeModel`.** That is the whole
/// reason the judge is a companion model rather than more members on its owner:
/// this view binds a `TextEditor` to `judge.testInput`, so it re-renders on every
/// keystroke in the test-case box — and observing the owner would put the account
/// state, the statement and the pane's own web view on that path.
///
/// **The editor arrives deliberately non-observed.** `workspace` is a plain `let`
/// for the reason `ContentView` states where it holds `commitDialog` and
/// `symbolIndex` the same way: an `@ObservedObject` would re-render this section
/// on every keystroke *in the file being solved*, which is the one text the user
/// types the most. Nothing here reads the buffer at render time — the judge reads
/// it once, synchronously, when a button is pressed (`liveSource(forFileAt:)`),
/// which is also what makes "what you see is what is judged" true without a save.
///
/// This view makes no decision of its own: availability, the phase, the verdict
/// and every sentence come from Core. What is left here is layout — and the one
/// piece of presentation state, `shownKind`, which only decides *which* of the two
/// finished results the area below the buttons is showing.
struct LeetCodeJudgeSection: View {
    @ObservedObject var judge: LeetCodeJudgeModel

    /// The editor the judged bytes come out of. See the type's note for why this
    /// is not observed; `nil` only in a default-constructed view (previews).
    var workspace: WorkspaceModel?

    /// The active tab's file and the configured LeetCode folder — the pair the
    /// association rule needs, since a file's *name* names a problem only when
    /// the file also sits inside that folder.
    var fileURL: URL?
    var folder: URL?

    /// Which result the area below the controls shows.
    ///
    /// `lastRun` and `lastSubmit` are separate published values on purpose (they
    /// are different shapes and a submit must not erase what a run just showed),
    /// so *something* has to say which one is on screen. It is set when a button
    /// is pressed rather than derived from the model, because "the one the user
    /// just asked for" is a fact about this surface and not about the judge.
    @State private var shownKind: LeetCodeJudgeKind = .run

    /// How tall the result area may grow before it scrolls. The statement above
    /// is what the pane is mostly for; a Wrong Answer with four long fields must
    /// not push it off the top.
    private static let resultMaximumHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            testCaseBox
            resultArea
        }
        .padding(8)
        // The statement pane's own key, on the same two halves: re-pointing the
        // folder has to re-ask the question for the tab already open. `prepare`
        // is a no-op for a repeat of the same file, so a re-render costs nothing
        // and never throws away what the user typed into the box.
        .task(id: preparationKey) {
            judge.workspace = workspace
            await judge.prepare(forFileAt: fileURL, in: folder)
        }
    }

    private var preparationKey: String {
        (fileURL?.path ?? "") + "\u{0}" + (folder?.path ?? "")
    }

    // MARK: - The controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Run") {
                shownKind = .run
                Task { await judge.run() }
            }
            .disabled(!judge.availability.isReady)

            Button("Submit") {
                shownKind = .submit
                Task { await judge.submit() }
            }
            .disabled(!judge.availability.isReady)

            if judge.phase.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(judge.phase.kind == .submit ? "Submitting…" : "Running…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            // A disabled button always has something to say — that is what
            // `LeetCodeJudgeAvailability` carries a sentence per case for. While a
            // run is in flight the spinner beside it already says the same thing,
            // so the badge stands down rather than repeating it.
            if !judge.phase.isRunning, let reason = judge.availability.reason {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .help(reason)
                    .accessibilityLabel(reason)
            }
        }
        // Both buttons carry the same explanation, so hovering either one answers
        // "why can I not press this?" without hunting for the badge.
        .help(judge.availability.reason ?? "Run against the test cases below, or submit to LeetCode.")
    }

    // MARK: - The editable input

    private var testCaseBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Test Cases")
                .font(.caption)
                .foregroundColor(.secondary)
            // Prefilled from the problem's own examples and used verbatim by Run;
            // Submit ignores it entirely. Session state — never written to disk.
            TextEditor(text: $judge.testInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 46, maxHeight: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor))
                )
        }
    }

    // MARK: - The result

    @ViewBuilder
    private var resultArea: some View {
        if let error = judge.lastError {
            scrolling {
                Text(error.localizedDescription)
                    .foregroundColor(.red)
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

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.resultMaximumHeight)
    }

    @ViewBuilder
    private func runResult(_ result: LeetCodeRunResult) -> some View {
        // On a **run**, code 10 means "it executed", not "it is right" — which is
        // exactly why `matchedExpected` exists and why it, not the verdict, is
        // what colours this header.
        verdict(result.verdict, isGood: result.verdict == .accepted && result.matchedExpected != false)
        if let matched = result.matchedExpected {
            Text(matched
                ? "Output matched the expected answer."
                : "Output did not match the expected answer.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        measurements(runtime: result.runtime, memory: result.memory)
        ForEach(Array(0..<caseCount(of: result)), id: \.self) { index in
            VStack(alignment: .leading, spacing: 2) {
                Text("Case \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                field("Input", result.inputs[safe: index])
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
                .foregroundColor(.secondary)
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

    /// The verdict, spelled the way LeetCode spells it so a user comparing
    /// against the site reads the same words.
    private func verdict(_ verdict: LeetCodeVerdict, isGood: Bool) -> some View {
        Text(verdict.displayName)
            .font(.headline)
            .foregroundColor(isGood ? .green : .red)
    }

    @ViewBuilder
    private func measurements(runtime: String?, memory: String?) -> some View {
        // Absences stay absences: LeetCode omits the runtime on a compile error,
        // and a "0 ms" invented to fill the gap would read as a measurement.
        let parts = [runtime.map { "Runtime \($0)" }, memory.map { "Memory \($0)" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// The compile or runtime diagnostic, **in full**.
    ///
    /// Truncating it to a line is the single thing that would send the user back
    /// to the browser, which is the whole reason this section exists: the text is
    /// monospaced, selectable, wrapped rather than clipped, and scrolls with the
    /// rest of the result area.
    @ViewBuilder
    private func errorText(_ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
    }

    /// How many example cases the judge answered about — the longest of the four
    /// parallel arrays, since LeetCode omits some of them on some verdicts and a
    /// shorter one must not hide a case the others describe.
    private func caseCount(of result: LeetCodeRunResult) -> Int {
        max(
            max(result.inputs.count, result.answers.count),
            max(result.expectedAnswers.count, result.stdOutputs.count)
        )
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
