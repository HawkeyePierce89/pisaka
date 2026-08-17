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
    /// no blank first or last line.
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

    /// The failable, checking initializer: segments that carry nothing are
    /// dropped, and content left with no segments at all is no content.
    public init?(segments: [HoverSegment], isTruncated: Bool = false) {
        let kept = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !kept.isEmpty else { return nil }
        self.segments = kept
        self.isTruncated = isTruncated
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

    /// This content capped at `limit` lines, saying whether it had to cut.
    ///
    /// Pure, and idempotent at the same limit. A cap below one line is read as
    /// one: the caller is asking for a popover, and an empty popover is not a
    /// smaller answer but a different (and forbidden) one. A partial segment
    /// keeps its kind and language — half a code block is still code.
    public func truncated(toLineCount limit: Int = HoverContent.maximumLineCount) -> HoverContent {
        let cap = max(1, limit)
        guard lineCount > cap else { return self }

        var kept: [HoverSegment] = []
        var remaining = cap
        for segment in segments {
            guard remaining > 0 else { break }
            let lines = segment.lines
            if lines.count <= remaining {
                kept.append(segment)
                remaining -= lines.count
            } else {
                kept.append(
                    HoverSegment(
                        kind: segment.kind,
                        text: lines.prefix(remaining).joined(separator: "\n")
                    )
                )
                remaining = 0
            }
        }
        return HoverContent(checkedSegments: kept, isTruncated: true)
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
               let label = bracketedLabel(in: characters, openingAt: index + 1) {
                write(inline(label.text))
                index = skippingLinkTarget(in: characters, from: label.end)
                continue
            }

            if character == "[", let label = bracketedLabel(in: characters, openingAt: index) {
                write(inline(label.text))
                index = skippingLinkTarget(in: characters, from: label.end)
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

    /// Past a link label's destination — `(url)`, `[reference]`, or nothing at
    /// all for a shortcut reference. The URL is what is being thrown away.
    private static func skippingLinkTarget(in characters: [Character], from index: Int) -> Int {
        guard index < characters.count else { return index }
        let opener = characters[index]
        let closer: Character
        switch opener {
        case "(": closer = ")"
        case "[": closer = "]"
        default: return index
        }
        var depth = 0
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == opener { depth += 1 }
            if character == closer {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return index
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
    static func proseBlock(_ text: String) -> String {
        var collapsed: [String] = []
        for line in lines(of: text).map(trimmingTrailingWhitespace) {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Character {
    /// The characters a backslash may escape in Markdown. Anything else after a
    /// backslash is a literal backslash followed by that character.
    var isMarkdownPunctuation: Bool {
        "\\`*_{}[]()#+-.!<>|~\"$%&'/:;=?@^".contains(self)
    }
}
