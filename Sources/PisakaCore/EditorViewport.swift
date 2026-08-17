import Foundation

/// Where a tab was left: the caret (or selected range) and the scroll anchor.
///
/// The macOS editor reuses one `NSTextView` for every tab, so switching tabs
/// replaces the whole buffer and the outgoing tab's position exists nowhere
/// unless something records it. This value is that record; the view layer keeps
/// one per open file in `EditorViewportMemory`, beside the per-file undo
/// managers it mirrors.
///
/// **The scroll anchor is a character offset, not a point.** A point is only
/// meaningful against the geometry that produced it, and that geometry is not
/// stable between two visits to the same tab: the code zoom can change (⌘+/⌘-
/// rescales every line), the font or the window width can change, and the text
/// itself can be rewritten by another path (Replace All, a revert, a merge
/// apply). Any of those re-wraps the document, so a remembered `y` would point
/// at a different line — or past the end. An offset into the text survives all
/// of them: the restore asks the live layout where that character is *now*.
public struct EditorViewport: Equatable {
    /// The caret, or the selected range, in UTF-16 units — the editor's own
    /// coordinates (`NSTextView.selectedRange()`).
    public var selection: NSRange
    /// The UTF-16 offset of the first character visible at the top of the
    /// viewport.
    public var topCharacterOffset: Int

    public init(selection: NSRange, topCharacterOffset: Int) {
        self.selection = selection
        self.topCharacterOffset = topCharacterOffset
    }

    /// This viewport made safe for a buffer of `length` UTF-16 units.
    ///
    /// A recorded viewport can outlive the text it described — the file may have
    /// been rewritten (or truncated) while the tab sat in the background, and the
    /// restore must never hand `NSTextView` an out-of-bounds range. Rules:
    ///
    /// - `topCharacterOffset` is clamped into `0...length`. `length` itself is
    ///   allowed on purpose: "the end of the document" is a legitimate anchor,
    ///   and the view layer resolves it against the document end rather than a
    ///   glyph.
    /// - `selection.location` is clamped into `0...length` and the length is then
    ///   **truncated** to what is left (`length - location`) — never intersected.
    ///   `NSIntersectionRange` answers `{0, 0}` for a range starting exactly at
    ///   the buffer end (it shares no unit with the document), which would send a
    ///   caret sitting at the end of the file back to the top; the reveal path
    ///   documents the same reasoning.
    /// - A `NSNotFound` or negative location has no meaningful position at all
    ///   and collapses to `{0, 0}`.
    public func clamped(toLength length: Int) -> EditorViewport {
        let limit = max(0, length)
        let anchor = min(max(topCharacterOffset, 0), limit)
        guard selection.location != NSNotFound, selection.location >= 0 else {
            return EditorViewport(selection: NSRange(location: 0, length: 0), topCharacterOffset: anchor)
        }
        let location = min(selection.location, limit)
        let selectionLength = min(max(selection.length, 0), limit - location)
        return EditorViewport(
            selection: NSRange(location: location, length: selectionLength),
            topCharacterOffset: anchor
        )
    }
}

/// The per-file viewport store: "where was each open tab left?".
///
/// Keyed by the same `OpenFile.id` as the coordinator's per-file undo managers
/// and pruned by the same open-tabs set on the same call, because the two answer
/// the same question about the same object and must not disagree about which
/// files still exist. App-run lifetime only — nothing here is persisted, so a
/// relaunch starts every tab at the top, which is today's behavior.
///
/// Absence is the contract's other half: a file with no entry is a file being
/// shown for the first time, and `viewport(for:clampedToLength:)` answers `nil`
/// for it so the view layer keeps its existing top-of-file behavior instead of
/// inventing a position.
public struct EditorViewportMemory {
    private var viewports: [UUID: EditorViewport] = [:]

    public init() {}

    /// Remember where `fileID` was left.
    public mutating func record(_ viewport: EditorViewport, for fileID: UUID) {
        viewports[fileID] = viewport
    }

    /// Drop `fileID`'s entry — used when the file's text was replaced out from
    /// under a background tab, where the remembered position describes text that
    /// no longer exists.
    public mutating func forget(_ fileID: UUID) {
        viewports.removeValue(forKey: fileID)
    }

    /// Drop every entry whose file is no longer open, so a closed tab leaves
    /// nothing behind (and reopening the same file starts at the top).
    public mutating func prune(keeping openFileIDs: Set<UUID>) {
        viewports = viewports.filter { openFileIDs.contains($0.key) }
    }

    /// The recorded viewport for `fileID`, made safe for a buffer of `length`
    /// UTF-16 units, or `nil` when nothing was recorded for it.
    public func viewport(for fileID: UUID, clampedToLength length: Int) -> EditorViewport? {
        viewports[fileID]?.clamped(toLength: length)
    }
}
