import Foundation

/// A single file open in the workspace.
///
/// An `OpenFile` may be backed by a `url` on disk or be a brand-new
/// "Untitled" buffer that has never been saved. The dirty state is derived
/// by comparing the current `text` against the last `savedText`.
///
/// A tab is one of two `Kind`s. A `.text` tab is the ordinary editable buffer
/// this type has always modeled; a `.viewer` tab stands for a file the editor
/// does not render as text at all (a database), carries no text and **can never
/// be dirty**.
public struct OpenFile: Identifiable, Equatable {
    /// What kind of surface this tab shows.
    ///
    /// `.text` is what every tab was before the database viewer existed; a tab
    /// only becomes `.viewer` through `init(id:viewerFor:)`.
    public enum Kind: Equatable, Sendable {
        /// An editable text buffer.
        case text
        /// A non-text file shown by a dedicated read-only surface.
        case viewer
    }

    /// Stable identity, independent of the file's url or name.
    public let id: UUID

    /// Location on disk, or `nil` for a new unsaved buffer.
    public var url: URL?

    /// Current editor contents. Always empty for a `.viewer` tab.
    public var text: String

    /// Contents as of the last successful save (or initial load).
    public var savedText: String

    /// The tab kind. Immutable: a tab never changes what it shows.
    public let kind: Kind

    /// Create an ordinary text tab.
    ///
    /// There is deliberately no `kind:` parameter here — the only way to build
    /// a viewer tab is `init(id:viewerFor:)`, which forces the text empty, so
    /// "a viewer tab carries no text" holds by construction rather than by
    /// convention.
    public init(id: UUID = UUID(), url: URL? = nil, text: String = "", savedText: String = "") {
        self.id = id
        self.url = url
        self.text = text
        self.savedText = savedText
        self.kind = .text
    }

    /// Create a viewer tab for a file on disk.
    ///
    /// A viewer tab always has a `url` (there is no unsaved database) and both
    /// text sides are forced empty; `isDirty` is `false` for it unconditionally,
    /// so even a caller that assigns `text` afterwards cannot make it dirty.
    public init(id: UUID = UUID(), viewerFor url: URL) {
        self.id = id
        self.url = url
        self.text = ""
        self.savedText = ""
        self.kind = .viewer
    }

    /// Name shown in the tab list: the file name, or "Untitled" when unsaved.
    public var displayName: String {
        url?.lastPathComponent ?? "Untitled"
    }

    /// Whether the buffer has unsaved changes.
    ///
    /// A `.viewer` tab is never dirty: it holds no buffer to have edited, so
    /// nothing about it can ever be unsaved. Part 1 of the viewer is read-only,
    /// and even the editing part 2 adds writes through the database, not
    /// through this text.
    public var isDirty: Bool {
        guard kind == .text else { return false }
        return text != savedText
    }
}
