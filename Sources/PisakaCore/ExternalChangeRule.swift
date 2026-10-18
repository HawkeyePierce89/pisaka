import Foundation

/// What a titled text tab's file looks like on disk at the moment of a check.
///
/// Three states, because the rule treats each differently: a **missing** file is
/// not a change at all (today's recreate-on-save stands), an **unreadable** one
/// (permission denied, not text) can only threaten edits that exist, and readable
/// text is compared byte-for-byte against the buffer's baseline.
public enum ExternalDiskRead: Equatable, Sendable {
    case text(String)
    case missing
    case unreadable
}

/// What the external-change check decided about one tab.
public enum ExternalChangeVerdict: Equatable, Sendable {
    /// The stamps match: nothing was read.
    case unchanged
    /// The stamp moved but the content is the baseline's (a touch, an identical
    /// checkout, a same-bytes copy): refresh the stamp alone.
    case stampOnly
    /// A clean tab whose file now holds other content: reload it silently.
    case reload
    /// The buffer already equals the new disk content: adopt it as the baseline,
    /// which is not a conflict.
    case adoptBaseline
    /// Edits and a different disk side. The disk text, or `nil` when the file
    /// could not be read as text (Compare then shows the disk side as empty).
    case conflict(diskText: String?)
    /// The file is gone. Not a change: a later save recreates it.
    case missing
    /// A clean tab whose file cannot be read: nothing to protect, nothing to load.
    case leaveAlone
}

/// Whether the disk really differs from a tab's baseline, and what to do about it.
///
/// Pure, so every verdict is pinned in Core and the three triggers — the guard
/// before every write, the watcher's coalesced event and app activation — read
/// one answer. A stamp mismatch alone is never a change: the content must differ
/// from `savedText` too, so a touch or an identical checkout costs one read and a
/// stamp refresh, never a reload or a conflict.
///
/// Dirtiness is `text != savedText`. A buffer edited back to `savedText` is
/// clean, so a different disk side reloads it — the clean-but-stale case.
public enum ExternalChangeRule {
    /// The verdict for one tab.
    ///
    /// - Parameters:
    ///   - recorded: the stamp taken when the baseline was last set.
    ///   - current: the stamp now, or `nil` when the service cannot tell — which
    ///     means "read and compare", never "unchanged".
    ///   - read: the disk read, evaluated only when the stamps do not settle it.
    ///   - savedText: the buffer's baseline.
    ///   - text: the live buffer.
    public static func verdict(
        recorded: FileStamp?,
        current: FileStamp?,
        read: () -> ExternalDiskRead,
        savedText: String,
        text: String
    ) -> ExternalChangeVerdict {
        if let current, current == recorded { return .unchanged }
        let isDirty = text != savedText
        switch read() {
        case .missing:
            return .missing
        case .unreadable:
            return isDirty ? .conflict(diskText: nil) : .leaveAlone
        case .text(let disk):
            if disk == savedText { return .stampOnly }
            if text == disk { return .adoptBaseline }
            return isDirty ? .conflict(diskText: disk) : .reload
        }
    }
}
