import Foundation

/// The `CodeIntelligenceProviding` implementation that answers from a language
/// server — the last layer of the LSP stack, and the only one the rest of the app
/// could ever see.
///
/// Everything below it speaks the protocol: `LSPWorkspace` decides *which*
/// conversation, `LSPSession` drives it, `LSPProtocolTypes` spells the bodies.
/// This file does the one translation none of them can: an LSP answer is about
/// lines and characters in documents, and the editor knows only UTF-16 offsets
/// into buffers. Every position that crosses in either direction goes through
/// `LSPPositionMap` here, so nothing above the seam ever learns what a line is.
///
/// Three rules run through it.
///
/// **No answer is better than a guessed one.** Every uncertainty — no file URL,
/// no language, no caret offset, no server, a request that failed, a target file
/// that cannot be read — returns an empty result, and `RoutingIntelligenceProvider`
/// (task 7) reads that as "ask tree-sitter". None of it is logged, alerted or
/// remembered; D7's fallback is per request and silent. The one case worth naming
/// is D2's guard: a `DefinitionRequest` whose `text` is empty while its `offset`
/// is not was built by a call site that forgot to pass the buffer, and clamping
/// its position to `0:0` would ask the server a confidently wrong question and get
/// a confidently wrong answer — which never falls back, because it *is* an answer.
/// So nothing is sent at all.
///
/// **The server's ranking is the ranking** (D6). Items are ordered by
/// `sortText ?? label` with the server's own array order preserved on ties, then
/// only hygiene is applied: drop the item identical to what was typed, collapse
/// duplicates by inserted text, cap the list. No name heuristic, no
/// current-file bonus, no fuzzy quality — those exist in
/// `SymbolIntelligenceProvider` because a bucket of names has no ranking of its
/// own, while a server has spent real work on this order and second-guessing it
/// with a string rule would only make it worse.
///
/// **A reader, never a writer** (D10). It reads buffers, asks questions and reads
/// files it is told about. It writes nothing, takes no writer gate, and is gated
/// by none.
///
/// Not an actor and not `@MainActor`: the two request methods are `nonisolated
/// async` so (SE-0338) their bodies run on the cooperative pool — the ranking,
/// the position mapping and the target-file reads all stay off the main thread —
/// and the only mutable state is the resolve table, which is small, touched twice
/// per completion round and guarded by a lock rather than by an actor hop.
public final class LSPIntelligenceProvider: CodeIntelligenceProviding, @unchecked Sendable {

    /// How the text of a file the *server* named is obtained.
    ///
    /// A seam for the same reason `LSPWorkspace.transportFactory` is one: a
    /// definition answer points at a file — an SDK `.swiftinterface`, another
    /// module's source — whose text this layer needs to turn a `(line, character)`
    /// pair into a buffer offset, and a test must be able to answer that without a
    /// project on disk. `nil` means "not readable", and a target whose text cannot
    /// be read is dropped rather than guessed at (see `candidate(for:…)`).
    public typealias TextLoader = @Sendable (URL) -> String?

    /// How large a file may be before a definition target in it is given up on.
    ///
    /// Generous, because the files this actually reads are generated interfaces
    /// (`Swift.String.swiftinterface` is roughly 20 000 lines) rather than user
    /// documents, and bounded anyway, because the alternative is loading whatever
    /// path a server happened to name into memory on a ⌘-click.
    public static let maximumTargetFileBytes = 16 * 1024 * 1024

    /// The default: an ordinary UTF-8 read that refuses binary and oversize
    /// files, i.e. exactly what Find in Files reads a file with.
    public static let defaultTextLoader: TextLoader = { url in
        (try? FileService().readTextIfNotBinary(url: url, maxBytes: maximumTargetFileBytes)) ?? nil
    }

    /// What a deferred item needs when the editor finally asks for its edits.
    ///
    /// The session is captured with the item: a resolve is only meaningful to the
    /// process that produced the list (sourcekit-lsp's `data` is a
    /// `{sessionId, itemId, uri}` triple), so sending it to a restarted server
    /// would resolve nothing at best.
    private struct PendingResolve {
        let session: LSPSession
        let item: LSPCompletionItem
        /// The buffer the offsets were computed against, so the resolved edits
        /// land in the same coordinates the primary one did.
        let text: String
        let typedWord: NSRange
    }

    private let workspace: LSPWorkspace
    private let loadText: TextLoader
    private let completionLimit: Int

    private let lock = NSLock()
    private var nextResolveHandle = 1
    /// The current list's deferred items, replaced wholesale when a new list is
    /// published — so a handle can only ever name an item from the list the popup
    /// is actually showing, and the table cannot grow with the session.
    private var pendingResolves: [Int: PendingResolve] = [:]

    public init(
        workspace: LSPWorkspace,
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        loadText: @escaping TextLoader = LSPIntelligenceProvider.defaultTextLoader
    ) {
        self.workspace = workspace
        self.completionLimit = completionLimit
        self.loadText = loadText
    }

    // MARK: - Definitions

    /// Where the server says the identifier under the caret is declared.
    ///
    /// The request carries its own buffer (D2), so the flush that precedes it —
    /// `didOpen`, or a `didChange` with a bumped version — happens inside
    /// `LSPWorkspace.prepare`, and the position below is computed against exactly
    /// the text the server has just been given.
    ///
    /// The candidates come back in the server's order, which is the answer's own
    /// order: sourcekit-lsp answers a type reference with the type *and* its
    /// memberwise initializer, and which of those the user meant is not something
    /// a sort key here could know better than the compiler did.
    public func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] {
        guard !request.identifier.isEmpty else { return [] }
        // D2's guard. An empty buffer is a legitimate document — but only at
        // offset 0; any other offset means the text was never passed and the
        // position would be a fiction.
        guard !(request.text.isEmpty && request.offset != 0) else { return [] }
        guard let fileURL = request.fileURL,
              let language = SyntaxLanguage(forFileName: fileURL.lastPathComponent),
              let prepared = await workspace.prepare(
                  url: fileURL,
                  language: language,
                  text: request.text
              )
        else { return [] }

        let source = request.text as NSString
        let position = LSPPositionMap.position(forOffset: request.offset, in: source)
        guard let response = try? await prepared.session.definition(
            LSPTextDocumentPositionParams(uri: prepared.uri, position: position)
        ) else { return [] }

        let root = await workspace.root
        // One text per file rather than one per target: a cross-module jump
        // routinely answers with two locations in the same file, and the file may
        // be a 20 000-line generated interface.
        var texts: [String: NSString] = [:]
        return response.targets.compactMap { target in
            candidate(
                for: target,
                identifier: request.identifier,
                requestURL: fileURL,
                requestText: source,
                root: root,
                texts: &texts
            )
        }
    }

    /// One target turned into something the picker can show and the editor can
    /// jump to.
    ///
    /// `nil` — and so, silently, one fewer candidate — when the URI is not a file
    /// URL or its text cannot be read. Both are refusals rather than
    /// approximations on purpose: every consumer of a candidate navigates by
    /// `range`, and without the target's text there is no offset to put in it,
    /// only an LSP line number that would be right in most files and wrong in
    /// exactly the ones D1's separator rule is about.
    private func candidate(
        for target: LSPDefinitionTarget,
        identifier: String,
        requestURL: URL,
        requestText: NSString,
        root: URL?,
        texts: inout [String: NSString]
    ) -> DefinitionCandidate? {
        guard let url = URL(string: target.uri), url.isFileURL else { return nil }
        let file = url.standardizedFileURL

        let content: NSString
        if CanonicalPath.canonical(file) == CanonicalPath.canonical(requestURL) {
            // The buffer beats the disk, for the index's reason: what the user is
            // reading is the edited text, and a jump within the file being edited
            // must land where the caret would go, not where the last save put it.
            content = requestText
        } else if let cached = texts[file.path] {
            content = cached
        } else if let loaded = loadText(file) {
            content = loaded as NSString
            texts[file.path] = content
        } else {
            return nil
        }

        let range = LSPPositionMap.range(for: target.jumpRange, in: content)
        // The *display* line is the editor's, not the server's (D1): derived from
        // the offset with `LineStartIndex`, so the number in the picker is the
        // number in the gutter even in a file the two disagree about.
        let line = TextSearchEngine.lineNumber(
            forOffset: range.location,
            in: LineStartIndex.offsets(in: content)
        )

        let inside = root.flatMap {
            CanonicalPath.relativeComponents(
                of: CanonicalPath.canonical(file).pathComponents,
                under: CanonicalPath.canonical($0).pathComponents
            )
        }
        return DefinitionCandidate(
            // A location is not a declaration: the server was asked "where", not
            // "what", so there is no name and no kind in the answer. The
            // identifier the user clicked is what the jump is *about*, and it is
            // what the picker row must read for the row to mean anything.
            name: identifier,
            kind: nil,
            fileURL: file,
            range: range,
            line: line,
            // Canonical components rather than `ProjectFileWalk.relativePath`'s
            // lexical strip: a server answers with the path *it* resolved, and
            // sourcekit-lsp really does report `/private/tmp/…` for a project
            // opened as `/tmp/…`, which a prefix comparison reads as "outside the
            // root" and would show as a bare file name.
            relativePath: inside?.joined(separator: "/") ?? file.lastPathComponent,
            isOutsideProjectRoot: inside == nil
        )
    }

    // MARK: - Completions

    /// What the server offers at the caret.
    ///
    /// A member request (`request.member != nil`) is sent as a `.` trigger rather
    /// than as a plain invocation: the two produce genuinely different lists from
    /// the same position — the trigger is what tells the server the user has
    /// committed to a member access — and the editor has already decided which
    /// this is, in the one place that can see the caret.
    public func completions(for request: CompletionRequest) async -> [CompletionItem] {
        guard let offset = request.offset,
              let fileURL = request.fileURL,
              let language = request.language,
              let prepared = await workspace.prepare(
                  url: fileURL,
                  language: language,
                  text: request.text
              )
        else { return [] }

        let source = request.text as NSString
        let position = LSPPositionMap.position(forOffset: offset, in: source)
        guard let response = try? await prepared.session.completion(
            LSPCompletionParams(
                uri: prepared.uri,
                position: position,
                context: request.member == nil ? .invoked : .dot
            )
        ) else { return [] }

        // A member context already carries the range a completion replaces, and
        // it is the same range the ordinary path reconstructs — see
        // `IdentifierScanner.MemberContext.prefixRange`. Using it where it exists
        // means the two paths cannot disagree about what the user typed.
        let typedWord = request.member?.prefixRange ?? LSPIntelligenceProvider.typedWordRange(
            endingAt: offset,
            prefix: request.prefix,
            length: source.length
        )
        let resolves = await prepared.session.capabilities?.resolvesCompletionItems ?? false

        return publish(
            response.items,
            typed: request.prefix,
            typedWord: typedWord,
            in: source,
            session: prepared.session,
            serverResolves: resolves
        )
    }

    /// D6's order, D6's hygiene, and the resolve bookkeeping — the whole of what
    /// happens between a `CompletionList` and the strings the popup shows.
    private func publish(
        _ items: [LSPCompletionItem],
        typed: String,
        typedWord: NSRange,
        in text: NSString,
        session: LSPSession,
        serverResolves: Bool
    ) -> [CompletionItem] {
        // `sorted(by:)` is not documented as stable, and the server's array order
        // is meaningful on a tie (it is the order it decided to send them in), so
        // the index is carried as the last key rather than trusted.
        let ordered = items.enumerated().sorted { lhs, rhs in
            lhs.element.rankingKey == rhs.element.rankingKey
                ? lhs.offset < rhs.offset
                : lhs.element.rankingKey < rhs.element.rankingKey
        }

        var seen = Set<String>()
        var results: [CompletionItem] = []
        var deferred: [Int: PendingResolve] = [:]
        var handle = claimResolveHandles(count: items.count)

        for entry in ordered {
            let item = entry.element
            let inserted = item.insertedText
            // Completing `foo` to `foo` inserts nothing and hides a real
            // candidate behind it — the same rule the tree-sitter path applies,
            // stated here too because the two lists are never merged.
            guard !inserted.isEmpty, inserted != typed else { continue }
            guard seen.insert(inserted).inserted else { continue }

            var resolveHandle: Int?
            if serverResolves, item.needsResolve {
                resolveHandle = handle
                deferred[handle] = PendingResolve(
                    session: session,
                    item: item,
                    text: text as String,
                    typedWord: typedWord
                )
                handle += 1
            }

            results.append(
                CompletionItem(
                    text: inserted,
                    kind: item.kind?.symbolKind,
                    // The server does not say, and nothing above ranks on it: D6
                    // adds no key of its own, so the flag is inert here rather
                    // than false in some interesting sense.
                    isFromCurrentFile: false,
                    edits: edits(for: item, typedWord: typedWord, in: text),
                    resolveHandle: resolveHandle
                )
            )
            if results.count == completionLimit { break }
        }

        replacePendingResolves(with: deferred)
        return results
    }

    /// The edits an item performs, in buffer coordinates — or none at all.
    ///
    /// **None** is the common case and the point of the emptiness: an item that
    /// merely replaces the typed word with its own text is what AppKit's stock
    /// completion machinery already does correctly, and routing it through the
    /// editor's own applier would buy nothing and cost an undo group. Edits are
    /// emitted only when applying them *as written* actually matters: the item
    /// drags an `import` along (D4), or the server chose a range other than the
    /// one the client typed — which it is entitled to do, and which AppKit would
    /// then get wrong.
    private func edits(
        for item: LSPCompletionItem,
        typedWord: NSRange,
        in text: NSString
    ) -> [CompletionEdit] {
        let primaryRange = item.textEdit.map { LSPPositionMap.range(for: $0.range, in: text) }
            ?? typedWord
        let additional = (item.additionalTextEdits ?? []).map {
            CompletionEdit(
                range: LSPPositionMap.range(for: $0.range, in: text),
                newText: $0.newText,
                role: .additional
            )
        }
        guard !additional.isEmpty || primaryRange != typedWord else { return [] }
        return [
            CompletionEdit(range: primaryRange, newText: item.insertedText, role: .primary)
        ] + additional
    }

    // MARK: - Resolve

    /// The second round trip for an item the server kept edits back on (D4).
    ///
    /// Answers `[]` for everything that is not exactly this: an item with no
    /// handle, a handle from a list that has since been superseded, an item from
    /// another provider, a server that has gone away, a resolve that timed out.
    /// The editor reads that as "insert the plain text", which is what it would
    /// have done anyway — the auto-import is the only thing lost.
    public func resolveEdits(for item: CompletionItem) async -> [CompletionEdit] {
        guard let handle = item.resolveHandle, let pending = pendingResolve(handle) else {
            return []
        }

        guard let resolved = try? await pending.session.resolveCompletionItem(pending.item) else {
            return []
        }
        return edits(
            for: resolved,
            typedWord: pending.typedWord,
            in: pending.text as NSString
        )
    }

    /// The deferred item behind a handle, if it belongs to the list currently
    /// shown.
    ///
    /// Synchronous on purpose: `NSLock` may not be taken across a suspension
    /// point, so every access to the table is a non-`async` function that takes
    /// it, reads, and gives it back before anything can await.
    private func pendingResolve(_ handle: Int) -> PendingResolve? {
        lock.lock()
        defer { lock.unlock() }
        return pendingResolves[handle]
    }

    private func replacePendingResolves(with deferred: [Int: PendingResolve]) {
        lock.lock()
        pendingResolves = deferred
        lock.unlock()
    }

    /// Reserve a contiguous block of handles for one list.
    ///
    /// Monotonic across the whole provider, never reused: a handle from a
    /// superseded list must resolve to nothing rather than to whatever item now
    /// sits at that number in the new one.
    private func claimResolveHandles(count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let first = nextResolveHandle
        nextResolveHandle += max(count, 0)
        return first
    }

    // MARK: - Geometry

    /// The range the typed word occupies, reconstructed from the caret and the
    /// prefix the editor resolved there.
    ///
    /// Exact rather than approximate: both call sites take `prefix` from the
    /// range immediately left of the caret (`IdentifierScanner`'s
    /// `completionPrefixRange`), so its UTF-16 length *is* the distance back to
    /// the word's start. Clamped anyway, because the buffer this is measured
    /// against is the one that travelled with the request.
    static func typedWordRange(endingAt offset: Int, prefix: String, length: Int) -> NSRange {
        let end = min(max(offset, 0), length)
        let start = max(end - (prefix as NSString).length, 0)
        return NSRange(location: start, length: end - start)
    }
}

extension LSPCompletionItemKind {
    /// The editor's declaration kind for an LSP completion kind, or `nil` when
    /// there is no honest equivalent.
    ///
    /// `SymbolKind` is a closed set pinned by set equality against the shipped
    /// `symbols.scm` queries (`SymbolQueryTests`), so it cannot grow a case for
    /// LSP's `.module`, `.snippet` or `.color`. Answering `nil` for those is not a
    /// loss: the kind is a ranking and presentation hint, and D6 ranks on neither
    /// — the completion is still offered, it just declines to claim a category it
    /// does not have.
    var symbolKind: SymbolKind? {
        switch self {
        case .method, .constructor: return .method
        case .function: return .function
        case .field, .property: return .property
        case .variable: return .variable
        case .class, .interface, .enum, .struct, .typeParameter: return .type
        case .constant, .enumMember: return .constant
        case .operator: return .function
        default: return nil
        }
    }
}
