import Foundation

/// The Find in Files window's scope line, shown under its fields: what the
/// search covers, in one sentence.
///
/// - without a file mask: `In: <project> · Exclude: ignored files`;
/// - with one: `In: <project> · Files: <mask> · Exclude: ignored files`.
///
/// The mask is shown as the user typed it, trimmed of surrounding whitespace,
/// and only when `ProjectSearchModel.maskPatterns(_:)` — the splitting the
/// search itself applies — yields at least one pattern. A mask of separators
/// alone (`","`, `" , ,"`) filters nothing, so the line does not claim it does. The
/// "ignored files" clause is constant because the walk always honours the
/// project's `.gitignore` — there is no control that turns that off, so the line
/// never says otherwise. The project name is the root's last path component as
/// the user spelled it, the `MainWindowTitle` rule.
public enum SearchScopeLine {
    /// The separator between the clauses: a middle dot with a space either side.
    public static let separator = " · "

    public static func text(projectName: String, fileMask: String) -> String {
        var clauses = ["In: \(projectName)"]
        let mask = fileMask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ProjectSearchModel.maskPatterns(mask).isEmpty {
            clauses.append("Files: \(mask)")
        }
        clauses.append("Exclude: ignored files")
        return clauses.joined(separator: separator)
    }
}
