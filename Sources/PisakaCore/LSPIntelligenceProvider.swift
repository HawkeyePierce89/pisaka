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
/// with a string rule would only make it worse. The one thing that does sit above
/// `sortText` is not a ranking either: whether an item answers what was typed at
/// all, because a server is not obliged to have asked that question (see
/// `publish`) and the cap must not spend itself on the items that do not.
///
/// **A reader, never a writer** (D10). It reads buffers, asks questions and reads
/// files it is told about. It writes nothing, takes no writer gate, and is gated
/// by none.
///
/// Not an actor and not `@MainActor`: the request methods are `nonisolated
/// async` so (SE-0338) their bodies run on the cooperative pool — the ranking,
/// the position mapping, the markup normalization and the target-file reads all
/// stay off the main thread —
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
    /// The request-ordering token of the list `pendingResolves` belongs to, and
    /// the one behind the next request — the generation-token discipline, applied
    /// to the one piece of state a completion leaves behind.
    ///
    /// Two completion requests overlap as a matter of course: the router abandons
    /// one at its deadline and it keeps running, the next keystroke asks again.
    /// Without an order, the table is whichever *finished* last rather than
    /// whichever the editor is showing, so an older answer landing late would wipe
    /// the displayed list's handles and take D4's auto-import with them —
    /// silently, since a missing handle reads exactly like a superseded one.
    private var nextListToken = 0
    private var publishedListToken = 0

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
        // `prepare` guaranteed the server's text and the open folder when it
        // returned, not for the life of the question — see
        // `LSPWorkspace.stillHolds(_:)`. An answer computed against a document some
        // other request talked the server out of underneath this one, or by a server
        // initialized for a folder the user has since left, is dropped rather than
        // mapped, for this file's first rule: no answer is better than a guessed
        // one, and a jump is the one place a guess is indistinguishable from
        // knowledge.
        guard await workspace.stillHolds(prepared) else { return [] }

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

    // MARK: - Find usages

    /// Every place the server says the symbol at the caret is used.
    ///
    /// `definitions(for:)` step for step — D2's guard, the language off the file
    /// name, `prepare` so the live buffer reaches the server before the question,
    /// `LSPPositionMap` on the way in and on the way out, `stillHolds` before the
    /// answer is read — with `hover`'s capability gate in front of it. The gate is
    /// worth a line here for a different reason than hover's: this request is not
    /// asked on a timer, but a server that cannot answer it would still cost the
    /// user the whole budget before the model gives up and walks the project, and
    /// the walk is the answer they are actually going to get.
    ///
    /// **An empty answer is returned as an empty answer**, not converted into
    /// anything. What replaces it is `FindUsagesModel`'s decision, not this
    /// layer's (decision 1): a provider that walked the project to fill in a gap
    /// would put a project-wide file scan inside the router's budget race, where
    /// the loser is abandoned mid-walk and nobody is left to say so.
    public func references(for request: UsagesRequest) async -> [UsageResult] {
        guard !request.identifier.isEmpty else { return [] }
        // D2's guard, in the words the definition path states it in: an empty
        // buffer is a legitimate document, but only at offset 0.
        guard !(request.text.isEmpty && request.offset != 0) else { return [] }
        guard let fileURL = request.fileURL,
              let language = SyntaxLanguage(forFileName: fileURL.lastPathComponent),
              let prepared = await workspace.prepare(
                  url: fileURL,
                  language: language,
                  text: request.text
              ),
              await prepared.session.capabilities?.supportsReferences == true
        else { return [] }

        let source = request.text as NSString
        let position = LSPPositionMap.position(forOffset: request.offset, in: source)
        guard let response = try? await prepared.session.references(
            LSPReferenceParams(uri: prepared.uri, position: position)
        ) else { return [] }
        // The same staleness gate every mapped answer takes, for the same reason:
        // a row is a *range in a buffer*, and a range computed against a document
        // some other request talked the server out of underneath this one points
        // at text that has moved.
        guard await workspace.stillHolds(prepared) else { return [] }

        let root = await workspace.root
        var texts = FileTextCache(requestURL: fileURL, requestText: source)
        return response.locations.compactMap { location in
            usage(at: location, root: root, texts: &texts)
        }
    }

    /// One location turned into a row the panel can draw and the editor can
    /// reveal.
    ///
    /// `nil` — one fewer row, silently — for `candidate(for:…)`'s two refusals and
    /// for its reasons: a URI that is not a file URL names nothing this editor can
    /// open, and a file whose text cannot be read has no offsets to navigate by,
    /// only protocol line numbers that would be right in most files and wrong in
    /// exactly the ones D1 is about.
    private func usage(
        at location: LSPLocation,
        root: URL?,
        texts: inout FileTextCache
    ) -> UsageResult? {
        guard let url = URL(string: location.uri), url.isFileURL else { return nil }
        let file = url.standardizedFileURL
        guard let content = texts.text(for: file, loadText: loadText) else { return nil }

        let range = LSPPositionMap.range(for: location.range, in: content.text)
        // The *display* line is the editor's, not the server's (D1).
        let line = TextSearchEngine.lineNumber(forOffset: range.location, in: content.lineStarts)
        let inside = root.flatMap {
            CanonicalPath.relativeComponents(
                of: CanonicalPath.canonical(file).pathComponents,
                under: CanonicalPath.canonical($0).pathComponents
            )
        }
        return UsageResult(
            fileURL: file,
            range: range,
            line: line,
            // Canonical components rather than a lexical strip, for
            // `candidate(for:…)`'s reason: a server answers with the path *it*
            // resolved, and `/private/tmp/…` for a project opened as `/tmp/…` is
            // a real answer a prefix comparison reads as "outside the root".
            relativePath: inside?.joined(separator: "/") ?? file.lastPathComponent,
            preview: ProjectSearchModel.preview(
                for: SearchMatch(range: range, lineNumber: line),
                in: content.text
            ),
            // A server resolved the symbol: this row means what it says.
            isTextual: false
        )
    }

    // MARK: - Rename

    /// The workspace-wide edit that renames the symbol at the caret.
    ///
    /// The same seven steps as `references(for:)`, plus two refusals of its own,
    /// and every one of its outcomes is `nil` — there is nothing else this can
    /// answer, because there is no second source for a rename (decision 4, and
    /// D25's reasoning applied to a command that writes).
    ///
    /// **A name that changes nothing is refused before the wire.** An empty new
    /// name is not a rename, and a new name equal to the old one is a
    /// `WorkspaceEdit` full of edits that replace text with itself — which would
    /// pass every verification in `RenameEditPlan` and rewrite a project's worth of
    /// files to no effect, taking each one's undo stack with it. The dialog refuses
    /// both too; this refuses them again because the dialog is not the only thing
    /// that can build a request.
    ///
    /// **A server that answers with no edits answers `nil`.** "No edits" and "I
    /// cannot rename this" are the same fact to every caller — the command beeps —
    /// and collapsing them here is what keeps the writer bracket from being raised
    /// around a plan that touches nothing.
    public func renameEdits(for request: RenameRequest) async -> RenameAnswer? {
        guard !request.identifier.isEmpty,
              !request.newName.isEmpty,
              request.newName != request.identifier else { return nil }
        guard !(request.text.isEmpty && request.offset != 0) else { return nil }
        guard let fileURL = request.fileURL,
              let language = SyntaxLanguage(forFileName: fileURL.lastPathComponent),
              let prepared = await workspace.prepare(
                  url: fileURL,
                  language: language,
                  text: request.text
              ),
              await prepared.session.capabilities?.supportsRename == true
        else { return nil }

        let source = request.text as NSString
        let position = LSPPositionMap.position(forOffset: request.offset, in: source)
        guard let edit = try? await prepared.session.rename(
            LSPRenameParams(uri: prepared.uri, position: position, newName: request.newName)
        ) else { return nil }
        // Load-bearing here in a way it is nowhere else in this file: every other
        // answer that survives a stale document is a wrong *reading*, and this one
        // would be a wrong *write*.
        guard await workspace.stillHolds(prepared) else { return nil }
        guard edit.documents.contains(where: { !$0.edits.isEmpty }) else { return nil }

        return RenameAnswer(newName: request.newName, edit: edit)
    }

    // MARK: - Hover

    /// What the server says the thing under the pointer *is* (D25).
    ///
    /// `definitions(for:)` step for step — D2's guard, the language off the file
    /// name, `prepare` so the live buffer reaches the server before the question,
    /// `LSPPositionMap` on the way in and on the way out, and `stillHolds` before
    /// the answer is read — with two rules of its own.
    ///
    /// **A server that does not advertise hover is not asked.** Every other
    /// request in this layer would merely waste a round trip; this one runs
    /// whenever the pointer stops moving, so an unanswerable question here is a
    /// question asked forever. The capability is read after `prepare` because
    /// `prepare` is what starts the server and so what produces the capability.
    ///
    /// **Every uncertainty is `nil`, including a server that answered.** Content
    /// that normalizes to nothing is not a smaller answer but no answer (D25):
    /// there is no empty popover, and the pointer resting on a keyword the server
    /// has nothing to say about must leave the screen exactly as it was.
    public func hover(for request: HoverRequest) async -> HoverAnswer? {
        // D2's guard, in the same words the definition path states it in: an empty
        // buffer is a legitimate document, but only at offset 0.
        guard !(request.text.isEmpty && request.offset != 0) else { return nil }
        guard let fileURL = request.fileURL,
              let language = SyntaxLanguage(forFileName: fileURL.lastPathComponent),
              let prepared = await workspace.prepare(
                  url: fileURL,
                  language: language,
                  text: request.text
              ),
              await prepared.session.capabilities?.supportsHover == true
        else { return nil }

        let source = request.text as NSString
        let position = LSPPositionMap.position(forOffset: request.offset, in: source)
        guard let response = try? await prepared.session.hover(
            LSPTextDocumentPositionParams(uri: prepared.uri, position: position)
        ) else { return nil }
        // The same staleness gate, for the same reason and one more: a popover is
        // drawn *beside a range in the buffer*, so an answer about a document the
        // server was talked out of underneath this one would be anchored to text
        // that has moved.
        guard await workspace.stillHolds(prepared) else { return nil }
        // Interpreting the markup is the one step here that is *work* rather than
        // waiting, and its cost is the server's to choose: the three caps bound it,
        // but a line of two thousand `[` costs a scan per character and the budget
        // above may already have expired. Nothing downstream is waiting for this
        // answer once the caller's task is cancelled, so stop before paying for it
        // instead of burning a cooperative-pool thread on a popover nobody will see.
        guard !Task.isCancelled, let content = HoverContent(response) else { return nil }

        return HoverAnswer(content: content, range: anchorRange(for: response, in: source, at: request.offset))
    }

    /// The buffer range a hover answer is about.
    ///
    /// The server's `range` when it sent one, mapped back to buffer coordinates;
    /// otherwise the identifier under the offset, which is the same span the
    /// editor resolved before it decided to ask and so keeps the popover anchored
    /// to the word the user is pointing at. An empty range at the offset is the
    /// last resort — a pointer is never "inside" it, so the popover is re-asked
    /// rather than kept, which is the harmless direction to be wrong in.
    ///
    /// **The server's range is accepted only when it covers the offset the
    /// question was about**, which is the same untrusted-numbers stance
    /// `LSPPositionMap` takes on the way in. It is not a formality: this range is
    /// both where the popover is drawn *and* the editor's re-ask suppressor
    /// (`HoverController.anchorRange`). A range that does not contain the hovered
    /// offset — a degenerate `{0, 0}` being the realistic shape — would anchor the
    /// popover at the top of the file *and* fail the "still about the word under
    /// the pointer" test on every subsequent mouse-moved event, turning pointer
    /// jitter over one identifier into a dismiss-and-re-ask loop on the one
    /// request path that runs whenever the pointer stops moving. An empty range
    /// fails this test too, and falls back to the identifier, which is strictly
    /// the better anchor.
    private func anchorRange(
        for response: LSPHoverResponse,
        in source: NSString,
        at offset: Int
    ) -> NSRange {
        if let range = response.range {
            let mapped = LSPPositionMap.range(for: range, in: source)
            if NSLocationInRange(offset, mapped) { return mapped }
        }
        if let identifier = IdentifierScanner.identifier(in: source, at: offset) {
            return identifier.range
        }
        return NSRange(location: min(max(offset, 0), source.length), length: 0)
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
        // Claimed before the first hop, so the table below is ordered by when the
        // question was *asked* rather than by when it happened to be answered.
        let listToken = claimListToken()
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
        // The same staleness gate the definition path applies, and for the sharper
        // consequence: a completion list is not merely displayed, its items carry
        // *edits* in buffer coordinates, and edits derived from a document the
        // server was talked out of — or from a project the user has left — would be
        // applied to the file.
        guard await workspace.stillHolds(prepared) else { return [] }

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
            serverResolves: resolves,
            listToken: listToken
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
        serverResolves: Bool,
        listToken: Int
    ) -> [CompletionItem] {
        // **Matching is the client's job, and a server is not required to have
        // done it.** sourcekit-lsp, tsserver and pyright answer a prefix with the
        // items that answer *that* prefix, which is why this could go unasked for
        // four phases. `yaml-language-server` does not: it answers with the
        // caret's entire schema property set regardless of what is typed — 93
        // items inside a compose service, the same 93 for an empty prefix — and
        // leaves the choosing to whoever asked. Ordered by `label` (it sends no
        // `sortText`) and cut at the cap, that popup is an alphabetical slice of
        // the schema: typing `ima` offers `annotations … hostname` and `image`,
        // the one key that answers it, is below the cut and never seen.
        //
        // So the one matcher every other candidate source goes through is asked
        // here too — and it decides *one* thing: which half of the list the cap
        // may reach first. It is deliberately neither a filter nor a ranking key.
        // Not a filter, because a server's own matching may legitimately be
        // looser than this one's boundary rule and dropping what it chose to send
        // would be this client overruling it: the recorded sourcekit-lsp
        // transcript answers `Gree` with `VM_MEMORY_MALLOC_LARGE_REUSED`, seven
        // of its ten items match nothing here, and they still belong in a list
        // that has room for them. Not a ranking key, because within each half D6
        // stands untouched — `sortText` still decides, and the server's own array
        // order still breaks a tie. The key is `filterText ?? label`, the spec's
        // own filtering key, never the inserted text: a YAML object property
        // inserts `services:\n  `, and asking whether *that* answers `ser` asks
        // something else. An empty prefix puts every item in the same half, which is the
        // bare-dot member case and the deliberate "show me everything".
        let matched = items.map { item in
            typed.isEmpty || FuzzyMatch.matches(item.filterText ?? item.label, query: typed)
        }
        // `sorted(by:)` is not documented as stable, and the server's array order
        // is meaningful on a tie (it is the order it decided to send them in), so
        // the index is carried as the last key rather than trusted.
        let ordered = items.enumerated().sorted { lhs, rhs in
            if matched[lhs.offset] != matched[rhs.offset] { return matched[lhs.offset] }
            return lhs.element.rankingKey == rhs.element.rankingKey
                ? lhs.offset < rhs.offset
                : lhs.element.rankingKey < rhs.element.rankingKey
        }

        var seen = Set<String>()
        var results: [CompletionItem] = []
        var deferred: [Int: PendingResolve] = [:]
        var handle = claimResolveHandles(count: items.count)
        // One table for the whole list rather than one per mapped range: see the
        // `lineStarts` overload of `LSPPositionMap.range(for:in:)`.
        let lineStarts = LSPPositionMap.lineStarts(in: text)

        for entry in ordered {
            let item = entry.element
            // D5 advertises `snippetSupport: false`, but that is a request, not an
            // enforcement — and this is the one path in the layer whose result is
            // *written to the file*. So the flag is not trusted on its own in
            // either direction: what is dropped is an item that claims snippet
            // format *and* whose text could expand, because that is the one that
            // would put `${1:…}` into the buffer verbatim. This file's first rule,
            // unchanged: no answer is better than a guessed one.
            //
            // The other half is not pedantry. `yaml-language-server` marks
            // **every** property completion `Snippet` and never looks at
            // `snippetSupport` — the string does not occur in its shipped source —
            // so a flag-only test discards `services:\n  ` along with the rest and
            // the server that was downloaded to know a compose schema contributes
            // no completion at all. A placeholder-free snippet *is* its own literal
            // text; inserting it is not a guess. Absent means plain text, per the
            // spec.
            guard item.insertTextFormat ?? 1 == 1 || !item.carriesSnippetSyntax else { continue }
            let primary = primaryRange(
                for: item,
                typedWord: typedWord,
                in: text,
                lineStarts: lineStarts
            )
            let inserted = Self.insertedText(
                of: item,
                forInsertionAt: primary.location,
                in: text,
                lineStarts: lineStarts
            )
            // Completing `foo` to `foo` inserts nothing and hides a real
            // candidate behind it — the same rule the tree-sitter path applies,
            // stated here too because the two lists are never merged.
            guard !inserted.isEmpty, inserted != typed else { continue }

            let itemEdits = edits(
                insertedText: inserted,
                primaryRange: primary,
                additionalTextEdits: item.additionalTextEdits,
                typedWord: typedWord,
                in: text,
                lineStarts: lineStarts
            )
            // What the row reads, from the item's own primary edit against the
            // buffer the request carried: tsserver answers a member access with a
            // `textEdit` over the typed dot, so `inserted` is `".greet"` and the
            // row must read `greet`. `nil` — the common case, including every
            // edit-less item — means the row *is* what is inserted.
            let display = itemEdits
                .first { $0.role == .primary }?
                .displayText(forTypedWordStartingAt: typedWord.location, in: text)
            // The "completes to what is already typed" rule again, this time
            // against the string the user will *see*, because a head the row
            // drops is exactly the difference between the two: a fully typed
            // `greeter.greet` makes tsserver's `".greet"` pass the test above and
            // read `greet` — the typed word itself. Such a row is not merely
            // useless. `CompletionController` keys its snapshot by the displayed
            // string, and AppKit routes Esc back through that same table with the
            // typed word, so a row spelled like it turns a cancel into a commit —
            // including the item's `import` line. Dropping it here keeps the
            // controller's invariant ("no row is the typed word") true by
            // construction, on the one side that can see both spellings. `nil`
            // means the row is the inserted text, which the guard above already
            // answered for.
            guard display != typed else { continue }
            // Claimed here rather than beside the guard above, i.e. only by an
            // item that is actually offered: a dropped row must not spend the
            // key, or a later item inserting the same text from a *different*
            // range — a different row, with a display of its own — would be
            // discarded as its duplicate and never reach the popup.
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
                    edits: itemEdits,
                    resolveHandle: resolveHandle,
                    // Computed above, where it is also a drop rule. Nothing else
                    // reads it: the dedup key, the cap and the edits are the
                    // inserted text's, so what reaches the buffer is untouched.
                    displayText: display
                )
            )
            if results.count == completionLimit { break }
        }

        // The items are returned either way — a superseded list still answers the
        // caller that asked for it, and that caller discards it on its own
        // generation token. Only the *shared* table is refused to an older list.
        replacePendingResolves(with: deferred, listToken: listToken)
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
    ///
    /// `additionalTextEdits` is passed in rather than read off `item`, because the
    /// resolve path takes the two halves from two different places — see
    /// `resolveEdits(for:)`.
    ///
    /// `lineStarts` is `text`'s table, built by the caller: `publish` maps every
    /// item in a list against the same buffer, and rebuilding it per range is the
    /// one avoidable cost on a path that runs per keystroke.
    ///
    /// `insertedText` and `primaryRange` are passed in rather than read off the
    /// item, because both callers must have decided them *before* asking for the
    /// edits: the range is what the indentation rule below measures against, and
    /// the text it produces is the text the popup publishes, the dedup key and
    /// the primary edit alike — the three must be the same string or the row and
    /// the buffer disagree.
    private func edits(
        insertedText: String,
        primaryRange: NSRange,
        additionalTextEdits: [LSPTextEdit]?,
        typedWord: NSRange,
        in text: NSString,
        lineStarts: [Int]
    ) -> [CompletionEdit] {
        let additional = (additionalTextEdits ?? []).map {
            CompletionEdit(
                range: LSPPositionMap.range(for: $0.range, in: text, lineStarts: lineStarts),
                newText: $0.newText,
                role: .additional
            )
        }
        guard !additional.isEmpty || primaryRange != typedWord else { return [] }
        return [
            CompletionEdit(range: primaryRange, newText: insertedText, role: .primary)
        ] + additional
    }

    /// The range the item's own text replaces: the server's if it named one,
    /// otherwise the word the user typed.
    private func primaryRange(
        for item: LSPCompletionItem,
        typedWord: NSRange,
        in text: NSString,
        lineStarts: [Int]
    ) -> NSRange {
        item.textEdit
            .map { LSPPositionMap.range(for: $0.range, in: text, lineStarts: lineStarts) }
            ?? typedWord
    }

    /// What the item puts in the buffer, indentation included — the one place
    /// either call site asks for it.
    ///
    /// `insertTextMode: 1` is `asIs`, a server stating that its continuation lines
    /// are already spelled against the buffer; adjusting those would indent them a
    /// second time. Everything else — including the common absent case, which is
    /// what every pinned server sends — goes through the rule below, because this
    /// client's whole handling of multi-line text *is* that rule and a server that
    /// says nothing gets the behaviour the YAML one needs.
    static func insertedText(
        of item: LSPCompletionItem,
        forInsertionAt location: Int,
        in text: NSString,
        lineStarts: [Int]
    ) -> String {
        guard item.insertTextMode != 1 else { return item.insertedText }
        return indentingContinuationLines(
            of: item.insertedText,
            forInsertionAt: location,
            in: text,
            lineStarts: lineStarts
        )
    }

    /// LSP's `insertTextMode.adjustIndentation`, applied to inserted text that
    /// spans more than one line.
    ///
    /// A server that answers with a multi-line insertion spells the lines after
    /// the first **relative to the item**, not to the buffer, and expects the
    /// client to add the current line's indentation back. `yaml-language-server`
    /// is the case in hand and it is not a corner one: an object-valued schema
    /// property inserts `deploy:\n  ` — the same eleven characters at every
    /// nesting depth, verified against the pinned server — so writing it verbatim
    /// four columns in leaves the caret at column 2, under the *grandparent*.
    /// What the user then types is a sibling of the wrong key, in a document that
    /// still parses. This is the one path in the layer whose result is written to
    /// the file, so an insertion that is silently wrong is worse than the popup
    /// the branch added.
    ///
    /// The rule is the spec's own words — "the editor adjusts leading whitespace
    /// of new lines so that they match the indentation up to the cursor of the
    /// line for which the item is accepted" — and it is not a guess about the
    /// text: the first line is untouched, every following one keeps whatever
    /// relative indentation the server gave it, and only the current line's own
    /// leading whitespace is prefixed. A line the server left empty stays empty,
    /// because indenting it would add trailing whitespace nobody asked for.
    ///
    /// Single-line text — every item every other server sends, and every scalar
    /// YAML property — returns identical, which is why the newline test comes
    /// first: this runs per item per keystroke.
    ///
    /// Splitting on `\n` alone is deliberate and complete. Inserted text is a
    /// string a server composed, and the separators it can contain are LSP's; a
    /// `\r\n` in it splits into `…\r` and the next line, and prefixing after the
    /// `\n` puts the indentation exactly where it belongs either way. The one
    /// thing that split changes is what "empty" looks like: a blank CRLF line
    /// arrives as `"\r"`, which is why the emptiness test is `isBlank(_:)` rather
    /// than `isEmpty`.
    ///
    /// The test that gets there is over **scalars**, not `Character`s, and that is
    /// the whole reason it is spelled this way: `\r\n` is a single grapheme, so
    /// `inserted.contains("\n")` — a `Character` comparison — is `false` for text
    /// whose line breaks are CRLF, while the splitter below bridges to `NSString`
    /// and splits it happily. A grapheme test would therefore hand back exactly the
    /// unindented multi-line insertion this function exists to prevent, on the one
    /// path in the layer whose result is written to the file. The guard and the
    /// split must agree on what a newline is.
    static func indentingContinuationLines(
        of inserted: String,
        forInsertionAt location: Int,
        in text: NSString,
        lineStarts: [Int]
    ) -> String {
        guard inserted.unicodeScalars.contains("\n") else { return inserted }
        let position = LSPPositionMap.position(
            forOffset: location,
            lineStarts: lineStarts,
            length: text.length
        )
        let lineStart = lineStarts[position.line]
        // "Up to the cursor": whitespace past the insertion point is not this
        // line's indentation — a caret inside the leading run indents to where it
        // stands, not to where the run happens to end.
        var end = lineStart
        let limit = min(lineStart + position.character, text.length)
        while end < limit {
            let unit = text.character(at: end)
            guard unit == 0x0020 || unit == 0x0009 else { break }
            end += 1
        }
        guard end > lineStart else { return inserted }
        let indent = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
        return inserted
            .components(separatedBy: "\n")
            .enumerated()
            .map { $0.offset == 0 || isBlank($0.element) ? $0.element : indent + $0.element }
            .joined(separator: "\n")
    }

    /// "The server left this line empty", asked of a component of the split above.
    ///
    /// Splitting CRLF text on `\n` leaves each line's own terminating `\r` at the
    /// end of the *previous* component, so a line the server left empty arrives
    /// here as `"\r"` rather than `""`. A plain `isEmpty` test therefore holds only
    /// for LF text and would prefix the indentation to a blank CRLF line — writing
    /// trailing whitespace nobody asked for into the file, on the one path in the
    /// layer whose result is written there at all.
    private static func isBlank(_ line: String) -> Bool {
        line.isEmpty || line == "\r"
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
        // The **primary** edit comes from the item the popup published and the user
        // committed, never from the resolved one. A resolve exists to fill in what
        // the server kept back — `detail`, `documentation`, `additionalTextEdits`
        // (the only property this client asks for) — and the spec does not let it
        // change what the item inserts; but a server that answers with a leaner item
        // than it was sent, dropping `textEdit`/`insertText`, would have
        // `insertedText` fall through to `label` here, and this is the one path in
        // the layer whose result is *written to the file* rather than dropped. So
        // the resolved item contributes exactly the half it is allowed to.
        let text = pending.text as NSString
        let lineStarts = LSPPositionMap.lineStarts(in: text)
        let primary = primaryRange(
            for: pending.item,
            typedWord: pending.typedWord,
            in: text,
            lineStarts: lineStarts
        )
        return edits(
            insertedText: Self.insertedText(
                of: pending.item,
                forInsertionAt: primary.location,
                in: text,
                lineStarts: lineStarts
            ),
            primaryRange: primary,
            additionalTextEdits: resolved.additionalTextEdits ?? pending.item.additionalTextEdits,
            typedWord: pending.typedWord,
            in: text,
            lineStarts: lineStarts
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

    /// Hand the table to `listToken`'s list, unless a *newer* request has already
    /// published over it — see `publishedListToken`.
    private func replacePendingResolves(with deferred: [Int: PendingResolve], listToken: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard listToken > publishedListToken else { return }
        publishedListToken = listToken
        pendingResolves = deferred
    }

    /// The next request's ordering token. Monotonic and never reused, like the
    /// handles.
    private func claimListToken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextListToken += 1
        return nextListToken
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

/// The router's one extra question (task 7).
///
/// In this file because the answer is the workspace's, and the workspace is
/// private to the provider — deliberately, so nothing above the seam can reach
/// past it to start, stop or interrogate a server.
extension LSPIntelligenceProvider: LSPIntelligenceSource {
    /// Whether a server for `language` is running or startable for the open
    /// folder — `LSPWorkspace.canServe`, which starts nothing.
    public func canServe(_ language: SyntaxLanguage) async -> Bool {
        await workspace.canServe(language)
    }

    /// Whether a rename is worth offering for `language` — the question the
    /// command asks *before* it puts a dialog on screen (decision 4).
    ///
    /// `canServe`, and deliberately no more. The stronger answer — does this
    /// server advertise `renameProvider` — is only knowable from a server that has
    /// finished its handshake, and starting one to decide whether to show a sheet
    /// is precisely what a free policy check must not do: on a cold project that is
    /// twenty seconds of a menu item deciding whether it is a menu item. So the
    /// capability is read where every other capability is, after `prepare` and
    /// inside `renameEdits(for:)`, and a server that turns out not to rename beeps
    /// after the request instead of before the dialog.
    ///
    /// Named separately from `canServe` rather than spelled at the call site
    /// because the two are the same answer today and need not stay so: this is the
    /// question the app asks, and the day it grows a second condition, the call
    /// site should not have to learn about it.
    public func canRename(_ language: SyntaxLanguage) async -> Bool {
        await canServe(language)
    }
}

/// The texts the rows of one answer are measured against, plus each one's line
/// starts.
///
/// The definition path caches only the text, because a jump answers with one
/// or two locations. A usages answer routinely holds hundreds in a single
/// file, and every row needs both a mapped range and a display line — so
/// recomputing `LineStartIndex.offsets(in:)` per row would scan the file once
/// per usage in it, which on the identifier that motivates the 2 000 cap is
/// the difference between a list and a hang.
///
/// The requesting file is seeded with the *buffer*, for the index's reason:
/// what the user is reading is the edited text, and a row in the file being
/// edited must point where the caret would go rather than where the last save
/// put it.
///
/// At file scope rather than nested inside the provider: it needs a nested
/// `Entry` of its own, and that is one level deeper than this repository's style
/// allows a type to be nested.
private struct FileTextCache {
    struct Entry {
        let text: NSString
        let lineStarts: [Int]

        init(_ text: NSString) {
            self.text = text
            lineStarts = LineStartIndex.offsets(in: text)
        }
    }

    private var entries: [String: Entry]

    init(requestURL: URL, requestText: NSString) {
        entries = [CanonicalPath.canonical(requestURL).path: Entry(requestText)]
    }

    /// Keyed canonically rather than by `path`, so the same file named two
    /// ways — which is exactly what a server that resolved `/private/tmp/…`
    /// hands back for a buffer opened as `/tmp/…` — is read and scanned once.
    mutating func text(
        for file: URL,
        loadText: LSPIntelligenceProvider.TextLoader
    ) -> Entry? {
        let key = CanonicalPath.canonical(file).path
        if let cached = entries[key] { return cached }
        guard let loaded = loadText(file) else { return nil }
        let entry = Entry(loaded as NSString)
        entries[key] = entry
        return entry
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
