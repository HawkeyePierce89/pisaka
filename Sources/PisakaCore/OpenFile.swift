import Foundation

/// A single file open in the workspace.
///
/// An `OpenFile` may be backed by a `url` on disk or be a brand-new
/// "Untitled" buffer that has never been saved. The dirty state is derived
/// by comparing the current `text` against the last `savedText`.
public struct OpenFile: Identifiable, Equatable {
    /// Stable identity, independent of the file's url or name.
    public let id: UUID

    /// Location on disk, or `nil` for a new unsaved buffer.
    public var url: URL?

    /// Current editor contents.
    public var text: String

    /// Contents as of the last successful save (or initial load).
    public var savedText: String

    public init(id: UUID = UUID(), url: URL? = nil, text: String = "", savedText: String = "") {
        self.id = id
        self.url = url
        self.text = text
        self.savedText = savedText
    }

    /// Name shown in the tab list: the file name, or "Untitled" when unsaved.
    public var displayName: String {
        url?.lastPathComponent ?? "Untitled"
    }

    /// Whether the buffer has unsaved changes.
    public var isDirty: Bool {
        text != savedText
    }
}
