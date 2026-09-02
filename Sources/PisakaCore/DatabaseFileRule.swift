import Foundation

/// The one rule that decides whether a file name names a database.
///
/// Deliberately a single pure static answer over a fixed extension set: the
/// project tree's icon table, `WorkspaceModel.open(url:)`'s routing and the
/// documentation all ask this type rather than restating the set, so a new
/// extension is added in exactly one place.
///
/// Only the **last** path extension is looked at, and it is matched
/// case-insensitively. `a.db.txt` is a text file whose *middle* component
/// happens to read `db`; opening it as a database viewer would hide a file the
/// user can perfectly well edit.
public enum DatabaseFileRule {
    /// The recognized extensions, lowercased.
    ///
    /// SQLite's own conventional suffixes. `.db` is not SQLite's alone, but a
    /// file that is not a database fails at connection time with the library's
    /// own message, which is a better answer than refusing to look.
    public static let recognizedExtensions: Set<String> = ["sqlite", "sqlite3", "db"]

    /// Whether `name` names a file this app opens in the database viewer.
    ///
    /// Takes a name rather than a `URL` so the caller may ask about a directory
    /// entry, a session record or a path component without building one.
    public static func isDatabaseFile(named name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return recognizedExtensions.contains(ext)
    }
}
