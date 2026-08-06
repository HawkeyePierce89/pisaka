import Foundation

/// One node in the by-folder grouping of the Local Changes view: either a
/// directory (with `children`) or a changed file leaf.
///
/// A single uniform node type (a directory has non-`nil` `children`, a file leaf
/// has `nil` children plus a non-`nil` `file`) so the SwiftUI tree can recurse
/// over `children` the way `DirectoryNodeView` does over the project tree. `path`
/// is repo-relative and serves as the stable identity; `url` is `root` joined
/// with `path` so the view can reuse `FileIcon(for:)` (which takes a
/// `DirectoryEntry`'s `url`).
public struct ChangeNode: Identifiable, Equatable {
    /// Display name (the last path component).
    public let name: String
    /// Repo-relative path of this node.
    public let path: String
    /// Absolute location (`root` + `path`), for the view's icon resolution.
    public let url: URL
    /// The changed file for a leaf; `nil` for a directory.
    public let file: ChangedFile?
    /// Child nodes for a directory; `nil` for a file leaf.
    public let children: [ChangeNode]?

    public init(name: String, path: String, url: URL, file: ChangedFile?, children: [ChangeNode]?) {
        self.name = name
        self.path = path
        self.url = url
        self.file = file
        self.children = children
    }

    /// Stable identity from the repo-relative path.
    public var id: String { path }

    /// Whether this node is a directory (has a `children` array).
    public var isDirectory: Bool { children != nil }
}

/// Pure directory-tree grouping of `[ChangedFile]` over their repo-relative
/// paths, mirroring `FileService`'s directories-first / case-insensitive sort.
///
/// Foundation-only and fully unit-tested; the view layer renders the resulting
/// `[ChangeNode]` tree (or the flat `[ChangedFile]` list) per the model's
/// grouping mode.
public enum ChangeTree {
    /// Build the folder-grouped tree from `files`, rooted at `root`.
    ///
    /// Root-level files (no directory component) stay flat at the top level.
    /// At every level directories come first (sorted case-insensitively), then
    /// files (sorted case-insensitively).
    public static func build(from files: [ChangedFile], root: URL) -> [ChangeNode] {
        let rootDir = MutableDir()
        for file in files {
            let components = file.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }
            let dirComponents = components.dropLast()
            var current = rootDir
            for component in dirComponents {
                if let next = current.subdirs[component] {
                    current = next
                } else {
                    let next = MutableDir()
                    current.subdirs[component] = next
                    current = next
                }
            }
            current.files.append(file)
        }
        return freeze(rootDir, prefix: "", root: root)
    }

    /// Freeze a mutable directory into sorted, immutable `ChangeNode`s.
    private static func freeze(_ dir: MutableDir, prefix: String, root: URL) -> [ChangeNode] {
        var nodes: [ChangeNode] = []

        for name in dir.subdirs.keys.sorted(by: caseInsensitive) {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let children = freeze(dir.subdirs[name]!, prefix: path, root: root)
            nodes.append(
                ChangeNode(
                    name: name,
                    path: path,
                    url: root.appendingPathComponent(path),
                    file: nil,
                    children: children
                )
            )
        }

        for file in dir.files.sorted(by: { caseInsensitive($0.path, $1.path) }) {
            nodes.append(
                ChangeNode(
                    name: (file.path as NSString).lastPathComponent,
                    path: file.path,
                    url: root.appendingPathComponent(file.path),
                    file: file,
                    children: nil
                )
            )
        }

        return nodes
    }

    private static func caseInsensitive(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    /// Mutable accumulator used only while building, before freezing into the
    /// immutable `ChangeNode` tree.
    private final class MutableDir {
        var subdirs: [String: MutableDir] = [:]
        var files: [ChangedFile] = []
    }
}
