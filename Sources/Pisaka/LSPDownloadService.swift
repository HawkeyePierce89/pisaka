#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPArtifactDownloading`: one `URLSession`, one request, one `Data`
/// (D14).
///
/// The app half of the download seam, and the counterpart to `LSPProcessTransport`
/// on the other one — Core owns *what* may be fetched (the pinned manifest), *what
/// makes it acceptable* (the SHA-256) and *what happens when it is not* (the whole
/// staging/rename sequence); this file owns the socket and knows none of that. It
/// is untested by repository convention, so it is kept to the two decisions it
/// actually makes: how the session is configured, and what counts as a failure.
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
/// **`data(from:)` rather than a download task**, per D14's "the seam carries
/// bytes, not files": handing back a file URL would make Core responsible for a
/// temporary file it would have to hash, unpack *and* delete on four different
/// failure paths. The stated cost is the peak resident size of the largest
/// artifact, recorded as a known limit in
/// `docs/architecture/core-provisioning.md`.
///
/// `@unchecked Sendable` over an immutable `let`, the `LSPProcessTransport`
/// arrangement: there is no mutable state here at all, and `URLSession` is
/// documented as safe to use from multiple threads.
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

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let code):
                return "The server responded \(code)."
            case .notHTTP:
                return "The server did not answer with a web response."
            }
        }
    }

    private let session: URLSession

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
        session = URLSession(configuration: configuration)
    }

    /// The bytes at `url`, or a `Failure`/`URLError` for anything else.
    ///
    /// A transport error propagates as itself: `URLError`'s own
    /// `localizedDescription` ("The Internet connection appears to be offline.")
    /// is a better sentence than anything this file could write, and it is the
    /// sentence the Settings row ends up showing.
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard http.statusCode == 200 else { throw Failure.unexpectedStatus(http.statusCode) }
        return data
    }
}

#endif
