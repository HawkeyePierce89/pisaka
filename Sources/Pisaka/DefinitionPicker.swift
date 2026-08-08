#if os(macOS)
import AppKit
import PisakaCore

/// The "which one did you mean?" surface of Go to Definition: an `NSMenu` popped
/// up under the identifier, one item per candidate.
///
/// A menu rather than a custom `NSPanel` on purpose (Decision 3 of the phase-1
/// plan): AppKit gives arrow-key navigation, type-select, Esc dismissal and
/// correct screen-edge flipping for free, and there is no window controller to
/// own, position or tear down across a tab switch. The cosmetic price is that a
/// row is one string — which is exactly what `DefinitionCandidate.displayLabel`
/// is for, so *both* platforms show the same text and this file decides nothing
/// about it.
///
/// Thin view-layer glue, untested by convention: the candidate list and its order
/// arrive already ranked from `SymbolIntelligenceProvider`.
@MainActor
enum DefinitionPicker {

    /// Pop the picker under `range` in `textView` and call `onSelect` with the
    /// chosen candidate (never called when the user dismisses the menu).
    ///
    /// `NSMenu.popUp(positioning:at:in:)` tracks modally and returns only once the
    /// menu is gone, so the local `target` — which the menu items reference
    /// *weakly*, as `NSMenuItem.target` always does — stays alive for exactly as
    /// long as it can be messaged.
    static func present(
        _ candidates: [DefinitionCandidate],
        in textView: NSTextView,
        anchoredTo range: NSRange,
        onSelect: @escaping (DefinitionCandidate) -> Void
    ) {
        guard !candidates.isEmpty else { return }

        let target = Target(candidates: candidates, onSelect: onSelect)
        let menu = NSMenu()
        // The items are model-driven, not responder-driven: without this AppKit
        // would ask a validator that does not exist and grey every row out.
        menu.autoenablesItems = false
        for (offset, candidate) in candidates.enumerated() {
            let item = NSMenuItem(
                title: candidate.displayLabel,
                action: #selector(Target.select(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.tag = offset
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: anchorPoint(in: textView, for: range), in: textView)
    }

    /// The bottom-left corner of `range` in `textView`'s coordinates, so the menu
    /// hangs under the identifier the way a completion popup does.
    ///
    /// The glyph bounds are asked of the layout manager (rather than
    /// `firstRect(forCharacterRange:)`, which answers in *screen* coordinates and
    /// would then have to be converted back) and offset by the text container's
    /// origin, which is non-zero here because the gutter is a ruler view. The
    /// range is clamped first: it was computed against the buffer as it was when
    /// the question was asked, and an edit may have shortened it since.
    private static func anchorPoint(in textView: NSTextView, for range: NSRange) -> NSPoint {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return textView.textContainerOrigin }

        let length = textView.textStorage?.length ?? 0
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: clamped,
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        // The text view is flipped, so `maxY` is the *bottom* of the line.
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    /// The menu's action receiver. `NSMenuItem.target` is a weak reference, so
    /// this is kept alive by the caller's local `let` for the duration of the
    /// modal `popUp` — the only window in which an item can be chosen.
    private final class Target: NSObject {
        private let candidates: [DefinitionCandidate]
        private let onSelect: (DefinitionCandidate) -> Void

        init(candidates: [DefinitionCandidate], onSelect: @escaping (DefinitionCandidate) -> Void) {
            self.candidates = candidates
            self.onSelect = onSelect
        }

        @objc func select(_ sender: NSMenuItem) {
            guard candidates.indices.contains(sender.tag) else { return }
            onSelect(candidates[sender.tag])
        }
    }
}

#endif
