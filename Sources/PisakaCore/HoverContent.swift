import Foundation

/// One run of a hover answer, as whatever draws it sees the world: a block of
/// code in a language somebody named, or a block of prose.
///
/// The distinction is the only one a renderer acts on, and it is why this is not
/// a single string: a type signature drawn in the interface font — with its `<`
/// and `>` read as markup and its indentation collapsed — is not a type
/// signature, and a paragraph of documentation drawn in the code font is a wall.
public struct HoverSegment: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// A code block. `language` is what the server called it — a fence's
        /// info string or a `MarkedString`'s `language` — and is `nil` when it
        /// named none, which means "monospaced, uncoloured" rather than "guess".
        case code(language: String?)
        case prose
    }

    public let kind: Kind
    /// The text to draw, already normalized: no markup, no trailing whitespace,
    /// no blank first or last line, and **no line longer than
    /// `HoverContent.maximumLineLength` characters or
    /// `HoverContent.maximumLineUTF8Length` bytes** — the last of those is what
    /// makes the text safe to walk on the main thread (see `HoverContent`'s cap).
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func code(_ text: String, language: String? = nil) -> HoverSegment {
        HoverSegment(kind: .code(language: language), text: text)
    }

    public static func prose(_ text: String) -> HoverSegment {
        HoverSegment(kind: .prose, text: text)
    }

    public var isCode: Bool {
        if case .code = kind { return true }
        return false
    }

    /// The drawn lines. A segment always has at least one, because a segment
    /// that would have none is never made.
    public var lines: [String] { text.components(separatedBy: "\n") }
}

/// Everything a hover popover draws, and nothing else.
///
/// **This type knows nothing about LSP** — it is what a *renderer* consumes, so
/// the view layer needs no protocol vocabulary to draw an answer, and a second
/// source of hover text (were there ever one) would produce the same value. The
/// *construction* from a decoded `textDocument/hover` payload lives at the
/// bottom of this file all the same: markup is interpreted in exactly one place,
/// and that place is beside the type whose invariants the interpretation exists
/// to establish.
///
/// **There is no empty hover** (D25). Content that normalizes to nothing — an
/// empty string, whitespace, a lone horizontal rule, a server answering `{}` —
/// is `nil`, not a `HoverContent` with no segments, so "show it if there is one"
/// is the only rule a caller needs and an empty popover cannot be drawn by
/// accident.
///
/// **Long content truncates; it never scrolls.** Scrolling would require the
/// pointer to reach the panel, and the panel is unreachable on purpose (it
/// passes every mouse event through to the code beneath it). So the cap is
/// applied here, as pure arithmetic over lines, and the renderer's only job is
/// to draw a marker when `isTruncated` says the answer was cut.
///
/// The cap has **two dimensions, and both are load-bearing**: a line count and a
/// per-line length. A count alone bounds nothing a renderer cares about — twenty
/// lines can be twenty megabytes, and the answer's size is decided by a language
/// server rather than by anything here (`LSPFraming` will carry 64 MB). The
/// renderer measures and lays that string out *synchronously on the main thread*,
/// from an event that fires whenever the pointer stops moving, so an unbounded
/// line is a hang nobody asked for. Bounding it here keeps that a Core rule
/// rather than a defensive `if` in a view.
///
/// **The length dimension is itself two caps**, in characters and in UTF-8 bytes,
/// and the second is not belt-and-braces: a `Character` is an extended grapheme
/// cluster and a cluster has no size limit, so `"a"` followed by a million
/// combining marks is *one* character. A character cap alone would pass that line
/// through whole — the megabyte hang arriving through the guard meant to stop it —
/// which is why the bound is also stated in the unit the layout actually costs.
///
/// **The two dimensions are applied in two different places, and that is the
/// point.** The line *count* is a display rule, so `truncated(toLineCount:)` is
/// the renderer's call. The line *length* is not a display rule at all — it is
/// the hang guard — so it is established by the **checking initializer**, which
/// is to say wherever a `HoverContent` is *built*: on the LSP path that is
/// `LSPIntelligenceProvider.hover`, a `nonisolated async` method, and therefore
/// off the main thread. The one pass that costs the size of the server's answer
/// happens there, once; every later reader — `truncated`, `lineCount`, the panel
/// — walks text whose lines are already bounded, so the renderer's work is
/// `maximumLineCount` × `maximumLineLength` characters whatever the server sent.
/// **The cap must not cost what the cap prevents**, and a cap applied for the
/// first time on the main thread would.
public struct HoverContent: Equatable, Hashable, Sendable {
    /// The segments to draw, in the order the server wrote them. Never empty.
    public let segments: [HoverSegment]
    /// Whether `truncated(toLineCount:)` dropped something. Purely a display
    /// fact — the answer itself is not otherwise different.
    public let isTruncated: Bool

    /// How long the pointer must rest before anything is asked.
    ///
    /// The feature's one timing constant, and it lives here rather than in the
    /// view for the reason every other rule does: a literal in a controller is a
    /// literal nobody can find, and this one is the difference between "hovering
    /// tells you the type" and "moving the mouse across the file fires a request
    /// per identifier".
    public static let dwellDelay: TimeInterval = 0.35

    /// The most lines a popover draws. Past this the content is cut and marked.
    ///
    /// Deliberately modest: the popover is a glance at a type, not a
    /// documentation browser, and everything past a screenful is better read in
    /// the file the definition jump already goes to.
    public static let maximumLineCount = 20

    /// The most characters a single drawn line may carry.
    ///
    /// Generous on purpose — far past anything the 520 pt panel can show, so no
    /// real signature or paragraph ever reaches it — because this is not a
    /// display rule but the bound that keeps `maximumLineCount` meaningful. It is
    /// what makes "at most twenty lines" also mean "at most a bounded amount of
    /// text to lay out", which is the only form of the promise the renderer can
    /// actually use.
    public static let maximumLineLength = 2_000

    /// The most UTF-8 bytes a single drawn line may carry.
    ///
    /// The other half of the same guard, and the half that actually closes it:
    /// `maximumLineLength` counts `Character`s, an extended grapheme cluster has
    /// no size limit, and so a line of one cluster — a letter and a million
    /// combining marks — passes a character cap of any size and still costs
    /// megabytes to break, measure and lay out on the main thread.
    ///
    /// Eight bytes per character: twice UTF-8's maximum for a single scalar, and
    /// past what any script spends on a character somebody reads. A line can
    /// therefore only reach this bound by not being text, and the two together
    /// bound the renderer's work in the unit the renderer pays it in.
    public static let maximumLineUTF8Length = 8 * maximumLineLength

    /// The failable, checking initializer: segments that carry nothing are
    /// dropped, and content left with no segments at all is no content.
    ///
    /// **This is where `HoverSegment.text`'s stated shape is established**, for
    /// every segment that exists rather than only for the ones `HoverMarkup`
    /// built, and it is two rules rather than one:
    ///
    /// - A kept segment loses its blank first and last *lines*.
    ///   `codeBlock`/`proseBlock` already strip them, so this is a no-op on the
    ///   LSP path and the rule for every other caller. **`truncated` depends on
    ///   it**: it keeps a prefix of a segment's lines, so a segment whose first
    ///   line were blank could be cut down to nothing but whitespace — a popover
    ///   drawing an ellipsis and no answer, the one state D25 says cannot exist.
    ///   Stripped line-wise, never off the joined string, for `proseBlock`'s
    ///   reason: trimming the join takes the first line's indentation with it and
    ///   leaves the rest.
    /// - No line survives longer than `maximumLineLength` characters *or*
    ///   `maximumLineUTF8Length` bytes, and a clip sets `isTruncated` — content
    ///   was lost, and the marker is how the popover says so. This is the hang
    ///   guard, and it is here rather than in `truncated`
    ///   because *here* is off the main thread (see the type's doc): the single
    ///   pass that costs the size of a 64 MB answer belongs beside the parse that
    ///   already paid for it, not in a renderer answering a mouse-moved event.
    ///
    /// Clipped *before* the blank edges go, so the degenerate line — three
    /// thousand spaces and then a character — cannot be clipped down to
    /// whitespace and then kept as a segment with nothing to draw.
    public init?(segments: [HoverSegment], isTruncated: Bool = false) {
        var didClip = false
        let kept = segments.compactMap { segment -> HoverSegment? in
            let normalized = HoverContent.normalized(segment.text)
            if normalized.didClip { didClip = true }
            guard !normalized.text.isEmpty else { return nil }
            return HoverSegment(kind: segment.kind, text: normalized.text)
        }
        guard !kept.isEmpty else { return nil }
        self.segments = kept
        self.isTruncated = isTruncated || didClip
    }

    /// `text` with every line clipped to the two length caps and the leading and
    /// trailing lines that then carry nothing but whitespace removed, plus whether
    /// the clip fired. Interior blank lines and every line's own indentation stay:
    /// they are the content.
    private static func normalized(_ text: String) -> (text: String, didClip: Bool) {
        var lines = HoverMarkup.lines(of: text)
        var didClip = false
        for index in lines.indices {
            let clip = clipped(lines[index])
            guard clip.didClip else { continue }
            lines[index] = clip.text
            didClip = true
        }
        let isBlank: (String) -> Bool = {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        return (lines.joined(separator: "\n"), didClip)
    }

    /// One line cut at whichever of the two length caps it reaches first, plus
    /// whether anything was cut.
    ///
    /// Cut on a `Character` boundary — no clip here halves a grapheme — which is
    /// exactly why the byte cap is checked *before* a character is kept rather
    /// than after: a single cluster too big for it is dropped whole, and "keep it,
    /// it is only one character" is the hole the byte cap exists to close. A line
    /// that is nothing but such a cluster clips to nothing, and a segment left
    /// with nothing is dropped by the initializer above — a hover answer whose
    /// entire content is an unrenderable blob draws no popover, which is the
    /// no-empty-popover rule reached from the other end.
    ///
    /// The walk is the *only* pass either cap costs, and it never runs on real
    /// text: a line whose whole UTF-8 size fits the character cap can break
    /// neither cap, since a character is at least one byte, so ordinary answers
    /// leave here on the first line of this function.
    private static func clipped(_ line: String) -> (text: String, didClip: Bool) {
        guard line.utf8.count > maximumLineLength else { return (line, false) }
        var cursor = line.startIndex
        var characters = 0
        var bytes = 0
        while cursor < line.endIndex, characters < maximumLineLength {
            let next = line.index(after: cursor)
            let width = line.utf8.distance(from: cursor, to: next)
            guard bytes + width <= maximumLineUTF8Length else { break }
            bytes += width
            characters += 1
            cursor = next
        }
        guard cursor < line.endIndex else { return (line, false) }
        return (String(line[..<cursor]), true)
    }

    /// The unchecked one, for the paths that have already established the
    /// invariant — only `truncated(toLineCount:)`, which keeps at least one line
    /// of at least one segment by construction.
    private init(checkedSegments: [HoverSegment], isTruncated: Bool) {
        self.segments = checkedSegments
        self.isTruncated = isTruncated
    }

    /// Total drawn lines across every segment.
    public var lineCount: Int { segments.reduce(0) { $0 + $1.lines.count } }

    /// This content capped at `limit` lines of `lineLength` characters each,
    /// saying whether it had to cut.
    ///
    /// Pure, and idempotent at the same limits. A cap below one line — or below
    /// one character — is read as one: the caller is asking for a popover, and an
    /// empty popover is not a smaller answer but a different (and forbidden) one.
    /// A partial segment keeps its kind and language — half a code block is still
    /// code — and a cut line is cut on a `Character` boundary, so no truncation
    /// here can halve a grapheme.
    ///
    /// Either dimension cutting sets `isTruncated`: the marker says "there was
    /// more", and a line whose tail is gone is exactly that.
    ///
    /// **The length dimension has nothing left to do at its default**, because the
    /// checking initializer already established it — which is what makes this safe
    /// to call on the main thread, since every line it walks is at most
    /// `maximumLineLength` characters *and* `maximumLineUTF8Length` bytes long
    /// (the second is the one that makes the first a bound on work rather than on
    /// a count). It stays a parameter all the same: the
    /// cap is stated here whole, so a caller asking for a *smaller* popover gets
    /// one and the function remains idempotent at whatever limits it was given.
    public func truncated(
        toLineCount limit: Int = HoverContent.maximumLineCount,
        lineLength lengthLimit: Int = HoverContent.maximumLineLength
    ) -> HoverContent {
        let cap = max(1, limit)
        let lengthCap = max(1, lengthLimit)
        var kept: [HoverSegment] = []
        var remaining = cap
        var didCut = false

        for segment in segments {
            guard remaining > 0 else {
                // Every segment carries text (the checking initializer drops the
                // ones that do not), so a segment left unvisited is content lost.
                didCut = true
                break
            }
            let capped = HoverContent.cappedLines(
                of: segment.text,
                count: remaining,
                length: lengthCap
            )
            if capped.didCut { didCut = true }
            remaining -= capped.lines.count
            kept.append(
                HoverSegment(kind: segment.kind, text: capped.lines.joined(separator: "\n"))
            )
        }
        guard didCut else { return self }
        // Every kept segment starts on a non-blank line (the checking initializer
        // establishes that), so cutting *lines* can never empty one. Cutting a
        // line's *tail* can, at a length cap small enough to leave only a first
        // line's indentation — degenerate, but this returns content that is drawn,
        // and "there is no empty popover" is the one rule it may not break. So the
        // blanks go, and content the cap would erase entirely stays whole: an
        // answer too big for the cap is still an answer, an empty one is not.
        let survivors = kept.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !survivors.isEmpty else { return self }
        return HoverContent(checkedSegments: survivors, isTruncated: true)
    }

    /// The first `count` lines of `text`, each clipped to `length` characters,
    /// plus whether anything was left behind.
    ///
    /// Exactly what `segment.lines` + `prefix` would answer, and deliberately not
    /// spelled that way: `lines` splits the *whole* string, so it allocates a copy
    /// of every line past the cap before the cap can drop them. This walks only as
    /// far as the budget reaches, so what it materializes is what will be drawn —
    /// `count` × `length` characters at most — and, because every line it can meet
    /// is already bounded by the checking initializer *in bytes as well as in
    /// characters*, the walk itself is bounded too: the newline search below and
    /// the grapheme breaking `prefix` does both cost at most one bounded line.
    /// That is the whole of `truncated`'s main-thread cost.
    ///
    /// Line ends are found on the UTF-8 view rather than by iterating
    /// `Character`s: a newline is one byte that no multi-byte sequence can
    /// contain, so the search is a byte scan instead of grapheme breaking over
    /// text that is about to be discarded. `prefix` then does the clipping on the
    /// `Character` view, where the no-halved-grapheme promise lives.
    ///
    /// The separator is `"\n"` alone, matching `HoverSegment.lines`: every text a
    /// `HoverContent` holds has been through `HoverMarkup.lines`, which normalizes
    /// `\r\n` and `\r` away.
    private static func cappedLines(
        of text: String,
        count: Int,
        length: Int
    ) -> (lines: [String], didCut: Bool) {
        var lines: [String] = []
        var didCut = false
        var cursor = text.startIndex
        while lines.count < count {
            let lineEnd = text.utf8[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? text.endIndex
            let line = text[cursor..<lineEnd]
            let head = line.prefix(length)
            if head.endIndex < line.endIndex { didCut = true }
            lines.append(String(head))
            // The last line is the one no separator follows. A separator at the
            // very end is a trailing empty line, which is a line like any other —
            // the same one `components(separatedBy:)` would report.
            guard lineEnd < text.endIndex else { return (lines, didCut) }
            cursor = text.index(after: lineEnd)
        }
        // The line budget ran out with text still to come.
        return (lines, true)
    }
}

// MARK: - Construction from a hover payload

extension HoverContent {
    /// The one interpretation of a `textDocument/hover` answer.
    ///
    /// Element order and each element's declared language survive verbatim: a
    /// server that sends `[{language: "swift", value: "func f()"}, "Does a
    /// thing."]` gets a code segment and then a prose one, in that order, and
    /// merging them would be exactly the mistake the two segment kinds exist to
    /// prevent.
    public init?(_ response: LSPHoverResponse) {
        self.init(hoverElements: response.elements)
    }

    /// The same, from the elements alone — what the tests drive and what a
    /// caller holding a decoded payload piecemeal would use.
    public init?(hoverElements: [LSPHoverElement]) {
        self.init(segments: hoverElements.flatMap(HoverMarkup.segments(of:)))
    }
}

/// The markup reader: everything that turns a server's string into segments.
///
/// Not a Markdown implementation and not trying to be. Hover answers are a
/// narrow dialect — a fenced signature, a paragraph, a list, the odd link — and
/// what matters is that **the constructs this does not render are degraded
/// rather than shown raw**: a `**` left standing in a type signature reads as an
/// error in the code, not as a limitation of the popover.
///
/// The two markup kinds are read differently, which is the whole reason the
/// server is asked to declare one. `markdown` is interpreted; `plaintext` is
/// *not* — its asterisks and backticks are the text, and stripping them would
/// corrupt a signature the server took care to send unformatted. Both are
/// normalized for whitespace.
enum HoverMarkup {
    static func segments(of element: LSPHoverElement) -> [HoverSegment] {
        switch element {
        case .code(let language, let value):
            let text = codeBlock(value)
            return text.isEmpty ? [] : [.code(text, language: language)]
        case .markup(.plaintext, let value):
            let text = proseBlock(value)
            return text.isEmpty ? [] : [.prose(text)]
        case .markup(.markdown, let value):
            return segments(markdown: value)
        }
    }

    // MARK: Block structure

    /// Split into fenced code blocks and the prose between them.
    ///
    /// An unterminated fence takes the rest of the element as code, which is
    /// CommonMark's rule and also the forgiving one: a server that forgets a
    /// closing fence meant everything after it to be a signature.
    static func segments(markdown: String) -> [HoverSegment] {
        var result: [HoverSegment] = []
        var prose: [String] = []

        func flushProse() {
            let text = proseBlock(prose.joined(separator: "\n"))
            if !text.isEmpty { result.append(.prose(text)) }
            prose = []
        }

        let lines = self.lines(of: markdown)
        var index = 0
        while index < lines.count {
            guard let fence = Fence(opening: lines[index]) else {
                prose.append(degraded(lines[index]))
                index += 1
                continue
            }
            flushProse()
            index += 1
            var body: [String] = []
            while index < lines.count, !fence.closes(lines[index]) {
                body.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }  // the closing fence itself
            let text = codeBlock(body.joined(separator: "\n"))
            if !text.isEmpty { result.append(.code(text, language: fence.language)) }
        }
        flushProse()
        return result
    }

    /// A fenced block's opening line: three or more backticks or tildes, up to
    /// three spaces of indentation, and an info string whose first word is the
    /// language.
    struct Fence {
        let marker: Character
        let length: Int
        let language: String?

        init?(opening line: String) {
            let stripped = HoverMarkup.strippingBlockIndent(line)
            guard let marker = stripped.first, marker == "`" || marker == "~" else { return nil }
            let run = stripped.prefix { $0 == marker }.count
            guard run >= 3 else { return nil }
            let info = stripped.dropFirst(run).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string may not contain a backtick — that
            // is an inline code span on its own line, not a fence.
            if marker == "`", info.contains("`") { return nil }
            let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            self.marker = marker
            self.length = run
            self.language = (word?.isEmpty ?? true) ? nil : word
        }

        func closes(_ line: String) -> Bool {
            let stripped = HoverMarkup.strippingBlockIndent(line)
            guard stripped.first == marker else { return false }
            let run = stripped.prefix { $0 == marker }.count
            guard run >= length else { return false }
            return stripped.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    // MARK: Line degrading

    /// One prose line with its markup removed.
    ///
    /// Every construct here is either *unrenderable* by a popover that draws two
    /// fonts and nothing else (headings, emphasis, rules) or *actively harmful*
    /// if left standing (a URL three times longer than the sentence around it).
    /// A line that degrades to nothing becomes a blank line, and blank runs
    /// collapse afterwards — so a lone `---` between two paragraphs leaves one
    /// separating blank line rather than a gap or a stray glyph.
    static func degraded(_ line: String) -> String {
        var text = trimmingTrailingWhitespace(line)
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if isHorizontalRule(text) { return "" }

        let indent = String(text.prefix { $0 == " " || $0 == "\t" })
        var body = Substring(text.dropFirst(indent.count))

        if let heading = strippingHeadingMarker(body) {
            return trimmingTrailingWhitespace(inline(String(heading)))
        }

        var bullet = ""
        if let rest = strippingBulletMarker(body) {
            bullet = "• "
            body = rest
        }

        text = indent + bullet + inline(String(body))
        return trimmingTrailingWhitespace(text)
    }

    /// `***`, `---` or `___`, three or more, spaces allowed between.
    static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = strippingBlockIndent(line).filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first else { return false }
        guard first == "*" || first == "-" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// `#`…`######` followed by a space or end of line; a closing run of `#` goes
    /// too. Returns `nil` when the line is not a heading.
    static func strippingHeadingMarker(_ line: Substring) -> Substring? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = Substring(rest.drop { $0 == " " || $0 == "\t" })
        // A closing run of `#` is a marker only when whitespace separates it from
        // the heading text (CommonMark), or when it is the whole heading. The
        // distinction is not pedantry here: `C#`, `F#` and a shell `$#` all end in
        // one, and a popover that renames `C#` to `C` is wrong rather than plain.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let preceding = text.dropLast(closing).last
            if preceding == nil || preceding == " " || preceding == "\t" {
                text = text.dropLast(closing)
            }
        }
        return Substring(text.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    /// `-`, `*` or `+` followed by whitespace. Ordered markers (`1.`) are left
    /// alone: they already read as a list, and their numbers carry meaning a
    /// bullet would throw away.
    static func strippingBulletMarker(_ line: Substring) -> Substring? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
        let rest = line.dropFirst()
        guard let next = rest.first, next == " " || next == "\t" else { return nil }
        return Substring(rest.drop { $0 == " " || $0 == "\t" })
    }

    // MARK: Inline degrading

    /// One line's inline markup removed, in a single left-to-right pass.
    ///
    /// Order matters and is the reason this is not a series of replacements:
    /// a code span's contents are kept **verbatim**, so `` `a*b*c` `` keeps its
    /// asterisks while `*emphasis*` loses them, and a link's text is degraded
    /// while its URL is dropped whole.
    ///
    /// The output is assembled as *pieces* rather than one appended string for
    /// one reason: an emphasis delimiter cannot be judged when it is read. A run
    /// that opens emphasis is markup only if something later closes it, so its
    /// piece is written empty and rewritten with the literal delimiters if the
    /// line ends with it still unmatched — see the loop at the bottom.
    static func inline(_ line: String) -> String {
        let characters = Array(line)
        var pieces: [String] = []
        /// The piece plain text is currently accumulating into, or `nil` when the
        /// last thing written was a delimiter (whose index must stay stable).
        var openPiece: Int?
        /// Delimiter runs dropped on the promise of a closer: where the empty
        /// piece is, and what to put back if the promise is not kept.
        var pendingOpeners: [Character: [(piece: Int, literal: String)]] = [:]

        func write(_ text: String) {
            if let openPiece {
                pieces[openPiece] += text
            } else {
                pieces.append(text)
                openPiece = pieces.count - 1
            }
        }
        func writeDelimiter(_ text: String) -> Int {
            pieces.append(text)
            openPiece = nil
            return pieces.count - 1
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count,
               characters[index + 1].isMarkdownPunctuation {
                write(String(characters[index + 1]))
                index += 2
                continue
            }

            if character == "`" {
                let run = runLength(of: "`", in: characters, at: index)
                if let span = codeSpan(in: characters, openingAt: index, length: run) {
                    write(span.text)
                    index = span.end
                } else {
                    write(String(repeating: "`", count: run))
                    index += run
                }
                continue
            }

            if character == "!", index + 1 < characters.count, characters[index + 1] == "[",
               let label = bracketedLabel(in: characters, openingAt: index + 1),
               let end = skippingLinkTarget(in: characters, from: label.end) {
                write(inline(label.text))
                index = end
                continue
            }

            if character == "[", let label = bracketedLabel(in: characters, openingAt: index),
               let end = skippingLinkTarget(in: characters, from: label.end) {
                write(inline(label.text))
                index = end
                continue
            }

            if character == "<", let end = htmlTagEnd(in: characters, from: index) {
                index = end
                continue
            }

            if character == "*" || character == "_" {
                let run = runLength(of: character, in: characters, at: index)
                let literal = String(repeating: character, count: run)
                let role = emphasisRole(character, in: characters, at: index, length: run)
                if role.canClose, pendingOpeners[character]?.isEmpty == false {
                    pendingOpeners[character]?.removeLast()
                    _ = writeDelimiter("")
                } else if role.canOpen {
                    let piece = writeDelimiter("")
                    pendingOpeners[character, default: []].append((piece, literal))
                } else {
                    _ = writeDelimiter(literal)
                }
                index += run
                continue
            }

            write(String(character))
            index += 1
        }

        // An opener nothing closed is not markup. CommonMark leaves such a run as
        // literal text, and here that is the difference between `w*h`, `*ptr` and
        // `_private` reaching the popover spelled the way the code spells them and
        // reaching it as `wh`, `ptr` and `private` — a wrong name rather than an
        // unformatted one, in the one popover whose job is naming things.
        for (_, openers) in pendingOpeners {
            for opener in openers { pieces[opener.piece] = opener.literal }
        }
        return pieces.joined()
    }

    private static func runLength(of character: Character, in characters: [Character], at index: Int) -> Int {
        var length = 0
        while index + length < characters.count, characters[index + length] == character { length += 1 }
        return length
    }

    /// A code span opening at `index` with `length` backticks, closed by a run of
    /// *exactly* that many. `nil` when it is never closed — the backticks are
    /// then literal text, which is CommonMark's reading and the only one that
    /// leaves an unbalanced backtick visible instead of eating the line.
    private static func codeSpan(
        in characters: [Character],
        openingAt index: Int,
        length: Int
    ) -> (text: String, end: Int)? {
        var cursor = index + length
        while cursor < characters.count {
            guard characters[cursor] == "`" else {
                cursor += 1
                continue
            }
            let run = runLength(of: "`", in: characters, at: cursor)
            if run == length {
                var text = String(characters[(index + length)..<cursor])
                // CommonMark strips one leading and one trailing space when both
                // are present, so `` ` `` renders as a lone backtick.
                if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" ") {
                    text = String(text.dropFirst().dropLast())
                }
                return (text, cursor + run)
            }
            cursor += run
        }
        return nil
    }

    /// The text between a `[` and its matching `]`, nesting allowed.
    private static func bracketedLabel(
        in characters: [Character],
        openingAt index: Int
    ) -> (text: String, end: Int)? {
        var depth = 0
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 {
                    return (String(characters[(index + 1)..<cursor]), cursor + 1)
                }
            }
            cursor += 1
        }
        return nil
    }

    /// Past a link label's destination — `(url)`, and only that — or `nil` when
    /// no target follows. The URL is what is being thrown away.
    ///
    /// **`nil` is the load-bearing answer**, and it is what makes a `[…]` a link
    /// rather than any balanced pair of brackets. CommonMark only reads a label
    /// as a link when a destination or a matching reference definition follows;
    /// consuming the brackets regardless would rewrite `[]byte` into `byte`,
    /// `map[string]int` into `mapstringint` and `[T; N]` into `T; N` — a *wrong*
    /// name rather than an unformatted one, in exactly the prose Go and Rust
    /// servers write beside a signature. Same reasoning as the unclosed emphasis
    /// run at the bottom of `inline(_:)`: unmatched markup is text.
    ///
    /// **A reference target (`[label][ref]`) is deliberately not read**, which is
    /// where this stops following CommonMark. The two syntaxes are
    /// indistinguishable from `a[i][j]` — a doubly-indexed expression in every
    /// language a server answers for — and honouring the markup answers `ai`,
    /// the same class of wrong name the paragraph above exists to prevent. The
    /// trade is one-sided: a reference link needs a `[ref]: url` definition to
    /// resolve against, and a hover string is a fragment with no document for
    /// one to live in, so nothing is lost that a server can actually send. Such
    /// a label stays literal text, which is the degraded-not-wrong direction the
    /// whole reader is built around.
    private static func skippingLinkTarget(in characters: [Character], from index: Int) -> Int? {
        guard index < characters.count, characters[index] == "(" else { return nil }
        var depth = 0
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    /// The HTML element names a hover answer is allowed to contain, lowercase.
    ///
    /// An allow-list, where CommonMark accepts *any* name — and the difference is
    /// the whole point. `<T>`, `<u8>` and `<Element>` are perfectly valid raw HTML
    /// by the spec, and they are also exactly how every server writes a generic in
    /// the unfenced prose beside a signature, so spelling this rule the spec's way
    /// deletes the type parameter the popover exists to show.
    ///
    /// Matched **case-sensitively** for the same reason: markup is written
    /// lowercase and type parameters are written capitalised, so `<BR>` surviving
    /// as text is a far cheaper mistake than `Box<B>` losing its parameter.
    private static let htmlTagNames: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "code", "dd", "del", "details",
        "div", "dl", "dt", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i",
        "img", "ins", "kbd", "li", "ol", "p", "pre", "q", "s", "samp", "small",
        "span", "strong", "sub", "summary", "sup", "table", "tbody", "td",
        "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var",
    ]

    /// The index just past `<tag …>` or `</tag>`, or `nil` when the `<` starts
    /// something else — a comparison, a generic parameter list, an autolinked
    /// URL — all of which stay exactly as the server wrote them.
    ///
    /// The attribute list is *walked* rather than skipped to the next `>`, which
    /// is the second half of not eating prose: `Compare a<b and x<y>z` opens with
    /// something tag-shaped, and a scan to the nearest `>` deletes the clause
    /// between them. Here the `<` inside `x<y` is not a character an attribute may
    /// contain, so the whole thing is rejected and stays text.
    private static func htmlTagEnd(in characters: [Character], from index: Int) -> Int? {
        var cursor = index + 1
        let isClosing = cursor < characters.count && characters[cursor] == "/"
        if isClosing { cursor += 1 }
        let nameStart = cursor
        guard cursor < characters.count, characters[cursor].isLetter else { return nil }
        while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber
            || characters[cursor] == "-" {
            cursor += 1
        }
        guard htmlTagNames.contains(String(characters[nameStart..<cursor])) else { return nil }

        func skippingSpaces(from start: Int) -> Int {
            var cursor = start
            while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
                cursor += 1
            }
            return cursor
        }

        if isClosing {
            cursor = skippingSpaces(from: cursor)
            return cursor < characters.count && characters[cursor] == ">" ? cursor + 1 : nil
        }

        while cursor < characters.count {
            switch characters[cursor] {
            case ">":
                return cursor + 1
            case "/":
                cursor += 1
                return cursor < characters.count && characters[cursor] == ">" ? cursor + 1 : nil
            case " ", "\t":
                cursor = skippingSpaces(from: cursor)
            default:
                return nil
            }
            guard cursor < characters.count else { return nil }
            let start = characters[cursor]
            if start == ">" || start == "/" { continue }
            guard start.isLetter || start == "_" || start == ":" else { return nil }
            while cursor < characters.count, characters[cursor].isLetter
                || characters[cursor].isNumber || "_:.-".contains(characters[cursor]) {
                cursor += 1
            }
            var value = skippingSpaces(from: cursor)
            guard value < characters.count, characters[value] == "=" else { continue }
            value = skippingSpaces(from: value + 1)
            guard value < characters.count else { return nil }
            let quote = characters[value]
            if quote == "\"" || quote == "'" {
                value += 1
                while value < characters.count, characters[value] != quote { value += 1 }
                guard value < characters.count else { return nil }
                cursor = value + 1
            } else {
                let start = value
                while value < characters.count, !" \t\"'=<>`".contains(characters[value]) { value += 1 }
                guard value > start else { return nil }
                cursor = value
            }
        }
        return nil
    }

    /// What a run of `*` or `_` is *allowed* to be, from what touches it.
    ///
    /// A run touching non-whitespace on its right may open emphasis; one touching
    /// it on its left may close it. A run touching it on neither side is
    /// arithmetic (`a * b`) and can do neither. `*` may do both at once —
    /// Markdown allows intra-word emphasis with asterisks — while `_` may not,
    /// which is precisely what keeps `some_identifier_name` spelled the way the
    /// code spells it.
    ///
    /// **Permission, not a verdict.** Whether a run that *may* open actually is
    /// markup depends on a closer arriving, which is `inline(_:)`'s bookkeeping
    /// and not something a rule reading two adjacent characters can know.
    static func emphasisRole(
        _ character: Character,
        in characters: [Character],
        at index: Int,
        length: Int
    ) -> (canOpen: Bool, canClose: Bool) {
        let before = index > 0 ? characters[index - 1] : nil
        let after = index + length < characters.count ? characters[index + length] : nil
        let opens = after.map { !$0.isWhitespace } ?? false
        let closes = before.map { !$0.isWhitespace } ?? false
        if character == "*" { return (opens, closes) }
        return (opens && !closes, closes && !opens)
    }

    // MARK: Whitespace

    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func strippingBlockIndent(_ line: String) -> Substring {
        var indent = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " ", indent < 3 {
            indent += 1
            cursor = line.index(after: cursor)
        }
        return line[cursor...]
    }

    static func trimmingTrailingWhitespace(_ line: String) -> String {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        return String(text)
    }

    /// A code block's text: trailing whitespace goes from every line and blank
    /// lines go from both ends, but interior blank lines and **every line's
    /// leading indentation** stay — they are the code.
    static func codeBlock(_ text: String) -> String {
        var lines = self.lines(of: text).map(trimmingTrailingWhitespace)
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A prose block's text: as above, plus runs of blank lines collapsed to one
    /// — a server that separates two sentences with four newlines meant a
    /// paragraph break, not a hole in the popover.
    ///
    /// Blank lines are stripped off both ends **line-wise**, exactly as
    /// `codeBlock` does it, rather than by trimming the joined string: trimming
    /// whitespace off the join takes the *first* line's indentation with it and
    /// leaves every following line's in place, so an indented plaintext block —
    /// which is how a server with no markdown renderer sends a signature —
    /// arrives with its first line shifted left against the rest. `degraded(_:)`
    /// preserves each line's indent for the same reason; this is the one place
    /// that was silently disagreeing with it.
    static func proseBlock(_ text: String) -> String {
        var collapsed: [String] = []
        for line in lines(of: text).map(trimmingTrailingWhitespace) {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        while collapsed.first?.isEmpty == true { collapsed.removeFirst() }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }
}

extension Character {
    /// The characters a backslash may escape in Markdown. Anything else after a
    /// backslash is a literal backslash followed by that character.
    var isMarkdownPunctuation: Bool {
        "\\`*_{}[]()#+-.!<>|~\"$%&'/:;=?@^".contains(self)
    }
}
