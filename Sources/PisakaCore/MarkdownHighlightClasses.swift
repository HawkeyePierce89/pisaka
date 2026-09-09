import Foundation

/// The bridge between the preview's syntax highlighter and the editor's palette:
/// every scope the bundled highlight.js build emits, and the ``SyntaxTokenKind``
/// it is drawn in.
///
/// The preview highlights fenced code with highlight.js, which classifies a
/// token by writing a *scope* into the element's `class` attribute; the editor
/// classifies the same token through a tree-sitter capture name resolved to a
/// ``SyntaxTokenKind``. Two vocabularies, one palette — so this file is the one
/// place they are joined, and the page's stylesheet is generated from it rather
/// than written by hand. A fenced Swift block in the preview and the same block
/// in the text view beside it are the same code read twice; the moment the two
/// tables drift, the pane stops being a preview of *this* editor.
///
/// **The scope list is pinned, not discovered.** ``standardScopes`` is the
/// documented class vocabulary of the highlight.js *standard* build — the one
/// bundled under `Resources/MarkdownPreview` — transcribed from that release's
/// own CSS-classes reference (`docs/css-classes-reference.rst` in the highlight.js
/// source tree). The exact version it was transcribed from is recorded, with the
/// update procedure, in `Resources/MarkdownPreview/VENDORED.md`; bumping the
/// bundled build means re-reading that document and re-stating the list here.
/// Nothing at run time can notice a stale entry — an unmapped scope renders in
/// body-text colour, which looks like ordinary unhighlighted code — so the
/// coverage is asserted statically instead, in both directions.
///
/// **A scope is not a class name.** highlight.js writes a top-level scope as
/// `hljs-<scope>` and each further segment of a dotted scope as that segment with
/// one trailing underscore per level of depth, all on the same element:
/// `title.function.invoke` arrives as `class="hljs-title function_ invoke__"`.
/// ``cssSelector(forScope:)`` is that rule, written once, and it is what makes a
/// refinement win: `.hljs-title.function_` carries more class selectors than
/// `.hljs-title`, so the more specific scope colours the token without any
/// ordering being relied on.
public enum MarkdownHighlightClasses {

    /// Scope → the kind it is drawn in.
    ///
    /// Total over ``standardScopes``, and onto every ``SyntaxTokenKind`` — both
    /// halves asserted by set equality, because either gap is silent. A scope
    /// with no entry renders uncoloured; a kind no scope reaches is a colour the
    /// preview computes, ships in the page's CSS and never uses.
    ///
    /// Where a scope has an obvious counterpart in the editor's own capture table
    /// (`SyntaxTokenKind.nameMap`) it is given the same kind, so the two
    /// highlighters agree by construction rather than by coincidence: `tag` and
    /// `name` are `.type` there, `attr`/`attribute` are `.property`, `section`
    /// (a heading) and `emphasis`/`strong` are `.keyword`, `code` is `.string`
    /// and `link` is `.label`.
    public static let scopeKinds: [String: SyntaxTokenKind] = [

        // MARK: General purpose

        "keyword": .keyword,
        // Built-in types and functions the language supplies rather than the
        // file: `.type` for the same reason the editor maps `constructor` there.
        "built_in": .type,
        "type": .type,
        // `true`, `false`, `nil` — the editor's `boolean` capture is `.constant`.
        "literal": .constant,
        "number": .number,
        "operator": .operator,
        "punctuation": .punctuation,
        "property": .property,
        // A regular-expression literal is a literal: the same red a string takes,
        // which is also what the editor's grammars emit for one.
        "regexp": .string,
        "string": .string,
        // `\n` inside a literal — the editor's `escape`/`string.escape`, `.string`
        // there for the same reason: an escape drawn in another colour punches a
        // hole through the literal it is inside.
        "char.escape": .string,
        // The wrapper around an interpolated expression inside a string
        // (`\(x)`, `${x}`). It is `.plain` *on purpose*: the expression inside is
        // re-highlighted with its own scopes, and the whole point of the wrapper
        // is that it is no longer string-coloured. This is the one scope whose
        // right answer is the absence of a colour.
        "subst": .plain,
        // Ruby/Elixir symbols, HTML entities: interned literals.
        "symbol": .constant,
        // The pre-11 spellings of `title.class`/`title.function`. Kept because
        // they are still documented and still emitted by grammars that predate
        // the rename; an unused entry costs one unused CSS rule, a missing one
        // costs an uncoloured token in whichever language still emits it.
        "class": .type,
        "function": .function,
        "variable": .variable,
        // `this`, `self`, `super` — the language's own variables, which read as
        // keywords in every scheme and are keywords to the reader.
        "variable.language": .keyword,
        "variable.constant": .constant,
        // The name in a declaration. `.function` is the unrefined answer, since
        // the refinements below re-point the class-shaped ones.
        "title": .function,
        "title.class": .type,
        "title.class.inherited": .type,
        "title.function": .function,
        "title.function.invoke": .function,
        "params": .parameter,
        "comment": .comment,
        // `@param` and friends *inside* a comment. `.comment` keeps them in the
        // comment's own colour: the editor draws a whole comment in one colour
        // and a doctag drawn in another would read as code that escaped it.
        "doctag": .comment,

        // MARK: Meta

        // `#include`, `#!/bin/sh`, `@Decorator` — instructions to the toolchain
        // rather than to the runtime, which is what a keyword is.
        "meta": .keyword,
        "meta.prefix": .keyword,
        "meta.keyword": .keyword,
        // The `<stdio.h>` of `#include <stdio.h>`: a literal inside a directive.
        "meta.string": .string,

        // MARK: Tags, attributes, configs

        // A heading in a markup language — the editor's `text.title`, `.keyword`
        // there too.
        "section": .keyword,
        "tag": .type,
        "name": .type,
        "attr": .property,
        "attribute": .property,

        // MARK: Text markup

        "bullet": .punctuation,
        // A code span in markup — the editor's `text.literal`.
        "code": .string,
        // The editor draws emphasis through colour rather than through font
        // traits and puts both in `.keyword`; the preview *can* use real italics
        // and bold, so this colour is what a marked span keeps on top of them.
        "emphasis": .keyword,
        "strong": .keyword,
        // A LaTeX span: literal content this feature does not typeset (one of the
        // preview's three stated limits), drawn as the literal it is.
        "formula": .string,
        // The editor's `text.uri`/`text.reference`.
        "link": .label,
        // A blockquote's content: secondary by definition, and `.comment` is the
        // palette's one muted entry.
        "quote": .comment,

        // MARK: CSS

        "selector-tag": .type,
        "selector-id": .label,
        "selector-class": .label,
        "selector-attr": .property,
        "selector-pseudo": .keyword,

        // MARK: Templates

        "template-tag": .keyword,
        "template-variable": .variable,

        // MARK: diff

        // A diff hunk has no counterpart in an editor's semantic vocabulary, so
        // these two are chosen for their *colour* rather than their meaning, and
        // said so here: `.function` is the palette's green and `.string` its red,
        // which is the one convention a diff may not violate.
        "addition": .function,
        "deletion": .string,
    ]

    /// Every scope the bundled standard build emits, as its own documentation
    /// lists them. The source and the version are in this type's doc comment and
    /// in `Resources/MarkdownPreview/VENDORED.md`.
    ///
    /// Kept as a set beside the table rather than derived from it, so the two can
    /// be compared: a scope added to the table but not to this list is a guess,
    /// and a scope in this list with no table entry is an uncoloured token.
    public static let standardScopes: Set<String> = [
        "keyword", "built_in", "type", "literal", "number", "operator",
        "punctuation", "property", "regexp", "string", "char.escape", "subst",
        "symbol", "class", "function", "variable", "variable.language",
        "variable.constant", "title", "title.class", "title.class.inherited",
        "title.function", "title.function.invoke", "params", "comment", "doctag",
        "meta", "meta.prefix", "meta.keyword", "meta.string",
        "section", "tag", "name", "attr", "attribute",
        "bullet", "code", "emphasis", "formula", "link", "quote", "strong",
        "selector-tag", "selector-id", "selector-class", "selector-attr",
        "selector-pseudo",
        "template-tag", "template-variable",
        "addition", "deletion",
    ]

    /// The kind a scope is drawn in, or `nil` for a scope this build does not
    /// know. `nil` rather than `.plain`, because "no rule at all" and "a rule
    /// naming body-text colour" are different pages: the caller emits nothing for
    /// the first, which is what leaves an unknown scope inheriting whatever
    /// encloses it.
    public static func kind(forScope scope: String) -> SyntaxTokenKind? {
        scopeKinds[scope]
    }

    /// The CSS selector matching the element highlight.js writes for a scope.
    ///
    /// The emission rule, in one place: the first segment becomes `hljs-<segment>`
    /// and each following segment becomes that segment with one trailing
    /// underscore per level of depth, every class on the same element. So
    /// `keyword` → `.hljs-keyword`, `char.escape` → `.hljs-char.escape_`, and
    /// `title.class.inherited` → `.hljs-title.class_.inherited__`. Depth is what
    /// carries specificity: a refined scope's selector names more classes than
    /// its parent's, so it wins wherever both match, with no ordering relied on.
    ///
    /// An empty scope answers `nil` — there is no element it could name.
    public static func cssSelector(forScope scope: String) -> String? {
        let segments = scope.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = segments.first, !first.isEmpty else { return nil }

        var selector = ".hljs-" + first
        for (offset, segment) in segments.dropFirst().enumerated() {
            guard !segment.isEmpty else { return nil }
            selector += "." + segment + String(repeating: "_", count: offset + 1)
        }
        return selector
    }
}
