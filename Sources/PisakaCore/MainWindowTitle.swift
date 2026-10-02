import Foundation

/// The main window's title: `<project folder name> — <file name>`.
///
/// Pure, so the three answers are pinned here rather than in the window chrome
/// that applies them:
/// - a project and a focused file read `<project> — <file>`, joined by an em
///   dash with a space either side;
/// - a project with no file focused reads the project name alone;
/// - no project open reads `defaultTitle`, the name the window carried before
///   anything set one — the app's display name.
///
/// The project name is the root's last path component as the user spelled it,
/// never resolved: the title names the folder the user opened.
public enum MainWindowTitle {
    /// The title with no project open: the app's display name, which is what
    /// the scene titled the window before this rule existed.
    public static let defaultTitle = "Pisaka"

    /// The separator between the project and the file name.
    public static let separator = " — "

    public static func text(projectRoot: URL?, focusedFileName: String?) -> String {
        guard let projectRoot else { return defaultTitle }
        let project = projectRoot.lastPathComponent
        guard let focusedFileName, !focusedFileName.isEmpty else { return project }
        return project + separator + focusedFileName
    }
}
