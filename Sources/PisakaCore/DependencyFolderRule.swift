import Foundation

/// Whether a project-tree folder is a **dependency root** — a folder a package
/// manager fills — and whether a path lies **inside dependencies**, decided
/// from folder names and their siblings' names alone.
///
/// **The table is closed and compared exactly** (`markers`): `node_modules`
/// beside `package.json`; `vendor` beside `composer.json`, `go.mod` or
/// `Gemfile`; `.venv` and `venv` beside `pyproject.toml`, `requirements.txt`,
/// `setup.py`, `setup.cfg` or `Pipfile`; `Pods` beside `Podfile`; `.build`
/// beside `Package.swift`. **A name alone is never enough**: one of its
/// markers must lie beside it, in the same directory, because a hand-written
/// `vendor` folder beside no manifest is ordinary source the user edits.
/// Build-output folders (`build`, `dist`, `target`, …) are deliberately not in
/// the table: they hold what the project produced, not what it depends on.
///
/// **The project root is never a dependency root**, whatever it is called on
/// disk: the components are relative to it and so never spell it, and `[]` is
/// never asked about. **Being inside dependencies is inherited**: everything
/// below a dependency root is inside, and a folder there is never itself a
/// second root (`State.node`).
///
/// **A chain row is a root row when *any* of its segments is one**
/// (`isDependencyRootRow`). `TreeChainRule` folds a folder into a chain only
/// when its listing is exactly one folder, so a root — which always has a
/// marker file beside it — can only be a chain's head in practice; the row
/// stands for its head the way its git colour does.
///
/// **The cost bound** of `isInsideDependencies`: one listing per table-named
/// *ancestor* component of the asked path, stopping at the first root found. A
/// path with no table-named ancestor costs no listing at all. Nothing is
/// memoized.
///
/// Pure: apart from the listings its callers hand it, it reads no file and
/// calls no service.
public enum DependencyFolderRule {
    /// The dependency-folder names, each mapped to the marker files one of
    /// which must lie beside it. Both sides are compared exactly.
    public static let markers: [String: Set<String>] = [
        "node_modules": ["package.json"],
        "vendor": ["composer.json", "go.mod", "Gemfile"],
        ".venv": ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"],
        "venv": ["pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"],
        "Pods": ["Podfile"],
        ".build": ["Package.swift"],
    ]

    /// Whether a folder called `name`, in a directory whose entries are
    /// `siblingNames`, is a dependency root: the name is in the table and at
    /// least one of its markers is among the siblings.
    public static func isDependencyRoot(name: String, siblingNames: [String]) -> Bool {
        guard let wanted = markers[name] else { return false }
        return siblingNames.contains(where: wanted.contains)
    }

    /// Whether a tree row standing for the folders `segmentNames` (one name, or
    /// a chain's segments head first) is a dependency root row: **any** segment
    /// is a root, asked about its own siblings. `siblingNames(i)` names the
    /// entries of the directory holding segment `i`, and is asked only for a
    /// table-named segment. No segments → `false`.
    public static func isDependencyRootRow(
        segmentNames: [String],
        siblingNames: (Int) -> [String]
    ) -> Bool {
        segmentNames.indices.contains { index in
            markers[segmentNames[index]] != nil
                && isDependencyRoot(name: segmentNames[index], siblingNames: siblingNames(index))
        }
    }

    /// Where a tree row stands relative to dependencies.
    public enum State: Equatable, Sendable {
        /// Not inside dependencies, and not a root.
        case outside
        /// A dependency root row: tagged.
        case root
        /// Below a dependency root.
        case inside

        /// The state of a folder row (one folder or a chain) under a parent in
        /// state `parent`: inherited `.inside` below a root or inside one,
        /// otherwise `.root` exactly when the row is a root row.
        public static func node(
            segmentNames: [String],
            siblingNames: (Int) -> [String],
            parent: State
        ) -> State {
            if parent != .outside { return .inside }
            return isDependencyRootRow(segmentNames: segmentNames, siblingNames: siblingNames)
                ? .root : .outside
        }

        /// The state of a file row under a parent in state `inParent`. A file is
        /// never a root.
        public static func file(inParent parent: State) -> State {
            parent == .outside ? .outside : .inside
        }

        /// Whether a row in this state shows the test wash: only outside
        /// dependencies, so a vendored package's `test` folder washes nothing.
        public func showsTestWash(isTestRow: Bool) -> Bool {
            isTestRow && self == .outside
        }

        /// Whether the row shows the `dependencies` tag.
        public var showsCaption: Bool { self == .root }
    }

    /// Whether the entry at `components` (root-relative, `[]` the root) lies
    /// inside dependencies: some **ancestor** component is a dependency root.
    /// The last component is the entry itself and is not asked about, and the
    /// root never is. `siblingNames(i)` names the entries of the directory
    /// holding component `i` and is called only when that component is a table
    /// name; `nil` (no listing) reads as not a root. Returns at the first root.
    public static func isInsideDependencies(
        components: [String],
        siblingNames: (Int) -> [String]?
    ) -> Bool {
        for (index, name) in components.dropLast().enumerated() where markers[name] != nil {
            if let siblings = siblingNames(index), isDependencyRoot(name: name, siblingNames: siblings) {
                return true
            }
        }
        return false
    }

    /// `isInsideDependencies(components:siblingNames:)` for a file URL under a
    /// project root, both matched canonically (`CanonicalPath`). A `nil` root,
    /// or a file not strictly under it, answers `false` without a listing.
    /// Component `i`'s listing is asked of the canonical root plus the
    /// components before it.
    public static func isInsideDependencies(
        fileURL: URL,
        projectRoot: URL?,
        listNames: (URL) -> [String]?
    ) -> Bool {
        guard let projectRoot else { return false }
        let root = CanonicalPath.canonical(projectRoot)
        guard let components = CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(fileURL).pathComponents,
            under: root.pathComponents
        ) else { return false }
        return isInsideDependencies(components: components) { index in
            let directory = components[..<index].reduce(root) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            return listNames(directory)
        }
    }
}
