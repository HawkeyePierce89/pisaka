import Foundation

/// One place an identifier is used — the row the usages panel draws and the
/// editor navigates to.
///
/// **A location, not a declaration**, for `DefinitionCandidate`'s reason (D8) and
/// then some: the question "where is this used" has no kind in its answer at all,
/// not even the optional one a definition carries, because every row is by
/// construction a *reference* rather than a thing that was declared. So the type
/// is flat: a file, a buffer range, the line the gutter would print beside it, the
/// path the group header shows, and the one line of text a row displays.
///
/// `isTextual` is the honesty flag. A row from a language server is a semantic
/// reference — the server resolved the symbol and this is genuinely it — while a
/// row from `TextualUsageScanner` is a whole-word string match that may name a
/// completely unrelated symbol with the same spelling. The two are the same shape
/// and must never be presented as the same claim, so the provenance travels with
/// the row rather than only with the answer that carries it: a panel that lost the
/// distinction would be a panel confidently listing coincidences.
public struct UsageResult: Equatable, Sendable {
    /// The file the usage is in.
    public let fileURL: URL
    /// UTF-16 range of the occurrence in that file, in the coordinates of the text
    /// the row was computed against — the open buffer where one existed, the disk
    /// copy otherwise.
    public let range: NSRange
    /// 1-based display line of `range`, counted with the editor's own separators
    /// (`LineStartIndex`) rather than with the protocol's (D1), so the number in
    /// the row is the number in the gutter.
    public let line: Int
    /// The file's path below the project root, or its file name when it lives
    /// outside one — precomputed here for `DefinitionCandidate.relativePath`'s
    /// reason: the root is the provider's knowledge, and both platforms must spell
    /// the same file identically.
    public let relativePath: String
    /// The single line the row shows, with the occurrence's range inside it —
    /// Find in Files' shape, so a usages row and a search row read alike.
    public let preview: MatchPreview
    /// Whether this row is a whole-word text match rather than a resolved
    /// reference. See the type's note: this is a claim about how much the row
    /// means, not a display detail.
    public let isTextual: Bool

    public init(
        fileURL: URL,
        range: NSRange,
        line: Int,
        relativePath: String,
        preview: MatchPreview,
        isTextual: Bool
    ) {
        self.fileURL = fileURL
        self.range = range
        self.line = line
        self.relativePath = relativePath
        self.preview = preview
        self.isTextual = isTextual
    }
}
