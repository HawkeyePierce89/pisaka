import Foundation

/// What a server's stderr carried, and how it last left — one `(server, root)`'s
/// failure history for the app run, held in memory only (D44).
///
/// D7 retires a server silently, and that stays true: nothing here is ever an
/// alert, a banner or a notification. What this adds is somewhere to *look*: the
/// LSP settings page shows `statusSentence` on the server's row and the captured
/// `text` behind a disclosure, so "Swift completion stopped working" has an
/// answer for someone who goes looking for one, and none for anyone who does not.
///
/// A value type the workspace mutates in place. The bytes are kept raw and
/// decoded lossily only for display: a ring that keeps the *newest* bytes can cut
/// a UTF-8 sequence at its front edge, and decoding on every append would pay for
/// a string nobody may ever read.
public struct LSPServerFailureRecord: Equatable, Sendable {
    /// The ring's bound: the newest 32 KiB of stderr survive, older bytes do not.
    /// The interesting lines — the panic, the "could not find toolchain" — are the
    /// last ones a server writes, and a bound is what keeps a chatty server's log
    /// from growing for the whole app run.
    public static let capacity = 32 * 1024

    /// The server this is about — `LSPServerDescription.id`, which is also the
    /// component id every settings row is keyed by.
    public let serverID: String
    /// The canonical root path the server was started for.
    public let root: String

    /// The newest bytes the server wrote to stderr, at most `capacity` of them.
    public private(set) var tail = Data()
    /// The last exit status seen, if any. Negative for a process ended by a
    /// signal (`-15` for `SIGTERM`), so one integer carries both outcomes
    /// without a second case.
    public private(set) var lastExitCode: Int32?
    /// D7's count for this key — the same number the restart budget is spent from.
    public private(set) var failureCount = 0
    /// Whether D7 has retired the key for the app run.
    public private(set) var isRetired = false
    /// Monotonic across every record one workspace keeps, bumped on each change, so
    /// "the newest record for a server with several roots" is a comparison rather
    /// than a guess about wall clocks.
    public private(set) var sequence = 0

    public init(serverID: String, root: String) {
        self.serverID = serverID
        self.root = root
    }

    /// Whether there is anything to show. A record exists from the first byte a
    /// launched server writes — healthy servers log too — but it is only *about a
    /// failure* once D7 has counted one, and only then does a row say anything.
    public var hasFailed: Bool { failureCount > 0 }

    /// The captured stderr, decoded for display. Invalid UTF-8 (including a
    /// sequence the ring cut in half) becomes U+FFFD rather than an empty string.
    public var text: String { String(decoding: tail, as: UTF8.self) }

    /// One line for the settings row, e.g. "Stopped after 4 failures · exit code 1".
    public var statusSentence: String {
        let noun = failureCount == 1 ? "failure" : "failures"
        var sentence = isRetired
            ? "Stopped after \(failureCount) \(noun)"
            : "Restarted after \(failureCount) \(noun)"
        if let code = lastExitCode {
            sentence += code < 0 ? " · signal \(-code)" : " · exit code \(code)"
        }
        return sentence
    }

    /// Append stderr bytes, dropping the oldest past `capacity`.
    public mutating func append(_ bytes: Data, sequence: Int) {
        guard !bytes.isEmpty else { return }
        if bytes.count >= LSPServerFailureRecord.capacity {
            tail = Data(bytes.suffix(LSPServerFailureRecord.capacity))
        } else {
            tail.append(bytes)
            let overflow = tail.count - LSPServerFailureRecord.capacity
            if overflow > 0 { tail = Data(tail.dropFirst(overflow)) }
        }
        self.sequence = sequence
    }

    public mutating func noteExit(code: Int32, sequence: Int) {
        lastExitCode = code
        self.sequence = sequence
    }

    public mutating func noteFailure(count: Int, retired: Bool, sequence: Int) {
        failureCount = count
        isRetired = retired
        self.sequence = sequence
    }
}

/// One thing a server's stderr side said: some bytes, or how the process left.
public enum LSPErrorOutputEvent: Equatable, Sendable {
    case bytes(Data)
    /// The process ended. Negative `code` is a signal number, negated.
    case exited(code: Int32)
}

/// The settings page's view of the failure records (D44): which status each row
/// carries, and which servers need a status-only row because nothing else on the
/// page names them.
///
/// Fed by `LSPWorkspace.onFailureRecordsChange` in the composed app; every rule
/// is a pure function of `records`, so the view decides nothing.
@MainActor
public final class LSPServerFailureModel: ObservableObject {
    /// Only records that are about a failure (`hasFailed`) — the workspace
    /// publishes nothing else.
    @Published public private(set) var records: [LSPServerFailureRecord] = []

    public init() {}

    public func receive(_ records: [LSPServerFailureRecord]) {
        let failed = records.filter(\.hasFailed)
        guard failed != self.records else { return }
        self.records = failed
    }

    /// The status for the row keyed by `serverID`, or `nil` with nothing to say.
    /// Several roots for one server resolve to the newest record: the row is
    /// about the server, and what it last did is the most useful single answer.
    public func status(forServerID serverID: String) -> LSPServerFailureRecord? {
        records
            .filter { $0.serverID == serverID }
            .max { $0.sequence < $1.sequence }
    }

    /// The servers no row on the page names — sourcekit-lsp today — one row each,
    /// present only while a record exists, in a stable order.
    public func statusOnlyRows(excludingServerIDs rowIDs: Set<String>) -> [LSPServerFailureRecord] {
        Set(records.map(\.serverID))
            .subtracting(rowIDs)
            .sorted()
            .compactMap { status(forServerID: $0) }
    }
}
