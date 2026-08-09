import Foundation

/// What the routing provider asks a language server through — the LSP half of the
/// composition, named as a protocol so the router can be built and tested without
/// one.
///
/// `CodeIntelligenceProviding` plus the one question a server-backed provider can
/// answer and an index-backed one cannot: *is it worth asking you at all*. The
/// router needs that before it spends a budget, because "no server serves this
/// language" and "the server timed out" must not cost the same — the first is
/// every language but Swift, on every keystroke, and has to be free.
///
/// `Sendable` because the router races the LSP call against a deadline, which puts
/// it in a child task; the wrapped fallback stays outside that race and needs no
/// such promise.
public protocol LSPIntelligenceSource: CodeIntelligenceProviding, Sendable {
    /// Whether a server for `language` is running, or could be started, for the
    /// folder currently open.
    ///
    /// A *policy* answer, not a health check: it starts nothing and probes
    /// nothing. `false` means there is no registered server, no open folder, or a
    /// `(server, root)` that D7 has given up on — the three cases where asking
    /// would only cost a hop.
    func canServe(_ language: SyntaxLanguage) async -> Bool
}

/// The one `CodeIntelligenceProviding` the editor surfaces hold: a language
/// server's answer where there is one, today's tree-sitter answer everywhere else.
///
/// This is the whole of phase 2a's user-visible contract. Everything below it can
/// fail — there may be no Xcode, sourcekit-lsp may not understand the project, the
/// process may be killed mid-session, the build system may take twenty seconds to
/// resolve — and *none* of that is allowed to be visible. So the composition is
/// deliberately dumb: ask the server, and if it does not answer something usable
/// in time, ask the index. Both questions have the same shape and the same result
/// type, so the caller cannot tell which one it got, and the editor keeps exactly
/// the behavior it shipped with.
///
/// Three properties are load-bearing, and each has a test.
///
/// **Fallback is per request, and silent.** A timeout marks nothing, logs nothing
/// and remembers nothing: the next request asks the server again. The only state
/// that outlives one question is D7's restart budget, and that lives in
/// `LSPWorkspace` where the failures are actually counted. There is no banner, no
/// alert and no "degraded" mode, because a user who never learns the editor has a
/// language server also never learns it lost one.
///
/// **A language with no server costs nothing.** `canServe` is asked first, so for
/// Markdown, YAML, a scratch buffer or a machine with no toolchain the request
/// never enters the LSP stack at all — it is handed straight to the wrapped
/// provider, and the output is *the wrapped provider's output*, byte for byte.
/// `RoutingIntelligenceProviderTests` pins that by equality on both request kinds
/// rather than by inspection, because "phase 2a changed nothing for the other
/// eleven languages" is the promise most worth being unable to break by accident.
///
/// **An empty answer is not an answer.** A server that returns no definitions
/// where the index has one has not answered the question better; it has failed to
/// answer it. So an empty LSP result falls through to the index, and only an empty
/// result from *both* is empty — the case the editor beeps at, once.
///
/// Not `@MainActor`: like both providers it composes, the two request methods are
/// `nonisolated async`, so the deadline race, the ranking and the index read all
/// stay off the main thread.
public final class RoutingIntelligenceProvider: CodeIntelligenceProviding {

    /// How long the *user* waits for a language server before the question is
    /// answered from the index instead (D7).
    ///
    /// The same numbers `LSPSession.Budgets` carries, measured over a different
    /// span — and both spans are deliberate. The session's budget bounds the
    /// *server's* part of one exchange: it starts when the request is written, and
    /// it is what keeps a wedged server to the cost of one question. This one
    /// bounds the whole attempt — resolving the language, starting a process,
    /// waiting out a handshake, flushing the buffer, and only then asking. Nothing
    /// else can bound the first of those: sourcekit-lsp is allowed twenty seconds
    /// to resolve a build system on first start, and a ⌘-click that blocked for
    /// twenty seconds would make the editor worse than having no language server
    /// at all.
    ///
    /// So on a cold project the first jump answers from tree-sitter while the
    /// server finishes starting behind it, and the next one is semantic. That is
    /// not a compromise but the point: the launch is an unstructured task
    /// `LSPWorkspace` owns, so abandoning *this* attempt does not abandon it.
    public struct Budgets: Equatable, Hashable, Sendable {
        public var definition: TimeInterval
        public var completion: TimeInterval
        /// The background `completionItem/resolve` prefetch (D4). Bounded for the
        /// same reason as the rest even though nobody is watching it: an
        /// unbounded prefetch is a task that outlives the popup it belongs to.
        public var resolve: TimeInterval

        public init(
            definition: TimeInterval = 3,
            completion: TimeInterval = 1.5,
            resolve: TimeInterval = 1.5
        ) {
            self.definition = definition
            self.completion = completion
            self.resolve = resolve
        }

        /// D7's numbers.
        public static let standard = Budgets()
    }

    private let lsp: any LSPIntelligenceSource
    private let fallback: any CodeIntelligenceProviding
    private let budgets: Budgets

    /// - Parameters:
    ///   - lsp: the server-backed source, asked first.
    ///   - fallback: the index-backed provider, asked whenever the first does not
    ///     answer — which on eleven of the twelve languages is always.
    public init(
        lsp: any LSPIntelligenceSource,
        fallback: any CodeIntelligenceProviding,
        budgets: Budgets = .standard
    ) {
        self.lsp = lsp
        self.fallback = fallback
        self.budgets = budgets
    }

    // MARK: - CodeIntelligenceProviding

    /// The server's locations, or the index's declarations.
    ///
    /// **D2's guard is not repeated here**, and that is a decision rather than an
    /// omission: a `DefinitionRequest` whose `text` was never filled in is
    /// unanswerable *by a language server* specifically — the index looks names up
    /// and does not care — so the rule belongs to `LSPIntelligenceProvider`, which
    /// refuses to send anything. This layer needs no special case, because "no
    /// answer" already routes to tree-sitter; the routed outcome is pinned by a
    /// test all the same.
    public func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] {
        if let language = request.fileURL
            .flatMap({ SyntaxLanguage(forFileName: $0.lastPathComponent) }),
           await lsp.canServe(language),
           let answer = await withBudget(budgets.definition, { [lsp] in
               await lsp.definitions(for: request)
           }),
           !answer.isEmpty {
            return answer
        }
        return await fallback.definitions(for: request)
    }

    /// The server's candidates, or the index's.
    ///
    /// The language comes off the request rather than off the file name: the
    /// editor resolved it once, and a `nil` there already means "this buffer has
    /// no language", which is exactly the state no server can be asked about.
    public func completions(for request: CompletionRequest) async -> [CompletionItem] {
        if let language = request.language,
           await lsp.canServe(language),
           let answer = await withBudget(budgets.completion, { [lsp] in
               await lsp.completions(for: request)
           }),
           !answer.isEmpty {
            return answer
        }
        return await fallback.completions(for: request)
    }

    /// D4's second round trip, routed to whichever provider issued the item.
    ///
    /// Neither side is asked whether it recognises the handle first: an item from
    /// the other provider resolves to `[]` there anyway (the seam's default), and
    /// an empty answer is indistinguishable from "nothing to add" — which is the
    /// same instruction to the editor either way. No `canServe` gate, because the
    /// item in hand *came from* a live list and the language question was already
    /// settled when it was published.
    public func resolveEdits(for item: CompletionItem) async -> [CompletionEdit] {
        if let edits = await withBudget(budgets.resolve, { [lsp] in
            await lsp.resolveEdits(for: item)
        }), !edits.isEmpty {
            return edits
        }
        return await fallback.resolveEdits(for: item)
    }

    // MARK: - The deadline

    /// Run `operation`, or give up on it after `budget` seconds.
    ///
    /// `nil` is "the budget ran out"; a genuine empty answer comes back as an
    /// empty value, and the callers above treat the two the same anyway. The
    /// loser is cancelled rather than left running, which is what turns an
    /// abandoned definition into a `$/cancelRequest` on the wire (the session's
    /// cancellation handler) instead of a server still computing an answer nobody
    /// will read.
    ///
    /// **Deliberately not a task group**, which is what this was and what it must
    /// not be. A group awaits every child before it returns, and `cancelAll()`
    /// only shortens a child that is *cancellable* — which the LSP attempt is not
    /// at the one point that matters. Waiting for a launch already in flight is
    /// `await Task.value` on a `Task<_, Never>`, and that ignores the awaiting
    /// task's cancellation entirely, so a group held the caller for the
    /// **handshake's** budget (20 s on a cold sourcekit-lsp) rather than for this
    /// one — turning the promise above exactly backwards: the first jump in a cold
    /// project waited out the whole start instead of being answered by
    /// tree-sitter while it happened. So the two racers are unstructured tasks
    /// meeting at a one-shot rendezvous, and this returns the moment either
    /// settles, leaving the loser to unwind on its own. The consequence worth
    /// stating: the cancellation is *scheduled* by the time the caller sees `nil`,
    /// not already written to the wire.
    private func withBudget<T: Sendable>(
        _ budget: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let race = FirstAnswer<T>()
        let work = Task { race.settle(await operation()) }
        let deadline = Task {
            // A cancelled sleep throws and settles `nil` all the same, so nothing
            // is left waiting when the caller gets its answer from the other side.
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            race.settle(nil)
        }
        defer {
            work.cancel()
            deadline.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                race.arm(continuation)
            }
        } onCancel: {
            // The caller's own task was cancelled (a newer keystroke superseded
            // the completion behind this one). Answering `nil` immediately is what
            // sends it to the index instead of leaving it on a budget nobody is
            // waiting out any more.
            race.settle(nil)
        }
    }
}

/// A one-shot rendezvous between a piece of work and its deadline.
///
/// Whichever of the two settles first resumes the waiting caller; every later
/// settle is dropped. A bare `CheckedContinuation` cannot express that on its own
/// — it must be resumed exactly once, and here two independent tasks race to do
/// it — and a lock is enough, because settling is one store and one hand-off.
///
/// `arm` can lose the race too, which is why the value is remembered rather than
/// only forwarded: `withTaskCancellationHandler` runs `onCancel` *immediately*
/// when the calling task is already cancelled, i.e. possibly before the
/// continuation exists at all. A continuation armed after the fact is resumed
/// with the answer that arrived first.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var isSettled = false
    private var value: T?

    func arm(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        guard !isSettled else {
            let value = self.value
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func settle(_ value: T?) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        self.value = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
