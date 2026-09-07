import XCTest
@testable import PisakaCore

/// Static verification of the two SwiftLint configuration files — the
/// documents this repository makes its style authority.
///
/// `.swiftlint.yml` (root) and `Tests/.swiftlint.yml` (the nested child whose
/// relaxations apply to the test tree only) are data, not code, so nothing in
/// `swift test` would notice them changing. This suite reads both through
/// `#filePath`, in the `ReleaseWorkflowTests` mould: Foundation only, matched
/// against comment-stripped lines through the shared `YAMLLineMatching`
/// helper, so a setting that survives only inside a comment cannot satisfy an
/// assertion about the live setting.
///
/// Pinned here because each is the exact regression this ticket exists to
/// prevent or the shape another layer depends on:
///
///  * both config files exist at all;
///  * the root declares a three-component `swiftlint_version:` — the one pin
///    the pre-commit hook and the CI lint job read their enforcement target
///    from (SwiftLint itself only warns on a mismatch);
///  * `trailing_comma` carries `mandatory_comma: true` — the deliberate flip
///    of the tool default; silently reverting to the default would turn the
///    conformance sweep into hundreds of new violations nobody asked for;
///  * the root `included:` names `Sources` and `Tests` — drop either and the
///    linter silently judges less than the whole first-party tree;
///  * the child's `disabled_rules` equals its documented five-rule set **by
///    set equality**, so quietly widening the test-tree exemptions (adding a
///    rule here is free, removing a line of lint coverage) fails the suite;
///  * the root's own `disabled_rules` equals its documented three-rule set by
///    the same set equality, and every configured threshold equals its
///    measured ceiling — a raised ceiling or an added disable is lint
///    coverage lost without any source change a reviewer could catch;
///  * every *in-file* exemption — a lint-disable comment anywhere under
///    `Sources/` or `Tests/` — equals the small documented set by path, rule
///    and count, so an exemption added silently in a source file fails here
///    instead of passing review unnoticed;
///  * `.githooks/pre-commit` exists, is executable, and keeps the shape that
///    makes it a gate rather than a courtesy: it reads its version pin out of
///    `.swiftlint.yml`'s staged copy (never a literal of its own), collects
///    staged Swift files from exactly the authority's `included:` trees
///    (explicit paths bypass `included:`, so any other scope would make hook
///    and CI judge different commits), lints what is being committed
///    (`--strict`, `--force-exclude`, over a materialised index), never
///    rewrites staged content (`--fix` is absent) and never softens
///    (`|| true`-style escapes are absent), and every refusal branch reaches
///    `exit 1`;
///  * the CI lint job is the half that actually refuses a pull request — hooks
///    are not cloned and are bypassable — so it must download exactly the
///    pinned release (its URL's version component **equals**
///    `.swiftlint.yml`'s `swiftlint_version`: the cross-file pair that makes
///    hook, configuration and CI incapable of disagreeing), verify the
///    archive's digest before running it, lint with no config override (root
///    discovery is what merges the nested test config) and carry no escape
///    hatch;
///  * the contributor-facing documents stay truthful: README.md keeps the
///    one-time setup (`git config core.hooksPath .githooks`) and names
///    `.swiftlint.yml`, and CLAUDE.md names the style authority too — setup
///    instructions that quietly disappear are this repository's documented
///    failure mode.
final class LintConfigurationTests: XCTestCase {
    func testBothConfigurationFilesExist() throws {
        for relativePath in [Self.rootConfigPath, Self.childConfigPath] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repositoryRoot.appendingPathComponent(relativePath).path
            ), "missing \(relativePath) — the style authority must stay committed")
        }
    }

    func testRootDeclaresAThreeComponentSwiftLintVersion() throws {
        let version = try pinnedSwiftLintVersion()
        let components = version.split(separator: ".")
        XCTAssertEqual(components.count, 3,
                       "swiftlint_version must be a three-component version, got \(version)")
        XCTAssertTrue(components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
                      "swiftlint_version components must be numeric, got \(version)")
    }

    func testTrailingCommaIsMandatory() throws {
        let block = try XCTUnwrap(topLevelBlock("trailing_comma", in: try rootText()),
                                  ".swiftlint.yml has no trailing_comma block")
        XCTAssertEqual(block.filter { $0 == "mandatory_comma: true" }.count, 1,
                       """
                       trailing_comma must configure mandatory_comma: true — the deliberate \
                       opposite of the tool default. Reverting it silently reopens every \
                       collection literal in the tree.
                       """)
        XCTAssertFalse(block.contains("mandatory_comma: false"),
                       "trailing_comma.mandatory_comma must not be false")
    }

    func testRootIncludedNamesSourcesAndTests() throws {
        let included = try XCTUnwrap(topLevelBlock("included", in: try rootText()),
                                     ".swiftlint.yml has no included: block")
        let paths = Set(included.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil })
        XCTAssertEqual(paths, ["Sources", "Tests"],
                       "included: must name exactly the two first-party trees")
    }

    func testChildDisabledRulesEqualTheDocumentedSet() throws {
        let child = try XCTUnwrap(topLevelBlock("disabled_rules", in: try childText()),
                                  "Tests/.swiftlint.yml has no disabled_rules block")
        let rules = Set(child.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil })
        XCTAssertEqual(rules, Self.documentedChildExemptions,
                       """
                       Tests/.swiftlint.yml disables something other than the documented \
                       test-tree exemptions. Widen the set only by changing BOTH this file \
                       and the documented set here — an unexplained exemption is lint \
                       coverage lost.
                       """)
    }

    /// The root file's own `disabled_rules` — the rules switched off across BOTH
    /// trees, the more consequential half — equals its documented three-rule set
    /// **by set equality**, exactly like the child's set above. Every entry is a
    /// behavior kept out of the linter's reach and carries its reason beside it in
    /// `.swiftlint.yml`; a quietly added fourth rule is lint coverage lost.
    func testRootDisabledRulesEqualTheDocumentedSet() throws {
        let block = try XCTUnwrap(topLevelBlock("disabled_rules", in: try rootText()),
                                  ".swiftlint.yml has no disabled_rules block")
        let rules = Set(block.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil })
        XCTAssertEqual(rules, Self.documentedRootExemptions,
                       """
                       .swiftlint.yml disables something other than the documented rules. \
                       Widen the set only by changing BOTH the config (with its written \
                       reason) and documentedRootExemptions here — an unexplained \
                       exemption is lint coverage lost across both trees.
                       """)
    }

    /// The measured ceilings themselves. Each number's reason sits beside it in
    /// `.swiftlint.yml`, and each was measured over this tree — so a quietly
    /// raised ceiling is lint coverage lost without any source change at all,
    /// the same regression class as a silently reverted `mandatory_comma`.
    /// (The two scalar thresholds configure their bound directly rather than in
    /// a block, so they are matched on active lines instead.)
    func testRootThresholdsEqualTheirMeasuredCeilings() throws {
        let text = try rootText()
        for (rule, expected) in Self.documentedRootThresholds {
            let block = try XCTUnwrap(topLevelBlock(rule, in: text),
                                      "\(rule) is missing from .swiftlint.yml")
            for (key, value) in expected {
                XCTAssertEqual(block.filter { $0 == "\(key): \(value)" }.count, 1,
                               "\(rule).\(key) must stay \(value) — the measured ceiling")
            }
        }
        let active = try activeRootLines()
        for (rule, value) in ["large_tuple": "4", "function_parameter_count": "8"] {
            XCTAssertTrue(active.contains("\(rule): \(value)"),
                          "\(rule) must stay \(value) — the measured ceiling")
        }
    }

    /// Every in-file lint exemption under `Sources/` and `Tests/`, counted by
    /// (relative path, rule), must equal this dictionary.
    ///
    /// The config files are the authority for relaxations; a disable command
    /// inside a source file is an *additional*, easily-forgotten exemption that
    /// no `.yml` diff would ever reveal — which is exactly how it slips past
    /// review. The narrowest legal form (`:next`/`:previous`/`:this`) and any
    /// file-wide disable are all caught here; each entry's reason lives beside
    /// the marker it counts. A new exemption means changing BOTH the source
    /// file and this dictionary, with the reason written down.
    func testInFileExemptionsEqualTheDocumentedSet() throws {
        // Assembled from parts so this file — which necessarily discusses the
        // command to pin its uses — never matches its own needle below.
        let marker = "// swiftlint:" + "disable"
        var counts: [String: [String: Int]] = [:]

        for tree in ["Sources", "Tests"] {
            for url in try swiftFiles(under: tree) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let relativePath = tree + String(url.path.dropFirst(
                    Self.repositoryRoot.appendingPathComponent(tree).path.count))
                for line in text.components(separatedBy: .newlines) {
                    guard let markerRange = line.range(of: marker) else { continue }
                    // Scope suffixes (`:next`/`:previous`/`:this`) carry a colon and so
                    // fail the letter filter below; commas separate rule lists in a
                    // disable command and are folded to separators here, so each rule in
                    // a list lands under its own name instead of a phantom catch-all.
                    let rules = line[markerRange.upperBound...]
                        .replacingOccurrences(of: ",", with: " ")
                        .split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .map(String.init)
                        .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0 == "_" } }
                    for rule in rules.isEmpty ? ["(every rule)"] : rules {
                        counts[relativePath, default: [:]][rule, default: 0] += 1
                    }
                }
            }
        }

        XCTAssertEqual(counts, Self.documentedInFileExemptions,
                       """
                       An in-file lint exemption appeared, moved, disappeared or changed \
                       count. In-file disables are exemptions outside the authority of the \
                       two configuration files; add or change one only by updating both the \
                       source comment (with its written reason) and documentedInFileExemptions \
                       here.
                       """)
    }

    // MARK: - The pre-commit hook

    /// `.githooks/pre-commit` is the local half of the enforcement; CI is the
    /// other. Both are only as good as their shape: a hook that skips when the
    /// tool is missing, rewrites staged content, or softens a violation into a
    /// warning is not a gate. These assertions pin that shape by mechanism —
    /// over comment-stripped lines, so a comment describing a refused branch
    /// cannot stand in for one.
    func testPreCommitHookExistsAndIsExecutable() throws {
        let path = Self.repositoryRoot.appendingPathComponent(Self.hookPath).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "missing \(Self.hookPath) — the local half of the gate must stay committed")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber,
                                        "\(Self.hookPath) has no POSIX permissions")
        XCTAssertTrue(permissions.uint16Value & 0o100 != 0,
                      "\(Self.hookPath) must carry the owner-execute bit (git runs hooks only if executable)")
    }

    func testPreCommitHookIsBinShWithSetEu() throws {
        XCTAssertEqual(try hookLines().first, "#!/bin/sh",
                       "the hook must run under plain /bin/sh, not a shell the author happened to have")
        XCTAssertTrue(try activeHookLines().contains("set -eu"),
                      "the hook must run with set -eu so a failed command fails the commit")
    }

    /// One source of truth for the version: the hook reads `swiftlint_version`
    /// out of `.swiftlint.yml`'s *staged* copy — the same place the rules it
    /// enforces come from. A hardcoded literal here would let hook and
    /// configuration disagree silently — SwiftLint itself only warns on a
    /// mismatch, which is why something else must enforce the pin at all.
    ///
    /// Matched as *active* lines because both files quote the key in their
    /// comments; a stripped body containing neither the key nor the file name
    /// means the read was deleted, and any three-component numeric literal in
    /// it means a second pin appeared.
    func testPreCommitHookReadsItsPinFromTheRootConfiguration() throws {
        let active = try activeHookText()
        XCTAssertTrue(active.contains("swiftlint_version:"),
                      "the hook must read swiftlint_version out of .swiftlint.yml rather than carrying its own pin")
        XCTAssertTrue(active.contains(".swiftlint.yml"),
                      "the hook must name .swiftlint.yml as the file its pin comes from")

        let regex = try NSRegularExpression(pattern: "[0-9]+\\.[0-9]+\\.[0-9]+")
        let range = NSRange(active.startIndex..., in: active)
        let matches = regex.matches(in: active, options: [], range: range).compactMap {
            Range($0.range, in: active).map { String(active[$0]) }
        }
        XCTAssertTrue(matches.isEmpty,
                     """
                     the hook contains a hardcoded version literal (\(matches.joined(separator: ", "))). \
                     The pin lives in .swiftlint.yml alone; a second one drifts from it and the \
                     gate then enforces the wrong version.
                     """)
    }

    func testPreCommitHookRunsStrictWithForceExcludeOverTheStagedIndex() throws {
        let active = try activeHookText()
        XCTAssertTrue(active.contains("--strict"),
                      "the hook must lint with --strict so warnings refuse too")
        XCTAssertTrue(active.contains("--force-exclude"),
                      "explicitly named paths need --force-exclude for excluded: to apply to them")
        XCTAssertTrue(active.contains("git checkout-index -a --prefix="),
                      """
                      the hook must lint what is being committed by materialising the index \
                      (git checkout-index), not the working tree — a partially staged file is \
                      judged by the content this commit will carry
                      """)
    }

    /// The hook's staged-file list must cover exactly the trees the style
    /// authority's `included:` names — no more, no less. The collected paths are
    /// handed to swiftlint explicitly, and explicit paths bypass `included:` under
    /// `--force-exclude`: an unscoped collection would judge files CI's
    /// discovery-mode run never sees (violations refused locally that CI waves
    /// through, and vice versa), a narrower one would leave files ungated
    /// everywhere. Derived from the config so the two cannot drift apart.
    func testPreCommitHookCollectsExactlyTheAuthoritysTrees() throws {
        let included = try XCTUnwrap(topLevelBlock("included", in: try rootText()),
                                     ".swiftlint.yml has no included: block")
        let trees = included.compactMap { $0.hasPrefix("- ") ? $0.dropFirst(2).trimmingCharacters(in: .whitespaces) : nil }
        XCTAssertFalse(trees.isEmpty, "included: must name at least one tree")
        let collectLine = try XCTUnwrap(
            try activeHookLines().first { $0.contains("--diff-filter=ACMR") },
            "the hook must collect staged files with git diff --cached --diff-filter=ACMR")
        XCTAssertEqual(collectLine,
                       "git diff --cached --name-only --diff-filter=ACMR -z -- "
                           + trees.map { "'\($0)/*.swift'" }.joined(separator: " ")
                           + " >\"$list\"",
                       """
                       the hook must collect staged Swift files from exactly the trees \
                       .swiftlint.yml's included: names (\(trees.joined(separator: ", "))) — \
                       explicit paths bypass included:, so any other scope makes the local \
                       gate judge a different commit than CI's discovery-mode run
                       """)
    }

    func testPreCommitHookNeverFixesAndNeverSoftens() throws {
        let active = try activeHookText()
        for forbidden in ["--fix", "|| true", "|| :"] {
            XCTAssertFalse(active.contains(forbidden), """
                the hook must not contain “\(forbidden)”. It refuses, or it is not a gate: \
                rewriting staged content loses what a person wrote; swallowing a failure \
                lets the commit through exactly when it should stop.
                """)
        }
    }

    /// Every refusal branch reaches `exit 1`, nesting-aware: an `if` opens at
    /// depth 0, a standalone `fi` closes it, and the counted `exit 1` must sit
    /// at depth 0 inside its own branch — an exit reachable only under a second
    /// condition is not this guard refusing.
    private func assertHookGuard(_ condition: String,
                                 exits exitLine: String,
                                 in lines: [String],
                                 because reason: String,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("if ") && $0.contains(condition) }) else {
            XCTFail("""
                \(Self.hookPath) has no guard testing \(condition). It must, because \(reason).
                """, file: file, line: line)
            return
        }

        var reaches = false
        var depth = 0
        for entry in lines[(start + 1)...] {
            if entry.hasPrefix("if ") { depth += 1; continue }
            if entry == "fi" {
                if depth == 0 { break }
                depth -= 1
                continue
            }
            if entry == exitLine, depth == 0 { reaches = true; break }
        }
        XCTAssertTrue(reaches, """
            \(Self.hookPath) tests \(condition) but its branch does not reach `\(exitLine)` — so the \
            case passes through instead of being handled: \(reason).
            """, file: file, line: line)
    }

    func testEveryRefusalBranchReachesExitOne() throws {
        let lines = try activeHookLines()
        assertHookGuard("-z \"$pin\"", exits: "exit 1", in: lines, because:
            "an unreadable pin means the gate cannot know what version to enforce, and guessing is worse than refusing")
        assertHookGuard("command -v swiftlint", exits: "exit 1", in: lines, because:
            "a machine without the pinned toolchain is refused, never skipped — skipping is how a violation gets in")
        assertHookGuard("installed\" != \"$pin", exits: "exit 1", in: lines, because:
            "a version mismatch must refuse naming both versions; SwiftLint itself only warns on one")
        assertHookGuard("xargs -0 swiftlint lint", exits: "exit 1", in: lines, because:
            "violations found in the staged content are the whole reason the hook exists")
    }

    /// The one permitted non-refusal guard is "no staged Swift files → exit 0"
    /// — nothing to judge is not a bypass. Any second `exit 0` means a refusal
    /// somewhere grew a happy path.
    func testTheOnlyExitZeroIsTheNoStagedSwiftFilesGuard() throws {
        let lines = try activeHookLines()
        XCTAssertEqual(lines.filter { $0 == "exit 0" }.count, 1,
                       "\(Self.hookPath) may reach exit 0 early only for the no-staged-Swift-files case")
        assertHookGuard("-s \"$list\"", exits: "exit 0", in: lines, because:
            "a commit touching no Swift files needs no lint, and the empty-input case must stay explicit")
    }

    // MARK: - The CI lint job

    /// CI is the half of the enforcement a bypassed hook cannot skip — hooks
    /// are not cloned and `--no-verify` exists — so its job's shape is
    /// load-bearing and pinned here by the same mechanism-over-wording rules
    /// as the hook above. These assertions run over the job's comment-stripped
    /// lines only, never the whole file, so a second, weaker job elsewhere
    /// could not satisfy them by existing.
    func testCIDeclaresALintJobIndependentOfTheBuildGraph() throws {
        let block = try ciLintJobBlock()
        XCTAssertEqual(block.filter { $0 == "runs-on: macos-15" }.count, 1,
                       "the lint job must name its runner like every other job in ci.yml")
        let budgetLine = try XCTUnwrap(
            block.first { $0.hasPrefix("timeout-minutes:") },
            """
            the lint job must declare its own timeout-minutes: — without one it runs under \
            GitHub's six-hour default, and a hung lint holds a runner for the afternoon
            """)
        let budget = try XCTUnwrap(Int(budgetLine.dropFirst("timeout-minutes:".count)
            .trimmingCharacters(in: .whitespaces)), "could not read a number out of “\(budgetLine)”")
        XCTAssertLessThanOrEqual(budget, 15, """
            the lint job budgets \(budget) minutes for a check that takes under two — style is \
            supposed to be the fastest feedback any job gives, not a queue behind it
            """)
        XCTAssertFalse(block.contains { $0.hasPrefix("needs:") }, """
            the lint job must not wait on the build graph: style feedback that arrives only after \
            a Release build is feedback nobody read
            """)
    }

    /// The cross-file pin pair. The URL's version component must equal
    /// `.swiftlint.yml`'s `swiftlint_version` — this is what makes hook,
    /// configuration and CI incapable of disagreeing about which binary judges
    /// style. A bump that updates one side fails here until both move.
    func testCILintsWithExactlyThePinnedSwiftLintRelease() throws {
        let block = try ciLintJobBlock()
        let pin = try pinnedSwiftLintVersion()
        let expectedURL = "https://github.com/realm/SwiftLint/releases/download/\(pin)/portable_swiftlint.zip"
        let downloadLines = block.filter { $0.contains(expectedURL) }
        XCTAssertEqual(downloadLines.count, 1, """
            ci.yml's lint job must download exactly the pinned release asset (\(expectedURL)) — \
            found \(downloadLines.count) matching lines. The pin lives in .swiftlint.yml; update \
            it there first, then bring the workflow to it.
            """)

        let verifyLines = block.filter { $0.contains("shasum -a 256 -c -") }
        XCTAssertEqual(verifyLines.count, 1,
                       "the downloaded archive must be digest-verified before anything runs it")
        XCTAssertTrue(verifyLines.allSatisfy { $0.contains("swiftlint.zip") },
                      "the digest check must verify the archive itself, verbatim")

        let regex = try NSRegularExpression(pattern: #""([0-9a-f]{64})\s+swiftlint\.zip""#)
        let digestPresent = verifyLines.contains { line in
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, options: [], range: range) != nil
        }
        XCTAssertTrue(digestPresent, """
            the shasum invocation must carry a complete 64-hex SHA-256 beside swiftlint.zip — a \
            truncated paste would fail at run time on every PR instead of failing here
            """)
    }

    /// Strict, over the whole tree, with no config override and no escape
    /// hatch. Root discovery (no explicit config path) is exactly what makes
    /// SwiftLint merge the nested `Tests/.swiftlint.yml`; passing one would
    /// silently drop the test tree from every CI judgment.
    func testCILintIsStrictWithoutAConfigOverrideAndCannotBeSoftened() throws {
        let block = try ciLintJobBlock()

        let lintLines = block.filter { $0.contains("./swiftlint lint") }
        XCTAssertEqual(lintLines, ["run: ./swiftlint lint --strict"], """
            exactly one lint invocation may judge the pull request, and it must be \
            exactly this: --strict so warnings refuse, and no path arguments — paths \
            would narrow CI's judgment below the whole first-party tree while the \
            pre-commit hook keeps judging every staged file in included:
            """)

        XCTAssertFalse(block.contains { $0.contains("--config") }, """
            the lint job must pass no config override: running from the repository root lets \
            SwiftLint discover .swiftlint.yml and merge Tests/.swiftlint.yml, and an override \
            would silently narrow what CI judges
            """)

        for forbidden in ["continue-on-error:", "|| true", "|| :"] {
            XCTAssertFalse(block.contains { $0.contains(forbidden) }, """
                the lint job must not soften with “\(forbidden)” — a violation that reaches CI has \
                already been committed once; swallowing the report makes the gate decorative
                """)
        }
    }

    /// The version print must precede the lint invocation, so a run's log
    /// records which binary judged it — an argument about a stale runner image
    /// needs that line to settle anything.
    func testCIPrintsTheJudgingVersionBeforeLinting() throws {
        let block = try ciLintJobBlock()
        let versionIndex = try XCTUnwrap(block.firstIndex { $0.contains("./swiftlint --version") },
                                         "the lint job must print ./swiftlint --version")
        let lintIndex = try XCTUnwrap(block.firstIndex { $0.contains("./swiftlint lint") },
                                      "the lint job must invoke ./swiftlint lint")
        XCTAssertLessThan(versionIndex, lintIndex,
                          "print --version before linting so the log records which binary judged it")
    }

    // MARK: - The documentation

    /// The contributor-facing half of the story. A hook that is not activated
    /// is decoration, and the activation is a one-line `git config` a fresh
    /// clone has no other way to learn — so README.md must keep giving it,
    /// verbatim, beside the pinned version it enforces. Both contributor documents
    /// must also keep naming `.swiftlint.yml`: the file these instructions
    /// exist to point at. Matched on raw text because markdown carries no
    /// comments to strip and the asserted strings are what a reader copies.
    func testReadmeKeepsTheHookSetupAndNamesTheAuthority() throws {
        let readme = try read("README.md")
        // README carries the *step*, not the tutorial: a fresh clone must be told
        // to run `make setup` and where the rest lives. The raw incantation moved
        // to style-lint.md — see the companion assertion below, which is what
        // keeps the move from becoming a deletion.
        XCTAssertTrue(readme.contains("make setup"), """
            README.md no longer tells a fresh clone to run `make setup` — without it \
            a contributor commits with no local lint gate and never learns why their \
            style diverged
            """)
        XCTAssertTrue(readme.contains("docs/architecture/style-lint.md"), """
            README.md no longer points at docs/architecture/style-lint.md, where the \
            installation and the hook wiring are documented
            """)
        XCTAssertTrue(readme.contains(".swiftlint.yml"), """
            README.md no longer names .swiftlint.yml, the style authority the \
            setup exists to enforce
            """)
    }

    /// The instructions README delegates to have to exist at the other end.
    /// Trimming README was a *move*; without this the same trim done again
    /// would be a silent deletion, and a fresh clone would have no route to the
    /// pinned linter or to the hook wiring at all.
    func testStyleLintDocCarriesTheSetupReadmeDelegatesTo() throws {
        let doc = try read("docs/architecture/style-lint.md")
        for (needle, what) in [
            ("make setup", "the blessed setup command"),
            ("git config core.hooksPath .githooks", "the by-hand hook wiring"),
            ("portable_swiftlint.zip", "how to install the pinned linter"),
            ("swiftlint version", "the check that the installed binary is the pinned one"),
        ] {
            XCTAssertTrue(doc.contains(needle), """
                docs/architecture/style-lint.md no longer documents \(what) (looked for \
                “\(needle)”). README delegates its setup here, so losing it here loses it \
                everywhere.
                """)
        }
    }

    func testClaudeMdNamesTheStyleAuthority() throws {
        XCTAssertTrue(try read("CLAUDE.md").contains(".swiftlint.yml"), """
            CLAUDE.md no longer names .swiftlint.yml as the single style \
            authority — the agent-facing conventions have lost their enforcement \
            story
            """)
    }

    // MARK: - Enabling the hook

    /// A committed hook that nobody activates is decoration. Git will not wire
    /// `core.hooksPath` on clone — it cannot, without turning `git clone` into
    /// code execution — so the activation has to ride on something people
    /// already run. Two carriers do that here, and each is only load-bearing
    /// while it stays wired: the `Makefile`'s targets and the build phase
    /// `project.yml` declares. These assertions pin both, because either one
    /// can be deleted in a hurry without any test noticing otherwise.
    func testMakefileTargetsAllDependOnWiringTheHooks() throws {
        let makefile = try read("Makefile")
        XCTAssertTrue(makefile.contains("git config core.hooksPath .githooks"), """
            Makefile no longer wires core.hooksPath, so running anything through \
            make leaves the clone without its local lint gate
            """)
        // Every target that does real work must reach `hooks` — directly or
        // through a prerequisite that does, which is how `build`, `build-ios`
        // and `test-app` reach it via `generate`. The list is **read from the
        // Makefile**, not enumerated here: a hard-coded roster covers the
        // targets that existed when it was written and silently exempts every
        // one added since, which is exactly the regression this test exists to
        // catch. `help` prints and `hooks` *is* the wiring, so both are the
        // stated exceptions.
        //
        // Reading it means reading *every* name, and refusing the shapes this
        // scan cannot read rather than skipping them: a name filter narrower
        // than make's own — lowercase and hyphens alone, say — re-introduces the
        // silent exemption one target called `smoke2` at a time. So a rule line
        // is anything unindented whose colon is not an assignment's, the name is
        // taken verbatim, and a multi-target, pattern or double-colon rule fails
        // the test instead of vanishing from the roster. `.PHONY` is then read as the
        // Makefile's own declaration of that roster and cross-checked against
        // what the scan found, so the two can never quietly disagree.
        // A colon after a target name does not always introduce prerequisites:
        // make also reads `smoke2: NOTE = hooks` as a *target-specific variable
        // assignment*, which declares no prerequisites at all and invokes
        // nothing. Read as a rule it yields `["NOTE", "=", "hooks"]` — enough to
        // satisfy the requirement below on its own, and enough to overwrite the
        // target's real rule if it is written after it. So the shape is
        // recognized as make writes it: any number of `private`/`export`/
        // `override`/`unexport` modifiers, one variable name, then one of
        // make's assignment operators.
        //
        // A modifier word is only a modifier while something follows it: make
        // reads each word by trying it as a variable definition *first* and
        // only then as a modifier, so `smoke2: private = hooks` assigns the
        // variable literally named `private` and is as prerequisite-free as
        // `smoke2: NOTE = hooks`. Taking the keyword for a modifier
        // unconditionally leaves the recursion looking at a bare `= hooks`,
        // finding no name, and reporting a rule whose "prerequisites" contain
        // `hooks` — the exact silent exemption this shape is refused for. So
        // the operator is looked for before the keyword is.
        //
        // Make's seven operators, longest first: `:::=` must never be read as
        // `::` followed by `=`.
        func assignmentOperatorLength(_ text: Substring) -> Int? {
            for candidate in [":::=", "::=", ":=", "+=", "?=", "!=", "="] where text.hasPrefix(candidate) {
                return candidate.count
            }
            return nil
        }

        // The name ends where an *operator* begins, not where an operator's
        // first character appears: `+`, `?` and `!` are ordinary characters in
        // a make variable name unless `=` follows them, so
        // `smoke2: cache+key = hooks` assigns the variable literally named
        // `cache+key` and declares no prerequisites — verified against make
        // itself, which reads that line as an assignment and then refuses the
        // recipe under it for want of a rule. Stopping the name at the bare `+`
        // instead reports the "prerequisites" `cache+key`, `=`, `hooks`, which
        // both invents the dependency and overwrites the target's real rule.
        // A bare `:` is the one character make will not carry in a name (it
        // ends the variable definition and, in a prerequisite list, is an error
        // in its own right), so it is what returns the line to the rule path.
        // The same reader answers the top-level question too: make's assignment
        // syntax is one grammar, written the same on either side of a rule's
        // colon, so a colon-less line is refused below unless it parses here.
        func isVariableAssignment(_ tail: Substring) -> Bool {
            var rest = tail.drop(while: { $0 == " " || $0 == "\t" })
            while true {
                var index = rest.startIndex
                var stoppedAtOperator = false
                while index < rest.endIndex {
                    let character = rest[index]
                    if character == " " || character == "\t" { break }
                    if assignmentOperatorLength(rest[index...]) != nil {
                        stoppedAtOperator = true
                        break
                    }
                    if character == ":" { return false }
                    index = rest.index(after: index)
                }
                let word = rest[rest.startIndex..<index]
                guard !word.isEmpty else { return false }
                if stoppedAtOperator { return true }
                let after = rest[index...].drop(while: { $0 == " " || $0 == "\t" })
                if assignmentOperatorLength(after) != nil { return true }
                guard ["private", "export", "override", "unexport"].contains(String(word)) else { return false }
                rest = after
            }
        }

        // Matched as a whole first word, so an ordinary target named for one of
        // them (`define: hooks`, whose first word is `define:`) is still read
        // as the rule it is.
        let makeDirectivesTheScanRefuses: Set<String> = [
            "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif",
            "include", "-include", "sinclude", "define", "endef",
        ]

        // Make's own special targets: a rule named for one of these is a
        // directive to make, never a target this repository asks anyone to run.
        let makeSpecialTargets: Set<String> = [
            ".DEFAULT", ".DELETE_ON_ERROR", ".EXPORT_ALL_VARIABLES", ".IGNORE",
            ".INTERMEDIATE", ".LOW_RESOLUTION_TIME", ".NOTINTERMEDIATE", ".NOTPARALLEL",
            ".ONESHELL", ".PHONY", ".POSIX", ".PRECIOUS", ".SECONDARY",
            ".SECONDEXPANSION", ".SILENT", ".SUFFIXES", ".WAIT",
        ]
        // Make folds a line ending in a backslash onto the next one *before* it
        // reads anything, and that join can land anywhere in a rule — including
        // between a target's name and its colon:
        //
        //     smoke2 \
        //     :
        //     <tab>@echo work
        //
        // Reading physical lines and discarding the continuations loses that
        // rule outright — the first line carries no colon, the second is
        // discarded, the recipe is a recipe — which is the silent exemption
        // this scan exists to refuse. So the physical lines are folded the way
        // make folds them first, and every rule below is read off a *logical*
        // one. Outside a recipe the backslash-newline and the whitespace after
        // it collapse to a single space; a continued *recipe* line stays part
        // of its recipe, and the joined line still opens with the tab that
        // skips it.
        //
        // Only an *odd* run of trailing backslashes continues the line: make
        // reads each `\\` as one escaped, literal backslash, so `foo: hooks \\`
        // ends its rule and the line after it opens a new one. Folding on the
        // last character alone would swallow that next line — and with it a
        // target that is not named in `.PHONY`, which is the one shape the
        // cross-check below cannot recover. So the run is counted, and only
        // the final backslash of an odd one is dropped.
        func logicalLines(of makefile: String) -> [String] {
            var joined: [String] = []
            var pending: String?
            for rawLine in makefile.components(separatedBy: .newlines) {
                let trailingBackslashes = rawLine.reversed().prefix(while: { $0 == "\\" }).count
                let continues = trailingBackslashes % 2 == 1
                let content = continues ? String(rawLine.dropLast()) : rawLine
                if let started = pending {
                    pending = started + " " + content.drop(while: { $0 == " " || $0 == "\t" })
                } else {
                    pending = content
                }
                if !continues, let complete = pending {
                    joined.append(complete)
                    pending = nil
                }
            }
            // A trailing backslash on the file's last line continues onto
            // nothing; make reads what it has, and so does this.
            if let unterminated = pending { joined.append(unterminated) }
            return joined
        }

        var prerequisites: [String: [String]] = [:]
        var declaredPhony: Set<String> = []
        for rawLine in logicalLines(of: makefile) {
            // The recipe prefix is a *tab*, and only a tab — make reads a
            // space-indented line as an ordinary rule line. Treating all leading
            // whitespace as a recipe marker would skip `  smoke2:` outright,
            // which is the silent exemption this scan exists to refuse, so the
            // spaces are dropped exactly as make drops them.
            guard let first = rawLine.first, first != "\t", first != "#" else { continue }
            let line = rawLine.drop(while: { $0 == " " })
            guard let afterIndent = line.first, afterIndent != "#" else { continue }
            // Directives this scan does not interpret, refused rather than
            // ignored — ignoring one is the same silent exemption every shape
            // above is refused for. A *conditional* is the sharpest case: make
            // reads one branch, this scan reads both, and a roster keyed by
            // target name keeps whichever came last, so an inactive
            // `else`-branch `smoke2: hooks` would answer for an active rule
            // that reaches nothing. `include` keeps whole rules — and the
            // `.PHONY` line that would otherwise catch them — in a file this
            // scan never opens; a `define` body carries rule-shaped lines make
            // never reads as rules; and `.RECIPEPREFIX` retires the tab that
            // every recipe skip here depends on. None appear in this Makefile,
            // and adding one is meant to be a failing test rather than a hole.
            let directive = line.prefix(while: { !$0.isWhitespace })
            let nameHead = line.prefix(while: { !$0.isWhitespace && $0 != ":" && $0 != "=" })
            XCTAssertFalse(
                makeDirectivesTheScanRefuses.contains(String(directive)) || nameHead == ".RECIPEPREFIX",
                """
                the Makefile uses `\(directive)`, a directive this scan neither \
                interprets nor can read around — rules it hides, or hands it two \
                versions of, would be silently exempt from the `hooks` requirement
                """
            )
            // Make *expands* a line before it reads it, and one function turns
            // an expansion back into makefile syntax: `$(eval …)` hands make
            // whole rules this scan never sees. It is also the one shape that
            // escapes the rule path entirely, because the line defining the
            // rule need carry no colon of its own:
            //
            //     COLON := :
            //     $(eval smoke2$(COLON))
            //
            // defines a real `smoke2` target that reaches nothing, on a line
            // the colon guard below would skip — and, being undeclared, one the
            // `.PHONY` cross-check never asks about either. Hidden on the right
            // of an assignment (`X := $(eval smoke2$(COLON))`, expanded at
            // assignment time) it is skipped by the assignment path instead.
            // So the reference itself is refused wherever it appears on a
            // non-recipe line, which is also where a `$(call …)` of a variable
            // holding one is caught: the variable's own definition names it.
            // Nothing else expands into a rule — `include` and `define` are
            // refused above — so this is the whole of that class.
            let code = line.prefix(while: { $0 != "#" })
            XCTAssertFalse(code.contains("$(eval") || code.contains("${eval"), """
                the Makefile expands `eval`, which defines rules this scan never reads \
                as rules — a target created that way would be silently exempt from the \
                `hooks` requirement
                """)
            guard let colon = line.firstIndex(of: ":") else {
                // No colon at all means the line is either a variable
                // assignment — the one top-level shape that declares no rule
                // and needs none — or something this scan cannot classify. The
                // second is refused rather than skipped, for the reason every
                // shape above is: make reads more than literal text, and a line
                // that expands into a rule (or that make rejects outright) must
                // fail here rather than quietly leave the roster short by one.
                XCTAssertTrue(isVariableAssignment(code), """
                    the Makefile carries the top-level line `\(line)`, which is neither a \
                    rule nor a variable assignment this scan can read — write it as one, \
                    or a target hiding behind it would be silently exempt from the \
                    `hooks` requirement
                    """)
                continue
            }
            let tail = line[line.index(after: colon)...]
            // `NAME := value` / `NAME ::= value` / `NAME :::= value` /
            // `NAME:= value` are variable assignments, not rules. All three
            // colon-carrying operators are spelled out, so what is left starting
            // with a colon below is a double-colon *rule* and nothing else.
            guard !tail.hasPrefix("="), !tail.hasPrefix(":="), !tail.hasPrefix("::=") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // A double-colon rule is the other shape this scan cannot attribute.
            // Make unions every `::` rule for a target and runs them all, while a
            // dictionary keyed by name keeps only the last; and splitting at the
            // *first* colon leaves the second one in the tail, which defeats the
            // assignment check below — `smoke2:: NOTE = hooks`, which make invokes
            // nothing for, would be read as the prerequisites `: NOTE = hooks` and
            // satisfy the requirement outright. So it is refused, like a
            // multi-target or pattern rule, rather than read wrong.
            if tail.hasPrefix(":") {
                XCTFail("""
                    the Makefile declares `\(name)` as a double-colon rule, a shape this \
                    scan cannot attribute to a single rule — write it with one colon, or \
                    this test stops covering it
                    """)
                continue
            }
            // A target-specific variable assignment carries no prerequisites, so
            // it is skipped rather than recorded — recording it would both
            // manufacture a `hooks` dependency out of the assigned value and
            // overwrite whatever the target's real rule says. A target that has
            // *only* such a line still cannot hide: `.PHONY` names every target
            // this repository declares, and the cross-check below refuses a
            // declared name the scan found no rule for.
            guard !isVariableAssignment(tail) else { continue }
            // Prerequisites end where make says they end: at `#` (a comment —
            // `##` is this file's help convention and merely a case of it) or
            // at `;` (an inline recipe). Both carry words make never resolves as
            // targets, and reading them as prerequisites is how `smoke2: # hooks`
            // or `smoke2: ; @echo hooks` would satisfy the requirement below
            // without invoking `hooks` at all.
            let body = tail.prefix(while: { $0 != "#" && $0 != ";" })
            let deps = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if name == ".PHONY" {
                // Make allows any number of `.PHONY` lines and unions them; a
                // roster that replaced the previous one would let everything
                // named in an earlier declaration slip past the cross-check.
                declaredPhony.formUnion(deps)
                continue
            }
            // Other special targets (`.SUFFIXES`, `.DELETE_ON_ERROR`, …) are
            // make's own, not this repository's front door — skipped by *name*,
            // never by the leading dot alone: `.smoke2` is an ordinary target
            // make runs on request, and exempting every dot-prefixed rule would
            // hide it from the requirement below one name at a time. Anything
            // else wearing a dot — an unknown directive, a legacy suffix rule
            // like `.c.o` — is refused rather than guessed at.
            if name.hasPrefix(".") {
                XCTAssertTrue(makeSpecialTargets.contains(name), """
                    the Makefile declares `\(name)`, which is not one of make's special \
                    targets — an ordinary target wearing a leading dot, skipped by this scan, \
                    would be silently exempt from the `hooks` requirement
                    """)
                continue
            }
            XCTAssertFalse(name.contains(" ") || name.contains("%"), """
                the Makefile declares `\(name)`, a multi-target or pattern rule this \
                scan cannot attribute to a single target — write it as one target per \
                rule, or this test stops covering it
                """)
            prerequisites[name] = deps
        }
        XCTAssertTrue(prerequisites.keys.contains("test"), """
            the Makefile target scan found no `test` target, so it is no longer reading \
            the file it means to read
            """)
        XCTAssertFalse(declaredPhony.isEmpty, """
            the Makefile declares no `.PHONY` targets, so the roster this scan checks \
            itself against is gone
            """)
        for target in declaredPhony.sorted() {
            XCTAssertNotNil(prerequisites[target], """
                Makefile declares `\(target)` in `.PHONY` but this scan found no rule \
                for it — either the declaration outlived the target, or the rule is \
                written in a shape the scan can no longer read and would otherwise be \
                silently exempt from the `hooks` requirement
                """)
        }

        func reachesHooks(_ target: String, seen: Set<String> = []) -> Bool {
            guard !seen.contains(target) else { return false }
            guard let deps = prerequisites[target] else { return false }
            if deps.contains("hooks") { return true }
            return deps.contains { reachesHooks($0, seen: seen.union([target])) }
        }

        for target in prerequisites.keys.sorted() where target != "help" && target != "hooks" {
            XCTAssertTrue(reachesHooks(target), """
                Makefile's `\(target)` target does not reach `hooks` through its \
                prerequisites, so invoking it leaves this clone's hooks unwired — which \
                is the whole reason the Makefile exists beside the raw commands
                """)
        }
    }

    func testGeneratedProjectWiresTheHooksOnEveryBuild() throws {
        let projectSpec = try read("project.yml")
        XCTAssertTrue(projectSpec.contains("preBuildScripts"), """
            project.yml declares no preBuildScripts, so building the app no longer \
            wires this clone's hooks — the one carrier that reaches contributors who \
            never touch make
            """)
        XCTAssertTrue(projectSpec.contains("git config core.hooksPath .githooks"), """
            project.yml's build phase no longer sets core.hooksPath
            """)
        // Always, not "when inputs changed": the phase declares no inputs, so
        // dependency analysis would let Xcode skip it — on exactly the incremental
        // builds a fresh clone performs after its first one.
        XCTAssertTrue(projectSpec.contains("basedOnDependencyAnalysis: false"), """
            the hook-wiring build phase must opt out of dependency analysis, or Xcode \
            skips it on incremental builds
            """)
    }

    // MARK: - Data

    private static let rootConfigPath = ".swiftlint.yml"
    private static let childConfigPath = "Tests/.swiftlint.yml"
    private static let hookPath = ".githooks/pre-commit"
    private static let ciWorkflowPath = ".github/workflows/ci.yml"

    /// The test-tree exemptions, as `Tests/.swiftlint.yml` documents them.
    private static let documentedChildExemptions: Set<String> = [
        "force_try",
        "file_length",
        "type_body_length",
        "function_body_length",
        "nesting",
    ]

    /// The in-file exemptions, counted by (relative path, rule). Both entries
    /// are indivisible literals whose lines cannot wrap:
    ///
    ///  * `LeetCodeAPITests` — the exact GraphQL wire bodies asserted verbatim;
    ///  * `LSPProvisioningManifestTests` — pinned-artifact rows, each one
    ///    id/file/byte-count/SHA-256 tuple kept on a single line.
    private static let documentedInFileExemptions: [String: [String: Int]] = [
        "Tests/PisakaCoreTests/LeetCodeAPITests.swift": ["line_length": 2],
        "Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift": ["line_length": 7],
    ]

    /// The root config's whole-tree exemptions, as `.swiftlint.yml` documents
    /// them (each beside its written reason there).
    private static let documentedRootExemptions: Set<String> = [
        "optional_data_string_conversion",
        "notification_center_detachment",
        "orphaned_doc_comment",
    ]

    /// The measured ceilings, as `.swiftlint.yml` configures them.
    private static let documentedRootThresholds: [String: [String: String]] = [
        "identifier_name": ["min_length": "1", "max_length": "60"],
        "type_name": ["min_length": "2", "max_length": "60"],
        "line_length": ["warning": "140", "error": "140"],
        "file_length": ["warning": "1886", "error": "1886"],
        "type_body_length": ["warning": "1870", "error": "1870"],
        "function_body_length": ["warning": "140", "error": "140"],
        "cyclomatic_complexity": ["warning": "22", "error": "22"],
    ]

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func rootText() throws -> String {
        try read(Self.rootConfigPath)
    }

    private func childText() throws -> String {
        try read(Self.childConfigPath)
    }

    private func activeRootLines() throws -> [String] {
        activeYAMLLines(of: try rootText())
    }

    /// The three-component version `.swiftlint.yml` pins — the one source of
    /// truth the hook, the CI job and these assertions all measure against.
    private func pinnedSwiftLintVersion() throws -> String {
        let prefix = "swiftlint_version:"
        let line = try XCTUnwrap(
            try activeRootLines().first { $0.hasPrefix(prefix) },
            ".swiftlint.yml must declare swiftlint_version: — the pin the hook and CI enforce"
        )
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private func read(_ relativePath: String) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file under `tree` (relative to the repository root),
    /// sorted, descending past nothing hidden (`.build`, `.git`, …).
    private func swiftFiles(under tree: String) throws -> [URL] {
        var files: [URL] = []

        func walk(_ directory: URL) throws {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
            for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if item.lastPathComponent.hasPrefix(".") { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
                else { continue }
                if isDirectory.boolValue {
                    try walk(item)
                } else if item.pathExtension == "swift" {
                    files.append(item)
                }
            }
        }

        try walk(Self.repositoryRoot.appendingPathComponent(tree))
        return files
    }

    private func hookText() throws -> String {
        try read(Self.hookPath)
    }

    /// The hook's lines, verbatim and in order — for assertions about the
    /// shebang, which comment-stripping would eat.
    private func hookLines() throws -> [String] {
        try hookText().components(separatedBy: .newlines)
    }

    /// The hook's active lines: neither blank nor a whole-line comment,
    /// trimmed. The hook is deliberately commented like the YAML files above
    /// — its reasons are written beside its refusals — so every substring and
    /// branch assertion runs over this, never the raw text.
    private func activeHookLines() throws -> [String] {
        activeYAMLLines(of: try hookText())
    }

    private func activeHookText() throws -> String {
        try activeHookLines().joined(separator: "\n")
    }

    // MARK: - The CI workflow

    private func ciText() throws -> String {
        try read(Self.ciWorkflowPath)
    }

    /// The `lint` job's active lines, extracted the way `topLevelBlock` would
    /// if jobs sat at zero indent: everything under the two-space `<name>:`
    /// header until the next job header or a zero-indent key, comments and
    /// blanks dropped. Scoped to the one job so an assertion about it cannot
    /// be satisfied by some other job's line.
    private func ciLintJobBlock() throws -> [String] {
        let raw = try ciText().components(separatedBy: .newlines)
        let start = try XCTUnwrap(
            raw.firstIndex(where: { $0.hasPrefix("  ") && !$0.hasPrefix("   ") && $0.dropFirst(2) == "lint:" }),
            "ci.yml has no lint job — CI is the half of the enforcement a bypassed hook cannot skip")
        var block: [String] = []
        for line in raw[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Terminators first — a column-0 comment between jobs must end this
            // job's block, not be skipped into it.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            if line.hasPrefix("  "), !line.hasPrefix("   ") { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            block.append(trimmed)
        }
        return block
    }
}
