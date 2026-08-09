import Foundation

/// The whole macOS/Core boundary of the LSP client.
///
/// Core owns the protocol — framing, correlation, budgets, position mapping — and
/// knows nothing about how the bytes get to a server. The app owns a `Process`
/// and three pipes and knows nothing about what the bytes mean. This protocol is
/// the seam between them, and it is deliberately tiny: bytes out, bytes in, stop.
/// That is the same split `GitServicing`/`GitCLIService` already makes, for the
/// same reason — everything interesting stays unit-testable in a target that
/// cannot spawn a process.
///
/// The one-way-ness matters. A transport never interprets a message, never
/// retries, never restarts: a crashed server is reported by the byte stream
/// *ending*, and the decision to restart it (D7's backoff) belongs to
/// `LSPWorkspace`, which is the only thing that knows how many times this has
/// happened already.
public protocol LSPTransport: AnyObject, Sendable {
    /// The bytes the server wrote, in whatever chunks the pipe delivered them —
    /// half a header, three messages at once, one message across eleven reads.
    /// Re-assembling them is `LSPFraming.Decoder`'s job, not the transport's.
    ///
    /// **Consumed exactly once**, by the `LSPSession` that owns this transport:
    /// an `AsyncStream` has a single consumer, and a second `for await` would
    /// silently split the message stream in two. Implementations therefore build
    /// it at construction and hand back the same value every time.
    ///
    /// The stream *finishing* is the only way EOF is reported — a server that
    /// crashed, exited after `exit`, or was terminated all end here, and the
    /// session's answer to all three is the same: fail everything pending and go
    /// terminal.
    var incomingBytes: AsyncStream<Data> { get }

    /// Write one already-framed message. Synchronous because the implementation
    /// hands the bytes to a serial queue and returns; nothing here waits on the
    /// server.
    func send(_ data: Data) throws

    /// Stop the server, unconditionally and without a handshake — the session has
    /// already sent `shutdown`/`exit` if it was going to. Must be idempotent (the
    /// session calls it on every terminal path) and must finish `incomingBytes`,
    /// because a stream that never ends is a read task that never exits.
    func terminate()
}

/// Why bytes could not move.
///
/// Deliberately not `LocalizedError`: nothing on this path is ever shown to the
/// user. Every failure here degrades one request to the tree-sitter answer,
/// silently, which is the whole point of the phase (D7: "no alerts, no banners —
/// ever").
public enum LSPTransportError: Error, Equatable, Hashable, Sendable {
    /// The server executable could not be started — missing, not executable, or
    /// the toolchain lookup found nothing.
    case launchFailed(String)
    /// Nothing is wrong yet: the factory cannot say where the executable is
    /// *without blocking*, and refuses rather than stall the turn it was called on
    /// (`LSPToolchain.Resolution.pending`). Distinct from `launchFailed` because
    /// `LSPWorkspace` must not spend restart budget on it — no attempt was made, and
    /// the answer that would let one be made is on its way.
    case notReady
    /// A write was attempted after the process ended.
    case notRunning
    /// The pipe rejected the write (most often a broken pipe: the server died
    /// between the last read and this write).
    case writeFailed(String)
}
