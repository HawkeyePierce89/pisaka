import Foundation

/// The ordered edits and resulting carets for one Tab press.
///
/// `replacements` are sorted by ascending location and never overlap, which is
/// what lets the view apply them **back-to-front** inside a single undo group:
/// applying the last one first leaves every earlier range's offsets untouched.
/// `carets` are zero-length `NSRange`s in the *resulting* text, in the same
/// order, ready to hand to `setSelectedRanges` — one per replacement, so a
/// multi-caret column selection survives the insertion instead of collapsing to
/// a single caret.
///
/// `IndentReplacement` is reused verbatim here: a (range, replacement) pair is a
/// (range, replacement) pair whether the dedent rule or this one produced it.
public struct TabInsertionPlan: Equatable {
    public let replacements: [IndentReplacement]
    public let carets: [NSRange]

    public init(replacements: [IndentReplacement], carets: [NSRange]) {
        self.replacements = replacements
        self.carets = carets
    }

    /// Nothing to do — an empty selection list, which the view treats as "let
    /// the responder chain have the key".
    public static let empty = TabInsertionPlan(replacements: [], carets: [])

    public var isEmpty: Bool { replacements.isEmpty }
}

/// Which string is one indentation level, and what the Tab key inserts.
///
/// Two questions with deliberately *different* answers, because they carry
/// different risks. Auto-indent already picks a unit for every file, so letting
/// `.editorconfig` refine it changes only which whitespace an already-automatic
/// insertion uses. The Tab key, by contrast, is what the user pressed: turning
/// it into spaces on a file the *content inference* merely guessed was
/// space-indented would silently rewrite what typing does. So the configuration
/// alone may do that, and only by saying so outright.
///
/// The unit rule is **hybrid**, per the feature's answered question: `indent_style`
/// decides tabs vs. spaces, `indent_size`/`tab_width` decides the width, and each
/// half the configuration leaves out falls back to what `IndentEngine
/// .inferIndentUnit(text:)` said for that half. A file with no applicable
/// property at all gets the inference back byte-for-byte, so a project without
/// `.editorconfig` behaves exactly as it did before this layer existed.
///
/// Pure and Foundation-only, like every other engine here: the views ask, they
/// do not decide.
public enum IndentUnitRule {

    /// The width used when the configuration asks for spaces of an unstated
    /// width and the inference cannot supply one either (because it says tab).
    /// Four matches `IndentEngine.inferIndentUnit`'s own fallback.
    static let defaultSpaceWidth = 4

    /// The widest indentation level that is honored.
    ///
    /// `indent_size` is any positive integer as far as the parser is concerned,
    /// and the unit it produces is *built as a string on the main thread* for
    /// every Enter and every Tab. An untrusted `indent_size = 2000000000` would
    /// allocate two gigabytes per keystroke, and an ordinary typo
    /// (`indent_size = 44444`) a 44 KB indent per level. Clamping rather than
    /// rejecting keeps a merely-large width behaving like a large width.
    static let maximumSpaceWidth = 64

    /// One indentation level for this file: what Enter's auto-indent appends.
    ///
    /// - `indent_style = tab` → a tab, whatever the file's own content looks
    ///   like and whatever width is configured (a width describes how a tab is
    ///   *displayed*, never what is inserted).
    /// - `indent_style = space` → spaces, as wide as the configuration says;
    ///   with no width configured, as wide as the inferred unit when *that* is
    ///   spaces, and `defaultSpaceWidth` when the inference says tab (there is
    ///   no width to carry over from a tab).
    /// - no `indent_style` → the inference decides tabs vs. spaces, and a
    ///   configured width re-widens it when it is spaces. A tab inference stays
    ///   a tab: a width alone never converts a file.
    /// - nothing applicable → `inferred`, returned unchanged.
    public static func unit(config: EditorConfigProperties, inferred: String) -> String {
        let configuredWidth = config.indentWidth
        switch config.indentStyle {
        case .tab:
            return "\t"
        case .space:
            return spaces(configuredWidth ?? inferredWidth(of: inferred) ?? defaultSpaceWidth)
        case nil:
            guard let width = configuredWidth, inferredWidth(of: inferred) != nil else { return inferred }
            return spaces(width)
        }
    }

    /// What the Tab key inserts: the effective unit **only** when the
    /// configuration says `indent_style = space`, and a literal tab in every
    /// other case.
    ///
    /// Stricter than `unit(config:inferred:)` on purpose. Without a
    /// configuration the key keeps doing exactly what it does today — insert a
    /// tab — so the content inference on its own can never turn a keystroke into
    /// spaces; and `indent_style = tab`, or a bare `indent_size` with no style,
    /// leaves it a tab too.
    public static func tabInsertion(config: EditorConfigProperties, inferred: String) -> String {
        guard config.indentStyle == .space else { return "\t" }
        return unit(config: config, inferred: inferred)
    }

    /// The edits and carets for inserting `insertion` at every one of the
    /// selection's `ranges`.
    ///
    /// Every range — a bare caret or a non-empty selection alike — is *replaced*
    /// by `insertion`, which is what the native Tab does at each insertion
    /// point. The resulting caret for each one sits at the end of its own
    /// insertion, shifted by the net length change of every earlier range, so
    /// the whole multi-caret state the column-selection gesture builds comes out
    /// the other side intact.
    ///
    /// The input is normalized rather than trusted: ranges arrive sorted, and
    /// overlapping ones (including duplicate carets) are unioned, so the
    /// replacements can be applied back-to-front without one edit invalidating
    /// the next. An empty list answers `.empty`.
    public static func tabInsertionPlan(ranges: [NSRange], insertion: String) -> TabInsertionPlan {
        let normalized = normalize(ranges)
        guard !normalized.isEmpty else { return .empty }

        let insertedLength = (insertion as NSString).length
        var replacements: [IndentReplacement] = []
        var carets: [NSRange] = []
        var shift = 0
        for range in normalized {
            replacements.append(IndentReplacement(range: range, replacement: insertion))
            carets.append(NSRange(location: range.location + shift + insertedLength, length: 0))
            shift += insertedLength - range.length
        }
        return TabInsertionPlan(replacements: replacements, carets: carets)
    }

    // MARK: - Helpers

    /// Sorted by location, with overlapping (and duplicate) ranges unioned.
    private static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            // Touching-but-not-overlapping ranges stay separate: a caret at the
            // end of a selection is a second insertion point, not the same one.
            // Anything starting where `last` starts is the same insertion point,
            // though — two identical carets, and equally a caret sitting at the
            // *start* of a selection, whose `NSMaxRange` is its own location and
            // so is not caught by the strict `<` above.
            let overlaps = range.location < NSMaxRange(last) || range.location == last.location
            if overlaps {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func spaces(_ width: Int) -> String {
        String(repeating: " ", count: min(max(1, width), maximumSpaceWidth))
    }

    /// The inferred unit's width when it is spaces, `nil` when it is a tab (or
    /// anything else with no space run to measure).
    private static func inferredWidth(of inferred: String) -> Int? {
        guard !inferred.isEmpty, inferred.allSatisfy({ $0 == " " }) else { return nil }
        return inferred.count
    }
}
