#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPArtifactDownloading`: one `URLSession` per request, one `Data`,
/// counted as it arrives (D14).
///
/// The app half of the download seam, and the counterpart to `LSPProcessTransport`
/// on the other one — Core owns *what* may be fetched (the pinned manifest), *what
/// makes it acceptable* (the SHA-256), *how large it may be* (the manifest's
/// `byteCount`, handed over as the maximum) and *what happens when it is not* (the
/// whole staging/rename sequence); this file owns the socket and knows none of
/// that. It is untested by repository convention, so it is kept to the three
/// decisions it actually makes: how the session is configured, what counts as a
/// failure, and where the bytes stop.
///
/// **Nothing is cached, at any layer.** The session is `.ephemeral` *and* its
/// `urlCache` is cleared *and* every request is `.reloadIgnoringLocalAndRemoteCacheData`,
/// which is three statements of the same intent because the alternative is a
/// 53 MB Node tarball sitting in the user's cache directory for a file that has
/// already been unpacked into its final home. A cached copy would also be a second
/// place bytes can come from, and the one promise this layer makes is that what
/// gets installed is what the manifest pinned — a promise kept by the digest, but
/// much easier to reason about when the response is known to have come off the
/// wire.
///
/// **No cookies, no credentials, no `URLSession` background transfer.** Every URL
/// in the manifest is a public tarball on `nodejs.org` or `registry.npmjs.org`;
/// there is nothing to authenticate with and nothing that should be sent. An
/// ephemeral session carries no cookie jar and no credential store by
/// construction, which is why it is the right kind here rather than merely a
/// convenient one.
///
/// **`data(from:maximumByteCount:)` rather than a download task**, per D14's "the
/// seam carries bytes, not files": handing back a file URL would make Core
/// responsible for a temporary file it would have to hash, unpack *and* delete on
/// four different failure paths. The stated cost is the peak resident size of the
/// largest artifact, recorded as a known limit in
/// `docs/architecture/core-provisioning.md`.
///
/// **The maximum is enforced on bytes received, never on a header.** The body is
/// streamed through a `URLSessionDataDelegate` that appends each chunk and cancels
/// the task the moment the running total passes the maximum, so a response that
/// keeps sending is stopped at the ceiling rather than at the twenty-minute
/// resource timeout. `Content-Length` and `expectedContentLength` are deliberately
/// not consulted: a chunked response reports `-1`, and a header is written by
/// whoever is answering. `URLSession.bytes(for:)` was the other candidate and was
/// rejected — `AsyncBytes` yields one `UInt8` at a time, which turns a 53 MB
/// artifact into ~53 million iterations.
///
/// **A cancellation this file caused surfaces as the size failure, never as
/// "cancelled".** `URLSessionTask.cancel()` makes URLSession complete the request
/// with `URLError.cancelled`, and that word — not the size — is what would
/// otherwise reach `LSPInstallError.downloadFailed` and the Settings row. So the
/// delegate **records its own reason before it cancels**, and the completion path
/// consults that record first: a cancellation for the maximum throws
/// `Failure.tooLarge`. A cancellation this file did *not* cause keeps its own
/// error unchanged. `ScriptedDownloader` cannot see any of this — it runs no
/// URLSession at all — which is why the rule is stated here and beside D14 rather
/// than pinned by a test.
///
/// `@unchecked Sendable` over an immutable `let`, the `LSPProcessTransport`
/// arrangement: there is no mutable state here at all — the configuration is built
/// once, read-only afterwards, and `URLSession` copies it — and the per-request
/// delegate that *does* hold state is created, used and discarded inside one call.
final class LSPDownloadService: LSPArtifactDownloading, @unchecked Sendable {
    /// How long a single request may go without progress. Generous, because the
    /// slowest legitimate case is a first-launch Node download on a hotel network,
    /// and the failure mode this guards against is a connection that has silently
    /// gone away rather than one that is merely slow.
    private static let requestTimeout: TimeInterval = 60

    /// The ceiling on one whole artifact. 53 MB at a very poor 100 KB/s is about
    /// nine minutes, so twenty is "this is never going to finish" rather than
    /// "this is taking a while" — and a download that trips it fails exactly like
    /// any other, which is to say the row says "not installed" and offers Retry.
    private static let resourceTimeout: TimeInterval = 20 * 60

    /// Why a fetch did not produce bytes.
    ///
    /// Deliberately *not* an `LSPInstallError`, and the reason is worth stating:
    /// `LSPInstallEngine` wraps whatever this throws into
    /// `LSPInstallError.downloadFailed(component:reason:)` with the component id it
    /// alone knows, taking this error's `localizedDescription` as the reason. A
    /// typed install error thrown from here would therefore be re-wrapped into
    /// another one and surface as two attributions of the same failure. So every
    /// case below is a bare reason phrase — the same shape `ScriptedDownloader`'s
    /// fake failures already take, which is what makes the fake a faithful stand-in
    /// for this file.
    enum Failure: Error, LocalizedError {
        /// The server answered, and did not answer with the file: a 404 from a
        /// tarball a registry has since unpublished, a 403 from a proxy, a 500.
        case unexpectedStatus(Int)
        /// The response was not HTTP at all — only reachable if a manifest URL
        /// ever stopped being `https:`, which `LSPProvisioningManifestTests` pins
        /// against, and cheaper to answer than to reason about.
        case notHTTP
        /// More bytes arrived than the manifest pins for this artifact. The
        /// transfer was stopped where the ceiling is, so the sentence describes
        /// the body rather than the cancellation that carried it out.
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let code):
                return "The server responded \(code)."
            case .notHTTP:
                return "The server did not answer with a web response."
            case .tooLarge:
                return "The server sent more than the size this app expects for this download."
            }
        }
    }

    private let configuration: URLSessionConfiguration

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        // One artifact at a time is all the engine ever asks for (its sequence is
        // strictly serial), so this bounds nothing in practice — it is here so that
        // a future parallel install cannot turn a first launch into six
        // simultaneous transfers competing for the same link.
        configuration.httpMaximumConnectionsPerHost = 2
        // `waitsForConnectivity` stays off, on purpose. It would turn "there is no
        // network" into a request that sits silently until the resource timeout,
        // and this layer's answer to no network is to fail immediately and leave a
        // Retry button — a twenty-minute spinner is a worse version of the same
        // outcome.
        self.configuration = configuration
    }

    /// The bytes at `url`, or a `Failure`/`URLError` for anything else.
    ///
    /// A transport error propagates as itself: `URLError`'s own
    /// `localizedDescription` ("The Internet connection appears to be offline.")
    /// is a better sentence than anything this file could write, and it is the
    /// sentence the Settings row ends up showing.
    ///
    /// The session is per request because the delegate is: a delegate holds the
    /// bytes of exactly one transfer, so sharing one session would mean either
    /// keying that state by task or serializing the layer on a lock for a sequence
    /// that is already serial. It is invalidated when the call ends, which is what
    /// releases the delegate.
    func data(from url: URL, maximumByteCount: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let collector = BoundedBodyCollector(maximumByteCount: maximumByteCount)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            // Set before `resume()`, so no callback can arrive with nowhere to go.
            collector.attach(continuation)
            session.dataTask(with: request).resume()
        }
    }
}

/// One transfer's bytes, counted against a ceiling as they arrive.
///
/// The whole of the streaming half of D14: it appends, it counts, and it stops the
/// task itself when the total passes the maximum. Everything it refuses is
/// recorded as a `Failure` **before** the cancel, because URLSession reports a
/// cancelled task as `URLError.cancelled` regardless of why it was cancelled — so
/// the recorded reason, not the completion's error, is what the seam throws when
/// there is one. A completion with no record is either the bytes or somebody
/// else's error, both passed through untouched.
private final class BoundedBodyCollector: NSObject, URLSessionDataDelegate {
    private let maximumByteCount: Int
    private let lock = NSLock()
    private var body = Data()
    private var refusal: LSPDownloadService.Failure?
    private var continuation: CheckedContinuation<Data, Error>?

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func attach(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            record(.notHTTP)
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            record(.unexpectedStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        // `expectedContentLength` is deliberately not consulted here: it is the
        // sender's claim, and the ceiling is about what actually arrives.
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        body.append(data)
        let overLimit = body.count > maximumByteCount
        if overLimit {
            // Dropped rather than kept: the transfer is over, and holding the
            // chunk that crossed the line is the one thing the ceiling exists to
            // avoid.
            body = Data()
            refusal = refusal ?? .tooLarge
        }
        lock.unlock()
        if overLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let refusal = self.refusal
        let body = self.body
        self.body = Data()
        lock.unlock()

        guard let continuation else { return }
        if let refusal {
            continuation.resume(throwing: refusal)
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: body)
        }
    }

    private func record(_ failure: LSPDownloadService.Failure) {
        lock.lock()
        refusal = refusal ?? failure
        lock.unlock()
    }
}

#endif
