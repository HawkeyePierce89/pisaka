#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PisakaCore

/// The editor's single built-in color theme: a `SyntaxTokenKind → Color` table.
///
/// Each kind resolves to a dynamic color that follows the system appearance
/// (distinct light/dark variants), so highlighting stays legible in both modes
/// without a user-configurable theme system (out of scope for the MVP). Color
/// lives here in the view layer; `PisakaCore` stays color-free (mirroring the
/// `FileIconColor` precedent).
///
/// The color table is built through the cross-platform `PlatformColor` bridge
/// (`NSColor` on macOS, `UIColor` on iOS), so the same theme drives both the
/// AppKit (`CodeEditorView`) and UIKit (`CodeEditorView_iOS`) editors.
struct SyntaxTheme {
    /// The shared built-in theme.
    static let shared = SyntaxTheme()

    /// The appearance-aware foreground color for a token kind, for the text-view
    /// attribute provider. `.plain` (and any unmapped kind) falls back to the
    /// default label color so ordinary text matches the editor's foreground.
    func color(for kind: SyntaxTokenKind) -> PlatformColor {
        if let mapped = SyntaxTheme.table[kind] { return mapped }
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    #if os(macOS)
    /// The appearance-aware `NSColor` for a token kind. Exposed for the
    /// `NSTextView` attribute provider, which needs an `NSColor` foreground. On
    /// macOS `PlatformColor` is `NSColor`, so this is `color(for:)` unchanged —
    /// the existing AppKit call sites keep the same dynamic `NSColor`s as before.
    func nsColor(for kind: SyntaxTokenKind) -> NSColor {
        color(for: kind)
    }
    #endif

    // MARK: - Brackets

    /// The rainbow palette, cycled by nesting depth (JetBrains Rainbow Brackets).
    ///
    /// `BracketDepthScanner` reports an *honest* depth (7 stays 7) and the palette
    /// is resolved here with `depth % count` — the "semantics in Core, color in the
    /// view" split the rest of the theme follows. Five hues, each far enough from
    /// its neighbours to be told apart at a glance and from the punctuation gray
    /// the brackets would otherwise take.
    var bracketDepthColors: [PlatformColor] { SyntaxTheme.bracketPalette }

    /// The bracket color for a nesting depth, cycling through
    /// `bracketDepthColors`. A negative depth (which the scanner never produces)
    /// folds back into range rather than trapping.
    func bracketColor(forDepth depth: Int) -> PlatformColor {
        let palette = SyntaxTheme.bracketPalette
        guard !palette.isEmpty else { return color(for: .punctuation) }
        let index = ((depth % palette.count) + palette.count) % palette.count
        return palette[index]
    }

    /// The color of a bracket `BracketDepthScanner` reported as unmatched — a
    /// stray/wrong-kind closer or an opener the document never closes. Red, and
    /// deliberately *not* the `.string` red: an unmatched bracket is an error
    /// marker, so it is the most saturated color in the editor.
    var unmatchedBracketColor: PlatformColor { SyntaxTheme.unmatchedBracket }

    /// The background painted behind both halves of the pair
    /// `BracketMatchEngine` matched for the caret (VS Code/Xcode). Opaque and
    /// neutral: every rainbow color has to stay readable on top of it, and it must
    /// not be mistaken for the selection highlight.
    var matchedPairBackground: PlatformColor { SyntaxTheme.pairBackground }

    // MARK: - Search

    /// The background painted behind every match of the editor's search bar
    /// (⌘F), except the one the caret is currently on.
    ///
    /// A warm yellow, deliberately far from `matchedPairBackground` (a neutral
    /// blue-gray) and from the selection highlight (the user's accent color), so
    /// a match sitting on a bracket pair and a match inside the selection both
    /// stay recognizable as matches.
    var searchMatchBackground: PlatformColor { SyntaxTheme.searchBackground }

    /// The background of the *current* match — the one ⌘G steps through and
    /// `EditorSearchController` scrolls to. A saturated orange: same family as
    /// `searchMatchBackground` (so it reads as "one of the matches") but
    /// unmistakably the highlighted one at a glance.
    var currentSearchMatchBackground: PlatformColor { SyntaxTheme.currentSearchBackground }

    #if os(macOS)
    /// `NSColor` wrappers for the AppKit editor, mirroring `nsColor(for:)`. On
    /// macOS `PlatformColor` *is* `NSColor`, so these only spell the type out for
    /// the temporary-attribute call sites in `BracketOverlayLayoutManager`.
    func nsBracketColor(forDepth depth: Int) -> NSColor {
        bracketColor(forDepth: depth)
    }

    var nsUnmatchedBracketColor: NSColor { unmatchedBracketColor }

    var nsMatchedPairBackground: NSColor { matchedPairBackground }

    var nsSearchMatchBackground: NSColor { searchMatchBackground }

    var nsCurrentSearchMatchBackground: NSColor { currentSearchMatchBackground }
    #endif

    /// Depth → color, cycled. Gold, purple, blue, teal, green.
    private static let bracketPalette: [PlatformColor] = [
        .dynamic(light: 0x9A6400, dark: 0xFFD479),
        .dynamic(light: 0x7B2FBE, dark: 0xD9A2FF),
        .dynamic(light: 0x1B6BCC, dark: 0x6FB3FF),
        .dynamic(light: 0x0E7C86, dark: 0x5BD5E0),
        .dynamic(light: 0x1E7A33, dark: 0x7EE787)
    ]

    private static let unmatchedBracket: PlatformColor = .dynamic(light: 0xC4241A, dark: 0xFF6B60)

    private static let pairBackground: PlatformColor = .dynamic(light: 0xD0DCEA, dark: 0x3D4B5C)

    private static let searchBackground: PlatformColor = .dynamic(light: 0xF3E39B, dark: 0x5C4F1E)

    private static let currentSearchBackground: PlatformColor = .dynamic(light: 0xFFB454, dark: 0x9A6218)

    /// Token kind → appearance-aware color. Tones loosely follow Xcode's default
    /// light/dark presentation themes. Built through the cross-platform
    /// `PlatformColor.dynamic(light:dark:)` bridge (on macOS `PlatformColor` is
    /// `NSColor`, so these stay the exact same dynamic `NSColor`s as before).
    private static let table: [SyntaxTokenKind: PlatformColor] = [
        .keyword: .dynamic(light: 0x9B2393, dark: 0xFC5FA3),
        .string: .dynamic(light: 0xC41A16, dark: 0xFC6A5D),
        .comment: .dynamic(light: 0x536579, dark: 0x7E8C99),
        .number: .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .type: .dynamic(light: 0x3F6E75, dark: 0x5DD8FF),
        .function: .dynamic(light: 0x326D74, dark: 0x67B7A4),
        .variable: .dynamic(light: 0x0F68A0, dark: 0x9EF1DD),
        .constant: .dynamic(light: 0x1C00CF, dark: 0xD0BF69),
        .operator: .dynamic(light: 0x3D3D3D, dark: 0xD6D6D6),
        .punctuation: .dynamic(light: 0x3D3D3D, dark: 0xD6D6D6),
        .property: .dynamic(light: 0x0F68A0, dark: 0x67B7A4),
        .parameter: .dynamic(light: 0x0F68A0, dark: 0x9EF1DD),
        .label: .dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    ]
}

#endif
