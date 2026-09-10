import Foundation

/// The `id` a rendered heading carries, and the rule that keeps two headings
/// from carrying the same one.
///
/// It lives beside the renderer, in Core, because an anchor is a **round trip
/// between two decisions this package already owns**: `MarkdownRenderer` writes
/// the `id`, and `MarkdownLinkRule` reads the fragment a click resolved to. Put
/// the rule in the page instead — a slug derived in JavaScript from a heading's
/// text — and the two halves would be written in different languages against
/// different string semantics, with nothing in `swift test` able to assert that
/// `[x](#a-heading)` reaches `## A Heading`. `preview.js` therefore keeps doing
/// an `id` lookup and nothing more; every reading of a heading's text is here.
///
/// The rule is GFM's, which is also what a document author will have in mind
/// when they type `#a-heading` by hand:
///
/// * the heading's inline content flattened to its words (the renderer hands
///   over `plainText(_:)`, the same flattening an image's `alt` uses, so
///   `## The **rule**` and `## The rule` slug identically);
/// * lowercased;
/// * every character that is not a letter, a digit, a space, a hyphen or an
///   underscore removed;
/// * spaces turned into hyphens.
///
/// Three details of that middle step are worth stating, each being the kind of
/// thing a reader assumes the other way:
///
/// * **A tab is removed, not folded to a hyphen.** "Space" here is the ASCII
///   space and nothing else, so a tab, a newline and a non-breaking space are
///   dropped like any other character outside the five classes. Folding them
///   would be a second, invisible rule about whitespace, and the character that
///   actually reaches a heading from a soft break is already a space.
/// * **Letter and digit are Unicode's, not ASCII's.** `## Привет мир` slugs to
///   `привет-мир` rather than to nothing, which is the only answer that lets a
///   non-English document have anchors at all. A URL fragment carries those
///   characters fine; percent-encoding is the transport's business, and both
///   sides of the round trip go through `URL` —
///   ``MarkdownLinkRule`` reads the fragment *decoded* for exactly this.
/// * **An underscore survives, like a hyphen.** GFM strips a punctuation set
///   that does not contain `_`, so `## snake_case` is `#snake_case` there and
///   must be here: an underscore is ordinary in the headings technical
///   documents carry (`indent_style`, `__init__`), and dropping it would send
///   every anchor an author copied from a rendered README to nothing at all.
///
/// An empty result is `nil` rather than the empty string: a heading made only of
/// punctuation has no honest anchor, and `id=""` is an attribute no fragment can
/// name while still being one a reader would take for a target.
public enum MarkdownHeadingSlug {

    /// `text` as a slug, or `nil` when nothing survives the rule.
    public static func slug(forText text: String) -> String? {
        var slug = ""
        for character in text.lowercased() {
            if character == " " {
                slug.append("-")
            } else if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            }
        }
        return slug.isEmpty ? nil : slug
    }

    /// The `id`s of one document, allocated in the order the renderer walks it.
    ///
    /// A **value threaded through the walk**, not static state: the renderer is
    /// a pure function of a tree and a context, and a shared counter would make
    /// two renders of the same document produce different markup — the second
    /// one's headings suffixed by the first one's. Threading it as `inout` also
    /// puts document order in the type: a heading gets its number when the walk
    /// reaches it, so a nested one is numbered where it sits rather than after
    /// every top-level one.
    ///
    /// Repeats are suffixed `-1`, `-2`, … in that order, so the first `## Notes`
    /// keeps `notes` and the second gets `notes-1`. The suffix is searched
    /// forward **past anything already taken**, which is what keeps a document
    /// that spells both `## Notes` twice and `## Notes 1` from producing two
    /// `notes-1`s: a collision here would be silent in the page and would send
    /// the second link to the first heading.
    ///
    /// "Taken" includes the ids the caller **reserves** at `init`, and the
    /// renderer reserves the one the shell itself ships. `getElementById` answers
    /// the *first* element in document order, so a `## Content` heading emitted
    /// inside `<div id="content">` would take an id an ancestor already carries
    /// and send its link to the top of the page — the same silent wrong-target
    /// failure the suffixing exists to prevent, arriving from outside the walk.
    public struct Allocator {

        /// Every `id` taken so far — reserved or handed out — and therefore the
        /// set the search below must miss. The one store, so there is one rule.
        private var used: Set<String>

        /// - Parameter reserved: ids the document already carries from outside
        ///   the walk, which no heading may be given.
        public init(reserving reserved: Set<String> = []) {
            used = reserved
        }

        /// The `id` for a heading whose flattened text is `text`, or `nil` when
        /// the rule leaves nothing to name it by.
        public mutating func allocate(forText text: String) -> String? {
            guard let base = MarkdownHeadingSlug.slug(forText: text) else { return nil }

            var suffix = 0
            var candidate = base
            while used.contains(candidate) {
                suffix += 1
                candidate = "\(base)-\(suffix)"
            }

            used.insert(candidate)
            return candidate
        }
    }
}
