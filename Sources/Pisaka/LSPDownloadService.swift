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
/// that. It is kept to the three decisions it actually makes: how the session is
/// configured, what counts as a failure, and where the bytes stop. Of those, the
/// last two are pinned by `BoundedBodyCollectorTests` in the app-layer bundle,
/// which drives the delegate callbacks directly and touches no network; the
/// configuration stays untested by repository convention.
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
/// streamed through a `URLSessionDataDelegate` that measures each arriving chunk
/// against the room still allowed *before* it appends anything: a chunk that does
/// not fit is never appended, the body already collected is dropped, and the task
/// is cancelled there. Nothing is accumulated after that, because the cancel is
/// asynchronous and the chunks still in flight would otherwise rebuild a buffer
/// from nothing. So a
/// response that keeps sending is stopped at the ceiling rather than at the
/// twenty-minute resource timeout, and the ceiling is inclusive — a chunk exactly
/// filling the remaining room is kept.
/// `Content-Length` and `expectedContentLength` are deliberately
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
/// URLSession at all — so the rule is pinned instead by
/// `BoundedBodyCollectorTests`, which feeds the delegate a self-caused cancel's
/// `URLError.cancelled` completion and asserts the seam still resolves as
/// `Failure.tooLarge`.
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
        // Read this as a bound on *one request*, not on the layer: the limit is
        // per `URLSession`, and a session here lives for exactly one call (see
        // `data(from:maximumByteCount:)`), so N concurrent calls would be N
        // sessions and up to 2N connections. It therefore bounds nothing today —
        // the engine's artifact sequence is strictly serial, one transfer at a
        // time — and is kept only so a redirect chain or a retry inside a single
        // request cannot fan out.
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
    /// releases the delegate. **The stated cost is that no connection is reused
    /// between artifacts** — the pool is per session, so `yaml-language-server`'s
    /// twenty `registry.npmjs.org` tarballs cost twenty handshakes rather than one
    /// reused HTTP/2 connection. That is a first-install latency cost measured in
    /// a second or two on a real link, paid once, and it buys a delegate whose
    /// whole state is one transfer's; recorded as a known limit in
    /// `docs/architecture/core-provisioning.md`.
    ///
    /// **The transfer is not Swift-task-cancellable**, and that is a limit rather
    /// than an oversight: cancelling the enclosing `Task` neither cancels the URL
    /// task nor resumes this continuation early, so the call returns when the
    /// transfer does (or at the resource timeout). Nothing cancels an install —
    /// `LSPProvisioningModel` never cancels its attempt task — so there is no
    /// caller to serve, and serving a hypothetical one means the collector must
    /// also remember a completion that arrived before `attach`, since
    /// `URLSessionTask.cancel()` can race `resume()`. Adding that bookkeeping for
    /// nobody is the more expensive mistake; the day a Cancel button exists, this
    /// is the paragraph it has to delete.
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
/// The whole of the streaming half of D14: it counts, then it appends, and it
/// stops the task itself when a chunk does not fit the room still allowed — the
/// order being the point, since a chunk measured after it is appended is a chunk
/// the ceiling has already let in. Everything it refuses is
/// recorded as a `Failure` **before** the cancel, because URLSession reports a
/// cancelled task as `URLError.cancelled` regardless of why it was cancelled — so
/// the recorded reason, not the completion's error, is what the seam throws when
/// there is one. A completion with no record is either the bytes or somebody
/// else's error, both passed through untouched.
final class BoundedBodyCollector: NSObject, URLSessionDataDelegate {
    private let maximumByteCount: Int
    private let lock = NSLock()
    private var body = Data()
    /// The high-water mark of `body.count`, updated wherever the body grows.
    /// It is *the* observable of the check-then-append order: the final state
    /// after a refusal is identical either way (the body is dropped), so only
    /// what was transiently resident tells the two orders apart. Read through
    /// `peakHeldByteCount`.
    private var peakByteCount = 0
    private var refusal: LSPDownloadService.Failure?
    private var continuation: CheckedContinuation<Data, Error>?

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
        // The maximum *is* the artifact's pinned size, exactly, so this is the
        // final length in the ordinary case rather than a guess. Reserving it
        // keeps the peak resident cost the one the docs state: appending 52 MB in
        // chunks otherwise doubles the buffer repeatedly, and each doubling holds
        // the old allocation and the new one at once. The promise holds because
        // the check precedes the append — nothing that would outgrow this
        // capacity is ever appended — and because a refusal is latched, so the
        // dropped body is never rebuilt into an unreserved one. The body's peak
        // is the pinned size, reached without a reallocation past it.
        body.reserveCapacity(maximumByteCount)
    }

    /// The bytes currently held. Exists for `BoundedBodyCollectorTests` in the
    /// app-layer bundle, which reads it synchronously right after a chunk
    /// callback; nothing in `Sources` calls it. It states the *outcome* — what
    /// a fitting chunk accumulated, and that a refusal drops the lot — never the
    /// order, which both orders agree on and only `peakHeldByteCount` separates.
    /// It takes the lock like every other reader here.
    var heldByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return body.count
    }

    /// The most bytes ever held at once. Exists for the same suite, and it is
    /// the accessor that pins the order rather than merely the outcome: a
    /// collector that appended first and measured afterwards would report a
    /// peak above `maximumByteCount`, which is exactly the promise the reserved
    /// capacity makes.
    var peakHeldByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakByteCount
    }

    /// The refusal recorded so far, if any. Exists for the same suite and for
    /// the same reason — the recorded reason is what the completion path
    /// prefers, so it is the thing the order is observed through.
    var recordedRefusal: LSPDownloadService.Failure? {
        lock.lock()
        defer { lock.unlock() }
        return refusal
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
        // A recorded refusal ends the transfer, and `cancel()` is asynchronous:
        // chunks already in flight still arrive afterwards. Accumulating them
        // would start over from an empty body — one whose reserved capacity went
        // with the refused one — and grow it back by doubling, which is the
        // allocation the reserve exists to prevent. So nothing is accumulated
        // once a reason is on record, and the first reason stays the one kept.
        guard refusal == nil else {
            lock.unlock()
            return
        }
        // Measured against what is still allowed, *before* anything is appended:
        // a chunk that does not fit is never appended, so the body never grows
        // past the capacity reserved for the pin. The ceiling is inclusive — a
        // chunk exactly filling the remaining room is kept.
        let roomLeft = maximumByteCount - body.count
        let overLimit = data.count > roomLeft
        if overLimit {
            // Dropped rather than kept: the transfer is over, and holding what
            // has arrived so far is the one thing the ceiling exists to avoid.
            body = Data()
            refusal = .tooLarge
        } else {
            body.append(data)
            peakByteCount = max(peakByteCount, body.count)
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
