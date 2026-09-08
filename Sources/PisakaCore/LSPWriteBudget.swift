import Foundation

/// How many bytes may sit unwritten in a language server's outgoing queue before
/// the backlog itself is read as the server's death (D39).
///
/// The transport hands a framed message to a serial write queue and returns —
/// waiting would put the session's actor behind a pipe a busy server has not
/// drained. That is the right trade, and it has one failure mode: a server that
/// is *alive but no longer reading its stdin* never fails a write, so the queue
/// grows without bound and every `didChange` adds to it. Nothing already in the
/// layer notices — a request timeout fails one request, and `didChange` has no
/// reply at all, so the one notification that does the growing is invisible to
/// every existing budget.
///
/// This value is the whole rule, kept pure so it can be exercised without a
/// process: the applier is `LSPProcessTransport.send(_:)`, which admits before it
/// queues and drains after the write attempt, exactly as ``ZoomScaleRule`` is the
/// arithmetic and `ZoomController` the applier.
///
/// ## The ceiling is about a backlog, not about one message
///
/// ``admit(_:)`` **always** accepts when nothing is pending, however large the
/// message. A `didOpen` carrying a 20 MB file is a big write, not a dead server,
/// and the pipe will drain it. Over-the-line is only reachable when a backlog
/// already exists *and* the new message would push the total past the ceiling —
/// which is precisely the shape the failure has.
///
/// An over-ceiling message is refused rather than trimmed, and refusing it does
/// **not** count it as pending: it was never queued, so the pending total keeps
/// describing bytes that are genuinely waiting on the pipe. ``drain(_:)`` clamps
/// at zero rather than trapping on an unbalanced call — the applier drains on
/// both the success and the failure path of a write, and a transport in teardown
/// is not worth a crash.
public struct LSPWriteBudget: Sendable, Equatable {
    /// What ``admit(_:)`` answers.
    ///
    /// Two cases and no third: either the bytes may be queued, or the backlog is
    /// past the ceiling and the caller treats the server as dead. There is no
    /// "queued but nearly full" — a warning nobody can act on is a channel this
    /// layer would have to invent a consumer for.
    public enum Admission: Sendable, Equatable {
        /// The bytes are counted as pending; queue them.
        case queued
        /// The backlog would cross the ceiling. Nothing was counted.
        case overCeiling
    }

    /// 32 MiB.
    ///
    /// Two readings, both meant to be legible at a glance: a 1 MB source file
    /// re-synced whole thirty times over is still under it, so ordinary typing
    /// against a slow server never approaches it; and it is half the incoming
    /// `LSPFraming.defaultMaximumContentLength`, the cap this layer already lives
    /// with in the other direction.
    public static let defaultCeiling = 32 * 1024 * 1024

    /// The most bytes that may be pending at once.
    public let ceiling: Int

    /// Bytes handed to the write queue that the pipe has not accepted yet.
    public private(set) var pendingByteCount = 0

    public init(ceiling: Int = LSPWriteBudget.defaultCeiling) {
        self.ceiling = ceiling
    }

    /// May `byteCount` bytes be queued?
    ///
    /// Nothing pending is always `.queued`, whatever the size. Otherwise the
    /// answer is `.overCeiling` when `pendingByteCount + byteCount > ceiling`, and
    /// an `.overCeiling` message leaves ``pendingByteCount`` untouched.
    public mutating func admit(_ byteCount: Int) -> Admission {
        guard pendingByteCount > 0, pendingByteCount + byteCount > ceiling else {
            pendingByteCount += byteCount
            return .queued
        }
        return .overCeiling
    }

    /// The pipe accepted (or refused) `byteCount` bytes: they are no longer
    /// pending. Clamps at zero.
    public mutating func drain(_ byteCount: Int) {
        pendingByteCount = max(0, pendingByteCount - byteCount)
    }
}
