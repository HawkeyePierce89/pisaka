/// The design's own glyphs: the one name table every macOS chrome surface
/// reads when it draws one.
///
/// Each case is one template vector image in the app's asset catalog
/// (`Sources/Pisaka/Assets.xcassets/Glyphs/<rawValue>.imageset`), and the **raw
/// value is that asset's name** — so the name is spelled once, here, and the
/// app layer's single drawing helper loads it by string (the catalog does not
/// generate asset symbols). A name is a string, as `FileIcon`'s symbol name is,
/// so this stays Foundation-only and colour-free.
///
/// `DesignGlyphAssetTests` holds the case set equal to the catalog's imagesets
/// by set equality and each PDF's bytes to the export's manifest digest — so
/// adding a case without its asset, or an asset without its case, fails the
/// Core gate. The table carries no size: a glyph is drawn at whatever size the
/// surface drawing it states.
/// Provenance and the update procedure are in `Resources/DesignGlyphs/VENDORED.md`.
public enum DesignGlyph: String, CaseIterable, Sendable {
    case package
    case gitBranch = "git-branch"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case gitPullRequest = "git-pull-request"
    case check
    case terminal
    case fileWarning = "file-warning"
    case gitCompare = "git-compare"
    case listChecks = "list-checks"
    case search
    case gitPullRequestArrow = "git-pull-request-arrow"
    case folder
    case folderOpen = "folder-open"
    case fileCode = "file-code"
    case fileText = "file-text"
    case database
    case x
    case userRound = "user-round"
    case undo2 = "undo-2"
    case refreshCw = "refresh-cw"
    case caseSensitive = "case-sensitive"
    case wholeWord = "whole-word"
    case regex
    case plus

    /// The asset catalog name the app loads this glyph by.
    public var assetName: String { rawValue }
}
