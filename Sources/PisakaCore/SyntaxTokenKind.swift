import Foundation

/// A semantic class of syntax token, resolved from a tree-sitter capture name.
///
/// Pure, UI-free semantic type (no Neon/SwiftTreeSitter/AppKit), mirroring the
/// semantic-enum precedent of `FileIconColor`. The view layer (`SyntaxTheme`)
/// maps each kind to a concrete color; Core stays color-free.
///
/// tree-sitter highlight queries emit dotted capture names (`keyword.control`,
/// `punctuation.bracket`, …). `init(captureName:)` resolves them by matching the
/// longest known dotted prefix against a name→kind table, so unrecognised
/// suffixes degrade gracefully to the broader kind, and unknown names to
/// `.plain`.
public enum SyntaxTokenKind: Equatable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case variable
    case constant
    case `operator`
    case punctuation
    case property
    case parameter
    case label
    case plain

    /// Resolve a kind from a tree-sitter capture name.
    ///
    /// The name is split on `.` and progressively shorter prefixes are looked up
    /// (longest first), so `keyword.control.return` resolves via `keyword`. A
    /// leading `@` or `.` (as some grammars emit) is ignored. No match → `.plain`.
    public init(captureName: String) {
        let sanitized = captureName.drop { $0 == "@" || $0 == "." }
        let segments = sanitized.split(separator: ".")

        var index = segments.count
        while index > 0 {
            let prefix = segments[0..<index].joined(separator: ".")
            if let kind = SyntaxTokenKind.nameMap[prefix] {
                self = kind
                return
            }
            index -= 1
        }
        self = .plain
    }

    /// Known capture-name prefix → kind. Keys are matched longest-first by
    /// `init(captureName:)`, so single-segment keys also catch their dotted
    /// descendants (e.g. `keyword` catches `keyword.control`).
    private static let nameMap: [String: SyntaxTokenKind] = [
        "keyword": .keyword,
        "string": .string,
        // Escape sequences inside a string literal. Most grammars spell these
        // `@string.escape`, which the `string` prefix already catches; the Go
        // grammar spells them bare `@escape`, with no broader mapped prefix — so
        // without this entry every `\n` in a Go string would render
        // default-colored, punching a hole through the string's coloring.
        "escape": .string,
        "comment": .comment,
        "number": .number,
        "float": .number,
        "boolean": .constant,
        "type": .type,
        "constructor": .type,
        // HTML/XML element and attribute names — the structural backbone of
        // markup, emitted as `@tag`/`@attribute` (no broader prefix to fall
        // back on), so they must be mapped explicitly or they render plain.
        "tag": .type,
        // The tree-sitter-sql grammar emits `attribute` for IMMUTABLE/STRICT/etc.
        // Remapping it globally here would recolor HTML attributes and Rust
        // `#[derive(…)]`, so we leave it as `.property` on purpose.
        "attribute": .property,
        // Markdown's block grammar emits its structural tokens under `@text.*`
        // (no broader `text` prefix is mapped, so these must be listed
        // explicitly or headings/code/links render plain): `text.title`
        // (headings), `text.literal` (code spans/fences), `text.uri` (link
        // targets), `text.reference` (reference-style link labels).
        "text.title": .keyword,
        "text.literal": .string,
        "text.uri": .label,
        "text.reference": .label,
        // Markdown's inline grammar (`markdown_inline`) emits bold/italic spans
        // as `@text.emphasis`/`@text.strong`. With no broader `text` prefix
        // mapped they would fall through to `.plain`, which is wrong twice over:
        // the spans would be indistinguishable from body text, and inside a
        // heading the `.plain` (default-color) span would punch a hole in the
        // heading's coloring. The editor's TextKit-1 temporary-attribute styling
        // can't carry font traits (bold/italic affect layout and are ignored as
        // temporary attributes), so emphasis is expressed through color: mapping
        // both to `.keyword` keeps them in Markdown's structural color family
        // (matching `text.title`) so emphasis reads as emphasized in body text
        // and stays seamless with heading color when nested in a heading.
        "text.emphasis": .keyword,
        "text.strong": .keyword,
        "function": .function,
        "method": .function,
        "variable": .variable,
        // `@variable.parameter` (Swift/TS function params): matched longest-first
        // so it wins over the broader `variable` entry, giving parameters the
        // dedicated `.parameter` kind/color.
        "variable.parameter": .parameter,
        "constant": .constant,
        "operator": .operator,
        "punctuation": .punctuation,
        "property": .property,
        "parameter": .parameter,
        "label": .label,
        // SQL keyword-shaped capture names emitted by tree-sitter-sql.
        // `conditional` (CASE/WHEN/THEN/ELSE) and `storageclass` (TEMP/UNLOGGED).
        "conditional": .keyword,
        "storageclass": .keyword,
        // SQL column names in `column_definition` are emitted as `field`.
        "field": .property,
        // SQL modifiers (NOWAIT/MAXVALUE) are emitted as `type.qualifier`.
        // This overrides the `type` prefix intentionally, as they are keywords,
        // not types. No other pinned grammar emits it.
        "type.qualifier": .keyword
    ]
}
