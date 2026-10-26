import Foundation

/// Whether a project-tree row is a **test row**, decided from the row's
/// root-relative path components alone — the tree paints those rows with a
/// wash underneath the row-state tints (`ChromeColorRole.treeRowWashRole`).
///
/// **Test folders are a closed set of names**, matched case-insensitively:
/// `test`, `tests`, `__tests__`, `spec`, `specs`. Being a test folder is
/// inherited the way a git ignore does: everything underneath one is a test row
/// too, so a folder is a test row when *any* of its components names a test
/// folder — itself, an ancestor, or any segment of a chain row, which is judged
/// by its tail's path.
///
/// **A file is a test row** when an ancestor component names a test folder, or
/// when its own name follows its ecosystem's naming convention
/// (`TestCommand.followsTestNamingConvention`). That predicate is the shared
/// table rather than `TestCommand.isTestFile`, which also answers every `.rs`
/// file: Rust has no naming convention, so a Rust file is a test row only
/// through a test folder above it (`tests/integration.rs` yes, `src/lib.rs`
/// no). A file's own name never makes it a test *folder* — a file named `test`
/// is judged by the convention alone.
///
/// `[]` is the project root, which is **never** a test row, whatever it is
/// called on disk: the components are relative to it and so never spell it.
///
/// Pure: it reads no file and calls no service, and the cost is one walk over
/// the components.
public enum TreeTestRule {
    /// The folder names that make a folder — and everything under it — a test
    /// row, lowercased; a component is compared after lowercasing it.
    public static let testFolderNames: Set<String> = [
        "test", "tests", "__tests__", "spec", "specs"
    ]

    /// Whether the row at `components` (root-relative, `[]` the root) is a test
    /// row; `isFolder` says whether its last component is a folder (or a
    /// chain's tail) rather than a file.
    public static func isTestRow(components: [String], isFolder: Bool) -> Bool {
        guard let last = components.last else { return false }
        if isFolder {
            return components.contains(where: isTestFolderName)
        }
        if components.dropLast().contains(where: isTestFolderName) {
            return true
        }
        return TestCommand.followsTestNamingConvention(fileName: last)
    }

    private static func isTestFolderName(_ component: String) -> Bool {
        testFolderNames.contains(component.lowercased())
    }
}
