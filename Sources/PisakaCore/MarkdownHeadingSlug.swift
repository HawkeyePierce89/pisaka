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
/// * every character that is not a letter, a digit, a space or a hyphen
///   removed;
/// * spaces turned into hyphens.
///
/// Two details of that middle step are worth stating, both being the kind of
/// thing a reader assumes the other way:
///
/// * **A tab is removed, not folded to a hyphen.** "Space" here is the ASCII
///   space and nothing else, so a tab, a newline and a non-breaking space are
///   dropped like any other character outside the four classes. Folding them
///   would be a second, invisible rule about whitespace, and the character that
///   actually reaches a heading from a soft break is already a space.
/// * **Letter and digit are Unicode's, not ASCII's.** `## Привет мир` slugs to
///   `привет-мир` rather than to nothing, which is the only answer that lets a
///   non-English document have anchors at all. A URL fragment carries those
///   characters fine; percent-encoding is the transport's business, and both
///   sides of the round trip go through `URL`.
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
            } else if character.isLetter || character.isNumber || character == "-" {
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
    /// forward from the last one handed out **past anything already allocated**,
    /// which is what keeps a document that spells both `## Notes` twice and
    /// `## Notes 1` from producing two `notes-1`s: a collision here would be
    /// silent in the page and would send the second link to the first heading.
    public struct Allocator {

        /// Every `id` handed out so far — the set the search below must miss.
        private var used: Set<String> = []

        /// Per base slug, the last suffix handed out for it, so a document with
        /// many repeats of one heading does not rescan from `1` each time.
        private var lastSuffix: [String: Int] = [:]

        public init() {}

        /// The `id` for a heading whose flattened text is `text`, or `nil` when
        /// the rule leaves nothing to name it by.
        public mutating func allocate(forText text: String) -> String? {
            guard let base = MarkdownHeadingSlug.slug(forText: text) else { return nil }

            var suffix = lastSuffix[base] ?? 0
            var candidate = base
            while used.contains(candidate) {
                suffix += 1
                candidate = "\(base)-\(suffix)"
            }

            lastSuffix[base] = suffix
            used.insert(candidate)
            return candidate
        }
    }
}
