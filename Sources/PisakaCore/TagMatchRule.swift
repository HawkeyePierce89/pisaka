import Foundation

/// One markup element as the app reads it off the syntax tree: a JSX element
/// or fragment, or an HTML element.
///
/// - `range`: the whole element, opening tag through closing tag.
/// - `openName`: the opening tag's name — `div` of `<div …>`. A fragment's
///   names are its `<>` and `</>` ranges, so the two pair with each other.
/// - `closeName`: the closing tag's name, or `nil` for a self-closing element
///   (`<Icon />`) and for one the tree left unclosed.
public struct TagElement: Equatable, Sendable {
    public let range: NSRange
    public let openName: NSRange
    public let closeName: NSRange?

    public init(range: NSRange, openName: NSRange, closeName: NSRange?) {
        self.range = range
        self.openName = openName
        self.closeName = closeName
    }
}

/// Which tag names the caret highlights, and whether that highlight takes the
/// bracket pair's place (R5).
///
/// The app extracts element ranges from the tree and paints; every decision
/// is here. Pure, Foundation-only, UTF-16 offsets like every editor engine.
public enum TagMatchRule {

    /// The settled answer for one caret.
    public struct Highlight: Equatable, Sendable {
        /// The tag-name ranges to paint, opening name first; empty for none.
        public let tagRanges: [NSRange]
        /// `true` when the tag pair wins over an active bracket pair, which
        /// the bracket highlight then does not paint.
        public let suppressBracketPair: Bool

        public init(tagRanges: [NSRange], suppressBracketPair: Bool) {
            self.tagRanges = tagRanges
            self.suppressBracketPair = suppressBracketPair
        }

        public static let none = Highlight(tagRanges: [], suppressBracketPair: false)
    }

    /// The highlight for a caret at `caret`.
    ///
    /// `enclosing` is the caret's chain of elements whose range contains it,
    /// innermost first, as the app read it off the tree — self-closing
    /// elements included. `bracketPairActive` is whether `BracketMatchEngine`
    /// has a pair at the caret.
    ///
    /// - **In a tag name** (either end inclusive, so `div|` counts): that
    ///   element's names — the one name of a self-closing or unclosed element
    ///   — and the bracket pair is suppressed. The tag pair wins here.
    /// - **At an active bracket, not in a tag name:** no tag ranges. The
    ///   bracket pair wins here.
    /// - **Otherwise:** the innermost enclosing element that has a closing
    ///   name gives its two names, one level only; self-closing and unclosed
    ///   elements are passed over. Both highlights may show.
    public static func highlight(caret: Int, enclosing: [TagElement], bracketPairActive: Bool) -> Highlight {
        for element in enclosing {
            let names = [element.openName] + (element.closeName.map { [$0] } ?? [])
            if names.contains(where: { contains($0, caret) }) {
                return Highlight(tagRanges: names, suppressBracketPair: true)
            }
        }
        guard !bracketPairActive else { return .none }
        guard let element = enclosing.first(where: { $0.closeName != nil }),
              let closeName = element.closeName else { return .none }
        return Highlight(tagRanges: [element.openName, closeName], suppressBracketPair: false)
    }

    private static func contains(_ name: NSRange, _ caret: Int) -> Bool {
        name.location != NSNotFound && caret >= name.location && caret <= NSMaxRange(name)
    }
}
