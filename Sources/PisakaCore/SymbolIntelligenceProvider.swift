import Foundation

/// The index-backed `CodeIntelligenceProviding` implementation — and the home of
/// **every ranking rule** in the feature.
///
/// `SymbolIndex` deliberately ranks nothing: its lookups return candidates in a
/// stable storage order. All relevance lives here, as `static` pure functions
/// over an index value, so each tie-break can be pinned by a test that builds
/// three symbols instead of a project. The instance methods are a thin async
/// shell over those functions, which is the whole protocol conformance.
///
/// The index is read through a closure rather than stored: `SymbolIndexModel`
/// publishes a fresh snapshot after every chunk, and a provider holding a stale
/// copy would answer from the state the folder was opened in.
///
/// **The read itself is `@MainActor`, the ranking is not.** The two methods below
/// are `nonisolated async`, so (SE-0338) their bodies run on the cooperative pool
/// rather than on the caller's actor — while the closures reach into a
/// `@MainActor` model that republishes `index` after every chunk of a walk.
/// Taking the snapshot inside a `MainActor.run` is what keeps a completion
/// request typed during an index build from reading the model's dictionaries
/// while `apply(_:)` is mutating them. Only the read hops: `SymbolIndex` is a
/// value type, so the ranking pass that follows walks a private copy off-main and
/// nothing can change under it.
public final class SymbolIntelligenceProvider: CodeIntelligenceProviding {

    /// How many completion items a caller is offered. AppKit's popup and the iOS
    /// accessory strip are both scroll-limited surfaces; beyond a couple of
    /// dozen entries the list stops being a choice and becomes a wall, and the
    /// user's next keystroke narrows it anyway.
    public static let defaultCompletionLimit = 30

    /// How many declarations a jump is allowed to disambiguate between.
    ///
    /// Both surfaces build one UI element per candidate — an `NSMenuItem` in
    /// `DefinitionPicker`, a `confirmationDialog` button on iOS — and neither
    /// bounds the list itself. The index is not only fed by languages with tidy
    /// declarations: `symbols.scm` also captures Markdown headings, top-level
    /// JSON/YAML keys and CSS selectors, so a docs-heavy or multi-package project
    /// can hold hundreds of declarations of `name`, `id` or `Overview`. Past a
    /// screenful the menu has stopped being a disambiguation anyway, and on iPhone
    /// a several-hundred-action sheet is a hang. Applied *after* ranking, so what
    /// survives is the best of them and not an arbitrary slice.
    public static let defaultDefinitionLimit = 50

    /// How many distinct words are harvested from the buffer per request. High
    /// enough that no hand-written file is truncated, low enough that a minified
    /// bundle cannot turn a debounce tick into a large allocation.
    public static let defaultBufferWordLimit = 5_000

    /// Both reads are `@Sendable @MainActor`: they are called from a
    /// `MainActor.run` inside a `nonisolated async` method, and the model they
    /// read is a `@MainActor` class (hence itself `Sendable`), so the annotation
    /// costs nothing and is what makes the hop expressible.
    private let index: @Sendable @MainActor () -> SymbolIndex
    private let projectRoot: @Sendable @MainActor () -> URL?
    private let completionLimit: Int
    private let bufferWordLimit: Int

    /// - Parameters:
    ///   - index: the current published snapshot; called once per request, on the
    ///     main actor.
    ///   - projectRoot: the opened folder, for the paths the picker shows.
    public init(
        index: @escaping @Sendable @MainActor () -> SymbolIndex,
        projectRoot: @escaping @Sendable @MainActor () -> URL?,
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) {
        self.index = index
        self.projectRoot = projectRoot
        self.completionLimit = completionLimit
        self.bufferWordLimit = bufferWordLimit
    }

    /// Fixed-snapshot convenience, for tests and for a caller that has an index
    /// value rather than a model.
    public convenience init(
        index: SymbolIndex,
        projectRoot: URL? = nil,
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) {
        self.init(
            index: { index },
            projectRoot: { projectRoot },
            completionLimit: completionLimit,
            bufferWordLimit: bufferWordLimit
        )
    }

    // MARK: - CodeIntelligenceProviding

    public func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] {
        let state = await snapshot()
        return Self.definitions(for: request, in: state.index, projectRoot: state.projectRoot)
    }

    public func completions(for request: CompletionRequest) async -> [CompletionItem] {
        let state = await snapshot()
        return Self.completions(
            for: request,
            in: state.index,
            limit: completionLimit,
            bufferWordLimit: bufferWordLimit
        )
    }

    /// The pure scanner's blocks, and nothing else.
    ///
    /// **The one method here that reads no index**, which is worth a line because
    /// "the index-backed provider" is this type's name in the seam rather than a
    /// description of every answer it gives. There is nothing in a declaration
    /// index that says where a block *ends* — a `symbols.scm` capture names a
    /// declaration's name node — so the fallback answer to "what folds here" comes
    /// from brackets and indentation, computed over the text the request already
    /// carries. No main-actor hop either, for the same reason: there is no
    /// snapshot to take.
    ///
    /// The widths come off the request rather than out of an inference here, so
    /// the block is measured with the same unit Enter appends
    /// (`FoldRegionRequest.indentWidths`).
    public func foldRegions(for request: FoldRegionRequest) async -> [FoldRegion] {
        FoldRegionScanner.scan(text: request.text as NSString, widths: request.indentWidths)
    }

    /// Both reads in one main-actor hop — see the type's note on why the read is
    /// isolated and the ranking is not. One hop rather than two so a request
    /// cannot straddle a chunk publication and pair one walk's index with the
    /// next one's root.
    private func snapshot() async -> Snapshot {
        let readIndex = index
        let readRoot = projectRoot
        return await MainActor.run { Snapshot(index: readIndex(), projectRoot: readRoot()) }
    }

    private struct Snapshot: Sendable {
        let index: SymbolIndex
        let projectRoot: URL?
    }

    // MARK: - Definitions (pure)

    /// Declarations of `request.identifier`, ordered: **current file first**,
    /// then by relative path, line, and offset.
    ///
    /// The name match is *exact and case-sensitive* — `Worker` and `worker` are
    /// two declarations in every language the editor indexes, and offering both
    /// for a jump would make the picker appear where a direct navigation was
    /// unambiguous. Current-file-first because a name declared in the file being
    /// read is nearly always the one meant; the remaining order is path-then-line
    /// so a rebuilt index cannot reshuffle the menu under the user's cursor.
    ///
    /// **Only the index is consulted** — not the buffer's words, and not
    /// `LanguageKeywords`, which the completion path below does read. A keyword
    /// has no declaration site to jump to, so a `guard` under the caret must
    /// beep rather than open a picker; the two features sharing this type is
    /// exactly why that is pinned by a test instead of left to convention.
    ///
    /// **Nothing here is filtered by the completion-candidate rule.** A heading,
    /// a multi-word key, a selector spelled `.btn-primary` — everything the index
    /// stores stays a jump target, precisely because
    /// `isCompletionCandidate(_:)` refuses it for *insertion*. Navigation and
    /// typing want different things out of the same index, and this method is the
    /// side that wants all of it.
    ///
    /// An empty identifier yields nothing: it is what
    /// `IdentifierScanner.identifier(in:at:)` reports for a click on whitespace,
    /// and "no name" must beep rather than open an empty menu. More than `limit`
    /// declarations are truncated after ranking — see `defaultDefinitionLimit`.
    public static func definitions(
        for request: DefinitionRequest,
        in index: SymbolIndex,
        projectRoot: URL?,
        limit: Int = SymbolIntelligenceProvider.defaultDefinitionLimit
    ) -> [DefinitionCandidate] {
        guard !request.identifier.isEmpty, limit > 0 else { return [] }

        var keys = FileKeyCache()
        let currentKey = request.fileURL.map { keys.key(for: $0) }

        let candidates = index.symbols(named: request.identifier).map { symbol in
            (
                candidate: DefinitionCandidate(
                    symbol: symbol,
                    relativePath: relativePath(of: symbol.fileURL, under: projectRoot)
                ),
                isCurrentFile: currentKey != nil && keys.key(for: symbol.fileURL) == currentKey
            )
        }

        return candidates.sorted { lhs, rhs in
            if lhs.isCurrentFile != rhs.isCurrentFile { return lhs.isCurrentFile }
            if lhs.candidate.relativePath != rhs.candidate.relativePath {
                return lhs.candidate.relativePath < rhs.candidate.relativePath
            }
            if lhs.candidate.line != rhs.candidate.line {
                return lhs.candidate.line < rhs.candidate.line
            }
            if lhs.candidate.range.location != rhs.candidate.range.location {
                return lhs.candidate.range.location < rhs.candidate.range.location
            }
            return lhs.candidate.name < rhs.candidate.name
        }.prefix(limit).map(\.candidate)
    }

    // MARK: - The completion-candidate rule (pure)

    /// The kinds of symbols that serve as ⌃⌘J navigation anchors but must never
    /// be offered as completions.
    ///
    /// The only member is `.heading`: a Markdown heading or `.editorconfig` section
    /// header is a structural boundary that a person wants to jump to, but it is a
    /// phrase or glob, not an identifier. Even if it happens to be one word (like
    /// `# Server` or `[Makefile]`), offering it for insertion crosses contexts —
    /// a Swift file that imports Foundation must not have its `let server =`
    /// answered `ser` with a heading lifted out of an unrelated `.md` or
    /// `.editorconfig` file.
    ///
    /// Every other kind stays a candidate, including the ones the non-code
    /// languages contribute (`.key`, `.anchor`, `.selector`, `.stage`): a
    /// top-level YAML key *is* the word the author is typing.
    static let kindsExcludedFromCompletion: Set<SymbolKind> = [.heading]

    /// Whether `symbol` may be **offered for insertion**.
    ///
    /// Two conditions, and the second is the general one: the kind is not one of
    /// the navigation-only kinds above, and the name is a single identifier-shaped
    /// token by `IdentifierScanner`'s own boundary rule. The shape question is
    /// asked *there*, not restated here, so the rule that decides what the caret
    /// is completing is literally the rule that decides what may be inserted — a
    /// name the scanner could never have produced (`Getting started`, `run(_:)`,
    /// `btn-primary`) would be inserted into the middle of a line as text no
    /// language accepts, and could never be re-found by the prefix that offered
    /// it.
    ///
    /// The hyphenated case is the one with a real cost, and it is deliberate: a
    /// CSS class is indexed under the name the query captures (`btn-primary`, no
    /// leading `.`), so hyphenated class names stop being offered. They cannot be
    /// offered *correctly* — the caret in `.btn-pri` is completing `pri`, the
    /// scanner having ended the token at the hyphen, so inserting `btn-primary`
    /// over it writes `.btn-btn-primary`. Refusing is the only answer that is
    /// right in every position rather than only the first one.
    ///
    /// **The refusal happens after the index's own pre-cap**, not inside it: an
    /// excluded entry occupies a slot in `symbols(matching:limit:)` and is then
    /// discarded, so a prefix matched by more excluded names than the cap holds
    /// can return a shorter list than it would have. `candidateLimit(for:)` is
    /// eight times the popup's own limit, so this needs hundreds of matching
    /// headings before it is reachable — and pushing the predicate into
    /// `SymbolIndex` would make the store hold an opinion about completion, which
    /// is the one thing it does not do.
    ///
    /// **This filters the completion source and nothing else.** `definitions(…)`,
    /// `SymbolIndex` and the walk that feeds it are deliberately untouched: the
    /// index keeps storing every entry, ⌃⌘J keeps listing headings and multi-word
    /// keys, and go-to-definition keeps landing on them. Navigation wants the
    /// entries typing refuses — that asymmetry *is* the rule.
    ///
    /// The other two completion sources are not re-filtered because they cannot
    /// fail it by construction: `LanguageKeywords` are hand-written words, and
    /// harvested buffer words come out of `IdentifierScanner.words(in:limit:)`,
    /// which yields only what this predicate would accept.
    static func isCompletionCandidate(_ symbol: Symbol) -> Bool {
        !kindsExcludedFromCompletion.contains(symbol.kind)
            && IdentifierScanner.isIdentifier(symbol.name)
    }

    // MARK: - Completions (pure)

    /// Completion candidates for `request.prefix`: the index's matches merged
    /// with the language's keywords and the words the buffer itself contains,
    /// ranked, de-duplicated by name and capped at `limit`.
    ///
    /// **Syntax-context gating.** When `request.offset` and `request.language`
    /// are both non-`nil`, the provider asks `SyntaxContextScanner` once whether
    /// the caret sits inside a string literal or comment that suppresses
    /// completion for that language; inside a gated string or any comment the
    /// answer is `[]` for symbols, keywords and buffer words alike, and no
    /// ranking is performed. Inside an interpolation hole (`${…}`, `\(…)` /
    /// `\#(…)`, Python `{…}`) the context is `.code` and completion proceeds
    /// exactly as in open code. The gate is applied before the member branch so
    /// member completion is covered by the same line; `nil` offset or `nil`
    /// language means no position or no vocabulary to consult and the request is
    /// ungated. `definitions(for:in:projectRoot:)`, the index and the walk that
    /// feeds it are untouched — the same navigation-versus-typing asymmetry the
    /// candidate rule already records: ⌃⌘J still lists what typing refuses.
    ///
    /// **The ranking, in order** (each tie-break is pinned by its own test):
    ///
    /// 1. **match quality** — `FuzzyMatch.Quality`, which is itself ordered
    ///    case-sensitive prefix, then case-insensitive prefix, then fuzzy, and
    ///    within fuzzy prefers a match that lands on word boundaries, then a
    ///    tighter span, then an earlier start. Typing `arr` still surfaces
    ///    `ArrayBuffer`, but never above `arrayCount`, because the user's
    ///    capitalization is a signal; and a literal prefix always beats a
    ///    scattered subsequence, however short the scattered candidate is.
    ///    For a literal prefix this key collapses to exactly the two-valued
    ///    case rank this method ranked on before fuzzy matching existed, so
    ///    every order that held then holds now;
    /// 2. the **current file** before the rest of the project — the nearby name
    ///    is the likely one, the same reasoning as go-to-definition;
    /// 3. the **source**: a known symbol, then a language keyword, then a bare
    ///    harvested word. A declaration is a fact, a keyword is a certainty
    ///    about the language but says nothing about *this* project, and a word
    ///    is a guess that only exists so languages without a query still
    ///    complete;
    /// 4. the **shorter** name — the shortest completion of a prefix is the most
    ///    common intent, and it is also the cheapest to correct if wrong;
    /// 5. lexicographic, then kind, purely so the list is deterministic: two
    ///    equally ranked entries must not swap places between two keystrokes.
    ///
    /// A member request (`request.member != nil`) adds **one key above all of
    /// these** — the receiver's own container first — and reorders none of them;
    /// see `memberCompletions(…)`.
    ///
    /// **Keywords count as current-file** (rule 2 puts them level with
    /// harvested words), because a keyword belongs to the language of the file
    /// being typed in and is exactly as local as a word lifted out of it; rule
    /// 3 is then what separates the two. Where rules 2 and 3 genuinely conflict
    /// — a keyword against a symbol declared in *another* file — the
    /// current-file rule wins, precisely as it already does between a harvested
    /// word and a project symbol.
    ///
    /// The typed token itself is dropped (completing `foo` to `foo` inserts
    /// nothing and hides a real candidate behind it), and duplicates collapse to
    /// their best-ranked entry, so a name that is both declared in this file and
    /// present in the buffer appears once, as the symbol — and `guard`, which a
    /// Swift buffer both contains and reserves, appears once as the keyword.
    ///
    /// An empty prefix yields nothing — with nothing typed there is nothing to
    /// complete, and a popup listing the project would be noise. The **one**
    /// exception is a request carrying a `member` context, which is handled by
    /// `memberCompletions(…)` below: a typed dot is itself the commitment, so
    /// there the empty prefix is meaningful and the candidate set is bounded by
    /// the member kinds instead of by the text.
    public static func completions(
        for request: CompletionRequest,
        in index: SymbolIndex,
        limit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        bufferWordLimit: Int = SymbolIntelligenceProvider.defaultBufferWordLimit
    ) -> [CompletionItem] {
        guard limit > 0 else { return [] }
        /// Syntax-context gate — why here and not in the router or the view
        /// layer, why `nil` offset and `nil` language mean ungated, and that it
        /// is asked exactly once per request: the fallback is the only source
        /// that needs suppression (LSP answers are typed and hover has no
        /// fallback), so gating the single static entry point of the
        /// fallback covers every call site including the router's forwarded
        /// request without touching views; `nil` offset means no caret position
        /// was supplied and `nil` language means no vocabulary to consult, hence
        /// ungated; the check is performed exactly once per request at the top
        /// of this method, before the member branch.
        if let offset = request.offset, let language = request.language,
           SyntaxContextScanner.suppressesCompletion(in: request.text as NSString, at: offset, language: language) {
            return []
        }
        if let member = request.member {
            return memberCompletions(
                for: request,
                member: member,
                in: index,
                limit: limit,
                bufferWordLimit: bufferWordLimit
            )
        }
        guard !request.prefix.isEmpty else { return [] }

        var keys = FileKeyCache()
        let currentKey = request.fileURL.map { keys.key(for: $0) }
        let query = request.prefix

        // The index is asked for more than the cap: it orders by storage
        // position, so capping *there* at `limit` would hand the ranking an
        // arbitrary slice and the best candidate could be missing entirely.
        //
        // A generous multiple still is not a guarantee, and the one place that
        // matters is the current file: storage order is *by file key*, so in a
        // project with more matches than the pre-cap, every match living in a
        // path sorting after the cut is invisible here — and whether the file
        // the user is typing in is one of them comes down to how its path
        // happens to sort. Ranking rule 2 (current file first) would then fail
        // exactly where it is most load-bearing. Asking that one file for its own
        // symbols costs a single dictionary hit and puts them back regardless of
        // where the pre-cap fell; the de-duplication below collapses the overlap
        // with whatever the bucket already returned.
        //
        // Fuzzy matching *widens* the set the pre-cap slices, so this mitigation
        // matters more now, not less: `aBu` matches more names than `aBu` as a
        // literal prefix ever did, so the cut falls earlier in file-key order and
        // the current file is more likely to sit past it. The current file's own
        // symbols are re-matched below rather than trusted wholesale — the
        // file-scoped lookup is unfiltered, so it is the matcher, applied to
        // every source alike, that decides what is a candidate.
        //
        // The *other* half of that widening — a literal prefix match in some
        // third file being evicted by unrelated fuzzy matches from files that
        // sort earlier — cannot be repaired here, because by the time this sees
        // the result the evicted candidate is simply absent. It is handled at the
        // cut instead, by `symbols(matching:limit:)` filling the cap from the
        // prefix matches first; see the truncation rule stated there.
        let symbols = index.symbols(matching: query, limit: candidateLimit(for: limit))
            + (request.fileURL.map { index.symbols(inFile: $0) } ?? [])
        var ranked: [Ranked] = symbols.compactMap { symbol in
            guard isCompletionCandidate(symbol) else { return nil }
            guard let quality = FuzzyMatch.quality(of: symbol.name, matching: query) else { return nil }
            return Ranked(
                item: CompletionItem(
                    text: symbol.name,
                    kind: symbol.kind,
                    isFromCurrentFile: currentKey != nil && keys.key(for: symbol.fileURL) == currentKey
                ),
                quality: quality,
                sourceRank: Ranked.symbolSource
            )
        }

        // The keyword source. A `nil` language contributes nothing at all rather
        // than some default language's vocabulary — see `CompletionRequest`.
        // `isFromCurrentFile: true` and `kind: nil` are both deliberate: the
        // keyword belongs to this file's language, and it is not a declaration
        // anything could jump to, which is also why `definitions(for:)` never
        // consults this list.
        for keyword in request.language.map(LanguageKeywords.keywords(for:)) ?? [] {
            guard let quality = FuzzyMatch.quality(of: keyword, matching: query) else { continue }
            ranked.append(
                Ranked(
                    item: CompletionItem(text: keyword, kind: nil, isFromCurrentFile: true),
                    quality: quality,
                    sourceRank: Ranked.keywordSource
                )
            )
        }

        let words = IdentifierScanner.words(in: request.text as NSString, limit: bufferWordLimit)
        for word in words {
            guard let quality = FuzzyMatch.quality(of: word, matching: query) else { continue }
            // Harvested from the buffer being edited, so by definition local.
            ranked.append(
                Ranked(
                    item: CompletionItem(text: word, kind: nil, isFromCurrentFile: true),
                    quality: quality,
                    sourceRank: Ranked.wordSource
                )
            )
        }

        return assemble(ranked, typed: request.prefix, limit: limit)
    }

    // MARK: - Member completions (pure)

    /// Completion candidates for a caret sitting **after a member-access dot**,
    /// which `IdentifierScanner.memberContext(in:at:)` has already recognized.
    ///
    /// Three things make this a branch rather than a filter on the ordinary
    /// path:
    ///
    /// 1. **The prefix may be empty.** A typed `.` is the user committing to a
    ///    member access before typing anything, so "nothing typed, nothing to
    ///    complete" — right everywhere else — would answer the one request that
    ///    is unambiguous about intent with nothing. The candidate set is bounded
    ///    by the member kinds instead (see `SymbolIndex.members(matching:limit:)`).
    /// 2. **The candidates are members only** — a `.method`, `.property` or
    ///    `.constant` that names an enclosing type. A type, a free function or a
    ///    file-scope constant is not reachable through a dot, and offering one
    ///    after a dot is a worse answer than offering nothing. **Keywords are not
    ///    offered at all**, for the same reason: no language lets `guard` follow
    ///    a dot.
    /// 3. **The receiver's own container ranks first**, above match quality and
    ///    therefore above every other key — but only when the receiver *spells a
    ///    type the project declares* (`index.declaresType(named:)`). This is a
    ///    name-based heuristic, not type inference: `worker.` cannot be resolved
    ///    without knowing what `worker` was assigned, while `Worker.` names the
    ///    container outright. A receiver that names a function rather than a type
    ///    promotes nothing, because a function called `worker` says nothing about
    ///    what `worker.` will offer. Below that one key every ordinary tie-break
    ///    still applies, unchanged.
    ///
    /// **The buffer-word fallback needs a non-empty member prefix.** Words are
    /// offered only when the user has typed at least one character after the dot
    /// *and* no member matched it — the case where the project simply has not
    /// indexed the receiver's type and a word from the buffer is better than an
    /// empty popup. With an **empty** prefix there is no fallback at all: an
    /// empty query matches every word in the buffer, and this scanner
    /// deliberately does not know about strings or comments, so a dot inside a
    /// JSON value, a URL in a comment or a decimal-less number would otherwise
    /// open a list of unrelated words exactly where the dot is least likely to be
    /// a member access. Nothing at all is the honest answer there.
    private static func memberCompletions(
        for request: CompletionRequest,
        member: IdentifierScanner.MemberContext,
        in index: SymbolIndex,
        limit: Int,
        bufferWordLimit: Int
    ) -> [CompletionItem] {
        var keys = FileKeyCache()
        let currentKey = request.fileURL.map { keys.key(for: $0) }
        let query = request.prefix

        // The receiver heuristic's one question, asked once — see rule 3 above.
        let promoted = member.receiver.flatMap { index.declaresType(named: $0) ? $0 : nil }

        // The promoted container's members are collected separately and
        // *uncapped*, so the pre-cap below — which slices the project in file-key
        // order — cannot be what drops the very members this request is most
        // about. The overlap between the two lists collapses in `assemble`.
        var candidates = index.members(matching: query, limit: memberCandidateLimit)
        if let promoted { candidates += index.members(inContainer: promoted) }
        // And the current file's own members, for precisely the reason the
        // ordinary path adds `symbols(inFile:)`: the pre-cap above slices the
        // project in file-key order, so without this the file being typed in can
        // contribute nothing at all and ranking rule 2 fails where it matters
        // most. The promoted-container rescue does not cover it — that one fires
        // only when the receiver spells a declared type, while `worker.` (the
        // common case) promotes nothing. Re-matched below like every other
        // source, so the lookup being unfiltered cannot widen what counts as a
        // candidate; `assemble` collapses the overlap.
        candidates += request.fileURL.map { index.members(inFile: $0) } ?? []

        var ranked: [Ranked] = candidates.compactMap { symbol in
            guard isCompletionCandidate(symbol) else { return nil }
            guard let quality = memberQuality(of: symbol.name, matching: query) else { return nil }
            return Ranked(
                item: CompletionItem(
                    text: symbol.name,
                    kind: symbol.kind,
                    isFromCurrentFile: currentKey != nil && keys.key(for: symbol.fileURL) == currentKey
                ),
                quality: quality,
                sourceRank: Ranked.symbolSource,
                containerRank: promoted != nil && symbol.containerName == promoted ? 0 : 1
            )
        }

        if ranked.isEmpty, !query.isEmpty {
            for word in IdentifierScanner.words(in: request.text as NSString, limit: bufferWordLimit) {
                guard let quality = FuzzyMatch.quality(of: word, matching: query) else { continue }
                ranked.append(
                    Ranked(
                        item: CompletionItem(text: word, kind: nil, isFromCurrentFile: true),
                        quality: quality,
                        sourceRank: Ranked.wordSource
                    )
                )
            }
        }

        return assemble(ranked, typed: query, limit: limit)
    }

    /// How well a member answers the member prefix.
    ///
    /// The ordinary matcher, except for the bare typed dot: with an empty query
    /// `FuzzyMatch` reports `nil` (nothing typed cannot be ranked), while here
    /// every member answers *equally* well, so the key is a constant and the
    /// remaining rules — the receiver's container, the current file, the shorter
    /// name — decide the whole order. The constant is the best tier with the
    /// fuzzy sub-keys zeroed, i.e. exactly the key a literal prefix produces, so
    /// members and the (impossible here) prefix case cannot be ordered against
    /// each other by accident.
    private static func memberQuality(of name: String, matching query: String) -> FuzzyMatch.Quality? {
        guard !query.isEmpty else {
            return FuzzyMatch.Quality(
                tier: FuzzyMatch.Quality.caseSensitivePrefixTier,
                offBoundary: 0,
                span: 0,
                start: 0
            )
        }
        return FuzzyMatch.quality(of: name, matching: query)
    }

    // MARK: - Assembly and caps

    /// Sort, drop the typed token, de-duplicate by name and cap — the tail every
    /// completion path shares, so an ordinary request and a member request can
    /// never disagree about which of two identically-named candidates survives.
    ///
    /// The typed token is dropped because completing `run` to `run` inserts
    /// nothing and hides a real candidate behind it; that holds after a dot too,
    /// where the token is the member prefix.
    private static func assemble(_ ranked: [Ranked], typed: String, limit: Int) -> [CompletionItem] {
        var seen = Set<String>()
        var results: [CompletionItem] = []
        for entry in ranked.sorted(by: isOrderedBefore) {
            guard entry.item.text != typed else { continue }
            guard seen.insert(entry.item.text).inserted else { continue }
            results.append(entry.item)
            if results.count == limit { break }
        }
        return results
    }

    /// How many index matches to rank before capping. A generous multiple of the
    /// visible cap, with a floor, so ranking has real choice without walking the
    /// whole project for a one-letter prefix.
    private static func candidateLimit(for limit: Int) -> Int {
        max(limit * 8, 200)
    }

    /// How many members to collect before ranking a member request.
    ///
    /// Deliberately a flat number rather than a multiple of the visible cap, the
    /// way `candidateLimit(for:)` is: that one slices a set the *query* already
    /// narrowed, while a bare typed dot has no query at all, so what bounds this
    /// pass is only the number itself. A few hundred members is far more than the
    /// popup can show and far less than a large project declares, which keeps the
    /// one linear pass over the index (see `SymbolIndex.members(matching:limit:)`)
    /// short enough to run per typed dot behind the editor's debounce. Where the
    /// cut falls is not load-bearing either: the receiver's own members — the ones
    /// ranked first and the reason the request was made — are collected separately
    /// and uncapped.
    private static let memberCandidateLimit = 400

    /// A candidate plus the precomputed ranking facts, so the comparator does no
    /// string work per comparison (`sorted` calls it O(n log n) times).
    ///
    /// `sourceRank` is passed in rather than derived from `item.kind`: two of the
    /// three sources produce a `kind`-less item (a keyword and a harvested word
    /// are both "just a string"), so the kind can no longer tell them apart, and
    /// the source is the caller's knowledge anyway.
    private struct Ranked {
        /// A declaration the index found — a fact about this project.
        static let symbolSource = 0
        /// A reserved word of the file's language — a fact about the language.
        static let keywordSource = 1
        /// A word lifted out of the buffer — a guess.
        static let wordSource = 2

        let item: CompletionItem
        /// 0 for a member of the receiver's own container — **member mode only**,
        /// and the one key that outranks match quality. Constant 0 on every
        /// ordinary request, so the key is inert outside member mode and the
        /// ranking there is bit-for-bit what it was before member completion
        /// existed.
        let containerRank: Int
        /// How well the candidate answers what was typed — the first key.
        let quality: FuzzyMatch.Quality
        /// 0 for the current file.
        let fileRank: Int
        /// One of the three `…Source` constants above.
        let sourceRank: Int
        /// UTF-16 length, the "shorter first" key.
        let length: Int

        init(
            item: CompletionItem,
            quality: FuzzyMatch.Quality,
            sourceRank: Int,
            containerRank: Int = 0
        ) {
            self.item = item
            self.containerRank = containerRank
            self.quality = quality
            self.fileRank = item.isFromCurrentFile ? 0 : 1
            self.sourceRank = sourceRank
            self.length = item.text.utf16.count
        }
    }

    private static func isOrderedBefore(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
        if lhs.containerRank != rhs.containerRank { return lhs.containerRank < rhs.containerRank }
        if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
        if lhs.fileRank != rhs.fileRank { return lhs.fileRank < rhs.fileRank }
        if lhs.sourceRank != rhs.sourceRank { return lhs.sourceRank < rhs.sourceRank }
        if lhs.length != rhs.length { return lhs.length < rhs.length }
        if lhs.item.text != rhs.item.text { return lhs.item.text < rhs.item.text }
        // Same name, same rank, different kind: order by kind so which of the two
        // survives de-duplication is deterministic rather than sort-dependent.
        return (lhs.item.kind?.rawValue ?? "") < (rhs.item.kind?.rawValue ?? "")
    }

    // MARK: - Paths

    /// Memoized canonical file keys.
    ///
    /// `SymbolIndex.fileKey(for:)` resolves symlinks, i.e. it touches the file
    /// system. A completion pass compares hundreds of candidates against the
    /// current file on every debounce tick, and those candidates come from a
    /// handful of files, so memoizing by raw path bounds the resolutions to the
    /// number of *distinct* files instead of the number of symbols.
    private struct FileKeyCache {
        private var keys: [String: String] = [:]

        mutating func key(for url: URL) -> String {
            if let cached = keys[url.path] { return cached }
            let key = SymbolIndex.fileKey(for: url)
            keys[url.path] = key
            return key
        }
    }

    /// `url`'s path below `root` — what the definition picker shows.
    ///
    /// `ProjectFileWalk.relativePath(of:under:)`, the very helper Find in Files
    /// labels its result groups with: the URLs come from that same traversal, so
    /// a lexical strip is exact, and sharing the function is what keeps a
    /// definition row and a search row from spelling one file two ways.
    static func relativePath(of url: URL, under root: URL?) -> String {
        ProjectFileWalk.relativePath(of: url, under: root)
    }
}
