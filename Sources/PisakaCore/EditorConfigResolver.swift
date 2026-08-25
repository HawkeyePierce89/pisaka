import Foundation

/// The hierarchy walk: which `.editorconfig` files apply to one open file, and
/// what the merged answer is.
///
/// The rule the spec states, and this implements, is a walk *outward*: from the
/// directory holding the file up through its ancestors, reading each
/// `.editorconfig` on the way, stopping after the first one that declares
/// `root = true` in its preamble. Files found closer to the edited file win, and
/// within one file every matching section applies in document order — so a later
/// section overwrites an earlier one property by property, never wholesale.
///
/// Two deliberate departures from a literal reading of the spec:
///
/// - **The walk never goes above the project root.** The spec walks to the
///   filesystem root; this stops at the folder the user opened, whose own
///   `.editorconfig` is the last one considered whatever it declares. The reason
///   is uniformity across platforms: on iOS the app reads through a
///   security-scoped grant for exactly that folder, so a config above it is not
///   merely unusual to honor — it is unreadable. Honoring it on macOS alone
///   would make the same project indent differently on the two platforms, which
///   is worse than a stated limit.
/// - **The directory chain is built from the file's own spelling**, not from its
///   canonical path, so a section glob matches the path as the user wrote it.
///   Containment — "is this file inside the project at all?" — is still asked
///   canonically through `CanonicalPath`, the repository's one rule for that
///   question; only the *spelling* the globs see comes from the url the caller
///   passed. When the two disagree about how many components separate the file
///   from the root (a symlinked root), the canonical spelling is used for both,
///   since a chain that does not actually contain the file would match nothing.
///
/// A **reader**, like the symbol index: it opens files and writes none, so it
/// neither raises the disk-writer gate nor is gated by it.
public enum EditorConfigResolver {

    /// The one file name this layer looks for.
    public static let fileName = ".editorconfig"

    /// Whether `name` names a `.editorconfig`, folding case.
    ///
    /// The comparison is case-insensitive because `resolve` does not compare at
    /// all: it appends `fileName` to a directory and hands the url to the
    /// filesystem, and the default APFS volume answers that with a file actually
    /// named `.EditorConfig` (which repositories authored on Windows carry). The
    /// app's cache-invalidation hooks *do* compare — they are told which urls a
    /// save just wrote — so the rule they need is this one, stated here beside
    /// the name rather than restated per platform.
    public static func isFileName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(fileName) == .orderedSame
    }

    /// The largest `.editorconfig` that is read at all.
    ///
    /// Three orders of magnitude above anything the spec's own acceptance floors
    /// imply (a 1024-character section name, a 4096-character value) and above
    /// any configuration a person writes, so no honest project meets it; what it
    /// bounds is the decode-and-line-split that would otherwise happen on a
    /// keystroke for a file a clone brought in.
    static let maximumFileBytes = 1 << 20

    /// The merged properties that apply to `fileURL`, or an empty map when
    /// nothing does.
    ///
    /// Empty is the answer for a `nil` project root, a `nil` url (an untitled
    /// buffer), a file that is not inside the project (an out-of-project
    /// definition window) and a project whose configs say nothing about the
    /// file — the caller cannot and need not tell those apart, because all four
    /// mean "fall back to what the editor would have done anyway".
    public static func resolve(
        fileURL: URL?,
        projectRoot: URL?,
        fileService: FileServicing
    ) -> EditorConfigProperties {
        guard let fileURL, let projectRoot,
              let chain = chain(fileURL: fileURL, projectRoot: projectRoot)
        else { return EditorConfigProperties() }

        var applicable: [(file: EditorConfigFile, relativePath: String)] = []
        // Innermost first, which is the order the `root = true` stop is defined
        // in; the merge below reverses it.
        for step in chain {
            let url = step.directory.appendingPathComponent(fileName)
            // An absent config is the common case and an unreadable one (a
            // permission, a lapsed security scope) degrades to the same thing:
            // no properties from that directory, and the walk carries on. Read
            // through the capped reader for the third case: this runs
            // synchronously inside the Enter and Tab key handlers over a file a
            // clone brought in, so a multi-megabyte `.editorconfig` must not be
            // decoded and line-split on the keystroke. Over the cap degrades to
            // the same "no properties from that directory" the `try?` already
            // spells — and being over it is itself the signal that the file is
            // not a configuration anyone wrote by hand.
            guard let text = try? fileService.readTextIfNotBinary(url: url, maxBytes: maximumFileBytes) else {
                continue
            }
            let file = EditorConfigFile(text: text)
            applicable.append((file, step.relativePath))
            if file.isRoot { break }
        }

        // One match budget for the whole answer. Nothing caps how many sections a
        // `.editorconfig` declares or how many configs the walk reads, so a
        // per-section budget would multiply by both and a keystroke could still
        // stall for tens of seconds on content from a cloned repository; see
        // `EditorConfigGlob.maximumMatchSteps`.
        //
        // Matching is therefore separated from merging, because the two want
        // *opposite* orders and only one of them is negotiable. Merging must run
        // outermost-first, since that is what "a closer file wins" means. Draining
        // the shared budget in that same order would make exhaustion fall on the
        // **closest** file — the one whose answer outranks every other — so a
        // hostile or merely quadratic root config could silently starve the
        // `src/foo/.editorconfig` sitting beside the edited file, and the walk
        // would degrade in precisely the wrong direction. Matching runs
        // innermost-first so the budget is spent on the most specific rules first;
        // the merge below then replays the results outermost-first, unchanged.
        var budget = EditorConfigGlob.maximumMatchSteps
        var matched: [[EditorConfigSection]] = []
        for entry in applicable {
            matched.append(entry.file.sections(matching: entry.relativePath, budget: &budget))
        }

        var properties = EditorConfigProperties()
        // Outermost first: every closer file overwrites what an outer one said,
        // property by property.
        for sections in matched.reversed() {
            for section in sections {
                for pair in section.pairs { properties.apply(pair) }
            }
        }
        return properties
    }

    // MARK: - The chain

    /// One directory of the walk and the file's path relative to it — the
    /// spelling that directory's section globs are matched against.
    private struct Step {
        let directory: URL
        let relativePath: String
    }

    /// The directories from the file's own directory up to and including the
    /// project root, innermost first, or `nil` when the file does not live
    /// strictly inside the root.
    private static func chain(fileURL: URL, projectRoot: URL) -> [Step]? {
        guard let spelling = spelling(fileURL: fileURL, projectRoot: projectRoot) else { return nil }

        var steps: [Step] = []
        var directory = spelling.root
        // Every component but the last names a directory between the root and
        // the file; the last one is the file itself.
        for depth in 0..<spelling.relativeComponents.count {
            let relativePath = spelling.relativeComponents.dropFirst(depth).joined(separator: "/")
            steps.append(Step(directory: directory, relativePath: relativePath))
            directory = directory.appendingPathComponent(spelling.relativeComponents[depth])
        }
        return Array(steps.reversed())
    }

    /// The root url and the file's relative components, in one consistent
    /// spelling.
    ///
    /// The caller's own spelling is preferred and the canonical one is the
    /// fallback, so the globs see the path the user wrote whenever that path
    /// lexically contains the file.
    private static func spelling(
        fileURL: URL,
        projectRoot: URL
    ) -> (root: URL, relativeComponents: [String])? {
        let file = fileURL.standardizedFileURL
        let root = projectRoot.standardizedFileURL
        if let components = CanonicalPath.relativeComponents(
            of: file.pathComponents,
            under: root.pathComponents
        ) {
            return (root, components)
        }
        let canonicalFile = CanonicalPath.canonical(fileURL)
        let canonicalRoot = CanonicalPath.canonical(projectRoot)
        guard let components = CanonicalPath.relativeComponents(
            of: canonicalFile.pathComponents,
            under: canonicalRoot.pathComponents
        ) else { return nil }
        return (canonicalRoot, components)
    }
}
