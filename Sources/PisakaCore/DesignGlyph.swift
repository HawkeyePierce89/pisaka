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
/// by set equality, each PDF's bytes to the export's manifest digest, and each
/// `nativeSize` to the size the export's record states — so adding a case
/// without its asset, or an asset without its case, fails the Core gate.
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

    /// The asset catalog name the app loads this glyph by.
    public var assetName: String { rawValue }

    /// The glyph's drawn size in points at interface scale 1.0, as the design
    /// export states it — the size a surface draws it at unless its own task
    /// names another. The drawing helper multiplies it by the interface scale.
    public var nativeSize: Double {
        switch self {
        case .package, .gitBranch, .chevronDown, .chevronRight, .gitPullRequest,
             .check, .terminal, .fileWarning, .gitCompare, .listChecks, .search,
             .gitPullRequestArrow, .database, .x, .userRound:
            11
        case .folder, .folderOpen, .fileCode, .fileText:
            12
        case .undo2, .refreshCw:
            13
        case .caseSensitive, .wholeWord, .regex:
            14
        }
    }
}
