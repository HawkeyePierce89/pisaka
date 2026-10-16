import Foundation

/// Which project-tree directories Reveal in Project Tree expands: every one
/// from the opened root down to the file's parent.
///
/// Each answer is spelled the way the tree spells its rows — the root exactly
/// as opened, then one listing component appended per level — so the app can
/// match them against the tree's own urls rather than against a canonical
/// spelling the tree never shows. Containment is the breadcrumb's two-probe
/// rule (`DisplayPath.relativeComponents(of:under:)`, lexical first, then
/// canonical through `CanonicalPath`), so a file the tab menu offers to reveal
/// is exactly a file the path bar shows relative to the root.
public enum TreeRevealRule {
    /// The directories to expand, root first, ending at the file's parent.
    /// A file directly under the root answers `[root]`. Nil for a file outside
    /// the root, and for the root itself (it is not inside itself).
    public static func ancestors(of fileURL: URL, root: URL) -> [URL]? {
        guard let suffix = DisplayPath.relativeComponents(of: fileURL, under: root) else {
            return nil
        }
        var directory = root
        var answer = [root]
        for component in suffix.dropLast() {
            directory = directory.appendingPathComponent(component, isDirectory: true)
            answer.append(directory)
        }
        return answer
    }
}
