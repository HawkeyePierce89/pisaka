import Foundation

/// The Xcode CI and the release workflow build with, read out of the workflows
/// themselves.
///
/// **This set is the one authority.** Every `maxim-lobanov/setup-xcode` step in
/// `.github/workflows/ci.yml` and `.github/workflows/release.yml` carries an
/// `xcode-version:`, and the set of those values must have exactly one member —
/// that member *is* the project's pinned toolchain. Nothing else states the
/// version on its own authority; every other spelling of it is a reader checked
/// against this value:
///
/// - `docs/RELEASING.md`'s anchored ``Pinned toolchain: Xcode `X.Y` `` phrase,
///   and every `xcodebuild` command line it spells, prefixed
///   `DEVELOPER_DIR=/Applications/Xcode_X.Y.app/Contents/Developer`
///   (`ReleaseWorkflowTests.testReleasingDocNamesTheWorkflowPin`).
/// - The `Makefile`'s `PINNED_XCODE_VERSION := X.Y`, which both names the
///   `PINNED_XCODE ?= /Applications/Xcode_$(PINNED_XCODE_VERSION).app` default
///   every `xcodebuild` it issues runs under and is what `toolchain` holds that
///   Xcode's reported version to
///   (`LintConfigurationTests.testMakefileRunsXcodebuildUnderThePinnedXcode`).
/// - `CLAUDE.md`'s Commands block, whose every `xcodebuild` command is prefixed
///   `DEVELOPER_DIR=/Applications/Xcode_X.Y.app/Contents/Developer`
///   (`LintConfigurationTests.testClaudeMdCommandsRunUnderThePinnedXcode`).
///
/// Three prose sites also spell the version and are deliberately **not**
/// readers: they record what that particular Xcode was observed to do, not
/// which Xcode is pinned, so no rule holds them equal to this value and a bump
/// owes each a hand revisit — the rest of `docs/RELEASING.md`'s toolchain
/// paragraph (why that version, and the `Makefile`'s path), `app-shell.md`'s
/// `CommandsBuilder` ceiling as read off that SDK, and `DependencyPinTests`'
/// doc comment on that Xcode's fresh-clone `Package.resolved` behaviour.
///
/// The workflows are read through `#filePath` with Foundation only, through the
/// shared `workflowJobs(in:)` / `workflowJobSteps(_:in:)` reading — so a
/// commented-out `xcode-version:` cannot count, and a step's extent and its
/// owning job come from the indentation that states them.
enum XcodePin {
    /// The two workflows that install an Xcode, by file name under
    /// `.github/workflows/`.
    static let workflows = ["ci.yml", "release.yml"]

    /// One `setup-xcode` step: where it sits and every `xcode-version:` it
    /// carries (exactly one, when the workflow is well-formed — kept as a list so
    /// a step with none or two is reportable rather than silently collapsed).
    struct Step: Hashable, CustomStringConvertible {
        let workflow: String
        let job: String
        let versions: [String]

        var description: String {
            "\(workflow) job `\(job)`: xcode-version \(versions.isEmpty ? "absent" : versions.joined(separator: ", "))"
        }
    }

    /// Why `pinnedVersion()` found no single value, naming every site.
    struct Disagreement: Error, CustomStringConvertible {
        let steps: [Step]

        var description: String {
            """
            The setup-xcode steps in \(XcodePin.workflows.joined(separator: " and ")) must all pin one \
            Xcode, as an exact release (`26.3`), and each must carry exactly one \
            `xcode-version:`. Found: \
            \(steps.isEmpty ? "no setup-xcode step at all" : steps.map(\.description).joined(separator: "; ")). \
            Set every one to the same version.
            """
        }
    }

    /// Every `setup-xcode` step across both workflows, in file order.
    static func steps() throws -> [Step] {
        try workflows.flatMap { try steps(in: text(of: $0), workflow: $0) }
    }

    /// Every active `xcode-version:` line across both workflows, wherever it
    /// sits — the count that must equal the steps' total, so a stray one outside
    /// any `setup-xcode` step is visible.
    static func versionLineCount() throws -> Int {
        try workflows.reduce(0) { count, workflow in
            count + activeYAMLLines(of: try text(of: workflow)).filter { $0.hasPrefix("xcode-version:") }.count
        }
    }

    /// The single pinned version, or a `Disagreement` naming every site when the
    /// steps carry more than one value, a step carries none or two, there are no
    /// steps, or the one value is not an exact release (`26.3`, `16.4.1`) —
    /// `latest-stable` or `26` in every step would agree with itself while
    /// letting the runner image choose the toolchain.
    static func pinnedVersion() throws -> String {
        let all = try steps()
        let values = Set(all.flatMap(\.versions))
        guard values.count == 1, all.allSatisfy({ $0.versions.count == 1 }), let only = values.first,
              only.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw Disagreement(steps: all)
        }
        return only
    }

    // MARK: - Parsing

    /// Every `setup-xcode` step of one workflow, through the shared
    /// `workflowJobSteps(_:in:)` reading.
    static func steps(in text: String, workflow: String) -> [Step] {
        workflowJobs(in: text).flatMap { job in
            workflowJobSteps(job, in: text)
                .filter { step in
                    step.contains { $0.hasPrefix("- uses: maxim-lobanov/setup-xcode@")
                        || $0.hasPrefix("uses: maxim-lobanov/setup-xcode@") }
                }
                .map { Step(workflow: workflow, job: job, versions: $0.compactMap(versionValue(of:))) }
        }
    }

    /// `26.3` out of `xcode-version: '26.3'` (either quote, or none, with any
    /// trailing comment dropped); `nil` for any other line.
    static func versionValue(of trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("xcode-version:") else { return nil }
        var value = trimmedLine.dropFirst("xcode-version:".count)
        if let comment = value.range(of: " #") { value = value[..<comment.lowerBound] }
        return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    // MARK: - Reading the repository

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static func text(of workflow: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/\(workflow)"), encoding: .utf8)
    }
}
